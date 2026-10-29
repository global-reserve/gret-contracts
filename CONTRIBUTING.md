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
  so. A risk is accepted only with an entry in [docs/ACCEPTED_RISKS.md](docs/ACCEPTED_RISKS.md)
  and a test named after its ID in `test/GRETVault.risks.t.sol`; a fixed issue gets a test in
  `test/GRETVault.protections.t.sol`.

## Recording security reviews

Keep internal review results in the existing documents and tests, rather than creating a
dated report and a new test file for each pass:

- `docs/ACCEPTED_RISKS.md` is the canonical finding register. Compare against existing entries
  before adding a finding; extend an existing risk when appropriate. Keep confirmed findings
  pending a decision separate from accepted risks, with stable IDs, prerequisites, impact,
  proposed mitigation and links to executable evidence. Record the review date, source
  revision, scope, limitations and checks alongside the findings.
- `docs/SPECIFICATION.md` describes the current behavior and closed design decisions. Link
  to the register for finding details instead of copying a review report into it.
- Add reproduction tests and controls to existing files by subject. Risk reproductions,
  including pending findings, belong in `test/GRETVault.risks.t.sol`; use another existing
  subject-specific suite when it fits better. Preserve the distinction between reproducing
  an issue and testing its fix.
- Preserve existing dated reports as historical records. New internal review passes should
  update the register and existing suites; a separate report needs a specific reason, such
  as an external auditor's deliverable or an explicit request.
