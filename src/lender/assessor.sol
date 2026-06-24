// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/* Hooke Protocol
/// @title Hooke - a thin open tranching protocol
/// @author adiii.eth
/// @notice This is minimal proof of concept to define tranching as a whole defi primmitive with credit market layout drawn from
/// the motivation of a legacy code base from centrifuge tilake github. 
///  */

import "../math/Math.sol";
import "../sacred.sol";
import "../fixed_point.sol";

//inline interfaces 

/// @notice for nav based calculations motivated from borrower side and discounted rate dep  
interface navLike{

}

/// @notice token interface
interface trancheLike{

}
/// @notice the idle reserve interface, refer idle,sol 
interface idleLike{

}

///@notice this depends strategies and future strategy developments, adapter surface may change as per roadmap 
interface lendingLike{

}

contract assessor is math,sacred,auth{
    Fixed27 public seniorRatio;

    ///@notice accessor is mostly motivated from senior tranche first as priority as per the convention for 
    /// easy follow up and this convemtion should be maintained for development.

    // there are two senior variables that are dedicated to token level calculations

    ///@dev seniorDebt is asset value that brings interest and is playable 
    /// seniorBalance is the balance of the senior tranche that dosen't contribute in interest accruel
    uint256 seniorDebt_;
    uint256 seniorBalance_;

    Fixed27 public maxSeniorRatio;
    Fixed27 public minSeniorRatio;

    Fixed27 public seniorInterestRate;

    uint256 lastUpdateSeniorInterest;

    /// @dev intentionally lending adapter type engagement is missing, configurable for future integrations

    TrancheLike public seniorTranche;
    TrancheLike public juniorTranche;
    NAVFeedLike public navFeed;
    ReserveLike public reserve;

    uint256 maxIdle; //reserve

    //dust related balance tolerence
    uint256 public constant supplyTolerence= 5;

    constructor () {
        seniorInterestRate.value = ONE;
        lastUpdateSeniorInterest = block.timestamp;
        seniorRatio.value = 0;
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    //======rebalancing========

    function rebalance() public{
        rebalance(calcExpectedDebtAsset(_accrueSeniorDebt(),_seniorBalance));
    }

    function rebalance(uint256 seniorAsset_) internal{
    }

    function getNav() public view returns (uint256 _nav) {

    }

    //======helpers========

    function _accrueSeniorDebt() public pure returns (uint256 finalAccruel){
        if (lastUpdateSeniorInterest >= block.timestamp) {
            return chargeInterest();
        }
        lastUpdateSeniorInterest = block.timestamp;
        return finalAccruel;
    }


}