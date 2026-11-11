// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ElyfishVip} from "../src/ElyfishVip.sol";
import {MockPriceFeed} from "../src/testnet/MockPriceFeed.sol";

/// random players buy, gift, claim and get grants while time passes and the price moves; the ghosts remember what
/// should be true so the invariants can check it
contract VipHandler is Test {
    ElyfishVip internal vip;
    MockPriceFeed internal feed;
    address internal owner;
    address[5] public actors; // the first four are on the airdrop list, the fifth never is
    bytes32 internal root;

    uint256 public paid; // HYPE kept by the contract from purchases
    uint256 public withdrawn;
    uint256 public buys;
    uint256 public claims;
    uint256 public grants;
    uint256 public strangerClaims; // claims by the wallet not on the list (must stay 0)
    mapping(address => uint256) public lastUntil; // vipUntil as the handler last saw it
    mapping(address => uint256) public capAtSet; // now + a year when it last changed
    mapping(uint32 => mapping(address => uint256)) public claimsIn; // claims per round per wallet

    constructor(ElyfishVip v, MockPriceFeed f, address o) {
        vip = v;
        feed = f;
        owner = o;
        for (uint256 i = 0; i < 5; i++) {
            actors[i] = makeAddr(string.concat("player", vm.toString(i)));
            vm.deal(actors[i], 1_000_000 ether);
        }
        bytes32[4] memory l;
        for (uint256 i = 0; i < 4; i++) l[i] = _leaf(actors[i]);
        root = _pair(_pair(l[0], l[1]), _pair(l[2], l[3]));
    }

    function buy(uint256 who, uint256 periods, uint256 extra) external {
        address a = actors[who % 5];
        periods = bound(periods, 1, 12);
        extra = bound(extra, 0, 5 ether);
        _fresh();
        uint256 cost = vip.quote(periods);
        uint256 before = a.balance;
        vm.prank(a);
        try vip.buy{value: cost + extra}(periods) {
            paid += cost;
            buys++;
            assertEq(a.balance, before - cost, "refund");
            _seen(a);
        } catch {
            assertEq(vip.vipUntil(a), lastUntil[a], "a failed buy changed VIP");
        }
    }

    function gift(uint256 from, uint256 to, uint256 periods) external {
        address a = actors[from % 5];
        address b = actors[to % 5];
        periods = bound(periods, 1, 12);
        _fresh();
        uint256 cost = vip.quote(periods);
        vm.prank(a);
        try vip.buyFor{value: cost}(b, periods) {
            paid += cost;
            buys++;
            _seen(b);
        } catch {}
    }

    function grant(uint256 who, uint32 days_) external {
        address[] memory w = new address[](1);
        w[0] = actors[who % 5];
        days_ = uint32(bound(days_, 1, 365));
        vm.prank(owner);
        vip.grant(w, days_);
        grants++;
        _seen(w[0]);
    }

    function openAirdrop(uint32 days_) external {
        days_ = uint32(bound(days_, 1, 365));
        vm.prank(owner);
        vip.setAirdrop(root, days_);
    }

    function closeAirdrop() external {
        vm.prank(owner);
        vip.setAirdrop(bytes32(0), 0);
    }

    function claim(uint256 who) external {
        uint256 i = who % 5;
        address a = actors[i];
        bytes32[] memory proof = _proof(i);
        uint32 round = vip.airdropRound();
        vm.prank(a);
        try vip.claimAirdrop(proof) {
            claims++;
            claimsIn[round][a]++;
            if (i == 4) strangerClaims++;
            _seen(a);
        } catch {
            assertEq(vip.vipUntil(a), lastUntil[a], "a failed claim changed VIP");
        }
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 60 days));
    }

    function moveRate(uint256 rate) external {
        vm.prank(owner);
        feed.setAnswer(int256(bound(rate, 1e6, 10_000e8)));
    }

    function withdraw() external {
        uint256 bal = address(vip).balance;
        vm.prank(owner);
        vip.withdraw(payable(owner));
        withdrawn += bal;
    }

    function actorCount() external pure returns (uint256) {
        return 5;
    }

    // the price feed is fresh for an hour: refresh it at the current rate before buying
    function _fresh() private {
        (, int256 a,,,) = feed.latestRoundData();
        vm.prank(owner);
        feed.setAnswer(a);
    }

    function _seen(address a) private {
        uint256 u = vip.vipUntil(a);
        assertGe(u, lastUntil[a], "VIP got shorter");
        if (u != lastUntil[a]) capAtSet[a] = block.timestamp + 365 days;
        lastUntil[a] = u;
    }

    function _leaf(address w) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(w))));
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// the proof for actor i (the fifth gets actor 0's proof: never valid for it)
    function _proof(uint256 i) private view returns (bytes32[] memory p) {
        bytes32[4] memory l;
        for (uint256 k = 0; k < 4; k++) l[k] = _leaf(actors[k]);
        uint256 j = i == 4 ? 0 : i;
        p = new bytes32[](2);
        p[0] = l[j ^ 1];
        p[1] = j < 2 ? _pair(l[2], l[3]) : _pair(l[0], l[1]);
    }
}

contract VipInvariantTest is Test {
    ElyfishVip internal vip;
    MockPriceFeed internal feed;
    VipHandler internal handler;
    address internal owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1_800_000_000);
        feed = new MockPriceFeed(owner, 8, 25e8, "HYPE / USD");
        vip = new ElyfishVip(owner, address(feed), 1 hours, 12e8);
        handler = new VipHandler(vip, feed, owner);
        targetContract(address(handler));
    }

    /// the contract holds exactly what was paid and not yet withdrawn: no HYPE appears or goes missing
    function invariant_balance_is_paid_minus_withdrawn() public view {
        assertEq(address(vip).balance, handler.paid() - handler.withdrawn());
    }

    /// nobody's VIP reaches more than a year past the moment it was last extended, and the contract's number is the
    /// one the handler saw (nothing else changes it)
    function invariant_vip_never_past_a_year_ahead() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            uint256 u = vip.vipUntil(a);
            assertEq(u, handler.lastUntil(a));
            if (u != 0) assertLe(u, handler.capAtSet(a));
        }
    }

    /// a wallet not on the airdrop list never claims, and nobody claims twice in one round
    function invariant_airdrop_once_and_only_for_the_list() public view {
        assertEq(handler.strangerClaims(), 0);
        address stranger = handler.actors(4);
        uint32 rounds = vip.airdropRound();
        for (uint32 r = 0; r <= rounds; r++) {
            assertFalse(vip.claimed(r, stranger));
            for (uint256 i = 0; i < 4; i++) assertLe(handler.claimsIn(r, handler.actors(i)), 1);
        }
    }

    /// the owner and the settings never change by themselves
    function invariant_settings_hold() public view {
        assertEq(vip.owner(), owner);
        assertEq(vip.usdPrice(), 12e8);
        assertEq(address(vip.priceFeed()), address(feed));
    }

    function afterInvariant() external view {
        // the run did real work (not only reverted calls)
        assertGt(handler.buys() + handler.grants() + handler.claims(), 0);
    }
}
