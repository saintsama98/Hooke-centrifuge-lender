// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../math/math.sol";
import "../fixed_point.sol";
import "../auth/auth.sol";
import "./sacred.sol";
import "./interfaces.sol";

/// @title EpochCoordinator
/// @author adiii.eth
/// @notice Orchestrates the epoch cycle. It opens and closes epochs, checks a proposed
/// allocation against the constraints of the pool, ranks the proposals it receives and
/// executes the winner. It holds no cash and computes no valuation.
///
/// @notice Note on status. Not audited. Written for study, and under development.
///
/// @dev The epoch runs through three states.
///  open        Orders build up in the tranches. Nothing here runs.
///  closing     closeEpoch has snapshotted the orders. Either every order can be
///              filled without breaking a constraint, in which case the epoch executes
///              in the same transaction and the cycle returns to open, or it cannot,
///              and the submission state begins.
///  submission  Anyone may propose an allocation through submitSolution and the best
///              one seen wins. A challenge window opens on the first valid proposal,
///              and when it closes executeEpoch settles the winner.
///
/// @dev Why there is a submission period. When the orders cannot all be filled,
/// something has to choose who is filled and by how much. That choice is a constrained
/// optimisation and it is too expensive to solve on chain. The approach taken from
/// Tinlake is to invert it. Anyone may compute a candidate off chain, and the contract
/// only checks and ranks it. Checking is cheap and optimising is not.
///
/// @dev What is fixed and what is a setting. The state machine, the constraint checks
/// and the ranking protocol are fixed, and changing them changes what the pool
/// guarantees. The weights that decide one solution is better than another are a
/// setting. They encode a choice about who to favour when not everyone can be
/// satisfied, and the default taken from Tinlake, which is redemptions before
/// subscriptions and senior before junior, is one reasonable answer. scoreSolution is
/// virtual for that reason. Overriding it changes the policy of a pool without
/// touching a constraint.
contract EpochCoordinator is Auth, Math, sacred {
    struct Order {
        // all variables are stored in currency
        uint256 seniorRedeem;
        uint256 juniorRedeem;
        uint256 juniorSupply;
        uint256 seniorSupply;
    }

    // return codes, numbered to match Tinlake so that tooling reading codes across the
    // two systems reports the same thing
    int256 public constant SUCCESS = 0;
    int256 public constant NEW_BEST = 0;
    int256 public constant ERR_CURRENCY_AVAILABLE = -1;
    int256 public constant ERR_MAX_ORDER = -2;
    int256 public constant ERR_MAX_RESERVE = -3;
    int256 public constant ERR_MIN_SENIOR_RATIO = -4;
    int256 public constant ERR_MAX_SENIOR_RATIO = -5;
    int256 public constant ERR_NOT_NEW_BEST = -6;
    int256 public constant ERR_POOL_CLOSING = -7;

    uint256 public constant BIG_NUMBER = ONE * ONE;
    uint256 public constant IMPROVEMENT_WEIGHT = 10000;

    // ==========================================================================
    // epoch state
    // ==========================================================================
    uint256 public lastEpochExecuted;
    uint256 public currentEpoch;
    uint256 public lastEpochClosed;

    // an epoch can only be closed once this much time has passed
    uint256 public minimumEpochPeriod = 1 days;
    uint256 public challengeTime;
    uint256 public minChallengePeriodEnd;

    bool public submissionPeriod;
    bool public poolClosing;
    bool public gotFullValidSolution;

    IdleLike public idleReserve;
    AssessorLike public assessor;
    EpochTrancheLike public juniorTranche;
    EpochTrancheLike public seniorTranche;

    /// @notice The full order book of the epoch, in currency.
    Order public order;

    /// @notice Best allocation submitted so far, with its score.
    Order public bestSubmission;
    uint256 public bestSubScore;
    uint256 public bestRatioImprovement;
    uint256 public bestReserveImprovement;

    /// @notice Weights used to rank a proposed allocation.
    /// @dev A setting rather than a rule. The default order is senior redeem, junior
    /// redeem, junior supply, senior supply, so letting people out ranks above letting
    /// people in and senior ranks above junior. Both are policy choices. Change them
    /// with file, or override scoreSolution for a policy these four numbers cannot
    /// express.
    uint256 public weightSeniorRedeem = 1000000;
    uint256 public weightJuniorRedeem = 100000;
    uint256 public weightJuniorSupply = 10000;
    uint256 public weightSeniorSupply = 1000;

    /// @notice State of the pool as it stood when the epoch was closed.
    /// @dev Taken once in closeEpoch and read everywhere after, so the whole submission
    /// period is scored against a fixed picture. If these could move during the period,
    /// two submissions would be ranked against different states and the comparison
    /// would mean nothing.
    uint256 public epochNav;
    uint256 public epochSeniorAsset;
    uint256 public epochReserve;
    Fixed27 public epochSeniorTokenPrice;
    Fixed27 public epochJuniorTokenPrice;

    event EpochClosed(uint256 indexed epochID, uint256 nav, uint256 reserve);
    event EpochExecuted(
        uint256 indexed epochID, uint256 seniorRedeem, uint256 juniorRedeem, uint256 seniorSupply, uint256 juniorSupply
    );
    event SolutionSubmitted(address indexed submitter, uint256 score);
    event File(bytes32 indexed what, uint256 value);

    error MinimumEpochTimeNotPassed();
    error SubmissionPeriodActive();
    error SubmissionPeriodNotActive();
    error ChallengePeriodNotEnded();
    error UnknownParameter();

    modifier minimumEpochTimePassed() {
        if (safeSub(block.timestamp, lastEpochClosed) < minimumEpochPeriod) revert MinimumEpochTimeNotPassed();
        _;
    }

    constructor(uint256 challengeTime_) {
        challengeTime = challengeTime_;
        lastEpochClosed = block.timestamp;
        currentEpoch = 1;
    }

    function file(bytes32 what, uint256 value) public auth {
        if (what == "challengeTime") {
            challengeTime = value;
        } else if (what == "minimumEpochPeriod") {
            minimumEpochPeriod = value;
        } else if (what == "weightSeniorRedeem") {
            weightSeniorRedeem = value;
        } else if (what == "weightJuniorRedeem") {
            weightJuniorRedeem = value;
        } else if (what == "weightJuniorSupply") {
            weightJuniorSupply = value;
        } else if (what == "weightSeniorSupply") {
            weightSeniorSupply = value;
        } else {
            revert UnknownParameter();
        }
        emit File(what, value);
    }

    function depend(bytes32 contractName, address addr) public auth {
        if (contractName == "assessor") {
            assessor = AssessorLike(addr);
        } else if (contractName == "juniorTranche") {
            juniorTranche = EpochTrancheLike(addr);
        } else if (contractName == "seniorTranche") {
            seniorTranche = EpochTrancheLike(addr);
        } else if (contractName == "reserve") {
            idleReserve = IdleLike(addr);
        } else {
            revert UnknownParameter();
        }
    }

    /// @notice Closes the current epoch. If every order can be filled without breaking
    /// a constraint the epoch also executes here, otherwise the submission period
    /// starts.
    function closeEpoch() external minimumEpochTimePassed {
        if (submissionPeriod) revert SubmissionPeriodActive();
        lastEpochClosed = block.timestamp;
        currentEpoch = currentEpoch + 1;

        // freeze borrower side draws for the duration, so currency this epoch may owe
        // to redeemers cannot be lent out from under it
        idleReserve.file("currencyAvailable", 0);

        //get supply and redeems
        (uint256 orderJuniorSupply, uint256 orderJuniorRedeem) = juniorTranche.closeEpoch();
        (uint256 orderSeniorSupply, uint256 orderSeniorRedeem) = seniorTranche.closeEpoch();

        //  if no orders exist epoch can be executed without validation
        if (orderSeniorRedeem == 0 && orderJuniorRedeem == 0 && orderSeniorSupply == 0 && orderJuniorSupply == 0) {
            // Tinlake keys this empty update by the current epoch, which it has just
            // raised, while execution keys by the last executed epoch plus one. The two
            // agree only while no epoch has ever been skipped. The execution counter is
            // used in both places here, so the epoch mapping is indexed by one thing
            // and the release walk cannot step over a live epoch.
            uint256 emptyEpochID = safeAdd(lastEpochExecuted, 1);
            juniorTranche.epochUpdate(emptyEpochID, 0, 0, 0, orderJuniorSupply, orderJuniorRedeem);
            seniorTranche.epochUpdate(emptyEpochID, 0, 0, 0, orderSeniorSupply, orderSeniorRedeem);
            lastEpochExecuted = emptyEpochID;
            return;
        }

        // create a snapshot of the current lender state
        epochNav = assessor.calcUpdateNAV();
        epochReserve = idleReserve.totalBalance();

        // calculate current token prices which are used for the execute
        epochSeniorTokenPrice = assessor.calcSeniorTokenPrice(epochNav, epochReserve);
        epochJuniorTokenPrice = assessor.calcJuniorTokenPrice(epochNav, epochReserve);

        // start closing the pool if juniorTranche lost everything
        // the flag will change the behaviour of the validate function for not allowing new supplies
        if (epochJuniorTokenPrice.value == 0) {
            poolClosing = true;
        }

        epochSeniorAsset = safeAdd(assessor.seniorDebt(), assessor.seniorBalance());

        // convert redeem orders in token into currency
        order.seniorRedeem = rmul(orderSeniorRedeem, epochSeniorTokenPrice.value);
        order.juniorRedeem = rmul(orderJuniorRedeem, epochJuniorTokenPrice.value);
        order.juniorSupply = orderJuniorSupply;
        order.seniorSupply = orderSeniorSupply;

        emit EpochClosed(currentEpoch, epochNav, epochReserve);

        // epoch is executed if orders can be fulfilled to 100% without constraint violation
        if (validate(order.seniorRedeem, order.juniorRedeem, order.seniorSupply, order.juniorSupply) == SUCCESS) {
            _executeEpoch(order.seniorRedeem, order.juniorRedeem, order.seniorSupply, order.juniorSupply);
            return;
        }
        // if 100% order fulfillment is not possible submission period starts
        submissionPeriod = true;
    }

    /// @notice Constraints that no allocation may break, whatever it scores.
    /// @param currencyAvailable Currency the pool can pay out this epoch.
    /// @param currencyOut Currency the allocation would pay out.
    /// @param seniorRedeem Senior redemption proposed, in currency.
    /// @param juniorRedeem Junior redemption proposed, in currency.
    /// @param seniorSupply Senior supply proposed, in currency.
    /// @param juniorSupply Junior supply proposed, in currency.
    /// @return err Zero on success, otherwise one of the error codes above.
    /// @dev These two are absolute. Currency the pool does not hold cannot be paid out,
    /// and an order cannot be filled beyond the size that was placed. A submission that
    /// fails either is rejected rather than ranked.
    function validateBaseConstraints(
        uint256 currencyAvailable,
        uint256 currencyOut,
        uint256 seniorRedeem,
        uint256 juniorRedeem,
        uint256 seniorSupply,
        uint256 juniorSupply
    ) public view returns (int256 err) {
        // constraint 1: currency available
        if (currencyOut > currencyAvailable) {
            return ERR_CURRENCY_AVAILABLE;
        }
        // constraint 2: max order
        if (
            seniorSupply > order.seniorSupply || juniorSupply > order.juniorSupply || seniorRedeem > order.seniorRedeem
                || juniorRedeem > order.juniorRedeem
        ) {
            return ERR_MAX_ORDER;
        }
        return SUCCESS;
    }

    /// @notice The risk settings of the pool, meaning the reserve ceiling and the
    /// senior ratio band.
    /// @param reserve_ Reserve the allocation would leave behind.
    /// @param seniorAsset Senior asset value the allocation would leave behind.
    /// @param nav_ Borrower side net asset value.
    /// @return err Zero on success, otherwise one of the error codes above.
    /// @dev Unlike the base constraints, a winning submission may break these, but only
    /// when no allocation satisfies them at all and only in the direction of
    /// improvement. See _improveScore.
    function validatePoolConstraints(uint256 reserve_, uint256 seniorAsset, uint256 nav_)
        public
        view
        returns (int256 err)
    {
        //constraint 3: max reserve
        if (reserve_ > assessor.maxReserve()) {
            return ERR_MAX_RESERVE;
        }
        uint256 assets = calcAssets(nav_, reserve_);
        (Fixed27 memory minSeniorRatio, Fixed27 memory maxSeniorRatio) = assessor.seniorRatioBounds();

        // constraint 4: min senior ratio
        if (seniorAsset < rmul(assets, minSeniorRatio.value)) {
            return ERR_MIN_SENIOR_RATIO;
        }
        // constraint 5: max senior ratio constraint
        if (seniorAsset > rmul(assets, maxSeniorRatio.value)) {
            return ERR_MAX_SENIOR_RATIO;
        }
        return SUCCESS;
    }

    function validate(uint256 seniorRedeem, uint256 juniorRedeem, uint256 seniorSupply, uint256 juniorSupply)
        public
        view
        returns (int256)
    {
        uint256 currencyAvailable = safeAdd(safeAdd(epochReserve, seniorSupply), juniorSupply);
        uint256 currencyOut = safeAdd(seniorRedeem, juniorRedeem);

        int256 err = validateBaseConstraints(
            currencyAvailable, currencyOut, seniorRedeem, juniorRedeem, seniorSupply, juniorSupply
        );
        if (err != SUCCESS) {
            return err;
        }

        uint256 newReserve = safeSub(currencyAvailable, currencyOut);
        if (poolClosing) {
            // junior is wiped out, so redemptions still settle but new supply does not
            if (seniorSupply == 0 && juniorSupply == 0) {
                return SUCCESS;
            }
            return ERR_POOL_CLOSING;
        }
        return validatePoolConstraints(
            newReserve,
            calcSeniorAssetValue(seniorRedeem, seniorSupply, epochSeniorAsset, newReserve, epochNav),
            epochNav
        );
    }

    /// @notice Proposes an allocation for the open epoch. Anyone may call this.
    /// @param seniorRedeem Senior redemption proposed, in currency.
    /// @param juniorRedeem Junior redemption proposed, in currency.
    /// @param juniorSupply Junior supply proposed, in currency.
    /// @param seniorSupply Senior supply proposed, in currency.
    /// @return Zero if the proposal is accepted, otherwise one of the error codes.
    function submitSolution(uint256 seniorRedeem, uint256 juniorRedeem, uint256 juniorSupply, uint256 seniorSupply)
        public
        returns (int256)
    {
        if (!submissionPeriod) revert SubmissionPeriodNotActive();

        int256 valid = _submitSolution(seniorRedeem, juniorRedeem, juniorSupply, seniorSupply);

        // the challenge period starts on the first valid proposal of the epoch
        if (valid == SUCCESS && minChallengePeriodEnd == 0) {
            minChallengePeriodEnd = safeAdd(block.timestamp, challengeTime);
        }
        return valid;
    }

    function _submitSolution(uint256 seniorRedeem, uint256 juniorRedeem, uint256 juniorSupply, uint256 seniorSupply)
        internal
        returns (int256)
    {
        int256 valid = validate(seniorRedeem, juniorRedeem, seniorSupply, juniorSupply);

        // every proposal has to satisfy the base constraints, without exception
        if (valid == ERR_CURRENCY_AVAILABLE || valid == ERR_MAX_ORDER) {
            return valid;
        }

        if (valid == SUCCESS) {
            uint256 score = scoreSolution(seniorRedeem, juniorRedeem, juniorSupply, seniorSupply);

            if (!gotFullValidSolution) {
                gotFullValidSolution = true;
                saveNewOptium(seniorRedeem, juniorRedeem, juniorSupply, seniorSupply, score);
                emit SolutionSubmitted(msg.sender, score);
                return SUCCESS;
            }
            if (score < bestSubScore) {
                return ERR_NOT_NEW_BEST;
            }
            saveNewOptium(seniorRedeem, juniorRedeem, juniorSupply, seniorSupply, score);
            emit SolutionSubmitted(msg.sender, score);
            return SUCCESS;
        }

        // the proposal breaks a pool constraint. If none that satisfies them has been
        // seen, it may still be accepted as an improvement on the current state.
        if (!gotFullValidSolution) {
            return _improveScore(seniorRedeem, juniorRedeem, juniorSupply, seniorSupply);
        }
        return ERR_NOT_NEW_BEST;
    }

    /// @notice Stores a new best allocation and its score.
    function saveNewOptium(
        uint256 seniorRedeem,
        uint256 juniorRedeem,
        uint256 juniorSupply,
        uint256 seniorSupply,
        uint256 score
    ) internal {
        bestSubmission.seniorRedeem = seniorRedeem;
        bestSubmission.juniorRedeem = juniorRedeem;
        bestSubmission.juniorSupply = juniorSupply;
        bestSubmission.seniorSupply = seniorSupply;
        bestSubScore = score;
    }

    /// @notice Ranks an allocation that satisfies every constraint.
    /// @param seniorRedeem Senior redemption proposed, in currency.
    /// @param juniorRedeem Junior redemption proposed, in currency.
    /// @param juniorSupply Junior supply proposed, in currency.
    /// @param seniorSupply Senior supply proposed, in currency.
    /// @return The score. Higher wins.
    /// @dev A weighted sum. The defaults fill senior redemptions first, then junior
    /// redemptions, then junior supply, then senior supply. Nothing in the constraint
    /// checks depends on that order, which is why this can safely be virtual. A fork
    /// that wants pro rata fairness, or priority by time, replaces this one function.
    function scoreSolution(uint256 seniorRedeem, uint256 juniorRedeem, uint256 juniorSupply, uint256 seniorSupply)
        public
        view
        virtual
        returns (uint256)
    {
        return safeAdd(
            safeAdd(safeMul(seniorRedeem, weightSeniorRedeem), safeMul(juniorRedeem, weightJuniorRedeem)),
            safeAdd(safeMul(juniorSupply, weightJuniorSupply), safeMul(seniorSupply, weightSeniorSupply))
        );
    }

    /// @dev The path that keeps the pool from deadlocking. When the pool is already
    /// outside its ratio band, no allocation satisfies the pool constraints, so
    /// validate rejects everything and no epoch would ever execute. Instead of
    /// freezing, allocations that break a constraint are ranked by how much closer to
    /// the middle of the band they move the pool, and the best of them wins. The ratio
    /// is repaired before the reserve, because a ratio breach affects the order in
    /// which claims are met and a reserve breach only affects efficiency.
    function _improveScore(uint256 seniorRedeem, uint256 juniorRedeem, uint256 juniorSupply, uint256 seniorSupply)
        internal
        returns (int256)
    {
        int256 err = 0;
        uint256 impScoreRatio = 0;
        uint256 impScoreReserve = 0;

        if (bestRatioImprovement == 0) {
            // measure against doing nothing, so a proposal has to beat the current
            // state rather than merely exist
            Fixed27 memory currSeniorRatio = Fixed27(calcSeniorRatio(epochSeniorAsset, epochNav, epochReserve));
            (err, impScoreRatio, impScoreReserve) = scoreImprovement(currSeniorRatio, epochReserve);
            saveNewImprovement(impScoreRatio, impScoreReserve);
        }

        uint256 newReserve = calcNewReserve(seniorRedeem, juniorRedeem, seniorSupply, juniorSupply);
        Fixed27 memory newSeniorRatio = Fixed27(
            calcSeniorRatio(
                calcSeniorAssetValue(seniorRedeem, seniorSupply, epochSeniorAsset, newReserve, epochNav),
                epochNav,
                newReserve
            )
        );

        (err, impScoreRatio, impScoreReserve) = scoreImprovement(newSeniorRatio, newReserve);
        if (err == ERR_NOT_NEW_BEST) {
            return err;
        }
        saveNewImprovement(impScoreRatio, impScoreReserve);

        // an improvement scores zero, so only allocations that satisfy every
        // constraint can score higher
        saveNewOptium(seniorRedeem, juniorRedeem, juniorSupply, seniorSupply, 0);
        return NEW_BEST;
    }

    function scoreImprovement(Fixed27 memory newSeniorRatio_, uint256 newReserve_)
        public
        view
        returns (int256, uint256, uint256)
    {
        uint256 impScoreRatio = scoreRatioImprovement(newSeniorRatio_);
        uint256 impScoreReserve = scoreReserveImprovement(newReserve_);

        // repairing the senior ratio comes first, so if it improves the reserve is
        // not considered
        if (impScoreRatio > bestRatioImprovement) {
            return (NEW_BEST, impScoreRatio, impScoreReserve);
        }
        if (impScoreRatio == bestRatioImprovement && impScoreReserve >= bestReserveImprovement) {
            return (NEW_BEST, impScoreRatio, impScoreReserve);
        }
        return (ERR_NOT_NEW_BEST, impScoreRatio, impScoreReserve);
    }

    function scoreRatioImprovement(Fixed27 memory newSeniorRatio) public view returns (uint256) {
        (Fixed27 memory minSeniorRatio, Fixed27 memory maxSeniorRatio) = assessor.seniorRatioBounds();
        if (checkRatioInRange(newSeniorRatio, minSeniorRatio, maxSeniorRatio)) {
            return BIG_NUMBER;
        }
        // closer to the middle of the band scores higher, and absDistance is never
        // zero so it is safe to divide by
        return rmul(
            IMPROVEMENT_WEIGHT,
            rdiv(
                ONE, absDistance(newSeniorRatio.value, safeDiv(safeAdd(minSeniorRatio.value, maxSeniorRatio.value), 2))
            )
        );
    }

    function scoreReserveImprovement(uint256 newReserve_) public view returns (uint256) {
        uint256 maxReserve_ = assessor.maxReserve();
        if (newReserve_ <= maxReserve_) {
            return BIG_NUMBER;
        }
        Fixed27 memory normalizedNewReserve = Fixed27(rdiv(newReserve_, maxReserve_));
        return rmul(IMPROVEMENT_WEIGHT, rdiv(ONE, absDistance(safeDiv(ONE, 2), normalizedNewReserve.value)));
    }

    function saveNewImprovement(uint256 impScoreRatio, uint256 impScoreReserve) internal {
        bestRatioImprovement = impScoreRatio;
        bestReserveImprovement = impScoreReserve;
    }

    /// @notice Settles the best allocation once the challenge period has ended.
    function executeEpoch() public {
        if (block.timestamp < minChallengePeriodEnd || minChallengePeriodEnd == 0) revert ChallengePeriodNotEnded();
        _executeEpoch(
            bestSubmission.seniorRedeem,
            bestSubmission.juniorRedeem,
            bestSubmission.seniorSupply,
            bestSubmission.juniorSupply
        );
    }

    /// @dev Settles an allocation: reports the fulfilment to both tranches, rebalances
    /// the senior claim and releases the new reserve to the borrower side.
    function _executeEpoch(uint256 seniorRedeem, uint256 juniorRedeem, uint256 seniorSupply, uint256 juniorSupply)
        internal
    {
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

        uint256 newReserve = calcNewReserve(seniorRedeem, juniorRedeem, seniorSupply, juniorSupply);
        uint256 seniorAsset = calcSeniorAssetValue(seniorRedeem, seniorSupply, epochSeniorAsset, newReserve, epochNav);
        uint256 newSeniorRatio = calcSeniorRatio(seniorAsset, epochNav, newReserve);

        // the assessor rebalances the senior debt against the new ratio
        assessor.changeSeniorAsset(newSeniorRatio, seniorSupply, seniorRedeem);
        // the reserve left after this epoch can fund new loans
        idleReserve.file("currencyAvailable", newReserve);

        emit EpochExecuted(epochID, seniorRedeem, juniorRedeem, seniorSupply, juniorSupply);

        // reset for the next epoch
        lastEpochExecuted = epochID;
        submissionPeriod = false;
        minChallengePeriodEnd = 0;
        bestSubScore = 0;
        gotFullValidSolution = false;
        bestRatioImprovement = 0;
        bestReserveImprovement = 0;
    }

    /// @notice Share of an order that a given amount fills.
    /// @param amount Amount allocated.
    /// @param totalOrder Size of the order.
    /// @return percent The share, in 27 decimal fixed point.
    function calcFulfillment(uint256 amount, uint256 totalOrder) public pure returns (Fixed27 memory percent) {
        if (amount == 0 || totalOrder == 0) {
            return Fixed27(0);
        }
        return Fixed27(rdiv(amount, totalOrder));
    }

    function calcNewReserve(uint256 seniorRedeem, uint256 juniorRedeem, uint256 seniorSupply, uint256 juniorSupply)
        public
        view
        returns (uint256)
    {
        return safeSub(safeAdd(safeAdd(epochReserve, seniorSupply), juniorSupply), safeAdd(seniorRedeem, juniorRedeem));
    }

    /// @notice Distance between two values.
    /// @dev Returns one rather than zero for equal inputs, so a caller can divide by
    /// the result.
    function absDistance(uint256 x, uint256 y) public pure returns (uint256) {
        if (x == y) return 1;
        if (x > y) return safeSub(x, y);
        return safeSub(y, x);
    }

    function checkRatioInRange(Fixed27 memory ratio, Fixed27 memory minRatio, Fixed27 memory maxRatio)
        public
        pure
        returns (bool)
    {
        return ratio.value >= minRatio.value && ratio.value <= maxRatio.value;
    }
}
