// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "../math/math.sol";
import "./sacred.sol";
import "../fixed_point.sol";
import "../auth/auth.sol";
import "../math/interest.sol";
import "./interfaces.sol";
import "./ICascade.sol";

/// @title assessor
/// @author adiii.eth
/// @notice Valuation and allocation for the pool. This is the only contract that knows
/// the pool has more than one tranche and what the ordering between them means. It
/// holds no currency and no tokens, so it can work out that the senior tranche is owed
/// a hundred units and has no way to move them. A mistake here is a mispricing rather
/// than a theft.
///
/// @notice Note on status. Not audited. Written for study, and under development.
///
/// @dev This contract implements ICascade. The Tinlake assessor answers what each
/// tranche is worth. trancher also answers who gets paid and in what order given an
/// amount of cash, which is the question a waterfall exists to answer.
///
/// @dev The senior claim is carried as two numbers. seniorDebt_ is the part financing
/// the borrower side and it earns the senior interest rate continuously. seniorBalance_
/// is senior capital sitting idle in the reserve and it earns nothing. Their sum is the
/// senior asset value. The split is recomputed against the new senior ratio each epoch,
/// which is what fillSeniorDebt does. Held as one number instead, the pool would pay
/// senior interest out of junior equity on cash that is financing nothing.
contract assessor is Math, sacred, Auth, Interest, ICascade {
    /// @notice Current share of total assets claimed by the senior tranche, in 27
    /// decimal fixed point.
    Fixed27 public seniorRatio;

    /// @notice Bounds the senior ratio has to stay inside for an epoch to execute.
    /// @dev These are the risk settings of the pool and nothing else in this
    /// repository depends on their values. A minimum keeps junior capital present, so
    /// the senior tranche cannot grow past its cushion. A maximum stops the junior
    /// tranche levering the pool without limit. The coordinator reads them through
    /// seniorRatioBounds and refuses any allocation that leaves the range.
    Fixed27 public maxSeniorRatio;
    Fixed27 public minSeniorRatio;

    /// @notice Senior rate per second, compounding continuously, in 27 decimal fixed
    /// point. A value of one means a rate of zero.
    Fixed27 public seniorInterestRate;

    uint256 public lastUpdateSeniorInterest;

    /// @notice Ceiling on idle currency, so the pool does not sit on supply that is
    /// not deployed.
    uint256 public maxReserve;

    /// @dev A lending adapter is deliberately absent and can be added later.

    TrancheLike public seniorTranche;
    TrancheLike public juniorTranche;
    NavLike public navFeed;
    IdleLike public reserve;

    /// @notice Seniority indices. 0 is the most senior, as ICascade requires.
    uint256 public constant SENIOR = 0;
    uint256 public constant JUNIOR = 1;
    uint256 public constant TRANCHE_COUNT = 2;

    // tolerance for rounding dust in balances
    uint256 public constant supplyTolerence = 5;

    event File(bytes32 indexed what, uint256 value);
    event SeniorAssetChanged(uint256 seniorRatio, uint256 seniorDebt, uint256 seniorBalance);

    error UnknownParameter();
    error NoSuchTranche();

    constructor() {
        seniorInterestRate.value = ONE;
        lastUpdateSeniorInterest = block.timestamp;
        seniorRatio.value = 0;
    }

    function file(bytes32 what, uint256 value) public auth {
        if (what == "seniorInterestRate") {
            dripSeniorDebt();
            seniorInterestRate.value = value;
        } else if (what == "maxReserve") {
            maxReserve = value;
        } else if (what == "minSeniorRatio") {
            minSeniorRatio.value = value;
        } else if (what == "maxSeniorRatio") {
            maxSeniorRatio.value = value;
        } else {
            revert UnknownParameter();
        }
        emit File(what, value);
    }

    function depend(bytes32 contractName, address addr) public auth {
        if (contractName == "navFeed") {
            navFeed = NavLike(addr);
        } else if (contractName == "reserve") {
            reserve = IdleLike(addr);
        } else if (contractName == "seniorTranche") {
            seniorTranche = TrancheLike(addr);
        } else if (contractName == "juniorTranche") {
            juniorTranche = TrancheLike(addr);
        } else {
            revert UnknownParameter();
        }
    }

    // ICascade

    /// @inheritdoc ICascade
    function getNav() public view override returns (uint256) {
        return navFeed.currentNAV();
    }

    /// @inheritdoc ICascade
    function getTrancheAssets(uint256 trancheId) public view override returns (uint256) {
        uint256 nav_ = getNav();
        uint256 reserve_ = reserve.totalBalance();
        uint256 assets = calcAssets(nav_, reserve_);
        uint256 seniorAsset = calcExpectedSeniorAssets(seniorDebt(), seniorBalance_);
        if (seniorAsset > assets) seniorAsset = assets;

        if (trancheId == SENIOR) return seniorAsset;
        if (trancheId == JUNIOR) return safeSub(assets, seniorAsset);
        // revert rather than return zero, because a zero here would read as a tranche
        // that has been wiped out. See the note on ICascade.getTrancheAssets.
        revert NoSuchTranche();
    }

    /// @inheritdoc ICascade
    /// @dev The waterfall itself. The senior tranche is filled to its entitlement
    /// before the junior tranche sees anything, which is rule I1, and the two returned
    /// amounts add up to the input by construction, which is rule I3. With two tranches
    /// this is a minimum and a subtraction. With more it is the same loop, which is why
    /// the return type is an array rather than a pair. Extending the tranche count
    /// changes this function and nothing else in the contract.
    function trancher(uint256 assets) public override returns (uint256[] memory perTrancheDistribution) {
        // accrue first, because the senior entitlement earns interest and filling a
        // stale entitlement overstates the junior residual
        dripSeniorDebt();

        perTrancheDistribution = new uint256[](TRANCHE_COUNT);
        uint256 seniorEntitlement = calcExpectedSeniorAssets(seniorDebt_, seniorBalance_);

        uint256 toSenior = assets < seniorEntitlement ? assets : seniorEntitlement;
        perTrancheDistribution[SENIOR] = toSenior;
        perTrancheDistribution[JUNIOR] = safeSub(assets, toSenior);
        return perTrancheDistribution;
    }

    /// @inheritdoc ICascade
    function fillSeniorDebt(uint256 seniorAsset_) public override returns (uint256) {
        dripSeniorDebt();
        reBalance(seniorAsset_, seniorRatio.value);
        return seniorDebt_;
    }

    // senior accrual

    /// @notice Senior debt including interest accrued up to this block.
    /// @return The accrued senior debt.
    /// @dev A view, so it never writes. dripSeniorDebt is the version that does.
    /// Reading and settling are separate so that any number of callers can price the
    /// pool without changing it.
    function seniorDebt() public view returns (uint256) {
        if (block.timestamp >= lastUpdateSeniorInterest) {
            return chargeInterest(seniorDebt_, seniorInterestRate.value, lastUpdateSeniorInterest);
        }
        return seniorDebt_;
    }

    function seniorBalance() public view returns (uint256) {
        return seniorBalance_;
    }

    /// @notice Settles accrued senior interest into storage.
    /// @return The senior debt after settlement.
    /// @dev The guard compares the new debt against the stored debt rather than
    /// comparing timestamps. Interest only rises, so anything that did not raise the
    /// debt does nothing and has to leave the timestamp alone. Moving the timestamp
    /// forward without booking the interest discards that period of accrual for good.
    function dripSeniorDebt() public returns (uint256) {
        uint256 newSeniorDebt = seniorDebt();
        if (newSeniorDebt > seniorDebt_) {
            seniorDebt_ = newSeniorDebt;
            lastUpdateSeniorInterest = block.timestamp;
        }
        return seniorDebt_;
    }

    // rebalancing

    /// @notice Recomputes the split between senior debt and senior balance at the
    /// current ratio.
    function trancheRebalance() public {
        reBalance(calcExpectedSeniorAssets(dripSeniorDebt(), seniorBalance_), seniorRatio.value);
    }

    /// @dev Splits the senior asset into the part that earns interest, which is the
    /// share of the net asset value the senior ratio entitles it to, and the idle
    /// remainder. If the entitled debt is larger than the whole senior asset then the
    /// pool has shrunk below the senior claim, so debt takes everything and the balance
    /// is zero.
    function reBalance(uint256 seniorAsset_, uint256 seniorRatio_) internal {
        uint256 nav_ = getNav();
        seniorDebt_ = rmul(nav_, seniorRatio_);
        if (seniorDebt_ > seniorAsset_) {
            seniorDebt_ = seniorAsset_;
            seniorBalance_ = 0;
        } else {
            seniorBalance_ = safeSub(seniorAsset_, seniorDebt_);
        }
        emit SeniorAssetChanged(seniorRatio_, seniorDebt_, seniorBalance_);
    }

    /// @notice Applies the senior supply and redemption of an executed epoch, then
    /// rebalances.
    /// @param seniorRatio_ New senior ratio, in 27 decimal fixed point.
    /// @param seniorSupply Senior supply settled this epoch, in currency.
    /// @param seniorRedeem Senior redemption settled this epoch, in currency.
    /// @dev The single write the coordinator makes into valuation, called once at the
    /// end of a successful epoch and from nowhere else.
    function changeSeniorAsset(uint256 seniorRatio_, uint256 seniorSupply, uint256 seniorRedeem) external auth {
        dripSeniorDebt();
        uint256 seniorAsset = calcExpectedSeniorAsset(seniorRedeem, seniorSupply, seniorBalance_, seniorDebt_);
        reBalance(seniorAsset, seniorRatio_);
        seniorRatio.value = seniorRatio_;
    }

    // pricing

    function seniorRatioBounds() public view returns (Fixed27 memory minRatio, Fixed27 memory maxRatio) {
        return (minSeniorRatio, maxSeniorRatio);
    }

    function calcUpdateNAV() external returns (uint256) {
        return navFeed.calcUpdateNAV();
    }

    /// @notice Senior asset value per senior token, in 27 decimal fixed point.
    /// @param nav_ Borrower side net asset value.
    /// @param reserve_ Currency in the reserve.
    /// @return The senior token price.
    /// @dev Capped at total assets, so the senior price cannot exceed what the pool
    /// holds. This is rule I2 expressed as a price.
    function calcSeniorTokenPrice(uint256 nav_, uint256 reserve_) public view returns (Fixed27 memory) {
        if ((nav_ == 0 && reserve_ == 0) || seniorTranche.tokenSupply() == 0) {
            // no pool or no holders yet, so the price starts at par
            return Fixed27(ONE);
        }
        uint256 totalAssets = calcAssets(nav_, reserve_);
        uint256 seniorAssetValue = calcExpectedSeniorAssets(seniorDebt(), seniorBalance_);
        if (totalAssets < seniorAssetValue) {
            seniorAssetValue = totalAssets;
        }
        return Fixed27(rdiv(seniorAssetValue, seniorTranche.tokenSupply()));
    }

    /// @notice Residual value per junior token, in 27 decimal fixed point.
    /// @param nav_ Borrower side net asset value.
    /// @param reserve_ Currency in the reserve.
    /// @return The junior token price.
    /// @dev Returns zero when the senior claim meets or exceeds total assets. That zero
    /// is the signal the coordinator watches for. The junior tranche has absorbed
    /// everything it can, so the pool stops accepting new supply and starts closing.
    function calcJuniorTokenPrice(uint256 nav_, uint256 reserve_) public view returns (Fixed27 memory) {
        if ((nav_ == 0 && reserve_ == 0) || juniorTranche.tokenSupply() == 0) {
            return Fixed27(ONE);
        }
        uint256 totalAssets = calcAssets(nav_, reserve_);
        uint256 seniorAssetValue = calcExpectedSeniorAssets(seniorDebt(), seniorBalance_);
        if (totalAssets < seniorAssetValue) {
            return Fixed27(0);
        }
        return Fixed27(rdiv(safeSub(totalAssets, seniorAssetValue), juniorTranche.tokenSupply()));
    }

    function calcTokenPrices(uint256 nav_, uint256 reserve_)
        public
        view
        returns (Fixed27 memory juniorPrice, Fixed27 memory seniorPrice)
    {
        return (calcJuniorTokenPrice(nav_, reserve_), calcSeniorTokenPrice(nav_, reserve_));
    }
}
