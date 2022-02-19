// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import '@openzeppelin/contracts-upgradeable/proxy/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import "../lib/UniERC20.sol";
import "../interfaces/IGlpVault.sol";
import "../interfaces/IVovoVault.sol";
import "../interfaces/gmx/IRewardTracker.sol";
import "../interfaces/gmx/IRewardRouter.sol";
import "../interfaces/gmx/IGlpManager.sol";
import "../interfaces/gmx/IStakedGlp.sol";
import "../interfaces/gmx/IRouter.sol";
import "../interfaces/gmx/IVault.sol";
import "../interfaces/gmx/IRewardTracker.sol";

/**
 * @title GlpVault
 * @dev A vault that receives tokens from users, and then use the token to buy and stake GLP from GMX.
 * Periodically, the vault collects the yield rewards(weth and esGMX).
 * Then uses the weth rewards to open a leverage trade on GMX, and stake esGMX to earn more rewards.
 */
contract GlpVault is Initializable, ERC20Upgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable  {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMathUpgradeable for uint256;
  using UniERC20 for IERC20;

  // usdc token address
  address public constant usdc = address(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
  // weth token address
  address public constant weth = address(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
  // gmx token address
  address public constant gmx = address(0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a);
  // glp token address
  address public constant glp = address(0x4277f8F2c384827B5273592FF7CeBd9f2C1ac258);
  // glpManager address
  address public constant glpManager = address(0x321F653eED006AD1C29D174e17d96351BDe22649);
  // fsGLP token address
  address public constant fsGLP = address(0x1aDDD80E6039594eE970E5872D247bf0414C8903);
  // fGLP address
  address public constant fGLP = address(0x4e971a87900b931fF39d1Aad67697F49835400b6);
  // staked Glp address
  address public constant stakedGlp = address(0x01AF26b74409d10e15b102621EDd29c326ba1c55);
  // glp reward router address
  address public constant rewardRouter = address(0xA906F338CB21815cBc4Bc87ace9e68c87eF8d8F1);
  // gmx router address
  address public constant gmxRouter = address(0xaBBc5F99639c9B6bCb58544ddf04EFA6802F4064);
  // gmx vault address
  address public constant gmxVault = address(0x489ee077994B6658eAfA855C308275EAd8097C4A);
  // glp fee reward tracker address
  address public constant feeGlpTracker = address(0x4e971a87900b931fF39d1Aad67697F49835400b6);
  // gmx fee reward tracker address
  address public constant feeGmxTracker = address(0xd2D1162512F927a7e282Ef43a362659E4F2a728F);

  uint256 public constant FEE_DENOMINATOR = 10000;
  uint256 public constant DENOMINATOR = 10000;

  address public underlying; // underlying token of the leverage position
  uint256 public withdrawalFee;
  uint256 public performanceFee;
  uint256 public maxCollateralMultiplier;
  uint256 public cap;
  uint256 public underlyingBase;
  uint256 public lastPokeTime;
  uint256 public pokeInterval;
  uint256 public currentTokenReward;
  bool public isKeeperOnly;
  bool public isDepositEnabled;
  uint256 public leverage;
  bool public isLong;
  address public governor;
  address public admin;
  address public guardian;
  address public rewards;
  /// mapping(keeperAddress => true/false)
  mapping(address => bool) public keepers;
  /// mapping(fromVault => mapping(toVault => true/false))
  mapping(address => mapping(address => bool)) public withdrawMapping;

  event Deposited(address account, uint256 shares, uint256 glpAmount, address tokenIn, uint256 tokenInAmount);
  event DepositedGlp(address account, uint256 shares, uint256 glpAmount);
  event LiquidityAdded(uint256 tokenAmount, uint256 lpMinted);
  event Poked(uint256 tokenReward, uint256 glpAmount, uint256 minPricePerShare, uint256 maxPricePerShare);
  event OpenPosition(address underlying, uint256 underlyingPrice, uint256 wethPrice, uint256 sizeDelta, bool isLong, uint256 collateralAmount);
  event ClosePosition(address underlying, uint256 underlyingPrice, uint256 vaultTokenPrice,uint256 sizeDelta, bool isLong, uint256 collateralAmount, uint256 fee);
  event Withdraw(address account, uint256 shares, uint256 glpAmount, address tokenOut, uint256 tokenOutAmount, uint256 fee);
  event WithdrawGlp(address account, uint256 shares, uint256 glpAmount, uint256 fee);
  event WithdrawToVault(address owner, uint256 shares, uint256 glpAmount, address vault, uint256 receivedShares);
  event GovernanceSet(address governor);
  event AdminSet(address admin);
  event GuardianSet(address guardian);
  event FeeSet(uint256 performanceFee, uint256 withdrawalFee);
  event PerformanceFeeSet(uint256 performanceFee);
  event WithdrawalFeeSet(uint256 withdrawalFee);
  event LeverageSet(uint256 leverage);
  event isLongSet(bool isLong);
  event RewardsSet(address rewards);
  event SlipSet(uint256 slip);
  event MaxCollateralMultiplierSet(uint256 maxCollateralMultiplier);
  event IsKeeperOnlySet(bool isKeeperOnly);
  event DepositEnabled(bool isDepositEnabled);
  event CapSet(uint256 cap);
  event PokeIntervalSet(uint256 pokeInterval);
  event KeeperAdded(address keeper);
  event KeeperRemoved(address keeper);
  event VaultRegistered(address fromVault, address toVault);
  event VaultRevoked(address fromVault, address toVault);

  function initialize(
    string memory _vaultName,
    string memory _vaultSymbol,
    uint8 _vaultDecimal,
    address _underlying,
    address _rewards,
    uint256 _leverage,
    bool _isLong,
    uint256 _cap,
    uint256 _underlyingBase
  )  public initializer {
    __ERC20_init(_vaultName, _vaultSymbol);
    _setupDecimals(_vaultDecimal);
    __Pausable_init();
    underlying = _underlying;
    rewards = _rewards;
    leverage = _leverage;
    isLong = _isLong;
    cap = _cap;
    underlyingBase = _underlyingBase;
    lastPokeTime = block.timestamp;
    pokeInterval = 7 days;
    governor = msg.sender;
    admin = msg.sender;
    guardian = msg.sender;
    keepers[msg.sender] = true;
    isKeeperOnly = true;
    isDepositEnabled = true;
    withdrawalFee = 20;
    performanceFee = 1000;
    maxCollateralMultiplier = leverage;
  }

  /**
   * @notice Get the value of this vault in GLP
   * @param isMax the flag for optimistic or pessimistic calculation of the vault value
   * if isMax is true: the value of staked glp + the value of open leveraged position + estimated pending rewards
   * if isMax is false: the value of staked glp
   */
  function balance(bool isMax) public view returns (uint256) {
    uint256 glpBalance = IERC20(fsGLP).balanceOf(address(this));
    if (isMax) {
      return glpBalance.add(getActivePositionValue()).add(getClaimableReward());
    }
    return glpBalance;
  }


  /**
   * @notice Deposit token to this vault for an account. The vault mints shares to the account.
   * @param tokenIn is the address of token deposited
   * @param tokenInAmount is the amount of token deposited
   * @param minGlp is the minimum amount of GLP to be minted
   */
  function deposit(address tokenIn, uint256 tokenInAmount, uint256 minGlp) public whenNotPaused payable nonReentrant returns(uint256) {
    uint256 _pool = balance(true); // use max vault balance for deposit
    uint256 _before = IERC20(tokenIn).uniBalanceOf(address(this));
    IERC20(tokenIn).uniTransferFromSenderToThis(tokenInAmount);
    uint256 _after = IERC20(tokenIn).uniBalanceOf(address(this));
    tokenInAmount = _after.sub(_before);

    uint256 glpAmount = 0;
    if (IERC20(tokenIn).isETH()) {
      glpAmount = IRewardRouter(rewardRouter).mintAndStakeGlpETH{value: msg.value}(0, minGlp);
    } else {
      IERC20(tokenIn).safeApprove(glpManager, 0);
      IERC20(tokenIn).safeApprove(glpManager, tokenInAmount);
      glpAmount = IRewardRouter(rewardRouter).mintAndStakeGlp(tokenIn, tokenInAmount, 0, minGlp);
    }
    require(isDepositEnabled && _pool.add(glpAmount) < cap, "!deposit");
    uint256 shares = 0;
    if (totalSupply() == 0) {
      shares = glpAmount;
    } else {
      shares = (glpAmount.mul(totalSupply())).div(_pool);
    }
    require(shares > 0, "!shares");
    _mint(msg.sender, shares);
    emit Deposited(msg.sender, shares, glpAmount, tokenIn, tokenInAmount);
    return shares;
  }

  /**
   * @notice Deposit GLP to this vault for an account. The vault mints shares to the account.
   * @param glpAmount is the amount of GLP deposited
   */
  function depositGlp(uint256 glpAmount) public whenNotPaused nonReentrant {
    uint256 _pool = balance(true);// use max vault balance for deposit
    require(isDepositEnabled && _pool.add(glpAmount) < cap, "!deposit");
    IStakedGlp(stakedGlp).transferFrom(msg.sender, address(this), glpAmount);
    uint256 shares = 0;
    if (totalSupply() == 0) {
      shares = glpAmount;
    } else {
      shares = (glpAmount.mul(totalSupply())).div(_pool);
    }
    require(shares > 0, "!shares");
    _mint(msg.sender, shares);
    emit DepositedGlp(msg.sender, shares, glpAmount);
  }


  /**
   * @notice 1. Collect reward for staked GLP; 2. Close old leverage trade;
             3. Use the reward to open new leverage trade; 4. Use trade profit to mint and stake more GLP to earn reward
   */
  function poke() external whenNotPaused nonReentrant {
    require(keepers[msg.sender] || !isKeeperOnly, "!keepers");
    require(lastPokeTime + pokeInterval < block.timestamp, "!poke time");
    uint256 tokenReward = collectReward();
    closeTrade();
    if (tokenReward > 0) {
      openTrade(tokenReward);
    }
    currentTokenReward = tokenReward;
    uint256 glpAmount = 0;
    uint256 wethBalance = IERC20(weth).balanceOf(address(this));
    if (wethBalance > 0) {
      IERC20(weth).safeApprove(glpManager, 0);
      IERC20(weth).safeApprove(glpManager, wethBalance);
      glpAmount = IRewardRouter(rewardRouter).mintAndStakeGlp(weth, wethBalance, 0, 0);
    }
    lastPokeTime = block.timestamp;
    emit Poked(tokenReward, glpAmount, getPricePerShare(false), getPricePerShare(true));
  }

  /**
   * @notice Claim esGMX, multiplier points and weth from the rewardRouter and stake esGMX and multiplier points
   * @return tokenReward the amount of weth reward
   */
  function collectReward() private returns(uint256 tokenReward) {
    uint256 _before = IERC20(weth).balanceOf(address(this));
    IRewardRouter(rewardRouter).handleRewards(false, false, true, true, true, true, false);
    uint256 _after = IERC20(weth).balanceOf(address(this));
    tokenReward = _after.sub(_before);
  }

  /**
   * @notice Open leverage position at GMX
   * @param amount the amount of token be used as leverage position collateral
   */
  function openTrade(uint256 amount) private {
    address[] memory _path;
    address collateral = isLong ? underlying : usdc;
    if (weth == collateral) {
      _path = new address[](1);
      _path[0] = collateral;
    } else {
      _path = new address[](2);
      _path[0] = weth;
      _path[1] = collateral;
    }
    uint256 _underlyingPrice = isLong ? IVault(gmxVault).getMaxPrice(underlying) : IVault(gmxVault).getMinPrice(underlying);
    uint256 _wethPrice = isLong ? IVault(gmxVault).getMinPrice(weth) : IVault(gmxVault).getMaxPrice(weth);
    uint256 _sizeDelta = leverage.mul(amount).mul(_wethPrice).div(1e18);
    IERC20(underlying).safeApprove(gmxRouter, 0);
    IERC20(underlying).safeApprove(gmxRouter, amount);
    IRouter(gmxRouter).increasePosition(_path, underlying, amount, 0, _sizeDelta, isLong, _underlyingPrice);
    emit OpenPosition(underlying, _underlyingPrice, _wethPrice, _sizeDelta, isLong, amount);
  }

  /**
   * @notice Close leverage position at GMX
   */
  function closeTrade() private {
    (uint256 size,,,,,,,) = IVault(gmxVault).getPosition(address(this), underlying, underlying, isLong);
    uint256 _underlyingPrice = isLong ? IVault(gmxVault).getMaxPrice(underlying) : IVault(gmxVault).getMinPrice(underlying);
    uint256 _wethPrice = isLong ? IVault(gmxVault).getMinPrice(weth) : IVault(gmxVault).getMaxPrice(weth);
    if (size == 0) {
      emit ClosePosition(underlying, _underlyingPrice, _wethPrice, size, isLong, 0, 0);
      return;
    }
    address collateral = isLong ? underlying : usdc;
    uint256 _before = IERC20(weth).balanceOf(address(this));
    if (weth == collateral) {
      IRouter(gmxRouter).decreasePosition(underlying, underlying, 0, size, isLong, address(this), _underlyingPrice);
    } else {
      address[] memory path = new address[](2);
      path = new address[](2);
      path[0] = collateral;
      path[1] = weth;
      IRouter(gmxRouter).decreasePositionAndSwap(path, underlying, 0, size, isLong, address(this), _underlyingPrice, 0);
    }
    uint256 _after = IERC20(weth).balanceOf(address(this));
    uint256 _tradeProfit = _after.sub(_before);
    uint256 _fee = 0;
    if (_tradeProfit > 0) {
      _fee = _tradeProfit.mul(performanceFee).div(FEE_DENOMINATOR);
      IERC20(weth).safeTransfer(rewards, _fee);
    }
    emit ClosePosition(underlying, _underlyingPrice, _wethPrice, size, isLong, _tradeProfit, _fee);
  }

  /**
   * @notice Withdraw from this vault to another vault
   * @param shares the number of this vault shares to be burned
   * @param vault the address of destination vault
   */
  function withdrawToVault(uint256 shares, address vault) external whenNotPaused nonReentrant {
    require(vault != address(0), "!vault");
    require(withdrawMapping[address(this)][vault], "Withdraw to vault not allowed");

    uint256 glpAmount = balance(false).mul(shares).div(totalSupply()); // use min vault balance for withdraw
    _burn(msg.sender, shares);
    IERC20(stakedGlp).approve(vault, glpAmount);
    IGlpVault(vault).depositGlp(glpAmount);
    uint256 receivedShares = IERC20(vault).balanceOf(address(this));
    IERC20(vault).safeTransfer(msg.sender, receivedShares);

    emit WithdrawGlp(msg.sender, shares, glpAmount, 0);
    emit WithdrawToVault(msg.sender, shares, glpAmount, vault, receivedShares);
  }

  /**
   * @notice Withdraw token from this vault
   * @param shares the number of this vault shares to be burned
   * @param tokenOut the withdraw token
   * @param minOut the minimum amount of tokenOut to withdraw
   */
  function withdraw(address tokenOut, uint256 shares, uint256 minOut) external whenNotPaused returns(uint256 withdrawAmount) {
    require(shares > 0, "!shares");
    uint256 glpAmount = (balance(false).mul(shares)).div(totalSupply()); // use min vault balance for withdraw
    _burn(msg.sender, shares);

    uint256 tokenOutAmount = 0;
    if (IERC20(tokenOut).isETH()) {
      tokenOutAmount = IRewardRouter(rewardRouter).unstakeAndRedeemGlpETH(glpAmount, minOut, address(this));
    } else {
      tokenOutAmount = IRewardRouter(rewardRouter).unstakeAndRedeemGlp(tokenOut, glpAmount, minOut, address(this));
    }
    uint256 fee = tokenOutAmount.mul(withdrawalFee).div(FEE_DENOMINATOR);
    withdrawAmount = tokenOutAmount.sub(fee);
    IERC20(tokenOut).uniTransfer(msg.sender, withdrawAmount);
    IERC20(tokenOut).uniTransfer(rewards, fee);
    emit Withdraw(msg.sender, shares, glpAmount, tokenOut, tokenOutAmount, fee);
  }

  /**
   * @notice Withdraw glp from this vault
   * @param shares the number of this vault shares to be burned
   */
  function withdrawGlp(uint256 shares) external whenNotPaused returns(uint256 withdrawAmount) {
    require(shares > 0, "!shares");
    uint256 glpAmount = balance(false).mul(shares).div(totalSupply()); // use min vault balance for withdraw
    _burn(msg.sender, shares);
    uint256 fee = glpAmount.mul(withdrawalFee).div(FEE_DENOMINATOR);
    withdrawAmount = glpAmount.sub(fee);
    IStakedGlp(stakedGlp).transfer(msg.sender, withdrawAmount);
    IStakedGlp(stakedGlp).transfer(rewards, fee);
    emit WithdrawGlp(msg.sender, shares, glpAmount, fee);
  }

  receive() external payable {}

  /// ===== View Functions =====

  function getPricePerShare(bool isMax) public view returns (uint256) {
     return balance(isMax).mul(1e18).div(totalSupply());
  }

  /**
   * @notice get the active leverage position value in GLP
   */
  function getActivePositionValue() public view returns (uint256) {
    (uint256 size, uint256 collateral,,uint256 entryFundingRate,,,,) = IVault(gmxVault).getPosition(address(this), underlying, underlying, isLong);
    if (size == 0) {
      return 0;
    }
    (bool hasProfit, uint256 delta) = IVault(gmxVault).getPositionDelta(address(this), underlying, underlying, isLong);
    uint256 feeUsd = IVault(gmxVault).getPositionFee(size);
    uint256 fundingFee = IVault(gmxVault).getFundingFee(underlying, size, entryFundingRate);
    feeUsd = feeUsd.add(fundingFee);
    uint256 positionValueUsd = hasProfit ? collateral.add(delta).sub(feeUsd) : collateral.sub(delta).sub(feeUsd);
    uint256 positionValue = IVault(gmxVault).usdToTokenMin(weth, positionValueUsd);
    // Cap the positionValue to avoid the oracle manipulation
    if (positionValue > currentTokenReward.mul(maxCollateralMultiplier)) {
      uint256 newPositionValue = currentTokenReward.mul(maxCollateralMultiplier);
      positionValueUsd = newPositionValue.mul(positionValueUsd).div(positionValue);
    }
    return positionValueUsd.mul(1e12).div(getGlpPrice());
  }

  function getClaimableReward() public view returns (uint256) {
    uint256 glpWethReward = IRewardTracker(feeGlpTracker).claimable(address(this));
    uint256 gmxWethReward = IRewardTracker(feeGmxTracker).claimable(address(this));
    uint256 _wethPrice = IVault(gmxVault).getMinPrice(weth);
    return (glpWethReward.add(gmxWethReward)).mul(_wethPrice).div(getGlpPrice()).div(1e12);
  }

  function getGlpPrice() public view returns (uint256) {
    return IGlpManager(glpManager).getAum(true).mul(1e6).div(IERC20(glp).totalSupply());
  }

  // ===== Permissioned Actions: Governance =====

  function setGovernance(address _governor) external onlyGovernor {
    governor = _governor;
    emit GovernanceSet(governor);
  }

  function setAdmin(address _admin) external {
    require(msg.sender == admin || msg.sender == governor, "!authorized");
    admin = _admin;
    emit AdminSet(admin);
  }

  function setGuardian(address _guardian) external onlyGovernor {
    guardian = _guardian;
    emit GuardianSet(guardian);
  }

  function setFees(uint256 _performanceFee, uint256 _withdrawalFee) external onlyGovernor {
    // ensure performanceFee is smaller than 50% and withdraw fee is smaller than 5%
    require(_performanceFee < 5000 && _withdrawalFee < 500, "!too-much");
    performanceFee = _performanceFee;
    withdrawalFee = _withdrawalFee;
    emit FeeSet(performanceFee, withdrawalFee);
  }

  function setLeverage(uint256 _leverage) external onlyGovernor {
    require(_leverage >= 1 && _leverage <= 50, "!leverage");
    leverage = _leverage;
    emit LeverageSet(leverage);
  }

  function setIsLong(bool _isLong) external onlyGovernor {
    closeTrade();
    isLong = _isLong;
    emit isLongSet(isLong);
  }

  function setRewards(address _rewards) external onlyGovernor {
    rewards = _rewards;
    emit RewardsSet(rewards);
  }

  function setMaxCollateralMultiplier(uint256 _maxCollateralMultiplier) external onlyGovernor {
    require(_maxCollateralMultiplier >= 1 && _maxCollateralMultiplier <= 50, "!maxCollateralMultiplier");
    maxCollateralMultiplier = _maxCollateralMultiplier;
  }

  function setIsKeeperOnly(bool _isKeeperOnly) external onlyGovernor {
    isKeeperOnly = _isKeeperOnly;
    emit IsKeeperOnlySet(_isKeeperOnly);
  }

  function setDepositEnabledAndCap(bool _flag, uint256 _cap) external onlyGovernor {
    isDepositEnabled = _flag;
    cap = _cap;
    emit DepositEnabled(isDepositEnabled);
    emit CapSet(cap);
  }

  function setPokeInterval(uint256 _pokeInterval) external onlyGovernor {
    pokeInterval = _pokeInterval;
    emit PokeIntervalSet(pokeInterval);
  }

  // ===== Permissioned Actions: Admin =====

  function addKeeper(address _keeper) external onlyAdmin {
    keepers[_keeper] = true;
    emit KeeperAdded(_keeper);
  }

  function removeKeeper(address _keeper) external onlyAdmin {
    keepers[_keeper] = false;
    emit KeeperRemoved(_keeper);
  }

  function registerVault(address fromVault, address toVault) external onlyAdmin {
    withdrawMapping[fromVault][toVault] = true;
    emit VaultRegistered(fromVault, toVault);
  }

  function revokeVault(address fromVault, address toVault) external onlyAdmin {
    withdrawMapping[fromVault][toVault] = false;
    emit VaultRevoked(fromVault, toVault);
  }

  /// ===== Permissioned Actions: Guardian =====

  function pause() external onlyGuardian {
    _pause();
  }

  /// ===== Permissioned Actions: Governance =====

  function unpause() external onlyGovernor {
    _unpause();
  }

  /// ===== Modifiers =====

  modifier onlyGovernor() {
    require(msg.sender == governor, "!governor");
    _;
  }

  modifier onlyAdmin() {
    require(msg.sender == admin, "!admin");
    _;
  }

  modifier onlyGuardian() {
    require(msg.sender == guardian, "!pausers");
    _;
  }

}
