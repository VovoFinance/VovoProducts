// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

interface IVovoVault {
    /**
     * @notice Deposit token to this vault. The vault mints shares to the depositor.
     * @param amount is the amount of token deposited
     */
    function deposit(uint256 amount) external;
}
