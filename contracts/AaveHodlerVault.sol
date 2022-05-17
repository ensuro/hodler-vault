// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILendingPoolAddressesProvider} from "@aave/protocol-v2/contracts/interfaces/ILendingPoolAddressesProvider.sol";
import {ILendingPool} from "@aave/protocol-v2/contracts/interfaces/ILendingPool.sol";
import {IPriceOracle} from "@aave/protocol-v2/contracts/interfaces/IPriceOracle.sol";
import {PercentageMath} from "@aave/protocol-v2/contracts/protocol/libraries/math/PercentageMath.sol";
import {IPriceRiskModule} from "@ensuro/core/contracts/extras/IPriceRiskModule.sol";
import {Policy} from "@ensuro/core/contracts/Policy.sol";
import {WadRayMath} from "@ensuro/core/contracts/WadRayMath.sol";
import {ERC20} from "@rari-capital/solmate/src/tokens/ERC20.sol";
import {ERC4626} from "@rari-capital/solmate/src/mixins/ERC4626.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/**
 * @title AaveHodlerVault
 * @dev Contract that manages the given collateral, invested into Aave, protected of the risk of liquidation,
 *      that borrows stable and reinvests them into another protocol (offering better yield)
 * @custom:security-contact security@ensuro.co
 * @author Ensuro
 */
abstract contract AaveHodlerVault is Initializable, OwnableUpgradeable, UUPSUpgradeable, ERC4626 {
  using SafeERC20 for IERC20Metadata;
  using WadRayMath for uint256;
  using PercentageMath for uint256;

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

  struct Parameters {
    uint256 triggerHF;
    uint256 safeHF;
    uint256 deinvestHF;
    uint256 investHF;
    uint256 maxSlippage;
    IUniswapV2Router02 swapRouter;
    uint40 policyDuration;
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
  constructor(string memory name_, string memory symbol_, IPriceRiskModule priceInsurance_, ILendingPoolAddressesProvider aaveAddrProv_)
    ERC4626(ERC20(address(priceInsurance_.asset())), name_, symbol_)
  {
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
    _validateParameters();
  }

  function totalAssets() public view override returns (uint256) {
    uint256 assetInAave = IERC20Metadata(
      _aave.getReserveData(address(asset)).aTokenAddress
    ).balanceOf(address(this));
    uint256 borrowAssetDebt = _borrowAssetDebt();
    uint256 borrowAssetInvested = totalInvested();
    if (borrowAssetInvested >= borrowAssetDebt) {
      return assetInAave + _convertBorrowToAsset(borrowAssetInvested - borrowAssetDebt);
    } else {
      uint256 borrowDebtInAsset = _convertBorrowToAsset(borrowAssetDebt - borrowAssetInvested);
      if (borrowAssetDebt > assetInAave) {
        return 0;   // MUST NOT REVERT, negative not supported
      } else {
        return assetInAave - borrowDebtInAsset;
      }
    }
  }

  function beforeWithdraw(uint256 assets, uint256 shares) internal override {
    uint256 assetInAave = IERC20Metadata(
      _aave.getReserveData(address(asset)).aTokenAddress
    ).balanceOf(address(this));

    // Withdraw operations must preserve or improve the health factor
    // Returns a fractor of stacked asset and swaps the remaining deinvesting the borrowAsset
    uint256 toWithdrawFromAave = assetInAave * shares / totalSupply;
    uint256 borrowAssetRepay = _borrowAssetDebt() * shares / totalSupply;
    uint256 toAcquireAsset = (assets - toWithdrawFromAave).wadMul(WadRayMath.wad() + _params.maxSlippage);
    _deinvest(toAcquireAsset + borrowAssetRepay);

    // Swap
    address[] memory path = new address[](2);
    path[0] = address(asset);
    path[1] = address(_borrowAsset);
    _borrowAsset.approve(address(_params.swapRouter), toAcquireAsset);  // TODO: infinite approval??
    _params.swapRouter.swapTokensForExactTokens(
      assets - toWithdrawFromAave,
      toAcquireAsset,
      path,
      address(this),
      block.timestamp
    );

    require(_borrowAsset.balanceOf(address(this)) >= borrowAssetRepay, "Can't decrease health factor");

    _aave.repay(
      address(_borrowAsset),
      _borrowAsset.balanceOf(address(this)),
      BORROW_RATE_MODE,
      address(this)
    );

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

  function _getHealthFactor() internal view returns (uint256) {
    (, , , , , uint256 currentHF) = _aave.getUserAccountData(address(this));
    return currentHF;
  }

  /**
   * @dev Withdraws the collateral
   * @param amount Amount to transfer from sender's address
   * @param doCheckpoint Boolean, indicates if calling checkpoint after the withdraw
   */
  function withdrawCollateral(uint256 amount, bool doCheckpoint)
    external
    onlyOwner
    returns (uint256)
  {
    uint256 withdrawalAmount = _aave.withdraw(address(asset), amount, msg.sender);
    if (doCheckpoint) {
      checkpoint();
    }
    return withdrawalAmount;
  }

  /**
   * @dev Check actual health factor and based on the parameters acts in consequence
   */
  function checkpoint() public {
    uint256 hf = _getHealthFactor();
    if (hf > _params.investHF) {
      // Borrow stable, insure against liquidation and invest
      _borrow(_params.investHF);
      _insure();
      _invest();
    } else if (hf > _params.deinvestHF) {
      _insure();
    } else if (hf <= _params.deinvestHF) {
      _repay(_params.investHF);
      _insure();
    }
  }

  /**
   * @dev Withdraws all the funds
   */
  function withdrawAll() external onlyOwner returns (uint256, uint256) {
    _repay(type(uint256).max);
    _deinvest(type(uint256).max);
    uint256 withdrawalAmount = _aave.withdraw(address(asset), type(uint256).max, msg.sender);
    uint256 borrowAssetAmount = _borrowAsset.balanceOf(address(this));
    _borrowAsset.safeTransfer(msg.sender, borrowAssetAmount);
    return (withdrawalAmount, borrowAssetAmount);
  }

  function _borrow(uint256 targetHF) internal {
    (uint256 currentDebt, uint256 targetDebt) = _calculateTargetDebt(targetHF);
    if (targetDebt > currentDebt)
      _aave.borrow(
        address(_borrowAsset),
        targetDebt - currentDebt,
        BORROW_RATE_MODE,
        0,
        address(this)
      );
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

  // solhint-disable-next-line no-empty-blocks
  function _insure() internal {
    if (_activePolicyExpiration > (block.timestamp + _params.policyDuration / 1000)) {
      // Active policy not yet expired - _params.policyDuration is to allow "some" overlap (<90 secs in 1 day)
      return;
    }
    uint256 currentHF = _getHealthFactor();
    if (currentHF <= _params.safeHF) {
      // I can't insure because it's already in the target health - _deinvest recommended at this point
      return;
    }
    uint256 triggerPrice = _collPriceInBorrowAsset().wadMul(currentHF.wadDiv(_params.triggerHF));
    // This triggerPrice doesn't take into account the interest rate of the borrowAsset neither the deposit interest
    // rate of the collateral. Can be improved in the future, but with a triggerHF at 1.01 we shouldn't be at
    // liquidation risk

    uint256 payout = triggerPrice.wadMul(asset.balanceOf(address(this))).wadMul(
      _params.safeHF.wadDiv(_params.triggerHF) - WadRayMath.wad()
    );
    (uint256 policyPrice, ) = _priceInsurance.pricePolicy(
      triggerPrice,
      true,
      payout,
      uint40(block.timestamp) + _params.policyDuration
    );
    // TODO: if policyPrice > expected return in _params.policyDuration (invest rate - _borrowAsset rate) then
    // reduce the price scaling the payout. It won't take you to safeHF but at least will take you out of triggerHF

    if (policyPrice == 0) return; // Duration / Price jump not supported - What to do in this case?
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

  function totalInvested() public view virtual returns (uint256);

  function _liqThreshold() internal view returns (uint256) {
    return
      (_aave.getReserveData(address(asset)).configuration.data &
        ~LIQUIDATION_THRESHOLD_MASK) >> LIQUIDATION_THRESHOLD_START_BIT_POSITION;
  }

  function _calculateTargetDebt(uint256 targetHF)
    internal
    view
    returns (uint256 currentDebt, uint256 targetDebt)
  {
    IPriceOracle oracle = IPriceOracle(_aave.getAddressesProvider().getPriceOracle());
    uint256 collateralInEth = (IERC20Metadata(
      _aave.getReserveData(address(asset)).aTokenAddress
    ).balanceOf(address(this)) * oracle.getAssetPrice(address(asset))) /
      10**asset.decimals();
    targetDebt = collateralInEth.percentMul(_liqThreshold()).wadDiv(targetHF);
    return (_borrowAssetDebt(), targetDebt);
  }

  function _borrowAssetDebt() internal view returns (uint256) {
    IERC20Metadata variableDebtToken = IERC20Metadata(
      _aave.getReserveData(address(_borrowAsset)).variableDebtTokenAddress
    );
    return variableDebtToken.balanceOf(address(this));
  }

  function _collPriceInBorrowAsset() internal view returns (uint256) {
    IPriceOracle oracle = IPriceOracle(_aave.getAddressesProvider().getPriceOracle());
    uint256 exchangeRate = oracle.getAssetPrice(address(asset)).wadDiv(
      oracle.getAssetPrice(address(_borrowAsset))
    );
    uint8 decFrom = asset.decimals();
    uint8 decTo = _borrowAsset.decimals();
    if (decFrom > decTo) {
      exchangeRate /= 10**(decFrom - decTo);
    } else {
      exchangeRate *= 10**(decTo - decFrom);
    }
    return exchangeRate;
  }

  function _convertBorrowToAsset(uint256 borrowAssetAmount) internal view returns (uint256) {
    IPriceOracle oracle = IPriceOracle(_aave.getAddressesProvider().getPriceOracle());
    uint256 exchangeRate = oracle.getAssetPrice(address(_borrowAsset)).wadDiv(
      oracle.getAssetPrice(address(asset))
    );
    uint8 decFrom = _borrowAsset.decimals();
    uint8 decTo = asset.decimals();
    if (decFrom > decTo) {
      exchangeRate /= 10**(decFrom - decTo);
    } else {
      exchangeRate *= 10**(decTo - decFrom);
    }
    return borrowAssetAmount.wadMul(exchangeRate);
  }
}
