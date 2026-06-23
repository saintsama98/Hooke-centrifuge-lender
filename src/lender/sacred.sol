// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "../math/math.sol";
import {fixedPoint} from "../fixed_point.sol";


/// @notice This contract defines all the functions that are inherited by operator and accessor
/// the sole purpose being abstraction and modularity, these functions are core to lending side operation

abstract contract sacred is Math, fixedPoint {

    /// @notice deposits, curation and redemption all phases in lifecycle are the only ones which are considered valid
    /// in this codebase, i,e these smart contracts are written for lender side waterfall model only.
    /// @dev these are the base types of senior tier (tranche) mechanics Hooke promotes and is built around:
    /// 1/ calcSeniorDebtAssets
    /// 2/ calcOverallNAV
    /// 3/ calcSeniorRatio
    /// 4/ calcSeniorNewAsset
    /// 5/ calcSeniorExpectedAsset

    function calcSeniorDebtAssets() internal view returns (uint256) {
        // Implementation for calculating senior debt assets
    }

    function calcOverallNAV() internal view returns (uint256) {
        // Implementation for calculating overall net asset value
    }

    function calcSeniorRatio() internal view returns (uint256) {
        // Implementation for calculating senior ratio
    }

    function calcSeniorNewAsset() internal view returns (uint256) {
        // Implementation for calculating senior new asset
    }

    function calcSeniorExpectedAsset() internal view returns (uint256) {
        // Implementation for calculating senior expected asset
    }
}
