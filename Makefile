-include .env

.PHONY: all test clean deploy help install format anvil coverage

DEFAULT_ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

help:
	@echo "Common commands:"
	@echo "  make install       - Install dependencies"
	@echo "  make build         - Compile contracts"
	@echo "  make test          - Run tests"
	@echo "  make deploy-sepolia - Deploy to Sepolia"
	@echo ""
	@echo "Interactions:"
	@echo "  make stake-eth VAULT_ADDRESS=0x... AMOUNT=1ether"
	@echo "  make get-balance VAULT_ADDRESS=0x... USER_ADDRESS=0x..."

all: clean install build

clean:; forge clean

install:; forge install cyfrin/foundry-devops@0.2.2 --no-commit && forge install smartcontractkit/chainlink-brownie-contracts@1.1.1 --no-commit && forge install foundry-rs/forge-std@v1.8.2 --no-commit && forge install transmissions11/solmate@v6 --no-commit

build:; forge build

test:; forge test 

test-v:; forge test -vvv

format:; forge fmt

anvil:; anvil -m 'test test test test test test test test test test test junk' --steps-tracing --block-time 1

coverage:; forge coverage

gas-report:; forge test --gas-report

# Deployment
NETWORK_ARGS := --rpc-url http://localhost:8545 --private-key $(DEFAULT_ANVIL_KEY) --broadcast

ifeq ($(findstring --network sepolia,$(ARGS)),--network sepolia)
	NETWORK_ARGS := --rpc-url $(SEPOLIA_RPC_URL) --account defaultKey --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
endif

deploy:
	@forge script script/DeployStakingVault.s.sol:DeployStakingVault $(NETWORK_ARGS)

deploy-sepolia:
	@forge script script/DeployStakingVault.s.sol:DeployStakingVault --rpc-url $(SEPOLIA_RPC_URL) --account defaultKey --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv

# Interactions
stake-eth:
	@cast send $(VAULT_ADDRESS) "depositETH()" --value $(AMOUNT) --rpc-url $(RPC_URL) --account defaultKey

stake-usdc:
	@cast send $(VAULT_ADDRESS) "depositUSDC(uint256)" $(AMOUNT) --rpc-url $(RPC_URL) --account defaultKey

get-balance:
	@cast call $(VAULT_ADDRESS) "getETHBalanceOfUser(address)" $(USER_ADDRESS) --rpc-url $(RPC_URL)

get-usdc-balance:
	@cast call $(VAULT_ADDRESS) "getUSDCBalanceOfDepositor(address)" $(USER_ADDRESS) --rpc-url $(RPC_URL)

get-rewards:
	@cast call $(VAULT_ADDRESS) "_pendingReward(address)" $(USER_ADDRESS) --rpc-url $(RPC_URL)

unstake:
	@cast send $(VAULT_ADDRESS) "unStake()" --rpc-url $(RPC_URL) --account defaultKey

withdraw-eth:
	@cast send $(VAULT_ADDRESS) "withdraw(uint8)" 0 --rpc-url $(RPC_URL) --account defaultKey

withdraw-usdc:
	@cast send $(VAULT_ADDRESS) "withdraw(uint8)" 1 --rpc-url $(RPC_URL) --account defaultKey