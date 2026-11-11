// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ElyfishPetEggs} from "../src/ElyfishPetEggs.sol";
import {MockPriceFeed} from "../src/testnet/MockPriceFeed.sol";
import {RawFeed} from "./ElyfishVip.t.sol";

/// a wallet that refuses HYPE (to see refunds and withdrawals fail cleanly)
contract EggNoReceive {
    function buy(ElyfishPetEggs eggs, uint256 packs) external payable {
        eggs.buy{value: msg.value}(packs);
    }
}

/// a wallet that tries to buy again while its refund arrives
contract EggReenter {
    ElyfishPetEggs internal eggs;

    constructor(ElyfishPetEggs e) {
        eggs = e;
    }

    function go(uint256 packs) external payable {
        eggs.buy{value: msg.value}(packs);
    }

    receive() external payable {
        eggs.buy{value: msg.value}(1);
    }
}

contract ElyfishPetEggsTest is Test {
    ElyfishPetEggs internal eggs;
    MockPriceFeed internal feed;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal constant PRICE = 5e8; // $5 per pack of 10
    uint256 internal constant T0 = 1_800_000_000;

    function setUp() public {
        vm.warp(T0);
        feed = new MockPriceFeed(owner, 8, 25e8, "HYPE / USD");
        eggs = new ElyfishPetEggs(owner, address(feed), 1 hours, PRICE);
        vm.deal(alice, 1_000_000 ether);
        vm.deal(bob, 1_000_000 ether);
    }

    /// $5 × packs at the feed's rate, worked out here independently (rounded up)
    function expected(uint256 packs) internal view returns (uint256) {
        (, int256 a,,,) = feed.latestRoundData();
        uint256 num = eggs.usdPrice() * packs * 10 ** feed.decimals() * 1e18;
        uint256 den = uint256(a) * 1e8;
        return (num + den - 1) / den;
    }

    // ── set up ──────────────────────────────────────────────────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(eggs.owner(), owner);
        assertEq(address(eggs.priceFeed()), address(feed));
        assertEq(eggs.maxStaleness(), 1 hours);
        assertEq(eggs.usdPrice(), PRICE);
        assertEq(eggs.EGGS_PER_PACK(), 10);
    }

    function test_constructor_rejects_bad_input() public {
        vm.expectRevert(ElyfishPetEggs.BadFeed.selector);
        new ElyfishPetEggs(owner, address(0), 1 hours, PRICE);
        vm.expectRevert(ElyfishPetEggs.BadFeed.selector);
        new ElyfishPetEggs(owner, address(feed), 0, PRICE);
        vm.expectRevert(ElyfishPetEggs.BadFeed.selector);
        new ElyfishPetEggs(owner, address(feed), 7 days + 1, PRICE);
        RawFeed odd = new RawFeed(19, 1);
        vm.expectRevert(ElyfishPetEggs.BadFeed.selector);
        new ElyfishPetEggs(owner, address(odd), 1 hours, PRICE);
        vm.expectRevert(ElyfishPetEggs.BadPrice.selector);
        new ElyfishPetEggs(owner, address(feed), 1 hours, 0);
        vm.expectRevert(abi.encodeWithSelector(ElyfishPetEggs.PriceTooHigh.selector, 1_000e8 + 1));
        new ElyfishPetEggs(owner, address(feed), 1 hours, 1_000e8 + 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ElyfishPetEggs(address(0), address(feed), 1 hours, PRICE);
    }

    // ── price ───────────────────────────────────────────────────────────────────────────────────────────────────

    function test_quote_is_5_dollars_in_hype() public view {
        // $5 at $25 a HYPE = 0.2 HYPE
        assertEq(eggs.quote(1), 0.2 ether);
        assertEq(eggs.quote(10), 2 ether);
    }

    function test_quote_rejects_bad_packs() public {
        vm.expectRevert(abi.encodeWithSelector(ElyfishPetEggs.BadPacks.selector, 0));
        eggs.quote(0);
        vm.expectRevert(abi.encodeWithSelector(ElyfishPetEggs.BadPacks.selector, 11));
        eggs.quote(11);
    }

    function testFuzz_quote_matches_the_rate(uint256 packs, int256 answer, uint8 dec) public {
        packs = bound(packs, 1, 10);
        dec = uint8(bound(dec, 0, 18));
        answer = int256(bound(answer, 1, 1e30));
        RawFeed raw = new RawFeed(dec, answer);
        vm.prank(owner);
        eggs.setPriceFeed(address(raw), 1 hours);
        uint256 num = PRICE * packs * 10 ** dec * 1e18;
        uint256 den = uint256(answer) * 1e8;
        assertEq(eggs.quote(packs), (num + den - 1) / den);
    }

    function test_stale_or_bad_feed_stops_buying() public {
        RawFeed raw = new RawFeed(8, 25e8);
        vm.prank(owner);
        eggs.setPriceFeed(address(raw), 1 hours);
        raw.set(1, 0, block.timestamp, 1);
        vm.expectRevert(ElyfishPetEggs.BadPrice.selector);
        eggs.quote(1);
        raw.set(2, 25e8, block.timestamp, 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishPetEggs.StalePrice.selector, block.timestamp));
        eggs.quote(1);
        raw.set(1, 25e8, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishPetEggs.StalePrice.selector, 0));
        eggs.quote(1);
        raw.set(1, 25e8, block.timestamp + 1, 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishPetEggs.StalePrice.selector, block.timestamp + 1));
        eggs.quote(1);
        uint256 old = block.timestamp - 1 hours - 1;
        raw.set(1, 25e8, old, 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishPetEggs.StalePrice.selector, old));
        eggs.quote(1);
    }

    // ── buying ──────────────────────────────────────────────────────────────────────────────────────────────────

    function test_buy_counts_packs_and_eggs() public {
        vm.expectEmit(address(eggs));
        emit ElyfishPetEggs.PacksBought(alice, alice, 1, 0.2 ether, 1);
        vm.prank(alice);
        eggs.buy{value: 0.2 ether}(1);
        assertEq(eggs.packsOf(alice), 1);
        assertEq(eggs.eggsOf(alice), 10);
        vm.prank(alice);
        eggs.buy{value: 0.6 ether}(3);
        assertEq(eggs.packsOf(alice), 4);
        assertEq(eggs.eggsOf(alice), 40);
        assertEq(address(eggs).balance, 0.8 ether);
    }

    function test_buy_for_a_friend() public {
        vm.expectEmit(address(eggs));
        emit ElyfishPetEggs.PacksBought(alice, bob, 2, 0.4 ether, 2);
        vm.prank(alice);
        eggs.buyFor{value: 0.4 ether}(bob, 2);
        assertEq(eggs.packsOf(bob), 2);
        assertEq(eggs.packsOf(alice), 0);
    }

    function test_buy_refunds_the_extra() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        eggs.buy{value: 1 ether}(1);
        assertEq(alice.balance, before - 0.2 ether);
        assertEq(address(eggs).balance, 0.2 ether);
    }

    function test_buy_rejects_underpaying_bad_packs_zero_wallet() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ElyfishPetEggs.Underpaid.selector, 0.2 ether, 0.2 ether - 1));
        eggs.buy{value: 0.2 ether - 1}(1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishPetEggs.BadPacks.selector, 11));
        eggs.buy{value: 10 ether}(11);
        vm.expectRevert(ElyfishPetEggs.ZeroAddress.selector);
        eggs.buyFor{value: 0.2 ether}(address(0), 1);
        vm.stopPrank();
        assertEq(eggs.packsOf(alice), 0);
    }

    function test_refund_to_a_wallet_that_refuses_fails_whole() public {
        EggNoReceive nr = new EggNoReceive();
        vm.deal(address(nr), 0);
        vm.expectRevert(ElyfishPetEggs.TransferFailed.selector);
        nr.buy{value: 1 ether}(eggs, 1);
        assertEq(eggs.packsOf(address(nr)), 0);
        // the exact price needs no refund: fine
        nr.buy{value: 0.2 ether}(eggs, 1);
        assertEq(eggs.packsOf(address(nr)), 1);
    }

    function test_no_reentry_during_the_refund() public {
        EggReenter r = new EggReenter(eggs);
        vm.expectRevert(ElyfishPetEggs.TransferFailed.selector);
        r.go{value: 1 ether}(1);
        assertEq(eggs.packsOf(address(r)), 0);
    }

    function testFuzz_packs_only_add_up(uint8 a, uint8 b) public {
        uint256 pa = bound(a, 1, 10);
        uint256 pb = bound(b, 1, 10);
        vm.startPrank(alice);
        eggs.buy{value: eggs.quote(pa)}(pa);
        eggs.buy{value: expected(pb)}(pb);
        vm.stopPrank();
        assertEq(eggs.packsOf(alice), pa + pb);
        assertEq(address(eggs).balance, expected(pa) + expected(pb));
    }

    // ── owner ───────────────────────────────────────────────────────────────────────────────────────────────────

    function test_grant_gives_packs() public {
        address[] memory ws = new address[](2);
        ws[0] = alice;
        ws[1] = bob;
        vm.expectEmit(address(eggs));
        emit ElyfishPetEggs.PacksGranted(alice, 3, 3);
        vm.prank(owner);
        eggs.grant(ws, 3);
        assertEq(eggs.packsOf(alice), 3);
        assertEq(eggs.packsOf(bob), 3);
    }

    function test_grant_checks() public {
        address[] memory none = new address[](0);
        address[] memory zero = new address[](1);
        address[] memory ws = new address[](1);
        ws[0] = alice;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        eggs.grant(ws, 1);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ElyfishPetEggs.BadBatch.selector, 0));
        eggs.grant(none, 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishPetEggs.BadBatch.selector, 501));
        eggs.grant(new address[](501), 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishPetEggs.BadPacks.selector, 0));
        eggs.grant(ws, 0);
        vm.expectRevert(abi.encodeWithSelector(ElyfishPetEggs.BadPacks.selector, 11));
        eggs.grant(ws, 11);
        vm.expectRevert(ElyfishPetEggs.ZeroAddress.selector);
        eggs.grant(zero, 1);
        vm.stopPrank();
    }

    function test_price_and_feed_owner_only() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        eggs.setPrice(1e8);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        eggs.setPriceFeed(address(feed), 1 hours);
        vm.stopPrank();
        vm.startPrank(owner);
        vm.expectEmit(address(eggs));
        emit ElyfishPetEggs.PriceSet(10e8);
        eggs.setPrice(10e8);
        assertEq(eggs.quote(1), 0.4 ether);
        vm.expectRevert(ElyfishPetEggs.BadPrice.selector);
        eggs.setPrice(0);
        vm.expectRevert(abi.encodeWithSelector(ElyfishPetEggs.PriceTooHigh.selector, 1_000e8 + 1));
        eggs.setPrice(1_000e8 + 1);
        vm.expectEmit(address(eggs));
        emit ElyfishPetEggs.PriceFeedSet(address(feed), 2 days);
        eggs.setPriceFeed(address(feed), 2 days);
        assertEq(eggs.maxStaleness(), 2 days);
        vm.stopPrank();
    }

    function test_pause_stops_buying_not_granting() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        eggs.pause();
        vm.prank(owner);
        eggs.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        eggs.buy{value: 0.2 ether}(1);
        address[] memory ws = new address[](1);
        ws[0] = alice;
        vm.prank(owner);
        eggs.grant(ws, 1);
        assertEq(eggs.packsOf(alice), 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        eggs.unpause();
        vm.prank(owner);
        eggs.unpause();
        vm.prank(alice);
        eggs.buy{value: 0.2 ether}(1);
        assertEq(eggs.packsOf(alice), 2);
    }

    function test_withdraw() public {
        vm.prank(alice);
        eggs.buy{value: 0.6 ether}(3);
        address payable to = payable(makeAddr("treasury"));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        eggs.withdraw(to);
        vm.startPrank(owner);
        vm.expectRevert(ElyfishPetEggs.ZeroAddress.selector);
        eggs.withdraw(payable(address(0)));
        vm.expectEmit(address(eggs));
        emit ElyfishPetEggs.Withdrawn(to, 0.6 ether);
        eggs.withdraw(to);
        vm.stopPrank();
        assertEq(to.balance, 0.6 ether);
        assertEq(address(eggs).balance, 0);
        EggNoReceive nr = new EggNoReceive();
        vm.prank(alice);
        eggs.buy{value: 0.2 ether}(1);
        vm.prank(owner);
        vm.expectRevert(ElyfishPetEggs.TransferFailed.selector);
        eggs.withdraw(payable(address(nr)));
    }
}
