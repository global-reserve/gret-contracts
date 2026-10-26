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

    it("takes only the surplus of a component, never its reserve", async () => {
      const basket = await networkHelpers.loadFixture(holdersFixture);
      const { vault, tokens, governance, carol } = basket;
      const reserves = await vault.read.reserves();
      const donation = parseUnits("1", 18);
      await tokens[0].write.mint([vault.address, donation]);
      assert.equal(await vault.read.componentSurplus([0n]), donation);

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.rescue([tokens[0].address, carol.account.address, donation + 1n], {
          account: governance.account,
        }),
        vault,
        "RescueExceedsSurplus",
        [getAddress(tokens[0].address), donation + 1n, donation],
      );
      await vault.write.rescue([tokens[0].address, carol.account.address, donation], {
        account: governance.account,
      });
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.rescue([tokens[0].address, carol.account.address, 1n], { account: governance.account }),
        vault,
        "RescueExceedsSurplus",
        [getAddress(tokens[0].address), 1n, 0n],
      );

      assert.deepEqual(await vault.read.reserves(), reserves);
      assert.deepEqual(await balancesOf(basket, vault.address), reserves);
    });

    it("governance chooses between sync and rescue for each surplus", async () => {
      const { vault, tokens, governance, carol } = await networkHelpers.loadFixture(holdersFixture);
      await tokens[1].write.mint([vault.address, 500n]);
      await tokens[2].write.mint([vault.address, 700n]);

      await vault.write.sync([tokens[1].address], { account: governance.account });
      await vault.write.rescue([tokens[2].address, carol.account.address, 700n], { account: governance.account });

      assert.equal(await vault.read.componentSurplus([1n]), 0n);
      assert.equal(await vault.read.componentSurplus([2n]), 0n);
      await viem.assertions.revertWithCustomError(
        vault.write.rescue([tokens[1].address, carol.account.address, 1n], { account: governance.account }),
        vault,
        "RescueExceedsSurplus",
      );
    });

    it("returns donations made before the first mint", async () => {
      const basket = await networkHelpers.loadFixture(basketFixture);
      const { vault, tokens, governance, alice, carol } = basket;
      await tokens[0].write.mint([vault.address, 123n]);
      assert.equal(await vault.read.componentSurplus([0n]), 123n);

      await vault.write.rescue([tokens[0].address, carol.account.address, 123n], { account: governance.account });
      await vault.write.mint([INITIAL_SHARES, INITIAL_AMOUNTS, 0n, 0n], { account: alice.account });

      assert.deepEqual(await balancesOf(basket, vault.address), INITIAL_AMOUNTS);
    });

    it("during liquidation, takes only what exceeds the rights still pending", async () => {
      const { vault, tokens, faulty, governance, alice, bob, carol } =
        await networkHelpers.loadFixture(holdersFixture);
      await vault.write.activateLiquidation({ account: governance.account });
      assert.equal(await vault.read.componentSurplus([0n]), 0n);

      // Claims lower the balance and the pending rights by the same amount.
      await vault.write.convertToClaims([INITIAL_SHARES], { account: alice.account });
      await vault.write.claim([0n, alice.account.address, 0n], { account: alice.account });
      assert.equal(await vault.read.componentSurplus([0n]), 0n);

      await tokens[0].write.mint([vault.address, 50n]);
      assert.equal(await vault.read.componentSurplus([0n]), 50n);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.rescue([tokens[0].address, carol.account.address, 51n], { account: governance.account }),
        vault,
        "RescueExceedsSurplus",
        [getAddress(tokens[0].address), 51n, 50n],
      );
      await vault.write.rescue([tokens[0].address, carol.account.address, 50n], { account: governance.account });

      // A component that fails blocks only its own rescue; pending rights stay payable.
      await faulty.write.setFault([Fault.RevertOnBalanceOf]);
      await viem.assertions.revertWithCustomError(
        vault.write.rescue([faulty.address, carol.account.address, 1n], { account: governance.account }),
        faulty,
        "BalanceOfBlocked",
      );
      const bobShares = await vault.read.balanceOf([bob.account.address]);
      await vault.write.convertToClaims([bobShares], { account: bob.account });
      for (const i of [0n, 1n, 2n]) {
        await vault.write.claim([i, bob.account.address, 0n], { account: bob.account });
      }
      await vault.write.claim([1n, alice.account.address, 0n], { account: alice.account });
      await vault.write.claim([2n, alice.account.address, 0n], { account: alice.account });
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
      assert.equal(await vault.read.pendingGovernance(), getAddress(carol.account.address));
      assert.equal(await vault.read.pendingGovernanceReadyAt(), readyAt);

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.acceptGovernance({ account: carol.account }),
        vault,
        "GovernanceTransferNotReady",
        [readyAt],
      );
      await networkHelpers.time.setNextBlockTimestamp(readyAt - 1n);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.acceptGovernance({ account: carol.account }),
        vault,
        "GovernanceTransferNotReady",
        [readyAt],
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.acceptGovernance({ account: bob.account }),
        vault,
        "NotPendingGovernance",
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
      assert.equal(await vault.read.pendingGovernance(), zeroAddress);
      assert.equal(await vault.read.pendingGovernanceReadyAt(), 0n);
    });

    it("the new governance takes every power and the previous one loses them", async () => {
      const { vault, tokens, governance, carol } = await networkHelpers.loadFixture(holdersFixture);
      await vault.write.proposeGovernance([carol.account.address], { account: governance.account });
      await networkHelpers.time.increase(SEVEN_DAYS);
      await vault.write.acceptGovernance({ account: carol.account });
      await tokens[0].write.mint([vault.address, 10n]);

      for (const call of [
        () => vault.write.sync([tokens[0].address], { account: governance.account }),
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

      await vault.write.sync([tokens[0].address], { account: carol.account });
      await vault.write.activateLiquidation({ account: carol.account });
      assert.equal(await vault.read.liquidationActive(), true);
    });

    it("a new proposal restarts the wait, and cancelling clears it", async () => {
      const { vault, governance, bob, carol } = await networkHelpers.loadFixture(holdersFixture);
      await vault.write.proposeGovernance([carol.account.address], { account: governance.account });
      await networkHelpers.time.increase(6n * 24n * 60n * 60n);

      const hash = await vault.write.proposeGovernance([bob.account.address], { account: governance.account });
      assert.equal(await vault.read.pendingGovernanceReadyAt(), (await blockTimestamp(hash)) + SEVEN_DAYS);
      await networkHelpers.time.increase(SEVEN_DAYS);
      await viem.assertions.revertWithCustomError(
        vault.write.acceptGovernance({ account: carol.account }),
        vault,
        "NotPendingGovernance",
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
        "NotPendingGovernance",
      );
      await viem.assertions.revertWithCustomError(
        vault.write.cancelGovernanceProposal({ account: governance.account }),
        vault,
        "NoPendingGovernance",
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
