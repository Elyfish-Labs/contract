// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILaunchRouter, IBurnable, PoolKey} from "./interfaces/ILaunchRouter.sol";

/// @title Elyfish Revenue — where the game's HYPE goes, decided on chain
/// @notice This contract owns the game's paid contracts (VIP, pet eggs, NFT skins, the HYPE trading post). Their HYPE can
/// only leave them into here, and here it is split by where it came from, the moment it arrives:
///   sales (VIP, pet eggs, NFT skins): 50 % platform, 20 % community, 30 % buyback and burn
///   trading post fees (3 % of a sale): 1 % platform, 2 % buyback and burn (parts 1 : 0 : 2)
/// `sweep()` (anyone) pulls every source's HYPE in; `release()` (anyone) pays the platform and community wallets; the
/// buyback buys the game token with its share through a Montra LaunchRouter (Uniswap v4) and burns what it bought in the
/// same transaction. A buyback needs a minimum output, so only the owner or a keeper runs it (a minimum taken on chain
/// in the same block protects nothing against a sandwich); each one is capped.
/// The owner still runs the paid contracts' own settings (prices, grants, airdrops, pausing) through `exec`, which
/// refuses their withdraw functions: the HYPE goes through the split or not at all. The owner should be a multisig.
contract ElyfishRevenue is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice how one source's HYPE is divided: parts, not percentages (50 : 20 : 30, or 1 : 0 : 2)
    struct Split {
        uint16 platform;
        uint16 community;
        uint16 buyback;
    }

    /// @notice a paid contract this one owns: how to pull its HYPE (`pull(address to)`) and which split it uses
    struct Source {
        bytes4 pull;
        uint8 split;
        bool listed;
    }

    /// @notice the most paid contracts one revenue contract takes
    uint256 public constant MAX_SOURCES = 16;
    /// @notice the most splits
    uint256 public constant MAX_SPLITS = 8;
    /// @notice HYPE from anyone else (a gift, a stray transfer) uses split 0
    uint8 public constant DEFAULT_SPLIT = 0;
    /// @notice where a token that can't burn itself is sent instead
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address payable public platform;
    address payable public community;
    /// @notice HYPE booked for each, not paid out yet
    uint256 public platformOwed;
    uint256 public communityOwed;
    uint256 public buybackPending;
    /// @notice all HYPE ever booked to the buyback, spent on it and token burned (for the page that shows it)
    uint256 public buybackSpent;
    uint256 public burned;

    Split[] internal _splits;
    address[] internal _sources;
    mapping(address target => Source) public sources;

    /// @notice the buyback: the router, the token, its pool, which way a buy goes, whether the token burns itself
    ILaunchRouter public router;
    address public token;
    PoolKey internal _poolKey;
    bool public zeroForOne;
    bool public burnByCall;
    /// @notice the most HYPE one buyback spends (keeps each buy small against the pool's depth)
    uint256 public maxBuyback;
    mapping(address => bool) public keepers;

    bool private _swapping;

    event SplitSet(uint8 indexed id, uint16 platform, uint16 community, uint16 buyback);
    event SourceSet(address indexed target, bytes4 pull, uint8 split, bool listed);
    event WalletsSet(address platform, address community);
    event BuybackSet(address router, address token, bool zeroForOne, bool burnByCall, uint256 maxBuyback);
    event KeeperSet(address indexed keeper, bool on);
    event Received(address indexed from, uint8 indexed split, uint256 amount, uint256 toPlatform, uint256 toCommunity, uint256 toBuyback);
    event Swept(address indexed source, uint256 amount);
    event Released(address indexed to, uint256 amount);
    event BoughtBack(uint256 hypeIn, uint256 tokensOut);
    event Burned(uint256 amount, bool byCall);
    event Executed(address indexed target, bytes4 selector);

    error ZeroAddress();
    error BadSplit();
    error TooMany();
    error NotListed(address target);
    error Refused(bytes4 selector);
    error CallFailed(bytes reason);
    error NotKeeper(address who);
    error NoBuyback();
    error TooMuch(uint256 amountIn, uint256 limit);
    error NoMinimum();

    /// @param owner_ who sets everything (a multisig on mainnet)
    /// @param platform_ the platform wallet
    /// @param community_ the community wallet
    constructor(address owner_, address payable platform_, address payable community_) Ownable(owner_) {
        _setWallets(platform_, community_);
        _splits.push(Split(50, 20, 30)); // 0: sales — VIP, pet eggs, NFT skins
        _splits.push(Split(1, 0, 2)); // 1: trading post fees — 1 % platform, 2 % buyback of the 3 %
        emit SplitSet(0, 50, 20, 30);
        emit SplitSet(1, 1, 0, 2);
    }

    // ── money in ────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice HYPE arriving is split at once by who sent it (a listed source's split, anyone else's split 0); the
    /// router's change during a buyback goes back to the buyback
    receive() external payable {
        if (_swapping) {
            buybackPending += msg.value;
            return;
        }
        Source memory s = sources[msg.sender];
        _book(msg.sender, s.listed ? s.split : DEFAULT_SPLIT, msg.value);
    }

    /// @notice pull every listed source's HYPE in (anyone; a source with nothing, or that fails, is skipped)
    function sweep() external nonReentrant returns (uint256 total) {
        for (uint256 i = 0; i < _sources.length; i++) {
            total += _pull(_sources[i]);
        }
    }

    /// @notice pull one source's HYPE in (anyone)
    function sweepOne(address target) external nonReentrant returns (uint256) {
        if (!sources[target].listed) revert NotListed(target);
        return _pull(target);
    }

    /// @notice pay the platform and community wallets what is booked for them (anyone; a wallet that refuses keeps its
    /// balance here for next time)
    function release() external nonReentrant {
        uint256 p = platformOwed;
        if (p > 0) {
            platformOwed = 0;
            if (!_trySend(platform, p)) platformOwed = p;
            else emit Released(platform, p);
        }
        uint256 c = communityOwed;
        if (c > 0) {
            communityOwed = 0;
            if (!_trySend(community, c)) communityOwed = c;
            else emit Released(community, c);
        }
    }

    // ── buyback and burn ────────────────────────────────────────────────────────────────────────────────────────

    /// @notice buy the token with `amountIn` of the buyback's HYPE (at most maxBuyback) and burn what comes back
    /// @param minOut the least token the buy may give (from an off-chain quote with slippage; never zero)
    function buyback(uint256 amountIn, uint256 minOut, uint256 deadline) external nonReentrant returns (uint256 out) {
        if (msg.sender != owner() && !keepers[msg.sender]) revert NotKeeper(msg.sender);
        if (address(router) == address(0)) revert NoBuyback();
        if (minOut == 0) revert NoMinimum();
        if (amountIn == 0 || amountIn > buybackPending) revert TooMuch(amountIn, buybackPending);
        if (amountIn > maxBuyback) revert TooMuch(amountIn, maxBuyback);
        buybackPending -= amountIn;
        buybackSpent += amountIn;
        uint256 before = IERC20(token).balanceOf(address(this));
        _swapping = true;
        router.swapExactIn{value: amountIn}(
            ILaunchRouter.ExactIn({
                key: _poolKey,
                zeroForOne: zeroForOne,
                // (amountIn ≤ maxBuyback ≤ uint128 max, minOut checked to fit)
                // forge-lint: disable-next-line(unsafe-typecast)
                amountIn: uint128(amountIn),
                minAmountOut: _u128(minOut),
                recipient: address(this),
                deadline: deadline
            })
        );
        _swapping = false;
        // what actually arrived, not what the router says
        out = IERC20(token).balanceOf(address(this)) - before;
        if (out < minOut) revert TooMuch(minOut, out);
        emit BoughtBack(amountIn, out);
        _burn(out);
    }

    /// @notice burn any of the token this contract holds (a stray transfer, or a burn that failed before)
    function burnHeld() external nonReentrant {
        if (token == address(0)) revert NoBuyback();
        uint256 held = IERC20(token).balanceOf(address(this));
        if (held > 0) _burn(held);
    }

    // ── running the paid contracts ──────────────────────────────────────────────────────────────────────────────

    /// @notice call a paid contract's own owner function (price, grant, airdrop, pause, ...). Its pull function and
    /// handing the contract away to anyone but the owner's chosen new home go through their own doors
    function exec(address target, bytes calldata data) external onlyOwner nonReentrant returns (bytes memory ret) {
        if (data.length < 4) revert Refused(bytes4(0));
        bytes4 sel = bytes4(data[:4]);
        if (sources[target].listed && sel == sources[target].pull) revert Refused(sel);
        if (_isWithdraw(sel)) revert Refused(sel);
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) revert CallFailed(ret);
        emit Executed(target, sel);
    }

    /// @notice accept the ownership a paid contract offered this one (Ownable2Step's second step)
    function acceptOwnershipOf(address target) external onlyOwner {
        Ownable2Step(target).acceptOwnership();
    }

    /// @notice hand a paid contract to a new owner (a new revenue contract, a migration). Its HYPE is pulled through
    /// the split first.
    function handOver(address target, address newOwner) external onlyOwner nonReentrant {
        if (newOwner == address(0)) revert ZeroAddress();
        if (sources[target].listed) _pull(target);
        Ownable2Step(target).transferOwnership(newOwner);
    }

    // ── settings ────────────────────────────────────────────────────────────────────────────────────────────────

    function setWallets(address payable platform_, address payable community_) external onlyOwner {
        _setWallets(platform_, community_);
    }

    /// @notice change a split, or add one (id = the next number); at least one part
    function setSplit(uint8 id, uint16 platform_, uint16 community_, uint16 buyback_) external onlyOwner {
        if (uint256(platform_) + community_ + buyback_ == 0) revert BadSplit();
        Split memory s = Split(platform_, community_, buyback_);
        if (id < _splits.length) _splits[id] = s;
        else if (id == _splits.length && id < MAX_SPLITS) _splits.push(s);
        else revert BadSplit();
        emit SplitSet(id, platform_, community_, buyback_);
    }

    /// @notice list a paid contract (or change / delist it): how to pull its HYPE and which split it uses
    function setSource(address target, bytes4 pull, uint8 split, bool listed) external onlyOwner {
        if (target == address(0) || target == address(this)) revert ZeroAddress();
        if (split >= _splits.length || (listed && pull == bytes4(0))) revert BadSplit();
        if (listed && !sources[target].listed) {
            if (_sources.length >= MAX_SOURCES) revert TooMany();
            _sources.push(target);
        } else if (!listed && sources[target].listed) {
            for (uint256 i = 0; i < _sources.length; i++) {
                if (_sources[i] == target) {
                    _sources[i] = _sources[_sources.length - 1];
                    _sources.pop();
                    break;
                }
            }
        }
        sources[target] = Source(pull, split, listed);
        emit SourceSet(target, pull, split, listed);
    }

    /// @notice where the buyback buys: Montra's LaunchRouter, the game token, its pool key, the direction of a buy
    /// (true when HYPE is currency0, which it always is: the zero address sorts first), whether the token has burn()
    function setBuyback(address router_, address token_, PoolKey calldata key, bool zeroForOne_, bool burnByCall_, uint256 maxBuyback_) external onlyOwner {
        if (router_ == address(0) || token_ == address(0)) revert ZeroAddress();
        if (maxBuyback_ == 0 || maxBuyback_ > type(uint128).max) revert TooMuch(maxBuyback_, type(uint128).max);
        // the pool must be HYPE against this token
        address input = zeroForOne_ ? key.currency0 : key.currency1;
        address output = zeroForOne_ ? key.currency1 : key.currency0;
        if (input != address(0) || output != token_) revert BadSplit();
        router = ILaunchRouter(router_);
        token = token_;
        _poolKey = key;
        zeroForOne = zeroForOne_;
        burnByCall = burnByCall_;
        maxBuyback = maxBuyback_;
        emit BuybackSet(router_, token_, zeroForOne_, burnByCall_, maxBuyback_);
    }

    function setKeeper(address keeper, bool on) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        keepers[keeper] = on;
        emit KeeperSet(keeper, on);
    }

    // ── reading ─────────────────────────────────────────────────────────────────────────────────────────────────

    function split(uint8 id) external view returns (Split memory) {
        return _splits[id];
    }

    function splitCount() external view returns (uint256) {
        return _splits.length;
    }

    function sourceList() external view returns (address[] memory) {
        return _sources;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice HYPE here that is booked (platform + community + buyback): always the whole balance
    function booked() public view returns (uint256) {
        return platformOwed + communityOwed + buybackPending;
    }

    // ── inside ──────────────────────────────────────────────────────────────────────────────────────────────────

    function _pull(address target) private returns (uint256 got) {
        uint256 before = address(this).balance;
        (bool ok,) = target.call(abi.encodeWithSelector(sources[target].pull, payable(address(this))));
        if (!ok) return 0;
        got = address(this).balance - before;
        if (got > 0) emit Swept(target, got);
    }

    /// divide `amount` by split `id`: community and buyback by their parts (rounded down), the platform the rest
    function _book(address from, uint8 id, uint256 amount) private {
        if (amount == 0) return;
        Split memory s = _splits[id];
        uint256 parts = uint256(s.platform) + s.community + s.buyback;
        uint256 toCommunity = (amount * s.community) / parts;
        uint256 toBuyback = (amount * s.buyback) / parts;
        uint256 toPlatform = amount - toCommunity - toBuyback;
        platformOwed += toPlatform;
        communityOwed += toCommunity;
        buybackPending += toBuyback;
        emit Received(from, id, amount, toPlatform, toCommunity, toBuyback);
    }

    function _burn(uint256 amount) private {
        if (burnByCall) {
            try IBurnable(token).burn(amount) {
                burned += amount;
                emit Burned(amount, true);
                return;
            } catch {}
        }
        IERC20(token).safeTransfer(DEAD, amount);
        burned += amount;
        emit Burned(amount, false);
    }

    /// what exec never calls: the paid contracts' withdraw functions (the HYPE goes through the split), and giving a
    /// contract away (that is handOver, which pulls its HYPE through the split first)
    function _isWithdraw(bytes4 sel) private pure returns (bool) {
        return sel == bytes4(keccak256("withdraw(address)")) || sel == bytes4(keccak256("withdrawFees(address)"))
            || sel == bytes4(keccak256("transferOwnership(address)")) || sel == bytes4(keccak256("renounceOwnership()"));
    }

    function _setWallets(address payable platform_, address payable community_) private {
        if (platform_ == address(0) || community_ == address(0)) revert ZeroAddress();
        platform = platform_;
        community = community_;
        emit WalletsSet(platform_, community_);
    }

    function _trySend(address payable to, uint256 amount) private returns (bool ok) {
        (ok,) = to.call{value: amount}("");
    }

    function _u128(uint256 v) private pure returns (uint128) {
        if (v > type(uint128).max) revert TooMuch(v, type(uint128).max);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(v);
    }
}
