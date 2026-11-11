// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ElyfishRevenue} from "../src/ElyfishRevenue.sol";
import {MockLaunchToken} from "../src/testnet/MockLaunchToken.sol";
import {MockLaunchRouter} from "../src/testnet/MockLaunchRouter.sol";
import {PoolKey} from "../src/interfaces/ILaunchRouter.sol";

/// Deploys Elyfish Revenue and gives it the game's paid contracts (the deployer must own them).
///   PRIVATE_KEY   the deployer: owner of the paid contracts now, owner of the revenue contract after
///   PLATFORM / COMMUNITY   the two wallets (default: the deployer)
///   VIP, EGGS, SKINS, POST  the paid contracts (any left unset is skipped)
///   MAX_BUYBACK   the most HYPE one buyback spends (default 1 HYPE)
/// Testnet (MOCK=1): also deploys a stand-in game token and a router selling it (Montra is on mainnet only).
/// Mainnet: TOKEN (the Montra launch token), ROUTER (Montra's LaunchRouter), HOOK (the launch hook), TICK_SPACING
/// (200), the pool's fee field is the dynamic flag 0x800000 and HYPE is currency0.
contract DeployRevenue is Script {
    bytes4 internal constant WITHDRAW = bytes4(keccak256("withdraw(address)"));
    bytes4 internal constant WITHDRAW_FEES = bytes4(keccak256("withdrawFees(address)"));

    function run() external returns (ElyfishRevenue rev) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);
        address payable platform = payable(vm.envOr("PLATFORM", me));
        address payable community = payable(vm.envOr("COMMUNITY", me));
        uint256 maxBuyback = vm.envOr("MAX_BUYBACK", uint256(1 ether));

        vm.startBroadcast(key);
        rev = new ElyfishRevenue(me, platform, community);
        console.log("ElyfishRevenue", address(rev));

        address token;
        address router;
        address hook;
        if (vm.envOr("MOCK", false)) {
            MockLaunchToken t = new MockLaunchToken("Mock Elyfish", "mFISH", 1_000_000_000e18, me);
            // about Montra's opening price: 10,000,000 tokens a HYPE, a 1 % pool fee
            MockLaunchRouter r = new MockLaunchRouter(me, t, 10_000_000e18, 10_000);
            t.transfer(address(r), 500_000_000e18);
            (token, router) = (address(t), address(r));
            console.log("MockLaunchToken", token);
            console.log("MockLaunchRouter", router);
        } else {
            token = vm.envAddress("TOKEN");
            router = vm.envAddress("ROUTER");
            hook = vm.envAddress("HOOK");
        }
        int24 spacing = int24(vm.envOr("TICK_SPACING", int256(200)));
        rev.setBuyback(router, token, PoolKey(address(0), token, 0x800000, spacing, hook), true, true, maxBuyback);

        _give(rev, vm.envOr("VIP", address(0)), WITHDRAW, 0);
        _give(rev, vm.envOr("EGGS", address(0)), WITHDRAW, 0);
        _give(rev, vm.envOr("SKINS", address(0)), WITHDRAW, 0);
        _give(rev, vm.envOr("POST", address(0)), WITHDRAW_FEES, 1);
        vm.stopBroadcast();
    }

    /// offer the paid contract to the revenue contract, accept it there, list it with its split
    function _give(ElyfishRevenue rev, address target, bytes4 pull, uint8 split) internal {
        if (target == address(0)) return;
        Ownable2Step(target).transferOwnership(address(rev));
        rev.acceptOwnershipOf(target);
        rev.setSource(target, pull, split, true);
        console.log("given", target);
    }
}
