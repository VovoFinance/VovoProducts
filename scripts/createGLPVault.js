// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const { ethers, upgrades } = require("hardhat");

async function main() {
  const glpVaultContract = await ethers.getContractFactory("GlpVault");
  // const glpVault = await upgrades.deployProxy(glpVaultContract,
  //     ["Vovo BTC DOWN GLP", "vbdGLP", 18,
  //         "0x2f2a2543b76a4166549f7aab2e75bef0aefc5b0f", // underlying: weth
  //         "0x91190C9a02A8e5D1d20773dB1B1a152292dc70B2", // rewards
  //         "10", // leverage
  //         false, // isLong
  //         "500000000000000000000000", // cap: 0.5m glp
  //         "1000000000000000000" // underlying base: 1e18
  //         ], {initializer: 'initialize'}) // underlying base: 1e18])
  // await glpVault.deployed();
  // console.log("GLP Vault deployed to:", glpVault.address);
  // "Vovo ETH UP USDC" "veuUSDC" 6 "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8" "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1" "0x7f90122BF0700F9E7e1F688fe926940E8839F353" "0xbF7E49483881C76487b0989CD7d9A8239B20CA41" "0x1162f324D80AD5E37E23b3d363C89ABfc6F31339" "20" true "1000000000000" "1000000" "1000000000000000000"
    const glpVault = await upgrades.upgradeProxy("0x0FAE768Ef2191fDfCb2c698f691C49035A53eF0f", glpVaultContract);
    console.log("glpVault upgraded");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
