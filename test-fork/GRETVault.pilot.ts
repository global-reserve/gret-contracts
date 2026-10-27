import assert from "node:assert/strict";
import { after, describe, it } from "node:test";

import { network } from "hardhat";
import { type Address, erc20Abi, parseEther } from "viem";

import { PILOT } from "../scripts/pilot/config.js";
import {
  components,
  deployTransaction,
  INITIAL_SHARES,
  mintTransactions,
  type PlannedTx,
  type Reader,
  redeemTransaction,
  verifyVault,
  wallet,
  walletStatus,
} from "../scripts/pilot/plan.js";

/**
 * Rehearses the mainnet pilot on a fork: the pilot wallet, with its real balances, sends the
 * exact transactions the local page would send. No key is needed: the fork impersonates it.
 *
 * MAINNET_RPC_URL is required; MAINNET_FORK_BLOCK optionally pins the block.
 */
const RPC_URL = process.env.MAINNET_RPC_URL;
const FORK_BLOCK = process.env.MAINNET_FORK_BLOCK ? BigInt(process.env.MAINNET_FORK_BLOCK) : undefined;
// Base units a transfer may lose to rounding in tokens that store shares (xStocks).
const ROUNDING = 10n;

describe("GRET pilot rehearsal on a mainnet fork", { skip: RPC_URL === undefined && "MAINNET_RPC_URL is not set" }, async () => {
  const connection = await network.create({
    override: { forking: { url: RPC_URL ?? "", blockNumber: FORK_BLOCK } },
  });
  const { viem, networkHelpers } = connection;
  after(() => connection.close());

  it("the pilot wallet deploys, mints 1 GRET, redeems it all and mints again", async () => {
    const publicClient = await viem.getPublicClient();
    const client = publicClient as unknown as Reader;
    console.log(`Fork at block ${await publicClient.getBlockNumber()}; pilot wallet ${PILOT.wallet}`);

    await networkHelpers.impersonateAccount(wallet);
    await networkHelpers.setBalance(wallet, parseEther("1"));
    const walletClient = await viem.getWalletClient(wallet);
    const gas: { step: string; gas: bigint }[] = [];
    const send = async (tx: PlannedTx) => {
      const hash = await walletClient.sendTransaction({ to: tx.to, data: tx.data });
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      assert.equal(receipt.status, "success", tx.label);
      gas.push({ step: tx.label, gas: receipt.gasUsed });
      return receipt;
    };

    const start = await walletStatus(client, wallet);
    for (const [i, c] of components.entries()) {
      assert.ok(start.balances[i] >= c.amount, `not enough ${c.symbol} for 1 GRET`);
    }

    const vault = (await send(deployTransaction())).contractAddress as Address;
    for (const check of await verifyVault(client, vault)) assert.ok(check.ok, check.label);

    const first = await mintTransactions(client, vault, wallet);
    assert.deepEqual(first.needed, components.map((c) => c.amount));
    assert.equal(first.txs.length, components.length + 1, "11 approvals and the mint");
    for (const tx of first.txs) await send(tx);

    const minted = await walletStatus(client, wallet, vault);
    assert.equal(minted.vault?.gret, INITIAL_SHARES);
    assert.equal(minted.vault?.supply, INITIAL_SHARES);
    assert.equal(minted.vault?.hasMinted, true);
    for (const [i, c] of components.entries()) {
      // Share-based tokens can also debit a few units less than requested, depending on
      // the sender's existing fractional balance. Other components must remain exact.
      const tolerance = c.symbol === "SPYx" || c.symbol === "JAAAx" ? ROUNDING : 0n;
      const paid = start.balances[i] - minted.balances[i];
      assert.ok(paid <= c.amount && paid + tolerance >= c.amount, `${c.symbol}: paid ${paid} of ${c.amount}`);
      const reserve: bigint = minted.vault?.reserves[i] ?? 0n;
      assert.ok(reserve <= c.amount && reserve + tolerance >= c.amount, `${c.symbol} reserve`);
      const held = await publicClient.readContract({
        address: c.address,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [vault],
      });
      assert.equal(held, reserve, `${c.symbol} actual backing`);
      assert.ok(reserve <= paid, `${c.symbol} credited more than the wallet paid`);
    }

    const redeem = await redeemTransaction(client, vault, wallet);
    assert.ok(redeem);
    await send(redeem);
    const redeemed = await walletStatus(client, wallet, vault);
    assert.equal(redeemed.vault?.supply, 0n);
    for (const [i, c] of components.entries()) {
      const lost = start.balances[i] - redeemed.balances[i];
      assert.ok(lost >= 0n && lost <= 2n * ROUNDING, `${c.symbol}: lost ${lost} base units in the round trip`);
    }

    const second = await mintTransactions(client, vault, wallet);
    for (const tx of second.txs) await send(tx);
    assert.equal((await walletStatus(client, wallet, vault)).vault?.supply, INITIAL_SHARES);

    const total = gas.reduce((sum, g) => sum + g.gas, 0n);
    console.table([...gas, { step: "Total", gas: total }].map((g) => ({ step: g.step, gas: g.gas.toString() })));
    console.log(
      "Base units lost per component in the mint and full redemption:",
      Object.fromEntries(components.map((c, i) => [c.symbol, (start.balances[i] - redeemed.balances[i]).toString()])),
    );
  });
});
