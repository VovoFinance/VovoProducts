// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const { ethers, upgrades } = require("hardhat");

async function main() {
  const ppvContract = await ethers.getContractFactory("PrincipalProtectedVault");
  const ppv = await upgrades.deployProxy(ppvContract,
      ["Vovo WBTC PPV", "voBTC", 8,
          "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f", // vaultoken: usdc
          "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f", // underlying: weth
          "0x3E01dD8a5E1fb3481F0F589056b428Fc308AF0Fb", // lpToken: _2crv
          "0xC2b1DF84112619D190193E48148000e3990Bf627", // gauge
          "0x1162f324D80AD5E37E23b3d363C89ABfc6F31339", // rewards
          "20", // leverage
          true, // isLong
          "10000000000", // cap: 100 wbtc
          "100000000", // vaultToken base: 1e8
          "1000000000000000000"], {initializer: 'initialize'}) // underlying base: 1e18])
  await ppv.deployed();
  console.log("PPV deployed to:", ppv.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
