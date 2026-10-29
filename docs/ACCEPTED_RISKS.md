# Accepted risks

Updated on October 29, 2026. Changes since the
[October 27, 2026 review](audits/2026-10-27-GRETVault-review.md), from a second internal review:
R-02, R-09 and P-5 widen their scope (the week of a guard replacement, a positive redemption
fee, pausing before a write-off can be executed); R-03, R-14 and R-15 correct how feeds and a
broken `balanceOf` are described; R-01, R-06, R-08, R-18, P-1 and P-2 add detail. No risk was
removed or renumbered.

The October 29 sequence review expands R-04 and adds R-25, with operational mitigations
accepted by the project owner: P-2 and P-7 cover the recovery exceptions, and P-13 prevents
zero-supply liquidation. The vault remains unchanged. Scope and validation are recorded
under [Review evidence](#review-evidence--october-29-2026).

This document lists every known risk of `GRETVault` and `ChainlinkPriceGuard` that was
consciously accepted, with the reason and what mitigates it. Issues that were fixed are not
listed: the protections are in the code and in
[`test/GRETVault.protections.t.sol`](../test/GRETVault.protections.t.sol). The contracts have had
internal reviews, not an independent audit.

Identifier legend:

| Prefix | Meaning | Example |
| --- | --- | --- |
| `R` | **Risk**: an accepted risk of the protocol | `R-04` |
| `P` | **Policy**: an operating rule for governance that the vault does not enforce | `P-2` |

Numbers are stable identifiers within each prefix, not severity levels or review numbers.
A risk can refer to several policies, and a policy can mitigate several risks; `R-04` and
`P-4` are not automatically related. Historical review references use a separate scheme:
`M` means Medium, `L` Low and `I` Informational severity (for example, `REVIEW2-L03` is a
Low finding from the second review, not risk `R-03`).

Each risk has a stable ID. Where a test reproduces the accepted behavior, it is in
[`test/GRETVault.risks.t.sol`](../test/GRETVault.risks.t.sol) and named after the ID; if a
decision changes, its entry and its test change with it. The cases found by the
[October 28, 2026 review](audits/2026-10-28-GRETVault-review.md) are in
`test/GRETVault.review2-*.t.sol`, named after that review's findings (`test_M01_…`), which
its summary maps to these risks. Mitigations that depend on
governance's conduct are in the [operating policy](#operating-policy) at the end.

## Summary

| ID | Risk | Who can cause it | Worst case |
| --- | --- | --- | --- |
| [R-01](#r-01--governance-holds-broad-powers-and-its-key-can-be-stolen-or-lost) | Governance holds broad powers | Whoever controls governance | After a 7-day notice, the reserves exchanged for anything |
| [R-02](#r-02--the-rebalancer-chooses-the-price-within-the-guards-limits) | The rebalancer chooses the price | The rebalancer or a thief of its key | 2% of each GRET's value per week (4% in the week of a guard replacement) until revoked |
| [R-03](#r-03--the-price-guard-is-only-as-good-as-its-feeds) | The guard is only as good as its feeds | A rebalancer, when a token trades below its feed | The priced healthy reserves, until revoked |
| [R-04](#r-04--governance-decides-what-happens-to-surpluses-and-recoveries) | Governance decides on surpluses and recoveries | Governance; issuer incidents and claim order | Distributions kept or recoveries allocated away from the holders who took a cut |
| [R-05](#r-05--a-token-with-two-addresses) | A token with two addresses | Governance, after an issuer change | A whole component |
| [R-06](#r-06--governance-can-write-off-a-healthy-component) | Writing off a healthy component | Governance | Late minters share in that component |
| [R-07](#r-07--pausing-minting-stops-new-holders-from-qualifying-for-redemption) | A mint pause stops new holders from qualifying | Governance or an issuer | A holder who never minted cannot redeem during a notice |
| [R-08](#r-08--whoever-mints-before-a-sync-shares-in-it) | Whoever mints before a sync shares in it | Anyone who can mint the basket | Most of a distribution or recovery |
| [R-09](#r-09--the-1-gret-floor-can-hold-back-the-last-holders) | The 1 GRET floor can hold back the last holders | Anyone who mints a fraction; the fee recipient; a positive redemption fee | Just under 1 GRET held back; 1 GRET while the redemption fee is positive |
| [R-10](#r-10--minimums-bound-what-the-vault-sends-not-what-arrives) | Minimums bound what is sent, not what arrives | An issuer | Less than the minimum received |
| [R-11](#r-11--the-mint-tolerance-is-fixed-in-base-units) | The mint tolerance is fixed in base units | A rounding component | A minter overpays the healthy components |
| [R-12](#r-12--issuers-control-their-tokens) | Issuers control their tokens | Issuers | A component lost to holders |
| [R-13](#r-13--a-component-that-takes-more-from-the-vault-than-it-sends) | A component takes more than it sends | An issuer | The last holder cannot withdraw that component |
| [R-14](#r-14--a-broken-balanceof-makes-a-loss-first-come-first-served) | A broken `balanceOf` makes a loss first come, first served | An issuer | Later holders bear the whole shortfall |
| [R-15](#r-15--a-token-can-become-expensive-or-call-back) | A token can become expensive or call back | An issuer | One token stops normal redemption |
| [R-16](#r-16--dust-left-after-selling-a-whole-reserve-blocks-removal) | Dust after a whole sale blocks removal | Any minter | One more swap |
| [R-17](#r-17--written-off-components-keep-their-slot-forever) | Written-off components keep their slot | Repeated issuer failures | No room for new components |
| [R-18](#r-18--any-contract-can-be-announced-as-a-component) | Any contract can be announced | Governance | A useless or hostile component, with notice |
| [R-19](#r-19--initial-amounts-can-go-stale-after-basket-changes) | Initial amounts can go stale | Nobody | No restart from zero supply until updated |
| [R-20](#r-20--a-dust-reserve-of-a-rounding-token-can-make-small-mints-revert) | A dust reserve can make small mints revert | Nobody | Small mints revert until the dust is sold |
| [R-21](#r-21--liquidation-dust-that-no-claim-can-take) | Liquidation dust no claim can take | Nobody | A few base units stuck |
| [R-22](#r-22--some-rights-are-never-paid-in-liquidation) | Some rights are never paid in liquidation | An issuer; holders that are contracts | Rights left pending for good |
| [R-23](#r-23--the-vault-cannot-change) | The vault cannot change | Nobody | A bug or a new rule needs a new vault |
| [R-24](#r-24--fees-round-down) | Fees round down | Anyone | Operations of a few wei pay no fee |
| [R-25](#r-25--empty-liquidation-strands-a-written-off-recovery) | Empty liquidation strands a written-off recovery | Governance activating after the last normal exit | The entire recovered component without an exit through the vault |

## Governance and rebalancing

### R-01 — Governance holds broad powers, and its key can be stolen or lost

- **What can happen.** At once, governance can activate the irreversible liquidation, pause
  minting, rescue surpluses (R-04), change the fee recipient, cut fees and revoke the
  rebalancer. With 7 days' notice it can appoint a rebalancer together with a price guard that
  accepts every swap, and then exchange the reserves for anything; add or write off
  components; raise fees up to 5%; and hand governance over. If its key is lost, nobody can
  activate liquidation, sync, change the basket or replace governance; mint and redemption keep
  working. Liquidation has no fast guardian: it takes as long as governance's own timelock.
- **Who can cause it.** Whoever controls the governance address: in the pilot, the pilot
  wallet, an EOA.
- **Worst case.** After the 7-day notice, the reserves exchanged for worthless tokens. At once,
  an unwanted end of normal operation, in which holders still claim everything per component.
- **Why it is accepted.** Someone has to change the basket and handle emergencies. Every power
  that can take value waits 7 days, visible on chain; the powers it has at once cannot take
  reserves.
- **Mitigation.** During the notice, wallets that minted can redeem, skipping any component
  made to fail (see R-07 for those that never minted). A hostile governance can delay those
  exits: with announced or zero-reserve components it can change `basketVersion` again and
  again, so redemptions prepared for a fixed version revert with `BasketChanged`; one sent
  from a contract that reads the version when it executes goes through. Governance moves to a
  Safe multisig with a recovery procedure before third-party funds (P-12).
- **Evidence.** `test_R07_pauseKeepsNonMinterInDuringNotice` ends with that drain.

### R-02 — The rebalancer chooses the price, within the guard's limits

- **What can happen.** The rebalancer sets both amounts of every swap. The price guard bounds
  what swaps can lose against its feeds: 2% of the value sold per swap and 2% of the vault's
  value per week, in fixed 7-day periods. Each loss counts as the share of the vault it takes
  at that moment, which is what every GRET loses, so deposits and withdrawals during the week do
  not stretch the weekly limit. The vault is valued by what it actually holds of each reserve,
  so a balance an issuer took and nobody has recognized yet does not stretch it either.
- **Who can cause it.** The rebalancer, or whoever steals its key.
- **Worst case.** With an honest `ChainlinkPriceGuard`, 2% of the value behind each GRET per week,
  or 4% in a row across the change of week, until governance revokes the rebalancer. The weekly
  count lives in each guard and a newly applied guard starts at zero, so in the week of a
  replacement the two guards allow up to 4%, and about 6% in a row across the change of week;
  if governance proposes the next guard as soon as one is applied, chained replacements allow
  about 7.8% within 7 days. Anyone can apply a ready guard, so a hostile rebalancer chooses that
  moment. Losses the feeds do not see are not limited (R-03). A captured governance can instead
  appoint a guard that accepts everything (R-01).
- **Why it is accepted.** Prices cannot be exact with thin liquidity. A cap on volume was
  rejected because it would also block a large legitimate rebalance. A budget that refills
  gradually would close the 4% case, at the cost of more code.
- **Mitigation.** Revoking the rebalancer needs no wait. P-6, P-8, including around a guard
  replacement.
- **Evidence.** `test_priceGuardStopsRebalancerDrain`,
  `test_priceGuardLimitHoldsAfterTemporaryDeposit`, `test_priceGuardLimitShrinksWithRedemptions`
  and `test_priceGuardIgnoresBalanceTheVaultNoLongerHolds` in the protections; [`test/ChainlinkPriceGuard.fuzz.t.sol`](../test/ChainlinkPriceGuard.fuzz.t.sol),
  with deposits and withdrawals between the swaps.

### R-03 — The price guard is only as good as its feeds

- **What can happen.** The guard sees only what its feeds report. A feed of the underlying (SPY
  for SPYx; the fund's price times Ondo's multiplier for the Ondo tokens) keeps pricing a token
  that trades far below it, after a depeg or a problem at the issuer. A swap that buys that
  token at the feed price records no loss: neither limit applies, and no `LossRecorded` is
  emitted. The same holds for a written-off component: `swap` does not refuse to buy it, and the
  purchase gives it a reserve again without a `sync`. Feeds also update on a deviation threshold
  (0.5%; 2% for cbBTC): a swap at a feed price that is off by up to that threshold loses the
  difference unrecorded, on top of both limits. Between two feeds the gap can reach the sum of
  their thresholds, and it can be taken again on every swap while a feed lags: it is bounded by
  the volume swapped, not by the weekly limit. A token without a feed cannot be swapped, so it
  can never be sold or removed: today
  ITOTon, EFAon, IEMGon, JAAAx, VNQon and DBCon, half of the basket's weight. The equity feeds
  follow US market hours; on weekends their prices go stale and those swaps stop.
- **Who can cause it.** A rebalancer, or a thief of its key, that buys the cheap token on the
  market and swaps it into the vault.
- **Worst case.** Value: the healthy reserves the guard lets be sold, today those of the five
  priced tokens, exchanged for the token that lost its value, until governance revokes the
  rebalancer. It is not bounded by R-02. Availability: half of the basket cannot be rebalanced
  until feeds exist.
- **Why it is accepted.** The feeds available for these tokens price the underlying or the
  fund; checking each token's own market price would need another oracle and more code.
  Refusing a swap that cannot be priced is safer than trusting it.
- **Mitigation.** Watch each priced token's market price against its feed and revoke the
  rebalancer at once if they part (P-8); `LossRecorded` does not show this case. A new guard
  with more feeds when Chainlink adds them, with the 7-day notice; choose components with that
  in mind (P-10).
- **Evidence.** `test_R03_depegTheFeedDoesNotSeeIsNotLimited`;
  [`test/ChainlinkPriceGuard.ts`](../test/ChainlinkPriceGuard.ts) ("refuses tokens it cannot
  price…", "refuses a token without a feed, and a stale…"); the guard test on the mainnet
  fork.

### R-04 — Governance decides what happens to surpluses and recoveries

- **What can happen.** What the vault holds above its recognized reserves is surplus, and
  governance syncs it to the holders or rescues it: issuer distributions, recoveries of
  recognized losses and, in liquidation, balance that comes back after claims took a cut.
  A claim during a shortfall consumes the whole right; a later recovery does not recreate
  that claimant's entitlement to the cut. A removed component's balance is outside the
  basket and fully rescuable. Written-off tokens are never rescuable, even after recovery.
  That permanent flag prevents P-2's direct compensation of a later liquidation haircut:
  `sync` allocates the surplus to all holders rather than only those who took a cut.
  Separately, a removed component cannot rejoin during liquidation, so its recovery must
  use P-7's external distribution instead of re-addition and sync.
- **Who can cause it.** Governance can retain surplus. A prior write-off, subsequent issuer
  loss and recovery, and different claim times can also cause unequal compensation with
  entirely cooperative governance. The redistribution requires multiple holders; a sole
  holder receives the whole synced recovery.
- **Worst case.** Governance keeps distributions as an effective fee, or a recovered loss
  benefits holders other than those who bore it. For example: two equal holders are owed
  5 tokens each; after a prior write-off and full recovery, liquidation begins, 5 of the
  10 tokens disappear, and Alice claims 2.5. All 5 return, but rescuing the 2.5 surplus to
  Alice is forbidden. Syncing it leaves Alice with 3.75 and Bob with 6.25. All assets are
  accounted for, but Alice is not made whole. With Bob holding `k` times Alice's shares
  and Alice's haircut `c`, approximately `c * k / (k + 1)` goes to Bob, within rounding.
- **Why it is accepted.** Individual recovery rights would add accounting inside liquidation.
  The permanent rescue prohibition protects written-off assets from governance withdrawal.
  The pilot retains that design and handles recovery allocation operationally under P-2
  and P-7. An external settlement requires cooperation; the vault does not guarantee it.
- **Mitigation.** P-1, P-2, P-3 and P-7. Reconstruct losses and payouts before distributing a
  recovery; for a written-off token, sync and reconcile any compensation externally rather
  than attempting a forbidden rescue. For a removed token recovered during liquidation,
  rescue and distribute externally. The empty-liquidation case is separate (R-25).
- **Evidence.** `test_R04_writtenOffRecoveryCannotReimburseHaircut`, its control without a
  prior write-off (which pays 5 to each),
  `testFuzz_R04_syncTransfersPartOfCompensationToWaitingHolder`, and
  `test_R04_removedRecoveryCannotRejoinLiquidation` in
  [`GRETVault.risks.t.sol`](../test/GRETVault.risks.t.sol). The last test verifies the failed
  re-addition and sync, followed by successful rescue. Also see the existing governance
  surplus tests and liquidation shortfall tests in `GRETVault.governance.ts` and
  `GRETVault.liquidation.ts`.

### R-05 — A token with two addresses

- **What can happen.** `rescue` recognizes components by address. If an issuer gave a component
  a second address over the same balance, as happened with TUSD, governance could rescue the
  whole reserve through it.
- **Who can cause it.** Governance, after an issuer change.
- **Worst case.** A whole component.
- **Why it is accepted.** It needs both an issuer change and a governance willing to steal.
  None of the 11 components has a second address.
- **Mitigation.** P-10.

### R-06 — Governance can write off a healthy component

- **What can happen.** Governance judges whether a component is broken; the vault only enforces
  the 7-day wait, and anyone can execute a ready write-off during its window. Writing off a
  healthy component drops its reserve to zero until a `sync` brings it back. A contract can
  execute a ready write-off and mint without that component in the same transaction, so a mint
  pause sent after the write-off comes too late.
- **Who can cause it.** Governance, or anyone if governance forgets to cancel a ready write-off.
- **Worst case.** Whoever mints in between shares in that component when it is synced (R-08).
- **Why it is accepted.** Governance gains nothing directly: it can never rescue the token, and
  `sync` undoes the write-off. A check by the vault itself could be fooled both ways and was
  removed. A captured governance can already do more with a rebalancer.
- **Mitigation.** P-5.
- **Evidence.** [`test/GRETVault.rebalancing.ts`](../test/GRETVault.rebalancing.ts) ("works on a
  healthy component too, and sync undoes a mistaken write-off");
  `test_R08_lateMinterCapturesWriteOffRecovery`.

## Entering and exiting

### R-07 — Pausing minting stops new holders from qualifying for redemption

- **What can happen.** Normal redemption requires a mint from the same wallet. Governance can
  pause minting at once and for as long as it wants; meanwhile, a holder who bought or received
  GRET cannot qualify. A frozen component with a positive reserve has the same effect until it is
  written off, because the qualifying mint must contribute it.
- **Who can cause it.** Governance, with the pause; an issuer, with a freeze.
- **Worst case.** During the notice of a hostile rebalancer, such holders can only sell, hand
  their GRET to a wallet that minted, or wait for a liquidation.
- **Why it is accepted.** Both rules stay: redemption remains for wallets that proved access to
  the whole basket by minting, and a pause that let new wallets mint would not serve its
  purpose. In the pilot the only holder is the pilot wallet, which minted.
- **Mitigation.** In a liquidation anyone can exit.
- **Evidence.** `test_R07_pauseKeepsNonMinterInDuringNotice`,
  `test_R07_frozenComponentKeepsNonMinterFromQualifying`.

### R-08 — Whoever mints before a sync shares in it

- **What can happen.** Mint prices shares from the recognized reserves, so value that has
  arrived but is not synced is left out of the price. Whoever mints before the `sync` of a
  distribution or of a written-off component that recovered, or before a swap favorable to the
  vault, and redeems after it, takes part of that value. A pause around the `sync` only stops
  those who arrive after the pause. The same holds for the share a `redeemSkipping` leaves
  behind: it would become surplus if the redemption emptied the supply, but whoever mints just
  before keeps the supply from emptying and takes all of it when the one skipping was the last
  holder, or its proportional part otherwise. Conversely, a holder who redeems
  before a swap that loses value and mints after it pushes its share of that loss onto the
  others, within the guard's limits.
- **Who can cause it.** Anyone who can mint the basket, above all someone who already holds it
  and can mint and redeem in kind at no other cost.
- **Worst case.** Most of a distribution or recovery, in proportion to what the entrant brings.
- **Why it is accepted.** Giving accrued value to past holders on chain needs snapshots or
  recovery claims: new accounting. A gradual release does not stop a holder of the basket, who
  can hold GRET through it.
- **Mitigation.** P-4 (above all, a mint fee around 0.1% once third parties can mint), P-5, P-6.
- **Evidence.** `test_R08_minterCapturesMostOfASync`,
  `test_R08_pauseAroundSyncDoesNotStopEarlierEntrant`,
  `test_R08_lateMinterCapturesWriteOffRecovery`.

### R-09 — The 1 GRET floor can hold back the last holders

- **What can happen.** A normal redemption cannot leave the supply between 0 and 1 GRET. If
  someone keeps a fraction of GRET, from a tiny mint or as fee GRET held by the recipient, the
  others can redeem only until 1 GRET remains. While the redemption fee is positive, redemption
  never empties the supply: each one leaves its fee in it, so at least 1 GRET remains even with
  every GRET gathered in one wallet.
- **Who can cause it.** Anyone who mints a fraction; the fee recipient, by accident; governance,
  by keeping a positive redemption fee.
- **Worst case.** Just under 1 GRET held back from the last holders, or 1 GRET while the
  redemption fee is positive. The bound is in GRET, not in dollars: what backs 1 GRET can grow.
  If governance's key is lost while the redemption fee is positive, nobody can cut the fee or
  liquidate, and that last GRET stays held back for good (R-01).
- **Why it is accepted.** The floor stops rounding dust from distorting the basket near zero
  supply. A seed locked forever at the first mint would remove the dependency, but it would lock
  about the same value forever.
- **Mitigation.** Cutting the redemption fee to zero applies at once. A liquidation lets every
  holder withdraw everything, although it ends that vault. In the pilot the fee recipient is the
  pilot wallet.
- **Evidence.** `test_R09_tinyMintHoldsBackLastHolder`,
  `test_R09_feeRecipientHoldsBackLastHolder`; [`test/GRETVault.fees.ts`](../test/GRETVault.fees.ts)
  ("the recipient's GRET stays in the supply…").

### R-10 — Minimums bound what the vault sends, not what arrives

- **What can happen.** `minAmountsOut` and `claim`'s `minAmount` are checked against what the
  vault sends. A component that charges the recipient delivers less, and a token that reports a
  transfer without moving anything still consumes the claimed right.
- **Who can cause it.** An issuer that changes its token.
- **Worst case.** Less than the minimum received, or nothing for that component in a claim.
- **Why it is accepted.** Checking the recipient's balance would add calls to every exit and
  weaken the exit from a broken token, and a token that lies about transfers can lie about
  balances too. Admitting a component is a matter of trust.
- **Mitigation.** P-10.
- **Evidence.** `test_R10_redeemMinimumIgnoresRecipientFee`,
  `test_R10_noOpTransferStillConsumesClaim`.

### R-11 — The mint tolerance is fixed in base units

- **What can happen.** `MAX_RECEIPT_SHORTFALL` lets a component arrive up to 10 base units short,
  in mints and in what the rebalancer delivers. With only a few units of a component left after
  a severe loss, that shortfall can cost the minter a larger share of the healthy contributions.
- **Who can cause it.** A component that rounds, such as the xStocks.
- **Worst case.** A minter overpays the healthy components. For cbBTC, with 8 decimals, 10 units
  are about one cent.
- **Why it is accepted.** The xStocks lose 2–3 units per transfer, and a fixed tolerance is
  simple.
- **Mitigation.** `minShares` lets the minter refuse the mint. P-10.
- **Evidence.** `test_minSharesRefusesShortfallAfterSevereLoss` in the protections.

## Issuers and tokens

### R-12 — Issuers control their tokens

- **What can happen.** All 11 components are upgradeable. Their issuers can pause, freeze,
  seize, charge or change them, and the vault cannot force a transfer. The mainnet fork tests
  describe the tokens at one block only.
- **Who can cause it.** Issuers.
- **Worst case.** A component lost to the holders.
- **Why it is accepted.** It is inherent to tokenized assets.
- **Mitigation.** Wallets that minted exit with `redeemSkipping`; a write-off restores normal
  operation without the component; a liquidation still pays the others. P-10.
- **Evidence.** [`test/GRETVault.adversarial.ts`](../test/GRETVault.adversarial.ts) ("if the issuer
  freezes the vault…", "if the issuer freezes a holder…").

### R-13 — A component that takes more from the vault than it sends

- **What can happen.** Redemptions, claims and swaps lower the reserve by the amount sent. If an
  issuer upgraded its token to debit the sender more than that, the difference would come out of
  the backing of those who stay, and the last exit of that component could fail even in
  liquidation, because the vault cannot pay the extra. `rescue` checks the backing after a
  transfer; the other paths do not. None of the 11 does it today; the xStocks have a fee
  setting, at zero.
- **Who can cause it.** An issuer.
- **Worst case.** The remaining holders pay the surcharge, and the last one cannot withdraw that
  component.
- **Why it is accepted.** A balance check after every transfer was rejected to keep the contract
  as it is.
- **Mitigation.** Wallets that minted exit with `redeemSkipping`; governance writes the
  component off or sells it. P-10.
- **Evidence.** `test_R13_senderSurchargeComesOutOfRemainingBacking`,
  `test_R13_senderSurchargeBlocksLastClaim`.

### R-14 — A broken `balanceOf` makes a loss first come, first served

- **What can happen.** If a component's `balanceOf` reverts while its transfers work, normal
  redemption and claims go ahead with the recorded reserve. If the real balance is short, the
  first to leave get everything. Running out of gas counts as a revert, so whoever chooses the
  gas limit can force this path when `balanceOf` costs millions of gas. Only a revert is
  tolerated: a `balanceOf` that succeeds with malformed return data, or a component without
  code, makes normal redemption and that component's claims revert; `redeemSkipping` without it
  still works.
- **Who can cause it.** An issuer, or a broken token.
- **Worst case.** The last holders bear the whole shortfall of that component.
- **Why it is accepted.** `balanceOf` tells the vault how much backing remains, which it needs
  to detect a shortfall and share the loss proportionally. A failed balance read does not mean
  transfers must fail too. Instead of blocking the exit when that read reverts, the vault tries
  the transfer using its recorded reserve; if the transfer fails, the operation reverts and the
  holder keeps their GRET or pending claim. This favors being able to exit a broken token over
  sharing a loss proportionally: if the recorded reserve exceeds the actual balance, early
  exits may be paid in full while later holders bear the shortfall.
- **Mitigation.** A write-off.
- **Evidence.** `test_R14_brokenBalanceReadPaysFirstRedeemerInFull`.

### R-15 — A token can become expensive or call back

- **What can happen.** The cap of 128 components was measured with mock tokens: mint 4.2M gas
  and redemption 3.5M, within Ethereum's per-transaction limit of about 16.7M. An issuer upgrade
  could make one token's calls expensive, or make them call back into the vault. During a mint,
  the vault's views can be inconsistent if a component calls back. The price guard reads the
  balance of every priced component on each swap with a loss, so an expensive `balanceOf` there
  also stops swaps; one that reverts only leaves that component out of the vault's value, and
  one that returns malformed data stops every swap with a loss.
- **Who can cause it.** An issuer.
- **Worst case.** One token makes normal redemption no longer fit in a transaction, or stops
  rebalancing.
- **Why it is accepted.** No cap can bound arbitrary external code.
- **Mitigation.** `redeemSkipping` never calls the skipped tokens, and every operation on the
  reserves is protected against reentrancy. Integrations, including future price guards, must
  not trust the vault's views during a component's callback.
- **Evidence.** `test_skippedComponentIsNeverCalled` in the protections;
  [`test/GRETVault.adversarial.ts`](../test/GRETVault.adversarial.ts) (128 components, reentrancy
  from every external call).

## The basket

### R-16 — Dust left after selling a whole reserve blocks removal

- **What can happen.** A swap fixes both amounts, which is its price. Selling "the whole
  reserve" read beforehand leaves a remainder if a mint lands in between, and the remainder
  blocks removing the component.
- **Who can cause it.** Any minter, by accident or on purpose.
- **Worst case.** One more swap.
- **Why it is accepted.** Letting the vault sell "whatever is there" would change the amount
  after the price was set, at the holders' expense.
- **Mitigation.** P-11.
- **Evidence.** `test_R16_mintBeforeWholeSaleLeavesDustThatBlocksRemoval`.

### R-17 — Written-off components keep their slot forever

- **What can happen.** A written-off component can never be removed, so each write-off takes one
  of the 128 places for good.
- **Who can cause it.** Repeated issuer failures.
- **Worst case.** After more than a hundred write-offs, no room for new components.
- **Why it is accepted.** Keeping them lets a recovery return to the holders at once, also during
  liquidation. Clearing the write-off would free the slot only for tokens that come back, and an
  archive outside the active basket would add accounting.
- **Evidence.** `test_writtenOffComponentStaysAndRecoversDuringLiquidation` in the protections.

### R-18 — Any contract can be announced as a component

- **What can happen.** `announceComponent` accepts any address with code, including the vault
  itself or an EIP-7702 account. `proposePriceGuard` likewise only checks for code: the notice
  covers a guard's address, not its code, so a guard behind an upgradeable proxy or an EIP-7702
  account can change its behavior later without notice.
- **Who can cause it.** Governance.
- **Worst case.** A useless or hostile component, after 7 days of notice; then R-01 and R-02.
- **Why it is accepted.** The vault cannot judge tokens. GRET as its own component could never
  get a reserve, since the vault rejects GRET.
- **Mitigation.** The 7-day notice. P-10.

### R-19 — Initial amounts can go stale after basket changes

- **What can happen.** Adding, removing and writing off components do not update the initial
  amounts, which only apply at zero supply. After basket changes they can be stale or all zero.
- **Who can cause it.** Nobody; it is upkeep.
- **Worst case.** If every holder leaves, nobody can mint again until governance sets them.
- **Why it is accepted.** They only matter at zero supply.
- **Mitigation.** P-9.

### R-20 — A dust reserve of a rounding token can make small mints revert

- **What can happen.** If a component that rounds keeps only a few units of reserve, small mints
  might revert. It has not been reproduced.
- **Who can cause it.** Nobody on purpose.
- **Worst case.** Small mints revert until the dust is sold.
- **Why it is accepted.** The rebalancer sells whole reserves and the component is removed.
- **Mitigation.** P-11.

## Liquidation

### R-21 — Liquidation dust that no claim can take

- **What can happen.** If a component's balance falls so low that every pending payout rounds
  to zero, nobody can claim the remainder. It is not surplus either, so it stays in the vault
  until a recovery. Rights cannot be pooled, because they are not transferable.
- **Who can cause it.** Nobody; a loss can leave it.
- **Worst case.** A few base units stuck: with the current components, which have 8 decimals or
  more, a fraction of a cent.
- **Why it is accepted.** Pooling rights, or a mechanism to distribute residues, would add code
  for dust.
- **Mitigation.** P-10.
- **Evidence.** `test_R21_payoutsThatRoundToZeroLeaveUnclaimableDust`.

### R-22 — Some rights are never paid in liquidation

- **What can happen.** A right over a component that never transfers again stays pending for
  good. GRET held by contracts that cannot call `convertToClaims`, such as exchange pools, stays
  unclaimed.
- **Who can cause it.** An issuer; holders that are contracts.
- **Worst case.** Those rights are never paid.
- **Why it is accepted.** Liquidation cannot force a token to move, and contracts must provide
  their own exit.

### R-25 — Empty liquidation strands a written-off recovery

- **What can happen.** A token stops transferring and is written off while minting is
  paused. The last holder redeems all GRET for the healthy components. Governance activates
  liquidation with supply zero, and the token later recovers. Its whole balance is readable
  and transferable, but has no exit through the vault. Activation accepts zero supply;
  `sync` needs a positive `liquidationSupply`, `rescue` permanently refuses the written-off
  token, nobody can acquire claim rights, and minting, swaps and component removal are
  closed. Unpausing or changing initial amounts cannot reverse this state.
- **Who can cause it.** Governance, by activating liquidation after a complete normal exit.
  No hostile governance or broken token at recovery time is required. An arbitrary third
  party cannot burn others' GRET or activate liquidation.
- **Worst case.** The entire recovered balance of that component is stranded through the
  vault, not merely dust. Exceptional intervention by an issuer outside the vault is not
  guaranteed. This is prevention-only: governance cannot repair the state once reached.
- **Why it is accepted.** The sequence is avoidable by retaining outstanding GRET through
  activation. In the own-funds pilot, the holder and governance are the same wallet and
  control this ordering. The owner accepts operational prevention under P-13 without
  replacing the immutable vault; a future code-enforced guard is not required by this decision.
- **Mitigation.** P-13: do not activate with zero supply, and retain GRET controlled by
  governance through activation. A supply read before signing alone is not an atomic
  guarantee when other holders can transact. If the vault is already empty, leave it in
  normal mode while recovery is assessed; a fresh mint is possible there if the initial
  basket is usable. Do not turn that recoverable state into an empty liquidation.
- **Evidence.** `test_R25_emptyLiquidationStrandsWrittenOffRecovery` in
  [`GRETVault.risks.t.sol`](../test/GRETVault.risks.t.sol). Three controls recover the assets:
  activation before the last exit; a fresh mint without liquidation; and rescue from an
  empty liquidation when the token was never written off.

## Limits of the design

### R-23 — The vault cannot change

- **What can happen.** The vault has no upgrades. A bug cannot be fixed in place, and moving to a
  new vault is voluntary: each holder redeems from the old one and mints in the new one. The
  vault cannot adopt an allowlist, identity checks, freezing of holders or a different
  redemption rule, nor act on distributions that must be claimed or on token migrations; only
  what arrives as balance can be synced.
- **Who can cause it.** Nobody; it is a choice.
- **Worst case.** A bug or a new rule requires a new vault.
- **Why it is accepted.** Any power to change the vault would also be a power to act against the
  holders.
- **Mitigation.** Tests, internal reviews, an independent audit before third-party funds, and a
  pilot with the project's own funds.

### R-24 — Fees round down

- **What can happen.** Fees are rounded down, so operations of a few wei pay none.
- **Who can cause it.** Anyone.
- **Worst case.** A fee of a few wei unpaid.
- **Why it is accepted.** Avoiding it costs more gas than it is worth.

## Review evidence — October 29, 2026

One Codex agent reviewed source at `8d4b69cef02e88c059f356d77307014249563ad2`, with no
auxiliary agent or independent verifier. It read the prior disclosures and reviews; this
was not a blind review. Scope: vault and guard source, specification and existing tests,
with new sequences around write-offs, losses, recoveries, last exits and liquidation.
Mocks model hypothetical issuer events, not current behavior of the eleven real tokens.
No mainnet reads, transactions, issuer-source audit, fork run or pilot rehearsal were made.
Production contracts and the dependency lock were unchanged. No new permissionless drain
was found in the examined paths; that is not proof that all paths are safe.

Already disclosed candidates were not counted again: mint-before-sync and skipped-share
capture (R-08), recovered pending write-offs (R-06/P-5), fee/supply-floor interactions
(R-09), interrupted whole-reserve sales (R-16), guard replacements and feed limitations
(R-02/R-03), and adverse token calls (R-10/R-13/R-14/R-15).

The recovery consequences were accepted under R-04 and R-25 with operational mitigations;
no contract changes were adopted. Eight reproduction/control tests were added, now grouped
in `GRETVault.risks.t.sol` under
`GRETVaultRecoveryRisksTest`. The full check passed 232 tests (104 Solidity, 128 Node.js);
the recovery suite passed its deep profile with 20,000 fuzz cases varying holder ratios
from 1 to 100 and losses from 1 to 9,999 bps. No fresh coverage or full deep-suite result
is claimed. These observations do not establish that a finding occurred on mainnet.

Reproduce the consolidated suite:

```sh
npm run check
npm test -- --grep 'R04_|R25_' test/GRETVault.risks.t.sol
npm test -- --test-profile deep --grep 'R04_|R25_' test/GRETVault.risks.t.sol
```

## Operating policy

Agreed conduct for governance, which the vault does not enforce. Each point mitigates the risks
that cite it.

- **P-1.** Sync every recovery of a recognized loss (`LossRecognized` events) instead of rescuing
  it. The event names the component by index, which a removal shifts: map it to a token by
  replaying `ComponentAdded` and `ComponentRemoved` in log order up to that event, not by
  reading the component list at that block. Apply P-2's compensation procedure and P-7's
  removed-component exception when relevant. (R-04)
- **P-2.** In liquidation, reconstruct each claimant's cut from `rights − amount` in
  `Claimed` events and reconcile actual token delivery. A transfer reporting success without
  moving tokens is not visible as a cut in that event. When a recovered balance is available
  as surplus, rescue it to compensate cuts without paying anyone more than their uncompensated
  loss; the rest is ordinary surplus. **For a token ever written off**, rescue is forbidden:
  compute the allocation before syncing, sync the recovery, and reconcile the resulting
  overpayments and shortfalls externally with the affected holders. Keep a settlement ledger
  to prevent duplicate compensation. Returning another holder's excess requires their
  cooperation; neither governance nor the vault can force it, and full compensation is not
  guaranteed. With a sole holder the entire synced recovery returns to that holder. (R-04)
- **P-3.** Sync issuer distributions that arrive as balance, such as xStocks multiplier
  increases: they belong to the holders. `rescue` is for what does not belong to them, such as
  mistaken transfers. (R-04)
- **P-4.** Around every `sync`: pause minting before it and resume it after; send it through a
  private RPC (Flashbots Protect, MEV Blocker or similar); sync as soon as a surplus appears, so
  each `sync` is small; once third parties can mint, keep a mint fee around 0.1%, larger than a
  quarterly dividend's share of the basket; and if a timelock is added, only the Safe executes
  its operations, since a timelocked `sync` is visible during its delay. (R-08)
- **P-5.** Write off only a component that stopped working, and cancel a pending write-off as
  soon as the token recovers. Pause minting before a write-off becomes executable, since it can
  be executed and followed by a mint in the same transaction, and keep it paused while a
  written-off component may recover; sync the recovered balance at once through a private RPC.
  When the last holders leave with `redeemSkipping`, pause minting first, so the skipped share
  becomes surplus instead of going to a late minter. Sync still requires positive normal or
  liquidation supply; follow P-13 before activating liquidation. (R-06, R-08, R-25)
- **P-6.** Send every `swap` through a private RPC. (R-02, R-08)
- **P-7.** If a component removed after a total loss gets its balance back before
  liquidation, add it again and sync it instead of rescuing it. **During liquidation**,
  re-addition is impossible: rescue the recovered token and distribute it externally to the
  entitled holders. Reconstruct and record the allocation from the GRET and claim history,
  including holders who have not converted, and record each payment to avoid paying twice.
  Do not delay an otherwise needed liquidation merely to wait for re-addition. (R-04)
- **P-8.** Watch the price guard's `LossRecorded` events, and the market price of every priced
  token against its feed. Revoke the rebalancer at once after a loss nobody expected, or when a
  token trades away from its feed. (R-02, R-03)
- **P-9.** Update the initial amounts (`setInitialAmounts`) as part of every basket change.
  (R-19)
- **P-10.** Admit components carefully and watch their issuers: no transfer fees, callbacks or
  second addresses; 8 decimals or more, unless R-11 and R-21 are revisited; a Chainlink feed if
  the component must be rebalanced. (R-03, R-05, R-10 to R-15, R-18, R-21)
- **P-11.** Sell a whole reserve with a second small swap if a remainder is left, and remove
  components whose reserve was sold. (R-16, R-20)
- **P-12.** Before third-party funds, governance is a Safe multisig with a tested recovery
  procedure. (R-01)
- **P-13.** Activate liquidation only with positive supply. When liquidation is intended,
  keep GRET controlled by governance, without granting others authority to spend that balance,
  until activation confirms; do not redeem or transfer that last position beforehand. Check
  the supply before signing as well. With other holders, that read alone does not prevent a
  complete exit before execution; the retained governance position prevents supply reaching
  zero in between. If supply is already zero, do not activate: assess recovery in normal mode,
  where a fresh mint may restore the ability to sync. This prevents R-25; it cannot undo an
  empty liquidation already activated. (R-25)
