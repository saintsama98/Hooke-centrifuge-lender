// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Auth
/// @notice Minimal ward based access control, in the style used across MakerDAO and
/// Centrifuge. Each inheriting contract keeps its own set of authorised addresses. An
/// address with wards set to 1 may call any function marked auth. The deployer is
/// authorised on construction, so it can authorise the intended controllers and then
/// usually remove itself once wiring is done.
/// @dev Not audited. Provided for study alongside the rest of this codebase.
abstract contract Auth {
    /// @notice 1 if the address is authorised, otherwise 0.
    mapping(address => uint256) public wards;

    event Rely(address indexed usr);
    event Deny(address indexed usr);

    error NotAuthorized();

    /// @notice Restricts a function to authorised addresses.
    modifier auth() {
        if (wards[msg.sender] != 1) revert NotAuthorized();
        _;
    }

    constructor() {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    /// @notice Grants authorisation to an address.
    /// @param usr Address to authorise.
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    /// @notice Removes authorisation from an address.
    /// @param usr Address to remove.
    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }
}
