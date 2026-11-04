import assert from "node:assert/strict";
import { after, describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress, parseUnits, zeroAddress } from "viem";

import { balancesOf, deployBasket, Fault, INITIAL_AMOUNTS, INITIAL_SHARES, NO_MAX } from "./helpers/basket.js";

const SEVEN_DAYS = 7n * 24n * 60n * 60n;

describe("GRETVault: governance, rescue and governance transfer", async () => {
  const connection = await network.create("hardhat");
  const { viem, networkHelpers } = connection;
  after(() => connection.close());

  async function basketFixture() {
    const basket = await deployBasket(viem);
    const stray = await viem.deployContract("MockERC20", ["Stray", "STRAY", 6]);
    return { ...basket, stray };
  }

  /** alice and bob minted; `stray` is a token outside the basket. */
  async function holdersFixture() {
    const basket = await basketFixture();
    const { vault, alice, bob } = basket;
    await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
    await vault.write.mint([INITIAL_SHARES / 3n, NO_MAX, 0n, 0n], { account: bob.account });
    return basket;
  }

  async function blockTimestamp(hash: `0x${string}`) {
    const publicClient = await viem.getPublicClient();
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    return (await publicClient.getBlock({ blockNumber: receipt.blockNumber })).timestamp;
  }

  describe("rescue", () => {
    it("returns tokens outside the basket in full, and only governance can do it", async () => {
      const { vault, stray, governance, alice, carol } = await networkHelpers.loadFixture(holdersFixture);
      const amount = parseUnits("1000", 6);
      await stray.write.mint([vault.address, amount]);

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.rescue([stray.address, alice.account.address, amount], { account: alice.account }),
        vault,
        "NotGovernance",
        [getAddress(alice.account.address)],
      );
      await viem.assertions.emitWithArgs(
        vault.write.rescue([stray.address, carol.account.address, amount], { account: governance.account }),
        vault,
        "Rescued",
        [getAddress(stray.address), getAddress(carol.account.address), amount],
      );
      assert.equal(await stray.read.balanceOf([carol.account.address]), amount);
      assert.equal(await stray.read.balanceOf([vault.address]), 0n);
    });

    it("rejects GRET sent to the vault, so a mistake costs nothing and governance never holds GRET", async () => {
      const { vault, governance, alice, bob } = await networkHelpers.loadFixture(holdersFixture);
      const amount = INITIAL_SHARES / 10n;

      await viem.assertions.revertWithCustomError(
        vault.write.transfer([vault.address, amount], { account: alice.account }),
        vault,
        "InvalidRecipient",
      );
      await vault.write.approve([bob.account.address, amount], { account: alice.account });
      await viem.assertions.revertWithCustomError(
        vault.write.transferFrom([alice.account.address, vault.address, amount], { account: bob.account }),
        vault,
        "InvalidRecipient",
      );
      assert.equal(await vault.read.balanceOf([alice.account.address]), INITIAL_SHARES);
      assert.equal(await vault.read.balanceOf([vault.address]), 0n);

      // Also during liquidation, when GRET could otherwise become rights over the reserves.
      await vault.write.activateLiquidation({ account: governance.account });
      await viem.assertions.revertWithCustomError(
        vault.write.transfer([vault.address, amount], { account: alice.account }),
        vault,
        "InvalidRecipient",
      );
    });

    it("cannot rescue any component income while holders exist", async () => {
      const { vault, tokens, governance, carol } = await networkHelpers.loadFixture(holdersFixture);
      const before = (await vault.read.reserves())[0];
      await tokens[0].write.mint([vault.address, 123n]);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.rescue([tokens[0].address, carol.account.address, 1n], { account: governance.account }),
        vault, "BackingToken", [getAddress(tokens[0].address)],
      );
      assert.equal((await vault.read.reserves())[0], before + 123n);
    });

    it("component donations belong to holders without governance discretion", async () => {
      const { vault, tokens, governance, carol } = await networkHelpers.loadFixture(holdersFixture);
      await tokens[1].write.mint([vault.address, 500n]);
      await viem.assertions.revertWithCustomError(
        vault.write.rescue([tokens[1].address, carol.account.address, 500n], { account: governance.account }),
        vault, "BackingToken",
      );
    });

    it("returns donations made before the first mint", async () => {
      const basket = await networkHelpers.loadFixture(basketFixture);
      const { vault, tokens, governance, alice, carol } = basket;
      await tokens[0].write.mint([vault.address, 123n]);
      assert.equal((await vault.read.reserves())[0], 123n);

      await vault.write.rescue([tokens[0].address, carol.account.address, 123n], { account: governance.account });
      await vault.write.mint([INITIAL_SHARES, INITIAL_AMOUNTS, 0n, 0n], { account: alice.account });

      assert.deepEqual(await balancesOf(basket, vault.address), INITIAL_AMOUNTS);
    });

    it("liquidation income remains protected even after a holder already claimed", async () => {
      const { vault, tokens, governance, alice, carol } = await networkHelpers.loadFixture(holdersFixture);
      await vault.write.activateLiquidation({ account: governance.account });
      await vault.write.convertToClaims([INITIAL_SHARES], { account: alice.account });
      await vault.write.claim([0n, alice.account.address, 0n], { account: alice.account });
      await tokens[0].write.mint([vault.address, 50n]);
      await viem.assertions.revertWithCustomError(
        vault.write.rescue([tokens[0].address, carol.account.address, 1n], { account: governance.account }),
        vault, "BackingToken",
      );
      assert.ok((await vault.read.claimable([alice.account.address, 0n])) > 0n);
    });

    it("rejects zero amounts, the zero address and the vault itself", async () => {
      const { vault, stray, governance } = await networkHelpers.loadFixture(holdersFixture);

      await viem.assertions.revertWithCustomError(
        vault.write.rescue([stray.address, governance.account.address, 0n], { account: governance.account }),
        vault,
        "ZeroAmount",
      );
      await viem.assertions.revertWithCustomError(
        vault.write.rescue([stray.address, zeroAddress, 1n], { account: governance.account }),
        vault,
        "ZeroAddress",
      );
      await viem.assertions.revertWithCustomError(
        vault.write.rescue([stray.address, vault.address, 1n], { account: governance.account }),
        vault,
        "InvalidRecipient",
      );
    });
  });

  describe("governance transfer", () => {
    it("only governance proposes, and the proposal waits 7 days in the vault", async () => {
      const { vault, governance, alice, bob, carol } = await networkHelpers.loadFixture(holdersFixture);

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.proposeGovernance([alice.account.address], { account: alice.account }),
        vault,
        "NotGovernance",
        [getAddress(alice.account.address)],
      );
      await viem.assertions.revertWithCustomError(
        vault.write.proposeGovernance([zeroAddress], { account: governance.account }),
        vault,
        "ZeroAddress",
      );

      const hash = await vault.write.proposeGovernance([carol.account.address], { account: governance.account });
      const readyAt = (await blockTimestamp(hash)) + SEVEN_DAYS;
      assert.equal((await vault.read.governanceProposal())[0], getAddress(carol.account.address));
      assert.equal((await vault.read.governanceProposal())[1], readyAt);

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.acceptGovernance({ account: carol.account }),
        vault,
        "NotReady",
        [readyAt],
      );
      await networkHelpers.time.setNextBlockTimestamp(readyAt - 1n);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.acceptGovernance({ account: carol.account }),
        vault,
        "NotReady",
        [readyAt],
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.acceptGovernance({ account: bob.account }),
        vault,
        "NotProposed",
        [getAddress(bob.account.address)],
      );

      await networkHelpers.time.setNextBlockTimestamp(readyAt);
      await viem.assertions.emitWithArgs(
        vault.write.acceptGovernance({ account: carol.account }),
        vault,
        "GovernanceTransferred",
        [getAddress(governance.account.address), getAddress(carol.account.address)],
      );
      assert.equal(await vault.read.governance(), getAddress(carol.account.address));
      assert.equal((await vault.read.governanceProposal())[0], zeroAddress);
      assert.equal((await vault.read.governanceProposal())[1], 0n);
    });

    it("the new governance takes every power and the previous one loses them", async () => {
      const { vault, tokens, governance, carol } = await networkHelpers.loadFixture(holdersFixture);
      await vault.write.proposeGovernance([carol.account.address], { account: governance.account });
      await networkHelpers.time.increase(SEVEN_DAYS);
      await vault.write.acceptGovernance({ account: carol.account });
      await tokens[0].write.mint([vault.address, 10n]);

      for (const call of [
        () => vault.write.activateComponent([tokens[0].address], { account: governance.account }),
        () => vault.write.activateLiquidation({ account: governance.account }),
        () => vault.write.proposeGovernance([governance.account.address], { account: governance.account }),
        () => vault.write.proposeRebalancer([governance.account.address], { account: governance.account }),
        () => vault.write.revokeRebalancer({ account: governance.account }),
        () => vault.write.announceComponent([tokens[1].address], { account: governance.account }),
        () => vault.write.removeComponent([tokens[1].address], { account: governance.account }),
        () => vault.write.setInitialAmounts([INITIAL_AMOUNTS, 0n], { account: governance.account }),
        () => vault.write.proposeWriteOff([tokens[1].address], { account: governance.account }),
        () => vault.write.proposeFees([1n, 1n], { account: governance.account }),
        () => vault.write.setFeeRecipient([carol.account.address], { account: governance.account }),
        () => vault.write.setMintPaused([true], { account: governance.account }),
      ]) {
        await viem.assertions.revertWithCustomError(call(), vault, "NotGovernance");
      }

      await vault.write.activateComponent([tokens[0].address], { account: carol.account });
      await vault.write.activateLiquidation({ account: carol.account });
      assert.equal(await vault.read.liquidationActive(), true);
    });

    it("a new proposal restarts the wait, and cancelling clears it", async () => {
      const { vault, governance, bob, carol } = await networkHelpers.loadFixture(holdersFixture);
      await vault.write.proposeGovernance([carol.account.address], { account: governance.account });
      await networkHelpers.time.increase(6n * 24n * 60n * 60n);

      const hash = await vault.write.proposeGovernance([bob.account.address], { account: governance.account });
      assert.equal((await vault.read.governanceProposal())[1], (await blockTimestamp(hash)) + SEVEN_DAYS);
      await networkHelpers.time.increase(SEVEN_DAYS);
      await viem.assertions.revertWithCustomError(
        vault.write.acceptGovernance({ account: carol.account }),
        vault,
        "NotProposed",
      );

      await viem.assertions.emitWithArgs(
        vault.write.cancelGovernanceProposal({ account: governance.account }),
        vault,
        "GovernanceProposalCancelled",
        [getAddress(bob.account.address)],
      );
      await viem.assertions.revertWithCustomError(
        vault.write.acceptGovernance({ account: bob.account }),
        vault,
        "NotProposed",
      );
      await viem.assertions.revertWithCustomError(
        vault.write.cancelGovernanceProposal({ account: governance.account }),
        vault,
        "NoPendingProposal",
      );
      assert.equal(await vault.read.governance(), getAddress(governance.account.address));
    });

    it("can still change during liquidation", async () => {
      const { vault, stray, governance, carol } = await networkHelpers.loadFixture(holdersFixture);
      await vault.write.activateLiquidation({ account: governance.account });
      await vault.write.proposeGovernance([carol.account.address], { account: governance.account });
      await networkHelpers.time.increase(SEVEN_DAYS);
      await vault.write.acceptGovernance({ account: carol.account });

      await stray.write.mint([vault.address, 1n]);
      await vault.write.rescue([stray.address, carol.account.address, 1n], { account: carol.account });
      assert.equal(await stray.read.balanceOf([carol.account.address]), 1n);
    });
  });
});
