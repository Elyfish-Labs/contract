// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ElyfishSkins} from "../src/ElyfishSkins.sol";
import {MockPriceFeed} from "../src/testnet/MockPriceFeed.sol";

/// Deploys Elyfish Collection with the skins of skins.json.
///   PRIVATE_KEY   the deployer, also the owner and the royalty receiver
///   FEED          the HYPE / USD feed (Chainlink). Unset on a testnet without one: a MockPriceFeed is deployed,
///                 starting at HYPE_USD (8 decimals; default $51.28) — its owner moves it (setAnswer)
///   STALENESS     the oldest feed answer a mint accepts, seconds (default 1 day; a mock: 7 days)
///   BASE_URI / CONTRACT_URI   the metadata on the CDN
///
///   forge script script/Deploy.s.sol --rpc-url elysium_testnet --broadcast
contract Deploy is Script {
    function run() external returns (ElyfishSkins nft, address feed) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);
        string memory json = vm.readFile("./skins.json");
        uint256[] memory k = vm.parseJsonUintArray(json, ".kinds");
        uint256[] memory r = vm.parseJsonUintArray(json, ".rarities");
        uint256[] memory s = vm.parseJsonUintArray(json, ".supplies");
        uint8[] memory kinds = new uint8[](k.length);
        uint8[] memory rarities = new uint8[](k.length);
        uint16[] memory supplies = new uint16[](k.length);
        for (uint256 i = 0; i < k.length; i++) {
            kinds[i] = uint8(k[i]);
            rarities[i] = uint8(r[i]);
            supplies[i] = uint16(s[i]);
        }
        // $2 common · $5 uncommon · $10 rare · $20 epic · $50 legendary (8 decimals)
        uint256[5] memory prices = [uint256(2e8), 5e8, 10e8, 20e8, 50e8];
        feed = vm.envOr("FEED", address(0));
        bool mock = feed == address(0);
        uint256 staleness = vm.envOr("STALENESS", mock ? uint256(7 days) : uint256(1 days));

        vm.startBroadcast(key);
        if (mock) feed = address(new MockPriceFeed(me, 8, int256(vm.envOr("HYPE_USD", uint256(5128e6))), "HYPE / USD (testnet mock)"));
        nft = new ElyfishSkins(
            me,
            feed,
            staleness,
            vm.envOr("BASE_URI", string("https://cdn.elyfish.xyz/nft/v1/")),
            vm.envOr("CONTRACT_URI", string("https://cdn.elyfish.xyz/nft/v1/collection.json")),
            me,
            500,
            kinds,
            rarities,
            supplies,
            prices
        );
        vm.stopBroadcast();

        console.log("ElyfishSkins", address(nft));
        console.log(mock ? "MockPriceFeed" : "Chainlink feed", feed);
    }
}
