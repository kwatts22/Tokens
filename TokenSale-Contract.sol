// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Chainlink price feed interface
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

contract Crowdsale is Ownable {
    uint256 public rate; // tokens per USD (not wei)
    ERC20 public token;
    address payable public wallet;
    uint256 public weiRaised;

    AggregatorV3Interface public priceFeed;
    uint256 public maxPriceAge = 1 hours;

    bool public promoEnabled = false;
    uint256 public promoBonusPercent = 0;

    event TokenPurchase(address indexed purchaser, address indexed beneficiary, uint256 value, uint256 amount);
    event PromoUpdated(bool enabled, uint256 bonusPercent);

    constructor(
        uint256 _rate,
        address payable _wallet,
        ERC20 _token,
        address _owner,
        address _priceFeed
    ) Ownable(_owner) {
        require(_rate > 0, "rate=0");
        require(_wallet != address(0), "wallet=0");
        require(_priceFeed != address(0), "feed=0");

        rate = _rate;
        wallet = _wallet;
        token = _token;
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    receive() external payable {
        buyTokens(msg.sender);
    }

    function buyTokens(address beneficiary) public payable {
        uint256 weiAmount = msg.value;
        require(beneficiary != address(0), "beneficiary=0");
        require(weiAmount > 0, "zero purchase");

        uint256 tokens = _getTokenAmount(weiAmount);
        weiRaised += weiAmount;

        token.transfer(beneficiary, tokens);
        emit TokenPurchase(msg.sender, beneficiary, weiAmount, tokens);

        wallet.transfer(msg.value);
    }

    function _getTokenAmount(uint256 weiAmount) internal view returns (uint256) {
        uint256 usdValue = _avaxUsd18(weiAmount); // convert AVAX to USD (18 decimals)
        uint256 base = usdValue * rate;

        if (promoEnabled && promoBonusPercent > 0) {
            uint256 bonus = (base * promoBonusPercent) / 100;
            return base + bonus;
        }

        return base;
    }

    function _avaxUsd18(uint256 avaxAmountInWei) internal view returns (uint256) {
        (
            uint80 roundID,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        require(price > 0, "Invalid price");
        require(updatedAt > 0 && block.timestamp - updatedAt <= maxPriceAge, "Stale price");
        require(answeredInRound >= roundID, "Incomplete round");

        uint8 feedDecimals = priceFeed.decimals();
        return (avaxAmountInWei * uint256(price)) / (10 ** feedDecimals); // 18 decimals output
    }

    function setPromo(bool enabled, uint256 bonusPercent) external onlyOwner {
        require(bonusPercent <= 100, "too high");
        promoEnabled = enabled;
        promoBonusPercent = bonusPercent;
        emit PromoUpdated(enabled, bonusPercent);
    }
}
