// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  Math — RAY (1e27) fixed-point helpers, MakerDAO "dss" style.
/// @notice Solidity 0.8 checks add/sub/mul for overflow natively, so no
///         safe-arithmetic wrappers are needed; only fixed-point multiply,
///         divide, and power are defined. All ratios and rates in the system are
///         RAY-scaled: `ONE` (1e27) represents 1.0 (= 100%).
abstract contract Math {
    /// @notice One in RAY fixed-point: 1e27 == 1.0 == 100%.
    uint256 internal constant ONE = 1e27;

    error DivideByZero();

    /// @notice Multiply two RAY numbers, rounding down.
    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = (x * y) / ONE;
    }

    /// @notice Divide RAY `x` by RAY `y`, rounding to nearest (half up).
    function rdiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        if (y == 0) revert DivideByZero();
        z = (x * ONE + y / 2) / y;
    }

    /// @notice Divide RAY `x` by RAY `y`, rounding up.
    function rdivup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        if (y == 0) revert DivideByZero();
        z = (x * ONE + (y - 1)) / y;
    }

    /// @notice `x` raised to the power `n` in fixed-point with the given `base`
    ///         (pass `ONE` for RAY). Used for per-second interest compounding.
    /// @dev    Canonical MakerDAO dss `rpow`, with in-assembly overflow guards.
    function rpow(uint256 x, uint256 n, uint256 base) internal pure returns (uint256 z) {
        assembly {
            switch x
            case 0 {
                switch n
                case 0 { z := base }
                default { z := 0 }
            }
            default {
                switch mod(n, 2)
                case 0 { z := base }
                default { z := x }
                let half := div(base, 2)
                for { n := div(n, 2) } n { n := div(n, 2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0, 0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0, 0) }
                    x := div(xxRound, base)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0, 0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0, 0) }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }
}
