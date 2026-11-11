// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ElyfishTradingPost} from "../src/ElyfishTradingPost.sol";

/// a seller wallet that sometimes refuses HYPE (its sales are credited)
contract MoodySeller {
    bool public open;

    function setOpen(bool o) external {
        open = o;
    }

    function withdraw(ElyfishTradingPost tp) external {
        tp.withdrawOwed();
    }

    receive() external payable {
        require(open, "no");
    }
}

/// random players buy, cancel, forge, withdraw and wait; the ghosts keep what must be true
contract TradeHandler is Test {
    ElyfishTradingPost internal tp;
    address internal owner;
    uint256 internal signerKey;
    uint256 internal evilKey;
    address payable[4] internal sellers;   // two wallets, two contracts that may refuse HYPE
    address[3] internal buyers;
    uint256 public constant N = 24;   // listings the server signed
    ElyfishTradingPost.Listing[N] internal ls;

    // ghosts
    uint256 public paidIn;   // prices of all sales
    uint256 public feeTotal;   // 3 % of each sale, rounded down
    uint256 public feesOut;   // fees withdrawn
    uint256 public sold;
    uint256 public cancelled;
    uint256 public forgedOk;   // forged / tampered purchases that went through (must stay 0)
    uint256 public lateOk;   // purchases after the expiry (must stay 0)
    uint256 public doubleOk;   // a second purchase or a cancel after the end (must stay 0)
    mapping(address => uint256) public dueTo;   // what each seller's sales earned (price − fee)
    mapping(address => uint256) public gotOut;   // what each seller received (paid at once or withdrawn)
    mapping(uint256 => uint8) public endedAs;   // 0 open, 1 sold, 2 cancelled — first end, never changes

    constructor(ElyfishTradingPost t, address o, uint256 sk) {
        tp = t;
        owner = o;
        signerKey = sk;
        (, evilKey) = makeAddrAndKey("evil");
        sellers[0] = payable(makeAddr("s0"));
        sellers[1] = payable(makeAddr("s1"));
        sellers[2] = payable(address(new MoodySeller()));
        sellers[3] = payable(address(new MoodySeller()));
        for (uint256 i = 0; i < 3; i++) {
            buyers[i] = makeAddr(string.concat("b", vm.toString(i)));
            vm.deal(buyers[i], 1e30);
        }
        for (uint256 i = 0; i < N; i++) {
            uint256 price = 1e12 + uint256(keccak256(abi.encode(i))) % 50 ether;
            ls[i] = ElyfishTradingPost.Listing({id: 1000 + i, seller: sellers[i % 4], price: price, expiry: uint64(block.timestamp + 1 days + (i * 1 hours))});
        }
    }

    function _sig(ElyfishTradingPost.Listing memory l, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, tp.hashListing(l));
        return abi.encodePacked(r, s, v);
    }

    function _received(address s) internal view returns (uint256) {
        return s.balance;
    }

    function buy(uint256 i, uint256 b, uint256 extra) external {
        i = i % N;
        ElyfishTradingPost.Listing memory l = ls[i];
        address who = buyers[b % 3];
        extra = bound(extra, 0, 5 ether);
        bytes memory sig = _sig(l, signerKey);
        uint256 sBefore = l.seller.balance;
        uint256 bBefore = who.balance;
        bool wasOpen = endedAs[i] == 0;
        bool late = block.timestamp > l.expiry;
        vm.prank(who);
        try tp.buy{value: l.price + extra}(l, sig) {
            if (!wasOpen) doubleOk++;
            if (late) lateOk++;
            endedAs[i] = 1;
            sold++;
            paidIn += l.price;
            uint256 fee = (l.price * 300) / 10_000;
            feeTotal += fee;
            dueTo[l.seller] += l.price - fee;
            gotOut[l.seller] += l.seller.balance - sBefore;
            assertEq(who.balance, bBefore - l.price, "the buyer paid exactly the price");
            assertEq(tp.buyerOf(l.id), who);
        } catch {
            assertEq(who.balance, bBefore, "a failed buy took nothing");
        }
    }

    function cancel(uint256 i, uint256 by) external {
        i = i % N;
        ElyfishTradingPost.Listing memory l = ls[i];
        bytes memory sig = _sig(l, signerKey);
        address who = by % 3 == 0 ? l.seller : by % 3 == 1 ? owner : buyers[by % 3];
        bool wasOpen = endedAs[i] == 0;
        vm.prank(who);
        try tp.cancel(l, sig) {
            if (!wasOpen) doubleOk++;
            assertTrue(who == l.seller || who == owner, "only the seller or owner here");
            endedAs[i] = 2;
            cancelled++;
        } catch {}
    }

    /// a purchase with a tampered listing or a forged signature — must never go through
    function forge(uint256 i, uint256 how, uint256 cut) external {
        i = i % N;
        ElyfishTradingPost.Listing memory l = ls[i];
        bytes memory sig;
        if (how % 3 == 0) {
            sig = _sig(l, evilKey);
        } else if (how % 3 == 1) {
            sig = _sig(l, signerKey);
            l.price = bound(cut, 1e12, l.price > 1e12 ? l.price - 1 : 1e12);   // cheaper than signed
            if (l.price == ls[i].price) return;
        } else {
            sig = _sig(l, signerKey);
            l.seller = payable(buyers[0]);   // proceeds redirected
        }
        vm.prank(buyers[1]);
        try tp.buy{value: ls[i].price}(l, sig) { forgedOk++; } catch {}
    }

    function withdrawOwed(uint256 s, bool openUp) external {
        uint256 k = 2 + (s % 2);
        MoodySeller m = MoodySeller(sellers[k]);
        m.setOpen(openUp);
        uint256 before = address(m).balance;
        try m.withdraw(tp) { gotOut[address(m)] += address(m).balance - before; } catch {}
    }

    function moodSwing(uint256 s, bool openUp) external {
        MoodySeller(sellers[2 + (s % 2)]).setOpen(openUp);
    }

    function withdrawFees() external {
        uint256 f = tp.feesAccrued();
        vm.prank(owner);
        tp.withdrawFees(payable(owner));
        feesOut += f;
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 6 hours));
    }

    function listing(uint256 i) external view returns (ElyfishTradingPost.Listing memory) {
        return ls[i];
    }

    function seller(uint256 k) external view returns (address) {
        return sellers[k];
    }
}

contract TradingPostInvariantTest is Test {
    ElyfishTradingPost internal tp;
    TradeHandler internal h;
    address internal owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1_800_000_000);
        (address signer, uint256 key) = makeAddrAndKey("game-server");
        tp = new ElyfishTradingPost(owner, signer);
        h = new TradeHandler(tp, owner, key);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](7);
        sel[0] = TradeHandler.buy.selector;
        sel[1] = TradeHandler.cancel.selector;
        sel[2] = TradeHandler.forge.selector;
        sel[3] = TradeHandler.withdrawOwed.selector;
        sel[4] = TradeHandler.moodSwing.selector;
        sel[5] = TradeHandler.withdrawFees.selector;
        sel[6] = TradeHandler.wait.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    /// the HYPE held is exactly the fees not yet withdrawn plus what sellers are still owed
    function invariant_balance_is_fees_plus_owed() public view {
        assertEq(address(tp).balance, tp.feesAccrued() + tp.totalOwed());
    }

    /// the fees are exactly 3 % (rounded down) of every sale; every seller got or is owed exactly the rest
    function invariant_money_adds_up() public view {
        assertEq(tp.feesAccrued() + h.feesOut(), h.feeTotal());
        uint256 owedSum;
        for (uint256 k = 0; k < 4; k++) {
            address s = h.seller(k);
            owedSum += tp.owed(s);
            assertEq(h.gotOut(s) + tp.owed(s), h.dueTo(s), "seller paid + owed = earned");
        }
        assertEq(owedSum, tp.totalOwed());
        assertEq(h.paidIn(), h.feeTotal() + h.dueTo(h.seller(0)) + h.dueTo(h.seller(1)) + h.dueTo(h.seller(2)) + h.dueTo(h.seller(3)));
    }

    /// no forged / tampered purchase, no purchase after the expiry, no second sale or cancel ever went through
    function invariant_no_exploit_went_through() public view {
        assertEq(h.forgedOk(), 0);
        assertEq(h.lateOk(), 0);
        assertEq(h.doubleOk(), 0);
    }

    /// every listing's state on chain is the one it first ended in; sold ones have their buyer, others none
    function invariant_listing_states() public view {
        for (uint256 i = 0; i < h.N(); i++) {
            uint256 id = h.listing(i).id;
            uint8 e = h.endedAs(i);
            assertEq(uint256(tp.status(id)), e);
            if (e == 1) assertTrue(tp.buyerOf(id) != address(0));
            else assertEq(tp.buyerOf(id), address(0));
        }
    }

    function afterInvariant() external view {
        assertGt(h.sold() + h.cancelled(), 0, "the run did real work");
    }
}
