// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/* ---------------- OpenZeppelin v5.4.0 (raw URLs for Remix) ---------------- */
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/token/ERC20/IERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/utils/ReentrancyGuard.sol";

/* ---- Chainlink Aggregator interface (your repo URL; keep or use a local file) ---- */
import "https://raw.githubusercontent.com/kwatts22/chainlink/refs/heads/main/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title TMINE Token Sale (Avalanche C-Chain)
 * @notice Purchases priced via AVAX/USD Chainlink oracle.
 *         - `rate` = tokens per 1 USD (e.g., 100 => $1 buys 100 TMINE)
 *         - Promo bonus is 0 by default; enable via `setPromoBonus(percent)`
 *         - Hard cap enforced on *base* (pre-bonus) tokens
 *         - Unsold tokens are swept to treasury on `endSale()`
 * @dev Assumes TMINE has 18 decimals. Fund this contract with enough TMINE before opening.
 */
contract TokenSale is Ownable, ReentrancyGuard {
    IERC20 public immutable token;                  // TMINE token (assumed 18d)
    address payable public treasury;                // where AVAX is forwarded
    AggregatorV3Interface public immutable nativeUsdFeed; // AVAX/USD price feed

    // Configuration
    uint256 public rate;                 // tokens per 1 USD (e.g., 100)
    uint256 public hardCap;              // cap in base tokens (18d)
    uint256 public promoBonusPercent;    // 0 by default; set via setPromoBonus(...)

    // Sale window / state
    uint256 public startTime;
    uint256 public endTime;
    bool    public saleEnded;

    // Accounting (pre-bonus)
    uint256 public tokensSoldBase;       // 18d base tokens sold

    // Price staleness guard (seconds); can be tuned by owner
    uint256 public maxPriceAge = 1 hours;

    // Events
    event TokensPurchased(address indexed buyer, uint256 avaxAmount, uint256 baseTokens, uint256 totalTokens);
    event PromoBonusUpdated(uint256 newBonusPct);
    event TreasuryUpdated(address treasury);
    event SaleTimesUpdated(uint256 start, uint256 end);
    event RateUpdated(uint256 rate);
    event HardCapUpdated(uint256 hardCap);
    event MaxPriceAgeUpdated(uint256 secondsAge);
    event SaleEnded();
    event ETHRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    /**
     * @param _token      TMINE token address
     * @param _treasury   AVAX receiver
     * @param _priceFeed  Chainlink AVAX/USD proxy
     * @param _rate       tokens per 1 USD (e.g., 100)
     * @param _hardCap    cap in base tokens (18 decimals)
     * @param _startTime  sale start (unix)
     * @param _endTime    sale end (unix)
     * @param initialOwner Ownable initial owner (OZ v5 requirement)
     */
    constructor(
        address _token,
        address payable _treasury,
        address _priceFeed,
        uint256 _rate,
        uint256 _hardCap,
        uint256 _startTime,
        uint256 _endTime,
        address initialOwner
    ) Ownable(initialOwner) {
        require(_token != address(0), "token=0");
        require(_treasury != address(0), "treasury=0");
        require(_priceFeed != address(0), "feed=0");
        require(_rate > 0, "rate=0");
        require(_startTime < _endTime, "start>=end");

        token         = IERC20(_token);
        treasury      = _treasury;
        nativeUsdFeed = AggregatorV3Interface(_priceFeed);
        rate          = _rate;
        hardCap       = _hardCap;
        startTime     = _startTime;
        endTime       = _endTime;

        promoBonusPercent = 0; // no promo by default
    }

    /// @dev Treat direct AVAX sends as buys.
    receive() external payable { buyWithAVAX(); }

    /**
     * @notice Buy tokens with AVAX priced via Chainlink AVAX/USD.
     *         USD is handled at 18 decimals; baseTokens = usd18 * rate.
     */
    function buyWithAVAX() public payable nonReentrant {
        require(block.timestamp >= startTime && block.timestamp <= endTime, "Sale inactive");
        require(!saleEnded, "Sale ended");
        uint256 avaxAmount = msg.value;
        require(avaxAmount > 0, "No AVAX");

        uint256 usd18      = _avaxUsd18(avaxAmount);
        uint256 baseTokens = usd18 * rate;               // 18d tokens (no division by 1e18)
        require(baseTokens > 0, "Too little AVAX");

        uint256 bonus      = (baseTokens * promoBonusPercent) / 100;
        uint256 total      = baseTokens + bonus;

        _enforceCap(baseTokens);
        tokensSoldBase += baseTokens;

        // Ensure inventory
        require(token.balanceOf(address(this)) >= total, "Insufficient token");

        // Deliver tokens
        require(token.transfer(msg.sender, total), "Token transfer failed");

        // Forward funds
        (bool ok, ) = treasury.call{value: avaxAmount}("");
        require(ok, "Forward failed");

        emit TokensPurchased(msg.sender, avaxAmount, baseTokens, total);
    }

    // ========= PREVIEW (UI helper) =========

    function previewTokensForAVAX(uint256 weiAmount)
        external
        view
        returns (uint256 usd18, uint256 baseTokens, uint256 total)
    {
        usd18      = _avaxUsd18(weiAmount);
        baseTokens = usd18 * rate; // No division by 1e18
        uint256 bonus = (baseTokens * promoBonusPercent) / 100;
        total = baseTokens + bonus;
    }

    // --------------------------- Internals ---------------------------

    /**
     * @dev Convert AVAX (wei) -> USD with 18 decimals using Chainlink.
     *      Adds round completeness + staleness checks.
     */
    function _avaxUsd18(uint256 avaxWei) internal view returns (uint256) {
        (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) =
            nativeUsdFeed.latestRoundData();

        require(price > 0, "Invalid price");
        require(updatedAt > 0, "Round incomplete");
        require(answeredInRound >= roundId, "Stale round");
        require(block.timestamp - updatedAt <= maxPriceAge, "Price stale");

        uint8 pdec = nativeUsdFeed.decimals(); // typically 8 for AVAX/USD
        // usd18 = (wei * price) / 10^pdec
        return (avaxWei * uint256(price)) / (10 ** pdec);
    }

    function _enforceCap(uint256 baseTokens) internal view {
        require(tokensSoldBase + baseTokens <= hardCap, "Cap exceeded");
    }

    // ----------------------------- Admin -----------------------------

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

    function setMaxPriceAge(uint256 secondsAge) external onlyOwner {
        maxPriceAge = secondsAge;
        emit MaxPriceAgeUpdated(secondsAge);
    }

    /// @notice End sale and sweep remaining TMINE to treasury.
    function endSale() external onlyOwner nonReentrant {
        require(!saleEnded, "Already ended");
        saleEnded = true;

        uint256 bal = token.balanceOf(address(this));
        if (bal > 0) {
            require(token.transfer(treasury, bal), "Return to treasury failed");
        }
        emit SaleEnded();
    }

    // ----------------------------- Rescue -----------------------------

    function rescueETH(address payable to, uint256 amount) external onlyOwner nonReentrant {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "rescue fail");
        emit ETHRescued(to, amount);
    }

    function rescueERC20(address tokenAddress, address to, uint256 amount) external onlyOwner nonReentrant {
        require(tokenAddress != address(token), "Can't rescue sale token");
        IERC20(tokenAddress).transfer(to, amount);
        emit ERC20Rescued(tokenAddress, to, amount);
    }
}
