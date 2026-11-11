// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ElyfishVip} from "../src/ElyfishVip.sol";
import {MockPriceFeed} from "../src/testnet/MockPriceFeed.sol";

/// a feed that answers whatever the test sets: bad rounds, old prices, odd decimals
contract RawFeed {
    uint8 public decimals;
    uint80 public round = 1;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
    }

    function set(uint80 r, int256 a, uint256 u, uint80 air) external {
        (round, answer, updatedAt, answeredInRound) = (r, a, u, air);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, updatedAt, updatedAt, answeredInRound);
    }
}

/// a wallet that refuses HYPE (to see refunds and withdrawals fail cleanly)
contract NoReceive {
    function buy(ElyfishVip vip, uint256 periods) external payable {
        vip.buy{value: msg.value}(periods);
    }
}

/// a wallet that tries to buy again while its refund arrives
contract Reenter {
    ElyfishVip internal vip;

    constructor(ElyfishVip v) {
        vip = v;
    }

    function go(uint256 periods) external payable {
        vip.buy{value: msg.value}(periods);
    }

    receive() external payable {
        vip.buy{value: msg.value}(1);
    }
}

abstract contract VipBase is Test {
    ElyfishVip internal vip;
    MockPriceFeed internal feed;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    uint256 internal constant PRICE = 12e8; // $12 per 30 days
    uint256 internal constant T0 = 1_800_000_000;

    function setUp() public virtual {
        vm.warp(T0);
        feed = new MockPriceFeed(owner, 8, 25e8, "HYPE / USD");
        vip = new ElyfishVip(owner, address(feed), 1 hours, PRICE);
        vm.deal(alice, 1_000_000 ether);
        vm.deal(bob, 1_000_000 ether);
    }

    /// $12 × periods at the feed's rate, worked out here independently (rounded up)
    function expected(uint256 periods) internal view returns (uint256) {
        (, int256 a,,,) = feed.latestRoundData();
        uint256 num = vip.usdPrice() * periods * 10 ** feed.decimals() * 1e18;
        uint256 den = uint256(a) * 1e8;
        return (num + den - 1) / den;
    }

    // ── a 4-wallet Merkle tree, built the way OpenZeppelin's StandardMerkleTree does (double-hashed leaves, sorted pairs)
    function leaf(address w) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(w))));
    }

    function pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// root of [alice, bob, carol, dave] and the proof for wallet i
    function tree(uint256 i) internal view returns (bytes32 root, bytes32[] memory proof) {
        bytes32[4] memory l = [leaf(alice), leaf(bob), leaf(carol), leaf(dave)];
        bytes32 left = pair(l[0], l[1]);
        bytes32 right = pair(l[2], l[3]);
        root = pair(left, right);
        proof = new bytes32[](2);
        proof[0] = l[i ^ 1];
        proof[1] = i < 2 ? right : left;
    }
}

contract ElyfishVipTest is VipBase {
    // ── set up ──────────────────────────────────────────────────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(vip.owner(), owner);
        assertEq(address(vip.priceFeed()), address(feed));
        assertEq(vip.maxStaleness(), 1 hours);
        assertEq(vip.usdPrice(), PRICE);
        assertEq(vip.airdropRound(), 0);
        assertEq(vip.airdropRoot(), bytes32(0));
    }

    function test_constructor_rejects_bad_input() public {
        vm.expectRevert(ElyfishVip.BadFeed.selector);
        new ElyfishVip(owner, address(0), 1 hours, PRICE);
        vm.expectRevert(ElyfishVip.BadFeed.selector);
        new ElyfishVip(owner, address(feed), 0, PRICE);
        vm.expectRevert(ElyfishVip.BadFeed.selector);
        new ElyfishVip(owner, address(feed), 7 days + 1, PRICE);
        RawFeed odd = new RawFeed(19, 1);
        vm.expectRevert(ElyfishVip.BadFeed.selector);
        new ElyfishVip(owner, address(odd), 1 hours, PRICE);
        vm.expectRevert(ElyfishVip.BadPrice.selector);
        new ElyfishVip(owner, address(feed), 1 hours, 0);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.PriceTooHigh.selector, 1_000e8 + 1));
        new ElyfishVip(owner, address(feed), 1 hours, 1_000e8 + 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ElyfishVip(address(0), address(feed), 1 hours, PRICE);
    }

    // ── price ───────────────────────────────────────────────────────────────────────────────────────────────────

    function test_quote_is_12_dollars_in_hype() public view {
        // $12 at $25 a HYPE = 0.48 HYPE
        assertEq(vip.quote(1), 0.48 ether);
        assertEq(vip.quote(12), 5.76 ether);
    }

    function test_quote_rejects_bad_periods() public {
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.BadPeriods.selector, 0));
        vip.quote(0);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.BadPeriods.selector, 13));
        vip.quote(13);
    }

    function test_quote_follows_the_feed() public {
        vm.prank(owner);
        feed.setAnswer(74.21e8);
        assertEq(vip.quote(1), expected(1));
        assertApproxEqAbs(vip.quote(1), 0.161703 ether, 0.000001 ether);
    }

    function test_hypeUsd_rejects_bad_answers() public {
        RawFeed raw = new RawFeed(8, 25e8);
        vm.prank(owner);
        vip.setPriceFeed(address(raw), 1 hours);
        (uint256 rate, uint8 dec) = vip.hypeUsd();
        assertEq(rate, 25e8);
        assertEq(dec, 8);

        raw.set(1, 0, block.timestamp, 1);
        vm.expectRevert(ElyfishVip.BadPrice.selector);
        vip.quote(1);
        raw.set(1, -5, block.timestamp, 1);
        vm.expectRevert(ElyfishVip.BadPrice.selector);
        vip.quote(1);
        raw.set(2, 25e8, block.timestamp, 1); // answered in an older round
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.StalePrice.selector, block.timestamp));
        vip.quote(1);
        raw.set(1, 25e8, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.StalePrice.selector, 0));
        vip.quote(1);
        raw.set(1, 25e8, block.timestamp + 1, 1); // from the future
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.StalePrice.selector, block.timestamp + 1));
        vip.quote(1);
        raw.set(1, 25e8, block.timestamp - 1 hours - 1, 1); // too old
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.StalePrice.selector, block.timestamp - 1 hours - 1));
        vip.quote(1);
        raw.set(1, 25e8, block.timestamp - 1 hours, 1); // just in time
        assertEq(vip.quote(1), 0.48 ether);
    }

    function test_stale_feed_blocks_buying() public {
        vm.warp(T0 + 1 hours + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.StalePrice.selector, T0));
        vip.buy{value: 1 ether}(1);
    }

    // ── buying ──────────────────────────────────────────────────────────────────────────────────────────────────

    function test_buy_gives_30_days() public {
        vm.expectEmit(address(vip));
        emit ElyfishVip.VipBought(alice, alice, 1, 0.48 ether, uint64(T0 + 30 days));
        vm.prank(alice);
        vip.buy{value: 0.48 ether}(1);
        assertEq(vip.vipUntil(alice), T0 + 30 days);
        assertTrue(vip.isVip(alice));
        assertEq(vip.timeLeft(alice), 30 days);
        assertEq(address(vip).balance, 0.48 ether);
        assertFalse(vip.isVip(bob));
        assertEq(vip.timeLeft(bob), 0);
    }

    function test_buy_refunds_extra() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        vip.buy{value: 3 ether}(2);
        assertEq(alice.balance, before - 0.96 ether);
        assertEq(address(vip).balance, 0.96 ether);
        assertEq(vip.vipUntil(alice), T0 + 60 days);
    }

    function test_buy_rejects_underpaying() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.Underpaid.selector, 0.48 ether, 0.48 ether - 1));
        vip.buy{value: 0.48 ether - 1}(1);
    }

    function test_buy_adds_on_to_time_left() public {
        vm.startPrank(alice);
        vip.buy{value: 1 ether}(1);
        vm.warp(T0 + 10 days);
        feed; // (the feed stays fresh only for an hour: move it)
        vm.stopPrank();
        vm.prank(owner);
        feed.setAnswer(25e8);
        vm.prank(alice);
        vip.buy{value: 1 ether}(1);
        assertEq(vip.vipUntil(alice), T0 + 60 days);
    }

    function test_buy_after_it_ran_out_starts_from_now() public {
        vm.prank(alice);
        vip.buy{value: 1 ether}(1);
        vm.warp(T0 + 40 days);
        vm.prank(owner);
        feed.setAnswer(25e8);
        assertFalse(vip.isVip(alice));
        vm.prank(alice);
        vip.buy{value: 1 ether}(1);
        assertEq(vip.vipUntil(alice), T0 + 70 days);
    }

    function test_buy_up_to_a_year_ahead_only() public {
        vm.prank(alice);
        vip.buy{value: 10 ether}(12); // 360 days
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.TooFarAhead.selector, uint64(T0 + 390 days)));
        vip.buy{value: 1 ether}(1);
        vm.warp(T0 + 25 days);
        vm.prank(owner);
        feed.setAnswer(25e8);
        vm.prank(alice);
        vip.buy{value: 1 ether}(1); // 390 days from T0 = 365 days from now
        assertEq(vip.vipUntil(alice), T0 + 390 days);
    }

    function test_buyFor_is_a_gift() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        vip.buyFor{value: 1 ether}(bob, 1);
        assertEq(vip.vipUntil(bob), T0 + 30 days);
        assertEq(vip.vipUntil(alice), 0);
        assertEq(alice.balance, before - 0.48 ether);
        vm.prank(alice);
        vm.expectRevert(ElyfishVip.ZeroAddress.selector);
        vip.buyFor{value: 1 ether}(address(0), 1);
    }

    function test_refund_to_a_wallet_that_refuses_fails() public {
        NoReceive nr = new NoReceive();
        vm.deal(address(this), 10 ether);
        vm.expectRevert(ElyfishVip.TransferFailed.selector);
        nr.buy{value: 1 ether}(vip, 1);
        // the exact price needs no refund
        nr.buy{value: 0.48 ether}(vip, 1);
        assertEq(vip.vipUntil(address(nr)), T0 + 30 days);
    }

    function test_no_reentry_during_refund() public {
        Reenter r = new Reenter(vip);
        vm.deal(address(this), 10 ether);
        // the inner buy is blocked by the guard, so the refund fails and nothing is bought
        vm.expectRevert(ElyfishVip.TransferFailed.selector);
        r.go{value: 2 ether}(1);
        assertEq(vip.vipUntil(address(r)), 0);
    }

    // ── pause ───────────────────────────────────────────────────────────────────────────────────────────────────

    function test_pause_stops_buying_and_claiming() public {
        (bytes32 root, bytes32[] memory proof) = tree(0);
        vm.startPrank(owner);
        vip.setAirdrop(root, 30);
        vip.pause();
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vip.buy{value: 1 ether}(1);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vip.claimAirdrop(proof);
        // the owner can still grant while paused
        address[] memory w = new address[](1);
        w[0] = alice;
        vm.prank(owner);
        vip.grant(w, 30);
        assertEq(vip.vipUntil(alice), T0 + 30 days);
        vm.prank(owner);
        vip.unpause();
        vm.prank(alice);
        vip.claimAirdrop(proof);
        assertEq(vip.vipUntil(alice), T0 + 60 days);
    }

    // ── grant ───────────────────────────────────────────────────────────────────────────────────────────────────

    function test_grant_gives_days_to_each() public {
        address[] memory w = new address[](3);
        (w[0], w[1], w[2]) = (alice, bob, carol);
        vm.prank(alice);
        vip.buy{value: 1 ether}(1);
        vm.expectEmit(address(vip));
        emit ElyfishVip.VipGranted(alice, 30, uint64(T0 + 60 days));
        vm.prank(owner);
        vip.grant(w, 30);
        assertEq(vip.vipUntil(alice), T0 + 60 days);
        assertEq(vip.vipUntil(bob), T0 + 30 days);
        assertEq(vip.vipUntil(carol), T0 + 30 days);
    }

    function test_grant_is_cut_at_a_year() public {
        address[] memory w = new address[](1);
        w[0] = alice;
        vm.startPrank(owner);
        vip.grant(w, 365);
        assertEq(vip.vipUntil(alice), T0 + 365 days);
        vip.grant(w, 30); // already a year ahead: stays
        assertEq(vip.vipUntil(alice), T0 + 365 days);
        vm.warp(T0 + 10 days);
        vip.grant(w, 30); // 10 days more fit
        assertEq(vip.vipUntil(alice), T0 + 375 days);
        vm.stopPrank();
    }

    function test_grant_rejects_bad_input() public {
        address[] memory none = new address[](0);
        address[] memory big = new address[](501);
        address[] memory zero = new address[](1);
        address[] memory w = new address[](1);
        w[0] = alice;
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.BadBatch.selector, 0));
        vip.grant(none, 30);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.BadBatch.selector, 501));
        vip.grant(big, 30);
        vm.expectRevert(ElyfishVip.ZeroAddress.selector);
        vip.grant(zero, 30);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.BadDays.selector, 0));
        vip.grant(w, 0);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.BadDays.selector, 366));
        vip.grant(w, 366);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vip.grant(w, 30);
    }

    // ── airdrop ─────────────────────────────────────────────────────────────────────────────────────────────────

    function test_airdrop_claim_once_per_round() public {
        (bytes32 root, bytes32[] memory proof) = tree(1);
        vm.expectEmit(address(vip));
        emit ElyfishVip.AirdropOpened(1, root, 30);
        vm.prank(owner);
        vip.setAirdrop(root, 30);
        assertTrue(vip.isEligible(bob, proof));
        vm.expectEmit(address(vip));
        emit ElyfishVip.AirdropClaimed(1, bob, uint64(T0 + 30 days));
        vm.prank(bob);
        vip.claimAirdrop(proof);
        assertEq(vip.vipUntil(bob), T0 + 30 days);
        assertTrue(vip.claimed(1, bob));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.AlreadyClaimed.selector, 1, bob));
        vip.claimAirdrop(proof);
        // a new round (same list) can be claimed again
        vm.prank(owner);
        vip.setAirdrop(root, 15);
        vm.prank(bob);
        vip.claimAirdrop(proof);
        assertEq(vip.vipUntil(bob), T0 + 45 days);
    }

    function test_airdrop_every_listed_wallet_can_claim() public {
        (bytes32 root,) = tree(0);
        vm.prank(owner);
        vip.setAirdrop(root, 30);
        address[4] memory w = [alice, bob, carol, dave];
        for (uint256 i = 0; i < 4; i++) {
            (, bytes32[] memory proof) = tree(i);
            vm.prank(w[i]);
            vip.claimAirdrop(proof);
            assertEq(vip.vipUntil(w[i]), T0 + 30 days);
        }
    }

    function test_airdrop_rejects_wallets_not_on_the_list() public {
        (bytes32 root, bytes32[] memory proof) = tree(0);
        vm.prank(owner);
        vip.setAirdrop(root, 30);
        address eve = makeAddr("eve");
        assertFalse(vip.isEligible(eve, proof));
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.NotEligible.selector, eve));
        vip.claimAirdrop(proof);
        // alice's proof does not work for bob
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.NotEligible.selector, bob));
        vip.claimAirdrop(proof);
    }

    function test_airdrop_closed() public {
        (bytes32 root, bytes32[] memory proof) = tree(0);
        vm.prank(alice);
        vm.expectRevert(ElyfishVip.NoAirdrop.selector);
        vip.claimAirdrop(proof);
        vm.startPrank(owner);
        vip.setAirdrop(root, 30);
        vip.setAirdrop(bytes32(0), 0); // closes it (days ignored)
        vm.stopPrank();
        assertEq(vip.airdropDays(), 0);
        assertFalse(vip.isEligible(alice, proof));
        vm.prank(alice);
        vm.expectRevert(ElyfishVip.NoAirdrop.selector);
        vip.claimAirdrop(proof);
    }

    function test_setAirdrop_rejects_bad_days_and_strangers() public {
        (bytes32 root,) = tree(0);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.BadDays.selector, 0));
        vip.setAirdrop(root, 0);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.BadDays.selector, 366));
        vip.setAirdrop(root, 366);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vip.setAirdrop(root, 30);
    }

    // ── owner ───────────────────────────────────────────────────────────────────────────────────────────────────

    function test_setPrice() public {
        vm.expectEmit(address(vip));
        emit ElyfishVip.PriceSet(15e8);
        vm.prank(owner);
        vip.setPrice(15e8);
        assertEq(vip.quote(1), 0.6 ether);
        vm.startPrank(owner);
        vm.expectRevert(ElyfishVip.BadPrice.selector);
        vip.setPrice(0);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.PriceTooHigh.selector, 1_000e8 + 1));
        vip.setPrice(1_000e8 + 1);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vip.setPrice(1e8);
    }

    function test_setPriceFeed() public {
        MockPriceFeed f2 = new MockPriceFeed(owner, 18, 50e18, "HYPE / USD");
        vm.expectEmit(address(vip));
        emit ElyfishVip.PriceFeedSet(address(f2), 1 days);
        vm.prank(owner);
        vip.setPriceFeed(address(f2), 1 days);
        assertEq(vip.quote(1), 0.24 ether); // $12 at $50
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vip.setPriceFeed(address(feed), 1 hours);
    }

    function test_owner_only_pause_and_withdraw() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vip.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vip.unpause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vip.withdraw(payable(alice));
        vm.stopPrank();
    }

    function test_withdraw_sends_everything() public {
        vm.prank(alice);
        vip.buy{value: 1 ether}(2);
        address payable to = payable(makeAddr("treasury"));
        vm.expectEmit(address(vip));
        emit ElyfishVip.Withdrawn(to, 0.96 ether);
        vm.prank(owner);
        vip.withdraw(to);
        assertEq(to.balance, 0.96 ether);
        assertEq(address(vip).balance, 0);
        address payable refuses = payable(address(new NoReceive()));
        vm.startPrank(owner);
        vm.expectRevert(ElyfishVip.ZeroAddress.selector);
        vip.withdraw(payable(address(0)));
        vm.expectRevert(ElyfishVip.TransferFailed.selector);
        vip.withdraw(refuses);
        vm.stopPrank();
    }

    function test_ownership_moves_in_two_steps() public {
        vm.prank(owner);
        vip.transferOwnership(alice);
        assertEq(vip.owner(), owner);
        assertEq(vip.pendingOwner(), alice);
        vm.prank(alice);
        vip.acceptOwnership();
        assertEq(vip.owner(), alice);
    }

    // the testnet feed itself: only its owner moves it, only the latest round can be read
    function test_mock_feed() public {
        assertEq(feed.version(), 1);
        assertEq(feed.description(), "HYPE / USD");
        (uint80 r, int256 a,, uint256 u, uint80 air) = feed.getRoundData(1);
        assertEq(r, 1);
        assertEq(a, 25e8);
        assertEq(u, T0);
        assertEq(air, 1);
        vm.expectRevert(bytes("only the latest round"));
        feed.getRoundData(2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        feed.setAnswer(1);
    }

    // ── fuzz ────────────────────────────────────────────────────────────────────────────────────────────────────

    /// any price, rate, decimals and number of periods: the cost is $price × periods at the rate (rounded up), the
    /// extra comes back, and the time added is exactly periods × 30 days
    function testFuzz_buy(uint256 usd, uint256 rate, uint8 dec, uint256 periods, uint256 extra) public {
        usd = bound(usd, 1, 1_000e8);
        dec = uint8(bound(dec, 0, 18));
        rate = bound(rate, 1, 1e12 * 10 ** dec);
        periods = bound(periods, 1, 12);
        MockPriceFeed f = new MockPriceFeed(owner, dec, int256(rate), "HYPE / USD");
        vm.startPrank(owner);
        vip.setPriceFeed(address(f), 1 hours);
        vip.setPrice(usd);
        vm.stopPrank();
        uint256 want = _ceil(usd * periods * 10 ** dec * 1e18, rate * 1e8);
        uint256 cost = vip.quote(periods);
        assertEq(cost, want);
        extra = bound(extra, 0, 1_000 ether);
        vm.assume(cost <= 100_000_000 ether);
        vm.deal(alice, cost + extra);
        vm.prank(alice);
        vip.buy{value: cost + extra}(periods);
        assertEq(alice.balance, extra);
        assertEq(address(vip).balance, cost);
        assertEq(vip.vipUntil(alice), T0 + periods * 30 days);
    }

    /// paying a wei less than the price never buys anything
    function testFuzz_underpaying_never_buys(uint256 periods, uint256 short) public {
        periods = bound(periods, 1, 12);
        uint256 cost = vip.quote(periods);
        short = bound(short, 1, cost);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.Underpaid.selector, cost, cost - short));
        vip.buy{value: cost - short}(periods);
        assertEq(vip.vipUntil(alice), 0);
    }

    /// buying at any moment: never past a year ahead, never shorter than before, adds exactly what was bought
    function testFuzz_extend(uint256 first, uint256 later, uint256 wait) public {
        first = bound(first, 1, 12);
        later = bound(later, 1, 12);
        wait = bound(wait, 0, 400 days);
        vm.prank(alice);
        vip.buy{value: 10 ether}(first);
        uint256 u1 = vip.vipUntil(alice);
        vm.warp(T0 + wait);
        vm.prank(owner);
        feed.setAnswer(25e8);
        uint256 want = (u1 > block.timestamp ? u1 : block.timestamp) + later * 30 days;
        vm.prank(alice);
        if (want > block.timestamp + 365 days) {
            vm.expectRevert(abi.encodeWithSelector(ElyfishVip.TooFarAhead.selector, uint64(want)));
            vip.buy{value: 10 ether}(later);
            assertEq(vip.vipUntil(alice), u1);
        } else {
            vip.buy{value: 10 ether}(later);
            assertEq(vip.vipUntil(alice), want);
        }
    }

    /// a grant of any days at any moment: never past a year ahead, never shorter than before
    function testFuzz_grant(uint32 d1, uint32 d2, uint256 wait) public {
        d1 = uint32(bound(d1, 1, 365));
        d2 = uint32(bound(d2, 1, 365));
        wait = bound(wait, 0, 800 days);
        address[] memory w = new address[](1);
        w[0] = alice;
        vm.prank(owner);
        vip.grant(w, d1);
        uint256 u1 = vip.vipUntil(alice);
        assertEq(u1, T0 + uint256(d1) * 1 days);
        vm.warp(T0 + wait);
        vm.prank(owner);
        vip.grant(w, d2);
        uint256 u2 = vip.vipUntil(alice);
        uint256 from = u1 > block.timestamp ? u1 : block.timestamp;
        uint256 want = from + uint256(d2) * 1 days;
        if (want > block.timestamp + 365 days) want = block.timestamp + 365 days;
        if (want < u1) want = u1;
        assertEq(u2, want);
        assertLe(u2, block.timestamp + 365 days);
        assertGe(u2, u1);
    }

    /// any wallet not on the list, any proof: never eligible
    function testFuzz_stranger_never_claims(address who, bytes32 p0, bytes32 p1) public {
        vm.assume(who != alice && who != bob && who != carol && who != dave);
        (bytes32 root,) = tree(0);
        vm.prank(owner);
        vip.setAirdrop(root, 30);
        bytes32[] memory proof = new bytes32[](2);
        (proof[0], proof[1]) = (p0, p1);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(ElyfishVip.NotEligible.selector, who));
        vip.claimAirdrop(proof);
    }

    function _ceil(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
