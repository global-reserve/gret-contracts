import assert from "node:assert/strict";
import { after, describe, it } from "node:test";

import { network } from "hardhat";

import {
  balancesOf,
  type Basket,
  deployBasket,
  Fault,
  INITIAL_AMOUNTS,
  INITIAL_SHARES,
  mulDivDown,
  mulDivUp,
  NO_MAX,
  NO_MIN,
} from "./helpers/basket.js";

const SEEDS = [1, 7, 42];
const NORMAL_STEPS = 40;
const LIQUIDATION_STEPS = 40;

/** Deterministic PRNG (mulberry32) so that failures are reproducible from the seed. */
function createRandom(seed: number) {
  let state = seed >>> 0;
  const next = () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const int = (n: number) => Math.floor(next() * n);
  return {
    int,
    pick: <T>(items: readonly T[]): T => items[int(items.length)],
    /** Between 1 and 10^18, with magnitudes spread evenly so that dust amounts appear often. */
    amount: () => 1n + (BigInt(int(1_000_000_000)) * 10n ** BigInt(int(19))) / 1_000_000_000n,
    /** A positive part of `total`, the whole of it a quarter of the time. */
    portion: (total: bigint) =>
      int(4) === 0 ? total : 1n + (total * BigInt(int(1_000_000))) / 1_000_000n,
  };
}

describe("GRETVault: randomized sequences", async () => {
  const connection = await network.create("hardhat");
  const { viem, networkHelpers } = connection;
  after(() => connection.close());

  async function basketFixture() {
    return deployBasket(viem);
  }

  async function snapshot(basket: Basket) {
    const { vault, users } = basket;
    return {
      supply: await vault.read.totalSupply(),
      reserves: await vault.read.reserves(),
      vaultBalances: await balancesOf(basket, vault.address),
      holdings: await Promise.all(users.map((user) => vault.read.balanceOf([user.account.address]))),
    };
  }

  async function assertNormalInvariants(basket: Basket, previous: Awaited<ReturnType<typeof snapshot>>) {
    const current = await snapshot(basket);
    assert.equal(current.holdings.reduce((sum, balance) => sum + balance, 0n), current.supply);

    for (const [i, reserve] of current.reserves.entries()) {
      // Every surplus is synced right away in these sequences, so balances match reserves exactly.
      assert.equal(current.vaultBalances[i], reserve, `component ${i} balance`);
      assert.equal(reserve > 0n, current.supply > 0n, `component ${i} reserve vs supply`);
      // Rounding favors holders: the amount behind each GRET never decreases.
      if (previous.supply > 0n && current.supply > 0n) {
        assert.ok(
          reserve * previous.supply >= previous.reserves[i] * current.supply,
          `component ${i} value per share decreased`,
        );
      }
    }
    return current;
  }

  for (const seed of SEEDS) {
    it(`seed ${seed}: mint, redeem, transfer and sync keep reserves consistent, then liquidation pays each right once`, async () => {
      const basket = await networkHelpers.loadFixture(basketFixture);
      const { vault, tokens, faulty, deployer, governance, alice, bob, carol, dave, users } = basket;
      const random = createRandom(seed);
      const minters = [alice, bob, carol];
      let state = await snapshot(basket);

      for (let step = 0; step < NORMAL_STEPS; step++) {
        const roll = random.int(100);

        if (state.supply === 0n) {
          const user = random.pick(minters);
          await vault.write.mint([INITIAL_SHARES, INITIAL_AMOUNTS, 0n, 0n], { account: user.account });
        } else if (roll < 35) {
          const user = random.pick(minters);
          const shares = random.amount();
          const expected = state.reserves.map((reserve) => mulDivUp(shares, reserve, state.supply));
          // A tiny supply makes each wei of GRET expensive; top up so the mint is always affordable.
          for (const [i, token] of tokens.entries()) {
            await token.write.mint([user.account.address, expected[i]]);
          }
          const before = await balancesOf(basket, user.account.address);
          await vault.write.mint([shares, expected, 0n, 0n], { account: user.account });
          const after = await balancesOf(basket, user.account.address);
          assert.deepEqual(before.map((balance, i) => balance - after[i]), expected);
        } else if (roll < 65) {
          const eligible = [];
          for (const [index, user] of users.entries()) {
            if (state.holdings[index] > 0n && (await vault.read.hasMinted([user.account.address]))) {
              eligible.push({ user, balance: state.holdings[index] });
            }
          }
          if (eligible.length === 0) continue;
          const { user, balance } = random.pick(eligible);
          const shares = random.portion(balance);
          const remaining = state.supply - shares;
          if (remaining !== 0n && remaining < INITIAL_SHARES) {
            await viem.assertions.revertWithCustomErrorWithArgs(
              vault.write.redeem([shares, NO_MIN, 0n], { account: user.account }),
              vault,
              "SupplyBelowMinimum",
              [remaining],
            );
            continue;
          }
          const expected = state.reserves.map((reserve) => mulDivDown(shares, reserve, state.supply));
          const before = await balancesOf(basket, user.account.address);
          await vault.write.redeem([shares, expected, 0n], { account: user.account });
          const after = await balancesOf(basket, user.account.address);
          assert.deepEqual(after.map((balance, i) => balance - before[i]), expected);
        } else if (roll < 85) {
          const holders = users.filter((_, index) => state.holdings[index] > 0n);
          const from = random.pick(holders);
          const balance = state.holdings[users.indexOf(from)];
          // dave never mints, so GRET that reaches him can only leave by transfer or liquidation.
          await vault.write.transfer([random.pick(users).account.address, random.portion(balance)], {
            account: from.account,
          });
        } else {
          // Governance either adds the surplus to the reserves or rescues it; never more than it.
          const index = random.int(tokens.length);
          const donation = random.amount();
          await tokens[index].write.mint([vault.address, donation]);
          assert.equal(await vault.read.componentSurplus([BigInt(index)]), donation);
          if (random.int(2) === 0) {
            await vault.write.sync([tokens[index].address], { account: governance.account });
          } else {
            await viem.assertions.revertWithCustomError(
              vault.write.rescue([tokens[index].address, deployer.account.address, donation + 1n], {
                account: governance.account,
              }),
              vault,
              "RescueExceedsSurplus",
            );
            await vault.write.rescue([tokens[index].address, deployer.account.address, donation], {
              account: governance.account,
            });
          }
        }

        state = await assertNormalInvariants(basket, state);
      }

      // Liquidation starts while component C is blocked; it is unblocked halfway through.
      await faulty.write.setFault([Fault.RevertOnTransfer]);
      await vault.write.activateLiquidation({ account: governance.account });
      const liquidationSupply = await vault.read.liquidationSupply();
      const frozenReserves = await vault.read.reserves();
      const balancesAtActivation = await balancesOf(basket, vault.address);
      assert.equal(liquidationSupply, state.supply);
      assert.deepEqual(frozenReserves, state.reserves);

      // A sync during liquidation raises the reserves, and with them every entitlement.
      const syncedInLiquidation = tokens.map(() => 0n);
      const entitlement = async (account: `0x${string}`, index: number) => {
        const shares = await vault.read.claimShares([account]);
        const reserve = (await vault.read.reserves())[index];
        return shares === 0n ? 0n : mulDivDown(shares, reserve, liquidationSupply);
      };

      const claimOnce = async (user: (typeof users)[number], index: number) => {
        const account = user.account.address;
        const pending = await vault.read.claimable([account, BigInt(index)]);
        assert.equal(
          pending,
          (await entitlement(account, index)) - (await vault.read.claimed([account, BigInt(index)])),
        );

        if (pending === 0n) {
          await viem.assertions.revertWithCustomError(
            vault.write.claim([BigInt(index), account, 0n], { account: user.account }),
            vault,
            "NothingToClaim",
          );
        } else if (index === 2 && (await faulty.read.fault()) === Fault.RevertOnTransfer) {
          await viem.assertions.revertWithCustomError(
            vault.write.claim([BigInt(index), account, 0n], { account: user.account }),
            faulty,
            "TransfersBlocked",
          );
          assert.equal(await vault.read.claimable([account, BigInt(index)]), pending);
        } else {
          const before = await tokens[index].read.balanceOf([account]);
          await vault.write.claim([BigInt(index), account, 0n], { account: user.account });
          assert.equal((await tokens[index].read.balanceOf([account])) - before, pending);
        }
      };

      for (let step = 0; step < LIQUIDATION_STEPS; step++) {
        if (step === LIQUIDATION_STEPS / 2) await faulty.write.setFault([Fault.None]);
        const user = random.pick(users);
        const balance = await vault.read.balanceOf([user.account.address]);
        const roll = random.int(100);

        if (roll < 35 && balance > 0n) {
          await vault.write.convertToClaims([random.portion(balance)], { account: user.account });
        } else if (roll < 45 && balance > 0n) {
          await vault.write.transfer([random.pick(users).account.address, random.portion(balance)], {
            account: user.account,
          });
        } else if (roll < 55) {
          // A donation after activation is surplus in full, and nothing owed to holders is.
          // Governance either rescues it or syncs it into everyone's rights.
          const index = random.int(2);
          const donation = random.amount();
          await tokens[index].write.mint([vault.address, donation]);
          assert.equal(await vault.read.componentSurplus([BigInt(index)]), donation);
          if (random.int(2) === 0) {
            await vault.write.rescue([tokens[index].address, deployer.account.address, donation], {
              account: governance.account,
            });
          } else {
            await vault.write.sync([tokens[index].address], { account: governance.account });
            syncedInLiquidation[index] += donation;
          }
          assert.equal(await vault.read.componentSurplus([BigInt(index)]), 0n);
        } else {
          await claimOnce(user, random.int(tokens.length));
        }
      }

      // Everyone converts what is left and withdraws every component.
      for (const user of users) {
        const balance = await vault.read.balanceOf([user.account.address]);
        if (balance > 0n) await vault.write.convertToClaims([balance], { account: user.account });
        for (let index = 0; index < tokens.length; index++) {
          if ((await vault.read.claimable([user.account.address, BigInt(index)])) > 0n) {
            await claimOnce(user, index);
          }
        }
      }

      const claimedTotals = await vault.read.totalClaimed();
      const vaultBalances = await balancesOf(basket, vault.address);
      const claimants = users.length;
      let convertedShares = 0n;
      for (const user of users) {
        convertedShares += await vault.read.claimShares([user.account.address]);
        for (let index = 0; index < tokens.length; index++) {
          assert.equal(
            await vault.read.claimed([user.account.address, BigInt(index)]),
            await entitlement(user.account.address, index),
          );
        }
      }
      assert.equal(convertedShares, liquidationSupply);
      assert.equal(await vault.read.totalSupply(), 0n);
      assert.equal(await vault.read.hasMinted([dave.account.address]), false);

      const finalReserves = await vault.read.reserves();
      for (const [index, reserve] of finalReserves.entries()) {
        assert.equal(reserve, frozenReserves[index] + syncedInLiquidation[index]);
        const dust = reserve - claimedTotals[index];
        assert.ok(dust >= 0n && dust < BigInt(claimants), `component ${index} dust ${dust}`);
        assert.equal(
          vaultBalances[index],
          balancesAtActivation[index] + syncedInLiquidation[index] - claimedTotals[index],
        );
      }
    });
  }
});
