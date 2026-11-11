// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Uniswap v4's pool key, as Montra's LaunchRouter takes it (native HYPE is the zero address)
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice the part of Montra's LaunchRouter (montramarkets.xyz/docs/reference, /docs/abis/LaunchRouter.json) the
/// buyback uses: exact-input swaps with a minimum and a deadline
interface ILaunchRouter {
    struct ExactIn {
        PoolKey key;
        bool zeroForOne;
        uint128 amountIn;
        uint128 minAmountOut;
        address recipient;
        uint256 deadline;
    }

    /// a native input is sent as the call's value, equal to amountIn
    function swapExactIn(ExactIn calldata s) external payable returns (uint256 amountOut);

    /// (simulates the swap and answers through a revert; call it off chain, with eth_call)
    function quoteExactIn(PoolKey calldata key, bool zeroForOne, uint128 amountIn) external returns (uint256);
}

/// @notice Montra launch tokens can burn their holder's own tokens
interface IBurnable {
    function burn(uint256 amount) external;
}
