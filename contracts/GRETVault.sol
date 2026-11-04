// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceGuard} from "./IPriceGuard.sol";

/// @title Global Reserve Token vault
/// @notice Basket of ERC-20 components whose shares are GRET. Mint and normal redemption are in
/// kind and proportional to the active components' actual balances, so no amount per GRET is set anywhere: it
/// follows what the vault holds. Governance, an external contract whose voting lives outside the
/// vault, can start an irreversible liquidation in which any holder exits component by component,
/// decides what to do with tokens that are not backing GRET, and changes the basket: it adds and
/// removes components and appoints a rebalancer that exchanges one component for another.
/// Nobody can take reserves without delivering another component in exchange, and every exchange
/// must pass a price guard, an external contract that holds the prices and the loss limits; every
/// new rebalancer, price guard and component waits seven days. A component that stops working can
/// be written off after the same wait.
/// Governance can charge mint and redemption fees in GRET, at most 5% each; raising them waits too.
/// It can pause minting at once, but never redemption.
/// @dev Not independently audited. The specification, including the known limitations, is in
/// docs/SPECIFICATION.md.
contract GRETVault is ERC20, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice GRET issued by the first mint, and again whenever the supply returns to zero.
    uint256 public constant INITIAL_SHARES = 1e18;
    /// @notice Normal redemption cannot leave the supply above zero but below this amount, so
    /// rounding dust can never dominate the basket.
    uint256 public constant MIN_SUPPLY = INITIAL_SHARES;
    /// @notice Maximum base-unit residue allowed when deactivating/removing an empty component.
    uint256 public constant MAX_REMOVAL_DUST = 10;
    /// @notice Highest number of components. Mint and redemption visit every component in one
    /// transaction, so the cap keeps them within Ethereum's per-transaction gas limit.
    uint256 public constant MAX_COMPONENTS = 128;
    /// @notice Base units a component may deliver below the requested amount on mint. Covers
    /// tokens that convert amounts to internal shares (xStocks); transfer fees still revert.
    uint256 public constant MAX_RECEIPT_SHORTFALL = 10;
    /// @notice Minimum wait, enforced by the vault, between proposing and accepting a new governance.
    uint256 public constant GOVERNANCE_TRANSFER_DELAY = 7 days;
    /// @notice Minimum wait, enforced by the vault, before a new rebalancer, price guard or component
    /// takes effect, so holders see every change to who may exchange the reserves, at what price
    /// and for what.
    uint256 public constant BASKET_CHANGE_DELAY = 7 days;
    /// @notice Time after its wait ends during which a proposal can still be executed or accepted;
    /// after it, the proposal expires and must be made again, so an old notice cannot be used
    /// at any moment later.
    uint256 public constant EXECUTION_WINDOW = 7 days;
    /// @notice Highest mint or redemption fee, in basis points of the GRET issued or redeemed: 5%.
    uint256 public constant MAX_FEE = 500;
    /// @notice Minimum wait, enforced by the vault, before a raise of either fee takes effect.
    uint256 public constant FEE_INCREASE_DELAY = 7 days;
    uint256 private constant FEE_DENOMINATOR = 10_000;

    /// @notice Starts liquidation, manages component activation and changes the basket; appoints
    /// the rebalancer and its own successor.
    address public governance;
    address public pendingGovernance;
    /// @notice Earliest timestamp at which `pendingGovernance` may accept.
    uint256 public pendingGovernanceReadyAt;

    /// @notice Exchanges one component for another at the price it chooses, within the limits of
    /// the price guard. Zero when nobody can, as at deployment.
    address public rebalancer;
    address public pendingRebalancer;
    /// @notice Earliest timestamp at which `pendingRebalancer` may accept.
    uint256 public pendingRebalancerReadyAt;
    /// @notice Prices every swap and refuses the ones that lose too much. None at deployment, and
    /// without one there are no swaps.
    IPriceGuard public priceGuard;
    /// @notice The guard that `applyPriceGuard` last replaced, from which the next one can continue
    /// the week's loss count; zero until the first replacement.
    address public previousPriceGuard;
    address public pendingPriceGuard;
    /// @notice Earliest timestamp at which `pendingPriceGuard` may be applied.
    uint256 public pendingPriceGuardReadyAt;
    /// @notice Earliest timestamp at which an announced token may join the basket; zero if none.
    mapping(address token => uint256) public componentReadyAt;
    /// @notice Earliest timestamp at which a proposed write-off may take effect; zero if none.
    mapping(address token => uint256) public writeOffReadyAt;
    /// @notice Permanent write-off history. These tokens can never be rescued or removed,
    /// even after governance reactivates them for normal operation.
    mapping(address token => bool) public writtenOff;
    /// @notice Excluded components are never called by normal mint/redemption or the price guard.
    mapping(address token => bool) public excluded;

    /// @notice Share of the GRET issued by a mint that goes to `feeRecipient`, in basis points.
    uint256 public mintFee;
    /// @notice Share of the GRET a redemption takes that goes to `feeRecipient` instead of being
    /// redeemed, in basis points.
    uint256 public redeemFee;
    /// @notice Receives the fees in GRET. Chosen by governance; required before any fee is positive.
    address public feeRecipient;
    uint256 public pendingMintFee;
    uint256 public pendingRedeemFee;
    /// @notice Earliest timestamp at which the pending fees may be applied; zero if none.
    uint256 public pendingFeesReadyAt;

    IERC20[] private _components;
    /// @dev Component index plus one; zero for tokens outside the basket.
    mapping(address token => uint256) private _componentSlot;
    uint256[] private _initialAmounts;
    /// @dev Established nominal liquidation basis. Zero throughout normal operation; initialized
    /// separately for each component on its first successful claim and raised by later income.
    uint256[] private _liquidationBasis;
    /// @dev Liquidation rights consumed per component, before any loss haircut.
    uint256[] private _rightsClaimed;
    /// @dev Component amounts actually paid out by claims.
    uint256[] private _totalClaimed;

    /// @notice Wallets that completed a mint and may use normal redemption. Not transferable.
    mapping(address account => bool) public hasMinted;

    /// @notice While true, `mint` reverts. Executing a write-off, or a skipping redemption that
    /// leaves zero supply, sets it. Redemption is never paused.
    bool public mintPaused;
    /// @notice Grows by one whenever a component is added or removed. Calls that pass amounts by
    /// position (`mint`, both redemptions, `setInitialAmounts`) state the version they were prepared
    /// for, so a basket that changed in between can never apply their limits to another token.
    uint256 public basketVersion;

    bool public liquidationActive;
    /// @notice GRET supply when liquidation started; denominator of every claim.
    uint256 public liquidationSupply;
    /// @notice GRET burned by each account in exchange for liquidation rights.
    mapping(address account => uint256) public claimShares;
    /// @notice Liquidation rights each account already consumed, per component. Equals the amount
    /// paid unless a loss reduced the payout.
    mapping(address account => mapping(uint256 index => uint256)) public claimed;

    event Minted(address indexed account, uint256 shares, uint256[] amounts);
    event Redeemed(address indexed account, uint256 shares, uint256[] amounts);
    event ComponentActivationChanged(address indexed token, bool active);
    event LiquidationActivated(uint256 supply);
    event MintPauseChanged(bool paused);
    event ConvertedToClaims(address indexed account, uint256 shares);
    event Claimed(address indexed account, uint256 indexed index, address to, uint256 amount, uint256 rights);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event Swapped(address indexed sold, uint256 soldAmount, address indexed bought, uint256 boughtAmount);
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
    error NotAContract(address token);
    error InvalidContract(address account);
    error DuplicateComponent(address token);
    error ZeroInitialAmount(uint256 index);
    error ZeroAddress();
    error InvalidIndex(uint256 index);
    error ZeroShares();
    error InvalidInitialMint(uint256 shares);
    error ZeroComponentAmount(uint256 index);
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
    error NotPendingGovernance(address caller);
    error NoPendingGovernance();
    error GovernanceTransferNotReady(uint256 readyAt);
    error NotRebalancer(address caller);
    error NotPendingRebalancer(address caller);
    error NoPendingRebalancer();
    error RebalancerChangeNotReady(uint256 readyAt);
    error NoPriceGuard();
    error NoPendingPriceGuard();
    error PriceGuardChangeNotReady(uint256 readyAt);
    error NotAComponent(address token);
    error SameComponent(address token);
    error SwapExceedsReserve(address token, uint256 amount, uint256 reserve);
    error NoPendingComponent(address token);
    error ComponentNotReady(address token, uint256 readyAt);
    error ComponentHasReserve(address token, uint256 reserve);
    error EmptyBasket();
    error NoPendingWriteOff(address token);
    error WriteOffNotReady(address token, uint256 readyAt);
    error ComponentExcluded(address token);
    error BackingToken(address token);
    error ComponentBalanceReduced(address token);
    error TokenWrittenOff(address token);
    error FeeAboveMax(uint256 fee);
    error NoPendingFees();
    error FeesNotReady(uint256 readyAt);
    error NoFeeRecipient();
    error ProposalExpired(uint256 expiredAt);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance(msg.sender);
        _;
    }

    constructor(IERC20[] memory components_, uint256[] memory initialAmounts_, address governance_)
        ERC20("Global Reserve Token", "GRET")
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
    // Normal operation
    // ---------------------------------------------------------------------------------------------

    /// @notice Contributes every component in proportion to the reserves and mints up to `shares`
    /// GRET: the mint fee goes to `feeRecipient` and the rest to the caller, reverting if the caller
    /// would get fewer than `minShares`. The first mint (supply zero) contributes the initial basket
    /// for exactly 1 GRET in total. Excluded or zero-balance components are not asked for.
    /// `version` is the `basketVersion` that `maxAmountsIn` was prepared for.
    /// @dev Contributions round up. GRET is issued for what actually arrived, rounded down, so a
    /// component that delivers a few units less costs the minter, never the existing holders;
    /// `minShares` bounds that cost. Snapshot every active balance before pulling any input.
    function mint(uint256 shares, uint256[] calldata maxAmountsIn, uint256 minShares, uint256 version)
        external
        nonReentrant
        returns (uint256 minted, uint256[] memory received)
    {
        _requireNotLiquidating();
        if (mintPaused) revert MintIsPaused();
        if (shares == 0) revert ZeroShares();
        _requireBasket(version, maxAmountsIn.length);

        uint256 count = _components.length;
        uint256 supply = totalSupply();
        if (supply == 0 && shares != INITIAL_SHARES) revert InvalidInitialMint(shares);
        uint256[] memory balancesBefore = new uint256[](count);
        uint256[] memory amounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            if (excluded[address(_components[i])]) continue;
            if (supply == 0 && _initialAmounts[i] == 0) continue;
            balancesBefore[i] = _components[i].balanceOf(address(this));
            amounts[i] = supply == 0 ? _initialAmounts[i]
                : Math.mulDiv(shares, balancesBefore[i], supply, Math.Rounding.Ceil);
        }

        received = new uint256[](count);
        minted = supply == 0 ? INITIAL_SHARES : shares;
        bool contributed;
        for (uint256 i; i < count; ++i) {
            if (amounts[i] == 0) continue;
            received[i] = _pull(i, amounts[i], maxAmountsIn[i], balancesBefore[i]);
            contributed = true;
            if (supply != 0) minted = Math.min(minted, Math.mulDiv(received[i], supply, balancesBefore[i]));
        }
        // Without this, GRET backed by nothing could be minted after every reserve was lost.
        if (!contributed) revert EmptyBasket();
        // The minter paid for every share, so the fee dilutes nobody.
        uint256 fee = _fee(minted, mintFee);
        minted -= fee;
        // Also refuses a mint whose fee, rounded up, takes every share.
        if (minted == 0) revert ZeroShares();
        if (minted < minShares) revert SharesBelowMin(minted, minShares);

        _mint(msg.sender, minted);
        if (fee != 0) _chargeFee(fee, true);
        hasMinted[msg.sender] = true;
        emit Minted(msg.sender, minted, received);
    }

    /// @notice Takes `shares` GRET from the caller: the redemption fee goes to `feeRecipient` and the
    /// rest is burned for the proportional amount of every component; redeeming the whole supply
    /// pays no fee. All or nothing: if any
    /// transfer fails the whole redemption reverts. The supply left must be zero or at least
    /// `MIN_SUPPLY`. `version` is the `basketVersion` that `minAmountsOut` was prepared for.
    /// @dev Only for wallets that completed a mint. Amounts round down, in favor of the vault.
    /// Live balances include all income and losses before calculating proportional outputs.
    function redeem(uint256 shares, uint256[] calldata minAmountsOut, uint256 version)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        _requireBasket(version, minAmountsOut.length);
        return _redeem(shares, minAmountsOut, new bool[](_components.length));
    }

    /// @notice Like `redeem`, but leaves out the `skipped` components, for when one of them cannot be
    /// sent: an issuer froze the vault, or a token was made to fail. The caller gives up its share
    /// of them, which stays with the other holders. If nobody remains, minting pauses so that
    /// governance can review what was left before a bootstrap takes it. Their `minAmountsOut` must
    /// be zero.
    /// @dev Skipped components are not called at all, so no token can block this exit. It keeps the
    /// 7-day notice of a new rebalancer meaningful: whoever minted can always leave with every
    /// component that still works.
    function redeemSkipping(
        uint256 shares,
        uint256[] calldata minAmountsOut,
        address[] calldata skipped,
        uint256 version
    ) external nonReentrant returns (uint256[] memory amounts) {
        _requireBasket(version, minAmountsOut.length);
        bool[] memory skip = new bool[](_components.length);
        for (uint256 i; i < skipped.length; ++i) {
            skip[_indexOf(skipped[i])] = true;
        }
        amounts = _redeem(shares, minAmountsOut, skip);
        if (skipped.length != 0 && totalSupply() == 0) _pauseMint();
    }

    /// @notice Activates a newly added or previously excluded component. Its whole balance then
    /// backs current holders. This does not erase a historical write-off's rescue prohibition.
    function activateComponent(address token) external onlyGovernance nonReentrant {
        _requireNotLiquidating();
        _indexOf(token);
        if (!excluded[token]) return;
        excluded[token] = false;
        emit ComponentActivationChanged(token, true);
    }

    /// @notice Keeps an empty component inactive even if unsolicited dust later arrives. Larger
    /// balances can only be excluded by the delayed write-off. Exclusion never permits rescue.
    function deactivateEmptyComponent(address token) external onlyGovernance nonReentrant {
        _requireNotLiquidating();
        _indexOf(token);
        uint256 balance = IERC20(token).balanceOf(address(this));
        _requireEmpty(token, balance);
        excluded[token] = true;
        emit ComponentActivationChanged(token, false);
    }

    /// @notice Live mint amounts. Excluded components are not called. Initial mint still uses
    /// the configured basket; preexisting active balances belong to the new first share.
    function previewMint(uint256 shares) public view nonReentrantView returns (uint256[] memory amounts) {
        _requireNotLiquidating();
        uint256 supply = totalSupply();
        if (supply == 0 && shares != INITIAL_SHARES) revert InvalidInitialMint(shares);
        amounts = new uint256[](_components.length);
        for (uint256 i; i < amounts.length; ++i) {
            if (excluded[address(_components[i])]) continue;
            amounts[i] = supply == 0 ? _initialAmounts[i]
                : Math.mulDiv(shares, _components[i].balanceOf(address(this)), supply, Math.Rounding.Ceil);
        }
    }

    /// @notice Live redemption amounts, after fees. Use previewRedeemSkipping for a broken token.
    function previewRedeem(uint256 shares) public view nonReentrantView returns (uint256[] memory amounts) {
        _requireNotLiquidating();
        return _redemptionAmounts(shares, new bool[](_components.length));
    }

    /// @notice Quotes an exit without calling any skipped or excluded component.
    function previewRedeemSkipping(uint256 shares, address[] calldata skipped)
        external
        view
        nonReentrantView
        returns (uint256[] memory amounts)
    {
        _requireNotLiquidating();
        bool[] memory skip = new bool[](_components.length);
        for (uint256 i; i < skipped.length; ++i) {
            skip[_indexOf(skipped[i])] = true;
        }
        return _redemptionAmounts(shares, skip);
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

    /// @notice Burns GRET in exchange for non-transferable rights over every component.
    /// Any holder may convert, including wallets that never minted.
    function convertToClaims(uint256 shares) external nonReentrant {
        _requireLiquidating();
        if (shares == 0) revert ZeroShares();

        _burn(msg.sender, shares);
        claimShares[msg.sender] += shares;
        emit ConvertedToClaims(msg.sender, shares);
    }

    /// @notice Withdraws the caller's pending right over one component to `to`, reverting if less
    /// than `minAmount` would be paid.
    /// @dev Calls only that component. If its transfer fails the call reverts and the right
    /// stays pending; rights over other components are unaffected. If the vault holds less of the
    /// component than all pending rights, it pays the same fraction to everyone still pending and
    /// consumes the whole right; `minAmount` lets the caller refuse such a cut and keep waiting.
    function claim(uint256 index, address to, uint256 minAmount) external nonReentrant returns (uint256 amount) {
        _requireLiquidating();
        _requireIndex(index);
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidRecipient();

        (uint256 basis, uint256 rights, uint256 payout) = _claimQuote(msg.sender, index);
        amount = payout;
        if (amount == 0) revert NothingToClaim(msg.sender, index);
        if (amount < minAmount) revert AmountOutBelowMin(index, amount, minAmount);

        _liquidationBasis[index] = basis;
        claimed[msg.sender][index] += rights;
        _rightsClaimed[index] += rights;
        _totalClaimed[index] += amount;
        _components[index].safeTransfer(to, amount);
        emit Claimed(msg.sender, index, to, amount, rights);
    }

    /// @notice Current payout including automatically allocated income. Only this token is read.
    function claimable(address account, uint256 index) public view nonReentrantView returns (uint256 amount) {
        _requireIndex(index);
        (,, amount) = _claimQuote(account, index);
    }

    /// @notice Nominal pending rights, including income since the last claim of this component.
    function pendingRights(address account, uint256 index) public view nonReentrantView returns (uint256 rights) {
        _requireIndex(index);
        (, rights,) = _claimQuote(account, index);
    }

    /// @notice The basis established by successful claims, without querying any external token.
    function liquidationBasis() external view returns (uint256[] memory) {
        return _liquidationBasis;
    }

    // ---------------------------------------------------------------------------------------------
    // Rebalancing
    // ---------------------------------------------------------------------------------------------

    /// @notice Exchanges `sellAmount` of one component for `buyAmount` of another: the rebalancer
    /// delivers first and receives after. The price guard must accept the exchange; without a
    /// guard there are no swaps. Mint and redemption follow the new reserves, so this is how the
    /// amounts per GRET change.
    /// @dev Both components must be active. The vault measures receipts with mint
    /// tolerance and the guard prices them. Selling a whole balance
    /// stops mint from asking for that component. Removal still requires the empty/dust rule;
    /// a donation arriving before removal can prevent it.
    function swap(address sell, uint256 sellAmount, address buy, uint256 buyAmount)
        external
        nonReentrant
        returns (uint256 received)
    {
        if (msg.sender != rebalancer) revert NotRebalancer(msg.sender);
        _requireNotLiquidating();
        uint256 sellIndex = _indexOf(sell);
        uint256 buyIndex = _indexOf(buy);
        if (sellIndex == buyIndex) revert SameComponent(sell);
        if (sellAmount == 0) revert ZeroAmount();
        IPriceGuard guard = priceGuard;
        if (address(guard) == address(0)) revert NoPriceGuard();

        if (totalSupply() == 0) revert NoSupply();
        if (excluded[sell]) revert ComponentExcluded(sell);
        if (excluded[buy]) revert ComponentExcluded(buy);
        uint256 reserve = IERC20(sell).balanceOf(address(this));
        uint256 buyBalance = IERC20(buy).balanceOf(address(this));
        if (sellAmount > reserve) revert SwapExceedsReserve(sell, sellAmount, reserve);

        received = _pull(buyIndex, buyAmount, buyAmount, buyBalance);
        // The guard excludes this measured receipt when reconstructing pre-swap backing.
        guard.checkSwap(sell, sellAmount, buy, received);
        IERC20(sell).safeTransfer(msg.sender, sellAmount);
        emit Swapped(sell, sellAmount, buy, received);
    }

    // ---------------------------------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------------------------------

    /// @notice Rescues foreign tokens, or ordinary components only while normal supply is zero.
    /// Exclusion does not make a component rescuable; written-off tokens are permanently protected.
    /// Reverts if the transfer lowers the balance of any other component.
    function rescue(address token, address to, uint256 amount) external onlyGovernance nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();
        if (writtenOff[token]) revert TokenWrittenOff(token);
        uint256 slot = _componentSlot[token];
        if (slot != 0 && (liquidationActive || totalSupply() != 0)) revert BackingToken(token);
        uint256 count = _components.length;
        uint256[] memory balances = new uint256[](count);
        for (uint256 i; i < count; ++i) balances[i] = _readableBalance(_components[i]);
        IERC20(token).safeTransfer(to, amount);
        // A second address over a component's ledger could move its balance; none may drop.
        for (uint256 i; i < count; ++i) {
            if (i + 1 == slot || balances[i] == 0) continue;
            if (_readableBalance(_components[i]) < balances[i]) revert ComponentBalanceReduced(address(_components[i]));
        }
        emit Rescued(token, to, amount);
    }

    /// @notice Proposes the address that may swap components. It can take over only after
    /// `BASKET_CHANGE_DELAY`. Replaces any pending proposal and restarts the wait.
    function proposeRebalancer(address next) external onlyGovernance {
        if (next == address(0)) revert ZeroAddress();
        uint256 readyAt = block.timestamp + BASKET_CHANGE_DELAY;
        pendingRebalancer = next;
        pendingRebalancerReadyAt = readyAt;
        emit RebalancerProposed(next, readyAt);
    }

    function cancelRebalancerProposal() external onlyGovernance {
        address pending = pendingRebalancer;
        if (pending == address(0)) revert NoPendingRebalancer();
        delete pendingRebalancer;
        delete pendingRebalancerReadyAt;
        emit RebalancerProposalCancelled(pending);
    }

    /// @notice The proposed rebalancer takes over once the wait has passed, proving it can call
    /// the vault.
    function acceptRebalancer() external {
        if (msg.sender != pendingRebalancer) revert NotPendingRebalancer(msg.sender);
        uint256 readyAt = pendingRebalancerReadyAt;
        if (block.timestamp < readyAt) revert RebalancerChangeNotReady(readyAt);
        _requireNotExpired(readyAt);

        address previous = rebalancer;
        rebalancer = msg.sender;
        delete pendingRebalancer;
        delete pendingRebalancerReadyAt;
        emit RebalancerChanged(previous, msg.sender);
    }

    /// @notice Leaves the vault without a rebalancer at once, and discards a pending one: taking the
    /// power away needs no wait.
    function revokeRebalancer() external onlyGovernance {
        address pending = pendingRebalancer;
        if (pending != address(0)) {
            delete pendingRebalancer;
            delete pendingRebalancerReadyAt;
            emit RebalancerProposalCancelled(pending);
        }
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
        uint256 readyAt = block.timestamp + BASKET_CHANGE_DELAY;
        pendingPriceGuard = next;
        pendingPriceGuardReadyAt = readyAt;
        emit PriceGuardProposed(next, readyAt);
    }

    function cancelPriceGuardProposal() external onlyGovernance {
        address pending = pendingPriceGuard;
        if (pending == address(0)) revert NoPendingPriceGuard();
        delete pendingPriceGuard;
        delete pendingPriceGuardReadyAt;
        emit PriceGuardProposalCancelled(pending);
    }

    /// @notice Governance decided when it proposed the guard: once the wait is over, anyone can
    /// apply it.
    function applyPriceGuard() external {
        address next = pendingPriceGuard;
        if (next == address(0)) revert NoPendingPriceGuard();
        uint256 readyAt = pendingPriceGuardReadyAt;
        if (block.timestamp < readyAt) revert PriceGuardChangeNotReady(readyAt);
        _requireNotExpired(readyAt);

        address previous = address(priceGuard);
        priceGuard = IPriceGuard(next);
        previousPriceGuard = previous;
        delete pendingPriceGuard;
        delete pendingPriceGuardReadyAt;
        emit PriceGuardChanged(previous, next);
    }

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

    function cancelComponentAnnouncement(address token) external onlyGovernance {
        if (componentReadyAt[token] == 0) revert NoPendingComponent(token);
        delete componentReadyAt[token];
        emit ComponentAnnouncementCancelled(token);
    }

    /// @notice Adds an announced token once its wait has passed, as the last component. It joins
    /// inactive and with no initial amount. Governance explicitly activates it before it can
    /// back normal mint/redemption or participate in swaps.
    /// @dev Anyone may execute it: governance decided when it announced the token, and can cancel
    /// during the wait, so a voting governance needs one vote per change.
    function addComponent(address token) external nonReentrant {
        _requireNotLiquidating();
        uint256 readyAt = componentReadyAt[token];
        if (readyAt == 0) revert NoPendingComponent(token);
        if (block.timestamp < readyAt) revert ComponentNotReady(token, readyAt);
        _requireNotExpired(readyAt);
        uint256 count = _components.length;
        if (count == MAX_COMPONENTS) revert InvalidComponentCount(count + 1);

        delete componentReadyAt[token];
        _pushComponent(token, 0);
        excluded[token] = true;
        ++basketVersion;
        emit ComponentAdded(token, count);
    }

    /// @notice Removes an empty component. Only tokens with at least 18 decimals may leave up to
    /// MAX_REMOVAL_DUST base units; lower-precision tokens must have a zero balance.
    /// The components after it move down one index. Any balance left becomes a token outside the
    /// basket, which `rescue` can take in full. A written-off component can never be removed.
    /// @dev Written-off components retain recovery rights and can never be removed.
    function removeComponent(address token) external onlyGovernance nonReentrant {
        _requireNotLiquidating();
        uint256 index = _indexOf(token);
        if (writtenOff[token]) revert TokenWrittenOff(token);
        uint256 balance = IERC20(token).balanceOf(address(this));
        _requireEmpty(token, balance);
        uint256 last = _components.length - 1;
        if (last == 0) revert InvalidComponentCount(0);

        for (uint256 i = index; i < last; ++i) {
            IERC20 next = _components[i + 1];
            _components[i] = next;
            _componentSlot[address(next)] = i + 1;
            _initialAmounts[i] = _initialAmounts[i + 1];
        }
        // Claim totals are zero outside liquidation, which never ends, so they need no shifting.
        _components.pop();
        _initialAmounts.pop();
        _liquidationBasis.pop();
        _rightsClaimed.pop();
        _totalClaimed.pop();
        delete _componentSlot[token];
        delete excluded[token];
        delete writeOffReadyAt[token];
        ++basketVersion;
        emit ComponentRemoved(token, index);
    }

    /// @notice Sets the basket the first mint contributes for 1 GRET. It only applies while the
    /// supply is zero, when no holder is affected. Zero leaves a component out of that mint; at
    /// least one amount must be positive. `version` is the `basketVersion` the amounts were
    /// prepared for, so a call waiting in a timelock cannot land on a reordered basket.
    function setInitialAmounts(uint256[] calldata amounts, uint256 version) external onlyGovernance nonReentrant {
        _requireBasket(version, amounts.length);
        bool positive;
        for (uint256 i; i < amounts.length; ++i) {
            _initialAmounts[i] = amounts[i];
            if (amounts[i] != 0 && !excluded[address(_components[i])]) positive = true;
        }
        if (!positive) revert EmptyBasket();
        emit InitialAmountsSet(amounts);
    }

    /// @notice Proposes writing off a component that stopped working, such as one whose issuer froze
    /// the vault: it blocks mint and normal redemption, and it cannot be sold. Governance judges
    /// that; the vault only enforces `BASKET_CHANGE_DELAY` before the write-off takes effect.
    /// Proposing it again restarts the wait.
    function proposeWriteOff(address token) external onlyGovernance {
        _indexOf(token);
        uint256 readyAt = block.timestamp + BASKET_CHANGE_DELAY;
        writeOffReadyAt[token] = readyAt;
        emit WriteOffProposed(token, readyAt);
    }

    function cancelWriteOff(address token) external onlyGovernance {
        if (writeOffReadyAt[token] == 0) revert NoPendingWriteOff(token);
        delete writeOffReadyAt[token];
        emit WriteOffCancelled(token);
    }

    /// @notice Excludes the component, clears its initial amount and pauses minting after the
    /// notice. Makes no token calls. It stays in the basket permanently, protected from rescue and
    /// removal; governance may reactivate it, and liquidation includes its recoveries automatically.
    /// @dev Anyone may execute it, as with `addComponent`. Governance should cancel the proposal if
    /// the token recovers during the wait. The pause stops a mint in the same transaction from
    /// entering without the component and sharing its recovery; governance resumes minting.
    function writeOffComponent(address token) external nonReentrant {
        _requireNotLiquidating();
        uint256 index = _indexOf(token);
        uint256 readyAt = writeOffReadyAt[token];
        if (readyAt == 0) revert NoPendingWriteOff(token);
        if (block.timestamp < readyAt) revert WriteOffNotReady(token, readyAt);
        _requireNotExpired(readyAt);
        if (excluded[token]) revert ComponentExcluded(token);

        delete writeOffReadyAt[token];
        writtenOff[token] = true;
        excluded[token] = true;
        _initialAmounts[index] = 0;
        emit ComponentWrittenOff(token);
        emit ComponentActivationChanged(token, false);
        _pauseMint();
    }

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
        if (block.timestamp < readyAt) revert FeesNotReady(readyAt);
        _requireNotExpired(readyAt);
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
        emit FeeRecipientChanged(feeRecipient, next);
        feeRecipient = next;
    }

    /// @notice Pauses or resumes minting, at once. Wallets that minted can still redeem; a holder
    /// that never minted cannot qualify until minting resumes (a known limitation). Useful during an
    /// incident; a write-off and a last skipping exit pause minting by themselves. Resuming before
    /// a written-off component is reactivated lets new entrants share its recovery.
    function setMintPaused(bool paused) external onlyGovernance {
        mintPaused = paused;
        emit MintPauseChanged(paused);
    }

    /// @notice First step of a governance change. Replaces any pending proposal and restarts
    /// the wait.
    function proposeGovernance(address next) external onlyGovernance {
        if (next == address(0)) revert ZeroAddress();
        uint256 readyAt = block.timestamp + GOVERNANCE_TRANSFER_DELAY;
        pendingGovernance = next;
        pendingGovernanceReadyAt = readyAt;
        emit GovernanceProposed(next, readyAt);
    }

    function cancelGovernanceProposal() external onlyGovernance {
        address pending = pendingGovernance;
        if (pending == address(0)) revert NoPendingGovernance();
        delete pendingGovernance;
        delete pendingGovernanceReadyAt;
        emit GovernanceProposalCancelled(pending);
    }

    /// @notice Second step: the proposed address takes over once the wait has passed, proving it
    /// can call the vault.
    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert NotPendingGovernance(msg.sender);
        uint256 readyAt = pendingGovernanceReadyAt;
        if (block.timestamp < readyAt) revert GovernanceTransferNotReady(readyAt);
        _requireNotExpired(readyAt);

        address previous = governance;
        governance = msg.sender;
        delete pendingGovernance;
        delete pendingGovernanceReadyAt;
        emit GovernanceTransferred(previous, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function componentCount() external view returns (uint256) {
        return _components.length;
    }

    function components() external view returns (IERC20[] memory) {
        return _components;
    }

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

    function totalClaimed() external view returns (uint256[] memory) {
        return _totalClaimed;
    }

    function rightsClaimed() external view returns (uint256[] memory) {
        return _rightsClaimed;
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

    function _redeem(uint256 shares, uint256[] calldata minAmountsOut, bool[] memory skip)
        private
        returns (uint256[] memory amounts)
    {
        _requireNotLiquidating();
        if (!hasMinted[msg.sender]) revert RedemptionNotEnabled(msg.sender);
        if (shares == 0) revert ZeroShares();

        amounts = _redemptionAmounts(shares, skip);
        uint256 fee = _redeemFeeOn(shares, totalSupply());
        uint256 burned = shares - fee;
        uint256 remaining = totalSupply() - burned;
        if (remaining != 0 && remaining < MIN_SUPPLY) revert SupplyBelowMinimum(remaining);
        uint256 count = _components.length;
        for (uint256 i; i < count; ++i) {
            if (amounts[i] < minAmountsOut[i]) revert AmountOutBelowMin(i, amounts[i], minAmountsOut[i]);
        }

        if (fee != 0) _chargeFee(fee, false);
        _burn(msg.sender, burned);
        for (uint256 i; i < count; ++i) {
            if (amounts[i] != 0) _components[i].safeTransfer(msg.sender, amounts[i]);
        }
        emit Redeemed(msg.sender, burned, amounts);
    }

    /// @dev Pulls one component for a mint or a swap and returns what actually arrived.
    function _pull(uint256 index, uint256 amount, uint256 maxAmount, uint256 balanceBefore)
        private
        returns (uint256 received)
    {
        // Mint skips components it does not ask for; a swap offering nothing stops here.
        if (amount == 0) revert ZeroComponentAmount(index);
        if (amount > maxAmount) revert AmountInAboveMax(index, amount, maxAmount);

        IERC20 token = _components[index];
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = token.balanceOf(address(this));
        received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received == 0 || received > amount || received + MAX_RECEIPT_SHORTFALL < amount) {
            revert UnexpectedBalance(index, amount, received);
        }
    }

    function _redemptionAmounts(uint256 shares, bool[] memory skip) private view returns (uint256[] memory amounts) {
        uint256 supply = totalSupply();
        if (shares > supply) revert SharesExceedSupply(shares, supply);
        amounts = new uint256[](_components.length);
        uint256 burned = shares - _redeemFeeOn(shares, supply);
        if (burned == 0) return amounts;
        for (uint256 i; i < amounts.length; ++i) {
            if (skip[i] || excluded[address(_components[i])]) continue;
            amounts[i] = Math.mulDiv(burned, _components[i].balanceOf(address(this)), supply);
        }
    }

    /// @dev Only high-precision tokens may leave up to ten base units. Low-decimal assets must
    /// be exactly empty, so ten whole indivisible assets cannot be discarded as rounding dust.
    function _requireEmpty(address token, uint256 balance) private view {
        if (balance == 0) return;
        if (balance > MAX_REMOVAL_DUST || IERC20Metadata(token).decimals() < 18) {
            revert ComponentHasReserve(token, balance);
        }
    }

    function _effectiveBasis(uint256 index, uint256 balance) private view returns (uint256) {
        return Math.max(_liquidationBasis[index], balance + _rightsClaimed[index]);
    }

    /// @dev No cached-balance fallback: an unreadable token cannot consume claims or overpay.
    /// Establish the basis lazily; later income increases all holders' rights automatically.
    function _claimQuote(address account, uint256 index)
        private view returns (uint256 basis, uint256 rights, uint256 amount)
    {
        uint256 shares = claimShares[account];
        if (shares == 0) return (0, 0, 0);
        uint256 balance = _components[index].balanceOf(address(this));
        basis = _effectiveBasis(index, balance);
        rights = Math.mulDiv(shares, basis, liquidationSupply) - claimed[account][index];
        if (rights == 0) return (basis, 0, 0);
        uint256 owed = basis - _rightsClaimed[index];
        amount = balance >= owed ? rights : Math.mulDiv(rights, balance, owed);
    }

    function _pushComponent(address token, uint256 initialAmount) private {
        _components.push(IERC20(token));
        _componentSlot[token] = _components.length;
        _initialAmounts.push(initialAmount);
        _liquidationBasis.push(0);
        _rightsClaimed.push(0);
        _totalClaimed.push(0);
    }

    /// @dev Rounded up, so that no operation with a positive fee rate pays nothing.
    function _fee(uint256 shares, uint256 rate) private pure returns (uint256) {
        return Math.mulDiv(shares, rate, FEE_DENOMINATOR, Math.Rounding.Ceil);
    }

    /// @dev Redeeming the whole supply pays no fee: fee GRET would otherwise stay in the supply and
    /// keep the holder of every GRET from leaving in full.
    function _redeemFeeOn(uint256 shares, uint256 supply) private view returns (uint256) {
        return shares == supply ? 0 : _fee(shares, redeemFee);
    }

    /// @dev On mint the fee is issued to the recipient; on redemption it is moved from the caller.
    function _chargeFee(uint256 fee, bool issue) private {
        address recipient = feeRecipient;
        if (issue) _mint(recipient, fee);
        else _transfer(msg.sender, recipient, fee);
        emit FeeCharged(msg.sender, recipient, fee);
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

    /// @dev The vault's balance of `token`, or zero if the read reverts or answers with less than a
    /// word, so an unreadable component does not block rescues of other tokens.
    function _readableBalance(IERC20 token) private view returns (uint256) {
        (bool ok, bytes memory data) = address(token).staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        return ok && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
    }

    /// @dev Emits only on a change, so an existing pause is kept without a second event.
    function _pauseMint() private {
        if (mintPaused) return;
        mintPaused = true;
        emit MintPauseChanged(true);
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

    function _indexOf(address token) private view returns (uint256) {
        uint256 slot = _componentSlot[token];
        if (slot == 0) revert NotAComponent(token);
        return slot - 1;
    }

    function _requireNotExpired(uint256 readyAt) private view {
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
