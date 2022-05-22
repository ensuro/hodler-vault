// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {IPriceOracle} from "@ensuro/core/interfaces/IExchange.sol";

contract PriceOracle is IPriceOracle {
  mapping(address => uint256) internal _prices;
  IPriceOracle internal _basePriceOracle;

  constructor(IPriceOracle basePriceOracle) {
    _basePriceOracle = basePriceOracle;
  }

  function getAssetPrice(address asset) external view override returns (uint256) {
    uint256 price = _prices[asset];
    if (price == 0) return _basePriceOracle.getAssetPrice(asset);
    else return price;
  }

  function setAssetPrice(address asset, uint256 priceInETH) external {
    _prices[asset] = priceInETH;
  }
}
