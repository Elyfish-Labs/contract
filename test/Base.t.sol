// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ElyfishSkins} from "../src/ElyfishSkins.sol";
import {MockPriceFeed} from "../src/testnet/MockPriceFeed.sol";

/// the collection as it ships (skins.json), a $25 HYPE feed with 8 decimals, and some players with HYPE
abstract contract Base is Test {
    ElyfishSkins internal nft;
    MockPriceFeed internal feed;
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint8[] internal kinds;
    uint8[] internal rarities;
    uint16[] internal supplies;
    uint256[5] internal prices = [uint256(2e8), 5e8, 10e8, 20e8, 50e8];
    string internal constant BASE = "https://cdn.elyfish.xyz/nft/v1/";
    string internal constant CONTRACT = "https://cdn.elyfish.xyz/nft/v1/collection.json";

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        string memory json = vm.readFile("./skins.json");
        uint256[] memory k = vm.parseJsonUintArray(json, ".kinds");
        uint256[] memory r = vm.parseJsonUintArray(json, ".rarities");
        uint256[] memory s = vm.parseJsonUintArray(json, ".supplies");
        for (uint256 i = 0; i < k.length; i++) {
            kinds.push(uint8(k[i]));
            rarities.push(uint8(r[i]));
            supplies.push(uint16(s[i]));
        }
        feed = new MockPriceFeed(owner, 8, 25e8, "HYPE / USD");
        nft = deploy(address(feed));
        vm.deal(alice, 1_000_000 ether);
        vm.deal(bob, 1_000_000 ether);
    }

    function deploy(address f) internal returns (ElyfishSkins) {
        return new ElyfishSkins(owner, f, 1 hours, BASE, CONTRACT, treasury, 500, kinds, rarities, supplies, prices);
    }

    /// what n tokens of this skin cost at the feed's rate, worked out here independently (rounded up)
    function expectedCost(uint256 skinId, uint256 n) internal view returns (uint256) {
        uint256 usd = prices[rarities[skinId]] * n;
        (, int256 answer,,,) = feed.latestRoundData();
        uint256 num = usd * 10 ** feed.decimals() * 1e18;
        uint256 den = uint256(answer) * 1e8;
        return (num + den - 1) / den;
    }
}
