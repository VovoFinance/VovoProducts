require("@nomiclabs/hardhat-waffle");
require('@openzeppelin/hardhat-upgrades');
require("@nomiclabs/hardhat-web3");
require("@nomiclabs/hardhat-etherscan");
// require("hardhat-gas-reporter");
const { infuraApiKey, infuraArbApiKey, kovankey, etherscanApiKey } = require('./secrets.json');

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

/**
 * @type import('hardhat/config').HardhatUserConfig
 */

module.exports = {
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      forking: {
        url: `https://arbitrum-mainnet.infura.io/v3/${infuraArbApiKey}`,
        blockNumber: 44750740,
        // gas: 2100000,
        // gasPrice: 8000000000,
        // allowUnlimitedContractSize: true
      }
      // gas: 12000000,
      // blockGasLimit: 0x1fffffffffffff,
      // allowUnlimitedContractSize: true,
    },
    kovan: {
      url: `https://kovan.infura.io/v3/${infuraApiKey}`,
      accounts: [`0x${kovankey}`]
    },
    rinkeby: {
      url: `https://rinkeby.infura.io/v3/${infuraApiKey}`,
      accounts: [`0x${kovankey}`]
    },
    arbitrum: {
      url: `https://arbitrum-mainnet.infura.io/v3/${infuraArbApiKey}`,
      accounts: [`0x${kovankey}`]
    }
  },
  etherscan: {
    apiKey:`${etherscanApiKey}`
  },
  solidity: {
    compilers: [{
      version: "0.7.6",
      settings: {
        optimizer: {
          enabled: true,
          runs: 200
        }
      }
    }]
  },
  mocha: {
    enableTimeouts: false,
    before_timeout: 120000 // Here is 2min but can be whatever timeout is suitable for you.
  }
}


