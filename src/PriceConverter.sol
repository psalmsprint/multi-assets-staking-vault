// SPDX-License-Identifier:MIT

pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library PriceConverter {
    function getConversionRate(uint256 ethAmount, AggregatorV3Interface priceFeed) internal view returns (uint256) {
        uint256 ethPrice = getPrice(priceFeed);
        uint256 ethAmountInUsd = (ethAmount * ethPrice) / 1e18;
        return ethAmountInUsd;
    }

    function getConversionRateUsdToEth(uint256 usdAmount, AggregatorV3Interface priceFeed)
        internal
        view
        returns (uint256)
    {
        uint256 ethPrice = getPrice(priceFeed);
        uint256 usdAmountToEth = (usdAmount * 1e18) / ethPrice;
        return usdAmountToEth;
    }

    function getPrice(AggregatorV3Interface priceFeed) internal view returns (uint256) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        return uint256(uint256(price) * 1e10);
    }

    function getVersion(AggregatorV3Interface priceFeed) internal view returns (uint256) {
        return priceFeed.version();
    }
}
