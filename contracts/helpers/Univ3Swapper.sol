// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';

contract Univ3Swapper {

    address public swapRouter;
    address public weth;

    constructor(address _swapRouter, address _weth) {
        swapRouter = _swapRouter;
        weth = _weth;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 poolFee1, uint256 poolFee2) external {
        TransferHelper.safeApprove(tokenIn, swapRouter, amountIn);

        ISwapRouter.ExactInputParams memory params =
        ISwapRouter.ExactInputParams({
        path: abi.encodePacked(tokenIn, uint24(poolFee1), weth, uint24(poolFee2), tokenOut),
        recipient: msg.sender,
        deadline: block.timestamp,
        amountIn: IERC20(tokenIn).balanceOf(address(this)),
        amountOutMinimum: 0
        });
        ISwapRouter(swapRouter).exactInput(params);

    }

}
