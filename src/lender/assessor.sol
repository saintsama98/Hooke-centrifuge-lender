// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/* Hooke Protocol
/// @title Hooke - a thin open tranching protocol
/// @author adiii.eth
/// @notice This is minimal proof of concept to define tranching as a whole defi primmitive with credit market layout drawn from
/// the motivation of a legacy code base from centrifuge tilake github.
///  */

import "../math/math.sol";
import "./sacred.sol";
import "../fixed_point.sol";
import "../auth/auth.sol";
import "../math/interest.sol";

//inline interfaces

/// @notice for nav based calculations motivated from borrower side and discounted rate dep
interface navLike {}

/// @notice token interface
interface trancheLike{

}
/// @notice the idle reserve interface, refer idle,sol 
interface idleLike{
    function totalBalance() external view returns (uint256);
}

///@notice this depends strategies and future strategy developments, adapter surface may change as per roadmap
interface lendingLike {}

}

contract assessor is Math,sacred,Auth,Interest{
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

    trancheLike public seniorTranche;
    trancheLike public juniorTranche;
    navLike public navFeed;
    idleLike public reserve;

    uint256 maxIdle; //reserve

    //dust related balance tolerence
    uint256 public constant supplyTolerence = 5;

    constructor() {
        seniorInterestRate.value = ONE;
        lastUpdateSeniorInterest = block.timestamp;
        seniorRatio.value = 0;
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    //======rebalancing========

    function rebalance() public{
        rebalance(calcExpectedSeniorAssets(_accrueSeniorDebt(),_seniorBalance));
    }

    function rebalance(uint256 seniorAsset_) internal{
        //get nav
        uint256 nav_= getNav();
        //get reserve
        uint256 reserve_ = reserve.totalBalance();

        //this is the primary implementation of waterfall and thus need other deps like
        //senior ratio

        uint256 seniorRato_= calcSeniorRatio(seniorAsset_, nav_, reserve_);

        //debt for senior tranche specefically
        seniorDebt_ = rmul(nav_, seniorRato_);


        //senior is priority and under loss protection 
        if (seniorDebt_>seniorAsset_){
            seniorDebt_=seniorAsset_;
            seniorBalance_=0;
        } 
        else{
            seniorBalance_= safeSub(seniorAsset_, seniorDebt_);
        } 


    }

    function getNav() public view returns (uint256 _nav) {
        //nav should be 
    }

    //======helpers========

    function _accrueSeniorDebt() public returns (uint256 finalAccruel){
        if (lastUpdateSeniorInterest >= block.timestamp) {
            return chargeInterest(seniorDebt_, seniorInterestRate.value, lastUpdateSeniorInterest);
        }
        lastUpdateSeniorInterest = block.timestamp;
        return finalAccruel;
    }

    


}
