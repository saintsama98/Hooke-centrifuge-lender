// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../math/math.sol";
import "../fixed_point.sol";
import "../auth/auth.sol";
// import "../math/interest.sol";

/// @notice original code base from tinlake plays major role in batching, epoch side orchestration and submission period
// handling the best solution submission and challenge period. We will keep a minimal version possible to avoid complexity and surface.

interface EpochLike {}

interface IdleLike {}

