// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../math/math.sol";
import "../fixed_point.sol";
import "../auth/auth.sol";
// import "../math/interest.sol";

/// @notice 1/ original code base from tinlake plays major role in batching, epoch side orchestration and submission period
// handling the best solution submission and challenge period. We will keep a minimal version possible to avoid complexity and surface
/// @notice 2/ we will deal with only onchain part here (and ignore offchainendpoints that may be overkill and we shall drift away
// the point around core risk management)
// Therefore you wont see any implementation of offchain surface and helpers for those surface functions

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

    uint256 public lastEpochExecuted;
    uint256 public currentEpoch;
    uint256 public lastEpochClosed;

    //tinlake's coordinator processes epochs based on minEpochTime passed
    uint256 public minimumEpochPeriod = 1 days;
    uint256 public minChallengePeriodEnd;
    uint256 public challengeTime;

    IdleLike public idleReserve;
    AccessorLike public assessor;
    EpochAndTrancheLike public juniorTranche;
    EpochAndTrancheLike public seniorTranche;

    //these can be skipped as we dont need to track them for now
    uint256 public bestRatioImprovement;
    uint256 public bestReserveImprovement;

    Order public bestSubmission;
    uint256 public bestSubScore;
    Order public order;
    Fixed27 public epochSeniorTokenPrice;
    Fixed27 public epochJuniorTokenPrice;
    //snapshots
    uint256 public epochNav;
    uint256 public epochSeniorAsset;
    uint256 public epochReserve;

    bool public submissionPeriod;

    constructor(uint256 challengeTime) public {}

    ///@notice 1/ This will abstract the epoch end once all the validation is satisfied, constraints are
    //maintained, note that this entirely falls after epoch execution in practical

    ///@notice 2/ This function surface is only meant for governance or external script/bot, to make it feasible
    // at smart contract level we will tend to let it be as it is

    function closeEpoch() public minimumEpochTimePassed {
        require(submissionPeriod == false);
        lastEpochClosed = block.timestamp;
        currentEpoch = currentEpoch + 1;

        (uint256 orderJuniorSupply, uint256 orderJuniorRedeem) = juniorTranche.closeEpoch();
        (uint256 orderSeniorSupply, uint256 orderSeniorRedeem) = seniorTranche.closeEpoch();
    }

    //validation
    function validatePoolConstraints(
        uint256 seniorRedeem,
        uint256 juniorRedeem,
        uint256 juniorSupply,
        uint256 seniorSupply
    ) public view returns (bool) {}
    function validateCoreConstraints(
        uint256 currencyAvailable,
        uint256 currencyOut,
        uint256 seniorRedeem,
        uint256 juniorRedeem,
        uint256 seniorSupply,
        uint256 juniorSupply
    ) public view returns (int256 err) {}
    function _validate() internal view returns (int256 err) {}

    function executeEpoch() public {
        _executeEpoch();
    }

    function _executeEpoch() internal {}
}
