import assert from "node:assert/strict";

import type { NetworkConnection } from "hardhat/types/network";
import { encodeAbiParameters, erc20Abi, getAddress, keccak256, toHex, type Address, type Hex } from "viem";

// OpenZeppelin ERC20Upgradeable v5 namespaced storage: `_balances` is its first field.
const OZ5_ERC20_STORAGE = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00n;

/**
 * Funds fork accounts with real tokens by writing each token's balance storage, so tests need no
 * holders and move no real funds.
 */
export async function storageFunding({ viem, networkHelpers }: NetworkConnection) {
  const publicClient = await viem.getPublicClient();
  const balanceSlots = new Map<Address, (account: Address) => Hex>();

  const balanceOf = (token: Address, account: Address) =>
    publicClient.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [account] });

  /** Finds how a token stores balances by writing candidate slots and watching balanceOf. */
  async function findBalanceSlot(token: Address) {
    const probe = getAddress("0x00000000000000000000000000000000000b0b0b");
    const candidates: ((account: Address) => Hex)[] = [
      (account) => keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [account, OZ5_ERC20_STORAGE])),
    ];
    // Solidity mappings first (xStocks keep balances at slot 263), then Vyper-style keys.
    for (let slot = 0n; slot < 300n; slot++) {
      candidates.push((account) =>
        keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [account, slot])),
      );
    }
    for (let slot = 0n; slot < 60n; slot++) {
      candidates.push((account) =>
        keccak256(encodeAbiParameters([{ type: "uint256" }, { type: "address" }], [slot, account])),
      );
    }
    const before = await balanceOf(token, probe);
    for (const keyOf of candidates) {
      const key = keyOf(probe);
      const previous = await publicClient.getStorageAt({ address: token, slot: key });
      // Large enough to survive a share-to-balance multiplier.
      await networkHelpers.setStorageAt(token, key, toHex(10n ** 30n, { size: 32 }));
      const changed = (await balanceOf(token, probe)) !== before;
      await networkHelpers.setStorageAt(token, key, previous ?? toHex(0n, { size: 32 }));
      if (changed) return keyOf;
    }
    throw new Error(`balance slot not found for ${token}`);
  }

  /**
   * Sets `account`'s balance of `token` to at least `amount` by writing its storage. Tokens that
   * store shares and apply a multiplier get the raw value scaled up accordingly.
   */
  async function fund(token: Address, account: Address, amount: bigint) {
    let keyOf = balanceSlots.get(token);
    if (keyOf === undefined) {
      keyOf = await findBalanceSlot(token);
      balanceSlots.set(token, keyOf);
    }
    await networkHelpers.setStorageAt(token, keyOf(account), toHex(amount, { size: 32 }));
    const balance = await balanceOf(token, account);
    if (balance < amount) {
      const raw = balance === 0n ? amount * 10n ** 18n : (amount * amount) / balance + 1n;
      await networkHelpers.setStorageAt(token, keyOf(account), toHex(raw, { size: 32 }));
    }
    assert.ok((await balanceOf(token, account)) >= amount, `funding ${token}: balance below ${amount}`);
  }

  return { balanceOf, fund };
}
