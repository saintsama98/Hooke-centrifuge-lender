// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The simplest conforming `NavLike`: a single number somebody sets.
///
/// @dev    THIS IS THE SEAM WHERE REAL VALUATION GOES, and it is worth being blunt
///         about how much this mock is hiding. Tinlake's real feed prices a book of
///         loans by discounting expected cash flows and writing down overdue ones.
///         That is a whole subsystem, it lives on the borrower side, and none of it
///         is in this repository.
///
/// @dev    What the lender guarantees is conditional on this number: given a correct
///         NAV, the waterfall pays out in the right order. It has no way to tell you
///         the NAV is wrong. Every real tranched pool that has failed, on-chain or
///         off, failed here rather than in the distribution logic.
contract SimpleNAVFeed {
    uint256 public nav;

    function file(bytes32 what, uint256 value) public {
        if (what == "nav") nav = value;
    }

    function currentNAV() public view returns (uint256) {
        return nav;
    }

    /// @dev A feed with nothing to settle implements the writing form as the reading one.
    function calcUpdateNAV() public view returns (uint256) {
        return nav;
    }
}
