// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ElyfishPetEggs} from "../src/ElyfishPetEggs.sol";

/// Deploys Elyfish Pet Eggs (packs of 10 pet eggs for HYPE).
///   PRIVATE_KEY   the deployer, also the owner (price, grants, withdraw)
///   FEED          the HYPE / USD feed: Chainlink on mainnet; on Elysium testnet the MockPriceFeed the skins use
///   STALENESS     the oldest feed answer a purchase accepts, seconds (default 1 day; 7 days for the testnet mock)
///   EGGS_USD      the price of one pack of 10, USD with 8 decimals (default $5 = 500000000)
///
///   FEED=0x… STALENESS=604800 forge script script/DeployPetEggs.s.sol --rpc-url elysium_testnet --broadcast
contract DeployPetEggs is Script {
    function run() external returns (ElyfishPetEggs eggs) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);
        address feed = vm.envAddress("FEED");
        uint256 staleness = vm.envOr("STALENESS", uint256(1 days));
        uint256 usd = vm.envOr("EGGS_USD", uint256(5e8));

        vm.startBroadcast(key);
        eggs = new ElyfishPetEggs(me, feed, staleness, usd);
        vm.stopBroadcast();

        console.log("ElyfishPetEggs", address(eggs));
    }
}
