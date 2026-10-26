import assert from "node:assert/strict";
import { after, describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, getAddress, zeroAddress } from "viem";

import {
  balancesOf,
  deployBasket,
  Fault,
  INITIAL_SHARES,
  mulDivDown,
  NO_MAX,
  NO_MIN,
} from "./helpers/basket.js";

describe("GRETVault: emergency liquidation", async () => {
  const connection = await network.create("hardhat");
  const { viem, networkHelpers } = connection;
  after(() => connection.close());

  /** alice and bob minted; dave only received GRET from alice. */
  async function holdersFixture() {
    const basket = await deployBasket(viem);
    const { vault, alice, bob, dave } = basket;
    await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
    await vault.write.mint([INITIAL_SHARES / 3n, NO_MAX, 0n, 0n], { account: bob.account });
    await vault.write.transfer([dave.account.address, INITIAL_SHARES / 4n], { account: alice.account });
    return basket;
  }

  async function liquidatingFixture() {
    const basket = await holdersFixture();
    await basket.vault.write.activateLiquidation({ account: basket.governance.account });
    return basket;
  }

  async function entitlement(basket: Awaited<ReturnType<typeof liquidatingFixture>>, shares: bigint) {
    const reserves = await basket.vault.read.reserves();
    const supply = await basket.vault.read.liquidationSupply();
    return reserves.map((reserve) => mulDivDown(shares, reserve, supply));
  }

  describe("activation", () => {
    it("only governance can activate it, and only once", async () => {
      const { vault, governance, alice } = await networkHelpers.loadFixture(holdersFixture);
      const supply = await vault.read.totalSupply();

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.activateLiquidation({ account: alice.account }),
        vault,
        "NotGovernance",
        [getAddress(alice.account.address)],
      );
      await viem.assertions.emitWithArgs(
        vault.write.activateLiquidation({ account: governance.account }),
        vault,
        "LiquidationActivated",
        [supply],
      );
      assert.equal(await vault.read.liquidationActive(), true);
      assert.equal(await vault.read.liquidationSupply(), supply);

      await viem.assertions.revertWithCustomError(
        vault.write.activateLiquidation({ account: governance.account }),
        vault,
        "LiquidationIsActive",
      );
    });

    it("exposes no reversal, pause or withdrawal of reserves; swap only exchanges them", async () => {
      const { vault } = await networkHelpers.loadFixture(holdersFixture);
      const mutating = vault.abi
        .filter((item) => item.type === "function" && item.stateMutability !== "view")
        .map((item) => (item as { name: string }).name)
        .sort();

      assert.deepEqual(mutating, [
        "acceptGovernance",
        "acceptRebalancer",
        "activateLiquidation",
        "addComponent",
        "announceComponent",
        "applyFees",
        "applyPriceGuard",
        "approve",
        "cancelComponentAnnouncement",
        "cancelFeesProposal",
        "cancelGovernanceProposal",
        "cancelPriceGuardProposal",
        "cancelRebalancerProposal",
        "cancelWriteOff",
        "claim",
        "convertToClaims",
        "mint",
        "proposeFees",
        "proposeGovernance",
        "proposePriceGuard",
        "proposeRebalancer",
        "proposeWriteOff",
        "recognizeLoss",
        "redeem",
        "redeemSkipping",
        "removeComponent",
        "rescue",
        "revokeRebalancer",
        "setFeeRecipient",
        "setInitialAmounts",
        "setMintPaused",
        "swap",
        "sync",
        "transfer",
        "transferFrom",
        "writeOffComponent",
      ]);
    });

    it("succeeds even when a component reverts on balanceOf or transfer", async () => {
      for (const fault of [Fault.RevertOnBalanceOf, Fault.RevertOnTransfer, Fault.ReturnFalseOnTransfer]) {
        const { vault, faulty, governance } = await networkHelpers.loadFixture(holdersFixture);
        await faulty.write.setFault([fault]);

        await vault.write.activateLiquidation({ account: governance.account });
        assert.equal(await vault.read.liquidationActive(), true);
      }
    });

    it("closes mint and normal redemption; claims need an active liquidation", async () => {
      const { vault, governance, alice } = await networkHelpers.loadFixture(holdersFixture);

      await viem.assertions.revertWithCustomError(
        vault.write.convertToClaims([1n], { account: alice.account }),
        vault,
        "LiquidationNotActive",
      );
      await viem.assertions.revertWithCustomError(
        vault.write.claim([0n, alice.account.address, 0n], { account: alice.account }),
        vault,
        "LiquidationNotActive",
      );

      await vault.write.activateLiquidation({ account: governance.account });

      await viem.assertions.revertWithCustomError(
        vault.write.mint([1n, NO_MAX, 0n, 0n], { account: alice.account }),
        vault,
        "LiquidationIsActive",
      );
      await viem.assertions.revertWithCustomError(
        vault.write.redeem([1n, NO_MIN, 0n], { account: alice.account }),
        vault,
        "LiquidationIsActive",
      );
    });
  });

  describe("claims", () => {
    it("any holder exits component by component, including wallets that never minted", async () => {
      const basket = await networkHelpers.loadFixture(liquidatingFixture);
      const { vault, dave } = basket;
      const shares = INITIAL_SHARES / 4n;
      const expected = await entitlement(basket, shares);
      const before = await balancesOf(basket, dave.account.address);
      assert.equal(await vault.read.hasMinted([dave.account.address]), false);

      await viem.assertions.emitWithArgs(
        vault.write.convertToClaims([shares], { account: dave.account }),
        vault,
        "ConvertedToClaims",
        [getAddress(dave.account.address), shares],
      );
      assert.equal(await vault.read.balanceOf([dave.account.address]), 0n);
      assert.equal(await vault.read.claimShares([dave.account.address]), shares);

      for (const [i, amount] of expected.entries()) {
        assert.equal(await vault.read.claimable([dave.account.address, BigInt(i)]), amount);
        await viem.assertions.emitWithArgs(
          vault.write.claim([BigInt(i), dave.account.address, 0n], { account: dave.account }),
          vault,
          "Claimed",
          [getAddress(dave.account.address), BigInt(i), getAddress(dave.account.address), amount, amount],
        );
      }

      const after = await balancesOf(basket, dave.account.address);
      assert.deepEqual(after.map((balance, i) => balance - before[i]), expected);
      assert.deepEqual(await vault.read.totalClaimed(), expected);
    });

    it("sends a claim to another recipient, never to the zero address", async () => {
      const basket = await networkHelpers.loadFixture(liquidatingFixture);
      const { vault, dave, carol } = basket;
      await vault.write.convertToClaims([INITIAL_SHARES / 4n], { account: dave.account });
      const [expected] = await entitlement(basket, INITIAL_SHARES / 4n);
      const [carolBefore] = await balancesOf(basket, carol.account.address);

      await viem.assertions.revertWithCustomError(
        vault.write.claim([0n, zeroAddress, 0n], { account: dave.account }),
        vault,
        "ZeroAddress",
      );
      await viem.assertions.revertWithCustomError(
        vault.write.claim([0n, vault.address, 0n], { account: dave.account }),
        vault,
        "InvalidRecipient",
      );
      await vault.write.claim([0n, carol.account.address, 0n], { account: dave.account });

      const [carolAfter] = await balancesOf(basket, carol.account.address);
      assert.equal(carolAfter - carolBefore, expected);
      assert.equal(await vault.read.claimed([dave.account.address, 0n]), expected);
    });

    it("keeps the right over a blocked component while the others are withdrawn", async () => {
      const basket = await networkHelpers.loadFixture(liquidatingFixture);
      const { vault, faulty, bob } = basket;
      const shares = await vault.read.balanceOf([bob.account.address]);
      const expected = await entitlement(basket, shares);
      await vault.write.convertToClaims([shares], { account: bob.account });

      await faulty.write.setFault([Fault.RevertOnTransfer]);
      await vault.write.claim([0n, bob.account.address, 0n], { account: bob.account });
      await viem.assertions.revertWithCustomError(
        vault.write.claim([2n, bob.account.address, 0n], { account: bob.account }),
        faulty,
        "TransfersBlocked",
      );
      await vault.write.claim([1n, bob.account.address, 0n], { account: bob.account });

      await faulty.write.setFault([Fault.ReturnFalseOnTransfer]);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.claim([2n, bob.account.address, 0n], { account: bob.account }),
        vault,
        "SafeERC20FailedOperation",
        [getAddress(faulty.address)],
      );
      assert.equal(await vault.read.claimable([bob.account.address, 2n]), expected[2]);
      assert.equal(await vault.read.claimed([bob.account.address, 2n]), 0n);

      // The block is lifted later: the pending right is still there, and only once.
      await faulty.write.setFault([Fault.None]);
      await vault.write.claim([2n, bob.account.address, 0n], { account: bob.account });
      assert.deepEqual(
        await Promise.all([0n, 1n, 2n].map((i) => vault.read.claimed([bob.account.address, i]))),
        expected,
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.claim([2n, bob.account.address, 0n], { account: bob.account }),
        vault,
        "NothingToClaim",
        [getAddress(bob.account.address), 2n],
      );
    });

    it("pays each right once, even across GRET transfers", async () => {
      const basket = await networkHelpers.loadFixture(liquidatingFixture);
      const { vault, alice, carol } = basket;
      const half = INITIAL_SHARES / 4n;
      const [aliceExpected] = await entitlement(basket, 2n * half);
      const [carolExpected] = await entitlement(basket, half);

      await vault.write.convertToClaims([2n * half], { account: alice.account });
      await vault.write.claim([0n, alice.account.address, 0n], { account: alice.account });
      await viem.assertions.revertWithCustomError(
        vault.write.claim([0n, alice.account.address, 0n], { account: alice.account }),
        vault,
        "NothingToClaim",
      );

      // Unconverted GRET stays transferable; converted GRET is burned and cannot travel.
      await vault.write.transfer([carol.account.address, half], { account: alice.account });
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.convertToClaims([1n], { account: alice.account }),
        vault,
        "ERC20InsufficientBalance",
        [getAddress(alice.account.address), 0n, 1n],
      );
      await vault.write.convertToClaims([half], { account: carol.account });
      await vault.write.claim([0n, carol.account.address, 0n], { account: carol.account });

      assert.equal(await vault.read.claimed([alice.account.address, 0n]), aliceExpected);
      assert.equal(await vault.read.claimed([carol.account.address, 0n]), carolExpected);
      assert.equal(await vault.read.claimable([alice.account.address, 0n]), 0n);
    });

    it("partial conversions accumulate without extra rounding loss", async () => {
      const { vault, bob } = await networkHelpers.loadFixture(liquidatingFixture);
      const supply = await vault.read.liquidationSupply();
      const [, reserveB] = await vault.read.reserves();
      // Each piece is worth just over 0.75 base units of B: zero alone, one unit together.
      const piece = (3n * supply) / (4n * reserveB) + 1n;

      await vault.write.convertToClaims([piece], { account: bob.account });
      assert.equal(await vault.read.claimable([bob.account.address, 1n]), 0n);
      await viem.assertions.revertWithCustomError(
        vault.write.claim([1n, bob.account.address, 0n], { account: bob.account }),
        vault,
        "NothingToClaim",
      );

      await vault.write.convertToClaims([piece], { account: bob.account });
      assert.equal(await vault.read.claimable([bob.account.address, 1n]), 1n);
      await vault.write.claim([1n, bob.account.address, 0n], { account: bob.account });
      assert.equal(await vault.read.claimed([bob.account.address, 1n]), 1n);
    });

    it("gives the same results regardless of claim order", async () => {
      const orders = [
        [[0n, 1n, 2n], [2n, 1n, 0n]],
        [[2n, 0n, 1n], [1n, 2n, 0n]],
      ];
      const results = [];

      for (const [aliceOrder, bobOrder] of orders) {
        const basket = await networkHelpers.loadFixture(liquidatingFixture);
        const { vault, alice, bob } = basket;
        for (const user of [alice, bob]) {
          await vault.write.convertToClaims([await vault.read.balanceOf([user.account.address])], {
            account: user.account,
          });
        }
        for (let step = 0; step < 3; step++) {
          await vault.write.claim([aliceOrder[step], alice.account.address, 0n], { account: alice.account });
          await vault.write.claim([bobOrder[step], bob.account.address, 0n], { account: bob.account });
        }
        results.push([
          await balancesOf(basket, alice.account.address),
          await balancesOf(basket, bob.account.address),
        ]);
      }

      assert.deepEqual(results[0], results[1]);
    });

    it("every holder exits and the vault keeps only rounding dust", async () => {
      const basket = await networkHelpers.loadFixture(liquidatingFixture);
      const { vault, alice, bob, dave } = basket;
      const holders = [alice, bob, dave];

      for (const holder of holders) {
        const shares = await vault.read.balanceOf([holder.account.address]);
        await vault.write.convertToClaims([shares], { account: holder.account });
        for (const i of [0n, 1n, 2n]) {
          await vault.write.claim([i, holder.account.address, 0n], { account: holder.account });
        }
      }

      const reserves = await vault.read.reserves();
      const claimedTotals = await vault.read.totalClaimed();
      const vaultBalances = await balancesOf(basket, vault.address);
      assert.equal(await vault.read.totalSupply(), 0n);
      for (const [i, reserve] of reserves.entries()) {
        const dust = reserve - claimedTotals[i];
        assert.ok(dust >= 0n && dust < BigInt(holders.length), `component ${i} dust ${dust}`);
        assert.equal(vaultBalances[i], dust);
      }
    });

    it("a loss is shared pro rata by everyone still pending, and payouts recover with the balance", async () => {
      const basket = await networkHelpers.loadFixture(liquidatingFixture);
      const { vault, tokens, faulty, alice, bob, dave } = basket;
      for (const holder of [alice, bob, dave]) {
        await vault.write.convertToClaims([await vault.read.balanceOf([holder.account.address])], {
          account: holder.account,
        });
      }
      const rights = await Promise.all(
        [alice, bob, dave].map((holder) => vault.read.pendingRights([holder.account.address, 2n])),
      );
      const balance = await faulty.read.balanceOf([vault.address]);
      await faulty.write.slash([vault.address, (balance * 2n) / 5n]);

      // 60 % of the component is left, so every pending right is paid at 60 %, in any order.
      const aliceGot = await vault.read.claimable([alice.account.address, 2n]);
      assert.equal(aliceGot, mulDivDown(rights[0], balance - (balance * 2n) / 5n, balance));
      await viem.assertions.emitWithArgs(
        vault.write.claim([2n, alice.account.address, 0n], { account: alice.account }),
        vault,
        "Claimed",
        [getAddress(alice.account.address), 2n, getAddress(alice.account.address), aliceGot, rights[0]],
      );
      const bobGot = await vault.read.claimable([bob.account.address, 2n]);
      assert.ok(bobGot * rights[0] >= aliceGot * rights[1], "later claimants are not worse off");
      assert.equal(await vault.read.componentSurplus([2n]), 0n);

      // The balance recovers: the remaining rights are paid in full again.
      await tokens[2].write.mint([vault.address, balance]);
      assert.equal(await vault.read.claimable([bob.account.address, 2n]), rights[1]);
      await vault.write.claim([2n, bob.account.address, 0n], { account: bob.account });
      await vault.write.claim([2n, dave.account.address, 0n], { account: dave.account });
      assert.equal(await vault.read.pendingRights([dave.account.address, 2n]), 0n);
      assert.ok((await vault.read.componentSurplus([2n])) > 0n);
    });

    it("rights are fixed at activation: later donations do not change them by themselves", async () => {
      const basket = await networkHelpers.loadFixture(liquidatingFixture);
      const { vault, tokens, dave } = basket;
      await vault.write.convertToClaims([INITIAL_SHARES / 4n], { account: dave.account });
      const before = await vault.read.claimable([dave.account.address, 0n]);

      await tokens[0].write.mint([vault.address, 10n ** 24n]);

      assert.equal(await vault.read.claimable([dave.account.address, 0n]), before);
    });

    it("a sync during liquidation raises every right in proportion, also over what was claimed", async () => {
      const basket = await networkHelpers.loadFixture(liquidatingFixture);
      const { vault, tokens, governance, alice, bob } = basket;
      for (const holder of [alice, bob]) {
        await vault.write.convertToClaims([await vault.read.balanceOf([holder.account.address])], {
          account: holder.account,
        });
      }
      await vault.write.claim([0n, alice.account.address, 0n], { account: alice.account });
      assert.equal(await vault.read.pendingRights([alice.account.address, 0n]), 0n);

      // A distribution arrives as balance, as with the xStocks multiplier, and governance syncs it.
      const reserve = (await vault.read.reserves())[0];
      const gain = reserve / 10n;
      await tokens[0].write.mint([vault.address, gain]);
      await viem.assertions.emitWithArgs(
        vault.write.sync([tokens[0].address], { account: governance.account }),
        vault,
        "Synced",
        [getAddress(tokens[0].address), gain, reserve + gain],
      );
      assert.equal(await vault.read.componentSurplus([0n]), 0n);

      const supply = await vault.read.liquidationSupply();
      for (const holder of [alice, bob]) {
        const shares = await vault.read.claimShares([holder.account.address]);
        assert.equal(
          (await vault.read.pendingRights([holder.account.address, 0n])) +
            (await vault.read.claimed([holder.account.address, 0n])),
          mulDivDown(shares, reserve + gain, supply),
        );
      }
      const before = await tokens[0].read.balanceOf([alice.account.address]);
      await vault.write.claim([0n, alice.account.address, 0n], { account: alice.account });
      const aliceShares = await vault.read.claimShares([alice.account.address]);
      assert.equal(
        (await tokens[0].read.balanceOf([alice.account.address])) - before,
        mulDivDown(aliceShares, reserve + gain, supply) - mulDivDown(aliceShares, reserve, supply),
      );
    });

    it("blocks reentrancy during a claim and keeps the right pending", async () => {
      const { vault, faulty, alice } = await networkHelpers.loadFixture(liquidatingFixture);
      await vault.write.convertToClaims([INITIAL_SHARES / 2n], { account: alice.account });
      const pending = await vault.read.claimable([alice.account.address, 2n]);
      await faulty.write.setReentry([
        vault.address,
        encodeFunctionData({ abi: vault.abi, functionName: "claim", args: [0n, faulty.address, 0n] }),
      ]);

      await viem.assertions.revertWithCustomError(
        vault.write.claim([2n, alice.account.address, 0n], { account: alice.account }),
        vault,
        "ReentrancyGuardReentrantCall",
      );
      assert.equal(await vault.read.claimable([alice.account.address, 2n]), pending);
    });

    it("rejects invalid indexes and zero conversions", async () => {
      const { vault, alice } = await networkHelpers.loadFixture(liquidatingFixture);

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.read.claimable([alice.account.address, 3n]),
        vault,
        "InvalidIndex",
        [3n],
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.claim([3n, alice.account.address, 0n], { account: alice.account }),
        vault,
        "InvalidIndex",
        [3n],
      );
      await viem.assertions.revertWithCustomError(
        vault.write.convertToClaims([0n], { account: alice.account }),
        vault,
        "ZeroShares",
      );
    });
  });
});
