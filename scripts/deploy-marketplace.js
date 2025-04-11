const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // Deploy Marketplace first
  const Marketplace = await hre.ethers.getContractFactory("Marketplace");
  // You need to replace these parameters with actual values:
  // 1. BLR token address on BSC testnet
  // 2. Trading fee (e.g., 100 for 1%)
  // 3. Initially set to zero address, will update after FactoryPool deployment
  const marketplace = await Marketplace.deploy(
    "0x0000000000000000000000000000000000000000", // Replace with actual BLR token address
    100, // 1% trading fee
    "0x0000000000000000000000000000000000000000" // Temporary FactoryPool address
  );
  await marketplace.deployed();
  console.log("Marketplace deployed to:", marketplace.address);

  // Deploy FactoryPool
  const FactoryPool = await hre.ethers.getContractFactory("PoolFactory");
  const factoryPool = await FactoryPool.deploy(marketplace.address);
  await factoryPool.deployed();
  console.log("FactoryPool deployed to:", factoryPool.address);

  // Update FactoryPool address in Marketplace
  const tx = await marketplace.setPoolFactory(factoryPool.address);
  await tx.wait();
  console.log("Updated FactoryPool address in Marketplace");

  console.log("Deployment completed!");
  console.log("Marketplace:", marketplace.address);
  console.log("FactoryPool:", factoryPool.address);

  // Verify contracts on BSCScan
  console.log("\nVerifying contracts on BSCScan...");
  try {
    await hre.run("verify:verify", {
      address: marketplace.address,
      constructorArguments: [
        "0x0000000000000000000000000000000000000000", // Replace with actual BLR token address
        100,
        factoryPool.address
      ],
    });
    console.log("Marketplace verified!");
  } catch (error) {
    console.error("Error verifying Marketplace:", error);
  }

  try {
    await hre.run("verify:verify", {
      address: factoryPool.address,
      constructorArguments: [marketplace.address],
    });
    console.log("FactoryPool verified!");
  } catch (error) {
    console.error("Error verifying FactoryPool:", error);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 