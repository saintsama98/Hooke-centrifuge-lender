// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../math/math.sol";
import "../auth/auth.sol";
import "./interfaces.sol";

/// @title idle
/// @author adiii.eth
/// @notice The reserve of the pool, meaning supplied capital that is not currently
/// financing anything. Tranches pay surplus in at the end of an epoch and draw
/// redemptions out of it, and the borrower side draws against currencyAvailable to
/// fund new lending.
///
/// @notice Note on status. Not audited. Written for study, and under development.
///
/// @dev The cash of the pool sits in one contract rather than in each tranche. With
/// one pot there is one balance to read, and asking whether there is enough to pay
/// this epoch does not become a sum over several contracts. This contract holds no
/// view about tranching at all, so it is the one actor that can be understood without
/// knowing what a tranche is.
///
/// @dev The balance is tracked explicitly rather than read from the token balance of
/// this contract. A donated balance would otherwise count as pool assets, raise the
/// net asset value, and be paid out to whoever redeems first. The accounting balance
/// and the token balance are allowed to differ, and only the accounting balance is
/// ever distributed.
contract idle is Math, Auth {
    ERC20Like public currency;

    /// @notice Total currency held by the pool, by its own accounting.
    uint256 public balance_;

    /// @notice Currency the borrower side may draw for new lending this epoch.
    /// @dev Set to zero at epoch close and to the new reserve at epoch execution, both
    /// by the coordinator. Between those two points the borrower side cannot draw,
    /// which stops a loan being funded out of currency that an epoch in flight has
    /// already promised to redeemers.
    uint256 public currencyAvailable;

    event Deposit(address indexed from, uint256 amount);
    event Payout(address indexed to, uint256 amount);
    event File(bytes32 indexed what, uint256 amount);

    error NotEnoughCurrency();
    error TransferFailed();
    error UnknownParameter();

    constructor(address currency_) {
        currency = ERC20Like(currency_);
    }

    function file(bytes32 what, uint256 amount) public auth {
        if (what == "currencyAvailable") {
            currencyAvailable = amount;
        } else {
            revert UnknownParameter();
        }
        emit File(what, amount);
    }

    function depend(bytes32 contractName, address addr) public auth {
        if (contractName == "currency") {
            currency = ERC20Like(addr);
        } else {
            revert UnknownParameter();
        }
    }

    function totalBalance() public view returns (uint256) {
        return balance_;
    }

    /// @notice Pulls currency from the caller into the reserve.
    /// @param currencyAmount Amount to pull, in the underlying asset.
    /// @dev The caller must have approved this contract first. Tranches do that in
    /// adjustCurrencyBalance immediately before calling.
    function deposit(uint256 currencyAmount) public auth {
        if (!currency.transferFrom(msg.sender, address(this), currencyAmount)) revert TransferFailed();
        balance_ = safeAdd(balance_, currencyAmount);
        emit Deposit(msg.sender, currencyAmount);
    }

    /// @notice Sends currency from the reserve to the caller.
    /// @param currencyAmount Amount to send, in the underlying asset.
    /// @dev Reverts rather than paying out less if the reserve is short. A quiet
    /// partial payout would let a tranche believe it had settled a redemption that it
    /// did not settle. A caller that wants the clamped behaviour clamps to
    /// totalBalance first, which is what tranche.safePayout does.
    function payout(uint256 currencyAmount) public auth {
        if (currencyAmount > balance_) revert NotEnoughCurrency();
        balance_ = safeSub(balance_, currencyAmount);
        if (!currency.transfer(msg.sender, currencyAmount)) revert TransferFailed();
        emit Payout(msg.sender, currencyAmount);
    }
}
