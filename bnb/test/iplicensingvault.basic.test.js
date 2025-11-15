const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("IPLicensingVault basic flows", function () {
  async function deployFixture() {
    const [deployer, user, treasury] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdt = await MockERC20.deploy(
      "Mock USDT",
      "mUSDT",
      ethers.parseUnits("1000000", 18)
    );
    await usdt.waitForDeployment();

    const btx = await MockERC20.deploy(
      "Mock BTX",
      "mBTX",
      ethers.parseUnits("1000000", 18)
    );
    await btx.waitForDeployment();

    const Vault = await ethers.getContractFactory("IPLicensingVault");
    const depositCap = ethers.parseUnits("1000", 18);

    const vault = await Vault.deploy(
      usdt.target,
      btx.target,
      treasury.address,
      depositCap
    );
    await vault.waitForDeployment();

    const usdtAddress = await usdt.getAddress();
    await usdt.transfer(user.address, ethers.parseUnits("1000", 18));

    return { deployer, user, treasury, usdt, btx, vault, depositCap };
  }

  it("deposits and updates reservedTotal", async function () {
    const { user, usdt, vault } = await deployFixture();

    const amount = ethers.parseUnits("100", 18);
    await usdt.connect(user).approve(vault.target, amount);

    await expect(vault.connect(user).deposit(amount))
      .to.emit(vault, "Deposit")
      .withArgs(user.address, amount);

    const info = await vault.accountInfoRaw(user.address);
    expect(info.balance).to.equal(amount);
    expect(info.reservedTotal).to.equal(amount);
    expect(info.reservedConsumed).to.equal(0n);
  });
});
