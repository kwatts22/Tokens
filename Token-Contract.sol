// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/* OpenZeppelin v5.4.0 (raw URLs for Remix) */
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/token/ERC20/ERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/access/Ownable.sol";

/// @custom:security-contact security@togethermining.xyz
contract TogetherMining is ERC20, ERC20Burnable, ERC20Pausable, ERC20Permit, Ownable {
    address public treasury;
    address public crowdsale;
    bool public tradingOpen = false;

    event TradingOpened();
    event TradingClosed();
    event TreasuryUpdated(address indexed treasury);
    event CrowdsaleUpdated(address indexed crowdsale);

    constructor(address _treasury, address initialOwner)
        ERC20("Together Mining", "TMINE")
        ERC20Permit("Together Mining")
        Ownable(initialOwner)
    {
        require(_treasury != address(0), "treasury=0");
        treasury = _treasury;
        _mint(_treasury, 1_000_000_000 * 10 ** decimals());
        emit TreasuryUpdated(_treasury);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "treasury=0");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setCrowdsale(address _crowdsale) external onlyOwner {
        require(_crowdsale != address(0), "crowdsale=0");
        crowdsale = _crowdsale;
        emit CrowdsaleUpdated(_crowdsale);
    }

    function openTrading() external onlyOwner {
        require(!tradingOpen, "Already open");
        tradingOpen = true;
        emit TradingOpened();
    }

    function closeTrading() external onlyOwner {
        require(tradingOpen, "Already closed");
        tradingOpen = false;
        emit TradingClosed();
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function mint(address to, uint256 amount) external onlyOwner { _mint(to, amount); }

    // Transfer gate while trading is closed:
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        if (!tradingOpen && from != address(0) && to != address(0)) {
            bool allowed = (from == treasury && to == crowdsale) || (from == crowdsale);
            require(allowed, "Transfers locked");
        }
        super._update(from, to, value);
    }
}
