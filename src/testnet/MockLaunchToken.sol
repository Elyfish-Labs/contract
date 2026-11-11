// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title A stand-in for the game token on a testnet (Montra launches on Elysium mainnet only)
/// @notice A plain ERC-20 with the one extra a Montra LaunchToken has that the buyback uses: burn(amount) of the
/// caller's own tokens. The whole supply is minted once, to whoever deploys it (who seeds the mock router).
contract MockLaunchToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply, address to) ERC20(name_, symbol_) {
        _mint(to, supply);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
