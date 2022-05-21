// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {AaveHodlerVault} from "./AaveHodlerVault.sol";
import {IEToken} from "@ensuro/core/interfaces/IEToken.sol";
import {IPolicyPoolComponent} from "@ensuro/core/interfaces/IPolicyPoolComponent.sol";
import {ILendingPoolAddressesProvider} from "@aave/protocol-v2/contracts/interfaces/ILendingPoolAddressesProvider.sol";
import {IPriceRiskModule} from "@ensuro/core/contracts/extras/IPriceRiskModule.sol";

/**
 * @title Trustful Risk Module
 * @dev Risk Module without any validation, just the newPolicy and resolvePolicy need to be called by
        authorized users
 * @custom:security-contact security@ensuro.co
 * @author Ensuro
 */
contract EnsuroLPAaveHodlerVault is AaveHodlerVault {
  IPolicyPoolComponent internal _eToken;

  /**
   * @dev Constructs the AaveLiquidationProtection
   * @param name_ Name for the vault
   * @param symbol_ Symbol of the vault
   * @param priceInsurance_ The Price Risk Module
   * @param aaveAddrProv_ AAVE address provider, the index to access AAVE's contracts
   */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    string memory name_,
    string memory symbol_,
    IPriceRiskModule priceInsurance_,
    ILendingPoolAddressesProvider aaveAddrProv_
  ) AaveHodlerVault(name_, symbol_, priceInsurance_, aaveAddrProv_) {} // solhint-disable-line no-empty-blocks

  /**
   * @dev Initializes the RiskModule
   * @param params_ Investment / insurance parameters
   * @param eToken_ EToken where the liquidity will be deployed
   */
  function initialize(Parameters memory params_, IPolicyPoolComponent eToken_) public initializer {
    __AaveHodlerVault_init(params_);
    _eToken = eToken_;
    require(
      eToken_.policyPool().currency() == _borrowAsset,
      "The borrow asset must be the same as in the liquidity pool"
    );
    _borrowAsset.approve(address(eToken_.policyPool()), type(uint256).max);
  }

  function _invest() internal override {
    _eToken.policyPool().deposit(IEToken(address(_eToken)), _borrowAsset.balanceOf(address(this)));
  }

  function _deinvest(uint256 amount) internal override returns (uint256) {
    return _eToken.policyPool().withdraw(IEToken(address(_eToken)), amount);
  }

  function totalInvested() public view override returns (uint256) {
    return IEToken(address(_eToken)).balanceOf(address(this));
  }

  function investYieldRate() public view override returns (uint256) {
    return IEToken(address(_eToken)).tokenInterestRate();
  }
}
