// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {ElyfishSkins} from "../src/ElyfishSkins.sol";
import {MockPriceFeed} from "../src/testnet/MockPriceFeed.sol";

/// The rotation: time runs in rounds of a week; two skins are on sale in a round (one legendary and one epic in the
/// first), then they close and the next two open; after every skin has had its round the order starts again, so
/// what was not sold out comes back.
contract SkinsScheduleTest is Base {
    ElyfishSkins internal fresh; // the collection as it ships: launched now, a week a round, two skins a round
    uint256 internal constant SKINS = 42;
    uint256 internal constant ROUNDS = 21; // 42 skins, two a round

    function setUp() public override {
        super.setUp();
        fresh = launchAt(0, PERIOD, 2);
    }

    function launchAt(uint64 at, uint64 every, uint16 each) internal returns (ElyfishSkins) {
        return new ElyfishSkins(owner, address(feed), 1 hours, BASE, CONTRACT, treasury, 500, kinds, rarities, supplies, saleAt(at, every, each));
    }

    /// move the clock and give the feed a fresh answer there (a mint needs one)
    function goTo(uint256 t) internal {
        vm.warp(t);
        vm.prank(owner);
        feed.setAnswer(25e8);
    }

    function startOf(ElyfishSkins c, uint256 r) internal view returns (uint256) {
        return uint256(c.launch()) + r * c.period();
    }

    /// the rotation is whole: every round of a cycle has its skins (perRound of them, the last round the rest), every
    /// skin is in exactly one round, onSale() and isOpen() agree, the first round has a legendary and an epic (when
    /// the collection has them), and the next cycle is the same again
    function checkRotation(ElyfishSkins c, uint8[] memory rar) internal {
        uint256 n = rar.length;
        uint256 each = c.perRound();
        uint256 rounds = c.cycle();
        assertEq(rounds, (n + each - 1) / each);
        uint256[] memory turn = new uint256[](n);
        bool[] memory seen = new bool[](n);
        bool hasLegendary;
        bool hasEpic;
        for (uint256 i = 0; i < n; i++) {
            if (rar[i] == 4) hasLegendary = true;
            if (rar[i] == 3) hasEpic = true;
        }
        for (uint256 r = 0; r < rounds; r++) {
            vm.warp(startOf(c, r));
            (uint256[] memory ids, uint256 closesAt) = c.onSale();
            assertEq(closesAt, startOf(c, r + 1));
            assertEq(c.round(), r);
            assertEq(ids.length, r + 1 < rounds ? each : n - each * (rounds - 1));
            bool legendary;
            bool epic;
            for (uint256 k = 0; k < ids.length; k++) {
                assertLt(ids[k], n);
                assertFalse(seen[ids[k]], "a skin has one round only");
                seen[ids[k]] = true;
                turn[ids[k]] = r;
                if (rar[ids[k]] == 4) legendary = true;
                if (rar[ids[k]] == 3) epic = true;
            }
            if (r == 0) {
                if (hasLegendary) assertTrue(legendary, "a legendary in the first round");
                if (hasEpic && ids.length > 1) assertTrue(epic, "an epic in the first round");
            }
            for (uint256 i = 0; i < n; i++) assertEq(c.isOpen(i), seen[i] && turn[i] == r, "isOpen is the round's list");
            // the last second of the round: still the same skins
            vm.warp(closesAt - 1);
            (uint256[] memory late,) = c.onSale();
            assertEq(keccak256(abi.encode(late)), keccak256(abi.encode(ids)));
        }
        for (uint256 i = 0; i < n; i++) assertTrue(seen[i], "every skin gets a round");
        // the next cycle: the same skins in the same rounds
        for (uint256 r = 0; r < rounds; r++) {
            vm.warp(startOf(c, rounds + r) + c.period() / 2);
            assertEq(c.round(), rounds + r);
            for (uint256 i = 0; i < n; i++) assertEq(c.isOpen(i), turn[i] == r);
        }
    }

    function pairOf(ElyfishSkins c) internal view returns (uint256 a, uint256 b) {
        (uint256[] memory ids,) = c.onSale();
        return (ids[0], ids[1]);
    }

    // ------------------------------------------------------------------ unit

    function test_TheFirstRoundIsOneLegendaryAndOneEpic() public view {
        assertEq(fresh.launch(), block.timestamp);
        assertEq(fresh.period(), 7 days);
        assertEq(fresh.perRound(), 2);
        assertEq(fresh.cycle(), ROUNDS);
        (uint256[] memory ids, uint256 closesAt) = fresh.onSale();
        assertEq(ids.length, 2);
        assertEq(rarities[ids[0]], 4, "a legendary");
        assertEq(rarities[ids[1]], 3, "an epic");
        assertEq(closesAt, block.timestamp + 7 days);
        uint256 open;
        for (uint256 i = 0; i < SKINS; i++) if (fresh.isOpen(i)) open++;
        assertEq(open, 2);
    }

    function test_TheShippedRotationIsWhole() public {
        checkRotation(fresh, rarities);   // 21 weeks, two skins a week, every skin once; then again
    }

    function test_OnlyTheRoundsSkinsMint() public {
        (uint256 a, uint256 b) = pairOf(fresh);
        for (uint256 i = 0; i < SKINS; i++) {
            uint256 cost = fresh.hypePrice(i, 1);
            if (i != a && i != b) vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotOnSale.selector, i));
            vm.prank(alice);
            fresh.mint{value: cost}(i, 1);
            if (i != a && i != b) vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotOnSale.selector, i));
            vm.prank(owner);
            fresh.reserveMint(bob, i, 1);
        }
        assertEq(fresh.balanceOf(alice), 2);
        assertEq(fresh.balanceOf(bob), 2);
        assertEq(fresh.totalSupply(), 4);
    }

    function test_AfterAWeekTheTwoCloseAndTheNextTwoOpen() public {
        (uint256 a, uint256 b) = pairOf(fresh);
        uint256 end = startOf(fresh, 1);
        goTo(end - 1);
        uint256 cost = fresh.hypePrice(a, 1);
        vm.prank(alice);
        fresh.mint{value: cost}(a, 1);   // the last second of its week
        goTo(end);
        (uint256 c, uint256 d) = pairOf(fresh);
        assertTrue(c != a && c != b && d != a && d != b, "two other skins");
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotOnSale.selector, a));
        vm.prank(alice);
        fresh.mint{value: cost}(a, 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotOnSale.selector, b));
        vm.prank(alice);
        fresh.mint{value: 1_000 ether}(b, 1);
        uint256 costC = fresh.hypePrice(c, 1);
        vm.prank(alice);
        fresh.mint{value: costC}(c, 1);
        assertEq(fresh.balanceOf(alice), 2);
    }

    /// what was not sold out in its week comes back on sale when the order starts again — with the stock it had left
    function test_AnUnsoldSkinComesBackInTheNextCycle() public {
        (uint256 a,) = pairOf(fresh);   // the legendary: 50 tokens
        uint256 cost = fresh.hypePrice(a, 20);
        vm.prank(alice);
        fresh.mint{value: cost}(a, 20);
        assertEq(fresh.remaining(a), 30);
        // closed for the 20 weeks in between
        for (uint256 r = 1; r < ROUNDS; r++) {
            vm.warp(startOf(fresh, r));
            assertFalse(fresh.isOpen(a));
        }
        goTo(startOf(fresh, ROUNDS));
        assertTrue(fresh.isOpen(a));
        vm.startPrank(bob);
        fresh.mint{value: fresh.hypePrice(a, 20)}(a, 20);
        fresh.mint{value: fresh.hypePrice(a, 10)}(a, 10);
        uint256 one = fresh.hypePrice(a, 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.SoldOut.selector, a, 0));
        fresh.mint{value: one}(a, 1);
        vm.stopPrank();
        assertEq(fresh.remaining(a), 0);
        // a third cycle: it has its week again, sold out as it is
        vm.warp(startOf(fresh, 2 * ROUNDS));
        assertTrue(fresh.isOpen(a));
    }

    function test_BeforeTheLaunchNothingIsOnSale() public {
        uint64 at = uint64(block.timestamp + 2 days);
        ElyfishSkins c = launchAt(at, PERIOD, 2);
        (uint256[] memory none, uint256 opensAt) = c.onSale();
        assertEq(none.length, 0);
        assertEq(opensAt, at);
        vm.expectRevert(ElyfishSkins.NotStarted.selector);
        c.round();
        for (uint256 i = 0; i < SKINS; i++) {
            assertFalse(c.isOpen(i));
            uint256 cost = c.hypePrice(i, 1);
            vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotOnSale.selector, i));
            vm.prank(alice);
            c.mint{value: cost}(i, 1);
        }
        goTo(at);
        (uint256 a,) = pairOf(c);
        uint256 costA = c.hypePrice(a, 1);
        vm.prank(alice);
        c.mint{value: costA}(a, 1);
        checkRotation(c, rarities);
    }

    function test_TheSettingsMustMakeSense() public {
        vm.expectRevert(ElyfishSkins.BadSchedule.selector);
        launchAt(0, 0, 2);
        vm.expectRevert(ElyfishSkins.BadSchedule.selector);
        launchAt(0, 30 days + 1, 2);
        vm.expectRevert(ElyfishSkins.BadSchedule.selector);
        launchAt(0, PERIOD, 0);
        launchAt(0, 30 days, 2);
        launchAt(0, 1, 1);
    }

    function test_UnknownSkinsAreNotOnSale() public {
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.UnknownSkin.selector, SKINS));
        fresh.isOpen(SKINS);
    }

    /// with so many a round that all fit, everything is on sale all the time (how the other test files run)
    function test_ARoundBigEnoughHoldsEverySkin() public {
        ElyfishSkins c = launchAt(0, PERIOD, 10_000);
        assertEq(c.cycle(), 1);
        (uint256[] memory ids,) = c.onSale();
        assertEq(ids.length, SKINS);
        vm.warp(block.timestamp + 500 days);
        for (uint256 i = 0; i < SKINS; i++) assertTrue(c.isOpen(i));
    }

    /// the order comes from the block the collection is deployed in: another block, another order
    function test_TheOrderIsShuffledByTheDeploymentBlock() public {
        vm.warp(block.timestamp + 12);
        vm.prevrandao(bytes32(uint256(777)));
        ElyfishSkins other = launchAt(fresh.launch(), PERIOD, 2);
        uint256 same;
        uint256 inListOrder;
        for (uint256 r = 0; r < ROUNDS; r++) {
            vm.warp(startOf(fresh, r));
            (uint256 a, uint256 b) = pairOf(fresh);
            (uint256 c, uint256 d) = pairOf(other);
            if (a == c && b == d) same++;
            if (a == 2 * r && b == 2 * r + 1) inListOrder++;
        }
        assertLt(same, ROUNDS, "a different order");
        assertLt(inListOrder, 3, "not the list's own order");
        checkRotation(other, rarities);
    }

    /// nothing the owner can do moves a round or puts another skin on sale
    function test_TheOwnerCannotMoveTheRotation() public {
        (uint256 a, uint256 b) = pairOf(fresh);
        vm.startPrank(owner);
        fresh.setPrice(0, 0);
        fresh.setPriceFeed(address(feed), 7 days);
        fresh.setBaseURI("https://cdn.elyfish.xyz/nft/v2/");
        fresh.setContractURI("x");
        fresh.setRoyalty(owner, 100);
        fresh.refreshMetadata(1, 10_000);
        fresh.pause();
        fresh.unpause();
        fresh.withdraw(payable(treasury));
        fresh.transferOwnership(alice);
        vm.stopPrank();
        vm.prank(alice);
        fresh.acceptOwnership();
        (uint256 c, uint256 d) = pairOf(fresh);
        assertEq(a, c);
        assertEq(b, d);
        // free tokens of a skin that is not on sale: not even at price 0, not even for the owner
        uint256 id = 27;   // the common skin (never in the first round)
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotOnSale.selector, id));
        vm.prank(alice);
        fresh.reserveMint(alice, id, 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotOnSale.selector, id));
        vm.prank(bob);
        fresh.mint(id, 1);
        checkRotation(fresh, rarities);
    }

    // ------------------------------------------------------------------ fuzz

    /// any launch, any round length, any number a round, any deployment block: the rotation is whole
    function testFuzz_TheRotationIsWhole(uint64 at, uint64 every, uint16 each, uint256 randao, uint64 deployedAt) public {
        deployedAt = uint64(bound(deployedAt, 1_700_000_000, 4_000_000_000));
        at = uint64(bound(at, 0, 4_100_000_000));
        every = uint64(bound(every, 2, 30 days));
        each = uint16(bound(each, 1, 50));
        vm.warp(deployedAt);
        vm.prevrandao(bytes32(randao));
        ElyfishSkins c = launchAt(at, every, each);
        assertEq(c.launch(), at == 0 ? deployedAt : at);
        checkRotation(c, rarities);
    }

    /// at any moment: exactly the round's skins are on sale, the round is the one the clock says, and a paid mint
    /// (or the owner's free one) goes through exactly for those
    function testFuzz_MintFollowsTheRotation(uint256 skinId, uint256 t, uint256 qty) public {
        skinId = bound(skinId, 0, SKINS - 1);
        qty = bound(qty, 1, 20);
        t = bound(t, block.timestamp, block.timestamp + 3 * ROUNDS * 7 days);
        goTo(t);
        uint256 r = (t - fresh.launch()) / 7 days;
        assertEq(fresh.round(), r);
        (uint256[] memory ids, uint256 closesAt) = fresh.onSale();
        assertEq(ids.length, 2);
        assertEq(closesAt, startOf(fresh, r + 1));
        assertTrue(closesAt > t && closesAt - t <= 7 days);
        bool onSale = ids[0] == skinId || ids[1] == skinId;
        assertEq(fresh.isOpen(skinId), onSale);
        uint256 cost = fresh.hypePrice(skinId, qty);
        if (!onSale) vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotOnSale.selector, skinId));
        vm.prank(alice);
        fresh.mint{value: cost}(skinId, qty);
        assertEq(fresh.totalSupply(), onSale ? qty : 0);
        assertEq(address(fresh).balance, onSale ? cost : 0);
        if (!onSale) vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotOnSale.selector, skinId));
        vm.prank(owner);
        fresh.reserveMint(bob, skinId, 1);
        assertEq(fresh.balanceOf(bob), onSale ? 1 : 0);
    }

    /// any collection (any number of skins, any rarities), any number a round: the same rules hold
    function testFuzz_AnyCollectionRotatesWhole(uint256 n, uint256 seed, uint64 every, uint16 each) public {
        n = bound(n, 1, 60);
        every = uint64(bound(every, 2, 30 days));
        each = uint16(bound(each, 1, 9));
        ElyfishSkins c = anyCollection(n, seed, every, each);
        checkRotation(c, anyRarities);
    }

    uint8[] internal anyKinds;
    uint8[] internal anyRarities;
    uint16[] internal anySupplies;

    /// n skins of random kinds and rarities (one token each, the last one takes the rest of the 10,000)
    function anyCollection(uint256 n, uint256 seed, uint64 every, uint16 each) internal returns (ElyfishSkins c) {
        delete anyKinds;
        delete anyRarities;
        delete anySupplies;
        for (uint256 i = 0; i < n; i++) {
            seed = uint256(keccak256(abi.encode(seed)));
            anyKinds.push(uint8(seed % 2));
            anyRarities.push(uint8((seed >> 8) % 5));
            anySupplies.push(i + 1 < n ? 1 : uint16(10_000 - (n - 1)));
        }
        vm.prevrandao(bytes32(seed));
        c = new ElyfishSkins(owner, address(feed), 1 hours, BASE, CONTRACT, treasury, 500, anyKinds, anyRarities, anySupplies, saleAt(0, every, each));
    }
}

/// players and the owner trying to mint anything at any time while the clock moves through the rounds
contract ScheduleHandler is Test {
    ElyfishSkins public nft;
    MockPriceFeed public feed;
    address public owner;
    address[] public players;
    uint256 public offSaleMints;    // mints (paid or the owner's) of a skin that was not on sale: must stay 0
    uint256 public wronglyRefused;  // paid mints of a skin on sale with stock, fresh price, not paused, refused: must stay 0
    uint256 public minted;
    uint256 public refusedOffSale;  // (how often the rotation really said no)
    uint256 public changedMidRound; // times a round's skins were seen to change inside that round: must stay 0
    uint256 public notAsLastCycle;  // times a round's skins differed from the same round a cycle before: must stay 0
    mapping(uint256 => bytes32) public seenInRound;   // round → hash of the skins seen on sale in it
    mapping(uint256 => uint256) public mintedInTurn;  // skin → tokens minted (all in its own rounds)

    constructor(ElyfishSkins n, MockPriceFeed f, address o) {
        nft = n;
        feed = f;
        owner = o;
        for (uint256 i = 0; i < 3; i++) players.push(makeAddr(string.concat("angler", vm.toString(i))));
    }

    function _look() private {
        (uint256[] memory ids,) = nft.onSale();
        bytes32 h = keccak256(abi.encode(ids));
        uint256 r = nft.round();
        if (seenInRound[r] == bytes32(0)) seenInRound[r] = h;
        else if (seenInRound[r] != h) changedMidRound++;
        uint256 c = nft.cycle();
        if (r >= c && seenInRound[r - c] != bytes32(0) && seenInRound[r - c] != h) notAsLastCycle++;
    }

    function _onSale(uint256 skinId) private view returns (bool) {
        (uint256[] memory ids,) = nft.onSale();
        for (uint256 i = 0; i < ids.length; i++) if (ids[i] == skinId) return true;
        return false;
    }

    /// (half the tries go for a skin that is on sale, so that tokens really are minted)
    function _pick(uint256 skinId) private view returns (uint256) {
        if (skinId % 2 == 0) return bound(skinId / 2, 0, 41);
        (uint256[] memory ids,) = nft.onSale();
        return ids[(skinId / 2) % ids.length];
    }

    function mint(uint256 who, uint256 skinId, uint256 qty) external {
        address p = players[who % players.length];
        skinId = _pick(skinId);
        qty = bound(qty, 1, 20);
        vm.prank(owner);
        feed.setAnswer(25e8);   // (a fresh price: the only things in the way are the rotation, the stock or a pause)
        uint256 cost = nft.hypePrice(skinId, qty);
        bool onSale = _onSale(skinId);
        bool stock = nft.remaining(skinId) >= qty;
        vm.deal(p, cost);
        vm.prank(p);
        try nft.mint{value: cost}(skinId, qty) {
            minted += qty;
            mintedInTurn[skinId] += qty;
            if (!onSale) offSaleMints++;
        } catch {
            if (onSale && stock && !nft.paused()) wronglyRefused++;
            if (!onSale) refusedOffSale++;
        }
        _look();
    }

    function reserve(uint256 who, uint256 skinId, uint256 qty) external {
        skinId = _pick(skinId);
        qty = bound(qty, 1, 20);
        bool onSale = _onSale(skinId);
        vm.prank(owner);
        try nft.reserveMint(players[who % players.length], skinId, qty) {
            minted += qty;
            mintedInTurn[skinId] += qty;
            if (!onSale) offSaleMints++;
        } catch {
            if (!onSale) refusedOffSale++;
        }
        _look();
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 16 days));
        _look();
    }

    function togglePause(bool on) external {
        vm.prank(owner);
        if (on) { try nft.pause() {} catch {} } else { try nft.unpause() {} catch {} }
    }

    /// the owner's other buttons: none of them may touch the rotation
    function ownerButtons(uint256 what, uint256 v) external {
        vm.startPrank(owner);
        uint256 w = what % 4;
        if (w == 0) { try nft.setPrice(uint8(v % 5), bound(v, 0, 1_000e8)) {} catch {} }
        else if (w == 1) { try nft.setPriceFeed(address(feed), bound(v, 1, 7 days)) {} catch {} }
        else if (w == 2) { nft.setBaseURI("https://cdn.elyfish.xyz/nft/v9/"); }
        else { nft.withdraw(payable(owner)); }
        vm.stopPrank();
        _look();
    }
}

contract ScheduleInvariantTest is Base {
    ElyfishSkins internal fresh;
    ScheduleHandler internal h;
    uint256 internal start;
    uint256[] internal turnOf;   // skin → its round of the cycle, read once at the start

    function setUp() public override {
        super.setUp();
        fresh = new ElyfishSkins(owner, address(feed), 1 hours, BASE, CONTRACT, treasury, 500, kinds, rarities, supplies, saleAt(0, PERIOD, 2));
        start = block.timestamp;
        for (uint256 i = 0; i < 42; i++) turnOf.push(type(uint256).max);
        for (uint256 r = 0; r < 21; r++) {
            vm.warp(start + r * 7 days);
            (uint256[] memory ids,) = fresh.onSale();
            for (uint256 k = 0; k < ids.length; k++) turnOf[ids[k]] = r;
        }
        vm.warp(start);
        h = new ScheduleHandler(fresh, feed, owner);
        targetContract(address(h));
    }

    /// nothing was ever minted while its skin was not on sale — by a buyer or by the owner
    function invariant_NothingMintsOffSale() public view {
        assertEq(h.offSaleMints(), 0);
        uint256 sum;
        for (uint256 i = 0; i < 42; i++) {
            assertEq(fresh.skin(i).minted, h.mintedInTurn(i));
            sum += fresh.skin(i).minted;
        }
        assertEq(sum, h.minted());
    }

    /// a skin on sale with stock is never refused to a buyer who pays (unless the sale is paused)
    function invariant_SkinsOnSaleAreNeverRefused() public view {
        assertEq(h.wronglyRefused(), 0);
    }

    /// a round's skins never change inside the round, and every cycle brings the same skins back in the same rounds
    function invariant_TheRotationNeverChanges() public view {
        assertEq(h.changedMidRound(), 0);
        assertEq(h.notAsLastCycle(), 0);
        assertEq(fresh.launch(), start);
        assertEq(fresh.period(), 7 days);
        assertEq(fresh.perRound(), 2);
        assertEq(fresh.cycle(), 21);
    }

    /// at any time exactly two skins are on sale: the two whose round of the cycle the clock says it is
    function invariant_TwoSkinsOnSaleByTheClock() public view {
        uint256 r = ((block.timestamp - start) / 7 days) % 21;
        (uint256[] memory ids, uint256 closesAt) = fresh.onSale();
        assertEq(ids.length, 2);
        assertEq(closesAt, start + ((block.timestamp - start) / 7 days + 1) * 7 days);
        uint256 open;
        for (uint256 i = 0; i < 42; i++) {
            bool isOpen = fresh.isOpen(i);
            assertEq(isOpen, turnOf[i] == r);
            if (isOpen) open++;
        }
        assertEq(open, 2);
        assertEq(turnOf[ids[0]], r);
        assertEq(turnOf[ids[1]], r);
    }
}
