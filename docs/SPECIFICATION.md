# GRET specification

Updated on November 2, 2026. **Live-balance accounting is the implemented design.** The
October 27 mainnet pilot is immutable and still runs the previous recognized-reserve design.
This change does not upgrade, migrate, deploy, or transact with that pilot.

## Overview

`contracts/GRETVault.sol` is both the GRET ERC-20 and its basket vault. It supports proportional
in-kind mint/redemption, per-component emergency claims, basket changes, fees and guarded
rebalancing. There are no upgrades. `ChainlinkPriceGuard.sol` limits swaps using Chainlink
prices. Mint, redemption and liquidation use token quantities, not prices.

The scope remains a mainnet pilot with the project's own funds, not an offering to third
parties. The current basket has 11 components; configuration and verified addresses are in
`scripts/pilot/config.ts`. Target dollar weights do not fix quantities per GRET. The current
pilot governance is a wallet. The proposed progression remains Safe, then a timelock,
then a Governor with a separate VORA voting token; those contracts and voting parameters
are not implemented or decided. GRET carries no votes. See [accepted risks](ACCEPTED_RISKS.md) and [pilot procedure](PILOT.md).

The contracts have internal tests and reviews, not an independent audit. Mocks are not proof
of issuer compatibility; fork results are specific to their recorded block and code versions.

## Core rules

- **Normal backing is the live balance of each active component.** No normal reserve amounts
  are stored. Positive rebases, issuer distributions and direct donations belong to holders
  as soon as they arrive. Losses likewise affect the next quote/operation immediately.
  There is no `sync`, `recognizeLoss`, `componentSurplus`, `Synced` or `LossRecognized` API.
- **Bootstrap:** when supply is zero, the first mint requests exactly `INITIAL_SHARES = 1e18`
  and contributes the configured initial basket, skipping excluded components. At least one
  positive contribution is required. Preexisting balances of active components then belong
  to that first GRET. This includes residues abandoned by a previous last skipping redeemer.
  Ordinary components may be rescued while normal supply is zero; written-off tokens may not.
  Blocking bootstrap on unsolicited balances was rejected because anyone could grief it.
- **Later mints:** snapshot all active balances before any input transfer. For requested shares
  `s`, supply `S` and each pre-input balance `B[i]`, ask for `ceil(s * B[i] / S)`. A zero balance
  asks for nothing; an excluded component is not called. Measure receipts and issue at most
  the minimum `floor(received[i] * S / B[i])` over contributing components. Fee shares come out
  of this issuance. `maxAmountsIn` and `minShares` bound user cost and net issuance.
- **Receipt tolerance:** each requested component must deliver a positive amount no larger
  than requested and no more than ten base units short (`MAX_RECEIPT_SHORTFALL`). The minter
  absorbs rounding, not existing holders. Larger transfer fees revert. Receipt measurement
  remains necessary even though backing is live.
- **Eligibility:** a wallet that completes a mint may redeem normally, including GRET acquired
  later. Eligibility does not transfer with GRET. A mint must contribute every active nonzero
  component; zero issuance and an empty backing basket are rejected.
- **Normal redemption:** calculate outputs from all required live balances before sending any
  token. The fee is transferred in GRET; the remainder is burned for
  `floor(burnedShares * B[i] / S)` per component. Every transfer must succeed atomically.
  Minimum outputs bound requested transfers, not the recipient's actual balance increase.
- **Skipping:** `redeemSkipping` never calls listed tokens or excluded components, even for
  `balanceOf`. Their outputs and minima must be zero. Skipped assets remain for other holders,
  or a later bootstrap if supply empties; the exiting holder retains no separate right.
  `previewRedeemSkipping` quotes this exit without calling skipped tokens.
- **Supply floor:** normal redemption leaves either zero or at least `MIN_SUPPLY = 1e18`.
  Fee shares remain outstanding, so a positive redemption fee prevents a full normal exit.
  Liquidation permits conversion below that floor and eventually zero unconverted supply.
- **Mint pause only:** governance can pause/resume minting immediately. Normal redemption is
  never paused. A secondary-market holder who never minted cannot qualify while paused.
- GRET transfers to the vault itself revert; otherwise shares are ordinary transferable ERC-20
  tokens, including unconverted GRET during liquidation.

A post-receipt minter now pays against the full increased backing, removing the old dividend
capture window. Entering before a future gift, before an excluded token is reactivated, or
before another holder skips an asset can still share that later allocation (R-08).

Only tokens already in the basket are considered. Payments in another currency, airdrops
outside the basket or income requiring an issuer-specific claim are not automatically handled.

## Component lifecycle

Between 1 and 128 unique deployed token contracts can be registered. Constructor components
are active and have positive initial amounts. Governance announces additions; anyone may add
one after seven days and before the following seven-day execution window expires. A new
component enters **excluded**, with zero initial amount. Even donations cannot make it active.

`activateComponent(token)`, only governance in normal mode, makes the entire balance active
without making a token call. It is explicit, immediate and idempotent. Calling it for an
already active token returns without emitting a change event. The original addition or
write-off already had its notice; reactivation does not require another wait. Keep minting closed
throughout a relevant exclusion/recovery period if new entrants must not share recovery.
Pausing only when reactivation is announced does not undo prior entry.

`deactivateEmptyComponent(token)` excludes an empty component immediately. A nonzero residue
is allowed only if it is at most `MAX_REMOVAL_DUST = 10` base units and the token reports at
least 18 decimals. Tokens with fewer decimals must be exactly empty: a few whole indivisible
assets must not be discarded as dust. This prevents incidental receipts from reactivating a
sold-out token. An active zero-balance token otherwise becomes required again when it receives
anything; that may block a minter unable to transfer it.

For a materially funded or unreadable component, governance proposes a **write-off**. After
seven days anyone may execute within the execution window. Execution makes no token calls:
it excludes the component, clears its initial amount and permanently sets `writtenOff`.
A previously excluded component cannot be written off again until reactivated. Governance
judges whether a write-off is warranted; the contract does not prove the issuer is broken.

The permanent history and reversible exclusion are separate. A written-off token:

- can be reactivated for normal backing by governance;
- can never be rescued or removed, including after reactivation;
- remains available for per-token liquidation claims automatically if transfers/readability
  recover, without reactivation or another governance operation.

Governance may remove an ordinary component only under the same empty/dust rule. Exclusion
alone never permits removal of meaningful funds. Removed residues become foreign tokens;
subsequent issuer recovery of a removed token is outside the claim system (R-04/P-7).
`basketVersion` increases on addition/removal, not activation or write-off. Positional limits
must match this version and current array length. This is intentional: the version protects
address/index mapping, not a frozen price or active set. `maxAmountsIn` and `minShares` protect
mint economics; `minAmountsOut` protects redemption. Activating funded backing after a quote
with a zero input cap reverts with `AmountInAboveMax`. Excluding a component after quoting a
positive output minimum reverts with `AmountOutBelowMin`, even though the version matches.
A caller supplying loose/zero limits accepts the corresponding changes. Initial amounts can be changed by governance,
but affect only bootstrap; at least one active initial amount must be positive.

Dust tolerance is bounded, not a general removal guarantee. Large donations can still obstruct
removal; broken metadata or balance reads can also prevent an ordinary removal. The delayed
write-off remains available and retains the token's slot permanently.

## Rebalancing and price guard

Only the appointed rebalancer may `swap(sell, sellAmount, buy, buyAmount)`, and only in normal
mode with positive supply. Both tokens must be registered and active. A swap cannot silently
reactivate a written-off or newly added component. Sell amount cannot exceed its live balance.
The vault pulls the buy token, measures the receipt with mint's tolerance, calls its guard,
and sends the sell amount only after approval. Every failure reverts the entire exchange.

The vault and guard must be deployed as a compatible pair. `IPriceGuard.checkSwap` keeps the
same arguments but its timing contract is explicit: buy tokens have arrived and sell tokens
have not left. In `ChainlinkPriceGuard`, pre-swap value is reconstructed by subtracting the
measured buy receipt **in token units before valuation**. Incoming purchase and outgoing
inventory cannot both inflate the weekly denominator. Excluded components do not count.
Donations received before the exchange do count, because they now back GRET.

The guard enumerates component addresses and reads each priced, active token separately.
A reverting balance read or unusable price contributes zero, making the loss fraction more
conservative. It does not call the aggregate `reserves()` view, which is unavailable during
mutation. Malformed successful return data can still revert valuation; this is part of R-15.

Guard limits and price assumptions are unchanged:

- Sell value rounds up, buy value down. Missing, nonpositive, future or stale feeds reject
  swaps involving that token. Each feed quotes a whole token in USD.
- A trade may lose at most 2% of sell value. Each loss is divided by the priced pre-trade
  backing, rounded up; the sum must be at most 2% during each fixed seven-day Unix epoch.
  Fair/favorable trades do not consume the budget. Deposits/withdrawals do not reset it.
- The guard has no owner; feeds, max ages, cached token decimals and limits are immutable.
  Replacement creates a fresh weekly counter. Losses across week boundaries or replacements
  can therefore exceed one period's budget; see R-02.
- Feeds may lag, price an underlying rather than the token's market peg, or become stale on
  weekends. Six current components lack configured Ethereum feeds; they cannot be traded by
  this guard. Neither price accuracy nor issuer solvency is guaranteed (R-03).

Rebalancer and guard appointments wait seven days and expire seven days later. Governance may
revoke the rebalancer immediately; the notice gives eligible holders an exit using skipping
if necessary. A captured governance can appoint a malicious guard after the notice (R-01).

## Fees and governance

Both fees start at zero and are capped at 500 basis points. Lowering both applies immediately;
raising either requires a seven-day proposal and execution within the following seven days.
Positive fees require a nonzero recipient distinct from the vault. Mint fees split the paid
issuance; redemption fees transfer GRET to that recipient and only the remainder is burned.
Liquidation has no fees. Fee rounding and the minimum supply can affect very small positions.

Governance may pause minting, activate liquidation, manage component lifecycle and initial
amounts, configure fees and their recipient, rescue permitted tokens, and appoint the guard,
rebalancer or its own successor. Governance succession is two-step: the proposed address must
accept after seven days and within the execution window. There is no governance-contract
assumption beyond being able to call the vault. No arbitrary external-call or upgrade function
exists. Proposals can be cancelled; revocation removes the pending rebalancer too.

`rescue(token,to,amount)` may transfer foreign tokens. For a registered ordinary component it
works only while normal supply is zero. It never rescues a component in liquidation or a
historically written-off token. Active income, excluded balances and late claim distributions
cannot be redirected by calling them surplus. Removing an eligible dust component explicitly
changes that component to foreign status.

### How governance grows without changing the vault

The vault fixes what governance can do: activate liquidation, manage activation/exclusion,
rescue permitted tokens, change the basket, write off components, set bounded fees, and
appoint the rebalancer, guard and successor. How governance decides can change independently.
The following progression is a **proposal**, not a deployed governance system:

1. The pilot wallet initially governs. A Safe multisig is the proposed next step, with
   threshold/signers and key recovery to be chosen; it can act immediately in emergencies.
2. The Safe can appoint an OpenZeppelin `TimelockController` using the vault's seven-day,
   two-step handover. The proposed Safe is its sole proposer and executor initially.
3. A Governor using a separate **VORA** voting token may become a timelock proposer. VORA's
   distribution, delegation, quorum, voting delay/period and timelock delay remain proposals.
   GRET does not acquire votes; the vault still sees the timelock as its governance address.
4. More complex rules, such as a fast emergency-only path, require a separate governance
   contract appointed through the same handover, not a new power inside the vault.

`test/GRETVault.timelock.ts` exercises handover, delayed actions, restricted execution of
reactivation and addition of another proposer with the actual `TimelockController` contract.
Its "multisig" actor is a stand-in signer, not proof of a particular Safe configuration or
an implemented Governor/VORA system. A timelock alone also delays emergency activation.
The rebalancer and guard remain independently replaceable after their notice. A new vault
is needed for new vault powers, not for changing who decides under existing powers.

## Emergency liquidation

`activateLiquidation()` permanently closes minting, normal redemption, swaps and basket
lifecycle changes. It requires positive supply and freezes that denominator in
`liquidationSupply`; it performs no token calls. This closes the former R-25 empty-liquidation
trap. Governance cannot reverse liquidation.

Any holder, including one who never minted, may burn GRET with `convertToClaims(shares)`.
`claimShares[account]` is cumulative and nontransferable. Unconverted GRET remains transferable.
Each component can be claimed independently to a nonzero recipient other than the vault.
Exclusion in normal mode does not waive liquidation rights over that component.

The vault keeps **only liquidation** nominal bases and consumed rights; it does not snapshot
all token balances at activation. For component `i`, let:

- `L` be the basis established by prior successful claims (initially zero);
- `Q` be aggregate nominal rights consumed, `B` its current balance;
- `S0` be the frozen supply, `c` the claimant's cumulative converted shares and `q` their
  previously consumed rights for that component.

```
nextBasis = max(L, B + Q)
rights = floor(c * nextBasis / S0) - q
owed = nextBasis - Q
payout = rights                     when B >= owed
         floor(rights * B / owed)   otherwise
```

A successful nonzero claim stores `nextBasis`, consumes `rights` in both ledgers, records the
actual requested payout in `totalClaimed`, then transfers it. Failed reads, transfers or
minimum-output checks revert all these changes. Zero converted shares return a zero quote
without reading the token. A zero payout leaves the right unconsumed. `minAmount` lets a
holder refuse a cut; a successful haircut consumes its full nominal right.

This automatically incorporates later income for all frozen shares, including unconverted
shares and accounts that already claimed. After everyone settles, a later receipt can open
new proportional claims. No governance sync is needed. The basis is established per component
at its first successful claim, not by a view and not at activation.

Recovery is not targeted compensation. For example, Alice and Bob own halves of 100. Alice
claims 50, the vault loses 25, Bob claims 25, then 25 is recovered. Automatic allocation gives
12.5 more to each: cumulative payouts 62.5/37.5. No component rescue can correct this internally.
Additional compensation requires external funding or voluntary settlement (R-04/P-2). A loss
before the first successful claim establishes a smaller initial basis instead. This differs
from the old fixed-at-activation reserve policy and is part of the implemented decision.

A reverting or malformed `balanceOf` blocks that component's claim until repaired. The vault
never substitutes a stale stored normal balance. Other components remain claimable. Rounding,
outgoing token fees/no-op transfers, unavailable recipients and unconverted contract-held
GRET remain limitations; no guaranteed recovery is promised.

## Views, callbacks and integrations

`reserves()` returns live active balances in normal mode. In liquidation it returns effective
nominal bases, including consumed rights; it is **not** a remaining-token-balance view then.
`liquidationBasis()` exposes only bases established by successful claims without token calls.
`pendingRights`/`claimable` compute effective current rights/payouts for one component.

`reserves`, both normal previews, the skipping preview, `pendingRights` and `claimable` use
`nonReentrantView`: callback consumers cannot read an intermediate accounting state. Mutations
use the existing transient reentrancy guard. Storage-only membership/exclusion views remain
available to the price guard. Ordinary ERC-20 views alone are not a NAV oracle; integrations
must not reconstruct prices from raw in-flight token balances and supply.

The pilot reports a readable error when wallet balances, aggregate backing or quotes cannot
be read. Its normal page does not implement skipping exits and never makes that forfeiture
choice for the user. The explicit skipping and per-component liquidation contract APIs remain
available independently of the page.

The pilot signs exact input approvals and exact quoted maxima. It requotes after approvals;
if the final transaction changes or another approval is needed, it stops and asks the user to
review again. An income event can still race transaction inclusion, in which case the bounded
mint reverts. There is no silently enlarged allowance or slippage tolerance. The pilot checks
bytecode against the local build; the old mainnet vault is intentionally not a match for this
version. Basket changes still require refreshing the pilot's configured component list.

## Implementation details

- Solidity 0.8.38, Hardhat 3, TypeScript ESM, viem and `node:test`; Solidity cases/fuzzing use
  forge-std. GRET is an immutable 18-decimal ERC-20, "Global Reserve Token" / "GRET".
- Constructor amounts are positive and configurable later. Local demo amounts of one whole
  unit per component are placeholders, not portfolio recommendations. Prefer initial amounts
  of at least about 10,000 base units so one unit of rounding is a small relative change.
- Initial issuance is exactly one GRET before fees. Subsequent receipts are measured; mint
  returns net `minted` and actual `received`. Exact input tokens produce the requested gross
  issuance; rounding tokens can reduce it. `hasMinted` belongs to the caller: a router's mint
  qualifies the router, not its underlying user.
- There is no normal reserve ledger. Every active required balance is read before input or
  output transfers. Unreadable/reverting/malformed balances fail closed. Explicitly excluded
  or skipped tokens are not called. Initial amounts of zero are omitted during bootstrap.
- Contributions round up; withdrawals and fee shares round down. A component payout that
  rounds to zero is not transferred. An empty contributing basket cannot issue shares.
- No transaction deadline is enforced. Input/output/share limits bound economics despite
  live income/losses, activation, fees or swaps changing a previously observed ratio. Tight
  limits may revert; a quote is not a reservation of a balance or basket state.
- `ReentrancyGuardTransient` relies on Cancun/EIP-1153. It guards reserve and liquidation
  mutations, component list/state mutations, initial amounts and applying fees. Sensitive
  accounting views reject callbacks. Authorized proposals, cancellations, appointments and
  rebalancer revocation do not themselves transfer backing and retain their authorization
  checks. GRET transfers cannot change already converted rights and cannot send GRET to the vault.
- The liquidation denominator is frozen once, but bases are established separately at the
  first successful claim. Storage for consumed nominal rights differs from actual requested
  payouts; neither implies full compensation for a later issuer recovery. Failure reverts the
  entire claim. An outgoing token's actual delivery may differ from requested payout (R-10).
- `reserves()` is a bulk external-token read in this design and may revert if any required
  balance is unreadable. Integrations that need partial availability must query per component;
  they must not substitute zero as if it were a verified NAV. For exits use an explicit
  `previewRedeemSkipping`/`redeemSkipping` choice or independent liquidation claims.
- The pilot currently provides a normal mint/redemption flow. Its actionable error identifies
  failed component wallet reads or unavailable aggregate backing/quotes and explains the
  separate skipping path and forfeiture. It never silently skips an asset. A complete
  emergency-exit page is still a separate integration task, not a capability of that page.

## Security requirements

Avoiding a vault bug that immobilizes all working assets remains a design priority. An
emergency boolean alone is not a recovery guarantee.

- Activation must not query or transfer external tokens. Conversion into rights must not
  require any component to respond. Zero-supply liquidation must be rejected atomically.
- A component claim must call only that component, independently of the normal basket
  computation, prices, other holders and administrative permission per withdrawal.
- Failed reads/transfers/minimum checks must preserve shares or pending rights. Prevent
  duplicate claims and reentrancy, including sequences with share transfers and conversion.
- Verify both global solvency and individual allocation, with independent actual-receipt
  records; do not rely only on totals or on the same formula used by the implementation.
- Mint/redemption must move the correct quantities and fees, and must not dilute remaining
  active backing per share. Removal must never permit withdrawing material registered backing.
- Do not add an arbitrary administrative withdrawal as a supposed universal recovery tool.
  Registered components are protected while shares or liquidation rights exist; historically
  written-off tokens are always protected. A swap requires incoming value and guard approval.
- Exercise issuer freezes, bad reads/return data, transfer failures, callbacks, loss/recovery
  timing, different claim orders, minters/secondary holders, last exits, rounding and donations.
  Healthy exits must remain possible without cooperation from other holders or the admin.
- Tests, randomized sequences and reviews reduce risk; they do not prove the absence of bugs.
  An independent audit remains pending before third-party funds. Mocks and fork observations
  cannot promise compatibility with future issuer upgrades.

## Validation and design history

The October 30 investigation was recorded here and implemented following the user's request.
The research-only model was replaced with production-vault regression tests in the existing
`test/GRETVault.audit-accounting.t.sol`. Historical dated audit reports remain unchanged and
refer to their original source revisions. Stable risk IDs are retained, including resolved
R-14/R-25 entries; R-08 now distinguishes future/excluded receipts from already received income.

Required commands for this change:

- `npm run check`: compilation, TypeScript and the complete local test suite.
- `npm run test:deep`: 20,000 cases per fuzz test and 1,000 sequences of depth 200 per invariant.
- `npm run pilot:rehearse`: local mainnet fork, real pilot wallet impersonated, no real signatures.
- `MAINNET_RPC_URL=... npm run test:fork`: real issuer-token and feed behavior at a recorded block.

The invariant handler uses an independent physical issuance/loss ledger and exercises mint,
redeem/skipping, share transfers, donations, losses, token faults, swaps, fees, pauses, component
activation/write-off/addition/removal, rescue, conversion and claims. Separate tests check
rounding/shortfall economics, callback views, price loss limits, claim order and late income.
Passing tests do not prove compatibility with future issuer upgrades or replace independent
review. Validation on November 2, 2026, on the working tree based on
`98a6e35f450a13409a2d2698089e47e9a39ee26e`:

- `npm run check`: 248 passing (119 Solidity, 129 Node.js), including compilation/typechecking.
- `npm run test:deep`: 119 passing; 20,000 cases per fuzz test and 1,000 runs of depth 200
  per invariant. Three initial states cover normal operations, existing losses/exclusions,
  and already-started liquidation. The handler checks exact mint/redemption quantities and
  fees, remaining-holder non-dilution, material removal rejection, global solvency and each
  holder's nominal entitlement and actual receipts against independent inflow records.
- `MAINNET_FORK_BLOCK=26327336 npm run pilot:rehearse`: one passing rehearsal.
  Deployment, approvals, mint, full redemption and another mint used 9,168,721 gas total.
  The round trip lost one base unit each of SPYx and JAAAx, zero for the other nine tokens.
- `MAINNET_FORK_BLOCK=26327339 npm run test:fork`: five passing tests covering token
  identity, each of the eleven tokens separately, the full basket, real Chainlink feeds and
  rebalance/add/remove flows. Inputs were funded in local fork storage; no mainnet balances
  were changed. Active income immediately changed mint quotes and could not be rescued.
  The guard's incoming receipt was delivered before its check. The full-basket example
  measured mint 712,646, redeem 591,378 and one claim 150,920 gas; these are scenario-specific
  samples, not bounds or a same-state comparison to the old code.

These final commands were run sequentially, with compilation enabled and without
`--no-compile`. Both network commands used
`MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com`. This supersedes the initial validation
at block 26,327,189. No fresh coverage percentage is claimed.

The independent normal reserve ledger and sync operations are gone, but the entire contract
is not dramatically smaller. Against the base revision with Solidity 0.8.38, optimizer 200
and Cancun, runtime bytecode grows from 19,945 to 20,608 bytes (below the 24,576-byte limit).
Exclusion controls, protected views and automatic liquidation income offset removed code.
The first mock-token claim now establishes its basis and measured 150,366 gas; its regression
bound is 175,000. Historical gas and coverage below describe the original deployment.

Primary references considered: [xStocks multipliers](https://docs.xstocks.fi/developers/multipliers),
[Backed share conversion](https://github.com/backed-fi/backed-token-contract/blob/main/contracts/BackedAutoFeeTokenImplementation.sol),
[Reserve Folio live basket accounting](https://github.com/reserve-protocol/reserve-index-dtf/blob/main/contracts/Folio.sol)
and [OpenZeppelin donation/rounding analysis](https://docs.openzeppelin.com/contracts/5.x/erc4626).
GRET is not an ERC-4626 implementation. No third-party architecture was copied as a substitute
for GRET's issuer-failure and per-component emergency requirements.

## Mainnet pilot

**Historical October 27 deployment.** The parameters, transactions and measurements below
describe the immutable previous code, not a deployment of the live-balance revision.

Parameters in
[`scripts/pilot/config.ts`](../scripts/pilot/config.ts); steps in [`PILOT.md`](PILOT.md).

- **Deployment:** `GRETVault` at `0x21b823334D2794a637cb9c0fd7fF8671b35F5A23` on Ethereum
  mainnet, October 27, 2026, 03:14 UTC, block 26,281,281, transaction
  `0x7ae2271ee3d7a81c04e78137c8d5eb12cc724656231eb6fa91bcfa0b45302467`, signed by the pilot
  wallet with MetaMask from the local page. Gas: 5,434,767 at 0.043 gwei, about 0.00023 ETH.
  The page's eight checks passed against mainnet right after the deployment, and
  `npm run test:fork` passed that day against a fresh fork. The source is verified on
  Sourcify with an exact match (creation and runtime bytecode) and, the same day, on
  Etherscan.
- **First mint:** 1 GRET to the pilot wallet, October 27, 2026, 03:26 UTC, block 26,281,343,
  transaction `0x9c72908baa94af16a1c209cc4a340964d1f75f7d1d0fe4e7f9ae3074288ece33`, after
  eleven approvals for the exact amounts. Gas: 1,154,288. The vault received the basket
  except 1 base unit of SPYx and 1 of JAAAx, lost to xStocks rounding, as in the rehearsal.
- **Pilot wallet:** `0xe03E228E1f1c50a985556Cc9c05b0aB953Feb7fd`, an EOA. It deploys,
  makes the first mint and is the initial governance. Deploying gives no power over the
  vault. There is no rebalancer or price guard at deployment; if the pilot needs a rebalance,
  the wallet proposes itself and a `ChainlinkPriceGuard` deployed with `PRICE_FEEDS`, and
  both take effect after 7 days. Handing governance to a Safe is left for later, with the
  vault's two steps and 7-day wait. Accepted risk (R-01): whoever obtains that key can
  activate liquidation, which is irreversible although holders still claim everything per
  component, withdraw surpluses and, after a 7-day wait visible on chain, appoint a
  rebalancer and a guard that accepts every swap, and exchange the reserves at any price.
  Losing it leaves the vault without anyone to activate liquidation, sync or change the
  basket. Fees stay at zero; if they are ever turned on, the fee recipient is this same
  wallet (R-09).
- **1 GRET ≈ USD 100 at deployment**, split by the target weights, at DefiLlama prices of
  October 22, 2026, 17:53 UTC:

| Component | Address | Weight | Price (USD) | In 1 GRET |
| --- | --- | ---: | ---: | ---: |
| ITOTon | `0x0692481C369E2BDc728A69ae31b848343a4567Be` | 7.5% | 167.80 | 0.0447 |
| SPYx | `0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48` | 7.5% | 766.15 | 0.009789 |
| EFAon | `0x4111b60bc87F2Bd1e81E783E271D7F0ec6EE088B` | 7.5% | 105.65 | 0.07099 |
| IEMGon | `0xcDD60D15125bf3362b6838D2506b0Fa33bc1a515` | 2.5% | 76.77 | 0.03256 |
| SGOVon | `0x8De5D49725550f7b318b2FA0f1B1F118E98E8D0F` | 10% | 102.78 | 0.09729 |
| BILon | `0x2710E30d84B376c34a3B3036aa196b26a83A321b` | 10% | 92.60 | 0.108 |
| JAAAx | `0x3bf2E3be4A829Bb3a5f5BE450AE4c8Eb3488da71` | 20% | 50.60 | 0.3953 |
| PAXG | `0x45804880De22913dAFE09f4980848ECE6EcbAf78` | 20% | 4,051.64 | 0.004936 |
| cbBTC | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | 2.5% | 81,150.78 | 0.00003081 |
| VNQon | `0xcCAe8843E26259278C200C6506F6E5A3bdD524cd` | 2.5% | 94.06 | 0.02658 |
| DBCon | `0x20224080aD516769723c9a4A18325fC4E8C9Ab5D` | 10% | 33.63 | 0.2974 |

  The addresses and amounts are the ones the deployed vault returns from `components()` and
  `initialAmounts()`, in that order.

  cbBTC gets 3,081 sats, below the ~10⁴ base-unit guideline. Accepted: with a 2.5% weight,
  a one-sat rounding is a negligible share of the basket's value, and reaching 10⁴ sats
  would need 1 GRET ≈ USD 330, more than the pilot wallet holds. With its balances that
  day, the pilot wallet can mint about 2.44 GRET; PAXG and JAAAx set the limit.
- **Addresses verified on October 20:** the seven Ondo tokens against Ondo's official
  token list (v13.0.0), SPYx and JAAAx against Backed's product pages, PAXG against
  Paxos's repository, and cbBTC against coinbase.com/cbbtc, confirmed by hand by the
  project owner.
- **Rehearsal** (`npm run pilot:rehearse`, fork of October 26, with these amounts and the
  current contract): the real wallet, with its balances, deploys, verifies the vault,
  approves exact amounts, mints 1 GRET, redeems it and mints again. Gas: deployment 5.43M;
  each approval between 54k and 60k; the first mint in a new vault 1.15M, because it writes
  empty storage; the full redemption 0.53M; the full cycle 9.46M. The round trip lost 1 base
  unit of SPYx and 1 of JAAAx. The MetaMask rehearsal on a local fork was skipped: the page
  was first used for the mainnet deployment and mint, after the automated rehearsal ran
  against mainnet state shortly before.
- **Tools:** `scripts/pilot/plan.ts` builds the transactions and verifies the deployed
  vault (code identical to this repository's build, components, amounts, governance, no
  rebalancer, fees at zero, minting not paused, name and symbol). The page (`npm run pilot`)
  only sends what that module returns; the automated rehearsal uses the same module. Both assume the deployment's
  basket: after a basket change, mint and redemption need the new component list.

Pending for the pilot: MetaMask flags the approvals and the mint as malicious (a Blockaid
alert, common for new contracts that receive approvals of many tokens); the vault only pulls
tokens from the caller of `mint` or `swap`, so it is a false positive still to be reported.


## Roadmap and open items

`GRETVault-explained.html` and its PDF describe this live-balance design as of November 2,
2026; the specification remains authoritative where they differ. Restoring governance
proposals here does not make them approved, implemented or part of a deployment plan.


- Independent review and issuer/fork verification before third-party funds.
- Governance implementation and recovery process; the current governance remains a wallet.
- Feed coverage, market-peg monitoring and the previously proposed guard improvements (counter
  continuity across replacements and token-decimal changes). They are not implemented here.
- Any migration from the original immutable pilot: requires a concrete deployment and funding
  plan. This source change authorizes neither a mainnet deployment nor movement of its assets.
- MetaMask's original Blockaid alert and the previously deferred manual pilot rehearsal.
