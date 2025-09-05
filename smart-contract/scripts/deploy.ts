import { ethers } from "hardhat";

export async function deployContracts() {
  const [deployer] = await ethers.getSigners();
  // console.log("Deploying with:", deployer.address);

  const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
  const initialSupply = ethers.parseUnits("1000000", 6);
  const usdt = await ERC20Mock.deploy(
    "Tether USD",
    "USDT",
    6,
    deployer.address,
    initialSupply
  );
  await usdt.waitForDeployment();
  const usdtAddress = await usdt.getAddress();
  // console.log("Mock USDT deployed to:", usdtAddress);

  const Market = await ethers.getContractFactory("Market");
  const market = await Market.deploy(usdtAddress);
  await market.waitForDeployment();
  const marketAddress = await market.getAddress();
  // console.log("Market deployed to:", marketAddress);

  return { deployer, usdt, usdtAddress, market, marketAddress };
}

async function main() {
  const { marketAddress } = await deployContracts();
  return marketAddress;
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
