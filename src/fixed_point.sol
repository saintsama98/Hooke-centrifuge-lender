// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A ratio, rate, price or fulfilment percentage held in 27 decimal fixed
/// point, where 1e27 means one.
///
/// @dev Declared at file level rather than inside an abstract contract so that
/// interface declarations can reference it.
///
/// @dev A value is either a plain uint256 in the decimals of the underlying asset, or
/// a Fixed27 carrying a ratio. Never both. Mixing the two is an easy way to break a
/// waterfall, because a ratio read as an amount is wrong by a factor of 1e27 and still
/// compiles.
struct Fixed27 {
    uint256 value;
}
