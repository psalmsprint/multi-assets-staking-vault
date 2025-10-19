Multi-Asset Staking Vault

Contract Address (Sepolia):
 0x1a6CaF724343Fb02d0ADf5834Da00db83796aA76

A secure, modular staking vault supporting ETH and USDC deposits. Features include automated reward distribution, price deviation monitoring via Chainlink Automation, and enterprise-grade security with reentrancy protection.

🔑 Features

Dual Asset Support: Stake ETH and USDC.

Automated Rewards: Chainlink Automation for reward distribution.

Security: Reentrancy protection and cooldown periods.

Modular Design: Easily extendable for additional tokens or features.

⚙️ Tech Stack

Solidity: ^0.8.30

Foundry: Testing and development

Chainlink: Price feeds and automation

ERC-4626: Tokenized vault standard

ERC-20: USDC integration

🚀 Getting Started
1. Clone the Repository
git clone https://github.com/psalmsprint/multi-asset-staking-vault.git
cd multi-asset-staking-vault

2. Install Dependencies
forge install

3. Build the Contracts
forge build

4. Run Tests
forge test -vv

🌐 Deployment

Deploy to Sepolia using the following script:

export SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<KEY>"
forge script script/DeployStakeVault.s.sol:DeployStakeVault --rpc-url $SEPOLIA_RPC_URL --broadcast -vv


Ensure HelperConfig contains the correct addresses for price feeds and tokens.

🧪 Testing

Local Tests: Use Foundry's built-in testing suite.

Forked Network Tests: Run tests against Sepolia state by forking the network.

🛠️ Contributing

Contributions are welcome! Please fork the repository, create a branch, and submit a pull request with your changes.