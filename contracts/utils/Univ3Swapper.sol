// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';

contract Univ3Swapper {

    address public swapRouter;
    address public weth;
    uint24 public poolFee1;
    uint24 public poolFee2 ;

    constructor(address _swapRouter, address _weth, uint24 _poolFee1, uint24 _poolFee2) {
        swapRouter = _swapRouter;
        weth = _weth;
        poolFee1 = _poolFee1;
        poolFee2 = _poolFee2;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn) external {
        TransferHelper.safeApprove(tokenIn, swapRouter, amountIn);

        ISwapRouter.ExactInputParams memory params =
        ISwapRouter.ExactInputParams({
        path: abi.encodePacked(tokenIn, poolFee1, weth, poolFee2, tokenOut),
        recipient: msg.sender,
        deadline: block.timestamp,
        amountIn: amountIn,
        amountOutMinimum: 0
        });
        ISwapRouter(swapRouter).exactInput(params);
    }

}
