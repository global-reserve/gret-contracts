import assert from "node:assert/strict";
import { after, describe, it } from "node:test";

import { network } from "hardhat";
import {
  encodeAbiParameters,
  erc20Abi,
  formatUnits,
  getAddress,
  keccak256,
  maxUint256,
  parseAbi,
  parseEther,
  parseEventLogs,
  parseUnits,
  toHex,
  type Address,
  type Hex,
} from "viem";

import { PRICE_FEEDS } from "../scripts/pilot/config.js";

/**
 * Runs the vault against the real basket components on an Ethereum mainnet fork.
 *
 * MAINNET_RPC_URL is required. MAINNET_FORK_BLOCK pins the block and needs an RPC with
 * historical state; without it the fork uses the latest block and prints it.
 *
 * Balances are written directly into each token's storage, so the test needs no holders and
 * moves no real funds. It checks what the contracts do at that block; issuers can change
 * upgradeable tokens later.
 */
const RPC_URL = process.env.MAINNET_RPC_URL;
const FORK_BLOCK = process.env.MAINNET_FORK_BLOCK ? BigInt(process.env.MAINNET_FORK_BLOCK) : undefined;

// Same basket as scripts/pilot/config.ts; addresses checked against the issuers' official sources.
const BASKET = [
  { symbol: "ITOTon", address: "0x0692481c369e2bdc728a69ae31b848343a4567be", decimals: 18 },
  { symbol: "SPYx", address: "0x90a2a4c76b5d8c0bc892a69ea28aa775a8f2dd48", decimals: 18 },
  { symbol: "EFAon", address: "0x4111b60bc87f2bd1e81e783e271d7f0ec6ee088b", decimals: 18 },
  { symbol: "IEMGon", address: "0xcdd60d15125bf3362b6838d2506b0fa33bc1a515", decimals: 18 },
  { symbol: "SGOVon", address: "0x8de5d49725550f7b318b2fa0f1b1f118e98e8d0f", decimals: 18 },
  { symbol: "BILon", address: "0x2710e30d84b376c34a3b3036aa196b26a83a321b", decimals: 18 },
  { symbol: "JAAAx", address: "0x3bf2e3be4a829bb3a5f5be450ae4c8eb3488da71", decimals: 18 },
  { symbol: "PAXG", address: "0x45804880de22913dafe09f4980848ece6ecbaf78", decimals: 18 },
  { symbol: "cbBTC", address: "0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf", decimals: 8 },
  { symbol: "VNQon", address: "0xccae8843e26259278c200c6506f6e5a3bdd524cd", decimals: 18 },
  { symbol: "DBCon", address: "0x20224080ad516769723c9a4a18325fc4e8c9ab5d", decimals: 18 },
] as const;

const EIP1967_IMPLEMENTATION = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const EIP1967_ADMIN = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";
const EIP1967_BEACON = "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50";
// OpenZeppelin ERC20Upgradeable v5 namespaced storage: `_balances` is its first field.
const OZ5_ERC20_STORAGE = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00n;
const INITIAL_SHARES = 10n ** 18n;
// Base units a transfer may lose to rounding in tokens that store shares (xStocks).
const ROUNDING = 10n;
const feedAbi = parseAbi([
  "function decimals() view returns (uint8)",
  "function description() view returns (string)",
  "function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)",
]);
const pausedAbi = [
  { type: "function", name: "paused", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
] as const;

const asAddress = (word: Hex | undefined) =>
  word && BigInt(word) !== 0n ? getAddress(`0x${word.slice(-40)}`) : "-";

describe("GRETVault on an Ethereum mainnet fork", { skip: RPC_URL === undefined && "MAINNET_RPC_URL is not set" }, async () => {
  const connection = await network.create({
    network: "hardhat",
    override: { forking: { url: RPC_URL ?? "", blockNumber: FORK_BLOCK } },
  });
  const { viem, networkHelpers } = connection;
  after(() => connection.close());

  const publicClient = await viem.getPublicClient();
  const [, governance, alice, bob] = await viem.getWalletClients();
  const block = await publicClient.getBlock();
  console.log(`Fork of Ethereum mainnet at block ${block.number} (${new Date(Number(block.timestamp) * 1000).toISOString()})`);

  const balanceSlots = new Map<Address, (account: Address) => Hex>();

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
    const readBalance = () => publicClient.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [probe] });
    const before = await readBalance();
    for (const keyOf of candidates) {
      const key = keyOf(probe);
      const previous = await publicClient.getStorageAt({ address: token, slot: key });
      // Large enough to survive a share-to-balance multiplier.
      await networkHelpers.setStorageAt(token, key, toHex(10n ** 30n, { size: 32 }));
      if ((await readBalance()) !== before) {
        await networkHelpers.setStorageAt(token, key, previous ?? toHex(0n, { size: 32 }));
        return keyOf;
      }
      await networkHelpers.setStorageAt(token, key, previous ?? toHex(0n, { size: 32 }));
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
    const read = () => publicClient.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [account] });
    await networkHelpers.setStorageAt(token, keyOf(account), toHex(amount, { size: 32 }));
    const balance = await read();
    if (balance < amount) {
      const raw = balance === 0n ? amount * 10n ** 18n : (amount * amount) / balance + 1n;
      await networkHelpers.setStorageAt(token, keyOf(account), toHex(raw, { size: 32 }));
    }
    assert.ok((await read()) >= amount, `funding ${token}: balance below ${amount}`);
  }

  const balanceOf = (token: Address, account: Address) =>
    publicClient.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [account] });

  it("reports what each component is at this block", async () => {
    const rows = [];
    for (const component of BASKET) {
      const address = getAddress(component.address);
      const code = await publicClient.getCode({ address });
      const read = async <T>(fn: () => Promise<T>) => {
        try {
          return await fn();
        } catch {
          return "-";
        }
      };
      rows.push({
        symbol: component.symbol,
        onChainSymbol: await read(() => publicClient.readContract({ address, abi: erc20Abi, functionName: "symbol" })),
        decimals: await read(() => publicClient.readContract({ address, abi: erc20Abi, functionName: "decimals" })),
        codeBytes: code ? (code.length - 2) / 2 : 0,
        implementation: asAddress(await publicClient.getStorageAt({ address, slot: EIP1967_IMPLEMENTATION })),
        proxyAdmin: asAddress(await publicClient.getStorageAt({ address, slot: EIP1967_ADMIN })),
        beacon: asAddress(await publicClient.getStorageAt({ address, slot: EIP1967_BEACON })),
        paused: await read(() => publicClient.readContract({ address, abi: pausedAbi, functionName: "paused" })),
      });
    }
    console.table(rows);

    for (const [i, component] of BASKET.entries()) {
      assert.ok(rows[i].codeBytes > 0, `${component.symbol} has no code`);
      assert.equal(rows[i].decimals, component.decimals, `${component.symbol} decimals`);
    }
  });

  it("each component works in its own vault: mint, redemption, rescue and liquidation", async () => {
    const results: Record<string, string>[] = [];

    for (const component of BASKET) {
      const token = getAddress(component.address);
      const unit = parseUnits("0.001", component.decimals);
      const row: Record<string, string> = { symbol: component.symbol };
      results.push(row);
      const step = async (name: string, action: () => Promise<void>) => {
        if (Object.values(row).some((value) => value.startsWith("FAIL"))) {
          row[name] = "skipped";
          return;
        }
        try {
          await action();
          row[name] = "ok";
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          row[name] = `FAIL: ${message.split("\n").find((line) => /revert|Error/.test(line))?.trim() ?? message.slice(0, 120)}`;
        }
      };

      const vault = await viem.deployContract("GRETVault", [[token], [unit], governance.account.address]);
      const erc20 = await viem.getContractAt("MockERC20", token);
      /** The vault never records more than it holds, and the difference is rounding dust only. */
      const assertAccounting = async () => {
        const [reserve] = await vault.read.reserves();
        const [rights] = await vault.read.rightsClaimed();
        const held = await balanceOf(token, vault.address);
        assert.ok(held >= reserve - rights, `holds ${held}, owes ${reserve - rights}`);
        assert.ok(held - (reserve - rights) <= 5n * ROUNDING, `unexpected surplus ${held - (reserve - rights)}`);
      };

      await step("fund", async () => {
        await fund(token, alice.account.address, 1_000n * unit);
        await erc20.write.approve([vault.address, maxUint256], { account: alice.account });
      });
      await step("mint", async () => {
        await vault.write.mint([INITIAL_SHARES, [maxUint256], 0n, 0n], { account: alice.account });
        const before = await balanceOf(token, alice.account.address);
        await vault.write.mint([INITIAL_SHARES, [unit], 0n, 0n], { account: alice.account });
        const paid = before - (await balanceOf(token, alice.account.address));
        assert.ok(paid <= unit && paid + ROUNDING >= unit, `paid ${paid}`);
        const supply = await vault.read.totalSupply();
        assert.ok(supply <= 2n * INITIAL_SHARES && supply + 10n ** 6n >= 2n * INITIAL_SHARES, `supply ${supply}`);
        row.shortfall = String(2n * unit - (await vault.read.reserves())[0]);
        await assertAccounting();
      });
      await step("redeem", async () => {
        const before = await balanceOf(token, alice.account.address);
        const [expected] = await vault.read.previewRedeem([INITIAL_SHARES / 2n]);
        await vault.write.redeem([INITIAL_SHARES / 2n, [expected], 0n], { account: alice.account });
        const got = (await balanceOf(token, alice.account.address)) - before;
        assert.ok(got <= expected && got + ROUNDING >= expected, `got ${got} of ${expected}`);
        await assertAccounting();
      });
      await step("rescue", async () => {
        await erc20.write.transfer([vault.address, 1_000n], { account: alice.account });
        const surplus = await vault.read.componentSurplus([0n]);
        assert.ok(surplus + ROUNDING >= 1_000n, `surplus ${surplus}`);
        await vault.write.rescue([token, bob.account.address, surplus], { account: governance.account });
        // The outgoing transfer may also round, leaving a unit or two behind.
        assert.ok((await vault.read.componentSurplus([0n])) <= ROUNDING);
        await assertAccounting();
      });
      await step("liquidation", async () => {
        await vault.write.activateLiquidation({ account: governance.account });
        await vault.write.convertToClaims([await vault.read.balanceOf([alice.account.address])], { account: alice.account });
        const pending = await vault.read.claimable([alice.account.address, 0n]);
        const before = await balanceOf(token, alice.account.address);
        await vault.write.claim([0n, alice.account.address, 0n], { account: alice.account });
        const got = (await balanceOf(token, alice.account.address)) - before;
        assert.ok(got <= pending && got + ROUNDING >= pending, `got ${got} of ${pending}`);
        assert.ok((await balanceOf(token, vault.address)) <= 5n * ROUNDING);
      });
    }

    console.table(results);
    const failures = results.filter((row) => Object.values(row).some((value) => value.startsWith("FAIL")));
    assert.deepEqual(failures, [], "components that failed on the fork");
  });

  it("the full 11-component basket works end to end", async () => {
    const tokens = BASKET.map((component) => getAddress(component.address));
    const units = BASKET.map((component) => parseUnits("0.001", component.decimals));
    const vault = await viem.deployContract("GRETVault", [tokens, units, governance.account.address]);
    for (const user of [alice, bob]) {
      await networkHelpers.setBalance(user.account.address, parseEther("100"));
      for (const [i, token] of tokens.entries()) {
        await fund(token, user.account.address, 1_000n * units[i]);
        const erc20 = await viem.getContractAt("MockERC20", token);
        await erc20.write.approve([vault.address, maxUint256], { account: user.account });
      }
    }
    const max = tokens.map(() => maxUint256);
    const min = tokens.map(() => 0n);
    const gas = async (hash: Hex) => (await publicClient.waitForTransactionReceipt({ hash })).gasUsed;

    await vault.write.mint([INITIAL_SHARES, max, 0n, 0n], { account: alice.account });
    const mintGas = await gas(await vault.write.mint([INITIAL_SHARES, max, 0n, 0n], { account: bob.account }));
    const redeemGas = await gas(await vault.write.redeem([INITIAL_SHARES / 2n, min, 0n], { account: alice.account }));
    const heldAfterRedeem = await Promise.all(tokens.map((token) => balanceOf(token, vault.address)));
    for (const [i, reserve] of (await vault.read.reserves()).entries()) {
      assert.ok(heldAfterRedeem[i] >= reserve && heldAfterRedeem[i] - reserve <= 5n * ROUNDING, BASKET[i].symbol);
    }

    await vault.write.activateLiquidation({ account: governance.account });
    let claimGas = 0n;
    for (const user of [alice, bob]) {
      await vault.write.convertToClaims([await vault.read.balanceOf([user.account.address])], { account: user.account });
      for (let i = 0n; i < BigInt(tokens.length); i++) {
        claimGas = await gas(await vault.write.claim([i, user.account.address, 0n], { account: user.account }));
      }
    }
    console.log(`Gas with the real components: mint ${mintGas}, redeem ${redeemGas}, one claim ${claimGas}`);

    for (const [i, token] of tokens.entries()) {
      assert.ok((await balanceOf(token, vault.address)) <= 10n * ROUNDING, `${BASKET[i].symbol} leftover`);
    }
  });

  // Runs before any test that moves the fork's clock, so the feeds are as fresh as on mainnet.
  it("the Chainlink price guard prices the real components with the real feeds", async () => {
    const tokens = BASKET.map((component) => getAddress(component.address));
    const units = BASKET.map((component) => parseUnits("0.001", component.decimals));
    const index = (symbol: string) => BASKET.findIndex((component) => component.symbol === symbol);
    const vault = await viem.deployContract("GRETVault", [tokens, units, governance.account.address]);
    await networkHelpers.setBalance(alice.account.address, parseEther("100"));
    for (const [i, token] of tokens.entries()) {
      await fund(token, alice.account.address, 1_000n * units[i]);
      const erc20 = await viem.getContractAt("MockERC20", token);
      await erc20.write.approve([vault.address, maxUint256], { account: alice.account });
    }
    const max = tokens.map(() => maxUint256);
    await vault.write.mint([INITIAL_SHARES, max, 0n, 0n], { account: alice.account });
    await vault.write.mint([99n * INITIAL_SHARES, max, 0n, 0n], { account: alice.account });
    const guard = await viem.deployContract("ChainlinkPriceGuard", [
      vault.address,
      PRICE_FEEDS.map(({ symbol }) => tokens[index(symbol)]),
      PRICE_FEEDS.map(({ feed }) => feed),
      PRICE_FEEDS.map(({ maxAge }) => BigInt(maxAge)),
    ]);

    // Each feed quotes one whole token; with US markets closed the equity feeds go stale and refuse.
    const now = (await publicClient.getBlock()).timestamp;
    const rows = [];
    for (const { symbol, description, feed, maxAge } of PRICE_FEEDS) {
      const token = tokens[index(symbol)];
      const [, answer, , updatedAt] = await publicClient.readContract({ address: feed, abi: feedAbi, functionName: "latestRoundData" });
      const decimals = await publicClient.readContract({ address: feed, abi: feedAbi, functionName: "decimals" });
      assert.equal(await publicClient.readContract({ address: feed, abi: feedAbi, functionName: "description" }), description);
      const whole = 10n ** BigInt(BASKET[index(symbol)].decimals);
      const fresh = now - updatedAt <= BigInt(maxAge);
      if (fresh) {
        assert.equal(await guard.read.valueOf([token, whole]), answer * 10n ** BigInt(18 - decimals), symbol);
      } else {
        await viem.assertions.revertWithCustomError(guard.read.valueOf([token, whole]), guard, "StalePrice");
      }
      rows.push({ symbol, description, price: formatUnits(answer, decimals), ageHours: (Number(now - updatedAt) / 3600).toFixed(1), fresh });
    }
    console.table(rows);
    for (const component of BASKET) {
      if (PRICE_FEEDS.some(({ symbol }) => symbol === component.symbol)) continue;
      const token = getAddress(component.address);
      await viem.assertions.revertWithCustomErrorWithArgs(guard.read.valueOf([token, 1n]), guard, "NoFeed", [token]);
    }

    // PAXG for cbBTC, checked as the vault checks it: at the feed price it passes without a loss,
    // 1.9% below records the loss as a share of the priced reserves, and 5% below is refused.
    const [paxg, cbBTC] = [tokens[index("PAXG")], tokens[index("cbBTC")]];
    const sold = parseUnits("0.05", 18);
    const soldValue = await guard.read.valueOf([paxg, sold]);
    const oneBitcoin = await guard.read.valueOf([cbBTC, 10n ** 8n]);
    const satoshisFor = (keptBps: bigint) => (soldValue * keptBps * 10n ** 8n) / (10_000n * oneBitcoin);
    await networkHelpers.impersonateAccount(vault.address);
    await networkHelpers.setBalance(vault.address, parseEther("1"));
    const gasOf = async (hash: Hex) => (await publicClient.waitForTransactionReceipt({ hash })).gasUsed - 21_000n;
    const fairGas = await gasOf(
      await guard.write.checkSwap([paxg, sold, cbBTC, satoshisFor(10_000n) + 1n], { account: vault.address }),
    );
    assert.equal(await guard.read.weeklyLoss(), 0n);
    const lossHash = await guard.write.checkSwap([paxg, sold, cbBTC, satoshisFor(9_810n)], { account: vault.address });
    const lossGas = await gasOf(lossHash);
    let priced = 0n;
    for (const [i, reserve] of (await vault.read.reserves()).entries()) {
      const balance = await publicClient.readContract({
        address: tokens[i],
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [vault.address],
      });
      try {
        priced += await guard.read.valueOf([tokens[i], reserve < balance ? reserve : balance]);
      } catch {
        // Unpriced or stale: left out of the vault's value.
      }
    }
    const [recorded] = parseEventLogs({
      abi: guard.abi,
      eventName: "LossRecorded",
      logs: (await publicClient.waitForTransactionReceipt({ hash: lossHash })).logs,
    });
    const { loss, vaultValue, weeklyLoss } = recorded.args;
    assert.equal(vaultValue, priced);
    assert.equal(weeklyLoss, (loss * 10n ** 18n + priced - 1n) / priced);
    assert.equal(await guard.read.weeklyLoss(), weeklyLoss);
    await viem.assertions.revertWithCustomError(
      guard.write.checkSwap([paxg, sold, cbBTC, satoshisFor(9_500n)], { account: vault.address }),
      guard,
      "SwapLossTooHigh",
    );
    await networkHelpers.stopImpersonatingAccount(vault.address);
    console.log(`Guard loss: $${formatUnits(loss, 18)}, ${formatUnits(weeklyLoss * 100n, 18)}% of $${formatUnits(priced, 18)} priced`);
    console.log(`Gas the guard adds to a swap: ${fairGas} without a loss, ${lossGas} with one`);
  });

  it("rebalancing with the real components: each one is sold and bought, one joins and one leaves", async () => {
    const tokens = BASKET.map((component) => getAddress(component.address));
    const units = BASKET.map((component) => parseUnits("0.001", component.decimals));
    const symbolOf = (token: Address) => BASKET[tokens.indexOf(getAddress(token))].symbol;
    // DBCon starts outside the basket and joins through governance.
    const joining = tokens.length - 1;
    const vault = await viem.deployContract("GRETVault", [
      tokens.slice(0, joining),
      units.slice(0, joining),
      governance.account.address,
    ]);
    for (const user of [alice, bob]) {
      await networkHelpers.setBalance(user.account.address, parseEther("100"));
      for (const [i, token] of tokens.entries()) {
        await fund(token, user.account.address, 1_000n * units[i]);
        const erc20 = await viem.getContractAt("MockERC20", token);
        await erc20.write.approve([vault.address, maxUint256], { account: user.account });
      }
    }
    const max = (count: number) => Array.from({ length: count }, () => maxUint256);
    await vault.write.mint([INITIAL_SHARES, max(joining), 0n, 0n], { account: alice.account });
    await vault.write.mint([INITIAL_SHARES, max(joining), 0n, 0n], { account: alice.account });

    // bob becomes the rebalancer and DBCon a component, both after the vault's 7-day wait. These
    // swaps test the tokens, not prices, so the guard accepts every swap.
    const guard = await viem.deployContract("MockPriceGuard");
    await vault.write.proposeRebalancer([bob.account.address], { account: governance.account });
    await vault.write.proposePriceGuard([guard.address], { account: governance.account });
    await vault.write.announceComponent([tokens[joining]], { account: governance.account });
    await networkHelpers.time.increase(await vault.read.BASKET_CHANGE_DELAY());
    await vault.write.acceptRebalancer({ account: bob.account });
    await vault.write.applyPriceGuard();
    await vault.write.addComponent([tokens[joining]], { account: governance.account });

    /** The vault holds every reserve it records, and the difference is rounding dust only. */
    const assertBacked = async () => {
      const reserves = await vault.read.reserves();
      for (const [i, token] of (await vault.read.components()).entries()) {
        const held = await balanceOf(token, vault.address);
        assert.ok(held >= reserves[i] && held - reserves[i] <= 5n * ROUNDING, `${symbolOf(token)}: ${held} vs ${reserves[i]}`);
      }
    };

    // Each component is sold for the next one, so every token leaves and enters the vault.
    let swapGas = 0n;
    for (let i = 0; i < tokens.length; i++) {
      const next = (i + 1) % tokens.length;
      const reserve = (await vault.read.reserves())[i];
      const hash = await vault.write.swap([tokens[i], reserve / 2n, tokens[next], units[next]], { account: bob.account });
      swapGas = (await publicClient.waitForTransactionReceipt({ hash })).gasUsed;
      await assertBacked();
    }

    // bob sells all the cbBTC, governance removes it, and the rest keep their order.
    const cbBTC = tokens[8];
    const cbBTCReserve = (await vault.read.reserves())[8];
    await vault.write.swap([cbBTC, cbBTCReserve, tokens[7], units[7]], { account: bob.account });
    await vault.write.removeComponent([cbBTC], { account: governance.account });
    const remaining = tokens.filter((token) => token !== cbBTC);
    assert.deepEqual(await vault.read.components(), remaining);

    // One addition and one removal: amounts by position are now prepared for version 2.
    const version = await vault.read.basketVersion();
    assert.equal(version, 2n);
    await vault.write.mint([INITIAL_SHARES, max(remaining.length), 0n, version], { account: alice.account });
    await vault.write.redeem([INITIAL_SHARES, remaining.map(() => 0n), version], { account: alice.account });
    await assertBacked();
    console.log(`Gas of one swap with the real components and a test guard that records it: ${swapGas}`);
  });
});
