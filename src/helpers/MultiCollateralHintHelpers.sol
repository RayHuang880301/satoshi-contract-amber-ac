// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IBorrowerOperations} from "../interfaces/core/IBorrowerOperations.sol";
import {ITroveManager} from "../interfaces/core/ITroveManager.sol";
import {ISortedTroves} from "../interfaces/core/ISortedTroves.sol";
import {IMultiCollateralHintHelpers} from "./interfaces/IMultiCollateralHintHelpers.sol";
import {SatoshiBase} from "../dependencies/SatoshiBase.sol";
import {SatoshiMath} from "../dependencies/SatoshiMath.sol";

/**
 * @title Multiple Collateral Hint Helpers Contract
 *        Mutated from:
 *        https://github.com/prisma-fi/prisma-contracts/blob/main/contracts/core/helpers/MultiCollateralHintHelpers.sol
 *
 */
contract MultiCollateralHintHelpers is IMultiCollateralHintHelpers, SatoshiBase {
    IBorrowerOperations public immutable borrowerOperations;

    constructor(IBorrowerOperations _borrowerOperations, uint256 _gasCompensation) {
        __SatoshiBase_init(_gasCompensation);
        borrowerOperations = _borrowerOperations;
    }

    // --- Functions ---

    /* getRedemptionHints() - Helper function for finding the right hints to pass to redeemCollateral().
     *
     * It simulates a redemption of `_debtAmount` to figure out where the redemption sequence will start and what state the final Trove
     * of the sequence will end up in.
     *
     * Returns three hints:
     *  - `firstRedemptionHint` is the address of the first Trove with ICR >= MCR (i.e. the first Trove that will be redeemed).
     *  - `partialRedemptionHintNICR` is the final nominal ICR of the last Trove of the sequence after being hit by partial redemption,
     *     or zero in case of no partial redemption.
     *  - `truncatedDebtAmount` is the maximum amount that can be redeemed out of the the provided `_debtAmount`. This can be lower than
     *    `_debtAmount` when redeeming the full amount would leave the last Trove of the redemption sequence with less net debt than the
     *    minimum allowed value (i.e. MIN_NET_DEBT).
     *
     * The number of Troves to consider for redemption can be capped by passing a non-zero value as `_maxIterations`, while passing zero
     * will leave it uncapped.
     */

    function getRedemptionHints(ITroveManager troveManager, uint256 _debtAmount, uint256 _price, uint256 _maxIterations)
        external
        view
        returns (address firstRedemptionHint, uint256 partialRedemptionHintNICR, uint256 truncatedDebtAmount)
    {
        TroveManagerInfo memory info;
        ISortedTroves sortedTrovesCached = ISortedTroves(troveManager.sortedTroves());

        uint256 remainingDebt = _debtAmount;
        address currentTroveuser = sortedTrovesCached.getLast();
        info.MCR = troveManager.MCR();
        info.decimals = IERC20Metadata(address(troveManager.collateralToken())).decimals();

        while (currentTroveuser != address(0) && troveManager.getCurrentICR(currentTroveuser, _price) < info.MCR) {
            currentTroveuser = sortedTrovesCached.getPrev(currentTroveuser);
        }

        firstRedemptionHint = currentTroveuser;

        if (_maxIterations == 0) {
            _maxIterations = type(uint256).max;
        }

        uint256 minNetDebt = borrowerOperations.minNetDebt();
        while (currentTroveuser != address(0) && remainingDebt > 0 && _maxIterations-- > 0) {
            (uint256 debt, uint256 coll,,) = troveManager.getEntireDebtAndColl(currentTroveuser);
            uint256 netDebt = _getNetDebt(debt);

            if (netDebt > remainingDebt) {
                if (netDebt > minNetDebt) {
                    uint256 maxRedeemableDebt = SatoshiMath._min(remainingDebt, netDebt - minNetDebt);

                    uint256 newColl = coll
                        - SatoshiMath._getOriginalCollateralAmount(
                            ((maxRedeemableDebt * DECIMAL_PRECISION) / _price), info.decimals
                        );
                    uint256 newDebt = netDebt - maxRedeemableDebt;

                    uint256 compositeDebt = _getCompositeDebt(newDebt);
                    partialRedemptionHintNICR = SatoshiMath._computeNominalCR(newColl, compositeDebt);

                    remainingDebt = remainingDebt - maxRedeemableDebt;
                }
                break;
            } else {
                remainingDebt = remainingDebt - netDebt;
            }

            currentTroveuser = sortedTrovesCached.getPrev(currentTroveuser);
        }

        truncatedDebtAmount = _debtAmount - remainingDebt;
    }

    /* getApproxHint() - return address of a Trove that is, on average, (length / numTrials) positions away in the
    sortedTroves list from the correct insert position of the Trove to be inserted.

    Note: The output address is worst-case O(n) positions away from the correct insert position, however, the function
    is probabilistic. Input can be tuned to guarantee results to a high degree of confidence, e.g:

    Submitting numTrials = k * sqrt(length), with k = 15 makes it very, very likely that the ouput address will
    be <= sqrt(length) positions away from the correct insert position.
    */
    function getApproxHint(ITroveManager troveManager, uint256 _CR, uint256 _numTrials, uint256 _inputRandomSeed)
        external
        view
        returns (address hintAddress, uint256 diff, uint256 latestRandomSeed)
    {
        ISortedTroves sortedTroves = ISortedTroves(troveManager.sortedTroves());
        uint256 arrayLength = troveManager.getTroveOwnersCount();

        if (arrayLength == 0) {
            return (address(0), 0, _inputRandomSeed);
        }

        hintAddress = sortedTroves.getLast();
        diff = SatoshiMath._getAbsoluteDifference(_CR, troveManager.getNominalICR(hintAddress));
        latestRandomSeed = _inputRandomSeed;

        uint256 i = 1;

        while (i < _numTrials) {
            latestRandomSeed = uint256(keccak256(abi.encodePacked(latestRandomSeed)));

            uint256 arrayIndex = latestRandomSeed % arrayLength;
            address currentAddress = troveManager.getTroveFromTroveOwnersArray(arrayIndex);
            uint256 currentNICR = troveManager.getNominalICR(currentAddress);

            // check if abs(current - CR) > abs(closest - CR), and update closest if current is closer
            uint256 currentDiff = SatoshiMath._getAbsoluteDifference(currentNICR, _CR);

            if (currentDiff < diff) {
                diff = currentDiff;
                hintAddress = currentAddress;
            }
            i++;
        }
    }

    function computeNominalCR(uint256 _coll, uint256 _debt) external pure returns (uint256) {
        return SatoshiMath._computeNominalCR(_coll, _debt);
    }

    function computeCR(uint256 _coll, uint256 _debt, uint256 _price) external pure returns (uint256) {
        return SatoshiMath._computeCR(_coll, _debt, _price);
    }
}
