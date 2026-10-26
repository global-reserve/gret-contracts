import { readFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

import { createPublicClient, getAddress, http, isAddress, numberToHex, parseEther } from "viem";

import { PILOT } from "./config.js";
import {
  components,
  deployTransaction,
  governance,
  mintTransactions,
  type Reader,
  redeemTransaction,
  verifyVault,
  wallet,
  walletStatus,
} from "./plan.js";

/**
 * Local page to sign the pilot with MetaMask: `npm run pilot`, then open http://127.0.0.1:8787.
 *
 * This process only builds transactions with `plan.ts` and reads the chain; MetaMask signs in the
 * browser and no key ever reaches it. Chain 1 reads mainnet through MAINNET_RPC_URL or PublicNode.
 * Chain 31337 is the local mainnet fork from `npm run pilot:fork-node`, to rehearse with the same
 * MetaMask account: what is signed there cannot be replayed on mainnet.
 */
const PORT = 8787;
const LOCAL_NODE = "http://127.0.0.1:8545";
const RPC_URLS: Record<number, string> = {
  1: process.env.MAINNET_RPC_URL ?? "https://ethereum-rpc.publicnode.com",
  31337: LOCAL_NODE,
};
const page = readFileSync(new URL("./index.html", import.meta.url));

function readerFor(chainId: number): Reader {
  const url = RPC_URLS[chainId];
  if (url === undefined) throw new Error(`Unsupported network (chainId ${chainId}).`);
  return createPublicClient({ transport: http(url) }) as unknown as Reader;
}

function json(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(JSON.stringify(body, (_, value) => (typeof value === "bigint" ? value.toString() : value)));
}

async function localNodeCall(method: string, params: unknown[]) {
  const response = await fetch(LOCAL_NODE, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const body = (await response.json()) as { result?: unknown; error?: { message: string } };
  if (body.error) throw new Error(body.error.message);
  return body.result;
}

async function handle(req: IncomingMessage, res: ServerResponse) {
  const url = new URL(req.url ?? "/", `http://127.0.0.1:${PORT}`);
  if (req.method === "GET" && url.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
    res.end(page);
    return;
  }

  const chainId = Number(url.searchParams.get("chainId"));
  const vaultParam = url.searchParams.get("vault");
  if (vaultParam !== null && !isAddress(vaultParam)) return json(res, 400, { error: "Invalid vault address." });
  const vault = vaultParam === null ? undefined : getAddress(vaultParam);

  switch (`${req.method} ${url.pathname}`) {
    case "GET /api/config":
      return json(res, 200, {
        wallet,
        governance,
        pricedAt: PILOT.pricedAt,
        components: components.map((c) => ({
          symbol: c.symbol,
          address: c.address,
          decimals: c.decimals,
          weightPct: c.weightPct,
          priceUsd: c.priceUsd,
          perGret: c.perGret,
          amount: c.amount,
        })),
        deploy: deployTransaction(),
      });
    case "GET /api/status": {
      const client = readerFor(chainId);
      const status = await walletStatus(client, wallet, vault);
      const checks = vault === undefined ? undefined : await verifyVault(client, vault);
      return json(res, 200, { ...status, checks });
    }
    case "GET /api/mint":
      if (vault === undefined) return json(res, 400, { error: "Missing vault." });
      return json(res, 200, await mintTransactions(readerFor(chainId), vault, wallet));
    case "GET /api/redeem": {
      if (vault === undefined) return json(res, 400, { error: "Missing vault." });
      const tx = await redeemTransaction(readerFor(chainId), vault, wallet);
      return json(res, 200, { txs: tx === undefined ? [] : [tx] });
    }
    case "POST /api/fund": {
      // Rehearsal only: gives the pilot wallet test ETH on the local fork.
      if ((await localNodeCall("eth_chainId", [])) !== "0x7a69") {
        return json(res, 400, { error: "The local node is not the rehearsal fork (chainId 31337)." });
      }
      await localNodeCall("hardhat_setBalance", [wallet, numberToHex(parseEther("1"))]);
      return json(res, 200, { ok: true });
    }
    default:
      return json(res, 404, { error: "Not found." });
  }
}

createServer((req, res) => {
  handle(req, res).catch((error: Error & { shortMessage?: string }) => {
    json(res, 500, { error: error.shortMessage ?? error.message });
  });
}).listen(PORT, "127.0.0.1", () => {
  console.log(`Pilot page: http://127.0.0.1:${PORT}  (Ctrl+C to stop)`);
});
