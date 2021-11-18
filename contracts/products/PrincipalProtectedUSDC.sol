//// SPDX-License-Identifier: MIT
//pragma solidity ^0.7.6;
//
//import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
//import "@openzeppelin/contracts/math/SafeMath.sol";
//import "@openzeppelin/contracts/utils/Address.sol";
//import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
//import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
//import '@openzeppelin/contracts-upgradeable/proxy/Initializable.sol';
//import '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';
//import '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
//import "../interfaces/IVovoVault.sol";
//import "../interfaces/curve/Gauge.sol";
//import "../interfaces/curve/Curve.sol";
//import "../interfaces/uniswap/Uni.sol";
//import "../interfaces/gmx/IRouter.sol";
//import "../interfaces/gmx/IVault.sol";
//
//
//contract PrincipalProtectedUSDC is Initializable, ERC20Upgradeable {
//  using SafeERC20 for IERC20;
//  using Address for address;
//  using SafeMath for uint256;
//
//  // usdc token address
//  address public constant usdc = address(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
//  // weth token address
//  address public constant weth = address(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
//  // crv token address
//  address public constant crv = address(0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978);
//  // curve LP token address
//  address public constant _2crv = address(0x7f90122BF0700F9E7e1F688fe926940E8839F353);
//  // curve gauge address
//  address public constant gauge = address(0xbF7E49483881C76487b0989CD7d9A8239B20CA41);
//  // curve 3pool address
//  address public constant _2pool = address(0x7f90122BF0700F9E7e1F688fe926940E8839F353);
//  // gmx router address
//  address public constant gmxRouter = address(0xaBBc5F99639c9B6bCb58544ddf04EFA6802F4064);
//  // gmx vault address
//  address public constant gmxVault = address(0x489ee077994B6658eAfA855C308275EAd8097C4A);
//  // sushiswap address
//  address public constant sushiswap = address(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506);
//
//  uint256 public constant FEE_DENOMINATOR = 10000;
//  uint256 public constant DENOMINATOR = 10000;
//
//  uint256 public withdrawalFee;
//  uint256 public performanceFee;
//  uint256 public slip;
//  uint256 public sizeDelta;
//  uint256 public totalFarmReward; // lifetime farm reward earnings
//  uint256 public totalTradeProfit; // lifetime trade profit
//  uint256 public cap;
//  bool public isDepositEnabled;
//  uint256 public leverage;
//  bool public isLong;
//  address public governor;
//  address public admin;
//  address public rewards;
//  address public dex;
//  /// mapping(keeperAddress => true/false)
//  mapping(address => bool) public keepers;
//  /// mapping(fromVault => mapping(toVault => true/false))
//  mapping(address => mapping(address => bool)) public withdrawMapping;
//
//  event Minted(address to, uint256 shares);
//  event LiquidityAdded(uint256 tokenAmount, uint256 lpMinted);
//  event GaugeDeposited(uint256 lpDeposited);
//  event Harvested(uint256 amount, uint256 totalFarmReward);
//  event OpenPosition(uint256 sizeDelta, bool isLong);
//  event ClosePosition(uint256 sizeDelta, bool isLong, uint256 pnl, uint256 fee);
//  event Withdraw(address to, uint256 amount, uint256 fee);
//  event WithdrawToVault(address owner, uint256 shares, address vault, uint256 receivedShares);
//  event GovernanceSet(address governor);
//  event AdminSet(address admin);
//  event PerformanceFeeSet(uint256 performanceFee);
//  event WithdrawalFeeSet(uint256 withdrawalFee);
//  event LeverageSet(uint256 leverage);
//  event isLongSet(bool isLong);
//  event RewardsSet(address rewards);
//  event SlipSet(uint256 slip);
//  event DepositEnabled(bool isDepositEnabled);
//  event CapSet(uint256 cap);
//  event KeeperAdded(address keeper);
//  event KeeperRemoved(address keeper);
//  event VaultRegistered(address fromVault, address toVault);
//  event VaultRevoked(address fromVault, address toVault);
//
//  function initialize(address _rewards, uint256 _leverage, bool _isLong, uint256 _cap) public initializer {
//    __ERC20_init("Vovo USDC PPV", "voUSDC");
//    governor = msg.sender;
//    admin = msg.sender;
//    rewards = _rewards;
//    leverage = _leverage;
//    isLong = _isLong;
//    cap = _cap;
//    dex = sushiswap;
//    keepers[msg.sender] = true;
//    isDepositEnabled = true;
//    withdrawalFee = 50;
//    performanceFee = 2000;
//    slip = 100;
//    sizeDelta = 0;
//  }
//
//
//  /**
//   * @notice Get the usd value of this vault: the value of lp + the value of usdc
//   */
//  function balance() public view returns (uint256) {
//    uint256 lpPrice = ICurveFi(_2pool).get_virtual_price();
//    uint256 lpAmount = Gauge(gauge).balanceOf(address(this));
//    uint256 lpValue = lpPrice.mul(lpAmount).div(1e30);
//    return lpValue.add(IERC20(usdc).balanceOf(address(this)));
//  }
//
//  /**
//   * @notice Add liquidity to curve and deposit the LP tokens to gauge
//   */
//  function earn() public {
//    uint256 usdcBalance = IERC20(usdc).balanceOf(address(this));
//    if (usdcBalance > 0) {
//      IERC20(usdc).safeApprove(_2pool, 0);
//      IERC20(usdc).safeApprove(_2pool, usdcBalance);
//      uint256 expected2cv = usdcBalance.mul(1e30).div(ICurveFi(_2pool).get_virtual_price());
//      uint256 lpMinted = ICurveFi(_2pool).add_liquidity([usdcBalance, 0], expected2cv.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR));
//      emit LiquidityAdded(usdcBalance, lpMinted);
//    }
//    uint256 lpBalance = IERC20(_2crv).balanceOf(address(this));
//    if (lpBalance > 0) {
//      IERC20(_2crv).safeApprove(gauge, 0);
//      IERC20(_2crv).safeApprove(gauge, lpBalance);
//      Gauge(gauge).deposit(lpBalance);
//      emit GaugeDeposited(lpBalance);
//    }
//  }
//
//  /**
//   * @notice Deposit all the token balance of the sender to this vault
//   */
//  function depositAll() external {
//    deposit(IERC20(usdc).balanceOf(msg.sender));
//  }
//
//  /**
//   * @notice Deposit token to this vault. The vault mints shares to the depositor.
//   * @param amount is the amount of token deposited
//   */
//  function deposit(uint256 amount) public {
//    uint256 _pool = balance();
//    require(isDepositEnabled && _pool.add(amount) < cap, "!deposit");
//    uint256 _before = IERC20(usdc).balanceOf(address(this));
//    IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
//    uint256 _after = IERC20(usdc).balanceOf(address(this));
//    amount = _after.sub(_before); // Additional check for deflationary usdcs
//    uint256 shares = 0;
//    if (totalSupply() == 0) {
//      shares = amount;
//    } else {
//      shares = (amount.mul(totalSupply())).div(_pool);
//    }
//    _mint(msg.sender, shares);
//    emit Minted(msg.sender, shares);
//  }
//
//
//  /**
//   * @notice 1. Collect reward from Curve Gauge; 2. Close old leverage trade;
//             3. Use the reward to open new leverage trade; 4. Deposit the trade profit and new user deposits into Curve to earn reward
//   */
//  function poke() external {
//    require(keepers[msg.sender] || msg.sender == governor, "!keepers");
//    uint256 usdcReward = 0;
//    if (Gauge(gauge).balanceOf(address(this)) > 0) {
//      usdcReward = collectReward();
//    }
//    if (sizeDelta > 0) {
//      closeTrade();
//    }
//    if (usdcReward > 0) {
//      openTrade(usdcReward);
//    }
//    earn();
//  }
//
//  /**
//   * @notice Claim rewards from the gauge and swap the rewards to usdc
//   * @return usdcReward the amount of usdc swapped from farm reward
//   */
//  function collectReward() private returns(uint256 usdcReward) {
//    uint256 _before = IERC20(usdc).balanceOf(address(this));
//    Gauge(gauge).claim_rewards();
//    uint256 _crv = IERC20(crv).balanceOf(address(this));
//    if (_crv > 0) {
//      IERC20(crv).safeApprove(dex, 0);
//      IERC20(crv).safeApprove(dex, _crv);
//
//      address[] memory path = new address[](3);
//      path[0] = crv;
//      path[1] = weth;
//      path[2] = usdc;
//      Uni(dex).swapExactTokensForTokens(_crv, uint256(0), path, address(this), block.timestamp.add(1800));
//    }
//    uint256 _after = IERC20(usdc).balanceOf(address(this));
//    usdcReward = _after.sub(_before);
//    totalFarmReward = totalFarmReward.add(usdcReward);
//    emit Harvested(usdcReward, totalFarmReward);
//  }
//
//  /**
//   * @notice Open leverage position at GMX
//   * @param amount the amount of token be used as leverage position collateral
//   */
//  function openTrade(uint256 amount) private {
//    address[] memory _path = new address[](2);
//    _path[0] = usdc;
//    _path[1] = weth;
//    uint256 _sizeDelta = leverage.mul(amount).mul(1e24);
//    uint256 _price = isLong ? IVault(gmxVault).getMaxPrice(weth) : IVault(gmxVault).getMinPrice(weth);
//    IERC20(usdc).safeApprove(gmxRouter, 0);
//    IERC20(usdc).safeApprove(gmxRouter, amount);
//    IRouter(gmxRouter).increasePosition(_path, weth, amount, 0, _sizeDelta, isLong, _price);
//    sizeDelta = _sizeDelta;
//    emit OpenPosition(sizeDelta, isLong);
//  }
//
//  /**
//   * @notice Close leverage position at GMX
//   */
//  function closeTrade() private {
//    (uint256 size,,,,,,,) = IVault(gmxVault).getPosition(address(this), weth, weth, isLong);
//    if (size == 0) {
//      return;
//    }
//    uint256 _before = IERC20(usdc).balanceOf(address(this));
//    uint256 price = isLong ? IVault(gmxVault).getMinPrice(weth) : IVault(gmxVault).getMaxPrice(weth);
//    IRouter(gmxRouter).decreasePosition(weth, weth, 0, sizeDelta, isLong, address(this), price);
//    address[] memory _path = new address[](2);
//    _path[0] = weth;
//    _path[1] = usdc;
//    uint256 wethBalance = IERC20(weth).balanceOf(address(this));
//    IERC20(weth).safeApprove(gmxRouter, 0);
//    IERC20(weth).safeApprove(gmxRouter, wethBalance);
//    IRouter(gmxRouter).swap(_path, wethBalance, 0, address(this));
//    uint256 _after = IERC20(usdc).balanceOf(address(this));
//    uint256 _tradeProfit = _after.sub(_before);
//    uint256 _fee = 0;
//    if (_tradeProfit > 0) {
//      _fee = _tradeProfit.mul(performanceFee).div(FEE_DENOMINATOR);
//      IERC20(usdc).safeTransfer(rewards, _fee);
//      totalTradeProfit = totalTradeProfit.add(_tradeProfit.sub(_fee));
//    }
//    emit ClosePosition(sizeDelta, isLong, _tradeProfit.sub(_fee), _fee);
//    sizeDelta = 0;
//  }
//
//  /**
//   * @notice Withdraw all the funds of the sender
//   */
//  function withdrawAll() external {
//    uint256 withdrawAmount = _withdraw(balanceOf(msg.sender), true);
//    IERC20(usdc).safeTransfer(msg.sender, withdrawAmount);
//  }
//
//  /**
//   * @notice Withdraw the funds for the `_shares` of the sender. Withdraw fee is deducted.
//   * @param shares is the shares of the sender to withdraw
//   */
//  function withdraw(uint256 shares) external {
//    uint256 withdrawAmount = _withdraw(shares, true);
//    IERC20(usdc).safeTransfer(msg.sender, withdrawAmount);
//  }
//
//  /**
//   * @notice Withdraw from this vault to another vault
//   * @param shares the number of this vault shares to be burned
//   * @param vault the address of destination vault
//   */
//  function withdrawToVault(uint256 shares, address vault) external {
//    require(vault != address(0), "!vault");
//    require(withdrawMapping[address(this)][vault], "Withdraw to vault not allowed");
//
//    // vault to vault transfer does not charge any withdraw fee
//    uint256 withdrawAmount = _withdraw(shares, false);
//    IERC20(usdc).safeApprove(vault, withdrawAmount);
//    IVovoVault(vault).deposit(withdrawAmount);
//    uint256 receivedShares = IERC20(vault).balanceOf(address(this));
//    IERC20(vault).safeTransfer(msg.sender, receivedShares);
//
//    emit Withdraw(msg.sender, withdrawAmount, 0);
//    emit WithdrawToVault(msg.sender, shares, vault, receivedShares);
//  }
//
//  function _withdraw(uint256 shares, bool shouldChargeFee) private returns(uint256 withdrawAmount) {
//    require(shares > 0, "!shares");
//    uint256 r = (balance().mul(shares)).div(totalSupply());
//    _burn(msg.sender, shares);
//
//    uint256 b = IERC20(usdc).balanceOf(address(this));
//    if (b < r) {
//      uint256 lpPrice = ICurveFi(_2pool).get_virtual_price();
//      // amount of LP tokens to withdraw
//      uint256 lpAmount = (r.sub(b)).mul(1e30).div(lpPrice);
//      _withdrawSome(lpAmount);
//      uint256 _after = IERC20(usdc).balanceOf(address(this));
//      uint256 _diff = _after.sub(b);
//      if (_diff < r.sub(b)) {
//        r = b.add(_diff);
//      }
//    }
//    uint256 fee = 0;
//    if (shouldChargeFee) {
//      fee = r.mul(withdrawalFee).div(FEE_DENOMINATOR);
//      IERC20(usdc).safeTransfer(rewards, fee);
//    }
//    withdrawAmount = r.sub(fee);
//    emit Withdraw(msg.sender, withdrawAmount, fee);
//  }
//
//  /**
//   * @notice Withdraw the asset that is accidentally sent to this address
//   * @param _asset is the token to withdraw
//   */
//  function withdrawAsset(address _asset) external {
//    require(keepers[msg.sender] || msg.sender == governor, "!keepers");
//    IERC20(_asset).safeTransfer(msg.sender, IERC20(_asset).balanceOf(address(this)));
//  }
//
//  /**
//   * @notice Withdraw the LP tokens from Gauge, and then withdraw usdc from Curve vault
//   * @param lpAmount is the amount of LP tokens to withdraw
//   */
//  function _withdrawSome(uint256 lpAmount) private {
//    uint256 _before = IERC20(_2crv).balanceOf(address(this));
//    Gauge(gauge).withdraw(lpAmount);
//    uint256 _after = IERC20(_2crv).balanceOf(address(this));
//    _withdrawOne(_after.sub(_before));
//  }
//
//  /**
//   * @notice Withdraw usdc from Curve vault
//   * @param _amnt is the amount of LP tokens to withdraw
//   */
//  function _withdrawOne(uint256 _amnt) private {
//    IERC20(_2crv).safeApprove(_2pool, 0);
//    IERC20(_2crv).safeApprove(_2pool, _amnt);
//    ICurveFi(_2pool).remove_liquidity_one_coin(_amnt, 0, _amnt.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR));
//  }
//
//  function getPricePerShare() external view returns (uint256) {
//    return balance().mul(1e18).div(totalSupply());
//  }
//
//  function setGovernance(address _governor) external onlyGovernor {
//    governor = _governor;
//    emit GovernanceSet(governor);
//  }
//
//  function setAdmin(address _admin) external {
//    require(msg.sender == admin || msg.sender == governor, "!authorized");
//    admin = _admin;
//    emit AdminSet(admin);
//  }
//
//  function setPerformanceFee(uint256 _performanceFee) external onlyGovernor {
//    performanceFee = _performanceFee;
//    emit PerformanceFeeSet(performanceFee);
//  }
//
//  function setWithdrawalFee(uint256 _withdrawalFee) external onlyGovernor {
//    withdrawalFee = _withdrawalFee;
//    emit WithdrawalFeeSet(withdrawalFee);
//  }
//
//  function setLeverage(uint256 _leverage) external onlyGovernor {
//    leverage = _leverage;
//    emit LeverageSet(leverage);
//  }
//
//  function setIsLong(bool _isLong) external onlyGovernor {
//    isLong = _isLong;
//    emit isLongSet(isLong);
//  }
//
//  function setRewards(address _rewards) public onlyGovernor {
//    rewards = _rewards;
//    emit RewardsSet(rewards);
//  }
//
//  function setSlip(uint256 _slip) public onlyGovernor {
//    slip = _slip;
//    emit SlipSet(slip);
//  }
//
//  function setDepositEnabled(bool _flag) public onlyGovernor {
//    isDepositEnabled = _flag;
//    emit DepositEnabled(isDepositEnabled);
//  }
//
//  function setCap(uint256 _cap) public onlyGovernor {
//    cap = _cap;
//    emit CapSet(cap);
//  }
//
//  function addKeeper(address _keeper) external onlyAdmin {
//    keepers[_keeper] = true;
//    emit KeeperAdded(_keeper);
//  }
//
//  function removeKeeper(address _keeper) external onlyAdmin {
//    keepers[_keeper] = false;
//    emit KeeperRemoved(_keeper);
//  }
//
//  function registerVault(address fromVault, address toVault) external onlyAdmin {
//    withdrawMapping[fromVault][toVault] = true;
//    emit VaultRegistered(fromVault, toVault);
//  }
//
//  function revokeVault(address fromVault, address toVault) external onlyAdmin {
//    withdrawMapping[fromVault][toVault] = false;
//    emit VaultRevoked(fromVault, toVault);
//  }
//
//  modifier onlyGovernor() {
//    require(msg.sender == governor, "!governor");
//    _;
//  }
//
//  modifier onlyAdmin() {
//    require(msg.sender == admin, "!admin");
//    _;
//  }
//
//}
