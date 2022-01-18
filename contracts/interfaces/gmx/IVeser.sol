// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

interface IVester {
    function getPairAmount(address _account, uint256 _esAmount) public view returns (uint256);
}

