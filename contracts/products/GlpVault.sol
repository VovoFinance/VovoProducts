// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import '@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol';
import "../lib/UniERC20.sol";
import "../interfaces/IGlpVault.sol";
import "../interfaces/gmx/IRewardTracker.sol";
import "../interfaces/gmx/IRewardRouter.sol";
import "../interfaces/gmx/IGlpManager.sol";
import "../interfaces/gmx/IStakedGlp.sol";
import "../interfaces/gmx/IRouter.sol";
import "../interfaces/gmx/IVault.sol";
import "../interfaces/gmx/IRewardTracker.sol";
import "../lib/MulDiv.sol";

/**
 * @title GlpVault
 * @dev A vault that receives tokens from users, and then use the token to buy and stake GLP from GMX.
 * Periodically, the vault collects the yield rewards(weth and esGMX).
 * Then uses the weth rewards to open a leverage trade on GMX, and stake esGMX to earn more rewards.
 */
contract GlpVault is Initializable, ERC20Upgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable  {
  using SafeERC20Upgradeable for IERC20Upgradeable;
  using AddressUpgradeable for address;
  using SafeMathUpgradeable for uint256;
  using UniERC20 for IERC20Upgradeable;
  using MulDiv for uint256;

  // usdc token address
  address public constant USDC = address(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
  // weth token address
  address public constant WETH = address(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
  // glp token address
  address public constant GLP = address(0x4277f8F2c384827B5273592FF7CeBd9f2C1ac258);
  // glpManager address
  address public constant GLP_MANAGER = address(0x321F653eED006AD1C29D174e17d96351BDe22649);
  // fsGLP token address
  address public constant FS_GLP = address(0x1aDDD80E6039594eE970E5872D247bf0414C8903);
  // staked Glp address
  address public constant STAKED_GLP = address(0x2F546AD4eDD93B956C8999Be404cdCAFde3E89AE);
  // glp reward router address
  address public constant REWARD_ROUTER = address(0xA906F338CB21815cBc4Bc87ace9e68c87eF8d8F1);
  // glp fee reward tracker address
  address public constant FEE_GLP_TRACKER = address(0x4e971a87900b931fF39d1Aad67697F49835400b6);
  // gmx fee reward tracker address
  address public constant FEE_GMX_TRACKER = address(0xd2D1162512F927a7e282Ef43a362659E4F2a728F);

  uint256 public constant FEE_DENOMINATOR = 10000;
  uint256 public constant BASE = 1e18;
  uint256 public constant SMALL_BASE = 1e6;

  address public underlying; // underlying token of the leverage position
  uint256 public managementFee;
  uint256 public performanceFee;
  uint256 public maxCollateralMultiplier; // multiplier to cap the value to avoid the oracle manipulation when calculating active position value
  uint256 public cap;
  uint256 public lastPokeTime;
  uint256 public pokeInterval;
  uint256 public withdrawInterval;
  uint256 public currentTokenReward; // weth reward collected during the last poke
  bool public isKeeperOnly;
  bool public isDepositEnabled;
  bool public disablePokeInterval;
  bool public isFreeWithdraw;
  uint256 public leverage; // leverage of trade when opening position
  bool public isLong;
  address public governor;
  address public admin;
  address public guardian;
  address public rewards;
  address public gmxPositionManager;
  address public gmxRouter;
  address public gmxVault;
  /// mapping(keeperAddress => true/false)
  mapping(address => bool) public keepers;
  /// mapping(fromVault => mapping(toVault => true/false))
  mapping(address => mapping(address => bool)) public withdrawMapping;

  event Deposited(address depositor, address account, uint256 shares, uint256 glpAmount, address tokenIn, uint256 tokenInAmount);
  event DepositedGlp(address depositor, address account, uint256 shares, uint256 glpAmount);
  event Poked(uint256 tokenReward, uint256 glpAmount, uint256 pricePerShare, uint256 fee);
  event CollectedRewardByKeeper(address keeper, uint256 tokenReward, uint256 glpAmount);
  event ClosedTradeByKeeper(address keeper, uint256 earning, uint256 glpAmount);
  event OpenPosition(address underlying, uint256 underlyingPrice, uint256 wethPrice, uint256 sizeDelta, bool isLong, uint256 collateralAmount);
  event ClosePosition(address underlying, uint256 underlyingPrice, uint256 vaultTokenPrice,uint256 sizeDelta, bool isLong, uint256 collateralAmount, uint256 fee);
  event Withdraw(address account, uint256 shares, uint256 glpAmount, address tokenOut, uint256 tokenOutAmount);
  event WithdrawGlp(address account, uint256 shares, uint256 glpAmount);
  event WithdrawToVault(address owner, uint256 shares, uint256 glpAmount, address vault, uint256 receivedShares);
  event GovernanceSet(address governor);
  event AdminSet(address admin);
  event GuardianSet(address guardian);
  event FeeSet(uint256 performanceFee, uint256 withdrawalFee);
  event LeverageSet(uint256 leverage);
  event isLongSet(bool isLong);
  event GmxContractsSet(address gmxPositionManager, address gmxRouter, address gmxVault);
  event ParametersSet(bool isDepositEnabled, uint256 _maxCollateralMultiplier, uint256 cap, uint256 pokeInterval, uint256 withdrawInterval, bool isKeeperOnly, bool isFreeWithdraw, address rewards);
  event KeeperSet(address keeper, bool isActive);
  event VaultSet(address fromVault, address toVault, bool isActive);

  function initialize(
    string memory _vaultName,
    string memory _vaultSymbol,
    uint8 _vaultDecimal,
    address _underlying,
    address _rewards,
    uint256 _leverage,
    bool _isLong,
    uint256 _cap
  )  public initializer {
    require(_leverage >= 1 && _leverage <= 50);
    __ERC20_init(_vaultName, _vaultSymbol);
    _setupDecimals(_vaultDecimal);
    __Pausable_init();
    underlying = _underlying;
    rewards = _rewards;
    leverage = _leverage;
    isLong = _isLong;
    cap = _cap;
    lastPokeTime = block.timestamp;
    pokeInterval = 7 days;
    withdrawInterval = 1 days;
    governor = msg.sender;
    admin = msg.sender;
    guardian = msg.sender;
    gmxPositionManager = address(0x87a4088Bd721F83b6c2E5102e2FA47022Cb1c831);
    gmxRouter = address(0xaBBc5F99639c9B6bCb58544ddf04EFA6802F4064);
    gmxVault = address(0x489ee077994B6658eAfA855C308275EAd8097C4A);
    keepers[msg.sender] = true;
    isKeeperOnly = true;
    isDepositEnabled = true;
    isFreeWithdraw = false;
    disablePokeInterval = false;
    managementFee = 200;
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
    uint256 glpBalance = IERC20Upgradeable(FS_GLP).balanceOf(address(this));
    if (isMax) {
      return glpBalance.add(getActivePositionValue()).add(getClaimableReward());
    }
    return glpBalance;
  }

  /**
   * @notice Deposit token to this vault for and receive shares.
   * @param tokenIn is the address of token deposited
   * @param tokenInAmount is the amount of token deposited
   * @param minGlp is the minimum amount of GLP to be minted
   * @return number of shares received
   */
  function deposit(address tokenIn, uint256 tokenInAmount, uint256 minGlp) external payable returns(uint256) {
    return depositFor(tokenIn, tokenInAmount, minGlp, msg.sender);
  }

  /**
   * @notice Deposit token to this vault for an account. The vault mints shares to the account.
   * @param tokenIn is the address of token deposited
   * @param tokenInAmount is the amount of token deposited
   * @param minGlp is the minimum amount of GLP to be minted
   * @param account is the account to deposit for
   * @return number of shares minted to account
   */
  function depositFor(address tokenIn, uint256 tokenInAmount, uint256 minGlp, address account) public whenNotPaused payable nonReentrant returns(uint256) {
    require(isDepositEnabled && block.timestamp >= lastPokeTime.add(withdrawInterval), "!deposit-time");
    uint256 _pool = balance(true); // use max vault balance for deposit
    IERC20Upgradeable(tokenIn).uniTransferFromSenderToThis(tokenInAmount);
    uint256 glpAmount;
    if (IERC20Upgradeable(tokenIn).isETH()) {
      glpAmount = IRewardRouter(REWARD_ROUTER).mintAndStakeGlpETH{value: tokenInAmount}(0, minGlp);
    } else {
      glpAmount = mintAndStakeGlp(tokenIn, tokenInAmount, minGlp);
    }
    require(_pool.add(glpAmount) <= cap, "!deposit");
    uint256 shares;
    if (totalSupply() == 0) {
      shares = glpAmount;
    } else {
      shares = glpAmount.muldiv(totalSupply(), _pool);
    }
    require(shares > 0, "!shares");
    _mint(account, shares);
    emit Deposited(msg.sender, account, shares, glpAmount, tokenIn, tokenInAmount);
    return shares;
  }

  /**
   * @notice Deposit GLP to this vault and receive shares.
   * @param glpAmount is the amount of GLP deposited
   */
  function depositGlp(uint256 glpAmount) external returns(uint256) {
    return depositGlpFor(glpAmount, msg.sender);
  }

  /**
   * @notice Deposit GLP to this vault for an account. The vault mints shares to the account.
   * @param glpAmount is the amount of GLP deposited
   * @param account is the account to deposit for
   * @return number of shares minted to account
   */
  function depositGlpFor(uint256 glpAmount, address account) public whenNotPaused nonReentrant returns(uint256) {
    require(block.timestamp >= lastPokeTime.add(withdrawInterval), "!deposit-time");
    uint256 _pool = balance(true);// use max vault balance for deposit
    require(isDepositEnabled && _pool.add(glpAmount) < cap, "!deposit");
    IStakedGlp(STAKED_GLP).transferFrom(msg.sender, address(this), glpAmount);
    uint256 shares = 0;
    if (totalSupply() == 0) {
      shares = glpAmount;
    } else {
      shares = glpAmount.muldiv(totalSupply(), _pool);
    }
    require(shares > 0, "!shares");
    _mint(account, shares);
    emit DepositedGlp(msg.sender, account, shares, glpAmount);
    return shares;
  }


  /**
   * @notice 1. Collect reward for staked GLP; 2. Close old leverage trade;
             3. Use the reward to open new leverage trade; 4. Use trade profit to mint and stake more GLP to earn reward
   */
  function poke() external whenNotPaused nonReentrant {
    require(keepers[msg.sender] || !isKeeperOnly, "!keepers");
    require(lastPokeTime + pokeInterval <= block.timestamp || disablePokeInterval, "!time");
    // collect management fee in glp first to avoid the glp cooldown duration for transfer after the mintAndStakeGlp below
    // management fee to collect = (yearly management fee) * (seconds from last poke time to now) / (seconds in a year)
    uint256 fee = balance(false).mul(managementFee).muldiv(block.timestamp.sub(lastPokeTime), 365 days).div(FEE_DENOMINATOR);
    IStakedGlp(STAKED_GLP).transfer(rewards, fee);

    uint256 tokenReward = collectReward();
    closeTrade();
    if (tokenReward > 0) {
      openTrade(tokenReward);
    }
    currentTokenReward = tokenReward;
    uint256 glpAmount;
    uint256 wethBalance = IERC20Upgradeable(WETH).balanceOf(address(this));
    if (wethBalance > 0) {
      glpAmount = mintAndStakeGlp(WETH, wethBalance, 0);
    }
    lastPokeTime = block.timestamp;
    emit Poked(tokenReward, glpAmount, getPricePerShare(false), fee);
  }

  /**
   * @notice Only can be called by keepers in case the poke() does not work
   *         Claim esGMX, multiplier points and weth from the rewardRouter and stake all of them
   * @return glpAmount the amount of glp staked from weth rewards
   */
  function collectRewardByKeeper() external nonReentrant returns(uint256 glpAmount) {
    require(keepers[msg.sender] && disablePokeInterval, "!keepers");
    uint256 tokenReward = collectReward();
    glpAmount = mintAndStakeGlp(WETH, tokenReward, 0);
    emit CollectedRewardByKeeper(msg.sender, tokenReward, glpAmount);
  }

  /**
   * @notice Claim esGMX, multiplier points and weth from the rewardRouter and stake esGMX and multiplier points
   * @return tokenReward the amount of weth reward
   */
  function collectReward() private returns(uint256 tokenReward) {
    uint256 _before = IERC20Upgradeable(WETH).balanceOf(address(this));
    IRewardRouter(REWARD_ROUTER).handleRewards({_shouldClaimGmx: false, _shouldStakeGmx: false, _shouldClaimEsGmx: true, _shouldStakeEsGmx: true,
      _shouldStakeMultiplierPoints: true, _shouldClaimWeth: true, _shouldConvertWethToEth: false});
    uint256 _after = IERC20Upgradeable(WETH).balanceOf(address(this));
    tokenReward = _after.sub(_before);
  }

  /**
   * @notice Open leverage position at GMX
   * @param amount the amount of token be used as leverage position collateral
   */
  function openTrade(uint256 amount) private {
    address[] memory _path;
    address collateral = isLong ? underlying : USDC;
    if (WETH == collateral) {
      _path = new address[](1);
      _path[0] = collateral;
    } else {
      _path = new address[](2);
      _path[0] = WETH;
      _path[1] = collateral;
    }
    uint256 _underlyingPrice = isLong ? IVault(gmxVault).getMaxPrice(underlying) : IVault(gmxVault).getMinPrice(underlying);
    uint256 _wethPrice = IVault(gmxVault).getMinPrice(WETH);
    uint256 _sizeDelta = leverage.mul(amount).muldiv(_wethPrice, BASE);
    IERC20Upgradeable(WETH).safeIncreaseAllowance(gmxRouter, amount);
    IRouter(gmxRouter).approvePlugin(gmxPositionManager);
    IRouter(gmxPositionManager).increasePosition({_path: _path, _indexToken: underlying, _amountIn: amount, _minOut: 0, _sizeDelta: _sizeDelta, _isLong: isLong, _price: _underlyingPrice});
    emit OpenPosition(underlying, _underlyingPrice, _wethPrice, _sizeDelta, isLong, amount);
  }

  /**
   * @notice Only can be called by keepers to close the position and stake weth profit in case the poke() does not work
   * @return glpAmount the amount of glp minted and staked
   */
  function closeTradeByKeeper() external nonReentrant returns(uint256 glpAmount) {
    require(keepers[msg.sender] && disablePokeInterval, "!keepers");
    closeTrade();
    uint256 wethBalance = IERC20Upgradeable(WETH).balanceOf(address(this));
    glpAmount = 0;
    if (wethBalance > 0) {
      glpAmount = mintAndStakeGlp(WETH, wethBalance, 0);
    }
    emit ClosedTradeByKeeper(msg.sender, wethBalance, glpAmount);
  }

  /**
   * @notice Close leverage position at GMX
   */
  function closeTrade() private {
    address collateral = isLong ? underlying : USDC;
    (uint256 size,,,,,,,) = IVault(gmxVault).getPosition(address(this), collateral, underlying, isLong);
    uint256 _underlyingPrice = isLong ? IVault(gmxVault).getMinPrice(underlying) : IVault(gmxVault).getMaxPrice(underlying);
    uint256 _wethPrice = IVault(gmxVault).getMinPrice(WETH);
    if (size == 0) {
      emit ClosePosition(underlying, _underlyingPrice, _wethPrice, size, isLong, 0, 0);
      return;
    }
    uint256 _before = IERC20Upgradeable(WETH).balanceOf(address(this));
    IRouter(gmxRouter).approvePlugin(gmxPositionManager);
    if (WETH == collateral) {
      IRouter(gmxPositionManager).decreasePosition({_collateralToken: underlying, _indexToken: underlying, _collateralDelta: 0,
      _sizeDelta: size, _isLong: isLong, _receiver: address(this), _price: _underlyingPrice});
    } else {
      address[] memory path = new address[](2);
      path = new address[](2);
      path[0] = collateral;
      path[1] = WETH;
      IRouter(gmxPositionManager).decreasePositionAndSwap({_path: path, _indexToken: underlying, _collateralDelta: 0,
      _sizeDelta: size, _isLong: isLong, _receiver: address(this), _price: _underlyingPrice, _minOut: 0});
    }
    uint256 _after = IERC20Upgradeable(WETH).balanceOf(address(this));
    uint256 _tradeProfit = _after.sub(_before);
    uint256 _fee = 0;
    if (_tradeProfit > 0) {
      _fee = _tradeProfit.muldiv(performanceFee, FEE_DENOMINATOR);
      IERC20Upgradeable(WETH).safeTransfer(rewards, _fee);
    }
    emit ClosePosition(underlying, _underlyingPrice, _wethPrice, size, isLong, _tradeProfit, _fee);
  }

  function mintAndStakeGlp(address tokenIn, uint256 tokenInAmount, uint256 minGlp) private returns(uint256 glpAmount) {
    IERC20Upgradeable(tokenIn).safeIncreaseAllowance(GLP_MANAGER, tokenInAmount);
    glpAmount = IRewardRouter(REWARD_ROUTER).mintAndStakeGlp({_token: tokenIn, _amount: tokenInAmount, _minUsdg: 0, _minGlp: minGlp});
  }

  /**
   * @notice Withdraw from this vault to another vault
   * @param shares the number of this vault shares to be burned
   * @param vault the address of destination vault
   */
  function withdrawToVault(uint256 shares, address vault) external whenNotPaused nonReentrant {
    require(withdrawMapping[address(this)][vault], "!whitelist");

    uint256 glpAmount = balance(false).muldiv(shares, totalSupply()); // use min vault balance for withdraw
    _burn(msg.sender, shares);
    IERC20Upgradeable(STAKED_GLP).approve(vault, glpAmount);
    IGlpVault(vault).depositGlp(glpAmount);
    uint256 receivedShares = IERC20Upgradeable(vault).balanceOf(address(this));
    IERC20Upgradeable(vault).safeTransfer(msg.sender, receivedShares);

    emit WithdrawGlp(msg.sender, shares, glpAmount);
    emit WithdrawToVault(msg.sender, shares, glpAmount, vault, receivedShares);
  }

  /**
   * @notice Withdraw token from this vault
   * @param shares the number of this vault shares to be burned
   * @param tokenOut the withdraw token
   * @param minOut the minimum amount of tokenOut to withdraw
   * @return tokenOutAmount the amount of tokenOut that is withdrawn
   */
  function withdraw(address tokenOut, uint256 shares, uint256 minOut) external whenNotPaused nonReentrant returns(uint256 tokenOutAmount) {
    require(block.timestamp <= lastPokeTime.add(withdrawInterval) || isFreeWithdraw, "!withdraw-time");
    require(shares > 0, "!shares");
    uint256 glpAmount = (balance(false).mul(shares)).div(totalSupply()); // use min vault balance for withdraw
    _burn(msg.sender, shares);

    if (IERC20Upgradeable(tokenOut).isETH()) {
      tokenOutAmount = IRewardRouter(REWARD_ROUTER).unstakeAndRedeemGlpETH({_glpAmount: glpAmount, _minOut: minOut, _receiver: address(this)});
    } else {
      tokenOutAmount = IRewardRouter(REWARD_ROUTER).unstakeAndRedeemGlp({_tokenOut: tokenOut, _glpAmount: glpAmount, _minOut: minOut, _receiver: address(this)});
    }
    IERC20Upgradeable(tokenOut).uniTransfer(msg.sender, tokenOutAmount);
    emit Withdraw(msg.sender, shares, glpAmount, tokenOut, tokenOutAmount);
  }

  /**
   * @notice Withdraw glp from this vault
   * @param shares the number of this vault shares to be burned
   * @return glpAmount amount of glp that is withdrawn
   */
  function withdrawGlp(uint256 shares) external whenNotPaused nonReentrant returns(uint256 glpAmount) {
    require(block.timestamp <= lastPokeTime.add(withdrawInterval) || isFreeWithdraw, "!withdraw-time");
    require(shares > 0, "!shares");
    glpAmount = balance(false).muldiv(shares, totalSupply()); // use min vault balance for withdraw
    _burn(msg.sender, shares);
    IStakedGlp(STAKED_GLP).transfer(msg.sender, glpAmount);
    emit WithdrawGlp(msg.sender, shares, glpAmount);
  }

  /**
   * @notice To receive ether from GMX contract when redeeming glp for ether
   */
  receive() external payable {}

  /// ===== View Functions =====

  function getPricePerShare(bool isMax) public view returns (uint256) {
     return balance(isMax).muldiv(BASE, totalSupply());
  }

  /**
   * @notice get the active leverage position value in GLP
   */
  function getActivePositionValue() public view returns (uint256) {
    address collateral = isLong ? underlying : USDC;
    (uint256 size, uint256 collateralAmount,,uint256 entryFundingRate,,,,) = IVault(gmxVault).getPosition(address(this), collateral, underlying, isLong);
    if (size == 0) {
      return 0;
    }
    (bool hasProfit, uint256 delta) = IVault(gmxVault).getPositionDelta(address(this), collateral, underlying, isLong);
    uint256 feeUsd = IVault(gmxVault).getPositionFee(size);
    uint256 fundingFee = IVault(gmxVault).getFundingFee(collateral, size, entryFundingRate);
    feeUsd = feeUsd.add(fundingFee);
    uint256 positionValueUsd = 0;
    if (hasProfit){
      uint256 collateralAndDelta = collateralAmount.add(delta);
      positionValueUsd = collateralAndDelta > feeUsd ? collateralAndDelta.sub(feeUsd) : 0;
    } else {
      uint256 deltaAndFeeUsd = delta.add(feeUsd);
      positionValueUsd = collateralAmount > deltaAndFeeUsd ? collateralAmount.sub(deltaAndFeeUsd) : 0;
    }
    uint256 positionValue = IVault(gmxVault).usdToTokenMin(WETH, positionValueUsd);
    // Cap the positionValue to avoid the oracle manipulation
    if (positionValue > currentTokenReward.mul(maxCollateralMultiplier)) {
      uint256 newPositionValue = currentTokenReward.mul(maxCollateralMultiplier);
      positionValueUsd = newPositionValue.muldiv(positionValueUsd, positionValue);
    }
    return positionValueUsd.muldiv(SMALL_BASE, getGlpPrice());
  }

  function getClaimableReward() public view returns (uint256) {
    uint256 glpWethReward = IRewardTracker(FEE_GLP_TRACKER).claimable(address(this));
    uint256 gmxWethReward = IRewardTracker(FEE_GMX_TRACKER).claimable(address(this));
    uint256 _wethPrice = IVault(gmxVault).getMinPrice(WETH);
    return (glpWethReward.add(gmxWethReward)).muldiv(_wethPrice, getGlpPrice()).div(SMALL_BASE).div(SMALL_BASE);
  }

  function getGlpPrice() public view returns (uint256) {
    return IGlpManager(GLP_MANAGER).getAum(true).muldiv(SMALL_BASE, IERC20Upgradeable(GLP).totalSupply());
  }

//   ===== Permissioned Actions: Governance =====

  function setGovernance(address _governor) external onlyGovernor {
    governor = _governor;
    emit GovernanceSet(governor);
  }

  function setAdmin(address _admin) external {
    require(msg.sender == admin || msg.sender == governor);
    admin = _admin;
    emit AdminSet(admin);
  }

  function setGuardian(address _guardian) external onlyGovernor {
    guardian = _guardian;
    emit GuardianSet(guardian);
  }

  function setFees(uint256 _performanceFee, uint256 _managementFee) external onlyGovernor {
    // ensure performanceFee is smaller than 50% and management fee is smaller than 5%
    require(_performanceFee < 5000 && _managementFee < 500);
    performanceFee = _performanceFee;
    managementFee = _managementFee;
    emit FeeSet(performanceFee, managementFee);
  }

  function setLeverage(uint256 _leverage) external onlyGovernor {
    require(_leverage >= 1 && _leverage <= 50);
    leverage = _leverage;
    emit LeverageSet(leverage);
  }

  function setIsLong(bool _isLong) external nonReentrant onlyGovernor {
    closeTrade();
    isLong = _isLong;
    emit isLongSet(isLong);
  }

  function setGmxContracts(address _gmxPositionManager, address _gmxRouter, address _gmxVault) external onlyGovernor {
    gmxPositionManager = _gmxPositionManager;
    gmxRouter = _gmxRouter;
    gmxVault = _gmxVault;
    emit GmxContractsSet(gmxPositionManager, gmxRouter, gmxVault);
  }

  function setParameters(
    bool _isDepositEnabled,
    bool _disablePokeInterval,
    uint256 _maxCollateralMultiplier,
    uint256 _cap,
    uint256 _pokeInterval,
    uint256 _withdrawInterval,
    bool _isKeeperOnly,
    bool _isFreeWithdraw,
    address _rewards
  ) external onlyGovernor {
    require(_maxCollateralMultiplier >= 1 && _maxCollateralMultiplier <= 50 && _pokeInterval > _withdrawInterval.mul(2), "!allowed");
    isDepositEnabled = _isDepositEnabled;
    disablePokeInterval = _disablePokeInterval;
    maxCollateralMultiplier = _maxCollateralMultiplier;
    cap = _cap;
    pokeInterval = _pokeInterval;
    withdrawInterval = _withdrawInterval;
    isKeeperOnly = _isKeeperOnly;
    isFreeWithdraw = _isFreeWithdraw;
    rewards = _rewards;
    emit ParametersSet(isDepositEnabled, maxCollateralMultiplier, cap, pokeInterval, withdrawInterval, isFreeWithdraw, isKeeperOnly, rewards);
  }

  // ===== Permissioned Actions: Admin =====

  function setKeeper(address _keeper, bool _isActive) external {
    require(msg.sender == admin);
    keepers[_keeper] = _isActive;
    emit KeeperSet(_keeper, _isActive);
  }

  function setVault(address fromVault, address toVault, bool isActive) external {
    require(msg.sender == admin);
    withdrawMapping[fromVault][toVault] = isActive;
    emit VaultSet(fromVault, toVault, isActive);
  }

  /// ===== Permissioned Actions: Guardian =====

  function pause() external {
    require(msg.sender == guardian);
    _pause();
  }

  /// ===== Permissioned Actions: Governance =====

  function unpause() external onlyGovernor {
    _unpause();
  }

  /// ===== Modifiers =====

  modifier onlyGovernor() {
    require(msg.sender == governor, "!gov");
    _;
  }

}
