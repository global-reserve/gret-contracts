# GRETVault security review — October 27, 2026

This is an AI-assisted internal security review conducted by OpenAI Codex with
GPT-6 Astra in Ultra mode, not an independent audit by a security firm, a formal
verification, or a certification. It covers the source at
commit `25a50a290e1ba6ac426e418cecc8ef5dabce70b9`, plus three audit tests added during
the review and one corrected pilot-test assertion. Production contracts were not
changed. No mainnet transaction was sent.

**Result: no new exploitable defect was confirmed within the reviewed scope.**
The proportional accounting and liquidation model held under the exercised
assumptions. Several already accepted risks can nevertheless cause material loss
or prevent an exit. Their acceptance does not reduce their technical impact.
This review does not establish readiness for third-party funds.

One low-severity validation defect was confirmed in the pilot rehearsal: it
incorrectly required exact sender debits for share-based xStocks. It was corrected
without changing vault behavior; the original failure and correction are recorded
below.

The most important distinction is between permissionless accounting attacks and
the powers entrusted to governance, issuers and price feeds. No permissionless
reserve drain was reproduced. A hostile governance can replace the price guard
and rebalancer after notice, and an honest guard cannot bound losses it cannot
observe. Some holders cannot use the notice period to exit completely.

## Reviewer identity and model configuration

The reviewer was an OpenAI Codex coding agent with access to the local repository,
command execution, auxiliary agents and public read-only network sources. The
agent examined the implementation, generated additional tests, ran tools and
authored this report. No independent human auditor's examination or sign-off is
represented by this report.

| Item | Recorded configuration |
| --- | --- |
| Reviewing agent | OpenAI Codex |
| Coordinator model | GPT-6 Astra, configured identifier `gpt-6-astra` |
| Reasoning mode | Ultra, recorded effort `ultra` |
| Configuration evidence | Local session `turn_context` records for the review turns on October 27, 2026, including the initial turn at `13:36:33Z` and continuation at `13:44:53Z` |
| Review organization | One coordinating agent and three auxiliary agents with assigned specialties |
| Auxiliary-agent launch | Conversation context inherited; no explicit model or reasoning-effort override supplied |

The model and effort entries were verified from this review's local session
records when this disclosure was added, rather than inferred from the report's
style or from the machine's current default configuration alone. They identify the
configured model and mode; no dated model snapshot or independently attested
per-agent backend identity was available. Private session logs are not included
in the repository.

OpenAI describes Ultra as a mode that uses subagents for parallel work. The
specific division of work below records what actually happened in this review;
the mode label by itself establishes neither completeness nor security assurance.
[OpenAI documentation on models and Ultra](https://learn.chatgpt.com/docs/models#know-when-to-use-max-or-ultra).

## How the review was conducted

The request was to examine the vault with the seriousness appropriate to real
funds. The review used the existing specification as the intended behavior and
the accepted-risk register to distinguish known architectural choices from new
implementation defects. Because those documents were read before the source
review, this was not a blind assessment of the design.

The coordinating agent assigned these parallel passes:

| Pass | Areas examined | Additional evidence produced |
| --- | --- | --- |
| Accounting | Mint and redemption ratios, rounding, fees, supply floor, donations, latent losses and token callbacks | A property test combining receipt shortfalls, unrecognized losses, donations and fees |
| Liquidation | Activation, conversion, cumulative rights, partial payouts, recovery, sync, rescue, write-offs and component isolation | A mixed-sequence property test with an independent physical token ledger |
| Governance and rebalancing | Authorization, proposal delays and expiry, basket changes, index shifts, price-guard boundaries and weekly loss accounting | A property test using an address-keyed ledger across removals and re-additions |

The agents inherited the conversation context and shared the same working copy,
specification and risk register. They could exchange findings through the
coordinator. These were separate analytical passes within one AI-assisted
process, not independent audit organizations or a comparison of different models.
Common assumptions, shared context and model-related blind spots can therefore
affect all of the passes.

The coordinator performed the following work:

1. Established the source revision, dependency versions and intended behavior;
   read the vault and guard implementations, relevant dependencies and tests.
2. Examined state transitions, arithmetic and external-call boundaries, including
   ordinary operation, basket mutation and irreversible liquidation. Candidate
   issues were checked for authorization requirements, token assumptions,
   economic consequences and overlap with documented risks.
3. Cross-checked the specialist conclusions and reviewed their added tests. The
   coordinator compiled and executed the shared tests; the three auxiliary agents
   did not each independently run the full validation suite or mainnet checks.
4. Ran the original suite, the expanded suite and deep fuzz/invariant profile;
   inspected Slither results individually rather than treating detector labels
   as confirmed vulnerabilities. The production-only analysis build and tool
   compatibility adjustment are disclosed in the static-analysis section.
5. Read public mainnet state at a pinned block, compared deployed runtime bytecode
   with the normal build, checked balances against reserves, simulated the existing
   holder's full exit and ran the fork and pilot tests. All state-changing test
   operations occurred on local simulated networks.
6. Investigated the pilot assertion failure, recorded its original counterexample,
   corrected only the test assumption and reran the same block. Re-ran the project
   checks after the test change.
7. Consolidated the evidence and requested an auxiliary factual review of the
   draft's references, severity wording and claims. That cross-check clarified the
   distinction between nominal liquidation rights and payouts bounded by backing.

The tools were local source inspection and Git, the pinned Hardhat/Solidity/
TypeScript toolchain, Node.js and Solidity tests, Slither 0.11.6, viem and JSON-RPC
reads, and targeted consultation of primary Solidity, OpenZeppelin and Chainlink
documentation. Detailed commands and results appear below.

The review's conclusions are the agents' interpretation of source and observed
tool results. Agreement between agents is not independent proof. The record
supports the stated findings and reproduced checks; it does not establish an
exhaustive attack search, formal correctness or the absence of undiscovered bugs.

## Scope and reproducibility

Primary scope:

- `contracts/GRETVault.sol`, all 1,022 lines.
- `contracts/ChainlinkPriceGuard.sol` and `contracts/IPriceGuard.sol`, because swaps
  rely on their behavior.
- The relevant pinned OpenZeppelin implementations: ERC20, SafeERC20, Math and
  ReentrancyGuardTransient.
- The specification, accepted risks, pilot configuration, and existing unit,
  adversarial, fuzz, invariant and fork tests.

The methodology above combined source-level examination by the agents with
executable properties, static analysis and public mainnet reads.

| Item | Reviewed value |
| --- | --- |
| Git commit | `25a50a290e1ba6ac426e418cecc8ef5dabce70b9` |
| Node / npm | `24.14.1` / `11.11.0` |
| Hardhat / OpenZeppelin | `3.18.0` / `5.6.1` |
| Solidity | `0.8.38+commit.1835d247` |
| Build | Optimizer enabled, 200 runs, Cancun EVM, legacy pipeline |
| GRETVault source SHA-256 | `4c3a02b92d12516a3aa6e500bdc3023481d79fefd2dea11c1761877b12cb642a` |
| ChainlinkPriceGuard source SHA-256 | `f8792d14ac26606b1f6b7e9bf01ff9043ebf0aa5d280cc0fbe341d2301c9ef96` |
| package-lock.json SHA-256 | `d52846b2e92abc56ced1c86cd43cf6f7a4320c05799bf0cfc5a8d9d1b0a4610b` |

The Solidity project's published bug list contained no entries for version
0.8.38 when checked during this review. That is a check for known compiler issues,
not proof that the compiler is defect-free.
[Solidity bugs by version](https://raw.githubusercontent.com/argotorg/solidity/develop/docs/bugs_by_version.json).

Excluded: a source audit of the eleven issuers' implementations or their future
upgrades; a governance voting system; rebalancing bots and external exchanges;
wallet/key custody; the pilot web server and browser security; legal eligibility;
and future integrations that use GRET as collateral. Fork execution tests token
compatibility at one block, not every issuer restriction or future behavior.

## Deployment checked

The public RPC snapshot is preserved in
[`2026-10-27-mainnet-snapshot.json`](2026-10-27-mainnet-snapshot.json).

| Item | Observation at the pinned block |
| --- | --- |
| Network / vault | Ethereum mainnet / `0x21b823334D2794a637cb9c0fd7fF8671b35F5A23` |
| Block | `26284402`, `2026-10-27T13:39:59Z` |
| Block hash | `0x18d2139da1041dadbfe4e8bb8a2291ad23121dfa67b31c73b8c9e5b4173d10f3` |
| Runtime | Exact byte-for-byte match to the repository build, including metadata |
| Runtime size / Keccak-256 | 19,945 bytes / `0x5e0a588f8331248b54ee799650a9cdb022c36222471e36f18eecec00fe309c4b` |
| Supply | 1 GRET, all held by the pilot wallet, which has minted |
| Components / version | Eleven, matching the pilot configuration / `0` |
| Backing | Every component's actual balance equaled its recorded reserve |
| Governance | Pilot address `0xe03E228E1f1c50a985556Cc9c05b0aB953Feb7fd` |
| Rebalancer / price guard | Both zero; swaps unavailable |
| Pending governance / rebalancer / guard / fee proposal | None |
| Fees / fee recipient | Both zero / zero address |
| Mint pause / liquidation | Both inactive |

A read-only `eth_call` from the pilot address successfully simulated redeeming the
entire 1 GRET at that same block, with basket version zero and zero output minima.
Its eleven nominal outputs matched the recorded reserves. This is evidence that
the current holder could traverse the full exit path at that state; it is not an
executed withdrawal, an assertion about future transaction ordering, or a check of
recipient balance deltas. The recorded balances already reflect the one-unit
bootstrap shortfall in each xStock.

These observations apply only to the pinned block. The RPC response was not
independently verified against a second provider or a local Ethereum node.

## Material risks retained by the design

This section summarizes the risks documented in the project's risk register.
Impact labels describe conditional consequences; they must not be added to a
count of newly found vulnerabilities. Detailed acceptance decisions remain in
[`ACCEPTED_RISKS.md`](../ACCEPTED_RISKS.md).

| Priority | Existing risk | Preconditions and impact | Evidence |
| --- | --- | --- | --- |
| Critical impact, privileged | R-01: governance can replace the trading controls | Governance compromise or collusion; after the waits, reserve value can be exchanged away | `GRETVault.sol:468`, `:528`, `:576`; `test_R07_pauseKeepsNonMinterInDuringNotice` |
| High impact, conditional | R-03: a feed can overvalue a token that depegs | Rebalancer access and a token trading below its feed; healthy sellable reserves can be exchanged for impaired assets without a recorded oracle loss | `ChainlinkPriceGuard.sol:103`, `:134`; `test_R03_depegTheFeedDoesNotSeeIsNotLimited` |
| Medium impact, permissionless griefing | R-09: the 1 GRET supply floor prevents full exit by the remaining holders | Another holder retains any positive fraction; almost 1 GRET can remain inaccessible through normal redemption | `GRETVault.sol:892`; `test_R09_tinyMintHoldsBackLastHolder` |
| High impact in a hostile-governance scenario | R-07: mint eligibility can prevent exit during notice | Holder never minted and minting is paused or a required component cannot be deposited | `GRETVault.sol:258`, `:876`; both R-07 tests |
| High impact, issuer-dependent | R-10/R-12/R-13/R-14: issuer behavior can defeat delivery or fairness | Token upgrades, freezes, no-op transfers, sender surcharges, or unreadable balances | `GRETVault.sol:424`, `:881`, `:911`, `:946`; risk and adversarial tests |
| Medium to high impact, amount-dependent | R-04/R-06/R-08: recoveries and distributions need governance, and late entrants can share in them | Unsynced value, recovered write-offs, or a public favorable operation with minting open | `GRETVault.sol:271`, `:343`, `:714`; R-08 tests |

### Governance notice does not guarantee a complete exit

The role transitions correctly enforce their seven-day wait and execution window.
That mechanism does not constrain the economic quality of a replacement guard.
A captured governance can nominate a permissive guard and an attacker rebalancer,
wait, then use `swap` to exchange valuable reserves for negligible quantities of
another component. At the checked block neither role was appointed, so this path
required future administrative actions and their waits.

There are two independent obstacles to exiting during notice: a wallet that never
minted may be unable to qualify, and the last holders may hit `MIN_SUPPLY`.
`redeemSkipping` isolates a broken component but does not bypass those rules.
Liquidation removes both normal-exit constraints, but only governance can activate
it. A hostile or lost governance key is therefore relevant to exit availability.

P-12's Safe multisig and tested recovery procedure should be completed before
third-party funds. This reduces single-key risk; it does not remove authorized
collusion or change the vault's powers. Any stronger promise that all holders can
exit during notice would require a design change and, for this immutable vault,
a new deployment. No such architecture change was made or accepted by this review.

### The 2% limits are not a universal loss bound

Within one guard instance, the guard correctly measures each recorded swap loss
as a fraction of the priced reserve before that swap; temporary deposits and later
withdrawals do not restore spent budget. Rounding is conservative. It refuses
missing, stale, future-dated, nonpositive prices and swaps beyond the configured limits.

However, buying an impaired token at its reported feed price produces no measured
loss. A rebalancer can repeat such purchases against the healthy priced reserves.
The per-swap and weekly limits do not constrain that loss. The same limitation
applies when an issuer debits more than the nominal sale amount. Fixed week
boundaries also allow approximately 4% of feed-valued loss across two adjacent
budgets, as already accepted in R-02.

That budget is local to the guard instance. Replacing it starts a new counter;
R-02 documents the additional loss budgets possible around a
replacement. The approximately 4% figure above describes two adjacent weekly
budgets of the same guard, not an aggregate bound across guard replacements.

The five configured feeds cover 50% of the pilot's target weights. The other six
tokens cannot be traded through this guard. A feed can be fresh while its price
differs materially from executable token value. Monitor market/feed divergence and
issuer changes, not only `LossRecorded`; depeg trades may emit no such event.

### The minimum supply is an economic liveness risk

Example with zero fees: Alice holds the initial 1 GRET. Bob mints and keeps a tiny
positive fraction. Alice can redeem only until total supply reaches 1 GRET, so
almost all her original position remains. Bob need not cooperate to cause this.
Fee shares held by a separate recipient can create the same obstruction.

The bound is in GRET, not dollars. In this pilot, the initial entire basket was
approximately the value of 1 GRET, so this is substantial relative to pilot size.
The successful full-exit simulation is consistent with this: at the checked block
the pilot wallet still held the entire supply and the redemption fee was zero.
It does not protect against a later entrant. Consolidation permits a full normal
exit only when the redemption fee is zero. With a positive redemption fee, fee
shares remain in the supply even if the holder is also the fee recipient, so at
least 1 GRET remains until governance cuts the fee to zero or activates
liquidation (R-09). Liquidation irreversibly ends normal operation.

### External token failures remain a trust boundary

`SafeERC20` detects reverts and false return values; it cannot establish that an
issuer's successful call delivered real value. Redemption and claim minima bound
the nominal amount sent, not the recipient's balance increase. A successful no-op
transfer can consume liquidation rights. Sender surcharges can take backing from
remaining holders and prevent the last claim. When `balanceOf` reverts, exits use
recorded rights; a hidden shortfall can become first-come, first-served.

Activation itself performs no external token calls, and each claim touches only
its selected component. Those are useful containment properties. They do not make
a permanently failing token recoverable. R-21 and R-22 additionally cover stranded
rounding dust and GRET held in contracts that cannot invoke the exit functions.

### A recovered loss is not automatically restored to its original holder

During ordinary operation, an explicit loss recognition lowers the recorded
reserve. A later recovery is surplus until governance syncs it, and the usual
surplus rules may permit rescue. Minting before a distribution or write-off
recovery is synced dilutes the historical holders' share of that recovered value.
A pause around the sync cannot exclude an entrant that arrived before the pause.

During liquidation, a claimant accepting a haircut consumes the full right for
that claim. A later balance recovery does not recreate that claimant's old right.
Governance policy P-2 provides an off-chain allocation of surplus, not an
enforceable recovery claim. New distributions synced later are a separate increase
in proportional entitlements. This distinction should stay explicit in holder
communications and incident procedures.

## Accounting properties checked

For normal operation, let `S` be supply, `R_i` the effective recorded reserve after
loss recognition, `d_i` the measured receipt and `M` the gross newly issued shares.
For every positive reserve, mint enforces:

```text
M <= floor(d_i * S / R_i)
(R_i + d_i) / (S + M) >= R_i / S
```

Thus a mint cannot dilute existing per-share backing under the receipt assumptions.
Fees partition `M` between the caller and recipient; they do not create unbacked
shares. Contributions to different components can overpay when one receipt is
short, but `minShares` permits refusal. A mint against an entirely empty basket is
rejected. The bootstrap has no prior holders and issues a fixed gross supply.

For a redemption that burns `b` shares, the payout is
`floor(b * R_i / S)`. Remaining per-share reserves cannot decrease from that
rounding. Skipping a component retains its reserve for other holders, or releases
it to surplus when supply reaches zero. Version binding prevents positional limits
from silently applying to a different basket after a removal and addition.

For liquidation, let `L` be the fixed original supply, `q_a` each account's
converted shares, `R` a component's entitlement basis, and `c_a` consumed rights:

```text
entitlement_a = floor(q_a * R / L)
pending_a = entitlement_a - c_a
C = sum(c_a)
owed = R - C
sum(pending_a) <= owed
```

An ordinary claim pays at most its pending right, or its rounded-down share of
available balance when there is a shortfall. Consumed rights and paid amounts are
tracked separately. `sync` adds only the balance above `owed`; it cannot make the
enlarged outstanding entitlement basis exceed backing when a positive sync occurs.
After a loss, nominal pending rights can exceed the balance; `_payout` bounds what
can actually be paid. Failed transfers revert all claim updates.
The component array is frozen during liquidation. Cumulative per-account
conversion avoids gaining extra rights by splitting conversions.

These arguments assume truthful, non-adversarial balance observations and the
transfer behavior stated by the tested token models. The accepted issuer risks
are explicit exceptions. They are not proofs over arbitrary external contracts.

## Added coverage

The original suite passed 166 tests. Three gaps were addressed with additional
tests, all passing in the regular profile:

| New test | Gap addressed | Main properties |
| --- | --- | --- |
| [`GRETVault.audit-accounting.t.sol`](../../test/GRETVault.audit-accounting.t.sol) | Existing stateful handler uses exact receipts and immediately recognizes slashes | Combine 0–10 unit receipt shortfalls, unrecognized losses, donations and both fees; backing per share does not decrease and mint/redeem does not profit |
| [`GRETVault.audit-liquidation.t.sol`](../../test/GRETVault.audit-liquidation.t.sol) | Need an additional independent physical ledger across recovery sequences | Five holders, 30 mixed operations and actual final exits; conservation, delivery, cumulative rights, claim solvency and rescue preserving backing |
| [`GRETVault.audit-governance.t.sol`](../../test/GRETVault.audit-governance.t.sol) | Existing handler only adds and removes the final component | Address-keyed ledger across first/middle/last removals, swaps, shifts, sync, re-addition, mint/redeem, stale versions and zero-supply restart |

The extra accounting fuzz uses requested shares of at least 1 GRET and finite
reserve bounds; existing tests cover smaller normal operations separately. The
liquidation test intentionally uses only 997 base units to expose rounding. The
basket test uses a permissive mock guard to isolate bookkeeping and makes no
claim about price safety. None of these mocks proves real issuer compatibility.

## REVIEW-L01 — Pilot rehearsal incorrectly requires exact xStock debits

**Severity:** Low, validation tooling. **Status:** Test corrected; final rerun result
is recorded in the validation table. No loss of backing or contract exploit was
demonstrated.

**Location:** Original `test-fork/GRETVault.pilot.ts:74`, at the reviewed commit.

**Evidence:** The unmodified rehearsal failed at block 26284402 after its first
mint. The request for SPYx was `9789000000000000` base units, while the pilot wallet's
balance decreased by `9788999999999999`, exactly one base unit less. The assertion
required equality and stopped before the redemption and restart steps.

**Cause:** Converting requested amounts into internal token shares can also make
the sender's observed balance debit round down. The vault measures what it
receives; this observation did not show an excess debit or unbacked GRET. The
ordinary mainnet fork test already permitted a bounded lower debit at
`test-fork/GRETVault.mainnet.ts:215`.

**Impact:** The rehearsal produces a false failure for supported rounding behavior,
and never reaches its exit checks at this otherwise usable block. A test failure
should not be dismissed without checking both sides of the transfer.

**Correction:** Only SPYx and JAAAx may debit up to ten units less than requested;
all other components still require exact debits and exact reserve receipts. No
component may debit more than requested. The first-mint checks now also require
actual vault balance to equal the credited reserve and that credit not exceed the
wallet's debit. The exact GRET supply and bounded roundtrip-loss checks remain.
The same pinned block is used for the rerun, rather than avoiding the failure by
changing the block.

## Executed validation

| Check | Result |
| --- | --- |
| `npm ci` | Passed; pinned dependencies installed |
| Baseline `npm run check` | Passed: 166 tests |
| Expanded `npm run check` | Passed: 169 tests, 41 Solidity and 128 Node.js |
| `npm run test:deep` | Passed: all 41 Solidity tests; seven fuzz properties at 20,000 runs each and six invariants at 1,000 runs each |
| Mainnet fork, block 26284402 | Passed: all five tests, approximately 502 seconds |
| Original pilot rehearsal, block 26284402 | Failed on the exact-SPYx-debit assertion; REVIEW-L01 |
| Corrected pilot rehearsal, block 26284402 | Passed: deploy, approve, mint, redeem all and mint again; one base unit lost per xStock on the roundtrip |
| Deployment bytecode and state comparison | Passed at the pinned block |
| Full deployed-vault redemption via `eth_call` | Passed at the pinned block |
| Slither 0.11.6 | Completed: 29 detector results; no high-severity detector result |

Reproduce the contract checks with the pinned dependencies and an RPC that still
serves the selected block:

```sh
npm ci
npm run check
npm run test:deep
MAINNET_RPC_URL=<archive-rpc> MAINNET_FORK_BLOCK=26284402 npm run test:fork
MAINNET_RPC_URL=<archive-rpc> MAINNET_FORK_BLOCK=26284402 npm run pilot:rehearse
```

The deep profile uses 20,000 runs per fuzz test, and 1,000 sequences of depth 200
per stateful invariant. Sampling does not exhaust the state space, and the
original handler deliberately catches some reverts. Successful test counts alone
do not establish that every economic scenario was explored. Historical coverage
claims in the specification were not rerun as part of this review.

The fork was read from PublicNode. Initial sandbox network attempts failed before
test execution; the RPC-dependent runs were retried with network access. No live
transaction methods were used: all fork state mutations were local.

The corrected pilot completed at the original pinned block. The cycle used
9,461,434 gas in total, including deployment and approvals. Its mint/redeem
roundtrip lost one base unit each of SPYx and JAAAx, with zero loss for the other
nine components. A final `npm run check` also covers the changed TypeScript test.

### Static-analysis triage

Slither's Hardhat adapter did not resolve `project/test/...` source paths. The
analysis therefore used an isolated production-only build made with the same
pinned `solc`, source contents, optimizer settings and EVM target. Build artifacts
were kept outside the repository. This adaptation changes source-path metadata;
the exact deployed-bytecode comparison used the normal Hardhat build, not this
analysis build. Dependency-only findings were filtered from the displayed results.

| Detector category | Count | Assessment |
| --- | --- | --- |
| Medium: strict equality | 3 | Intentional checks for zero surplus, zero payout and invalid receipt; not price or timestamp equality dependencies |
| Medium: reentrancy without ETH | 1 | Guard called before reserve updates so it sees the pre-swap reserve; reserve mutations are guarded. Read-only integration risks remain R-15 |
| Medium: uninitialized local | 2 | Solidity initializes the local booleans `contributed` and `positive` to false |
| Medium: unused return | 1 | Deliberately unused round metadata; positive price and timestamp freshness are checked |
| Low: external calls in loops | 7 | Basket traversal is inherent; hostile token gas use remains R-15 |
| Low: timestamps | 11 | Intended administrative waits, expiry, price freshness and week buckets |
| Informational: complexity | 2 | Reviewability observations, not reproduced exploits |
| Informational: missing inheritance | 1 | Vault structurally provides the interface read by the guard |
| Optimization: external self-call | 1 | `this.valueOf` enables per-component `try/catch` |

No medium detector result was confirmed as a new exploitable issue. This is a
manual disposition, not an inference that passing Slither makes a contract safe.
Chainlink documents `answeredInRound` as deprecated; retaining timestamp and
price validation is still essential, and admitting a different feed architecture
would need a separate review.
[Chainlink API reference](https://docs.chain.link/data-feeds/api-reference).

The transient reentrancy lock clears after each protected call. Its use relies on
an EIP-1153-enabled chain, consistent with the mainnet target and Cancun build.
The transient-storage compiler warning is not a finding that this lock remains
set across successful sequential calls.
[OpenZeppelin ReentrancyGuardTransient](https://docs.openzeppelin.com/contracts/5.x/api/utils#ReentrancyGuardTransient),
[EIP-1153](https://eips.ethereum.org/EIPS/eip-1153).

## Disposition

There is no newly confirmed contract defect here for which this review prescribes
an immediate source patch. The three added tests strengthen regression coverage;
the separate low-severity rehearsal defect was corrected in test code.
The remaining high-impact risks are architectural or external trust assumptions;
none was silently marked fixed or newly accepted.

For the existing own-funds pilot, the pinned state and successful exit simulation
support a narrower conclusion: the deployed code matches the reviewed code, its
recorded backing is present, and its current holder's ordinary exit simulated
successfully. They do not justify increasing funds without revisiting the risk
boundaries above.

Before third-party funds, complete the independent external audit already required
by the project, the Safe/recovery transition, tested incident and liquidation
procedures, monitoring of issuer changes and market/feed divergence, and explicit
holder disclosure of the eligibility rule and supply floor. The deployed vault is
permissionless: the own-funds scope is an operating policy, not an on-chain barrier
preventing others from minting. Architectural changes require a new vault and a
voluntary migration because this deployment is immutable.
