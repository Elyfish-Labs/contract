// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ElyfishTradingPost} from "../src/ElyfishTradingPost.sol";

/// Deploys the Elyfish Trading Post (game items for HYPE).
///   PRIVATE_KEY   the deployer, also the owner (signer rotation, pause, fees)
///   SIGNER        the game server's signing address (TRADE_SIGNER_KEY on the server)
///
///   SIGNER=0x… forge script script/DeployTradingPost.s.sol --rpc-url elysium_testnet --broadcast
contract DeployTradingPost is Script {
    function run() external returns (ElyfishTradingPost tp) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(key);
        tp = new ElyfishTradingPost(vm.addr(key), vm.envAddress("SIGNER"));
        vm.stopBroadcast();
        console.log("ElyfishTradingPost", address(tp));
    }
}
