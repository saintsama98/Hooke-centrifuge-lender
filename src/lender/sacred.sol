// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../math/math.sol";
import "../fixed_point.sol";

/// @title sacred
/// @notice The ratio arithmetic shared by the assessor and the coordinator, together
/// with the senior tranche state that both of them read.
///
/// @notice Note on status. Not audited. Written for study, and under development.
///
/// @dev Tinlake computes the senior asset value in its assessor and the senior ratio
/// in its coordinator, and both contracts carry their own copy of
/// calcSeniorAssetValue. The copies are kept in step by hand. Here every function both
/// actors need is held in one place, so the ratio arithmetic is changed once.
///
/// @dev The senior tranche state lives here for the same reason. It is the only
/// mutable state in this file and it is internal. The assessor may move it, the
/// coordinator may only read it back through AssessorLike, and nothing else touches it.
///
/// @dev Everything else here is pure, so the ratio arithmetic can be fuzzed on its own
/// without deploying a pool or a valuation feed. See test/lender/sacred.t.sol.
abstract contract sacred is Math {
    /// @notice Senior claim that earns interest.
    uint256 internal seniorDebt_;

    /// @notice Senior claim that does not earn interest, meaning senior capital
    /// sitting in the reserve rather than deployed against the net asset value.
    /// @dev The split between debt and balance is the reason fillSeniorDebt exists.
    /// Senior capital earns its rate only while it is financing the asset side. Idle
    /// senior capital earning the senior rate would pay interest out of junior equity
    /// for nothing.
    uint256 internal seniorBalance_;

    /// @notice Total assets of the pool.
    /// @param nav_ Borrower side net asset value.
    /// @param reserve_ Currency sitting idle in the reserve.
    /// @return Sum of the two.
    function calcAssets(uint256 nav_, uint256 reserve_) public pure returns (uint256) {
        return safeAdd(nav_, reserve_);
    }

    /// @notice Total asset value of the senior tranche.
    /// @param _debt Senior claim that earns interest.
    /// @param _balance Senior claim that does not.
    /// @return _seniorAsset The two halves recombined.
    function calcExpectedSeniorAssets(uint256 _debt, uint256 _balance) public pure returns (uint256 _seniorAsset) {
        return safeAdd(_debt, _balance);
    }

    /// @notice Share of total assets claimed by the senior tranche.
    /// @param _seniorAsset Senior asset value.
    /// @param _nav Borrower side net asset value.
    /// @param _reserve Currency in the reserve.
    /// @return seniorRatio The share, in 27 decimal fixed point.
    function calcSeniorRatio(uint256 _seniorAsset, uint256 _nav, uint256 _reserve)
        public
        pure
        returns (uint256 seniorRatio)
    {
        uint256 assets = calcAssets(_nav, _reserve);
        if (assets == 0) return 0;
        return rdiv(_seniorAsset, assets);
    }

    /// @notice Share of total assets left to the junior tranche.
    /// @param _seniorAsset Senior asset value.
    /// @param _nav Borrower side net asset value.
    /// @param _reserve Currency in the reserve.
    /// @return The share, in 27 decimal fixed point.
    /// @dev Tinlake has no junior ratio function, because junior is always implicit as
    /// the residual. It is written out here because the residual is where rule I3 can
    /// be checked, and an implicit quantity cannot be asserted on. The senior ratio and
    /// the junior ratio add up to one whenever the senior claim has not been wiped out.
    /// @dev Pure, taking the senior asset as an argument rather than reading state, so
    /// the one function that expresses the loss absorption boundary can be fuzzed
    /// without a live pool.
    function calcJuniorRatio(uint256 _seniorAsset, uint256 _nav, uint256 _reserve) public pure returns (uint256) {
        uint256 assets = calcAssets(_nav, _reserve);
        if (assets == 0) return 0;
        // senior claim exceeds the pool, so junior is wiped out and senior takes all
        if (_seniorAsset >= assets) return 0;
        // no senior claim at all, so junior owns the pool outright
        if (_seniorAsset == 0) return ONE;
        return safeSub(ONE, rdiv(_seniorAsset, assets));
    }

    /// @notice Senior asset value after a supply and a redemption, before rebalancing.
    /// @param seniorRedeem Senior redemption settled this epoch, in currency.
    /// @param seniorSupply Senior supply settled this epoch, in currency.
    /// @param seniorBalance Senior claim not earning interest.
    /// @param seniorDebt Senior claim earning interest.
    /// @return expectedSeniorAsset_ The resulting senior asset value.
    function calcExpectedSeniorAsset(
        uint256 seniorRedeem,
        uint256 seniorSupply,
        uint256 seniorBalance,
        uint256 seniorDebt
    ) public pure returns (uint256 expectedSeniorAsset_) {
        return safeSub(safeAdd(safeAdd(seniorDebt, seniorBalance), seniorSupply), seniorRedeem);
    }

    /// @notice Senior asset value after a supply and a redemption, capped at the total
    /// assets of the pool.
    /// @param seniorRedeem Senior redemption settled this epoch, in currency.
    /// @param seniorSupply Senior supply settled this epoch, in currency.
    /// @param currSeniorAsset Senior asset value before this epoch.
    /// @param reserve_ Currency in the reserve.
    /// @param nav_ Borrower side net asset value.
    /// @return seniorAsset The capped senior asset value.
    /// @dev The cap is the loss absorption rule. When the pool is worth less than the
    /// senior claim, the senior claim is truncated to the pool. That truncation is
    /// where rule I2 takes effect: junior has already been written to zero by
    /// calcJuniorRatio returning zero, and only then does senior start to absorb.
    /// Without the cap the senior tranche would report a claim on value that does not
    /// exist.
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
}
