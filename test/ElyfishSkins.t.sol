// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {ElyfishSkins} from "../src/ElyfishSkins.sol";
import {MockPriceFeed} from "../src/testnet/MockPriceFeed.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// takes tokens, and on each one tries to mint again (a re-entrance must fail)
contract Reenterer is IERC721Receiver {
    ElyfishSkins public nft;
    bool public tried;
    bool public succeeded;

    constructor(ElyfishSkins n) {
        nft = n;
    }

    function go(uint256 skinId) external payable {
        nft.mint{value: msg.value}(skinId, 1);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (!tried) {
            tried = true;
            try nft.mint{value: 0}(0, 1) { succeeded = true; } catch {}
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// a contract that can't take tokens or coins
contract Rock {
    function go(ElyfishSkins nft, uint256 skinId) external payable {
        nft.mint{value: msg.value}(skinId, 1);
    }
}

/// takes tokens but refuses coins (its refund must make its own mint fail, not lose the money)
contract NoCoins is IERC721Receiver {
    function go(ElyfishSkins nft, uint256 skinId) external payable {
        nft.mint{value: msg.value}(skinId, 1);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// a feed with 30 decimals (not allowed)
contract WideFeed {
    function decimals() external pure returns (uint8) {
        return 30;
    }
}

contract ElyfishSkinsTest is Base {
    // ------------------------------------------------------------------ the collection as deployed

    function test_Setup() public view {
        assertEq(nft.name(), "Elyfish");
        assertEq(nft.symbol(), "ELYFISH");
        assertEq(nft.owner(), owner);
        assertEq(nft.skinCount(), 42);
        assertEq(nft.totalSupply(), 0);
        assertEq(address(nft.priceFeed()), address(feed));
        assertEq(nft.maxStaleness(), 1 hours);
        assertEq(nft.contractURI(), CONTRACT);
        uint256 total;
        for (uint256 i = 0; i < 42; i++) {
            ElyfishSkins.Skin memory s = nft.skin(i);
            assertEq(s.start, total + 1, "blocks follow each other");
            assertEq(s.supply, supplies[i]);
            assertEq(s.kind, kinds[i]);
            assertEq(s.rarity, rarities[i]);
            total += s.supply;
        }
        assertEq(total, 10_000);
        for (uint8 r = 0; r < 5; r++) assertEq(nft.usdPrice(r), prices[r]);
        ElyfishSkins.Skin[] memory all = nft.allSkins();
        assertEq(all.length, 42);
        for (uint256 i = 0; i < 42; i++) assertEq(all[i].start, nft.skin(i).start);
    }

    function test_SupportsInterfaces() public view {
        assertTrue(nft.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(nft.supportsInterface(0x5b5e139f)); // metadata
        assertTrue(nft.supportsInterface(0x2a55205a)); // ERC-2981
        assertTrue(nft.supportsInterface(0x49064906)); // ERC-4906
        assertTrue(nft.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(nft.supportsInterface(0xffffffff));
    }

    function test_ConstructorRejectsBadSkins() public {
        uint8[] memory k = new uint8[](1);
        uint8[] memory r = new uint8[](1);
        uint16[] memory s = new uint16[](1);
        s[0] = 10_000;
        // fine: one skin of all 10,000
        new ElyfishSkins(owner, address(feed), 1 hours, BASE, CONTRACT, treasury, 500, k, r, s, prices);
        // not adding up to 10,000
        s[0] = 9_999;
        vm.expectRevert(ElyfishSkins.BadSkins.selector);
        new ElyfishSkins(owner, address(feed), 1 hours, BASE, CONTRACT, treasury, 500, k, r, s, prices);
        // no skins / lengths that don't match
        vm.expectRevert(ElyfishSkins.BadSkins.selector);
        new ElyfishSkins(owner, address(feed), 1 hours, BASE, CONTRACT, treasury, 500, new uint8[](0), new uint8[](0), new uint16[](0), prices);
        vm.expectRevert(ElyfishSkins.BadSkins.selector);
        new ElyfishSkins(owner, address(feed), 1 hours, BASE, CONTRACT, treasury, 500, k, new uint8[](2), s, prices);
        // a bad kind / rarity / an empty skin / more than 10,000
        s[0] = 10_000;
        k[0] = 2;
        vm.expectRevert(ElyfishSkins.BadSkins.selector);
        new ElyfishSkins(owner, address(feed), 1 hours, BASE, CONTRACT, treasury, 500, k, r, s, prices);
        k[0] = 0;
        r[0] = 5;
        vm.expectRevert(ElyfishSkins.BadSkins.selector);
        new ElyfishSkins(owner, address(feed), 1 hours, BASE, CONTRACT, treasury, 500, k, r, s, prices);
        r[0] = 0;
        s[0] = 0;
        vm.expectRevert(ElyfishSkins.BadSkins.selector);
        new ElyfishSkins(owner, address(feed), 1 hours, BASE, CONTRACT, treasury, 500, k, r, s, prices);
        uint8[] memory k2 = new uint8[](2);
        uint8[] memory r2 = new uint8[](2);
        uint16[] memory s2 = new uint16[](2);
        s2[0] = 10_000;
        s2[1] = 1;
        vm.expectRevert(ElyfishSkins.BadSkins.selector);
        new ElyfishSkins(owner, address(feed), 1 hours, BASE, CONTRACT, treasury, 500, k2, r2, s2, prices);
    }

    function test_ConstructorRejectsBadSettings() public {
        vm.expectRevert(ElyfishSkins.BadFeed.selector);
        new ElyfishSkins(owner, address(0), 1 hours, BASE, CONTRACT, treasury, 500, kinds, rarities, supplies, prices);
        vm.expectRevert(ElyfishSkins.BadFeed.selector);
        new ElyfishSkins(owner, address(feed), 0, BASE, CONTRACT, treasury, 500, kinds, rarities, supplies, prices);
        vm.expectRevert(ElyfishSkins.BadRoyalty.selector);
        new ElyfishSkins(owner, address(feed), 1 hours, BASE, CONTRACT, treasury, 1_001, kinds, rarities, supplies, prices);
        uint256[5] memory p = prices;
        p[4] = 100_001e8;
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.PriceTooHigh.selector, 100_001e8));
        new ElyfishSkins(owner, address(feed), 1 hours, BASE, CONTRACT, treasury, 500, kinds, rarities, supplies, p);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ElyfishSkins(address(0), address(feed), 1 hours, BASE, CONTRACT, treasury, 500, kinds, rarities, supplies, prices);
    }

    // ------------------------------------------------------------------ minting

    function test_MintPaysAndGivesTheRightTokens() public {
        uint256 cost = nft.hypePrice(2, 3);   // a legendary rod: $50 each at $25 = 2 HYPE each
        assertEq(cost, 6 ether);
        uint256 before = alice.balance;
        vm.expectEmit(true, true, false, true);
        emit ElyfishSkins.SkinsMinted(alice, 2, 101, 3, 6 ether);
        vm.prank(alice);
        nft.mint{value: 7 ether}(2, 3);
        assertEq(alice.balance, before - 6 ether, "the extra HYPE came back");
        assertEq(address(nft).balance, 6 ether);
        assertEq(nft.totalSupply(), 3);
        assertEq(nft.remaining(2), 47);
        for (uint256 id = 101; id <= 103; id++) {
            assertEq(nft.ownerOf(id), alice);
            (uint256 skinId, uint256 serial) = nft.skinOfToken(id);
            assertEq(skinId, 2);
            assertEq(serial, id - 100);
            assertEq(nft.tokenURI(id), string.concat(BASE, vm.toString(id), ".json"));
        }
        assertEq(nft.balanceOf(alice), 3);
    }

    function test_MintRejects() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.BadQuantity.selector, 0));
        nft.mint{value: 1 ether}(0, 0);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.BadQuantity.selector, 21));
        nft.mint{value: 100 ether}(0, 21);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.UnknownSkin.selector, 42));
        nft.mint{value: 100 ether}(42, 1);
        uint256 cost = nft.hypePrice(0, 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.Underpaid.selector, cost, cost - 1));
        nft.mint{value: cost - 1}(0, 1);
        vm.stopPrank();
    }

    function test_SoldOut() public {
        // the first legendary rod: 50 tokens
        vm.startPrank(alice);
        nft.mint{value: 100 ether}(0, 20);
        nft.mint{value: 100 ether}(0, 20);
        nft.mint{value: 100 ether}(0, 10);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.SoldOut.selector, 0, 0));
        nft.mint{value: 100 ether}(0, 1);
        vm.stopPrank();
        assertEq(nft.remaining(0), 0);
        assertEq(nft.ownerOf(50), alice);
        (uint256 skinId,) = nft.skinOfToken(51);
        assertEq(skinId, 1, "the next block is the next skin");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 51));
        nft.ownerOf(51);
    }

    function test_FreeRarityNeedsNoFeed() public {
        vm.prank(owner);
        nft.setPrice(0, 0);   // commons free
        vm.mockCallRevert(address(nft.priceFeed()), abi.encodeWithSignature("latestRoundData()"), "feed down");
        uint256 commonSkin = 27;   // Fossil Rod
        assertEq(nft.skin(commonSkin).rarity, 0);
        assertEq(nft.hypePrice(commonSkin, 5), 0);
        vm.prank(alice);
        nft.mint(commonSkin, 5);
        assertEq(nft.balanceOf(alice), 5);
    }

    function test_ReserveMint() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.reserveMint(alice, 0, 1);
        vm.startPrank(owner);
        vm.expectRevert(ElyfishSkins.ZeroAddress.selector);
        nft.reserveMint(address(0), 0, 1);
        nft.reserveMint(bob, 41, 20);
        vm.stopPrank();
        assertEq(nft.balanceOf(bob), 20);
        assertEq(address(nft).balance, 0);
        ElyfishSkins.Skin memory s = nft.skin(41);
        assertEq(nft.ownerOf(s.start), bob);
    }

    function test_MintPaused() public {
        vm.prank(owner);
        nft.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        nft.mint{value: 10 ether}(0, 1);
        vm.prank(owner);
        nft.unpause();
        vm.prank(alice);
        nft.mint{value: 10 ether}(0, 1);
        assertEq(nft.totalSupply(), 1);
    }

    function test_ReentranceFails() public {
        Reenterer r = new Reenterer(nft);
        vm.deal(address(r), 0);
        r.go{value: 10 ether}(0);
        assertTrue(r.tried());
        assertFalse(r.succeeded(), "a mint inside a mint must fail");
        assertEq(nft.totalSupply(), 1);
    }

    function test_ContractsThatCantHoldTokensCantMint() public {
        Rock rock = new Rock();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(rock)));
        rock.go{value: 10 ether}(nft, 0);
        assertEq(nft.totalSupply(), 0);
    }

    function test_RefundThatCantBePaidUndoesTheMint() public {
        NoCoins nc = new NoCoins();
        vm.expectRevert(ElyfishSkins.TransferFailed.selector);
        nc.go{value: 10 ether}(nft, 0);   // overpays: the refund fails, so nothing happens
        assertEq(nft.totalSupply(), 0);
        uint256 cost = nft.hypePrice(0, 1);
        nc.go{value: cost}(nft, 0);   // exact: no refund needed
        assertEq(nft.totalSupply(), 1);
    }

    // ------------------------------------------------------------------ the price feed

    function test_PriceFollowsTheFeed() public {
        assertEq(nft.hypePrice(0, 1), 2 ether);   // $50 at $25
        vm.prank(owner);
        feed.setAnswer(50e8);
        assertEq(nft.hypePrice(0, 1), 1 ether);   // at $50
        vm.prank(owner);
        feed.setAnswer(3e8);
        assertEq(nft.hypePrice(0, 1), 16666666666666666667);   // $50 / $3, rounded up
        (uint256 rate, uint8 dec) = nft.hypeUsd();
        assertEq(rate, 3e8);
        assertEq(dec, 8);
    }

    function test_BadOrOldPricesStopMints() public {
        vm.prank(owner);
        feed.setAnswer(0);
        vm.expectRevert(ElyfishSkins.BadPrice.selector);
        nft.hypePrice(0, 1);
        vm.prank(owner);
        feed.setAnswer(-1);
        vm.expectRevert(ElyfishSkins.BadPrice.selector);
        nft.hypePrice(0, 1);
        vm.prank(owner);
        feed.setAnswer(25e8);
        uint256 at = block.timestamp;
        vm.warp(at + 1 hours);
        nft.hypePrice(0, 1);   // exactly as old as allowed: fine
        vm.warp(at + 1 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.StalePrice.selector, at));
        nft.hypePrice(0, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.StalePrice.selector, at));
        nft.mint{value: 100 ether}(0, 1);
    }

    function test_UnfinishedOrFutureRoundsAreRefused() public {
        // answeredInRound behind the round
        vm.mockCall(address(feed), abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(5), int256(25e8), uint256(0), block.timestamp, uint80(4)));
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.StalePrice.selector, block.timestamp));
        nft.hypePrice(0, 1);
        // never updated
        vm.mockCall(address(feed), abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(5), int256(25e8), uint256(0), uint256(0), uint80(5)));
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.StalePrice.selector, 0));
        nft.hypePrice(0, 1);
        // from the future
        vm.mockCall(address(feed), abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(5), int256(25e8), uint256(0), block.timestamp + 1, uint80(5)));
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.StalePrice.selector, block.timestamp + 1));
        nft.hypePrice(0, 1);
    }

    function test_FeedWithOtherDecimals() public {
        MockPriceFeed f18 = new MockPriceFeed(owner, 18, 25e18, "HYPE / USD 18");
        vm.prank(owner);
        nft.setPriceFeed(address(f18), 2 hours);
        assertEq(nft.hypePrice(0, 1), 2 ether);
        MockPriceFeed f0 = new MockPriceFeed(owner, 0, 25, "HYPE / USD 0");
        vm.prank(owner);
        nft.setPriceFeed(address(f0), 2 hours);
        assertEq(nft.hypePrice(0, 1), 2 ether);
    }

    // ------------------------------------------------------------------ the owner's settings

    function test_OnlyTheOwnerChangesSettings() public {
        bytes memory no = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(no);
        nft.setPrice(0, 1);
        vm.expectRevert(no);
        nft.setPriceFeed(address(feed), 1);
        vm.expectRevert(no);
        nft.setBaseURI("x");
        vm.expectRevert(no);
        nft.setContractURI("x");
        vm.expectRevert(no);
        nft.refreshMetadata(1, 2);
        vm.expectRevert(no);
        nft.setRoyalty(alice, 1);
        vm.expectRevert(no);
        nft.pause();
        vm.expectRevert(no);
        nft.unpause();
        vm.expectRevert(no);
        nft.withdraw(payable(alice));
        vm.stopPrank();
    }

    function test_SetPrice() public {
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit ElyfishSkins.PriceSet(4, 100e8);
        nft.setPrice(4, 100e8);
        assertEq(nft.usdPrice(4), 100e8);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.BadRarity.selector, 5));
        nft.setPrice(5, 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.PriceTooHigh.selector, 100_000e8 + 1));
        nft.setPrice(0, 100_000e8 + 1);
        vm.stopPrank();
    }

    function test_SetPriceFeed() public {
        MockPriceFeed f = new MockPriceFeed(owner, 8, 30e8, "x");
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit ElyfishSkins.PriceFeedSet(address(f), 2 days);
        nft.setPriceFeed(address(f), 2 days);
        assertEq(address(nft.priceFeed()), address(f));
        assertEq(nft.maxStaleness(), 2 days);
        vm.expectRevert(ElyfishSkins.BadFeed.selector);
        nft.setPriceFeed(address(0), 1 hours);
        vm.expectRevert(ElyfishSkins.BadFeed.selector);
        nft.setPriceFeed(address(f), 0);
        vm.expectRevert(ElyfishSkins.BadFeed.selector);
        nft.setPriceFeed(address(f), 7 days + 1);
        WideFeed w = new WideFeed();
        vm.expectRevert(ElyfishSkins.BadFeed.selector);
        nft.setPriceFeed(address(w), 1 hours);
        vm.stopPrank();
    }

    function test_MetadataSettings() public {
        vm.prank(alice);
        nft.mint{value: 10 ether}(0, 1);
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true);
        emit ElyfishSkins.BaseURISet("https://cdn.elyfish.xyz/nft/v2/");
        vm.expectEmit(false, false, false, true);
        emit IERC4906.BatchMetadataUpdate(1, 10_000);
        nft.setBaseURI("https://cdn.elyfish.xyz/nft/v2/");
        assertEq(nft.tokenURI(1), "https://cdn.elyfish.xyz/nft/v2/1.json");
        vm.expectEmit(false, false, false, false);
        emit ElyfishSkins.ContractURIUpdated();
        nft.setContractURI("https://cdn.elyfish.xyz/nft/v2/collection.json");
        assertEq(nft.contractURI(), "https://cdn.elyfish.xyz/nft/v2/collection.json");
        vm.expectEmit(false, false, false, true);
        emit IERC4906.MetadataUpdate(7);
        nft.refreshMetadata(7, 7);
        vm.expectEmit(false, false, false, true);
        emit IERC4906.BatchMetadataUpdate(3, 9);
        nft.refreshMetadata(3, 9);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotAToken.selector, 0));
        nft.refreshMetadata(0, 9);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotAToken.selector, 9));
        nft.refreshMetadata(9, 3);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotAToken.selector, 1));
        nft.refreshMetadata(1, 10_001);
        vm.stopPrank();
    }

    function test_TokenURIOnlyForMintedTokens() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        nft.tokenURI(1);
    }

    function test_Royalty() public {
        (address to, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(to, treasury);
        assertEq(amount, 0.05 ether);
        vm.startPrank(owner);
        nft.setRoyalty(bob, 1_000);
        (to, amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(to, bob);
        assertEq(amount, 0.1 ether);
        vm.expectRevert(ElyfishSkins.BadRoyalty.selector);
        nft.setRoyalty(bob, 1_001);
        vm.expectRevert(ElyfishSkins.BadRoyalty.selector);
        nft.setRoyalty(address(0), 100);
        vm.stopPrank();
    }

    function test_Withdraw() public {
        vm.prank(alice);
        nft.mint{value: 2 ether}(0, 1);
        vm.startPrank(owner);
        vm.expectRevert(ElyfishSkins.ZeroAddress.selector);
        nft.withdraw(payable(address(0)));
        vm.expectEmit(true, false, false, true);
        emit ElyfishSkins.Withdrawn(treasury, 2 ether);
        nft.withdraw(payable(treasury));
        vm.stopPrank();
        assertEq(treasury.balance, 2 ether);
        assertEq(address(nft).balance, 0);
        Rock rock = new Rock();
        vm.deal(address(nft), 1 ether);
        vm.prank(owner);
        vm.expectRevert(ElyfishSkins.TransferFailed.selector);
        nft.withdraw(payable(address(rock)));
    }

    function test_PlainCoinsAreRefused() public {
        vm.prank(alice);
        (bool ok,) = address(nft).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_OwnershipMovesInTwoSteps() public {
        vm.prank(owner);
        nft.transferOwnership(alice);
        assertEq(nft.owner(), owner, "not until accepted");
        vm.prank(alice);
        nft.acceptOwnership();
        assertEq(nft.owner(), alice);
    }

    function test_SkinOfTokenEdges() public {
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotAToken.selector, 0));
        nft.skinOfToken(0);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotAToken.selector, 10_001));
        nft.skinOfToken(10_001);
        (uint256 s, uint256 serial) = nft.skinOfToken(1);
        assertEq(s, 0);
        assertEq(serial, 1);
        (s, serial) = nft.skinOfToken(10_000);
        assertEq(s, 41);
        assertEq(serial, supplies[41]);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.UnknownSkin.selector, 42));
        nft.skin(42);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.UnknownSkin.selector, 42));
        nft.remaining(42);
    }

    function test_MockFeed() public {
        assertEq(feed.version(), 1);
        assertEq(feed.description(), "HYPE / USD");
        (uint80 round,,,,) = feed.latestRoundData();
        (, int256 answer,,,) = feed.getRoundData(round);
        assertEq(answer, 25e8);
        vm.expectRevert("only the latest round");
        feed.getRoundData(round + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        feed.setAnswer(1);
    }

    // ------------------------------------------------------------------ fuzz

    /// any skin, any quantity, any HYPE rate: the cost is the dollars at that rate rounded up, the buyer pays exactly
    /// that, gets the next ids of that skin's block and the rest of the HYPE back
    function testFuzz_MintCost(uint256 skinId, uint256 qty, int256 rate, uint256 extra) public {
        skinId = bound(skinId, 0, 41);
        qty = bound(qty, 1, 20);
        rate = int256(bound(uint256(rate), 1, 1_000_000e8));   // $0.00000001 .. $1,000,000 a HYPE
        extra = bound(extra, 0, 100 ether);
        vm.prank(owner);
        feed.setAnswer(rate);
        uint256 cost = nft.hypePrice(skinId, qty);
        assertEq(cost, expectedCost(skinId, qty));
        // never less than the dollars are worth: cost · rate ≥ usd (in the same units)
        assertGe(cost * uint256(rate), prices[rarities[skinId]] * qty * 1e18);
        vm.deal(alice, cost + extra);
        vm.prank(alice);
        nft.mint{value: cost + extra}(skinId, qty);
        assertEq(alice.balance, extra);
        assertEq(address(nft).balance, cost);
        ElyfishSkins.Skin memory s = nft.skin(skinId);
        assertEq(s.minted, qty);
        for (uint256 i = 0; i < qty; i++) assertEq(nft.ownerOf(s.start + i), alice);
    }

    /// paying any amount below the cost never mints
    function testFuzz_UnderpayFails(uint256 skinId, uint256 qty, uint256 short) public {
        skinId = bound(skinId, 0, 41);
        qty = bound(qty, 1, 20);
        uint256 cost = nft.hypePrice(skinId, qty);
        short = bound(short, 1, cost);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.Underpaid.selector, cost, cost - short));
        nft.mint{value: cost - short}(skinId, qty);
        assertEq(nft.totalSupply(), 0);
    }

    /// any token id 1..10,000 maps to the one skin whose block holds it, with the right serial
    function testFuzz_SkinOfToken(uint256 tokenId) public view {
        tokenId = bound(tokenId, 1, 10_000);
        (uint256 skinId, uint256 serial) = nft.skinOfToken(tokenId);
        ElyfishSkins.Skin memory s = nft.skin(skinId);
        assertGe(tokenId, s.start);
        assertLt(tokenId, uint256(s.start) + s.supply);
        assertEq(serial, tokenId - s.start + 1);
    }

    /// a bad quantity or skin is always refused
    function testFuzz_BadInputs(uint256 skinId, uint256 qty) public {
        vm.assume(skinId > 41 || qty == 0 || qty > 20);
        vm.prank(alice);
        vm.expectRevert();
        nft.mint{value: 1_000 ether}(skinId, qty);
    }

    /// any old answer past the limit is refused, any fresh one accepted
    function testFuzz_Staleness(uint256 age, uint256 limit) public {
        limit = bound(limit, 1, 7 days);
        age = bound(age, 0, 30 days);
        vm.prank(owner);
        nft.setPriceFeed(address(feed), limit);
        vm.prank(owner);
        feed.setAnswer(25e8);
        uint256 at = block.timestamp;
        vm.warp(at + age);
        if (age > limit) vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.StalePrice.selector, at));
        nft.hypePrice(0, 1);
    }

    /// any royalty up to 10 % pays exactly that share; more is refused
    function testFuzz_Royalty(uint96 bps, uint256 sale) public {
        sale = bound(sale, 0, 1e30);
        vm.prank(owner);
        if (bps > 1_000) {
            vm.expectRevert(ElyfishSkins.BadRoyalty.selector);
            nft.setRoyalty(bob, bps);
            return;
        }
        nft.setRoyalty(bob, bps);
        (address to, uint256 amount) = nft.royaltyInfo(1, sale);
        assertEq(to, bob);
        assertEq(amount, sale * bps / 10_000);
    }

    /// only the owner, whoever else calls
    function testFuzz_StrangersCantWithdraw(address who) public {
        vm.assume(who != owner);
        vm.deal(address(nft), 5 ether);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
        nft.withdraw(payable(who));
        assertEq(address(nft).balance, 5 ether);
    }
}
