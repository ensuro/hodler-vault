// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AddressUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILendingPoolAddressesProvider} from "@aave/protocol-v2/contracts/interfaces/ILendingPoolAddressesProvider.sol";
import {ILendingPool} from "@aave/protocol-v2/contracts/interfaces/ILendingPool.sol";
import {ILendingRateOracle} from "@aave/protocol-v2/contracts/interfaces/ILendingRateOracle.sol";
import {PercentageMath} from "@aave/protocol-v2/contracts/protocol/libraries/math/PercentageMath.sol";
import {IPriceRiskModule} from "@ensuro/core/contracts/extras/IPriceRiskModule.sol";
import {IPolicyPoolComponent} from "@ensuro/core/interfaces/IPolicyPoolComponent.sol";
import {IExchange, IPriceOracle} from "@ensuro/core/interfaces/IExchange.sol";
import {IPolicyHolder} from "@ensuro/core/interfaces/IPolicyHolder.sol";
import {WadRayMath} from "@ensuro/core/contracts/WadRayMath.sol";
import {ERC20} from "@rari-capital/solmate/src/tokens/ERC20.sol";
import {ERC4626} from "@rari-capital/solmate/src/mixins/ERC4626.sol";
import {FixedPointMathLib} from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/**
 * @title AaveHodlerVault
 * @dev Contract that manages the given collateral, invested into Aave, protected of the risk of liquidation,
 *      that borrows stable and reinvests them into another protocol (offering better yield)
 * @custom:security-contact security@ensuro.co
 * @author Ensuro
 */
abstract contract AaveHodlerVault is
  Initializable,
  OwnableUpgradeable,
  UUPSUpgradeable,
  ERC4626,
  IPolicyHolder
{
  using SafeERC20 for IERC20Metadata;
  using WadRayMath for uint256;
  using PercentageMath for uint256;
  using FixedPointMathLib for uint256;
  using AddressUpgradeable for address;

  uint256 private constant SECONDS_PER_YEAR = 3600 * 24 * 365;

  uint256 private constant PAYOUT_BUFFER = 2e16; // 2%
  uint256 private constant LIQUIDATION_THRESHOLD_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0000FFFF; // prettier-ignore
  uint256 private constant LIQUIDATION_THRESHOLD_START_BIT_POSITION = 16;
  uint256 private constant BORROW_RATE_MODE = 2; // variable

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  ILendingPool internal immutable _aave;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IPriceRiskModule internal immutable _priceInsurance;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IERC20Metadata internal immutable _borrowAsset;

  enum OnPayoutStrategy {
    buyTheDip, // Uses the payout money to buy more asset, deposited into AAVE to increase HF
    repay // repays the borrowAsset debt
  }

  struct Parameters {
    uint256 triggerHF;
    uint256 safeHF;
    uint256 deinvestHF;
    uint256 investHF;
    IExchange exchange;
    uint40 policyDuration;
    OnPayoutStrategy payoutStrategy;
  }

  Parameters internal _params;

  uint256 internal _activePolicyId;
  uint40 internal _activePolicyExpiration;

  /**
   * @dev Constructs the AaveHodlerVault
   * @param priceInsurance_ The Price Risk Module
   * @param aaveAddrProv_ AAVE address provider, the index to access AAVE's contracts
   */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    string memory name_,
    string memory symbol_,
    IPriceRiskModule priceInsurance_,
    ILendingPoolAddressesProvider aaveAddrProv_
  ) ERC4626(ERC20(address(priceInsurance_.asset())), name_, symbol_) {
    ILendingPool aave = ILendingPool(aaveAddrProv_.getLendingPool());
    _aave = aave;
    _priceInsurance = priceInsurance_;
    _borrowAsset = priceInsurance_.referenceCurrency();
  }

  /**
   * @dev Initializes the protection contract
   * @param params_ Investment / insurance parameters
   */
  // solhint-disable-next-line func-name-mixedcase
  function __AaveHodlerVault_init(Parameters memory params_) internal initializer {
    __Ownable_init();
    __UUPSUpgradeable_init();
    __AaveHodlerVault_init_unchained(params_);
  }

  // solhint-disable-next-line func-name-mixedcase
  function __AaveHodlerVault_init_unchained(Parameters memory params_) internal initializer {
    _params = params_;
    asset.approve(address(_aave), type(uint256).max);
    _borrowAsset.approve(address(_aave), type(uint256).max);
    _borrowAsset.approve(
      address(IPolicyPoolComponent(address(_priceInsurance)).policyPool()),
      type(uint256).max
    );
    _validateParameters();
  }

  function _assetBalance() internal view returns (uint256) {
    return
      IERC20Metadata(_aave.getReserveData(address(asset)).aTokenAddress).balanceOf(address(this));
  }

  function _maxSlippage() internal view returns (uint256) {
    return _params.exchange.maxSlippage();
  }

  function totalAssets() public view override returns (uint256) {
    uint256 assetInAave = _assetBalance();
    uint256 borrowAssetDebt = _borrowAssetDebt();
    uint256 borrowAssetInvested = totalInvested();
    if (borrowAssetInvested >= borrowAssetDebt) {
      return
        assetInAave +
        _convertBorrowToAsset(borrowAssetInvested - borrowAssetDebt).wadMul(
          WadRayMath.wad() - _maxSlippage()
        );
    } else {
      uint256 borrowDebtInAsset = _convertBorrowToAsset(borrowAssetDebt - borrowAssetInvested)
        .wadMul(WadRayMath.wad() + _maxSlippage());
      if (borrowAssetDebt > assetInAave) {
        return 0; // MUST NOT REVERT, negative not supported
      } else {
        return assetInAave - borrowDebtInAsset;
      }
    }
  }

  function expectedYield(uint40 duration) public view returns (uint256) {
    uint256 borrowRate = _lendingRateOracle().getMarketBorrowRate(address(_borrowAsset));
    uint256 borrowAssetNegYield = _borrowAssetDebt().wadMul(
      borrowRate.mulDivDown(duration, SECONDS_PER_YEAR).rayToWad()
    );
    uint256 investmentYield = totalInvested().wadMul(
      investYieldRate().mulDivDown(duration, SECONDS_PER_YEAR).rayToWad()
    );
    if (borrowAssetNegYield > investmentYield) return 0;
    return investmentYield - borrowAssetNegYield;
  }

  function beforeWithdraw(uint256 assets, uint256 shares) internal override {
    // TODO: forbit withdraw / deposit in the same tx, can be exploited
    uint256 assetInAave = _assetBalance();

    // Withdraw operations must preserve or improve the health factor
    // Returns a fractor of stacked asset and swaps the remaining deinvesting the borrowAsset
    uint256 toWithdrawFromAave = assetInAave.mulDivDown(shares, totalSupply);
    uint256 borrowAssetRepay = _borrowAssetDebt().mulDivDown(shares, totalSupply);
    uint256 toAcquireAsset = _convertAssetToBorrow(
      (assets - toWithdrawFromAave).wadMul(WadRayMath.wad() + _maxSlippage())
    );
    _deinvest(toAcquireAsset + borrowAssetRepay);

    // Swap
    if (toAcquireAsset > 0) {
      address swapRouter = _params.exchange.getSwapRouter();
      _borrowAsset.approve(swapRouter, toAcquireAsset); // TODO: infinite approval??
      bytes memory swapCall = _params.exchange.buy(
        address(_borrowAsset),
        address(asset),
        assets - toWithdrawFromAave,
        address(this),
        block.timestamp
      );
      swapRouter.functionCall(swapCall, "Swap operation failed");
    }

    require(
      _borrowAsset.balanceOf(address(this)) >= borrowAssetRepay,
      "Can't decrease health factor"
    );

    borrowAssetRepay = _borrowAsset.balanceOf(address(this));
    if (borrowAssetRepay > 0) {
      _aave.repay(address(_borrowAsset), borrowAssetRepay, BORROW_RATE_MODE, address(this));
    }

    _aave.withdraw(address(asset), toWithdrawFromAave, address(this));
  }

  function afterDeposit(uint256, uint256) internal override {
    _aave.deposit(address(asset), asset.balanceOf(address(this)), address(this), 0);
    // on deposit just the AAVE deposit is done, borrow stable will be done on the
    // checkpoint
  }

  function _validateParameters() internal view virtual {
    require(_params.triggerHF < _params.safeHF, "triggerHF >= safeHF!");
    require(_params.safeHF < _params.deinvestHF, "safeHF >= deinvestHF!");
    require(_params.deinvestHF < _params.investHF, "deinvestHF >= investHF!");
  }

  // solhint-disable-next-line no-empty-blocks
  function _authorizeUpgrade(address) internal override onlyOwner {}

  function onERC721Received(
    address,
    address,
    uint256,
    bytes calldata
  ) external pure override returns (bytes4) {
    return IERC721Receiver.onERC721Received.selector;
  }

  function onPayoutReceived(
    address,
    address,
    uint256 policyId,
    uint256
  ) external override returns (bytes4) {
    require(
      msg.sender == address(IPolicyPoolComponent(address(_priceInsurance)).policyPool()) &&
        policyId == _activePolicyId,
      "Only the PolicyPool can call onPayoutReceived"
    );
    if (_params.payoutStrategy == OnPayoutStrategy.buyTheDip) {
      _buyTheDip();
    } else {
      _aave.repay(
        address(_borrowAsset),
        _borrowAsset.balanceOf(address(this)),
        BORROW_RATE_MODE,
        address(this)
      );
    }
    _activePolicyId = 0;
    _activePolicyExpiration = 0;
    insure(false);
    return IPolicyHolder.onPayoutReceived.selector;
  }

  function _buyTheDip() internal {
    uint256 amount = _borrowAsset.balanceOf(address(this));
    address swapRouter = _params.exchange.getSwapRouter();
    _borrowAsset.approve(swapRouter, amount); // TODO: infinite approval??
    bytes memory swapCall = _params.exchange.sell(
      address(_borrowAsset),
      address(asset),
      amount,
      address(this),
      block.timestamp
    );
    swapRouter.functionCall(swapCall, "Swap operation failed");
    _aave.deposit(address(asset), asset.balanceOf(address(this)), address(this), 0);
  }

  function onPolicyExpired(
    address,
    address,
    uint256
  ) external override returns (bytes4) {
    // TODO: do I need to validate the call comes from the pool?
    // Since insure it's an open end-point I don't think so
    insure(false);
    return IPolicyHolder.onPolicyExpired.selector;
  }

  function _getHealthFactor() internal view returns (uint256) {
    (, , , , , uint256 currentHF) = _aave.getUserAccountData(address(this));
    return currentHF;
  }

  /**
   * @dev Check actual health factor and based on the parameters acts in consequence
   */
  function checkpoint() public {
    uint256 hf = _getHealthFactor();
    if (hf > _params.investHF) {
      // Borrow stable, insure against liquidation and invest
      _borrow(_params.investHF);
      _invest();
    } else if (hf <= _params.deinvestHF) {
      _repay(_params.investHF);
    }
  }

  function _borrow(uint256 targetHF) internal {
    (uint256 currentDebt, uint256 targetDebt) = _calculateTargetDebt(targetHF);
    if (targetDebt > currentDebt) _borrowAmount(targetDebt - currentDebt);
  }

  function _borrowAmount(uint256 amount) internal {
    if (amount > 0) _aave.borrow(address(_borrowAsset), amount, BORROW_RATE_MODE, 0, address(this));
  }

  function _repay(uint256 targetHF) internal {
    (uint256 currentDebt, uint256 targetDebt) = _calculateTargetDebt(targetHF);
    if (targetDebt < currentDebt) {
      uint256 requiredCash = currentDebt - targetDebt;
      requiredCash -= Math.min(requiredCash, _borrowAsset.balanceOf(address(this)));
      _deinvest(requiredCash);
      // As the amount I send _borrowAsset.balanceOf(this) because perhaps _deinvest deinvests more or less than
      // required
      _aave.repay(
        address(_borrowAsset),
        _borrowAsset.balanceOf(address(this)),
        BORROW_RATE_MODE,
        address(this)
      );
    }
  }

  function _lendingRateOracle() internal view returns (ILendingRateOracle) {
    return ILendingRateOracle(_aave.getAddressesProvider().getLendingRateOracle());
  }

  function _hasActivePolicy() internal view returns (bool) {
    return _activePolicyExpiration > (block.timestamp + _params.policyDuration / 1000);
  }

  function insure(bool forced) public {
    require(!forced || owner() == _msgSender(), "Only the owner can force");
    // Active policy not yet expired - _params.policyDuration is to allow some overlap (<90 secs in 1 day)
    if (_hasActivePolicy()) return;
    uint256 currentHF = _getHealthFactor();
    if (currentHF <= _params.safeHF) {
      // I can't insure because it's already in the target health - _deinvest recommended at this point
      return;
    }
    uint256 triggerPrice = _params
      .exchange
      .getExchangeRate(address(asset), address(_borrowAsset))
      .wadMul(_params.triggerHF.wadDiv(currentHF));
    // This triggerPrice doesn't take into account the interest rate of the borrowAsset neither the deposit interest
    // rate of the collateral. Can be improved in the future, but with a triggerHF at 1.01 we shouldn't be at
    // liquidation risk

    uint256 payout = _assetBalance()
      .wadMul(_params.safeHF.wadDiv(_params.triggerHF) - WadRayMath.wad())
      .wadMul(triggerPrice);
    (uint256 policyPrice, ) = _priceInsurance.pricePolicy(
      triggerPrice,
      true,
      payout,
      uint40(block.timestamp) + _params.policyDuration
    );
    if (policyPrice == 0) return; // Duration / Price jump not supported - What to do in this case?

    if (!forced) {
      uint256 yield = expectedYield(_params.policyDuration);
      if (yield < policyPrice) {
        // Scale payout to something more affordable...
        payout = payout.mulDivDown(yield, policyPrice);
        policyPrice = yield;
      }
    }

    if (_borrowAsset.balanceOf(address(this)) < policyPrice) {
      _borrowAmount(policyPrice - _borrowAsset.balanceOf(address(this)));
    }

    _activePolicyId = _priceInsurance.newPolicy(
      triggerPrice,
      true,
      payout,
      uint40(block.timestamp) + _params.policyDuration
    );
    _activePolicyExpiration = uint40(block.timestamp) + _params.policyDuration;
  }

  function _invest() internal virtual;

  function _deinvest(uint256 amount) internal virtual returns (uint256);

  function activePolicyId() external view returns (uint256) {
    return _activePolicyId;
  }

  function activePolicyExpiration() external view returns (uint40) {
    return _activePolicyExpiration;
  }

  function totalInvested() public view virtual returns (uint256);

  function investYieldRate() public view virtual returns (uint256);

  function _liqThreshold() internal view returns (uint256) {
    return
      (_aave.getReserveData(address(asset)).configuration.data & ~LIQUIDATION_THRESHOLD_MASK) >>
      LIQUIDATION_THRESHOLD_START_BIT_POSITION;
  }

  function _calculateTargetDebt(uint256 targetHF)
    internal
    view
    returns (uint256 currentDebt, uint256 targetDebt)
  {
    uint256 assetBalance = _assetBalance();
    targetDebt = _convertAssetToBorrow(assetBalance.percentMul(_liqThreshold()).wadDiv(targetHF));
    return (_borrowAssetDebt(), targetDebt);
  }

  function _borrowAssetDebt() internal view returns (uint256) {
    IERC20Metadata variableDebtToken = IERC20Metadata(
      _aave.getReserveData(address(_borrowAsset)).variableDebtTokenAddress
    );
    return variableDebtToken.balanceOf(address(this));
  }

  function _convertBorrowToAsset(uint256 borrowAssetAmount) internal view returns (uint256) {
    return _params.exchange.convert(address(_borrowAsset), address(asset), borrowAssetAmount);
  }

  function _convertAssetToBorrow(uint256 assetAmount) internal view returns (uint256) {
    return _params.exchange.convert(address(asset), address(_borrowAsset), assetAmount);
  }
}
