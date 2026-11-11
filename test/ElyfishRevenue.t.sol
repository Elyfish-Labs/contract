// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ElyfishRevenue} from "../src/ElyfishRevenue.sol";
import {ElyfishVip} from "../src/ElyfishVip.sol";
import {ElyfishPetEggs} from "../src/ElyfishPetEggs.sol";
import {ElyfishTradingPost} from "../src/ElyfishTradingPost.sol";
import {MockPriceFeed} from "../src/testnet/MockPriceFeed.sol";
import {MockLaunchToken} from "../src/testnet/MockLaunchToken.sol";
import {MockLaunchRouter} from "../src/testnet/MockLaunchRouter.sol";
import {ILaunchRouter, PoolKey} from "../src/interfaces/ILaunchRouter.sol";

/// a wallet that refuses HYPE until told otherwise
contract Refuser {
    bool public open;

    function setOpen(bool o) external {
        open = o;
    }

    receive() external payable {
        require(open, "no");
    }
}

/// a token without burn(): the buyback sends it to 0x…dEaD instead
contract NoBurnToken is ERC20 {
    constructor(address to) ERC20("No Burn", "NB") {
        _mint(to, 1e27);
    }
}

/// a source whose pull always fails (the sweep skips it)
contract BrokenSource {
    function withdraw(address payable) external pure {
        revert("broken");
    }
}

/// a source that pays whatever it holds when pulled, from anyone (to test the split by sender)
contract OpenSource {
    function withdraw(address payable to) external {
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {}
}

/// a router that sends back a tenth of the HYPE as change during the swap (Montra refunds unused native input)
contract ChangeRouter {
    MockLaunchToken internal token;

    constructor(MockLaunchToken t) {
        token = t;
    }

    function swapExactIn(ILaunchRouter.ExactIn calldata s) external payable returns (uint256) {
        (bool ok,) = msg.sender.call{value: msg.value / 10}("");
        require(ok);
        token.transfer(s.recipient, s.minAmountOut);
        return s.minAmountOut;
    }
}

/// a router that says it gave the minimum but gave less
contract ShortRouter {
    MockLaunchToken internal token;

    constructor(MockLaunchToken t) {
        token = t;
    }

    function swapExactIn(ILaunchRouter.ExactIn calldata s) external payable returns (uint256) {
        token.transfer(s.recipient, s.minAmountOut - 1);
        return s.minAmountOut;
    }
}

abstract contract RevenueBase is Test {
    ElyfishRevenue internal rev;
    ElyfishVip internal vip;
    ElyfishPetEggs internal eggs;
    ElyfishTradingPost internal tp;
    MockPriceFeed internal feed;
    MockLaunchToken internal token;
    MockLaunchRouter internal router;
    PoolKey internal key;

    address internal owner = makeAddr("owner");
    address payable internal platform = payable(makeAddr("platform"));
    address payable internal community = payable(makeAddr("community"));
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal seller = makeAddr("seller");
    address internal signer;
    uint256 internal signerKey;
    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant RATE = 1_000_000e18; // 1 HYPE = 1,000,000 tokens
    bytes4 internal constant WITHDRAW = bytes4(keccak256("withdraw(address)"));
    bytes4 internal constant WITHDRAW_FEES = bytes4(keccak256("withdrawFees(address)"));

    function setUp() public virtual {
        vm.warp(T0);
        (signer, signerKey) = makeAddrAndKey("game-server");
        feed = new MockPriceFeed(owner, 8, 25e8, "HYPE / USD");
        vip = new ElyfishVip(owner, address(feed), 1 hours, 12e8);
        eggs = new ElyfishPetEggs(owner, address(feed), 1 hours, 5e8);
        tp = new ElyfishTradingPost(owner, signer);
        rev = new ElyfishRevenue(owner, platform, community);

        // the game token and a router that sells it (testnet stand-ins for Montra)
        token = new MockLaunchToken("Elyfish", "FISH", SUPPLY, address(this));
        router = new MockLaunchRouter(owner, token, RATE, 10_000); // 1 % fee
        token.transfer(address(router), SUPPLY / 2);
        key = PoolKey({currency0: address(0), currency1: address(token), fee: 0x800000, tickSpacing: 200, hooks: address(0x38EC)});

        vm.startPrank(owner);
        vip.transferOwnership(address(rev));
        eggs.transferOwnership(address(rev));
        tp.transferOwnership(address(rev));
        rev.acceptOwnershipOf(address(vip));
        rev.acceptOwnershipOf(address(eggs));
        rev.acceptOwnershipOf(address(tp));
        rev.setSource(address(vip), WITHDRAW, 0, true);
        rev.setSource(address(eggs), WITHDRAW, 0, true);
        rev.setSource(address(tp), WITHDRAW_FEES, 1, true);
        rev.setBuyback(address(router), address(token), key, true, true, 100 ether);
        rev.setKeeper(keeper, true);
        vm.stopPrank();

        vm.deal(alice, 1_000_000 ether);
    }

    function listing(uint256 id, uint256 price) internal pure returns (ElyfishTradingPost.Listing memory) {
        return ElyfishTradingPost.Listing({id: id, seller: address(0x5e11e7), price: price, expiry: uint64(T0 + 3 days)});
    }

    function sign(ElyfishTradingPost.Listing memory l) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, tp.hashListing(l));
        return abi.encodePacked(r, s, v);
    }

    function sellOnPost(uint256 id, uint256 price) internal {
        ElyfishTradingPost.Listing memory l = listing(id, price);
        bytes memory sig = sign(l);
        vm.prank(alice);
        tp.buy{value: price}(l, sig);
    }

    /// the split's arithmetic, worked out here on its own
    function parts(uint256 amount, uint256 p, uint256 c, uint256 b) internal pure returns (uint256 toP, uint256 toC, uint256 toB) {
        uint256 sum = p + c + b;
        toC = (amount * c) / sum;
        toB = (amount * b) / sum;
        toP = amount - toC - toB;
    }
}

contract ElyfishRevenueTest is RevenueBase {
    // ── set up ──────────────────────────────────────────────────────────────────────────────────────────────────

    function test_constructor_and_owner_of_the_paid_contracts() public view {
        assertEq(rev.owner(), owner);
        assertEq(rev.platform(), platform);
        assertEq(rev.community(), community);
        assertEq(rev.splitCount(), 2);
        ElyfishRevenue.Split memory s = rev.split(0);
        assertEq(s.platform, 50);
        assertEq(s.community, 20);
        assertEq(s.buyback, 30);
        s = rev.split(1);
        assertEq(s.platform, 1);
        assertEq(s.community, 0);
        assertEq(s.buyback, 2);
        assertEq(vip.owner(), address(rev));
        assertEq(eggs.owner(), address(rev));
        assertEq(tp.owner(), address(rev));
        assertEq(rev.sourceList().length, 3);
        assertEq(rev.poolKey().currency1, address(token));
    }

    function test_constructor_rejects_zero_wallets() public {
        vm.expectRevert(ElyfishRevenue.ZeroAddress.selector);
        new ElyfishRevenue(owner, payable(address(0)), community);
        vm.expectRevert(ElyfishRevenue.ZeroAddress.selector);
        new ElyfishRevenue(owner, platform, payable(address(0)));
    }

    // ── the splits ──────────────────────────────────────────────────────────────────────────────────────────────

    function test_sales_split_50_20_30() public {
        vm.prank(alice);
        vip.buy{value: 0.48 ether}(1); // $12 at $25
        vm.prank(alice);
        eggs.buy{value: 0.2 ether}(1); // $5 at $25
        uint256 got = rev.sweep();
        assertEq(got, 0.68 ether);
        assertEq(rev.platformOwed(), 0.34 ether);
        assertEq(rev.communityOwed(), 0.136 ether);
        assertEq(rev.buybackPending(), 0.204 ether);
        assertEq(address(rev).balance, rev.booked());
        assertEq(address(vip).balance, 0);
        assertEq(address(eggs).balance, 0);
    }

    function test_trading_post_fee_split_1_platform_2_buyback() public {
        sellOnPost(1, 3 ether); // fee 3 % = 0.09
        assertEq(tp.feesAccrued(), 0.09 ether);
        rev.sweepOne(address(tp));
        assertEq(rev.platformOwed(), 0.03 ether); // 1 %
        assertEq(rev.communityOwed(), 0);
        assertEq(rev.buybackPending(), 0.06 ether); // 2 %
        assertEq(tp.feesAccrued(), 0);
        // the seller's 97 % never comes here
        assertEq(address(0x5e11e7).balance, 2.91 ether);
    }

    function test_hype_from_anyone_else_uses_split_0() public {
        vm.prank(alice);
        (bool ok,) = address(rev).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(rev.platformOwed(), 0.5 ether);
        assertEq(rev.communityOwed(), 0.2 ether);
        assertEq(rev.buybackPending(), 0.3 ether);
    }

    function test_sweep_skips_empty_and_broken_sources() public {
        BrokenSource broken = new BrokenSource();
        vm.prank(owner);
        rev.setSource(address(broken), WITHDRAW, 0, true);
        assertEq(rev.sweep(), 0);
        assertEq(rev.sweepOne(address(broken)), 0);
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.NotListed.selector, alice));
        rev.sweepOne(alice);
    }

    function test_a_source_sending_by_itself_is_split_by_its_own_split() public {
        OpenSource src = new OpenSource();
        vm.prank(owner);
        rev.setSource(address(src), WITHDRAW, 1, true);
        vm.deal(address(src), 3 ether);
        src.withdraw(payable(address(rev)));
        assertEq(rev.platformOwed(), 1 ether);
        assertEq(rev.buybackPending(), 2 ether);
    }

    // ── paying out ──────────────────────────────────────────────────────────────────────────────────────────────

    function test_release_pays_the_wallets() public {
        vm.prank(alice);
        eggs.buy{value: 2 ether}(10);
        rev.sweep();
        rev.release();
        assertEq(platform.balance, 1 ether);
        assertEq(community.balance, 0.4 ether);
        assertEq(rev.platformOwed(), 0);
        assertEq(rev.communityOwed(), 0);
        assertEq(address(rev).balance, 0.6 ether);
        // nothing booked: nothing happens
        rev.release();
        assertEq(platform.balance, 1 ether);
    }

    function test_a_refusing_wallet_keeps_its_share_here() public {
        Refuser p = new Refuser();
        Refuser c = new Refuser();
        vm.prank(owner);
        rev.setWallets(payable(address(p)), payable(address(c)));
        vm.prank(alice);
        eggs.buy{value: 2 ether}(10);
        rev.sweep();
        rev.release();
        assertEq(rev.platformOwed(), 1 ether);
        assertEq(rev.communityOwed(), 0.4 ether);
        p.setOpen(true);
        c.setOpen(true);
        rev.release();
        assertEq(address(p).balance, 1 ether);
        assertEq(address(c).balance, 0.4 ether);
    }

    // ── buyback and burn ────────────────────────────────────────────────────────────────────────────────────────

    function test_buyback_buys_and_burns() public {
        vm.prank(alice);
        eggs.buy{value: 2 ether}(10);
        rev.sweep(); // 0.6 to the buyback
        uint256 supply = token.totalSupply();
        uint256 expectOut = (0.6 ether - 0.006 ether) * RATE / 1e18; // 1 % pool fee
        vm.prank(keeper);
        uint256 out = rev.buyback(0.6 ether, expectOut, block.timestamp);
        assertEq(out, expectOut);
        assertEq(token.totalSupply(), supply - out);
        assertEq(token.balanceOf(address(rev)), 0);
        assertEq(rev.burned(), out);
        assertEq(rev.buybackSpent(), 0.6 ether);
        assertEq(rev.buybackPending(), 0);
        assertEq(address(router).balance, 0.6 ether);
    }

    function test_buyback_without_burn_sends_to_dead() public {
        vm.prank(owner);
        rev.setBuyback(address(router), address(token), key, true, false, 100 ether);
        vm.prank(alice);
        eggs.buy{value: 2 ether}(10);
        rev.sweep();
        vm.prank(owner);
        uint256 out = rev.buyback(0.3 ether, 1, block.timestamp);
        assertEq(token.balanceOf(rev.DEAD()), out);
        assertEq(rev.burned(), out);
    }

    function test_a_token_without_burn_falls_back_to_dead() public {
        NoBurnToken nb = new NoBurnToken(address(this));
        MockLaunchRouter r2 = new MockLaunchRouter(owner, nb, RATE, 0);
        nb.transfer(address(r2), 1e26);
        PoolKey memory k2 = PoolKey(address(0), address(nb), 0x800000, 200, address(0));
        vm.prank(owner);
        rev.setBuyback(address(r2), address(nb), k2, true, true, 100 ether);
        vm.prank(alice);
        eggs.buy{value: 2 ether}(10);
        rev.sweep();
        vm.prank(keeper);
        uint256 out = rev.buyback(0.6 ether, 1, block.timestamp);
        assertEq(nb.balanceOf(rev.DEAD()), out);
        assertEq(rev.burned(), out);
    }

    function test_buyback_guards() public {
        vm.prank(alice);
        eggs.buy{value: 2 ether}(10);
        rev.sweep();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.NotKeeper.selector, alice));
        rev.buyback(0.1 ether, 1, block.timestamp);
        vm.startPrank(keeper);
        vm.expectRevert(ElyfishRevenue.NoMinimum.selector);
        rev.buyback(0.1 ether, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.TooMuch.selector, 0, 0.6 ether));
        rev.buyback(0, 1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.TooMuch.selector, 0.7 ether, 0.6 ether));
        rev.buyback(0.7 ether, 1, block.timestamp);
        vm.stopPrank();
        // the cap per buy
        vm.prank(owner);
        rev.setBuyback(address(router), address(token), key, true, true, 0.1 ether);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.TooMuch.selector, 0.2 ether, 0.1 ether));
        rev.buyback(0.2 ether, 1, block.timestamp);
        // the router's own minimum and deadline: nothing changes
        vm.startPrank(keeper);
        vm.expectRevert();
        rev.buyback(0.1 ether, type(uint128).max, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(MockLaunchRouter.Expired.selector, block.timestamp - 1));
        rev.buyback(0.1 ether, 1, block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.TooMuch.selector, uint256(type(uint128).max) + 1, type(uint128).max));
        rev.buyback(0.1 ether, uint256(type(uint128).max) + 1, block.timestamp);
        vm.stopPrank();
        assertEq(rev.buybackPending(), 0.6 ether);
        assertEq(rev.buybackSpent(), 0);
    }

    function test_no_buyback_before_it_is_set() public {
        ElyfishRevenue fresh = new ElyfishRevenue(owner, platform, community);
        vm.prank(owner);
        vm.expectRevert(ElyfishRevenue.NoBuyback.selector);
        fresh.buyback(1, 1, block.timestamp);
        vm.expectRevert(ElyfishRevenue.NoBuyback.selector);
        fresh.burnHeld();
    }

    function test_burn_held_burns_strays() public {
        token.transfer(address(rev), 5e18);
        uint256 supply = token.totalSupply();
        rev.burnHeld();
        assertEq(token.totalSupply(), supply - 5e18);
        assertEq(rev.burned(), 5e18);
        rev.burnHeld(); // nothing held: nothing happens
        assertEq(rev.burned(), 5e18);
    }

    // ── running the paid contracts ──────────────────────────────────────────────────────────────────────────────

    function test_exec_runs_owner_settings() public {
        vm.prank(owner);
        rev.exec(address(vip), abi.encodeCall(ElyfishVip.setPrice, (15e8)));
        assertEq(vip.usdPrice(), 15e8);
        address[] memory ws = new address[](1);
        ws[0] = alice;
        vm.prank(owner);
        rev.exec(address(eggs), abi.encodeCall(ElyfishPetEggs.grant, (ws, 2)));
        assertEq(eggs.packsOf(alice), 2);
    }

    function test_exec_refuses_taking_the_hype_or_the_contract() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.Refused.selector, WITHDRAW));
        rev.exec(address(vip), abi.encodeCall(ElyfishVip.withdraw, (payable(owner))));
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.Refused.selector, WITHDRAW_FEES));
        rev.exec(address(tp), abi.encodeCall(ElyfishTradingPost.withdrawFees, (payable(owner))));
        bytes4 transferSel = bytes4(keccak256("transferOwnership(address)"));
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.Refused.selector, transferSel));
        rev.exec(address(vip), abi.encodeWithSelector(transferSel, owner));
        bytes4 renounceSel = bytes4(keccak256("renounceOwnership()"));
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.Refused.selector, renounceSel));
        rev.exec(address(vip), abi.encodeWithSelector(renounceSel));
        // an unlisted contract's withdraw too
        OpenSource src = new OpenSource();
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.Refused.selector, WITHDRAW));
        rev.exec(address(src), abi.encodeCall(OpenSource.withdraw, (payable(owner))));
        // a listed source's own pull selector, whatever it is called
        rev.setSource(address(src), bytes4(0x12345678), 0, true);
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.Refused.selector, bytes4(0x12345678)));
        rev.exec(address(src), abi.encodeWithSelector(bytes4(0x12345678)));
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.Refused.selector, bytes4(0)));
        rev.exec(address(vip), hex"1234");
        // a failing call
        vm.expectRevert();
        rev.exec(address(vip), abi.encodeCall(ElyfishVip.setPrice, (0)));
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rev.exec(address(vip), abi.encodeCall(ElyfishVip.setPrice, (15e8)));
    }

    function test_hand_over_pulls_the_hype_first() public {
        vm.prank(alice);
        vip.buy{value: 0.48 ether}(1);
        address next = makeAddr("next");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rev.handOver(address(vip), next);
        vm.startPrank(owner);
        vm.expectRevert(ElyfishRevenue.ZeroAddress.selector);
        rev.handOver(address(vip), address(0));
        rev.handOver(address(vip), next);
        vm.stopPrank();
        assertEq(address(vip).balance, 0);
        assertEq(rev.booked(), 0.48 ether);
        vm.prank(next);
        vip.acceptOwnership();
        assertEq(vip.owner(), next);
        // an unlisted contract hands over without a pull
        ElyfishPetEggs other = new ElyfishPetEggs(owner, address(feed), 1 hours, 5e8);
        vm.prank(owner);
        other.transferOwnership(address(rev));
        vm.startPrank(owner);
        rev.acceptOwnershipOf(address(other));
        rev.handOver(address(other), next);
        vm.stopPrank();
        assertEq(other.pendingOwner(), next);
    }

    // ── settings ────────────────────────────────────────────────────────────────────────────────────────────────

    function test_settings_are_owner_only() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rev.setWallets(platform, community);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rev.setSplit(0, 1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rev.setSource(alice, WITHDRAW, 0, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rev.setBuyback(address(router), address(token), key, true, true, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rev.setKeeper(alice, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rev.acceptOwnershipOf(address(vip));
        vm.stopPrank();
    }

    function test_set_split_change_add_and_refuse() public {
        vm.startPrank(owner);
        rev.setSplit(0, 60, 10, 30);
        assertEq(rev.split(0).platform, 60);
        rev.setSplit(2, 0, 0, 1);
        assertEq(rev.splitCount(), 3);
        vm.expectRevert(ElyfishRevenue.BadSplit.selector);
        rev.setSplit(1, 0, 0, 0);
        vm.expectRevert(ElyfishRevenue.BadSplit.selector);
        rev.setSplit(5, 1, 1, 1);
        for (uint8 i = 3; i < 8; i++) rev.setSplit(i, 1, 0, 0);
        vm.expectRevert(ElyfishRevenue.BadSplit.selector);
        rev.setSplit(8, 1, 0, 0);
        vm.stopPrank();
    }

    function test_set_source_list_change_delist_and_limits() public {
        vm.startPrank(owner);
        vm.expectRevert(ElyfishRevenue.ZeroAddress.selector);
        rev.setSource(address(0), WITHDRAW, 0, true);
        vm.expectRevert(ElyfishRevenue.ZeroAddress.selector);
        rev.setSource(address(rev), WITHDRAW, 0, true);
        vm.expectRevert(ElyfishRevenue.BadSplit.selector);
        rev.setSource(alice, WITHDRAW, 9, true);
        vm.expectRevert(ElyfishRevenue.BadSplit.selector);
        rev.setSource(alice, bytes4(0), 0, true);
        // change in place: still three
        rev.setSource(address(vip), WITHDRAW, 1, true);
        assertEq(rev.sourceList().length, 3);
        // delist the first: the last takes its place
        rev.setSource(address(vip), WITHDRAW, 0, false);
        assertEq(rev.sourceList().length, 2);
        (,, bool listed) = rev.sources(address(vip));
        assertFalse(listed);
        // delisting something not listed changes nothing
        rev.setSource(alice, WITHDRAW, 0, false);
        assertEq(rev.sourceList().length, 2);
        // up to 16
        for (uint160 i = 1; i <= 14; i++) rev.setSource(address(i + 1000), WITHDRAW, 0, true);
        assertEq(rev.sourceList().length, 16);
        vm.expectRevert(ElyfishRevenue.TooMany.selector);
        rev.setSource(address(5000), WITHDRAW, 0, true);
        vm.stopPrank();
    }

    function test_set_buyback_checks_the_pool() public {
        vm.startPrank(owner);
        vm.expectRevert(ElyfishRevenue.ZeroAddress.selector);
        rev.setBuyback(address(0), address(token), key, true, true, 1);
        vm.expectRevert(ElyfishRevenue.ZeroAddress.selector);
        rev.setBuyback(address(router), address(0), key, true, true, 1);
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.TooMuch.selector, 0, type(uint128).max));
        rev.setBuyback(address(router), address(token), key, true, true, 0);
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.TooMuch.selector, uint256(type(uint128).max) + 1, type(uint128).max));
        rev.setBuyback(address(router), address(token), key, true, true, uint256(type(uint128).max) + 1);
        // a buy the other way round, or another token's pool
        vm.expectRevert(ElyfishRevenue.BadSplit.selector);
        rev.setBuyback(address(router), address(token), key, false, true, 1);
        PoolKey memory other = PoolKey(address(0), alice, 0x800000, 200, address(0));
        vm.expectRevert(ElyfishRevenue.BadSplit.selector);
        rev.setBuyback(address(router), address(token), other, true, true, 1);
        vm.stopPrank();
    }

    function test_keepers() public {
        vm.startPrank(owner);
        vm.expectRevert(ElyfishRevenue.ZeroAddress.selector);
        rev.setKeeper(address(0), true);
        rev.setKeeper(keeper, false);
        vm.stopPrank();
        assertFalse(rev.keepers(keeper));
    }

    function test_mock_router_refuses_other_pools_and_values() public {
        vm.expectRevert(MockLaunchRouter.WrongPool.selector);
        router.quoteExactIn(key, false, 1 ether);
        assertEq(router.quoteExactIn(key, true, 1 ether), (1 ether - 0.01 ether) * RATE / 1e18);
        ILaunchRouter.ExactIn memory s = ILaunchRouter.ExactIn(key, true, 1 ether, 1, alice, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(MockLaunchRouter.IncorrectValue.selector);
        router.swapExactIn{value: 0.5 ether}(s);
        s.recipient = address(0);
        vm.prank(alice);
        vm.expectRevert(MockLaunchRouter.ZeroAddress.selector);
        router.swapExactIn{value: 1 ether}(s);
        vm.prank(owner);
        router.setRate(2 * RATE, 0);
        assertEq(router.quoteExactIn(key, true, 1 ether), 2 * RATE);
        vm.deal(address(router), 1 ether);
        vm.prank(owner);
        router.withdraw(payable(owner));
        assertEq(owner.balance, 1 ether);
    }

    function test_change_from_the_router_goes_back_to_the_buyback() public {
        ChangeRouter cr = new ChangeRouter(token);
        token.transfer(address(cr), 1e24);
        vm.prank(owner);
        rev.setBuyback(address(cr), address(token), key, true, true, 100 ether);
        vm.prank(alice);
        (bool ok,) = address(rev).call{value: 10 ether}("");
        assertTrue(ok);
        vm.prank(keeper);
        rev.buyback(1 ether, 5e18, block.timestamp);
        assertEq(rev.buybackPending(), 3 ether - 1 ether + 0.1 ether);
        assertEq(address(rev).balance, rev.booked());
    }

    function test_a_router_that_gives_too_little_is_refused() public {
        ShortRouter sr = new ShortRouter(token);
        token.transfer(address(sr), 1e24);
        vm.prank(owner);
        rev.setBuyback(address(sr), address(token), key, true, true, 100 ether);
        vm.prank(alice);
        (bool ok,) = address(rev).call{value: 10 ether}("");
        assertTrue(ok);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ElyfishRevenue.TooMuch.selector, 5e18, 5e18 - 1));
        rev.buyback(1 ether, 5e18, block.timestamp);
        assertEq(rev.buybackPending(), 3 ether);
    }

    function test_mock_router_withdraw_to_a_refuser_fails() public {
        vm.deal(address(router), 1 ether);
        Refuser r = new Refuser();
        vm.prank(owner);
        vm.expectRevert(bytes("send"));
        router.withdraw(payable(address(r)));
    }

    // ── fuzz ────────────────────────────────────────────────────────────────────────────────────────────────────

    /// any amount, any split: nothing is lost or made, rounding goes to the platform
    function testFuzz_split_conserves(uint96 amount, uint16 p, uint16 c, uint16 b) public {
        vm.assume(uint256(p) + c + b > 0);
        vm.prank(owner);
        rev.setSplit(0, p, c, b);
        vm.deal(alice, amount);
        vm.prank(alice);
        (bool ok,) = address(rev).call{value: amount}("");
        assertTrue(ok);
        (uint256 toP, uint256 toC, uint256 toB) = parts(amount, p, c, b);
        assertEq(rev.platformOwed(), toP);
        assertEq(rev.communityOwed(), toC);
        assertEq(rev.buybackPending(), toB);
        assertEq(rev.booked(), amount);
        assertEq(address(rev).balance, amount);
    }

    /// any trading post sale: the 3 % fee is 1 part platform, 2 parts buyback
    function testFuzz_trade_fee_split(uint96 price) public {
        uint256 pr = bound(price, 1e12, 1e24);
        sellOnPost(7, pr);
        uint256 fee = pr * 300 / 10_000;
        rev.sweep();
        assertEq(rev.buybackPending(), fee * 2 / 3);
        assertEq(rev.platformOwed(), fee - fee * 2 / 3);
        assertEq(rev.communityOwed(), 0);
    }

    /// any buyback within the pending amount and the cap: everything bought is burned, the rest stays booked
    function testFuzz_buyback_burns_all(uint96 sales, uint96 spend) public {
        uint256 s = bound(sales, 1e15, 500 ether);
        vm.deal(alice, s);
        vm.prank(alice);
        (bool ok,) = address(rev).call{value: s}("");
        assertTrue(ok);
        uint256 pending = rev.buybackPending();
        uint256 amountIn = bound(spend, 1, pending < 100 ether ? pending : 100 ether);
        uint256 supply = token.totalSupply();
        vm.prank(keeper);
        uint256 out = rev.buyback(amountIn, 1, block.timestamp);
        assertEq(token.totalSupply(), supply - out);
        assertEq(token.balanceOf(address(rev)), 0);
        assertEq(rev.buybackPending(), pending - amountIn);
        assertEq(address(rev).balance, rev.booked());
    }
}
