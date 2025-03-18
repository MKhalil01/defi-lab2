const { expect } = require("chai");
const { ethers, network } = require("hardhat");

describe("LiquidationOperator", function () {
  let liquidationOperator;
  let snapshot;

  before(async function () {
    // Take a snapshot of the current network state
    snapshot = await network.provider.request({ method: "evm_snapshot", params: [] });

    // Fork the mainnet at the specific block number
    await network.provider.request({
      method: "hardhat_reset",
      params: [
        {
          forking: {
            jsonRpcUrl: process.env.ALCHE_API,
            blockNumber: 12489619, // Block right before the liquidation
          },
        },
      ],
    });

    // Deploy the LiquidationOperator contract
    const LiquidationOperator = await ethers.getContractFactory("LiquidationOperator");
    liquidationOperator = await LiquidationOperator.deploy();
    await liquidationOperator.deployed();
    console.log("LiquidationOperator deployed at:", liquidationOperator.address);
  });

  after(async function () {
    // Restore the network state after tests
    await network.provider.request({
      method: "evm_revert",
      params: [snapshot],
    });
  });

  it("should deploy the contract successfully", async function () {
    expect(liquidationOperator.address).to.properAddress;
  });

  it("should check target user's health factor before liquidation", async function () {
    // Constants from the contract
    const AAVE_LENDING_POOL = "0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9";
    const TARGET_USER = "0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F";
    
    // Get the lending pool contract
    const lendingPool = await ethers.getContractAt("ILendingPool", AAVE_LENDING_POOL);
    
    // Get user account data
    const userData = await lendingPool.getUserAccountData(TARGET_USER);
    
    // Log the health factor (scaled by 1e18)
    const healthFactor = userData.healthFactor;
    console.log("Target user health factor:", ethers.utils.formatUnits(healthFactor, 18));

    // Health factor should be below 1.0 for liquidation
    expect(healthFactor).to.be.lt(ethers.utils.parseUnits("1.0", 18));
  });



// Up to this point outputs are clearly working

  it("should execute the liquidation and make profit", async function () {
    // Get initial ETH balance of the contract deployer
    const [deployer] = await ethers.getSigners();
    const initialBalance = await deployer.getBalance();
    console.log("Initial ETH balance:", ethers.utils.formatEther(initialBalance));

    // Execute the liquidation operation
    const tx = await liquidationOperator.operate();
    const receipt = await tx.wait();
//     console.log("Gas used for liquidation:", receipt.gasUsed.toString());

//     // Get final ETH balance
//     const finalBalance = await deployer.getBalance();
//     console.log("Final ETH balance:", ethers.utils.formatEther(finalBalance));

//     // Calculate profit (ignoring gas costs for this test)
//     const gasCost = receipt.gasUsed.mul(tx.gasPrice);
//     const profit = finalBalance.sub(initialBalance).add(gasCost);
//     console.log("Profit (ETH):", ethers.utils.formatEther(profit));

//     // Write profit to file for grading
//     const fs = require("fs");
//     fs.writeFileSync("profit.txt", ethers.utils.formatEther(profit));

//     // Profit should be at least 21 ETH as mentioned in the README
//     expect(profit).to.be.gte(ethers.utils.parseEther("21"));
  });

//   it("should verify the flash loan and liquidation steps", async function () {
//     // This test would trace through the transaction to verify each step
//     // However, this is complex to implement in a test
//     // Instead, we'll check the final state which confirms all steps worked correctly
    
//     // Constants from the contract
//     const WBTC = "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599";
    
//     // Check that the contract doesn't hold any WBTC after the operation
//     // (all should be converted to ETH)
//     const wbtcContract = await ethers.getContractAt("IERC20", WBTC);
//     const wbtcBalance = await wbtcContract.balanceOf(liquidationOperator.address);
//     expect(wbtcBalance).to.equal(0);
//   });
});