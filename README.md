# GRET contracts

[![CI](https://github.com/global-reserve/gret-contracts/actions/workflows/ci.yml/badge.svg)](https://github.com/global-reserve/gret-contracts/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Solidity 0.8.38](https://img.shields.io/badge/solidity-0.8.38-363636.svg)](https://docs.soliditylang.org/en/v0.8.38/)

Smart contracts for **Global Reserve Token (GRET)**: an ERC-20 share of a basket of tokenized
assets on Ethereum, minted and redeemed in kind.

**[Website](https://grt.finance)** · [Specification](docs/SPECIFICATION.md)

> [!WARNING]
> **Not audited by an audit firm.** An AI model, Claude Opus 5.5, audited this source at the
> project's request; its [report](docs/audits/2026-11-05-claude-opus-5-5.md) lists every finding and
> how each was fixed or documented. An earlier version of the vault, which that audit does not cover, is deployed on
> Ethereum mainnet as a pilot with the project's own funds, not meant for third parties. Nothing in
> this repository is an offer to buy or sell any asset, nor investment advice. Use it at your own
> risk.

The current source implements automatic live-balance accounting and has **not been deployed**.
The immutable October 27 pilot below still uses recognized reserves and governance `sync`.
A new vault and compatible guard require a separate deployment and migration decision.

## Overview

- **One contract, one token.** `GRETVault` is both the GRET ERC-20 and the vault that holds
  the basket: 11 tokenized assets, from equity, Treasury, credit, real-estate and commodity
  funds to gold and bitcoin.
- **In kind, without prices.** A mint deposits every component in proportion to the reserves
  and a redemption pays them out. Active balances include income and losses immediately. No
  oracle takes part in either.
- **Immutable.** No upgrades and no owner. Governance acts within limits the code enforces:
  new components, rebalancers, price guards, eligibility contracts, write-offs, fee raises and
  governance handovers wait 7 days in public; fees are capped at 5%; redemption can never be
  paused, though an appointed eligibility contract decides who may redeem.
- **Bounded rebalancing.** A rebalancer exchanges one component for another, and every swap
  must pass a price guard. `ChainlinkPriceGuard` refuses a swap that loses more than 2%, or
  one that would take more than 2% of the vault's priced backing in a week.
- **Open by default.** Anyone may mint and redeem. Governance may appoint an eligibility
  contract, after the same 7-day notice, that decides who may; it can remove it at once.
- **An exit for everyone.** Governance can start an irreversible liquidation in which every
  holder withdraws each component on its own, even if others fail.

## Architecture

```mermaid
flowchart TB
    Gov["Governance<br/>pilot wallet<br/>proposed: Safe → timelock → Governor"]
    Holders["Holders"]
    Vault["<b>GRETVault</b><br/>GRET token and reserves"]
    Rebalancer["Rebalancer"]
    Guard["<b>ChainlinkPriceGuard</b><br/>implements IPriceGuard"]
    Feeds["Chainlink price feeds"]
    Tokens["11 component tokens"]
    Eligibility["Eligibility contract<br/>optional, none at deployment"]
    Gov -->|"basket, activation, fees, pause, rescue, appointments, liquidation"| Vault
    Holders <-->|"mint, redeem, claim"| Vault
    Rebalancer -->|swap| Vault
    Vault -->|checkSwap| Guard
    Vault -.->|"canMint, canRedeem"| Eligibility
    Guard -->|latestRoundData| Feeds
    Guard -.->|"reads components and exclusions"| Vault
    Guard -->|"balanceOf; subtract incoming swap receipt"| Tokens
    Vault -->|"transfer, balanceOf"| Tokens
```

Only `GRETVault` holds funds. The price guard can only refuse a swap. Governance and the
rebalancer are addresses to the vault, so what stands behind them can change without
touching it. The [specification](docs/SPECIFICATION.md) is authoritative for the current code.

| Contract | Description |
| --- | --- |
| [`GRETVault`](contracts/GRETVault.sol) | The GRET token and the vault: mint, redemption, basket changes, rebalancing, fees, the optional eligibility contract and liquidation |
| [`ChainlinkPriceGuard`](contracts/ChainlinkPriceGuard.sol) | The first price guard: values both sides of a swap with Chainlink feeds and enforces the loss limits; no owner, nothing to change |
| [`IPriceGuard`](contracts/IPriceGuard.sol) | The one question the vault asks before every swap |
| [`IEligibility`](contracts/IEligibility.sol) | The questions the vault asks before a mint or a redemption, once governance appoints an eligibility contract |

## Documentation

| Document | Contents |
| --- | --- |
| [Specification](docs/SPECIFICATION.md) | Design, rules, implementation details, operating assumptions and known limitations |
| [Mainnet pilot](docs/PILOT.md) | Steps to deploy the vault and make the first mint, and the record of the October 27 deployment |
| [Audit report](docs/audits/2026-11-05-claude-opus-5-5.md) | The audit of tag `audit-2026-11` by Claude Opus 5.5, an AI model: findings, evidence and the status of each fix |
| [Security policy](SECURITY.md) | How to report a vulnerability |
| [Contributing](CONTRIBUTING.md) | Setup, what to run for each change and conventions |
| [Code of conduct](CODE_OF_CONDUCT.md) | Contributor Covenant 2.1 |

## Deployments

| Network | Contract | Address |
| --- | --- | --- |
| Ethereum mainnet | `GRETVault` (October 27 pilot; previous code) | [`0x21b823334D2794a637cb9c0fd7fF8671b35F5A23`](https://etherscan.io/address/0x21b823334D2794a637cb9c0fd7fF8671b35F5A23) |

Basket at deployment, in the order of `components()`, with the amounts in the first GRET from
`initialAmounts()`. Addresses verified against each issuer's official sources; see the
[pilot guide](docs/PILOT.md#october-27-2026-deployment).

| # | Token | Asset | Address | In 1 GRET |
| ---: | --- | --- | --- | ---: |
| 0 | ITOTon | iShares Core S&P Total U.S. Stock Market ETF (Ondo) | [`0x0692481C369E2BDc728A69ae31b848343a4567Be`](https://etherscan.io/token/0x0692481C369E2BDc728A69ae31b848343a4567Be) | 0.0447 |
| 1 | SPYx | SPDR S&P 500 ETF Trust (Backed / xStocks) | [`0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48`](https://etherscan.io/token/0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48) | 0.009789 |
| 2 | EFAon | iShares MSCI EAFE ETF (Ondo) | [`0x4111b60bc87F2Bd1e81E783E271D7F0ec6EE088B`](https://etherscan.io/token/0x4111b60bc87F2Bd1e81E783E271D7F0ec6EE088B) | 0.07099 |
| 3 | IEMGon | iShares Core MSCI Emerging Markets ETF (Ondo) | [`0xcDD60D15125bf3362b6838D2506b0Fa33bc1a515`](https://etherscan.io/token/0xcDD60D15125bf3362b6838D2506b0Fa33bc1a515) | 0.03256 |
| 4 | SGOVon | iShares 0-3 Month Treasury Bond ETF (Ondo) | [`0x8De5D49725550f7b318b2FA0f1B1F118E98E8D0F`](https://etherscan.io/token/0x8De5D49725550f7b318b2FA0f1B1F118E98E8D0F) | 0.09729 |
| 5 | BILon | SPDR Bloomberg 1-3 Month T-Bill ETF (Ondo) | [`0x2710E30d84B376c34a3B3036aa196b26a83A321b`](https://etherscan.io/token/0x2710E30d84B376c34a3B3036aa196b26a83A321b) | 0.108 |
| 6 | JAAAx | Janus Henderson AAA CLO ETF (Backed / xStocks) | [`0x3bf2E3be4A829Bb3a5f5BE450AE4c8Eb3488da71`](https://etherscan.io/token/0x3bf2E3be4A829Bb3a5f5BE450AE4c8Eb3488da71) | 0.3953 |
| 7 | PAXG | Physical gold (Paxos) | [`0x45804880De22913dAFE09f4980848ECE6EcbAf78`](https://etherscan.io/token/0x45804880De22913dAFE09f4980848ECE6EcbAf78) | 0.004936 |
| 8 | cbBTC | Bitcoin (Coinbase) | [`0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf`](https://etherscan.io/token/0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf) | 0.00003081 |
| 9 | VNQon | Vanguard Real Estate ETF (Ondo) | [`0xcCAe8843E26259278C200C6506F6E5A3bdD524cd`](https://etherscan.io/token/0xcCAe8843E26259278C200C6506F6E5A3bdD524cd) | 0.02658 |
| 10 | DBCon | Invesco DB Commodity Index Tracking Fund (Ondo) | [`0x20224080aD516769723c9a4A18325fC4E8C9Ab5D`](https://etherscan.io/token/0x20224080aD516769723c9a4A18325fC4E8C9Ab5D) | 0.2974 |

## Getting started

Requires Node.js 24.14.1 (`.nvmrc`) and npm 11.

```sh
nvm use
npm ci
npm run check
npm run demo
```

`check` compiles, type-checks the TypeScript and runs the tests. `demo` deploys, on an
ephemeral local blockchain, 11 mocks with the basket's symbols and decimals plus the vault,
makes the first mint of 1 GRET and prints addresses and reserves. A Hardhat test account
stands in for governance.

## Commands

| Command | Use |
| --- | --- |
| `npm run compile` | Compile Solidity and generate the contract types |
| `npm test` | Run the tests |
| `npm run typecheck` | Compile and type-check TypeScript |
| `npm run check` | Type-check and run the tests |
| `npm run test:coverage` | Run the tests with coverage |
| `npm run test:deep` | Long fuzz and invariant runs (about 7 minutes) |
| `npm run test:fork` | Test the vault with the 11 real components on a mainnet fork |
| `npm run pilot:rehearse` | Rehearse the pilot on a mainnet fork with the pilot wallet |
| `npm run pilot:fork-node` | Local mainnet fork at `127.0.0.1:8545`, to rehearse with MetaMask |
| `npm run pilot` | Local pilot page at `127.0.0.1:8787`, to sign with MetaMask |
| `npm run node` | Start a local node at `127.0.0.1:8545` |
| `npm run deploy:local` | Deploy the mocks and the vault on that node |
| `npm run demo` | Deploy the mocks and the vault on an ephemeral local network |
| `npm run clean` | Remove Hardhat artifacts |

`test:fork` needs `MAINNET_RPC_URL`. Without `MAINNET_FORK_BLOCK` it uses the latest block
and prints which one; pinning a block requires an RPC with historical state. For example:

```sh
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com npm run test:fork
```

The mainnet pilot is explained step by step in [`docs/PILOT.md`](docs/PILOT.md).

To keep a local network between runs, leave `npm run node` open in one terminal and run
`npm run deploy:local` in another. Hardhat provides the test accounts; no private keys need
to be configured. The state lasts while the node is running.

## Interface

Functions of `GRETVault`, besides the standard ERC-20 ones and EIP-2612 `permit`:

| Function | Who | What it does |
| --- | --- | --- |
| `mint(shares, to, maxAmountsIn, minShares, version)` | Anyone, or whom the eligibility contract approves | The caller contributes every component with a reserve in proportion; `to` receives the GRET, minus the mint fee; the first mint issues exactly 1 GRET |
| `redeem(shares, to, minAmountsOut, version)` | Any holder, or whom the eligibility contract approves | Pays the redemption fee in GRET and burns the rest; `to` receives every component; redeeming the whole supply pays no fee; all or nothing; leaves the supply at 0 or at least 1 GRET |
| `redeemSkipping(shares, to, minAmountsOut, skipped, version)` | Any holder, or whom the eligibility contract approves | Same redemption without the listed components, which are not called; listed addresses outside the basket are ignored; the caller gives up its share of them; leaving zero supply pauses minting |
| `convertToClaims(shares)` | Any holder | During liquidation, burns GRET in exchange for per-component rights |
| `claim(i, to, minAmount)` | Whoever converted | Withdraws the pending right over component `i` |
| `activateLiquidation()` | Governance | With positive supply, freezes the share denominator and closes mint/normal redemption without token calls |
| `activateComponent(token)` | Governance | Includes a newly added or excluded component in normal backing; retains write-off history |
| `deactivateEmptyComponent(token)` | Governance | Excludes an empty component so later dust cannot reactivate it; at most ten base units allowed only for tokens with at least 18 decimals |
| `rescue(token, to, amount)` | Governance | Withdraws foreign tokens, or ordinary components only with zero normal supply; never historically written-off tokens; reverts if another component's balance drops |
| `proposeGovernance(next)` / `cancelGovernanceProposal()` | Governance | Proposes or discards the next governance |
| `acceptGovernance()` | Proposed governance | Takes over the role, 7 to 14 days after the proposal |
| `swap(sell, sellAmount, buy, buyAmount, guardData)` | Rebalancer | Delivers `buyAmount` of one component and takes `sellAmount` of another's reserve; the price guard must accept it and receives `guardData` unchanged |
| `proposeRebalancer(next)` / `cancelRebalancerProposal()` / `revokeRebalancer()` | Governance | Proposes or discards the next rebalancer, or removes the current and pending ones at once |
| `acceptRebalancer()` | Proposed rebalancer | Takes over the role, 7 to 14 days after the proposal; there is none at deployment |
| `proposePriceGuard(guard)` / `cancelPriceGuardProposal()` | Governance | Proposes or discards the contract that must accept every swap; never the vault or an EIP-7702 account |
| `applyPriceGuard()` | Anyone | Applies the proposed guard, 7 to 14 days after the proposal; there is none at deployment, and without one there are no swaps |
| `announceComponent(token)` / `cancelComponentAnnouncement(token)` | Governance | Announces or discards a new component; at most 128 waiting at once; never the vault or an EIP-7702 account |
| `addComponent(token)` | Anyone | Adds an announced component, 7 to 14 days later, initially excluded |
| `removeComponent(token)` | Governance | Removes an empty ordinary component under the bounded dust rule, never a written-off one; later indices shift |
| `setMintPaused(paused)` | Governance | Pauses or resumes minting at once; a write-off and a skipping exit that empties the supply also pause it; redemption is never paused |
| `proposeEligibility(next)` / `cancelEligibilityProposal()` / `removeEligibility()` | Governance | Proposes or discards the contract that decides who may mint and redeem, or removes the current one at once; never the vault or an EIP-7702 account |
| `applyEligibility()` | Anyone | Applies the proposed eligibility contract, 7 to 14 days after the proposal; there is none at deployment, and without one anyone may mint and redeem |
| `setInitialAmounts(amounts, version)` | Governance | Sets the basket of the first mint, used only while the supply is zero |
| `proposeWriteOff(token)` / `cancelWriteOff(token)` | Governance | Proposes or discards writing off a component that stopped working; governance judges it |
| `writeOffComponent(token)` | Anyone | 7 to 14 days later, excludes the component without reading it and pauses minting; the token stays registered and permanently non-rescuable |
| `proposeFees(mintFee, redeemFee)` / `cancelFeesProposal()` | Governance | Sets the fees in basis points, at most 5% each: a cut applies at once, a raise waits 7 days |
| `applyFees()` | Anyone | Applies a proposed raise, 7 to 14 days after it |
| `setFeeRecipient(recipient)` | Governance | Chooses who receives the fees, in GRET |

Governance is currently the pilot wallet. The proposed progression is Safe, then a timelock,
then a Governor with a separate VORA voting token; it is not implemented. GRET does not vote. A
proposal that waited 7 days expires if nobody executes or accepts it in the following 7 days
(`EXECUTION_WINDOW`). Amounts per GRET are not stored: they follow the reserves, so rebalancing
means swapping what the vault holds. The vault rejects GRET sent to its own address.

The views `previewMint`, `previewRedeem`, `previewRedeemSkipping`, `reserves`, `pendingRights`
and `claimable` compute current amounts outside mutations. In liquidation `reserves` returns
effective nominal bases, not remaining token balances; `liquidationBasis` returns only the
stored bases established by successful claims, and `totalConsumedRights` and `totalPaid` the
rights consumed and the amounts paid per component. `governanceProposal`, `rebalancerProposal`,
`priceGuardProposal` and `eligibilityProposal` return each pending successor and when it can take
over; an expired proposal stays there until it is cancelled or replaced.

`ChainlinkPriceGuard` is the first price guard. It values both sides of each swap with one
Chainlink feed per token and refuses a token without a fresh price, a swap that loses more
than 2% of what the vault sells, and swaps that would take more than 2% of the vault's priced
backing in a week: its active, readable components with a feed, measured at the moment of each
loss. A token whose decimals
change after the guard is deployed can no longer be swapped. It has
no owner: its feeds and limits are fixed at deployment, and changing them means appointing
another guard with the 7-day wait; the new guard continues the week's loss count of the one it
replaces. It ignores the `guardData` the vault forwards from the rebalancer. Mint, redemption and
liquidation never call it. The
proposed feeds are `PRICE_FEEDS` in `scripts/pilot/config.ts`; six of the 11 components have
no Ethereum feed and cannot be swapped.

Arrays of amounts follow the order of `components()`. `version` is the `basketVersion()` they
were prepared for: it grows with every addition or removal, and a call prepared for another
basket reverts with `BasketChanged` instead of applying a limit to another token. Redemption
minima that are all zero, or an empty array, limit nothing, so the redemption ignores `version`
and no basket change can refuse it for that reason.

## Repository layout

```text
contracts/GRETVault.sol              GRET token and vault: mint, redemption, live balances, rebalancing and liquidation
contracts/IPriceGuard.sol            What the vault asks the price guard in every swap
contracts/IEligibility.sol           What the vault asks an appointed eligibility contract before a mint or a redemption
contracts/ChainlinkPriceGuard.sol    Price guard with Chainlink feeds and loss limits per swap and per week
contracts/mocks/MockAggregator.sol   Test Chainlink feed with a price set by hand
contracts/mocks/MockPriceGuard.sol   Test guard that accepts every swap unless told to refuse
contracts/mocks/MockEligibility.sol  Test eligibility contract with a list and broken answers
contracts/mocks/MockERC20.sol        Test ERC-20 with configurable decimals
contracts/mocks/MockFaultyERC20.sol  Test ERC-20 with switchable faults
contracts/mocks/MockNoReturnERC20.sol Test token without a return value, like USDT
test/GRETVault.ts                    Setup, bootstrap, mint, redemption, losses and income
test/GRETVault.liquidation.ts        Activation, conversion and claims with failing components
test/GRETVault.governance.ts         Rescues, governance limits and governance transfer
test/GRETVault.timelock.ts           Governance that evolves with OpenZeppelin's TimelockController
test/GRETVault.rebalancing.ts        Rebalancer, price guard, swaps, adding, removing and writing off components
test/ChainlinkPriceGuard.ts          Chainlink price guard: prices and loss limits
test/ChainlinkPriceGuard.fuzz.t.sol  Fuzzing of the weekly loss limit
test/GRETVault.fees.ts               Mint and redemption fees
test/GRETVault.adversarial.ts        Reentrancy, non-standard tokens and issuer actions
test/GRETVault.protections.t.sol     Attacks and failures the vault refuses or lets holders get around
test/GRETVault.limitations.t.sol     One case per known limitation in the specification
test/GRETVault.accounting.t.sol      Live balances with short deliveries, losses, donations and fees
test/GRETVault.components.t.sol      Component removal keeps balances tied to token addresses
test/GRETVault.exits.t.sol           Exits with a redemption fee, unreadable balances and skipped components
test/GRETVault.governance.t.sol      Write-offs, basket versions, swap losses and proposal events
test/GRETVault.guard.t.sol           Guard replacement, written-off components and lagging feeds
test/GRETVault.eligibility.t.sol     The optional eligibility contract: notice, decisions, broken answers and removal
test/GRETVault.liquidation.t.sol     Liquidation conservation and shortfall claims under fuzzing
test/GRETVault.fuzz.t.sol            Property fuzzing in Solidity
test/GRETVault.invariant.t.sol       Invariants over random sequences of every operation, from several starting states
test/GRETVault.invariants.ts         Deterministic random sequences with invariants
test/MockERC20.ts                    Tests of the mocks with 18 and 8 decimals
test/helpers/basket.ts               Test basket shared by the vault tests
test/helpers/GRETVaultCase.sol       Setup and adverse tokens shared by the Solidity cases
test-fork/GRETVault.mainnet.ts       Vault, rebalancing and price guard with the real components and feeds on a mainnet fork
test-fork/GRETVault.pilot.ts         Pilot rehearsal with the real wallet on a mainnet fork
scripts/deploy-local.ts              Local deployment of 11 mocks and the vault
scripts/pilot/config.ts              Mainnet pilot parameters
scripts/pilot/plan.ts                Pilot transactions and checks
scripts/pilot/server.ts, index.html  Local page to sign the pilot with MetaMask
assets/gret-logo.svg, -256.png       GRET logo (SVG, and 256 px PNG for wallets and explorers)
hardhat.config.ts                    Compiler, plugins and local networks
foundry.toml                         Formatting only, for `forge fmt contracts`; Hardhat builds and tests the project
docs/SPECIFICATION.md                Specification: design, rules, implementation details and known limitations
docs/PILOT.md                        Mainnet pilot guide and record of the October 27 deployment
docs/audits/                         Audit reports, one per review, named with its date and reviewer
.github/workflows/ci.yml             Continuous integration: compile, type-check and test
CONTRIBUTING.md                      Setup, what to run for each change and conventions
CODE_OF_CONDUCT.md                   Contributor Covenant 2.1
.github/ISSUE_TEMPLATE/              Bug report and proposal forms; security reports go private
.github/pull_request_template.md     Pull request checklist
SECURITY.md                          How to report a vulnerability
```

The mocks start with zero supply and let anyone call `mint` to set up test scenarios.
`MockFaultyERC20` can revert or return `false` on transfers, revert on `balanceOf`, charge a
fee, deliver 1 wei less, reject zero transfers, block addresses, remove balance or reenter
the vault. They do not represent the real tokens or their issuer restrictions.

## Development notes

- Node.js **24.14.1** (`.nvmrc`) and npm **11.11.0**.
- Hardhat **3.18.0**, TypeScript ESM, viem and `node:test`.
- Solidity **0.8.38**, EVM Cancun, optimizer with 200 runs.
- OpenZeppelin Contracts **5.6.1** for the vault and the ERC-20 mocks.
- forge-std **1.17.0** for the Solidity fuzz and invariant tests.

Direct dependencies use exact versions and `package-lock.json` pins the whole tree. The
`solc` compiler is installed from npm and Hardhat loads it locally; once installed,
compiling and running the local tests needs neither an RPC nor another compiler download.

`package.json` pins `solc > tmp` to **0.2.7** to fix advisory
[GHSA-7c78-jf6q-g5cm](https://github.com/advisories/GHSA-7c78-jf6q-g5cm) in version 0.2.6,
which `solc` pulls in. Review this override when upgrading the compiler.

`hardhat.config.ts` also compiles OpenZeppelin's `TimelockController` (`npmFilesToBuild`)
for the governance integration tests; it is not part of the vault.

When compiling, `solc` prints a generic warning about transient storage (EIP-1153). It
comes from OpenZeppelin's `ReentrancyGuardTransient`. The warning itself states that using
it for reentrancy guards that are cleared at the end of the call is safe.

## Security

An AI model, Claude Opus 5.5, audited this source at tag `audit-2026-11` at the project's request,
and a second agent of the same model checked the fixes that followed; the
[report](docs/audits/2026-11-05-claude-opus-5-5.md) records
every finding, its status and its evidence. No audit firm has reviewed the contracts. Report
vulnerabilities privately as described in [SECURITY.md](SECURITY.md); the limitations accepted
by design are described in the [specification](docs/SPECIFICATION.md#known-limitations).

## License

MIT; see [LICENSE](LICENSE).
