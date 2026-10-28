# Accepted risks

Updated on October 28, 2026. Changes since the
[October 27, 2026 review](audits/2026-10-27-GRETVault-review.md), from a second internal review:
R-02, R-09 and P-5 widen their scope (the week of a guard replacement, a positive redemption
fee, pausing before a write-off can be executed); R-03, R-14 and R-15 correct how feeds and a
broken `balanceOf` are described; R-06, R-08, R-18, P-1 and P-2 add detail. No risk was removed
or renumbered.

This document lists every known risk of `GRETVault` and `ChainlinkPriceGuard` that was
consciously accepted, with the reason and what mitigates it. Issues that were fixed are not
listed: the protections are in the code and in
[`test/GRETVault.protections.t.sol`](../test/GRETVault.protections.t.sol). The contracts have had
internal reviews, not an independent audit.

Each risk has a stable ID. Where a test reproduces the accepted behavior, it is in
[`test/GRETVault.risks.t.sol`](../test/GRETVault.risks.t.sol) and named after the ID; if a
decision changes, its entry and its test change with it. Mitigations that depend on
governance's conduct are in the [operating policy](#operating-policy) at the end.

## Summary

| ID | Risk | Who can cause it | Worst case |
| --- | --- | --- | --- |
| [R-01](#r-01--governance-holds-broad-powers-and-its-key-can-be-stolen-or-lost) | Governance holds broad powers | Whoever controls governance | After a 7-day notice, the reserves exchanged for anything |
| [R-02](#r-02--the-rebalancer-chooses-the-price-within-the-guards-limits) | The rebalancer chooses the price | The rebalancer or a thief of its key | 2% of each GRET's value per week (4% in the week of a guard replacement) until revoked |
| [R-03](#r-03--the-price-guard-is-only-as-good-as-its-feeds) | The guard is only as good as its feeds | A rebalancer, when a token trades below its feed | The priced healthy reserves, until revoked |
| [R-04](#r-04--governance-decides-what-happens-to-surpluses-and-recoveries) | Governance decides on surpluses and recoveries | Governance | Distributions or recoveries kept by governance |
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
  made to fail (see R-07 for those that never minted). Governance moves to a Safe multisig
  with a recovery procedure before third-party funds (P-12).
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
  anyone can apply a ready guard, so a hostile rebalancer chooses that moment. Losses the
  feeds do not see are not limited (R-03). A captured governance can instead appoint a guard
  that accepts everything (R-01).
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
  difference unrecorded, on top of both limits. A token without a feed cannot be swapped, so it
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
  recognized losses and, in liquidation, balance that comes back after claims took a cut. A
  claim during a shortfall consumes the whole right, and a later recovery does not return to
  that claimant. A component removed after a loss leaves its balance outside the basket, fully
  rescuable. Written-off tokens are the exception: they are never rescued.
- **Who can cause it.** Governance.
- **Worst case.** Governance keeps distributions or recoveries that belong to the holders,
  which works as a fee.
- **Why it is accepted.** Recovery rights per holder would add state and logic, partly inside
  liquidation, for an unlikely case. Forbidding `rescue` of components was rejected: a
  component sent to the vault by mistake could never be returned, and in liquidation the
  recovery would go to whoever had not claimed yet rather than to those who took the cut.
- **Mitigation.** P-1, P-2, P-3, P-7.
- **Evidence.** [`test/GRETVault.governance.ts`](../test/GRETVault.governance.ts) ("governance
  chooses between sync and rescue for each surplus");
  [`test/GRETVault.liquidation.ts`](../test/GRETVault.liquidation.ts) ("a loss is shared pro
  rata…").

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
  before keeps the supply from emptying and takes part of it. Conversely, a holder who redeems
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
- **Why it is accepted.** Being able to exit a broken token takes priority over sharing the loss
  equally.
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

## Operating policy

Agreed conduct for governance, which the vault does not enforce. Each point mitigates the risks
that cite it.

- **P-1.** Sync every recovery of a recognized loss (`LossRecognized` events) instead of rescuing
  it. The event names the component by index, which a removal shifts: read the component list
  at that block. (R-04)
- **P-2.** In liquidation, use a balance that comes back after claims with a cut to return the
  cuts: rescue it and split it among those who claimed, in proportion to `rights − amount` in
  their `Claimed` events, without exceeding each one's cut. What exceeds the cuts is ordinary
  surplus. A claim whose transfer reported success without moving the tokens records `amount`
  equal to `rights`; only the token's own transfers show it. (R-04)
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
  becomes surplus instead of going to a late minter. (R-06, R-08)
- **P-6.** Send every `swap` through a private RPC. (R-02, R-08)
- **P-7.** If a component removed after a total loss gets its balance back, add it again and
  sync that balance instead of rescuing it. (R-04)
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
