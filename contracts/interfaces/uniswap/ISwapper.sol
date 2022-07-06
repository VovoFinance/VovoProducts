// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

interface ISwapper {
    function swap(address tokenIn, address tokenOut, uint256 amountIn) external returns(uint256 amountOut);
}
