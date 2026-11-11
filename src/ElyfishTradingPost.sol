// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title Elyfish Trading Post — game items sold between players for HYPE
/// @notice The items themselves (fish, ores, meat, harvest, seeds, food) live in the game. When a player lists some for
/// HYPE, the game server takes them out of the seller's bag and signs the listing (EIP-712: id, seller, price, expiry).
/// A buyer pays that price here, once: 3 % goes to the trading post, 97 % to the seller, anything sent above the price
/// comes back. The game server then reads this contract (status, buyerOf) and gives the items to the buyer's account —
/// or back to the seller once the listing was cancelled here, or ran out without a sale.
/// Nothing here can be bought twice, after it was cancelled, after its expiry, without the server's signature, or for
/// less than its price; the HYPE held is always exactly the fees not yet withdrawn plus what sellers are still owed.
contract ElyfishTradingPost is Ownable2Step, Pausable, ReentrancyGuard, EIP712 {
    /// @notice the trading post's cut of every sale: 3 %
    uint256 public constant FEE_BPS = 300;
    uint256 public constant BPS = 10_000;
    /// @notice prices between 0.000001 and 1,000,000 HYPE
    uint256 public constant MIN_PRICE = 1e12;
    uint256 public constant MAX_PRICE = 1_000_000 ether;
    /// @notice a listing can't run longer than this from when it is bought or cancelled (a signature far in the future is
    /// refused)
    uint256 public constant MAX_RUN = 30 days;
    /// @notice gas the seller's payout gets (enough for a wallet or a smart-wallet's receive; a contract that needs more
    /// or refuses is credited instead and withdraws later)
    uint256 public constant PAYOUT_GAS = 50_000;

    struct Listing {
        uint256 id; // the game server's listing number
        address seller; // the seller's wallet (the game account's)
        uint256 price; // in wei of HYPE, the whole listing
        uint64 expiry; // unix seconds: no sale after this
    }

    enum Status {
        Open, // never bought or cancelled (also: a number never listed)
        Sold,
        Cancelled
    }

    bytes32 public constant LISTING_TYPEHASH =
        keccak256("Listing(uint256 id,address seller,uint256 price,uint64 expiry)");

    /// @notice the game server's signing address: only listings it signed can be bought
    address public signer;
    mapping(uint256 id => Status) public status;
    mapping(uint256 id => address) public buyerOf;
    /// @notice HYPE a seller is owed (only when sending it straight away did not work)
    mapping(address seller => uint256) public owed;
    uint256 public totalOwed;
    /// @notice the trading post's fees not yet withdrawn
    uint256 public feesAccrued;

    event Bought(uint256 indexed id, address indexed buyer, address indexed seller, uint256 price, uint256 fee);
    event Cancelled(uint256 indexed id, address indexed by);
    event Owed(address indexed seller, uint256 amount);
    event OwedWithdrawn(address indexed seller, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event SignerSet(address indexed signer);

    error BadListing();
    error BadSignature();
    error NotOpen(uint256 id, Status status);
    error Expired(uint256 id, uint64 expiry);
    error TooLong(uint256 id, uint64 expiry);
    error OwnListing();
    error BadPrice(uint256 price);
    error Underpaid(uint256 price, uint256 sent);
    error NotAllowed();
    error ZeroAddress();
    error NothingOwed();
    error TransferFailed();

    constructor(address owner_, address signer_) Ownable(owner_) EIP712("Elyfish Trading Post", "1") {
        _setSigner(signer_);
    }

    // ── buying ──────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice buy a listing the game server signed: pay at least its price (the rest comes back)
    function buy(Listing calldata l, bytes calldata sig) external payable whenNotPaused nonReentrant {
        _check(l, sig);
        if (msg.sender == l.seller) revert OwnListing();
        if (msg.value < l.price) revert Underpaid(l.price, msg.value);

        status[l.id] = Status.Sold;
        buyerOf[l.id] = msg.sender;
        uint256 fee = (l.price * FEE_BPS) / BPS;
        uint256 proceeds = l.price - fee;
        feesAccrued += fee;
        emit Bought(l.id, msg.sender, l.seller, l.price, fee);

        // the seller is paid now if their wallet takes it; else it waits for them (withdrawOwed) — a seller can't
        // block a sale
        (bool ok,) = payable(l.seller).call{value: proceeds, gas: PAYOUT_GAS}("");
        if (!ok) {
            owed[l.seller] += proceeds;
            totalOwed += proceeds;
            emit Owed(l.seller, proceeds);
        }
        uint256 extra = msg.value - l.price;
        if (extra > 0) _send(payable(msg.sender), extra);
    }

    /// @notice end a listing before it sells: its seller (with the listing's signature), the game server's signer or the
    /// owner. The game gives the items back once it sees this.
    function cancel(Listing calldata l, bytes calldata sig) external {
        _check(l, sig);
        if (msg.sender != l.seller && msg.sender != signer && msg.sender != owner()) revert NotAllowed();
        status[l.id] = Status.Cancelled;
        emit Cancelled(l.id, msg.sender);
    }

    /// @notice a seller takes the HYPE that could not be sent to them at the sale
    function withdrawOwed() external nonReentrant {
        uint256 amount = owed[msg.sender];
        if (amount == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        totalOwed -= amount;
        emit OwedWithdrawn(msg.sender, amount);
        _send(payable(msg.sender), amount);
    }

    // ── reading ─────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice the EIP-712 digest the game server signs for a listing
    function hashListing(Listing calldata l) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(LISTING_TYPEHASH, l.id, l.seller, l.price, l.expiry)));
    }

    /// @notice whether this listing and signature would be accepted by buy right now (ignoring the payment and buyer)
    function isBuyable(Listing calldata l, bytes calldata sig) external view returns (bool) {
        if (paused() || status[l.id] != Status.Open || block.timestamp > l.expiry) return false;
        if (l.seller == address(0) || l.price < MIN_PRICE || l.price > MAX_PRICE || l.expiry > block.timestamp + MAX_RUN) return false;
        (address got, ECDSA.RecoverError err,) = ECDSA.tryRecover(hashListing(l), sig);
        return err == ECDSA.RecoverError.NoError && got == signer;
    }

    // ── owner ───────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice a new game-server signing key (listings signed by the old one can no longer be bought or cancelled)
    function setSigner(address signer_) external onlyOwner {
        _setSigner(signer_);
    }

    /// @notice stops buying (cancelling and withdrawing still work)
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice the trading post's fees to `to` — never the sellers' owed HYPE
    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = feesAccrued;
        feesAccrued = 0;
        emit FeesWithdrawn(to, amount);
        _send(to, amount);
    }

    // ── inside ──────────────────────────────────────────────────────────────────────────────────────────────────

    /// an open, well-formed, unexpired listing with the server's signature
    function _check(Listing calldata l, bytes calldata sig) private view {
        if (l.seller == address(0)) revert BadListing();
        if (l.price < MIN_PRICE || l.price > MAX_PRICE) revert BadPrice(l.price);
        Status s = status[l.id];
        if (s != Status.Open) revert NotOpen(l.id, s);
        if (block.timestamp > l.expiry) revert Expired(l.id, l.expiry);
        if (l.expiry > block.timestamp + MAX_RUN) revert TooLong(l.id, l.expiry);
        (address got, ECDSA.RecoverError err,) = ECDSA.tryRecover(hashListing(l), sig);
        if (err != ECDSA.RecoverError.NoError || got != signer) revert BadSignature();
    }

    function _setSigner(address signer_) private {
        if (signer_ == address(0)) revert ZeroAddress();
        signer = signer_;
        emit SignerSet(signer_);
    }

    function _send(address payable to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
