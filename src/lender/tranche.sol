//SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "../math/math.sol";
import "../fixed_point.sol";
import "../auth/auth.sol";
import "./interfaces.sol";

/// @title Tranche
/// @author adiii.eth
/// @notice Holds the orders and the escrow for one seniority class. A pool with a
/// senior and a junior class deploys this twice, against two different tranche tokens,
/// and wires both into one coordinator. The contract does not know which one it is.
/// Nothing here knows about seniority, ratios or the other tranche, and all of that
/// lives in the assessor. Adding a third class is a change to the deployment and to
/// the coordinator, not to this contract.
///
/// @notice Note on status. Not audited. Written for study, and under development.
///
/// @dev The order lifecycle runs in four steps.
///  1. supplyOrder or redeemOrder. A user states intent. Currency or tokens are held
///     here and the order is tagged with the current epoch.
///  2. closeEpoch. The coordinator snapshots the total and locks this tranche until it
///     hears back.
///  3. epochUpdate. The coordinator reports what share of the orders was filled and at
///     what price. Tokens are minted or burned and currency settles against the
///     reserve once, in total.
///  4. deservedRelease. Each user pulls their own share of every epoch executed since
///     they ordered.
///
/// @dev Steps 2 and 3 cost the same no matter how many users there are. Step 4 is the
/// only work done per user and the user pays for it. That is the reason for the epoch
/// design: a pool with ten thousand suppliers settles in one transaction.
contract Tranche is Math, Auth {
    mapping(uint256 => Epoch) public epochs;

    struct Epoch {
        /// @notice Share of the supply orders of the epoch that was filled, in 27
        /// decimal fixed point. An order is placed in full but the coordinator may
        /// fill less than all of it, because of the constraints of the pool.
        Fixed27 supplyFulfillment;
        /// @notice Share of the redeem orders of the epoch that was filled, in 27
        /// decimal fixed point.
        Fixed27 redeemFulfillment;
        /// @notice Token price at the end of the epoch, in 27 decimal fixed point.
        Fixed27 tokenPrice;
    }

    struct UserOrder {
        uint256 orderedInEpoch;
        uint256 supplyCurrencyAmount;
        uint256 redeemTokenAmount;
    }

    /// @notice Aggregate open supply orders, in currency.
    uint256 public totalSupply;
    /// @notice Aggregate open redeem orders, in tranche tokens.
    uint256 public totalRedeem;

    mapping(address => UserOrder) public users;

    ERC20Like public currency;
    ERC20Like public token;
    IdleLike public reserve;
    EpochPlacementLike public epochPlacement;

    address self;

    /// @notice True between closeEpoch and epochUpdate.
    /// @dev The lock that makes the two step handshake safe. Without it a coordinator
    /// could close twice and snapshot the same orders into two epochs, or update an
    /// epoch it never closed.
    bool public waitingForUpdate = false;

    event SupplyOrder(address indexed usr, uint256 amount);
    event RedeemOrder(address indexed usr, uint256 amount);
    event EpochUpdate(
        uint256 indexed epochID, uint256 supplyFulfillment, uint256 redeemFulfillment, uint256 tokenPrice
    );
    event Release(address indexed usr, uint256 payoutCurrency, uint256 payoutToken);

    error ReleaseRequiredFirst();
    error TransferFailed();
    error NotWaitingForUpdate();
    error AlreadyClosed();
    error UnknownParameter();

    /// @dev A user may place a new order only when both open orders are empty, or
    /// when the existing order belongs to the current epoch. Requiring both to be
    /// empty matters. A user holding an order from an executed epoch has to collect it
    /// before ordering again, because the epoch a user ordered in is stored as a single
    /// cursor. Overwriting it with a new epoch would start the release walk in the
    /// wrong place and give up everything in between.
    modifier orderAllowed(address usr) {
        if (!((users[usr].supplyCurrencyAmount == 0 && users[usr].redeemTokenAmount == 0)
                    || users[usr].orderedInEpoch == epochPlacement.currentEpoch())) revert ReleaseRequiredFirst();
        _;
    }

    /// @param currency_ Address of the underlying asset.
    /// @param token_ Address of the tranche token.
    constructor(address currency_, address token_) {
        token = ERC20Like(token_);
        currency = ERC20Like(currency_);
        self = address(this);
    }

    function depend(bytes32 contractName, address addr) public auth {
        if (contractName == "token") {
            token = ERC20Like(addr);
        } else if (contractName == "currency") {
            currency = ERC20Like(addr);
        } else if (contractName == "reserve") {
            reserve = IdleLike(addr);
        } else if (contractName == "epochPlacement") {
            epochPlacement = EpochPlacementLike(addr);
        } else {
            revert UnknownParameter();
        }
    }

    // views

    function balance() external view returns (uint256) {
        return currency.balanceOf(self);
    }

    function tokenSupply() external view returns (uint256) {
        return token.totalSupply();
    }

    // step 1, ordering. Orders are recorded against the current epoch and the value is
    // held here until the epoch settles. Supply and redeem are kept separate.

    /// @notice Sets the open supply order of a user, in currency.
    /// @param usr Address the order belongs to.
    /// @param newSupplyAmount New order size. Zero cancels the order and refunds it.
    /// @dev The amount is absolute rather than added to what is there. The difference
    /// is taken in or returned, so a user who lowers an order is not charged twice and
    /// one who raises it is not credited for currency that was never sent.
    function supplyOrder(address usr, uint256 newSupplyAmount) public auth orderAllowed(usr) {
        users[usr].orderedInEpoch = epochPlacement.currentEpoch();

        uint256 currentSupplyAmount = users[usr].supplyCurrencyAmount;
        users[usr].supplyCurrencyAmount = newSupplyAmount;
        totalSupply = safeAdd(safeTotalSub(totalSupply, currentSupplyAmount), newSupplyAmount);

        emit SupplyOrder(usr, newSupplyAmount);

        if (newSupplyAmount > currentSupplyAmount) {
            uint256 delta = safeSub(newSupplyAmount, currentSupplyAmount);
            if (!currency.transferFrom(usr, self, delta)) revert TransferFailed();
            return;
        }
        uint256 refund = safeSub(currentSupplyAmount, newSupplyAmount);
        if (refund > 0) {
            _safeTransfer(currency, usr, refund);
        }
    }

    /// @notice Sets the open redeem order of a user, in tranche tokens.
    /// @param usr Address the order belongs to.
    /// @param newRedeemAmount New order size. Zero cancels the order.
    function redeemOrder(address usr, uint256 newRedeemAmount) public auth orderAllowed(usr) {
        users[usr].orderedInEpoch = epochPlacement.currentEpoch();

        uint256 currentRedeemAmount = users[usr].redeemTokenAmount;
        users[usr].redeemTokenAmount = newRedeemAmount;
        totalRedeem = safeAdd(safeTotalSub(totalRedeem, currentRedeemAmount), newRedeemAmount);

        emit RedeemOrder(usr, newRedeemAmount);

        if (newRedeemAmount > currentRedeemAmount) {
            uint256 delta = safeSub(newRedeemAmount, currentRedeemAmount);
            if (!token.transferFrom(usr, self, delta)) revert TransferFailed();
            return;
        }
        uint256 refund = safeSub(currentRedeemAmount, newRedeemAmount);
        if (refund > 0) {
            _safeTransfer(token, usr, refund);
        }
    }

    // step 2, close. Hand the totals to the coordinator and lock.

    /// @notice Snapshots the open orders of this tranche and locks it until
    /// epochUpdate.
    /// @return totalSupplyCurrency_ Total open supply orders, in currency.
    /// @return totalRedeemToken_ Total open redeem orders, in tranche tokens.
    function closeEpoch() public auth returns (uint256 totalSupplyCurrency_, uint256 totalRedeemToken_) {
        if (waitingForUpdate) revert AlreadyClosed();
        waitingForUpdate = true;
        return (totalSupply, totalRedeem);
    }

    // step 3, update. Settle the epoch once, in total.

    /// @notice Records what the coordinator decided to fill and settles it in total.
    /// @param supplyFulfillment_ Share of the supply orders filled, in 27 decimal
    /// fixed point.
    /// @param redeemFulfillment_ Share of the redeem orders filled, in 27 decimal
    /// fixed point.
    /// @param tokenPrice_ Price used for the conversions of this epoch, in 27 decimal
    /// fixed point.
    function epochUpdate(
        uint256 epochID,
        uint256 supplyFulfillment_,
        uint256 redeemFulfillment_,
        uint256 tokenPrice_,
        uint256 epochSupplyOrderCurrency,
        uint256 epochRedeemOrderCurrency
    ) public auth {
        if (!waitingForUpdate) revert NotWaitingForUpdate();
        waitingForUpdate = false;

        epochs[epochID].supplyFulfillment.value = supplyFulfillment_;
        epochs[epochID].redeemFulfillment.value = redeemFulfillment_;
        epochs[epochID].tokenPrice.value = tokenPrice_;

        // currency is converted to a token amount at the current token price
        uint256 redeemInToken = 0;
        uint256 supplyInToken = 0;
        if (tokenPrice_ > 0) {
            supplyInToken = rdiv(epochSupplyOrderCurrency, tokenPrice_);
            redeemInToken = safeDiv(safeMul(epochRedeemOrderCurrency, ONE), tokenPrice_);
        }

        // net the token side and mint or burn only the difference
        adjustTokenBalance(epochID, supplyInToken, redeemInToken);
        // net the currency side and settle only the difference against the reserve
        adjustCurrencyBalance(epochID, epochSupplyOrderCurrency, epochRedeemOrderCurrency);

        // whatever was not filled stays as an open order
        totalSupply = safeAdd(
            safeTotalSub(totalSupply, epochSupplyOrderCurrency),
            rmul(epochSupplyOrderCurrency, safeSub(ONE, epochs[epochID].supplyFulfillment.value))
        );
        totalRedeem = safeAdd(
            safeTotalSub(totalRedeem, redeemInToken),
            rmul(redeemInToken, safeSub(ONE, epochs[epochID].redeemFulfillment.value))
        );

        emit EpochUpdate(epochID, supplyFulfillment_, redeemFulfillment_, tokenPrice_);
    }

    /// @dev Nets the minting of the epoch against its burning and moves only the
    /// difference. Minting the full supply and burning the full redemption separately
    /// would end in the same place, cost more gas, and show a misleading total supply
    /// to anyone reading it during the transaction.
    function adjustTokenBalance(uint256 epochID, uint256 epochSupplyToken, uint256 epochRedeemToken) internal {
        uint256 mintAmount = 0;
        if (epochs[epochID].tokenPrice.value > 0) {
            mintAmount = rmul(epochSupplyToken, epochs[epochID].supplyFulfillment.value);
        }
        uint256 burnAmount = rmul(epochRedeemToken, epochs[epochID].redeemFulfillment.value);

        if (burnAmount > mintAmount) {
            safeBurn(safeSub(burnAmount, mintAmount));
            return;
        }
        uint256 diff = safeSub(mintAmount, burnAmount);
        if (diff > 0) {
            token.mint(self, diff);
        }
    }

    /// @dev The same netting for currency, settled against the reserve rather than
    /// the token.
    function adjustCurrencyBalance(uint256 epochID, uint256 epochSupply, uint256 epochRedeem) internal {
        uint256 currencySupplied = rmul(epochSupply, epochs[epochID].supplyFulfillment.value);
        uint256 currencyRequired = rmul(epochRedeem, epochs[epochID].redeemFulfillment.value);

        if (currencySupplied > currencyRequired) {
            uint256 surplus = safeSub(currencySupplied, currencyRequired);
            currency.approve(address(reserve), surplus);
            reserve.deposit(surplus);
            return;
        }
        uint256 shortfall = safeSub(currencyRequired, currencySupplied);
        if (shortfall > 0) {
            safePayout(shortfall);
        }
    }

    // step 4, release. Each user pulls their own share. Allocating value to tranches
    // happens in the coordinator, between the escrow step and this one.

    /// @notice What a user is owed across every epoch executed since they ordered.
    /// @param usr Address to calculate for.
    /// @param endEpoch Last epoch to include.
    /// @return payoutCurrencyAmount Currency owed.
    /// @return payoutTokenAmount Tranche tokens owed.
    /// @return remainingSupplyCurrency Supply order still open.
    /// @return remainingRedeemToken Redeem order still open.
    /// @dev A read only version of the same walk that deservedRelease performs, so a
    /// caller can preview a settlement before paying gas for it.
    function calculateDeservedRelease(address usr, uint256 endEpoch)
        public
        view
        returns (
            uint256 payoutCurrencyAmount,
            uint256 payoutTokenAmount,
            uint256 remainingSupplyCurrency,
            uint256 remainingRedeemToken
        )
    {
        uint256 epochId = users[usr].orderedInEpoch;
        uint256 lastEpochExecuted_ = epochPlacement.lastEpochExecuted();
        remainingSupplyCurrency = users[usr].supplyCurrencyAmount;
        remainingRedeemToken = users[usr].redeemTokenAmount;
        uint256 amount = 0;

        if (endEpoch > lastEpochExecuted_) {
            endEpoch = lastEpochExecuted_;
        }

        while (epochId <= endEpoch && (remainingSupplyCurrency != 0 || remainingRedeemToken != 0)) {
            if (remainingSupplyCurrency != 0) {
                // the payout includes orders that are still open
                amount = rmul(remainingSupplyCurrency, epochs[epochId].supplyFulfillment.value);
                if (amount != 0) {
                    payoutTokenAmount =
                        safeAdd(payoutTokenAmount, safeDiv(safeMul(amount, ONE), epochs[epochId].tokenPrice.value));
                    remainingSupplyCurrency = safeSub(remainingSupplyCurrency, amount);
                }
            }
            if (remainingRedeemToken != 0) {
                amount = rmul(remainingRedeemToken, epochs[epochId].redeemFulfillment.value);
                if (amount != 0) {
                    payoutCurrencyAmount = safeAdd(payoutCurrencyAmount, rmul(amount, epochs[epochId].tokenPrice.value));
                    remainingRedeemToken = safeSub(remainingRedeemToken, amount);
                }
            }
            epochId = safeAdd(epochId, 1);
        }

        return (payoutCurrencyAmount, payoutTokenAmount, remainingSupplyCurrency, remainingRedeemToken);
    }

    /// @notice Settles everything a user is owed up to the last executed epoch.
    /// @param usr Address to settle for.
    function deservedRelease(address usr)
        public
        auth
        returns (
            uint256 payoutCurrencyAmount,
            uint256 payoutTokenAmount,
            uint256 remainingSupplyCurrency,
            uint256 remainingRedeemToken
        )
    {
        return deservedRelease(usr, epochPlacement.lastEpochExecuted());
    }

    /// @notice Settles what a user is owed up to a given epoch.
    /// @param usr Address to settle for.
    /// @param endEpoch Last epoch to settle.
    /// @dev Bounded, so a user whose order has sat through many epochs can settle in
    /// several transactions rather than one that runs out of gas. The stored cursor
    /// moves past the epoch just settled, so settling in parts can be continued and
    /// never pays twice.
    function deservedRelease(address usr, uint256 endEpoch)
        public
        auth
        returns (
            uint256 payoutCurrencyAmount,
            uint256 payoutTokenAmount,
            uint256 remainingSupplyCurrency,
            uint256 remainingRedeemToken
        )
    {
        uint256 lastEpochExecuted_ = epochPlacement.lastEpochExecuted();
        if (endEpoch > lastEpochExecuted_) {
            endEpoch = lastEpochExecuted_;
        }

        (payoutCurrencyAmount, payoutTokenAmount, remainingSupplyCurrency, remainingRedeemToken) =
            calculateDeservedRelease(usr, endEpoch);

        users[usr].supplyCurrencyAmount = remainingSupplyCurrency;
        users[usr].redeemTokenAmount = remainingRedeemToken;
        users[usr].orderedInEpoch = safeAdd(endEpoch, 1);

        if (payoutCurrencyAmount > 0) {
            _safeTransfer(currency, usr, payoutCurrencyAmount);
        }
        if (payoutTokenAmount > 0) {
            _safeTransfer(token, usr, payoutTokenAmount);
        }

        emit Release(usr, payoutCurrencyAmount, payoutTokenAmount);
        return (payoutCurrencyAmount, payoutTokenAmount, remainingSupplyCurrency, remainingRedeemToken);
    }

    // helpers

    /// @dev The three safe helpers below clamp to what is available rather than
    /// reverting, and that behaviour is confined to this contract. Epoch arithmetic
    /// gathers rounding dust across the fulfilment shares, and reverting on a shortfall
    /// of one wei would block the pool for every user at once. The reserve does not
    /// clamp, so a real shortfall still shows up and only dust is absorbed here.
    function _safeTransfer(ERC20Like erc20, address usr, uint256 amount) internal {
        uint256 max = erc20.balanceOf(self);
        if (amount > max) {
            amount = max;
        }
        if (!erc20.transfer(usr, amount)) revert TransferFailed();
    }

    function safeBurn(uint256 tokenAmount) internal {
        uint256 max = token.balanceOf(self);
        if (tokenAmount > max) {
            tokenAmount = max;
        }
        token.burn(self, tokenAmount);
    }

    function safePayout(uint256 currencyAmount) internal {
        uint256 max = reserve.totalBalance();
        if (currencyAmount > max) {
            currencyAmount = max;
        }
        reserve.payout(currencyAmount);
    }
}
