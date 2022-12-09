const { ethers } = require("hardhat");

async function main() {
    const Univ3Swapper = await ethers.getContractFactory("Univ3Swapper");
    const univ3Swapper = await Univ3Swapper.deploy( "0xE592427A0AEce92De3Edee1F18E0157C05861564", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1", 3000, 500);
    await univ3Swapper.deployed();
    console.log("Univ3Swapper deployed to:", univ3Swapper.address);
}

main();
