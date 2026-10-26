import assert from "node:assert/strict";
import { after, describe, it } from "node:test";

import { network } from "hardhat";
import { parseUnits } from "viem";

describe("MockERC20: local component scaffolding", async () => {
  const connection = await network.create("hardhat");
  const { viem, networkHelpers } = connection;
  after(() => connection.close());

  async function deployComponents() {
    const [holder, spender, recipient] = await viem.getWalletClients();
    const token18 = await viem.deployContract("MockERC20", [
      "Mock Component 18",
      "MOCK18",
      18,
    ]);
    const token8 = await viem.deployContract("MockERC20", [
      "Mock Component 8",
      "MOCK8",
      8,
    ]);

    return { token18, token8, holder, spender, recipient };
  }

  it("deploys components with 18 and 8 decimals and no initial supply", async () => {
    const { token18, token8 } = await networkHelpers.loadFixture(deployComponents);

    assert.equal(await token18.read.decimals(), 18);
    assert.equal(await token8.read.decimals(), 8);
    assert.equal(await token18.read.totalSupply(), 0n);
    assert.equal(await token8.read.totalSupply(), 0n);
  });

  it("mints the same human amount using each component's base units", async () => {
    const { token18, token8, holder } = await networkHelpers.loadFixture(deployComponents);

    for (const [token, decimals] of [[token18, 18], [token8, 8]] as const) {
      const amount = parseUnits("1.25", decimals);
      await token.write.mint([holder.account.address, amount]);

      assert.equal(await token.read.balanceOf([holder.account.address]), amount);
      assert.equal(await token.read.totalSupply(), amount);
    }
  });

  it("supports the approval and transferFrom flow needed by a future vault", async () => {
    const { token8, holder, spender, recipient } = await networkHelpers.loadFixture(deployComponents);
    const amount = parseUnits("0.25", 8);

    await token8.write.mint([holder.account.address, amount]);
    await token8.write.approve([spender.account.address, amount]);
    await token8.write.transferFrom(
      [holder.account.address, recipient.account.address, amount],
      { account: spender.account },
    );

    assert.equal(await token8.read.balanceOf([holder.account.address]), 0n);
    assert.equal(await token8.read.balanceOf([recipient.account.address]), amount);
    assert.equal(await token8.read.allowance([holder.account.address, spender.account.address]), 0n);
    assert.equal(await token8.read.totalSupply(), amount);
  });

  it("rejects transferFrom without approval and preserves balances", async () => {
    const { token18, holder, spender, recipient } = await networkHelpers.loadFixture(deployComponents);
    const amount = parseUnits("1", 18);
    await token18.write.mint([holder.account.address, amount]);

    await viem.assertions.revertWithCustomErrorWithArgs(
      token18.write.transferFrom(
        [holder.account.address, recipient.account.address, amount],
        { account: spender.account },
      ),
      token18,
      "ERC20InsufficientAllowance",
      [spender.account.address, 0n, amount],
    );

    assert.equal(await token18.read.balanceOf([holder.account.address]), amount);
    assert.equal(await token18.read.balanceOf([recipient.account.address]), 0n);
  });
});
