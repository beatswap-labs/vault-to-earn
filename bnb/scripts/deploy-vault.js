const { ethers } = require("hardhat");
require("dotenv").config();

async function main() {
  const {
    USDT_ADDRESS,
    BTX_ADDRESS,
    PROJECT_TREASURY_ADDRESS,
    USDT_DEPOSIT_CAP
  } = process.env;

  if (!USDT_ADDRESS || !BTX_ADDRESS || !PROJECT_TREASURY_ADDRESS || !USDT_DEPOSIT_CAP) {
    throw new Error("Missing env vars: please set USDT_ADDRESS, BTX_ADDRESS, PROJECT_TREASURY_ADDRESS, USDT_DEPOSIT_CAP");
  }

  console.log("Deploying IPLicensingVault with:");
  console.log("  USDT              :", USDT_ADDRESS);
  console.log("  BTX               :", BTX_ADDRESS);
  console.log("  Project Treasury  :", PROJECT_TREASURY_ADDRESS);
  console.log("  USDT Deposit Cap  :", USDT_DEPOSIT_CAP);

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const Vault = await ethers.getContractFactory("IPLicensingVault");
  const vault = await Vault.deploy(
    USDT_ADDRESS,
    BTX_ADDRESS,
    PROJECT_TREASURY_ADDRESS,
    USDT_DEPOSIT_CAP
  );

  await vault.deployed();

  console.log("IPLicensingVault deployed to:", vault.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
