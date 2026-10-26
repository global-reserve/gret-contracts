import assert from "node:assert/strict";
import { after, describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress, parseUnits, zeroAddress } from "viem";

import { deployBasket, Fault, INITIAL_AMOUNTS, INITIAL_SHARES, NO_MAX } from "./helpers/basket.js";

const DAY = 24n * 60n * 60n;
const WEEK = 7n * DAY;
const ONE = 10n ** 18n;
const LIMIT = parseUnits("0.02", 18);

/** The share of the vault a loss takes, as the guard records it: rounded up, with 18 decimals. */
const shareOf = (loss: bigint, vaultValue: bigint) => (loss * ONE + vaultValue - 1n) / vaultValue;

describe("ChainlinkPriceGuard", async () => {
  const connection = await network.create("hardhat");
  const { viem, networkHelpers } = connection;
  after(() => connection.close());

  // A is worth $100 (8-decimal feed), B $80,000 (B has 8 decimals) and C $40 (18-decimal feed).
  const PRICES = [100n * 10n ** 8n, 80_000n * 10n ** 8n, 40n * 10n ** 18n];
  const FEED_DECIMALS = [8, 8, 18];

  /**
   * alice and bob minted 1 GRET each, so the vault holds 4 A ($400), 0.002 B ($160) and 10 C
   * ($400): $960. dave is the rebalancer and the guard prices A, B and C, or only the tokens in
   * `priced`. The clock sits one minute into a week, with fresh prices.
   */
  async function deployGuarded(priced = [0, 1, 2]) {
    const basket = await deployBasket(viem);
    const { vault, tokens, governance, alice, bob, dave } = basket;
    const feeds = await Promise.all(
      PRICES.map((price, i) => viem.deployContract("MockAggregator", [FEED_DECIMALS[i], price])),
    );
    const guard = await viem.deployContract("ChainlinkPriceGuard", [
      vault.address,
      priced.map((i) => tokens[i].address),
      priced.map((i) => feeds[i].address),
      priced.map(() => DAY),
    ]);
    await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
    await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: bob.account });
    await vault.write.proposeRebalancer([dave.account.address], { account: governance.account });
    await vault.write.proposePriceGuard([guard.address], { account: governance.account });
    const now = BigInt(await networkHelpers.time.latest());
    await networkHelpers.time.increaseTo(((now + WEEK) / WEEK + 1n) * WEEK + 60n);
    await vault.write.acceptRebalancer({ account: dave.account });
    await vault.write.applyPriceGuard();
    for (const [i, feed] of feeds.entries()) await feed.write.setAnswer([PRICES[i]]);
    return { ...basket, feeds, guard };
  }

  const guardFixture = () => deployGuarded();
  const partialFixture = () => deployGuarded([0, 1]);

  async function blockTimestamp(hash: `0x${string}`) {
    const publicClient = await viem.getPublicClient();
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    return (await publicClient.getBlock({ blockNumber: receipt.blockNumber })).timestamp;
  }

  describe("configuration", () => {
    it("is fixed at deployment: no owner and nothing to change but the record of losses", async () => {
      const { vault, tokens, feeds, guard } = await networkHelpers.loadFixture(guardFixture);
      const mutating = guard.abi
        .filter((item) => item.type === "function" && item.stateMutability !== "view")
        .map((item) => (item as { name: string }).name);
      assert.deepEqual(mutating, ["checkSwap"]);
      assert.equal(await guard.read.vault(), getAddress(vault.address));
      for (const [i, token] of tokens.entries()) {
        assert.deepEqual(await guard.read.priceFeed([token.address]), [getAddress(feeds[i].address), DAY]);
      }
      assert.deepEqual(await guard.read.priceFeed([zeroAddress]), [zeroAddress, 0n]);
      assert.equal(await guard.read.MAX_SWAP_LOSS(), 200n);
      assert.equal(await guard.read.MAX_WEEKLY_LOSS(), 200n);
      assert.equal(await guard.read.WEEK(), WEEK);
    });

    it("rejects an inconsistent configuration", async () => {
      const { vault, tokens, feeds, guard, alice } = await networkHelpers.loadFixture(guardFixture);
      const [a, b] = tokens.map((token) => token.address);
      const [feedA, feedB] = feeds.map((feed) => feed.address);
      const eoa = alice.account.address;
      const deploy = (target: `0x${string}`, list: `0x${string}`[], sources: `0x${string}`[], ages: bigint[]) => () =>
        viem.deployContract("ChainlinkPriceGuard", [target, list, sources, ages]);
      const cases = [
        { deployment: deploy(eoa, [a], [feedA], [DAY]), error: "NotAContract", errorArgs: [getAddress(eoa)] },
        { deployment: deploy(vault.address, [a, b], [feedA], [DAY, DAY]), error: "LengthMismatch", errorArgs: [] },
        { deployment: deploy(vault.address, [a], [feedA], [DAY, DAY]), error: "LengthMismatch", errorArgs: [] },
        { deployment: deploy(vault.address, [eoa], [feedA], [DAY]), error: "NotAContract", errorArgs: [getAddress(eoa)] },
        { deployment: deploy(vault.address, [a], [eoa], [DAY]), error: "NotAContract", errorArgs: [getAddress(eoa)] },
        { deployment: deploy(vault.address, [a], [feedA], [0n]), error: "ZeroMaxAge", errorArgs: [getAddress(a)] },
        {
          deployment: deploy(vault.address, [a, a], [feedA, feedB], [DAY, DAY]),
          error: "DuplicateToken",
          errorArgs: [getAddress(a)],
        },
      ] as const;
      for (const { deployment, error, errorArgs } of cases) {
        await viem.assertions.revertWithCustomErrorWithArgs(
          deployment() as unknown as Promise<`0x${string}`>,
          guard,
          error,
          errorArgs as never,
        );
      }
    });

    it("only the vault records swaps", async () => {
      const { tokens, guard, dave } = await networkHelpers.loadFixture(guardFixture);
      await viem.assertions.revertWithCustomErrorWithArgs(
        guard.write.checkSwap([tokens[0].address, 1n, tokens[1].address, 1n], { account: dave.account }),
        guard,
        "NotVault",
        [getAddress(dave.account.address)],
      );
    });
  });

  describe("prices", () => {
    it("values whole tokens in dollars with 18 decimals, whatever the decimals of token and feed", async () => {
      const { tokens, guard } = await networkHelpers.loadFixture(guardFixture);
      const [a, b, c] = tokens.map((token) => token.address);
      assert.equal(await guard.read.valueOf([a, parseUnits("1", 18)]), parseUnits("100", 18));
      assert.equal(await guard.read.valueOf([b, parseUnits("1", 8)]), parseUnits("80000", 18));
      assert.equal(await guard.read.valueOf([c, parseUnits("1", 18)]), parseUnits("40", 18));
      assert.equal(await guard.read.valueOf([b, 1n]), parseUnits("0.0008", 18));
      assert.equal(await guard.read.valueOf([a, 1n]), 100n);
    });

    it("refuses a token without a feed, and a stale, future, zero or negative price", async () => {
      const { tokens, feeds, guard } = await networkHelpers.loadFixture(guardFixture);
      const outside = await viem.deployContract("MockERC20", ["Mock D", "MD", 6]);
      const a = tokens[0].address;
      await viem.assertions.revertWithCustomErrorWithArgs(guard.read.valueOf([outside.address, 1n]), guard, "NoFeed", [
        getAddress(outside.address),
      ]);

      const now = BigInt(await networkHelpers.time.latest());
      for (const updatedAt of [now - DAY - 10n, now + 3600n, 0n]) {
        await feeds[0].write.setRound([PRICES[0], updatedAt]);
        await viem.assertions.revertWithCustomErrorWithArgs(guard.read.valueOf([a, 1n]), guard, "StalePrice", [
          getAddress(a),
          updatedAt,
        ]);
      }
      for (const answer of [0n, -1n]) {
        await feeds[0].write.setAnswer([answer]);
        await viem.assertions.revertWithCustomErrorWithArgs(guard.read.valueOf([a, 1n]), guard, "InvalidPrice", [
          getAddress(a),
          answer,
        ]);
      }
    });
  });

  describe("swaps", () => {
    it("accepts a fair or favorable swap without recording a loss", async () => {
      const { vault, tokens, guard, dave } = await networkHelpers.loadFixture(guardFixture);
      const [a, , c] = tokens.map((token) => token.address);
      // $100 of A for $100 of C, then for $120 of C.
      await vault.write.swap([a, parseUnits("1", 18), c, parseUnits("2.5", 18)], { account: dave.account });
      await vault.write.swap([a, parseUnits("1", 18), c, parseUnits("3", 18)], { account: dave.account });
      assert.equal(await guard.read.weeklyLoss(), 0n);
      assert.equal(await guard.read.currentWeek(), 0n);
    });

    it("refuses a single swap that loses more than 2% of what the vault sells", async () => {
      const { vault, tokens, guard, dave } = await networkHelpers.loadFixture(guardFixture);
      const [a, , c] = tokens.map((token) => token.address);
      // The original drain: everything for 1 wei.
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.swap([a, INITIAL_AMOUNTS[0] * 2n, c, 1n], { account: dave.account }),
        guard,
        "SwapLossTooHigh",
        [parseUnits("400", 18), 40n],
      );
      // $100 of A for $97.96 of C loses 2.04%.
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.swap([a, parseUnits("1", 18), c, parseUnits("2.449", 18)], { account: dave.account }),
        guard,
        "SwapLossTooHigh",
        [parseUnits("100", 18), parseUnits("97.96", 18)],
      );
      // Exactly 2% passes: $2 of the vault's $960.
      const hash = await vault.write.swap([a, parseUnits("1", 18), c, parseUnits("2.45", 18)], { account: dave.account });
      const share = shareOf(parseUnits("2", 18), parseUnits("960", 18));
      await viem.assertions.emitWithArgs(Promise.resolve(hash), guard, "LossRecorded", [
        getAddress(a),
        getAddress(c),
        parseUnits("2", 18),
        parseUnits("960", 18),
        share,
      ]);
      assert.equal(await guard.read.currentWeek(), (await blockTimestamp(hash)) / WEEK);
      assert.equal(await guard.read.weeklyLoss(), share);
    });

    it("stops the week's swaps once they take 2% of the vault's value, and the next week starts over", async () => {
      const { vault, tokens, feeds, guard, dave } = await networkHelpers.loadFixture(guardFixture);
      const [a, , c] = tokens.map((token) => token.address);
      // Each swap loses $1.90, 1.9% of the $100 it sells, counted against the vault's value then.
      const aForC = () => vault.write.swap([a, parseUnits("1", 18), c, parseUnits("2.4525", 18)], { account: dave.account });
      const cForA = () => vault.write.swap([c, parseUnits("2.5", 18), a, parseUnits("0.981", 18)], { account: dave.account });
      const loss = parseUnits("1.9", 18);
      let value = parseUnits("960", 18);
      let expected = 0n;
      for (let i = 0; i < 10; i++) {
        await (i % 2 === 0 ? aForC() : cForA());
        expected += shareOf(loss, value);
        value -= loss;
      }
      assert.equal(await guard.read.weeklyLoss(), expected);
      assert.ok(expected < LIMIT);
      await viem.assertions.revertWithCustomErrorWithArgs(aForC(), guard, "WeeklyLossTooHigh", [
        expected + shareOf(loss, value),
        LIMIT,
      ]);

      // A week later the count starts over, against what the vault is worth then: $941.
      await networkHelpers.time.increase(WEEK);
      for (const [i, feed] of feeds.entries()) await feed.write.setAnswer([PRICES[i]]);
      await aForC();
      assert.equal(await guard.read.weeklyLoss(), shareOf(loss, parseUnits("941", 18)));
    });

    it("keeps the week's count when the vault empties and starts again", async () => {
      const { vault, tokens, guard, alice, bob, dave } = await networkHelpers.loadFixture(guardFixture);
      const [a, , c] = tokens.map((token) => token.address);
      const aForC = () => vault.write.swap([a, parseUnits("1", 18), c, parseUnits("2.4525", 18)], { account: dave.account });
      const cForA = () => vault.write.swap([c, parseUnits("2.5", 18), a, parseUnits("0.981", 18)], { account: dave.account });
      for (let i = 0; i < 10; i++) await (i % 2 === 0 ? aForC() : cForA());
      const used = await guard.read.weeklyLoss();
      await vault.write.redeem([INITIAL_SHARES, [0n, 0n, 0n], 0n], { account: bob.account });
      await vault.write.redeem([INITIAL_SHARES, [0n, 0n, 0n], 0n], { account: alice.account });
      assert.equal(await vault.read.totalSupply(), 0n);
      // The vault starts over at $480; $1.90 more is 0.4% of it, above what is left of the 2%.
      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
      await viem.assertions.revertWithCustomErrorWithArgs(aForC(), guard, "WeeklyLossTooHigh", [
        used + shareOf(parseUnits("1.9", 18), parseUnits("480", 18)),
        LIMIT,
      ]);
    });

    it("values each component at the lesser of its reserve and the vault's balance", async () => {
      const { vault, tokens, faulty, guard, dave } = await networkHelpers.loadFixture(guardFixture);
      const [a, b] = tokens.map((token) => token.address);
      // C loses half its balance and nobody recognizes it: it counts as $200, not $400. A donation
      // of A is not reserve: A still counts as $400.
      await faulty.write.slash([vault.address, parseUnits("5", 18)]);
      await tokens[0].write.mint([vault.address, parseUnits("10", 18)]);
      const aForB = () => vault.write.swap([a, parseUnits("1", 18), b, 123_125n], { account: dave.account });
      await aForB();
      const first = shareOf(parseUnits("1.5", 18), parseUnits("760", 18));
      assert.equal(await guard.read.weeklyLoss(), first);

      // A balance it cannot read counts as zero: $300 of A and $258.50 of B.
      await faulty.write.setFault([Fault.RevertOnBalanceOf]);
      await aForB();
      assert.equal(await guard.read.weeklyLoss(), first + shareOf(parseUnits("1.5", 18), parseUnits("558.5", 18)));
    });

    it("refuses tokens it cannot price, and counts them as zero in the vault's value", async () => {
      const { vault, tokens, feeds, guard, dave } = await networkHelpers.loadFixture(partialFixture);
      const [a, b, c] = tokens.map((token) => token.address);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.swap([a, parseUnits("1", 18), c, parseUnits("2.5", 18)], { account: dave.account }),
        guard,
        "NoFeed",
        [getAddress(c)],
      );
      // $100 of A for $98.50 of B; C is left out, so the vault counts as $560.
      await vault.write.swap([a, parseUnits("1", 18), b, 123_125n], { account: dave.account });
      assert.equal(await guard.read.weeklyLoss(), shareOf(parseUnits("1.5", 18), parseUnits("560", 18)));

      // A stale price stops every swap of that token.
      const stale = BigInt(await networkHelpers.time.latest()) - DAY - 10n;
      await feeds[0].write.setRound([PRICES[0], stale]);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.swap([a, parseUnits("1", 18), b, 125_000n], { account: dave.account }),
        guard,
        "StalePrice",
        [getAddress(a), stale],
      );
    });

    it("leaves a component with a stale price out of the vault's value", async () => {
      const { vault, tokens, feeds, guard, dave } = await networkHelpers.loadFixture(guardFixture);
      const [a, b, c] = tokens.map((token) => token.address);
      await feeds[1].write.setRound([PRICES[1], BigInt(await networkHelpers.time.latest()) - DAY - 10n]);
      // $100 of A for $98.10 of C; B is left out, so the vault counts as $800.
      await vault.write.swap([a, parseUnits("1", 18), c, parseUnits("2.4525", 18)], { account: dave.account });
      assert.equal(await guard.read.weeklyLoss(), shareOf(parseUnits("1.9", 18), parseUnits("800", 18)));
      await viem.assertions.revertWithCustomError(
        vault.write.swap([b, 1n, a, 1n], { account: dave.account }),
        guard,
        "StalePrice",
      );
    });
  });
});
