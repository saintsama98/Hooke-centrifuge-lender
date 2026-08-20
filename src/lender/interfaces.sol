// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../fixed_point.sol";

/// @title Hooke lender seams
/// @author adiii.eth
///
/// @notice Every call one lender contract makes into another is declared here, so the
/// whole architecture can be read on one page.
///
/// @notice Note on status. Not audited. Written for study, and under development.
///
/// @dev The four actors and what each one is allowed to do.
///  tranche      One per seniority class. Owns user orders and escrow. Knows nothing
///               about the other tranches and nothing about risk.
///  idle         The cash pot. Owns currency at rest. Knows nothing else.
///  assessor     Valuation and allocation. Owns the net asset value, the ratios, the
///               token prices and the waterfall itself. Holds no cash.
///  coordinator  Orchestration. Opens and closes epochs, checks a proposed allocation
///               and executes it. Holds no cash and computes no valuation.
///
/// @dev Valuation that cannot move money, and orchestration that cannot value
/// anything, is what lets each piece be replaced on its own.

/// @notice The underlying asset and the tranche tokens both sit behind this.
/// @dev mint and burn are used on tranche tokens only. The underlying asset needs
/// neither and may revert on both.
interface ERC20Like {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address usr, uint256 amount) external;
    function mint(address usr, uint256 amount) external;
    function burn(address usr, uint256 amount) external;
}

/// @notice The reserve, meaning currency at rest between epochs. Implemented by idle.
/// @dev Named idle rather than reserve because that is what the balance is: supplied
/// capital that is not currently deployed against the borrower side.
interface IdleLike {
    function totalBalance() external view returns (uint256);
    function deposit(uint256 currencyAmount) external;
    function payout(uint256 currencyAmount) external;
    function file(bytes32 what, uint256 amount) external;
}

/// @notice The borrower side valuation feed.
/// @dev This is the extension point that matters most. Everything in this repository
/// is the lending side of a pool, which decides who gets paid in what order. What the
/// assets are actually worth is a separate problem and is not solved here. A
/// discounted cash flow feed over a loan book, an oracle, or a single number set by
/// governance in a test deployment all satisfy this seam. The smallest working example
/// is test/mock/navfeed.sol.
/// @dev currentNAV must not change state. calcUpdateNAV may, so a feed can write down
/// an accrual at epoch close. A feed with nothing to settle can implement the second
/// as a call to the first.
interface NavLike {
    function currentNAV() external view returns (uint256);
    function calcUpdateNAV() external returns (uint256);
}

/// @notice What the coordinator needs from a tranche. Nothing about orders and nothing
/// about users, because the coordinator moves aggregates and never touches a position.
interface EpochTrancheLike {
    function closeEpoch() external returns (uint256 totalSupplyCurrency, uint256 totalRedeemToken);
    function epochUpdate(
        uint256 epochID,
        uint256 supplyFulfillment_,
        uint256 redeemFulfillment_,
        uint256 tokenPrice_,
        uint256 epochSupplyOrderCurrency,
        uint256 epochRedeemOrderCurrency
    ) external;
}

/// @notice What a tranche needs from the coordinator, which is only where the epoch
/// cycle currently stands.
/// @dev The tranche never asks the coordinator to do anything. That one way dependency
/// is why the two can be replaced separately.
interface EpochPlacementLike {
    function currentEpoch() external view returns (uint256);
    function lastEpochExecuted() external view returns (uint256);
}

/// @notice What the assessor needs from a tranche in order to price it.
interface TrancheLike {
    function tokenSupply() external view returns (uint256);
}

/// @notice What the coordinator needs from the assessor.
/// @dev Every member here is read only from the coordinator side except
/// changeSeniorAsset, which is the single write the coordinator may make into
/// valuation, and only at the end of a successful epoch.
interface AssessorLike {
    function calcUpdateNAV() external returns (uint256);
    function calcSeniorTokenPrice(uint256 nav_, uint256 reserve_) external view returns (Fixed27 memory);
    function calcJuniorTokenPrice(uint256 nav_, uint256 reserve_) external view returns (Fixed27 memory);
    function seniorDebt() external view returns (uint256);
    function seniorBalance() external view returns (uint256);
    function seniorRatioBounds() external view returns (Fixed27 memory minRatio, Fixed27 memory maxRatio);
    function maxReserve() external view returns (uint256);
    function changeSeniorAsset(uint256 seniorRatio_, uint256 seniorSupply, uint256 seniorRedeem) external;
}

/// @notice What the operator needs from a tranche in order to serve a user.
interface OperatorTrancheLike {
    function supplyOrder(address usr, uint256 newSupplyAmount) external;
    function redeemOrder(address usr, uint256 newRedeemAmount) external;
    function deservedRelease(address usr, uint256 endEpoch)
        external
        returns (uint256 payoutCurrency, uint256 payoutToken, uint256 remainingSupply, uint256 remainingRedeem);
    function calculateDeservedRelease(address usr, uint256 endEpoch)
        external
        view
        returns (uint256 payoutCurrency, uint256 payoutToken, uint256 remainingSupply, uint256 remainingRedeem);
}

/// @notice Optional permissioning hook.
/// @dev Tinlake requires a memberlist on every tranche because it was built for
/// regulated real world asset pools where the issuer must know every holder. That is a
/// property of those pools rather than of tranching, so here it is optional. An
/// operator with a zero memberlist address is permissionless, and that is the default.
interface MemberlistLike {
    function hasMember(address usr) external view returns (bool);
}
