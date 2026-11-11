// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILaunchRouter, PoolKey} from "../interfaces/ILaunchRouter.sol";

/// @title A stand-in for Montra's LaunchRouter on a testnet: the same swapExactIn / quoteExactIn, HYPE in, token out
/// @notice Sells the token it holds at a fixed rate (tokens per HYPE, 18 decimals) that its owner sets, minus a fee
/// in pips like a Montra pool's. Only buys (HYPE → token) of the one pool it was made for. Never use it on mainnet:
/// point the revenue contract at Montra's LaunchRouter there.
contract MockLaunchRouter is ILaunchRouter, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    /// @notice tokens (wei) given for 1 HYPE before the fee
    uint256 public rate;
    /// @notice the fee in pips (1,000,000 = 100 %), like a Montra pool's total
    uint24 public feePips;

    event Swapped(bytes32 indexed poolId, address indexed sender, address indexed recipient, bool zeroForOne, uint256 amountIn, uint256 amountOut);

    error Expired(uint256 deadline);
    error IncorrectValue();
    error ZeroAddress();
    error WrongPool();
    error TooLittleReceived(uint256 amountOut, uint256 minAmountOut);

    constructor(address owner_, IERC20 token_, uint256 rate_, uint24 feePips_) Ownable(owner_) {
        token = token_;
        rate = rate_;
        feePips = feePips_;
    }

    function setRate(uint256 rate_, uint24 feePips_) external onlyOwner {
        rate = rate_;
        feePips = feePips_;
    }

    function quoteExactIn(PoolKey calldata key, bool zeroForOne, uint128 amountIn) external view returns (uint256) {
        _check(key, zeroForOne);
        return _out(amountIn);
    }

    function swapExactIn(ExactIn calldata s) external payable returns (uint256 amountOut) {
        if (block.timestamp > s.deadline) revert Expired(s.deadline);
        if (msg.value != s.amountIn) revert IncorrectValue();
        if (s.recipient == address(0)) revert ZeroAddress();
        _check(s.key, s.zeroForOne);
        amountOut = _out(s.amountIn);
        if (amountOut < s.minAmountOut) revert TooLittleReceived(amountOut, s.minAmountOut);
        token.safeTransfer(s.recipient, amountOut);
        emit Swapped(keccak256(abi.encode(s.key)), msg.sender, s.recipient, s.zeroForOne, s.amountIn, amountOut);
    }

    /// @notice the HYPE the buys paid, to the owner
    function withdraw(address payable to) external onlyOwner {
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok, "send");
    }

    function _check(PoolKey calldata key, bool zeroForOne) private view {
        if (!zeroForOne || key.currency0 != address(0) || key.currency1 != address(token)) revert WrongPool();
    }

    function _out(uint256 amountIn) private view returns (uint256) {
        uint256 net = amountIn - (amountIn * feePips) / 1_000_000;
        return (net * rate) / 1e18;
    }
}
