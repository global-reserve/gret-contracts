import type { HardhatViemHelpers } from "@nomicfoundation/hardhat-viem/types";
import { maxUint256, parseUnits } from "viem";

/** Mirrors `MockFaultyERC20.Fault`. */
export const Fault = {
  None: 0,
  RevertOnTransfer: 1,
  ReturnFalseOnTransfer: 2,
  RevertOnBalanceOf: 3,
  FeeOnTransfer: 4,
  Reenter: 5,
  RevertOnZeroTransfer: 6,
  ShortByOneOnTransfer: 7,
} as const;

export const INITIAL_SHARES = 10n ** 18n;

/**
 * Test basket: A (18 decimals), B (8 decimals, like cbBTC) and C (18 decimals, switchable
 * faults). Quantities are arbitrary and chosen so that rounding is visible on B.
 */
export const INITIAL_AMOUNTS = [parseUnits("2", 18), parseUnits("0.001", 8), parseUnits("5", 18)];
export const NO_MAX = INITIAL_AMOUNTS.map(() => maxUint256);
export const NO_MIN = INITIAL_AMOUNTS.map(() => 0n);

const FUNDING = [parseUnits("1000000", 18), parseUnits("1000000", 8), parseUnits("1000000", 18)];

export const mulDivDown = (a: bigint, b: bigint, c: bigint) => (a * b) / c;
export const mulDivUp = (a: bigint, b: bigint, c: bigint) => (a * b + c - 1n) / c;

/**
 * Deploys the three components and the vault, funds `alice`, `bob`, `carol` and `dave` with
 * every component and approves the vault. `governance` stands in for the external governance
 * contract and holds no components.
 */
export async function deployBasket(viem: HardhatViemHelpers) {
  const [deployer, governance, alice, bob, carol, dave] = await viem.getWalletClients();

  const tokenA = await viem.deployContract("MockERC20", ["Mock A", "MA", 18]);
  const tokenB = await viem.deployContract("MockERC20", ["Mock B", "MB", 8]);
  const faulty = await viem.deployContract("MockFaultyERC20", ["Mock C", "MC", 18]);
  // C exposes the same ERC-20 surface; typing it as MockERC20 lets the tests loop over all three.
  const tokens = [tokenA, tokenB, await viem.getContractAt("MockERC20", faulty.address)];

  const vault = await viem.deployContract("GRETVault", [
    tokens.map((token) => token.address),
    INITIAL_AMOUNTS,
    governance.account.address,
  ]);

  const users = [alice, bob, carol, dave];
  for (const user of users) {
    for (const [i, token] of tokens.entries()) {
      await token.write.mint([user.account.address, FUNDING[i]]);
      await token.write.approve([vault.address, maxUint256], { account: user.account });
    }
  }

  return { vault, tokens, faulty, deployer, governance, alice, bob, carol, dave, users };
}

export type Basket = Awaited<ReturnType<typeof deployBasket>>;

export async function balancesOf(basket: Basket, account: `0x${string}`) {
  return Promise.all(basket.tokens.map((token) => token.read.balanceOf([account])));
}
