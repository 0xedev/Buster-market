const HDWalletProvider = require("@truffle/hdwallet-provider");
const fs = require("fs");
const mnemonic = fs.readFileSync(".secret").toString().trim();

module.exports = {
  networks: {
    development: {
      host: "localhost",
      port: 8545,
      network_id: "*",
    },
    BASE: {
      provider: () =>
        new HDWalletProvider(
          mnemonic,
          //changes to your own wallet mnemonic and infura project id
          `https://base-mainnet.g.alchemy.com/v2/jprc9bb4eoqJdv5K71YUZdhKyf20gILa`
        ),
      network_id: 8453,
      confirmations: 2,
      timeoutBlocks: 200,
      skipDryRun: true,
      chainId: 8453,
    },
  },
  contracts_directory: "./contracts",
  contracts_build_directory: "./abis",
  compilers: {
    solc: {
      version: "^0.8.6",
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },

  db: {
    enabled: false,
  },
};
