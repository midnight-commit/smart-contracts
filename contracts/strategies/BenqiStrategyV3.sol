// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

import "../YakStrategyV2.sol";
import "../interfaces/IBenqiUnitroller.sol";
import "../interfaces/IBenqiERC20Delegator.sol";
import "../interfaces/IWAVAX.sol";

import "../interfaces/IERC20.sol";
import "../lib/DexLibrary.sol";
import "../lib/ExponentialNoError.sol";

contract BenqiStrategyV3 is YakStrategyV2, ExponentialNoError {
    using SafeMath for uint256;

    IBenqiUnitroller private rewardController;
    IBenqiERC20Delegator private tokenDelegator;
    IERC20 private rewardToken0;
    IERC20 private rewardToken1;
    IPair private swapPairToken0;
    IPair private swapPairToken1;
    IWAVAX private constant WAVAX = IWAVAX(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    uint256 private leverageLevel;
    uint256 private leverageBips;
    uint256 private minMinting;
    uint256 private redeemLimitSafetyMargin;

    constructor(
        string memory _name,
        address _depositToken,
        address _rewardController,
        address _tokenDelegator,
        address _rewardToken0,
        address _rewardToken1,
        address _swapPairToken0,
        address _swapPairToken1,
        address _timelock,
        uint256 _minMinting,
        uint256 _leverageLevel,
        uint256 _leverageBips,
        uint256 _minTokensToReinvest,
        uint256 _adminFeeBips,
        uint256 _devFeeBips,
        uint256 _reinvestRewardBips
    ) {
        name = _name;
        depositToken = IERC20(_depositToken);
        rewardController = IBenqiUnitroller(_rewardController);
        tokenDelegator = IBenqiERC20Delegator(_tokenDelegator);
        rewardToken0 = IERC20(_rewardToken0);
        rewardToken1 = IERC20(_rewardToken1);
        rewardToken = rewardToken1;
        minMinting = _minMinting;
        _updateLeverage(
            _leverageLevel,
            _leverageBips,
            _leverageBips.mul(990).div(1000) //works as long as leverageBips > 1000
        );
        devAddr = 0x2D580F9CF2fB2D09BC411532988F2aFdA4E7BefF;

        _enterMarket();

        assignSwapPairSafely(_swapPairToken0, _swapPairToken1);
        updateMinTokensToReinvest(_minTokensToReinvest);
        updateAdminFee(_adminFeeBips);
        updateDevFee(_devFeeBips);
        updateReinvestReward(_reinvestRewardBips);
        updateDepositsEnabled(true);
        transferOwnership(_timelock);

        emit Reinvest(0, 0);
    }

    function totalDeposits() public view override returns (uint256) {
        (, uint256 internalBalance, uint256 borrow, uint256 exchangeRate) = tokenDelegator.getAccountSnapshot(
            address(this)
        );
        return internalBalance.mul(exchangeRate).div(1e18).sub(borrow);
    }

    function _totalDepositsFresh() internal returns (uint256) {
        uint256 borrow = tokenDelegator.borrowBalanceCurrent(address(this));
        uint256 balance = tokenDelegator.balanceOfUnderlying(address(this));
        return balance.sub(borrow);
    }

    function _enterMarket() internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenDelegator);
        rewardController.enterMarkets(tokens);
    }

    function _updateLeverage(
        uint256 _leverageLevel,
        uint256 _leverageBips,
        uint256 _redeemLimitSafetyMargin
    ) internal {
        leverageLevel = _leverageLevel;
        leverageBips = _leverageBips;
        redeemLimitSafetyMargin = _redeemLimitSafetyMargin;
    }

    function updateLeverage(
        uint256 _leverageLevel,
        uint256 _leverageBips,
        uint256 _redeemLimitSafetyMargin
    ) external onlyDev {
        _updateLeverage(_leverageLevel, _leverageBips, _redeemLimitSafetyMargin);
        uint256 borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
        uint256 balance = tokenDelegator.balanceOfUnderlying(address(this));
        _unrollDebt(balance.sub(borrowed));
        if (balance.sub(borrowed) > 0) {
            _rollupDebt(balance.sub(borrowed), 0);
        }
    }

    /**
     * @notice Initialization helper for Pair deposit tokens
     * @dev Checks that selected Pairs are valid for trading deposit tokens
     * @dev Assigns values to swapPairToken0 and swapPairToken1
     */
    function assignSwapPairSafely(address _swapPairToken0, address _swapPairToken1) private {
        require(_swapPairToken0 > address(0), "Swap pair 0 is necessary but not supplied");
        require(_swapPairToken1 > address(0), "Swap pair 1 is necessary but not supplied");

        require(
            address(rewardToken0) == IPair(address(_swapPairToken0)).token0() ||
                address(rewardToken0) == IPair(address(_swapPairToken0)).token1(),
            "Swap pair 0 does not match rewardToken0"
        );

        require(
            address(rewardToken1) == IPair(address(_swapPairToken0)).token0() ||
                address(rewardToken1) == IPair(address(_swapPairToken0)).token1(),
            "Swap pair 0 does not match rewardToken1"
        );

        require(
            address(depositToken) == IPair(address(_swapPairToken1)).token0() ||
                address(depositToken) == IPair(address(_swapPairToken1)).token1(),
            "Swap pair 1 does not match depositToken"
        );

        require(
            address(rewardToken1) == IPair(address(_swapPairToken1)).token0() ||
                address(rewardToken1) == IPair(address(_swapPairToken1)).token1(),
            "Swap pair 1 does not match rewardToken1"
        );

        swapPairToken0 = IPair(_swapPairToken0);
        swapPairToken1 = IPair(_swapPairToken1);
    }

    /**
     * @notice Approve tokens for use in Strategy
     * @dev Deprecated; approvals should be handled in context of staking
     */
    function setAllowances() public override onlyOwner {
        revert("setAllowances::deprecated");
    }

    function deposit(uint256 amount) external override {
        _deposit(msg.sender, amount);
    }

    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        depositToken.permit(msg.sender, address(this), amount, deadline, v, r, s);
        _deposit(msg.sender, amount);
    }

    function depositFor(address account, uint256 amount) external override {
        _deposit(account, amount);
    }

    function _deposit(address account, uint256 amount) private onlyAllowedDeposits {
        require(DEPOSITS_ENABLED == true, "BenqiStrategyV3::_deposit");
        if (MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST > 0) {
            (uint256 qiRewards, uint256 avaxRewards, uint256 totalAvaxRewards) = _checkRewards();
            if (totalAvaxRewards > MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST) {
                _reinvest(qiRewards, avaxRewards, totalAvaxRewards);
            }
        }
        require(depositToken.transferFrom(msg.sender, address(this), amount), "BenqiStrategyV3::transfer failed");
        uint256 depositTokenAmount = amount;
        uint256 balance = _totalDepositsFresh();
        if (totalSupply.mul(balance) > 0) {
            depositTokenAmount = amount.mul(totalSupply).div(balance);
        }
        _mint(account, depositTokenAmount);
        _stakeDepositTokens(amount);
        emit Deposit(account, amount);
    }

    function withdraw(uint256 amount) external override {
        uint256 depositTokenAmount = _totalDepositsFresh().mul(amount).div(totalSupply);
        require(depositTokenAmount > 0, "BenqiStrategyV3::withdraw");
        _burn(msg.sender, amount);
        _withdrawDepositTokens(depositTokenAmount);
        _safeTransfer(address(depositToken), msg.sender, depositTokenAmount);
        emit Withdraw(msg.sender, depositTokenAmount);
    }

    function _withdrawDepositTokens(uint256 amount) private {
        _unrollDebt(amount);
        require(tokenDelegator.redeemUnderlying(amount) == 0, "BenqiStrategyV3::failed to redeem");
    }

    function reinvest() external override onlyEOA {
        (uint256 qiRewards, uint256 avaxRewards, uint256 totalAvaxRewards) = _checkRewards();
        require(totalAvaxRewards >= MIN_TOKENS_TO_REINVEST, "BenqiStrategyV3::reinvest");
        _reinvest(qiRewards, avaxRewards, totalAvaxRewards);
    }

    receive() external payable {
        require(msg.sender == address(rewardController), "BenqiStrategyV3::payments not allowed");
    }

    /**
     * @notice Reinvest rewards from staking contract to deposit tokens
     * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
     * @param amount deposit tokens to reinvest
     */
    function _reinvest(
        uint256 qiRewards,
        uint256 avaxRewards,
        uint256 amount
    ) private {
        address[] memory markets = new address[](1);
        markets[0] = address(tokenDelegator);
        rewardController.claimReward(0, address(this), markets);
        rewardController.claimReward(1, address(this), markets);

        uint256 qiBalance = rewardToken0.balanceOf(address(this));
        uint256 avaxBalance = address(this).balance;

        require(avaxBalance >= avaxRewards, "BenqiStrategyV3::AVAX rewards received not sufficient");
        require(qiBalance >= qiRewards, "BenqiStrategyV3::QI rewards received not sufficient");

        if (avaxBalance > 0) {
            WAVAX.deposit{value: avaxBalance}();
        }

        if (qiBalance > 0) {
            DexLibrary.swap(qiBalance, address(rewardToken0), address(rewardToken1), swapPairToken0);
        }

        amount = rewardToken.balanceOf(address(this));

        uint256 devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
        if (devFee > 0) {
            _safeTransfer(address(rewardToken), devAddr, devFee);
        }

        uint256 reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
        if (reinvestFee > 0) {
            _safeTransfer(address(rewardToken), msg.sender, reinvestFee);
        }

        uint256 depositTokenAmount = DexLibrary.swap(
            amount.sub(devFee).sub(reinvestFee),
            address(rewardToken),
            address(depositToken),
            swapPairToken1
        );

        _stakeDepositTokens(depositTokenAmount);

        emit Reinvest(totalDeposits(), totalSupply);
    }

    function _rollupDebt(uint256 principal, uint256 borrowed) internal {
        (uint256 borrowLimit, uint256 borrowBips) = _getBorrowLimit();
        uint256 supplied = principal;
        uint256 lendTarget = principal.sub(borrowed).mul(leverageLevel).div(leverageBips);
        uint256 totalBorrowed = borrowed;
        depositToken.approve(address(tokenDelegator), lendTarget);
        while (supplied < lendTarget) {
            uint256 toBorrowAmount = _getBorrowable(supplied, totalBorrowed, borrowLimit, borrowBips);
            if (supplied.add(toBorrowAmount) > lendTarget) {
                toBorrowAmount = lendTarget.sub(supplied);
            }
            // safeguard needed because we can't mint below a certain threshold
            if (toBorrowAmount < minMinting) {
                break;
            }
            require(tokenDelegator.borrow(toBorrowAmount) == 0, "BenqiStrategyV3::borrowing failed");
            require(tokenDelegator.mint(toBorrowAmount) == 0, "BenqiStrategyV3::lending failed");
            supplied = tokenDelegator.balanceOfUnderlying(address(this));
            totalBorrowed = totalBorrowed.add(toBorrowAmount);
        }
        depositToken.approve(address(tokenDelegator), 0);
    }

    function _getRedeemable(
        uint256 balance,
        uint256 borrowed,
        uint256 borrowLimit,
        uint256 bips
    ) internal view returns (uint256) {
        return balance.sub(borrowed.mul(bips).div(borrowLimit)).mul(redeemLimitSafetyMargin).div(leverageBips);
    }

    function _getBorrowable(
        uint256 balance,
        uint256 borrowed,
        uint256 borrowLimit,
        uint256 bips
    ) internal pure returns (uint256) {
        return balance.mul(borrowLimit).div(bips).sub(borrowed);
    }

    function _getBorrowLimit() internal view returns (uint256, uint256) {
        (, uint256 borrowLimit) = rewardController.markets(address(tokenDelegator));
        return (borrowLimit, 1e18);
    }

    function _unrollDebt(uint256 amountToBeFreed) internal {
        uint256 borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
        uint256 balance = tokenDelegator.balanceOfUnderlying(address(this));
        uint256 targetBorrow = balance.sub(borrowed).sub(amountToBeFreed).mul(leverageLevel).div(leverageBips).sub(
            balance.sub(borrowed).sub(amountToBeFreed)
        );
        uint256 toRepay = borrowed.sub(targetBorrow);
        (uint256 borrowLimit, uint256 borrowBips) = _getBorrowLimit();
        depositToken.approve(address(tokenDelegator), borrowed);
        while (toRepay > 0) {
            uint256 unrollAmount = _getRedeemable(balance, borrowed, borrowLimit, borrowBips);
            if (unrollAmount > toRepay) {
                unrollAmount = toRepay;
            }
            require(tokenDelegator.redeemUnderlying(unrollAmount) == 0, "BenqiStrategyV3::failed to redeem");
            require(tokenDelegator.repayBorrow(unrollAmount) == 0, "BenqiStrategyV3::failed to repay borrow");
            balance = tokenDelegator.balanceOfUnderlying(address(this));
            borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
            if (targetBorrow >= borrowed) {
                break;
            }
            toRepay = borrowed.sub(targetBorrow);
        }
        depositToken.approve(address(tokenDelegator), 0);
    }

    function _stakeDepositTokens(uint256 amount) private {
        require(amount > 0, "BenqiStrategyV3::_stakeDepositTokens");
        depositToken.approve(address(tokenDelegator), amount);
        require(tokenDelegator.mint(amount) == 0, "BenqiStrategyV3::Deposit failed");
        depositToken.approve(address(tokenDelegator), 0);
        uint256 borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
        uint256 principal = tokenDelegator.balanceOfUnderlying(address(this));
        _rollupDebt(principal, borrowed);
    }

    /**
     * @notice Safely transfer using an anonymous ERC20 token
     * @dev Requires token to return true on transfer
     * @param token address
     * @param to recipient address
     * @param value amount
     */
    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        require(IERC20(token).transfer(to, value), "BenqiStrategyV3::TRANSFER_FROM_FAILED");
    }

    function _checkRewards()
        internal
        view
        returns (
            uint256 qiAmount,
            uint256 avaxAmount,
            uint256 totalAvaxAmount
        )
    {
        uint256 qiRewards = _getReward(0, address(this));
        uint256 avaxRewards = _getReward(1, address(this));

        uint256 qiAsWavax = DexLibrary.estimateConversionThroughPair(
            qiRewards,
            address(rewardToken0),
            address(rewardToken1),
            swapPairToken0
        );
        return (qiRewards, avaxRewards, avaxRewards.add(qiAsWavax));
    }

    function checkReward() public view override returns (uint256) {
        (, , uint256 avaxRewards) = _checkRewards();
        return avaxRewards;
    }

    function _getReward(uint8 tokenIndex, address account) internal view returns (uint256) {
        uint256 rewardAccrued = rewardController.rewardAccrued(tokenIndex, account);

        Double memory supplyIndex = Double({mantissa: _supplyIndex(tokenIndex)});
        Double memory supplierIndex = Double({
            mantissa: rewardController.rewardSupplierIndex(tokenIndex, address(tokenDelegator), account)
        });

        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = 1e36;
        }
        Double memory deltaIndex = supplyIndex.mantissa > 0 ? sub_(supplyIndex, supplierIndex) : Double({mantissa: 0});
        uint256 supplyAccrued = mul_(tokenDelegator.balanceOf(account), deltaIndex);

        Double memory borrowerIndex = Double({
            mantissa: rewardController.rewardBorrowerIndex(tokenIndex, address(tokenDelegator), account)
        });

        uint256 borrowAccrued = 0;
        if (borrowerIndex.mantissa > 0) {
            Exp memory marketBorrowIndex = Exp({mantissa: tokenDelegator.borrowIndex()});
            Double memory borrowIndex = Double({mantissa: _borrowIndex(tokenIndex, marketBorrowIndex)});
            if (borrowIndex.mantissa > 0) {
                deltaIndex = sub_(borrowIndex, borrowerIndex);
                uint256 borrowerAmount = div_(tokenDelegator.borrowBalanceStored(address(this)), marketBorrowIndex);
                borrowAccrued = mul_(borrowerAmount, deltaIndex);
            }
        }

        return rewardAccrued.add(supplyAccrued).add(borrowAccrued);
    }

    function _supplyIndex(uint8 rewardType) internal view returns (uint224) {
        (uint224 supplyStateIndex, uint256 supplyStateTimestamp) = rewardController.rewardSupplyState(
            rewardType,
            address(tokenDelegator)
        );

        uint256 supplySpeed = rewardController.rewardSpeeds(rewardType, address(tokenDelegator));
        uint256 deltaTimestamps = sub_(block.timestamp, uint256(supplyStateTimestamp));
        if (deltaTimestamps > 0 && supplySpeed > 0) {
            uint256 supplyTokens = IERC20(tokenDelegator).totalSupply();
            uint256 qiAccrued = mul_(deltaTimestamps, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(qiAccrued, supplyTokens) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: supplyStateIndex}), ratio);
            return safe224(index.mantissa, "new index exceeds 224 bits");
        }
        return 0;
    }

    function _borrowIndex(uint8 rewardType, Exp memory marketBorrowIndex) internal view returns (uint224) {
        (uint224 borrowStateIndex, uint256 borrowStateTimestamp) = rewardController.rewardBorrowState(
            rewardType,
            address(tokenDelegator)
        );
        uint256 borrowSpeed = rewardController.rewardSpeeds(rewardType, address(tokenDelegator));
        uint256 deltaTimestamps = sub_(block.timestamp, uint256(borrowStateTimestamp));
        if (deltaTimestamps > 0 && borrowSpeed > 0) {
            uint256 borrowAmount = div_(tokenDelegator.totalBorrows(), marketBorrowIndex);
            uint256 qiAccrued = mul_(deltaTimestamps, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(qiAccrued, borrowAmount) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: borrowStateIndex}), ratio);
            return safe224(index.mantissa, "new index exceeds 224 bits");
        }
        return 0;
    }

    function getActualLeverage() public view returns (uint256) {
        (, uint256 internalBalance, uint256 borrow, uint256 exchangeRate) = tokenDelegator.getAccountSnapshot(
            address(this)
        );
        uint256 balance = internalBalance.mul(exchangeRate).div(1e18);
        return balance.mul(1e18).div(balance.sub(borrow));
    }

    function estimateDeployedBalance() external view override returns (uint256) {
        return totalDeposits();
    }

    function rescueDeployedFunds(uint256 minReturnAmountAccepted, bool disableDeposits) external override onlyOwner {
        uint256 balanceBefore = depositToken.balanceOf(address(this));
        uint256 borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
        uint256 balance = tokenDelegator.balanceOfUnderlying(address(this));
        _unrollDebt(balance.sub(borrowed));
        tokenDelegator.redeemUnderlying(tokenDelegator.balanceOfUnderlying(address(this)));
        uint256 balanceAfter = depositToken.balanceOf(address(this));
        require(balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted, "BenqiStrategyV3::rescueDeployedFunds");
        emit Reinvest(totalDeposits(), totalSupply);
        if (DEPOSITS_ENABLED == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
    }
}
