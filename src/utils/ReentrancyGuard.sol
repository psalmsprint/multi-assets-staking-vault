// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

error StakeVault__Reentrance();

abstract contract ReentrancyGuard {
    uint256 private constant NON_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private status = NON_ENTERED;

    modifier nonReentrancy() {
        if (status == ENTERED) {
            revert StakeVault__Reentrance();
        }

        status = ENTERED;
        _;

        status = NON_ENTERED;
    }
}
