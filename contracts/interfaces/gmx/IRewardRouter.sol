// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

interface IRewardRouter {
    function mintAndStakeGlp(address _token, uint256 _amount, uint256 _minUsdg, uint256 _minGlp) external nonReentrant returns (uint256);
    function mintAndStakeGlpETH(uint256 _minUsdg, uint256 _minGlp) external payable nonReentrant returns (uint256);
    function handleRewards(
        bool _shouldClaimGmx,
        bool _shouldStakeGmx,
        bool _shouldClaimEsGmx,
        bool _shouldStakeEsGmx,
        bool _shouldStakeMultiplierPoints,
        bool _shouldClaimWeth,
        bool _shouldConvertWethToEth
    ) external nonReentrant;
}

