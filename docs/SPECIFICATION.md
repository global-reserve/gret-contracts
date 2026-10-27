# GRET specification

Updated on October 26, 2026.

## Overview

`contracts/GRETVault.sol` is the GRET token and the vault in a single contract: proportional
mint and normal redemption, per-component emergency liquidation, basket changes and
rebalancing, and the permissions of an external governance (activating liquidation, deciding
on surpluses, changing the basket, appointing the rebalancer, the price guard and its own
successor). `contracts/ChainlinkPriceGuard.sol` is the price guard that limits what swaps can
lose.

- GRET represents proportional shares in a reserve of several ERC-20 tokens, minted and
  redeemed in kind over every component.
- Mint, redemption and liquidation use no price oracles, and the reserve is normally passive.
- Governance-authorized rebalancing goes through a single exchange primitive in the vault
  (see [Basket changes and rebalancing](#basket-changes-and-rebalancing)), priced by an
  external guard with Chainlink feeds that limits what swaps can lose.
- Ethereum mainnet is the target network.

Both contracts are tested with mocks on the local Hardhat network and against the 11 real
components on an Ethereum mainnet fork (see [Tests and results](#tests-and-results)). They
have not been independently audited. A mainnet pilot with the project's own funds was
deployed on October 27, 2026 (see [Mainnet pilot](#mainnet-pilot)). The governance
contracts (voting, timelock) and any rebalancing mechanism beyond the vault's `swap` and the
price guard, such as auctions or trading bots, are outside this repository.

The current basket, with its weights, verified addresses and pilot amounts, is in
[Mainnet pilot](#mainnet-pilot) and in
[`scripts/pilot/config.ts`](../scripts/pilot/config.ts). Target weights are value
percentages, not initial amounts per share.

## Core rules

- No upgrades. Fees start at zero and governance can set them within hard-coded caps (see
  [Fees](#fees)). The basket changes only through governance, with the limits in
  [Basket changes and rebalancing](#basket-changes-and-rebalancing).
  Nobody can withdraw the reserves backing GRET without delivering another component in
  exchange, within the limits of the price guard; governance also decides on what exceeds
  those reserves (see
  [Governance](#governance)).
- The initial amount of each component is set when the vault is created. The first
  successful mint contributes that basket and issues exactly **1 GRET** in total. This does
  not fix a price of 1 dollar; the pilot's amounts are in [Mainnet pilot](#mainnet-pilot).
- Later mints are computed in proportion to the reserves and the supply.
- The same wallet contributes the components and receives its GRET. There is no dollar
  minimum and no identity requirement. To enable normal redemption, a mint must complete a
  positive contribution of every component with a positive reserve and issue a positive
  amount of GRET; zero, or a rounding that skips a component, does not prove access to the
  whole basket.
- The mint history stays with that wallet and is not transferred with GRET. The enabled
  wallet can also redeem GRET bought or received later.
- Normal redemption is atomic: if any transfer fails, the whole operation reverts and the
  wallet keeps its GRET.
- **Pausing the mint, never the redemption.** Governance can
  pause and resume minting at once (`setMintPaused`). It helps during an incident and around
  a `sync`. Wallets that already minted can still redeem; a holder who never minted cannot
  qualify while the pause lasts (R-07 in [`ACCEPTED_RISKS.md`](ACCEPTED_RISKS.md)). There is
  no explicit pause of redemptions: it is
  exactly the power to trap holders during the notice of a new rebalancer, and the emergency
  tools are liquidation and write-offs.
- **Redeeming without a failing component.**
  `redeemSkipping(shares, minAmountsOut, skipped)` is the same redemption but leaves out the
  listed components, which are not called at all. The caller gives up its share of them: it
  stays in the reserve for the other holders or, when the redemption empties the supply,
  becomes surplus. Without it, a single component that cannot be sent (an issuer freeze, or a
  token a captured governance syncs in and makes fail) blocks every redemption, so the
  7-day notice of a new rebalancer would give nobody an exit. Keeping the skipped share as a
  pending right for the caller was rejected: it would bring liquidation-style accounting
  into normal operation for an emergency exit.
- **Minimum supply:** a normal redemption cannot leave the supply between 0 and 1 GRET
  (`MIN_SUPPLY`). Either everyone leaves or at least 1 GRET remains. Without this floor,
  whoever held almost the whole supply could redeem down to 1 wei, and the rounding
  leftovers distorted the basket (1 GRET came to require 1e18 units of an 8-decimal
  component), making minting unusable. The last holders with less than 1 GRET between them
  must gather their GRET in one wallet to leave (R-09).
- **Mint by what arrived:** the vault measures what arrives of each component and issues
  GRET for the minimum proportion received, rounded down. It tolerates up to
  `MAX_RECEIPT_SHORTFALL` (10 base units) per component, which covers tokens that convert
  amounts into internal shares (xStocks lose 2–3 wei per transfer). A larger shortfall,
  such as a fee, reverts. The minter absorbs the shortfall; existing holders never lose
  value. `minShares` lets the minter refuse a mint that issues too little (R-11).
- **Recognized losses:** if the vault holds less of a component than its recorded reserve
  (a negative rebase, an issuer fee or seizure), the reserve drops to the actual balance
  with the `LossRecognized` event, and the loss is shared by every holder in proportion.
  Mint and redemption do this automatically before computing, and anyone can call
  `recognizeLoss(i)`. After a total loss of a component, mint stops asking for it, and mint
  and redemption continue without it.
- Tokens that reach the vault outside a mint (donations, positive rebases, distributions)
  are not recognized on their own. Governance decides, surplus by surplus, whether to add
  them to the reserves with `sync(token)`, for the benefit of every holder, or to withdraw
  them with `rescue`. `sync` also works during liquidation. Issuer distributions belong to
  the holders and are synced (P-3 in [`ACCEPTED_RISKS.md`](ACCEPTED_RISKS.md#operating-policy)).
- The vault does not accept GRET: a GRET transfer to its address reverts, so a mistaken
  transfer is not lost and governance never has GRET at its disposal.
- GRET carries no votes. The voting mechanism lives outside the vault.
- The code is public under the MIT license; the license identifier is part of the source
  verified on Etherscan.
  Internal handoff notes stay out of the repository.

## Basket changes and rebalancing

The product must live in one contract for its whole life, whether the basket has 11
components or 19, and be able to rebalance without migrating holders. Holders' GRET and the
reserves stay protected by the rules below; the price of each exchange is chosen by the
rebalancer and bounded by the price guard.

- **Nobody sets amounts per GRET.** Mint and redemption follow `reserves ÷ supply`, as
  before. Governance cannot set the mint amounts directly: a mint basket different from
  the reserves would move value between minters and holders, and without prices the vault
  cannot tell whether two baskets are worth the same. Rebalancing means changing what the
  vault holds, and the amounts per GRET follow.
- **`swap(sell, sellAmount, buy, buyAmount)`**, only for the `rebalancer`: the vault first
  pulls `buyAmount` of `buy`, measures what arrived (with mint's tolerance) and then sends
  `sellAmount` of `sell`. It recognizes losses on both components first, sells only
  recognized reserve, never surplus, requires two different components and is closed
  during liquidation. The price guard must accept it (next points).
- **Rebalancer.** None at deployment. Governance proposes one; the proposed address accepts
  after `BASKET_CHANGE_DELAY` (7 days). A new proposal restarts the wait and governance can
  cancel it. Governance revokes the rebalancer at once, which also discards a pending one:
  taking the power away needs no notice. The role is separate from governance so that a
  timelocked governance can appoint a contract that trades at market prices, such as an
  auction.
- **Price guard.** Every
  `swap` must pass `priceGuard.checkSwap(sell, sellAmount, buy, received)`, called with what
  actually arrived and before the reserves change; if it reverts, so does the swap. There is
  none at deployment, and without one there are no swaps. Governance proposes it
  (`proposePriceGuard`, which must be a contract) and, after `BASKET_CHANGE_DELAY`, anyone
  applies it (`applyPriceGuard`), within `EXECUTION_WINDOW`; governance can cancel a pending
  one. There is no way to remove it: to stop swaps, governance revokes the rebalancer. Mint,
  redemption and liquidation never call it, so a guard that fails or misbehaves can block
  rebalancing, never an exit. The vault holds no prices or limits: they live in the guard,
  since a guard that lies about prices would defeat any limit, wherever it lived. A
  misbehaving guard brings back the earlier situation, a rebalancer trusted with the price,
  and replacing the guard waits the same 7 days as replacing the rebalancer.
- **`ChainlinkPriceGuard`**, the first guard. It values both sides of a swap in US dollars
  with one Chainlink feed per token and refuses:
  - a token without a feed, or whose price is older than its `maxAge`, in the future, zero
    or negative (fail closed: the swap reverts);
  - a swap that loses more than 2% of the value sold (`MAX_SWAP_LOSS`);
  - a swap that would make the week's swaps take more than 2% of the vault's value
    (`MAX_WEEKLY_LOSS`). Each loss counts as its share of the vault's value just before that
    swap, and the week adds those shares (`weeklyLoss`). Each priced component is valued at
    the lesser of its recognized reserve and the vault's actual balance, so neither a loss
    nobody has recognized yet nor tokens that are not reserve (a donation, what the swap just
    brought in) count; components it cannot price, or whose balance cannot be read, count as
    zero. That share is what every GRET loses, so mints
    and redemptions in between change nothing: capital present only when a loss is recorded
    cannot stretch the limit, and after large exits the limit shrinks with what is left. A
    dollar budget fixed once a week was rejected for that reason. Weeks are fixed 7-day
    periods from the Unix epoch, and the count carries on if the vault empties and starts
    again within the week. A per-swap limit alone lets the same value be traded back and
    forth, losing up to 2% each time: 50 such swaps take 64%. Swaps that lose nothing do not
    count. Around the change of week, up to 4% can be lost in a row; a limit that refills
    gradually would avoid that, but it was rejected as more code.
  - What leaves is valued rounded up and what arrives rounded down, so rounding never hides
    a loss.
  - It has no owner and nothing can be changed after deployment: tokens, feeds, `maxAge`
    and both limits are fixed. Changing any of them means
    deploying another guard, with the 7-day notice. Only the vault can call `checkSwap`;
    otherwise anyone could use up the weekly limit.
  - Each feed must quote one whole token, with nothing to convert. The proposed feeds are in
    [`scripts/pilot/config.ts`](../scripts/pilot/config.ts) (`PRICE_FEEDS`), checked on
    October 26, 2026: Chainlink's "Calculated" feeds for SGOVon and BILon (the underlying
    fund's price times Ondo's multiplier), SPY's for SPYx (one SPYx is one SPY share; its
    multiplier only turns internal shares into balance), and those of PAXG and cbBTC.
    ITOTon, EFAon, IEMGon, JAAAx, VNQon and DBCon have no Ethereum feed (the "JAAA NAV" feed
    belongs to a different fund token), so half of the basket's weight cannot be swapped
    until Chainlink adds feeds and a new guard is appointed. The equity feeds follow US
    market hours: on weekends they go stale and those swaps stop.
  - Limits of what it protects: a feed of the underlying does not see a token that loses
    its peg, and a swap that buys such a token at the feed price records no loss, so neither
    limit applies; feeds update on a deviation threshold (0.5%; 2% for cbBTC), which can eat
    into the 2%; and up to the weekly limit, a stolen rebalancer key still takes value until
    governance revokes it. Watching `LossRecorded` and each token's market price against its
    feed is policy, not code (R-02, R-03 and P-8 in [`ACCEPTED_RISKS.md`](ACCEPTED_RISKS.md)).
- **Adding a component.** Governance announces a token (`announceComponent`, named apart from
  a Governor's `propose`) and, after 7 days, anyone can add it as
  the last component, with no reserve and no initial amount. Mint does not ask for it until the
  rebalancer buys some, or governance syncs a donation of it. The wait lets holders see a
  new token coming before it can be bought with the reserves.
- **Removing a component.** Only with no reserve: sold entirely, or lost and recognized. The
  components after it move down one index. What is left of its balance becomes a token
  outside the basket, which governance can rescue in full.
- **Amounts by position are bound to the basket version.** `basketVersion` grows by one with
  every addition and every removal. `mint`, `redeem`, `redeemSkipping` and
  `setInitialAmounts` take the version their arrays were prepared for and revert with
  `BasketChanged(expected, current)` if the basket changed in between: a removal and an
  addition keep the length, and a minimum written for one token would otherwise apply to
  whichever token moved into its position. A write-off does not change the version, because
  the component keeps its position. Clients read `basketVersion()` together with
  `components()` and the previews; a call waiting in a Safe or a timelock fails instead of
  landing on another token.
- **`sync` takes the token's address**, not an index, so a `sync` waiting in a timelock cannot
  land on another component if a removal shifts the indexes in between.
- Between 1 and 128 components (`MAX_COMPONENTS`), fixed in the code. Mint and redemption visit every component in one transaction, so the cap keeps them
  within Ethereum's per-transaction gas limit (2^24, about 16.7M, since EIP-7825): with 128
  mock components, mint takes 4.2M and redemption 3.5M; with tokens like the current ones,
  about 8.7M is expected. A governance-set cap was rejected: a captured
  governance could raise it until no redemption fits in a transaction. Components that were
  sold and removed free their place; written-off ones keep it but are never called. Basket
  changes are closed during liquidation.
- **Initial amounts.** Governance can change them with `setInitialAmounts`, which takes the
  basket version it was prepared for, like mint and redemption. They apply only
  while the supply is zero, when no holder is affected; zero leaves a component out of the
  first mint, and at least one must be positive. Adding, removing and writing off components
  do not update them (a new component starts at zero; a written-off one is set to zero), so
  after basket changes they can be stale or all zero, and a restart from zero supply would
  need governance. Policy: update them as part of every basket change (R-19, P-9).
- **No weekly cap per component.** Rejected: it would limit the damage of a stolen key, but
  also a large rebalance. The price guard's weekly limit caps losses against the feeds, not
  volume: selling a whole component near its
  price uses almost none of it.
- **One decision per change.** Once its wait has passed, anyone
  can execute an added component, a write-off or a fee raise (`addComponent`,
  `writeOffComponent`, `applyFees`): governance decided when it proposed and can cancel
  during the wait. A Governor therefore needs one vote per change, not two.
- **Proposals expire.** Every proposal with a
  wait (an announced component, a write-off, a fee raise, a new rebalancer, a new
  governance) can be executed or accepted only during the 7 days after its wait ends
  (`EXECUTION_WINDOW`); after that it reverts with `ProposalExpired` and must be proposed
  again. So an old notice cannot be used at any moment later, for example a fee raise
  forgotten for a year. A timelocked governance can still accept a transfer if its own
  delay is up to 14 days and it schedules the acceptance right away.
- **Writing off a broken component.** If an issuer freezes the vault, or a component's
  `balanceOf` stops working, mint and normal redemption stop, and the component can neither
  be sold nor removed: without a write-off, only liquidation would be left, which ends the
  product. Governance proposes the write-off (`proposeWriteOff`) and, after 7
  days, anyone can execute it (`writeOffComponent`): the component's reserve and initial amount drop
  to zero and mint and redemption continue without it. Holders bear that component's share
  as a loss unless the token recovers.
  - Governance judges whether the component is broken; the vault only enforces the 7-day
    wait (R-06). A check by the vault itself (a probe that tried to read and send the
    balance) was rejected: it could be fooled both ways, and it protected little, since a
    governance that wants to harm holders already has the rebalancer.
  - What was written off never goes to governance: `rescue` refuses that token forever.
  - A written-off component stays in the basket for good and can never be removed: if the
    token recovers, `sync` returns its balance to the reserves at once, also during
    liquidation, without a new 7-day announcement that would let late minters capture it. It
    keeps its place among the 128 (R-17).
  - Closed during liquidation, which already handles broken components per claim.

How the rebalancer evolves (proposed, not decided):

1. Pilot: the pilot wallet, appointed with the 7-day wait when a rebalance is needed, together
   with a `ChainlinkPriceGuard` deployed with `PRICE_FEEDS`.
2. Later: a bot or contract that finds the best execution, still within the guard's limits.
3. Each change of rebalancer or guard goes through the same 7-day wait, without changing the
   vault.

## Fees

- **Mint and redemption fees**, in basis points of the GRET issued or redeemed, each at most
  5% (`MAX_FEE`, fixed in the code). Both are zero at deployment.
- **Charged in GRET**, which costs one movement instead of one per component. On mint, the
  minter contributes the basket for every share issued and the fee's share of that GRET goes
  to the recipient. On redemption, the fee's share of the GRET goes to the recipient and only
  the rest is burned and paid out. Either way the payer bears the fee: the value behind each
  GRET does not drop.
- **Raises wait 7 days** (`FEE_INCREASE_DELAY`), so holders see them coming; lowering both
  fees applies at once and discards a pending raise. After the wait, anyone can apply the
  raise (`applyFees`), and only once there is a recipient.
- **The recipient** is set by governance, at once: it changes who earns the fee, not what a
  holder pays. It can never return to zero nor be the vault. Its GRET gives no right to
  normal redemption unless it mints, like any other wallet.
- **Never on liquidation exits** (`convertToClaims`, `claim`), on swaps or on GRET transfers.
- `mint`'s `shares` is the gross amount and `minShares` bounds what the caller gets after the
  fee; `previewRedeem` already discounts the redemption fee.
- **The recipient's GRET stays in the supply.** If the recipient holds less than 1 GRET, the
  last holders cannot take the supply below 1 GRET, even with both fees at zero, unless the
  recipient hands its GRET over or governance liquidates (R-09). In the pilot the recipient is
  the pilot wallet, which can consolidate.
- **Events report net amounts.** `Minted.shares` and `mint`'s return are what the
  caller got; `Redeemed.shares` is what was burned. The GRET issued by a mint, or taken by a
  redemption, is that plus `FeeCharged.shares`. A recipient that mints or redeems pays itself a
  fee that moves nothing, and the event still shows it. A cut that discards a pending raise
  emits `FeesProposalCancelled`.

## Emergency liquidation

- Only governance can activate an irreversible liquidation. It has the power to close
  normal operation, but not to choose recipients, alter rights or withdraw reserves.
  There is no fast guardian: activation takes as long as the governance's timelock, and
  that delay is accepted.
- New deposits close and exits become per component, with independent operations and
  rights proportional to the shares held.
- Any holder can exit, even one that never minted. The prior-mint condition applies only
  to normal redemption.
- Withdrawing available components does not extinguish the right over blocked ones. Each
  right can be claimed only once; if a transfer fails, the corresponding right must stay
  pending.
- Liquidation cannot force an external token to allow transfers. Keeping a right does
  not guarantee recovering a token that fails permanently.

### Liquidation accounting

- `activateLiquidation()` stores the GRET supply in `liquidationSupply` and fixes the
  recognized reserves as the basis of every right; afterwards only `sync` can raise them.
  It calls no external token.
- `convertToClaims(shares)` burns GRET and credits non-transferable `claimShares`. It can
  be done in several steps. Unconverted GRET stays transferable, so whoever receives it can
  also exit.
- Each holder's right over component `i` (`pendingRights`):
  `floor(claimShares × reserve_i / liquidationSupply) − claimed_i`. It is computed on the
  total converted, so converting in parts adds no rounding losses.
- `claim(i, to, minAmount)` pays that right in full while the component's balance covers
  every pending right. If it does not, it pays the same fraction (balance ÷ pending rights) to
  everyone who has not claimed yet, in any order; if the balance recovers, the fraction
  rises again for those who have not claimed yet. It only calls component `i`. If the
  transfer fails, that call reverts and the right stays pending, without affecting the
  other components. If less than `minAmount` would be paid, it reverts and the right stays
  pending, so a cut that appears between quoting and execution can be refused.
- **Claiming during a shortfall closes the position on that component:** the right is
  consumed in full and the difference cannot be recovered through the contract. If the
  balance comes back later, it first makes whole those who waited, who bore the risk of
  further losses, and what is left becomes surplus (R-04 and P-2 in
  [`ACCEPTED_RISKS.md`](ACCEPTED_RISKS.md)). The `Claimed` event records `amount` and
  `rights`, so every cut can be reconstructed.
- `to` allows claiming to another address, for example if an issuer blocks the holder's.
  It cannot be the vault itself.
- Conservation: what is paid per component never exceeds the rights consumed or the
  balance. Rounding dust stays in the vault.
- Donations and distributions after activation do not change the rights on their own.
  Governance can add them with `sync(token)`, which raises everyone's rights in proportion,
  also over what was already claimed, or rescue them; it can never touch what is owed to
  holders (see Governance).
- Known limits: if a component never transfers again, its right stays pending with no
  recovery. GRET held by contracts that cannot call `convertToClaims` (for example, DEX
  pools) stays unclaimed (R-22).

## Governance

- The vault stores the `governance` address: an external contract that implements
  voting. The vault only checks `msg.sender == governance`; what can be done, and within
  which limits, is set by the vault.
- Powers: activating liquidation, `sync(token)` (in normal operation and during liquidation),
  `rescue(token, to, amount)`, appointing the next governance, changing the basket
  (announcing, adding and removing components, setting the initial amounts), appointing and
  revoking the rebalancer, appointing the price guard, writing off a broken component,
  setting the fees and their recipient, and pausing minting. It cannot
  withdraw reserves or pending rights, pause redemptions, reverse liquidation or redirect
  claims, and it does not swap unless it appoints itself rebalancer with the 7-day wait.
- `rescue` of a token outside the basket: the whole balance. Of a component: at most
  `componentSurplus(i)`, that is, the balance minus what is still owed (the recognized
  reserve minus the rights already claimed during liquidation). It works in normal
  operation and during liquidation. The destination is free except for the zero address
  and the vault itself. After rescuing a component, the balance left must still cover what
  is owed, so a token that debits the sender more than the amount sent cannot reduce the
  backing. The vault never holds GRET, so there is no GRET to rescue.
- Two-step governance transfer: the current governance calls `proposeGovernance(next)`
  and `next` calls `acceptGovernance()` once at least 7 days have passed
  (`GOVERNANCE_TRANSFER_DELAY`) and before the proposal expires 7 days later. The vault
  enforces the wait even if the governance contract has a bug; holders see the change
  coming. A new proposal replaces the previous
  one and restarts the wait; `cancelGovernanceProposal()` discards it. The zero address
  cannot be appointed.

### Accepted risks

What these powers still allow, and every other risk that was accepted, is in
[`ACCEPTED_RISKS.md`](ACCEPTED_RISKS.md), each with its reason and mitigation, together with
governance's operating policy (P-1 to P-12), which the vault does not enforce.

### How governance grows without changing the vault

What governance **can do** in this vault is fixed: activate liquidation, `sync`, `rescue`,
change the basket, write off components, set fees within their caps, appoint the
rebalancer and the price guard, and appoint its successor. **How it decides** can
change without redeploying or modifying the vault, because the vault only looks at one
address:

1. Minimal start (proposed, not decided): a Safe multisig as `governance`. It needs no
   code of its own and acts without delay, also in emergencies.
2. Visible delay: the Safe appoints, with the vault's two steps, an OpenZeppelin
   `TimelockController` in which it is the only proposer and the only executor (P-4 in
   [`ACCEPTED_RISKS.md`](ACCEPTED_RISKS.md#operating-policy)).
3. Open voting or other actors: they are added as proposers inside the timelock (for
   example, a `Governor` with its own voting token). The vault's address stays the
   timelock.
4. More complex rules, such as a fast path only for emergencies, live in a new governance
   contract appointed with the same two steps.

`test/GRETVault.timelock.ts` checks steps 2 and 3 with the real `TimelockController`, and
that nobody but the Safe can execute a ready `sync`. While governance is only a timelock,
activating the emergency also waits for its delay.

The rebalancer and the price guard evolve the same way: each new one is appointed with the
7-day wait.

What requires a new vault is **new powers**, such as another kind of fee or a way to claim
distributions that do not arrive as balance. The vault cannot transfer
reserves to another contract except in exchange through `swap`, so a migration would be
voluntary: each holder redeems from the old vault and mints in the new one.

## Implementation details

Bootstrap:

- The initial amounts are constructor parameters, and governance can change them later
  (`setInitialAmounts`). `scripts/deploy-local.ts` uses one whole unit of each component as
  a placeholder.
- Any wallet can make the first mint and must request exactly `INITIAL_SHARES` (1 GRET).
  With fixed amounts there is no inflation attack at bootstrap.
- Redeeming the whole supply withdraws all reserves. With zero supply, the next mint goes
  back to the initial basket for 1 GRET.

Normal accounting:

- Internal recognized reserves. `balanceOf` is queried in mint and redemption (to
  recognize losses and measure what arrived), in claims (to detect shortfalls) and when
  computing surpluses. If a component's `balanceOf` reverts, normal redemption and claims
  go ahead without adjusting that component; mint and swaps that involve it revert. Mint
  does not read components it does not ask for.
- Mint contributions round up and redemption outputs round down, so rounding never lowers
  the value behind each GRET. Every successful mint receives at least one base unit of each
  component with a positive reserve and issues positive GRET, so it always meets the
  condition that enables redemption. If every reserve was lost, mint reverts
  (`EmptyBasket`) instead of issuing GRET backed by nothing.
- `mint` returns `(minted, received)`: with exact tokens, `minted` is what was requested;
  with tokens that round, it can be a few wei less.
- Initial amounts should be at least ~10⁴ base units per component, so that a one-unit
  rounding does not move the composition by more than 0.01% per operation.
- `sync` is disabled with zero supply; in that case governance can use `rescue`. During
  liquidation it remains available, with `liquidationSupply` as the supply.
- User protection: `maxAmountsIn` and `minShares` on mint, `minAmountsOut` per component on
  redemption and `minAmount` on each claim. There is no deadline: the ratio per GRET only
  changes through rounding, `sync`, swaps or losses, fees rise only after 7 days, and the
  limits bound the cost and the result.
- A small redemption can round some component to zero; that component is not
  transferred. The user prevents it with `minAmountsOut`.
- Transient losses: if a token overstates a balance drop that later reverses, the already
  recognized loss comes back as surplus and governance decides whether to sync it. It is
  an accepted risk and the agreed policy is to sync it (R-04 and P-1 in
  [`ACCEPTED_RISKS.md`](ACCEPTED_RISKS.md)).

Permissions and structure:

- A single 18-decimal ERC-20, "Global Reserve Token" / "GRET", without upgrades.
  `transfer` and `transferFrom` to the vault itself revert with `InvalidRecipient`.
- Between 1 and 128 components, without duplicates and with deployed code. At deployment
  every initial amount must be positive.
- The initial governance is a constructor parameter; it cannot be the zero address. Only
  minting can be paused; there is no pause of redemptions, no reversal of liquidation and
  no withdrawal of reserves.
- `hasMinted` is recorded for `msg.sender`. If a router or a contract wallet mints, the
  contract is enabled, not the end user.
- `ReentrancyGuardTransient` (EIP-1153, available on mainnet since Cancun) protects the
  reserve and liquidation operations, including activation, both redemptions, swaps,
  adding, removing and writing off components, setting initial amounts and applying fees,
  so that none can happen in the middle of a mint. Proposals, cancellations and acceptances of
  governance, rebalancer, price guard and components, and revoking the rebalancer, use their own
  authorization checks and are not guarded: they do not touch reserves or the component
  list. GRET transfers do not affect reserves or rights already converted.

Gas with the 11 real components on the fork: mint 0.76M, normal redemption 0.64M, each
claim 0.16M and each swap about 0.17M, plus what the price guard spends: `ChainlinkPriceGuard`
adds about 58k with the real feeds to a swap without a loss, and 0.36M to one with a loss,
since it then reads the balance and the price of every priced component. With 128 mock components: mint 4.17M and redemption 3.49M.

## Security requirements

The project prioritizes avoiding a failure of its own that immobilizes the whole reserve,
even when the external ERC-20 tokens allow transfers. An emergency boolean does not
guarantee recoverability: activation and withdrawals can have bugs too.

- Activation must not query or transfer external tokens: a reverting `balanceOf` must not
  prevent entering the emergency.
- Establishing exit rights must not require every component to respond.
- Claiming a component must not call the other components, nor depend on the global
  mint/normal-redemption computation, oracles or an administrative authorization per
  withdrawal.
- A failed transfer must keep the pending right without affecting rights over other
  components. Also protect against reentrancy and duplicate claims, including through GRET
  transfers.
- Do not add an arbitrary administrative withdrawal as a supposed universal remedy: it
  would give discretionary custody and would not guarantee recoverability against every
  bug either. Governance's `rescue` is bounded to surpluses and does not serve that
  purpose, and `swap` always requires delivering a component in exchange.
- Before using real funds: invariant tests and random sequences, adverse token scenarios
  and an independent review of the whole contract. These checks reduce risk; they do not
  justify promising the absence of bugs.

Minimum emergency scenarios: a component reverts on `transfer` or `balanceOf`, another
returns `false`, the block is lifted later, reentrancy, claims in different orders, users
with and without a prior mint, GRET transfers, the last holder, dust, donations and
preservation of reserves for pending claims. Check both conservation (never extracting
more than owed) and the ability to withdraw the working components without cooperation
from other holders or the admin.

All these scenarios are covered; see the next section. The independent review is still
pending.

## Tests and results

| What | Where | Command |
| --- | --- | --- |
| Unit: setup, mint, redemption, minimum supply, losses, `sync` | `test/GRETVault.ts` | `npm test` |
| Liquidation, with failing components and losses | `test/GRETVault.liquidation.ts` | `npm test` |
| Governance, rescues and governance transfer | `test/GRETVault.governance.ts`, `test/GRETVault.timelock.ts` | `npm test` |
| Rebalancer, price guard, swaps, adding, removing and writing off components, initial amounts | `test/GRETVault.rebalancing.ts` | `npm test` |
| Mint and redemption fees: caps, delays, recipient and charging | `test/GRETVault.fees.ts` | `npm test` |
| Adversarial: reentrancy in 70 combinations, tokens without `bool`, tokens rejecting zero transfers, issuer freezing the vault or a holder, 0 and 24 decimals, 128 components | `test/GRETVault.adversarial.ts` | `npm test` |
| Deterministic random sequences | `test/GRETVault.invariants.ts` | `npm test` |
| Property fuzzing and invariants with a handler | `test/GRETVault.fuzz.t.sol`, `test/GRETVault.invariant.t.sol` | `npm test` (fast), `npm run test:deep` |
| Mainnet fork with the 11 components, including swaps, basket changes and the price guard with the real feeds | `test-fork/GRETVault.mainnet.ts` | `npm run test:fork` |
| Protections: attacks and failures the vault refuses or lets holders get around | `test/GRETVault.protections.t.sol` | `npm test` |
| Accepted risks: each test reproduces an accepted behavior and is named after its ID in `docs/ACCEPTED_RISKS.md` | `test/GRETVault.risks.t.sol` | `npm test` |
| Chainlink price guard: configuration, prices, per-swap and weekly limits, tokens without a price | `test/ChainlinkPriceGuard.ts` | `npm test` |
| Fuzzing: whatever swaps the rebalancer attempts in a week, with deposits and withdrawals in between, a holder who stays keeps 98% of the value of their GRET | `test/ChainlinkPriceGuard.fuzz.t.sol` | `npm test` (fast), `npm run test:deep` |
| Pilot rehearsal with the pilot wallet on a mainnet fork | `test-fork/GRETVault.pilot.ts` | `npm run pilot:rehearse` |

Invariants the fuzzing checks after every operation, with mint, redemption, transfers
(including GRET sent to the vault, which must revert), donations, `sync` (also during
liquidation), `rescue`, losses, swaps, a fourth token that joins and leaves the basket,
write-offs of the faulty component, fee changes, redemptions that skip a component,
activation, conversion, claims and random component faults:

- Every unit that enters or leaves the vault is in an independent ledger, including the
  token while it is outside the basket.
- Reserves only change through mint, `sync`, swaps, redemption, recognized losses and
  write-offs; a swap changes only its two reserves, a component leaves only with no
  reserve, and a written-off token is never rescued.
- The vault always covers what it owes: its reserve in normal operation; during
  liquidation, the sum of what everyone can claim never exceeds the balance.
- The supply is 0 or at least 1 GRET; without supply there are no reserves.
- The value behind each GRET never drops because of a mint or a redemption.
- Nobody redeems without having minted, nobody claims more than their right, `rescue`
  never changes what is owed nor exceeds the surplus, and the vault never holds GRET.
- Fees never exceed 5%, the recipient gets exactly the fee's share of each mint and
  redemption, and only the rest of a redemption is paid out.

`npm run test:deep` (20,000 cases per fuzz test, 1,000 sequences of 200 steps per
invariant) passes on the current version; the price guard's fuzz test tries up to 40 steps
per case, with fees on: swaps between −3% and +1% of the feed price, and deposits of up to
100 times a holder's position and withdrawals in between. Temporary probes confirmed that the
sequences reach every path, including swaps, adding and removing the fourth token, minting and
claiming it, mints, redemptions and redemptions that skip a component after the basket
changed, write-offs followed by mints and by a `sync` of the recovered balance, mints and
redemptions with fees, redemptions that skip a component (also by the last holder), failed
claims, losses during liquidation, `sync` during liquidation and GRET rejected by the vault;
another probe confirmed that the guard's fuzz test reaches the weekly limit. `npm run check`
passes 166 tests. Coverage of `GRETVault.sol` and `ChainlinkPriceGuard.sol`: 100% of lines and
statements.

Slither 0.11.6 on the vault and on `ChainlinkPriceGuard`, with Solidity 0.8.38: no high
findings. In the vault it reports deliberate strict equalities against zero,
`reentrancy-no-eth` on `swap`, which calls the guard before updating the reserves on purpose,
so that the guard sees them as they were (`swap` is `nonReentrant` and the guard is appointed
with notice), token calls inside bounded loops (inherent to a basket) and `block.timestamp`
in the 7-day waits. In the guard: the unused fields of `latestRoundData`, calls inside the
bounded loops, timestamps in the price age and the week, and `this.valueOf`, used for the
`try`.

### Ethereum mainnet fork (block 26,278,379, October 26, 2026 UTC)

The 11 components work with the vault, each in its own vault and also as the full basket:
mint, normal redemption, surplus rescue, liquidation and claims. In the rebalancing test,
DBCon joins a vault of the other 10 after the 7-day wait, each component is sold for the
next one, so every token leaves and enters the vault through `swap`, and cbBTC is sold
entirely and removed; the vault always holds what it records, give or take the xStocks
rounding. Those swaps go through a test guard that accepts them, since they test the tokens;
a separate test deploys `ChainlinkPriceGuard` with `PRICE_FEEDS` and the real feeds, all five
fresh at that block: it values each priced token as its feed does, refuses the six without a
feed, and, checking a PAXG-for-cbBTC swap as the vault would, accepts it at the feed price,
records a 1.9% loss as its share of the priced reserves and refuses a 5% loss. Test balances are
written into storage; no real funds moved.

| Token | Contract type | Notes |
| --- | --- | --- |
| 7 from Ondo | Beacon proxy (`0x9854…1598`), upgradeable | Exact transfers; no `paused()` |
| SPYx, JAAAx (xStocks) | EIP-1967 proxy, upgradeable | Store shares with a multiplier (1.0057 and 1.0112, already updated 4 times): lose 2–3 wei per transfer. They have a per-period fee (0 today), `multiplierUpdater`, `pauser` and a sanctions list |
| PAXG | Own proxy, upgradeable | Exact transfers; `paused()` = false |
| cbBTC | Own proxy, upgradeable | Exact transfers; `paused()` = false |

This describes the contracts at that block. All are upgradeable: their issuers can change
the behavior later. PublicNode only serves recent state, so repeating the test at the same
block requires an RPC with historical state and `MAINNET_FORK_BLOCK`.

## Mainnet pilot

Parameters in
[`scripts/pilot/config.ts`](../scripts/pilot/config.ts); steps in [`PILOT.md`](PILOT.md).

- **Deployment:** `GRETVault` at `0x21b823334D2794a637cb9c0fd7fF8671b35F5A23` on Ethereum
  mainnet, October 27, 2026, 03:14 UTC, block 26,281,281, transaction
  `0x7ae2271ee3d7a81c04e78137c8d5eb12cc724656231eb6fa91bcfa0b45302467`, signed by the pilot
  wallet with MetaMask from the local page. Gas: 5,434,767 at 0.043 gwei, about 0.00023 ETH.
  The page's eight checks passed against mainnet right after the deployment, and
  `npm run test:fork` passed that day against a fresh fork. The source is verified on
  Sourcify with an exact match (creation and runtime bytecode).
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

Pending for the pilot: verifying the source on Etherscan. MetaMask flags the approvals and
the mint as malicious (a Blockaid alert, common for new contracts that receive approvals of
many tokens); the vault only pulls tokens from the caller of `mint` or `swap`, so it is a
false positive still to be reported.

## Roadmap and open items

Next: verify the vault on Etherscan and report the MetaMask alert. An independent audit comes
before opening the vault to third parties.

1. **Name check.** Name and symbol are fixed per vault, and the pilot vault already uses
   them. Search Etherscan for an unlisted "GRET" token on mainnet, and the USPTO and EUIPO
   trademark registers for "GRET" and "Global Reserve Token"; a conflict would need a new
   vault.
2. Restrictions a fork does not show: trading hours (DBCon), future changes to the
   upgradeable tokens and the xStocks fee policy.
3. Governance after the pilot: the Safe it is handed to, signers and threshold, whether
   there will be a timelock and with which delay (with execution for the Safe only), and
   later the Governor with the VORA voting token (GRET does not vote).
4. Independent review and longer fuzzing before using third-party funds, covering the vault
   and the price guard.
5. Price coverage: six components (half of the basket's weight) have no Chainlink feed on
   Ethereum and cannot be swapped; a new guard when feeds appear, and whether to choose
   components with that in mind.
6. Final choice of implementation, and how it maps to existing audited designs.
7. The mint fee once third parties can mint (P-4 in
   [`ACCEPTED_RISKS.md`](ACCEPTED_RISKS.md#operating-policy)).
8. Update the development dependency flagged by `npm audit` (`follow-redirects`, pulled in
   by `solc`); it is not part of the vault.
