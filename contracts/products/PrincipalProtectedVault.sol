// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import '@openzeppelin/contracts-upgradeable/proxy/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import "../interfaces/IVovoVault.sol";
import "../interfaces/curve/Gauge.sol";
import "../interfaces/curve/Curve.sol";
import "../interfaces/uniswap/Uni.sol";
import "../interfaces/gmx/IRouter.sol";
import "../interfaces/gmx/IVault.sol";
import "../interfaces/curve/GaugeFactory.sol";

/**
 * @title PrincipalProtectedVault
 * @dev A vault that receives vaultToken from users, and then deposits the vaultToken into yield farming pools.
 * Periodically, the vault collects the yield rewards and uses the rewards to open a leverage trade on a perpetual swap exchange.
 */
contract PrincipalProtectedVault is Initializable, ERC20Upgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMath for uint256;

  // usdc token address
  address public constant usdc = address(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
  // crv token address
  address public constant crv = address(0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978);

  uint256 public constant FEE_DENOMINATOR = 10000;
  uint256 public constant DENOMINATOR = 10000;

  address public vaultToken; // deposited token of the vault
  address public underlying; // underlying token of the leverage position
  address public lpToken;
  address public gauge;
  uint256 public managementFee;
  uint256 public performanceFee;
  uint256 public slip;
  uint256 public maxCollateralMultiplier;
  uint256 public cap;
  uint256 public vaultTokenBase;
  uint256 public underlyingBase;
  uint256 public lastPokeTime;
  uint256 public pokeInterval;
  uint256 public currentTokenReward;
  uint256 public currentPokeInterval;
  bool public isKeeperOnly;
  bool public isDepositEnabled;
  uint256 public leverage;
  bool public isLong;
  address public governor;
  address public admin;
  address public guardian;
  address public rewards;
  address public dex;
  address public gmxPositionManager;
  address public gmxRouter;
  address public gmxVault;
  /// mapping(keeperAddress => true/false)
  mapping(address => bool) public keepers;
  /// mapping(fromVault => mapping(toVault => true/false))
  mapping(address => mapping(address => bool)) public withdrawMapping;

  // added these two parameters in the upgraded contract to move liquidity to new gauge because of the Curve gauge migration:
  // https://gov.curve.fi/t/sidechain-gauge-upgrade-and-migration/3869
  address public constant newGauge = address(0xCE5F24B7A95e9cBa7df4B54E911B4A3Dc8CDAf6f);
  address public constant gaugeFactory = address(0xabC000d88f23Bb45525E447528DBF656A9D55bf5);

  event Deposit(address depositor, address account, uint256 amount, uint256 shares);
  event LiquidityAdded(uint256 tokenAmount, uint256 lpMinted);
  event GaugeDeposited(uint256 lpDeposited);
  event Poked(uint256 pricePerShare, uint256 feeShare);
  event OpenPosition(address underlying, uint256 underlyingPrice, uint256 vaultTokenPrice, uint256 sizeDelta, bool isLong, uint256 collateralAmountVaultToken);
  event ClosePosition(address underlying, uint256 underlyingPrice, uint256 vaultTokenPrice,uint256 sizeDelta, bool isLong, uint256 collateralAmountVaultToken, uint256 fee);
  event Withdraw(address account, uint256 amount, uint256 shares);
  event WithdrawToVault(address owner, uint256 shares, address vault, uint256 receivedShares);
  event GovernanceSet(address governor);
  event AdminSet(address admin);
  event GuardianSet(address guardian);
  event FeeSet(uint256 performanceFee, uint256 withdrawalFee);
  event isLongSet(bool isLong);
  event GmxContractsSet(address gmxPositionManager, address gmxRouter, address gmxVault);
  event MaxCollateralMultiplierSet(uint256 maxCollateralMultiplier);
  event ParametersSet(bool isDepositEnabled, uint256 cap, uint256 pokeInterval, bool isKeeperOnly);
  event KeeperAdded(address keeper);
  event KeeperRemoved(address keeper);
  event VaultRegistered(address fromVault, address toVault);
  event VaultRevoked(address fromVault, address toVault);

  function initialize(
    string memory _vaultName,
    string memory _vaultSymbol,
    uint8 _vaultDecimal,
    address _vaultToken,
    address _underlying,
    address _lpToken,
    address _gauge,
    address _rewards,
    uint256 _leverage,
    bool _isLong,
    uint256 _cap,
    uint256 _vaultTokenBase,
    uint256 _underlyingBase,
    address _dex
  ) public initializer {
    __ERC20_init(_vaultName, _vaultSymbol);
    _setupDecimals(_vaultDecimal);
    __Pausable_init();
    vaultToken = _vaultToken;
    underlying = _underlying;
    lpToken = _lpToken;
    gauge = _gauge;
    rewards = _rewards;
    leverage = _leverage;
    isLong = _isLong;
    cap = _cap;
    vaultTokenBase = _vaultTokenBase;
    underlyingBase = _underlyingBase;
    dex = _dex;
    lastPokeTime = block.timestamp;
    pokeInterval = 7 days;
    governor = msg.sender;
    admin = msg.sender;
    guardian = msg.sender;
    gmxPositionManager = address(0x87a4088Bd721F83b6c2E5102e2FA47022Cb1c831);
    gmxRouter = address(0xaBBc5F99639c9B6bCb58544ddf04EFA6802F4064);
    gmxVault = address(0x489ee077994B6658eAfA855C308275EAd8097C4A);
    keepers[msg.sender] = true;
    isKeeperOnly = true;
    isDepositEnabled = true;
    managementFee = 200;
    performanceFee = 1000;
    slip = 30;
    maxCollateralMultiplier = leverage;
  }


  /**
   * @notice Get the value of this vault in vaultToken:
   * @param isMax the flag for optimistic or pessimistic calculation of the vault value
   * if isMax is true: the value of lp in vaultToken + the amount of vaultToken in this contract + the value of open leveraged position + estimated pending rewards
   * if isMax is false: the value of lp in vaultToken + the amount of vaultToken in this contract
   */
  function balance(bool isMax) public view returns (uint256) {
    uint256 lpPrice = ICurveFi(lpToken).get_virtual_price();
    uint256 lpAmount = Gauge(newGauge).balanceOf(address(this));
    uint256 lpValue = lpPrice.mul(lpAmount).mul(vaultTokenBase).div(1e36);
    if (isMax) {
      return lpValue.add(getActivePositionValue()).add(getEstimatedPendingRewardValue()).add(IERC20(vaultToken).balanceOf(address(this)));
    }
    return lpValue.add(IERC20(vaultToken).balanceOf(address(this)));
  }

  /**
   * @notice Add liquidity to curve and deposit the LP tokens to gauge
   */
  function earn() public whenNotPaused {
    require(keepers[msg.sender] || !isKeeperOnly, "!keepers");
    uint256 tokenBalance = IERC20(vaultToken).balanceOf(address(this));
    if (tokenBalance > 0) {
      IERC20(vaultToken).safeApprove(lpToken, 0);
      IERC20(vaultToken).safeApprove(lpToken, tokenBalance);
      uint256 expectedLpAmount = tokenBalance.mul(1e18).div(vaultTokenBase).mul(1e18).div(ICurveFi(lpToken).get_virtual_price());
      uint256 lpMinted = ICurveFi(lpToken).add_liquidity([tokenBalance, 0], expectedLpAmount.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR));
      emit LiquidityAdded(tokenBalance, lpMinted);
    }
    uint256 lpBalance = IERC20(lpToken).balanceOf(address(this));
    if (lpBalance > 0) {
      IERC20(lpToken).safeApprove(newGauge, 0);
      IERC20(lpToken).safeApprove(newGauge, lpBalance);
      Gauge(newGauge).deposit(lpBalance);
      emit GaugeDeposited(lpBalance);
    }
  }

  /**
   * @notice Deposit token to this vault. The vault mints shares to the depositor.
   * @param amount is the amount of token deposited
   */
  function deposit(uint256 amount) external {
      depositFor(amount, msg.sender);
  }

  /**
   * @notice Deposit token to this vault. The vault mints shares to the account.
   * @param amount is the amount of token deposited
   * @param account is the account to deposit for
   */
  function depositFor(uint256 amount, address account) public whenNotPaused nonReentrant {
    uint256 _pool = balance(true); // use max vault balance for deposit
    require(isDepositEnabled && _pool.add(amount) < cap, "!deposit");
    uint256 _before = IERC20(vaultToken).balanceOf(address(this));
    IERC20(vaultToken).safeTransferFrom(msg.sender, address(this), amount);
    uint256 _after = IERC20(vaultToken).balanceOf(address(this));
    amount = _after.sub(_before);
    uint256 shares = 0;
    if (totalSupply() == 0) {
      shares = amount;
    } else {
      shares = (amount.mul(totalSupply())).div(_pool);
    }
    require(shares > 0, "!shares");
    _mint(account, shares);
    emit Deposit(msg.sender, account, amount, shares);
  }


  /**
   * @notice 1. Collect reward from Curve Gauge; 2. Close old leverage trade;
             3. Use the reward to open new leverage trade; 4. Deposit the trade profit and new user deposits into Curve to earn reward
   */
  function poke() external whenNotPaused nonReentrant {
    require(keepers[msg.sender] || !isKeeperOnly, "!keepers");
    require(lastPokeTime.add(pokeInterval) < block.timestamp, "!poke time");
    // collect management fee by minting shares to reward recipient
    uint256 feeShare = totalSupply().mul(managementFee).mul(block.timestamp.sub(lastPokeTime)).div(86400*365).div(FEE_DENOMINATOR);
    _mint(rewards, feeShare);
    currentPokeInterval = block.timestamp.sub(lastPokeTime);
    uint256 tokenReward = 0;
    if (Gauge(newGauge).balanceOf(address(this)) > 0) {
      tokenReward = collectReward();
    }
    closeTrade();
    if (tokenReward > 0) {
      openTrade(tokenReward);
    }
    currentTokenReward = tokenReward;
    earn();
    lastPokeTime = block.timestamp;
    emit Poked(getPricePerShare(false), feeShare);
  }

  /**
   * @notice Only can be called by keepers in case the poke() does not work
   *         Claim rewards from the gauge and swap the rewards to the vault token
   * @return tokenReward the amount of vault token swapped from farm reward
   */
  function collectRewardByKeeper() external whenNotPaused nonReentrant returns(uint256 tokenReward) {
    require(keepers[msg.sender], "!keepers");
    tokenReward = collectReward();
  }

  /**
   * @notice Claim rewards from the gauge and swap the rewards to the vault token
   * @return tokenReward the amount of vault token swapped from farm reward
   */
  function collectReward() private returns(uint256 tokenReward) {
    uint256 _before = IERC20(vaultToken).balanceOf(address(this));
    GaugeFactory(gaugeFactory).mint(newGauge);
    uint256 _crv = IERC20(crv).balanceOf(address(this));
    if (_crv > 0) {
      IERC20(crv).safeApprove(dex, 0);
      IERC20(crv).safeApprove(dex, _crv);
      Uni(dex).swap(crv, vaultToken, _crv);
    }
    uint256 _after = IERC20(vaultToken).balanceOf(address(this));
    tokenReward = _after.sub(_before);
  }

  /**
   * @notice Open leverage position at GMX
   * @param amount the amount of token be used as leverage position collateral
   */
  function openTrade(uint256 amount) private {
    address[] memory _path;
    address collateral = isLong ? underlying : usdc;
    if (vaultToken == collateral) {
      _path = new address[](1);
      _path[0] = vaultToken;
    } else {
      _path = new address[](2);
      _path[0] = vaultToken;
      _path[1] = collateral;
    }
    uint256 _underlyingPrice = isLong ? IVault(gmxVault).getMaxPrice(underlying) : IVault(gmxVault).getMinPrice(underlying);
    uint256 _vaultTokenPrice = IVault(gmxVault).getMinPrice(vaultToken);
    uint256 _sizeDelta = leverage.mul(amount).mul(_vaultTokenPrice).div(vaultTokenBase);
    IERC20(vaultToken).safeApprove(gmxRouter, 0);
    IERC20(vaultToken).safeApprove(gmxRouter, amount);
    IRouter(gmxRouter).approvePlugin(gmxPositionManager);
    IRouter(gmxPositionManager).increasePosition(_path, underlying, amount, 0, _sizeDelta, isLong, _underlyingPrice);
    emit OpenPosition(underlying, _underlyingPrice, _vaultTokenPrice, _sizeDelta, isLong, amount);
  }

  /**
   * @notice Only can be called by keepers to close the position in case the poke() does not work
   */
  function closeTradeByKeeper() external whenNotPaused nonReentrant {
    require(keepers[msg.sender], "!keepers");
    closeTrade();
  }

  /**
   * @notice Close leverage position at GMX
   */
  function closeTrade() private {
    address collateral = isLong ? underlying : usdc;
    (uint256 size,,,,,,,) = IVault(gmxVault).getPosition(address(this), collateral, underlying, isLong);
    uint256 _underlyingPrice = isLong ? IVault(gmxVault).getMinPrice(underlying) : IVault(gmxVault).getMaxPrice(underlying);
    uint256 _vaultTokenPrice = IVault(gmxVault).getMinPrice(vaultToken);
    if (size == 0) {
      emit ClosePosition(underlying, _underlyingPrice, _vaultTokenPrice, size, isLong, 0, 0);
      return;
    }
    uint256 _before = IERC20(vaultToken).balanceOf(address(this));
    IRouter(gmxRouter).approvePlugin(gmxPositionManager);
    if (vaultToken == collateral) {
      IRouter(gmxPositionManager).decreasePosition(collateral, underlying, 0, size, isLong, address(this), _underlyingPrice);
    } else {
      address[] memory path = new address[](2);
      path = new address[](2);
      path[0] = collateral;
      path[1] = vaultToken;
      IRouter(gmxPositionManager).decreasePositionAndSwap(path, underlying, 0, size, isLong, address(this), _underlyingPrice, 0);
    }
    uint256 _after = IERC20(vaultToken).balanceOf(address(this));
    uint256 _tradeProfit = _after.sub(_before);
    uint256 _fee = 0;
    if (_tradeProfit > 0) {
      _fee = _tradeProfit.mul(performanceFee).div(FEE_DENOMINATOR);
      IERC20(vaultToken).safeTransfer(rewards, _fee);
    }
    emit ClosePosition(underlying, _underlyingPrice, _vaultTokenPrice, size, isLong, _tradeProfit, _fee);
  }

  /**
   * @notice Withdraw the funds for the `_shares` of the sender. Withdraw fee is deducted.
   * @param shares is the shares of the sender to withdraw
   */
  function withdraw(uint256 shares) external whenNotPaused nonReentrant {
    uint256 withdrawAmount = _withdraw(shares);
    IERC20(vaultToken).safeTransfer(msg.sender, withdrawAmount);
  }

  /**
   * @notice Withdraw from this vault to another vault
   * @param shares the number of this vault shares to be burned
   * @param vault the address of destination vault
   */
  function withdrawToVault(uint256 shares, address vault) external whenNotPaused nonReentrant {
    require(vault != address(0), "!vault");
    require(withdrawMapping[address(this)][vault], "Withdraw to vault not allowed");

    // vault to vault transfer does not charge any withdraw fee
    uint256 withdrawAmount = _withdraw(shares);
    IERC20(vaultToken).safeApprove(vault, withdrawAmount);
    IVovoVault(vault).deposit(withdrawAmount);
    uint256 receivedShares = IERC20(vault).balanceOf(address(this));
    IERC20(vault).safeTransfer(msg.sender, receivedShares);

    emit Withdraw(msg.sender, withdrawAmount, shares);
    emit WithdrawToVault(msg.sender, shares, vault, receivedShares);
  }

  function _withdraw(uint256 shares) private returns(uint256 withdrawAmount) {
    require(shares > 0, "!shares");
    withdrawAmount = (balance(false).mul(shares)).div(totalSupply()); // use minimum vault balance for withdraw
    _burn(msg.sender, shares);

    uint256 b = IERC20(vaultToken).balanceOf(address(this));
    if (b < withdrawAmount) {
      uint256 lpPrice = ICurveFi(lpToken).get_virtual_price();
      // amount of LP tokens to withdraw
      uint256 lpAmount = (withdrawAmount.sub(b)).mul(1e18).div(vaultTokenBase).mul(1e18).div(lpPrice);
      _withdrawSome(lpAmount);
      uint256 _after = IERC20(vaultToken).balanceOf(address(this));
      uint256 _diff = _after.sub(b);
      if (_diff < withdrawAmount.sub(b)) {
          withdrawAmount = b.add(_diff);
      }
    }
    emit Withdraw(msg.sender, withdrawAmount, shares);
  }

  /**
   * @notice Withdraw the asset that is accidentally sent to this address
   * @param _asset is the token to withdraw
   */
  function withdrawAsset(address _asset) external onlyGovernor {
    require(_asset != vaultToken, "!vaultToken");
    IERC20(_asset).safeTransfer(msg.sender, IERC20(_asset).balanceOf(address(this)));
  }

  /**
   * @notice Withdraw the LP tokens from Gauge, and then withdraw vaultToken from Curve vault
   * @param lpAmount is the amount of LP tokens to withdraw
   */
  function _withdrawSome(uint256 lpAmount) private {
    uint256 _before = IERC20(lpToken).balanceOf(address(this));
    Gauge(newGauge).withdraw(lpAmount);
    uint256 _after = IERC20(lpToken).balanceOf(address(this));
    _withdrawOne(_after.sub(_before));
  }

  /**
   * @notice Withdraw vaultToken from Curve vault
   * @param _amnt is the amount of LP tokens to withdraw
   */
  function _withdrawOne(uint256 _amnt) private {
    IERC20(lpToken).safeApprove(lpToken, 0);
    IERC20(lpToken).safeApprove(lpToken, _amnt);
    uint256 expectedVaultTokenAmount = _amnt.mul(vaultTokenBase).mul(ICurveFi(lpToken).get_virtual_price()).div(1e36);
    ICurveFi(lpToken).remove_liquidity_one_coin(_amnt, 0, expectedVaultTokenAmount.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR));
  }

  /**
   * @notice Add this function in the upgraded contract to move liquidity to new gauge because of the Curve gauge migration:
   * https://gov.curve.fi/t/sidechain-gauge-upgrade-and-migration/3869
   */
  function migrateToNewGauge() external onlyAdmin {
    Gauge(gauge).withdraw(Gauge(gauge).balanceOf(address(this)));
    uint256 lpBalance = IERC20(lpToken).balanceOf(address(this));
    IERC20(lpToken).safeApprove(newGauge, 0);
    IERC20(lpToken).safeApprove(newGauge, lpBalance);
    Gauge(newGauge).deposit(lpBalance);
  }

  /// ===== View Functions =====

  function getPricePerShare(bool isMax) public view returns (uint256) {
    return balance(isMax).mul(1e18).div(totalSupply());
  }

  /**
   * @notice get the active leverage position value in vaultToken
   */
  function getActivePositionValue() public view returns (uint256) {
    address collateral = isLong ? underlying : usdc;
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
      positionValueUsd = collateralAmount.add(delta) > feeUsd ? collateralAmount.add(delta).sub(feeUsd) : 0;
    } else {
      positionValueUsd = collateralAmount > delta.add(feeUsd) ? collateralAmount.sub(delta).sub(feeUsd) : 0;
    }
    uint256 positionValue = IVault(gmxVault).usdToTokenMin(vaultToken, positionValueUsd);
    // Cap the positionValue to avoid the oracle manipulation
    if (positionValue > currentTokenReward.mul(maxCollateralMultiplier)) {
      positionValue = currentTokenReward.mul(maxCollateralMultiplier);
    }
    return positionValue;
  }

  /**
   * @notice get the estimated pending reward value in vaultToken, based on the reward from last period
   */
  function getEstimatedPendingRewardValue() public view returns(uint256) {
    if (currentPokeInterval == 0) {
      return 0;
    }
    return currentTokenReward.mul(block.timestamp.sub(lastPokeTime)).div(currentPokeInterval);
  }

  /// ===== Permissioned Actions: Governance =====

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

  function setFees(uint256 _performanceFee, uint256 _managementFee) external onlyGovernor {
    // ensure performanceFee is smaller than 50% and management fee is smaller than 5%
    require(_performanceFee < 5000 && _managementFee < 500, "!too-much");
    performanceFee = _performanceFee;
    managementFee = _managementFee;
    emit FeeSet(performanceFee, managementFee);
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

  function setMaxCollateralMultiplier(uint256 _maxCollateralMultiplier) external onlyGovernor {
    require(_maxCollateralMultiplier >= 1 && _maxCollateralMultiplier <= 50, "!maxCollateralMultiplier");
    maxCollateralMultiplier = _maxCollateralMultiplier;
    emit MaxCollateralMultiplierSet(maxCollateralMultiplier);
  }

  function setParameters(
    bool _flag,
    uint256 _cap,
    uint256 _pokeInterval,
    bool _isKeeperOnly,
    uint256 _slip,
    address _dex,
    address _rewards,
    uint256 _leverage
  ) external onlyGovernor {
    require(_leverage >= 1 && _leverage <= 50, "!leverage");
    isDepositEnabled = _flag;
    cap = _cap;
    pokeInterval = _pokeInterval;
    isKeeperOnly = _isKeeperOnly;
    slip = _slip;
    dex = _dex;
    rewards = _rewards;
    leverage = _leverage;
    emit ParametersSet(isDepositEnabled, cap, pokeInterval, isKeeperOnly);
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
