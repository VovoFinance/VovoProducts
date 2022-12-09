const { ethers } = require("hardhat");


async function main() {
    // We get the contract to deploy
    const VaultRouter = await ethers.getContractFactory("VaultRouter");
    const vaultRouter = await VaultRouter.deploy("0x9ba57a1D3f6C61Ff500f598F16b97007EB02E346", "0x5D8a5599D781CC50A234D73ac94F4da62c001D8B", "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8",
        "0xbFbEe90E2A96614ACe83139F41Fa16a2079e8408", "0x0FAE768Ef2191fDfCb2c698f691C49035A53eF0f", "0x2F546AD4eDD93B956C8999Be404cdCAFde3E89AE");
    console.log("ppvRouter deployed to:", vaultRouter.address);
}

main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
