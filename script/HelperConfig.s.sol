// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "@chainlink/src/v0.8/tests/MockV3Aggregator.sol";
import {ERC20Mock} from "../test/mocks/Erc20Mocks.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address priceFeed;
        address usdcAddress;
    }

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaConfig();
        } else if (block.chainid == 1) {
            activeNetworkConfig = getMiannetETHConfig();
        } else if (block.chainid == 84532) {
            activeNetworkConfig = getBaseSepoliaConfig();
        } else if (block.chainid == 8453) {
            activeNetworkConfig = getBaseMainnetConfig();
        } else {
            activeNetworkConfig = getAnvilConfig();
        }
    }

    function getSepoliaConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory sepolia = NetworkConfig({
            priceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            usdcAddress: 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8
        });

        return sepolia;
    }

    function getMiannetETHConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory mainnetETH = NetworkConfig({
            priceFeed: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,
            usdcAddress: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        });

        return mainnetETH;
    }

    function getBaseSepoliaConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory baseSepolia = NetworkConfig({
            priceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            usdcAddress: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
        });

        return baseSepolia;
    }

    function getBaseMainnetConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory baseMinnetConfig = NetworkConfig({
            priceFeed: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70,
            usdcAddress: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
        });

        return baseMinnetConfig;
    }

    function getAnvilConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.priceFeed != address(0)) {
            return activeNetworkConfig;
        }

        uint8 decimals = 8;
        int256 initialAnswer = 4500e8;

        vm.startBroadcast();
        MockV3Aggregator mockPriceFeed = new MockV3Aggregator(decimals, initialAnswer);

        ERC20Mock mockUSDC = new ERC20Mock();
        vm.stopBroadcast();

        NetworkConfig memory anvilConfig =
            NetworkConfig({priceFeed: address(mockPriceFeed), usdcAddress: address(mockUSDC)});

        return anvilConfig;
    }
}
