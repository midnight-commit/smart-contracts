// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../../../YakStrategyV2.sol";

/**
 * @notice LiquidityBookStrategyBase
 */
abstract contract LiquidityBookStrategyBaseForSA is YakStrategyV2 {
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
