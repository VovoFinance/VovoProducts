// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

interface IGlpManager {
    function getAum(bool maximise) external view returns (uint256);
}

