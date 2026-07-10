// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../math/math.sol";
import "../fixed_point.sol";

/// @notice This contract defines all the functions that are inherited by operator and accessor
/// the sole purpose being abstraction and modularity, these functions are core to lending side operation

abstract contract sacred is Math, fixedPoint {
    uint256 public _seniorBalance;
    uint256 public _seniorDebt;

    /// @notice deposits, curation and redemption all phases in lifecycle are the only ones which are considered valid
    /// in this codebase, i,e these smart contracts are written for lender side waterfall model only.
    /// @dev these are the base types of senior tier (tranche) mechanics Hooke promotes and is built around:
    /// 1/ calcSeniorDebtAssets
    /// 2/ calcOverallNAV
    /// 3/ calcSeniorRatio
    /// 4/ calcSeniorNewAsset
    /// 5/ calcSeniorExpectedAsset

    function calcExpectedSeniorAssets(uint256 _debt, uint256 _balance) public pure returns (uint256 _seniorAsset) {
        // Implementation for calculating senior debt assets
        //returns the totsl assets for senior
        return safeAdd(_debt, _balance);
    }

    function calcOverallNAV(uint256 _nav, uint256 _reserve) internal view returns (uint256) {
        // Implementation for calculating overall net asset value
    }

    function calcSeniorRatio(uint256 _seniorAsset, uint256 _nav, uint256 _reserve)
        public
        pure
        returns (uint256 seniorRatio)
    {
        // Implementation for calculating senior ratio
        uint256 assets = safeAdd(_nav, _reserve);
        if (assets == 0) return 0;
        return rdiv(_seniorAsset, assets);
    }

    function calcJuniorRatio(uint256 _nav, uint256 _reserve) external returns (uint256) {
        //calculate senior assets
        uint256 seniorAssets = calcExpectedSeniorAssets(_seniorDebt, _seniorBalance);
        //total assets
        uint256 assets = safeAdd(_nav, _reserve);
        //for junio ratio we need some checks as it is obviously one priority level below to senior
        if (assets == 0) return 0;

        if (seniorAssets > assets) return 0;
        if (seniorAssets == 0 && assets > 0) return ONE;
        return safeSub(ONE, rdiv(seniorAssets, assets));
    }

    // function seniorDebt() public view returns (uint256 _seniorDebt) {
    //     if (block.timestamp >= lastUpdateSeniorInterest) {
    //         return chargeInterest(seniorDebt_, seniorInterestRate.value, lastUpdateSeniorInterest);
    //     }
    //     return seniorDebt_;
    // }

    // function calcSeniorNewAsset() internal view returns (uint256) {
    //     // Implementation for calculating senior new asset
    // }

    function calcExpectedSeniorAsset(
        uint256 seniorRedeem,
        uint256 seniorSupply,
        uint256 seniorBalance_,
        uint256 seniorDebt_
    ) public pure returns (uint256 expectedSeniorAsset_) {
        return safeSub(safeAdd(safeAdd(seniorDebt_, seniorBalance_), seniorSupply), seniorRedeem);
    }
}
