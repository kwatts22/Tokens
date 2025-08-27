// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Chainlink Price Feed Interface
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
    uint256 public rate; // tokens per 1 USD
    IERC20 public token;
    address payable public wallet;
    uint256 public weiRaised;

    uint256 public openingTime;
    uint256 public closingTime;

    AggregatorV3Interface public priceFeed;
    uint256 public maxPriceAge = 1 hours;

    bool public promoEnabled = false;
    uint256 public promoBonusPercent = 0;

    event TokenPurchase(
        address indexed purchaser,
        address indexed beneficiary,
        uint256 value,
        uint256 amount
    );

    event PromoUpdated(bool enabled, uint256 bonusPercent);
    event WithdrawnUnsold(address indexed to, uint256 amount);

    constructor(
        uint256 _rate,                // tokens per USD
        address payable _wallet,     // where funds go
        IERC20 _token,               // TMINE token
        address _owner,              // initial owner
        address _priceFeed,          // Chainlink AVAX/USD
        uint256 _openingTime,
        uint256 _closingTime
    ) Ownable(_owner) {
        require(_rate > 0, "rate=0");
        require(_wallet != address(0), "wallet=0");
        require(_priceFeed != address(0), "priceFeed=0");
        require(_openingTime < _closingTime, "invalid time window");

        rate = _rate;
        wallet = _wallet;
        token = _token;
        priceFeed = AggregatorV3Interface(_priceFeed);
        openingTime = _openingTime;
        closingTime = _closingTime;
    }

    // Accept AVAX
    receive() external payable {
        buyTokens(msg.sender);
    }

    function buyTokens(address beneficiary) public payable {
        require(block.timestamp >= openingTime, "Sale not open");
        require(block.timestamp <= closingTime, "Sale closed");
        require(beneficiary != address(0), "beneficiary=0");
        require(msg.value > 0, "no AVAX");

        uint256 weiAmount = msg.value;
        uint256 tokens = _getTokenAmount(weiAmount);
        weiRaised += weiAmount;

        require(token.transfer(beneficiary, tokens), "token transfer failed");

        emit TokenPurchase(msg.sender, beneficiary, weiAmount, tokens);
        wallet.transfer(msg.value);
    }

    function _getTokenAmount(uint256 weiAmount) internal view returns (uint256) {
        uint256 usdValue = _avaxUsd18(weiAmount); // 18-decimal USD
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

        require(price > 0, "invalid price");
        require(updatedAt > 0 && block.timestamp - updatedAt <= maxPriceAge, "stale price");
        require(answeredInRound >= roundID, "round not complete");

        uint8 feedDecimals = priceFeed.decimals();
        return (avaxAmountInWei * uint256(price)) / (10 ** feedDecimals); // 18-decimal USD output
    }

    function setPromo(bool enabled, uint256 bonusPercent) external onlyOwner {
        require(bonusPercent <= 100, "too high");
        promoEnabled = enabled;
        promoBonusPercent = bonusPercent;
        emit PromoUpdated(enabled, bonusPercent);
    }

    // 🟡 Withdraw unsold tokens after sale ends
    function withdrawUnsoldTokens(address to) external onlyOwner {
        require(block.timestamp > closingTime, "Sale not ended");
        require(to != address(0), "to=0");

        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "no tokens");

        require(token.transfer(to, balance), "withdraw failed");
        emit WithdrawnUnsold(to, balance);
    }
}
