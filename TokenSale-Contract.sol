// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * TMINECrowdsale (Polygon-ready)
 * - Pay with USDC (6d) or native MATIC (priced via Chainlink MATIC/USD)
 * - Time bonus: Weeks 1–2 = +20%, Weeks 3–4 = +10%, then 0%
 * - Optional promo bonus (bps) owner-set
 * - Owner can raise hard cap later
 * - SafeERC20 + ReentrancyGuard + Chainlink price freshness guard
 * - endSale() sweeps unsold TMINE back to treasury
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract TMINECrowdsale is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- constants ---
    uint8   public constant USDC_DECIMALS   = 6;
    uint8   public constant TOKEN_DECIMALS  = 18;
    uint256 public constant DECIMAL_ADJUST  = 10 ** (TOKEN_DECIMALS - USDC_DECIMALS); // 1e12
    uint256 public constant WEEK            = 7 days;

    // --- core state ---
    IERC20 public immutable tmine;              // 18-dec token being sold
    IERC20 public immutable usdc;               // USDC (6 decimals)
    AggregatorV3Interface public nativeUsdFeed; // MATIC/USD feed (Chainlink)
    address payable public treasury;            // where raised funds go

    // Base rate: TMINE per 1 USDC (e.g., 10 => $0.10/token)
    uint256 public rate;

    // Sale window + switch
    uint256 public startTime;
    uint256 public endTime;
    bool    public isActive;

    // Accounting
    uint256 public tokensSoldBase;  // base TMINE (18d) sold (excludes bonus)
    uint256 public hardCapTokens;   // cap for base TMINE (18d)

    // Promo bonus (bps). 100 bps = 1%. 0 = off.
    uint16  public promoBonusBps;

    // Chainlink price staleness guard (max age in seconds)
    uint256 public maxPriceAge = 3 hours;

    // --- custom errors ---
    error Inactive();
    error OutsideWindow();
    error ZeroAmount();
    error HardCap();
    error InsufficientInventory();
    error BadRate();
    error BadTimes();
    error BadAddress();
    error PriceInvalid();
    error PriceStale();
    error CapBelowSold();
    error PromoTooHigh();
    error ActiveSale();

    // --- events ---
    event TokensPurchased(
        address indexed buyer,
        uint256 usdcValue,
        uint256 baseTokens,
        uint256 bonusTokens,
        bool paidWithMATIC
    );
    event ActiveSet(bool active);
    event TreasuryUpdated(address indexed treasury);
    event RateUpdated(uint256 rate);
    event TimeWindowUpdated(uint256 startTime, uint256 endTime);
    event PriceFeedUpdated(address indexed feed);
    event PromoBonusUpdated(uint16 bps);
    event HardCapUpdated(uint256 newHardCapTokens);
    event MaxPriceAgeUpdated(uint256 secondsAge);
    event Ended(uint256 sweptTokens);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event ETHRescued(address indexed to, uint256 amount);

    constructor(
        address _tmine,
        address _usdc,
        address payable _treasury,
        uint256 _rate,                 // TMINE per 1 USDC (10 => $0.10)
        uint256 _startTime,
        uint256 _endTime,
        uint256 _hardCapWholeTokens,   // e.g., 200_000_000 for 200M
        address _nativeUsdPriceFeed,   // Chainlink MATIC/USD
        address _initialOwner          // Ownable v5 requires initial owner
    ) Ownable(_initialOwner) {
        if (_tmine == address(0) || _usdc == address(0) || _treasury == address(0) || _nativeUsdPriceFeed == address(0)) revert BadAddress();
        if (_startTime >= _endTime) revert BadTimes();
        if (_rate == 0) revert BadRate();

        tmine    = IERC20(_tmine);
        usdc     = IERC20(_usdc);
        treasury = _treasury;
        rate     = _rate;

        startTime     = _startTime;
        endTime       = _endTime;
        isActive      = true;
        hardCapTokens = _hardCapWholeTokens * 1e18;

        nativeUsdFeed   = AggregatorV3Interface(_nativeUsdPriceFeed);
        promoBonusBps   = 0;
    }

    // ========= BUY FUNCTIONS =========

    /// @notice Buy with USDC (spender must approve USDC to this contract).
    function buyWithUSDC(uint256 usdcAmount) external nonReentrant {
        _preChecks();
        if (usdcAmount == 0) revert ZeroAmount();

        // Pull USDC to treasury
        usdc.safeTransferFrom(msg.sender, treasury, usdcAmount);

        // Base tokens @ rate, scaled to 18 decimals
        uint256 baseTokens = usdcAmount * rate * DECIMAL_ADJUST; // USDC-6 * rate * 1e12
        _enforceCap(baseTokens);

        (uint256 bonus, uint256 total) = _bonusAndTotal(baseTokens);
        if (tmine.balanceOf(address(this)) < total) revert InsufficientInventory();

        tokensSoldBase += baseTokens;
        tmine.safeTransfer(msg.sender, total);

        emit TokensPurchased(msg.sender, usdcAmount, baseTokens, bonus, false);
    }

    /// @notice Buy with native MATIC (priced in USD via Chainlink MATIC/USD). Sends MATIC to treasury.
    function buyWithMATIC() public payable nonReentrant {
        _preChecks();
        uint256 weiAmount = msg.value;
        if (weiAmount == 0) revert ZeroAmount();

        uint256 usdcAmount = _usdcFromWeiOrRevert(weiAmount); // USDC-6
        uint256 baseTokens = usdcAmount * rate * DECIMAL_ADJUST;
        _enforceCap(baseTokens);

        (uint256 bonus, uint256 total) = _bonusAndTotal(baseTokens);
        if (tmine.balanceOf(address(this)) < total) revert InsufficientInventory();

        tokensSoldBase += baseTokens;

        // Forward native MATIC to treasury
        Address.sendValue(treasury, weiAmount);

        tmine.safeTransfer(msg.sender, total);

        emit TokensPurchased(msg.sender, usdcAmount, baseTokens, bonus, true);
    }

    // Legacy alias (if frontend still calls ETH)
    function buyWithETH() external payable { buyWithMATIC(); }

    // ========= OWNER / ADMIN =========

    function setActive(bool _active) external onlyOwner {
        isActive = _active;
        emit ActiveSet(_active);
    }

    /// @notice Ends sale and sweeps remaining TMINE to treasury.
    function endSale() external onlyOwner nonReentrant {
        isActive = false;
        uint256 bal = tmine.balanceOf(address(this));
        if (bal > 0) {
            tmine.safeTransfer(treasury, bal);
        }
        emit Ended(bal);
    }

    function setRate(uint256 _rate) external onlyOwner {
        if (_rate == 0) revert BadRate();
        rate = _rate;
        emit RateUpdated(_rate);
    }

    function setTimeWindow(uint256 _start, uint256 _end) external onlyOwner {
        if (_start >= _end) revert BadTimes();
        startTime = _start;
        endTime   = _end;
        emit TimeWindowUpdated(_start, _end);
    }

    function setPriceFeed(address _feed) external onlyOwner {
        if (_feed == address(0)) revert BadAddress();
        nativeUsdFeed = AggregatorV3Interface(_feed);
        emit PriceFeedUpdated(_feed);
    }

    function setTreasury(address payable _treasury) external onlyOwner {
        if (_treasury == address(0)) revert BadAddress();
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /// @notice Set an optional promo bonus in basis points (100 bps = 1%). Max 50% (5000 bps).
    function setPromoBonusBps(uint16 bps) external onlyOwner {
        if (bps > 5000) revert PromoTooHigh();
        promoBonusBps = bps;
        emit PromoBonusUpdated(bps);
    }

    /// @notice Raise (or lower) the base-token hard cap using whole-token units.
    function setHardCapWholeTokens(uint256 _hardCapWholeTokens) external onlyOwner {
        _setHardCapTokens18(_hardCapWholeTokens * 1e18);
    }

    /// @notice Set the base-token hard cap directly in 18 decimals.
    function setHardCapTokens18(uint256 newCap18) external onlyOwner {
        _setHardCapTokens18(newCap18);
    }

    function _setHardCapTokens18(uint256 newCap18) internal {
        if (newCap18 < tokensSoldBase) revert CapBelowSold();
        hardCapTokens = newCap18;
        emit HardCapUpdated(newCap18);
    }

    /// @notice Set max accepted price age for Chainlink (staleness guard).
    function setMaxPriceAge(uint256 secondsAge) external onlyOwner {
        maxPriceAge = secondsAge;
        emit MaxPriceAgeUpdated(secondsAge);
    }

    /// @notice Rescue non-sale tokens or stuck MATIC/ETH (never rescues TMINE while active).
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(tmine) && isActive) revert ActiveSale();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function rescueETH(address payable to, uint256 amount) external onlyOwner nonReentrant {
        Address.sendValue(to, amount);
        emit ETHRescued(to, amount);
    }

    // ========= VIEWS (for UI) =========

    /// @notice Returns (base, bonus, total) TMINE for a USDC amount (USDC-6).
    function previewTokensForUSDC(uint256 usdcAmount)
        external
        view
        returns (uint256 baseTokens, uint256 bonusTokens, uint256 total)
    {
        baseTokens  = usdcAmount * rate * DECIMAL_ADJUST;
        bonusTokens = _calculateBonus(baseTokens);
        total       = baseTokens + bonusTokens;
    }

    /// @notice Returns (usdcAmount, base, bonus, total) for a MATIC amount (wei).
    /// If price is invalid/stale, returns zeros (UI-friendly).
    function previewTokensForMATIC(uint256 weiAmount)
        public
        view
        returns (uint256 usdcAmount, uint256 baseTokens, uint256 bonusTokens, uint256 total)
    {
        (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) = nativeUsdFeed.latestRoundData();
        if (price <= 0 || answeredInRound < roundId) return (0,0,0,0);
        if (maxPriceAge > 0 && block.timestamp > updatedAt + maxPriceAge) return (0,0,0,0);

        uint8 pdec   = nativeUsdFeed.decimals();     // typically 8
        uint256 usd18 = (weiAmount * uint256(price)) / (10 ** pdec);
        usdcAmount    = usd18 / 1e12;                // to USDC-6
        baseTokens    = usdcAmount * rate * DECIMAL_ADJUST;
        bonusTokens   = _calculateBonus(baseTokens);
        total         = baseTokens + bonusTokens;
    }

    // Legacy alias (frontend may still call ETH-named view)
    function previewTokensForETH(uint256 weiAmount)
        external
        view
        returns (uint256 usdcAmount, uint256 baseTokens, uint256 bonusTokens, uint256 total)
    {
        return previewTokensForMATIC(weiAmount);
    }

    // ========= INTERNALS =========

    function _preChecks() internal view {
        if (!isActive) revert Inactive();
        if (block.timestamp < startTime || block.timestamp > endTime) revert OutsideWindow();
    }

    function _enforceCap(uint256 baseTokens) internal view {
        if (tokensSoldBase + baseTokens > hardCapTokens) revert HardCap();
    }

    /// @dev Helper used in buy functions.
    function _bonusAndTotal(uint256 baseTokens) internal view returns (uint256 bonus, uint256 total) {
        bonus = _calculateBonus(baseTokens);
        total = baseTokens + bonus;
    }

    /// @dev Time bonus + promo bonus (bps).
    function _calculateBonus(uint256 baseTokens) internal view returns (uint256 b) {
        unchecked {
            if (block.timestamp < startTime + 2 * WEEK) {
                b += (baseTokens * 20) / 100; // +20%
            } else if (block.timestamp < startTime + 4 * WEEK) {
                b += (baseTokens * 10) / 100; // +10%
            }
            if (promoBonusBps > 0) {
                b += (baseTokens * promoBonusBps) / 10_000;
            }
        }
    }

    /// @dev Converts wei (MATIC) -> USDC-6 using Chainlink, reverting on invalid/stale price.
    function _usdcFromWeiOrRevert(uint256 weiAmount) internal view returns (uint256 usdcAmount) {
        (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) = nativeUsdFeed.latestRoundData();
        if (price <= 0 || answeredInRound < roundId) revert PriceInvalid();
        if (maxPriceAge > 0 && block.timestamp > updatedAt + maxPriceAge) revert PriceStale();

        uint8 pdec   = nativeUsdFeed.decimals();     // typically 8
        uint256 usd18 = (weiAmount * uint256(price)) / (10 ** pdec);
        usdcAmount    = usd18 / 1e12;                // to USDC-6
    }

    // Block direct MATIC sends; must call buyWithMATIC()
    receive() external payable {
        revert("use buyWithMATIC()");
    }
}
