import { readFileSync } from "node:fs";

import {
  type Abi,
  type Address,
  encodeDeployData,
  encodeFunctionData,
  erc20Abi,
  formatUnits,
  getAddress,
  type Hex,
  parseUnits,
  type PublicClient,
  zeroAddress,
} from "viem";

import { PILOT } from "./config.js";

/**
 * Builds and checks the pilot transactions. The local page (`server.ts`) sends exactly what this
 * module returns, and `test-fork/GRETVault.pilot.ts` rehearses the same transactions on a fork.
 */

const artifact = JSON.parse(
  readFileSync(new URL("../../artifacts/contracts/GRETVault.sol/GRETVault.json", import.meta.url), "utf8"),
) as { abi: Abi; bytecode: Hex; deployedBytecode: Hex };

export const vaultAbi = artifact.abi;
export const INITIAL_SHARES = 10n ** 18n;

export type Reader = Pick<PublicClient, "readContract" | "getBalance" | "getCode">;

export interface PlannedTx {
  label: string;
  /** Absent for the deployment. */
  to?: Address;
  data: Hex;
}

export const components = PILOT.components.map((component) => ({
  ...component,
  address: getAddress(component.address),
  amount: parseUnits(component.perGret, component.decimals),
}));

export const governance = getAddress(PILOT.governance);
export const wallet = getAddress(PILOT.wallet);

export function deployTransaction(): PlannedTx {
  return {
    label: "Deploy GRETVault",
    data: encodeDeployData({
      abi: vaultAbi,
      bytecode: artifact.bytecode,
      args: [components.map((c) => c.address), components.map((c) => c.amount), governance],
    }),
  };
}

const readVault = <T>(client: Reader, vault: Address, functionName: string, args: readonly unknown[] = []) =>
  client.readContract({ address: vault, abi: vaultAbi, functionName, args }) as Promise<T>;

/** Each parameter the deployed vault reports, compared with the pilot configuration. */
export async function verifyVault(client: Reader, vault: Address) {
  const [code, onChainComponents, amounts, onChainGovernance, rebalancer, mintFee, redeemFee, mintPaused, name, symbol] =
    await Promise.all([
      client.getCode({ address: vault }),
      readVault<Address[]>(client, vault, "components"),
      readVault<bigint[]>(client, vault, "initialAmounts"),
      readVault<Address>(client, vault, "governance"),
      readVault<Address>(client, vault, "rebalancer"),
      readVault<bigint>(client, vault, "mintFee"),
      readVault<bigint>(client, vault, "redeemFee"),
      readVault<boolean>(client, vault, "mintPaused"),
      readVault<string>(client, vault, "name"),
      readVault<string>(client, vault, "symbol"),
    ]);
  return [
    {
      label: "Code identical to this repository's build",
      ok: code?.toLowerCase() === artifact.deployedBytecode.toLowerCase(),
    },
    {
      label: "The 11 components, in order",
      ok:
        onChainComponents.length === components.length &&
        onChainComponents.every((address, i) => getAddress(address) === components[i].address),
    },
    {
      label: "Amounts in 1 GRET",
      ok: amounts.length === components.length && amounts.every((amount, i) => amount === components[i].amount),
    },
    { label: "Governance", ok: getAddress(onChainGovernance) === governance },
    { label: "No rebalancer: nobody can swap reserves yet", ok: rebalancer === zeroAddress },
    { label: "Mint and redemption fees at zero", ok: mintFee === 0n && redeemFee === 0n },
    { label: "Minting not paused", ok: mintPaused === false },
    { label: "Name and symbol", ok: name === "Global Reserve Token" && symbol === "GRET" },
  ];
}

/** Balances of the pilot wallet and, once deployed, its position in the vault. */
export async function walletStatus(client: Reader, account: Address, vault?: Address) {
  const balances = await Promise.all(
    components.map((c) =>
      client.readContract({ address: c.address, abi: erc20Abi, functionName: "balanceOf", args: [account] }),
    ),
  );
  const eth = await client.getBalance({ address: account });
  if (vault === undefined) return { eth, balances };
  const [gret, supply, hasMinted, reserves] = await Promise.all([
    readVault<bigint>(client, vault, "balanceOf", [account]),
    readVault<bigint>(client, vault, "totalSupply"),
    readVault<boolean>(client, vault, "hasMinted", [account]),
    readVault<bigint[]>(client, vault, "reserves"),
  ]);
  return { eth, balances, vault: { gret, supply, hasMinted, reserves } };
}

/**
 * Approvals still missing and the mint of `shares` GRET, paying at most what the vault asks
 * today and receiving at least `shares` minus 0.1%, which covers the few wei xStocks lose per
 * transfer. Approvals are for that exact amount, never unlimited.
 */
export async function mintTransactions(client: Reader, vault: Address, account: Address, shares = INITIAL_SHARES) {
  const needed = await readVault<bigint[]>(client, vault, "previewMint", [shares]);
  const version = await readVault<bigint>(client, vault, "basketVersion");
  const txs: PlannedTx[] = [];
  for (const [i, c] of components.entries()) {
    const allowance = await client.readContract({
      address: c.address,
      abi: erc20Abi,
      functionName: "allowance",
      args: [account, vault],
    });
    if (allowance < needed[i]) {
      txs.push({
        label: `Approve ${formatUnits(needed[i], c.decimals)} ${c.symbol}`,
        to: c.address,
        data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [vault, needed[i]] }),
      });
    }
  }
  txs.push({
    label: `Mint ${formatUnits(shares, 18)} GRET`,
    to: vault,
    data: encodeFunctionData({
      abi: vaultAbi,
      functionName: "mint",
      args: [shares, needed, shares - shares / 1000n, version],
    }),
  });
  return { needed, txs };
}

/** Redemption of all the account's GRET, requiring at least what the vault pays today. */
export async function redeemTransaction(client: Reader, vault: Address, account: Address) {
  const shares = await readVault<bigint>(client, vault, "balanceOf", [account]);
  if (shares === 0n) return undefined;
  const out = await readVault<bigint[]>(client, vault, "previewRedeem", [shares]);
  const version = await readVault<bigint>(client, vault, "basketVersion");
  return {
    label: `Redeem ${formatUnits(shares, 18)} GRET`,
    to: vault,
    data: encodeFunctionData({ abi: vaultAbi, functionName: "redeem", args: [shares, out, version] }),
  } satisfies PlannedTx;
}
