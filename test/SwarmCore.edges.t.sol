// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./utils/TestBase.sol";
import {SwarmCore} from "../src/SwarmCore.sol";

/// @notice Deploys the token inside a single transaction and records what it observed about the
/// supply before returning, so a test can see what the launch factory would see in `launchCustom`:
/// the whole supply on the deploying contract, in the same call that created it.
contract OneShotDeployer {
    SwarmCore public token;
    uint256 public supplySeen;
    uint256 public balanceSeen;
    uint256 public originBalanceSeen;

    constructor() {
        token = new SwarmCore();
        supplySeen = token.totalSupply();
        balanceSeen = token.balanceOf(address(this));
        originBalanceSeen = token.balanceOf(tx.origin);
    }
}

/// @notice The inputs the first suite did not try: the zero address as a caller, the allowance one
/// below unlimited, a spender pulling to the owner or to itself, the constructor's event, calls to
/// selectors the token does not have, and the launch deployment seen from inside one transaction.
/// forge-config: default.fuzz.runs = 1000
contract SwarmCoreEdgesTest is TestBase {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant UNLIMITED = type(uint256).max;

    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5BE4);

    SwarmCore internal token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new SwarmCore();
    }

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    function test_constructorEmitsOneMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), ALICE, EXPECTED_SUPPLY);
        vm.prank(ALICE);
        new SwarmCore();
    }

    function test_supplyIsVisibleToTheDeployingContractInTheSameTransaction() public {
        OneShotDeployer factory = new OneShotDeployer();
        assertEq(factory.supplySeen(), EXPECTED_SUPPLY, "supply inside the deploying transaction");
        assertEq(factory.balanceSeen(), EXPECTED_SUPPLY, "the deploying contract held the supply at once");
        assertEq(factory.originBalanceSeen(), 0, "tx.origin received something");
        assertEq(factory.token().balanceOf(address(factory)), EXPECTED_SUPPLY, "the supply stayed with the factory");
    }

    function test_supplyMatchesTheManifestMinorUnits() public view {
        assertEq(token.totalSupply(), 1000000000000000000000000000, "manifest minor units");
        assertEq(token.totalSupply(), 10 ** 9 * 10 ** uint256(token.decimals()), "supply is 1e9 whole tokens");
    }

    // ---------------------------------------------------------------------------------------------
    // The zero address as a caller
    // ---------------------------------------------------------------------------------------------

    function test_transfer_fromZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(ALICE, 0);
    }

    function test_approve_fromZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(SPENDER, 1);
    }

    function test_transferFrom_fromZeroAddressRevertsEvenForZero() public {
        // No allowance can be granted by the zero address, so the allowance check fires first
        // for any positive amount; for zero the transfer itself rejects the zero sender.
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InvalidSender.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(0), ALICE, 0);

        vm.expectRevert(
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, SPENDER, uint256(0), uint256(1))
        );
        vm.prank(SPENDER);
        token.transferFrom(address(0), ALICE, 1);
    }

    function test_transferFrom_zeroSpenderHasNoAllowance() public {
        vm.expectRevert(
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, address(0), uint256(0), uint256(1))
        );
        vm.prank(address(0));
        token.transferFrom(DEPLOYER, ALICE, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowance boundaries
    // ---------------------------------------------------------------------------------------------

    function test_transferFrom_oneBelowUnlimitedIsDecreased() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, UNLIMITED - 1);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 1);
        assertEq(token.allowance(DEPLOYER, SPENDER), UNLIMITED - 2, "only the exact maximum is unlimited");
    }

    function test_transferFrom_unlimitedAllowanceStillNeedsBalance() public {
        vm.prank(ALICE);
        token.approve(SPENDER, UNLIMITED);
        vm.expectRevert(
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, ALICE, uint256(0), uint256(1))
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
        assertEq(token.allowance(ALICE, SPENDER), UNLIMITED, "the failed pull touched the allowance");
    }

    function test_transferFrom_zeroAmountNeedsNoAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(DEPLOYER, BOB, 0);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, BOB, 0), "zero transferFrom returned false");
        assertEq(token.balanceOf(BOB), 0, "bob received something");
    }

    function test_transferFrom_toTheOwnerSpendsAllowanceButMovesNothing() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 10);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, DEPLOYER, 4);
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY, "a self pull changed the balance");
        assertEq(token.allowance(DEPLOYER, SPENDER), 6, "a self pull did not spend the allowance");
    }

    function test_transferFrom_spenderMayPullToItself() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 10);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, SPENDER, 10);
        assertEq(token.balanceOf(SPENDER), 10, "the spender did not receive the pull");
        assertEq(token.allowance(DEPLOYER, SPENDER), 0, "the allowance was not exhausted");
    }

    function test_approve_overwritesNotAccumulates() public {
        vm.startPrank(DEPLOYER);
        token.approve(SPENDER, 5);
        token.approve(SPENDER, 3);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, SPENDER), 3, "approve accumulated instead of overwriting");
    }

    function test_approve_doesNotRequireABalance() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(ALICE, SPENDER, EXPECTED_SUPPLY + 1);
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, EXPECTED_SUPPLY + 1), "approve returned false");
        assertEq(token.allowance(ALICE, SPENDER), EXPECTED_SUPPLY + 1, "allowance above balance not set");
    }

    function test_approve_selfAllowanceIsOrdinary() public {
        vm.prank(DEPLOYER);
        token.approve(DEPLOYER, 2);
        vm.prank(DEPLOYER);
        token.transferFrom(DEPLOYER, ALICE, 2);
        assertEq(token.balanceOf(ALICE), 2, "alice");
        assertEq(token.allowance(DEPLOYER, DEPLOYER), 0, "self allowance not spent");
    }

    function test_allowancesAreIndependentPerPair() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 9);
        assertEq(token.allowance(DEPLOYER, ALICE), 0, "another spender gained an allowance");
        assertEq(token.allowance(SPENDER, DEPLOYER), 0, "the allowance was mirrored");
        assertEq(token.allowance(ALICE, SPENDER), 0, "another owner granted an allowance");
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers do not touch allowances; tokens can be sent to the token itself and to contracts
    // ---------------------------------------------------------------------------------------------

    function test_transfer_doesNotChangeAllowances() public {
        vm.startPrank(DEPLOYER);
        token.approve(SPENDER, 11);
        token.transfer(ALICE, 1e18);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, SPENDER), 11, "a transfer changed an allowance");
    }

    function test_transfer_toTheTokenContractIsAllowedAndCounted() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(address(token), 1), "transfer to the token returned false");
        assertEq(token.balanceOf(address(token)), 1, "the token's own balance");
        assertEq(token.balanceOf(DEPLOYER) + token.balanceOf(address(token)), EXPECTED_SUPPLY, "supply conserved");
    }

    // ---------------------------------------------------------------------------------------------
    // Unknown calls
    // ---------------------------------------------------------------------------------------------

    function test_unknownSelectorReverts() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok, "an unknown selector was accepted");
        (ok,) = address(token).call(hex"");
        assertFalse(ok, "an empty call was accepted");
        (ok,) = address(token).call(hex"01");
        assertFalse(ok, "a short call was accepted");
    }

    function test_viewFunctionsRejectEther() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1}(abi.encodeCall(token.totalSupply, ()));
        assertFalse(ok, "totalSupply accepted ether");
        (ok,) = address(token).call{value: 1}(abi.encodeCall(token.transfer, (ALICE, 0)));
        assertFalse(ok, "transfer accepted ether");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: the properties a single call must keep, at any input
    // ---------------------------------------------------------------------------------------------

    /// @notice Any transfer either succeeds exactly or reverts cleanly: there is no third outcome.
    function testFuzz_transferSucceedsExactlyOrRevertsCleanly(address from, address to, uint256 held, uint256 amount)
        public
    {
        held = bound(held, 0, EXPECTED_SUPPLY);
        // The cheatcode address and this test are not plausible holders; fold them onto a plain one.
        if (from == address(vm) || from == address(this)) from = ALICE;
        if (to == address(vm) || to == address(this)) to = BOB;
        if (from != address(0) && from != DEPLOYER) {
            vm.prank(DEPLOYER);
            token.transfer(from, held);
        } else {
            held = from == address(0) ? 0 : EXPECTED_SUPPLY;
        }
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (to, amount)));

        bool shouldSucceed = from != address(0) && to != address(0) && amount <= held;
        assertTrue(ok == shouldSucceed, "the outcome does not match the ERC-20 rule");
        if (ok && from != to) {
            assertEq(token.balanceOf(from), held - amount, "sender after");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver after");
        } else {
            assertEq(token.balanceOf(from), held, "sender unchanged");
            assertEq(token.balanceOf(to), from == to ? held : toBefore, "receiver unchanged");
        }
    }

    /// @notice Approve then transferFrom round-trips: the allowance left is the approval minus the
    /// pull, unless the approval was unlimited, and the tokens land where they were sent.
    function testFuzz_approveThenTransferFromRoundTrip(uint256 approved, uint256 amount, bool unlimited) public {
        if (unlimited) approved = UNLIMITED;
        else approved = bound(approved, 0, EXPECTED_SUPPLY);
        amount = bound(amount, 0, approved < EXPECTED_SUPPLY ? approved : EXPECTED_SUPPLY);

        vm.prank(DEPLOYER);
        token.approve(SPENDER, approved);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, amount), "transferFrom returned false");

        uint256 expectedLeft = approved == UNLIMITED ? UNLIMITED : approved - amount;
        assertEq(token.allowance(DEPLOYER, SPENDER), expectedLeft, "allowance after");
        assertEq(token.balanceOf(ALICE), amount, "alice after");
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY - amount, "deployer after");
    }

    /// @notice Two transfers in either order end in the same state: transfers commute when both can
    /// be paid for, which is what a fixed-supply ledger must do.
    function testFuzz_transfersCommute(uint256 a, uint256 b) public {
        a = bound(a, 0, EXPECTED_SUPPLY / 2);
        b = bound(b, 0, EXPECTED_SUPPLY / 2);

        vm.prank(ALICE);
        SwarmCore other = new SwarmCore();

        vm.startPrank(DEPLOYER);
        token.transfer(ALICE, a);
        token.transfer(BOB, b);
        vm.stopPrank();

        vm.startPrank(ALICE);
        other.transfer(BOB, b);
        other.transfer(ALICE, a);
        vm.stopPrank();

        // In `token` the deployer paid alice `a` and bob `b`; in `other` alice is the deployer and
        // paid bob `b` first and herself `a` (a no-op), so the deployer-side balances must agree.
        assertEq(token.balanceOf(DEPLOYER), other.balanceOf(ALICE) - a, "deployer-side balance");
        assertEq(token.balanceOf(BOB), other.balanceOf(BOB), "bob's balance differs by order");
    }

    /// @notice An amount one above any balance is rejected with that balance in the error, whoever
    /// the holder is.
    function testFuzz_oneAboveAnyBalanceReverts(address holder, uint256 held) public {
        held = bound(held, 0, EXPECTED_SUPPLY - 1);
        if (holder == address(0) || holder == DEPLOYER || holder == address(vm) || holder == address(this)) {
            holder = ALICE;
        }
        vm.prank(DEPLOYER);
        token.transfer(holder, held);

        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, holder, held, held + 1));
        vm.prank(holder);
        token.transfer(BOB, held + 1);
    }
}
