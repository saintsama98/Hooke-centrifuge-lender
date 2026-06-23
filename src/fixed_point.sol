// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6;

/// @notice abstract contract for FixedPoint math operations
/// defining ONE with 10^27 precision
abstract contract fixedPoint {
    struct Fixed27 {
        uint256 value;
    }
}
