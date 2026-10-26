import assert from "node:assert/strict";
import { after, describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress, maxUint256, parseUnits, zeroAddress } from "viem";

import {
  balancesOf,
  deployBasket,
  Fault,
  INITIAL_AMOUNTS,
  INITIAL_SHARES,
  mulDivUp,
  NO_MAX,
  NO_MIN,
} from "./helpers/basket.js";

const SEVEN_DAYS = 7n * 24n * 60n * 60n;

describe("GRETVault: rebalancing and basket changes", async () => {
  const connection = await network.create("hardhat");
  const { viem, networkHelpers } = connection;
  after(() => connection.close());

  /** The basket plus D, a token outside it that every user holds and has approved. */
  async function basketFixture() {
    const basket = await deployBasket(viem);
    const tokenD = await viem.deployContract("MockERC20", ["Mock D", "MD", 6]);
    for (const user of basket.users) {
      await tokenD.write.mint([user.account.address, parseUnits("1000000", 6)]);
      await tokenD.write.approve([basket.vault.address, maxUint256], { account: user.account });
    }
    return { ...basket, tokenD };
  }

  /**
   * alice and bob minted 1 GRET each; dave became the rebalancer and a guard that accepts every
   * swap took effect, both through the 7-day wait.
   */
  async function rebalancerFixture() {
    const basket = await basketFixture();
    const { vault, governance, alice, bob, dave } = basket;
    const guard = await viem.deployContract("MockPriceGuard");
    await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
    await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: bob.account });
    await vault.write.proposeRebalancer([dave.account.address], { account: governance.account });
    await vault.write.proposePriceGuard([guard.address], { account: governance.account });
    await networkHelpers.time.increase(SEVEN_DAYS);
    await vault.write.acceptRebalancer({ account: dave.account });
    await vault.write.applyPriceGuard();
    return { ...basket, guard };
  }

  async function blockTimestamp(hash: `0x${string}`) {
    const publicClient = await viem.getPublicClient();
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    return (await publicClient.getBlock({ blockNumber: receipt.blockNumber })).timestamp;
  }

  const doubled = INITIAL_AMOUNTS.map((amount) => 2n * amount);

  describe("rebalancer", () => {
    it("starts empty, so nobody can swap, not even governance", async () => {
      const { vault, tokens, governance, alice } = await networkHelpers.loadFixture(basketFixture);
      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });

      for (const account of [governance, alice]) {
        await viem.assertions.revertWithCustomErrorWithArgs(
          vault.write.swap([tokens[0].address, 1n, tokens[1].address, 1n], { account: account.account }),
          vault,
          "NotRebalancer",
          [getAddress(account.account.address)],
        );
      }
    });

    it("only governance proposes, and the rebalancer takes over only after 7 days", async () => {
      const { vault, governance, alice, bob, dave } = await networkHelpers.loadFixture(basketFixture);

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.proposeRebalancer([alice.account.address], { account: alice.account }),
        vault,
        "NotGovernance",
        [getAddress(alice.account.address)],
      );
      await viem.assertions.revertWithCustomError(
        vault.write.proposeRebalancer([zeroAddress], { account: governance.account }),
        vault,
        "ZeroAddress",
      );

      const hash = await vault.write.proposeRebalancer([dave.account.address], { account: governance.account });
      const readyAt = (await blockTimestamp(hash)) + SEVEN_DAYS;
      assert.equal(await vault.read.pendingRebalancer(), getAddress(dave.account.address));
      assert.equal(await vault.read.pendingRebalancerReadyAt(), readyAt);

      await networkHelpers.time.setNextBlockTimestamp(readyAt - 1n);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.acceptRebalancer({ account: dave.account }),
        vault,
        "RebalancerChangeNotReady",
        [readyAt],
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.acceptRebalancer({ account: bob.account }),
        vault,
        "NotPendingRebalancer",
        [getAddress(bob.account.address)],
      );

      await networkHelpers.time.setNextBlockTimestamp(readyAt);
      await viem.assertions.emitWithArgs(
        vault.write.acceptRebalancer({ account: dave.account }),
        vault,
        "RebalancerChanged",
        [zeroAddress, getAddress(dave.account.address)],
      );
      assert.equal(await vault.read.rebalancer(), getAddress(dave.account.address));
      assert.equal(await vault.read.pendingRebalancer(), zeroAddress);
      assert.equal(await vault.read.pendingRebalancerReadyAt(), 0n);
    });

    it("governance revokes it at once; a new proposal restarts the wait and cancelling clears it", async () => {
      const { vault, tokens, governance, alice, carol, dave } = await networkHelpers.loadFixture(rebalancerFixture);

      await viem.assertions.revertWithCustomError(
        vault.write.revokeRebalancer({ account: alice.account }),
        vault,
        "NotGovernance",
      );
      await viem.assertions.emitWithArgs(
        vault.write.revokeRebalancer({ account: governance.account }),
        vault,
        "RebalancerChanged",
        [getAddress(dave.account.address), zeroAddress],
      );
      await viem.assertions.revertWithCustomError(
        vault.write.swap([tokens[0].address, 1n, tokens[1].address, 1n], { account: dave.account }),
        vault,
        "NotRebalancer",
      );

      await viem.assertions.revertWithCustomError(
        vault.write.cancelRebalancerProposal({ account: governance.account }),
        vault,
        "NoPendingRebalancer",
      );
      await vault.write.proposeRebalancer([dave.account.address], { account: governance.account });
      await networkHelpers.time.increase(6n * 24n * 60n * 60n);
      const hash = await vault.write.proposeRebalancer([carol.account.address], { account: governance.account });
      assert.equal(await vault.read.pendingRebalancerReadyAt(), (await blockTimestamp(hash)) + SEVEN_DAYS);
      await networkHelpers.time.increase(SEVEN_DAYS);
      await viem.assertions.revertWithCustomError(
        vault.write.acceptRebalancer({ account: dave.account }),
        vault,
        "NotPendingRebalancer",
      );

      await viem.assertions.emitWithArgs(
        vault.write.cancelRebalancerProposal({ account: governance.account }),
        vault,
        "RebalancerProposalCancelled",
        [getAddress(carol.account.address)],
      );
      await viem.assertions.revertWithCustomError(
        vault.write.cancelRebalancerProposal({ account: alice.account }),
        vault,
        "NotGovernance",
      );
      await viem.assertions.revertWithCustomError(
        vault.write.acceptRebalancer({ account: carol.account }),
        vault,
        "NotPendingRebalancer",
      );
      assert.equal(await vault.read.rebalancer(), zeroAddress);
    });
  });

  describe("price guard", () => {
    it("starts empty, and without a guard not even the rebalancer can swap", async () => {
      const { vault, tokens, governance, alice, dave } = await networkHelpers.loadFixture(basketFixture);
      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
      await vault.write.proposeRebalancer([dave.account.address], { account: governance.account });
      await networkHelpers.time.increase(SEVEN_DAYS);
      await vault.write.acceptRebalancer({ account: dave.account });

      assert.equal(await vault.read.priceGuard(), zeroAddress);
      await viem.assertions.revertWithCustomError(
        vault.write.swap([tokens[0].address, 1n, tokens[1].address, 1n], { account: dave.account }),
        vault,
        "NoPriceGuard",
      );
    });

    it("only governance proposes it, it waits 7 days, anyone applies it and it expires", async () => {
      const { vault, governance, alice } = await networkHelpers.loadFixture(basketFixture);
      const guard = await viem.deployContract("MockPriceGuard");
      const other = await viem.deployContract("MockPriceGuard");

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.proposePriceGuard([guard.address], { account: alice.account }),
        vault,
        "NotGovernance",
        [getAddress(alice.account.address)],
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.proposePriceGuard([alice.account.address], { account: governance.account }),
        vault,
        "NotAContract",
        [getAddress(alice.account.address)],
      );
      for (const call of [
        () => vault.write.applyPriceGuard({ account: alice.account }),
        () => vault.write.cancelPriceGuardProposal({ account: governance.account }),
      ]) {
        await viem.assertions.revertWithCustomError(call(), vault, "NoPendingPriceGuard");
      }

      // A new proposal replaces the pending one and restarts the wait; cancelling clears it.
      await vault.write.proposePriceGuard([other.address], { account: governance.account });
      await networkHelpers.time.increase(SEVEN_DAYS);
      const hash = await vault.write.proposePriceGuard([guard.address], { account: governance.account });
      const readyAt = (await blockTimestamp(hash)) + SEVEN_DAYS;
      assert.equal(await vault.read.pendingPriceGuard(), getAddress(guard.address));
      assert.equal(await vault.read.pendingPriceGuardReadyAt(), readyAt);
      await networkHelpers.time.setNextBlockTimestamp(readyAt - 1n);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.applyPriceGuard({ account: alice.account }),
        vault,
        "PriceGuardChangeNotReady",
        [readyAt],
      );
      await networkHelpers.time.setNextBlockTimestamp(readyAt);
      await viem.assertions.emitWithArgs(vault.write.applyPriceGuard({ account: alice.account }), vault, "PriceGuardChanged", [
        zeroAddress,
        getAddress(guard.address),
      ]);
      assert.equal(await vault.read.priceGuard(), getAddress(guard.address));
      assert.equal(await vault.read.pendingPriceGuard(), zeroAddress);
      assert.equal(await vault.read.pendingPriceGuardReadyAt(), 0n);

      await vault.write.proposePriceGuard([other.address], { account: governance.account });
      await viem.assertions.revertWithCustomError(
        vault.write.cancelPriceGuardProposal({ account: alice.account }),
        vault,
        "NotGovernance",
      );
      await viem.assertions.emitWithArgs(
        vault.write.cancelPriceGuardProposal({ account: governance.account }),
        vault,
        "PriceGuardProposalCancelled",
        [getAddress(other.address)],
      );

      const expiring = await vault.write.proposePriceGuard([other.address], { account: governance.account });
      const expiredAt = (await blockTimestamp(expiring)) + 2n * SEVEN_DAYS;
      await networkHelpers.time.setNextBlockTimestamp(expiredAt + 1n);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.applyPriceGuard({ account: alice.account }),
        vault,
        "ProposalExpired",
        [expiredAt],
      );
      assert.equal(await vault.read.priceGuard(), getAddress(guard.address));
    });

    it("prices what arrived against the reserves before the swap, and a refusal reverts it", async () => {
      const basket = await networkHelpers.loadFixture(rebalancerFixture);
      const { vault, tokens, guard, dave } = basket;
      const [a, b] = tokens;

      await vault.write.swap([a.address, INITIAL_AMOUNTS[0], b.address, INITIAL_AMOUNTS[1]], { account: dave.account });
      assert.equal(await guard.read.calls(), 1n);
      assert.equal(await guard.read.lastSell(), getAddress(a.address));
      assert.equal(await guard.read.lastSellAmount(), INITIAL_AMOUNTS[0]);
      assert.equal(await guard.read.lastBuy(), getAddress(b.address));
      assert.equal(await guard.read.lastReceived(), INITIAL_AMOUNTS[1]);
      assert.deepEqual(await guard.read.reservesSeen(), doubled);

      await guard.write.setRefuse([true]);
      const reserves = await vault.read.reserves();
      const daveBefore = await balancesOf(basket, dave.account.address);
      await viem.assertions.revertWithCustomError(
        vault.write.swap([a.address, 1n, b.address, 1n], { account: dave.account }),
        guard,
        "SwapRefused",
      );
      assert.deepEqual(await vault.read.reserves(), reserves);
      assert.deepEqual(await balancesOf(basket, dave.account.address), daveBefore);
    });

    it("is never called by mint, redemption or liquidation, so it cannot block an exit", async () => {
      const { vault, guard, governance, alice, bob, carol } = await networkHelpers.loadFixture(rebalancerFixture);
      await guard.write.setRefuse([true]);

      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: carol.account });
      await vault.write.redeem([INITIAL_SHARES, NO_MIN, 0n], { account: alice.account });
      await vault.write.activateLiquidation({ account: governance.account });
      await vault.write.convertToClaims([INITIAL_SHARES], { account: bob.account });
      await vault.write.claim([0n, bob.account.address, 0n], { account: bob.account });
      assert.equal(await guard.read.calls(), 0n);
    });
  });

  describe("swap", () => {
    it("exchanges reserves, delivery first, and mint and redemption follow the new amounts", async () => {
      const basket = await networkHelpers.loadFixture(rebalancerFixture);
      const { vault, tokens, bob, dave } = basket;
      const [a, b] = tokens;
      const sold = INITIAL_AMOUNTS[0] / 2n;
      const bought = INITIAL_AMOUNTS[1];
      const daveBefore = await balancesOf(basket, dave.account.address);

      await viem.assertions.emitWithArgs(
        vault.write.swap([a.address, sold, b.address, bought], { account: dave.account }),
        vault,
        "Swapped",
        [getAddress(a.address), sold, getAddress(b.address), bought],
      );
      const daveAfter = await balancesOf(basket, dave.account.address);
      assert.equal(daveAfter[0] - daveBefore[0], sold);
      assert.equal(daveBefore[1] - daveAfter[1], bought);

      const reserves = [doubled[0] - sold, doubled[1] + bought, doubled[2]];
      assert.deepEqual(await vault.read.reserves(), reserves);
      assert.deepEqual(await balancesOf(basket, vault.address), reserves);
      assert.equal(await vault.read.totalSupply(), 2n * INITIAL_SHARES);

      // No amount per GRET is stored elsewhere: both directions read the reserves.
      assert.deepEqual(
        await vault.read.previewMint([INITIAL_SHARES]),
        reserves.map((reserve) => mulDivUp(INITIAL_SHARES, reserve, 2n * INITIAL_SHARES)),
      );
      const bobBefore = await balancesOf(basket, bob.account.address);
      await vault.write.redeem([INITIAL_SHARES, NO_MIN, 0n], { account: bob.account });
      const bobAfter = await balancesOf(basket, bob.account.address);
      assert.deepEqual(
        bobAfter.map((balance, i) => balance - bobBefore[i]),
        reserves.map((reserve) => reserve / 2n),
      );
    });

    it("credits what arrived, tolerating xStocks-like rounding and rejecting fees", async () => {
      const { vault, tokens, faulty, dave } = await networkHelpers.loadFixture(rebalancerFixture);
      const a = tokens[0].address;
      const bought = 1000n;

      await faulty.write.setFault([Fault.ShortByOneOnTransfer]);
      await viem.assertions.emitWithArgs(
        vault.write.swap([a, 1n, faulty.address, bought], { account: dave.account }),
        vault,
        "Swapped",
        [getAddress(a), 1n, getAddress(faulty.address), bought - 1n],
      );
      assert.equal((await vault.read.reserves())[2], doubled[2] + bought - 1n);

      await faulty.write.setFault([Fault.FeeOnTransfer]);
      const large = parseUnits("1", 18);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.swap([a, 1n, faulty.address, large], { account: dave.account }),
        vault,
        "UnexpectedBalance",
        [2n, large, large - large / 100n],
      );
    });

    it("sells only recognized reserve, never surplus, and rejects invalid pairs and amounts", async () => {
      const { vault, tokens, faulty, tokenD, dave } = await networkHelpers.loadFixture(rebalancerFixture);
      const [a, b] = tokens.map((token) => token.address);
      await tokens[0].write.mint([vault.address, 10n ** 18n]);
      const swap = (sell: `0x${string}`, sellAmount: bigint, buy: `0x${string}`, buyAmount: bigint) =>
        vault.write.swap([sell, sellAmount, buy, buyAmount], { account: dave.account });

      await viem.assertions.revertWithCustomErrorWithArgs(
        swap(a, doubled[0] + 1n, b, 1n),
        vault,
        "SwapExceedsReserve",
        [getAddress(a), doubled[0] + 1n, doubled[0]],
      );
      await viem.assertions.revertWithCustomErrorWithArgs(swap(a, 1n, a, 1n), vault, "SameComponent", [getAddress(a)]);
      await viem.assertions.revertWithCustomErrorWithArgs(swap(tokenD.address, 1n, a, 1n), vault, "NotAComponent", [
        getAddress(tokenD.address),
      ]);
      await viem.assertions.revertWithCustomErrorWithArgs(swap(a, 1n, tokenD.address, 1n), vault, "NotAComponent", [
        getAddress(tokenD.address),
      ]);
      await viem.assertions.revertWithCustomError(swap(a, 0n, b, 1n), vault, "ZeroAmount");
      await viem.assertions.revertWithCustomErrorWithArgs(swap(a, 1n, b, 0n), vault, "ZeroComponentAmount", [1n]);

      // Atomic: if the component going out fails, what came in goes back too.
      await faulty.write.setFault([Fault.RevertOnTransfer]);
      await assert.rejects(swap(faulty.address, 1n, a, 1n));
      assert.deepEqual(await vault.read.reserves(), doubled);
    });

    it("recognizes losses on both components first", async () => {
      const { vault, tokens, faulty, dave } = await networkHelpers.loadFixture(rebalancerFixture);
      const a = tokens[0].address;
      const loss = INITIAL_AMOUNTS[2];
      const left = doubled[2] - loss;
      await faulty.write.slash([vault.address, loss]);

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.swap([faulty.address, left + 1n, a, 1n], { account: dave.account }),
        vault,
        "SwapExceedsReserve",
        [getAddress(faulty.address), left + 1n, left],
      );
      await viem.assertions.emitWithArgs(
        vault.write.swap([faulty.address, left, a, 1n], { account: dave.account }),
        vault,
        "LossRecognized",
        [2n, loss, left],
      );
      assert.deepEqual(await vault.read.reserves(), [doubled[0] + 1n, doubled[1], 0n]);
    });

    it("refuses to mint once swaps and losses empty every reserve, so GRET is never backed by nothing", async () => {
      const { vault, tokens, faulty, bob, dave } = await networkHelpers.loadFixture(rebalancerFixture);
      await vault.write.swap([tokens[0].address, doubled[0], faulty.address, 1n], { account: dave.account });
      await vault.write.swap([tokens[1].address, doubled[1], faulty.address, 1n], { account: dave.account });
      await faulty.write.slash([vault.address, doubled[2] + 2n]);
      await vault.write.recognizeLoss([2n]);

      assert.deepEqual(await vault.read.reserves(), [0n, 0n, 0n]);
      assert.deepEqual(await vault.read.previewMint([INITIAL_SHARES]), [0n, 0n, 0n]);
      await viem.assertions.revertWithCustomError(
        vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: bob.account }),
        vault,
        "EmptyBasket",
      );
    });
  });

  describe("components", () => {
    it("a new component waits 7 days, joins empty and is asked for only once the rebalancer buys it", async () => {
      const basket = await networkHelpers.loadFixture(rebalancerFixture);
      const { vault, tokens, tokenD, governance, alice, carol, dave } = basket;
      const d = tokenD.address;

      await viem.assertions.revertWithCustomError(
        vault.write.announceComponent([d], { account: alice.account }),
        vault,
        "NotGovernance",
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.announceComponent([alice.account.address], { account: governance.account }),
        vault,
        "NotAContract",
        [getAddress(alice.account.address)],
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.announceComponent([tokens[0].address], { account: governance.account }),
        vault,
        "DuplicateComponent",
        [getAddress(tokens[0].address)],
      );

      const hash = await vault.write.announceComponent([d], { account: governance.account });
      const readyAt = (await blockTimestamp(hash)) + SEVEN_DAYS;
      assert.equal(await vault.read.componentReadyAt([d]), readyAt);
      // The rebalancer cannot buy it with the reserves while it waits.
      await viem.assertions.revertWithCustomError(
        vault.write.swap([tokens[0].address, 1n, d, 1n], { account: dave.account }),
        vault,
        "NotAComponent",
      );
      await networkHelpers.time.setNextBlockTimestamp(readyAt - 1n);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.addComponent([d], { account: governance.account }),
        vault,
        "ComponentNotReady",
        [getAddress(d), readyAt],
      );
      // Governance decided when it announced it: once the wait is over, anyone can add it.
      await networkHelpers.time.setNextBlockTimestamp(readyAt);
      await viem.assertions.emitWithArgs(
        vault.write.addComponent([d], { account: alice.account }),
        vault,
        "ComponentAdded",
        [getAddress(d), 3n],
      );
      assert.equal(await vault.read.componentReadyAt([d]), 0n);
      assert.equal(await vault.read.basketVersion(), 1n);
      assert.deepEqual(await vault.read.components(), [...tokens.map((t) => getAddress(t.address)), getAddress(d)]);
      assert.deepEqual(await vault.read.reserves(), [...doubled, 0n]);
      assert.deepEqual(await vault.read.initialAmounts(), [...INITIAL_AMOUNTS, 0n]);

      // Limits prepared for the old basket are refused, and arrays now have four entries; mint
      // skips D while it has no reserve.
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: carol.account }),
        vault,
        "BasketChanged",
        [0n, 1n],
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 1n], { account: carol.account }),
        vault,
        "LengthMismatch",
        [4n, 3n],
      );
      assert.deepEqual(await vault.read.previewMint([INITIAL_SHARES]), [...INITIAL_AMOUNTS, 0n]);

      const boughtD = parseUnits("50", 6);
      await vault.write.swap([tokens[0].address, INITIAL_AMOUNTS[0], d, boughtD], { account: dave.account });
      const reserves = [doubled[0] - INITIAL_AMOUNTS[0], doubled[1], doubled[2], boughtD];
      assert.deepEqual(await vault.read.reserves(), reserves);
      const expected = reserves.map((reserve) => mulDivUp(INITIAL_SHARES, reserve, 2n * INITIAL_SHARES));
      assert.deepEqual(await vault.read.previewMint([INITIAL_SHARES]), expected);

      const carolBefore = await tokenD.read.balanceOf([carol.account.address]);
      await vault.write.mint([INITIAL_SHARES, [...NO_MAX, maxUint256], 0n, 1n], { account: carol.account });
      assert.equal(carolBefore - (await tokenD.read.balanceOf([carol.account.address])), expected[3]);
      assert.equal(await vault.read.balanceOf([carol.account.address]), INITIAL_SHARES);
    });

    it("cancelling an announcement clears it, and only a ready announcement can be added", async () => {
      const { vault, tokenD, governance, alice } = await networkHelpers.loadFixture(rebalancerFixture);
      const d = tokenD.address;

      for (const call of [
        () => vault.write.cancelComponentAnnouncement([d], { account: governance.account }),
        () => vault.write.addComponent([d], { account: governance.account }),
      ]) {
        await viem.assertions.revertWithCustomErrorWithArgs(call(), vault, "NoPendingComponent", [getAddress(d)]);
      }
      await vault.write.announceComponent([d], { account: governance.account });
      await viem.assertions.revertWithCustomError(
        vault.write.cancelComponentAnnouncement([d], { account: alice.account }),
        vault,
        "NotGovernance",
      );
      await viem.assertions.emitWithArgs(
        vault.write.cancelComponentAnnouncement([d], { account: governance.account }),
        vault,
        "ComponentAnnouncementCancelled",
        [getAddress(d)],
      );
      await networkHelpers.time.increase(SEVEN_DAYS);
      await viem.assertions.revertWithCustomError(
        vault.write.addComponent([d], { account: governance.account }),
        vault,
        "NoPendingComponent",
      );
      assert.equal(await vault.read.componentCount(), 3n);
    });

    it("removes a component only with no reserve, keeping the order of the rest", async () => {
      const basket = await networkHelpers.loadFixture(rebalancerFixture);
      const { vault, tokens, tokenD, governance, alice, bob, carol, dave } = basket;
      const [a, b, c] = tokens.map((token) => token.address);

      await viem.assertions.revertWithCustomError(
        vault.write.removeComponent([a], { account: alice.account }),
        vault,
        "NotGovernance",
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.removeComponent([tokenD.address], { account: governance.account }),
        vault,
        "NotAComponent",
        [getAddress(tokenD.address)],
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.removeComponent([a], { account: governance.account }),
        vault,
        "ComponentHasReserve",
        [getAddress(a), doubled[0]],
      );

      // The rebalancer sells all of A; a donation of A stays behind as surplus.
      await vault.write.swap([a, doubled[0], b, INITIAL_AMOUNTS[1]], { account: dave.account });
      await tokens[0].write.mint([vault.address, 5n]);
      await viem.assertions.emitWithArgs(
        vault.write.removeComponent([a], { account: governance.account }),
        vault,
        "ComponentRemoved",
        [getAddress(a), 0n],
      );
      assert.deepEqual(await vault.read.components(), [getAddress(b), getAddress(c)]);
      assert.deepEqual(await vault.read.reserves(), [doubled[1] + INITIAL_AMOUNTS[1], doubled[2]]);
      assert.deepEqual(await vault.read.initialAmounts(), [INITIAL_AMOUNTS[1], INITIAL_AMOUNTS[2]]);
      assert.equal(await vault.read.componentCount(), 2n);
      assert.equal(await vault.read.basketVersion(), 1n);

      // Indexes moved down: sync, mint and redemption keep working on the new order.
      await tokens[1].write.mint([vault.address, 7n]);
      await viem.assertions.emitWithArgs(vault.write.sync([b], { account: governance.account }), vault, "Synced", [
        getAddress(b),
        7n,
        doubled[1] + INITIAL_AMOUNTS[1] + 7n,
      ]);
      await vault.write.mint([INITIAL_SHARES, [maxUint256, maxUint256], 0n, 1n], { account: carol.account });
      await vault.write.redeem([INITIAL_SHARES, [0n, 0n], 1n], { account: bob.account });

      // What is left of A is now outside the basket, so governance decides on all of it.
      await vault.write.rescue([a, governance.account.address, 5n], { account: governance.account });
      assert.equal(await tokens[0].read.balanceOf([vault.address]), 0n);
      assert.deepEqual(
        await Promise.all(tokens.slice(1).map((token) => token.read.balanceOf([vault.address]))),
        await vault.read.reserves(),
      );
    });

    it("keeps at least one component", async () => {
      const { vault, tokens, governance } = await networkHelpers.loadFixture(basketFixture);
      // Without supply every reserve is zero, so any component may go, except the last.
      await vault.write.removeComponent([tokens[1].address], { account: governance.account });
      await vault.write.removeComponent([tokens[0].address], { account: governance.account });
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.removeComponent([tokens[2].address], { account: governance.account }),
        vault,
        "InvalidComponentCount",
        [0n],
      );
    });

    it("binds amounts by position to the basket version, so limits never apply to another token", async () => {
      const { vault, tokens, tokenD, governance, alice, dave } = await networkHelpers.loadFixture(rebalancerFixture);
      assert.equal(await vault.read.basketVersion(), 0n);

      // A leaves and D joins: the basket keeps three entries, but each position holds another token.
      await vault.write.announceComponent([tokenD.address], { account: governance.account });
      await networkHelpers.time.increase(SEVEN_DAYS);
      await vault.write.swap([tokens[0].address, doubled[0], tokens[1].address, INITIAL_AMOUNTS[1]], {
        account: dave.account,
      });
      await vault.write.removeComponent([tokens[0].address], { account: governance.account });
      assert.equal(await vault.read.basketVersion(), 1n);
      await vault.write.addComponent([tokenD.address], { account: alice.account });
      assert.equal(await vault.read.basketVersion(), 2n);

      for (const call of [
        () => vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account }),
        () => vault.write.redeem([INITIAL_SHARES, NO_MIN, 0n], { account: alice.account }),
        () => vault.write.redeemSkipping([INITIAL_SHARES, NO_MIN, [], 0n], { account: alice.account }),
        () => vault.write.setInitialAmounts([INITIAL_AMOUNTS, 0n], { account: governance.account }),
      ]) {
        await viem.assertions.revertWithCustomErrorWithArgs(call(), vault, "BasketChanged", [0n, 2n]);
      }
      // The same arrays, prepared for the current basket, go through.
      await vault.write.redeem([INITIAL_SHARES, NO_MIN, 2n], { account: alice.account });
      assert.equal(await vault.read.balanceOf([alice.account.address]), 0n);
    });

    it("swaps and basket changes are closed during liquidation", async () => {
      const { vault, tokens, tokenD, governance, dave } = await networkHelpers.loadFixture(rebalancerFixture);
      await vault.write.announceComponent([tokenD.address], { account: governance.account });
      await networkHelpers.time.increase(SEVEN_DAYS);
      await vault.write.activateLiquidation({ account: governance.account });

      for (const call of [
        () => vault.write.swap([tokens[0].address, 1n, tokens[1].address, 1n], { account: dave.account }),
        () => vault.write.addComponent([tokenD.address], { account: governance.account }),
        () => vault.write.removeComponent([tokens[0].address], { account: governance.account }),
      ]) {
        await viem.assertions.revertWithCustomError(call(), vault, "LiquidationIsActive");
      }
    });
  });

  describe("writing off a component", () => {
    it("governance decides, the vault waits 7 days, anyone executes it and the vault works again", async () => {
      const basket = await networkHelpers.loadFixture(rebalancerFixture);
      const { vault, faulty, governance, alice, carol } = basket;
      const c = faulty.address;

      // The issuer freezes the vault: redemption reverts and the component cannot be sold.
      await faulty.write.setBlocked([vault.address, true]);
      await assert.rejects(vault.write.redeem([INITIAL_SHARES, NO_MIN, 0n], { account: alice.account }));
      const hash = await vault.write.proposeWriteOff([c], { account: governance.account });
      const readyAt = (await blockTimestamp(hash)) + SEVEN_DAYS;
      assert.equal(await vault.read.writeOffReadyAt([c]), readyAt);

      await networkHelpers.time.setNextBlockTimestamp(readyAt - 1n);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.writeOffComponent([c], { account: carol.account }),
        vault,
        "WriteOffNotReady",
        [getAddress(c), readyAt],
      );
      await networkHelpers.time.setNextBlockTimestamp(readyAt);
      await viem.assertions.emitWithArgs(
        vault.write.writeOffComponent([c], { account: carol.account }),
        vault,
        "ComponentWrittenOff",
        [getAddress(c), doubled[2]],
      );
      assert.deepEqual(await vault.read.reserves(), [doubled[0], doubled[1], 0n]);
      assert.deepEqual(await vault.read.initialAmounts(), [INITIAL_AMOUNTS[0], INITIAL_AMOUNTS[1], 0n]);
      assert.equal(await vault.read.writtenOff([c]), true);
      assert.equal(await vault.read.writeOffReadyAt([c]), 0n);
      assert.equal(await faulty.read.rawBalanceOf([vault.address]), doubled[2]);

      // Mint and redemption continue without it. It stays in the basket for good.
      assert.deepEqual(await vault.read.previewMint([INITIAL_SHARES]), [INITIAL_AMOUNTS[0], INITIAL_AMOUNTS[1], 0n]);
      const before = await balancesOf(basket, alice.account.address);
      await vault.write.redeem([INITIAL_SHARES, NO_MIN, 0n], { account: alice.account });
      const after = await balancesOf(basket, alice.account.address);
      assert.deepEqual(after.map((balance, i) => balance - before[i]), [INITIAL_AMOUNTS[0], INITIAL_AMOUNTS[1], 0n]);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.removeComponent([c], { account: governance.account }),
        vault,
        "TokenWrittenOff",
        [getAddress(c)],
      );
      assert.equal(await vault.read.componentCount(), 3n);
    });

    it("works on a healthy component too, and sync undoes a mistaken write-off", async () => {
      const { vault, tokens, governance } = await networkHelpers.loadFixture(rebalancerFixture);
      const a = tokens[0].address;
      await vault.write.proposeWriteOff([a], { account: governance.account });
      await networkHelpers.time.increase(SEVEN_DAYS);
      await vault.write.writeOffComponent([a]);
      assert.deepEqual(await vault.read.reserves(), [0n, doubled[1], doubled[2]]);

      await viem.assertions.revertWithCustomError(
        vault.write.rescue([a, governance.account.address, 1n], { account: governance.account }),
        vault,
        "TokenWrittenOff",
      );
      await vault.write.sync([a], { account: governance.account });
      assert.deepEqual(await vault.read.reserves(), doubled);
    });

    it("never lets governance take what was written off: sync returns it to the reserves at once", async () => {
      const { vault, faulty, governance, carol } = await networkHelpers.loadFixture(rebalancerFixture);
      const c = faulty.address;
      await faulty.write.setFault([Fault.RevertOnTransfer]);
      await vault.write.proposeWriteOff([c], { account: governance.account });
      await networkHelpers.time.increase(SEVEN_DAYS);
      await vault.write.writeOffComponent([c], { account: governance.account });

      // The issuer lifts the block: the balance is back, but it is not governance's.
      await faulty.write.setFault([Fault.None]);
      assert.equal(await vault.read.componentSurplus([2n]), doubled[2]);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.rescue([c, governance.account.address, 1n], { account: governance.account }),
        vault,
        "TokenWrittenOff",
        [getAddress(c)],
      );

      // It stays in the basket, so sync returns the whole balance to the holders at once.
      await viem.assertions.emitWithArgs(vault.write.sync([c], { account: governance.account }), vault, "Synced", [
        getAddress(c),
        doubled[2],
        doubled[2],
      ]);
      assert.deepEqual(await vault.read.reserves(), doubled);
      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: carol.account });
      assert.equal(await faulty.read.balanceOf([vault.address]), doubled[2] + INITIAL_AMOUNTS[2]);
    });

    it("checks permissions, can be cancelled and is closed during liquidation", async () => {
      const { vault, faulty, tokenD, governance, alice } = await networkHelpers.loadFixture(rebalancerFixture);
      const c = faulty.address;

      await viem.assertions.revertWithCustomError(
        vault.write.proposeWriteOff([c], { account: alice.account }),
        vault,
        "NotGovernance",
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.proposeWriteOff([tokenD.address], { account: governance.account }),
        vault,
        "NotAComponent",
        [getAddress(tokenD.address)],
      );
      for (const call of [
        () => vault.write.cancelWriteOff([c], { account: governance.account }),
        () => vault.write.writeOffComponent([c], { account: governance.account }),
      ]) {
        await viem.assertions.revertWithCustomErrorWithArgs(call(), vault, "NoPendingWriteOff", [getAddress(c)]);
      }

      await vault.write.proposeWriteOff([c], { account: governance.account });
      await viem.assertions.revertWithCustomError(
        vault.write.cancelWriteOff([c], { account: alice.account }),
        vault,
        "NotGovernance",
      );
      await viem.assertions.emitWithArgs(
        vault.write.cancelWriteOff([c], { account: governance.account }),
        vault,
        "WriteOffCancelled",
        [getAddress(c)],
      );
      await networkHelpers.time.increase(SEVEN_DAYS);
      await viem.assertions.revertWithCustomError(
        vault.write.writeOffComponent([c], { account: governance.account }),
        vault,
        "NoPendingWriteOff",
      );

      await vault.write.proposeWriteOff([c], { account: governance.account });
      await networkHelpers.time.increase(SEVEN_DAYS);
      await vault.write.activateLiquidation({ account: governance.account });
      await viem.assertions.revertWithCustomError(
        vault.write.writeOffComponent([c], { account: governance.account }),
        vault,
        "LiquidationIsActive",
      );
    });

    it("needs a reserve to write off; without one, removing the component is enough", async () => {
      const { vault, faulty, governance } = await networkHelpers.loadFixture(basketFixture);
      const c = faulty.address;
      await vault.write.proposeWriteOff([c], { account: governance.account });
      await networkHelpers.time.increase(SEVEN_DAYS);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.writeOffComponent([c], { account: governance.account }),
        vault,
        "NoReserve",
        [getAddress(c)],
      );
      await vault.write.removeComponent([c], { account: governance.account });
      assert.equal(await vault.read.writeOffReadyAt([c]), 0n);
    });
  });

  describe("proposal expiry", () => {
    it("every proposal can be executed or accepted only during the 7 days after its wait", async () => {
      const { vault, tokenD, faulty, governance, alice, carol } = await networkHelpers.loadFixture(rebalancerFixture);
      await vault.write.setFeeRecipient([carol.account.address], { account: governance.account });
      await vault.write.announceComponent([tokenD.address], { account: governance.account });
      await vault.write.proposeWriteOff([faulty.address], { account: governance.account });
      await vault.write.proposeFees([100n, 100n], { account: governance.account });
      await vault.write.proposeRebalancer([alice.account.address], { account: governance.account });
      await vault.write.proposeGovernance([carol.account.address], { account: governance.account });
      const window = await vault.read.EXECUTION_WINDOW();
      assert.equal(window, SEVEN_DAYS);

      const proposals = [
        { readyAt: await vault.read.componentReadyAt([tokenD.address]), run: () => vault.write.addComponent([tokenD.address]) },
        { readyAt: await vault.read.writeOffReadyAt([faulty.address]), run: () => vault.write.writeOffComponent([faulty.address]) },
        { readyAt: await vault.read.pendingFeesReadyAt(), run: () => vault.write.applyFees() },
        {
          readyAt: await vault.read.pendingRebalancerReadyAt(),
          run: () => vault.write.acceptRebalancer({ account: alice.account }),
        },
        {
          readyAt: await vault.read.pendingGovernanceReadyAt(),
          run: () => vault.write.acceptGovernance({ account: carol.account }),
        },
      ];
      await networkHelpers.time.increaseTo(proposals.at(-1)!.readyAt + window + 1n);
      for (const { readyAt, run } of proposals) {
        await viem.assertions.revertWithCustomErrorWithArgs(run(), vault, "ProposalExpired", [readyAt + window]);
      }

      // Proposed again, each one works up to the last second of its window.
      await vault.write.announceComponent([tokenD.address], { account: governance.account });
      const expiredAt = (await vault.read.componentReadyAt([tokenD.address])) + window;
      await networkHelpers.time.setNextBlockTimestamp(expiredAt);
      await vault.write.addComponent([tokenD.address]);
      assert.equal(await vault.read.componentCount(), 4n);
    });

    it("revoking the rebalancer also discards a pending one", async () => {
      const { vault, governance, alice } = await networkHelpers.loadFixture(rebalancerFixture);
      await vault.write.proposeRebalancer([alice.account.address], { account: governance.account });
      await viem.assertions.emitWithArgs(
        vault.write.revokeRebalancer({ account: governance.account }),
        vault,
        "RebalancerProposalCancelled",
        [getAddress(alice.account.address)],
      );
      assert.equal(await vault.read.rebalancer(), zeroAddress);
      assert.equal(await vault.read.pendingRebalancer(), zeroAddress);
      await networkHelpers.time.increase(SEVEN_DAYS);
      await viem.assertions.revertWithCustomError(
        vault.write.acceptRebalancer({ account: alice.account }),
        vault,
        "NotPendingRebalancer",
      );
    });
  });

  describe("initial amounts", () => {
    it("governance sets the basket of the first mint, which applies only while the supply is zero", async () => {
      const basket = await networkHelpers.loadFixture(rebalancerFixture);
      const { vault, tokens, governance, alice, bob } = basket;
      const next = [INITIAL_AMOUNTS[0] / 2n, 0n, INITIAL_AMOUNTS[2] * 3n];

      await viem.assertions.revertWithCustomError(
        vault.write.setInitialAmounts([next, 0n], { account: alice.account }),
        vault,
        "NotGovernance",
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.setInitialAmounts([next.slice(0, 2), 0n], { account: governance.account }),
        vault,
        "LengthMismatch",
        [3n, 2n],
      );
      await viem.assertions.revertWithCustomError(
        vault.write.setInitialAmounts([[0n, 0n, 0n], 0n], { account: governance.account }),
        vault,
        "EmptyBasket",
      );
      await viem.assertions.emitWithArgs(
        vault.write.setInitialAmounts([next, 0n], { account: governance.account }),
        vault,
        "InitialAmountsSet",
        [next],
      );
      assert.deepEqual(await vault.read.initialAmounts(), next);

      // With holders, mint still follows the reserves.
      assert.deepEqual(
        await vault.read.previewMint([INITIAL_SHARES]),
        doubled.map((reserve) => reserve / 2n),
      );
      await vault.write.redeem([INITIAL_SHARES, NO_MIN, 0n], { account: alice.account });
      await vault.write.redeem([INITIAL_SHARES, NO_MIN, 0n], { account: bob.account });

      // Without supply, the next first mint contributes the new basket and skips the zero.
      const before = await balancesOf(basket, alice.account.address);
      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
      const after = await balancesOf(basket, alice.account.address);
      assert.deepEqual(before.map((balance, i) => balance - after[i]), next);
      assert.deepEqual(await vault.read.reserves(), next);
      assert.equal(await tokens[1].read.balanceOf([vault.address]), 0n);
    });
  });
});
