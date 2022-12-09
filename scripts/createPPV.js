// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const { ethers, upgrades } = require("hardhat");

async function main() {
  const ppvContract = await ethers.getContractFactory("PrincipalProtectedVault");
  // const ppv = await upgrades.deployProxy(ppvContract,
  //     ["Vovo BTC DOWN USDC", "vbdUSDC", 6,
  //         "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8", // vaultoken: usdc
  //         "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f", // underlying: wbtc
  //         "0x7f90122BF0700F9E7e1F688fe926940E8839F353", // lpToken: _2crv
  //         "0xCE5F24B7A95e9cBa7df4B54E911B4A3Dc8CDAf6f", // gauge
  //         "0xabC000d88f23Bb45525E447528DBF656A9D55bf5", // gaugeFactory
  //         "0x1162f324D80AD5E37E23b3d363C89ABfc6F31339", // rewards
  //         "10", // leverage
  //         false, // isLong
  //         "500000000000", // cap: 1m usdc
  //         "1000000", // vaultToken base: 1e6
  //         "1000000000000000000",
  //         "0xBDfb17C2abbf9A9ee3817409B63D4101fc7015B0"], {initializer: 'initialize'}) // underlying base: 1e18])
  // await ppv.deployed();
  // console.log("PPV deployed to:", ppv.address);
  // "Vovo ETH UP USDC" "veuUSDC" 6 "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8" "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1" "0x7f90122BF0700F9E7e1F688fe926940E8839F353" "0xbF7E49483881C76487b0989CD7d9A8239B20CA41" "0x1162f324D80AD5E37E23b3d363C89ABfc6F31339" "20" true "1000000000000" "1000000" "1000000000000000000"

    const ppv = await upgrades.upgradeProxy("0x1704A75bc723A018D176Dc603b0D1a361040dF16", ppvContract);
    console.log("ppv upgraded");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
