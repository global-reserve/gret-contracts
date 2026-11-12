import assert from "node:assert/strict";
import { after, beforeEach, describe, it } from "node:test";

import { artifacts, network } from "hardhat";
import {
  BaseError,
  ContractFunctionRevertedError,
  getAddress,
  maxUint256,
  parseEther,
  parseSignature,
  parseUnits,
  zeroAddress,
  type Address,
} from "viem";

import { PILOT } from "../scripts/pilot/config.js";
import { storageFunding } from "./funding.js";

/**
 * Attacks the deployed vault on an Ethereum mainnet fork. The code, configuration, balances and
 * holder are the mainnet ones at the fork block; attackers are fresh accounts funded by writing
 * token storage, and governance is impersonated where a test needs it. Nothing is sent to
 * mainnet, and every test starts again from the fork block.
 *
 * `npm run test:deployed` uses PublicNode unless MAINNET_RPC_URL is set; MAINNET_FORK_BLOCK pins
 * the block and needs an RPC with historical state; ATTACK_SEED changes the random sequence.
 * Tests that reproduce a known limitation of the specification say so in their name.
 *
 * The configuration test doubles as an alarm: it fails when governance proposes or makes any
 * change, which is then expected to be recorded here.
 */
const RPC_URL = process.env.MAINNET_RPC_URL;
const FORK_BLOCK = process.env.MAINNET_FORK_BLOCK ? BigInt(process.env.MAINNET_FORK_BLOCK) : undefined;
const SEED = Number(process.env.ATTACK_SEED ?? 1);

// The current deployment, as recorded in README.md#deployments.
const VAULT = getAddress("0x8cC6dfd77A5BDB9098d90d8beccF9F7eC145e8BA");
const ONE_GRET = 10n ** 18n;
// Components that store shares and convert amounts with a multiplier (xStocks): a transfer can
// move a few base units more or less than requested.
const SHARE_TOKENS = new Set(["SPYx", "JAAAx"]);
const ROUNDING = 10n;
const DEAD = getAddress("0x000000000000000000000000000000000000dEaD");
// Holds nothing and approved nothing: the plain outsider.
const OUTSIDER = getAddress("0x00000000000000000000000000000000000bad00");

/** Deterministic pseudo-random numbers in [0, 1) (mulberry32), so a failing run can be replayed. */
function randomFrom(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

describe("The deployed GRETVault under attack on a mainnet fork", { skip: RPC_URL === undefined && "MAINNET_RPC_URL is not set" }, async () => {
  const connection = await network.create({
    network: "hardhat",
    override: { forking: { url: RPC_URL ?? "", blockNumber: FORK_BLOCK } },
  });
  const { viem, networkHelpers } = connection;
  after(() => connection.close());

  const publicClient = await viem.getPublicClient();
  const block = await publicClient.getBlock();
  console.log(`Fork of Ethereum mainnet at block ${block.number} (${new Date(Number(block.timestamp) * 1000).toISOString()}); vault ${VAULT}`);

  const vault = await viem.getContractAt("GRETVault", VAULT);
  const { balanceOf, fund } = await storageFunding(connection);
  const tokens = [...(await vault.read.components())];
  const count = tokens.length;
  const symbols = tokens.map((token) => PILOT.components.find((c) => getAddress(c.address) === token)?.symbol ?? token);
  const erc20s = await Promise.all(tokens.map((token) => viem.getContractAt("MockERC20", token)));

  // The pilot wallet: the only holder at deployment, and governance.
  const holder = getAddress(PILOT.wallet);
  const governance = await vault.read.governance();
  for (const account of new Set([holder, governance])) {
    await networkHelpers.impersonateAccount(account);
    await networkHelpers.setBalance(account, parseEther("10"));
  }
  const holderClient = await viem.getWalletClient(holder);
  const governanceClient = await viem.getWalletClient(governance);

  // Attackers and other minters, each with a thousand GRET's worth of every component.
  const [attacker, bob, carol] = await viem.getWalletClients();
  const supplyAtFork = await vault.read.totalSupply();
  const heldAtFork = await Promise.all(tokens.map((token) => balanceOf(token, VAULT)));
  for (const user of [attacker, bob, carol]) {
    await networkHelpers.setBalance(user.account.address, parseEther("100"));
    for (const [i, token] of tokens.entries()) {
      await fund(token, user.account.address, (1_000n * heldAtFork[i] * ONE_GRET) / supplyAtFork + 1_000n);
      await erc20s[i].write.approve([VAULT, maxUint256], { account: user.account });
    }
  }

  const baseline = await networkHelpers.takeSnapshot();
  beforeEach(() => baseline.restore());

  const held = () => Promise.all(tokens.map((token) => balanceOf(token, VAULT)));
  const balancesOf = (account: Address) => Promise.all(tokens.map((token) => balanceOf(token, account)));
  const tolerance = (i: number) => (SHARE_TOKENS.has(symbols[i]) ? ROUNDING : 0n);
  const maxIn = () => tokens.map(() => maxUint256);
  const version = () => vault.read.basketVersion();
  const shareOf = (shares: bigint, amount: bigint, supply: bigint) => (shares * amount) / supply;
  const table = (rows: Record<string, bigint | string>[]) =>
    console.table(rows.map((row) => Object.fromEntries(Object.entries(row).map(([k, v]) => [k, String(v)]))));

  /** What a call would do, without sending it: "ok", or the name of the error it reverts with. */
  async function outcome(account: Address, functionName: string, args: readonly unknown[]): Promise<string> {
    try {
      await publicClient.simulateContract({ address: VAULT, abi: vault.abi, functionName, args, account } as never);
      return "ok";
    } catch (error) {
      if (!(error instanceof BaseError)) throw error;
      const reverted = error.walk((cause) => cause instanceof ContractFunctionRevertedError);
      if (reverted instanceof ContractFunctionRevertedError) {
        return reverted.data?.errorName ?? reverted.signature ?? reverted.reason ?? "revert";
      }
      throw error;
    }
  }

  it("runs the code of this repository", async () => {
    const artifact = await artifacts.readArtifact("GRETVault");
    const onchain = await publicClient.getCode({ address: VAULT });
    assert.ok(onchain, "no code at the vault address");
    // Immutables (the EIP-712 domain) are written at deployment; everything else must match.
    const mask = (code: string) => {
      let out = code.toLowerCase();
      for (const references of Object.values(artifact.immutableReferences ?? {})) {
        for (const { start, length } of references) {
          const from = 2 + 2 * start;
          out = out.slice(0, from) + "0".repeat(2 * length) + out.slice(from + 2 * length);
        }
      }
      return out;
    };
    assert.equal(onchain.length, artifact.deployedBytecode.length, "runtime code length");
    assert.equal(mask(onchain), mask(artifact.deployedBytecode), "runtime code");
  });

  it("is configured as the pilot recorded it, with no change pending", async () => {
    assert.equal(governance, getAddress(PILOT.governance));
    assert.deepEqual(tokens, PILOT.components.map((c) => getAddress(c.address)));
    assert.deepEqual(await vault.read.initialAmounts(), PILOT.components.map((c) => parseUnits(c.perGret, c.decimals)));
    for (const fn of ["rebalancer", "priceGuard", "eligibility", "feeRecipient"] as const) {
      assert.equal(await vault.read[fn](), zeroAddress, fn);
    }
    for (const fn of ["mintFee", "redeemFee", "pendingMintFee", "pendingRedeemFee", "pendingFeesReadyAt", "pendingAnnouncements", "basketVersion"] as const) {
      assert.equal(await vault.read[fn](), 0n, fn);
    }
    for (const fn of ["governanceProposal", "rebalancerProposal", "priceGuardProposal", "eligibilityProposal"] as const) {
      assert.deepEqual(await vault.read[fn](), [zeroAddress, 0n], fn);
    }
    assert.equal(await vault.read.mintPaused(), false, "mintPaused");
    assert.equal(await vault.read.liquidationActive(), false, "liquidationActive");
    for (const token of tokens) {
      assert.equal(await vault.read.excluded([token]), false);
      assert.equal(await vault.read.writtenOff([token]), false);
      assert.equal(await vault.read.writeOffReadyAt([token]), 0n);
    }
    // Backing is the live balance of every component.
    assert.deepEqual(await vault.read.reserves(), await held());
    const supply = await vault.read.totalSupply();
    console.log(`Supply ${supply}; the pilot wallet holds ${await vault.read.balanceOf([holder])}`);
    table(tokens.map((_, i) => ({ component: symbols[i], held: heldAtFork[i], initialAmount: parseUnits(PILOT.components[i].perGret, PILOT.components[i].decimals) })));
  });

  it("lets its holder redeem now and receive every component in full", async () => {
    const supply = await vault.read.totalSupply();
    const shares = await vault.read.balanceOf([holder]);
    assert.ok(shares > 0n, "the pilot wallet holds no GRET");
    const quote = await vault.read.previewRedeem([shares]);
    const before = await balancesOf(holder);
    const left = await held();
    await vault.write.redeem([shares, holder, quote, await version()], { account: holderClient.account });
    const after = await balancesOf(holder);
    for (let i = 0; i < count; i++) {
      assert.equal(quote[i], shareOf(shares, left[i], supply), symbols[i]);
      const got = after[i] - before[i];
      assert.ok(got <= quote[i] && got + tolerance(i) >= quote[i], `${symbols[i]}: got ${got} of ${quote[i]}`);
    }
  });

  it("refuses every state-changing call from an outsider, except moving its own GRET", async () => {
    const [c0, c1] = tokens;
    const holderShares = await vault.read.balanceOf([holder]);
    // A permit for the holder's GRET, signed by someone else.
    const deadline = block.timestamp + 3_600n;
    const forged = parseSignature(
      await attacker.signTypedData({
        domain: { name: "Global Reserve Token", version: "1", chainId: await publicClient.getChainId(), verifyingContract: VAULT },
        types: {
          Permit: [
            { name: "owner", type: "address" },
            { name: "spender", type: "address" },
            { name: "value", type: "uint256" },
            { name: "nonce", type: "uint256" },
            { name: "deadline", type: "uint256" },
          ],
        },
        primaryType: "Permit",
        message: { owner: holder, spender: OUTSIDER, value: maxUint256, nonce: await vault.read.nonces([holder]), deadline },
      }),
    );

    // null: any revert, here a component refusing to move tokens the caller does not have.
    const attempts: [string, readonly unknown[], string | null][] = [
      ["activateLiquidation", [], "NotGovernance"],
      ["proposeRebalancer", [OUTSIDER], "NotGovernance"],
      ["cancelRebalancerProposal", [], "NotGovernance"],
      ["revokeRebalancer", [], "NotGovernance"],
      ["proposePriceGuard", [c0], "NotGovernance"],
      ["cancelPriceGuardProposal", [], "NotGovernance"],
      ["announceComponent", [c0], "NotGovernance"],
      ["cancelComponentAnnouncement", [c0], "NotGovernance"],
      ["removeComponent", [c0], "NotGovernance"],
      ["activateComponent", [c0], "NotGovernance"],
      ["deactivateEmptyComponent", [c0], "NotGovernance"],
      ["setInitialAmounts", [tokens.map(() => 1n), 0n], "NotGovernance"],
      ["proposeWriteOff", [c0], "NotGovernance"],
      ["cancelWriteOff", [c0], "NotGovernance"],
      ["proposeFees", [500n, 500n], "NotGovernance"],
      ["cancelFeesProposal", [], "NotGovernance"],
      ["setFeeRecipient", [OUTSIDER], "NotGovernance"],
      ["setMintPaused", [true], "NotGovernance"],
      ["proposeEligibility", [c0], "NotGovernance"],
      ["cancelEligibilityProposal", [], "NotGovernance"],
      ["removeEligibility", [], "NotGovernance"],
      ["rescue", [c0, OUTSIDER, 1n], "NotGovernance"],
      ["proposeGovernance", [OUTSIDER], "NotGovernance"],
      ["cancelGovernanceProposal", [], "NotGovernance"],
      ["acceptGovernance", [], "NotProposed"],
      ["acceptRebalancer", [], "NotProposed"],
      ["applyPriceGuard", [], "NoPendingProposal"],
      ["applyEligibility", [], "NoPendingProposal"],
      ["applyFees", [], "NoPendingFees"],
      ["addComponent", [c0], "NoPendingComponent"],
      ["writeOffComponent", [c0], "NoPendingWriteOff"],
      ["swap", [c0, 1n, c1, 1n, "0x"], "NotRebalancer"],
      ["convertToClaims", [1n], "LiquidationNotActive"],
      ["claim", [0n, OUTSIDER, 0n], "LiquidationNotActive"],
      ["redeem", [holderShares, OUTSIDER, [], 0n], "ERC20InsufficientBalance"],
      ["redeemSkipping", [holderShares, OUTSIDER, [], [], 0n], "ERC20InsufficientBalance"],
      ["transfer", [OUTSIDER, 1n], "ERC20InsufficientBalance"],
      ["transferFrom", [holder, OUTSIDER, 1n], "ERC20InsufficientAllowance"],
      ["permit", [holder, OUTSIDER, maxUint256, deadline, Number(forged.v ?? BigInt(forged.yParity + 27)), forged.r, forged.s], "ERC2612InvalidSigner"],
      ["mint", [ONE_GRET, OUTSIDER, maxIn(), 0n, 0n], null],
      // Only lets someone else move the caller's own GRET.
      ["approve", [holder, maxUint256], "ok"],
    ];

    // Every function that can change state is in the list, so a new one cannot go unchecked.
    const mutating = vault.abi
      .filter((item) => item.type === "function" && !["view", "pure"].includes(item.stateMutability))
      .map((item) => (item as { name: string }).name)
      .sort();
    assert.deepEqual([...new Set(attempts.map(([name]) => name))].sort(), mutating);

    const rows = [];
    for (const [fn, args, expected] of attempts) {
      const got = await outcome(OUTSIDER, fn, args);
      rows.push({ function: fn, outcome: got });
      if (expected === null) assert.notEqual(got, "ok", fn);
      else assert.equal(got, expected, fn);
    }
    table(rows);
  });

  it("an attacker who mints, redeems and donates at any size and in any order takes nothing", async () => {
    const random = randomFrom(SEED);
    const pick = (n: number) => Math.floor(random() * n);
    const cbBTC = symbols.indexOf("cbBTC");
    const holderShares = await vault.read.balanceOf([holder]);
    const quoteBefore = await vault.read.previewRedeem([holderShares]);
    const heldBefore = await held();
    const walletBefore = await balancesOf(attacker.account.address);
    const tally: Record<string, number> = {};
    const note = (what: string) => (tally[what] = (tally[what] ?? 0) + 1);

    for (let step = 0; step < 60; step++) {
      const kind = pick(10);
      const owned = await vault.read.balanceOf([attacker.account.address]);
      if (kind < 5) {
        // A mint of any magnitude, from 1 wei to tens of GRET.
        const shares = BigInt(1 + pick(9)) * 10n ** BigInt(pick(20));
        const args = [shares, attacker.account.address, maxIn(), 0n, await version()] as const;
        const result = await outcome(attacker.account.address, "mint", args);
        note(`mint: ${result}`);
        if (result === "ok") await vault.write.mint(args, { account: attacker.account });
        // Tiny mints ask a share-converting token for a unit or two it can deliver as nothing.
        else assert.ok(["UnexpectedBalance", "ZeroShares"].includes(result), `mint of ${shares}: ${result}`);
      } else if (kind === 5) {
        // A mint sized to a rounding boundary of the coarsest component, cbBTC (8 decimals).
        const supply = await vault.read.totalSupply();
        const satoshis = await balanceOf(tokens[cbBTC], VAULT);
        const shares = (BigInt(1 + pick(5)) * supply) / satoshis + BigInt(pick(3)) - 1n;
        if (shares <= 0n) continue;
        const args = [shares, attacker.account.address, maxIn(), 0n, await version()] as const;
        const result = await outcome(attacker.account.address, "mint", args);
        note(`boundary mint: ${result}`);
        if (result === "ok") await vault.write.mint(args, { account: attacker.account });
        else assert.ok(["UnexpectedBalance", "ZeroShares"].includes(result), `mint of ${shares}: ${result}`);
      } else if (kind < 9) {
        if (owned === 0n) continue;
        // All of it, 1 wei, or any fraction.
        const choice = pick(3);
        const shares = choice === 0 ? owned : choice === 1 ? 1n : (owned * BigInt(1 + pick(999))) / 1000n || 1n;
        await vault.write.redeem([shares, attacker.account.address, [], 0n], { account: attacker.account });
        note("redeem: ok");
      } else {
        const i = pick(count);
        await erc20s[i].write.transfer([VAULT, BigInt(1 + pick(1_000))], { account: attacker.account });
        note("donation");
      }
    }
    const owned = await vault.read.balanceOf([attacker.account.address]);
    if (owned > 0n) await vault.write.redeem([owned, attacker.account.address, [], 0n], { account: attacker.account });

    const walletAfter = await balancesOf(attacker.account.address);
    const heldAfter = await held();
    const quoteAfter = await vault.read.previewRedeem([holderShares]);
    console.log(`Seed ${SEED}:`, tally);
    table(tokens.map((_, i) => ({
      component: symbols[i],
      attackerNet: walletAfter[i] - walletBefore[i],
      vaultNet: heldAfter[i] - heldBefore[i],
      holderQuoteNet: quoteAfter[i] - quoteBefore[i],
    })));
    assert.equal(await vault.read.totalSupply(), supplyAtFork);
    for (let i = 0; i < count; i++) {
      assert.ok(walletAfter[i] <= walletBefore[i] + tolerance(i), `${symbols[i]}: the attacker gained ${walletAfter[i] - walletBefore[i]}`);
      assert.ok(heldAfter[i] + tolerance(i) >= heldBefore[i], `${symbols[i]}: the vault lost ${heldBefore[i] - heldAfter[i]}`);
      assert.ok(quoteAfter[i] + tolerance(i) >= quoteBefore[i], `${symbols[i]}: the holder's share fell`);
    }
  });

  it("a donation goes to the holders: the donor cannot take it back, and a minter front-run by one loses nothing", async () => {
    const supply = await vault.read.totalSupply();
    const holderShares = await vault.read.balanceOf([holder]);
    const quoteBefore = await vault.read.previewRedeem([holderShares]);
    const donations = (await held()).map((amount) => amount / 100n);
    for (const [i, amount] of donations.entries()) {
      await erc20s[i].write.transfer([VAULT, amount], { account: attacker.account });
    }
    const quoteAfter = await vault.read.previewRedeem([holderShares]);
    for (let i = 0; i < count; i++) {
      const expected = shareOf(holderShares, donations[i], supply);
      assert.ok(quoteAfter[i] - quoteBefore[i] + tolerance(i) + 1n >= expected, `${symbols[i]}: the holder did not get the donation`);
    }

    // The donor mints as many GRET as exist and redeems them: it pays the donation back in.
    const walletBefore = await balancesOf(attacker.account.address);
    await vault.write.mint([supply, attacker.account.address, maxIn(), 0n, await version()], { account: attacker.account });
    const minted = await vault.read.balanceOf([attacker.account.address]);
    await vault.write.redeem([minted, attacker.account.address, [], 0n], { account: attacker.account });
    const walletAfter = await balancesOf(attacker.account.address);
    for (let i = 0; i < count; i++) {
      assert.ok(walletAfter[i] <= walletBefore[i] + tolerance(i), `${symbols[i]}: the donor recovered ${walletAfter[i] - walletBefore[i]}`);
    }

    // Bob prepares a mint at the current amounts; a donation lands first and his limits refuse it.
    const quote = await vault.read.previewMint([ONE_GRET]);
    const cbBTC = symbols.indexOf("cbBTC");
    await erc20s[cbBTC].write.transfer([VAULT, (await balanceOf(tokens[cbBTC], VAULT)) / 100n + 1n], { account: attacker.account });
    await viem.assertions.revertWithCustomError(
      vault.write.mint([ONE_GRET, bob.account.address, quote, 0n, await version()], { account: bob.account }),
      vault,
      "AmountInAboveMax",
    );
    // Without limits he pays more, for GRET backed by as much more; leaving costs him rounding only.
    const bobBefore = await balancesOf(bob.account.address);
    const heldNow = await held();
    await vault.write.mint([ONE_GRET, bob.account.address, maxIn(), 0n, await version()], { account: bob.account });
    await vault.write.redeem([await vault.read.balanceOf([bob.account.address]), bob.account.address, [], 0n], { account: bob.account });
    const bobAfter = await balancesOf(bob.account.address);
    const rows = [];
    for (let i = 0; i < count; i++) {
      const lost = bobBefore[i] - bobAfter[i];
      rows.push({ component: symbols[i], bobLost: lost, heldPerGret: heldNow[i] });
      // At most one millionth of a millionth of the amount behind 1 GRET, plus a unit of rounding.
      assert.ok(lost <= heldNow[i] / 10n ** 12n + 2n + tolerance(i), `${symbols[i]}: bob lost ${lost}`);
    }
    table(rows);
  });

  it("a holder who skips a component gives its share of it to the others, and cannot pause minting", async () => {
    const cbBTC = symbols.indexOf("cbBTC");
    const holderShares = await vault.read.balanceOf([holder]);
    const quoteBefore = await vault.read.previewRedeem([holderShares]);
    await vault.write.mint([ONE_GRET, attacker.account.address, maxIn(), 0n, await version()], { account: attacker.account });
    const minted = await vault.read.balanceOf([attacker.account.address]);
    const satoshisBefore = await balanceOf(tokens[cbBTC], attacker.account.address);
    await vault.write.redeemSkipping([minted, attacker.account.address, [], [tokens[cbBTC], OUTSIDER], 0n], { account: attacker.account });
    assert.equal(await balanceOf(tokens[cbBTC], attacker.account.address), satoshisBefore);
    assert.equal(await vault.read.mintPaused(), false);
    const quoteAfter = await vault.read.previewRedeem([holderShares]);
    assert.ok(quoteAfter[cbBTC] > quoteBefore[cbBTC], "the holder did not get the skipped cbBTC");
  });

  it("in a liquidation an attacker gets its share and no more, whatever it claims, donates or converts", async () => {
    const holderShares = await vault.read.balanceOf([holder]);
    const walletBefore = await balancesOf(attacker.account.address);
    await vault.write.mint([holderShares / 2n, attacker.account.address, maxIn(), 0n, await version()], { account: attacker.account });
    const attackerShares = await vault.read.balanceOf([attacker.account.address]);
    const supply = await vault.read.totalSupply();
    const heldAtStart = await held();
    await vault.write.activateLiquidation({ account: governanceClient.account });

    const me = attacker.account.address;
    assert.equal(await outcome(me, "claim", [0n, me, 0n]), "NothingToClaim");
    assert.equal(await outcome(me, "convertToClaims", [attackerShares + 1n]), "ERC20InsufficientBalance");
    await vault.write.convertToClaims([attackerShares], { account: attacker.account });
    assert.equal(await outcome(me, "claim", [0n, VAULT, 0n]), "InvalidRecipient");
    for (let i = 0n; i < BigInt(count); i++) await vault.write.claim([i, me, 0n], { account: attacker.account });
    assert.equal(await outcome(me, "claim", [0n, me, 0n]), "NothingToClaim");
    // A donation after claiming is shared pro rata: the attacker gets back only its part of it.
    const paxg = symbols.indexOf("PAXG");
    await erc20s[paxg].write.transfer([VAULT, heldAtStart[paxg] / 10n], { account: attacker.account });
    await vault.write.claim([BigInt(paxg), me, 0n], { account: attacker.account });
    const walletAfter = await balancesOf(me);

    await vault.write.convertToClaims([holderShares], { account: holderClient.account });
    const holderBefore = await balancesOf(holder);
    for (let i = 0n; i < BigInt(count); i++) await vault.write.claim([i, holder, 0n], { account: holderClient.account });
    const holderAfter = await balancesOf(holder);
    const leftover = await held();
    const rows = [];
    for (let i = 0; i < count; i++) {
      const fair = shareOf(holderShares, heldAtStart[i], supply);
      const got = holderAfter[i] - holderBefore[i];
      rows.push({ component: symbols[i], holderGot: got, holderFair: fair, attackerNet: walletAfter[i] - walletBefore[i], left: leftover[i] });
      assert.ok(got + tolerance(i) >= fair, `${symbols[i]}: the holder got ${got} of ${fair}`);
      assert.ok(walletAfter[i] <= walletBefore[i] + tolerance(i), `${symbols[i]}: the attacker gained`);
      assert.ok(leftover[i] <= 2n + tolerance(i), `${symbols[i]}: ${leftover[i]} left unclaimed`);
    }
    table(rows);
  });

  it("a few wei of GRET sent where nobody can move them hold back the holder's last GRET, and liquidation releases it (known limitation)", async () => {
    const me = attacker.account.address;
    // The smallest mint the components accept.
    let shares = 1n;
    while ((await outcome(me, "mint", [shares, me, maxIn(), 0n, await version()])) !== "ok") {
      shares *= 2n;
      assert.ok(shares <= ONE_GRET, "no small mint succeeded");
    }
    const walletBefore = await balancesOf(me);
    await vault.write.mint([shares, me, maxIn(), 0n, await version()], { account: attacker.account });
    const walletAfter = await balancesOf(me);
    const dust = await vault.read.balanceOf([me]);
    await vault.write.transfer([DEAD, dust], { account: attacker.account });
    console.log(`The attacker minted ${dust} wei of GRET and sent them to ${DEAD}, paying:`,
      Object.fromEntries(tokens.map((_, i) => [symbols[i], String(walletBefore[i] - walletAfter[i])])));

    const holderShares = await vault.read.balanceOf([holder]);
    const supply = await vault.read.totalSupply();
    assert.equal(await outcome(holder, "redeem", [holderShares, holder, [], 0n]), "SupplyBelowMinimum");

    const heldNow = await held();
    await vault.write.activateLiquidation({ account: governanceClient.account });
    await vault.write.convertToClaims([holderShares], { account: holderClient.account });
    const before = await balancesOf(holder);
    for (let i = 0n; i < BigInt(count); i++) await vault.write.claim([i, holder, 0n], { account: holderClient.account });
    const after = await balancesOf(holder);
    for (let i = 0; i < count; i++) {
      const fair = shareOf(holderShares, heldNow[i], supply);
      assert.ok(after[i] - before[i] + tolerance(i) >= fair, `${symbols[i]}: got ${after[i] - before[i]} of ${fair}`);
    }
  });

  // Moves the clock, so it runs last.
  it("a stolen governance key needs seven days to reach the reserves; holders who leave in time keep everything (known limitation)", async () => {
    for (const user of [bob, carol]) {
      await vault.write.mint([ONE_GRET, user.account.address, maxIn(), 0n, await version()], { account: user.account });
    }
    const bobShares = await vault.read.balanceOf([bob.account.address]);
    const carolShares = await vault.read.balanceOf([carol.account.address]);
    const bobQuote = await vault.read.previewRedeem([bobShares]);
    const carolQuote = await vault.read.previewRedeem([carolShares]);
    const thief = governanceClient.account;

    // Nothing governance can do at once moves a reserve.
    for (const token of tokens) {
      assert.equal(await outcome(thief.address, "rescue", [token, thief.address, 1n]), "BackingToken");
      assert.equal(await outcome(thief.address, "removeComponent", [token]), "ComponentNotEmpty");
      assert.equal(await outcome(thief.address, "deactivateEmptyComponent", [token]), "ComponentNotEmpty");
      assert.equal(await outcome(thief.address, "writeOffComponent", [token]), "NoPendingWriteOff");
    }
    assert.equal(await outcome(thief.address, "swap", [tokens[0], 1n, tokens[1], 1n, "0x"]), "NotRebalancer");

    // So it starts every delayed change at once: a rebalancer and a guard that accepts any swap,
    // the highest fees, and an eligibility contract that refuses everyone.
    const guard = await viem.deployContract("MockPriceGuard");
    const eligibility = await viem.deployContract("MockEligibility");
    await vault.write.setMintPaused([true], { account: thief });
    await vault.write.setFeeRecipient([thief.address], { account: thief });
    await vault.write.proposeFees([500n, 500n], { account: thief });
    await vault.write.proposeRebalancer([thief.address], { account: thief });
    await vault.write.proposePriceGuard([guard.address], { account: thief });
    await vault.write.proposeEligibility([eligibility.address], { account: thief });
    for (const fn of ["acceptRebalancer", "applyPriceGuard", "applyEligibility", "applyFees"]) {
      assert.equal(await outcome(thief.address, fn, []), "NotReady", fn);
    }
    assert.deepEqual(await vault.read.previewRedeem([bobShares]), bobQuote, "bob's share moved");

    // Bob sees the notices and leaves with his full share, without a fee.
    const bobBefore = await balancesOf(bob.account.address);
    await vault.write.redeem([bobShares, bob.account.address, bobQuote, await version()], { account: bob.account });
    const bobAfter = await balancesOf(bob.account.address);
    for (let i = 0; i < count; i++) {
      assert.ok(bobAfter[i] - bobBefore[i] + tolerance(i) >= bobQuote[i], `${symbols[i]}: bob got less than his share`);
    }

    // Carol stays. Seven days later the thief exchanges every reserve for a token's crumbs.
    await networkHelpers.time.increase(await vault.read.BASKET_CHANGE_DELAY());
    await vault.write.acceptRebalancer({ account: thief });
    await vault.write.applyPriceGuard();
    const crumbs = 1_000n;
    for (let i = 0; i < count; i++) {
      const next = (i + 1) % count;
      await fund(tokens[next], thief.address, crumbs);
      await erc20s[next].write.approve([VAULT, maxUint256], { account: thief });
      await vault.write.swap([tokens[i], await balanceOf(tokens[i], VAULT), tokens[next], crumbs, "0x"], { account: thief });
    }
    const carolAfter = await vault.read.previewRedeem([carolShares]);
    const rows = [];
    for (let i = 0; i < count; i++) {
      rows.push({ component: symbols[i], carolBefore: carolQuote[i], carolAfter: carolAfter[i] });
      assert.ok(carolAfter[i] * 100n <= carolQuote[i], `${symbols[i]}: carol kept more than 1%`);
    }
    table(rows);
  });
});
