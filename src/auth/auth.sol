// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  Auth — minimal ward-based access control.
/// @notice MakerDAO "dss" style, as used across Centrifuge. Each inheriting
///         contract carries its own authorization set: an address with
///         `wards[addr] == 1` may call `auth`-gated functions. The deployer is
///         relied on construction; it can then `rely` the intended controllers
///         and (typically) `deny` itself once wiring is complete.
abstract contract Auth {
    /// @notice 1 if `usr` is authorized, else 0.
    mapping(address => uint256) public wards;

    event Rely(address indexed usr);
    event Deny(address indexed usr);

    error NotAuthorized();

    /// @notice Restrict a function to authorized wards.
    modifier auth() {
        if (wards[msg.sender] != 1) revert NotAuthorized();
        _;
    }

    constructor() {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    /// @notice Grant authorization to `usr`.
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    /// @notice Revoke authorization from `usr`.
    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }
}
