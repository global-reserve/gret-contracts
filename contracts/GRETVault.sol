// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceGuard} from "./IPriceGuard.sol";

/// @title Global Reserve Token vault
/// @notice Basket of ERC-20 components whose shares are GRET. Mint and normal redemption are in
/// kind and proportional to the active components' actual balances, so no amount per GRET is set
/// anywhere: it follows what the vault holds. Governance, an external contract whose voting lives
/// outside the vault, can start an irreversible liquidation in which any holder exits component by
/// component, decides what to do with tokens that are not backing GRET, and changes the basket: it
/// adds and removes components and appoints a rebalancer that exchanges one component for another.
/// Nobody can take reserves without delivering another component in exchange, and every exchange
/// must pass a price guard, an external contract that holds the prices and the loss limits; every
/// new rebalancer, price guard and component waits seven days. A component that stops working can
/// be written off after the same wait. Governance can charge mint and redemption fees in GRET, at
/// most 5% each; raising them waits too. It can pause minting at once, but never redemption. GRET
/// supports EIP-2612 `permit`.
/// @dev Not independently audited. The specification, including the known limitations, is in
/// docs/SPECIFICATION.md.
contract GRETVault is ERC20, ERC20Permit, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @dev Also the EIP-712 domain name that `permit` signatures commit to.
    string private constant NAME = "Global Reserve Token";

    /// @notice GRET issued by the first mint, and again whenever the supply returns to zero.
    uint256 public constant INITIAL_SHARES = 1e18;
    /// @notice Normal redemption cannot leave the supply above zero but below this amount, so
    /// rounding dust can never dominate the basket.
    uint256 public constant MIN_SUPPLY = INITIAL_SHARES;
    /// @notice Maximum base-unit residue allowed when deactivating or removing an empty component.
    uint256 public constant MAX_REMOVAL_DUST = 10;
    /// @notice Highest number of components. Mint and redemption visit every component in one
    /// transaction, so the cap keeps them within Ethereum's per-transaction gas limit.
    uint256 public constant MAX_COMPONENTS = 128;
    /// @notice Base units a component may deliver below the requested amount on mint. Covers tokens
    /// that convert amounts to internal shares (xStocks); transfer fees still revert.
    uint256 public constant MAX_RECEIPT_SHORTFALL = 10;
    /// @notice Minimum wait, enforced by the vault, before a proposed governance may accept.
    uint256 public constant GOVERNANCE_TRANSFER_DELAY = 7 days;
    /// @notice Minimum wait, enforced by the vault, before a new rebalancer, price guard or
    /// component takes effect, so holders see every change to who may exchange the reserves, at
    /// what price and for what.
    uint256 public constant BASKET_CHANGE_DELAY = 7 days;
    /// @notice Time after its wait ends during which a proposal can still be executed or accepted;
    /// after it, the proposal expires and must be made again, so an old notice cannot be used at
    /// any moment later.
    uint256 public constant EXECUTION_WINDOW = 7 days;
    /// @notice Highest mint or redemption fee, in basis points of the GRET issued or redeemed: 5%.
    uint256 public constant MAX_FEE = 500;
    /// @notice Minimum wait, enforced by the vault, before a raise of either fee takes effect.
    uint256 public constant FEE_INCREASE_DELAY = 7 days;
    uint256 private constant FEE_DENOMINATOR = 10_000;

    /// @dev A successor waiting out its notice: who takes over, and from when.
    struct Proposal {
        address next;
        uint256 readyAt;
    }

    /// @notice Starts liquidation, manages component activation and changes the basket; appoints
    /// the rebalancer and its own successor.
    address public governance;
    /// @notice Proposed successor of `governance`, which may accept from `readyAt`; zero if none.
    Proposal public governanceProposal;

    /// @notice Exchanges one component for another at the price it chooses, within the limits of
    /// the price guard. Zero when nobody can, as at deployment.
    address public rebalancer;
    /// @notice Proposed rebalancer, which may accept from `readyAt`; zero if none.
    Proposal public rebalancerProposal;
    /// @notice Prices every swap and refuses the ones that lose too much. None at deployment, and
    /// without one there are no swaps.
    IPriceGuard public priceGuard;
    /// @notice The guard that `applyPriceGuard` last replaced, from which the next one can continue
    /// the week's loss count; zero until the first replacement.
    address public previousPriceGuard;
    /// @notice Proposed price guard, which anyone may apply from `readyAt`; zero if none.
    Proposal public priceGuardProposal;
    /// @notice Earliest timestamp at which an announced token may join the basket; zero if none.
    mapping(address token => uint256) public componentReadyAt;
    /// @notice Earliest timestamp at which a proposed write-off may take effect; zero if none.
    mapping(address token => uint256) public writeOffReadyAt;
    /// @notice Permanent write-off history. These tokens can never be rescued or removed, even
    /// after governance reactivates them for normal operation.
    mapping(address token => bool) public writtenOff;
    /// @notice Excluded components are never called by mint, normal redemption or the price guard.
    mapping(address token => bool) public excluded;

    /// @notice Share of the GRET issued by a mint that goes to `feeRecipient`, in basis points.
    uint256 public mintFee;
    /// @notice Share of the GRET a redemption takes that goes to `feeRecipient` instead of being
    /// redeemed, in basis points.
    uint256 public redeemFee;
    /// @notice Receives the fees in GRET, as chosen by governance. Every positive fee needs one.
    address public feeRecipient;
    uint256 public pendingMintFee;
    uint256 public pendingRedeemFee;
    /// @notice Earliest timestamp at which the pending fees may be applied; zero if none.
    uint256 public pendingFeesReadyAt;

    IERC20[] private _components;
    /// @dev Component index plus one; zero for tokens outside the basket.
    mapping(address token => uint256) private _componentSlot;
    uint256[] private _initialAmounts;

    /// @dev Claim totals of one component. Only claims write them, during liquidation, when the
    /// basket can no longer change, so they are keyed by index and never move.
    struct LiquidationTotals {
        /// @dev Established nominal basis: set on the component's first successful claim and raised
        /// by later income.
        uint256 basis;
        /// @dev Rights consumed, before any loss haircut.
        uint256 consumedRights;
        /// @dev Amounts actually paid out.
        uint256 paid;
    }

    mapping(uint256 index => LiquidationTotals) private _liquidationTotals;

    /// @notice Wallets that completed a mint and may use normal redemption. Not transferable.
    mapping(address account => bool) public hasMinted;

    /// @notice While true, `mint` reverts. Executing a write-off, or a skipping redemption that
    /// leaves zero supply, sets it. Redemption is never paused.
    bool public mintPaused;
    /// @notice Grows by one whenever a component is added or removed. Calls that pass amounts by
    /// position (`mint`, both redemptions, `setInitialAmounts`) state the version they were
    /// prepared for, so their limits never land on another token.
    uint256 public basketVersion;

    /// @notice Set by `activateLiquidation` and never cleared.
    bool public liquidationActive;
    /// @notice GRET supply when liquidation started; denominator of every claim.
    uint256 public liquidationSupply;
    /// @notice GRET burned by each account in exchange for liquidation rights.
    mapping(address account => uint256) public convertedShares;
    /// @notice Liquidation rights each account already consumed, per component. Equals the amount
    /// paid unless a loss reduced the payout.
    mapping(address account => mapping(uint256 index => uint256)) public consumedRights;

    event Minted(address indexed account, address indexed to, uint256 shares, uint256[] amounts);
    event Redeemed(address indexed account, address indexed to, uint256 shares, uint256[] amounts);
    event ComponentActivationChanged(address indexed token, bool active);
    event LiquidationActivated(uint256 supply);
    event MintPauseChanged(bool paused);
    event ConvertedToClaims(address indexed account, uint256 shares);
    event Claimed(
        address indexed account, uint256 indexed index, address to, uint256 amount, uint256 rights
    );
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event Swapped(
        address indexed sold, uint256 soldAmount, address indexed bought, uint256 boughtAmount
    );
    event RebalancerProposed(address indexed pending, uint256 readyAt);
    event RebalancerProposalCancelled(address indexed pending);
    event RebalancerChanged(address indexed previous, address indexed next);
    event PriceGuardProposed(address indexed pending, uint256 readyAt);
    event PriceGuardProposalCancelled(address indexed pending);
    event PriceGuardChanged(address indexed previous, address indexed next);
    event ComponentAnnounced(address indexed token, uint256 readyAt);
    event ComponentAnnouncementCancelled(address indexed token);
    event ComponentAdded(address indexed token, uint256 index);
    event ComponentRemoved(address indexed token, uint256 index);
    event InitialAmountsSet(uint256[] amounts);
    event WriteOffProposed(address indexed token, uint256 readyAt);
    event WriteOffCancelled(address indexed token);
    event ComponentWrittenOff(address indexed token);
    event FeesProposed(uint256 mintFee, uint256 redeemFee, uint256 readyAt);
    event FeesProposalCancelled();
    event FeesChanged(uint256 mintFee, uint256 redeemFee);
    event FeeRecipientChanged(address indexed previous, address indexed next);
    event FeeCharged(address indexed payer, address indexed recipient, uint256 shares);
    event GovernanceProposed(address indexed pending, uint256 readyAt);
    event GovernanceProposalCancelled(address indexed pending);
    event GovernanceTransferred(address indexed previous, address indexed next);

    error InvalidComponentCount(uint256 count);
    error LengthMismatch(uint256 expected, uint256 actual);
    error NotAContract(address account);
    error InvalidContract(address account);
    error DuplicateComponent(address token);
    error ZeroInitialAmount(uint256 index);
    error ZeroAddress();
    error InvalidIndex(uint256 index);
    error ZeroShares();
    error InvalidInitialMint(uint256 shares);
    error AmountInAboveMax(uint256 index, uint256 amount, uint256 maxAmount);
    error AmountOutBelowMin(uint256 index, uint256 amount, uint256 minAmount);
    error UnexpectedBalance(uint256 index, uint256 expected, uint256 actual);
    error SharesExceedSupply(uint256 shares, uint256 supply);
    error SupplyBelowMinimum(uint256 remaining);
    error InvalidRecipient();
    error RedemptionNotEnabled(address account);
    error NoSupply();
    error LiquidationIsActive();
    error MintIsPaused();
    error BasketChanged(uint256 expected, uint256 current);
    error LiquidationNotActive();
    error NothingToClaim(address account, uint256 index);
    error ZeroAmount();
    error SharesBelowMin(uint256 shares, uint256 minShares);
    error NotGovernance(address caller);
    error NotRebalancer(address caller);
    error NoPriceGuard();
    error NotAComponent(address token);
    error SameComponent(address token);
    error SwapExceedsReserve(address token, uint256 amount, uint256 reserve);
    error NoPendingComponent(address token);
    error ComponentNotEmpty(address token, uint256 balance);
    error EmptyBasket();
    error NoPendingWriteOff(address token);
    error ComponentExcluded(address token);
    error BackingToken(address token);
    error ComponentBalanceReduced(address token);
    error TokenWrittenOff(address token);
    error FeeAboveMax(uint256 fee);
    error NoPendingFees();
    error NoFeeRecipient();
    error NoPendingProposal();
    error NotProposed(address caller);
    error NotReady(uint256 readyAt);
    error ProposalExpired(uint256 expiredAt);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance(msg.sender);
        _;
    }

    constructor(IERC20[] memory components_, uint256[] memory initialAmounts_, address governance_)
        ERC20(NAME, "GRET")
        ERC20Permit(NAME)
    {
        uint256 count = components_.length;
        if (count == 0 || count > MAX_COMPONENTS) revert InvalidComponentCount(count);
        if (initialAmounts_.length != count) revert LengthMismatch(count, initialAmounts_.length);
        if (governance_ == address(0)) revert ZeroAddress();

        for (uint256 i; i < count; ++i) {
            address token = address(components_[i]);
            _requireNewComponent(token);
            if (initialAmounts_[i] == 0) revert ZeroInitialAmount(i);
            _pushComponent(token, initialAmounts_[i]);
        }
        governance = governance_;
        emit GovernanceTransferred(address(0), governance_);
    }

    // ---------------------------------------------------------------------------------------------
    // Mint and redemption
    // ---------------------------------------------------------------------------------------------

    /// @notice Contributes every component in proportion to the reserves and mints up to `shares`
    /// GRET: the mint fee goes to `feeRecipient` and the rest to `to`, reverting if `to` would get
    /// fewer than `minShares`. The caller pays the components. The first mint (supply zero)
    /// contributes the initial basket for exactly 1 GRET in total. Excluded or zero-balance
    /// components are not asked for. `version` is the `basketVersion` that `maxAmountsIn` was
    /// prepared for.
    /// @dev Contributions round up. GRET is issued for what actually arrived, rounded down, so a
    /// component that delivers a few units less costs the minter, never the existing holders;
    /// `minShares` bounds that cost. Every limit is checked before any input is pulled.
    function mint(
        uint256 shares,
        address to,
        uint256[] calldata maxAmountsIn,
        uint256 minShares,
        uint256 version
    ) external nonReentrant returns (uint256 minted, uint256[] memory received) {
        _requireNotLiquidating();
        if (mintPaused) revert MintIsPaused();
        if (shares == 0) revert ZeroShares();
        _requireBasket(version, maxAmountsIn.length);

        uint256 supply = totalSupply();
        (uint256[] memory amounts, uint256[] memory balancesBefore) = _mintAmounts(shares, supply);
        uint256 count = amounts.length;
        bool contributes;
        for (uint256 i; i < count; ++i) {
            if (amounts[i] > maxAmountsIn[i]) {
                revert AmountInAboveMax(i, amounts[i], maxAmountsIn[i]);
            }
            if (amounts[i] != 0) contributes = true;
        }
        // Without this, GRET backed by nothing could be minted after every reserve was lost.
        if (!contributes) revert EmptyBasket();

        received = new uint256[](count);
        uint256 issued = shares;
        for (uint256 i; i < count; ++i) {
            if (amounts[i] == 0) continue;
            received[i] = _pull(i, amounts[i], balancesBefore[i]);
            if (supply != 0) {
                issued = Math.min(issued, Math.mulDiv(received[i], supply, balancesBefore[i]));
            }
        }
        // The minter paid for every share, so the fee dilutes nobody.
        uint256 fee = _fee(issued, mintFee);
        minted = issued - fee;
        // Also refuses a mint whose fee, rounded up, takes every share.
        if (minted == 0) revert ZeroShares();
        if (minted < minShares) revert SharesBelowMin(minted, minShares);

        _mint(to, minted);
        if (fee != 0) {
            _mint(feeRecipient, fee);
            emit FeeCharged(msg.sender, feeRecipient, fee);
        }
        hasMinted[msg.sender] = true;
        emit Minted(msg.sender, to, minted, received);
    }

    /// @notice Takes `shares` GRET from the caller: the redemption fee goes to `feeRecipient` and
    /// the rest is burned for the proportional amount of every component, which goes to `to`;
    /// redeeming the whole supply pays no fee. All or nothing: if any transfer fails the whole
    /// redemption reverts. The supply left must be zero or at least `MIN_SUPPLY`. `version` is the
    /// `basketVersion` that `minAmountsOut` was prepared for.
    /// @dev Only for wallets that completed a mint. Amounts round down, in favor of the vault. Live
    /// balances include all income and losses before calculating proportional outputs.
    function redeem(uint256 shares, address to, uint256[] calldata minAmountsOut, uint256 version)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        _requireBasket(version, minAmountsOut.length);
        return _redeem(shares, to, minAmountsOut, new bool[](_components.length));
    }

    /// @notice Like `redeem`, but leaves out the `skipped` components, for when one of them cannot
    /// be sent: an issuer froze the vault, or a token was made to fail. The caller gives up its
    /// share of them, which stays with the other holders, and their `minAmountsOut` must be zero.
    /// If nobody remains, minting pauses so that governance can review what was left before a
    /// bootstrap takes it.
    /// @dev Skipped components are not called at all, so no token can block this exit. It keeps the
    /// 7-day notice of a new rebalancer meaningful: whoever minted can always leave with every
    /// component that still works.
    function redeemSkipping(
        uint256 shares,
        address to,
        uint256[] calldata minAmountsOut,
        address[] calldata skipped,
        uint256 version
    ) external nonReentrant returns (uint256[] memory amounts) {
        _requireBasket(version, minAmountsOut.length);
        amounts = _redeem(shares, to, minAmountsOut, _skipMask(skipped));
        if (skipped.length != 0 && totalSupply() == 0) _setMintPaused(true);
    }

    /// @notice Live mint amounts. Excluded components are not called. Initial mint still uses the
    /// configured basket; preexisting active balances belong to the new first share.
    function previewMint(uint256 shares)
        external
        view
        nonReentrantView
        returns (uint256[] memory amounts)
    {
        _requireNotLiquidating();
        (amounts,) = _mintAmounts(shares, totalSupply());
    }

    /// @notice Live redemption amounts, after fees. Use `previewRedeemSkipping` for a broken token.
    function previewRedeem(uint256 shares)
        external
        view
        nonReentrantView
        returns (uint256[] memory amounts)
    {
        _requireNotLiquidating();
        (amounts,) = _redemptionAmounts(shares, new bool[](_components.length));
    }

    /// @notice Quotes an exit without calling any skipped or excluded component.
    function previewRedeemSkipping(uint256 shares, address[] calldata skipped)
        external
        view
        nonReentrantView
        returns (uint256[] memory amounts)
    {
        _requireNotLiquidating();
        (amounts,) = _redemptionAmounts(shares, _skipMask(skipped));
    }

    // ---------------------------------------------------------------------------------------------
    // Liquidation
    // ---------------------------------------------------------------------------------------------

    /// @notice Starts the irreversible liquidation: closes mint and normal redemption, and fixes
    /// the share denominator. Each component establishes its own basis on its first claim.
    /// @dev Makes no external calls, so a failing component cannot prevent activation.
    function activateLiquidation() external onlyGovernance nonReentrant {
        _requireNotLiquidating();

        uint256 supply = totalSupply();
        if (supply == 0) revert NoSupply();
        liquidationActive = true;
        liquidationSupply = supply;
        emit LiquidationActivated(supply);
    }

    /// @notice Burns GRET in exchange for non-transferable rights over every component. Any holder
    /// may convert, including wallets that never minted.
    function convertToClaims(uint256 shares) external nonReentrant {
        _requireLiquidating();
        if (shares == 0) revert ZeroShares();

        _burn(msg.sender, shares);
        convertedShares[msg.sender] += shares;
        emit ConvertedToClaims(msg.sender, shares);
    }

    /// @notice Withdraws the caller's pending right over one component to `to`, reverting if less
    /// than `minAmount` would be paid.
    /// @dev Calls only that component. If its transfer fails the call reverts and the right stays
    /// pending; rights over other components are unaffected. If the vault holds less of the
    /// component than all pending rights, it pays the same fraction to everyone still pending and
    /// consumes the whole right; `minAmount` lets the caller refuse such a cut and keep waiting.
    function claim(uint256 index, address to, uint256 minAmount)
        external
        nonReentrant
        returns (uint256 amount)
    {
        _requireLiquidating();
        _requireIndex(index);
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidRecipient();

        uint256 basis;
        uint256 rights;
        (basis, rights, amount) = _claimQuote(msg.sender, index);
        if (amount == 0) revert NothingToClaim(msg.sender, index);
        if (amount < minAmount) revert AmountOutBelowMin(index, amount, minAmount);

        LiquidationTotals storage totals = _liquidationTotals[index];
        totals.basis = basis;
        totals.consumedRights += rights;
        totals.paid += amount;
        consumedRights[msg.sender][index] += rights;
        _components[index].safeTransfer(to, amount);
        emit Claimed(msg.sender, index, to, amount, rights);
    }

    /// @notice Current payout including automatically allocated income. Only this token is read.
    function claimable(address account, uint256 index)
        external
        view
        nonReentrantView
        returns (uint256 amount)
    {
        _requireIndex(index);
        (,, amount) = _claimQuote(account, index);
    }

    /// @notice Nominal pending rights, including income since the last claim of this component.
    function pendingRights(address account, uint256 index)
        external
        view
        nonReentrantView
        returns (uint256 rights)
    {
        _requireIndex(index);
        (, rights,) = _claimQuote(account, index);
    }

    /// @notice The basis established by successful claims, without querying any external token.
    function liquidationBasis() external view returns (uint256[] memory amounts) {
        amounts = new uint256[](_components.length);
        for (uint256 i; i < amounts.length; ++i) {
            amounts[i] = _liquidationTotals[i].basis;
        }
    }

    /// @notice Liquidation rights consumed by claims, per component, before any loss haircut.
    function totalConsumedRights() external view returns (uint256[] memory amounts) {
        amounts = new uint256[](_components.length);
        for (uint256 i; i < amounts.length; ++i) {
            amounts[i] = _liquidationTotals[i].consumedRights;
        }
    }

    /// @notice Amounts paid out by claims, per component.
    function totalPaid() external view returns (uint256[] memory amounts) {
        amounts = new uint256[](_components.length);
        for (uint256 i; i < amounts.length; ++i) {
            amounts[i] = _liquidationTotals[i].paid;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Rebalancing
    // ---------------------------------------------------------------------------------------------

    /// @notice Exchanges `sellAmount` of one component for `buyAmount` of another: the rebalancer
    /// delivers first and receives after. The price guard must accept the exchange; without a guard
    /// there are no swaps. Mint and redemption follow the new reserves, so this is how the amounts
    /// per GRET change. `guardData` goes to the guard unchanged, for one that needs prices signed
    /// by an oracle; the vault never reads it.
    /// @dev Both components must be active. The vault measures receipts with the mint tolerance and
    /// the guard prices them. Selling a whole balance stops mint from asking for that component;
    /// removing it still needs an empty balance, which a donation can prevent.
    function swap(
        address sell,
        uint256 sellAmount,
        address buy,
        uint256 buyAmount,
        bytes calldata guardData
    ) external nonReentrant returns (uint256 received) {
        if (msg.sender != rebalancer) revert NotRebalancer(msg.sender);
        _requireNotLiquidating();
        _indexOf(sell);
        uint256 buyIndex = _indexOf(buy);
        if (sell == buy) revert SameComponent(sell);
        if (sellAmount == 0 || buyAmount == 0) revert ZeroAmount();
        IPriceGuard guard = priceGuard;
        if (address(guard) == address(0)) revert NoPriceGuard();

        if (totalSupply() == 0) revert NoSupply();
        if (excluded[sell]) revert ComponentExcluded(sell);
        if (excluded[buy]) revert ComponentExcluded(buy);
        uint256 sellBalance = IERC20(sell).balanceOf(address(this));
        if (sellAmount > sellBalance) revert SwapExceedsReserve(sell, sellAmount, sellBalance);

        received = _pull(buyIndex, buyAmount, IERC20(buy).balanceOf(address(this)));
        // The guard excludes this measured receipt when reconstructing pre-swap backing.
        guard.checkSwap(sell, sellAmount, buy, received, guardData);
        IERC20(sell).safeTransfer(msg.sender, sellAmount);
        emit Swapped(sell, sellAmount, buy, received);
    }

    /// @notice Proposes the address that may swap components. It can take over only after
    /// `BASKET_CHANGE_DELAY`. Replaces any pending proposal and restarts the wait.
    function proposeRebalancer(address next) external onlyGovernance {
        if (next == address(0)) revert ZeroAddress();
        emit RebalancerProposed(next, _propose(rebalancerProposal, next, BASKET_CHANGE_DELAY));
    }

    /// @notice Discards the pending rebalancer.
    function cancelRebalancerProposal() public onlyGovernance {
        emit RebalancerProposalCancelled(_cancel(rebalancerProposal));
    }

    /// @notice The proposed rebalancer takes over after the wait, proving it can call the vault.
    function acceptRebalancer() external {
        _accept(rebalancerProposal);
        address previous = rebalancer;
        rebalancer = msg.sender;
        emit RebalancerChanged(previous, msg.sender);
    }

    /// @notice Leaves the vault without a rebalancer at once, and discards a pending one: taking
    /// the power away needs no wait.
    function revokeRebalancer() external onlyGovernance {
        if (rebalancerProposal.next != address(0)) cancelRebalancerProposal();
        address previous = rebalancer;
        delete rebalancer;
        emit RebalancerChanged(previous, address(0));
    }

    /// @notice Proposes the contract that must accept every swap. It takes effect only after
    /// `BASKET_CHANGE_DELAY`, like a new rebalancer: a guard that misprices lets the rebalancer
    /// take value. Replaces any pending proposal and restarts the wait. The vault itself and
    /// EIP-7702 accounts are refused; the notice binds an address, not the code behind a proxy.
    function proposePriceGuard(address next) external onlyGovernance {
        _requireContract(next);
        emit PriceGuardProposed(next, _propose(priceGuardProposal, next, BASKET_CHANGE_DELAY));
    }

    /// @notice Discards the pending price guard.
    function cancelPriceGuardProposal() external onlyGovernance {
        emit PriceGuardProposalCancelled(_cancel(priceGuardProposal));
    }

    /// @notice Governance decided when it proposed the guard: once the wait is over, anyone can
    /// apply it.
    function applyPriceGuard() external {
        address next = _take(priceGuardProposal);
        address previous = address(priceGuard);
        priceGuard = IPriceGuard(next);
        previousPriceGuard = previous;
        emit PriceGuardChanged(previous, next);
    }

    // ---------------------------------------------------------------------------------------------
    // Basket
    // ---------------------------------------------------------------------------------------------

    /// @notice Announces a token for the basket. It can join only after `BASKET_CHANGE_DELAY`, so
    /// holders see it coming before the rebalancer can buy it with the reserves. Announcing it
    /// again restarts the wait. The vault itself and EIP-7702 accounts are refused. Named apart
    /// from a voting governance's `propose`.
    function announceComponent(address token) external onlyGovernance {
        _requireNewComponent(token);
        uint256 readyAt = block.timestamp + BASKET_CHANGE_DELAY;
        componentReadyAt[token] = readyAt;
        emit ComponentAnnounced(token, readyAt);
    }

    /// @notice Withdraws the announcement of `token` before it joins the basket.
    function cancelComponentAnnouncement(address token) external onlyGovernance {
        if (componentReadyAt[token] == 0) revert NoPendingComponent(token);
        delete componentReadyAt[token];
        emit ComponentAnnouncementCancelled(token);
    }

    /// @notice Adds an announced token once its wait has passed, as the last component. It joins
    /// inactive and with no initial amount. Governance explicitly activates it before it can back
    /// mint and normal redemption or take part in swaps.
    /// @dev Anyone may execute it: governance decided when it announced the token, and can cancel
    /// during the wait, so a voting governance needs one vote per change.
    function addComponent(address token) external nonReentrant {
        _requireNotLiquidating();
        uint256 readyAt = componentReadyAt[token];
        if (readyAt == 0) revert NoPendingComponent(token);
        _requireReady(readyAt);
        uint256 count = _components.length;
        if (count == MAX_COMPONENTS) revert InvalidComponentCount(count + 1);

        delete componentReadyAt[token];
        _pushComponent(token, 0);
        excluded[token] = true;
        ++basketVersion;
        emit ComponentAdded(token, count);
    }

    /// @notice Removes an empty component. Only tokens with at least 18 decimals may leave up to
    /// `MAX_REMOVAL_DUST` base units; lower-precision tokens must have a zero balance. The
    /// components after it move down one index. Any balance left becomes a token outside the
    /// basket, which `rescue` can take in full. A written-off component keeps its recovery rights,
    /// so it can never be removed.
    function removeComponent(address token) external onlyGovernance nonReentrant {
        _requireNotLiquidating();
        uint256 index = _indexOf(token);
        if (writtenOff[token]) revert TokenWrittenOff(token);
        _requireEmpty(token);
        uint256 last = _components.length - 1;
        if (last == 0) revert InvalidComponentCount(0);

        for (uint256 i = index; i < last; ++i) {
            IERC20 next = _components[i + 1];
            _components[i] = next;
            _componentSlot[address(next)] = i + 1;
            _initialAmounts[i] = _initialAmounts[i + 1];
        }
        _components.pop();
        _initialAmounts.pop();
        delete _componentSlot[token];
        delete excluded[token];
        delete writeOffReadyAt[token];
        ++basketVersion;
        emit ComponentRemoved(token, index);
    }

    /// @notice Activates a newly added or previously excluded component. Its whole balance then
    /// backs current holders. This does not erase a historical write-off's rescue prohibition.
    function activateComponent(address token) external onlyGovernance nonReentrant {
        _requireNotLiquidating();
        _indexOf(token);
        _setActive(token, true);
    }

    /// @notice Keeps an empty component inactive even if unsolicited dust later arrives. Larger
    /// balances can only be excluded by the delayed write-off. Exclusion never permits rescue.
    function deactivateEmptyComponent(address token) external onlyGovernance nonReentrant {
        _requireNotLiquidating();
        _indexOf(token);
        _requireEmpty(token);
        _setActive(token, false);
    }

    /// @notice Sets the basket the first mint contributes for 1 GRET. It only applies while the
    /// supply is zero, when no holder is affected. Zero leaves a component out of that mint; at
    /// least one amount must be positive. `version` is the `basketVersion` the amounts were
    /// prepared for, so a call waiting in a timelock cannot land on a reordered basket.
    function setInitialAmounts(uint256[] calldata amounts, uint256 version)
        external
        onlyGovernance
        nonReentrant
    {
        _requireBasket(version, amounts.length);
        bool positive;
        for (uint256 i; i < amounts.length; ++i) {
            _initialAmounts[i] = amounts[i];
            if (amounts[i] != 0 && !excluded[address(_components[i])]) positive = true;
        }
        if (!positive) revert EmptyBasket();
        emit InitialAmountsSet(amounts);
    }

    /// @notice Proposes writing off a component that stopped working, such as one whose issuer
    /// froze the vault: it blocks mint and normal redemption, and it cannot be sold. Governance
    /// judges that; the vault only enforces `BASKET_CHANGE_DELAY` before the write-off takes
    /// effect. Proposing it again restarts the wait.
    function proposeWriteOff(address token) external onlyGovernance {
        _indexOf(token);
        uint256 readyAt = block.timestamp + BASKET_CHANGE_DELAY;
        writeOffReadyAt[token] = readyAt;
        emit WriteOffProposed(token, readyAt);
    }

    /// @notice Discards the pending write-off of `token`, for instance because it recovered.
    function cancelWriteOff(address token) external onlyGovernance {
        if (writeOffReadyAt[token] == 0) revert NoPendingWriteOff(token);
        delete writeOffReadyAt[token];
        emit WriteOffCancelled(token);
    }

    /// @notice Excludes the component, clears its initial amount and pauses minting after the
    /// notice. Makes no token calls. It stays in the basket permanently, protected from rescue and
    /// removal; governance may reactivate it, and liquidation pays out what it recovers.
    /// @dev Anyone may execute it, as with `addComponent`. Governance should cancel the proposal if
    /// the token recovers during the wait. The pause stops a mint in the same transaction from
    /// entering without the component and sharing its recovery; governance resumes minting.
    function writeOffComponent(address token) external nonReentrant {
        _requireNotLiquidating();
        uint256 index = _indexOf(token);
        uint256 readyAt = writeOffReadyAt[token];
        if (readyAt == 0) revert NoPendingWriteOff(token);
        _requireReady(readyAt);
        if (excluded[token]) revert ComponentExcluded(token);

        delete writeOffReadyAt[token];
        writtenOff[token] = true;
        _initialAmounts[index] = 0;
        emit ComponentWrittenOff(token);
        _setActive(token, false);
        _setMintPaused(true);
    }

    // ---------------------------------------------------------------------------------------------
    // Fees
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets the mint and redemption fees, in basis points, each at most `MAX_FEE` (5%).
    /// Lowering both takes effect at once and discards any pending raise; raising either waits
    /// `FEE_INCREASE_DELAY`, replacing any pending proposal, so holders see it coming.
    function proposeFees(uint256 mintFee_, uint256 redeemFee_) external onlyGovernance {
        if (mintFee_ > MAX_FEE) revert FeeAboveMax(mintFee_);
        if (redeemFee_ > MAX_FEE) revert FeeAboveMax(redeemFee_);
        if (mintFee_ <= mintFee && redeemFee_ <= redeemFee) {
            if (pendingFeesReadyAt != 0) {
                _clearPendingFees();
                emit FeesProposalCancelled();
            }
            _setFees(mintFee_, redeemFee_);
            return;
        }
        uint256 readyAt = block.timestamp + FEE_INCREASE_DELAY;
        pendingMintFee = mintFee_;
        pendingRedeemFee = redeemFee_;
        pendingFeesReadyAt = readyAt;
        emit FeesProposed(mintFee_, redeemFee_, readyAt);
    }

    /// @notice Discards the pending fee raise.
    function cancelFeesProposal() external onlyGovernance {
        if (pendingFeesReadyAt == 0) revert NoPendingFees();
        _clearPendingFees();
        emit FeesProposalCancelled();
    }

    /// @notice Applies a proposed raise once its wait has passed. Positive fees need a recipient.
    /// @dev Anyone may execute it, as with `addComponent`. Guarded so that it cannot run in the
    /// middle of a mint or a redemption.
    function applyFees() external nonReentrant {
        uint256 readyAt = pendingFeesReadyAt;
        if (readyAt == 0) revert NoPendingFees();
        _requireReady(readyAt);
        if (feeRecipient == address(0)) revert NoFeeRecipient();
        uint256 nextMintFee = pendingMintFee;
        uint256 nextRedeemFee = pendingRedeemFee;
        _clearPendingFees();
        _setFees(nextMintFee, nextRedeemFee);
    }

    /// @notice Changes who receives the fees, at once: it never changes what a holder pays. Once
    /// set, it can never return to zero, so a positive fee always has somewhere to go.
    function setFeeRecipient(address next) external onlyGovernance {
        if (next == address(0)) revert ZeroAddress();
        if (next == address(this)) revert InvalidRecipient();
        address previous = feeRecipient;
        feeRecipient = next;
        emit FeeRecipientChanged(previous, next);
    }

    // ---------------------------------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------------------------------

    /// @notice Pauses or resumes minting, at once. Wallets that minted can still redeem; a holder
    /// that never minted cannot qualify until minting resumes (a known limitation). Useful during
    /// an incident; a write-off and a last skipping exit pause minting by themselves. Resuming
    /// before a written-off component is reactivated lets new entrants share its recovery. Asking
    /// for the current state does nothing.
    function setMintPaused(bool paused) external onlyGovernance {
        _setMintPaused(paused);
    }

    /// @notice Rescues foreign tokens, or ordinary components only while normal supply is zero.
    /// Exclusion does not make a component rescuable; written-off tokens are permanently protected.
    /// Reverts if the transfer lowers the balance of any other component.
    function rescue(address token, address to, uint256 amount)
        external
        onlyGovernance
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();
        if (writtenOff[token]) revert TokenWrittenOff(token);
        if (_componentSlot[token] != 0 && (liquidationActive || totalSupply() != 0)) {
            revert BackingToken(token);
        }
        uint256 count = _components.length;
        uint256[] memory balances = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            balances[i] = _readableBalance(_components[i]);
        }
        IERC20(token).safeTransfer(to, amount);
        // A second address over a component's ledger could move its balance; none may drop.
        for (uint256 i; i < count; ++i) {
            IERC20 component = _components[i];
            if (address(component) == token || balances[i] == 0) continue;
            if (_readableBalance(component) < balances[i]) {
                revert ComponentBalanceReduced(address(component));
            }
        }
        emit Rescued(token, to, amount);
    }

    /// @notice First step of a governance change; replaces any pending one and restarts the wait.
    function proposeGovernance(address next) external onlyGovernance {
        if (next == address(0)) revert ZeroAddress();
        uint256 readyAt = _propose(governanceProposal, next, GOVERNANCE_TRANSFER_DELAY);
        emit GovernanceProposed(next, readyAt);
    }

    /// @notice Discards the pending governance.
    function cancelGovernanceProposal() external onlyGovernance {
        emit GovernanceProposalCancelled(_cancel(governanceProposal));
    }

    /// @notice Second step: the proposed address takes over once the wait has passed, proving it
    /// can call the vault.
    function acceptGovernance() external {
        _accept(governanceProposal);
        address previous = governance;
        governance = msg.sender;
        emit GovernanceTransferred(previous, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Number of components, active or not.
    function componentCount() external view returns (uint256) {
        return _components.length;
    }

    /// @notice Every component, active or not, by index.
    function components() external view returns (IERC20[] memory) {
        return _components;
    }

    /// @notice What the first mint contributes for 1 GRET, by index.
    function initialAmounts() external view returns (uint256[] memory) {
        return _initialAmounts;
    }

    /// @notice Live active backing normally; effective nominal claim bases during liquidation.
    /// Liquidation bases include consumed rights and are not the remaining token balances.
    function reserves() external view nonReentrantView returns (uint256[] memory amounts) {
        amounts = new uint256[](_components.length);
        for (uint256 i; i < amounts.length; ++i) {
            if (!liquidationActive && excluded[address(_components[i])]) continue;
            uint256 balance = _components[i].balanceOf(address(this));
            amounts[i] = liquidationActive ? _effectiveBasis(i, balance) : balance;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    /// @dev GRET sent to the vault would be lost to its sender, so such transfers revert. The vault
    /// never holds GRET: mint goes to the caller and redemption burns from the caller.
    function _update(address from, address to, uint256 value) internal override {
        if (to == address(this)) revert InvalidRecipient();
        super._update(from, to, value);
    }

    /// @dev What a mint of `shares` asks for, and the balances it is measured against. The first
    /// mint asks for the initial basket; later ones for a share of every balance, rounded up.
    /// Excluded components, and on the first mint those without an initial amount, are not called.
    function _mintAmounts(uint256 shares, uint256 supply)
        private
        view
        returns (uint256[] memory amounts, uint256[] memory balances)
    {
        if (supply == 0 && shares != INITIAL_SHARES) revert InvalidInitialMint(shares);
        uint256 count = _components.length;
        amounts = new uint256[](count);
        balances = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            if (excluded[address(_components[i])] || (supply == 0 && _initialAmounts[i] == 0)) {
                continue;
            }
            balances[i] = _components[i].balanceOf(address(this));
            amounts[i] = supply == 0
                ? _initialAmounts[i]
                : Math.mulDiv(shares, balances[i], supply, Math.Rounding.Ceil);
        }
    }

    /// @dev Pulls a positive `amount` of one component for a mint or a swap and returns what
    /// actually arrived, measured against `balanceBefore`.
    function _pull(uint256 index, uint256 amount, uint256 balanceBefore)
        private
        returns (uint256 received)
    {
        IERC20 token = _components[index];
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = token.balanceOf(address(this));
        received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received == 0 || received > amount || received + MAX_RECEIPT_SHORTFALL < amount) {
            revert UnexpectedBalance(index, amount, received);
        }
    }

    function _redeem(
        uint256 shares,
        address to,
        uint256[] calldata minAmountsOut,
        bool[] memory skip
    ) private returns (uint256[] memory amounts) {
        _requireNotLiquidating();
        if (!hasMinted[msg.sender]) revert RedemptionNotEnabled(msg.sender);
        if (shares == 0) revert ZeroShares();
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidRecipient();

        uint256 fee;
        (amounts, fee) = _redemptionAmounts(shares, skip);
        uint256 burned = shares - fee;
        uint256 remaining = totalSupply() - burned;
        if (remaining != 0 && remaining < MIN_SUPPLY) revert SupplyBelowMinimum(remaining);
        uint256 count = amounts.length;
        for (uint256 i; i < count; ++i) {
            if (amounts[i] < minAmountsOut[i]) {
                revert AmountOutBelowMin(i, amounts[i], minAmountsOut[i]);
            }
        }

        if (fee != 0) {
            _transfer(msg.sender, feeRecipient, fee);
            emit FeeCharged(msg.sender, feeRecipient, fee);
        }
        _burn(msg.sender, burned);
        for (uint256 i; i < count; ++i) {
            if (amounts[i] != 0) _components[i].safeTransfer(to, amounts[i]);
        }
        emit Redeemed(msg.sender, to, burned, amounts);
    }

    /// @dev Redeeming the whole supply pays no fee: fee GRET would otherwise stay in the supply and
    /// keep the holder of every GRET from leaving in full.
    function _redemptionAmounts(uint256 shares, bool[] memory skip)
        private
        view
        returns (uint256[] memory amounts, uint256 fee)
    {
        uint256 supply = totalSupply();
        if (shares > supply) revert SharesExceedSupply(shares, supply);
        amounts = new uint256[](_components.length);
        fee = shares == supply ? 0 : _fee(shares, redeemFee);
        uint256 burned = shares - fee;
        if (burned == 0) return (amounts, fee);
        for (uint256 i; i < amounts.length; ++i) {
            if (skip[i] || excluded[address(_components[i])]) continue;
            amounts[i] = Math.mulDiv(burned, _components[i].balanceOf(address(this)), supply);
        }
    }

    function _skipMask(address[] calldata skipped) private view returns (bool[] memory skip) {
        skip = new bool[](_components.length);
        for (uint256 i; i < skipped.length; ++i) {
            skip[_indexOf(skipped[i])] = true;
        }
    }

    /// @dev Rounded up, so that no operation with a positive fee rate pays nothing.
    function _fee(uint256 shares, uint256 rate) private pure returns (uint256) {
        return Math.mulDiv(shares, rate, FEE_DENOMINATOR, Math.Rounding.Ceil);
    }

    /// @dev No cached-balance fallback: an unreadable token cannot consume claims or overpay.
    /// Establish the basis lazily; later income increases all holders' rights automatically.
    function _claimQuote(address account, uint256 index)
        private
        view
        returns (uint256 basis, uint256 rights, uint256 amount)
    {
        uint256 shares = convertedShares[account];
        if (shares == 0) return (0, 0, 0);
        uint256 balance = _components[index].balanceOf(address(this));
        basis = _effectiveBasis(index, balance);
        rights = Math.mulDiv(shares, basis, liquidationSupply) - consumedRights[account][index];
        if (rights == 0) return (basis, 0, 0);
        uint256 owed = basis - _liquidationTotals[index].consumedRights;
        amount = balance >= owed ? rights : Math.mulDiv(rights, balance, owed);
    }

    function _effectiveBasis(uint256 index, uint256 balance) private view returns (uint256) {
        LiquidationTotals storage totals = _liquidationTotals[index];
        return Math.max(totals.basis, balance + totals.consumedRights);
    }

    function _pushComponent(address token, uint256 initialAmount) private {
        _components.push(IERC20(token));
        _componentSlot[token] = _components.length;
        _initialAmounts.push(initialAmount);
    }

    function _requireNewComponent(address token) private view {
        _requireContract(token);
        if (_componentSlot[token] != 0) revert DuplicateComponent(token);
    }

    /// @dev Components and guards must be contracts other than the vault. An EIP-7702 account,
    /// whose code is a delegation designator, is refused: its key holder can replace that code
    /// without notice.
    function _requireContract(address account) private view {
        uint256 size = account.code.length;
        if (size == 0) revert NotAContract(account);
        if (account == address(this) || (size == 23 && bytes3(account.code) == 0xef0100)) {
            revert InvalidContract(account);
        }
    }

    /// @dev Only high-precision tokens may leave up to ten base units. Low-decimal assets must be
    /// exactly empty, so ten whole indivisible assets cannot be discarded as rounding dust.
    function _requireEmpty(address token) private view {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return;
        if (balance > MAX_REMOVAL_DUST || IERC20Metadata(token).decimals() < 18) {
            revert ComponentNotEmpty(token, balance);
        }
    }

    /// @dev Emits only on a change, like `_setMintPaused`.
    function _setActive(address token, bool active) private {
        if (excluded[token] == !active) return;
        excluded[token] = !active;
        emit ComponentActivationChanged(token, active);
    }

    function _indexOf(address token) private view returns (uint256) {
        uint256 slot = _componentSlot[token];
        if (slot == 0) revert NotAComponent(token);
        return slot - 1;
    }

    function _setFees(uint256 mintFee_, uint256 redeemFee_) private {
        mintFee = mintFee_;
        redeemFee = redeemFee_;
        emit FeesChanged(mintFee_, redeemFee_);
    }

    function _clearPendingFees() private {
        delete pendingMintFee;
        delete pendingRedeemFee;
        delete pendingFeesReadyAt;
    }

    /// @dev Emits only on a change, so an existing pause is kept without a second event.
    function _setMintPaused(bool paused) private {
        if (mintPaused == paused) return;
        mintPaused = paused;
        emit MintPauseChanged(paused);
    }

    /// @dev The vault's balance of `token`, or zero if the read reverts or answers with less than a
    /// word, so an unreadable component does not block rescues of other tokens.
    function _readableBalance(IERC20 token) private view returns (uint256) {
        (bool ok, bytes memory data) =
            address(token).staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        return ok && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
    }

    /// @dev Names `next` to take over once `delay` has passed, replacing any earlier proposal.
    function _propose(Proposal storage proposal, address next, uint256 delay)
        private
        returns (uint256 readyAt)
    {
        readyAt = block.timestamp + delay;
        proposal.next = next;
        proposal.readyAt = readyAt;
    }

    /// @dev Discards a pending proposal and returns whom it named.
    function _cancel(Proposal storage proposal) private returns (address next) {
        next = proposal.next;
        if (next == address(0)) revert NoPendingProposal();
        delete proposal.next;
        delete proposal.readyAt;
    }

    /// @dev Clears a proposal whose notice has passed and returns whom it named.
    function _take(Proposal storage proposal) private returns (address next) {
        uint256 readyAt = proposal.readyAt;
        next = _cancel(proposal);
        _requireReady(readyAt);
    }

    /// @dev Like `_take`, for a successor that accepts in person, proving it can call the vault.
    function _accept(Proposal storage proposal) private {
        if (msg.sender != proposal.next) revert NotProposed(msg.sender);
        _take(proposal);
    }

    /// @dev A proposal can be executed from `readyAt` until `EXECUTION_WINDOW` later.
    function _requireReady(uint256 readyAt) private view {
        if (block.timestamp < readyAt) revert NotReady(readyAt);
        uint256 expiredAt = readyAt + EXECUTION_WINDOW;
        if (block.timestamp > expiredAt) revert ProposalExpired(expiredAt);
    }

    function _requireNotLiquidating() private view {
        if (liquidationActive) revert LiquidationIsActive();
    }

    function _requireLiquidating() private view {
        if (!liquidationActive) revert LiquidationNotActive();
    }

    function _requireIndex(uint256 index) private view {
        if (index >= _components.length) revert InvalidIndex(index);
    }

    /// @dev Positional amounts must belong to the basket the caller saw: same version, same length.
    function _requireBasket(uint256 version, uint256 length) private view {
        if (version != basketVersion) revert BasketChanged(version, basketVersion);
        if (length != _components.length) revert LengthMismatch(_components.length, length);
    }
}
