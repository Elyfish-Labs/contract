// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ElyfishVip} from "../src/ElyfishVip.sol";

/// Deploys Elyfish VIP.
///   PRIVATE_KEY   the deployer, also the owner (price, grants, airdrops, withdraw)
///   FEED          the HYPE / USD feed: Chainlink on mainnet; on Elysium testnet the MockPriceFeed the skins use
///   STALENESS     the oldest feed answer a purchase accepts, seconds (default 1 day; 7 days for the testnet mock)
///   VIP_USD       the price of 30 days, USD with 8 decimals (default $12 = 1200000000)
///   DISCOUNT_DAYS how long the discount on longer purchases runs from this deploy, days (default 180, the most; 0 = none)
///   DISCOUNT_90 / DISCOUNT_180 / DISCOUNT_360   basis points off 90 / 180 / 360 days (default 2000 / 3000 / 4000 = 20 / 30 / 40 %)
///
///   FEED=0x… STALENESS=604800 forge script script/DeployVip.s.sol --rpc-url elysium_testnet --broadcast
contract DeployVip is Script {
    function run() external returns (ElyfishVip vip) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);
        address feed = vm.envAddress("FEED");
        uint256 staleness = vm.envOr("STALENESS", uint256(1 days));
        uint256 usd = vm.envOr("VIP_USD", uint256(12e8));

        uint256 discountDays = vm.envOr("DISCOUNT_DAYS", uint256(180));
        uint16 d90 = uint16(vm.envOr("DISCOUNT_90", uint256(2000)));
        uint16 d180 = uint16(vm.envOr("DISCOUNT_180", uint256(3000)));
        uint16 d360 = uint16(vm.envOr("DISCOUNT_360", uint256(4000)));

        vm.startBroadcast(key);
        vip = new ElyfishVip(me, feed, staleness, usd);
        if (discountDays > 0) vip.setDiscount(uint64(block.timestamp + discountDays * 1 days), d90, d180, d360);
        vm.stopBroadcast();

        console.log("ElyfishVip", address(vip));
        console.log("discount until", vip.discountUntil());
    }
}
