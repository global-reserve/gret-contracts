# GRET specification

Updated on November 5, 2026. This document states what the contracts in `contracts/` must do.
The current source has not been deployed. The pilot vault deployed on Ethereum mainnet on
October 27, 2026 runs an earlier, immutable version, which kept a recognized-reserve ledger
updated by governance `sync`; [PILOT.md](PILOT.md) records that deployment.

## Overview

`contracts/GRETVault.sol` is both the GRET ERC-20 and its basket vault. It supports proportional
in-kind mint/redemption, per-component emergency claims, basket changes, fees, guarded
rebalancing and an optional eligibility contract. There are no upgrades.
`ChainlinkPriceGuard.sol` limits swaps using Chainlink prices. Mint, redemption and liquidation
use token quantities, not prices.

The scope is a mainnet pilot with the project's own funds, not an offering to third parties.
The current basket has 11 components; configuration and verified addresses are in
`scripts/pilot/config.ts`. Target dollar weights do not fix quantities per GRET. The current
pilot governance is a wallet. The proposed progression is Safe, then a timelock, then a
Governor with a separate VORA voting token; those contracts and voting parameters are not
implemented or decided. GRET carries no votes.

Mocks are not proof of issuer compatibility; fork results are specific to their block and code
versions.

## Core rules

- **Normal backing is the live balance of each active component.** No normal reserve amounts
  are stored. Positive rebases, issuer distributions and direct donations belong to holders
  as soon as they arrive. Losses likewise affect the next quote/operation immediately.
- **Bootstrap:** when supply is zero, the first mint requests exactly `INITIAL_SHARES = 1e18`
  and contributes the configured initial basket, skipping excluded components and zero
  amounts. At least one positive contribution is required. Preexisting balances of active
  components then belong to that first GRET. This includes residues abandoned by a previous
  last skipping redeemer, so a skipping redemption that leaves zero supply pauses minting:
  governance reviews what was left before a restart and resumes minting when it decides. A
  normal redemption of the whole supply pays out every active balance and does not pause.
  Ordinary components may be rescued while normal supply is zero; written-off tokens may not.
  Blocking bootstrap on unsolicited balances was rejected because anyone could grief it.
- **Later mints:** snapshot all active balances before any input transfer. For requested shares
  `s`, supply `S` and each pre-input balance `B[i]`, ask for `ceil(s * B[i] / S)`. A zero balance
  asks for nothing; an excluded component is not called. Measure receipts and issue at most
  the minimum `floor(received[i] * S / B[i])` over contributing components. Fee shares come out
  of this issuance. `maxAmountsIn` and `minShares` bound user cost and net issuance; every
  `maxAmountsIn` is checked before any input is pulled.
- **Receipt tolerance:** each requested component must deliver a positive amount no larger
  than requested and no more than ten base units short (`MAX_RECEIPT_SHORTFALL`). The minter
  absorbs rounding, not existing holders. Larger transfer fees revert. Receipts are measured
  even though backing is live.
- **Eligibility:** without an eligibility contract anyone may mint and redeem, including a
  holder who received GRET by transfer. Governance may appoint one after the seven-day notice
  (see "Eligibility contract"). A mint must contribute every active component with a positive
  balance (at bootstrap, with a positive initial amount); zero issuance and an empty backing
  basket are rejected.
- **Normal redemption:** calculate outputs from all required live balances before sending any
  token. The fee is transferred in GRET; the remainder is burned for
  `floor(burnedShares * B[i] / S)` per component. Redeeming the whole supply pays no fee.
  Every transfer must succeed atomically.
  Minimum outputs bound requested transfers, not the recipient's actual balance increase.
- **Skipping:** `redeemSkipping` never calls listed tokens or excluded components, even for
  `balanceOf`. Their outputs and minima must be zero. Listed addresses that are not components
  are ignored, so a token announced for the basket can be listed before it joins. Skipped
  assets remain for other holders, or, if supply empties, for a later bootstrap once governance
  resumes minting; the exiting holder retains no separate right. A skipping redemption that
  leaves zero supply pauses minting whenever its list is not empty, even if the list names no
  component.
  `previewRedeemSkipping` quotes this exit without calling skipped tokens.
- **Supply floor:** normal redemption leaves either zero or at least `MIN_SUPPLY = 1e18`.
  Fee shares remain outstanding, but a redemption of the whole supply pays no fee, so a holder
  of every GRET can always leave in full. GRET that can never move, which anyone can create
  for a few base units, keeps anyone from holding every GRET; the last GRET then leaves only
  through liquidation.
  Liquidation permits conversion below that floor and eventually zero unconverted supply.
- **Mint pause only:** governance can pause/resume minting immediately; executing a write-off
  and a skipping redemption that leaves zero supply also pause it. Normal redemption is never
  paused.
- GRET transfers to the vault itself revert; otherwise shares are ordinary transferable ERC-20
  tokens, including unconverted GRET during liquidation.

A minter pays against the full current backing, including income already received. Entering
before a future gift, before an excluded token is reactivated, or before another holder skips
an asset still shares that later allocation.

Only tokens already in the basket are considered. Payments in another currency, airdrops
outside the basket or income requiring an issuer-specific claim are not automatically handled.

## Component lifecycle

Between 1 and 128 unique deployed token contracts can be registered. The vault itself and
EIP-7702 accounts, whose code is a delegation designator their key holder can replace without
notice, are refused with `InvalidContract`, as components, price guards and eligibility
contracts. Constructor components are active and have positive initial amounts. Governance
announces additions; anyone may add one after seven days and before the following seven-day
execution window expires. At most `MAX_PENDING_ANNOUNCEMENTS = 128` tokens may be announced and
waiting at once (`pendingAnnouncements`): an addition or a cancellation frees a slot,
announcing a waiting token again restarts its wait without taking another, and an expired
announcement keeps its slot until it is cancelled. A new component enters **excluded**, with
zero initial amount. Even donations cannot make it active.

`activateComponent(token)`, only governance in normal mode, makes the entire balance active
without making a token call. It is explicit, immediate and idempotent. Calling it for an
already active token returns without emitting a change event. The original addition or
write-off already had its notice, and an empty deactivation needs none; reactivation does not
require another wait. If governance resumes minting while a funded component is excluded,
entrants in between do not pay for it but share it once it is reactivated.

`deactivateEmptyComponent(token)` excludes an empty component immediately. A nonzero residue is
allowed only if it is at most `MAX_REMOVAL_DUST = 10` base units and the token reports at least
18 decimals. Tokens with fewer decimals must be exactly empty: a few whole indivisible assets
must not be discarded as dust. This prevents incidental receipts from reactivating a sold-out
token. Deactivation keeps the initial amount, which bootstrap ignores while the component is
excluded. Deactivating an already excluded component that meets the same rule changes nothing
and emits nothing; one funded beyond it, or whose balance cannot be read, makes the call
revert, as an active one does. An active zero-balance token otherwise becomes required again
when it receives anything; that may block a minter unable to transfer it.

For a materially funded or unreadable component, governance proposes a **write-off**. After
seven days anyone may execute within the execution window. Execution makes no token calls:
it excludes the component, clears its initial amount, permanently sets `writtenOff` and
pauses minting. The pause applies in the same transaction, so no mint can enter without the
component and later share its recovery; `MintPauseChanged` is emitted only if minting was not
already paused. Governance decides when to resume minting.
A proposal may name any registered component, but execution requires an active one: a newly
added, deactivated or already written-off component must be reactivated first. Governance
judges whether a write-off is warranted; the contract does not prove the issuer is broken.

The permanent history and reversible exclusion are separate. A written-off token:

- can be reactivated for normal backing by governance;
- can never be rescued or removed, including after reactivation;
- remains available for per-token liquidation claims automatically if transfers/readability
  recover, without reactivation or another governance operation.

Governance may remove an ordinary component only under the same empty/dust rule. Exclusion
alone never permits removal of meaningful funds. Removed residues become foreign tokens, and
so does any later issuer recovery of a removed token: it is outside the claim system.
`basketVersion` increases on addition/removal, not activation or write-off. Positional limits
must match this version and current array length. This is intentional: the version protects
address/index mapping, not a frozen price or active set. `maxAmountsIn` and `minShares` protect
mint economics; `minAmountsOut` protects redemption. Redemption minima are positional only when
one is positive: minima that are all zero, or an empty array, limit nothing, so neither the
version nor the length is checked, and a change of version, which a hostile governance could
repeat throughout a notice, cannot refuse such a redemption. Activating funded backing after a
quote with a zero input cap reverts with `AmountInAboveMax`. Excluding a component after
quoting a positive output minimum reverts with `AmountOutBelowMin`, even though the version
matches. A caller supplying loose/zero limits accepts the corresponding changes. Governance can
change initial amounts at any time, but they affect only bootstrap. `setInitialAmounts`
requires at least one positive amount on an active component when it is called; a later
deactivation, write-off or removal can leave none, and bootstrap then reverts with
`EmptyBasket` until governance sets new amounts.

Dust tolerance is bounded, not a general removal guarantee. Large donations can still obstruct
removal; broken metadata or balance reads can also prevent an ordinary removal. The delayed
write-off remains available for an active component and retains the token's slot permanently.
An excluded component cannot be written off without reactivation; while excluded, mint,
redemption and swaps never call it.

## Rebalancing and price guard

Only the appointed rebalancer may `swap(sell, sellAmount, buy, buyAmount, guardData)`, and only
in normal mode with positive supply. Both tokens must be registered, distinct and active, and
both amounts positive. A swap cannot silently reactivate a written-off or newly added
component. Sell amount cannot exceed its live balance. The vault pulls the buy token, measures
the receipt with mint's tolerance, calls its guard, and sends the sell amount only after
approval. Every failure reverts the entire exchange. `guardData` reaches the guard unchanged
and the vault never reads it, so a later guard can take prices signed by an oracle (a pull
oracle) without a new vault; the rebalancer chooses those bytes, so such a guard must
authenticate them. `ChainlinkPriceGuard` ignores them.

The vault and guard must be deployed as a compatible pair. `IPriceGuard.checkSwap` is called
after the buy tokens have arrived and before the sell tokens leave. In `ChainlinkPriceGuard`,
pre-swap value is reconstructed by subtracting the measured buy receipt **in token units
before valuation**. Incoming purchase and outgoing inventory cannot both inflate the weekly
denominator. Excluded components do not count. Donations received before the exchange do
count, because they back GRET.

The guard enumerates component addresses and reads each priced, active token separately.
Each balance read and each valuation gets 200,000 gas, and only the first word of an answer
is copied. A balance read that reverts, answers with less than one word or needs more gas,
or an unusable price, contributes zero, making the loss fraction more conservative. It does
not call the aggregate `reserves()` view, which is unavailable during mutation.

Guard limits and price assumptions:

- Sell value rounds up, buy value down. Missing, nonpositive, future or stale feeds reject
  swaps involving that token. Each feed quotes a whole token in USD.
- A trade may lose at most 2% of sell value. Each loss is divided by the priced pre-trade
  backing, rounded up; the sum must be at most 2% during each fixed seven-day Unix epoch.
  Fair/favorable trades do not consume the budget. Deposits/withdrawals do not reset it.
- The guard has no owner; feeds, max ages, cached token decimals and limits are immutable.
  Every valuation reads the token's decimals again: a token whose decimals differ from the
  cached ones cannot be valued while they differ, so swaps of it revert and it counts as zero
  in the vault's priced backing until its decimals return or another guard is applied.
  A replacement continues the weekly count: the vault records the guard it replaced as
  `previousPriceGuard`, and on its first loss in a week the new guard starts from what that
  guard recorded in the same week. A predecessor that reports another week, or does not
  answer `currentWeek` and `weeklyLoss` with one word each within 200,000 gas, counts as
  zero. The seven-day notice lets at most one replacement take effect per week, so one
  predecessor is enough.
  Losses on both sides of a week boundary can still reach about 4% within seven days.
- Feeds may lag, price an underlying rather than the token's market peg, or become stale on
  weekends. A split or multiplier change alters what one unit of a token is worth when the
  issuer applies it, not when its feed moves. Six current components lack configured Ethereum
  feeds; they cannot be traded by this guard, so the rebalancer cannot sell them, and while
  GRET is outstanding such a component can stop backing it only through a write-off, which
  keeps its slot. Neither price accuracy nor issuer solvency is guaranteed.

Rebalancer and guard appointments wait seven days and expire seven days later. The proposed
rebalancer accepts its own appointment; anyone may apply a ready guard. Governance may revoke
the rebalancer immediately. The guard cannot be removed, only replaced after the same notice.
Proposing the guard in place applies it again: within the week it keeps its own count, and it
inherits nothing from an earlier week. The notice gives holders time to redeem, skipping a
component if necessary. A captured governance can appoint a malicious guard after the notice.
The notice binds an address: a guard or component behind an upgradeable proxy can change its
behavior later without one.

## Fees and governance

Both fees start at zero and are capped at 500 basis points. A `proposeFees` call in which
neither fee rises applies immediately and discards any pending raise. One that raises either
fee delays both values: anyone may apply it after seven days and within the following seven.
Positive fees require a nonzero recipient distinct from the vault. Mint fees split the paid
issuance; redemption fees transfer GRET to that recipient and only the remainder is burned,
except that redeeming the whole supply pays no fee. Fees round up, so a positive rate never
charges nothing; a mint whose fee would take every share reverts with `ZeroShares`. A
redemption whose fee takes every share, such as 1 wei under a positive fee when it is not the
whole supply, still pays that fee but burns and sends nothing; a positive `minAmountsOut`
refuses it. Liquidation has no fees. Fee rounding and the minimum supply can affect very small
positions.

Governance may pause minting, activate liquidation, manage component lifecycle and initial
amounts, configure fees and their recipient, rescue permitted tokens, and appoint the guard,
rebalancer, eligibility contract or its own successor. Governance succession is two-step: the
proposed address must accept after seven days and within the execution window. There is no
governance-contract assumption beyond being able to call the vault. No arbitrary external-call
or upgrade function exists. Proposals can be cancelled; revocation removes the pending
rebalancer too. A governance handover keeps every pending proposal: the new governance cancels
what it does not want, and proposals that anyone or the proposed rebalancer can execute stay
executable through their windows.

The seven-day waits are enforced by the vault itself, not left to an external timelock such
as OpenZeppelin's `TimelockController` or `AccessManager`. An external contract's delays are
set by whoever administers it, so they would hold only while governance keeps them; the vault's
own waits hold whoever governs, and they let some powers stay immediate (pausing minting,
revoking the rebalancer, removing the eligibility contract, liquidation) while others wait. A
timelock can still sit on top as the governance address.

`rescue(token,to,amount)` may transfer foreign tokens at any time, including during
liquidation. For a registered ordinary component, active or excluded, it works only while
normal supply is zero. It never rescues a component in liquidation or a historically
written-off token. While supply is positive, active income and excluded balances cannot be
redirected by calling them surplus; in liquidation, neither can late claim distributions.
Removing a component under the dust rule explicitly changes it to foreign status. A rescue
reads every component balance before its transfer and, after it, reads again every other
component whose first read was positive, reverting with `ComponentBalanceReduced` if any of
them fell, so a second address over a component's ledger, which an issuer upgrade could create,
cannot move registered backing. Each read gets 200,000 gas and copies only the first word of
the answer. A component whose read reverts, answers with less than one word or needs more gas
counts as zero before the transfer, so it is not compared; neither it nor an oversized answer
blocks rescues of other tokens.

### Eligibility contract

Without an eligibility contract, anyone may mint and redeem. Governance may appoint one with
`proposeEligibility`; anyone applies it with `applyEligibility` after the seven-day notice and
within the execution window, and governance can remove it at once with `removeEligibility`.
Like the guard, it must be a contract other than the vault and not an EIP-7702 account.

Once appointed, `mint` asks `canMint(caller, to)` and both redemptions ask `canRedeem(caller,
to)`, where the caller pays or burns and `to` receives. The vault asks with a read-only call
and only an explicit `true` passes: a revert, a malformed answer or one that runs out of gas
refuses, whatever gas the caller sends. GRET transfers, liquidation, swaps and `rescue` never
ask it. It is asked in the middle of a mint or a redemption, so the vault's guarded views
(`reserves`, the previews, `pendingRights`, `claimable`) revert inside it and its answer
refuses; storage views such as `components`, `excluded` and GRET balances remain readable.

It follows how tokenized-asset issuers restrict their primary market: only approved parties
create and redeem with the issuer, while the tokens trade freely elsewhere. Starting open
keeps that choice for later without a new vault, and the notice gives holders that a new
contract would refuse time to redeem first.

### How governance grows without changing the vault

The vault fixes what governance can do: activate liquidation, manage activation/exclusion,
rescue permitted tokens, change the basket, write off components, set bounded fees, and appoint
the rebalancer, guard, eligibility contract and successor. How governance decides can change
independently. The following progression is a **proposal**, not a deployed governance system:

1. The pilot wallet initially governs. A Safe multisig is the proposed next step, with
   threshold/signers and key recovery to be chosen; it can act immediately in emergencies.
2. The Safe can appoint an OpenZeppelin `TimelockController` using the vault's seven-day,
   two-step handover. The proposed Safe is its sole proposer and executor initially.
3. A Governor using a separate **VORA** voting token may become a timelock proposer. VORA's
   distribution, delegation, quorum, voting delay/period and timelock delay remain proposals.
   GRET does not acquire votes; the vault still sees the timelock as its governance address.
4. More complex rules, such as a fast emergency-only path, require a separate governance
   contract appointed through the same handover, not a new power inside the vault.

`test/GRETVault.timelock.ts` exercises this handover with the actual `TimelockController`
contract; its "multisig" actor is a stand-in signer, not a particular Safe configuration or an
implemented Governor/VORA system. A timelock alone also delays emergency activation. The
rebalancer, guard and eligibility contract remain independently replaceable after their notice.
A new vault is needed for new vault powers, not for changing who decides under existing powers.

## Emergency liquidation

`activateLiquidation()` permanently closes minting, normal and skipping redemption, swaps,
rescue of registered components and the execution of basket lifecycle changes (adding,
removing, activating, deactivating and writing off components). Proposals, announcements,
appointments, initial amounts and fee settings remain callable, but none of them affects
claims: liquidation has no fees and none of those changes can execute. It requires positive
supply and freezes that denominator in `liquidationSupply`; it performs no token calls.
Governance cannot reverse liquidation.

Any holder may burn GRET with `convertToClaims(shares)`; the eligibility contract is not asked.
`convertedShares[account]` is cumulative and nontransferable. Unconverted GRET remains transferable.
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

A successful nonzero claim stores `nextBasis`, consumes `rights` in both ledgers
(`consumedRights[account][i]` and `totalConsumedRights`), records the requested payout, after
any cut, in `totalPaid`, then transfers it. Failed reads, transfers or minimum-output checks
revert all these changes. Zero converted shares return a zero quote without reading the token.
A zero payout leaves the right unconsumed. `minAmount` lets a holder refuse a cut; a successful
haircut consumes its full nominal right.

This automatically incorporates later income for all frozen shares, including unconverted
shares and accounts that already claimed. After everyone settles, a later receipt can open
new proportional claims. No governance action is needed. The basis is established per
component at its first successful claim, not by a view and not at activation.

Recovery is not targeted compensation. For example, Alice and Bob own halves of 100. Alice
claims 50, the vault loses 25, Bob claims 25, then 25 is recovered. Automatic allocation gives
12.5 more to each before rounding: cumulative payouts 62.5/37.5. No component rescue can
correct this internally; additional compensation requires external funding or voluntary
settlement. A loss before the first successful claim establishes a smaller initial basis
instead.

A reverting or malformed `balanceOf` blocks that component's claim until repaired; the vault
stores no balance to fall back on. Other components remain claimable. Rounding, outgoing token
fees/no-op transfers, unavailable recipients and unconverted contract-held GRET remain
limitations; no guaranteed recovery is promised.

## Views, callbacks and integrations

`reserves()` returns live active balances in normal mode, with zero for excluded components
and no call to them. In liquidation it returns effective nominal bases, including consumed
rights; it is **not** a remaining-token-balance view then.
`liquidationBasis()` exposes only bases established by successful claims without token calls.
`pendingRights`/`claimable` compute effective current rights/payouts for one component.
`governanceProposal`, `rebalancerProposal`, `priceGuardProposal` and `eligibilityProposal`
return the pending successor and the earliest time it can take over, or zero when none is
pending: none was proposed, or the last one was executed or cancelled. Like `componentReadyAt`,
`writeOffReadyAt` and `pendingFeesReadyAt`, they keep a proposal until it is executed,
cancelled or replaced, also after it expires at `readyAt + EXECUTION_WINDOW`, when it can no
longer execute.

Activation, the mint pause and eligibility removal emit their events only on a change. Other
setters emit on every successful call, even when nothing changes: `revokeRebalancer` emits
`RebalancerChanged` when there is no rebalancer, `setFeeRecipient` and `proposeFees` emit
`FeeRecipientChanged` and `FeesChanged` with unchanged values, and re-appointing the current
rebalancer, guard, eligibility contract or governance emits `RebalancerChanged`,
`PriceGuardChanged`, `EligibilityChanged` or `GovernanceTransferred` with equal previous and
next addresses. Monitors compare the values instead of counting events.

`reserves`, both normal previews, the skipping preview, `pendingRights` and `claimable` use
`nonReentrantView`: callback consumers cannot read an intermediate accounting state. Mutations
use the transient reentrancy guard. Storage-only membership, exclusion and
`previousPriceGuard` views remain available to the price guard. Ordinary ERC-20 views alone
are not a NAV oracle; integrations must not reconstruct prices from raw in-flight token
balances and supply.

## Implementation details

- Solidity 0.8.38, Hardhat 3, TypeScript ESM, viem and `node:test`; Solidity cases/fuzzing use
  forge-std. GRET is an immutable 18-decimal ERC-20, "Global Reserve Token" / "GRET", with
  EIP-2612 `permit` (EIP-712 domain name "Global Reserve Token", version "1").
- Constructor amounts are positive and configurable later. Local demo amounts of one whole
  unit per component are placeholders, not portfolio recommendations. Prefer initial amounts
  of at least about 10,000 base units so one unit of rounding is a small relative change.
- Initial issuance is exactly one GRET before fees. Subsequent receipts are measured; mint
  returns net `minted` and actual `received`. Exact input tokens produce the requested gross
  issuance; rounding tokens can reduce it. The caller pays a mint and burns a redemption;
  `to` receives the GRET or the components, and a redemption to zero or to the vault reverts.
- There is no normal reserve ledger. Every active required balance is read before input or
  output transfers. Unreadable/reverting/malformed balances fail closed. Explicitly excluded
  or skipped tokens are not called. Initial amounts of zero are omitted during bootstrap.
- Contributions and fee shares round up; withdrawals round down. A component payout that
  rounds to zero is not transferred. An empty contributing basket cannot issue shares.
- No transaction deadline is enforced. Input/output/share limits bound economics despite
  live income/losses, activation, fees or swaps changing a previously observed ratio. Tight
  limits may revert; a quote is not a reservation of a balance or basket state.
- `ReentrancyGuardTransient` relies on Cancun/EIP-1153. It guards mint, both redemptions,
  swaps, rescue, liquidation activation, conversion and claims, component list/state mutations,
  initial amounts and `applyFees`. Sensitive accounting views reject callbacks. Proposals and
  cancellations (including an immediate fee reduction through `proposeFees`), appointments of
  the rebalancer, guard and eligibility contract, the governance handover (`acceptGovernance`),
  the fee recipient, the mint pause, rebalancer revocation and eligibility removal are not
  guarded: they transfer no tokens and retain their authorization checks. A reduction made by
  governance from a callback can only lower the fee of a mint in progress. GRET transfers
  cannot change already converted rights and cannot send GRET to the vault.
- The liquidation denominator is frozen once, but bases are established separately at the
  first successful claim. Storage for consumed nominal rights differs from actual requested
  payouts; neither implies full compensation for a later issuer recovery. Failure reverts the
  entire claim. An outgoing token's actual delivery may differ from requested payout.
- `reserves()` is a bulk external-token read and may revert if any required balance is
  unreadable. Integrations that need partial availability must query per component; they must
  not substitute zero as if it were a verified NAV. For exits use an explicit
  `previewRedeemSkipping`/`redeemSkipping` choice or independent liquidation claims.

## Security requirements

Avoiding a vault bug that immobilizes all working assets is a design priority. An emergency
boolean alone is not a recovery guarantee.

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
  timing, different claim orders, minters/secondary holders, last exits, rounding and
  donations. Without an eligibility contract, healthy exits must remain possible without
  cooperation from other holders or the admin, except the last GRET that the supply floor holds
  back (see Known limitations); with one, they also depend on its rules, which take effect only
  after a notice that lets holders leave first.
- Tests, randomized sequences and reviews reduce risk; they do not prove the absence of bugs.
  An independent audit is pending before third-party funds. Mocks and fork observations
  cannot promise compatibility with future issuer upgrades.

## Operating assumptions

The code does not enforce these. The design assumes that governance and the rebalancer follow
them, and an assessment of the vault should take them as part of its trust model.

- **Admit components with care.** No transfer fees, callbacks or second addresses over the same
  balances; at least 8 decimals, since the dust and receipt allowances are fixed in base units;
  for a token that converts amounts to shares, a multiplier below about ten, since each
  transfer can arrive up to about one multiplier of base units short; and a usable Chainlink
  feed if the component will be rebalanced. Mocks do not prove an issuer's compatibility; the
  mainnet fork tests do.
- **Monitor issuers, balances and prices.** Watch issuer notices and corporate actions,
  component balances against mint, redemption, swap and claim flows, `LossRecorded`, and each
  priced token's market price against its feed. Revoke the rebalancer after an unexpected loss
  or a depeg, and before a scheduled split, multiplier change or any other change of what one
  unit of a priced component represents; propose it again only once the feed prices the new
  unit. `Minted` and `Redeemed` list amounts by position, and a removal moves the components
  after it, so match those amounts to tokens by replaying `ComponentAdded` and
  `ComponentRemoved` in log order. Income paid in another token or requiring an issuer claim is
  not counted automatically.
- **Time distributions.** Before a known distribution or multiplier change, consider pausing
  minting so that entrants right before it do not share it; earlier entrants still do. A
  multiplier change also requires revoking the rebalancer, as above. A split that would take a
  share-converting component's multiplier above about ten requires selling the component out or
  writing it off first.
- **Send swaps privately.** The rebalancer sends every `swap` through a private RPC, so nobody
  can redeem or mint around it in the same block.
- **Write off only what stopped working.** Cancel a pending write-off if the component
  recovers; after one executes, reactivate the recovered balance before resuming minting.
- **Keep the basket tidy.** Sell material remainders and retire sold-out components promptly,
  atomically when the caller allows it. Update the initial amounts after basket changes, and
  before resuming minting from zero supply decide who owns the balances left in the vault.
- **Re-add recovered components.** A removed component that recovers before liquidation must be
  announced, added and activated again. During liquidation it cannot rejoin: rescue it and
  distribute it outside the vault, recording each payment.
- **Reconcile liquidation.** Reconstruct conversions and payouts from `ConvertedToClaims` and
  `Claimed`. `Claimed` records the payout requested from the token, so a transfer that moves
  nothing looks like a full payment: compare each claim with what the token actually moved.
  Recoveries are shared pro rata, so any targeted compensation for a cut is settled outside the
  vault.
- **Govern with a recoverable key.** Before third-party funds, a Safe multisig with a tested
  recovery procedure governs.
- **Configure feeds to their heartbeat.** Each guard feed's `maxAge` follows that feed's update
  interval, so a stale price refuses swaps without blocking them in normal operation.

## Known limitations

These are accepted consequences of the design, not defects. A change to any of them is a
design decision and must be made here first.

- **Governance holds broad powers.** At once it can activate the irreversible liquidation,
  pause or resume minting, reactivate components, rescue foreign tokens, change the fee
  recipient, lower fees, revoke the rebalancer and remove the eligibility contract. Resuming
  minting and reactivating together can take a written-off component's recovery: in one
  transaction, a governance that ignores the operating assumption on write-offs resumes
  minting, mints without paying for the excluded component, reactivates it and redeems, taking
  nearly all of what recovered. Holders' claim on a written-off balance therefore rests on that
  assumption. After seven days' notice it can appoint a rebalancer with a guard that accepts
  every swap and exchange the reserves for anything, add or write off components, raise fees up
  to 5%, appoint an eligibility contract that refuses mint and redemption, and hand over
  governance. Removing empty components and adding announced ones change `basketVersion`, so a
  hostile governance that announced enough tokens a week earlier can make every redemption with
  a positive minimum revert with `BasketChanged` throughout a notice. Redemptions whose minima
  are all zero are not tied to the version, but accept whatever swaps the guard allows until
  they execute. An announced token can join and be activated at once; if its calls fail, every
  exit that does not skip it reverts; an exit prepared in advance avoids this for seven days by
  listing every token announced and waiting, at most 128, and every component the holder does
  not want, excluded ones included, since governance can reactivate those at once. If the
  governance key is lost, nobody can activate liquidation, reactivate components, change the
  basket, revoke the rebalancer, propose a new guard or replace governance, while proposals
  made before the loss stay executable through their windows. Redemption keeps working unless
  an eligibility contract was appointed or proposed before the loss, and minting keeps working
  until a write-off proposed earlier is executed or the last holder leaves by skipping, which
  pauses it for good.
- **The rebalancer chooses the price within the guard's view.** The guard bounds only the
  losses its feeds can see. Feeds may lag within their deviation thresholds, price an
  underlying while the token trades below it, or go stale. A split or multiplier change makes
  one unit of a token worth a different amount from the moment the issuer applies it, while its
  feed follows the market: until both agree, the guard misprices the token by the split ratio,
  a swap that looks fair records no loss, and one swap can take a whole reserve. Revoking the
  rebalancer before such a change prevents it. Weeks are fixed epochs, so losses on both sides
  of a boundary can reach about 4% within seven days. A guard behind an upgradeable proxy can
  change its rules after its notice.
- **Allocation follows timing.** Whoever holds GRET when value arrives shares it: future
  income, a favorable swap, a reactivated component or an asset another holder skipped. A
  holder can redeem before a losing swap and return afterwards. A last skipping exit pauses
  minting; once governance resumes it, the next bootstrap owns all remaining active balances,
  including later donations. A write-off pauses minting, but if
  governance resumes it before reactivating the component, the entrants in between share its
  recovery.
- **An eligibility contract keeps its own rules.** The notice binds its address, not the
  rules inside it, so one whose owner can change its list at once can refuse holders without
  notice; holders should read a proposed contract during its notice. A broken one refuses mint
  and redemption until governance removes it, and with the governance key lost they stay
  refused; selling GRET remains.
- **The supply floor can hold back the last holders.** A fraction of GRET held elsewhere, from
  a tiny mint or as fee GRET, keeps the others from redeeming the last GRET normally until it
  is handed over; whoever then holds every GRET leaves without a fee. It may never be handed
  over: anyone can mint a few wei of GRET for a few base units of each component and send them
  to an address that cannot move them, and the last GRET, at most 1 GRET in aggregate, then
  leaves only through liquidation, which only governance can activate. Liquidation lets every
  holder exit.
- **Minimums bound what the vault sends, not what arrives.** A token that charges the
  recipient delivers less than `minAmountsOut` or `minAmount`, and a token that reports a
  transfer without moving anything still consumes the claimed right.
- **The receipt tolerance is fixed in base units.** A component may arrive up to ten base units
  short in a mint or a swap. A token that converts amounts to shares can arrive up to about one
  multiplier of base units short, so once its multiplier exceeds about ten, part of all mints,
  and of all swaps that buy it, revert with `UnexpectedBalance` whatever their size, until the
  component is sold out and deactivated or written off. After a severe loss leaves only a few
  units of a rounding component, those units bound the issuance and the minter overpays the
  other components; `minShares` lets the minter refuse. The check adds the tolerance to what
  arrived, so a request within ten units of the largest `uint256` reverts with an arithmetic
  panic even when everything arrives; no real token comes near that amount.
- **A small mint can revert on a nearly empty rounding component.** While such a component keeps
  only a few units, a small mint asks it for one or two, which a token that converts amounts to
  shares can deliver as nothing; the mint reverts until the remainder is sold or the component
  excluded.
- **A token that debits the vault more than it sends** takes the difference from the remaining
  holders' backing, and the last exit of that component can fail even in liquidation. Swaps are
  included: the vault sends the requested sell amount and the guard values that amount, so a
  sell token that debits the vault more takes the difference without the guard seeing it.
  Checking the vault's balance after every outgoing transfer was rejected: on exits it would
  add a read to every redemption and claim, and on swaps as on exits it would cover one
  behavior among the many an issuer controls, which the operating assumptions already keep out
  of the basket.
- **Issuers control their tokens.** A freeze, an upgrade, an expensive call or an unreadable
  balance can block normal mint and redemption until holders skip the component or governance
  writes it off; its liquidation claim waits until reads and transfers recover. A written-off
  component keeps its slot for good, so repeated issuer failures can fill the 128 slots and
  leave no room for new components. The 128-component cap cannot bound arbitrary issuer code.
- **Dust and donations.** One unsolicited base unit makes an active zero-balance component
  required again. A donation can front-run a removal; for a token that cannot be sold, a
  donation above the dust allowance leaves a write-off, which keeps the slot forever, as the
  only way to exclude it. Excluding a component automatically once sold out was rejected:
  every rotation through it would then need governance to reactivate it, while
  `deactivateEmptyComponent` already excludes it at once. In liquidation, a balance where every
  pending payout rounds to zero stays until more arrives.
- **Initial amounts are upkeep.** Adding, removing or writing off a component changes only that
  component's entry (a new one starts at zero, a removed one leaves, a written-off one is
  cleared) and does not rebalance the others. Initial amounts matter only when the supply
  returns to zero: a restart then contributes the old weights, and if no active component has a
  positive initial amount the first mint reverts with `EmptyBasket` until governance sets them.
- **Some liquidation rights may never be paid.** Rights over a component that never transfers
  again stay pending, and GRET held by contracts that cannot call `convertToClaims` stays
  unconverted. Late recoveries are shared pro rata, not targeted to whoever took a cut.
- **The vault cannot change.** A fix or a new power requires a new vault and a voluntary
  migration.

## References

Primary references considered: [xStocks multipliers](https://docs.xstocks.fi/developers/multipliers),
[Backed share conversion](https://github.com/backed-fi/backed-token-contract/blob/main/contracts/BackedAutoFeeTokenImplementation.sol),
[Reserve Folio live basket accounting](https://github.com/reserve-protocol/reserve-index-dtf/blob/main/contracts/Folio.sol)
and [OpenZeppelin donation/rounding analysis](https://docs.openzeppelin.com/contracts/5.x/erc4626).
GRET is not an ERC-4626 implementation. No third-party architecture was copied as a substitute
for GRET's issuer-failure and per-component emergency requirements.

## Roadmap and open items

These items are proposals: none is approved, implemented or part of a deployment plan.

- Independent audit and issuer/fork verification before third-party funds.
- Governance implementation and key recovery; the current governance is a wallet.
- Feed coverage, market-peg monitoring and guard improvements, such as a cap on the value that
  swaps which look fair can move, which would also bound a mispricing the feeds do not see.
- Deploying this source, and any migration from the October 27 pilot, requires a concrete
  deployment and funding plan.
