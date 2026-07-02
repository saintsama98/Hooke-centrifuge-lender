//SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "../math/math.sol";
import "../fixed_point.sol";
import "../auth/auth.sol";

///@notice this is the origin tranche making contract motivated from tinlake completely, honestly more abstracted that it is
// originally intended.

interface ERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transferFrom(address, address, uint256) external returns (bool);
    function mint(address, uint256) external;
    function burn(address, uint256) external;
    function totalSupply() external view returns (uint256);
    function approve(address usr, uint256 amount) external;
}

interface IdleLike {
    function totalBalance() public view returns (uint256);
    function payout(uint256 currencyAmount) external;
    function deposit(uint256 currencyAmount) external;
}

///@notice we will be depending on coordinator contract for epoch placement and update, this is a minimal interface to avoid complexity and surface.
// this pattern of cross dependency is what makes tinlake interesting especially if dev wants to interprete tranching fundamentals

///@dev different phases handled by coordinator with help of epoch handling and income processing which is done in this very
//tranche contract

interface EpochPlacementLike {
    function currentEpoch() external view returns (uint256);
    function lastEpochExecuted() external view returns (uint256);
}

contract Tranche is Math, Auth, FixedPoint {
    ///@notice tranche contract will be a dependecy for contracts like operator, coordinator eventually
    mapping(uint256 => Epoch) public epochs;

    struct Epoch {
        ///@notice supplyFulfillment is the percentage of the supply that is fulfilled for the epoch
        //same goes for redeemFulfillment

        //this is done because the supply is 100% but coordinator can only keep it less that 100% due
        //to allocations, also cannot invest 100% due to caps and constraints from base securitization that are implemented
        //here itself

        uint256 supplyFulfillment;
        uint256 redeemFulfillment;
        uint256 tokenPrice;
    }

    struct UserOrder {
        uint256 orderedInEpoch;
        uint256 supplyCurrencyAmount;
        uint256 redeemTokenAmount;
    }

    uint256 totalSupply;
    uint256 totalRedeem;

    mapping(address => UserOrder) public users;

    ERC20Like public currency;
    ERC20Like public token;
    ReserveLike public reserve;
    EpochPlacementLike public epochPlacement;

    modifier orderAllowed(address user) {
        //supply/redeem whitelisting based only
        require(
            users[user].suppluCurrentAmount == 0 || users[user].redeemCurrentAmount == 0
                || users[user].orderedInEpoch == epochTicker.currentEpoch(),
            "this release required first"
        );
        _;
    }

    ///@param  currency_ address of the currency token/underlying asset
    ///@param token_ address of the token/to-be-tranche token
    constructor(address currency_, address token_) public {
        wards[msg.sender] = 1;
        token = ERC20Like(token_);
        currency = ERC20Like(currency_);
        self = address(this);
    }

    function depend() public auth {}

    //snapshots and simple escrowing to record the epoch
    //this snapshot is divided in two parts, one for supply and other for redeem as both are
    //obvious outcomes from investing/lending side

    function supplyOrder(address user, uint256 newSupplyAmount) public auth orderAllowed(user) {
        //initially we need to put user in currennt epoch for accurate snapshot
        users[user].orderedInEpoch = epochPlacement.currentEpoch();
        //the underlying asset is what lender will soft allocate
        uint256 currentSupplyAmount = users[user].supplyCurrencyAmount;

        users[user].supplyCurrencyAmount = newSupplyAmount;

        totalSupply = safeAdd(safeTotalSub(totalSupply, currentSupplyAmount), newSupplyAmount);

        if (newSupplyAmount > currentSupplyAmount) {
            uint256 delta = safeSub(newSupplyAmount, currentSupplyAmount);
            require(currency.transferFrom(user, self, delta), "currency-transfer-failed");
            return;
        }
        delta = safeSub(currentSupplyAmount, newSupplyAmount);
        if (delta > 0) {
            _safeTransfer(currency, user, delta);
        }
    }

    function redeemOrder(address user, uint256 newRedeemAmount) public auth orderAllowed(user) {
        users[usr].orderedInEpoch = epochTicker.currentEpoch();

        uint256 currentRedeemAmount = users[usr].redeemTokenAmount;
        users[usr].redeemTokenAmount = newRedeemAmount;
        totalRedeem = safeAdd(safeTotalSub(totalRedeem, currentRedeemAmount), newRedeemAmount);

        if (newRedeemAmount > currentRedeemAmount) {
            uint256 delta = safeSub(newRedeemAmount, currentRedeemAmount);
            require(token.transferFrom(usr, self, delta), "token-transfer-failed");
            return;
        }

        uint256 delta = safeSub(currentRedeemAmount, newRedeemAmount);
        if (delta > 0) {
            _safeTransfer(token, usr, delta);
        }
    }

    //this stage is releasing(lenders currency with all profits) back the assets to investor or lender at this surface (since tranche is an important
    //surface for lender to be able to invest and redeem)

    ///@notice there lies an intermediate surface between escrowing and releasing which is allocating assets to tranches by coordinator
    //but at this surface it is probably more clean to keep this surface for snapshotting and release from lender perspective

    function calculateDeservedRelease(address user, uint256 endEpoch)
        public
        view
        returns (
            uint256 payouCurrencyAmount,
            uint256 payouTokenAmount,
            uint256 remainingSupplyCurrency,
            uint256 remainingRedeemToken
        )
    {
        uint256 epochId = users[user].orderedInEpoch;
        uint256 lastEpochExecuted = epochPlacement.lastEpochExecuted();
        uint256 remainingSupplyCurrency = users[user].supplyCurrencyAmount;
        uint256 remainingRedeemToken = users[user].redeemTokenAmount;
        uint256 amount = 0;

        if (endEpoch > lastEpochExecuted) {
            endEpoch = lastEpochExecuted;
        }

        while (epochId <= endEpoch && (remainingSupplyCurrency != 0 || remainingRedeemToken != 0)) {
            if (remainingSupplyCurrency != 0) {
                //payout should be including remaining or unprocessed orders
                amount = rmul(remainingSupplyCurrency, epochs[epochId].supplyFulfillment);
                if (amount != 0) {
                    payoutTokenAmount =
                        safeAdd(payoutTokenAmount, safeDiv(safeMul(amount, ONE), epochs[epochId].tokenPrice));
                    remainingSupplyCurrency = safeSub(remainingSupplyCurrency, amount);
                }
            }
            if (remainingRedeemToken != 0) {
                amount = rmul(remainingRedeemToken, epochs[epochId].redeemFulfillment);
                if (amount != 0) {
                    payoutCurrencyAmount = safeAdd(payoutCurrencyAmount, rmul(amount, epochs[epochId].tokenPrice));
                    remainingRedeemToken = safeSub(remainingRedeemToken, amount);
                }
            }
            epochId = safeAdd(epochId, 1);
        }

        return (payoutCurrencyAmount, payoutTokenAmount, remainingSupplyCurrency, remainingRedeemToken);
    }

    function deservedRelease()
        public
        auth
        returns (
            uint256 payoutCurrencyAmount,
            uint256 payoutTokenAmount,
            uint256 remainingSupplyCurrency,
            uint256 remainingRedeemToken
        )
    {
        (
            payoutCurrencyAmount, payoutTokenAmount, remainingSupplyCurrency, remainingRedeemToken
        ) = calculateDeservedRelease(user, endEpoch);
        users[user].supplyCurrencyAmount = remainingSupplyCurrency;
        users[user].redeemTokenAmount = remainingRedeemToken;
        users[user].orderedInEpoch = safeAdd(endEpoch, 1);

        if (payoutCurrencyAmount > 0) {
            _safeTransfer(currency, user, payoutCurrencyAmount);
        }
        if (payoutTokenAmount > 0) {
            _safeTransfer(token, user, payoutTokenAmount);
        }
        return (payoutCurrencyAmount, payoutTokenAmount, remainingSupplyCurrency, remainingRedeemToken);
    }

    //=========helpers=========
    function _safeTransfer(ERC20Like token, address user, uint256) internal {}
}
