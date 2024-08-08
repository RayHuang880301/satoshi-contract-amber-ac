// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceFeed} from "../src/interfaces/dependencies/IPriceFeed.sol";
import {ISortedTroves} from "../src/interfaces/core/ISortedTroves.sol";
import {ITroveManager} from "../src/interfaces/core/ITroveManager.sol";
import {DeployBase} from "./utils/DeployBase.t.sol";
import {DEPLOYER, OWNER, GUARDIAN, TestConfig} from "./TestConfig.sol";

contract DeployInstanceTest is Test, DeployBase, TestConfig {
    function setUp() public override {
        super.setUp();

        // compute all contracts address
        _computeContractsAddress(DEPLOYER);

        // deploy all implementation contracts
        _deployImplementationContracts(DEPLOYER);

        // deploy all non-upgradeable contracts
        _deployNonUpgradeableContracts(DEPLOYER);

        // deploy all UUPS upgradeable contracts
        _deployUUPSUpgradeableContracts(DEPLOYER);

        // deploy all beacon contracts
        _deployBeaconContracts(DEPLOYER);
    }

    function testDeployInstance() public {
        address priceFeedAddr = _deployPriceFeed(DEPLOYER, ORACLE_MOCK_DECIMALS, ORACLE_MOCK_VERSION, initRoundData);
        assert(IPriceFeed(priceFeedAddr).owner() == OWNER);
        assert(IPriceFeed(priceFeedAddr).guardian() == GUARDIAN);
        assert(IPriceFeed(priceFeedAddr).SATOSHI_CORE() == satoshiCore);

        uint256 troveManagerCountBefore = factoryProxy.troveManagerCount();

        _setPriceFeedToPriceFeedAggregatorProxy(OWNER, collateralMock, IPriceFeed(priceFeedAddr));
        _deployNewInstance(OWNER, collateralMock, IPriceFeed(priceFeedAddr), deploymentParams);

        uint256 troveManagerCountAfter = factoryProxy.troveManagerCount();

        assert(troveManagerCountAfter == troveManagerCountBefore + 1);

        uint256 stabilityPoolIndexByCollateral = stabilityPoolProxy.indexByCollateral(collateralMock);
        assert(stabilityPoolProxy.collateralTokens(stabilityPoolIndexByCollateral - 1) == collateralMock); // index - 1

        ITroveManager troveManagerBeaconProxy = factoryProxy.troveManagers(troveManagerCountAfter - 1);
        ISortedTroves sortedTrovesBeaconProxy = troveManagerBeaconProxy.sortedTroves();
        assert(sortedTrovesBeaconProxy.troveManager() == troveManagerBeaconProxy);

        assert(troveManagerBeaconProxy.collateralToken() == collateralMock);
        assert(troveManagerBeaconProxy.systemDeploymentTime() != 0);
        assert(troveManagerBeaconProxy.sunsetting() == false);
        assert(troveManagerBeaconProxy.lastActiveIndexUpdate() != 0);

        assert(debtTokenProxy.troveManager(troveManagerBeaconProxy) == true);

        (IERC20 collateralToken,) = borrowerOperationsProxy.troveManagersData(troveManagerBeaconProxy);
        assert(collateralToken == collateralMock);

        assert(troveManagerBeaconProxy.communityIssuance() == communityIssuanceProxy);

        assertEq(troveManagerBeaconProxy.rewardRate(), 0);
    }
}
