// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../math/math.sol";
import "../fixed_point.sol";
import "../auth/auth.sol";
// import "../math/interest.sol";

/// @notice 1/ original code base from tinlake plays major role in batching, epoch side orchestration and submission period
// handling the best solution submission and challenge period. We will keep a minimal version possible to avoid complexity and surface
/// @notice 2/ we will deal with only moving parts here (and ignore static endpoints that may be overkill and we shall drift away
//the point around core risk management)
// this is an important piece out of all the risk odometer and kill switcher for any protocol that may be hypothetically
// integrated with this base

interface IdleLike {}

interface AccessorLike {}

interface EpochAndTrancheLike {}

contract Coordinator is Auth, Math, FixedPoint {
    struct Order {
        uint256 seniorRedeem;
        uint256 juniorRedeem;
        uint256 juniorSupply;
        uint256 seniorSupply;
    }

    modifier minimumEpochTimePassed() {}

    //restating vars from tranche, assessor and reserve
    uint256 public lastEpochExecuted;
    uint256 public currentEpoch;
    uint256 public lastEpochClosed;

    //tinlake's coordinator processes epochs based on minEpochTime passed
    uint256 public minimumEpochPeriod = 1 days;

    //weights for scoring (we may skip it)

    uint256 public minChallengePeriodEnd;

    IdleLike public idleReserve;
    AccessorLike public assessor;
    EpochAndTrancheLike public juniorTranche;
    EpochAndTrancheLike public seniorTranche;

    //current best solution
    uint256 public bestSubScore;

    //these can be skipped as we dont need to track them for now
    uint256 public bestRatioImprovement;
    uint256 public bestReserveImprovement;

    //current best solution
}
