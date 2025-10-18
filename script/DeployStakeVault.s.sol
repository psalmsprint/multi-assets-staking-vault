// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {StakeVault} from "../src/StakeVault.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployStakeVault is Script {
    function run(HelperConfig helper) external returns (StakeVault, HelperConfig) {
        (address priceFeed, address usdcAddress) = helper.activeNetworkConfig();

        vm.startBroadcast();
        StakeVault vault = new StakeVault(priceFeed, usdcAddress);
        vm.stopBroadcast();

        return (vault, helper);
    }
}
