# GRETVault security review — October 28, 2026

This is a second AI-assisted internal security review, conducted by Claude Code with
Claude Opus 5.5 and carried out separately from the
[October 27, 2026 review](2026-10-27-GRETVault-review.md). It is not an independent audit
by a security firm, a formal verification, or a certification. It covers the source at
commit `219b6a47da88e4e788a87581934f501e16049785`, whose contracts are identical to those the
first review read. Production contracts were not changed and no tests were added to the
repository. No mainnet transaction was sent.

**Result: no permissionless way to take reserves was found, and the accounting held under
every property exercised. Fifteen findings were confirmed: one Medium, nine Low and five
Informational. None of them can occur in the pilot's state at the checked block.**

The Medium finding is a bound that does not hold. The documents said an honest price guard
limits a rebalancer to 2% of the vault's value per week, or 4% in a row across the change of
week. A guard replacement restarts that count, so the limits are about 4% and 6%, and about
7.8% within 7 days if replacements are chained. It needs a rebalancer acting against holders
and a replacement guard, neither of which the pilot has.

Most findings are of the same kind: the vault behaves as coded, and the specification or
the risk register described it more favorably. The vault is immutable, so those were
resolved by documentation. During this review `SPECIFICATION.md` and `ACCEPTED_RISKS.md` were
aligned with the code in commits `95177d0`, `484b41f`, `51d03cf` and `e071920`; line numbers
of those documents below refer to commit `219b6a4`, before the changes.
`ChainlinkPriceGuard` is not deployed, so its four findings can still be fixed in code. Those
changes are recorded in the specification's roadmap as proposed, not decided.

This review does not establish readiness for third-party funds.

## Reviewer identity and model configuration

The reviewer was Claude Code, Anthropic's coding agent, running in the VS Code extension with
access to the local repository, command execution, sub-agents and public read-only network
sources. The agents examined the implementation, wrote and ran tests, ran tools and drafted
this report. No independent human auditor's examination or sign-off is represented by it.

| Item | Recorded configuration |
| --- | --- |
| Reviewing agent | Claude Code (VS Code extension) |
| Coordinator model | Claude Opus 5.5, configured identifier `claude-opus-5-5[1m]` (1M-token context) |
| Orchestration | Claude Code workflows: scripted sub-agents with structured results |
| Review organization | One coordinator, eight finder agents with one lens each, three verifier agents |
| Sub-agent configuration | Model inherited from the coordinator; no model or reasoning-effort override supplied |
| Configuration evidence | The session's system context names the model identifier; each workflow run has a recorded ID (below) |
| Dates | Finders on October 27, 2026; static analysis, test gaps and verification on October 28 (UTC) |

The model identifier comes from the session's own configuration, not from the report's
style. No dated model snapshot or independently attested per-agent backend identity was
available. Private session records are not included in the repository. Every agent ran the
same model, so the passes share its blind spots: they are separate analyses, not independent
organizations or a comparison of different models.

## How the review was conducted

The request was a security review of `GRETVault`, independent of the first one and written
in the same format. The work had two stages: finders that look for problems, each through
one lens, and verifiers that try to refute every candidate with their own tests.

| Finder lens | Run | Areas examined | Findings returned |
| --- | --- | --- | --- |
| Accounting and rounding | `wf_be85dc9a-c49` | Mint and redemption ratios, rounding, fees, supply floor, skipping | 1 |
| Emergency liquidation | `wf_be85dc9a-c49` | Activation, conversion, rights, shortfall payouts, sync and rescue | 3 |
| External calls and reentrancy | `wf_be85dc9a-c49` | Token calls, `try`/`catch`, SafeERC20, callbacks, the guard's reads | 3 |
| Governance and time locks | `wf_83d42898-c83` | Every delayed and anyone-may-execute path, access control, state machine | 6 |
| Rebalancing and price guard | `wf_83d42898-c83` | `swap`, `ChainlinkPriceGuard` pricing, weekly accounting, guard lifecycle | 4 |
| Economic and MEV | `wf_83d42898-c83` | Just-in-time minting, sandwiches, donations, ordering of public actions | 3 |
| Static analysis | `wf_76ce0bb4-030` | Slither, Aderyn and `slither-check-erc`, each result triaged by hand | 1 |
| Test-suite gaps | `wf_01fe1561-74d` | What the committed tests do not exercise; new stateful properties | 1 |
| Specification conformance | Not run | — | — |

The 22 findings returned were merged into 15 candidates. Each verifier took five of them and
was told to refute or narrow each one, to accept only what it reproduced in its own sandbox
with its own tests, and to classify against the documents as they were at `219b6a4`:

| Verifier group | Run | Candidates | Tests written | Result |
| --- | --- | --- | --- | --- |
| Price guard and rebalancing | `wf_2cf33b86-ebd` | 5 | 14 passing | All confirmed |
| Exits and external calls | `wf_d5c337b8-e6e` | 5 | 14 passing, one fuzz at 256 runs | All confirmed, two with a narrower scope |
| Governance and economics | `wf_f518ede0-bc0` | 5 | 12 passing, one fuzz at 256 runs, one mutation run | All confirmed |

The coordinator performed the following work:

1. Read the vault and the guard in full, set the scope, wrote each lens's instructions and
   kept every agent's work in its own sandbox copy of the repository.
2. Merged the finders' results, removed duplicates and grouped the candidates.
3. Read public mainnet state at a pinned block, compared the deployed runtime with the
   repository build and ran the project's checks, the fork tests and the pilot rehearsal.
4. Checked every documentation change against the code before writing it, and corrected
   the documents again where the verifiers measured something the new wording missed.
5. Wrote this report from the verifiers' results.

Disclosures about independence and method:

- **The first review.** Every finder and verifier was told not to open `docs/audits/` or the
  first review's working files, and their instructions did not relay its findings. The
  coordinator read the first review at the start, to follow its format, so the coordinator
  was not blind to it. The comparison below was written after every verdict was final.
- **Tests from the first review.** The repository's suite includes the three property tests
  the first review added (`test/GRETVault.audit-*.t.sol`); the accounting lens was told to
  read one of them as an example of the test style.
- **Not blind to the design.** Agents read `SPECIFICATION.md` and `ACCEPTED_RISKS.md` to
  classify what they found, after reading the code.
- **Directed questions.** The instructions of the liquidation and external-calls lenses
  asked explicitly how `try`/`catch` treats undecodable return data, an address without code
  and a gas limit chosen by the caller, a hypothesis of the coordinator's. REVIEW2-L01 and
  REVIEW2-L08 come from those questions. The static-analysis lens reached REVIEW2-L01 again
  from its detector triage.
- **Specification conformance not run.** The owner decided that, the vault being deployed
  and immutable, the documents follow the code. A systematic comparison of every sentence of
  the specification with the code was therefore not made; the lenses compared only what
  they examined.
- **Documents changed during the review.** The documentation commits listed above were
  made after the finders reported. The test-gaps lens and the verifiers saw the updated
  documents; the verifiers classified against `219b6a4` and checked the new wording.
- **Interrupted work.** A first run of all nine lenses (`wf_ea263c90-e51`) was stopped to
  save cost before any agent finished; the lenses were run again in smaller groups. Later a
  machine restart erased the temporary working folder. The agents' results survived in the
  session records; the on-chain read, the validation and the compiler bug list were redone,
  and the verifiers wrote their own tests instead of reusing lost ones.

The tools were local source inspection and Git, the pinned Hardhat, Solidity and
TypeScript toolchain, Solidity tests with forge-std, Slither 0.11.6, Aderyn 0.6.8, viem and
JSON-RPC reads, and Solidity's published bug list.

The conclusions are the agents' interpretation of the source and of observed tool results.
Agreement between agents of the same model is not independent proof. The record supports
the findings and checks it reports; it does not establish an exhaustive attack search,
formal correctness or the absence of undiscovered bugs.

## Scope and reproducibility

Primary scope:

- `contracts/GRETVault.sol`, all 1,022 lines.
- `contracts/ChainlinkPriceGuard.sol` and `contracts/IPriceGuard.sol`, because swaps depend
  on them.
- The pinned OpenZeppelin implementations the vault uses: ERC20, SafeERC20, Math and
  ReentrancyGuardTransient.
- The specification, the accepted risks, the pilot configuration and the existing tests.

| Item | Reviewed value |
| --- | --- |
| Git commit | `219b6a47da88e4e788a87581934f501e16049785` |
| Node / npm | `24.14.1` / `11.11.0` |
| Hardhat / OpenZeppelin / viem / forge-std | `3.18.0` / `5.6.1` / `2.57.1` / `1.17.0` |
| Solidity | `0.8.38+commit.1835d247` |
| Build | Optimizer enabled, 200 runs, Cancun EVM, legacy pipeline |
| GRETVault source SHA-256 | `4c3a02b92d12516a3aa6e500bdc3023481d79fefd2dea11c1761877b12cb642a` |
| ChainlinkPriceGuard source SHA-256 | `f8792d14ac26606b1f6b7e9bf01ff9043ebf0aa5d280cc0fbe341d2301c9ef96` |
| IPriceGuard source SHA-256 | `40d310fd21a49f2d3dc53a42dc653229d858078c0457ef911a77a5d88f1c38cf` |
| package-lock.json SHA-256 | `d52846b2e92abc56ced1c86cd43cf6f7a4320c05799bf0cfc5a8d9d1b0a4610b` |

The contracts, tests, test configuration and lock file are identical at `219b6a4` and at
the commit where the validation below ran (`95177d0`, which changed only documentation).

Solidity's published bug list, fetched on October 28, 2026 at 03:22 UTC, has no entries for
0.8.38 (released October 22, 2026; `bugs_by_version.json` SHA-256 `42aede20…ae08`). That is a
check for known compiler issues, not proof that the compiler is free of defects.
[Solidity bugs by version](https://raw.githubusercontent.com/ethereum/solidity/develop/docs/bugs_by_version.json).

Excluded: a source audit of the eleven issuers' tokens or their future upgrades; a
governance voting system; rebalancing bots and external exchanges; wallet and key custody;
the pilot's local page; legal questions; and future integrations that use GRET. The fork
tests check token compatibility at one block, not every issuer restriction.

## Deployment checked

The public RPC snapshot is preserved in
[`2026-10-28-mainnet-snapshot.json`](2026-10-28-mainnet-snapshot.json).

| Item | Observation at the pinned block |
| --- | --- |
| Network / vault | Ethereum mainnet / `0x21b823334D2794a637cb9c0fd7fF8671b35F5A23` |
| Block | `26288497`, `2026-10-28T03:21:11Z` |
| Block hash | `0x8d5e51fe05bebfe8d3faf93a3926ace2edb41731d14d397e9d976a4b3b821efc` |
| Runtime | Exact byte-for-byte match to the repository build, including metadata |
| Runtime size / Keccak-256 | 19,945 bytes / `0x5e0a588f8331248b54ee799650a9cdb022c36222471e36f18eecec00fe309c4b` |
| Supply | 1 GRET, all held by the pilot wallet, which has minted |
| Components / version | Eleven / `0` |
| Backing | Every component's actual balance equals its recorded reserve; no surplus |
| Governance | Pilot address `0xe03E228E1f1c50a985556Cc9c05b0aB953Feb7fd` |
| Rebalancer / price guard | Both zero; swaps unavailable |
| Pending proposals | None, including write-offs and component announcements |
| Fees / mint pause / liquidation | Both fees zero / not paused / not active |
| History | One GRET transfer (the first mint) and three vault event types |

A read-only `eth_call` from the pilot address at that block simulated redeeming the whole
1 GRET with version zero and zero minimums, and succeeded. It is evidence that the current
holder could exit at that state, not an executed withdrawal. These observations apply only
to the pinned block and were read from one provider (PublicNode). An earlier read on
October 27 gave the same state; its record was lost with the temporary folder.

## Summary of findings

| ID | Finding | Severity | Classification | Related | Pilot today |
| --- | --- | --- | --- | --- | --- |
| REVIEW2-M01 | A guard replacement restarts the weekly loss budget | Medium | Variant of an accepted risk | R-02, P-8 | No |
| REVIEW2-L01 | `try`/`catch` tolerates only a revert of `balanceOf` | Low | Documentation | R-14, R-15 | No |
| REVIEW2-L02 | The guard reads token decimals once, at deployment | Low | New code issue (guard) | R-12, R-03 | No |
| REVIEW2-L03 | A ready write-off and a mint fit in one transaction | Low | Variant of an accepted risk | R-06, R-08, P-5 | No |
| REVIEW2-L04 | A minter just in time takes what `redeemSkipping` leaves | Low | Variant of an accepted risk | R-08, R-12 | No |
| REVIEW2-L05 | A positive redemption fee keeps 1 GRET in the supply | Low | Variant of an accepted risk | R-09, R-01 | No |
| REVIEW2-L06 | `swap` can buy a written-off component | Low | Variant of an accepted risk | R-03, R-06 | No |
| REVIEW2-L07 | Losses from a lagging feed fall outside both limits | Low | Documentation | R-03, R-02 | No |
| REVIEW2-L08 | A caller's gas limit can force the `catch` branch | Low | Variant of an accepted risk | R-14, R-15 | No |
| REVIEW2-L09 | Version changes can make prepared redemptions revert | Low | Variant of an accepted risk | R-01, R-18 | No |
| REVIEW2-I01 | P-2 cannot see a claim that moved no tokens | Informational | Documentation | P-2, R-10 | No |
| REVIEW2-I02 | Leaving before a losing swap shifts the loss to others | Informational | Variant of an accepted risk | R-08, P-6 | No |
| REVIEW2-I03 | `LossRecognized` names the component only by index | Informational | Code (events) | P-1 | No |
| REVIEW2-I04 | The guard notice covers an address, not its code | Informational | Variant of an accepted risk | R-01, R-18 | No |
| REVIEW2-I05 | The suite never asserts the six proposal events | Informational | Test coverage | — | No |

Severity scale: High is a loss or freeze of holders' funds reachable without a trusted role
acting against holders, or a documented bound failing by a large factor. Medium is a bounded
loss beyond a documented bound, reachable by a role the design already treats as possibly
hostile together with an ordinary action of governance. Low is a limited or unlikely impact,
an extreme precondition, or documentation that materially understates real behavior.
Informational has no loss.

## REVIEW2-M01 — A guard replacement restarts the weekly loss budget

**Severity:** Medium. **Status:** Documented (R-02 and the specification); a fix for the
next guard is proposed, not decided. Not reachable in the pilot today.

**Location:** `ChainlinkPriceGuard.sol:61-64` and `:109-119` (weekly state per instance);
`GRETVault.sol:594-606` (`applyPriceGuard`, callable by anyone).

**Evidence:** In a $400 vault at feed prices, one guard stopped a hostile rebalancer at
198 bps in a fixed week. With guard A used up, the rebalancer applied guard B in the same
block and used it up too: 394 bps (A and B each recorded 0.019999999984). Across the change
of week, A then B then B again took 585 bps in 180 seconds, against 394 bps with one guard.
If governance proposes the next guard in the block where one is applied, a closed 7-day
window holds four budgets: 772 bps. The caps are 1 − 0.98² = 3.96% per fixed week,
1 − 0.98³ = 5.88% in a row and 1 − 0.98⁴ = 7.76% within 7 days.

**Cause:** `currentWeek` and `weeklyLoss` are storage of each guard instance, so a new guard
starts at zero. Any change of feed or `maxAge` needs a new guard, as do the feeds the
roadmap plans. Restricting `applyPriceGuard` to governance would take away the rebalancer's
choice of moment, but not the reset.

**Impact:** About 2% of the vault's value more per replacement than R-02 stated (2% per
week, 4% in a row). At most one replacement can become ready per fixed week, and revoking
the rebalancer needs no wait.

**Correction:** R-02 and the specification now state the reset, the chained case and that
anyone can apply a ready guard. Proposed for the next guard: take the previous guard in the
constructor and, while in its week, start from its `weeklyLoss`. Proposed operating rules,
not adopted: have no rebalancer appointed when a replacement becomes ready, do not chain
replacements, and watch `LossRecorded` on both guards around a replacement (P-8).

## REVIEW2-L01 — `try`/`catch` tolerates only a revert of `balanceOf`

**Severity:** Low, documentation. **Status:** Documented (R-14, R-15 and the
specification); a fix in the guard is proposed, not decided.

**Location:** `GRETVault.sol:879-887` (`_redeem`), `:943-954` (`_payout`) and `:443-445`
(`claimable`); `ChainlinkPriceGuard.sol:147-163` (`_vaultValue`).

**Evidence:** With a `balanceOf` that reverts, redemption and claims went ahead, as
documented. With one that returns empty data or 31 bytes, or a component without code,
`redeem`, `claim` and `claimable` reverted with empty data while the token's transfers still
worked; `redeemSkipping` without it paid the rest. In the guard, every swap with a loss
reverted, even one not involving that token. Reported by three lenses, two of which were
asked about it (see the disclosures above).

**Cause:** Solidity's `catch` handles a revert inside the callee. Decoding fewer than 32
bytes of return data, or calling an address without code, fails in the caller and is not
caught. The documents said a component whose balance "cannot be read" counts as zero in the
guard and that the transfer decides in the vault; the NatSpec says "fails".

**Impact:** No funds are lost; each case fails closed. Normal redemption stops until a
write-off; in liquidation, where write-offs are closed, that component's claims wait until
the token answers again. Rebalancing stops. `sync`, `rescue`, `recognizeLoss` and `mint`
revert for any failure of `balanceOf`, so they are not part of this deviation. For a proxy
pointing at an implementation without code, the revert protects holders from a transfer
that moves nothing.

**Correction:** The documents now state that only a revert is tolerated. Proposed for the
guard: read the balance with a low-level static call and use it only when the call succeeds
with at least 32 bytes, otherwise count the component as zero, as its NatSpec says.

## REVIEW2-L02 — The guard reads token decimals once, at deployment

**Severity:** Low, new code issue in the undeployed guard. **Status:** Documented in the
specification; a code fix is proposed, not decided.

**Location:** `ChainlinkPriceGuard.sol:94` (stored at construction) and `:143` (used).

**Evidence:** After an issuer changed decimals in place while keeping value, a swap at the
feed recorded no loss. From 18 to 6 decimals, the rebalancer took a whole reserve of $200
for 2e6 wei of another token. From 6 to 18, it delivered 5e6 units ($5e-12 of value) and
took $200 of other reserves. `weeklyLoss` stayed at zero in both cases.

**Cause:** The guard scales by the stored decimals and the live feed decimals, so a change
on the token's side is never seen. Monitoring of market price against feed (P-8) does not
catch it, because the feed stays correct.

**Impact:** Neither limit holds for swaps that sell or buy that token, and the second case
takes other components' reserves. All eleven components are upgradeable (R-12), but an
in-place change of decimals by a regulated issuer is an extreme precondition.

**Correction:** Proposed for the guard: read `decimals()` on each valuation, or keep the
stored value and refuse a swap when the live value differs.

## REVIEW2-L03 — A ready write-off and a mint fit in one transaction

**Severity:** Low. **Status:** Documented (R-06, P-5 and the specification). Not reachable
in the pilot today: no write-off is pending.

**Location:** `GRETVault.sol:714-729` (`writeOffComponent`, callable by anyone once ready);
`:265-266` and `:373-375` (mint skips a component with no reserve).

**Evidence:** While a component was frozen for the vault, mints reverted on their own, so
governance had no reason to pause. At `readyAt`, a contract executed the write-off and
minted 9 GRET without that component in one transaction; a pause sent next came too late.
After the token recovered and governance synced it, the entrant took 4.5 of Alice's 5 units.
A fuzz confirmed the share k/(k+1) for an entrant minting k times the supply (k from 1 to
1000). If the token never recovers, the entrant redeems exactly what it paid. A pause before
`readyAt` stopped the bundle.

**Cause:** P-5 said to keep minting paused while a written-off component may recover, which
reads as pausing once it is written off. A public `cancelWriteOff` sent after `readyAt` can
be front-run the same way.

**Impact:** A free option on the recovery, paid by the holders who bore the write-off.

**Correction:** P-5 now says to pause minting before a write-off becomes executable.

## REVIEW2-L04 — A minter just in time takes what `redeemSkipping` leaves

**Severity:** Low. **Status:** Documented (R-08, P-5 and the specification).

**Location:** `GRETVault.sol:320-332` and `:892-900` (the skipped share leaves the reserve
only if the supply reaches zero).

**Evidence:** When the last holder redeemed with a component skipped, the share became
surplus that governance could rescue to that holder. With a mint of 1 GRET just before it,
the supply did not reach zero and the entrant redeemed afterwards with the whole skipped
share (5 units, $200 in the test). With another holder present, the entrant took
X/(S_rest + X) of it. A mint pause sent first restored the surplus.

**Cause:** The skipped share stays in the reserve for whoever holds GRET, and anyone who can
mint the basket can become a holder for one block. R-08 listed syncs and favorable swaps,
not skipped shares.

**Impact:** A holder an issuer blocked loses the share governance could have returned. The
pilot is reachable in principle (mint is open and one wallet holds the supply), but it needs
an issuer to block the pilot wallet and that wallet to redeem publicly; it is also
governance and can pause minting first.

**Correction:** R-08 now states it, including that the entrant takes all of it when the one
skipping is the last holder; P-5 says to pause minting before the last holders leave this
way.

## REVIEW2-L05 — A positive redemption fee keeps 1 GRET in the supply

**Severity:** Low. **Status:** Documented (R-09 and the specification).

**Location:** `GRETVault.sol:889-893` (fee, burn and the supply floor) and `:905`.

**Evidence:** With any redemption fee from 1 to 500 bps, no sequence emptied the supply: the
sole holder, also the fee recipient, could not redeem its last GRET at any size, and handing
the fee GRET back did not help (fuzz, 256 runs). After cutting the fees to zero, which
applies at once, the redemption emptied the supply.

**Cause:** Every redemption leaves its fee in the supply, so `burned` can never equal the
supply, and a remainder below 1 GRET reverts. R-09 said "just under 1 GRET" and that
gathering the GRET in one wallet lets the last holders leave.

**Impact:** The basket behind 1 GRET (about $100 in the pilot) stays until governance cuts
the fee or liquidates. If governance's key is lost while the fee is positive, it stays for
good. No value moves to anyone.

**Correction:** R-09 and the specification now state it. Proposed, not adopted: cut the
redemption fee to zero before the last holders leave.

## REVIEW2-L06 — `swap` can buy a written-off component

**Severity:** Low. **Status:** Documented (R-03 and the specification); a guard-side check is
proposed, not decided.

**Location:** `GRETVault.sol:468-494` (no check of `writtenOff`); the NatSpec at `:80-81`
says only `sync` returns a written-off balance to the reserves.

**Evidence:** After a component frozen for sending was written off, the rebalancer swapped
the whole other reserve for it at the feed price: no loss recorded, a reserve of 10 units,
`previewMint` asking for it again, normal redemption reverting, and `redeemSkipping` without
it paying nothing, since the other reserve had been sold. A swap of 1 wei for 3 wei passed
the guard and was enough to make normal redemption revert again.

**Cause:** `swap` checks neither side's `writtenOff` flag; selling is blocked only because
the reserve is zero. The NatSpec is misleading rather than false: the swap credits new
units, and the old balance still returns only through `sync`.

**Impact:** The value at risk is within R-03's worst case. What R-03 missed is that the
purchase undoes the write-off, which costs another 7-day write-off of degraded redemption.

**Correction:** R-03 and the specification now state it. Proposed for the guard, which would
also protect the deployed vault: refuse a swap when the vault's public `writtenOff(buy)` is
true.

## REVIEW2-L07 — Losses from a lagging feed fall outside both limits

**Severity:** Low, documentation. **Status:** Documented (R-03 and the specification).

**Location:** `ChainlinkPriceGuard.sol:103-105` (a swap at or above the feed price returns
before both limits).

**Evidence:** With the weekly budget used up at accurate prices (198 bps), two swaps at the
ratio of a feed lagging its market within a 2% band lost $3.67 and $3.72 without changing
`weeklyLoss`: 383 bps of the vault in one fixed week. One swap within the per-swap limit lost
385 bps of the value sold at market prices.

**Cause:** The documents said the deviation threshold "can eat into the 2%", suggesting the
lag counts inside the budget. It never counts.

**Impact:** The loss is bounded by the thresholds times the volume swapped, can be taken on
every swap while a feed lags, and between two feeds can reach the sum of their thresholds.
The real feeds' thresholds and heartbeats were taken from the documents, not verified on
chain.

**Correction:** R-03 and the specification now state it. Comparing each token's market price
with its feed (P-8) remains the control.

## REVIEW2-L08 — A caller's gas limit can force the `catch` branch

**Severity:** Low. **Status:** Documented (R-14 and the specification).

**Location:** `GRETVault.sol:946-954` (`_payout` pays the full right on `catch`) and
`:882-887` (`_redeem` skips loss recognition on `catch`).

**Evidence:** With a `balanceOf` costing 8M gas, a claim during a shortfall was paid in full
at gas limits from 5.25M to 8.0M with cold storage (4.5M to 8.0M warm). In the test, Alice
took all 5 units left of 10 owed, and Bob was left with 5 pending and nothing claimable. A
redemption with a 12M-gas `balanceOf` paid on the stale reserve at 43 gas limits; with 11
components, starving was possible from 12.84M, inside the transaction cap. A `balanceOf`
near 100k gas was never starved at any limit.

**Cause:** A call keeps 1/64 of the gas it forwards (EIP-150), so a caller who chooses the
limit can make an expensive `balanceOf` run out of gas and still finish.

**Impact:** The R-14 outcome (later holders bear the whole shortfall), chosen by any caller
instead of requiring a reverting `balanceOf`. It needs an issuer upgrade that makes
`balanceOf` cost millions of gas while transfers keep working.

**Correction:** R-14 and the specification now state it. Proposed, not adopted: treat a
component whose `balanceOf` becomes expensive like a broken one (P-10). For a future vault,
call `balanceOf` with a fixed gas stipend.

## REVIEW2-L09 — Version changes can make prepared redemptions revert

**Severity:** Low. **Status:** Documented (R-01 and the specification).

**Location:** `GRETVault.sol:629-642` (`addComponent`, anyone), `:649-674`
(`removeComponent`, at once for a component with no reserve) and `:1018-1021` (the version
check).

**Evidence:** With ten tokens announced earlier, a hostile governance made 20 prepared
redemptions revert with `BasketChanged` during a notice; the next one went through. A junk
component added within its window and kept with no reserve could be removed 90 days later,
so the capacity can be stored up (117 free places in the pilot). A redemption sent from a
contract that reads `basketVersion()` when it executes was not affected.

**Cause:** Each addition and each removal changes the version, and governance controls
when. R-01's mitigation said wallets that minted can redeem during a notice, without this
caveat.

**Impact:** Exits are delayed, not blocked; a loss would need the delay to outlast a
hostile rebalancer's notice. The announcements are themselves a visible warning.

**Correction:** R-01 and the specification now state it, with the mitigation.

## Informational findings

**REVIEW2-I01 — P-2 cannot see a claim that moved no tokens.** A transfer that reports
success without moving tokens (R-10) emits `Claimed` with `amount` equal to `rights`, so P-2
sees no cut. With two equal holders, following P-2 and then syncing the leftover returned
50 units to the victim and 150 to the other holder; rescuing to the victim, reconstructed
from the token's own transfers, restored 100 each. P-2 now states the gap. Proposed, not
adopted: compare each `Claimed` with what actually left the vault and rescue undelivered
amounts to their claimant before any `sync`.

**REVIEW2-I02 — Leaving before a losing swap shifts the loss to others.** A holder who
redeems before a swap that loses value and mints after it bears none of that loss: in the
test the other holder's loss per GRET doubled from $0.80 to $1.60. The guard records the
loss as a share of the vault after the exit, which equals the remaining holders' real loss,
so R-02's bounds hold. R-08 described only the favorable direction; it now covers both.
P-6 (private RPC for swaps) mitigates it.

**REVIEW2-I03 — `LossRecognized` names the component only by index.** The event
(`GRETVault.sol:131`) carries no address, and removals shift indexes, while P-1 relies on it
to find recoveries to sync. After removing an earlier component, the old index named another
token. Reading the component list at the end of the event's block is not enough, since a
removal may follow in the same block. P-1 now says to replay `ComponentAdded` and
`ComponentRemoved` in log order. A future vault should index the token address.

**REVIEW2-I04 — The guard notice covers an address, not its code.** `proposePriceGuard`
checks only that the address has code. A guard whose owner can switch its behavior, and an
EIP-7702 account, passed the check and accepted a drain after the notice with no new notice
in the vault. The outcome equals R-01's hostile guard, without a notice at the moment of the
change; it needs governance to choose such a guard, and the code is public during the
notice. R-18 and the specification now state it. Proposed, not adopted: a guard must be
immutable, and watchers compare a proposed guard's code with the repository build.

**REVIEW2-I05 — The suite never asserts the six proposal events.** With the six `emit`
lines of `RebalancerProposed`, `PriceGuardProposed`, `ComponentAnnounced`,
`WriteOffProposed`, `FeesProposed` and `GovernanceProposed` deleted, the committed suite still
passed (169 tests); a test written for this review failed on that mutant. These events are
the on-chain notice that the 7-day waits exist to give. The committed stateful handler also
never leaves a loss unrecognized, removes only the last component, never calls
`setInitialAmounts`, skips only one component, never delivers short in sequences, never
claims to a third party and has no checks that a healthy mint or exit succeeds. Proposed:
add a test of the six events and extend the handler.

## Properties that held

Beyond the findings, the agents checked these properties with tests or by reasoning on the
code; no violation was found:

- **Mint and redemption.** A mint issues `min(shares, minᵢ floor(receivedᵢ · S / Rᵢ))` less
  the fee, with receipts up to 10 units short, and never lowers the backing per share; a
  redemption pays `floor(burned · Rᵢ / S)`. No round trip, dust sequence or coalition with
  the fee recipient returned more than it paid. The first mint at zero supply ignores
  surplus left in the vault.
- **Liquidation.** Per component, pending rights plus rights claimed never exceed the
  reserve, and what is claimable never exceeds the balance. Payments never exceed the rights
  consumed, except through REVIEW2-L08. Rights cannot be claimed twice or inflated by
  splitting, merging or converting in parts. Shortfall payouts do not depend on claim order
  beyond 2 units of rounding. Governance cannot lower what is owed or what anyone can claim.
- **Time locks.** No delayed action took effect before `readyAt`, after its window, without
  a live proposal or through the wrong caller, across re-proposals, cancellations and
  governance changes (stateful fuzz, plus a 3,000-step probe that reached every delayed
  action and both window edges). Positive fees always have a recipient, and a raise always
  waits. A removal keeps every per-index structure consistent, and a component added again
  inherits nothing.
- **Price guard.** With one honest guard and accurate feeds, swaps took at most 2% of each
  GRET's value per fixed week, with mints, redemptions, donations, syncs, losses, stale
  feeds and unpriced components between swaps. `valueOf` is the exact floor for token
  decimals 0 to 24 and feed decimals 0 to 18, and overflows, invalid prices and a zero vault
  value fail closed. Changes to the basket between swaps cannot misalign the guard.
- **External calls.** Every function that writes reserves is `nonReentrant`; calls to
  `balanceOf`, `decimals` and the vault's views are static calls; a callback cannot change
  the guard of a swap in flight; a mint credits only what arrived.
- **Stateful invariants** (test-gaps lens): an address-keyed ledger of every inflow and
  outflow, reserves recomputed independently, backing per share, liveness of healthy mints
  and exits, the supply floor and liquidation solvency all held over 2,500 sequences of
  depth 200, and 1,000 more with half of the losses left unrecognized. Three liquidation
  fuzz tests ran 10,000 times each.

These arguments assume the token behaviors that the tests model. The accepted issuer risks
are explicit exceptions; mocks do not prove compatibility with the real issuers.

## Tests written for this review

The tests are kept outside the repository; they are not part of `npm run check`.

| Tests | Purpose | Result |
| --- | --- | --- |
| Finders' proofs of concept, one or more files per lens | Reproduce each candidate | Passing; replaced by the verifiers' own tests |
| `Find2Gaps.invariant.t.sol`, `Find2Unrecognized.invariant.t.sol` and liquidation fuzz | Stateful paths the committed handler skips | 6 + 6 passing (2,500 × 200 and 1,000 × 200); 3 × 10,000 runs |
| `VerifyGuard.t.sol` | REVIEW2-M01, L02, L06, L07, I04 | 14 passing |
| `VerifyExits.t.sol` | REVIEW2-L01, L04, L05, L08, I01 | 14 passing, including a 256-run fuzz |
| `VerifyGovernance.t.sol` | REVIEW2-L03, L09, I02, I03, I05 | 12 passing, including a 256-run fuzz; one mutation run |

## Executed validation

| Check | Result |
| --- | --- |
| `npm run check` | Passed: 169 tests, 41 Solidity and 128 Node.js |
| `npm run test:deep` | Passed: 41 Solidity tests; fuzz at 20,000 runs, invariants at 1,000 runs of depth 200 |
| Mainnet fork, block 26288500 | Passed: 5 tests, about 598 seconds |
| Pilot rehearsal, block 26288550 | Passed: 1 test, about 368 seconds |
| Deployed bytecode and state, block 26288497 | Runtime identical to the repository build; state as in the table above |
| Full redemption of the deployed vault via `eth_call` | Succeeded at block 26288497 |
| Slither 0.11.6 | 64 results on the vault and 34 on the guard, 68 of them in OpenZeppelin; none confirmed as a defect |
| Aderyn 0.6.8 | 2 high and 8 low issue types, 39 instances; none confirmed as a defect |
| `slither-check-erc` (ERC-20) | GRET conforms; only the standard approval race of OpenZeppelin's ERC20 is flagged |

The checks ran on October 28, 2026 at commit `95177d0`, whose contracts and tests are
identical to `219b6a4`. An earlier run on October 27 gave the same results; its logs were
lost with the temporary folder, so only the reruns are cited. Reproduce them with the pinned
dependencies and an RPC that still serves the blocks:

```sh
npm ci
npm run check
npm run test:deep
MAINNET_RPC_URL=<archive-rpc> MAINNET_FORK_BLOCK=26288500 npm run test:fork
MAINNET_RPC_URL=<archive-rpc> MAINNET_FORK_BLOCK=26288550 npm run pilot:rehearse
```

Sampling does not exhaust the state space, and passing counts alone do not show that every
economic scenario was explored. All fork state changes were local.

### Static-analysis triage

Slither and Aderyn ran in a sandbox copy with the native `solc` 0.8.38 binary (same commit as
the project's build). Aderyn used its default EVM version, Prague, while the project builds
for Cancun. Each result was checked by hand.

| Tool and detector | Count | Assessment |
| --- | --- | --- |
| Slither reentrancy-no-eth (`swap`) and Aderyn H-1 (state change after external call) | 1 and 5 | False positives: `balanceOf`, `decimals` and the vault's views are static calls; every function that writes reserves is `nonReentrant`; `swap` keeps the guard it loaded. Views during a callback are R-15 |
| Slither incorrect-equality | 3 | Intended checks for zero surplus, zero payout and zero receipt |
| Slither uninitialized-local and Aderyn L-7 | 2 and 6 | Booleans and counters that start at their default on purpose |
| Slither unused-return and Aderyn L-6 | 1 and 5 | Unused round metadata; the returns of `_recognizeLoss` and `_indexOf` are not needed where ignored |
| Slither calls-loop | 7 | Inherent to a basket; hostile gas use is R-15. The triage of these calls led again to REVIEW2-L01 |
| Aderyn L-1 (storage writes in a loop) and L-5 (revert in a loop) | 7 and 4 | Intended: per-component reserves and checks |
| Slither timestamp | 11 | Intended waits, expiry, price freshness and week buckets |
| Aderyn H-2 (unprotected initializer) | 1 | False positive: a view function, not an initializer |
| Aderyn L-4 (`nonReentrant` not first) | 5 | False positive: the modifier before it makes no call |
| Slither var-read-using-this | 1 | Intended: `this.valueOf` allows a `try`/`catch` per component |
| Slither pragma and cyclomatic-complexity; Aderyn L-2, L-3, L-8 | 4 and 6 | Style and reviewability; no security impact |
| Slither on OpenZeppelin (incorrect-exp, divide-before-multiply, assembly, others) | 68 | Out of scope; `incorrect-exp` in `Math.mulDiv` is a known false positive |

## Comparison with the first review

The two reviews read the same contracts. They agree that no permissionless drain of reserves
exists, that the proportional accounting and the liquidation model hold under the exercised
properties, and that the material risks are the powers entrusted to governance, issuers and
feeds. The first review found one Low defect in the pilot rehearsal, since corrected, and
recorded the existing accepted risks with their impact; it reported no new contract defect.

This review adds fifteen findings, none in the vault's accounting. The guard's bounds were
the clearest difference: the first review described the 2% limits and the 4% across the
change of week as accepted, and both reviews noted that a feed cannot see a depeg; neither
the first review nor the register considered a guard replacement (REVIEW2-M01) or the guard's
stored decimals (REVIEW2-L02). Several findings sharpen risks the first review discussed:
the supply floor with a positive redemption fee (REVIEW2-L05), `balanceOf` failures beyond a
revert (REVIEW2-L01, L08), and late entrants capturing value through a write-off or a skipped
share (REVIEW2-L03, L04).

The methods differed. The first review used one coordinator and three auxiliary passes that
shared the specification and the register from the start. This one used eight finder lenses
and three verifiers that tried to refute each candidate with their own tests, kept away from
the first review. The reviews used different model families. Both are AI-assisted, and
neither replaces the independent audit the project requires before third-party funds.

## Disposition

The vault is immutable and needs no source patch for these findings: the specification and
the risk register now describe what it does. The four guard findings (REVIEW2-M01, L01's
guard part, L02 and L06's guard check) are proposed code changes for `ChainlinkPriceGuard`
before it is deployed, recorded as item 9 of the specification's roadmap, not decided.
Adopted in the documents: pausing minting before a write-off becomes executable and before
the last holders leave with `redeemSkipping` (P-5), and mapping `LossRecognized` by replaying
events (P-1). Proposed, not adopted: the other operating rules named in each finding, and the
tests of REVIEW2-I05.

For the own-funds pilot, the deployed code matches the reviewed code, its backing is present
and its only holder's exit simulated successfully. None of the findings can occur in that
state; most need a rebalancer and a price guard, which the pilot has not appointed.

Before third-party funds, the independent external audit the project already requires,
the Safe and recovery transition (P-12), monitoring of issuers and of market price against
feeds, and a decision on the guard changes above remain necessary. The vault is
permissionless: the own-funds scope is an operating policy, not an on-chain barrier.
