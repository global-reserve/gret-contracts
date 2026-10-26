import assert from "node:assert/strict";
import { after, describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, getAddress, maxUint256, parseEther, parseUnits } from "viem";

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

describe("GRETVault: adversarial components and callers", async () => {
  const connection = await network.create("hardhat");
  const { viem, networkHelpers } = connection;
  after(() => connection.close());

  async function holdersFixture() {
    const basket = await deployBasket(viem);
    const { vault, alice, bob } = basket;
    await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
    await vault.write.mint([INITIAL_SHARES / 3n, NO_MAX, 0n, 0n], { account: bob.account });
    return basket;
  }

  /**
   * Same basket, but governance and rebalancer are the faulty component itself, so a reentrant
   * call from the token also passes their checks and reaches the reentrancy guard of every
   * function.
   */
  async function hostileGovernanceFixture() {
    const [, , alice] = await viem.getWalletClients();
    const tokenA = await viem.deployContract("MockERC20", ["Mock A", "MA", 18]);
    const tokenB = await viem.deployContract("MockERC20", ["Mock B", "MB", 8]);
    const faulty = await viem.deployContract("MockFaultyERC20", ["Mock C", "MC", 18]);
    const tokens = [tokenA, tokenB, await viem.getContractAt("MockERC20", faulty.address)];
    const vault = await viem.deployContract("GRETVault", [
      tokens.map((token) => token.address),
      INITIAL_AMOUNTS,
      faulty.address,
    ]);
    for (const token of tokens) {
      await token.write.mint([alice.account.address, parseUnits("1000000", 18)]);
      await token.write.approve([vault.address, maxUint256], { account: alice.account });
    }
    await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
    await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
    await networkHelpers.impersonateAccount(faulty.address);
    await networkHelpers.setBalance(faulty.address, parseEther("10"));
    const guard = await viem.deployContract("MockPriceGuard");
    await vault.write.proposeRebalancer([faulty.address], { account: faulty.address });
    await vault.write.proposePriceGuard([guard.address], { account: faulty.address });
    await networkHelpers.time.increase(await vault.read.BASKET_CHANGE_DELAY());
    await vault.write.acceptRebalancer({ account: faulty.address });
    await vault.write.applyPriceGuard();
    await faulty.write.mint([faulty.address, parseUnits("10", 18)]);
    await faulty.write.approve([vault.address, maxUint256], { account: faulty.address });
    return { vault, tokens, faulty, alice };
  }

  describe("reentrancy from every external call into every state-changing function", () => {
    type Setup = Awaited<ReturnType<typeof hostileGovernanceFixture>>;
    const reentries: [string, (setup: Setup) => `0x${string}`][] = [
      ["mint", ({ vault }) => encodeFunctionData({ abi: vault.abi, functionName: "mint", args: [1n, NO_MAX, 0n, 0n] })],
      ["redeem", ({ vault }) => encodeFunctionData({ abi: vault.abi, functionName: "redeem", args: [1n, NO_MIN, 0n] })],
      [
        "redeemSkipping",
        ({ vault }) => encodeFunctionData({ abi: vault.abi, functionName: "redeemSkipping", args: [1n, NO_MIN, [], 0n] }),
      ],
      ["sync", ({ vault, tokens }) => encodeFunctionData({ abi: vault.abi, functionName: "sync", args: [tokens[0].address] })],
      [
        "rescue",
        ({ vault, tokens, faulty }) =>
          encodeFunctionData({ abi: vault.abi, functionName: "rescue", args: [tokens[0].address, faulty.address, 1n] }),
      ],
      ["activateLiquidation", ({ vault }) => encodeFunctionData({ abi: vault.abi, functionName: "activateLiquidation" })],
      ["convertToClaims", ({ vault }) => encodeFunctionData({ abi: vault.abi, functionName: "convertToClaims", args: [1n] })],
      [
        "claim",
        ({ vault, faulty }) => encodeFunctionData({ abi: vault.abi, functionName: "claim", args: [0n, faulty.address, 0n] }),
      ],
      [
        "swap",
        ({ vault, tokens }) =>
          encodeFunctionData({ abi: vault.abi, functionName: "swap", args: [tokens[0].address, 1n, tokens[1].address, 1n] }),
      ],
      [
        "addComponent",
        ({ vault, tokens }) => encodeFunctionData({ abi: vault.abi, functionName: "addComponent", args: [tokens[0].address] }),
      ],
      [
        "removeComponent",
        ({ vault, tokens }) =>
          encodeFunctionData({ abi: vault.abi, functionName: "removeComponent", args: [tokens[0].address] }),
      ],
      [
        "setInitialAmounts",
        ({ vault }) => encodeFunctionData({ abi: vault.abi, functionName: "setInitialAmounts", args: [INITIAL_AMOUNTS, 0n] }),
      ],
      ["applyFees", ({ vault }) => encodeFunctionData({ abi: vault.abi, functionName: "applyFees" })],
      [
        "writeOffComponent",
        ({ vault, tokens }) =>
          encodeFunctionData({ abi: vault.abi, functionName: "writeOffComponent", args: [tokens[0].address] }),
      ],
    ];
    const entries: [string, boolean, (setup: Setup) => Promise<`0x${string}`>][] = [
      ["mint", false, ({ vault, alice }) => vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account })],
      ["redeem", false, ({ vault, alice }) => vault.write.redeem([INITIAL_SHARES / 2n, NO_MIN, 0n], { account: alice.account })],
      [
        "rescue",
        false,
        ({ vault, faulty }) => vault.write.rescue([faulty.address, faulty.address, 1n], { account: faulty.address }),
      ],
      ["claim", true, ({ vault, alice }) => vault.write.claim([2n, alice.account.address, 0n], { account: alice.account })],
      [
        "swap",
        false,
        ({ vault, tokens, faulty }) =>
          vault.write.swap([tokens[0].address, 1n, faulty.address, 1n], { account: faulty.address }),
      ],
    ];

    for (const [entryName, inLiquidation, entry] of entries) {
      it(`${entryName} cannot be reentered through any function`, async () => {
        for (const [reentryName, payload] of reentries) {
          const setup = await networkHelpers.loadFixture(hostileGovernanceFixture);
          const { vault, faulty, alice } = setup;
          if (entryName === "rescue") await faulty.write.mint([vault.address, 10n]);
          if (inLiquidation) {
            await vault.write.activateLiquidation({ account: faulty.address });
            await vault.write.convertToClaims([INITIAL_SHARES / 2n], { account: alice.account });
          }
          const reservesBefore = await vault.read.reserves();
          const supplyBefore = await vault.read.totalSupply();
          await faulty.write.setReentry([vault.address, payload(setup)]);

          await viem.assertions.revertWithCustomError(entry(setup), vault, "ReentrancyGuardReentrantCall");
          assert.deepEqual(await vault.read.reserves(), reservesBefore, `${entryName} <- ${reentryName}`);
          assert.equal(await vault.read.totalSupply(), supplyBefore, `${entryName} <- ${reentryName}`);
        }
      });
    }
  });

  describe("non-standard tokens", () => {
    it("works with a component that returns nothing from transfer, like USDT", async () => {
      const [, governance, alice] = await viem.getWalletClients();
      const usdtLike = await viem.deployContract("MockNoReturnERC20", ["No Return", "NR", 6]);
      const tokenA = await viem.deployContract("MockERC20", ["Mock A", "MA", 18]);
      const vault = await viem.deployContract("GRETVault", [
        [tokenA.address, usdtLike.address],
        [parseUnits("1", 18), parseUnits("3", 6)],
        governance.account.address,
      ]);
      await tokenA.write.mint([alice.account.address, parseUnits("10", 18)]);
      await usdtLike.write.mint([alice.account.address, parseUnits("30", 6)]);
      await tokenA.write.approve([vault.address, maxUint256], { account: alice.account });
      await usdtLike.write.approve([vault.address, maxUint256], { account: alice.account });

      await vault.write.mint([INITIAL_SHARES, [maxUint256, maxUint256], 0n, 0n], { account: alice.account });
      await vault.write.mint([INITIAL_SHARES, [maxUint256, maxUint256], 0n, 0n], { account: alice.account });
      await vault.write.redeem([INITIAL_SHARES, [0n, 0n], 0n], { account: alice.account });
      await usdtLike.write.mint([vault.address, 5n]);
      await vault.write.rescue([usdtLike.address, alice.account.address, 5n], { account: governance.account });
      await vault.write.activateLiquidation({ account: governance.account });
      await vault.write.convertToClaims([INITIAL_SHARES], { account: alice.account });
      await vault.write.claim([1n, alice.account.address, 0n], { account: alice.account });

      assert.equal(await usdtLike.read.balanceOf([alice.account.address]), parseUnits("30", 6) + 5n);
      assert.equal(await usdtLike.read.balanceOf([vault.address]), 0n);
    });

    it("never transfers zero, so tokens that reject zero transfers keep working", async () => {
      const [, governance, alice] = await viem.getWalletClients();
      const tokenA = await viem.deployContract("MockERC20", ["Mock A", "MA", 18]);
      const faulty = await viem.deployContract("MockFaultyERC20", ["Tiny", "TINY", 0]);
      // One indivisible unit of the faulty component per GRET: small redemptions round it to zero.
      const vault = await viem.deployContract("GRETVault", [
        [tokenA.address, faulty.address],
        [parseUnits("1", 18), 1n],
        governance.account.address,
      ]);
      await tokenA.write.mint([alice.account.address, parseUnits("10", 18)]);
      await faulty.write.mint([alice.account.address, 10n]);
      await tokenA.write.approve([vault.address, maxUint256], { account: alice.account });
      await faulty.write.approve([vault.address, maxUint256], { account: alice.account });
      await vault.write.mint([INITIAL_SHARES, [maxUint256, maxUint256], 0n, 0n], { account: alice.account });
      await vault.write.mint([INITIAL_SHARES, [maxUint256, maxUint256], 0n, 0n], { account: alice.account });
      await faulty.write.setFault([Fault.RevertOnZeroTransfer]);

      await vault.write.redeem([INITIAL_SHARES / 2n, [0n, 0n], 0n], { account: alice.account });
      assert.equal(await faulty.read.balanceOf([vault.address]), 2n);

      await vault.write.activateLiquidation({ account: governance.account });
      await vault.write.convertToClaims([INITIAL_SHARES / 4n], { account: alice.account });
      await viem.assertions.revertWithCustomError(
        vault.write.claim([1n, alice.account.address, 0n], { account: alice.account }),
        vault,
        "NothingToClaim",
      );
      await vault.write.claim([0n, alice.account.address, 0n], { account: alice.account });
    });

    it("works with components of 0 and 24 decimals and very large amounts", async () => {
      const [, governance, alice] = await viem.getWalletClients();
      const zero = await viem.deployContract("MockERC20", ["Zero", "Z0", 0]);
      const big = await viem.deployContract("MockERC20", ["Big", "B24", 24]);
      const huge = 2n ** 200n;
      const vault = await viem.deployContract("GRETVault", [
        [zero.address, big.address],
        [3n, huge],
        governance.account.address,
      ]);
      await zero.write.mint([alice.account.address, 1000n]);
      await big.write.mint([alice.account.address, huge * 1000n]);
      await zero.write.approve([vault.address, maxUint256], { account: alice.account });
      await big.write.approve([vault.address, maxUint256], { account: alice.account });

      await vault.write.mint([INITIAL_SHARES, [maxUint256, maxUint256], 0n, 0n], { account: alice.account });
      await vault.write.mint([7n * INITIAL_SHARES + 1n, [maxUint256, maxUint256], 0n, 0n], { account: alice.account });
      const shares = 7n * INITIAL_SHARES + 1n;
      assert.deepEqual(await vault.read.reserves(), [
        3n + mulDivUp(shares, 3n, INITIAL_SHARES),
        huge + mulDivUp(shares, huge, INITIAL_SHARES),
      ]);
      await vault.write.redeem([await vault.read.totalSupply(), [0n, 0n], 0n], { account: alice.account });
      assert.deepEqual(await vault.read.reserves(), [0n, 0n]);
    });

    it("reverts cleanly when the amount a mint needs does not fit in 256 bits", async () => {
      // Reserves themselves cannot overflow: they never exceed the token's balance, which the
      // token's own supply bounds. Only the computed contribution can exceed 256 bits.
      const [, governance, alice] = await viem.getWalletClients();
      const token = await viem.deployContract("MockERC20", ["Max", "MAX", 18]);
      const vault = await viem.deployContract("GRETVault", [[token.address], [2n ** 255n], governance.account.address]);
      await token.write.mint([alice.account.address, 2n ** 255n]);
      await token.write.approve([vault.address, maxUint256], { account: alice.account });
      await vault.write.mint([INITIAL_SHARES, [maxUint256], 0n, 0n], { account: alice.account });

      await viem.assertions.revert(vault.write.mint([4n * INITIAL_SHARES, [maxUint256], 0n, 0n], { account: alice.account }));
      assert.deepEqual(await vault.read.reserves(), [2n ** 255n]);
      assert.equal(await vault.read.totalSupply(), INITIAL_SHARES);
    });
  });

  describe("issuer actions on a component", () => {
    it("if the issuer freezes the vault, normal operation stops and liquidation still pays the other components", async () => {
      const basket = await networkHelpers.loadFixture(holdersFixture);
      const { vault, faulty, governance, alice, bob } = basket;
      await faulty.write.setBlocked([vault.address, true]);

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.redeem([INITIAL_SHARES / 10n, NO_MIN, 0n], { account: alice.account }),
        faulty,
        "AccountBlocked",
        [getAddress(vault.address)],
      );
      await viem.assertions.revertWithCustomError(
        vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: bob.account }),
        faulty,
        "AccountBlocked",
      );

      await vault.write.activateLiquidation({ account: governance.account });
      for (const holder of [alice, bob]) {
        const shares = await vault.read.balanceOf([holder.account.address]);
        await vault.write.convertToClaims([shares], { account: holder.account });
        await vault.write.claim([0n, holder.account.address, 0n], { account: holder.account });
        await vault.write.claim([1n, holder.account.address, 0n], { account: holder.account });
        await viem.assertions.revertWithCustomError(
          vault.write.claim([2n, holder.account.address, 0n], { account: holder.account }),
          faulty,
          "AccountBlocked",
        );
      }

      await faulty.write.setBlocked([vault.address, false]);
      await vault.write.claim([2n, alice.account.address, 0n], { account: alice.account });
      await vault.write.claim([2n, bob.account.address, 0n], { account: bob.account });
      assert.ok((await vault.read.totalClaimed())[2] > 0n);
    });

    it("if the issuer freezes a holder, the holder claims that component to another address", async () => {
      const basket = await networkHelpers.loadFixture(holdersFixture);
      const { vault, faulty, governance, alice, bob, carol } = basket;
      await faulty.write.setBlocked([bob.account.address, true]);

      // Normal redemption is all or nothing, so the frozen holder cannot use it; others can.
      await viem.assertions.revertWithCustomError(
        vault.write.redeem([1n, NO_MIN, 0n], { account: bob.account }),
        faulty,
        "AccountBlocked",
      );
      await vault.write.redeem([INITIAL_SHARES / 10n, NO_MIN, 0n], { account: alice.account });

      await vault.write.activateLiquidation({ account: governance.account });
      await vault.write.convertToClaims([await vault.read.balanceOf([bob.account.address])], { account: bob.account });
      const pending = await vault.read.claimable([bob.account.address, 2n]);
      const [, , carolBefore] = await balancesOf(basket, carol.account.address);
      await vault.write.claim([2n, carol.account.address, 0n], { account: bob.account });
      const [, , carolAfter] = await balancesOf(basket, carol.account.address);
      assert.equal(carolAfter - carolBefore, pending);
    });

    it("a negative rebase during liquidation is shared pro rata, whoever claims first", async () => {
      const basket = await networkHelpers.loadFixture(holdersFixture);
      const { vault, faulty, governance, alice, bob } = basket;
      await vault.write.activateLiquidation({ account: governance.account });
      for (const holder of [alice, bob]) {
        await vault.write.convertToClaims([await vault.read.balanceOf([holder.account.address])], {
          account: holder.account,
        });
      }
      // The issuer removes tokens: before the fix, alice would have taken all that is left.
      const aliceRights = await vault.read.pendingRights([alice.account.address, 2n]);
      const bobRights = await vault.read.pendingRights([bob.account.address, 2n]);
      const balanceC = await faulty.read.balanceOf([vault.address]);
      const left = aliceRights + 1n;
      await faulty.write.slash([vault.address, balanceC - left]);
      assert.equal(await vault.read.componentSurplus([2n]), 0n);

      const [, , aliceBefore] = await balancesOf(basket, alice.account.address);
      const [, , bobBefore] = await balancesOf(basket, bob.account.address);
      await vault.write.claim([2n, alice.account.address, 0n], { account: alice.account });
      await vault.write.claim([2n, bob.account.address, 0n], { account: bob.account });
      const [, , aliceAfter] = await balancesOf(basket, alice.account.address);
      const [, , bobAfter] = await balancesOf(basket, bob.account.address);

      const aliceGot = aliceAfter - aliceBefore;
      const bobGot = bobAfter - bobBefore;
      assert.equal(aliceGot, (aliceRights * left) / balanceC);
      assert.ok(aliceGot + bobGot <= left, "paid more than the vault held");
      // Same fraction for both, up to one unit of rounding.
      const aliceFraction = (aliceGot * 10n ** 18n) / aliceRights;
      const bobFraction = (bobGot * 10n ** 18n) / bobRights;
      assert.ok(bobFraction >= aliceFraction - 10n ** 18n / bobRights, "bob got a smaller fraction");
      // The other components are unaffected.
      await vault.write.claim([0n, bob.account.address, 0n], { account: bob.account });
      await vault.write.claim([1n, bob.account.address, 0n], { account: bob.account });
    });
  });

  describe("maximum basket size", () => {
    it("reaches the maximum of 128 components and stays within the per-transaction gas limit", async () => {
      const [, governance, alice] = await viem.getWalletClients();
      const publicClient = await viem.getPublicClient();
      const tokens = [];
      for (let i = 0; i < 129; i++) {
        const token = await viem.deployContract("MockERC20", [`Mock ${i}`, `M${i}`, i % 2 === 0 ? 18 : 8]);
        await token.write.mint([alice.account.address, parseUnits("1000", 18)]);
        tokens.push(token);
      }
      const amounts = tokens.map((_, i) => (i % 2 === 0 ? parseUnits("1", 18) : parseUnits("0.01", 8)));
      // Half at deployment, the rest added through the 7-day announcement.
      const vault = await viem.deployContract("GRETVault", [
        tokens.slice(0, 64).map((token) => token.address),
        amounts.slice(0, 64),
        governance.account.address,
      ]);
      for (const token of tokens.slice(64)) {
        await vault.write.announceComponent([token.address], { account: governance.account });
      }
      await networkHelpers.time.increase(7n * 24n * 60n * 60n);
      for (const token of tokens.slice(64, 128)) await vault.write.addComponent([token.address]);
      assert.equal(await vault.read.componentCount(), 128n);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.addComponent([tokens[128].address]),
        vault,
        "InvalidComponentCount",
        [129n],
      );
      tokens.pop();
      // Every addition moved the basket to a new version.
      const version = await vault.read.basketVersion();
      assert.equal(version, 64n);
      await vault.write.setInitialAmounts([amounts.slice(0, 128), version], { account: governance.account });
      for (const token of tokens) {
        await token.write.approve([vault.address, maxUint256], { account: alice.account });
      }
      const max = tokens.map(() => maxUint256);
      const min = tokens.map(() => 0n);
      const gasOf = async (hash: `0x${string}`) => (await publicClient.waitForTransactionReceipt({ hash })).gasUsed;

      await vault.write.mint([INITIAL_SHARES, max, 0n, version], { account: alice.account });
      const mintGas = await gasOf(
        await vault.write.mint([INITIAL_SHARES, max, 0n, version], { account: alice.account }),
      );
      const redeemGas = await gasOf(
        await vault.write.redeem([INITIAL_SHARES / 2n, min, version], { account: alice.account }),
      );
      await vault.write.activateLiquidation({ account: governance.account });
      await vault.write.convertToClaims([INITIAL_SHARES], { account: alice.account });
      const claimGas = await gasOf(await vault.write.claim([127n, alice.account.address, 0n], { account: alice.account }));

      // Ethereum's per-transaction gas limit (EIP-7825) is 2^24 = 16,777,216.
      assert.equal(await vault.read.MAX_COMPONENTS(), 128n);
      assert.ok(mintGas < 8_000_000n, `mint gas ${mintGas}`);
      assert.ok(redeemGas < 8_000_000n, `redeem gas ${redeemGas}`);
      assert.ok(claimGas < 150_000n, `claim gas ${claimGas}`);
    });
  });
});
