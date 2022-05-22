// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {Exchange} from "@ensuro/core/contracts/Exchange.sol";
import {IPolicyPool} from "@ensuro/core/interfaces/IPolicyPool.sol";

contract ExchangeAnyMaxSlippage is Exchange {
  // solhint-disable-next-line no-empty-blocks
  constructor(IPolicyPool policyPool_) Exchange(policyPool_) {}

  function setMaxSlippageUncapped(uint256 newValue)
    external
    onlyPoolRole2(LEVEL2_ROLE, LEVEL3_ROLE)
  {
    _maxSlippage = newValue;
  }
}
