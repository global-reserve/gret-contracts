import assert from "node:assert/strict";
import { after, describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, getAddress, toHex, zeroAddress, zeroHash } from "viem";

import { deployBasket, INITIAL_SHARES, NO_MAX } from "./helpers/basket.js";

const DAY = 24n * 60n * 60n;
const TIMELOCK_DELAY = 2n * DAY;
const VAULT_GOVERNANCE_DELAY = 7n * DAY;

/**
 * Governance grows outside the vault: a multisig (here a plain account standing in for a Safe)
 * hands governance to an OpenZeppelin TimelockController, which later gains new proposers. The
 * vault is never redeployed or modified.
 */
describe("GRETVault: governance evolves without changing the vault", async () => {
  const connection = await network.create("hardhat");
  const { viem, networkHelpers } = connection;
  after(() => connection.close());

  let salt = 0;

  async function multisigFixture() {
    const basket = await deployBasket(viem);
    await basket.vault.write.mint([INITIAL_SHARES, NO_MAX, 0n, 0n], { account: basket.alice.account });
    // Only the multisig proposes and executes; the timelock administers itself. Executing must not
    // be open: anyone could otherwise wrap a ready sync between their own mint and redemption.
    const timelock = await viem.deployContract("TimelockController", [
      TIMELOCK_DELAY,
      [basket.governance.account.address],
      [basket.governance.account.address],
      zeroAddress,
    ]);
    const stray = await viem.deployContract("MockERC20", ["Stray", "STRAY", 6]);
    return { ...basket, multisig: basket.governance, timelock, stray };
  }

  type Setup = Awaited<ReturnType<typeof multisigFixture>>;

  /** Schedules a call through the timelock, waits the delay and has the multisig execute it. */
  async function throughTimelock(
    { timelock, multisig }: Setup,
    proposer: Setup["multisig"],
    target: `0x${string}`,
    data: `0x${string}`,
    delay = TIMELOCK_DELAY,
  ) {
    const operationSalt = toHex(++salt, { size: 32 });
    await timelock.write.schedule([target, 0n, data, zeroHash, operationSalt, delay], {
      account: proposer.account,
    });
    await networkHelpers.time.increase(delay);
    await timelock.write.execute([target, 0n, data, zeroHash, operationSalt], { account: multisig.account });
  }

  async function timelockFixture() {
    const setup = await multisigFixture();
    const { vault, multisig, timelock } = setup;
    await vault.write.proposeGovernance([timelock.address], { account: multisig.account });
    await throughTimelock(
      setup,
      multisig,
      vault.address,
      encodeFunctionData({ abi: vault.abi, functionName: "acceptGovernance" }),
      VAULT_GOVERNANCE_DELAY,
    );
    return setup;
  }

  it("the multisig hands governance to a timelock through the vault's two steps", async () => {
    const { vault, tokens, multisig, timelock } = await networkHelpers.loadFixture(timelockFixture);

    assert.equal(await vault.read.governance(), getAddress(timelock.address));
    await viem.assertions.revertWithCustomError(
      vault.write.sync([tokens[0].address], { account: multisig.account }),
      vault,
      "NotGovernance",
    );
  });

  it("the timelock exercises the vault powers only after its delay", async () => {
    const setup = await networkHelpers.loadFixture(timelockFixture);
    const { vault, multisig, timelock, stray, carol } = setup;
    await stray.write.mint([vault.address, 1_000n]);
    const rescue = encodeFunctionData({
      abi: vault.abi,
      functionName: "rescue",
      args: [stray.address, carol.account.address, 1_000n],
    });

    const operationSalt = toHex(++salt, { size: 32 });
    await timelock.write.schedule([vault.address, 0n, rescue, zeroHash, operationSalt, TIMELOCK_DELAY], {
      account: multisig.account,
    });
    await viem.assertions.revertWithCustomError(
      timelock.write.execute([vault.address, 0n, rescue, zeroHash, operationSalt], { account: multisig.account }),
      timelock,
      "TimelockUnexpectedOperationState",
    );
    await networkHelpers.time.increase(TIMELOCK_DELAY);
    await timelock.write.execute([vault.address, 0n, rescue, zeroHash, operationSalt], { account: multisig.account });
    assert.equal(await stray.read.balanceOf([carol.account.address]), 1_000n);

    // The emergency also waits the timelock delay while governance is only a timelock.
    await throughTimelock(
      setup,
      multisig,
      vault.address,
      encodeFunctionData({ abi: vault.abi, functionName: "activateLiquidation" }),
    );
    assert.equal(await vault.read.liquidationActive(), true);
  });

  it("only the multisig executes a ready sync, so nobody can wrap it in their own transaction", async () => {
    const { vault, tokens, multisig, timelock, bob } = await networkHelpers.loadFixture(timelockFixture);
    await tokens[0].write.mint([vault.address, 10n]);
    const sync = encodeFunctionData({ abi: vault.abi, functionName: "sync", args: [tokens[0].address] });
    const operationSalt = toHex(++salt, { size: 32 });
    await timelock.write.schedule([vault.address, 0n, sync, zeroHash, operationSalt, TIMELOCK_DELAY], {
      account: multisig.account,
    });
    await networkHelpers.time.increase(TIMELOCK_DELAY);

    await viem.assertions.revertWithCustomError(
      timelock.write.execute([vault.address, 0n, sync, zeroHash, operationSalt], { account: bob.account }),
      timelock,
      "AccessControlUnauthorizedAccount",
    );
    await timelock.write.execute([vault.address, 0n, sync, zeroHash, operationSalt], { account: multisig.account });
    assert.equal(await vault.read.componentSurplus([0n]), 0n);
  });

  it("only the timelock's proposers can schedule vault actions", async () => {
    const { vault, timelock, bob } = await networkHelpers.loadFixture(timelockFixture);

    await viem.assertions.revertWithCustomError(
      timelock.write.schedule(
        [
          vault.address,
          0n,
          encodeFunctionData({ abi: vault.abi, functionName: "activateLiquidation" }),
          zeroHash,
          zeroHash,
          TIMELOCK_DELAY,
        ],
        { account: bob.account },
      ),
      timelock,
      "AccessControlUnauthorizedAccount",
    );
  });

  it("a new proposer, such as a future Governor, is added inside the timelock", async () => {
    const setup = await networkHelpers.loadFixture(timelockFixture);
    const { vault, tokens, multisig, timelock, carol } = setup;
    const proposerRole = await timelock.read.PROPOSER_ROLE();

    await throughTimelock(
      setup,
      multisig,
      timelock.address,
      encodeFunctionData({ abi: timelock.abi, functionName: "grantRole", args: [proposerRole, carol.account.address] }),
    );

    await tokens[0].write.mint([vault.address, 10n]);
    await throughTimelock(
      setup,
      carol,
      vault.address,
      encodeFunctionData({ abi: vault.abi, functionName: "sync", args: [tokens[0].address] }),
    );
    assert.equal(await vault.read.componentSurplus([0n]), 0n);
    assert.equal(await vault.read.governance(), getAddress(timelock.address));
  });
});
