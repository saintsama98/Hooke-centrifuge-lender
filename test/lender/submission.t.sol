// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../script/deployer.sol";
import "../mock/currency.sol";
import "../mock/navfeed.sol";

/// @notice The second exit from `closeEpoch`: what happens when the orders on the
///         table cannot all be filled without breaching the pool's risk band.
///
/// @dev    THIS IS THE PATH THAT DISTINGUISHES A COORDINATOR FROM AN EXECUTOR. If a
///         pool can only ever execute epochs where everyone gets everything, it does
///         not need a coordinator at all, it needs a settlement function. The whole
///         apparatus below exists for the epochs where somebody has to be turned away.
///
/// @dev    The scenario: a hard 80% ceiling on the senior ratio, and orders that would
///         put the pool at 91% senior. No allocation filling every order is legal, so
///         the epoch cannot execute on close. It opens for submissions instead, ranks
///         what it receives, and settles the winner after a challenge window.
contract SubmissionPeriodTest is Test {
    uint256 constant RAY = 1e27;

    SimpleToken currency;
    SimpleToken seniorToken;
    SimpleToken juniorToken;
    SimpleNAVFeed navFeed;
    LenderDeployer d;

    EpochCoordinator coordinator;
    Operator seniorOp;
    Operator juniorOp;
    Tranche seniorTranche;
    Tranche juniorTranche;
    assessor assessor_;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xCEEDED);

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
            maxSeniorRatio_: (RAY * 8) / 10, // senior may not exceed 80% of the pool
            maxReserve_: 1_000_000 ether,
            seniorRate_: RAY
        });

        coordinator = d.coordinator();
        seniorOp = d.seniorOperator();
        juniorOp = d.juniorOperator();
        seniorTranche = d.seniorTranche();
        juniorTranche = d.juniorTranche();
        assessor_ = d.assessor_();

        currency.mint(alice, 1000 ether);
        currency.mint(bob, 1000 ether);
        vm.prank(alice);
        currency.approve(address(seniorTranche), type(uint256).max);
        vm.prank(bob);
        currency.approve(address(juniorTranche), type(uint256).max);
    }

    /// @notice Orders that breach the senior ceiling open a submission period instead
    ///         of executing, and a compliant partial allocation settles them.
    function test_submissionPeriodResolves() public {
        // 100 senior against 10 junior would leave the pool 91% senior, over the 80% cap
        vm.prank(alice);
        seniorOp.supplyOrder(100 ether);
        vm.prank(bob);
        juniorOp.supplyOrder(10 ether);

        vm.warp(block.timestamp + 1 days + 1);
        coordinator.closeEpoch();

        // the epoch did NOT execute
        assertTrue(coordinator.submissionPeriod(), "submission period must open");
        assertEq(coordinator.lastEpochExecuted(), 0, "nothing executed on close");
        assertEq(coordinator.minChallengePeriodEnd(), 0, "no challenge window until a valid solution");

        // filling everything is still illegal, and saying so costs nothing
        assertEq(
            coordinator.validate(0, 0, 100 ether, 10 ether),
            coordinator.ERR_MAX_SENIOR_RATIO(),
            "full fill breaches the senior ceiling"
        );

        // 40 senior against 10 junior is exactly 80%: the largest legal allocation.
        // Anyone may propose it. The proposer needs no capital and no permission.
        vm.prank(keeper);
        int256 result = coordinator.submitSolution(0, 0, 10 ether, 40 ether);
        assertEq(result, coordinator.SUCCESS(), "compliant allocation accepted");
        assertGt(coordinator.minChallengePeriodEnd(), 0, "challenge window opened");

        // it cannot be settled until the window closes
        vm.expectRevert(EpochCoordinator.ChallengePeriodNotEnded.selector);
        coordinator.executeEpoch();

        vm.warp(block.timestamp + 1 hours + 1);
        coordinator.executeEpoch();

        assertEq(coordinator.lastEpochExecuted(), 1, "winning allocation settled");
        assertFalse(coordinator.submissionPeriod(), "back to open");
        assertEq(coordinator.minChallengePeriodEnd(), 0, "challenge state reset");

        // alice was filled 40 of 100; the unfilled 60 stays as a live order
        vm.prank(alice);
        seniorOp.deservedRelease();
        assertEq(seniorToken.balanceOf(alice), 40 ether, "partial fill at the ceiling");

        (, uint256 stillOrdered,) = seniorTranche.users(alice);
        assertEq(stillOrdered, 60 ether, "unfilled remainder carries into the next epoch");

        // the pool landed exactly on its ceiling
        assertEq(assessor_.seniorRatio(), (RAY * 8) / 10, "senior ratio at the 80% cap");
    }

    /// @notice A better-scoring allocation displaces a worse one; a worse one is rejected.
    /// @dev    Ranking is by `scoreSolution`, which is CALIBRATION and `virtual`. The
    ///         default weights prefer larger fills, so 40 senior beats 20 senior. A fork
    ///         that overrides `scoreSolution` changes who wins here and nothing else.
    function test_bestSubmissionWins() public {
        vm.prank(alice);
        seniorOp.supplyOrder(100 ether);
        vm.prank(bob);
        juniorOp.supplyOrder(10 ether);

        vm.warp(block.timestamp + 1 days + 1);
        coordinator.closeEpoch();

        // a legal but small allocation lands first
        vm.prank(keeper);
        assertEq(coordinator.submitSolution(0, 0, 10 ether, 20 ether), coordinator.SUCCESS());
        uint256 firstScore = coordinator.bestSubScore();

        // a legal and larger one displaces it
        vm.prank(alice);
        assertEq(coordinator.submitSolution(0, 0, 10 ether, 40 ether), coordinator.SUCCESS());
        assertGt(coordinator.bestSubScore(), firstScore, "larger fill scores higher");

        // going back to the small one is refused rather than accepted and ignored
        vm.prank(keeper);
        assertEq(
            coordinator.submitSolution(0, 0, 10 ether, 20 ether),
            coordinator.ERR_NOT_NEW_BEST(),
            "a worse allocation must be rejected"
        );

        vm.warp(block.timestamp + 1 hours + 1);
        coordinator.executeEpoch();

        vm.prank(alice);
        seniorOp.deservedRelease();
        assertEq(seniorToken.balanceOf(alice), 40 ether, "the best submission is what settled");
    }

    /// @notice An allocation paying out more than the pool holds is refused outright.
    /// @dev    Base constraints are absolute: unlike the ratio band they are never
    ///         relaxed, at any score, in any pool state.
    function test_baseConstraintsAreAbsolute() public {
        vm.prank(alice);
        seniorOp.supplyOrder(100 ether);
        vm.prank(bob);
        juniorOp.supplyOrder(10 ether);

        vm.warp(block.timestamp + 1 days + 1);
        coordinator.closeEpoch();

        // filling more than was ordered
        vm.prank(keeper);
        assertEq(
            coordinator.submitSolution(0, 0, 10 ether, 200 ether),
            coordinator.ERR_MAX_ORDER(),
            "cannot fill beyond the order placed"
        );
        assertEq(coordinator.minChallengePeriodEnd(), 0, "an invalid submission opens no window");
    }

    /// @notice Submissions are only accepted while a period is open.
    function test_cannotSubmitOutsidePeriod() public {
        vm.expectRevert(EpochCoordinator.SubmissionPeriodNotActive.selector);
        coordinator.submitSolution(0, 0, 0, 0);
    }
}
