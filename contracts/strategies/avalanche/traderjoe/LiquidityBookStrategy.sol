// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../../../interfaces/IPair.sol";
import "../../../interfaces/IWAVAX.sol";
import "../../../lib/DexLibrary.sol";
import "../../../lib/SafeTransferLib.sol";

import "./LiquidityBookStrategyBase.sol";
import "./interfaces/ILBPair.sol";
import "./interfaces/ILBRouter.sol";
import "./interfaces/ILBFactory.sol";
import "./lib/Math512Bits.sol";

/**
 * @notice LiquidityBookStrategy
 */
contract LiquidityBookStrategy is LiquidityBookStrategyBase {
    using SafeTransferLib for IERC20;
    using Math512Bits for uint256;

    uint256 internal constant SCALE_OFFSET = 128;
    uint256 internal constant PRECISION = 1e18;

    address internal immutable WAVAX;
    ILBPair public immutable lbPair;
    ILBRouter public immutable lbRouter;
    address public immutable tokenX;
    address public immutable tokenY;
    address public immutable swapPairTokenX;
    address public immutable swapPairTokenY;
    uint24 public immutable binStep;

    uint256[] public currentBins;

    int256[] public deltas;
    uint256 public maxReinvestSlippage;

    address public manager;
    uint256 public rebalanceGasEstimate;

    event Deposit(address indexed account, uint256 amountX, uint256 amountY);
    event Withdraw(address indexed account, uint256 amountX, uint256 amountY);
    event Reinvest(uint256 totalX, uint256 totalY, uint256 totalSupply);

    error InvalidReinvestRewardToken();
    error OnlyManager();
    error InvalidManager();
    error DepositsDisabled();
    error InsufficientLiquidityTooAdd();
    error WithdrawAmountTooLow();
    error ReinvestAmountTooLow();
    error EmergencyWithdrawMinimumXNotReached();
    error EmergencyWithdrawMinimumYNotReached();

    modifier onlyManager() {
        if (msg.sender != manager) revert OnlyManager();
        _;
    }

    struct LiquidityBookStrategySettings {
        string name;
        address platformToken;
        address timelock;
        address devAddr;
        address manager;
        address lbRouter;
        address tokenX;
        address tokenY;
        uint24 binStep;
        address swapPairTokenX;
        address swapPairTokenY;
        uint256 maxReinvestSlippage;
    }

    constructor(LiquidityBookStrategySettings memory _settings, StrategySettings memory _strategySettings)
        YakStrategyV2(_strategySettings)
    {
        name = _settings.name;
        WAVAX = _settings.platformToken;
        if (_strategySettings.rewardToken != WAVAX) revert InvalidReinvestRewardToken();
        devAddr = _settings.devAddr;
        if (_settings.manager == address(0)) revert InvalidManager();
        manager = _settings.manager;

        tokenX = _settings.tokenX;
        tokenY = _settings.tokenY;

        binStep = _settings.binStep;
        lbRouter = ILBRouter(_settings.lbRouter);
        (, address lbPairAddress, , ) = ILBFactory(ILBRouter(_settings.lbRouter).factory()).getLBPairInformation(
            _settings.tokenX,
            _settings.tokenY,
            _settings.binStep
        );
        lbPair = ILBPair(lbPairAddress);
        swapPairTokenX = _settings.swapPairTokenX;
        swapPairTokenY = _settings.swapPairTokenY;
        maxReinvestSlippage = _settings.maxReinvestSlippage;

        updateDepositsEnabled(true);
        transferOwnership(_settings.timelock);
        emit Reinvest(0, 0);
    }

    function updateManager(address _manager) external onlyDev {
        if (_manager == address(0)) revert InvalidManager();
        manager = _manager;
    }

    function updateMaxReinvestSlippage(uint256 _maxReinvestSlippage) external onlyDev {
        maxReinvestSlippage = _maxReinvestSlippage;
    }

    /**
     * @notice Deposit tokens to receive receipt tokens
     * @param _amountX Amount of token X to deposit
     * @param _amountY Amount of token Y to deposit
     */
    function deposit(
        uint256 _amountX,
        uint256 _amountY,
        uint256 _slippageBips
    ) external {
        _deposit(msg.sender, _amountX, _amountY, _slippageBips);
    }

    /**
     * @notice Deposit using Permit
     * @param _amountX Amount of token X to deposit
     * @param _amountY Amount of token Y to deposit
     * @param _deadline The time at which to expire the signature
     * @param _v The recovery byte of the signature
     * @param _r Half of the ECDSA signature pair
     * @param _s Half of the ECDSA signature pair
     */
    function depositWithPermit(
        uint256 _amountX,
        uint256 _amountY,
        uint256 _slippageBips,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        IERC20(tokenX).permit(msg.sender, address(this), _amountX, _deadline, _v, _r, _s);
        IERC20(tokenY).permit(msg.sender, address(this), _amountY, _deadline, _v, _r, _s);
        _deposit(msg.sender, _amountX, _amountY, _slippageBips);
    }

    function depositFor(
        address _account,
        uint256 _amountX,
        uint256 _amountY,
        uint256 _slippageBips
    ) external {
        _deposit(_account, _amountX, _amountY, _slippageBips);
    }

    function _deposit(
        address _account,
        uint256 _amountX,
        uint256 _amountY,
        uint256 _slippageBips
    ) internal {
        if (!DEPOSITS_ENABLED) revert DepositsDisabled();
        uint256 maxPendingRewards = MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST;
        if (maxPendingRewards > 0) {
            uint256 estimatedTotalReward = checkReward();
            if (estimatedTotalReward > maxPendingRewards) {
                _reinvest(true);
            }
        }
        if (_amountX > 0) {
            IERC20(tokenX).safeTransferFrom(msg.sender, address(this), _amountX);
        }
        if (_amountY > 0) {
            IERC20(tokenY).safeTransferFrom(msg.sender, address(this), _amountY);
        }

        _mint(_account, sharesForDepositTokens(_amountX, _amountY));
        _userDeposit(_amountX, _amountY, _slippageBips);
        emit Deposit(_account, _amountX, _amountY);
    }

    function sharesForDepositTokens(uint256 _amountX, uint256 _amountY) public view returns (uint256) {
        (, , uint256 activeId) = lbPair.getReservesAndId();
        uint256 price = lbRouter.getPriceFromId(address(lbPair), uint24(activeId));
        uint256 amount = price.mulShiftRoundDown(_amountX, SCALE_OFFSET) + _amountY;

        (uint256 totalX, uint256 totalY, , ) = depositBalances();
        uint256 tDeposits = price.mulShiftRoundDown(totalX, SCALE_OFFSET) + totalY;
        if (totalSupply == 0 || tDeposits == 0) {
            return amount;
        }
        return (amount * totalSupply) / tDeposits;
    }

    function _userDeposit(
        uint256 _amountX,
        uint256 _amountY,
        uint256 _slippageBips
    ) internal {
        _addLiquidityToActiveBin(_amountX, _amountY, _slippageBips);
    }

    function _addLiquidityToActiveBin(
        uint256 _amountX,
        uint256 _amountY,
        uint256 _slippageBips
    ) internal returns (uint256[] memory binIds, uint256[] memory liquidityAdded) {
        uint256[] memory distribution = new uint256[](1);
        distribution[0] = 1e18;
        int256[] memory idDeltas = new int256[](1);
        (binIds, liquidityAdded) = _addLiquidity(
            _amountX,
            _amountY,
            distribution,
            distribution,
            idDeltas,
            _slippageBips
        );
        uint256 currentBinsLength = currentBins.length;
        for (uint256 i; i < currentBinsLength; i++) {
            if (currentBins[i] == binIds[0]) {
                return (binIds, liquidityAdded);
            }
        }
        currentBins.push(binIds[0]);
    }

    function _addLiquidity(
        uint256 _amountX,
        uint256 _amountY,
        uint256[] memory _distributionX,
        uint256[] memory _distributionY,
        int256[] memory _deltas,
        uint256 _slippageBips
    ) internal virtual returns (uint256[] memory binIds, uint256[] memory liquidityAdded) {
        if (_amountX == 0 && _amountY == 0) revert InsufficientLiquidityTooAdd();
        uint256 amountXmin = _amountX - (_amountX * _slippageBips) / BIPS_DIVISOR;
        uint256 amountYmin = _amountY - (_amountY * _slippageBips) / BIPS_DIVISOR;
        (, , uint256 activeBin) = lbPair.getReservesAndId();

        ILBRouter.LiquidityParameters memory liquidityParameters = ILBRouter.LiquidityParameters(
            tokenX,
            tokenY,
            binStep,
            _amountX,
            _amountY,
            amountXmin,
            amountYmin,
            activeBin,
            0,
            _deltas,
            _distributionX,
            _distributionY,
            address(this),
            block.timestamp
        );

        IERC20(tokenX).approve(address(lbRouter), _amountX);
        IERC20(tokenY).approve(address(lbRouter), _amountY);

        (binIds, liquidityAdded) = lbRouter.addLiquidity(liquidityParameters);
    }

    function withdraw(uint256 _shares) external override {
        (uint256 amountX, uint256 amountY) = _withdraw(_shares);
        if (amountX == 0 && amountY == 0) revert WithdrawAmountTooLow();
        if (amountX > 0) {
            IERC20(tokenX).safeTransfer(msg.sender, amountX);
        }
        if (amountY > 0) {
            IERC20(tokenY).safeTransfer(msg.sender, amountY);
        }
        _burn(msg.sender, _shares);
        emit Withdraw(msg.sender, amountX, amountY);
    }

    function depositTokensForShares(uint256 _shares) public view returns (uint256 amountX, uint256 amountY) {
        (amountX, amountY, , ) = depositBalances();
        if (totalSupply == 0 || amountX + amountY == 0) {
            return (0, 0);
        }
        amountX = (_shares * amountX) / totalSupply;
        amountY = (_shares * amountY) / totalSupply;
    }

    function _withdraw(uint256 _shares) internal returns (uint256 withdrawAmountX, uint256 withdrawAmountY) {
        uint256 amountX;
        uint256 amountY;
        uint256[] memory lbTokenAmounts;

        uint256[] memory binIds = currentBins;
        if (binIds.length > 0) {
            lbTokenAmounts = new uint256[](binIds.length);
            for (uint256 i; i < binIds.length; i++) {
                lbTokenAmounts[i] = _shares.mulDivRoundDown(lbPair.balanceOf(address(this), binIds[i]), totalSupply);

                (uint256 binReserveX, uint256 binReserveY) = lbPair.getBin(uint24(binIds[i]));
                uint256 tSupply = lbPair.totalSupply(binIds[i]);
                amountX += lbTokenAmounts[i].mulDivRoundDown(binReserveX, tSupply);
                amountY += lbTokenAmounts[i].mulDivRoundDown(binReserveY, tSupply);
            }
            return _removeLiquidity(amountX, amountY, lbTokenAmounts, binIds);
        }
    }

    function _removeLiquidity(
        uint256 totalXBalance,
        uint256 totalYBalance,
        uint256[] memory lbTokenAmounts,
        uint256[] memory ids
    ) internal returns (uint256 withdrawAmountX, uint256 withdrawAmountY) {
        lbPair.setApprovalForAll(address(lbRouter), true);
        (withdrawAmountX, withdrawAmountY) = lbRouter.removeLiquidity(
            tokenX,
            tokenY,
            uint16(binStep),
            totalXBalance,
            totalYBalance,
            ids,
            lbTokenAmounts,
            address(this),
            block.timestamp
        );
        lbPair.setApprovalForAll(address(lbRouter), false);
    }

    function reinvest() external override onlyEOA {
        _reinvest(false);
    }

    /**
     * @notice Reinvest rewards from staking contract to deposit tokens
     * @dev Reverts if the expected amount of tokens are not returned from the staking contract
     */
    function _reinvest(bool userDeposit) private {
        (uint256 rewardTokenBalance, uint256 tokenXConverted, uint256 tokenYConverted, uint256 total) = _checkReward();
        if (!userDeposit) {
            if (total < MIN_TOKENS_TO_REINVEST) revert ReinvestAmountTooLow();
        }

        lbPair.collectFees(address(this), currentBins);

        uint256 devFee = (total * DEV_FEE_BIPS) / BIPS_DIVISOR;
        uint256 reinvestFee = userDeposit ? 0 : (total * REINVEST_REWARD_BIPS) / BIPS_DIVISOR;
        uint256 feeTotal = devFee + reinvestFee;
        if (rewardTokenBalance < feeTotal) {
            if (tokenXConverted > tokenYConverted) {
                feeTotal = _swapFees(tokenX, swapPairTokenX, feeTotal);
            } else {
                feeTotal = _swapFees(tokenY, swapPairTokenY, feeTotal);
            }
        }
        payFees(devFee, reinvestFee, feeTotal);
        _addLiquidityToActiveBin(
            IERC20(tokenX).balanceOf(address(this)),
            IERC20(tokenY).balanceOf(address(this)),
            maxReinvestSlippage
        );

        (uint256 totalXBalance, uint256 totalYBalance, , ) = depositBalances();

        emit Reinvest(totalXBalance, totalYBalance, totalSupply);
    }

    function _swapFees(
        address _token,
        address _swapPair,
        uint256 _feeTotal
    ) internal returns (uint256) {
        if (_token == WAVAX) return _feeTotal;
        uint256 tokenInAmount = DexLibrary.estimateConversionThroughPair(
            _feeTotal,
            address(rewardToken),
            _token,
            IPair(_swapPair),
            DexLibrary.DEFAULT_SWAP_FEE
        );
        return
            DexLibrary.swap(tokenInAmount, _token, address(rewardToken), IPair(_swapPair), DexLibrary.DEFAULT_SWAP_FEE);
    }

    function payFees(
        uint256 _devFee,
        uint256 _reinvestFee,
        uint256 _feeTotal
    ) internal {
        if (_reinvestFee > 0) {
            rewardToken.safeTransfer(msg.sender, _feeTotal < _reinvestFee ? _feeTotal : _reinvestFee);
        }
        if (_devFee > 0) {
            rewardToken.safeTransfer(devAddr, _feeTotal - _reinvestFee);
        }
    }

    function checkReward() public view override returns (uint256) {
        (, , , uint256 totalReward) = _checkReward();
        return totalReward;
    }

    function _checkReward()
        internal
        view
        returns (
            uint256 rewardTokenBalance,
            uint256 tokenXConverted,
            uint256 tokenYConverted,
            uint256 total
        )
    {
        (uint256 amountX, uint256 amountY) = lbPair.pendingFees(address(this), currentBins);
        rewardTokenBalance = rewardToken.balanceOf(address(this));
        if (amountX > 0) {
            tokenXConverted = tokenX == WAVAX
                ? amountX
                : DexLibrary.estimateConversionThroughPair(
                    amountX,
                    tokenX,
                    address(rewardToken),
                    IPair(swapPairTokenX),
                    DexLibrary.DEFAULT_SWAP_FEE
                );
        }
        if (amountY > 0) {
            tokenYConverted = tokenY == WAVAX
                ? amountY
                : DexLibrary.estimateConversionThroughPair(
                    amountY,
                    tokenY,
                    address(rewardToken),
                    IPair(swapPairTokenY),
                    DexLibrary.DEFAULT_SWAP_FEE
                );
        }
        total = rewardTokenBalance + tokenXConverted + tokenYConverted;
    }

    function rebalance(
        uint256[] memory _distributionX,
        uint256[] memory _distributionY,
        int256[] memory _deltas,
        uint256 _slippageBips,
        address _gasRefundReceiver
    ) external onlyManager {
        uint256 gasleftBefore = gasleft();
        (uint256 withdrawAmountX, uint256 withdrawAmountY) = _removeAllLiquidity();
        (uint256 refundX, uint256 refundY) = _refundManager(withdrawAmountX, withdrawAmountY, _gasRefundReceiver);
        (currentBins, ) = _addLiquidity(
            withdrawAmountX - refundX,
            withdrawAmountY - refundY,
            _distributionX,
            _distributionY,
            _deltas,
            _slippageBips
        );
        rebalanceGasEstimate = gasleftBefore - gasleft();
    }

    function _removeAllLiquidity() internal returns (uint256 withdrawAmountX, uint256 withdrawAmountY) {
        (uint256 feeX, uint256 feeY) = lbPair.collectFees(address(this), currentBins);
        (
            uint256 totalXBalance,
            uint256 totalYBalance,
            uint256[] memory lbTokenAmounts,
            uint256[] memory ids
        ) = depositBalances();
        (withdrawAmountX, withdrawAmountY) = _removeLiquidity(totalXBalance, totalYBalance, lbTokenAmounts, ids);
        withdrawAmountX += feeX;
        withdrawAmountY += feeY;
        currentBins = new uint256[](0);
    }

    function _refundManager(
        uint256 _amountXTotal,
        uint256 _amountYTotal,
        address _gasRefundReceiver
    ) internal returns (uint256 tokenXUsed, uint256 tokenYUsed) {
        uint256 rebalanceGasUsage = rebalanceGasEstimate;
        if (rebalanceGasUsage > 0) {
            uint256 gasCostEstimate = rebalanceGasUsage * tx.gasprice;
            address tokenIn;
            uint256 tokenInAmount;
            address pair;
            if (_amountXTotal > 0) {
                tokenInAmount = DexLibrary.estimateConversionThroughPair(
                    gasCostEstimate,
                    WAVAX,
                    tokenX,
                    IPair(swapPairTokenX),
                    DexLibrary.DEFAULT_SWAP_FEE
                );
                if (_amountXTotal > tokenInAmount) {
                    tokenIn = tokenX;
                    tokenXUsed = tokenInAmount;
                    pair = swapPairTokenX;
                }
            }
            if (_amountYTotal > 0 && tokenIn == address(0)) {
                tokenInAmount = DexLibrary.estimateConversionThroughPair(
                    gasCostEstimate,
                    WAVAX,
                    tokenY,
                    IPair(swapPairTokenY),
                    DexLibrary.DEFAULT_SWAP_FEE
                );
                if (_amountYTotal > tokenInAmount) {
                    tokenIn = tokenY;
                    tokenYUsed = tokenInAmount;
                    pair = swapPairTokenY;
                }
            }
            if (tokenIn > address(0)) {
                uint256 refund = DexLibrary.swap(
                    tokenInAmount,
                    tokenIn,
                    WAVAX,
                    IPair(pair),
                    DexLibrary.DEFAULT_SWAP_FEE
                );
                IERC20(WAVAX).safeTransfer(_gasRefundReceiver > address(0) ? _gasRefundReceiver : manager, refund);
            }
        }
    }

    function depositBalances()
        public
        view
        returns (
            uint256 totalXBalance,
            uint256 totalYBalance,
            uint256[] memory lbTokenAmounts,
            uint256[] memory binIds
        )
    {
        binIds = currentBins;
        if (binIds.length > 0) {
            lbTokenAmounts = new uint256[](binIds.length);
            for (uint256 i; i < binIds.length; i++) {
                (uint256 binReserveX, uint256 binReserveY) = lbPair.getBin(uint24(binIds[i]));
                uint256 tSupply = lbPair.totalSupply(binIds[i]);

                lbTokenAmounts[i] = lbPair.balanceOf(address(this), binIds[i]);
                totalXBalance += lbTokenAmounts[i].mulDivRoundDown(binReserveX, tSupply);
                totalYBalance += lbTokenAmounts[i].mulDivRoundDown(binReserveY, tSupply);
            }
        }
    }

    function rescueDeployedFunds(
        uint256 _minReturnAmountAcceptedTokenX,
        uint256 _minReturnAmountAcceptedTokenY,
        uint256[] memory _bins
    ) external onlyOwner {
        uint256 xBalanceBefore = IERC20(tokenX).balanceOf(address(this));
        uint256 yBalanceBefore = IERC20(tokenY).balanceOf(address(this));

        if (_bins.length == 0) {
            _bins = currentBins;
        }
        uint256[] memory lbTokenAmounts = new uint256[](_bins.length);
        for (uint256 i; i < _bins.length; i++) {
            lbTokenAmounts[i] = lbPair.balanceOf(address(this), _bins[i]);
        }
        lbRouter.removeLiquidity(
            tokenX,
            tokenY,
            uint16(binStep),
            _minReturnAmountAcceptedTokenX,
            _minReturnAmountAcceptedTokenY,
            _bins,
            lbTokenAmounts,
            address(this),
            block.timestamp
        );

        uint256 xBalanceAfter = IERC20(tokenX).balanceOf(address(this));
        uint256 yBalanceAfter = IERC20(tokenY).balanceOf(address(this));
        if (xBalanceBefore - xBalanceAfter < _minReturnAmountAcceptedTokenX)
            revert EmergencyWithdrawMinimumXNotReached();

        if (yBalanceBefore - yBalanceAfter < _minReturnAmountAcceptedTokenY)
            revert EmergencyWithdrawMinimumYNotReached();

        (uint256 totalXBalance, uint256 totalYBalance, , ) = depositBalances();
        if (totalXBalance == 0 && totalYBalance == 0) {
            currentBins = new uint256[](0);
        }
        emit Reinvest(totalXBalance, totalYBalance, totalSupply);

        if (DEPOSITS_ENABLED == true) {
            updateDepositsEnabled(false);
        }
    }
}
