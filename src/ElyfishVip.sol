// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title Elyfish VIP — the game's VIP membership, kept on chain
/// @notice A wallet is VIP while `vipUntil(wallet)` is in the future; the game server reads that number and gives the
/// perks (more bag slots, XP and sell price, unlimited auto sell / auto fishing, the badge). VIP is sold in periods of
/// 30 days at a flat US-dollar price, paid in the chain's native coin (HYPE) at the HYPE / USD rate of a Chainlink price
/// feed. More time adds on to what is left, up to a year ahead. The owner can also give VIP away: straight to a list of
/// wallets (`grant`), or as an airdrop the eligible wallets claim themselves (`claimAirdrop`, a Merkle tree of wallets).
contract ElyfishVip is Ownable2Step, Pausable, ReentrancyGuard {
    /// @notice one VIP period
    uint256 public constant PERIOD = 30 days;
    /// @notice VIP never reaches further than this from now
    uint256 public constant MAX_AHEAD = 365 days;
    /// @notice most periods one purchase buys (12 × 30 days = 360 days)
    uint256 public constant MAX_PERIODS = 12;
    /// @notice prices are in USD with 8 decimals ($1 = 1e8); a period never costs more than $1,000
    uint256 public constant MAX_USD_PRICE = 1_000e8;
    /// @notice a price older than this can never be accepted, whatever maxStaleness says
    uint256 public constant MAX_STALENESS_CAP = 7 days;
    /// @notice most wallets one `grant` call gives VIP to
    uint256 public constant MAX_BATCH = 500;
    /// @notice most days one grant or airdrop round gives
    uint32 public constant MAX_GIFT_DAYS = 365;

    /// @notice the price of one 30-day period, USD with 8 decimals
    uint256 public usdPrice;
    AggregatorV3Interface public priceFeed;
    /// @notice the oldest HYPE / USD answer a purchase accepts, in seconds
    uint256 public maxStaleness;
    /// @notice when each wallet's VIP ends (unix seconds; 0 = never had it)
    mapping(address wallet => uint64) public vipUntil;

    /// @notice the current airdrop: the Merkle root of the eligible wallets (0 = no airdrop open), its number and how many
    /// days each claim gives
    bytes32 public airdropRoot;
    uint32 public airdropRound;
    uint32 public airdropDays;
    /// @notice whether a wallet has claimed a given airdrop round
    mapping(uint32 round => mapping(address wallet => bool)) public claimed;

    event VipBought(address indexed payer, address indexed wallet, uint256 periods, uint256 paid, uint64 until);
    event VipGranted(address indexed wallet, uint32 days_, uint64 until);
    event AirdropOpened(uint32 indexed round, bytes32 root, uint32 days_);
    event AirdropClaimed(uint32 indexed round, address indexed wallet, uint64 until);
    event PriceSet(uint256 usd);
    event PriceFeedSet(address indexed feed, uint256 maxStaleness);
    event Withdrawn(address indexed to, uint256 amount);

    error BadPeriods(uint256 periods);
    error Underpaid(uint256 cost, uint256 sent);
    error TooFarAhead(uint64 until);
    error BadPrice();
    error StalePrice(uint256 updatedAt);
    error BadFeed();
    error PriceTooHigh(uint256 usd);
    error ZeroAddress();
    error BadBatch(uint256 size);
    error BadDays(uint32 days_);
    error NoAirdrop();
    error AlreadyClaimed(uint32 round, address wallet);
    error NotEligible(address wallet);
    error TransferFailed();

    /// @param owner_ who sets the price, gives VIP away and withdraws
    /// @param feed a HYPE / USD price feed (Chainlink AggregatorV3)
    /// @param maxStaleness_ the oldest answer accepted, seconds (1 .. 7 days)
    /// @param usd the price of one 30-day period, USD with 8 decimals ($12 = 12e8)
    constructor(address owner_, address feed, uint256 maxStaleness_, uint256 usd) Ownable(owner_) {
        _setFeed(feed, maxStaleness_);
        _setPrice(usd);
    }

    // ── buying ──────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice buy `periods` × 30 days of VIP for yourself; HYPE sent above the price comes back
    function buy(uint256 periods) external payable {
        buyFor(msg.sender, periods);
    }

    /// @notice buy `periods` × 30 days of VIP for any wallet (a gift); HYPE sent above the price comes back to the payer
    function buyFor(address wallet, uint256 periods) public payable whenNotPaused nonReentrant {
        if (wallet == address(0)) revert ZeroAddress();
        uint256 cost = quote(periods);
        if (msg.value < cost) revert Underpaid(cost, msg.value);
        uint64 until = _extendedUntil(wallet, periods * PERIOD);
        if (until > block.timestamp + MAX_AHEAD) revert TooFarAhead(until);
        vipUntil[wallet] = until;
        emit VipBought(msg.sender, wallet, periods, cost, until);
        if (msg.value > cost) _send(payable(msg.sender), msg.value - cost);
    }

    /// @notice what `periods` × 30 days cost now, in HYPE (wei, 18 decimals), rounded up
    function quote(uint256 periods) public view returns (uint256) {
        if (periods == 0 || periods > MAX_PERIODS) revert BadPeriods(periods);
        (uint256 rate, uint8 dec) = hypeUsd();
        // usd (8 decimals) / rate (dec decimals) HYPE, as wei: usd · 10^dec · 10^18 / (rate · 10^8)
        return Math.mulDiv(usdPrice * periods * 10 ** dec, 1e18, rate * 1e8, Math.Rounding.Ceil);
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

    // ── reading ─────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice whether a wallet is VIP right now
    function isVip(address wallet) external view returns (bool) {
        return vipUntil[wallet] > block.timestamp;
    }

    /// @notice the seconds of VIP a wallet has left (0 when it is not VIP)
    function timeLeft(address wallet) external view returns (uint256) {
        uint256 until = vipUntil[wallet];
        return until > block.timestamp ? until - block.timestamp : 0;
    }

    // ── giving VIP away ─────────────────────────────────────────────────────────────────────────────────────────

    /// @notice give `days_` of VIP to each wallet (added to what it has; anything past a year ahead is cut off)
    function grant(address[] calldata wallets, uint32 days_) external onlyOwner {
        if (wallets.length == 0 || wallets.length > MAX_BATCH) revert BadBatch(wallets.length);
        _checkDays(days_);
        for (uint256 i = 0; i < wallets.length; i++) {
            address w = wallets[i];
            if (w == address(0)) revert ZeroAddress();
            uint64 until = _gift(w, days_);
            emit VipGranted(w, days_, until);
        }
    }

    /// @notice open a new airdrop round (the old one closes): the eligible wallets are the leaves of a Merkle tree, each
    /// leaf keccak256(bytes.concat(keccak256(abi.encode(wallet)))) (OpenZeppelin StandardMerkleTree, type ["address"]).
    /// A zero root closes the airdrop.
    function setAirdrop(bytes32 root, uint32 days_) external onlyOwner {
        if (root != bytes32(0)) _checkDays(days_);
        airdropRound += 1;
        airdropRoot = root;
        airdropDays = root == bytes32(0) ? 0 : days_;
        emit AirdropOpened(airdropRound, root, airdropDays);
    }

    /// @notice claim this round's airdrop, once per wallet: `proof` shows the caller is on the list
    function claimAirdrop(bytes32[] calldata proof) external whenNotPaused {
        uint32 round = airdropRound;
        if (airdropRoot == bytes32(0)) revert NoAirdrop();
        if (claimed[round][msg.sender]) revert AlreadyClaimed(round, msg.sender);
        if (!isEligible(msg.sender, proof)) revert NotEligible(msg.sender);
        claimed[round][msg.sender] = true;
        uint64 until = _gift(msg.sender, airdropDays);
        emit AirdropClaimed(round, msg.sender, until);
    }

    /// @notice whether `proof` puts `wallet` on the current airdrop's list (claimed or not)
    function isEligible(address wallet, bytes32[] calldata proof) public view returns (bool) {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(wallet))));
        return airdropRoot != bytes32(0) && MerkleProof.verifyCalldata(proof, airdropRoot, leaf);
    }

    // ── owner ───────────────────────────────────────────────────────────────────────────────────────────────────

    function setPrice(uint256 usd) external onlyOwner {
        _setPrice(usd);
    }

    function setPriceFeed(address feed, uint256 maxStaleness_) external onlyOwner {
        _setFeed(feed, maxStaleness_);
    }

    /// @notice stops buying and claiming (granting, reading and withdrawing still work)
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice send all the HYPE paid for VIP to `to`
    function withdraw(address payable to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        emit Withdrawn(to, amount);
        _send(to, amount);
    }

    // ── inside ──────────────────────────────────────────────────────────────────────────────────────────────────

    /// when VIP would end with `secs` more: added to the time left, or from now when it has run out
    function _extendedUntil(address wallet, uint256 secs) private view returns (uint64) {
        uint256 from = Math.max(vipUntil[wallet], block.timestamp);
        // (from ≤ now + a year and secs ≤ a year: far below 2^64)
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(from + secs);
    }

    /// a gift of days: like a purchase, but anything past a year ahead is cut off instead of refused
    function _gift(address wallet, uint32 days_) private returns (uint64 until) {
        until = _extendedUntil(wallet, uint256(days_) * 1 days);
        uint256 cap = block.timestamp + MAX_AHEAD;
        // (cap is far below 2^64)
        // forge-lint: disable-next-line(unsafe-typecast)
        if (until > cap) until = uint64(cap);
        if (until > vipUntil[wallet]) vipUntil[wallet] = until;
        else until = vipUntil[wallet];
    }

    function _checkDays(uint32 days_) private pure {
        if (days_ == 0 || days_ > MAX_GIFT_DAYS) revert BadDays(days_);
    }

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
