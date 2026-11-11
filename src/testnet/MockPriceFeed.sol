// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @title A stand-in HYPE / USD feed for testnets that have no Chainlink feed (Elysium testnet)
/// @notice Same interface as a Chainlink feed; only its owner moves the price. Never use it on mainnet: point the
/// skins contract at the real Chainlink feed there (ElyfishSkins.setPriceFeed).
contract MockPriceFeed is AggregatorV3Interface, Ownable {
    uint8 public immutable override decimals;
    string public override description;
    uint80 private _round;
    int256 private _answer;
    uint256 private _updatedAt;

    constructor(address owner_, uint8 decimals_, int256 answer_, string memory description_) Ownable(owner_) {
        decimals = decimals_;
        description = description_;
        _set(answer_);
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    /// @notice a new price, now
    function setAnswer(int256 answer_) external onlyOwner {
        _set(answer_);
    }

    function getRoundData(uint80 roundId)
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        require(roundId == _round, "only the latest round");
        return (_round, _answer, _updatedAt, _updatedAt, _round);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (_round, _answer, _updatedAt, _updatedAt, _round);
    }

    function _set(int256 answer_) private {
        _round += 1;
        _answer = answer_;
        _updatedAt = block.timestamp;
    }
}
