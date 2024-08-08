// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISortedTroves} from "../src/interfaces/core/ISortedTroves.sol";
import {ITroveManager, TroveManagerOperation} from "../src/interfaces/core/ITroveManager.sol";
import {IMultiCollateralHintHelpers} from "../src/helpers/interfaces/IMultiCollateralHintHelpers.sol";
import {SatoshiMath} from "../src/dependencies/SatoshiMath.sol";
import {DeployBase, LocalVars} from "./utils/DeployBase.t.sol";
import {HintLib} from "./utils/HintLib.sol";
import {DEPLOYER, OWNER, GAS_COMPENSATION, TestConfig} from "./TestConfig.sol";
import {TroveBase} from "./utils/TroveBase.t.sol";
import {Events} from "./utils/Events.sol";
import {RoundData} from "../src/mocks/OracleMock.sol";

contract RecoveryModeTest is Test, DeployBase, TroveBase, TestConfig, Events {
    using Math for uint256;

    ISortedTroves sortedTrovesBeaconProxy;
    ITroveManager troveManagerBeaconProxy;
    IMultiCollateralHintHelpers hintHelpers;
    address user1;
    address user2;
    address user3;
    address user4;
    uint256 maxFeePercentage = 0.05e18; // 5%

    function setUp() public override {
        super.setUp();

        // testing user
        user1 = vm.addr(1);
        user2 = vm.addr(2);
        user3 = vm.addr(3);
        user4 = vm.addr(4);

        // setup contracts and deploy one instance
        (sortedTrovesBeaconProxy, troveManagerBeaconProxy) = _deploySetupAndInstance(
            DEPLOYER, OWNER, ORACLE_MOCK_DECIMALS, ORACLE_MOCK_VERSION, initRoundData, collateralMock, deploymentParams
        );

        // deploy hint helper contract
        hintHelpers = IMultiCollateralHintHelpers(_deployHintHelpers(DEPLOYER));
    }

    // utils
    function _openTrove(address caller, uint256 collateralAmt, uint256 debtAmt) internal {
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            caller,
            caller,
            collateralMock,
            collateralAmt,
            debtAmt,
            maxFeePercentage
        );
    }

    function _provideToSP(address caller, uint256 amount) internal {
        TroveBase.provideToSP(stabilityPoolProxy, caller, amount);
    }

    function _withdrawFromSP(address caller, uint256 amount) internal {
        TroveBase.withdrawFromSP(stabilityPoolProxy, caller, amount);
    }

    function _updateRoundData(RoundData memory data) internal {
        TroveBase.updateRoundData(oracleMockAddr, DEPLOYER, data);
    }

    function _claimCollateralGains(address caller) internal {
        vm.startPrank(caller);
        uint256[] memory collateralIndexes = new uint256[](1);
        collateralIndexes[0] = 0;
        stabilityPoolProxy.claimCollateralGains(caller, collateralIndexes);
        vm.stopPrank();
    }

    function test_checkRecoveryMode() public {
        // open troves
        _openTrove(user1, 1e18, 10000e18);
        _openTrove(user2, 1e18, 10000e18);
        _openTrove(user3, 1e18, 10000e18);

        // reducing TCR below 150%, and all Troves below 100% ICR
        _updateRoundData(
            RoundData({
                answer: 10000_00_000_000, // 10000
                startedAt: block.timestamp,
                updatedAt: block.timestamp,
                answeredInRound: 1
            })
        );

        uint256 TCR = borrowerOperationsProxy.getTCR();
        bool isRecoveryMode = borrowerOperationsProxy.checkRecoveryMode(TCR);
        assertTrue(isRecoveryMode);
    }

    // top up and borrow
    function test_adjustTorveInRecoveryMode() public {
        LocalVars memory vars;
        vars.maxFeePercentage = 0.05e18; // 5%

        // open troves
        _openTrove(user1, 1e18, 10000e18);
        _openTrove(user2, 1e18, 10000e18);
        _openTrove(user3, 1e18, 10000e18);

        // reducing TCR below 150%, and all Troves below 100% ICR
        _updateRoundData(
            RoundData({
                answer: 10000_00_000_000, // 10000
                startedAt: block.timestamp,
                updatedAt: block.timestamp,
                answeredInRound: 1
            })
        );

        // user 1 top up and borrow
        vars.addCollAmt = 0.5e18;
        vars.withdrawDebtAmt = 1000e18;

        vm.startPrank(user1);
        deal(address(collateralMock), user1, vars.addCollAmt);
        collateralMock.approve(address(borrowerOperationsProxy), vars.addCollAmt);

        // calc hint
        (vars.upperHint, vars.lowerHint) = HintLib.getHint(
            hintHelpers,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            vars.totalCollAmt,
            vars.totalNetDebtAmt,
            GAS_COMPENSATION
        );

        vm.expectRevert("BorrowerOps: Operation must leave trove with ICR >= CCR");
        // tx execution
        borrowerOperationsProxy.adjustTrove(
            troveManagerBeaconProxy,
            user1,
            vars.maxFeePercentage,
            vars.addCollAmt,
            0, /* collWithdrawalAmt */
            vars.withdrawDebtAmt,
            true, /* debtIncrease */
            vars.upperHint,
            vars.lowerHint
        );

        vars.addCollAmt = 5e18;
        vars.withdrawDebtAmt = 10e18;
        deal(address(collateralMock), user1, vars.addCollAmt);
        collateralMock.approve(address(borrowerOperationsProxy), vars.addCollAmt);

        // state before
        vars.userCollAmtBefore = collateralMock.balanceOf(user1);
        vars.troveManagerCollateralAmtBefore = collateralMock.balanceOf(address(troveManagerBeaconProxy));
        vars.userDebtAmtBefore = debtTokenProxy.balanceOf(user1);
        vars.debtTokenTotalSupplyBefore = debtTokenProxy.totalSupply();

        // calc hint
        (vars.upperHint, vars.lowerHint) = HintLib.getHint(
            hintHelpers,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            vars.totalCollAmt,
            vars.totalNetDebtAmt,
            GAS_COMPENSATION
        );

        // tx execution
        borrowerOperationsProxy.adjustTrove(
            troveManagerBeaconProxy,
            user1,
            vars.maxFeePercentage,
            vars.addCollAmt,
            0, /* collWithdrawalAmt */
            vars.withdrawDebtAmt,
            true, /* debtIncrease */
            vars.upperHint,
            vars.lowerHint
        );

        // state after
        vars.userCollAmtAfter = collateralMock.balanceOf(user1);
        vars.troveManagerCollateralAmtAfter = collateralMock.balanceOf(address(troveManagerBeaconProxy));
        vars.userDebtAmtAfter = debtTokenProxy.balanceOf(user1);
        vars.debtTokenTotalSupplyAfter = debtTokenProxy.totalSupply();

        // check state
        assertEq(vars.userCollAmtAfter, vars.userCollAmtBefore - vars.addCollAmt);
        assertEq(vars.troveManagerCollateralAmtAfter, vars.troveManagerCollateralAmtBefore + vars.addCollAmt);
        assertEq(vars.userDebtAmtAfter, vars.userDebtAmtBefore + vars.withdrawDebtAmt);

        vm.stopPrank();
    }
}
