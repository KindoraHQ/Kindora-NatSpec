require("@nomiclabs/hardhat-ethers");
require("solidity-coverage");

module.exports = {
  solidity: {
    version: "0.8.17",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  mocha: {
    timeout: 120000
  }
};
