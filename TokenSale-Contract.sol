// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/* OpenZeppelin v5.4.0 (raw URLs for Remix) */
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/token/ERC20/IERC20.sol";

/* Minimal Chainlink Aggregator interface embedded locally (no GitHub import) */
interface AggregatorV3Interface {
  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function version() external view returns (uint256);
  function getRoundData(uint80 _roundId)
    external view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
  function latestRoundData()
    external view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
}

/// @title TMINE Token Sale (Avalanche C-Chain)
/// @notice Purchases are priced via AVAX/USD Chainlink oracle.
///         `rate` = tokens per 1 USD (e.g., 100 => $1 buys 100 TMINE).
///         Promo bonus is 0 by default; set via `setPromoBonus(percent)`.
/// @custom:security-contact security@togethermining.xyz
contract TokenSale is Ownable {
    IERC20 public immutable token;                 // TMINE token (18d)
    address payable public treasury;               // where AVAX is forwarded
    uint256 public rate;                           // tokens per 1 USD (e.g., 100)
    uint256 public hardCap;                        // cap in base tokens (18d)
    uint256 public tokensSoldBase;                 // base (no bonus), 18d
    uint256 public promoBonusPercent = 0;          // no bonus by default

    uint256 public startTime;
    uint256 public endTime;
    bool    public saleEnded;

    AggregatorV3Interface public immutable nativeUsdFeed; // AVAX/USD feed

    event TokensPurchased(address indexed buyer, uint256 avaxAmount, uint256 baseTokens, uint256 totalTokens);
    event PromoBonusUpdated(uint256 newBonusPct);
    event TreasuryUpdated(address treasury);
    event SaleTimesUpdated(uint256 start, uint256 end);
    event RateUpdated(uint256 rate);
    event HardCapUpdated(uint256 hardCap);
    event SaleEnded();
    event ETHRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    constructor(
        address _token,
        address payable _treasury,
        address _priceFeed,
        uint256 _rate,         // tokens per 1 USD (e.g., 100)
        uint256 _hardCap,      // 18-dec tokens (e.g., 200_000_000 * 1e18)
        uint256 _startTime,
        uint256 _endTime,
        address initialOwner
    ) Ownable(initialOwner) {
        require(_token != address(0), "token=0");
        require(_treasury != address(0), "treasury=0");
        require(_priceFeed != address(0), "feed=0");
        require(_startTime < _endTime, "start>=end");
        require(_rate > 0, "rate=0");

        token         = IERC20(_token);
        treasury      = _treasury;
        nativeUsdFeed = AggregatorV3Interface(_priceFeed);
        rate          = _rate;
        hardCap       = _hardCap;
        startTime     = _startTime;
        endTime       = _endTime;
    }

    /// @dev Treat direct AVAX sends as buys.
    receive() external payable { buyWithAVAX(); }

    /// @notice Buy tokens with AVAX priced via Chainlink AVAX/USD.
    ///         USD is handled at 18 decimals; baseTokens = usd18 * rate / 1e18.
    function buyWithAVAX() public payable {
        require(block.timestamp >= startTime && block.timestamp <= endTime, "Sale inactive");
        require(!saleEnded, "Sale ended");
        uint256 avaxAmount = msg.value;
        require(avaxAmount > 0, "No AVAX");

        uint256 usd18      = _avaxUsd18(avaxAmount);
        uint256 baseTokens = (usd18 * rate) / 1e18;              // tokens (18d)
        uint256 bonus      = (baseTokens * promoBonusPercent) / 100;
        uint256 total      = baseTokens + bonus;

        _enforceCap(baseTokens);
        tokensSoldBase += baseTokens;

        require(token.transfer(msg.sender, total), "Token transfer failed");

        (bool ok, ) = treasury.call{value: avaxAmount}("");
        require(ok, "Forward failed");

        emit TokensPurchased(msg.sender, avaxAmount, baseTokens, total);
    }

    // ------- Internals -------

    /// @dev Convert AVAX (wei) -> USD with 18 decimals using Chainlink.
    function _avaxUsd18(uint256 avaxWei) internal view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = nativeUsdFeed.latestRoundData();
        require(price > 0, "Invalid price");
        require(block.timestamp - updatedAt <= 1 hours, "Price stale");
        uint8 pdec = nativeUsdFeed.decimals(); // typically 8
        // usd18 = (wei * price) / 10^pdec
        return (avaxWei * uint256(price)) / (10 ** pdec);
    }

    function _enforceCap(uint256 baseTokens) internal view {
        require(tokensSoldBase + baseTokens <= hardCap, "Cap exceeded");
    }

    // ------- Admin -------

    /// @param percent e.g. 20 => +20%. Set 0 to disable promo.
    function setPromoBonus(uint256 percent) external onlyOwner {
        require(percent <= 100, "Too high");
        promoBonusPercent = percent;
        emit PromoBonusUpdated(percent);
    }

    /// @param _rate tokens per 1 USD (e.g., 100)
    function setRate(uint256 _rate) external onlyOwner {
        require(_rate > 0, "rate=0");
        rate = _rate;
        emit RateUpdated(_rate);
    }

    /// @param _cap cap in base tokens (18 decimals)
    function setHardCap(uint256 _cap) external onlyOwner {
        hardCap = _cap;
        emit HardCapUpdated(_cap);
    }

    function setTimeWindow(uint256 _start, uint256 _end) external onlyOwner {
        require(_start < _end, "Invalid range");
        startTime = _start;
        endTime   = _end;
        emit SaleTimesUpdated(_start, _end);
    }

    function setTreasury(address payable _treasury) external onlyOwner {
        require(_treasury != address(0), "treasury=0");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /// @notice End sale and sweep remaining TMINE to treasury.
    function endSale() external onlyOwner {
        require(!saleEnded, "Already ended");
        saleEnded = true;

        uint256 bal = token.balanceOf(address(this));
        if (bal > 0) {
            require(token.transfer(treasury, bal), "Return to treasury failed");
        }
        emit SaleEnded();
    }

    // ------- Rescue -------

    function rescueETH(address payable to, uint256 amount) external onlyOwner {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "rescue fail");
        emit ETHRescued(to, amount);
    }

    function rescueERC20(address tokenAddress, address to, uint256 amount) external onlyOwner {
        require(tokenAddress != address(token), "Can't rescue sale token");
        IERC20(tokenAddress).transfer(to, amount);
        emit ERC20Rescued(tokenAddress, to, amount);
    }
}
