//SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "../auth/auth.sol";
import "./interfaces.sol";

/// @title Operator
/// @author adiii.eth
/// @notice The only contract an end user calls. One operator per tranche. Placing an
/// order, changing it, cancelling it and collecting all go through here.
///
/// @notice Note on status. Not audited. Written for study, and under development.
///
/// @dev It exists as a separate contract even though it mostly forwards, because every
/// entry point on the tranche is gated on authorisation and the operator is the one
/// address allowed to call it. That buys two things. Access policy lives in one small
/// contract that can be replaced without migrating any position, so swapping the
/// operator turns a permissionless pool into a permissioned one with every balance
/// untouched. And the tranche never has to ask who the caller is, so all of its logic
/// is about epochs and none of it is about identity.
///
/// @dev The Tinlake operator also carries permit variants so a user can approve and
/// order in one transaction. That is left out here. It is a convenience over the same
/// two calls and adds a signature surface that has nothing to say about tranching.
contract Operator is Auth {
    OperatorTrancheLike public tranche;

    /// @notice Optional. When the address is zero the pool is permissionless, which
    /// is the default.
    /// @dev See MemberlistLike in interfaces.sol for why this is optional rather than
    /// assumed.
    MemberlistLike public memberlist;

    error NotAMember();
    error UnknownParameter();

    constructor(address tranche_) {
        tranche = OperatorTrancheLike(tranche_);
    }

    function depend(bytes32 contractName, address addr) public auth {
        if (contractName == "tranche") {
            tranche = OperatorTrancheLike(addr);
        } else if (contractName == "memberlist") {
            memberlist = MemberlistLike(addr);
        } else {
            revert UnknownParameter();
        }
    }

    /// @dev Passes when no memberlist is configured. That is the intended default. A
    /// tranching framework should permit an allowlist rather than require one.
    modifier permitted(address usr) {
        if (address(memberlist) != address(0) && !memberlist.hasMember(usr)) revert NotAMember();
        _;
    }

    /// @notice Places or changes the supply order of the caller, in currency.
    /// @param amount New order size. Zero cancels the order and refunds it.
    function supplyOrder(uint256 amount) public permitted(msg.sender) {
        tranche.supplyOrder(msg.sender, amount);
    }

    /// @notice Places or changes the redeem order of the caller, in tranche tokens.
    /// @param amount New order size. Zero cancels the order.
    function redeemOrder(uint256 amount) public permitted(msg.sender) {
        tranche.redeemOrder(msg.sender, amount);
    }

    /// @notice Collects everything owed to the caller from every executed epoch.
    function deservedRelease()
        public
        returns (uint256 payoutCurrency, uint256 payoutToken, uint256 remainingSupply, uint256 remainingRedeem)
    {
        return tranche.deservedRelease(msg.sender, type(uint256).max);
    }

    /// @notice Collects what is owed to the caller up to a given epoch only.
    /// @param endEpoch Last epoch to settle.
    /// @dev For a position that has sat through enough epochs that settling all of
    /// them in one transaction would run out of gas. Call again with a later bound to
    /// continue.
    function deservedRelease(uint256 endEpoch)
        public
        returns (uint256 payoutCurrency, uint256 payoutToken, uint256 remainingSupply, uint256 remainingRedeem)
    {
        return tranche.deservedRelease(msg.sender, endEpoch);
    }

    /// @notice Previews a collection without performing it.
    /// @param usr Address to preview for.
    /// @param endEpoch Last epoch to include.
    function calculateDeservedRelease(address usr, uint256 endEpoch)
        public
        view
        returns (uint256 payoutCurrency, uint256 payoutToken, uint256 remainingSupply, uint256 remainingRedeem)
    {
        return tranche.calculateDeservedRelease(usr, endEpoch);
    }
}
