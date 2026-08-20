// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/lender/sacred.sol";

/// @dev `sacred` is abstract because it is meant to be inherited, not deployed.
///      Fuzzing it needs a concrete shell and nothing else: every function under test
///      is `pure`, so there is no pool to stand up, no NAV feed to mock, and no epoch
///      to advance. That is the payoff for keeping the ratio arithmetic stateless.
contract SacredHarness is sacred {}

/// @notice Invariants I1 and I3 from ICascade, checked directly on the arithmetic.
///
/// @dev    IF YOU FORK THIS, THESE ARE THE TESTS TO KEEP. Everything else in the
///         repository is a policy choice you are invited to change. These four
///         properties are what makes the thing a waterfall rather than a pro-rata
///         pool, and a change that breaks one of them has changed the instrument.
contract SacredTest is Test {
    SacredHarness s;
    uint256 constant RAY = 1e27;

    function setUp() public {
        s = new SacredHarness();
    }

    /// @notice I3, conservation. The two tranche ratios partition the pool exactly.
    function testFuzz_ratiosConserve(uint256 seniorAsset, uint256 nav, uint256 reserve) public view {
        nav = bound(nav, 0, 1e36);
        reserve = bound(reserve, 0, 1e36);
        uint256 assets = nav + reserve;
        vm.assume(assets > 0);
        seniorAsset = bound(seniorAsset, 0, assets);

        uint256 sr = s.calcSeniorRatio(seniorAsset, nav, reserve);
        uint256 jr = s.calcJuniorRatio(seniorAsset, nav, reserve);

        if (seniorAsset == assets) {
            // senior takes the whole pool: junior is wiped, and the pair still sums to 1.
            assertEq(jr, 0, "junior must be zero when senior claims everything");
        } else {
            assertEq(sr + jr, RAY, "senior + junior ratio must equal exactly ONE");
        }
    }

    /// @notice I2, loss order. Junior reaches zero before senior absorbs anything.
    /// @dev    The boundary condition of the whole structure: for every pool value
    ///         above the senior claim, junior holds a positive residual; the instant
    ///         the pool falls to the senior claim, junior is exactly zero. There is no
    ///         range in which both are impaired.
    function testFuzz_juniorAbsorbsFirst(uint256 seniorAsset, uint256 assets) public view {
        assets = bound(assets, 1, 1e36);
        seniorAsset = bound(seniorAsset, 0, 2e36);

        uint256 jr = s.calcJuniorRatio(seniorAsset, assets, 0);
        if (seniorAsset < assets) {
            assertGt(jr, 0, "junior must hold a residual while the pool covers senior");
        } else {
            assertEq(jr, 0, "junior must be exactly zero once senior claims the pool");
        }
    }

    /// @notice The loss-absorption cap: a senior claim never exceeds the pool.
    /// @dev    Remove the cap in `calcSeniorAssetValue` and this is the test that fails.
    ///         Its failure mode in production is a pool reporting senior solvency
    ///         against value that does not exist.
    function testFuzz_seniorNeverExceedsAssets(
        uint256 seniorRedeem,
        uint256 seniorSupply,
        uint256 currSeniorAsset,
        uint256 reserve,
        uint256 nav
    ) public view {
        currSeniorAsset = bound(currSeniorAsset, 0, 1e36);
        seniorSupply = bound(seniorSupply, 0, 1e36);
        seniorRedeem = bound(seniorRedeem, 0, currSeniorAsset + seniorSupply);
        reserve = bound(reserve, 0, 1e36);
        nav = bound(nav, 0, 1e36);

        uint256 seniorAsset = s.calcSeniorAssetValue(seniorRedeem, seniorSupply, currSeniorAsset, reserve, nav);
        assertLe(seniorAsset, nav + reserve, "senior asset value must never exceed total assets");
    }

    /// @notice An empty pool has no ratios rather than a division by zero.
    function test_emptyPool() public view {
        assertEq(s.calcSeniorRatio(0, 0, 0), 0);
        assertEq(s.calcJuniorRatio(0, 0, 0), 0);
        assertEq(s.calcAssets(0, 0), 0);
    }

    /// @notice With no senior claim at all, junior owns the pool outright.
    function test_juniorOwnsUntranchedPool() public view {
        assertEq(s.calcJuniorRatio(0, 100 ether, 0), RAY);
    }
}
