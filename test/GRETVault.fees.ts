import assert from "node:assert/strict";
import { after, describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress, zeroAddress } from "viem";

import {
  balancesOf,
  deployBasket,
  INITIAL_AMOUNTS,
  INITIAL_SHARES,
  mulDivDown,
  NO_MAX,
  NO_MIN,
} from "./helpers/basket.js";

const SEVEN_DAYS = 7n * 24n * 60n * 60n;
const BPS = 10_000n;

describe("GRETVault: mint and redemption fees", async () => {
  const connection = await network.create("hardhat");
  const { viem, networkHelpers } = connection;
  after(() => connection.close());

  async function basketFixture() {
    return deployBasket(viem);
  }

  /** alice minted 1 GRET, bob 1/3 GRET; carol receives the fees, which are still zero. */
  async function holdersFixture() {
    const basket = await deployBasket(viem);
    const { vault, governance, alice, bob, carol } = basket;
    await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
    await vault.write.mint([INITIAL_SHARES / 3n, NO_MAX, 0n, 0n], { account: bob.account });
    await vault.write.setFeeRecipient([carol.account.address], { account: governance.account });
    return basket;
  }

  type Basket = Awaited<ReturnType<typeof deployBasket>>;

  async function raiseFees({ vault, governance }: Basket, mintFee: bigint, redeemFee: bigint) {
    await vault.write.proposeFees([mintFee, redeemFee], { account: governance.account });
    await networkHelpers.time.increase(SEVEN_DAYS);
    await vault.write.applyFees({ account: governance.account });
  }

  async function blockTimestamp(hash: `0x${string}`) {
    const publicClient = await viem.getPublicClient();
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    return (await publicClient.getBlock({ blockNumber: receipt.blockNumber })).timestamp;
  }

  describe("setting them", () => {
    it("start at zero without a recipient; only governance sets them, at most 5% each", async () => {
      const { vault, governance, alice } = await networkHelpers.loadFixture(basketFixture);
      assert.equal(await vault.read.mintFee(), 0n);
      assert.equal(await vault.read.redeemFee(), 0n);
      assert.equal(await vault.read.feeRecipient(), zeroAddress);
      assert.equal(await vault.read.MAX_FEE(), 500n);

      for (const call of [
        () => vault.write.proposeFees([1n, 1n], { account: alice.account }),
        () => vault.write.setFeeRecipient([alice.account.address], { account: alice.account }),
        () => vault.write.cancelFeesProposal({ account: alice.account }),
      ]) {
        await viem.assertions.revertWithCustomError(call(), vault, "NotGovernance");
      }
      for (const [mintFee, redeemFee] of [
        [501n, 0n],
        [0n, 501n],
      ]) {
        await viem.assertions.revertWithCustomErrorWithArgs(
          vault.write.proposeFees([mintFee, redeemFee], { account: governance.account }),
          vault,
          "FeeAboveMax",
          [501n],
        );
      }
      await viem.assertions.revertWithCustomError(
        vault.write.setFeeRecipient([zeroAddress], { account: governance.account }),
        vault,
        "ZeroAddress",
      );
      await viem.assertions.revertWithCustomError(
        vault.write.setFeeRecipient([vault.address], { account: governance.account }),
        vault,
        "InvalidRecipient",
      );
    });

    it("a raise waits 7 days, needs a recipient and anyone applies it; a cut applies at once", async () => {
      const { vault, governance, carol, dave } = await networkHelpers.loadFixture(basketFixture);

      const hash = await vault.write.proposeFees([100n, 200n], { account: governance.account });
      const readyAt = (await blockTimestamp(hash)) + SEVEN_DAYS;
      assert.equal(await vault.read.pendingFeesReadyAt(), readyAt);
      assert.equal(await vault.read.pendingMintFee(), 100n);
      assert.equal(await vault.read.pendingRedeemFee(), 200n);
      assert.equal(await vault.read.mintFee(), 0n);

      await networkHelpers.time.setNextBlockTimestamp(readyAt - 1n);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.applyFees({ account: governance.account }),
        vault,
        "FeesNotReady",
        [readyAt],
      );
      await networkHelpers.time.setNextBlockTimestamp(readyAt);
      await viem.assertions.revertWithCustomError(
        vault.write.applyFees({ account: governance.account }),
        vault,
        "NoFeeRecipient",
      );
      await viem.assertions.emitWithArgs(
        vault.write.setFeeRecipient([carol.account.address], { account: governance.account }),
        vault,
        "FeeRecipientChanged",
        [zeroAddress, getAddress(carol.account.address)],
      );
      // Governance decided when it proposed: once the wait is over, anyone can apply it.
      await viem.assertions.emitWithArgs(vault.write.applyFees({ account: dave.account }), vault, "FeesChanged", [
        100n,
        200n,
      ]);
      assert.equal(await vault.read.mintFee(), 100n);
      assert.equal(await vault.read.redeemFee(), 200n);
      assert.equal(await vault.read.pendingFeesReadyAt(), 0n);

      // Lowering both is immediate, and discards a raise still waiting, saying so.
      await vault.write.proposeFees([300n, 200n], { account: governance.account });
      const lowering = vault.write.proposeFees([50n, 0n], { account: governance.account });
      await viem.assertions.emitWithArgs(lowering, vault, "FeesChanged", [50n, 0n]);
      const receipt = await (await viem.getPublicClient()).getTransactionReceipt({ hash: await lowering });
      assert.equal(receipt.logs.length, 2, "FeesProposalCancelled and FeesChanged");
      assert.equal(await vault.read.pendingFeesReadyAt(), 0n);
      assert.equal(await vault.read.mintFee(), 50n);

      // Raising one and lowering the other waits as a whole.
      await vault.write.proposeFees([0n, 10n], { account: governance.account });
      assert.equal(await vault.read.mintFee(), 50n);
      await viem.assertions.emitWithArgs(
        vault.write.cancelFeesProposal({ account: governance.account }),
        vault,
        "FeesProposalCancelled",
        [],
      );
      for (const call of [
        () => vault.write.cancelFeesProposal({ account: governance.account }),
        () => vault.write.applyFees({ account: governance.account }),
      ]) {
        await viem.assertions.revertWithCustomError(call(), vault, "NoPendingFees");
      }
    });
  });

  describe("charging them", () => {
    it("on mint, the minter pays the whole basket and the recipient gets its share of the GRET", async () => {
      const basket = await networkHelpers.loadFixture(holdersFixture);
      const { vault, carol, dave } = basket;
      await raiseFees(basket, 100n, 0n);
      const supply = await vault.read.totalSupply();
      const valueBefore = await vault.read.previewRedeem([INITIAL_SHARES]);
      const fee = INITIAL_SHARES / 100n;

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.mint([INITIAL_SHARES, NO_MAX, INITIAL_SHARES, 0n], { account: dave.account }),
        vault,
        "SharesBelowMin",
        [INITIAL_SHARES - fee, INITIAL_SHARES],
      );
      const paid = await vault.read.previewMint([INITIAL_SHARES]);
      const daveBefore = await balancesOf(basket, dave.account.address);
      await viem.assertions.emitWithArgs(
        vault.write.mint([INITIAL_SHARES, NO_MAX, INITIAL_SHARES - fee, 0n], { account: dave.account }),
        vault,
        "FeeCharged",
        [getAddress(dave.account.address), getAddress(carol.account.address), fee],
      );
      const daveAfter = await balancesOf(basket, dave.account.address);
      assert.deepEqual(daveBefore.map((balance, i) => balance - daveAfter[i]), paid);
      assert.equal(await vault.read.balanceOf([dave.account.address]), INITIAL_SHARES - fee);
      assert.equal(await vault.read.balanceOf([carol.account.address]), fee);
      assert.equal(await vault.read.totalSupply(), supply + INITIAL_SHARES);
      assert.equal(await vault.read.hasMinted([carol.account.address]), false);

      // The fee comes out of the minter: what stands behind each GRET does not drop.
      const valueAfter = await vault.read.previewRedeem([INITIAL_SHARES]);
      valueAfter.forEach((amount, i) => assert.ok(amount >= valueBefore[i], `component ${i}`));
    });

    it("on the first mint too, out of the 1 GRET it issues", async () => {
      const basket = await networkHelpers.loadFixture(basketFixture);
      const { vault, governance, alice, carol } = basket;
      await vault.write.setFeeRecipient([carol.account.address], { account: governance.account });
      await raiseFees(basket, 500n, 0n);

      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
      assert.equal(await vault.read.totalSupply(), INITIAL_SHARES);
      assert.equal(await vault.read.balanceOf([alice.account.address]), (INITIAL_SHARES * 95n) / 100n);
      assert.equal(await vault.read.balanceOf([carol.account.address]), (INITIAL_SHARES * 5n) / 100n);
      assert.deepEqual(await vault.read.reserves(), INITIAL_AMOUNTS);
    });

    it("on redemption, part of the GRET goes to the recipient and the rest is redeemed", async () => {
      const basket = await networkHelpers.loadFixture(holdersFixture);
      const { vault, alice, carol } = basket;
      await raiseFees(basket, 0n, 200n);
      const shares = INITIAL_SHARES / 4n;
      const fee = (shares * 200n) / BPS;
      const supply = await vault.read.totalSupply();
      const reserves = await vault.read.reserves();
      const expected = reserves.map((reserve) => mulDivDown(shares - fee, reserve, supply));

      assert.deepEqual(await vault.read.previewRedeem([shares]), expected);
      const before = await balancesOf(basket, alice.account.address);
      await viem.assertions.emitWithArgs(
        vault.write.redeem([shares, expected, 0n], { account: alice.account }),
        vault,
        "Redeemed",
        [getAddress(alice.account.address), shares - fee, expected],
      );
      const after = await balancesOf(basket, alice.account.address);
      assert.deepEqual(after.map((balance, i) => balance - before[i]), expected);
      assert.equal(await vault.read.balanceOf([alice.account.address]), INITIAL_SHARES - shares);
      assert.equal(await vault.read.balanceOf([carol.account.address]), fee);
      assert.equal(await vault.read.totalSupply(), supply - (shares - fee));
    });

    it("never on liquidation exits", async () => {
      const basket = await networkHelpers.loadFixture(holdersFixture);
      const { vault, governance, alice, carol } = basket;
      await raiseFees(basket, 500n, 500n);
      await vault.write.activateLiquidation({ account: governance.account });

      await vault.write.convertToClaims([INITIAL_SHARES], { account: alice.account });
      assert.equal(await vault.read.claimShares([alice.account.address]), INITIAL_SHARES);
      assert.equal(await vault.read.balanceOf([carol.account.address]), 0n);

      const owed = mulDivDown(INITIAL_SHARES, (await vault.read.reserves())[0], await vault.read.liquidationSupply());
      const [before] = await balancesOf(basket, alice.account.address);
      await vault.write.claim([0n, alice.account.address, 0n], { account: alice.account });
      const [after] = await balancesOf(basket, alice.account.address);
      assert.equal(after - before, owed);
    });

    it("the recipient's GRET stays in the supply, so the last holder cannot leave it below 1 GRET", async () => {
      const basket = await networkHelpers.loadFixture(basketFixture);
      const { vault, governance, alice, carol } = basket;
      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
      await vault.write.setFeeRecipient([carol.account.address], { account: governance.account });
      await raiseFees(basket, 0n, 500n);

      const fee = (INITIAL_SHARES * 500n) / BPS;
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.redeem([INITIAL_SHARES, NO_MIN, 0n], { account: alice.account }),
        vault,
        "SupplyBelowMinimum",
        [fee],
      );
      // Cutting the fee to zero lets the last holder leave at once.
      await vault.write.proposeFees([0n, 0n], { account: governance.account });
      await vault.write.redeem([INITIAL_SHARES, NO_MIN, 0n], { account: alice.account });
      assert.equal(await vault.read.totalSupply(), 0n);
    });
  });
});
