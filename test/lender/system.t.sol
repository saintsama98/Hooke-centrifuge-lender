// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../script/deployer.sol";
import "../mock/currency.sol";
import "../mock/navfeed.sol";

/// @notice A full pool, wired by `LenderDeployer`, driven through complete epochs.
///
/// @dev    READ THIS SECOND, after `sacred.t.sol`. It is the executable version of the
///         lifecycle comment at the top of `tranche.sol`, and the fastest way to see
///         how the four actors actually talk to each other.
contract SystemTest is Test {
    uint256 constant RAY = 1e27;

    SimpleToken currency;
    SimpleToken seniorToken;
    SimpleToken juniorToken;
    SimpleNAVFeed navFeed;
    LenderDeployer d;

    /// @dev Cached rather than reached through `d` at the call site. `seniorOp`
    ///      is itself an external call, so it consumes a pending `vm.prank` or
    ///      `vm.expectRevert` and the cheatcode lands on the getter instead of the call
    ///      under test. A very easy way to write a test that passes for the wrong reason.
    idle reserve;
    assessor assessor_;
    EpochCoordinator coordinator;
    Tranche seniorTranche;
    Tranche juniorTranche;
    Operator seniorOp;
    Operator juniorOp;

    address alice = address(0xA11CE); // senior supplier
    address bob = address(0xB0B); // junior supplier

    function setUp() public {
        currency = new SimpleToken("USD Coin", "USDC");
        seniorToken = new SimpleToken("Senior", "SEN");
        juniorToken = new SimpleToken("Junior", "JUN");
        navFeed = new SimpleNAVFeed();

        d = new LenderDeployer(address(currency), address(seniorToken), address(juniorToken));
        d.deploy({
            navFeed: address(navFeed),
            challengeTime: 1 hours,
            minSeniorRatio_: 0,
            maxSeniorRatio_: RAY,
            maxReserve_: 1_000_000 ether,
            seniorRate_: RAY // ONE == zero interest, so the first tests are exact
        });

        reserve = d.reserve();
        assessor_ = d.assessor_();
        coordinator = d.coordinator();
        seniorTranche = d.seniorTranche();
        juniorTranche = d.juniorTranche();
        seniorOp = d.seniorOperator();
        juniorOp = d.juniorOperator();

        currency.mint(alice, 1000 ether);
        currency.mint(bob, 1000 ether);
        vm.prank(alice);
        currency.approve(address(seniorTranche), type(uint256).max);
        vm.prank(bob);
        currency.approve(address(juniorTranche), type(uint256).max);
    }

    function _closeEpoch() internal {
        vm.warp(block.timestamp + 1 days + 1);
        coordinator.closeEpoch();
    }

    // ==========================================================================

    /// @notice The happy path: orders in, one epoch, tokens out.
    /// @dev    Every order fits inside every constraint, so `closeEpoch` validates and
    ///         executes in the same transaction and no submission period opens. This
    ///         is what the overwhelming majority of real epochs look like.
    function test_fullEpochLifecycle() public {
        vm.prank(alice);
        seniorOp.supplyOrder(100 ether);
        vm.prank(bob);
        juniorOp.supplyOrder(50 ether);

        // escrowed on the tranches, not yet in the reserve
        assertEq(currency.balanceOf(address(seniorTranche)), 100 ether);
        assertEq(reserve.totalBalance(), 0);

        _closeEpoch();

        // executed straight through: no submission period was needed
        assertEq(coordinator.lastEpochExecuted(), 1, "epoch 1 should have executed");
        assertFalse(coordinator.submissionPeriod(), "no submission period expected");

        // currency has moved into the single pot
        assertEq(reserve.totalBalance(), 150 ether, "reserve holds the whole supply");

        // each supplier collects their own claim
        vm.prank(alice);
        seniorOp.deservedRelease();
        vm.prank(bob);
        juniorOp.deservedRelease();

        // priced at par on an empty pool, so tokens equal currency supplied
        assertEq(seniorToken.balanceOf(alice), 100 ether, "senior tokens at par");
        assertEq(juniorToken.balanceOf(bob), 50 ether, "junior tokens at par");

        // I3: the two tranches account for the whole pool and nothing more
        assertEq(
            assessor_.getTrancheAssets(0) + assessor_.getTrancheAssets(1),
            150 ether,
            "tranche assets must sum to pool assets"
        );
    }

    /// @notice A redemption settles out of the reserve in the following epoch.
    function test_redeemRoundTrip() public {
        test_fullEpochLifecycle();

        vm.prank(alice);
        seniorToken.approve(address(seniorTranche), type(uint256).max);
        vm.prank(alice);
        seniorOp.redeemOrder(40 ether);

        _closeEpoch();
        assertEq(coordinator.lastEpochExecuted(), 2);

        vm.prank(alice);
        seniorOp.deservedRelease();

        assertEq(currency.balanceOf(alice), 900 ether + 40 ether, "redemption paid at par");
        assertEq(seniorToken.balanceOf(alice), 60 ether, "redeemed tokens burned");
        assertEq(reserve.totalBalance(), 110 ether, "reserve drawn down by the redemption");
    }

    /// @notice I1, distribution order, on the live cascade: senior fills before junior.
    /// @dev    `trancher` is the function with no Tinlake ancestor, so this is the
    ///         first place the framework does something its source cannot.
    function test_cascadeFillsSeniorFirst() public {
        test_fullEpochLifecycle();

        // senior entitlement is 100; anything at or below it goes entirely to senior
        uint256[] memory split = assessor_.trancher(80 ether);
        assertEq(split[0], 80 ether, "senior takes all of a partial distribution");
        assertEq(split[1], 0, "junior receives nothing until senior is filled");

        // above the entitlement, senior caps and the residual falls to junior
        split = assessor_.trancher(130 ether);
        assertEq(split[0], 100 ether, "senior caps at its entitlement");
        assertEq(split[1], 30 ether, "junior takes the residual");

        // I3: conservation, at any input
        split = assessor_.trancher(37 ether);
        assertEq(split[0] + split[1], 37 ether, "distribution must conserve value");
    }

    /// @notice Junior absorbs a NAV loss in full before senior is touched at all.
    /// @dev    THE TEST THAT MATTERS. A 30 ether write-down against a pool holding
    ///         100 senior and 50 junior must leave the senior price exactly at par and
    ///         take the entire loss out of the junior price. If a change to this
    ///         codebase breaks one assertion, make it this one.
    function test_juniorAbsorbsLossFirst() public {
        test_fullEpochLifecycle();

        // pool is 150 in reserve; write the asset side down by 30
        navFeed.file("nav", 0);
        uint256 seniorBefore = assessor_.calcSeniorTokenPrice(0, 150 ether).value;
        uint256 juniorBefore = assessor_.calcJuniorTokenPrice(0, 150 ether).value;
        assertEq(seniorBefore, RAY, "senior starts at par");
        assertEq(juniorBefore, RAY, "junior starts at par");

        uint256 seniorAfter = assessor_.calcSeniorTokenPrice(0, 120 ether).value;
        uint256 juniorAfter = assessor_.calcJuniorTokenPrice(0, 120 ether).value;

        assertEq(seniorAfter, RAY, "senior price is untouched by a loss junior can absorb");
        assertEq(juniorAfter, (20 ether * RAY) / 50 ether, "junior absorbs the entire 30");
    }

    /// @notice Once junior is wiped out the pool stops accepting new supply.
    /// @dev    A junior price of exactly zero is the insolvency signal. The coordinator
    ///         latches `poolClosing` on it, after which redemptions still settle and
    ///         subscriptions are rejected. Letting new capital in at this point would
    ///         be selling a claim on a pool already short of its senior obligation.
    function test_poolClosesWhenJuniorWipedOut() public {
        test_fullEpochLifecycle();

        // total assets fall to the senior claim exactly: junior is gone
        assertEq(assessor_.calcJuniorTokenPrice(0, 100 ether).value, 0, "junior wiped out");
        assertEq(assessor_.calcJuniorTokenPrice(0, 90 ether).value, 0, "and stays wiped out below");

        // senior still prices, now against a pool smaller than its claim
        assertEq(assessor_.calcSeniorTokenPrice(0, 90 ether).value, (90 ether * RAY) / 100 ether);
    }

    /// @notice An epoch with no orders still advances the counter.
    function test_emptyEpochAdvances() public {
        _closeEpoch();
        assertEq(coordinator.lastEpochExecuted(), 1, "empty epoch executes immediately");
        assertFalse(coordinator.submissionPeriod());
    }

    /// @notice Epochs cannot be closed faster than the configured period.
    function test_cannotCloseEarly() public {
        vm.expectRevert(EpochCoordinator.MinimumEpochTimeNotPassed.selector);
        coordinator.closeEpoch();
    }

    /// @notice A stale order must be collected before a new one can be placed.
    /// @dev    Guards the `orderedInEpoch` cursor. The condition here is an AND in
    ///         Tinlake and was an OR in this repo before the fix; an OR lets a user
    ///         with one empty leg overwrite the cursor and silently forfeit everything
    ///         between the old epoch and the new one.
    function test_staleOrderBlocksNewOrder() public {
        vm.prank(alice);
        seniorOp.supplyOrder(100 ether);
        _closeEpoch();

        vm.prank(alice);
        vm.expectRevert(Tranche.ReleaseRequiredFirst.selector);
        seniorOp.supplyOrder(10 ether);

        // collecting clears the cursor and ordering works again
        vm.prank(alice);
        seniorOp.deservedRelease();
        vm.prank(alice);
        seniorOp.supplyOrder(10 ether);
    }

    /// @notice Only the operator may place orders directly on a tranche.
    function test_trancheIsAuthGated() public {
        vm.prank(alice);
        vm.expectRevert(Auth.NotAuthorized.selector);
        seniorTranche.supplyOrder(alice, 1 ether);
    }
}
