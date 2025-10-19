// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20Mock is ERC20 {
    address public blockedReceiver;
    
    constructor() ERC20("ERC20Mock", "E20M") {}
    
    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
    
    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
    
    function setBlockedReceiver(address _blocked) external {
        blockedReceiver = _blocked;
    }
    
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == blockedReceiver) {
            return false;
        }
        return super.transfer(to, amount);
    }
    
}