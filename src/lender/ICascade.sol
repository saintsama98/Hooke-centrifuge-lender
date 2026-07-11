//SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

///@title ICascade
///@author adiii.eth (https://adiii.eth.limo)
///@notice Interface for ERC — priority-of-payments ("cascade") distribution cascade engine.
///
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

///
///@notice SCOPE — the interface standardises the plumbing (the deterministic split
/// of cash and loss) and exposes the calibration (coverage triggers, ratio bounds)
/// as explicit, governable, queryable parameters. It deliberately does NOT specify:
///  1. loss recognition — how loss is measured or attested (NAV oracles, write-off
///     schedules) is delegated to the implementation's valuation module;
///  2. tranche tokenisation — how claims are represented (ERC-20 pairs, ERC-6909,
///     ERC-3475) is delegated to a composed token standard;
///  3. settlement cadence — the engine may be invoked continuously or batched into
///     epochs (cf. ERC-7540 asynchronous flows).
///
///@dev All amounts are denominated in the single underlying ERC-20 asset. Ratios
/// are fixed-point integers scaled by 1e27 (RAY), where 1e27 == 1.0 == 100%.
///
///@dev Invariants a conforming implementation upholds:
///  I1 distribution order — tranche i receives no value until every tranche j < i
///     has received its full entitlement for that distribution;
///  I2 loss order — tranche i absorbs no loss until every tranche k > i has been
///     written down to zero;
///  I3 conservation — per-tranche amounts of a distribution or loss allocation sum
///     to the input amount (modulo bounded rounding dust);
///  I4 diversion — while a coverage test of tranche i is breached, amounts otherwise
///     payable to tranches junior to i are re-routed toward tranche i until cured.

interface ICascade {
    ///@notice Meant to get the senior accruel + par from the cascade or waterfall.
    function getTrancheAssets(uint256 trancheId) external view returns (uint256);
    function getNav() external view returns (uint256);

    ///@notice rebalancer/ distributor for the tranches based on the senior gallons only (simple structuring)
    function trancher(uint256 assets) external returns (uint256[] memory perTrancheDistribution);

    ///@notice  tinlake style drip / accrual of the senior debt based on new_senior_debt > old_senior_debt
    function fillSeniorDebt(uint256 assets) external returns (uint256);
}
