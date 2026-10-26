# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/global-reserve/gret-contracts/security/advisories/new),
or by email to **pernandoparauflo@gmail.com**. Do not open a public issue or pull request
about a security problem.

Please include:

- a description of the issue and its impact;
- the affected contract, function or script;
- the steps or a proof of concept to reproduce it.

The report will be acknowledged and you will be kept informed while it is investigated and
fixed. There is no bug bounty program at this time.

## Scope

In scope:

- `contracts/GRETVault.sol`, `contracts/ChainlinkPriceGuard.sol` and their deployments listed
  in the [README](README.md#deployments).
- The pilot scripts in `scripts/pilot/`, insofar as they could make a signer send a
  transaction other than the one shown.

Out of scope:

- The test mocks in `contracts/mocks/` and the test suites.
- Vulnerabilities in the component tokens themselves, which belong to their issuers.
- The risks already accepted and documented in
  [`docs/ACCEPTED_RISKS.md`](docs/ACCEPTED_RISKS.md).

## Status

The contracts have had internal reviews, not an independent audit. Issues that were fixed
are not listed; every risk that was accepted, with its reason and mitigation, is in
[`docs/ACCEPTED_RISKS.md`](docs/ACCEPTED_RISKS.md). Nothing so far clears the vault for
material third-party capital.
