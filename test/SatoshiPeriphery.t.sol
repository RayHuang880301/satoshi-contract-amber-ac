// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISortedTroves} from "../src/interfaces/core/ISortedTroves.sol";
import {ITroveManager, TroveManagerOperation} from "../src/interfaces/core/ITroveManager.sol";
import {ISatoshiPeriphery} from "../src/helpers/interfaces/ISatoshiPeriphery.sol";
import {IMultiCollateralHintHelpers} from "../src/helpers/interfaces/IMultiCollateralHintHelpers.sol";
import {IWETH} from "../src/helpers/interfaces/IWETH.sol";
import {SatoshiMath} from "../src/dependencies/SatoshiMath.sol";
import {DeployBase, LocalVars} from "./utils/DeployBase.t.sol";
import {HintLib} from "./utils/HintLib.sol";
import {DEPLOYER, OWNER, GAS_COMPENSATION, TestConfig, LIQUIDATION_FEE} from "./TestConfig.sol";
import {TroveBase} from "./utils/TroveBase.t.sol";
import {Events} from "./utils/Events.sol";
import {RoundData} from "../src/mocks/OracleMock.sol";

contract SatoshiPeripheryTest is Test, DeployBase, TroveBase, TestConfig, Events {
    using Math for uint256;

    ISortedTroves sortedTrovesBeaconProxy;
    ITroveManager troveManagerBeaconProxy;
    IMultiCollateralHintHelpers hintHelpers;
    ISatoshiPeriphery satoshiPeriphery;
    address user;
    address user1;
    address user2;
    address user3;
    address user4;

    struct LiquidationVars {
        uint256 entireTroveDebt;
        uint256 entireTroveColl;
        uint256 collGasCompensation;
        uint256 debtGasCompensation;
        uint256 debtToOffset;
        uint256 collToSendToSP;
        uint256 debtToRedistribute;
        uint256 collToRedistribute;
        uint256 collSurplus;
        // user state
        uint256[5] userCollBefore;
        uint256[5] userCollAfter;
        uint256[5] userDebtBefore;
        uint256[5] userDebtAfter;
    }

    function setUp() public override {
        super.setUp();

        // testing user
        user = vm.addr(0xdead);
        user1 = vm.addr(1);
        user2 = vm.addr(2);
        user3 = vm.addr(3);
        user4 = vm.addr(4);

        // use WETH as collateral
        weth = IWETH(_deployWETH(DEPLOYER));
        deal(address(weth), 10000e18);

        // setup contracts and deploy one instance
        (sortedTrovesBeaconProxy, troveManagerBeaconProxy) = _deploySetupAndInstance(
            DEPLOYER, OWNER, ORACLE_MOCK_DECIMALS, ORACLE_MOCK_VERSION, initRoundData, weth, deploymentParams
        );

        // deploy helper contracts
        hintHelpers = IMultiCollateralHintHelpers(_deployHintHelpers(DEPLOYER));

        satoshiPeriphery = ISatoshiPeriphery(_deploySatoshiPeriphery(DEPLOYER));

        // user set delegate approval for satoshiPeriphery
        vm.startPrank(user);
        borrowerOperationsProxy.setDelegateApproval(address(satoshiPeriphery), true);
        vm.stopPrank();
    }

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
            0.05e18
        );
    }

    function _updateRoundData(RoundData memory data) internal {
        TroveBase.updateRoundData(oracleMockAddr, DEPLOYER, data);
    }

    function testOpenTroveByRouter() public {
        LocalVars memory vars;
        // open trove params
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD

        vm.startPrank(user);
        deal(user, 1e18);

        // state before
        vars.rewardManagerDebtAmtBefore = debtTokenProxy.balanceOf(satoshiCore.rewardManager());
        vars.gasPoolDebtAmtBefore = debtTokenProxy.balanceOf(address(gasPool));
        vars.userDebtAmtBefore = debtTokenProxy.balanceOf(user);
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));

        vars.borrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);

        /* check events emitted correctly in tx */
        // check BorrowingFeePaid event
        vm.expectEmit(true, true, true, true, address(borrowerOperationsProxy));
        emit BorrowingFeePaid(user, weth, vars.borrowingFee);

        // check TotalStakesUpdated event
        vars.stake = vars.collAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check NodeAdded event
        vars.compositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.debtAmt);
        vars.totalDebt = vars.compositeDebt + vars.borrowingFee;
        vars.NICR = SatoshiMath._computeNominalCR(vars.collAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check NewDeployment event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.collAmt, vars.stake, TroveManagerOperation.open);

        // calc hint
        (vars.upperHint, vars.lowerHint) = HintLib.getHint(
            hintHelpers, sortedTrovesBeaconProxy, troveManagerBeaconProxy, vars.collAmt, vars.debtAmt, GAS_COMPENSATION
        );
        // tx execution
        satoshiPeriphery.openTrove{value: vars.collAmt}(
            troveManagerBeaconProxy,
            0.05e18, /* vars.maxFeePercentage 5% */
            vars.collAmt,
            vars.debtAmt,
            vars.upperHint,
            vars.lowerHint
        );

        // state after
        vars.rewardManagerDebtAmtAfter = debtTokenProxy.balanceOf(satoshiCore.rewardManager());
        vars.gasPoolDebtAmtAfter = debtTokenProxy.balanceOf(address(gasPool));
        vars.userDebtAmtAfter = debtTokenProxy.balanceOf(user);
        vars.userBalanceAfter = user.balance;
        vars.troveManagerCollateralAmtAfter = weth.balanceOf(address(troveManagerBeaconProxy));

        // check state
        assertEq(vars.rewardManagerDebtAmtAfter, vars.rewardManagerDebtAmtBefore + vars.borrowingFee);
        assertEq(vars.gasPoolDebtAmtAfter, vars.gasPoolDebtAmtBefore + GAS_COMPENSATION);
        assertEq(vars.userDebtAmtAfter, vars.userDebtAmtBefore + vars.debtAmt);
        assertEq(vars.userBalanceAfter, vars.userBalanceBefore - vars.collAmt);
        assertEq(vars.troveManagerCollateralAmtAfter, vars.troveManagerCollateralAmtBefore + vars.collAmt);

        vm.stopPrank();
    }

    function testOpenTroveByRouterWithPyth() public {
        LocalVars memory vars;
        // open trove params
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD

        vm.startPrank(user);
        deal(user, 1e18);

        // state before
        vars.rewardManagerDebtAmtBefore = debtTokenProxy.balanceOf(satoshiCore.rewardManager());
        vars.gasPoolDebtAmtBefore = debtTokenProxy.balanceOf(address(gasPool));
        vars.userDebtAmtBefore = debtTokenProxy.balanceOf(user);
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));

        vars.borrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);

        /* check events emitted correctly in tx */
        // check BorrowingFeePaid event
        vm.expectEmit(true, true, true, true, address(borrowerOperationsProxy));
        emit BorrowingFeePaid(user, weth, vars.borrowingFee);

        // check TotalStakesUpdated event
        vars.stake = vars.collAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check NodeAdded event
        vars.compositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.debtAmt);
        vars.totalDebt = vars.compositeDebt + vars.borrowingFee;
        vars.NICR = SatoshiMath._computeNominalCR(vars.collAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check NewDeployment event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.collAmt, vars.stake, TroveManagerOperation.open);

        // calc hint
        (vars.upperHint, vars.lowerHint) = HintLib.getHint(
            hintHelpers, sortedTrovesBeaconProxy, troveManagerBeaconProxy, vars.collAmt, vars.debtAmt, GAS_COMPENSATION
        );
        // tx execution
        satoshiPeriphery.openTroveWithPythPriceUpdate{value: vars.collAmt}(
            troveManagerBeaconProxy,
            0.05e18, /* vars.maxFeePercentage 5% */
            vars.collAmt,
            vars.debtAmt,
            vars.upperHint,
            vars.lowerHint,
            new bytes[](0)
        );

        // state after
        vars.rewardManagerDebtAmtAfter = debtTokenProxy.balanceOf(satoshiCore.rewardManager());
        vars.gasPoolDebtAmtAfter = debtTokenProxy.balanceOf(address(gasPool));
        vars.userDebtAmtAfter = debtTokenProxy.balanceOf(user);
        vars.userBalanceAfter = user.balance;
        vars.troveManagerCollateralAmtAfter = weth.balanceOf(address(troveManagerBeaconProxy));

        // check state
        assertEq(vars.rewardManagerDebtAmtAfter, vars.rewardManagerDebtAmtBefore + vars.borrowingFee);
        assertEq(vars.gasPoolDebtAmtAfter, vars.gasPoolDebtAmtBefore + GAS_COMPENSATION);
        assertEq(vars.userDebtAmtAfter, vars.userDebtAmtBefore + vars.debtAmt);
        assertEq(vars.userBalanceAfter, vars.userBalanceBefore - vars.collAmt);
        assertEq(vars.troveManagerCollateralAmtAfter, vars.troveManagerCollateralAmtBefore + vars.collAmt);

        vm.stopPrank();
    }

    function testAddCollByRouter() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vars.addCollAmt = 0.5e18;
        vars.totalCollAmt = vars.collAmt + vars.addCollAmt;

        vm.startPrank(user);
        deal(user, vars.addCollAmt);
        weth.approve(address(borrowerOperationsProxy), vars.addCollAmt);

        // state before
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check NodeAdded event
        vars.compositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.debtAmt);
        vars.borrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);
        vars.totalDebt = vars.compositeDebt + vars.borrowingFee;
        vars.NICR = SatoshiMath._computeNominalCR(vars.totalCollAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check TotalStakesUpdated event
        vars.stake = vars.totalCollAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.totalCollAmt, vars.stake, TroveManagerOperation.adjust);

        // calc hint
        (vars.upperHint, vars.lowerHint) = HintLib.getHint(
            hintHelpers,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            vars.totalCollAmt,
            vars.debtAmt,
            GAS_COMPENSATION
        );
        // tx execution
        satoshiPeriphery.addColl{value: vars.addCollAmt}(
            troveManagerBeaconProxy, vars.addCollAmt, vars.upperHint, vars.lowerHint
        );

        // state after
        vars.userBalanceAfter = user.balance;
        vars.troveManagerCollateralAmtAfter = weth.balanceOf(address(troveManagerBeaconProxy));

        // check state
        assertEq(vars.userBalanceAfter, vars.userBalanceBefore - vars.addCollAmt);
        assertEq(vars.troveManagerCollateralAmtAfter, vars.troveManagerCollateralAmtBefore + vars.addCollAmt);

        vm.stopPrank();
    }

    function testAddCollByRouterWithPyth() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vars.addCollAmt = 0.5e18;
        vars.totalCollAmt = vars.collAmt + vars.addCollAmt;

        vm.startPrank(user);
        deal(user, vars.addCollAmt);
        weth.approve(address(borrowerOperationsProxy), vars.addCollAmt);

        // state before
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check NodeAdded event
        vars.compositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.debtAmt);
        vars.borrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);
        vars.totalDebt = vars.compositeDebt + vars.borrowingFee;
        vars.NICR = SatoshiMath._computeNominalCR(vars.totalCollAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check TotalStakesUpdated event
        vars.stake = vars.totalCollAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.totalCollAmt, vars.stake, TroveManagerOperation.adjust);

        // calc hint
        (vars.upperHint, vars.lowerHint) = HintLib.getHint(
            hintHelpers,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            vars.totalCollAmt,
            vars.debtAmt,
            GAS_COMPENSATION
        );
        // tx execution
        satoshiPeriphery.addCollWithPythPriceUpdate{value: vars.addCollAmt}(
            troveManagerBeaconProxy, vars.addCollAmt, vars.upperHint, vars.lowerHint, new bytes[](0)
        );

        // state after
        vars.userBalanceAfter = user.balance;
        vars.troveManagerCollateralAmtAfter = weth.balanceOf(address(troveManagerBeaconProxy));

        // check state
        assertEq(vars.userBalanceAfter, vars.userBalanceBefore - vars.addCollAmt);
        assertEq(vars.troveManagerCollateralAmtAfter, vars.troveManagerCollateralAmtBefore + vars.addCollAmt);

        vm.stopPrank();
    }

    function testwithdrawCollByRouter() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vars.withdrawCollAmt = 0.5e18;
        vars.totalCollAmt = vars.collAmt - vars.withdrawCollAmt;

        vm.startPrank(user);

        // state before
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check NodeAdded event
        vars.compositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.debtAmt);
        vars.borrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);
        vars.totalDebt = vars.compositeDebt + vars.borrowingFee;
        vars.NICR = SatoshiMath._computeNominalCR(vars.totalCollAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check TotalStakesUpdated event
        vars.stake = vars.totalCollAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.totalCollAmt, vars.stake, TroveManagerOperation.adjust);

        // calc hint
        (vars.upperHint, vars.lowerHint) = HintLib.getHint(
            hintHelpers,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            vars.totalCollAmt,
            vars.debtAmt,
            GAS_COMPENSATION
        );
        // tx execution
        satoshiPeriphery.withdrawColl(troveManagerBeaconProxy, vars.withdrawCollAmt, vars.upperHint, vars.lowerHint);

        // state after
        vars.userBalanceAfter = user.balance;
        vars.troveManagerCollateralAmtAfter = weth.balanceOf(address(troveManagerBeaconProxy));

        // check state
        assertEq(vars.userBalanceAfter, vars.userBalanceBefore + vars.withdrawCollAmt);
        assertEq(vars.troveManagerCollateralAmtAfter, vars.troveManagerCollateralAmtBefore - vars.withdrawCollAmt);

        vm.stopPrank();
    }

    function testwithdrawCollByRouterWithPyth() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vars.withdrawCollAmt = 0.5e18;
        vars.totalCollAmt = vars.collAmt - vars.withdrawCollAmt;

        vm.startPrank(user);

        // state before
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check NodeAdded event
        vars.compositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.debtAmt);
        vars.borrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);
        vars.totalDebt = vars.compositeDebt + vars.borrowingFee;
        vars.NICR = SatoshiMath._computeNominalCR(vars.totalCollAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check TotalStakesUpdated event
        vars.stake = vars.totalCollAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.totalCollAmt, vars.stake, TroveManagerOperation.adjust);

        // calc hint
        (vars.upperHint, vars.lowerHint) = HintLib.getHint(
            hintHelpers,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            vars.totalCollAmt,
            vars.debtAmt,
            GAS_COMPENSATION
        );
        // tx execution
        satoshiPeriphery.withdrawCollWithPythPriceUpdate(
            troveManagerBeaconProxy, vars.withdrawCollAmt, vars.upperHint, vars.lowerHint, new bytes[](0)
        );

        // state after
        vars.userBalanceAfter = user.balance;
        vars.troveManagerCollateralAmtAfter = weth.balanceOf(address(troveManagerBeaconProxy));

        // check state
        assertEq(vars.userBalanceAfter, vars.userBalanceBefore + vars.withdrawCollAmt);
        assertEq(vars.troveManagerCollateralAmtAfter, vars.troveManagerCollateralAmtBefore - vars.withdrawCollAmt);

        vm.stopPrank();
    }

    function testWithdrawDebtByRouter() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vars.withdrawDebtAmt = 10000e18;
        vars.totalNetDebtAmt = vars.debtAmt + vars.withdrawDebtAmt;

        vm.startPrank(user);

        // state before
        vars.userDebtAmtBefore = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyBefore = debtTokenProxy.totalSupply();

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check NodeAdded event
        vars.compositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.totalNetDebtAmt);
        vars.borrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.totalNetDebtAmt);
        vars.totalDebt = vars.compositeDebt + vars.borrowingFee;
        vars.NICR = SatoshiMath._computeNominalCR(vars.collAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check TotalStakesUpdated event
        vars.stake = vars.collAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.collAmt, vars.stake, TroveManagerOperation.adjust);

        // calc hint
        (vars.upperHint, vars.lowerHint) = HintLib.getHint(
            hintHelpers,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            vars.collAmt,
            vars.totalNetDebtAmt,
            GAS_COMPENSATION
        );
        // tx execution
        satoshiPeriphery.withdrawDebt(
            troveManagerBeaconProxy, vars.maxFeePercentage, vars.withdrawDebtAmt, vars.upperHint, vars.lowerHint
        );

        // state after
        vars.userDebtAmtAfter = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyAfter = debtTokenProxy.totalSupply();

        // check state
        assertEq(vars.userDebtAmtAfter, vars.userDebtAmtBefore + vars.withdrawDebtAmt);
        uint256 newBorrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.withdrawDebtAmt);
        assertEq(
            vars.debtTokenTotalSupplyAfter, vars.debtTokenTotalSupplyBefore + vars.withdrawDebtAmt + newBorrowingFee
        );

        vm.stopPrank();
    }

    function testWithdrawDebtByRouterWithPyth() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vars.withdrawDebtAmt = 10000e18;
        vars.totalNetDebtAmt = vars.debtAmt + vars.withdrawDebtAmt;

        vm.startPrank(user);

        // state before
        vars.userDebtAmtBefore = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyBefore = debtTokenProxy.totalSupply();

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check NodeAdded event
        vars.compositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.totalNetDebtAmt);
        vars.borrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.totalNetDebtAmt);
        vars.totalDebt = vars.compositeDebt + vars.borrowingFee;
        vars.NICR = SatoshiMath._computeNominalCR(vars.collAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check TotalStakesUpdated event
        vars.stake = vars.collAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.collAmt, vars.stake, TroveManagerOperation.adjust);

        // calc hint
        (vars.upperHint, vars.lowerHint) = HintLib.getHint(
            hintHelpers,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            vars.collAmt,
            vars.totalNetDebtAmt,
            GAS_COMPENSATION
        );
        // tx execution
        satoshiPeriphery.withdrawDebtWithPythPriceUpdate(
            troveManagerBeaconProxy,
            vars.maxFeePercentage,
            vars.withdrawDebtAmt,
            vars.upperHint,
            vars.lowerHint,
            new bytes[](0)
        );

        // state after
        vars.userDebtAmtAfter = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyAfter = debtTokenProxy.totalSupply();

        // check state
        assertEq(vars.userDebtAmtAfter, vars.userDebtAmtBefore + vars.withdrawDebtAmt);
        uint256 newBorrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.withdrawDebtAmt);
        assertEq(
            vars.debtTokenTotalSupplyAfter, vars.debtTokenTotalSupplyBefore + vars.withdrawDebtAmt + newBorrowingFee
        );

        vm.stopPrank();
    }

    function testRepayDebtByRouter() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vars.repayDebtAmt = 5000e18;
        vars.totalNetDebtAmt = vars.debtAmt - vars.repayDebtAmt;

        vm.startPrank(user);
        debtTokenProxy.approve(address(satoshiPeriphery), vars.repayDebtAmt);

        // state before
        vars.userDebtAmtBefore = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyBefore = debtTokenProxy.totalSupply();

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check NodeAdded event
        uint256 originalCompositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.debtAmt);
        uint256 originalBorrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);
        vars.totalDebt = originalCompositeDebt + originalBorrowingFee - vars.repayDebtAmt;
        vars.NICR = SatoshiMath._computeNominalCR(vars.collAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check TotalStakesUpdated event
        vars.stake = vars.collAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.collAmt, vars.stake, TroveManagerOperation.adjust);

        // calc hint
        (vars.upperHint, vars.lowerHint) = HintLib.getHint(
            hintHelpers,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            vars.collAmt,
            vars.totalNetDebtAmt,
            GAS_COMPENSATION
        );

        // tx execution
        satoshiPeriphery.repayDebt(troveManagerBeaconProxy, vars.repayDebtAmt, vars.upperHint, vars.lowerHint);

        // state after
        vars.userDebtAmtAfter = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyAfter = debtTokenProxy.totalSupply();

        // check state
        assertEq(vars.userDebtAmtAfter, vars.userDebtAmtBefore - vars.repayDebtAmt);
        assertEq(vars.debtTokenTotalSupplyAfter, vars.debtTokenTotalSupplyBefore - vars.repayDebtAmt);

        vm.stopPrank();
    }

    function testRepayDebtByRouterWithPyth() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vars.repayDebtAmt = 5000e18;
        vars.totalNetDebtAmt = vars.debtAmt - vars.repayDebtAmt;

        vm.startPrank(user);
        debtTokenProxy.approve(address(satoshiPeriphery), vars.repayDebtAmt);

        // state before
        vars.userDebtAmtBefore = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyBefore = debtTokenProxy.totalSupply();

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check NodeAdded event
        uint256 originalCompositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.debtAmt);
        uint256 originalBorrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);
        vars.totalDebt = originalCompositeDebt + originalBorrowingFee - vars.repayDebtAmt;
        vars.NICR = SatoshiMath._computeNominalCR(vars.collAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check TotalStakesUpdated event
        vars.stake = vars.collAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.collAmt, vars.stake, TroveManagerOperation.adjust);

        // calc hint
        (vars.upperHint, vars.lowerHint) = HintLib.getHint(
            hintHelpers,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            vars.collAmt,
            vars.totalNetDebtAmt,
            GAS_COMPENSATION
        );

        // tx execution
        satoshiPeriphery.repayDebtWithPythPriceUpdate(
            troveManagerBeaconProxy, vars.repayDebtAmt, vars.upperHint, vars.lowerHint, new bytes[](0)
        );

        // state after
        vars.userDebtAmtAfter = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyAfter = debtTokenProxy.totalSupply();

        // check state
        assertEq(vars.userDebtAmtAfter, vars.userDebtAmtBefore - vars.repayDebtAmt);
        assertEq(vars.debtTokenTotalSupplyAfter, vars.debtTokenTotalSupplyBefore - vars.repayDebtAmt);

        vm.stopPrank();
    }

    function testAdjustTroveByRouter_AddCollAndRepayDebt() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vars.addCollAmt = 0.5e18;
        vars.repayDebtAmt = 5000e18;
        vars.totalCollAmt = vars.collAmt + vars.addCollAmt;
        vars.totalNetDebtAmt = vars.debtAmt - vars.repayDebtAmt;

        vm.startPrank(user);
        deal(user, vars.addCollAmt);
        debtTokenProxy.approve(address(satoshiPeriphery), vars.repayDebtAmt);

        // state before
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));
        vars.userDebtAmtBefore = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyBefore = debtTokenProxy.totalSupply();

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check NodeAdded event
        uint256 originalCompositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.debtAmt);
        uint256 originalBorrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);
        vars.totalDebt = originalCompositeDebt + originalBorrowingFee - vars.repayDebtAmt;
        vars.NICR = SatoshiMath._computeNominalCR(vars.totalCollAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check TotalStakesUpdated event
        vars.stake = vars.totalCollAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.totalCollAmt, vars.stake, TroveManagerOperation.adjust);

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
        satoshiPeriphery.adjustTrove{value: vars.addCollAmt}(
            troveManagerBeaconProxy,
            0, /* vars.maxFeePercentage */
            vars.addCollAmt,
            0, /* collWithdrawalAmt */
            vars.repayDebtAmt,
            false, /* debtIncrease */
            vars.upperHint,
            vars.lowerHint
        );

        // state after
        vars.userBalanceAfter = user.balance;
        vars.troveManagerCollateralAmtAfter = weth.balanceOf(address(troveManagerBeaconProxy));
        vars.userDebtAmtAfter = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyAfter = debtTokenProxy.totalSupply();

        // check state
        assertEq(vars.userBalanceAfter, vars.userBalanceBefore - vars.addCollAmt);
        assertEq(vars.troveManagerCollateralAmtAfter, vars.troveManagerCollateralAmtBefore + vars.addCollAmt);
        assertEq(vars.userDebtAmtAfter, vars.userDebtAmtBefore - vars.repayDebtAmt);
        assertEq(vars.debtTokenTotalSupplyAfter, vars.debtTokenTotalSupplyBefore - vars.repayDebtAmt);

        vm.stopPrank();
    }

    function testAdjustTroveByRouterWithPyth_AddCollAndRepayDebt() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vars.addCollAmt = 0.5e18;
        vars.repayDebtAmt = 5000e18;
        vars.totalCollAmt = vars.collAmt + vars.addCollAmt;
        vars.totalNetDebtAmt = vars.debtAmt - vars.repayDebtAmt;

        vm.startPrank(user);
        deal(user, vars.addCollAmt);
        debtTokenProxy.approve(address(satoshiPeriphery), vars.repayDebtAmt);

        // state before
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));
        vars.userDebtAmtBefore = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyBefore = debtTokenProxy.totalSupply();

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check NodeAdded event
        uint256 originalCompositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.debtAmt);
        uint256 originalBorrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);
        vars.totalDebt = originalCompositeDebt + originalBorrowingFee - vars.repayDebtAmt;
        vars.NICR = SatoshiMath._computeNominalCR(vars.totalCollAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check TotalStakesUpdated event
        vars.stake = vars.totalCollAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.totalCollAmt, vars.stake, TroveManagerOperation.adjust);

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
        satoshiPeriphery.adjustTroveWithPythPriceUpdate{value: vars.addCollAmt}(
            troveManagerBeaconProxy,
            0, /* vars.maxFeePercentage */
            vars.addCollAmt,
            0, /* collWithdrawalAmt */
            vars.repayDebtAmt,
            false, /* debtIncrease */
            vars.upperHint,
            vars.lowerHint,
            new bytes[](0)
        );

        // state after
        vars.userBalanceAfter = user.balance;
        vars.troveManagerCollateralAmtAfter = weth.balanceOf(address(troveManagerBeaconProxy));
        vars.userDebtAmtAfter = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyAfter = debtTokenProxy.totalSupply();

        // check state
        assertEq(vars.userBalanceAfter, vars.userBalanceBefore - vars.addCollAmt);
        assertEq(vars.troveManagerCollateralAmtAfter, vars.troveManagerCollateralAmtBefore + vars.addCollAmt);
        assertEq(vars.userDebtAmtAfter, vars.userDebtAmtBefore - vars.repayDebtAmt);
        assertEq(vars.debtTokenTotalSupplyAfter, vars.debtTokenTotalSupplyBefore - vars.repayDebtAmt);

        vm.stopPrank();
    }

    function testAdjustTroveByRouter_AddCollAndWithdrawDebt() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vars.addCollAmt = 0.5e18;
        vars.withdrawDebtAmt = 5000e18;
        vars.totalCollAmt = vars.collAmt + vars.addCollAmt;
        vars.totalNetDebtAmt = vars.debtAmt + vars.withdrawDebtAmt;

        vm.startPrank(user);
        deal(user, vars.addCollAmt);

        // state before
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));
        vars.userDebtAmtBefore = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyBefore = debtTokenProxy.totalSupply();

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check NodeAdded event
        vars.compositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.totalNetDebtAmt);
        vars.borrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.totalNetDebtAmt);
        vars.totalDebt = vars.compositeDebt + vars.borrowingFee;
        vars.NICR = SatoshiMath._computeNominalCR(vars.totalCollAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check TotalStakesUpdated event
        vars.stake = vars.totalCollAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.totalCollAmt, vars.stake, TroveManagerOperation.adjust);

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
        satoshiPeriphery.adjustTrove{value: vars.addCollAmt}(
            troveManagerBeaconProxy,
            vars.maxFeePercentage,
            vars.addCollAmt,
            0, /* collWithdrawalAmt */
            vars.withdrawDebtAmt,
            true, /* debtIncrease */
            vars.upperHint,
            vars.lowerHint
        );

        // state after
        vars.userBalanceAfter = user.balance;
        vars.troveManagerCollateralAmtAfter = weth.balanceOf(address(troveManagerBeaconProxy));
        vars.userDebtAmtAfter = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyAfter = debtTokenProxy.totalSupply();

        // check state
        assertEq(vars.userBalanceAfter, vars.userBalanceBefore - vars.addCollAmt);
        assertEq(vars.troveManagerCollateralAmtAfter, vars.troveManagerCollateralAmtBefore + vars.addCollAmt);
        assertEq(vars.userDebtAmtAfter, vars.userDebtAmtBefore + vars.withdrawDebtAmt);
        uint256 newBorrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.withdrawDebtAmt);
        assertEq(
            vars.debtTokenTotalSupplyAfter, vars.debtTokenTotalSupplyBefore + vars.withdrawDebtAmt + newBorrowingFee
        );

        vm.stopPrank();
    }

    function testAdjustTroveByRouter_WithdrawCollAndRepayDebt() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vars.withdrawCollAmt = 0.5e18;
        vars.repayDebtAmt = 5000e18;
        vars.totalCollAmt = vars.collAmt - vars.withdrawCollAmt;
        vars.totalNetDebtAmt = vars.debtAmt - vars.repayDebtAmt;

        vm.startPrank(user);
        debtTokenProxy.approve(address(satoshiPeriphery), vars.repayDebtAmt);

        // state before
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));
        vars.userDebtAmtBefore = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyBefore = debtTokenProxy.totalSupply();

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check NodeAdded event
        uint256 originalCompositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.debtAmt);
        uint256 originalBorrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);
        vars.totalDebt = originalCompositeDebt + originalBorrowingFee - vars.repayDebtAmt;
        vars.NICR = SatoshiMath._computeNominalCR(vars.totalCollAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check TotalStakesUpdated event
        vars.stake = vars.totalCollAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.totalCollAmt, vars.stake, TroveManagerOperation.adjust);

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
        satoshiPeriphery.adjustTrove(
            troveManagerBeaconProxy,
            0, /* vars.maxFeePercentage */
            0, /* collAdditionAmt */
            vars.withdrawCollAmt,
            vars.repayDebtAmt,
            false, /* debtIncrease */
            vars.upperHint,
            vars.lowerHint
        );

        // state after
        vars.userBalanceAfter = user.balance;
        vars.troveManagerCollateralAmtAfter = weth.balanceOf(address(troveManagerBeaconProxy));
        vars.userDebtAmtAfter = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyAfter = debtTokenProxy.totalSupply();

        // check state
        assertEq(vars.userBalanceAfter, vars.userBalanceBefore + vars.withdrawCollAmt);
        assertEq(vars.troveManagerCollateralAmtAfter, vars.troveManagerCollateralAmtBefore - vars.withdrawCollAmt);
        assertEq(vars.userDebtAmtAfter, vars.userDebtAmtBefore - vars.repayDebtAmt);
        assertEq(vars.debtTokenTotalSupplyAfter, vars.debtTokenTotalSupplyBefore - vars.repayDebtAmt);

        vm.stopPrank();
    }

    function testAdjustTroveByRouter_WithdrawCollAndWithdrawDebt() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vars.withdrawCollAmt = 0.5e18;
        vars.withdrawDebtAmt = 2000e18;
        vars.totalCollAmt = vars.collAmt - vars.withdrawCollAmt;
        vars.totalNetDebtAmt = vars.debtAmt + vars.withdrawDebtAmt;

        vm.startPrank(user);

        // state before
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));
        vars.userDebtAmtBefore = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyBefore = debtTokenProxy.totalSupply();

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check NodeAdded event
        vars.compositeDebt = borrowerOperationsProxy.getCompositeDebt(vars.totalNetDebtAmt);
        vars.borrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.totalNetDebtAmt);
        vars.totalDebt = vars.compositeDebt + vars.borrowingFee;
        vars.NICR = SatoshiMath._computeNominalCR(vars.totalCollAmt, vars.totalDebt);
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeAdded(user, vars.NICR);

        // check TotalStakesUpdated event
        vars.stake = vars.totalCollAmt;
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TotalStakesUpdated(vars.stake);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, vars.totalDebt, vars.totalCollAmt, vars.stake, TroveManagerOperation.adjust);

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
        satoshiPeriphery.adjustTrove(
            troveManagerBeaconProxy,
            vars.maxFeePercentage,
            0, /* collAdditionAmt */
            vars.withdrawCollAmt,
            vars.withdrawDebtAmt,
            true, /* debtIncrease */
            vars.upperHint,
            vars.lowerHint
        );

        // state after
        vars.userBalanceAfter = user.balance;
        vars.troveManagerCollateralAmtAfter = weth.balanceOf(address(troveManagerBeaconProxy));
        vars.userDebtAmtAfter = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyAfter = debtTokenProxy.totalSupply();

        // check state
        assertEq(vars.userBalanceAfter, vars.userBalanceBefore + vars.withdrawCollAmt);
        assertEq(vars.troveManagerCollateralAmtAfter, vars.troveManagerCollateralAmtBefore - vars.withdrawCollAmt);
        assertEq(vars.userDebtAmtAfter, vars.userDebtAmtBefore + vars.withdrawDebtAmt);
        uint256 newBorrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.withdrawDebtAmt);
        assertEq(
            vars.debtTokenTotalSupplyAfter, vars.debtTokenTotalSupplyBefore + vars.withdrawDebtAmt + newBorrowingFee
        );

        vm.stopPrank();
    }

    function testCloseTroveByRouter() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vm.startPrank(user);
        //  mock user debt token balance
        vars.borrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);
        vars.repayDebtAmt = vars.debtAmt + vars.borrowingFee;
        deal(address(debtTokenProxy), user, vars.repayDebtAmt);
        debtTokenProxy.approve(address(satoshiPeriphery), vars.repayDebtAmt);

        // state before
        vars.debtTokenTotalSupplyBefore = debtTokenProxy.totalSupply();
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, 0, 0, 0, TroveManagerOperation.close);

        // tx execution
        satoshiPeriphery.closeTrove(troveManagerBeaconProxy);

        // state after
        vars.userDebtAmtAfter = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyAfter = debtTokenProxy.totalSupply();
        vars.userBalanceAfter = user.balance;
        vars.troveManagerCollateralAmtAfter = weth.balanceOf(address(troveManagerBeaconProxy));

        // check state
        assertEq(vars.userDebtAmtAfter, 0);
        assertEq(vars.debtTokenTotalSupplyAfter, vars.debtTokenTotalSupplyBefore - vars.repayDebtAmt - GAS_COMPENSATION);
        assertEq(vars.userBalanceAfter, vars.userBalanceBefore + vars.collAmt);
        // assertEq(vars.troveManagerCollateralAmtAfter, vars.troveManagerCollateralAmtBefore - vars.collAmt);

        vm.stopPrank();
    }

    function testCloseTroveByRouterWithPyth() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vm.startPrank(user);
        //  mock user debt token balance
        vars.borrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);
        vars.repayDebtAmt = vars.debtAmt + vars.borrowingFee;
        deal(address(debtTokenProxy), user, vars.repayDebtAmt);
        debtTokenProxy.approve(address(satoshiPeriphery), vars.repayDebtAmt);

        // state before
        vars.debtTokenTotalSupplyBefore = debtTokenProxy.totalSupply();
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));

        /* check events emitted correctly in tx */
        // check NodeRemoved event
        vm.expectEmit(true, true, true, true, address(sortedTrovesBeaconProxy));
        emit NodeRemoved(user);

        // check TroveUpdated event
        vm.expectEmit(true, true, true, true, address(troveManagerBeaconProxy));
        emit TroveUpdated(user, 0, 0, 0, TroveManagerOperation.close);

        // tx execution
        satoshiPeriphery.closeTroveWithPythPriceUpdate(troveManagerBeaconProxy, new bytes[](0));

        // state after
        vars.userDebtAmtAfter = debtTokenProxy.balanceOf(user);
        vars.debtTokenTotalSupplyAfter = debtTokenProxy.totalSupply();
        vars.userBalanceAfter = user.balance;
        vars.troveManagerCollateralAmtAfter = weth.balanceOf(address(troveManagerBeaconProxy));

        // check state
        assertEq(vars.userDebtAmtAfter, 0);
        assertEq(vars.debtTokenTotalSupplyAfter, vars.debtTokenTotalSupplyBefore - vars.repayDebtAmt - GAS_COMPENSATION);
        assertEq(vars.userBalanceAfter, vars.userBalanceBefore + vars.collAmt);
        // assertEq(vars.troveManagerCollateralAmtAfter, vars.troveManagerCollateralAmtBefore - vars.collAmt);

        vm.stopPrank();
    }

    function _redeemCollateral(address caller, uint256 redemptionAmount) internal {
        uint256 price = troveManagerBeaconProxy.fetchPrice();
        (address firstRedemptionHint, uint256 partialRedemptionHintNICR, uint256 truncatedDebtAmount) =
            hintHelpers.getRedemptionHints(troveManagerBeaconProxy, redemptionAmount, price, 0);
        (address hintAddress,,) = hintHelpers.getApproxHint(troveManagerBeaconProxy, partialRedemptionHintNICR, 10, 42);

        (address upperPartialRedemptionHint, address lowerPartialRedemptionHint) =
            sortedTrovesBeaconProxy.findInsertPosition(partialRedemptionHintNICR, hintAddress, hintAddress);

        // redeem
        vm.startPrank(caller);
        debtTokenProxy.approve(address(satoshiPeriphery), truncatedDebtAmount);
        satoshiPeriphery.redeemCollateral(
            troveManagerBeaconProxy,
            truncatedDebtAmount,
            firstRedemptionHint,
            upperPartialRedemptionHint,
            lowerPartialRedemptionHint,
            partialRedemptionHintNICR,
            0,
            0.05e18
        );
        vm.stopPrank();
    }

    function _redeemCollateralWithPyth(address caller, uint256 redemptionAmount) internal {
        uint256 price = troveManagerBeaconProxy.fetchPrice();
        (address firstRedemptionHint, uint256 partialRedemptionHintNICR, uint256 truncatedDebtAmount) =
            hintHelpers.getRedemptionHints(troveManagerBeaconProxy, redemptionAmount, price, 0);
        (address hintAddress,,) = hintHelpers.getApproxHint(troveManagerBeaconProxy, partialRedemptionHintNICR, 10, 42);

        (address upperPartialRedemptionHint, address lowerPartialRedemptionHint) =
            sortedTrovesBeaconProxy.findInsertPosition(partialRedemptionHintNICR, hintAddress, hintAddress);

        // redeem
        vm.startPrank(caller);
        debtTokenProxy.approve(address(satoshiPeriphery), truncatedDebtAmount);
        satoshiPeriphery.redeemCollateralWithPythPriceUpdate(
            troveManagerBeaconProxy,
            truncatedDebtAmount,
            firstRedemptionHint,
            upperPartialRedemptionHint,
            lowerPartialRedemptionHint,
            partialRedemptionHintNICR,
            0,
            0.05e18,
            new bytes[](0)
        );
        vm.stopPrank();
    }

    function testRedeemByRouter() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vm.startPrank(user);
        //  mock user debt token balance
        vars.borrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);
        vars.repayDebtAmt = vars.debtAmt + vars.borrowingFee;
        deal(address(debtTokenProxy), user, vars.repayDebtAmt);
        debtTokenProxy.approve(address(satoshiPeriphery), vars.repayDebtAmt);

        // state before
        vars.debtTokenTotalSupplyBefore = debtTokenProxy.totalSupply();
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));

        vm.stopPrank();

        vm.warp(block.timestamp + 14 days);
        // price drop
        _updateRoundData(
            RoundData({
                answer: 40000_00_000_000,
                startedAt: block.timestamp,
                updatedAt: block.timestamp,
                answeredInRound: 1
            })
        );

        uint256 redemptionAmount = 500e18;
        deal(address(debtTokenProxy), user2, redemptionAmount);

        vars.price = troveManagerBeaconProxy.fetchPrice();
        (vars.firstRedemptionHint, vars.partialRedemptionHintNICR, vars.truncatedDebtAmount) =
            hintHelpers.getRedemptionHints(troveManagerBeaconProxy, redemptionAmount, vars.price, 0);
        (address hintAddress,,) =
            hintHelpers.getApproxHint(troveManagerBeaconProxy, vars.partialRedemptionHintNICR, 10, 42);

        (vars.upperPartialRedemptionHint, vars.lowerPartialRedemptionHint) =
            sortedTrovesBeaconProxy.findInsertPosition(vars.partialRedemptionHintNICR, hintAddress, hintAddress);

        // redeem
        vm.startPrank(user2);
        debtTokenProxy.approve(address(satoshiPeriphery), vars.truncatedDebtAmount);
        satoshiPeriphery.redeemCollateral(
            troveManagerBeaconProxy,
            vars.truncatedDebtAmount,
            vars.firstRedemptionHint,
            vars.upperPartialRedemptionHint,
            vars.lowerPartialRedemptionHint,
            vars.partialRedemptionHintNICR,
            0,
            0.05e18
        );
        vm.stopPrank();
        // _redeemCollateral(user2, redemptionAmount);

        // state after
        (vars.userCollAmtAfter, vars.userDebtAmtAfter) = troveManagerBeaconProxy.getTroveCollAndDebt(user);
        assertGt(vars.collAmt, vars.userCollAmtAfter);
        assertGt(vars.debtAmt, vars.userDebtAmtAfter);

        vars.userBalanceAfter = user2.balance;

        // uint256 price = troveManagerBeaconProxy.fetchPrice();
        // uint256 expectedAmt = redemptionAmount * 1e18 * 995 / 1000 / price;
        // assertEq(vars.userBalanceAfter, expectedAmt);
    }

    function testRedeemByRouterWithPyth() public {
        LocalVars memory vars;
        // pre open trove
        vars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        vars.debtAmt = 10000e18; // 10000 USD
        vars.maxFeePercentage = 0.05e18; // 5%
        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user,
            user,
            weth,
            vars.collAmt,
            vars.debtAmt,
            vars.maxFeePercentage
        );

        vm.startPrank(user);
        //  mock user debt token balance
        vars.borrowingFee = troveManagerBeaconProxy.getBorrowingFeeWithDecay(vars.debtAmt);
        vars.repayDebtAmt = vars.debtAmt + vars.borrowingFee;
        deal(address(debtTokenProxy), user, vars.repayDebtAmt);
        debtTokenProxy.approve(address(satoshiPeriphery), vars.repayDebtAmt);

        // state before
        vars.debtTokenTotalSupplyBefore = debtTokenProxy.totalSupply();
        vars.userBalanceBefore = user.balance;
        vars.troveManagerCollateralAmtBefore = weth.balanceOf(address(troveManagerBeaconProxy));

        vm.stopPrank();

        vm.warp(block.timestamp + 14 days);
        // price drop
        _updateRoundData(
            RoundData({
                answer: 40000_00_000_000,
                startedAt: block.timestamp,
                updatedAt: block.timestamp,
                answeredInRound: 1
            })
        );

        vars.userBalanceBefore = user2.balance;
        uint256 redemptionAmount = 500e18;
        deal(address(debtTokenProxy), user2, redemptionAmount);
        vars.price = troveManagerBeaconProxy.fetchPrice();
        (vars.firstRedemptionHint, vars.partialRedemptionHintNICR, vars.truncatedDebtAmount) =
            hintHelpers.getRedemptionHints(troveManagerBeaconProxy, redemptionAmount, vars.price, 0);
        (address hintAddress,,) =
            hintHelpers.getApproxHint(troveManagerBeaconProxy, vars.partialRedemptionHintNICR, 10, 42);

        (vars.upperPartialRedemptionHint, vars.lowerPartialRedemptionHint) =
            sortedTrovesBeaconProxy.findInsertPosition(vars.partialRedemptionHintNICR, hintAddress, hintAddress);

        // redeem
        vm.startPrank(user2);
        debtTokenProxy.approve(address(satoshiPeriphery), vars.truncatedDebtAmount);
        satoshiPeriphery.redeemCollateralWithPythPriceUpdate(
            troveManagerBeaconProxy,
            vars.truncatedDebtAmount,
            vars.firstRedemptionHint,
            vars.upperPartialRedemptionHint,
            vars.lowerPartialRedemptionHint,
            vars.partialRedemptionHintNICR,
            0,
            0.05e18,
            new bytes[](0)
        );
        vm.stopPrank();

        // state after
        (vars.userCollAmtAfter, vars.userDebtAmtAfter) = troveManagerBeaconProxy.getTroveCollAndDebt(user);
        assertGt(vars.collAmt, vars.userCollAmtAfter);
        assertGt(vars.debtAmt, vars.userDebtAmtAfter);

        vars.userBalanceAfter = user2.balance;

        // uint256 price = troveManagerBeaconProxy.fetchPrice();
        // uint256 expectedAmt = redemptionAmount * 1e18 * 995 / 1000 / price;
        // assertEq(vars.userBalanceAfter - vars.userBalanceBefore, expectedAmt);
    }

    function testLiquidaeByRouter() public {
        LiquidationVars memory vars;
        LocalVars memory lvars;
        lvars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        lvars.debtAmt = 10000e18; // 10000 USD
        lvars.maxFeePercentage = 0.05e18; // 5%

        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user2,
            user2,
            weth,
            lvars.collAmt,
            lvars.debtAmt,
            lvars.maxFeePercentage
        );

        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user3,
            user3,
            weth,
            lvars.collAmt,
            lvars.debtAmt,
            lvars.maxFeePercentage
        );

        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user1,
            user1,
            weth,
            lvars.collAmt,
            lvars.debtAmt,
            lvars.maxFeePercentage
        );

        // reducing TCR below 150%, and all Troves below 100% ICR
        _updateRoundData(
            RoundData({
                answer: 10000_00_000_000, // 10000
                startedAt: block.timestamp,
                updatedAt: block.timestamp,
                answeredInRound: 1
            })
        );

        (uint256 coll1, uint256 debt1) = troveManagerBeaconProxy.getTroveCollAndDebt(user1);
        (uint256 coll2Before, uint256 debt2Before) = troveManagerBeaconProxy.getTroveCollAndDebt(user2);
        (uint256 coll3Before, uint256 debt3Before) = troveManagerBeaconProxy.getTroveCollAndDebt(user3);
        vars.collToRedistribute = (coll1 - coll1 / LIQUIDATION_FEE);
        vars.debtToRedistribute = debt1;
        vars.collGasCompensation = coll1 / LIQUIDATION_FEE;
        vars.debtGasCompensation = GAS_COMPENSATION;

        vm.prank(user4);
        satoshiPeriphery.liquidateTroves(liquidationManagerProxy, troveManagerBeaconProxy, 1, 110e18);

        (uint256 coll2, uint256 debt2) = troveManagerBeaconProxy.getTroveCollAndDebt(user2);
        (uint256 coll3, uint256 debt3) = troveManagerBeaconProxy.getTroveCollAndDebt(user3);

        assertEq(coll2, coll2Before + vars.collToRedistribute / 2);
        assertEq(debt2, debt2Before + vars.debtToRedistribute / 2);
        assertEq(coll3, coll3Before + vars.collToRedistribute / 2);
        assertEq(debt3, debt3Before + vars.debtToRedistribute / 2);

        // check user4 gets the reward for liquidation
        assertEq(user4.balance, vars.collGasCompensation / 2);
        assertEq(user4.balance, vars.collGasCompensation / 2);
        assertEq(debtTokenProxy.balanceOf(user4), vars.debtGasCompensation);
    }

    function testLiquidaeByRouterWithPyth() public {
        LiquidationVars memory vars;
        LocalVars memory lvars;
        lvars.collAmt = 1e18; // price defined in `TestConfig.roundData`
        lvars.debtAmt = 10000e18; // 10000 USD
        lvars.maxFeePercentage = 0.05e18; // 5%

        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user2,
            user2,
            weth,
            lvars.collAmt,
            lvars.debtAmt,
            lvars.maxFeePercentage
        );

        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user3,
            user3,
            weth,
            lvars.collAmt,
            lvars.debtAmt,
            lvars.maxFeePercentage
        );

        TroveBase.openTrove(
            borrowerOperationsProxy,
            sortedTrovesBeaconProxy,
            troveManagerBeaconProxy,
            hintHelpers,
            GAS_COMPENSATION,
            user1,
            user1,
            weth,
            lvars.collAmt,
            lvars.debtAmt,
            lvars.maxFeePercentage
        );

        // reducing TCR below 150%, and all Troves below 100% ICR
        _updateRoundData(
            RoundData({
                answer: 10000_00_000_000, // 10000
                startedAt: block.timestamp,
                updatedAt: block.timestamp,
                answeredInRound: 1
            })
        );

        (uint256 coll1, uint256 debt1) = troveManagerBeaconProxy.getTroveCollAndDebt(user1);
        (uint256 coll2Before, uint256 debt2Before) = troveManagerBeaconProxy.getTroveCollAndDebt(user2);
        (uint256 coll3Before, uint256 debt3Before) = troveManagerBeaconProxy.getTroveCollAndDebt(user3);
        vars.collToRedistribute = (coll1 - coll1 / LIQUIDATION_FEE);
        vars.debtToRedistribute = debt1;
        vars.collGasCompensation = coll1 / LIQUIDATION_FEE;
        vars.debtGasCompensation = GAS_COMPENSATION;

        vm.prank(user4);
        satoshiPeriphery.liquidateTrovesWithPythPriceUpdate(
            liquidationManagerProxy, troveManagerBeaconProxy, 1, 110e18, new bytes[](0)
        );

        (uint256 coll2, uint256 debt2) = troveManagerBeaconProxy.getTroveCollAndDebt(user2);
        (uint256 coll3, uint256 debt3) = troveManagerBeaconProxy.getTroveCollAndDebt(user3);

        assertEq(coll2, coll2Before + vars.collToRedistribute / 2);
        assertEq(debt2, debt2Before + vars.debtToRedistribute / 2);
        assertEq(coll3, coll3Before + vars.collToRedistribute / 2);
        assertEq(debt3, debt3Before + vars.debtToRedistribute / 2);

        // check user4 gets the reward for liquidation
        assertEq(user4.balance, vars.collGasCompensation / 2);
        assertEq(user4.balance, vars.collGasCompensation / 2);
        assertEq(debtTokenProxy.balanceOf(user4), vars.debtGasCompensation);
    }
}
