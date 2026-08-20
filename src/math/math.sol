// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  Math — RAY (1e27) fixed-point + safe arithmetic, MakerDAO "dss" style.
/// @notice Ported to parity with Centrifuge `tinlake-math`. All ratios and rates
///         are RAY-scaled: `ONE` (1e27) represents 1.0 (= 100%).
/// @dev    Solidity 0.8 already reverts on overflow / underflow / div-by-zero, so
///         the `safe*` helpers are thin, name-compatible wrappers — they exist so
///         logic ported from Tinlake's `definitions.sol` / `assessor.sol`
///         (which call `safeAdd`/`safeSub`/`safeMul`) resolves unchanged. In new
///         code you may use the native `+ - * /` directly with identical safety.
abstract contract Math {
    /// @notice One in RAY fixed-point: 1e27 == 1.0 == 100%.
    uint256 internal constant ONE = 1e27;

    error DivideByZero();

    // --------------------------------------------------------------------------
    // Safe arithmetic (Tinlake-API parity; 0.8 enforces the checks natively)
    // --------------------------------------------------------------------------

    function safeAdd(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x + y;
    }

    function safeSub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x - y;
    }

    function safeMul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x * y;
    }

    function safeDiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x / y;
    }

    /// @notice Saturating subtraction: returns 0 instead of reverting when `amount > total`.
    /// @dev    Tinlake keeps this on `Tranche` as a private helper. It is hoisted here
    ///         because it is generic and because the epoch bookkeeping in `tranche.sol`
    ///         legitimately drifts by rounding dust: `totalSupply` can end an epoch a few
    ///         wei below the amount being retired, and a revert there would wedge the
    ///         whole pool over a rounding error. Use it ONLY for that. Anywhere a
    ///         negative result is a real accounting fault, use `safeSub` and let it revert.
    function safeTotalSub(uint256 total, uint256 amount) internal pure returns (uint256) {
        if (total < amount) return 0;
        return total - amount;
    }

    // --------------------------------------------------------------------------
    // RAY fixed-point (built on the safe helpers, exactly as in tinlake-math)
    // --------------------------------------------------------------------------

    /// @notice Multiply two RAY numbers, rounding down.
    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = safeMul(x, y) / ONE;
    }

    /// @notice Divide RAY `x` by RAY `y`, rounding to nearest (half up).
    function rdiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        if (y == 0) revert DivideByZero();
        z = safeAdd(safeMul(x, ONE), y / 2) / y;
    }

    /// @notice Divide RAY `x` by RAY `y`, rounding up.
    function rdivup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        if (y == 0) revert DivideByZero();
        z = safeAdd(safeMul(x, ONE), safeSub(y, 1)) / y;
    }

    // --------------------------------------------------------------------------
    // rpow — x^n in fixed-point with `base` (pass `ONE` for RAY).
    // Used for per-second interest compounding. Canonical MakerDAO dss rpow.
    // --------------------------------------------------------------------------

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
