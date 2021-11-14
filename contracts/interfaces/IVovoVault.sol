// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

interface IRegistry {
    function canWithdrawToVault(address fromVault, address toVault) external returns (bool);
}
