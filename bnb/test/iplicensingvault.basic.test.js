const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("IPLicensingVault basic flows", function () {
  async function deployFixture() {
    const [deployer, user, treasury] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdt = await MockERC20.deploy("Mock USDT", "mUSDT", ethers.utils.parseUnits("1000000", 18));
    const btx = await MockERC20.deploy("Mock BTX", "mBTX", ethers.utils.parseUnits("1000000", 18));

    const Vault = await ethers.getContractFactory("IPLicensingVault");
    const depositCap = ethers.utils.parseUnits("1000", 18);

    const vault = await Vault.deploy(
      usdt.address,
      btx.address,
      treasury.address,
      depositCap
    );

    // Send USDT to the user
    await usdt.transfer(user.address, ethers.utils.parseUnits("1000", 18));

    return { deployer, user, treasury, usdt, btx, vault, depositCap };
  }

  it("deposits and updates reservedTotal", async function () {
    const { user, usdt, vault } = await deployFixture();

    const amount = ethers.utils.parseUnits("100", 18);
    await usdt.connect(user).approve(vault.address, amount);

    await expect(vault.connect(user).deposit(amount))
      .to.emit(vault, "Deposit")
      .withArgs(user.address, amount);

    const info = await vault.accountInfoRaw(user.address);
    expect(info.balance).to.equal(amount);
    expect(info.reservedTotal).to.equal(amount);
    expect(info.reservedConsumed).to.equal(0);
  });

  it("cannot withdraw more than withdrawable + royalty buffer", async function () {
    const { user, usdt, vault } = await deployFixture();

    const amount = ethers.utils.parseUnits("100", 18);
    await usdt.connect(user).approve(vault.address, amount);
    await vault.connect(user).deposit(amount);

    // Immediately after deposit, reservedTotal equals balance, so withdrawable is 0.
    await expect(
      vault.connect(user).withdraw(amount)
    ).to.be.revertedWithCustomError(vault, "ErrInsufficient");
  });

  it("increaseReserved reduces withdrawable", async function () {
    const { user, usdt, vault } = await deployFixture();

    const amount = ethers.utils.parseUnits("200", 18);
    await usdt.connect(user).approve(vault.address, amount);
    await vault.connect(user).deposit(amount);

    // reservedTotal == balance, withdrawable == 0
    let withdrawable = await vault.withdrawableOf(user.address);
    expect(withdrawable).to.equal(0);

    // When you call decreaseReserved to partially release the reserve, a withdrawable amount becomes available.
    const decrease = ethers.utils.parseUnits("50", 18);
    await vault.connect(user).decreaseReserved(decrease);

    withdrawable = await vault.withdrawableOf(user.address);
    expect(withdrawable).to.equal(decrease);
  });
});
