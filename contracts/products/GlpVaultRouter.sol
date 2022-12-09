// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import "../interfaces/IGlpVault.sol";
import "../interfaces/gmx/IStakedGlp.sol";

contract GlpVaultRouter {

    address public upVault;
    address public downVault;
    address public vaultToken;

    event DepositGlp(address indexed depositor, address indexed account, uint256 upVaultAmount, uint256 downVaultAmount);
    event WithdrawGlp(address indexed account, uint256 amount, uint256 upVaultShares, uint256 downVaultShare);

    constructor(address _upVault, address _downVault, address _vaultToken) public {
        upVault = _upVault;
        downVault = _downVault;
        vaultToken = _vaultToken;
    }

    function depositFor(uint256 upVaultAmount, uint256 downVaultAmount, address account) external {
        IGlpVault(upVault).depositGlpFor(upVaultAmount, account);
        IGlpVault(downVault).depositGlpFor(downVaultAmount, account);
        emit DepositGlp(msg.sender, account, upVaultAmount, downVaultAmount);
    }

    function withdraw(uint256 upVaultShares, uint256 downVaultShares) external {
        uint256 upGlpAmount = IGlpVault(upVault).withdrawGlp(upVaultShares);
        uint256 downGlpAmount = IGlpVault(downVault).withdrawGlp(downVaultShares);
        IStakedGlp(vaultToken).transfer(msg.sender, upGlpAmount + downGlpAmount);
        emit WithdrawGlp(msg.sender, upGlpAmount + downGlpAmount, upVaultShares, downVaultShares);
    }
}
