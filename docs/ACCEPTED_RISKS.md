# Accepted risks

Updated on November 2, 2026 for the implemented live-balance design. The immutable
[October 27 mainnet pilot](SPECIFICATION.md#mainnet-pilot) still runs the prior code: local
fixes do not change that deployment. The dated reviews remain historical evidence.

This is the canonical register of accepted risks and their operating mitigations. Stable
IDs are retained when a change fixes a finding: R-14 and R-25 now describe controls, and R-08
distinguishes the closed post-receipt window from remaining timing risks. R-04, R-16 and the
policies below incorporate the consequences of automatic accounting. The contracts have had
internal reviews and tests, not an independent audit. Fixes are also covered by the existing
accounting, protection and subject-specific suites.

Identifier legend:

| Prefix | Meaning | Example |
| --- | --- | --- |
| `R` | **Risk**: a stable finding, with current status in its entry | `R-04` |
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
| [R-04](#r-04--automatic-recovery-is-not-targeted-compensation) | Automatic recovery is not targeted compensation | Issuer incidents and claim order | Recoveries benefit holders other than those who took a cut |
| [R-05](#r-05--a-token-with-two-addresses) | A token with two addresses | Governance, after an issuer change | A whole component |
| [R-06](#r-06--governance-can-write-off-a-healthy-component) | Writing off a healthy component | Governance | Late minters share in that component |
| [R-07](#r-07--pausing-minting-stops-new-holders-from-qualifying-for-redemption) | A mint pause stops new holders from qualifying | Governance or an issuer | A holder who never minted cannot redeem during a notice |
| [R-08](#r-08--allocation-timing-and-excluded-recoveries) | Allocation timing and excluded recoveries | Anyone who can mint the basket | A share of future income or an excluded recovery |
| [R-09](#r-09--the-1-gret-floor-can-hold-back-the-last-holders) | The 1 GRET floor can hold back the last holders | Anyone who mints a fraction; the fee recipient; a positive redemption fee | Just under 1 GRET held back; 1 GRET while the redemption fee is positive |
| [R-10](#r-10--minimums-bound-what-the-vault-sends-not-what-arrives) | Minimums bound what is sent, not what arrives | An issuer | Less than the minimum received |
| [R-11](#r-11--the-mint-tolerance-is-fixed-in-base-units) | The mint tolerance is fixed in base units | A rounding component | A minter overpays the healthy components |
| [R-12](#r-12--issuers-control-their-tokens) | Issuers control their tokens | Issuers | A component lost to holders |
| [R-13](#r-13--a-component-that-takes-more-from-the-vault-than-it-sends) | A component takes more than it sends | An issuer | The last holder cannot withdraw that component |
| [R-14](#r-14--closed-stale-balance-payouts-after-a-broken-balance-read) | Closed: stale-balance payouts | An issuer can still break reads | That component becomes unavailable until recovery or skipping |
| [R-15](#r-15--a-token-can-become-expensive-or-call-back) | A token can become expensive or call back | An issuer | One token stops normal redemption |
| [R-16](#r-16--dust-and-donations-after-a-whole-reserve-sale) | Dust and donations after a whole sale | Any sender or minter | Required contributions or delayed removal |
| [R-17](#r-17--written-off-components-keep-their-slot-forever) | Written-off components keep their slot | Repeated issuer failures | No room for new components |
| [R-18](#r-18--any-contract-can-be-announced-as-a-component) | Any contract can be announced | Governance | A useless or hostile component, with notice |
| [R-19](#r-19--initial-amounts-can-go-stale-after-basket-changes) | Initial amounts can go stale | Nobody | No restart from zero supply until updated |
| [R-20](#r-20--a-dust-reserve-of-a-rounding-token-can-make-small-mints-revert) | A dust reserve can make small mints revert | Nobody | Small mints revert until the dust is sold |
| [R-21](#r-21--liquidation-dust-that-no-claim-can-take) | Liquidation dust no claim can take | Nobody | A few base units stuck |
| [R-22](#r-22--some-rights-are-never-paid-in-liquidation) | Some rights are never paid in liquidation | An issuer; holders that are contracts | Rights left pending for good |
| [R-23](#r-23--the-vault-cannot-change) | The vault cannot change | Nobody | A bug or a new rule needs a new vault |
| [R-24](#r-24--fees-round-down) | Fees round down | Anyone | Operations of a few wei pay no fee |
| [R-25](#r-25--closed-locally-zero-supply-liquidation) | Closed locally: zero-supply liquidation | Old deployed pilot remains exposed | Current activation reverts with `NoSupply` |

## Governance and rebalancing

### R-01 — Governance holds broad powers, and its key can be stolen or lost

- **What can happen.** At once, governance can activate the irreversible liquidation, pause
  minting, reactivate components, rescue foreign tokens (R-04), change the fee recipient, cut fees and revoke the
  rebalancer. With 7 days' notice it can appoint a rebalancer together with a price guard that
  accepts every swap, and then exchange the reserves for anything; add or write off
  components; raise fees up to 5%; and hand governance over. If its key is lost, nobody can
  activate liquidation, reactivate components, change the basket or replace governance; mint and redemption keep
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
  so losses immediately reduce it and income increases it. The incoming swap receipt is
  subtracted before valuation; excluded components do not count.
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
  emitted. Excluded components cannot be bought by the rebalancer. After governance reactivates
  one, a misleading feed can still misprice it. Feeds also update on a deviation threshold
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

### R-04 — Automatic recovery is not targeted compensation

- **What can happen.** Registered active balances, including mistaken transfers, immediately
  back GRET. Governance cannot rescue any registered component while shares exist or during
  liquidation. A successful haircut consumes the full nominal right. Later excess balance
  increases the liquidation basis for all frozen shares, including holders already paid in
  full; it does not reimburse only the holder who took a cut. Each token's basis is established
  at its first successful claim, so losses before that moment lower its initial basis.
  Removed components are foreign tokens and their recoveries remain fully rescuable; they
  cannot rejoin the basket during liquidation. Excluded registered tokens remain protected.
- **Who can cause it.** Issuer losses/recoveries and differing claim times. Governance retains
  allocation discretion for foreign tokens, including removed-component recoveries.
- **Worst case.** Two equal holders own 10 tokens. Alice claims 5; 2.5 disappear; Bob claims
  2.5; the missing 2.5 return. Each gets another 1.25: Alice receives 6.25 and Bob 3.75.
  All assets are accounted for but Bob is not made whole. This occurs without a write-off.
  A mistaken component deposit cannot be returned by governance while holders exist.
- **Why it is accepted.** Keeping individual compensation entitlements would add liquidation
  accounting. Automatic allocation removes governance's discretion over registered income
  and the operational sync window. A sole frozen holder receives the entire recovery.
- **Mitigation.** P-1, P-2, P-3 and P-7. Reconcile compensation externally using independent
  funds or voluntary settlements. The vault cannot force another holder to return an excess.
- **Evidence.** `test_R04_automaticRecoveryIsNotTargetedCompensation`,
  `testFuzz_R04_recoveryRewardsPreviouslyPaidHolder`,
  `test_R04_removedRecoveryCannotRejoinLiquidation` in `GRETVault.risks.t.sol`.
  `test_liveBalance_lazyBasisUsesBalanceAtFirstSuccessfulClaim` and
  `test_liveBalance_paidHoldersCanClaimLateIncomeAutomatically` in the accounting suite.

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
  healthy component excludes its balance until `activateComponent` brings it back. A contract can
  execute a ready write-off and mint without that component in the same transaction, so a mint
  pause sent after the write-off comes too late.
- **Who can cause it.** Governance, or anyone if governance forgets to cancel a ready write-off.
- **Worst case.** Whoever mints in between shares in that component when it is reactivated (R-08).
- **Why it is accepted.** Governance gains nothing directly: it can never rescue the token, and
  reactivation restores backing while retaining the permanent write-off history. A check by the vault itself could be fooled both ways and was
  removed. A captured governance can already do more with a rebalancer.
- **Mitigation.** P-5.
- **Evidence.** [`test/GRETVault.rebalancing.ts`](../test/GRETVault.rebalancing.ts) ("works on a
  healthy component too, and activation restores its backing");
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

### R-08 — Allocation timing and excluded recoveries

- **Status.** The old post-receipt mint-before-sync window is closed for active components.
  A minter pays against their complete live balance, including previously received dividends.
- **What can still happen.** Entering before a future distribution, favorable swap or another
  holder's skipping exit shares the value that arrives later. An excluded token does not
  enter mint pricing until governance reactivates it; new entrants can share that recovery.
  A pause immediately before reactivation cannot remove shares minted earlier. A holder can
  also redeem before a losing swap and return afterwards, avoiding that loss. After the last
  normal exit, the next bootstrap owns all preexisting active balances for the configured
  initial contribution; ordinary components can instead be rescued while supply is zero.
- **Who can cause it.** Anyone able to mint the basket; any sender can add unsolicited balances.
- **Worst case.** A large share of future income, excluded recovery or abandoned assets.
  Donations can also increase required contributions and make a pending exact quote revert.
- **Why it is accepted.** Claims for former holders and dividend record dates require additional
  accounting. A fixed one-GRET bootstrap and the supply floor prevent a donation from forcing
  issuance to round to zero; neither promises entitlement to a past holder who already exited.
- **Mitigation.** P-4, P-5 and P-6. Pause before exclusion and through recovery when appropriate;
  monitor empty-vault restarts. Exact input limits and a fresh quote after approvals bound
  minter spending. Fees are optional economic friction, not a fix for allocation timing.
- **Evidence.** `test_R08_controlLiveDividendCannotBeCaptured` in the protections suite;
  `test_R08_entryBeforeFutureDonationStillSharesIt`,
  `test_R08_lateMinterCapturesWriteOffRecovery`; the accounting suite also fuzzes a donation
  followed by mint/redeem and tests bootstrap ownership of old receipts.

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

- **What can happen.** Redemptions, claims and swaps request a transfer of the quoted amount. If an
  issuer upgraded its token to debit the sender more than that, the difference would come out of
  the backing of those who stay, and the last exit of that component could fail even in
  liquidation, because the vault cannot pay the extra. Live accounting reflects the lower
  balance on the next operation; it does not bound the sender debit of an outgoing transfer.
- **Who can cause it.** An issuer.
- **Worst case.** The remaining holders pay the surcharge, and the last one cannot withdraw that
  component.
- **Why it is accepted.** A balance check after every transfer was rejected to avoid adding issuer-specific transfer accounting.
- **Mitigation.** Wallets that minted exit with `redeemSkipping`; governance writes the
  component off or sells it. P-10.
- **Evidence.** `test_R13_senderSurchargeComesOutOfRemainingBacking`,
  `test_R13_senderSurchargeBlocksLastClaim`.

### R-14 — Closed: stale-balance payouts after a broken balance read

- **Previous finding.** The old reserve fallback could pay an early redeemer in full when
  `balanceOf` reverted despite a real shortfall, leaving the loss to later holders.
- **Current control.** Normal payouts and claims require a successful current balance read.
  A revert, out-of-gas or malformed result cannot select a cached full payout. The operation
  reverts with shares and rights intact. This closes the allocation issue in local code.
- **Remaining limitation.** A component with a broken read is unavailable even if its transfer
  works. Use `redeemSkipping` to leave without that asset, or exclude it after the write-off
  notice. Liquidation activation makes no token calls, and healthy claims remain independent.
  The broken component's claim must wait for readability to recover (R-12, R-15).
- **Evidence.** `test_R14_controlBrokenBalanceCannotOverpayFirstRedeemer` in the protections suite, and the malformed,
  expensive-read and skipping controls in `GRETVault.review2-exits.t.sol` and the accounting
  suite. The deployed pilot retains its former behavior.

### R-15 — A token can become expensive or call back

- **What can happen.** The cap of 128 components is exercised with mock tokens against a transaction gas
  bound. This cannot bound arbitrary issuer code. An issuer upgrade
  could make one token's calls expensive, or make them call back into the vault. Accounting views reject callbacks during mutations. Raw token balances and ordinary
  ERC-20 supply views can still show different stages of a transfer. The price guard reads the
  balance of every priced component on each swap with a loss, so an expensive `balanceOf` there
  also stops swaps; one that reverts only leaves that component out of the vault's value, and
  one that returns malformed data stops every swap with a loss.
- **Who can cause it.** An issuer.
- **Worst case.** One token makes normal redemption no longer fit in a transaction, or stops
  rebalancing.
- **Why it is accepted.** No cap can bound arbitrary external code.
- **Mitigation.** `redeemSkipping` never calls the skipped tokens, and every operation on the
  reserves is protected against reentrancy. Integrations, including future price guards, must
  use compatible accounting views outside mutations, not compose an in-flight NAV themselves.
- **Evidence.** `test_skippedComponentIsNeverCalled` in the protections;
  [`test/GRETVault.adversarial.ts`](../test/GRETVault.adversarial.ts) (128 components, reentrancy
  from every external call).

## The basket

### R-16 — Dust and donations after a whole-reserve sale

- **What can happen.** A fixed-amount swap leaves a remainder if minting or a donation lands
  first. With live balances, even one unsolicited base unit reintroduces an active zero-balance
  token into required contributions, potentially blocking a minter that cannot transfer it.
  A direct donation can also front-run removal. Excluded components cannot be reactivated by
  a donation; governance must call `activateComponent`.
- **Who can cause it.** Any sender or minter, by accident or on purpose.
- **Worst case.** Required contributions, reverting pending quotes, or blocked component
  retirement. When a token cannot be sold (for example, no usable feed or transfer failure),
  a donation above the dust threshold can force a permanent-slot write-off. A tradable token
  can instead be sold again; repeated donations can still race a non-atomic removal.
- **Why it is accepted.** Swaps must not silently change their fixed price. Treating all active
  balances as backing necessarily includes unsolicited transfers.
- **Mitigation.** P-11. Governance may deactivate/remove an empty ordinary component, allowing
  at most ten base units only when token decimals are at least 18. Tokens with fewer decimals
  must be exactly empty. This handles rounding residue, not a larger donation or broken
  metadata. Exclusion alone never permits rescuing or removing a material balance; writing
  it off requires notice and permanently retains the slot and rescue prohibition.
- **Evidence.** `test_R16_mintBeforeWholeSaleLeavesDustThatBlocksRemoval`;
  `test_liveBalance_oneUnitCanReactivateAnActiveZeroBalance`,
  `test_liveBalance_dustRetirementIsBoundedAndCannotBypassWriteOff`,
  `test_liveBalance_removalToleranceCannotDiscardLowDecimalAssets`,
  `test_R16_donationBlocksRemovalUntilAnotherSale`.

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
  itself or an EIP-7702 account. Additions start excluded, but activation does not validate
  ERC-20 behavior. Removal still needs a readable balance (and decimals for nonzero dust). `proposePriceGuard` likewise only checks for code: the notice
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

### R-25 — Closed locally: zero-supply liquidation

- **Previous finding.** Governance could activate irreversible liquidation after the last
  normal exit. With no frozen shares, a later written-off recovery had no possible claimant
  and remained permanently non-rescuable.
- **Current control.** `activateLiquidation` reverts with `NoSupply` when supply is zero,
  before changing state. An empty vault stays in normal mode, where a bootstrap may restore
  ownership if its active initial basket is usable. The check is atomic with activation.
- **Deployment limitation.** The immutable October 27 pilot still needs P-13; this source
  change cannot repair or modify it. A new deployment and voluntary migration are separate.
- **Evidence.** `test_R25_controlEmptyLiquidationIsRejected` in the protections suite.

## Limits of the design

### R-23 — The vault cannot change

- **What can happen.** The vault has no upgrades. A bug cannot be fixed in place, and moving to a
  new vault is voluntary: each holder redeems from the old one and mints in the new one. The
  vault cannot adopt an allowlist, identity checks, freezing of holders or a different
  redemption rule, nor act on distributions that must be claimed or on token migrations; only
  what arrives as an active component balance is included automatically.
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

## Implementation evidence — November 2, 2026

Live-balance implementation reviewed in the working tree based on
`98a6e35f450a13409a2d2698089e47e9a39ee26e`. Scope: vault, Chainlink guard, component lifecycle,
liquidation, pilot quoting, existing tests and disclosures. One Codex agent, with prior
findings available; no independent audit or auxiliary agent. Historical reproductions were
adapted to current behavior, and closed-finding controls moved into the existing protections
suite. The three stateful suites share one handler with distinct initial states, an independent
physical issuance/loss ledger, non-dilution checks and aggregate/per-holder claim checks.

Final validation: 248 local tests passing (119 Solidity, 129 Node.js) and 119 deep tests
passing, with 20,000 cases per fuzz test and 1,000 sequences of depth 200 per invariant. Pilot
rehearsal passed at mainnet block 26,327,336; all five real-component/feed/rebalancing fork tests
passed at block 26,327,339. Commands ran sequentially with compilation enabled. Exact commands,
fork scope and gas measurements are recorded in
[SPECIFICATION.md](SPECIFICATION.md#validation-and-design-history). No live deployment,
migration, signature or mainnet state-changing transaction was performed. Mock issuer faults
are hypothetical; fork observations do not promise future issuer behavior.

## Historical review evidence — October 29, 2026

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

The following commands run the current consolidated tests, including replacement controls;
they no longer reproduce every historical vulnerable behavior:

```sh
npm run check
npm test -- --grep 'R04_|R25_' test/GRETVault.risks.t.sol
npm test -- --test-profile deep --grep 'R04_|R25_' test/GRETVault.risks.t.sol
```

## Operating policy

Agreed conduct for governance. Code-enforced controls are identified explicitly; the rest
requires operational follow-through. The historical pilot still needs its original sync
procedures until a separately authorized migration; the policies below describe new code.

- **P-1.** Monitor actual component balances and issuer incidents. Normal income and losses no
  longer need recognition calls or `LossRecognized` event reconstruction. Reconcile losses
  and recoveries for P-2; a removed token still needs P-7. (R-04)
- **P-2.** In liquidation, reconstruct consumed rights and requested payouts from `Claimed`
  events and reconcile actual delivery. No-op transfers are not visible as a haircut in that
  event. Automatic recovery is proportional to frozen shares, not uncompensated losses.
  Compute overpayments/shortfalls and settle externally using separate funds or voluntary
  returns; every registered component is non-rescuable during liquidation. Record settlements
  to avoid duplicate compensation. Cooperation and complete reimbursement are not guaranteed.
  With a sole frozen holder, the whole recovery returns to that holder. (R-04)
- **P-3.** Monitor issuer distributions even though active component receipts count automatically.
  Poll component balances and compare them with mint/redemption/swap/claim flows and issuer
  notices; `Synced` and `LossRecognized` no longer provide an event-driven income/loss ledger.
  No sync transaction is needed. Payments in foreign tokens or requiring a separate issuer
  claim remain outside automatic accounting. Mistaken deposits of registered components cannot
  be refunded by rescue while holders or liquidation rights exist. (R-04)
- **P-4.** A post-receipt mint cannot capture an active dividend without paying for it. For
  future distributions, favorable swaps or reactivation, assess timing separately: a pause
  after entry does not undo that entrant's shares. Monitor announced multiplier/dividend
  schedules. For a known external-value distribution, governance should assess and, when
  appropriate, pause minting before the event until the new balance is reflected. The timing
  must be chosen early enough to matter; prior entrants still participate. A mint fee may add
  friction but neither a fixed fee nor a last-minute pause guarantees prevention. Fee increases
  require their existing seven-day notice. Keep input limits and refresh quotes after approvals;
  do not silently increase approvals when balances change. (R-08)
- **P-5.** Write off only a component that stopped working; cancel its pending write-off as
  soon as it recovers. Pause minting before execution becomes possible and keep it paused
  through a relevant exclusion/recovery period. Reactivate recovered normal backing explicitly.
  Liquidation automatically includes registered recoveries without activation. Before the
  last skipping exit, pause and assess ownership of abandoned balances before allowing a
  restart; pausing alone does not preserve an exited holder's rights. (R-06, R-08)
- **P-6.** Send every `swap` through a private RPC. (R-02, R-08)
- **P-7.** If a removed component recovers before liquidation, announce/add it again and then
  activate it. During liquidation re-addition is impossible: rescue the foreign token and
  distribute externally to entitled holders. Reconstruct GRET and claim history, including
  unconverted holders, and record each payment. Do not delay needed liquidation merely to
  wait for re-addition. (R-04)
- **P-8.** Watch `LossRecorded` and each priced token's market price against its feed. Revoke
  the rebalancer after an unexpected loss or depeg. Review budgets across guard replacement
  and week boundaries. Deploy this vault with a guard compatible with live accounting. (R-02, R-03)
- **P-9.** Update initial amounts after basket changes, including active/excluded state. Before
  a zero-supply restart inspect all existing balances and deliberate ownership of them. (R-08, R-19)
- **P-10.** Admit components carefully and monitor issuers: no transfer fees, callbacks or
  second addresses; at least 8 decimals unless R-11 and R-21 are revisited; a usable feed if
  rebalancing is required. Mocks do not prove real-issuer compatibility. (R-03, R-05, R-10 to R-15, R-18, R-21)
- **P-11.** Sell material remainders and promptly remove or deactivate sold-out components.
  Group final sale and retirement atomically when the governing/rebalancing caller supports
  it; otherwise a donation can land between them. The dust exception is at most ten base
  units for tokens with at least 18 decimals; lower-decimal tokens must be empty. Larger
  donations still need a sale or delayed write-off. (R-16, R-20)
- **P-12.** Before third-party funds, use a Safe multisig with a tested recovery procedure. (R-01)
- **P-13.** The new vault atomically rejects zero-supply liquidation. On the old immutable
  pilot, retain governance-controlled GRET until activation confirms and check supply before
  signing; do not activate an already empty vault. A prior read alone is not atomic with
  other holders' exits. This prevents the old R-25 and cannot undo an empty liquidation. (R-25)
