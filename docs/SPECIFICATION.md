# GRET specification

Updated on November 3, 2026. This document states what the contracts in `contracts/` must do.
The current source has not been deployed. The pilot vault deployed on Ethereum mainnet on
October 27, 2026 runs an earlier, immutable version, which kept a recognized-reserve ledger
updated by governance `sync`; [PILOT.md](PILOT.md) records that deployment.

## Overview

`contracts/GRETVault.sol` is both the GRET ERC-20 and its basket vault. It supports proportional
in-kind mint/redemption, per-component emergency claims, basket changes, fees and guarded
rebalancing. There are no upgrades. `ChainlinkPriceGuard.sol` limits swaps using Chainlink
prices. Mint, redemption and liquidation use token quantities, not prices.

The scope is a mainnet pilot with the project's own funds, not an offering to third parties.
The current basket has 11 components; configuration and verified addresses are in
`scripts/pilot/config.ts`. Target dollar weights do not fix quantities per GRET. The current
pilot governance is a wallet. The proposed progression is Safe, then a timelock, then a
Governor with a separate VORA voting token; those contracts and voting parameters are not
implemented or decided. GRET carries no votes.

The contracts have not been independently audited. Mocks are not proof of issuer
compatibility; fork results are specific to their block and code versions.

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
  of this issuance. `maxAmountsIn` and `minShares` bound user cost and net issuance.
- **Receipt tolerance:** each requested component must deliver a positive amount no larger
  than requested and no more than ten base units short (`MAX_RECEIPT_SHORTFALL`). The minter
  absorbs rounding, not existing holders. Larger transfer fees revert. Receipts are measured
  even though backing is live.
- **Eligibility:** a wallet that completes a mint may redeem normally, including GRET acquired
  later. Eligibility does not transfer with GRET. A mint must contribute every active component
  with a positive balance (at bootstrap, with a positive initial amount); zero issuance and an
  empty backing basket are rejected.
- **Normal redemption:** calculate outputs from all required live balances before sending any
  token. The fee is transferred in GRET; the remainder is burned for
  `floor(burnedShares * B[i] / S)` per component. Every transfer must succeed atomically.
  Minimum outputs bound requested transfers, not the recipient's actual balance increase.
- **Skipping:** `redeemSkipping` never calls listed tokens or excluded components, even for
  `balanceOf`. Their outputs and minima must be zero. Skipped assets remain for other holders,
  or, if supply empties, for a later bootstrap once governance resumes minting; the exiting
  holder retains no separate right.
  `previewRedeemSkipping` quotes this exit without calling skipped tokens.
- **Supply floor:** normal redemption leaves either zero or at least `MIN_SUPPLY = 1e18`.
  Fee shares remain outstanding, so a positive redemption fee prevents a full normal exit.
  Liquidation permits conversion below that floor and eventually zero unconverted supply.
- **Mint pause only:** governance can pause/resume minting immediately; executing a write-off
  and a skipping redemption that leaves zero supply also pause it. Normal redemption is never
  paused. A secondary-market holder who never minted cannot qualify while paused.
- GRET transfers to the vault itself revert; otherwise shares are ordinary transferable ERC-20
  tokens, including unconverted GRET during liquidation.

A minter pays against the full current backing, including income already received. Entering
before a future gift, before an excluded token is reactivated, or before another holder skips
an asset still shares that later allocation.

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
write-off already had its notice, and an empty deactivation needs none; reactivation does not
require another wait. If governance resumes minting while a funded component is excluded,
entrants in between do not pay for it but share it once it is reactivated.

`deactivateEmptyComponent(token)` excludes an empty component immediately. A nonzero residue
is allowed only if it is at most `MAX_REMOVAL_DUST = 10` base units and the token reports at
least 18 decimals. Tokens with fewer decimals must be exactly empty: a few whole indivisible
assets must not be discarded as dust. This prevents incidental receipts from reactivating a
sold-out token. Deactivation keeps the initial amount, which bootstrap ignores while the
component is excluded. An active zero-balance token otherwise becomes required again when it
receives anything; that may block a minter unable to transfer it.

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
mint economics; `minAmountsOut` protects redemption. Activating funded backing after a quote
with a zero input cap reverts with `AmountInAboveMax`. Excluding a component after quoting a
positive output minimum reverts with `AmountOutBelowMin`, even though the version matches.
A caller supplying loose/zero limits accepts the corresponding changes. Governance can change
initial amounts at any time, but they affect only bootstrap. `setInitialAmounts` requires at
least one positive amount on an active component when it is called; a later deactivation,
write-off or removal can leave none, and bootstrap then reverts with `EmptyBasket` until
governance sets new amounts.

Dust tolerance is bounded, not a general removal guarantee. Large donations can still obstruct
removal; broken metadata or balance reads can also prevent an ordinary removal. The delayed
write-off remains available for an active component and retains the token's slot permanently.
An excluded component cannot be written off without reactivation; while excluded, mint,
redemption and swaps never call it.

## Rebalancing and price guard

Only the appointed rebalancer may `swap(sell, sellAmount, buy, buyAmount)`, and only in normal
mode with positive supply. Both tokens must be registered, distinct and active, and both
amounts positive. A swap cannot silently reactivate a written-off or newly added component.
Sell amount cannot exceed its live balance. The vault pulls the buy token, measures the
receipt with mint's tolerance, calls its guard, and sends the sell amount only after
approval. Every failure reverts the entire exchange.

The vault and guard must be deployed as a compatible pair. `IPriceGuard.checkSwap` is called
after the buy tokens have arrived and before the sell tokens leave. In `ChainlinkPriceGuard`,
pre-swap value is reconstructed by subtracting the measured buy receipt **in token units
before valuation**. Incoming purchase and outgoing inventory cannot both inflate the weekly
denominator. Excluded components do not count. Donations received before the exchange do
count, because they back GRET.

The guard enumerates component addresses and reads each priced, active token separately.
A reverting balance read or unusable price contributes zero, making the loss fraction more
conservative. It does not call the aggregate `reserves()` view, which is unavailable during
mutation. Malformed successful return data can still revert valuation.

Guard limits and price assumptions:

- Sell value rounds up, buy value down. Missing, nonpositive, future or stale feeds reject
  swaps involving that token. Each feed quotes a whole token in USD.
- A trade may lose at most 2% of sell value. Each loss is divided by the priced pre-trade
  backing, rounded up; the sum must be at most 2% during each fixed seven-day Unix epoch.
  Fair/favorable trades do not consume the budget. Deposits/withdrawals do not reset it.
- The guard has no owner; feeds, max ages, cached token decimals and limits are immutable.
  A replacement continues the weekly count: the vault records the guard it replaced as
  `previousPriceGuard`, and on its first loss in a week the new guard starts from what that
  guard recorded in the same week. A predecessor that reports another week, or does not
  answer `currentWeek` and `weeklyLoss` with one word each, counts as zero. The seven-day
  notice lets at most one replacement take effect per week, so one predecessor is enough.
  Losses on both sides of a week boundary can still reach about 4% within seven days.
- Feeds may lag, price an underlying rather than the token's market peg, or become stale on
  weekends. Six current components lack configured Ethereum feeds; they cannot be traded by
  this guard. Neither price accuracy nor issuer solvency is guaranteed.

Rebalancer and guard appointments wait seven days and expire seven days later. The proposed
rebalancer accepts its own appointment; anyone may apply a ready guard. Governance may revoke
the rebalancer immediately. The guard cannot be removed, only replaced by another contract
after the same notice. The notice gives eligible holders an exit using skipping if
necessary. A captured governance can appoint a malicious guard after the notice.

## Fees and governance

Both fees start at zero and are capped at 500 basis points. A `proposeFees` call in which
neither fee rises applies immediately and discards any pending raise. One that raises either
fee delays both values: anyone may apply it after seven days and within the following seven.
Positive fees require a nonzero recipient distinct from the vault. Mint fees split the paid
issuance; redemption fees transfer GRET to that recipient and only the remainder is burned.
Liquidation has no fees. Fee rounding and the minimum supply can affect very small positions.

Governance may pause minting, activate liquidation, manage component lifecycle and initial
amounts, configure fees and their recipient, rescue permitted tokens, and appoint the guard,
rebalancer or its own successor. Governance succession is two-step: the proposed address must
accept after seven days and within the execution window. There is no governance-contract
assumption beyond being able to call the vault. No arbitrary external-call or upgrade function
exists. Proposals can be cancelled; revocation removes the pending rebalancer too.

`rescue(token,to,amount)` may transfer foreign tokens at any time, including during
liquidation. For a registered ordinary component, active or excluded, it works only while
normal supply is zero. It never rescues a component in liquidation or a historically
written-off token. While supply is positive, active income and excluded balances cannot be
redirected by calling them surplus; in liquidation, neither can late claim distributions.
Removing an eligible dust component explicitly changes that component to foreign status.

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

`test/GRETVault.timelock.ts` exercises this handover with the actual `TimelockController`
contract; its "multisig" actor is a stand-in signer, not a particular Safe configuration or an
implemented Governor/VORA system. A timelock alone also delays emergency activation. The
rebalancer and guard remain independently replaceable after their notice. A new vault is
needed for new vault powers, not for changing who decides under existing powers.

## Emergency liquidation

`activateLiquidation()` permanently closes minting, normal and skipping redemption, swaps,
rescue of registered components and the execution of basket lifecycle changes (adding,
removing, activating, deactivating and writing off components). Proposals, announcements,
appointments, initial amounts and fee settings remain callable, but none of them affects
claims: liquidation has no fees and none of those changes can execute. It requires positive
supply and freezes that denominator in `liquidationSupply`; it performs no token calls.
Governance cannot reverse liquidation.

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

`reserves`, both normal previews, the skipping preview, `pendingRights` and `claimable` use
`nonReentrantView`: callback consumers cannot read an intermediate accounting state. Mutations
use the transient reentrancy guard. Storage-only membership, exclusion and
`previousPriceGuard` views remain available to the price guard. Ordinary ERC-20 views alone
are not a NAV oracle; integrations must not reconstruct prices from raw in-flight token
balances and supply.

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
- `ReentrancyGuardTransient` relies on Cancun/EIP-1153. It guards mint, both redemptions,
  swaps, rescue, liquidation activation, conversion and claims, component list/state
  mutations, initial amounts and `applyFees`. Sensitive accounting views reject callbacks.
  Proposals and cancellations (including an immediate fee reduction through `proposeFees`),
  appointments, the fee recipient, the mint pause and rebalancer revocation are not guarded:
  they transfer no tokens and retain their authorization checks. A reduction made by
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
  timing, different claim orders, minters/secondary holders, last exits, rounding and donations.
  Healthy exits must remain possible without cooperation from other holders or the admin.
- Tests, randomized sequences and reviews reduce risk; they do not prove the absence of bugs.
  An independent audit is pending before third-party funds. Mocks and fork observations
  cannot promise compatibility with future issuer upgrades.

## Known limitations

These are accepted consequences of the design, not defects. A change to any of them is a
design decision and must be made here first.

- **Governance holds broad powers.** At once it can activate the irreversible liquidation,
  pause minting, reactivate components, rescue foreign tokens, change the fee recipient, lower
  fees and revoke the rebalancer. After seven days' notice it can appoint a rebalancer with a
  guard that accepts every swap and exchange the reserves for anything, add or write off
  components, raise fees up to 5% and hand over governance. Removing empty components and adding
  announced ones change `basketVersion`, so a hostile governance can make redemptions prepared
  for a fixed version revert with `BasketChanged`. If the governance key is lost, nobody can
  activate liquidation, reactivate components, change the basket or replace governance;
  redemption keeps working, and so does minting until a write-off proposed earlier is
  executed or the last holder leaves by skipping, which pauses it for good.
- **The rebalancer chooses the price within the guard's view.** The guard bounds only the
  losses its feeds can see. Feeds may lag within their deviation thresholds, price an
  underlying while the token trades below it, or go stale. Weeks are fixed epochs, so losses
  on both sides of a boundary can reach about 4% within seven days.
- **Allocation follows timing.** Whoever holds GRET when value arrives shares it: future
  income, a favorable swap, a reactivated component or an asset another holder skipped. A
  holder can redeem before a losing swap and return afterwards. A last skipping exit pauses
  minting; once governance resumes it, the next bootstrap owns all remaining active balances,
  including later donations. A write-off pauses minting, but if
  governance resumes it before reactivating the component, the entrants in between share its
  recovery.
- **Qualifying for normal redemption requires a mint.** A holder who never minted cannot
  qualify while minting is paused, including after a write-off until governance resumes it, or
  while an active component with a positive balance cannot be transferred in; selling,
  transferring to a wallet that minted or liquidation remain.
- **The supply floor can hold back the last holders.** A fraction of GRET held elsewhere, from
  a tiny mint or as fee GRET, keeps the others from redeeming the last GRET normally. While the
  redemption fee is positive, normal redemption never empties the supply. Liquidation lets
  every holder exit.
- **Minimums bound what the vault sends, not what arrives.** A token that charges the
  recipient delivers less than `minAmountsOut` or `minAmount`, and a token that reports a
  transfer without moving anything still consumes the claimed right.
- **A token that debits the vault more than it sends** takes the difference from the
  remaining holders' backing, and the last exit of that component can fail even in
  liquidation.
- **Issuers control their tokens.** A freeze, an upgrade, an expensive call or an unreadable
  balance can block normal mint and redemption until holders skip the component or governance
  writes it off; its liquidation claim waits until reads and transfers recover. The
  128-component cap cannot bound arbitrary issuer code. In the guard, malformed balance data
  stops every swap with a loss.
- **Dust and donations.** One unsolicited base unit makes an active zero-balance component
  required again. A donation can front-run a removal; for a token that cannot be sold, a
  donation above the dust allowance leaves a write-off, which keeps the slot forever, as the
  only way to exclude it. In
  liquidation, a balance where every pending payout rounds to zero stays until more arrives.
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
- Feed coverage, market-peg monitoring and guard improvements (counter continuity across
  replacements and token-decimal changes).
- Deploying this source, and any migration from the October 27 pilot, requires a concrete
  deployment and funding plan.
