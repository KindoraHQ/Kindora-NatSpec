// Minimal Hardhat config snippet with multiple compiler versions.
// Merge with your existing config; ensure you keep networks/plugins after merging.
require("@nomiclabs/hardhat-ethers");
require("@nomiclabs/hardhat-waffle");

module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.20",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
      {
        version: "0.6.6",
        settings: {
          optimizer: { enabled: true, runs: 200 }
        }
      },
      {
        version: "0.5.16",
        settings: {
          optimizer: { enabled: true, runs: 200 }
        }
      }
    ]
  },
  // keep your existing networks, paths, and plugin configs here
};
