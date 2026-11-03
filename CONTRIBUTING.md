# Contributing

Thanks for your interest in GRET. Security issues must not be reported here: follow
[SECURITY.md](SECURITY.md). By participating you agree to the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Setup

```sh
nvm use      # Node.js 24.14.1, from .nvmrc
npm ci       # exact, pinned dependencies
npm run check
```

`npm run check` compiles the contracts, type-checks the TypeScript and runs every test. It
must pass before a pull request is reviewed; CI runs it on every push and pull request.

## What to run for each change

| Change | Also run |
| --- | --- |
| `contracts/GRETVault.sol` | `npm run test:deep`, `npm run pilot:rehearse` and, with `MAINNET_RPC_URL`, `npm run test:fork` |
| `contracts/ChainlinkPriceGuard.sol` | `npm run test:deep` and, with `MAINNET_RPC_URL`, `npm run test:fork` |
| `scripts/pilot/` | `npm run pilot:rehearse` |
| Tests or documentation only | `npm run check` |

Coverage (`npm run test:coverage`) rewrites the build artifacts: do not run it at the same
time as the deep, fork or rehearsal tests.

## Conventions

- Everything is written in English: code, comments, user-facing strings, documentation and
  commit messages.
- Solidity 0.8.38 with exact pragmas; document external functions with NatSpec and use custom
  errors.
- Tests use Hardhat 3, viem and `node:test` in TypeScript, and forge-std for Solidity fuzz,
  invariant and case tests.
- Mocks do not prove compatibility with the real issuers; the mainnet fork tests do.
- A design decision is not closed until [docs/SPECIFICATION.md](docs/SPECIFICATION.md) says
  so. A limitation is accepted only when the specification describes it under "Known
  limitations" and a test in `test/GRETVault.limitations.t.sol` reproduces it; a fixed issue
  gets a test in `test/GRETVault.protections.t.sol`.

## Recording security reviews

References go one way: a review cites the specification and the code it reviewed; the
specification and the code never cite a review.

- Each review is one report in `docs/audits/`, named with its date and reviewer. It states
  the commit it reviewed, its scope, method and limitations, and its findings with their
  evidence. Once published, a report is not rewritten to follow later code: a later review
  writes a new report.
- An accepted finding becomes a known limitation in the specification, written in its own
  words, without report or finding IDs. A finding judged invalid needs no entry.
- Add tests to the existing suites by subject: reproductions of accepted limitations in
  `test/GRETVault.limitations.t.sol`, regression tests of fixed issues in
  `test/GRETVault.protections.t.sol`. Preserve the distinction between reproducing an issue
  and testing its fix.
