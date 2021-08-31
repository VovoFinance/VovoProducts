// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../interfaces/curve/Gauge.sol";
import "../interfaces/curve/Mintr.sol";
import "../interfaces/curve/Curve.sol";
import "../interfaces/uniswap/Uni.sol";
import "../interfaces/gambit/IRouter.sol";
import "../interfaces/gambit/IVault.sol";

contract PrincipalProtectedVault is ERC20 {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMath for uint256;

  // usdc token address
  address public constant usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
  // weth token address
  address public constant weth = address(0x2170Ed0880ac9A755fd29B2688956BD959F933F8);
  // crv token address
  address public constant crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
  // curve LP token address
  address public constant _3crv = address(0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490);
  // curve gauge address
  address public constant gauge = address(0xbFcF63294aD7105dEa65aA58F8AE5BE2D9d0952A);
  // curve 3pool address
  address public constant _3pool = address(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7);
  // crv token minter
  address public constant mintr = address(0xd061D61a4d941c39E5453435B6345Dc261C2fcE0);
  // gmx router address
  address public constant router = address(0xD46B23D042E976F8666F554E928e0Dc7478a8E1f);
  // gmx vault address
  address public constant vault = address(0xc73A8DcAc88498FD4b4B1b2AaA37b0a2614Ff67B);
  // sushiswap address
  address public constant sushiswap = address(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

  uint256 public withdrawalFee = 50;
  uint256 public performanceFee = 2000;
  uint256 public constant FEE_DENOMINATOR = 10000;
  uint256 public constant DENOMINATOR = 10000;
  uint256 public slip = 100;
  uint256 public leverage = 20;
  uint256 public sizeDelta = 0;
  bool public isLong = true;

  uint256 public totalFarmReward; // lifetime farm reward earnings
  uint256 public totalTradeProfit; // lifetime trade profit
  address public keeper;
  address public governance;
  address public rewards;
  address public dex;

  event Harvested(uint256 amount, uint256 totalFarmReward);
  event OpenPosition(uint256 sizeDelta, bool isLong);
  event ClosePosition(uint256 sizeDelta, bool isLong, uint256 pnl);

  constructor(address _keeper, address _rewards)
  ERC20("vovo usdc", "voUSDC") public {
    governance = msg.sender;
    keeper = _keeper;
    rewards = _rewards;
    dex = sushiswap;
  }

  /**
   * @notice Get the usd value of this vault: the value of lp + the value of usdc
   */
  function balance() public view returns (uint256) {
    uint256 lpPrice = ICurveFi(_3pool).get_virtual_price();
    uint256 lpAmount = Gauge(gauge).balanceOf(address(this));
    uint256 lpValue = lpPrice.mul(lpAmount);
    return lpValue.add(IERC20(usdc).balanceOf(address(this)));
  }

  function setGovernance(address _governance) public {
    require(msg.sender == governance, "!governance");
    governance = _governance;
  }

  function setWithdrawalFee(uint256 _withdrawalFee) external {
    require(msg.sender == governance, "!governance");
    withdrawalFee = _withdrawalFee;
  }

  function setLeverage(uint256 _leverage) external {
    require(msg.sender == governance, "!governance");
    leverage = _leverage;
  }

  function setIsLong(bool _isLong) external {
    require(msg.sender == governance, "!governance");
    isLong = _isLong;
  }

  function setRewards(address _rewards) public {
    require(msg.sender == governance, "!governance");
    rewards = _rewards;
  }

  function changeDex(address _dex) external {
    require(msg.sender == governance, "!authorized");
    dex = _dex;
  }

  /**
   * @notice Add liquidity to curve and deposit the LP tokens to gauge
   */
  function earn() public {
    uint256 _usdc = IERC20(usdc).balanceOf(address(this));
    if (_usdc > 0) {
      IERC20(usdc).safeApprove(_3pool, 0);
      IERC20(usdc).safeApprove(_3pool, _usdc);
      uint256 v = _usdc.mul(1e30).div(ICurveFi(_3pool).get_virtual_price());
      ICurveFi(_3pool).add_liquidity([0, _usdc, 0], v.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR));
    }
    uint256 _3crvBalance = IERC20(_3crv).balanceOf(address(this));
    if (_3crvBalance > 0) {
      IERC20(_3crv).safeApprove(gauge, 0);
      IERC20(_3crv).safeApprove(gauge, _3crvBalance);
      Gauge(gauge).deposit(_3crvBalance);
    }
  }

  /**
   * @notice Deposit all the token balance of the sender to this vault
   */
  function depositAll() external {
    deposit(IERC20(usdc).balanceOf(msg.sender));
  }

  /**
   * @notice Deposit token to this vault. The vault mints shares to the depositor.
   * @param _amount is the amount of token deposited
   */
  function deposit(uint256 _amount) public {
    uint256 _pool = balance();
    uint256 _before = IERC20(usdc).balanceOf(address(this));
    IERC20(usdc).safeTransferFrom(msg.sender, address(this), _amount);
    uint256 _after = IERC20(usdc).balanceOf(address(this));
    _amount = _after.sub(_before); // Additional check for deflationary usdcs
    uint256 shares = 0;
    if (totalSupply() == 0) {
      shares = _amount;
    } else {
      shares = (_amount.mul(totalSupply())).div(_pool);
    }
    _mint(msg.sender, shares);
  }


  /**
   * @notice 1. Collect reward from Curve Gauge; 2. Close old leverage trade;
             3. Use the reward to open new leverage trade; 4. Deposit the trade profit and new user deposits into Curve to earn reward
   */
  function poke() external {
    require(msg.sender == keeper || msg.sender == governance, "!keepers");
    uint256 usdcReward = 0;
    if (Gauge(gauge).balanceOf(address(this)) > 0) {
      usdcReward = collectReward();
    }
    if (sizeDelta > 0) {
      closeTrade();
    }
    if (usdcReward > 0) {
      openTrade(usdcReward);
    }
    earn();
  }

  /**
   * @notice Claim rewards from the gauge and swap the rewards to usdc
   * @return usdcReward the amount of usdc swapped from farm reward
   */
  function collectReward() internal returns(uint256 usdcReward) {
    uint256 _before = IERC20(usdc).balanceOf(address(this));
    Mintr(mintr).mint(gauge);
    uint256 _crv = IERC20(crv).balanceOf(address(this));
    if (_crv > 0) {

      IERC20(crv).safeApprove(dex, 0);
      IERC20(crv).safeApprove(dex, _crv);

      address[] memory path = new address[](3);
      path[0] = crv;
      path[1] = weth;
      path[2] = usdc;

      Uni(dex).swapExactTokensForTokens(_crv, uint256(0), path, address(this), block.timestamp.add(1800));
    }
    uint256 _after = IERC20(usdc).balanceOf(address(this));
    usdcReward = _after.sub(_before);
    totalFarmReward = totalFarmReward.add(usdcReward);
    emit Harvested(usdcReward, totalFarmReward);
  }

  /**
   * @notice Open leverage position at GMX
   */
  function openTrade(uint256 _usdc) internal {
    address[] memory _path = new address[](2);
    _path[0] = usdc;
    _path[1] = weth;
    uint256 _sizeDelta = leverage.mul(_usdc).mul(1e18);
    uint256 _price = isLong ? IVault(vault).getMaxPrice(weth) : IVault(vault).getMinPrice(weth);
    IRouter(router).increasePosition(_path, weth, _usdc, 0, _sizeDelta, isLong, _price);
    sizeDelta = _sizeDelta;
    emit OpenPosition(sizeDelta, isLong);
  }

  /**
   * @notice Close leverage position at GMX
   */
  function closeTrade() internal {
    (uint256 size,,,,,,,) = IVault(vault).getPosition(address(this), weth, weth, isLong);
    if (size == 0) {
      return;
    }
    uint256 _before = IERC20(usdc).balanceOf(address(this));
    uint256 price = isLong ? IVault(vault).getMinPrice(weth) : IVault(vault).getMaxPrice(weth);
    IRouter(router).decreasePosition(weth, weth, 0, sizeDelta, isLong, address(this), price);
    address[] memory _path = new address[](2);
    _path[0] = weth;
    _path[1] = usdc;
    IRouter(router).swap(_path, IERC20(weth).balanceOf(address(this)), 0, address(this));
    uint256 _after = IERC20(usdc).balanceOf(address(this));
    uint256 _tradeProfit = _after.sub(_before);
    uint256 _fee = 0;
    if (_tradeProfit > 0) {
      _fee = _tradeProfit.mul(performanceFee).div(FEE_DENOMINATOR);
      IERC20(usdc).safeTransfer(rewards, _fee);
    }
    emit ClosePosition(sizeDelta, isLong, _tradeProfit.sub(_fee));
    sizeDelta = 0;
  }

    /**
     * @notice Withdraw all the funds of the sender
     */
  function withdrawAll() external {
    withdraw(balanceOf(msg.sender));
  }

  /**
   * @notice Withdraw the funds for the `_shares` of the sender. Withdraw fee is deducted.
   * @param _shares is the shares of the sender to withdraw
   */
  function withdraw(uint256 _shares) public {
    uint256 r = (balance().mul(_shares)).div(totalSupply());
    _burn(msg.sender, _shares);

    uint256 b = IERC20(usdc).balanceOf(address(this));
    if (b < r) {
      uint256 lpPrice = ICurveFi(_3pool).get_virtual_price();
      // amount of LP tokens to withdraw
      uint256 _withdraw = (r.sub(b)).div(lpPrice);
      _withdrawSome(_withdraw);
      uint256 _after = IERC20(usdc).balanceOf(address(this));
      uint256 _diff = _after.sub(b);
      if (_diff < r.sub(b)) {
        r = b.add(_diff);
      }
    }

    uint256 _fee = r.mul(withdrawalFee).div(FEE_DENOMINATOR);

    IERC20(usdc).safeTransfer(rewards, _fee);

    IERC20(usdc).safeTransfer(msg.sender, r.sub(_fee));
  }

  /**
   * @notice Withdraw the asset that is accidentally sent to this address
   * @param _asset is the token to withdraw
   */
  function withdraw(IERC20 _asset) external returns (uint256 balance) {
    require(msg.sender == keeper || msg.sender == governance, "!keepers");
    balance = _asset.balanceOf(address(this));
    _asset.safeTransfer(msg.sender, balance);
  }

  /**
   * @notice Withdraw the LP tokens from Gauge, and then withdraw usdc from Curve vault
   * @param _amount is the amount of LP tokens to withdraw
   * @return amount of usdc that is withdrawn
   */
  function _withdrawSome(uint256 _amount) internal returns (uint256) {
    uint256 _before = IERC20(_3crv).balanceOf(address(this));
    Gauge(gauge).withdraw(_amount);
    uint256 _after = IERC20(_3crv).balanceOf(address(this));
    return _withdrawOne(_after.sub(_before));
  }

  /**
   * @notice Withdraw usdc from Curve vault
   * @param _amnt is the amount of LP tokens to withdraw
   * @return amount of usdc that is withdrawn
   */
  function _withdrawOne(uint256 _amnt) internal returns (uint256) {
    uint256 _before = IERC20(usdc).balanceOf(address(this));
    IERC20(_3crv).safeApprove(_3pool, 0);
    IERC20(_3crv).safeApprove(_3pool, _amnt);
    ICurveFi(_3pool).remove_liquidity_one_coin(_amnt, 1, _amnt.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR).div(1e12));
    uint256 _after = IERC20(usdc).balanceOf(address(this));
    return _after.sub(_before);
  }

  function getPricePerFullShare() public view returns (uint256) {
    return balance().mul(1e18).div(totalSupply());
  }

}
