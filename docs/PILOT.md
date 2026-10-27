# Ethereum mainnet pilot

Guide to deploy the vault, make the first mint of 1 GRET, redeem it and mint again. The
parameters are in [`scripts/pilot/config.ts`](../scripts/pilot/config.ts) and the
decisions in [`SPECIFICATION.md`](SPECIFICATION.md#mainnet-pilot).

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
   uses about 9.5M gas: at 1.35 gwei, about 0.013 ETH.
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
4. **Approve and mint.** Each approval is for the exact amount, never unlimited.
5. Check on Etherscan that the wallet holds 1 GRET. **Add GRET to MetaMask** shows it in
   the wallet with its logo.
6. Optional: **Redeem everything** and mint again, to test the exit with real funds.

Rejecting a signature sends nothing else; resume with the same button. After a reload,
the page remembers the vault in this browser; otherwise paste its address and click
**Use**.

## Afterwards

- Verify the vault's source code on Etherscan and Sourcify, and record the vault address in
  the README's Deployments table and in `SPECIFICATION.md`. Done on October 27, 2026.
- Later, hand governance over to a Safe, with the vault's two steps and 7-day wait.
- To rebalance, governance proposes the rebalancer (the pilot wallet itself) and a
  `ChainlinkPriceGuard` deployed with `PRICE_FEEDS` from `config.ts`; both take effect after
  7 days. Only the five components with a feed can be swapped, and SPYx, SGOVon and BILon
  not on weekends. The page only handles the deployment's basket: after a basket change, mint
  and redemption need the new component list.
