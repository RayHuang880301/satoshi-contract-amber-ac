// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SatoshiOwnable} from "../dependencies/SatoshiOwnable.sol";
import {SatoshiMath} from "../dependencies/SatoshiMath.sol";
import {IDebtToken} from "../interfaces/core/IDebtToken.sol";
import {IFactory} from "../interfaces/core/IFactory.sol";
import {ILiquidationManager} from "../interfaces/core/ILiquidationManager.sol";
import {ISatoshiCore} from "../interfaces/core/ISatoshiCore.sol";
import {IStabilityPool, AccountDeposit, Snapshots, SunsetIndex, Queue} from "../interfaces/core/IStabilityPool.sol";
import {ICommunityIssuance} from "../interfaces/core/ICommunityIssuance.sol";
/**
 * @title Stability Pool Contract (Upgradeable)
 *        Mutated from:
 *        https://github.com/prisma-fi/prisma-contracts/blob/main/contracts/core/StabilityPool.sol
 *        https://github.com/liquity/dev/blob/main/packages/contracts/contracts/StabilityPool.sol
 *
 */

contract StabilityPool is IStabilityPool, SatoshiOwnable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public constant DECIMAL_PRECISION = 1e18;
    uint128 public constant SUNSET_DURATION = 180 days;
    uint256 public constant OSHI_EMISSION_DURATION = 5 * 365 days; // 5 years
    uint128 public constant MAX_REWARD_RATE = 63419583967529168; // 10_000_000e18 / (5 * 31536000)

    IDebtToken public debtToken;
    IFactory public factory;
    ILiquidationManager public liquidationManager;
    ICommunityIssuance public communityIssuance;

    // OSHI reward
    uint128 public rewardRate;
    uint32 public lastUpdate;
    uint32 public claimStartTime;

    // collateral => index
    mapping(IERC20 => uint256) public indexByCollateral;
    IERC20[] public collateralTokens;

    // Tracker for Debt held in the pool. Changes when users deposit/withdraw, and when Trove debt is offset.
    uint256 internal totalDebtTokenDeposits;

    mapping(address => AccountDeposit) public accountDeposits; // depositor address -> initial deposit
    mapping(address => Snapshots) public depositSnapshots; // depositor address -> snapshots struct

    // index values are mapped against the values within `collateralTokens`
    mapping(address => uint256[256]) public depositSums; // depositor address -> sums

    // depositor => gains
    mapping(address => uint80[256]) public collateralGainsByDepositor;

    mapping(address => uint256) private storedPendingReward;

    /*  Product 'P': Running product by which to multiply an initial deposit, in order to find the current compounded deposit,
     * after a series of liquidations have occurred, each of which cancel some debt with the deposit.
     *
     * During its lifetime, a deposit's value evolves from d_t to d_t * P / P_t , where P_t
     * is the snapshot of P taken at the instant the deposit was made. 18-digit decimal.
     */
    uint256 public P; // init to DECIMAL_PRECISION

    uint256 public constant SCALE_FACTOR = 1e9;

    // Each time the scale of P shifts by SCALE_FACTOR, the scale is incremented by 1
    uint128 public currentScale;

    // With each offset that fully empties the Pool, the epoch is incremented by 1
    uint128 public currentEpoch;

    /* collateral Gain sum 'S': During its lifetime, each deposit d_t earns a collateral gain of ( d_t * [S - S_t] )/P_t, where S_t
     * is the depositor's snapshot of S taken at the time t when the deposit was made.
     *
     * The 'S' sums are stored in a nested mapping (epoch => scale => sum):
     *
     * - The inner mapping records the sum S at different scales
     * - The outer mapping records the (scale => sum) mappings, for different epochs.
     */

    // index values are mapped against the values within `collateralTokens`
    mapping(uint128 => mapping(uint128 => uint256[256])) public epochToScaleToSums;

    /*
     * Similarly, the sum 'G' is used to calculate OSHI gains. During it's lifetime, each deposit d_t earns a OSHI gain of
     *  ( d_t * [G - G_t] )/P_t, where G_t is the depositor's snapshot of G taken at time t when the deposit was made.
     *
     *  OSHI reward events occur are triggered by depositor operations (new deposit, topup, withdrawal), and liquidations.
     *  In each case, the OSHI reward is issued (i.e. G is updated), before other state changes are made.
     */
    mapping(uint128 => mapping(uint128 => uint256)) public epochToScaleToG;

    // Error tracker for the error correction in the OSHI issuance calculation
    uint256 public lastOSHIError;
    // Error trackers for the error correction in the OSHI offset calculation
    uint256[256] public lastCollateralError_Offset;
    uint256 public lastDebtLossError_Offset;

    mapping(uint16 => SunsetIndex) _sunsetIndexes;
    Queue queue;

    constructor() {
        _disableInitializers();
    }

    /// @notice Override the _authorizeUpgrade function inherited from UUPSUpgradeable contract
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        // No additional authorization logic is needed for this contract
    }

    function initialize(
        ISatoshiCore _satoshiCore,
        IDebtToken _debtToken,
        IFactory _factory,
        ILiquidationManager _liquidationManager,
        ICommunityIssuance _communityIssuance
    ) external initializer {
        __UUPSUpgradeable_init_unchained();
        __SatoshiOwnable_init(_satoshiCore);
        debtToken = _debtToken;
        factory = _factory;
        liquidationManager = _liquidationManager;
        P = DECIMAL_PRECISION;
        communityIssuance = _communityIssuance;
        lastUpdate = uint32(block.timestamp);
    }

    function enableCollateral(IERC20 _collateral) external {
        require(msg.sender == address(factory), "Not factory");
        uint256 length = collateralTokens.length;
        bool collateralEnabled;
        for (uint256 i = 0; i < length; i++) {
            if (collateralTokens[i] == _collateral) {
                collateralEnabled = true;
                break;
            }
        }
        if (!collateralEnabled) {
            Queue memory queueCached = queue;
            if (queueCached.nextSunsetIndexKey > queueCached.firstSunsetIndexKey) {
                SunsetIndex memory sIdx = _sunsetIndexes[queueCached.firstSunsetIndexKey];
                if (sIdx.expiry < block.timestamp) {
                    delete _sunsetIndexes[queue.firstSunsetIndexKey++];
                    _overwriteCollateral(_collateral, sIdx.idx);
                    return;
                }
            }
            collateralTokens.push(_collateral);
            indexByCollateral[_collateral] = collateralTokens.length;
        } else {
            // revert if the factory is trying to deploy a new TM with a sunset collateral
            require(indexByCollateral[_collateral] > 0, "Collateral is sunsetting");
        }
    }

    function _overwriteCollateral(IERC20 _newCollateral, uint256 idx) internal {
        require(indexByCollateral[_newCollateral] == 0, "Collateral must be sunset");
        uint256 length = collateralTokens.length;
        require(idx < length, "Index too large");
        uint256 externalLoopEnd = currentEpoch;
        uint256 internalLoopEnd = currentScale;
        for (uint128 i; i <= externalLoopEnd;) {
            for (uint128 j; j <= internalLoopEnd;) {
                epochToScaleToSums[i][j][idx] = 0;
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
        indexByCollateral[_newCollateral] = idx + 1;
        emit CollateralOverwritten(collateralTokens[idx], _newCollateral);
        collateralTokens[idx] = _newCollateral;
    }

    function setRewardRate(uint128 _newRewardRate) external onlyOwner {
        require(_newRewardRate <= MAX_REWARD_RATE, "StabilityPool: Reward rate too high");
        _triggerOSHIIssuance();
        rewardRate = _newRewardRate;
        emit RewardRateUpdated(_newRewardRate);
    }

    /**
     * @notice Starts sunsetting a collateral
     *         During sunsetting liquidated collateral handoff to the SP will revert
     *     @dev IMPORTANT: When sunsetting a collateral, `TroveManager.startSunset`
     *                     should be called on all TM linked to that collateral
     *     @param collateral Collateral to sunset
     */
    function startCollateralSunset(IERC20 collateral) external onlyOwner {
        require(indexByCollateral[collateral] > 0, "Collateral already sunsetting");
        _sunsetIndexes[queue.nextSunsetIndexKey++] =
            SunsetIndex(uint128(indexByCollateral[collateral] - 1), uint128(block.timestamp + SUNSET_DURATION));
        delete indexByCollateral[collateral]; //This will prevent calls to the SP in case of liquidations
        emit CollateralSunset(address(collateral));
    }

    function getTotalDebtTokenDeposits() external view returns (uint256) {
        return totalDebtTokenDeposits;
    }

    // --- External Depositor Functions ---

    /*  provideToSP():
     *
     * - Triggers a Satoshi issuance, based on time passed since the last issuance. The Satoshi issuance is shared between *all* depositors and front ends
     * - Tags the deposit with the provided front end tag param, if it's a new deposit
     * - Sends depositor's accumulated gains (Satoshi, collateral) to depositor
     * - Sends the tagged front end's accumulated Satoshi gains to the tagged front end
     * - Increases deposit and tagged front end's stake, and takes new snapshots for each.
     */
    function provideToSP(uint256 _amount) external {
        require(!SATOSHI_CORE.paused(), "Deposits are paused");
        require(_amount > 0, "StabilityPool: Amount must be non-zero");

        _triggerOSHIIssuance();

        _accrueDepositorCollateralGain(msg.sender);

        uint256 compoundedDebtDeposit = getCompoundedDebtDeposit(msg.sender);

        _accrueRewards(msg.sender);

        debtToken.sendToSP(msg.sender, _amount);
        uint256 newTotalDebtTokenDeposits = totalDebtTokenDeposits + _amount;
        totalDebtTokenDeposits = newTotalDebtTokenDeposits;
        emit StabilityPoolDebtBalanceUpdated(newTotalDebtTokenDeposits);

        uint256 newDeposit = compoundedDebtDeposit + _amount;
        accountDeposits[msg.sender] = AccountDeposit({amount: uint128(newDeposit), timestamp: uint128(block.timestamp)});

        _updateSnapshots(msg.sender, newDeposit);
        emit UserDepositChanged(msg.sender, newDeposit);
    }

    /*  withdrawFromSP():
     *
     * - Triggers a Satoshi issuance, based on time passed since the last issuance. The Satoshi issuance is shared between *all* depositors and front ends
     * - Removes the deposit's front end tag if it is a full withdrawal
     * - Sends all depositor's accumulated gains (Satoshi, collateral) to depositor
     * - Sends the tagged front end's accumulated Satoshi gains to the tagged front end
     * - Decreases deposit and tagged front end's stake, and takes new snapshots for each.
     *
     * If _amount > userDeposit, the user withdraws all of their compounded deposit.
     */
    function withdrawFromSP(uint256 _amount) external {
        uint256 initialDeposit = accountDeposits[msg.sender].amount;
        uint128 depositTimestamp = accountDeposits[msg.sender].timestamp;
        require(initialDeposit > 0, "StabilityPool: User must have a non-zero deposit");
        require(depositTimestamp < block.timestamp, "!Deposit and withdraw same block");

        _triggerOSHIIssuance();

        _accrueDepositorCollateralGain(msg.sender);

        uint256 compoundedDebtDeposit = getCompoundedDebtDeposit(msg.sender);
        uint256 debtToWithdraw = SatoshiMath._min(_amount, compoundedDebtDeposit);

        _accrueRewards(msg.sender);

        if (debtToWithdraw > 0) {
            debtToken.returnFromPool(address(this), msg.sender, debtToWithdraw);
            _decreaseDebt(debtToWithdraw);
        }

        // Update deposit
        uint256 newDeposit = compoundedDebtDeposit - debtToWithdraw;
        accountDeposits[msg.sender] = AccountDeposit({amount: uint128(newDeposit), timestamp: depositTimestamp});

        _updateSnapshots(msg.sender, newDeposit);
        emit UserDepositChanged(msg.sender, newDeposit);
    }

    // --- Liquidation functions ---

    /*
     * Cancels out the specified debt against the Debt contained in the Stability Pool (as far as possible)
     */
    function offset(IERC20 collateral, uint256 _debtToOffset, uint256 _collToAdd) external virtual {
        _offset(collateral, _debtToOffset, _collToAdd);
    }

    function _offset(IERC20 collateral, uint256 _debtToOffset, uint256 _collToAdd) internal {
        require(msg.sender == address(liquidationManager), "StabilityPool: Caller is not Liquidation Manager");
        uint256 idx = indexByCollateral[collateral];
        idx -= 1;

        uint256 totalDebt = totalDebtTokenDeposits; // cached to save an SLOAD
        if (totalDebt == 0 || _debtToOffset == 0) {
            return;
        }

        _triggerOSHIIssuance();

        uint8 _decimals = IERC20Metadata(address(collateral)).decimals();
        uint256 scaledCollToAdd = SatoshiMath._getScaledCollateralAmount(_collToAdd, _decimals);

        (uint256 collateralGainPerUnitStaked, uint256 debtLossPerUnitStaked) =
            _computeRewardsPerUnitStaked(scaledCollToAdd, _debtToOffset, totalDebt, idx);

        _updateRewardSumAndProduct(collateralGainPerUnitStaked, debtLossPerUnitStaked, idx); // updates S and P

        // Cancel the liquidated Debt debt with the Debt in the stability pool
        _decreaseDebt(_debtToOffset);
    }

    // --- Offset helper functions ---

    function _computeRewardsPerUnitStaked(
        uint256 _collToAdd,
        uint256 _debtToOffset,
        uint256 _totalDebtTokenDeposits,
        uint256 idx
    ) internal returns (uint256 collateralGainPerUnitStaked, uint256 debtLossPerUnitStaked) {
        /*
         * Compute the Debt and collateral rewards. Uses a "feedback" error correction, to keep
         * the cumulative error in the P and S state variables low:
         *
         * 1) Form numerators which compensate for the floor division errors that occurred the last time this
         * function was called.
         * 2) Calculate "per-unit-staked" ratios.
         * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
         * 4) Store these errors for use in the next correction when this function is called.
         * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
         */
        uint256 collateralNumerator = (_collToAdd * DECIMAL_PRECISION) + lastCollateralError_Offset[idx];

        if (_debtToOffset == _totalDebtTokenDeposits) {
            debtLossPerUnitStaked = DECIMAL_PRECISION; // When the Pool depletes to 0, so does each deposit
            lastDebtLossError_Offset = 0;
        } else {
            uint256 debtLossNumerator = (_debtToOffset * DECIMAL_PRECISION) - lastDebtLossError_Offset;
            /*
             * Add 1 to make error in quotient positive. We want "slightly too much" Debt loss,
             * which ensures the error in any given compoundedDebtDeposit favors the Stability Pool.
             */
            debtLossPerUnitStaked = (debtLossNumerator / _totalDebtTokenDeposits) + 1;
            lastDebtLossError_Offset = (debtLossPerUnitStaked * _totalDebtTokenDeposits) - debtLossNumerator;
        }

        collateralGainPerUnitStaked = collateralNumerator / _totalDebtTokenDeposits;
        lastCollateralError_Offset[idx] = collateralNumerator - (collateralGainPerUnitStaked * _totalDebtTokenDeposits);

        return (collateralGainPerUnitStaked, debtLossPerUnitStaked);
    }

    // Update the Stability Pool reward sum S and product P
    function _updateRewardSumAndProduct(
        uint256 _collateralGainPerUnitStaked,
        uint256 _debtLossPerUnitStaked,
        uint256 idx
    ) internal {
        uint256 currentP = P;
        uint256 newP;

        /*
         * The newProductFactor is the factor by which to change all deposits, due to the depletion of Stability Pool Debt in the liquidation.
         * We make the product factor 0 if there was a pool-emptying. Otherwise, it is (1 - DebtLossPerUnitStaked)
         */
        uint256 newProductFactor = uint256(DECIMAL_PRECISION) - _debtLossPerUnitStaked;

        uint128 currentScaleCached = currentScale;
        uint128 currentEpochCached = currentEpoch;
        uint256 currentS = epochToScaleToSums[currentEpochCached][currentScaleCached][idx];

        /*
         * Calculate the new S first, before we update P.
         * The collateral gain for any given depositor from a liquidation depends on the value of their deposit
         * (and the value of totalDeposits) prior to the Stability being depleted by the debt in the liquidation.
         *
         * Since S corresponds to collateral gain, and P to deposit loss, we update S first.
         */
        uint256 marginalCollateralGain = _collateralGainPerUnitStaked * currentP;
        uint256 newS = currentS + marginalCollateralGain;
        epochToScaleToSums[currentEpochCached][currentScaleCached][idx] = newS;
        emit S_Updated(idx, newS, currentEpochCached, currentScaleCached);

        // If the Stability Pool was emptied, increment the epoch, and reset the scale and product P
        if (newProductFactor == 0) {
            currentEpoch = currentEpochCached + 1;
            emit EpochUpdated(currentEpoch);
            currentScale = 0;
            emit ScaleUpdated(currentScale);
            newP = DECIMAL_PRECISION;

            // If multiplying P by a non-zero product factor would reduce P below the scale boundary, increment the scale
        } else if ((currentP * newProductFactor) / DECIMAL_PRECISION < SCALE_FACTOR) {
            newP = (currentP * newProductFactor * SCALE_FACTOR) / DECIMAL_PRECISION;
            currentScale = currentScaleCached + 1;
            emit ScaleUpdated(currentScale);
        } else {
            newP = (currentP * newProductFactor) / DECIMAL_PRECISION;
        }

        require(newP > 0, "NewP");
        P = newP;
        emit P_Updated(newP);
    }

    function _decreaseDebt(uint256 _amount) internal {
        uint256 newTotalDebtTokenDeposits = totalDebtTokenDeposits - _amount;
        totalDebtTokenDeposits = newTotalDebtTokenDeposits;
        emit StabilityPoolDebtBalanceUpdated(newTotalDebtTokenDeposits);
    }

    // --- Reward calculator functions for depositor ---

    /* Calculates the collateral gain earned by the deposit since its last snapshots were taken.
     * Given by the formula:  E = d0 * (S - S(0))/P(0)
     * where S(0) and P(0) are the depositor's snapshots of the sum S and product P, respectively.
     * d0 is the last recorded deposit value.
     */
    function getDepositorCollateralGain(address _depositor) external view returns (uint256[] memory collateralGains) {
        collateralGains = new uint256[](collateralTokens.length);
        uint80[256] storage depositorGains = collateralGainsByDepositor[_depositor];
        for (uint256 i = 0; i < collateralGains.length; i++) {
            collateralGains[i] = depositorGains[i];
        }

        uint256 P_Snapshot = depositSnapshots[_depositor].P;
        if (P_Snapshot == 0) return collateralGains;
        uint256 initialDeposit = accountDeposits[_depositor].amount;
        uint128 epochSnapshot = depositSnapshots[_depositor].epoch;
        uint128 scaleSnapshot = depositSnapshots[_depositor].scale;
        uint256[256] storage sums = epochToScaleToSums[epochSnapshot][scaleSnapshot];
        uint256[256] storage nextSums = epochToScaleToSums[epochSnapshot][scaleSnapshot + 1];
        uint256[256] storage depSums = depositSums[_depositor];

        for (uint256 i = 0; i < collateralGains.length; i++) {
            if (sums[i] == 0) continue; // Collateral was overwritten or not gains
            uint256 firstPortion = sums[i] - depSums[i];
            uint256 secondPortion = nextSums[i] / SCALE_FACTOR;
            uint8 _decimals = IERC20Metadata(address(collateralTokens[i])).decimals();
            collateralGains[i] += initialDeposit
                * SatoshiMath._getOriginalCollateralAmount(firstPortion + secondPortion, _decimals) / P_Snapshot
                / DECIMAL_PRECISION;
        }
        return collateralGains;
    }

    function _accrueDepositorCollateralGain(address _depositor) private returns (bool hasGains) {
        uint80[256] storage depositorGains = collateralGainsByDepositor[_depositor];
        uint256 collaterals = collateralTokens.length;
        uint256 initialDeposit = accountDeposits[_depositor].amount;
        hasGains = false;
        if (initialDeposit == 0) {
            return hasGains;
        }

        uint128 epochSnapshot = depositSnapshots[_depositor].epoch;
        uint128 scaleSnapshot = depositSnapshots[_depositor].scale;
        uint256 P_Snapshot = depositSnapshots[_depositor].P;

        uint256[256] storage sums = epochToScaleToSums[epochSnapshot][scaleSnapshot];
        uint256[256] storage nextSums = epochToScaleToSums[epochSnapshot][scaleSnapshot + 1];
        uint256[256] storage depSums = depositSums[_depositor];

        for (uint256 i = 0; i < collaterals; i++) {
            if (sums[i] == 0) continue; // Collateral was overwritten or not gains
            hasGains = true;
            uint256 firstPortion = sums[i] - depSums[i];
            uint256 secondPortion = nextSums[i] / SCALE_FACTOR;
            uint8 _decimals = IERC20Metadata(address(collateralTokens[i])).decimals();
            depositorGains[i] += uint80(
                (
                    initialDeposit * SatoshiMath._getOriginalCollateralAmount(firstPortion + secondPortion, _decimals)
                        / P_Snapshot / DECIMAL_PRECISION
                )
            );
        }
        return (hasGains);
    }

    /*
     * Calculate the OSHI gain earned by a deposit since its last snapshots were taken.
     * Given by the formula:  OSHI = d0 * (G - G(0))/P(0)
     * where G(0) and P(0) are the depositor's snapshots of the sum G and product P, respectively.
     * d0 is the last recorded deposit value.
     */
    function claimableReward(address _depositor) external view returns (uint256) {
        uint256 totalDebt = totalDebtTokenDeposits;
        uint256 initialDeposit = accountDeposits[_depositor].amount;

        if (totalDebt == 0 || initialDeposit == 0) {
            return storedPendingReward[_depositor] + _claimableReward(_depositor);
        }

        Snapshots memory snapshots = depositSnapshots[_depositor];
        uint128 epochSnapshot = snapshots.epoch;
        uint128 scaleSnapshot = snapshots.scale;
        uint256 oshiNumerator = (_OSHIIssuance() * DECIMAL_PRECISION) + lastOSHIError;
        uint256 oshiPerUnitStaked = oshiNumerator / totalDebt;
        uint256 marginalOSHIGain = (epochSnapshot == currentEpoch) ? oshiPerUnitStaked * P : 0;
        uint256 firstPortion;
        uint256 secondPortion;

        if (scaleSnapshot == currentScale) {
            firstPortion = epochToScaleToG[epochSnapshot][scaleSnapshot] - snapshots.G + marginalOSHIGain;
            secondPortion = epochToScaleToG[epochSnapshot][scaleSnapshot + 1] / SCALE_FACTOR;
        } else {
            firstPortion = epochToScaleToG[epochSnapshot][scaleSnapshot] - snapshots.G;
            secondPortion = (epochToScaleToG[epochSnapshot][scaleSnapshot + 1] + marginalOSHIGain) / SCALE_FACTOR;
        }

        return storedPendingReward[_depositor]
            + (initialDeposit * (firstPortion + secondPortion)) / snapshots.P / DECIMAL_PRECISION;
    }

    function _claimableReward(address _depositor) private view returns (uint256) {
        uint256 initialDeposit = accountDeposits[_depositor].amount;
        if (initialDeposit == 0) {
            return 0;
        }

        Snapshots memory snapshots = depositSnapshots[_depositor];

        return _getOSHIGainFromSnapshots(initialDeposit, snapshots);
    }

    function _getOSHIGainFromSnapshots(uint256 initialStake, Snapshots memory snapshots)
        internal
        view
        returns (uint256)
    {
        /*
         * Grab the sum 'G' from the epoch at which the stake was made. The OSHI gain may span up to one scale change.
         * If it does, the second portion of the OSHI gain is scaled by 1e9.
         * If the gain spans no scale change, the second portion will be 0.
         */
        uint128 epochSnapshot = snapshots.epoch;
        uint128 scaleSnapshot = snapshots.scale;
        uint256 G_Snapshot = snapshots.G;
        uint256 P_Snapshot = snapshots.P;

        uint256 firstPortion = epochToScaleToG[epochSnapshot][scaleSnapshot] - G_Snapshot;
        uint256 secondPortion = epochToScaleToG[epochSnapshot][scaleSnapshot + 1] / SCALE_FACTOR;

        uint256 OSHIGain = (initialStake * (firstPortion + secondPortion)) / P_Snapshot / DECIMAL_PRECISION;

        return OSHIGain;
    }

    // --- Compounded deposit ---

    /*
     * Return the user's compounded deposit. Given by the formula:  d = d0 * P/P(0)
     * where P(0) is the depositor's snapshot of the product P, taken when they last updated their deposit.
     */
    function getCompoundedDebtDeposit(address _depositor) public view returns (uint256) {
        uint256 initialDeposit = accountDeposits[_depositor].amount;
        if (initialDeposit == 0) {
            return 0;
        }

        Snapshots memory snapshots = depositSnapshots[_depositor];

        uint256 compoundedDeposit = _getCompoundedStakeFromSnapshots(initialDeposit, snapshots);
        return compoundedDeposit;
    }

    // Internal function, used to calculcate compounded deposits and compounded front end stakes.
    function _getCompoundedStakeFromSnapshots(uint256 initialStake, Snapshots memory snapshots)
        internal
        view
        returns (uint256)
    {
        uint256 snapshot_P = snapshots.P;
        uint128 scaleSnapshot = snapshots.scale;
        uint128 epochSnapshot = snapshots.epoch;

        // If stake was made before a pool-emptying event, then it has been fully cancelled with debt -- so, return 0
        if (epochSnapshot < currentEpoch) {
            return 0;
        }

        uint256 compoundedStake;
        uint128 scaleDiff = currentScale - scaleSnapshot;

        /* Compute the compounded stake. If a scale change in P was made during the stake's lifetime,
         * account for it. If more than one scale change was made, then the stake has decreased by a factor of
         * at least 1e-9 -- so return 0.
         */
        if (scaleDiff == 0) {
            compoundedStake = (initialStake * P) / snapshot_P;
        } else if (scaleDiff == 1) {
            compoundedStake = (initialStake * P) / snapshot_P / SCALE_FACTOR;
        } else {
            // if scaleDiff >= 2
            compoundedStake = 0;
        }

        /*
         * If compounded deposit is less than a billionth of the initial deposit, return 0.
         *
         * NOTE: originally, this line was in place to stop rounding errors making the deposit too large. However, the error
         * corrections should ensure the error in P "favors the Pool", i.e. any given compounded deposit should slightly less
         * than it's theoretical value.
         *
         * Thus it's unclear whether this line is still really needed.
         */
        if (compoundedStake < initialStake / 1e9) {
            return 0;
        }

        return compoundedStake;
    }

    // --- Sender functions for Debt deposit, collateral gains and Satoshi gains ---
    function claimCollateralGains(address recipient, uint256[] calldata collateralIndexes) public virtual {
        uint256 compoundedDebtDeposit = getCompoundedDebtDeposit(msg.sender);
        uint128 depositTimestamp = accountDeposits[msg.sender].timestamp;
        _accrueDepositorCollateralGain(msg.sender);

        uint256 loopEnd = collateralIndexes.length;
        uint256[] memory collateralGains = new uint256[](collateralTokens.length);

        uint80[256] storage depositorGains = collateralGainsByDepositor[msg.sender];
        for (uint256 i; i < loopEnd;) {
            uint256 collateralIndex = collateralIndexes[i];
            uint256 gains = depositorGains[collateralIndex];
            if (gains > 0) {
                collateralGains[collateralIndex] = gains;
                depositorGains[collateralIndex] = 0;
                collateralTokens[collateralIndex].safeTransfer(recipient, gains);
            }
            unchecked {
                ++i;
            }
        }
        accountDeposits[msg.sender] =
            AccountDeposit({amount: uint128(compoundedDebtDeposit), timestamp: depositTimestamp});
        _updateSnapshots(msg.sender, compoundedDebtDeposit);
        emit CollateralGainWithdrawn(msg.sender, collateralGains);
    }

    // --- Stability Pool Deposit Functionality ---

    function _updateSnapshots(address _depositor, uint256 _newValue) internal {
        uint256 length;
        if (_newValue == 0) {
            delete depositSnapshots[_depositor];

            length = collateralTokens.length;
            for (uint256 i = 0; i < length; i++) {
                depositSums[_depositor][i] = 0;
            }
            emit DepositSnapshotUpdated(_depositor, 0, 0);
            return;
        }
        uint128 currentScaleCached = currentScale;
        uint128 currentEpochCached = currentEpoch;
        uint256 currentP = P;

        // Get S and G for the current epoch and current scale
        uint256[256] storage currentS = epochToScaleToSums[currentEpochCached][currentScaleCached];
        uint256 currentG = epochToScaleToG[currentEpochCached][currentScaleCached];

        // Record new snapshots of the latest running product P, sum S, and sum G, for the depositor
        depositSnapshots[_depositor].P = currentP;
        depositSnapshots[_depositor].G = currentG;
        depositSnapshots[_depositor].scale = currentScaleCached;
        depositSnapshots[_depositor].epoch = currentEpochCached;

        length = collateralTokens.length;
        for (uint256 i = 0; i < length; i++) {
            depositSums[_depositor][i] = currentS[i];
        }

        emit DepositSnapshotUpdated(_depositor, currentP, currentG);
    }

    // --- OSHI issuance functions ---
    function _triggerOSHIIssuance() internal {
        uint256 OSHIIssuance = _OSHIIssuance();
        communityIssuance.collectAllocatedTokens(OSHIIssuance);
        _updateG(OSHIIssuance);
        lastUpdate = uint32(block.timestamp);
    }

    function _OSHIIssuance() internal view returns (uint256) {
        uint256 duration = block.timestamp - lastUpdate;
        uint256 releasedToken = duration * rewardRate;
        uint256 allocatedToken = communityIssuance.allocated(address(this));
        // check the allocated token in community issuance
        if (releasedToken > allocatedToken) {
            releasedToken = allocatedToken;
        }
        return releasedToken;
    }

    function _updateG(uint256 OSHIIssuance) internal {
        uint256 totalDebt = totalDebtTokenDeposits; // cached to save an SLOAD
        /*
         * When total deposits is 0, G is not updated. In this case, the OSHI issued can not be obtained by later
         * depositors - it is missed out on, and remains in the balanceof the Treasury contract.
         *
         */
        if (totalDebt == 0 || OSHIIssuance == 0) {
            return;
        }

        uint256 oshiPerUnitStaked;
        oshiPerUnitStaked = _computeOSHIPerUnitStaked(OSHIIssuance, totalDebt);
        uint128 currentEpochCached = currentEpoch;
        uint128 currentScaleCached = currentScale;
        uint256 marginalOSHIGain = oshiPerUnitStaked * P;
        uint256 newG = epochToScaleToG[currentEpochCached][currentScaleCached] + marginalOSHIGain;
        epochToScaleToG[currentEpochCached][currentScaleCached] = newG;

        emit G_Updated(newG, currentEpochCached, currentScaleCached);
    }

    function _computeOSHIPerUnitStaked(uint256 OSHIIssuance, uint256 _totalDebtTokenDeposits)
        internal
        returns (uint256)
    {
        /*
        * Calculate the OSHI-per-unit staked.  Division uses a "feedback" error correction, to keep the
        * cumulative error low in the running total G:
        *
        * 1) Form a numerator which compensates for the floor division error that occurred the last time this
        * function was called.
        * 2) Calculate "per-unit-staked" ratio.
        * 3) Multiply the ratio back by its denominator, to reveal the current floor division error.
        * 4) Store this error for use in the next correction when this function is called.
        * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
        */
        uint256 OSHINumerator = (OSHIIssuance * DECIMAL_PRECISION) + lastOSHIError;

        uint256 OSHIPerUnitStaked = OSHINumerator / _totalDebtTokenDeposits;
        lastOSHIError = OSHINumerator - (OSHIPerUnitStaked * _totalDebtTokenDeposits);

        return OSHIPerUnitStaked;
    }

    // --- Reward ---
    function _accrueRewards(address _depositor) internal {
        uint256 amount = _claimableReward(_depositor);
        storedPendingReward[_depositor] = storedPendingReward[_depositor] + amount;
    }

    function claimReward(address recipient) external returns (uint256 amount) {
        require(isClaimStart(), "StabilityPool: Claim not started");
        amount = _claimReward(msg.sender);

        if (amount > 0) {
            communityIssuance.transferAllocatedTokens(recipient, amount);
        }
        emit RewardClaimed(msg.sender, recipient, amount);
        return amount;
    }

    function _claimReward(address account) internal returns (uint256 amount) {
        uint256 initialDeposit = accountDeposits[account].amount;

        if (initialDeposit > 0) {
            uint128 depositTimestamp = accountDeposits[account].timestamp;
            _triggerOSHIIssuance();
            bool hasGains = _accrueDepositorCollateralGain(account);

            uint256 compoundedDebtDeposit = getCompoundedDebtDeposit(account);
            uint256 debtLoss = initialDeposit - compoundedDebtDeposit;

            amount = _claimableReward(account);
            // we update only if the snapshot has changed
            if (debtLoss > 0 || hasGains || amount > 0) {
                // Update deposit
                accountDeposits[account] =
                    AccountDeposit({amount: uint128(compoundedDebtDeposit), timestamp: depositTimestamp});
                _updateSnapshots(account, compoundedDebtDeposit);
            }
        }
        uint256 pending = storedPendingReward[account];
        if (pending > 0) {
            amount += pending;
            storedPendingReward[account] = 0;
        }
        return amount;
    }

    // set the time when the OSHI claim starts
    function setClaimStartTime(uint32 _claimStartTime) external onlyOwner {
        claimStartTime = _claimStartTime;
        emit ClaimStartTimeSet(_claimStartTime);
    }

    // check the start time
    function isClaimStart() public view returns (bool) {
        return claimStartTime <= uint32(block.timestamp);
    }
}
