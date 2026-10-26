import assert from "node:assert/strict";
import { after, describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, getAddress, zeroAddress } from "viem";

import {
  balancesOf,
  deployBasket,
  Fault,
  INITIAL_AMOUNTS,
  INITIAL_SHARES,
  mulDivDown,
  mulDivUp,
  NO_MAX,
  NO_MIN,
} from "./helpers/basket.js";

describe("GRETVault: basket, mint, normal redemption and sync", async () => {
  const connection = await network.create("hardhat");
  const { viem, networkHelpers } = connection;
  after(() => connection.close());

  async function basketFixture() {
    return deployBasket(viem);
  }

  async function bootstrappedFixture() {
    const basket = await deployBasket(viem);
    await basket.vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: basket.alice.account });
    return basket;
  }

  describe("configuration", () => {
    it("exposes the basket, GRET metadata and the governance, without a rebalancer", async () => {
      const { vault, tokens, governance } = await networkHelpers.loadFixture(basketFixture);

      assert.equal(await vault.read.name(), "Global Reserve Token");
      assert.equal(await vault.read.symbol(), "GRET");
      assert.equal(await vault.read.decimals(), 18);
      assert.equal(await vault.read.componentCount(), 3n);
      assert.deepEqual(
        await vault.read.components(),
        tokens.map((token) => getAddress(token.address)),
      );
      assert.deepEqual(await vault.read.initialAmounts(), INITIAL_AMOUNTS);
      assert.deepEqual(await vault.read.reserves(), [0n, 0n, 0n]);
      assert.equal(await vault.read.totalSupply(), 0n);
      assert.deepEqual(await vault.read.previewRedeem([0n]), [0n, 0n, 0n]);
      assert.equal(await vault.read.governance(), getAddress(governance.account.address));
      assert.equal(await vault.read.pendingGovernance(), zeroAddress);
      assert.equal(await vault.read.rebalancer(), zeroAddress);
      assert.equal(await vault.read.pendingRebalancer(), zeroAddress);
      assert.equal(await vault.read.liquidationActive(), false);
    });

    it("rejects invalid basket configurations", async () => {
      const { vault, tokens, governance, alice } = await networkHelpers.loadFixture(basketFixture);
      const [a, b, c] = tokens.map((token) => token.address);
      const admin = governance.account.address;
      const deploy = (components: `0x${string}`[], amounts: bigint[], emergency = admin) => () =>
        viem.deployContract("GRETVault", [components, amounts, emergency]);
      const cases = [
        { deployment: deploy([], []), error: "InvalidComponentCount", errorArgs: [0n] },
        {
          deployment: deploy(Array(129).fill(a), Array(129).fill(1n)),
          error: "InvalidComponentCount",
          errorArgs: [129n],
        },
        { deployment: deploy([a, b, c], [1n, 1n]), error: "LengthMismatch", errorArgs: [3n, 2n] },
        { deployment: deploy([a, b, c], [1n, 1n, 1n], zeroAddress), error: "ZeroAddress", errorArgs: [] },
        {
          deployment: deploy([a, alice.account.address], [1n, 1n]),
          error: "NotAContract",
          errorArgs: [getAddress(alice.account.address)],
        },
        { deployment: deploy([a, b, a], [1n, 1n, 1n]), error: "DuplicateComponent", errorArgs: [getAddress(a)] },
        { deployment: deploy([a, b, c], [1n, 0n, 1n]), error: "ZeroInitialAmount", errorArgs: [1n] },
      ] as const;

      for (const { deployment, error, errorArgs } of cases) {
        await viem.assertions.revertWithCustomErrorWithArgs(
          deployment() as unknown as Promise<`0x${string}`>,
          vault,
          error,
          errorArgs as never,
        );
      }
    });
  });

  describe("bootstrap", () => {
    it("the first mint contributes exactly the initial basket and issues 1 GRET", async () => {
      const basket = await networkHelpers.loadFixture(basketFixture);
      const { vault, alice } = basket;
      const aliceBefore = await balancesOf(basket, alice.account.address);

      await viem.assertions.emitWithArgs(
        vault.write.mint([INITIAL_SHARES, INITIAL_AMOUNTS, 0n, 0n], { account: alice.account }),
        vault,
        "Minted",
        [getAddress(alice.account.address), INITIAL_SHARES, INITIAL_AMOUNTS],
      );

      const aliceAfter = await balancesOf(basket, alice.account.address);
      assert.deepEqual(aliceBefore.map((balance, i) => balance - aliceAfter[i]), INITIAL_AMOUNTS);
      assert.deepEqual(await balancesOf(basket, vault.address), INITIAL_AMOUNTS);
      assert.deepEqual(await vault.read.reserves(), INITIAL_AMOUNTS);
      assert.equal(await vault.read.totalSupply(), INITIAL_SHARES);
      assert.equal(await vault.read.balanceOf([alice.account.address]), INITIAL_SHARES);
      assert.equal(await vault.read.hasMinted([alice.account.address]), true);
    });

    it("the first mint must issue exactly 1 GRET", async () => {
      const { vault, alice } = await networkHelpers.loadFixture(basketFixture);

      for (const shares of [1n, INITIAL_SHARES - 1n, 2n * INITIAL_SHARES]) {
        await viem.assertions.revertWithCustomErrorWithArgs(
          vault.write.mint([shares, NO_MAX, 0n, 0n], { account: alice.account }),
          vault,
          "InvalidInitialMint",
          [shares],
        );
      }
      assert.equal(await vault.read.totalSupply(), 0n);
    });
  });

  describe("proportional mint", () => {
    it("is proportional to reserves and rounds contributions up", async () => {
      const basket = await networkHelpers.loadFixture(bootstrappedFixture);
      const { vault, bob } = basket;
      const shares = INITIAL_SHARES / 3n;
      const expected = INITIAL_AMOUNTS.map((reserve) => mulDivUp(shares, reserve, INITIAL_SHARES));
      // 0.001 BTC-like units: 100_000 / 3 rounds up from 33_333.33 to 33_334.
      assert.equal(expected[1], 33_334n);
      assert.deepEqual(await vault.read.previewMint([shares]), expected);

      const bobBefore = await balancesOf(basket, bob.account.address);
      await vault.write.mint([shares, expected, 0n, 0n], { account: bob.account });
      const bobAfter = await balancesOf(basket, bob.account.address);

      assert.deepEqual(bobBefore.map((balance, i) => balance - bobAfter[i]), expected);
      assert.deepEqual(
        await vault.read.reserves(),
        INITIAL_AMOUNTS.map((reserve, i) => reserve + expected[i]),
      );
      assert.equal(await vault.read.balanceOf([bob.account.address]), shares);
      assert.equal(await vault.read.hasMinted([bob.account.address]), true);
    });

    it("a mint of 1 wei of GRET still contributes every component and enables redemption", async () => {
      const basket = await networkHelpers.loadFixture(bootstrappedFixture);
      const { vault, bob } = basket;
      const bobBefore = await balancesOf(basket, bob.account.address);

      await vault.write.mint([1n, NO_MAX, 0n, 0n], { account: bob.account });

      const bobAfter = await balancesOf(basket, bob.account.address);
      // ceil(1 * reserve / 1e18): at least one base unit of each component, never zero.
      assert.deepEqual(bobBefore.map((balance, i) => balance - bobAfter[i]), [2n, 1n, 5n]);
      assert.equal(await vault.read.hasMinted([bob.account.address]), true);
    });

    it("rejects zero shares, wrong array lengths and contributions above maxAmountsIn", async () => {
      const { vault, bob } = await networkHelpers.loadFixture(bootstrappedFixture);
      const shares = INITIAL_SHARES / 2n;
      const expected = INITIAL_AMOUNTS.map((reserve) => reserve / 2n);

      await viem.assertions.revertWithCustomError(
        vault.write.mint([0n, NO_MAX, 0n, 0n], { account: bob.account }),
        vault,
        "ZeroShares",
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.mint([shares, NO_MAX.slice(0, 2), 0n, 0n], { account: bob.account }),
        vault,
        "LengthMismatch",
        [3n, 2n],
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.mint([shares, [expected[0], expected[1] - 1n, expected[2]], 0n, 0n], { account: bob.account }),
        vault,
        "AmountInAboveMax",
        [1n, expected[1], expected[1] - 1n],
      );
      assert.equal(await vault.read.hasMinted([bob.account.address]), false);
    });

    it("rejects a component that charges a transfer fee", async () => {
      const { vault, faulty, bob } = await networkHelpers.loadFixture(bootstrappedFixture);
      await faulty.write.setFault([Fault.FeeOnTransfer]);
      const amount = INITIAL_AMOUNTS[2];
      const fee = (amount * (await faulty.read.FEE_BPS())) / 10_000n;

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: bob.account }),
        vault,
        "UnexpectedBalance",
        [2n, amount, amount - fee],
      );
      assert.equal(await vault.read.totalSupply(), INITIAL_SHARES);
    });

    it("accepts a few units short, like xStocks, and issues GRET only for what arrived", async () => {
      const basket = await networkHelpers.loadFixture(bootstrappedFixture);
      const { vault, faulty, bob } = basket;
      await faulty.write.setFault([Fault.ShortByOneOnTransfer]);
      const shares = INITIAL_SHARES / 3n;
      const amounts = INITIAL_AMOUNTS.map((reserve) => mulDivUp(shares, reserve, INITIAL_SHARES));
      const received = [amounts[0], amounts[1], amounts[2] - 1n];
      const minted = mulDivDown(received[2], INITIAL_SHARES, INITIAL_AMOUNTS[2]);
      assert.ok(minted < shares && shares - minted < 10n);

      await viem.assertions.emitWithArgs(
        vault.write.mint([shares, NO_MAX, 0n, 0n], { account: bob.account }),
        vault,
        "Minted",
        [getAddress(bob.account.address), minted, received],
      );
      const reserves = await vault.read.reserves();
      assert.deepEqual(reserves, INITIAL_AMOUNTS.map((reserve, i) => reserve + received[i]));
      assert.deepEqual(await balancesOf(basket, vault.address), reserves);
      // Existing holders never lose: the amount behind each GRET does not go down.
      const supply = await vault.read.totalSupply();
      for (const [i, reserve] of reserves.entries()) {
        assert.ok(reserve * INITIAL_SHARES >= INITIAL_AMOUNTS[i] * supply, `component ${i}`);
      }
    });

    it("issues nothing, and reverts, when what arrived is worth less than 1 wei of GRET", async () => {
      const { vault, faulty, bob } = await networkHelpers.loadFixture(bootstrappedFixture);
      await faulty.write.setFault([Fault.ShortByOneOnTransfer]);

      // 1 wei of GRET needs 5 units of C; 4 arrive, which is worth 0.8 wei.
      await viem.assertions.revertWithCustomError(
        vault.write.mint([1n, NO_MAX, 0n, 0n], { account: bob.account }),
        vault,
        "ZeroShares",
      );
      assert.equal(await vault.read.hasMinted([bob.account.address]), false);
    });

    it("blocks reentrancy from a component during mint", async () => {
      const { vault, faulty, alice } = await networkHelpers.loadFixture(bootstrappedFixture);
      await faulty.write.setReentry([
        vault.address,
        encodeFunctionData({ abi: vault.abi, functionName: "redeem", args: [1n, NO_MIN, 0n] }),
      ]);

      await viem.assertions.revertWithCustomError(
        vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account }),
        vault,
        "ReentrancyGuardReentrantCall",
      );
    });
  });

  describe("normal redemption", () => {
    it("returns the proportional amount of every component and rounds down", async () => {
      const basket = await networkHelpers.loadFixture(bootstrappedFixture);
      const { vault, alice, bob } = basket;
      await vault.write.mint([INITIAL_SHARES / 3n, NO_MAX, 0n, 0n], { account: bob.account });

      const supply = await vault.read.totalSupply();
      const reserves = await vault.read.reserves();
      const shares = INITIAL_SHARES / 4n;
      const expected = reserves.map((reserve) => mulDivDown(shares, reserve, supply));
      const aliceBefore = await balancesOf(basket, alice.account.address);

      await viem.assertions.emitWithArgs(
        vault.write.redeem([shares, expected, 0n], { account: alice.account }),
        vault,
        "Redeemed",
        [getAddress(alice.account.address), shares, expected],
      );

      const aliceAfter = await balancesOf(basket, alice.account.address);
      assert.deepEqual(aliceAfter.map((balance, i) => balance - aliceBefore[i]), expected);
      assert.deepEqual(
        await vault.read.reserves(),
        reserves.map((reserve, i) => reserve - expected[i]),
      );
      assert.equal(await vault.read.totalSupply(), supply - shares);
      assert.equal(await vault.read.balanceOf([alice.account.address]), INITIAL_SHARES - shares);
    });

    it("is only available to wallets that minted, even when they hold GRET", async () => {
      const { vault, alice, dave } = await networkHelpers.loadFixture(bootstrappedFixture);
      await vault.write.transfer([dave.account.address, INITIAL_SHARES / 4n], { account: alice.account });

      assert.equal(await vault.read.hasMinted([dave.account.address]), false);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.redeem([INITIAL_SHARES / 4n, NO_MIN, 0n], { account: dave.account }),
        vault,
        "RedemptionNotEnabled",
        [getAddress(dave.account.address)],
      );
    });

    it("lets a wallet that minted redeem GRET acquired later", async () => {
      const { vault, alice, bob } = await networkHelpers.loadFixture(bootstrappedFixture);
      await vault.write.mint([2n * INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
      await vault.write.mint([1n, NO_MAX, 0n, 0n], { account: bob.account });
      await vault.write.transfer([bob.account.address, INITIAL_SHARES / 2n], { account: alice.account });

      await vault.write.redeem([INITIAL_SHARES / 2n + 1n, NO_MIN, 0n], { account: bob.account });

      assert.equal(await vault.read.balanceOf([bob.account.address]), 0n);
      assert.equal(await vault.read.hasMinted([bob.account.address]), true);
    });

    it("is atomic: a failing component reverts the whole redemption", async () => {
      const basket = await networkHelpers.loadFixture(bootstrappedFixture);
      const { vault, faulty, alice, bob } = basket;
      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: bob.account });
      const shares = INITIAL_SHARES / 2n;
      const aliceBefore = await balancesOf(basket, alice.account.address);
      const reservesBefore = await vault.read.reserves();

      await faulty.write.setFault([Fault.RevertOnTransfer]);
      await viem.assertions.revertWithCustomError(
        vault.write.redeem([shares, NO_MIN, 0n], { account: alice.account }),
        faulty,
        "TransfersBlocked",
      );

      await faulty.write.setFault([Fault.ReturnFalseOnTransfer]);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.redeem([shares, NO_MIN, 0n], { account: alice.account }),
        vault,
        "SafeERC20FailedOperation",
        [getAddress(faulty.address)],
      );

      assert.deepEqual(await balancesOf(basket, alice.account.address), aliceBefore);
      assert.equal(await vault.read.balanceOf([alice.account.address]), INITIAL_SHARES);
      assert.deepEqual(await vault.read.reserves(), reservesBefore);

      await faulty.write.setFault([Fault.None]);
      await vault.write.redeem([shares, NO_MIN, 0n], { account: alice.account });
      assert.equal(await vault.read.balanceOf([alice.account.address]), INITIAL_SHARES - shares);
    });

    it("governance pauses and resumes minting at once; redemption is never paused", async () => {
      const { vault, faulty, governance, alice, bob } = await networkHelpers.loadFixture(bootstrappedFixture);
      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: bob.account });
      assert.equal(await vault.read.mintPaused(), false);
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.setMintPaused([true], { account: alice.account }),
        vault,
        "NotGovernance",
        [getAddress(alice.account.address)],
      );

      await viem.assertions.emitWithArgs(
        vault.write.setMintPaused([true], { account: governance.account }),
        vault,
        "MintPauseChanged",
        [true],
      );
      await viem.assertions.revertWithCustomError(
        vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: bob.account }),
        vault,
        "MintIsPaused",
      );
      // Holders still leave, normally or skipping a component.
      await vault.write.redeem([INITIAL_SHARES / 4n, NO_MIN, 0n], { account: alice.account });
      await vault.write.redeemSkipping([INITIAL_SHARES / 4n, NO_MIN, [faulty.address], 0n], { account: alice.account });

      await vault.write.setMintPaused([false], { account: governance.account });
      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: bob.account });
      assert.equal(await vault.read.balanceOf([bob.account.address]), 2n * INITIAL_SHARES);
    });

    it("redeemSkipping leaves out a component that cannot be sent; that share stays with the others", async () => {
      const basket = await networkHelpers.loadFixture(bootstrappedFixture);
      const { vault, faulty, alice, bob } = basket;
      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: bob.account });
      await faulty.write.setBlocked([vault.address, true]);
      await assert.rejects(vault.write.redeem([INITIAL_SHARES, NO_MIN, 0n], { account: alice.account }));

      const reserves = await vault.read.reserves();
      const aliceBefore = await balancesOf(basket, alice.account.address);
      await viem.assertions.emitWithArgs(
        vault.write.redeemSkipping([INITIAL_SHARES, NO_MIN, [faulty.address], 0n], { account: alice.account }),
        vault,
        "Redeemed",
        [getAddress(alice.account.address), INITIAL_SHARES, [reserves[0] / 2n, reserves[1] / 2n, 0n]],
      );
      const aliceAfter = await balancesOf(basket, alice.account.address);
      assert.deepEqual(aliceAfter.map((balance, i) => balance - aliceBefore[i]), [reserves[0] / 2n, reserves[1] / 2n, 0n]);
      assert.equal(await vault.read.balanceOf([alice.account.address]), 0n);

      // Bob now owns the whole reserve of the frozen component, including Alice's half.
      assert.deepEqual(await vault.read.reserves(), [reserves[0] / 2n, reserves[1] / 2n, reserves[2]]);
      assert.deepEqual(await vault.read.previewRedeem([INITIAL_SHARES]), [reserves[0] / 2n, reserves[1] / 2n, reserves[2]]);
    });

    it("redeemSkipping by the last holder turns the skipped share into surplus", async () => {
      const basket = await networkHelpers.loadFixture(bootstrappedFixture);
      const { vault, faulty, alice } = basket;
      await faulty.write.setFault([Fault.RevertOnTransfer]);
      await vault.write.redeemSkipping([INITIAL_SHARES, NO_MIN, [faulty.address], 0n], { account: alice.account });

      assert.equal(await vault.read.totalSupply(), 0n);
      assert.deepEqual(await vault.read.reserves(), [0n, 0n, 0n]);
      assert.equal(await vault.read.componentSurplus([2n]), INITIAL_AMOUNTS[2]);
    });

    it("redeemSkipping checks the skipped list, the minima and who may redeem", async () => {
      const { vault, tokens, faulty, alice, carol } = await networkHelpers.loadFixture(bootstrappedFixture);
      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.redeemSkipping([INITIAL_SHARES, NO_MIN, [carol.account.address], 0n], { account: alice.account }),
        vault,
        "NotAComponent",
        [getAddress(carol.account.address)],
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.redeemSkipping([INITIAL_SHARES, [0n, 0n, 1n], [faulty.address], 0n], { account: alice.account }),
        vault,
        "AmountOutBelowMin",
        [2n, 0n, 1n],
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.redeemSkipping([INITIAL_SHARES, NO_MIN, [faulty.address], 0n], { account: carol.account }),
        vault,
        "RedemptionNotEnabled",
        [getAddress(carol.account.address)],
      );
      // Skipping nothing, or the same token twice, works like a plain redemption without it.
      await vault.write.redeemSkipping([INITIAL_SHARES / 2n, NO_MIN, [], 0n], { account: alice.account });
      await vault.write.redeemSkipping([INITIAL_SHARES / 2n, NO_MIN, [tokens[0].address, tokens[0].address], 0n], {
        account: alice.account,
      });
      assert.equal(await vault.read.balanceOf([alice.account.address]), INITIAL_SHARES);
    });

    it("enforces minAmountsOut, the caller's balance and the supply", async () => {
      const { vault, alice, bob } = await networkHelpers.loadFixture(bootstrappedFixture);
      await vault.write.mint([3n * INITIAL_SHARES, NO_MAX, 0n, 0n], { account: bob.account });
      const expected = INITIAL_AMOUNTS.map((amount) => amount / 2n);

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.redeem([INITIAL_SHARES / 2n, [expected[0] + 1n, 0n, 0n], 0n], { account: alice.account }),
        vault,
        "AmountOutBelowMin",
        [0n, expected[0], expected[0] + 1n],
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.redeem([INITIAL_SHARES + 1n, NO_MIN, 0n], { account: alice.account }),
        vault,
        "ERC20InsufficientBalance",
        [getAddress(alice.account.address), INITIAL_SHARES, INITIAL_SHARES + 1n],
      );
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.redeem([5n * INITIAL_SHARES, NO_MIN, 0n], { account: alice.account }),
        vault,
        "SharesExceedSupply",
        [5n * INITIAL_SHARES, 4n * INITIAL_SHARES],
      );
      await viem.assertions.revertWithCustomError(
        vault.write.redeem([0n, NO_MIN, 0n], { account: alice.account }),
        vault,
        "ZeroShares",
      );
    });

    it("cannot leave the supply between zero and 1 GRET, which stops the rounding-dust attack", async () => {
      const { vault, alice, bob } = await networkHelpers.loadFixture(bootstrappedFixture);

      // Right after the first mint, redeeming all but 1 wei would leave dust ruling the basket.
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.redeem([INITIAL_SHARES - 1n, NO_MIN, 0n], { account: alice.account }),
        vault,
        "SupplyBelowMinimum",
        [1n],
      );

      await vault.write.mint([INITIAL_SHARES / 2n, NO_MAX, 0n, 0n], { account: bob.account });
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.redeem([(INITIAL_SHARES * 6n) / 10n, NO_MIN, 0n], { account: alice.account }),
        vault,
        "SupplyBelowMinimum",
        [(INITIAL_SHARES * 9n) / 10n],
      );
      await vault.write.redeem([INITIAL_SHARES / 2n, NO_MIN, 0n], { account: alice.account });
      assert.equal(await vault.read.totalSupply(), INITIAL_SHARES);

      // The last holders exit together: GRET gathered in one wallet can go to zero.
      await vault.write.transfer([alice.account.address, INITIAL_SHARES / 2n], { account: bob.account });
      await vault.write.redeem([INITIAL_SHARES, NO_MIN, 0n], { account: alice.account });
      assert.equal(await vault.read.totalSupply(), 0n);
      assert.deepEqual(await vault.read.reserves(), [0n, 0n, 0n]);
    });

    it("a full redemption empties the reserves and the next mint restarts from the initial basket", async () => {
      const basket = await networkHelpers.loadFixture(bootstrappedFixture);
      const { vault, alice, carol } = basket;
      const aliceBefore = await balancesOf(basket, alice.account.address);

      await vault.write.redeem([INITIAL_SHARES, INITIAL_AMOUNTS, 0n], { account: alice.account });

      const aliceAfter = await balancesOf(basket, alice.account.address);
      assert.deepEqual(aliceAfter.map((balance, i) => balance - aliceBefore[i]), INITIAL_AMOUNTS);
      assert.deepEqual(await vault.read.reserves(), [0n, 0n, 0n]);
      assert.deepEqual(await balancesOf(basket, vault.address), [0n, 0n, 0n]);
      assert.equal(await vault.read.totalSupply(), 0n);

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.mint([2n * INITIAL_SHARES, NO_MAX, 0n, 0n], { account: carol.account }),
        vault,
        "InvalidInitialMint",
        [2n * INITIAL_SHARES],
      );
      await vault.write.mint([INITIAL_SHARES, INITIAL_AMOUNTS, 0n, 0n], { account: carol.account });
      assert.deepEqual(await vault.read.reserves(), INITIAL_AMOUNTS);
    });

    it("a mint followed by a redemption never returns more than was contributed", async () => {
      const basket = await networkHelpers.loadFixture(bootstrappedFixture);
      const { vault, bob } = basket;

      for (const shares of [1n, 7n, 10n ** 9n + 1n, INITIAL_SHARES / 3n, 5n * INITIAL_SHARES + 11n]) {
        const before = await balancesOf(basket, bob.account.address);
        await vault.write.mint([shares, NO_MAX, 0n, 0n], { account: bob.account });
        await vault.write.redeem([shares, NO_MIN, 0n], { account: bob.account });
        const after = await balancesOf(basket, bob.account.address);

        for (const [i, balance] of after.entries()) {
          assert.ok(balance <= before[i], `component ${i} gained on a roundtrip of ${shares}`);
        }
      }
    });
  });

  describe("losses", () => {
    it("recognizing a loss lowers the reserve to the balance and shares it among all holders", async () => {
      const { vault, faulty, alice, carol } = await networkHelpers.loadFixture(bootstrappedFixture);
      const loss = INITIAL_AMOUNTS[2] / 5n;
      await faulty.write.slash([vault.address, loss]);
      assert.deepEqual(await vault.read.previewRedeem([INITIAL_SHARES]), INITIAL_AMOUNTS);

      // Anyone may record it; carol holds no GRET.
      await viem.assertions.emitWithArgs(
        vault.write.recognizeLoss([2n], { account: carol.account }),
        vault,
        "LossRecognized",
        [2n, loss, INITIAL_AMOUNTS[2] - loss],
      );
      assert.equal((await vault.read.reserves())[2], INITIAL_AMOUNTS[2] - loss);
      assert.deepEqual(await vault.read.previewRedeem([INITIAL_SHARES]), [
        INITIAL_AMOUNTS[0],
        INITIAL_AMOUNTS[1],
        INITIAL_AMOUNTS[2] - loss,
      ]);
      const { result } = await vault.simulate.recognizeLoss([2n], { account: alice.account.address });
      assert.equal(result, 0n);
    });

    it("mint and redemption recognize losses by themselves before computing amounts", async () => {
      const basket = await networkHelpers.loadFixture(bootstrappedFixture);
      const { vault, faulty, alice, bob } = basket;
      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: bob.account });
      const reserveC = INITIAL_AMOUNTS[2] * 2n;

      // The new minter does not pay for the loss.
      await faulty.write.slash([vault.address, reserveC / 4n]);
      const [, , bobCBefore] = await balancesOf(basket, bob.account.address);
      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: bob.account });
      const [, , bobCAfter] = await balancesOf(basket, bob.account.address);
      assert.equal(bobCBefore - bobCAfter, mulDivUp(INITIAL_SHARES, reserveC - reserveC / 4n, 2n * INITIAL_SHARES));

      // The redeemer receives a proportional part of what is really there.
      await faulty.write.slash([vault.address, INITIAL_AMOUNTS[2]]);
      const reserveAfterLoss = (await faulty.read.balanceOf([vault.address]));
      const supply = await vault.read.totalSupply();
      const [, , aliceCBefore] = await balancesOf(basket, alice.account.address);
      await vault.write.redeem([INITIAL_SHARES, NO_MIN, 0n], { account: alice.account });
      const [, , aliceCAfter] = await balancesOf(basket, alice.account.address);
      assert.equal(aliceCAfter - aliceCBefore, mulDivDown(INITIAL_SHARES, reserveAfterLoss, supply));
      assert.deepEqual(await balancesOf(basket, vault.address), await vault.read.reserves());
    });

    it("after a total loss of one component, mint and redemption continue without it", async () => {
      const basket = await networkHelpers.loadFixture(bootstrappedFixture);
      const { vault, faulty, alice, bob } = basket;
      await faulty.write.slash([vault.address, INITIAL_AMOUNTS[2]]);
      await vault.write.recognizeLoss([2n]);

      // Mint no longer asks for the lost component, so a new holder can still enter and exit.
      assert.deepEqual(await vault.read.previewMint([INITIAL_SHARES]), [INITIAL_AMOUNTS[0], INITIAL_AMOUNTS[1], 0n]);
      const bobBefore = await balancesOf(basket, bob.account.address);
      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: bob.account });
      const bobAfter = await balancesOf(basket, bob.account.address);
      assert.deepEqual(bobBefore.map((balance, i) => balance - bobAfter[i]), [
        INITIAL_AMOUNTS[0],
        INITIAL_AMOUNTS[1],
        0n,
      ]);
      await vault.write.redeem([INITIAL_SHARES, NO_MIN, 0n], { account: bob.account });
      assert.deepEqual(await balancesOf(basket, bob.account.address), bobBefore);

      const aliceBefore = await balancesOf(basket, alice.account.address);
      await vault.write.redeem([INITIAL_SHARES, NO_MIN, 0n], { account: alice.account });
      const aliceAfter = await balancesOf(basket, alice.account.address);
      assert.deepEqual(aliceAfter.map((balance, i) => balance - aliceBefore[i]), [
        INITIAL_AMOUNTS[0],
        INITIAL_AMOUNTS[1],
        0n,
      ]);
    });
  });

  describe("sync", () => {
    it("recognizes donations only after governance syncs them, for every holder", async () => {
      const { vault, tokens, governance } = await networkHelpers.loadFixture(bootstrappedFixture);
      const donation = INITIAL_AMOUNTS[0] / 2n;
      await tokens[0].write.mint([vault.address, donation]);

      assert.deepEqual(await vault.read.reserves(), INITIAL_AMOUNTS);
      assert.deepEqual(await vault.read.previewRedeem([INITIAL_SHARES]), INITIAL_AMOUNTS);

      await viem.assertions.emitWithArgs(
        vault.write.sync([tokens[0].address], { account: governance.account }),
        vault,
        "Synced",
        [getAddress(tokens[0].address), donation, INITIAL_AMOUNTS[0] + donation],
      );
      assert.deepEqual(await vault.read.previewRedeem([INITIAL_SHARES]), [
        INITIAL_AMOUNTS[0] + donation,
        INITIAL_AMOUNTS[1],
        INITIAL_AMOUNTS[2],
      ]);
      assert.deepEqual(await vault.read.previewMint([INITIAL_SHARES]), [
        INITIAL_AMOUNTS[0] + donation,
        INITIAL_AMOUNTS[1],
        INITIAL_AMOUNTS[2],
      ]);
    });

    it("only governance can sync", async () => {
      const { vault, tokens, alice } = await networkHelpers.loadFixture(bootstrappedFixture);
      await tokens[0].write.mint([vault.address, 1n]);

      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.sync([tokens[0].address], { account: alice.account }),
        vault,
        "NotGovernance",
        [getAddress(alice.account.address)],
      );
      assert.deepEqual(await vault.read.reserves(), INITIAL_AMOUNTS);
    });

    it("is a no-op without surplus", async () => {
      const { vault, tokens, governance } = await networkHelpers.loadFixture(bootstrappedFixture);

      const { result } = await vault.simulate.sync([tokens[1].address], { account: governance.account.address });
      assert.equal(result, 0n);
      await vault.write.sync([tokens[1].address], { account: governance.account });
      assert.deepEqual(await vault.read.reserves(), INITIAL_AMOUNTS);
    });

    it("a failing component does not block sync of the others", async () => {
      const { vault, tokens, faulty, governance } = await networkHelpers.loadFixture(bootstrappedFixture);
      await faulty.write.setFault([Fault.RevertOnBalanceOf]);
      await tokens[1].write.mint([vault.address, 10n]);

      await viem.assertions.revertWithCustomError(
        vault.write.sync([faulty.address], { account: governance.account }),
        faulty,
        "BalanceOfBlocked",
      );
      await vault.write.sync([tokens[1].address], { account: governance.account });
      assert.equal((await vault.read.reserves())[1], INITIAL_AMOUNTS[1] + 10n);
    });

    it("requires a positive supply and a component of the basket", async () => {
      const { vault, tokens, governance, alice } = await networkHelpers.loadFixture(basketFixture);
      await tokens[0].write.mint([vault.address, 1n]);

      await viem.assertions.revertWithCustomError(
        vault.write.sync([tokens[0].address], { account: governance.account }),
        vault,
        "NoSupply",
      );

      await vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: alice.account });
      await viem.assertions.revertWithCustomErrorWithArgs(
        vault.write.sync([alice.account.address], { account: governance.account }),
        vault,
        "NotAComponent",
        [getAddress(alice.account.address)],
      );
    });
  });
});
