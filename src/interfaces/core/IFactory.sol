// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {IDebtToken} from "./IDebtToken.sol";
import {IStabilityPool} from "./IStabilityPool.sol";
import {IBorrowerOperations} from "./IBorrowerOperations.sol";
import {ILiquidationManager} from "./ILiquidationManager.sol";
import {ISortedTroves} from "./ISortedTroves.sol";
import {ITroveManager} from "./ITroveManager.sol";
import {ISatoshiCore} from "./ISatoshiCore.sol";
import {IPriceFeed} from "../dependencies/IPriceFeed.sol";
import {IPriceFeedAggregator} from "./IPriceFeedAggregator.sol";
import {IGasPool} from "./IGasPool.sol";
import {ISatoshiOwnable} from "../dependencies/ISatoshiOwnable.sol";
import {ICommunityIssuance} from "./ICommunityIssuance.sol";
import {IRewardManager} from "./IRewardManager.sol";

// commented values are suggested default parameters
struct DeploymentParams {
    uint256 minuteDecayFactor; // 999037758833783500  (half life of 12 hours)
    uint256 redemptionFeeFloor; // 1e18 / 1000 * 5  (0.5%)
    uint256 maxRedemptionFee; // 1e18  (100%)
    uint256 borrowingFeeFloor; // 1e18 / 1000 * 5  (0.5%)
    uint256 maxBorrowingFee; // 1e18 / 100 * 5  (5%)
    uint256 interestRateInBps; // 450 (4.5%)
    uint256 maxDebt; // 1e18 * 1000000000 (1 billion)
    uint256 MCR; // 11 * 1e17  (110%)
    uint128 rewardRate; // 57077625570776256 (9000000e18 / (5 * 31536000))
    uint256 OSHIAllocation; // 20 * _1_MILLION
    uint32 claimStartTime; // 1713542400  (2024-04-20 0:0:0)
}

interface IFactory is ISatoshiOwnable {
    event NewDeployment(
        IERC20 indexed collateral, IPriceFeed priceFeed, ITroveManager troveManager, ISortedTroves sortedTroves
    );

    function deployNewInstance(IERC20 collateralToken, IPriceFeed priceFeed, DeploymentParams memory params) external;

    function debtToken() external view returns (IDebtToken);

    function gasPool() external view returns (IGasPool);

    function priceFeedAggregatorProxy() external view returns (IPriceFeedAggregator);

    function borrowerOperationsProxy() external view returns (IBorrowerOperations);

    function liquidationManagerProxy() external view returns (ILiquidationManager);

    function stabilityPoolProxy() external view returns (IStabilityPool);

    function sortedTrovesBeacon() external view returns (IBeacon);

    function troveManagerBeacon() external view returns (IBeacon);

    function gasCompensation() external view returns (uint256);

    function troveManagerCount() external view returns (uint256);

    function troveManagers(uint256) external view returns (ITroveManager);

    function communityIssuance() external view returns (ICommunityIssuance);

    function setRewardRate(uint128[] calldata _numerator, uint128 _denominator) external;

    function maxRewardRate() external view returns (uint128);

    function initialize(
        ISatoshiCore _satoshiCore,
        IDebtToken _debtToken,
        IGasPool _gasPool,
        IPriceFeedAggregator _priceFeedAggregatorProxy,
        IBorrowerOperations _borrowerOperationsProxy,
        ILiquidationManager _liquidationManagerProxy,
        IStabilityPool _stabilityPoolProxy,
        IBeacon _sortedTrovesBeacon,
        IBeacon _troveManagerBeacon,
        ICommunityIssuance _communityIssuance,
        uint256 _gasCompensation
    ) external;
}
