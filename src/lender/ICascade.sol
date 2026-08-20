//SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

///@title ICascade
///@author adiii.eth (https://adiii.eth.limo)
///@notice A cascade is the deterministic engine at the heart of any tranched
/// structure: it routes incoming cash flow across an ordered set of tranches in
/// strictly decreasing order of seniority, and allocates realised loss across the
/// same set in strictly increasing order of seniority. The senior-most tranche is
/// paid first and impaired last; the junior-most tranche is paid last and impaired
/// first. This interface standardises that engine: the priority of payments, the
/// loss allocation, and the coverage tests whose breach re-routes cash flow away
/// from junior tranches toward the repayment of senior obligations until the
/// measured ratio is restored (diversion).

///@notice MOTIVATION : Centrifuge tinlake is the only motivation for this interface design as tinlake has a clear seam over
/// the distribution and epoch wise execution, genuine showcasing of the tranche hierarchy.
/// Various layouts / invarient specs were tried before settling current implementation.

///@notice Current implementation is as per current specefications only, may alter in future.

///@notice SCOPE - the interface standardises the plumbing (the deterministic split
/// of cash and loss) and exposes the calibration (coverage triggers, ratio bounds)
/// as explicit, governable, queryable parameters. It deliberately does NOT specify:
///  1. loss recognition: how loss is measured or attested (NAV oracles, write-off
///     schedules) is delegated to the implementation's valuation module;
///  2. tranche tokenisation - how claims are represented (ERC-20 pairs, ERC-6909,
///     ERC-3475) is delegated to a composed token standard;
///  3. settlement cadence - the engine may be invoked continuously or batched into
///     epochs (cf. ERC-7540 asynchronous flows).

/*IMPORTANT*/
/// The implementation side is under development and this surface is expected to change.
///
/// @notice What is covered and what is left out. Covered: the split of cash and of
/// loss between tranches, and the settings that drive that split, exposed as values
/// anyone can read. Left out: how loss is measured and who attests to it, how a tranche
/// claim is represented as a token, and whether the engine runs continuously or in
/// batches. Those belong to whatever an implementation composes with.
///
/// @dev Amounts are in the single underlying asset of the pool. Ratios use 27 decimal
/// fixed point, so a value of 1e27 means one.
///
/// @dev Rules an implementation is expected to hold.
///  I1 payment order. A tranche receives nothing until every tranche senior to it has
///     received its full entitlement for that payment.
///  I2 loss order. A tranche absorbs no loss until every tranche junior to it has been
///     written down to zero.
///  I3 conservation. The per tranche amounts of a payment or a loss add up to the
///     amount that went in, apart from rounding dust.
///  I4 diversion. While a coverage test on a tranche is breached, amounts that would
///     have gone to tranches junior to it are sent to that tranche instead, until the
///     test passes again.
///
/// @dev Where this comes from. Three of the four functions below have a direct
/// equivalent in Centrifuge Tinlake and were taken from a system that ran on mainnet.
/// getNav is assessor.currentNAV. getTrancheAssets is the senior debt and senior
/// balance pair. fillSeniorDebt is dripSeniorDebt followed by reBalance. The fourth,
/// trancher, has no equivalent. Tinlake never splits an amount across tranches by a
/// rule that lives in one function. It takes fulfilment percentages from a solver that
/// runs off chain and pushes them into two contracts wired in by name. trancher exists
/// so that I1 and I3 can be checked rather than inferred, and it is the reason this
/// interface is kept separate from the assessor.
///
/// @dev What is not in this interface yet. I2 and I4 are written down because they are
/// what a cascade is for, but the functions below do not expose loss allocation or a
/// coverage test, so an implementation holds those two rules without doing anything.
/// Adding allocateLoss and a coverage test triple is the next step. The rules are
/// stated now so that adding them does not change what they mean.
interface ICascade {
    /// @notice Assets attributable to one tranche.
    /// @param trancheId Index of the tranche. 0 is the most senior, and seniority
    /// falls as the index rises.
    /// @return Value claimable by that tranche, in the underlying asset.
    /// @dev Must be defined for every index below the tranche count, and must revert
    /// outside that range rather than return zero. A zero for an index that does not
    /// exist reads as a tranche that has been wiped out, which is a different claim.
    function getTrancheAssets(uint256 trancheId) external view returns (uint256);

    /// @notice Net asset value of the pool, as reported by the valuation module.
    /// @return The current net asset value, in the underlying asset.
    /// @dev Read only. An implementation that has to settle an accrual before it can
    /// report exposes that separately. See NavLike.calcUpdateNAV.
    function getNav() external view returns (uint256);

    /// @notice Split an amount of the underlying asset across the tranches.
    /// @param assets Amount to route through the cascade.
    /// @return perTrancheDistribution Amount given to each tranche, indexed by
    /// trancheId, most senior first.
    /// @dev Holds I1, because the senior tranche is filled to its entitlement before
    /// any junior tranche receives anything, and I3, because the returned amounts add
    /// up to assets.
    /// @dev Changes state, because the senior entitlement earns interest. The
    /// entitlement has to be brought up to the current block before it can be filled.
    /// Filling a stale entitlement overstates the junior residual by exactly the
    /// interest that was never accrued.
    function trancher(uint256 assets) external returns (uint256[] memory perTrancheDistribution);

    /// @notice Accrue senior interest, then rebalance the senior claim.
    /// @param seniorAsset_ Senior asset value to rebalance against.
    /// @return Senior debt after the accrual and the rebalance.
    /// @dev Two steps, in this order. Accrue interest onto the senior debt, then split
    /// the given senior asset into the part that earns interest and the part that does
    /// not. Rebalancing before accruing applies the new split to a stale debt figure
    /// and loses one period of senior interest.
    function fillSeniorDebt(uint256 seniorAsset_) external returns (uint256);
}
