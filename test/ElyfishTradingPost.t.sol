// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ElyfishTradingPost} from "../src/ElyfishTradingPost.sol";

/// a seller wallet that refuses HYPE (its sales are credited, withdrawn later from a wallet that can take it)
contract RefusingSeller {
    bool public open;

    function setOpen(bool o) external {
        open = o;
    }

    function cancel(ElyfishTradingPost tp, ElyfishTradingPost.Listing calldata l, bytes calldata sig) external {
        tp.cancel(l, sig);
    }

    function withdraw(ElyfishTradingPost tp) external {
        tp.withdrawOwed();
    }

    receive() external payable {
        require(open, "no");
    }
}

/// a seller that burns all the gas it is given
contract GasBomb {
    receive() external payable {
        while (true) {}
    }
}

/// a seller that tries to buy again (or withdraw) while it is being paid
contract ReentrantSeller {
    ElyfishTradingPost internal tp;
    ElyfishTradingPost.Listing internal l2;
    bytes internal sig2;

    constructor(ElyfishTradingPost t) {
        tp = t;
    }

    function arm(ElyfishTradingPost.Listing calldata l, bytes calldata sig) external {
        l2 = l;
        sig2 = sig;
    }

    receive() external payable {
        tp.buy{value: 0}(l2, sig2);
    }
}

/// a buyer that refuses the change sent back
contract RefusingBuyer {
    function buy(ElyfishTradingPost tp, ElyfishTradingPost.Listing calldata l, bytes calldata sig) external payable {
        tp.buy{value: msg.value}(l, sig);
    }
}

abstract contract TradeBase is Test {
    ElyfishTradingPost internal tp;
    address internal owner = makeAddr("owner");
    address internal signer;
    uint256 internal signerKey;
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    uint256 internal constant T0 = 1_800_000_000;

    function setUp() public virtual {
        vm.warp(T0);
        (signer, signerKey) = makeAddrAndKey("game-server");
        tp = new ElyfishTradingPost(owner, signer);
        vm.deal(buyer, 10_000_000 ether);
    }

    function listing(uint256 id, address s, uint256 price) internal pure returns (ElyfishTradingPost.Listing memory) {
        return ElyfishTradingPost.Listing({id: id, seller: s, price: price, expiry: uint64(T0 + 3 days)});
    }

    function sign(ElyfishTradingPost.Listing memory l, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, tp.hashListing(l));
        return abi.encodePacked(r, s, v);
    }

    function sign(ElyfishTradingPost.Listing memory l) internal view returns (bytes memory) {
        return sign(l, signerKey);
    }
}

contract ElyfishTradingPostTest is TradeBase {
    // ── set up ──────────────────────────────────────────────────────────────────────────────────────────────────

    function test_constructor() public {
        assertEq(tp.owner(), owner);
        assertEq(tp.signer(), signer);
        assertEq(tp.FEE_BPS(), 300);
        vm.expectRevert(ElyfishTradingPost.ZeroAddress.selector);
        new ElyfishTradingPost(owner, address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ElyfishTradingPost(address(0), signer);
    }

    // ── buying ──────────────────────────────────────────────────────────────────────────────────────────────────

    function test_buy_pays_97_percent_and_keeps_3() public {
        ElyfishTradingPost.Listing memory l = listing(1, seller, 10 ether);
        bytes memory sig = sign(l);
        assertTrue(tp.isBuyable(l, sig));
        vm.expectEmit(address(tp));
        emit ElyfishTradingPost.Bought(1, buyer, seller, 10 ether, 0.3 ether);
        vm.prank(buyer);
        tp.buy{value: 10 ether}(l, sig);
        assertEq(seller.balance, 9.7 ether);
        assertEq(tp.feesAccrued(), 0.3 ether);
        assertEq(address(tp).balance, 0.3 ether);
        assertEq(uint256(tp.status(1)), uint256(ElyfishTradingPost.Status.Sold));
        assertEq(tp.buyerOf(1), buyer);
        assertFalse(tp.isBuyable(l, sig));
    }

    function test_buy_sends_back_the_extra() public {
        ElyfishTradingPost.Listing memory l = listing(2, seller, 1 ether);
        bytes memory sig = sign(l);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        tp.buy{value: 5 ether}(l, sig);
        assertEq(buyer.balance, before - 1 ether);
    }

    function test_no_second_sale() public {
        ElyfishTradingPost.Listing memory l = listing(3, seller, 1 ether);
        bytes memory sig = sign(l);
        vm.prank(buyer);
        tp.buy{value: 1 ether}(l, sig);
        address other = makeAddr("other");
        vm.deal(other, 10 ether);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ElyfishTradingPost.NotOpen.selector, 3, ElyfishTradingPost.Status.Sold));
        tp.buy{value: 1 ether}(l, sig);
        assertEq(tp.buyerOf(3), buyer);
    }

    function test_underpaying_fails() public {
        ElyfishTradingPost.Listing memory l = listing(4, seller, 1 ether);
        bytes memory sig = sign(l);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ElyfishTradingPost.Underpaid.selector, 1 ether, 1 ether - 1));
        tp.buy{value: 1 ether - 1}(l, sig);
    }

    function test_own_listing_cant_be_bought() public {
        ElyfishTradingPost.Listing memory l = listing(5, seller, 1 ether);
        bytes memory sig = sign(l);
        vm.deal(seller, 2 ether);
        vm.prank(seller);
        vm.expectRevert(ElyfishTradingPost.OwnListing.selector);
        tp.buy{value: 1 ether}(l, sig);
    }

    function test_expired_or_too_long_fails() public {
        ElyfishTradingPost.Listing memory l = listing(6, seller, 1 ether);
        bytes memory sig = sign(l);
        vm.warp(l.expiry + 1);
        assertFalse(tp.isBuyable(l, sig));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ElyfishTradingPost.Expired.selector, 6, l.expiry));
        tp.buy{value: 1 ether}(l, sig);
        // exactly at expiry is still fine
        vm.warp(l.expiry);
        vm.prank(buyer);
        tp.buy{value: 1 ether}(l, sig);
        // a signature far in the future is refused
        ElyfishTradingPost.Listing memory far = listing(7, seller, 1 ether);
        far.expiry = uint64(block.timestamp + 31 days);
        bytes memory fsig = sign(far);
        assertFalse(tp.isBuyable(far, fsig));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ElyfishTradingPost.TooLong.selector, 7, far.expiry));
        tp.buy{value: 1 ether}(far, fsig);
    }

    function test_bad_listings_fail() public {
        ElyfishTradingPost.Listing memory noSeller = listing(8, address(0), 1 ether);
        bytes memory s1 = sign(noSeller);
        assertFalse(tp.isBuyable(noSeller, s1));
        vm.prank(buyer);
        vm.expectRevert(ElyfishTradingPost.BadListing.selector);
        tp.buy{value: 1 ether}(noSeller, s1);
        ElyfishTradingPost.Listing memory cheap = listing(9, seller, 1e12 - 1);
        bytes memory s2 = sign(cheap);
        assertFalse(tp.isBuyable(cheap, s2));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ElyfishTradingPost.BadPrice.selector, 1e12 - 1));
        tp.buy{value: 1 ether}(cheap, s2);
        ElyfishTradingPost.Listing memory dear = listing(10, seller, 1_000_000 ether + 1);
        bytes memory s3 = sign(dear);
        assertFalse(tp.isBuyable(dear, s3));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ElyfishTradingPost.BadPrice.selector, 1_000_000 ether + 1));
        tp.buy{value: 1 ether}(dear, s3);
    }

    function test_signature_must_be_the_servers_and_match() public {
        ElyfishTradingPost.Listing memory l = listing(11, seller, 1 ether);
        (, uint256 evil) = makeAddrAndKey("evil");
        bytes memory forged = sign(l, evil);
        assertFalse(tp.isBuyable(l, forged));
        vm.prank(buyer);
        vm.expectRevert(ElyfishTradingPost.BadSignature.selector);
        tp.buy{value: 1 ether}(l, forged);
        // the server's signature, a changed price
        bytes memory sig = sign(l);
        ElyfishTradingPost.Listing memory cheaper = listing(11, seller, 0.5 ether);
        vm.prank(buyer);
        vm.expectRevert(ElyfishTradingPost.BadSignature.selector);
        tp.buy{value: 1 ether}(cheaper, sig);
        // a changed seller (to steal the proceeds)
        ElyfishTradingPost.Listing memory thief = listing(11, buyer, 1 ether);
        vm.prank(makeAddr("x"));
        vm.expectRevert(ElyfishTradingPost.BadSignature.selector);
        tp.buy{value: 0}(thief, sig);
        // garbage
        vm.prank(buyer);
        vm.expectRevert(ElyfishTradingPost.BadSignature.selector);
        tp.buy{value: 1 ether}(l, hex"1234");
        // a malleable twin (high s) of a good signature is refused too
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, tp.hashListing(l));
        bytes32 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory twin = abi.encodePacked(r, bytes32(uint256(n) - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.prank(buyer);
        vm.expectRevert(ElyfishTradingPost.BadSignature.selector);
        tp.buy{value: 1 ether}(l, twin);
    }

    function test_signatures_from_another_contract_dont_work() public {
        ElyfishTradingPost other = new ElyfishTradingPost(owner, signer);
        ElyfishTradingPost.Listing memory l = listing(12, seller, 1 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, other.hashListing(l));
        vm.prank(buyer);
        vm.expectRevert(ElyfishTradingPost.BadSignature.selector);
        tp.buy{value: 1 ether}(l, abi.encodePacked(r, s, v));
    }

    // ── the seller's payout ─────────────────────────────────────────────────────────────────────────────────────

    function test_refusing_seller_is_credited_and_withdraws() public {
        RefusingSeller rs = new RefusingSeller();
        ElyfishTradingPost.Listing memory l = listing(13, address(rs), 2 ether);
        bytes memory sig = sign(l);
        vm.expectEmit(address(tp));
        emit ElyfishTradingPost.Owed(address(rs), 1.94 ether);
        vm.prank(buyer);
        tp.buy{value: 2 ether}(l, sig);
        assertEq(tp.owed(address(rs)), 1.94 ether);
        assertEq(tp.totalOwed(), 1.94 ether);
        assertEq(address(tp).balance, 2 ether);
        vm.expectRevert(ElyfishTradingPost.TransferFailed.selector);
        rs.withdraw(tp);
        rs.setOpen(true);
        rs.withdraw(tp);
        assertEq(address(rs).balance, 1.94 ether);
        assertEq(tp.totalOwed(), 0);
        vm.expectRevert(ElyfishTradingPost.NothingOwed.selector);
        rs.withdraw(tp);
    }

    function test_gas_bomb_seller_cant_block_the_sale() public {
        GasBomb gb = new GasBomb();
        ElyfishTradingPost.Listing memory l = listing(14, address(gb), 1 ether);
        bytes memory sig = sign(l);
        vm.prank(buyer);
        tp.buy{value: 1 ether, gas: 1_000_000}(l, sig);
        assertEq(tp.owed(address(gb)), 0.97 ether);
        assertEq(tp.buyerOf(14), buyer);
    }

    function test_reentrant_seller_gets_credited_not_double_sale() public {
        ReentrantSeller rs = new ReentrantSeller(tp);
        ElyfishTradingPost.Listing memory l = listing(15, address(rs), 1 ether);
        bytes memory sig = sign(l);
        ElyfishTradingPost.Listing memory l2 = listing(16, makeAddr("s2"), 1 ether);
        bytes memory sig2 = sign(l2);
        rs.arm(l2, sig2);
        vm.prank(buyer);
        tp.buy{value: 1 ether}(l, sig);
        // its receive tried to buy (guarded): the payout failed and was credited; listing 16 is still open
        assertEq(tp.owed(address(rs)), 0.97 ether);
        assertEq(uint256(tp.status(16)), uint256(ElyfishTradingPost.Status.Open));
    }

    function test_buyer_refusing_its_change_fails_cleanly() public {
        RefusingBuyer rb = new RefusingBuyer();
        ElyfishTradingPost.Listing memory l = listing(17, seller, 1 ether);
        bytes memory sig = sign(l);
        vm.deal(address(this), 5 ether);
        vm.expectRevert(ElyfishTradingPost.TransferFailed.selector);
        rb.buy{value: 2 ether}(tp, l, sig);
        assertEq(uint256(tp.status(17)), uint256(ElyfishTradingPost.Status.Open));
        rb.buy{value: 1 ether}(tp, l, sig);   // the exact price needs no change
        assertEq(tp.buyerOf(17), address(rb));
    }

    // ── cancelling ──────────────────────────────────────────────────────────────────────────────────────────────

    function test_cancel_by_seller_signer_or_owner_only() public {
        ElyfishTradingPost.Listing memory l = listing(18, seller, 1 ether);
        bytes memory sig = sign(l);
        vm.prank(buyer);
        vm.expectRevert(ElyfishTradingPost.NotAllowed.selector);
        tp.cancel(l, sig);
        vm.expectEmit(address(tp));
        emit ElyfishTradingPost.Cancelled(18, seller);
        vm.prank(seller);
        tp.cancel(l, sig);
        assertEq(uint256(tp.status(18)), uint256(ElyfishTradingPost.Status.Cancelled));
        // no buying, no second cancel
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ElyfishTradingPost.NotOpen.selector, 18, ElyfishTradingPost.Status.Cancelled));
        tp.buy{value: 1 ether}(l, sig);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ElyfishTradingPost.NotOpen.selector, 18, ElyfishTradingPost.Status.Cancelled));
        tp.cancel(l, sig);
        ElyfishTradingPost.Listing memory a = listing(19, seller, 1 ether);
        ElyfishTradingPost.Listing memory b = listing(20, seller, 1 ether);
        bytes memory sa = sign(a);
        bytes memory sb = sign(b);
        vm.prank(signer);
        tp.cancel(a, sa);
        vm.prank(owner);
        tp.cancel(b, sb);
        assertEq(uint256(tp.status(19)), 2);
        assertEq(uint256(tp.status(20)), 2);
    }

    function test_sold_cant_be_cancelled() public {
        ElyfishTradingPost.Listing memory l = listing(21, seller, 1 ether);
        bytes memory sig = sign(l);
        vm.prank(buyer);
        tp.buy{value: 1 ether}(l, sig);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ElyfishTradingPost.NotOpen.selector, 21, ElyfishTradingPost.Status.Sold));
        tp.cancel(l, sig);
    }

    function test_cancel_needs_a_real_listing() public {
        ElyfishTradingPost.Listing memory l = listing(22, seller, 1 ether);
        (, uint256 evil) = makeAddrAndKey("evil");
        bytes memory forged = sign(l, evil);
        // a seller can't cancel someone's listing by signing their own "listing" with the same id
        vm.prank(seller);
        vm.expectRevert(ElyfishTradingPost.BadSignature.selector);
        tp.cancel(l, forged);
    }

    // ── owner ───────────────────────────────────────────────────────────────────────────────────────────────────

    function test_pause_stops_buying_only() public {
        ElyfishTradingPost.Listing memory l = listing(23, seller, 1 ether);
        bytes memory sig = sign(l);
        vm.prank(owner);
        tp.pause();
        assertFalse(tp.isBuyable(l, sig));
        vm.prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        tp.buy{value: 1 ether}(l, sig);
        vm.prank(seller);
        tp.cancel(l, sig);   // still possible
        vm.prank(owner);
        tp.unpause();
    }

    function test_rotating_the_signer_kills_old_signatures() public {
        ElyfishTradingPost.Listing memory l = listing(24, seller, 1 ether);
        bytes memory sig = sign(l);
        (address s2, uint256 k2) = makeAddrAndKey("new-server");
        vm.expectEmit(address(tp));
        emit ElyfishTradingPost.SignerSet(s2);
        vm.prank(owner);
        tp.setSigner(s2);
        vm.prank(buyer);
        vm.expectRevert(ElyfishTradingPost.BadSignature.selector);
        tp.buy{value: 1 ether}(l, sig);
        bytes memory sig2 = sign(l, k2);
        vm.prank(buyer);
        tp.buy{value: 1 ether}(l, sig2);
        vm.prank(owner);
        vm.expectRevert(ElyfishTradingPost.ZeroAddress.selector);
        tp.setSigner(address(0));
    }

    function test_fees_go_to_the_owner_never_the_owed() public {
        RefusingSeller rs = new RefusingSeller();
        ElyfishTradingPost.Listing memory a = listing(25, address(rs), 10 ether);
        ElyfishTradingPost.Listing memory b = listing(26, seller, 10 ether);
        bytes memory sa = sign(a);
        bytes memory sb = sign(b);
        vm.startPrank(buyer);
        tp.buy{value: 10 ether}(a, sa);
        tp.buy{value: 10 ether}(b, sb);
        vm.stopPrank();
        address payable bomb = payable(address(new GasBomb()));
        address payable treasury = payable(makeAddr("treasury"));
        vm.expectEmit(address(tp));
        emit ElyfishTradingPost.FeesWithdrawn(treasury, 0.6 ether);
        vm.prank(owner);
        tp.withdrawFees(treasury);
        assertEq(treasury.balance, 0.6 ether);
        assertEq(address(tp).balance, 9.7 ether);   // the refusing seller's share stays
        assertEq(tp.totalOwed(), 9.7 ether);
        vm.startPrank(owner);
        vm.expectRevert(ElyfishTradingPost.ZeroAddress.selector);
        tp.withdrawFees(payable(address(0)));
        vm.expectRevert(ElyfishTradingPost.TransferFailed.selector);
        tp.withdrawFees(bomb);
        vm.stopPrank();
    }

    function test_owner_only() public {
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        tp.setSigner(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        tp.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        tp.unpause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        tp.withdrawFees(payable(buyer));
        vm.stopPrank();
    }

    function test_two_step_ownership() public {
        vm.prank(owner);
        tp.transferOwnership(buyer);
        assertEq(tp.owner(), owner);
        vm.prank(buyer);
        tp.acceptOwnership();
        assertEq(tp.owner(), buyer);
    }

    // ── fuzz ────────────────────────────────────────────────────────────────────────────────────────────────────

    /// any price and overpayment: the seller gets price − 3 % (rounded in their favour), the post 3 %, the buyer the rest
    function testFuzz_split(uint256 price, uint256 extra, uint256 id) public {
        price = bound(price, 1e12, 1_000_000 ether);
        extra = bound(extra, 0, 1_000 ether);
        ElyfishTradingPost.Listing memory l = listing(id, seller, price);
        bytes memory sig = sign(l);
        vm.deal(buyer, price + extra);
        vm.prank(buyer);
        tp.buy{value: price + extra}(l, sig);
        uint256 fee = (price * 300) / 10_000;
        assertEq(tp.feesAccrued(), fee);
        assertEq(seller.balance, price - fee);
        assertEq(buyer.balance, extra);
        assertEq(address(tp).balance, fee);
        assertLe(fee * 10_000, price * 300);
        assertGt((fee + 1) * 10_000, price * 300);
    }

    /// any change to a signed listing (id, seller, price, expiry) breaks the signature
    function testFuzz_tampering_breaks_the_signature(uint256 id, uint256 dId, uint256 dPrice, uint64 dExp, address s2) public {
        vm.assume(s2 != address(0) && s2 != seller);
        ElyfishTradingPost.Listing memory l = listing(id, seller, 1 ether);
        bytes memory sig = sign(l);
        ElyfishTradingPost.Listing memory t = l;
        uint256 which = dId % 4;
        if (which == 0) t.id = id ^ (dId | 1);
        else if (which == 1) t.seller = s2;
        else if (which == 2) t.price = bound(dPrice, 1e12, 1_000_000 ether) == 1 ether ? 2 ether : bound(dPrice, 1e12, 1_000_000 ether);
        else t.expiry = uint64(T0 + 1 + (uint256(dExp) % (30 days - 1)) == l.expiry ? T0 + 1 : T0 + 1 + (uint256(dExp) % (30 days - 1)));
        assertFalse(tp.isBuyable(t, sig));
        vm.prank(buyer);
        vm.expectRevert(ElyfishTradingPost.BadSignature.selector);
        tp.buy{value: 1_000_000 ether}(t, sig);
    }

    /// any amount below the price never buys
    function testFuzz_underpay(uint256 price, uint256 sent) public {
        price = bound(price, 1e12, 1_000_000 ether);
        sent = bound(sent, 0, price - 1);
        ElyfishTradingPost.Listing memory l = listing(42, seller, price);
        bytes memory sig = sign(l);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ElyfishTradingPost.Underpaid.selector, price, sent));
        tp.buy{value: sent}(l, sig);
        assertEq(uint256(tp.status(42)), 0);
    }

    /// any time after the expiry, never
    function testFuzz_after_expiry(uint256 late) public {
        ElyfishTradingPost.Listing memory l = listing(43, seller, 1 ether);
        bytes memory sig = sign(l);
        vm.warp(uint256(l.expiry) + bound(late, 1, 3650 days));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ElyfishTradingPost.Expired.selector, 43, l.expiry));
        tp.buy{value: 1 ether}(l, sig);
    }

    /// strangers can never cancel
    function testFuzz_stranger_cant_cancel(address who) public {
        vm.assume(who != seller && who != signer && who != owner);
        ElyfishTradingPost.Listing memory l = listing(44, seller, 1 ether);
        bytes memory sig = sign(l);
        vm.prank(who);
        vm.expectRevert(ElyfishTradingPost.NotAllowed.selector);
        tp.cancel(l, sig);
    }
}
