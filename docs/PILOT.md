# Ethereum mainnet pilot

Guide to deploy the vault, make the first mint of 1 GRET, redeem it and mint again. The
parameters are in [`scripts/pilot/config.ts`](../scripts/pilot/config.ts) and the
contract rules in [`SPECIFICATION.md`](SPECIFICATION.md). The October 27 deployment is
recorded at the end of this guide.

The immutable vault at `0x21b823334D2794a637cb9c0fd7fF8671b35F5A23` was deployed on
October 27 with recognized-reserve accounting. Current source uses live balances and is
**not deployed**. It cannot update that vault. The page's bytecode check will reject the
old deployment against the new build; do not bypass it. A compatible new vault/guard pair
and any voluntary migration need a separate deployment plan. The flow below can rehearse
the new build without changing the existing pilot.

The pilot wallet signs everything from MetaMask. The local page only builds the
transactions: it never sees a key.

## What can and cannot be undone

- **The deployment cannot.** The code is fixed at that address. The 11 tokens and the
  contents of 1 GRET change only through governance, and a new component, rebalancer or
  price guard takes 7 days; there is no rebalancer at deployment. If something went wrong, another
  vault is deployed.
- **The mint can.** While the pilot wallet is the only holder, it redeems everything and
  gets the 11 tokens back. In the rehearsal, the round trip lost 1 base unit of SPYx and 1
  of JAAAx to xStocks rounding. If someone else mints even a fraction of GRET, the minimum
  supply blocks redeeming the last part normally; the pilot wallet, as governance, then
  recovers everything through liquidation, which ends that vault.
- The contract is open: anyone can mint after the deployment. If someone else joins,
  redoing the vault requires that person to redeem first.

## Before starting

1. **ETH for gas.** Fund `0xe03E228E1f1c50a985556Cc9c05b0aB953Feb7fd` with about
   **0.03 ETH**. The full cycle (deploy, approve, mint, redeem, approve and mint again)
   historically used about 9.5M gas: at 1.35 gwei, about 0.013 ETH. Re-estimate the new
   build and current gas price before any deployment.
2. **Check in MetaMask** that this same account is selected.

## Rehearsal with MetaMask (recommended)

The same flow, with the pilot account and its real balances, on a local copy of mainnet.
Whatever is signed there cannot be replayed on mainnet: the signature includes the chain
id.

1. In a terminal: `npm run pilot:fork-node`. Leave it open.
2. In MetaMask, add a network manually:
   - Name: `GRET rehearsal`
   - RPC: `http://127.0.0.1:8545`
   - Chain ID: `31337`
   - Currency: `ETH`
3. In another terminal: `npm run pilot`, and open <http://127.0.0.1:8787>.
4. In MetaMask, select the `GRET rehearsal` network and connect the page. The green local
   rehearsal banner must appear.
5. Click **Add 1 test ETH**.
6. **Deploy**, then **Approve and mint** (12 signatures) and then **Redeem everything**.
   You can mint again to see the full cycle.

If the node restarts, the page's vault no longer exists: click **Forget**. If MetaMask
keeps waiting for old transactions, clear that network's activity data in MetaMask's
advanced settings.

There is also an automated rehearsal, without MetaMask: `npm run pilot:rehearse`.

## The real deployment

1. With `npm run pilot` running, select **Ethereum mainnet** in MetaMask. The red mainnet
   banner must appear.
2. **Deploy.** The page shows the parameters before signing. Write down the vault address
   shown once it is confirmed.
3. **Verify the contract.** It happens automatically. The 8 checks must be green: code
   identical to this repository's build, the 11 components in order, the amounts, the
   governance, no rebalancer, fees at zero, minting not paused, and the name and symbol.
   **If any fails, stop.**
4. **Approve and mint.** Each approval is for the exact amount, never unlimited. After
   approvals, the page requests a fresh plan before submitting mint. If live balances changed
   the required inputs or mint calldata, it stops and asks for review and retry. It does not
   silently raise approvals or input limits. A later change can still make mint revert safely.
   The mint accepts at most 0.1% fewer GRET than requested (`minShares`), covering xStocks
   rounding.
5. Check on Etherscan that the wallet holds 1 GRET. **Add GRET to MetaMask** shows it in
   the wallet with its logo.
6. Optional: **Redeem everything** and mint again, to test the exit with real funds. The
   redemption requires at least the quoted amounts.

Rejecting a signature sends nothing else; resume with the same button. After a reload,
the page remembers the vault in this browser; otherwise paste its address and click
**Use**.

## Afterwards

- Verify the vault's source code on Etherscan and Sourcify, and record the vault address in
  the README's Deployments table and in this guide. Done for the previous deployment on
  October 27, 2026.
- Later, hand governance over to a Safe, with the vault's two steps and 7-day wait.
- To rebalance, governance proposes the rebalancer (the pilot wallet itself) and a
  `ChainlinkPriceGuard` deployed with `PRICE_FEEDS` from `config.ts`; both take effect after
  7 days. Only the five components with a feed can be swapped, and SPYx, SGOVon and BILon
  not on weekends. The page only handles the deployment's basket: after a basket change, mint
  and redemption need the new component list.

## Unreadable component balances

If a token or the RPC cannot return a balance, the page stops with an explicit error. It does
not replace a missing balance with zero and does not silently omit assets from redemption.
The current page has no skipping-exit flow: `previewRedeemSkipping` and `redeemSkipping` must
be used through a separately reviewed interaction, with the holder explicitly accepting the
forfeited component share. Governance may consider a write-off or liquidation; a page failure
does not itself prevent independent healthy-component claims.

## October 27, 2026 deployment

This records the immutable vault deployed with the previous code, not the current source.
References here to `sync` and to withdrawing surpluses are functions of that deployed code.

- **Deployment:** `GRETVault` at `0x21b823334D2794a637cb9c0fd7fF8671b35F5A23` on Ethereum
  mainnet, October 27, 2026, 03:14 UTC, block 26,281,281, transaction
  `0x7ae2271ee3d7a81c04e78137c8d5eb12cc724656231eb6fa91bcfa0b45302467`, signed by the pilot
  wallet with MetaMask from the local page. Gas: 5,434,767 at 0.043 gwei, about 0.00023 ETH.
  The page's eight checks passed against mainnet right after the deployment, and
  `npm run test:fork` passed that day against a fresh fork. The source is verified on
  Sourcify with an exact match (creation and runtime bytecode) and, the same day, on
  Etherscan.
- **First mint:** 1 GRET to the pilot wallet, October 27, 2026, 03:26 UTC, block 26,281,343,
  transaction `0x9c72908baa94af16a1c209cc4a340964d1f75f7d1d0fe4e7f9ae3074288ece33`, after
  eleven approvals for the exact amounts. Gas: 1,154,288. The vault received the basket
  except 1 base unit of SPYx and 1 of JAAAx, lost to xStocks rounding, as in the rehearsal.
- **Pilot wallet:** `0xe03E228E1f1c50a985556Cc9c05b0aB953Feb7fd`, an EOA. It deploys,
  makes the first mint and is the initial governance. Deploying gives no power over the
  vault. There is no rebalancer or price guard at deployment; if the pilot needs a rebalance,
  the wallet proposes itself and a `ChainlinkPriceGuard` deployed with `PRICE_FEEDS`, and
  both take effect after 7 days. Handing governance to a Safe is left for later, with the
  vault's two steps and 7-day wait. Whoever obtains that key can activate liquidation, which
  is irreversible although holders still claim everything per component, withdraw surpluses
  and, after a 7-day wait visible on chain, appoint a rebalancer and a guard that accepts
  every swap, and exchange the reserves at any price. Losing it leaves the vault without
  anyone to activate liquidation, sync or change the basket. Fees stay at zero; if they are
  ever turned on, the fee recipient is this same wallet.
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
  code deployed on October 27): the real wallet, with its balances, deploys, verifies the
  vault, approves exact amounts, mints 1 GRET, redeems it and mints again. Gas: deployment
  5.43M; each approval between 54k and 60k; the first mint in a new vault 1.15M, because it
  writes empty storage; the full redemption 0.53M; the full cycle 9.46M. The round trip lost
  1 base unit of SPYx and 1 of JAAAx. The MetaMask rehearsal on a local fork was skipped: the
  page was first used for the mainnet deployment and mint, after the automated rehearsal ran
  against mainnet state shortly before.
- **Tools:** `scripts/pilot/plan.ts` builds the transactions and verifies a vault against
  this repository (code identical to its build, components, amounts, governance, no
  rebalancer, fees at zero, minting not paused, name and symbol). The October 27 vault passed
  all eight checks with the build of that day; against the current build it fails the code
  check by design. The page (`npm run pilot`) only sends what that module returns; the
  automated rehearsal uses the same module. Both assume the deployment's basket: after a
  basket change, mint and redemption need the new component list.

Pending for this deployment:

- MetaMask flags the approvals and the mint as malicious (a Blockaid alert, common for new
  contracts that receive approvals of many tokens). The vault only pulls tokens from the
  caller of `mint` or `swap`, so it is a false positive still to be reported.
- The manual MetaMask rehearsal on a local fork, skipped before the deployment.
