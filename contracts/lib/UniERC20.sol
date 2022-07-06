// SPDX-License-Identifier: MIT

// forked from: https://github.com/CryptoManiacsZone/mooniswap/blob/master/contracts/libraries/UniERC20.sol

pragma solidity ^0.7.0;

import '@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol';

library UniERC20 {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    function isETH(IERC20Upgradeable token) internal pure returns (bool) {
        return (token == IERC20Upgradeable(0));
    }

    function uniBalanceOf(IERC20Upgradeable token, address account) internal view returns (uint256) {
        if (isETH(token)) {
            return account.balance;
        } else {
            return token.balanceOf(account);
        }
    }

    function uniTransfer(
        IERC20Upgradeable token,
        address to,
        uint256 amount
    ) internal {
        if (amount > 0) {
            if (isETH(token)) {
                (bool success, ) = payable(to).call{value: amount}("");
                require(success, "Transfer failed");
            } else {
                token.safeTransfer(to, amount);
            }
        }
    }

    // After the usage of this method, using of msg.value inside the code might not be correct in a caller method if the msg.value is larger than amount.
    function uniTransferFromSenderToThis(IERC20Upgradeable token, uint256 amount) internal {
        if (amount > 0) {
            if (isETH(token)) {
                require(msg.value >= amount, "UniERC20: not enough value");
                if (msg.value > amount) {
                    // Return remainder if exist
                    uint256 refundAmount = msg.value.sub(amount);
                    (bool success, ) = msg.sender.call{value: refundAmount}("");
                    require(success, "Transfer failed");
                }
            } else {
                token.safeTransferFrom(msg.sender, address(this), amount);
            }
        }
    }
}
