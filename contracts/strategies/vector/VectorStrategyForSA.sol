// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../VariableRewardsStrategyForSA.sol";
import "../../lib/SafeERC20.sol";
import "../../interfaces/IBoosterFeeCollector.sol";

import "./interfaces/IVectorMainStaking.sol";
import "./interfaces/IVectorPoolHelper.sol";

contract VectorStrategyForSA is VariableRewardsStrategyForSA {
    using SafeERC20 for IERC20;

    IERC20 private constant PTP = IERC20(0x22d4002028f537599bE9f666d1c4Fa138522f9c8);
    IERC20 private constant VTX = IERC20(0x5817D4F0b62A59b17f75207DA1848C2cE75e7AF4);

    IVectorMainStaking public immutable vectorMainStaking;
    IBoosterFeeCollector public boosterFeeCollector;
    uint256 public maxSlippageBips;

    constructor(
        address _stakingContract,
        uint256 _maxSlippageBips,
        address _boosterFeeCollector,
        address _swapPairDepositToken,
        RewardSwapPairs[] memory _rewardSwapPairs,
        BaseSettings memory _baseSettings,
        StrategySettings memory _strategySettings
    ) VariableRewardsStrategyForSA(_swapPairDepositToken, _rewardSwapPairs, _baseSettings, _strategySettings) {
        vectorMainStaking = IVectorMainStaking(_stakingContract);
        boosterFeeCollector = IBoosterFeeCollector(_boosterFeeCollector);
        maxSlippageBips = _maxSlippageBips;
    }

    function updateBoosterFeeCollector(address _collector) public onlyOwner {
        boosterFeeCollector = IBoosterFeeCollector(_collector);
    }

    /**
     * @notice Update max slippage for withdrawal
     * @dev Function name matches interface for FeeCollector
     */
    function updateMaxSwapSlippage(uint256 slippageBips) public onlyDev {
        maxSlippageBips = slippageBips;
    }

    function _getMaxSlippageBips() internal view override returns (uint256) {
        return maxSlippageBips;
    }

    function _depositToStakingContract(uint256 _amount) internal override {
        IVectorPoolHelper vectorPoolHelper = _vectorPoolHelper();
        IERC20(asset).approve(address(vectorPoolHelper.mainStaking()), _amount);
        vectorPoolHelper.deposit(_amount);
        IERC20(asset).approve(address(vectorPoolHelper.mainStaking()), 0);
    }

    function _withdrawFromStakingContract(uint256 _amount) internal override returns (uint256 _withdrawAmount) {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        _vectorPoolHelper().withdraw(_amount, 0);
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }

    function _emergencyWithdraw() internal override {
        IVectorPoolHelper vectorPoolHelper = _vectorPoolHelper();
        IERC20(asset).approve(address(vectorPoolHelper), 0);
        vectorPoolHelper.withdraw(totalDeposits(), 0);
    }

    function _pendingRewards() internal view override returns (Reward[] memory) {
        IVectorPoolHelper vectorPoolHelper = _vectorPoolHelper();
        uint256 count = rewardCount;
        Reward[] memory pendingRewards = new Reward[](count);
        (uint256 pendingVTX, uint256 pendingPTP) = vectorPoolHelper.earned(address(PTP));
        uint256 boostFee = boosterFeeCollector.calculateBoostFee(address(this), pendingPTP);
        pendingRewards[0] = Reward({reward: address(PTP), amount: pendingPTP - boostFee});
        pendingRewards[1] = Reward({reward: address(VTX), amount: pendingVTX});
        uint256 offset = 2;
        for (uint256 i = 0; i < count; i++) {
            address rewardToken = supportedRewards[i];
            if (rewardToken == address(PTP) || rewardToken == address(VTX)) {
                continue;
            }
            (, uint256 pendingAdditionalReward) = vectorPoolHelper.earned(address(rewardToken));
            pendingRewards[offset] = Reward({reward: rewardToken, amount: pendingAdditionalReward});
            offset++;
        }
        return pendingRewards;
    }

    function _getRewards() internal override {
        uint256 ptpBalanceBefore = PTP.balanceOf(address(this));
        _vectorPoolHelper().getReward();
        uint256 amount = PTP.balanceOf(address(this)) - ptpBalanceBefore;
        uint256 boostFee = boosterFeeCollector.calculateBoostFee(address(this), amount);
        PTP.safeTransfer(address(boosterFeeCollector), boostFee);
    }

    function totalAssets() public view override returns (uint256) {
        return _vectorPoolHelper().depositTokenBalance();
    }

    function _vectorPoolHelper() private view returns (IVectorPoolHelper) {
        (, , , , , , , , address helper) = vectorMainStaking.getPoolInfo(asset);
        return IVectorPoolHelper(helper);
    }
}
