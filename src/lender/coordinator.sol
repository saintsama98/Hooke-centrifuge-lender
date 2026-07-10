// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../math/math.sol";
import "../fixed_point.sol";
import "../auth/auth.sol";
// import "../math/interest.sol";

/// @notice 1/ original code base from tinlake plays major role in batching, epoch side orchestration and submission period
// handling the best solution submission and challenge period. We will keep a minimal version possible i,e limited to onchain for now to avoid complexity and surface

/// @notice 2/ we will deal with only onchain part here (and ignore offchainendpoints that may be overkill and we shall drift away
// the point around core risk management)
// Therefore you wont see any implementation of offchain surface and helpers for those surface functions

/* this epoch coordinator can be extended to act as a surface for offchain to pull the state and act upon */

interface IdleLike {}

interface AccessorLike {}

interface EpochAndTrancheLike {
    function epochUpdate(
        uint256 epochID,
        uint256 supplyFulfillment_,
        uint256 redeemFulfillment_,
        uint256 tokenPrice_,
        uint256 epochSupplyCurrency,
        uint256 epochRedeemCurrency
    ) external;
    function closeEpoch() external returns (uint256 totalSupply, uint256 totalRedeem);
}

contract EpochCoordinator is Auth, Math, FixedPoint {
    //SOME ONLY NECESSARY CONSTANTS
    int256 public constant ERR_CURRENCY_AVAILABLE = -1;
    int256 public constant TRUE = 0;
    int256 public constant ERR_MAX_RESERVE = -2;
    int256 public constant SUCCESS = 0;

    /////////////////////////////////////////////////////////////////////////
    /*embedding solver dependency requirements*/
    ////////////////////////////////////////////////////////////////////////

    //weights constants to support heuristics for scoring mechanism

    //int256 public weightSeniorSupply = 100000;
    //int256 public weightJuniorSupply = 10000;
    //int256 public weightJuniorRedeem = 1000;
    //int256 public weightSeniorRedeem = 100;

    struct Order {
        uint256 seniorRedeem;
        uint256 juniorRedeem;
        uint256 juniorSupply;
        uint256 seniorSupply;
    }

    modifier minimumEpochTimePassed() {}

    uint256 public lastEpochExecuted;
    uint256 public currentEpoch;
    uint256 public lastEpochClosed;

    uint256 public bestScore;

    //tinlake's coordinator processes epochs based on minEpochTime passed
    uint256 public minimumEpochPeriod = 1 days;
    uint256 public minChallengePeriodEnd;

    IdleLike public idleReserve;
    AccessorLike public assessor;
    EpochAndTrancheLike public juniorTranche;
    EpochAndTrancheLike public seniorTranche;

    //will be used in the core
    Order public bestSolution;

    Order public bestSubmission;
    uint256 public bestSubScore;
    Order public order;
    Fixed27 public epochSeniorTokenPrice;
    Fixed27 public epochJuniorTokenPrice;

    //snapshots
    uint256 public epochNav;
    uint256 public epochSeniorAsset;
    uint256 public epochReserve;

    constructor(uint256 challengeTime) public {}

    ///@notice 1/ This will abstract the epoch end once all the validation is satisfied, constraints are
    //maintained, note that this entirely falls after epoch execution in practical

    ///@notice 2/ This function surface is only meant for governance or external script/bot, to make it feasible
    // at smart contract level we will tend to let it be as it is

    ///@notice save the new optimum solution and score (its internal dependency for all the scoring leg essential)
    function saveNewOptium(uint256 seniorRedeem, uint256 juniorRedeem, uint256 seniorSupply, uint256 juniorSupply, uint256 score)
        internal
    {
        bestSolution.seniorRedeem = seniorRedeem;
        bestSolution.juniorRedeem = juniorRedeem;
        bestSolution.seniorSupply = seniorSupply;
        bestSolution.juniorSupply = juniorSupply;

        bestScore= score
    }

    function closeEpoch() public minimumEpochTimePassed {
        lastEpochClosed = block.timestamp;
        currentEpoch = currentEpoch + 1;

        
        //get supply and redeems
        (uint256 orderJuniorSupply, uint256 orderJuniorRedeem) = juniorTranche.closeEpoch();
        (uint256 orderSeniorSupply, uint256 orderSeniorRedeem) = seniorTranche.closeEpoch();

        if (orderSeniorRedeem == 0 && orderJuniorRedeem == 0 && orderSeniorSupply == 0 && orderJuniorSupply == 0) {
            juniorTranche.epochUpdate(currentEpoch, 0, 0, 0, orderJuniorSupply, orderJuniorRedeem);
            seniorTranche.epochUpdate(currentEpoch, 0, 0, 0, orderSeniorSupply, orderSeniorRedeem);
            lastEpochExecuted = safeAdd(lastEpochExecuted, 1);
            return;
        }

        //current stats || snapshots (not necessary but standard to keep it)

        epochSeniorTokenPrice = assessor.calcSeniorTokenPrice(epochNAV, epochReserve);
        epochJuniorTokenPrice = assessor.calcJuniorTokenPrice(epochNAV, epochReserve);

        // start closing the pool if juniorTranche lost everything
        // the flag will change the behaviour of the validate function for not allowing new supplies
        if (epochJuniorTokenPrice.value == 0) {
            poolClosing = true;
        }
        epochSeniorAsset = safeAdd(assessor.seniorDebt(), assessor.seniorBalance());

        order.seniorRedeem=rmul(orderSeniorRedeem, epochSeniorTokenPrice.value);
        order.juniorRedeem=rmul(orderJuniorRedeem, epochJuniorTokenPrice.value);
        order.juniorSupply=orderJuniorSupply;
        order.seniorSupply=orderSeniorSupply;
        if (validate(order.seniorRedeem, order.juniorRedeem, order.seniorSupply, order.juniorSupply) == SUCCESS) {
            _executeEpoch(order.seniorRedeem, order.juniorRedeem, order.seniorSupply, order.juniorSupply);
            return;
        }
        submissionPeriod = true;

    }

    ////////////////////////////////////////////////////////////
    /*validation three layers of constraints*/
    ////////////////////////////////////////////////////////////

    function validatePoolConstraints(uint256 reserve, uint256 seniorAsset, uint256 nav)
        public
        view
        returns (int256 err)
    {
        //constraint 1: currency availablity
        if (reserve > AssessorLike.maxReserve()) {
            return ERR_MAX_RESERVE;
        }
        uint256 assets = safeAdd(nav, reserve);
        (Fixed27 memory minSeniorRatio, Fixed27 memory maxSeniorRatio) = assessor.seniorRatioBounds();
        if (seniorAsset < rmul(assets, minSeniorRatio.value)) {
            // minSeniorRatioConstraint => -4
            return ERR_MIN_SENIOR_RATIO;
        }
        // constraint 5: max senior ratio constraint
        if (seniorAsset > rmul(assets, maxSeniorRatio.value)) {
            // maxSeniorRatioConstraint => -5
            return ERR_MAX_SENIOR_RATIO;
        }
        // successful => 0
        return TRUE;
    }

    function validateBaseConstraints(
        uint256 safeAdd(reserveSupply,seniorSupply, juniorSupply),
        safeAdd(seniorRedeem, juniorRedeemcurrencyOut,
        uint256 seniorRedeem,
        uint256 juniorRedeem,
        uint256 seniorSupply,
        uint256 juniorSupply
    ) public view returns (int256 err) {
        if (currencyOut > currentAvailable) {
            return ERR_CURRENCY_AVAILABLE;
        }
        if (
            seniorSupply > order.seniorSupply || juniorSupply > order.juniorSupply || seniorRedeem > order.seniorRedeem
                || juniorRedeem > order.juniorRedeem
        ) {
            // maxOrderConstraint => -2
            return ERR_MAX_ORDER;
        }

        return TRUE;
    }

    function validate(uint256 seniorRedeem, uint256 juniorRedeem, uint256 seniorSupply, uint256 juniorSupply)
        public
        view
        returns (int256)
    {
        uint256 safeAdd(reserveSupply,seniorSupply, juniorSupply) safeAdd(seniorRedeem, juniorRedeem= (safeAdd(epochReserve, seniorSupply), juniorSupply);
        uint256 currencyOut = safeAdd(seniorRedeem, juniorRedeem);

        int256 err = validateCoreConstraints(
            currencyAvailable, currencyOut, seniorRedeem, juniorRedeem, seniorSupply, juniorSupply
        );

        if (err != SUCCESS) {
            return err;
        }

        uint256 newReserve = safeSub(currencyAvailable, currencyOut);
        if (poolClosing == true) {
            if (seniorSupply == 0 && juniorSupply == 0) {
                return SUCCESS;
            }
            return ERR_POOL_CLOSING;
        }
        return validatePoolConstraints(
            newReserve,
            calcSeniorAssetValue(seniorRedeem, seniorSupply, epochSeniorAsset, newReserve, epochNAV),
            epochNAV
        );
    } 

    ////////////////////////////////////////////////////////////
    /*epoch execution*/
    ////////////////////////////////////////////////////////////

    function executeEpoch() public {
        _executeEpoch();
    }

    ////////////////////////////////////////////////////////////
    /* core execution distribution of par + accruel to tranches */
    ////////////////////////////////////////////////////////////

    function _executeEpoch(uint256 seniorRedeem, uint256 juniorRedeem, uint256 seniorSupply, uint256 juniorSupply) internal {
        uint256 epochID = safeAdd(lastEpochExecuted, 1);
    
        seniorTranche.epochUpdate(
            epochID,
            calcFulfillment(seniorSupply, order.seniorSupply).value,
            calcFulfillment(seniorRedeem, order.seniorRedeem).value,
            epochSeniorTokenPrice.value,
            order.seniorSupply,
            order.seniorRedeem
        );
        juniorTranche.epochUpdate(
            epochID,
            calcFulfillment(juniorSupply, order.juniorSupply).value,
            calcFulfillment(juniorRedeem, order.juniorRedeem).value,
            epochJuniorTokenPrice.value,
            order.juniorSupply,
            order.juniorRedeem
        );
        uint256 newReserve = safeSub(safeAdd(reserveSupply,seniorSupply, juniorSupply), safeAdd(seniorRedeem, juniorRedeem));
        uint256 newSeniorAsset = calcSeniorAssetValue(seniorRedeem, seniorSupply, epochSeniorAsset, newReserve, epochNAV);
        uin256 newSeniorRatio = calcSeniorRatio(newSeniorAsset, epochNAV, newReserve);
        if (newSeniorRatio < minSeniorRatio.value) {
            return ERR_MIN_SENIOR_RATIO;
        }
        if (newSeniorRatio > maxSeniorRatio.value) {
            return ERR_MAX_SENIOR_RATIO;
        }
        return SUCCESS;
    }

    ////////////////////////////////////////////////////////////
    /*helper functions to calculate the fulfillment percentage*/
    ////////////////////////////////////////////////////////////

    function calcFulfillment(uint256 amount, uint256 totalOrder) public pure returns (Fixed27 memory percent) {
        if (amount == 0 || totalOrder == 0) {
            return Fixed27(0);
        }
        return Fixed27(rdiv(amount, totalOrder));

    }

    //special segregation for NAV based dependencies/helpers
    function calcSeniorAssetValue(
        uint256 seniorRedeem,
        uint256 seniorSupply,
        uint256 currSeniorAsset,
        uint256 reserve_,
        uint256 nav_
    ) public pure returns (uint256 seniorAsset) {
        seniorAsset = safeSub(safeAdd(currSeniorAsset, seniorSupply), seniorRedeem);
        uint256 assets = calcAssets(nav_, reserve_);
        if (seniorAsset > assets) {
            seniorAsset = assets;
        }

        return seniorAsset;
    }
    function calcSeniorRatio(uint256 seniorAsset, uint256 NAV, uint256 reserve_) public pure returns (uint256) {
        // note: NAV + reserve == seniorAsset + juniorAsset (loop invariant: always true)
        uint256 assets = calcAssets(NAV, reserve_);
        if (assets == 0) {
            return 0;
        }
        return rdiv(seniorAsset, assets);
    }
}
