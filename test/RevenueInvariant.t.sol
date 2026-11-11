// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ElyfishRevenue} from "../src/ElyfishRevenue.sol";
import {ElyfishVip} from "../src/ElyfishVip.sol";
import {ElyfishPetEggs} from "../src/ElyfishPetEggs.sol";
import {ElyfishTradingPost} from "../src/ElyfishTradingPost.sol";
import {MockPriceFeed} from "../src/testnet/MockPriceFeed.sol";
import {MockLaunchToken} from "../src/testnet/MockLaunchToken.sol";
import {MockLaunchRouter} from "../src/testnet/MockLaunchRouter.sol";
import {PoolKey} from "../src/interfaces/ILaunchRouter.sol";

struct Parts {
    ElyfishRevenue rev;
    ElyfishVip vip;
    ElyfishPetEggs eggs;
    ElyfishTradingPost tp;
    MockPriceFeed feed;
    MockLaunchToken token;
    MockLaunchRouter router;
    address feedOwner;
    address keeper;
    uint256 signerKey;
}

/// random players buying VIP, pet eggs and trading post items, strangers sending HYPE, and anyone sweeping, releasing
/// and (the keeper) buying back, in any order. It keeps its own books of what each wallet and the buyback should get.
contract RevenueHandler is Test {
    ElyfishRevenue internal rev;
    ElyfishVip internal vip;
    ElyfishPetEggs internal eggs;
    ElyfishTradingPost internal tp;
    MockPriceFeed internal feed;
    MockLaunchToken internal token;
    MockLaunchRouter internal router;
    address internal feedOwner;
    address internal keeper;
    uint256 internal signerKey;
    address internal buyer = address(0xB0B);
    uint256 internal nextId = 1;

    // the books: what the split owes each side in total, worked out here on every arrival
    uint256 public ghostPlatform;
    uint256 public ghostCommunity;
    uint256 public ghostBuyback;
    uint256 public ghostIn;
    uint256 public ghostBurned;
    uint256 public calls;

    constructor(Parts memory p) {
        rev = p.rev;
        vip = p.vip;
        eggs = p.eggs;
        tp = p.tp;
        feed = p.feed;
        token = p.token;
        router = p.router;
        feedOwner = p.feedOwner;
        keeper = p.keeper;
        signerKey = p.signerKey;
        vm.deal(buyer, type(uint128).max);
    }

    function _book(uint256 amount, uint256 p, uint256 c, uint256 b) internal {
        uint256 sum = p + c + b;
        uint256 toC = (amount * c) / sum;
        uint256 toB = (amount * b) / sum;
        ghostCommunity += toC;
        ghostBuyback += toB;
        ghostPlatform += amount - toC - toB;
        ghostIn += amount;
    }

    function buyVip(uint8 periods) external {
        calls++;
        periods = uint8(bound(periods, 1, 3));
        if (vip.vipUntil(buyer) > block.timestamp + 270 days) return;
        uint256 cost = vip.quote(periods);
        vm.prank(buyer);
        vip.buy{value: cost}(periods);
    }

    function buyEggs(uint8 packs) external {
        calls++;
        packs = uint8(bound(packs, 1, 10));
        uint256 cost = eggs.quote(packs);
        vm.prank(buyer);
        eggs.buy{value: cost}(packs);
    }

    function sellOnPost(uint96 price) external {
        calls++;
        uint256 pr = bound(price, 1e12, 1e22);
        ElyfishTradingPost.Listing memory l = ElyfishTradingPost.Listing({id: nextId++, seller: address(0x5e11e7), price: pr, expiry: uint64(block.timestamp + 1 days)});
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, tp.hashListing(l));
        vm.prank(buyer);
        tp.buy{value: pr}(l, abi.encodePacked(r, s, v));
    }

    function gift(uint96 amount) external {
        calls++;
        uint256 a = bound(amount, 0, 100 ether);
        vm.prank(buyer);
        (bool ok,) = address(rev).call{value: a}("");
        require(ok);
        _book(a, 50, 20, 30);
    }

    function sweep() external {
        calls++;
        uint256 v = address(vip).balance;
        uint256 e = address(eggs).balance;
        uint256 f = tp.feesAccrued();
        rev.sweep();
        _book(v, 50, 20, 30);
        _book(e, 50, 20, 30);
        _book(f, 1, 0, 2);
    }

    function release() external {
        calls++;
        rev.release();
    }

    function buyback(uint96 amount) external {
        calls++;
        uint256 pending = rev.buybackPending();
        uint256 cap = rev.maxBuyback();
        uint256 most = pending < cap ? pending : cap;
        if (most == 0) return;
        uint256 a = bound(amount, 1, most);
        uint256 quote = router.quoteExactIn(rev.poolKey(), true, uint128(a));
        if (quote == 0) return;
        vm.prank(keeper);
        uint256 out = rev.buyback(a, quote, block.timestamp + 60);
        ghostBurned += out;
    }

    function wait(uint16 secs) external {
        calls++;
        vm.warp(block.timestamp + bound(secs, 1, 50 minutes));
        vm.prank(feedOwner);
        feed.setAnswer(25e8); // fresh price (staleness 1 hour)
    }
}

contract RevenueInvariantTest is Test {
    ElyfishRevenue internal rev;
    ElyfishVip internal vip;
    ElyfishPetEggs internal eggs;
    ElyfishTradingPost internal tp;
    MockLaunchToken internal token;
    MockLaunchRouter internal router;
    RevenueHandler internal handler;
    address internal owner = makeAddr("owner");
    address payable internal platform = payable(makeAddr("platform"));
    address payable internal community = payable(makeAddr("community"));
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        (address signer, uint256 signerKey) = makeAddrAndKey("game-server");
        MockPriceFeed feed = new MockPriceFeed(owner, 8, 25e8, "HYPE / USD");
        vip = new ElyfishVip(owner, address(feed), 1 hours, 12e8);
        eggs = new ElyfishPetEggs(owner, address(feed), 1 hours, 5e8);
        tp = new ElyfishTradingPost(owner, signer);
        rev = new ElyfishRevenue(owner, platform, community);
        token = new MockLaunchToken("Elyfish", "FISH", SUPPLY, address(this));
        router = new MockLaunchRouter(owner, token, 1_000_000e18, 10_000);
        token.transfer(address(router), SUPPLY);
        address keeper = makeAddr("keeper");

        vm.startPrank(owner);
        vip.transferOwnership(address(rev));
        eggs.transferOwnership(address(rev));
        tp.transferOwnership(address(rev));
        rev.acceptOwnershipOf(address(vip));
        rev.acceptOwnershipOf(address(eggs));
        rev.acceptOwnershipOf(address(tp));
        rev.setSource(address(vip), bytes4(keccak256("withdraw(address)")), 0, true);
        rev.setSource(address(eggs), bytes4(keccak256("withdraw(address)")), 0, true);
        rev.setSource(address(tp), bytes4(keccak256("withdrawFees(address)")), 1, true);
        rev.setBuyback(address(router), address(token), PoolKey(address(0), address(token), 0x800000, 200, address(0)), true, true, 50 ether);
        rev.setKeeper(keeper, true);
        vm.stopPrank();

        handler = new RevenueHandler(Parts(rev, vip, eggs, tp, feed, token, router, owner, keeper, signerKey));
        targetContract(address(handler));
    }

    /// every wei here is booked to someone: the platform, the community or the buyback
    function invariant_balance_is_all_booked() public view {
        assertEq(address(rev).balance, rev.booked());
    }

    /// each side got exactly its parts of everything that came in: paid out plus still booked
    function invariant_each_side_gets_its_parts() public view {
        assertEq(platform.balance + rev.platformOwed(), handler.ghostPlatform());
        assertEq(community.balance + rev.communityOwed(), handler.ghostCommunity());
        assertEq(rev.buybackSpent() + rev.buybackPending(), handler.ghostBuyback());
        assertEq(handler.ghostPlatform() + handler.ghostCommunity() + handler.ghostBuyback(), handler.ghostIn());
    }

    /// everything bought back is burned: none of it waits here, and the supply fell by exactly that
    function invariant_bought_back_is_burned() public view {
        assertEq(token.balanceOf(address(rev)), 0);
        assertEq(rev.burned(), handler.ghostBurned());
        assertEq(token.totalSupply(), SUPPLY - rev.burned());
    }

    /// the buyback's HYPE went to the pool, nowhere else
    function invariant_buyback_hype_reached_the_router() public view {
        assertEq(address(router).balance, rev.buybackSpent());
    }

    /// the paid contracts stay owned by the split, and keep only what was not swept yet
    function invariant_paid_contracts_stay_owned() public view {
        assertEq(vip.owner(), address(rev));
        assertEq(eggs.owner(), address(rev));
        assertEq(tp.owner(), address(rev));
    }
}
