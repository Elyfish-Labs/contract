// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {ElyfishSkins} from "../src/ElyfishSkins.sol";
import {MockPriceFeed} from "../src/testnet/MockPriceFeed.sol";

/// what players and the owner do, at random: mint (paying right, too little, too much), reserve, move the price,
/// let time pass, pause, withdraw, transfer tokens, and strangers trying the owner's buttons. It keeps its own books
/// (ghost variables) to check the contract's against.
contract Handler is Test {
    ElyfishSkins public nft;
    MockPriceFeed public feed;
    address public owner;
    address[] public players;
    uint256 public ghostPaid;       // HYPE the contract kept from mints
    uint256 public ghostWithdrawn;  // HYPE the owner took out
    uint256 public ghostMinted;     // tokens minted, by any way
    mapping(uint256 => uint256) public ghostSkinOf;   // token id → the skin it was minted as (+1; 0 = never minted)
    mapping(uint256 => uint256) public ghostMintedOf; // skin → how many minted
    uint256[] public mintedIds;
    uint256 public strangerWins;    // owner-only calls a stranger got through (must stay 0)
    uint256 public ghostOpenTries;  // mints tried while minting was open (not paused, fresh price, stock left)

    constructor(ElyfishSkins n, MockPriceFeed f, address o) {
        nft = n;
        feed = f;
        owner = o;
        for (uint256 i = 0; i < 4; i++) players.push(makeAddr(string.concat("player", vm.toString(i))));
    }

    function _player(uint256 seed) private view returns (address) {
        return players[seed % players.length];
    }

    function mint(uint256 who, uint256 skinId, uint256 qty, uint256 extra) external {
        address p = _player(who);
        skinId = bound(skinId, 0, 41);
        qty = bound(qty, 1, 20);
        extra = bound(extra, 0, 10 ether);
        uint256 cost;
        try nft.hypePrice(skinId, qty) returns (uint256 c) { cost = c; } catch { return; }   // (stale / paused feed: nothing)
        ElyfishSkins.Skin memory s = nft.skin(skinId);
        if (!nft.paused() && s.supply - s.minted >= qty) ghostOpenTries++;
        vm.deal(p, cost + extra);
        vm.prank(p);
        try nft.mint{value: cost + extra}(skinId, qty) {
            assertEq(p.balance, extra, "the extra came back");
            ghostPaid += cost;
            _record(skinId, s.start + s.minted, qty);
        } catch {
            assertEq(p.balance, cost + extra, "a refused mint keeps nothing");
        }
    }

    function underpay(uint256 who, uint256 skinId, uint256 qty, uint256 short) external {
        address p = _player(who);
        skinId = bound(skinId, 0, 41);
        qty = bound(qty, 1, 20);
        uint256 cost;
        try nft.hypePrice(skinId, qty) returns (uint256 c) { cost = c; } catch { return; }
        if (cost == 0) return;
        short = bound(short, 1, cost);
        vm.deal(p, cost - short);
        vm.prank(p);
        try nft.mint{value: cost - short}(skinId, qty) {
            fail();   // paying less must never mint
        } catch {}
    }

    function reserve(uint256 who, uint256 skinId, uint256 qty) external {
        skinId = bound(skinId, 0, 41);
        qty = bound(qty, 1, 20);
        ElyfishSkins.Skin memory s = nft.skin(skinId);
        vm.prank(owner);
        try nft.reserveMint(_player(who), skinId, qty) { _record(skinId, s.start + s.minted, qty); } catch {}
    }

    function setRate(uint256 rate) external {
        vm.prank(owner);
        feed.setAnswer(int256(bound(rate, 1e6, 10_000e8)));
    }

    function setPrice(uint8 rarity, uint256 usd) external {
        vm.prank(owner);
        try nft.setPrice(uint8(bound(rarity, 0, 4)), bound(usd, 0, 1_000e8)) {} catch {}
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 2 hours));
    }

    function togglePause(bool on) external {
        vm.prank(owner);
        if (on) { try nft.pause() {} catch {} } else { try nft.unpause() {} catch {} }
    }

    function withdraw() external {
        uint256 bal = address(nft).balance;
        address to = makeAddr("treasury");
        vm.prank(owner);
        nft.withdraw(payable(to));
        ghostWithdrawn += bal;
    }

    function transfer(uint256 which, uint256 to) external {
        if (mintedIds.length == 0) return;
        uint256 id = mintedIds[which % mintedIds.length];
        address from = nft.ownerOf(id);
        vm.prank(from);
        nft.transferFrom(from, _player(to), id);
    }

    /// a stranger pressing the owner's buttons: none may work
    function stranger(uint256 what, address who) external {
        if (who == owner) return;
        vm.startPrank(who);
        bool ok;
        uint256 w = what % 6;
        if (w == 0) { try nft.withdraw(payable(who)) { ok = true; } catch {} }
        else if (w == 1) { try nft.setPrice(0, 0) { ok = true; } catch {} }
        else if (w == 2) { try nft.reserveMint(who, 0, 1) { ok = true; } catch {} }
        else if (w == 3) { try nft.setPriceFeed(address(feed), 7 days) { ok = true; } catch {} }
        else if (w == 4) { try nft.pause() { ok = true; } catch {} }
        else { try nft.setBaseURI("https://evil/") { ok = true; } catch {} }
        vm.stopPrank();
        if (ok) strangerWins++;
    }

    function _record(uint256 skinId, uint256 first, uint256 qty) private {
        ghostMinted += qty;
        ghostMintedOf[skinId] += qty;
        for (uint256 i = 0; i < qty; i++) {
            ghostSkinOf[first + i] = skinId + 1;
            mintedIds.push(first + i);
        }
    }

    function mintedCount() external view returns (uint256) {
        return mintedIds.length;
    }
}

contract InvariantTest is Base {
    Handler internal h;

    function setUp() public override {
        super.setUp();
        h = new Handler(nft, feed, owner);
        targetContract(address(h));
    }

    /// minted tokens add up, per skin and in all, and never past a skin's supply or 10,000
    function invariant_SupplyAddsUp() public view {
        uint256 sum;
        for (uint256 i = 0; i < 42; i++) {
            ElyfishSkins.Skin memory s = nft.skin(i);
            assertLe(s.minted, s.supply);
            assertEq(s.minted, h.ghostMintedOf(i));
            assertEq(nft.remaining(i), uint256(s.supply) - s.minted);
            sum += s.minted;
        }
        assertEq(sum, nft.totalSupply());
        assertEq(nft.totalSupply(), h.ghostMinted());
        assertLe(nft.totalSupply(), nft.MAX_SUPPLY());
    }

    /// the contract holds exactly what mints paid minus what was withdrawn: no HYPE appears or vanishes
    function invariant_FundsAddUp() public view {
        assertEq(address(nft).balance, h.ghostPaid() - h.ghostWithdrawn());
    }

    /// every minted token exists, belongs to someone, and is the skin it was minted as (its id says so too)
    function invariant_TokensAreWhatTheyWereMintedAs() public view {
        uint256 n = h.mintedCount();
        uint256 owned;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = h.mintedIds(i);
            assertTrue(nft.ownerOf(id) != address(0));
            (uint256 skinId,) = nft.skinOfToken(id);
            assertEq(skinId + 1, h.ghostSkinOf(id));
        }
        for (uint256 p = 0; p < 4; p++) owned += nft.balanceOf(h.players(p));
        assertEq(owned, n, "all tokens are with the players");
    }

    /// within each skin the minted ids are exactly its lowest ones: nothing minted twice, none skipped
    function invariant_BlocksFillFromTheStart() public view {
        for (uint256 i = 0; i < 42; i++) {
            ElyfishSkins.Skin memory s = nft.skin(i);
            if (s.minted > 0) nft.ownerOf(s.start + s.minted - 1);   // the last minted exists
            if (s.minted < s.supply) {
                try nft.ownerOf(s.start + s.minted) returns (address) { revert("an id past the minted ones exists"); } catch {}
            }
        }
    }

    /// (each run really minted something: the checks above were not over an empty collection)
    /// the handler is not idle: a run that ever tried a mint while minting was open did mint (a run that paused
    /// first, or let the price go stale, could not — those prove the refusals instead)
    function afterInvariant() public view {
        if (h.ghostOpenTries() > 0) assertGt(h.ghostMinted(), 0);
    }

    /// nobody but the owner ever changed a setting or took the HYPE
    function invariant_OnlyTheOwner() public view {
        assertEq(h.strangerWins(), 0);
        assertEq(nft.owner(), owner);
    }
}
