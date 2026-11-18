// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ElyfishSkins} from "../src/ElyfishSkins.sol";

/// The collection as it is deployed (a fork of the chain; nothing is sent): this round's skins mint, every other one
/// is refused, and over a cycle each skin gets its round.
///   NFT=<address> forge test --match-contract LiveCheck --fork-url elysium_testnet -vv
contract LiveCheck is Test {
    function test_TheDeployedCollectionFollowsItsRotation() public {
        address at = vm.envOr("NFT", address(0));
        if (at == address(0) || at.code.length == 0) return;   // (not a fork run)
        ElyfishSkins nft = ElyfishSkins(at);
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1_000_000 ether);
        uint256 n = nft.skinCount();
        (uint256[] memory now_, uint256 closesAt) = nft.onSale();
        assertEq(now_.length, nft.perRound());
        assertGt(closesAt, block.timestamp);
        uint256 open;
        uint256 refused;
        for (uint256 i = 0; i < n; i++) {
            uint256 cost = nft.hypePrice(i, 1);
            bool onSale = nft.isOpen(i);
            if (!onSale) vm.expectRevert(abi.encodeWithSelector(ElyfishSkins.NotOnSale.selector, i));
            vm.prank(buyer);
            nft.mint{value: cost}(i, 1);
            if (onSale) open++;
            else refused++;
        }
        assertEq(open, now_.length);
        assertEq(nft.balanceOf(buyer), open);
        emit log_named_uint("on sale now", open);
        emit log_named_uint("refused", refused);
        emit log_named_uint("first skin on sale", now_[0]);
        emit log_named_uint("second skin on sale", now_[1]);
        // every skin gets exactly one round of the cycle
        uint256[] memory seen = new uint256[](n);
        uint256 start = nft.launch();
        uint256 every = nft.period();
        uint256 rounds = nft.cycle();
        for (uint256 r = 0; r < rounds; r++) {
            vm.warp(start + r * every);
            (uint256[] memory ids,) = nft.onSale();
            for (uint256 k = 0; k < ids.length; k++) seen[ids[k]]++;
        }
        for (uint256 i = 0; i < n; i++) assertEq(seen[i], 1);
    }
}
