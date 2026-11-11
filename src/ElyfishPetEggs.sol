// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title Elyfish Pet Eggs — packs of 10 pet eggs for the game's pet gacha, bought with HYPE
/// @notice A pack is 10 eggs at a flat US-dollar price, paid in the chain's native coin (HYPE) at the HYPE / USD rate of
/// a Chainlink price feed. The contract only counts the packs each wallet ever got (`packsOf`, never goes down); the
/// game server reads that count, gives the wallet's game account 10 eggs for every pack it has not given yet, and
/// hatches them with the game's odds. The owner can also give packs away (`grant`).
contract ElyfishPetEggs is Ownable2Step, Pausable, ReentrancyGuard {
    /// @notice eggs in one pack
    uint256 public constant EGGS_PER_PACK = 10;
    /// @notice most packs one purchase buys
    uint256 public constant MAX_PACKS = 10;
    /// @notice prices are in USD with 8 decimals ($1 = 1e8); a pack never costs more than $1,000
    uint256 public constant MAX_USD_PRICE = 1_000e8;
    /// @notice a price older than this can never be accepted, whatever maxStaleness says
    uint256 public constant MAX_STALENESS_CAP = 7 days;
    /// @notice most wallets one `grant` call gives packs to
    uint256 public constant MAX_BATCH = 500;

    /// @notice the price of one pack, USD with 8 decimals
    uint256 public usdPrice;
    AggregatorV3Interface public priceFeed;
    /// @notice the oldest HYPE / USD answer a purchase accepts, in seconds
    uint256 public maxStaleness;
    /// @notice every pack a wallet ever got, bought or given (only goes up)
    mapping(address wallet => uint256) public packsOf;

    event PacksBought(address indexed payer, address indexed wallet, uint256 packs, uint256 paid, uint256 total);
    event PacksGranted(address indexed wallet, uint256 packs, uint256 total);
    event PriceSet(uint256 usd);
    event PriceFeedSet(address indexed feed, uint256 maxStaleness);
    event Withdrawn(address indexed to, uint256 amount);

    error BadPacks(uint256 packs);
    error Underpaid(uint256 cost, uint256 sent);
    error BadPrice();
    error StalePrice(uint256 updatedAt);
    error BadFeed();
    error PriceTooHigh(uint256 usd);
    error ZeroAddress();
    error BadBatch(uint256 size);
    error TransferFailed();

    /// @param owner_ who sets the price, gives packs away and withdraws
    /// @param feed a HYPE / USD price feed (Chainlink AggregatorV3)
    /// @param maxStaleness_ the oldest answer accepted, seconds (1 .. 7 days)
    /// @param usd the price of one pack of 10 eggs, USD with 8 decimals ($5 = 5e8)
    constructor(address owner_, address feed, uint256 maxStaleness_, uint256 usd) Ownable(owner_) {
        _setFeed(feed, maxStaleness_);
        _setPrice(usd);
    }

    // ── buying ──────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice buy `packs` packs of 10 eggs for yourself; HYPE sent above the price comes back
    function buy(uint256 packs) external payable {
        buyFor(msg.sender, packs);
    }

    /// @notice buy `packs` packs for any wallet (a gift); HYPE sent above the price comes back to the payer
    function buyFor(address wallet, uint256 packs) public payable whenNotPaused nonReentrant {
        if (wallet == address(0)) revert ZeroAddress();
        uint256 cost = quote(packs);
        if (msg.value < cost) revert Underpaid(cost, msg.value);
        uint256 total = packsOf[wallet] + packs;
        packsOf[wallet] = total;
        emit PacksBought(msg.sender, wallet, packs, cost, total);
        if (msg.value > cost) _send(payable(msg.sender), msg.value - cost);
    }

    /// @notice what `packs` packs cost now, in HYPE (wei, 18 decimals), rounded up
    function quote(uint256 packs) public view returns (uint256) {
        if (packs == 0 || packs > MAX_PACKS) revert BadPacks(packs);
        (uint256 rate, uint8 dec) = hypeUsd();
        // usd (8 decimals) / rate (dec decimals) HYPE, as wei: usd · 10^dec · 10^18 / (rate · 10^8)
        return Math.mulDiv(usdPrice * packs * 10 ** dec, 1e18, rate * 1e8, Math.Rounding.Ceil);
    }

    /// @notice the HYPE / USD rate from the feed, checked: positive, from a finished round, not too old
    function hypeUsd() public view returns (uint256 rate, uint8 dec) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        if (answer <= 0) revert BadPrice();
        if (answeredInRound < roundId || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxStaleness) {
            revert StalePrice(updatedAt);
        }
        // (answer > 0 (checked above))
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(answer), priceFeed.decimals());
    }

    /// @notice every egg a wallet ever got (packs × 10)
    function eggsOf(address wallet) external view returns (uint256) {
        return packsOf[wallet] * EGGS_PER_PACK;
    }

    // ── owner ───────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice give `packs` packs to each wallet
    function grant(address[] calldata wallets, uint256 packs) external onlyOwner {
        if (wallets.length == 0 || wallets.length > MAX_BATCH) revert BadBatch(wallets.length);
        if (packs == 0 || packs > MAX_PACKS) revert BadPacks(packs);
        for (uint256 i = 0; i < wallets.length; i++) {
            address w = wallets[i];
            if (w == address(0)) revert ZeroAddress();
            uint256 total = packsOf[w] + packs;
            packsOf[w] = total;
            emit PacksGranted(w, packs, total);
        }
    }

    function setPrice(uint256 usd) external onlyOwner {
        _setPrice(usd);
    }

    function setPriceFeed(address feed, uint256 maxStaleness_) external onlyOwner {
        _setFeed(feed, maxStaleness_);
    }

    /// @notice stops buying (granting, reading and withdrawing still work)
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice send all the HYPE paid for eggs to `to`
    function withdraw(address payable to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        emit Withdrawn(to, amount);
        _send(to, amount);
    }

    // ── inside ──────────────────────────────────────────────────────────────────────────────────────────────────

    function _setPrice(uint256 usd) private {
        if (usd == 0) revert BadPrice();
        if (usd > MAX_USD_PRICE) revert PriceTooHigh(usd);
        usdPrice = usd;
        emit PriceSet(usd);
    }

    function _setFeed(address feed, uint256 maxStaleness_) private {
        if (feed == address(0) || maxStaleness_ == 0 || maxStaleness_ > MAX_STALENESS_CAP) revert BadFeed();
        if (AggregatorV3Interface(feed).decimals() > 18) revert BadFeed();
        priceFeed = AggregatorV3Interface(feed);
        maxStaleness = maxStaleness_;
        emit PriceFeedSet(feed, maxStaleness_);
    }

    function _send(address payable to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
