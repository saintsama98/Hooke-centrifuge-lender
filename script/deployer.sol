// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../src/lender/idle.sol";
import "../src/lender/tranche.sol";
import "../src/lender/assessor.sol";
import "../src/lender/coordinator.sol";
import "../src/lender/operator.sol";

/// @title LenderDeployer
/// @author adiii.eth
/// @notice Deploys and wires a complete pool with two tranches. This is the shortest
/// full description of the system: nine contracts, which of them knows about which,
/// and which of them may call which.
///
/// @notice Note on status. Not audited. Written for study, and under development.
///
/// @dev Two separate graphs are set up below. depend records which contracts hold the
/// addresses of which others, and it mostly points downward, from valuation and
/// orchestration to the things they read. rely records which contracts may change the
/// state of which others, and it is far sparser. Read the second one as the list of
/// every privileged edge in the pool. There are eight, and any one of them being wrong
/// is a vulnerability, so they are written out one by one rather than granted in a
/// loop.
///
/// @dev Each contract authorises its deployer on construction. denyDeployer gives that
/// up and should be called. A deployer that stays authorised is an admin on every
/// contract in the pool that cannot be removed.
contract LenderDeployer {
    // tokens
    address public immutable currency;
    address public immutable seniorToken;
    address public immutable juniorToken;

    // pool
    idle public reserve;
    assessor public assessor_;
    EpochCoordinator public coordinator;
    Tranche public seniorTranche;
    Tranche public juniorTranche;
    Operator public seniorOperator;
    Operator public juniorOperator;

    constructor(address currency_, address seniorToken_, address juniorToken_) {
        currency = currency_;
        seniorToken = seniorToken_;
        juniorToken = juniorToken_;
    }

    /// @param navFeed Address of a valuation feed. See test/mock/navfeed.sol.
    /// @param challengeTime Seconds a submission period stays open after its first
    /// valid proposal. Zero removes the challenge window, which is acceptable in a test
    /// and wrong in a live pool.
    /// @param minSeniorRatio_ Lower bound of the senior band, in 27 decimal fixed point.
    /// @param maxSeniorRatio_ Upper bound of the senior band, in 27 decimal fixed point.
    /// @param maxReserve_ Ceiling on idle currency.
    /// @param seniorRate_ Senior rate per second, in 27 decimal fixed point. A value of
    /// 1e27 means zero interest.
    function deploy(
        address navFeed,
        uint256 challengeTime,
        uint256 minSeniorRatio_,
        uint256 maxSeniorRatio_,
        uint256 maxReserve_,
        uint256 seniorRate_
    ) public {
        reserve = new idle(currency);
        assessor_ = new assessor();
        coordinator = new EpochCoordinator(challengeTime);
        seniorTranche = new Tranche(currency, seniorToken);
        juniorTranche = new Tranche(currency, juniorToken);
        seniorOperator = new Operator(address(seniorTranche));
        juniorOperator = new Operator(address(juniorTranche));

        // depend, meaning which contract holds the address of which other
        seniorTranche.depend("reserve", address(reserve));
        seniorTranche.depend("epochPlacement", address(coordinator));
        juniorTranche.depend("reserve", address(reserve));
        juniorTranche.depend("epochPlacement", address(coordinator));

        assessor_.depend("navFeed", navFeed);
        assessor_.depend("reserve", address(reserve));
        assessor_.depend("seniorTranche", address(seniorTranche));
        assessor_.depend("juniorTranche", address(juniorTranche));

        coordinator.depend("assessor", address(assessor_));
        coordinator.depend("seniorTranche", address(seniorTranche));
        coordinator.depend("juniorTranche", address(juniorTranche));
        coordinator.depend("reserve", address(reserve));

        // rely, meaning which contract may change the state of which other. Every
        // privileged edge in the pool is listed here.
        // the coordinator drives both tranches through the epoch handshake
        seniorTranche.rely(address(coordinator));
        juniorTranche.rely(address(coordinator));
        // each operator is the only caller allowed to place orders on its tranche
        seniorTranche.rely(address(seniorOperator));
        juniorTranche.rely(address(juniorOperator));
        // the coordinator settles the senior split once per executed epoch
        assessor_.rely(address(coordinator));
        // tranches move currency in and out of the reserve during epochUpdate
        reserve.rely(address(seniorTranche));
        reserve.rely(address(juniorTranche));
        // the coordinator opens and closes the borrower side draw window
        reserve.rely(address(coordinator));

        // settings
        assessor_.file("minSeniorRatio", minSeniorRatio_);
        assessor_.file("maxSeniorRatio", maxSeniorRatio_);
        assessor_.file("maxReserve", maxReserve_);
        assessor_.file("seniorInterestRate", seniorRate_);
    }

    /// @notice Removes the admin rights the deployer holds on every contract in the
    /// pool.
    function denyDeployer() public {
        seniorTranche.deny(address(this));
        juniorTranche.deny(address(this));
        assessor_.deny(address(this));
        coordinator.deny(address(this));
        reserve.deny(address(this));
        seniorOperator.deny(address(this));
        juniorOperator.deny(address(this));
    }
}
