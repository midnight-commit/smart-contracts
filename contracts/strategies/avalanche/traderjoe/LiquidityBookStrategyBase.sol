// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../../../YakStrategyV2.sol";

/**
 * @notice LiquidityBookStrategyBase
 */
abstract contract LiquidityBookStrategyBase is YakStrategyV2 {
    function deposit(uint256) external pure override {
        revert();
    }

    function depositWithPermit(
        uint256,
        uint256,
        uint8,
        bytes32,
        bytes32
    ) external pure override {
        revert();
    }

    function depositFor(address, uint256) external pure override {
        revert();
    }

    function estimateDeployedBalance() external pure override returns (uint256) {
        return 0;
    }

    function getSharesForDepositTokens(uint256) public pure override returns (uint256) {
        return 0;
    }

    function getDepositTokensForShares(uint256) public pure override returns (uint256) {
        return 0;
    }

    function totalDeposits() public pure override returns (uint256) {
        return 0;
    }

    function rescueDeployedFunds(uint256, bool) external pure override {
        revert();
    }
}
