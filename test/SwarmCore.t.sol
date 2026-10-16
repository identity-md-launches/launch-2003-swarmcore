// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./utils/TestBase.sol";
import {SwarmCore} from "../src/SwarmCore.sol";

/// @notice Stands in for the launch factory: deploys the token through CREATE2 from a contract, so
/// the test can check that the supply lands on the deploying contract and not on `tx.origin`.
contract FactoryStub {
    function deploy(bytes32 salt) external returns (SwarmCore) {
        return new SwarmCore{salt: salt}();
    }
}

contract SwarmCoreTest is TestBase {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant ONE = 1e18;

    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5BE4);
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant POOL_MANAGER = address(0x900C);
    address internal constant REQUESTER = address(0x4E0);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant ATTACKER = address(0xBEEF);

    SwarmCore internal token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new SwarmCore();
        vm.label(address(token), "SwarmCore");
        vm.label(DEPLOYER, "deployer");
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "SwarmCore", "name");
        assertEq(token.symbol(), "SWARMCORE", "symbol");
        assertEq(uint256(token.decimals()), 18, "decimals");
        assertEq(uint256(token.DECIMALS()), 18, "DECIMALS constant");
    }

    function test_constructorMintsTheWholeSupplyToTheDeployerOnce() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "total supply");
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY, "TOTAL_SUPPLY constant");
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY, "the deployer holds the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the test contract holds nothing");
        assertEq(token.balanceOf(address(token)), 0, "the token holds nothing");
    }

    function test_supplyIsMintedToTheDeployingContractNotTheOrigin() public {
        FactoryStub factory = new FactoryStub();
        SwarmCore launched = factory.deploy(bytes32(uint256(1)));
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY, "launched supply");
        assertEq(launched.balanceOf(address(factory)), EXPECTED_SUPPLY, "the factory holds the whole supply");
        assertEq(launched.balanceOf(address(this)), 0, "the caller holds nothing");
        assertEq(launched.balanceOf(DEPLOYER), 0, "another deployment does not touch this one");
    }

    function test_eachDeploymentIsIndependent() public {
        vm.prank(ALICE);
        SwarmCore second = new SwarmCore();
        assertEq(second.balanceOf(ALICE), EXPECTED_SUPPLY, "second deployer holds the second supply");
        assertEq(token.balanceOf(ALICE), 0, "the first token is unaffected");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "the first supply is unchanged");
    }

    // ---------------------------------------------------------------------------------------------
    // transfer
    // ---------------------------------------------------------------------------------------------

    function test_transfer_movesBalanceAndEmits() public {
        uint256 amount = 1000 * ONE;
        vm.expectEmit(true, true, true, true);
        emit Transfer(DEPLOYER, ALICE, amount);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, amount), "transfer returned false");
        assertEq(token.balanceOf(ALICE), amount, "alice");
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY - amount, "deployer");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "supply unchanged");
    }

    function test_transfer_wholeBalanceAndZeroAmountSucceed() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, EXPECTED_SUPPLY), "whole-balance transfer returned false");
        assertEq(token.balanceOf(ALICE), EXPECTED_SUPPLY, "alice holds everything");
        assertEq(token.balanceOf(DEPLOYER), 0, "deployer is empty");

        vm.prank(DEPLOYER);
        assertTrue(token.transfer(BOB, 0), "zero transfer returned false");
        assertEq(token.balanceOf(BOB), 0, "bob received nothing");
    }

    function test_transfer_toSelfKeepsBalance() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(DEPLOYER, EXPECTED_SUPPLY), "self transfer returned false");
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY, "self transfer changed the balance");
    }

    function test_transfer_revertsWhenBalanceIsInsufficient() public {
        vm.expectRevert(
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, ALICE, uint256(0), uint256(1))
        );
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    function test_transfer_revertsOneAboveBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmCore.ERC20InsufficientBalance.selector, DEPLOYER, EXPECTED_SUPPLY, EXPECTED_SUPPLY + 1
            )
        );
        vm.prank(DEPLOYER);
        token.transfer(ALICE, EXPECTED_SUPPLY + 1);
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY, "nothing moved");
    }

    function test_transfer_revertsToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(DEPLOYER);
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // approve / transferFrom
    // ---------------------------------------------------------------------------------------------

    function test_approve_setsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(DEPLOYER, SPENDER, 5);
        vm.prank(DEPLOYER);
        assertTrue(token.approve(SPENDER, 5), "approve returned false");
        assertEq(token.allowance(DEPLOYER, SPENDER), 5, "allowance");

        vm.prank(DEPLOYER);
        assertTrue(token.approve(SPENDER, 0), "re-approve returned false");
        assertEq(token.allowance(DEPLOYER, SPENDER), 0, "allowance cleared");
    }

    function test_approve_doesNotMoveTokens() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, EXPECTED_SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY, "approve moved tokens");
        assertEq(token.balanceOf(SPENDER), 0, "spender received tokens");
    }

    function test_approve_revertsForZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InvalidSpender.selector, address(0)));
        vm.prank(DEPLOYER);
        token.approve(address(0), 1);
    }

    function test_transferFrom_spendsAllowanceAndEmits() public {
        uint256 allowed = 10 * ONE;
        uint256 amount = 4 * ONE;
        vm.prank(DEPLOYER);
        token.approve(SPENDER, allowed);

        vm.expectEmit(true, true, true, true);
        emit Transfer(DEPLOYER, BOB, amount);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, BOB, amount), "transferFrom returned false");

        assertEq(token.balanceOf(BOB), amount, "bob");
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY - amount, "deployer");
        assertEq(token.balanceOf(SPENDER), 0, "the spender keeps nothing");
        assertEq(token.allowance(DEPLOYER, SPENDER), allowed - amount, "allowance decreased");
    }

    function test_transferFrom_exactAllowanceLeavesZero() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 7);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 7);
        assertEq(token.allowance(DEPLOYER, SPENDER), 0, "allowance exhausted");

        vm.expectRevert(
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, SPENDER, uint256(0), uint256(1))
        );
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    function test_transferFrom_unlimitedAllowanceIsNotDecreased() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, BOB, ONE), "transferFrom returned false");
        assertEq(token.allowance(DEPLOYER, SPENDER), type(uint256).max, "unlimited allowance was decreased");
        assertEq(token.balanceOf(BOB), ONE, "bob");
    }

    function test_transferFrom_revertsWithoutAllowance() public {
        vm.expectRevert(
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, SPENDER, uint256(0), uint256(1))
        );
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 1);
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY, "nothing moved");
    }

    function test_transferFrom_revertsWhenAllowanceIsShort() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 5);
        vm.expectRevert(
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, SPENDER, uint256(5), uint256(6))
        );
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 6);
        assertEq(token.allowance(DEPLOYER, SPENDER), 5, "allowance untouched after revert");
    }

    function test_transferFrom_revertsWhenHolderBalanceIsShort() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 1);
        vm.expectRevert(
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, ALICE, uint256(0), uint256(1))
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_transferFrom_revertsToZeroAddress() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 1);
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flows: every transfer arrives whole, so the swarm share, the seed and the remainder
    // move exactly what the factory sends.
    // ---------------------------------------------------------------------------------------------

    function test_launchFlowsArriveWhole() public {
        uint256 swarm = (EXPECTED_SUPPLY * 1_000) / 10_000;
        uint256 pool = (EXPECTED_SUPPLY * 8_000) / 10_000;
        uint256 remainder = EXPECTED_SUPPLY - swarm - pool;

        vm.startPrank(DEPLOYER);
        assertTrue(token.transfer(DISTRIBUTOR, swarm), "swarm transfer returned false");
        assertTrue(token.transfer(POOL_MANAGER, pool), "seed transfer returned false");
        assertTrue(token.transfer(REQUESTER, remainder), "remainder transfer returned false");
        vm.stopPrank();

        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "the swarm share arrived short");
        assertEq(token.balanceOf(POOL_MANAGER), pool, "the seed arrived short");
        assertEq(token.balanceOf(REQUESTER), remainder, "the remainder arrived short");
        assertEq(token.balanceOf(DEPLOYER), 0, "the factory kept something back");

        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm), "claim transfer returned false");
        assertEq(token.balanceOf(CLAIMANT), swarm, "a claim arrived short");
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "the distributor kept something back");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "the launch flows changed the supply");
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged surface: nothing mints, pauses, freezes or seizes, from anyone.
    // ---------------------------------------------------------------------------------------------

    function test_noMintOrAdminFunctionExists() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ATTACKER, type(uint128).max);
            vm.prank(ATTACKER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(DEPLOYER);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, "the supply changed");
            assertEq(token.balanceOf(ATTACKER), 0, "the attacker received tokens");
            assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY, "the deployer's balance changed");
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        uint256 held = EXPECTED_SUPPLY / 1_000;
        vm.prank(DEPLOYER);
        token.transfer(ALICE, held);

        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, true);
            vm.prank(DEPLOYER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }

        vm.prank(DEPLOYER);
        (bool moved,) = address(token).call(abi.encodeWithSelector(token.transferFrom.selector, ALICE, DEPLOYER, 1));
        assertFalse(moved, "the deployer pulled from a holder without allowance");
        assertEq(token.balanceOf(ALICE), held, "the holder's balance changed");

        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(BOB), held / 2, "the holder's transfer delivered short");
    }

    function test_rejectsEther() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0, "the token has no runtime code");
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "runtime code contains DELEGATECALL");
            assertTrue(op != 0xF2, "runtime code contains CALLCODE");
            assertTrue(op != 0xFF, "runtime code contains SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, EXPECTED_SUPPLY);

        vm.prank(DEPLOYER);
        assertTrue(token.transfer(to, amount), "transfer returned false");

        if (to == DEPLOYER) {
            assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY, "self transfer changed the balance");
        } else {
            assertEq(token.balanceOf(to), amount, "recipient balance");
            assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY - amount, "sender balance");
            assertEq(token.balanceOf(to) + token.balanceOf(DEPLOYER), EXPECTED_SUPPLY, "supply not conserved");
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "total supply changed");
    }

    function testFuzz_transferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, EXPECTED_SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, DEPLOYER, EXPECTED_SUPPLY, amount)
        );
        vm.prank(DEPLOYER);
        token.transfer(ALICE, amount);
    }

    function testFuzz_transferFromWithinAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY);
        amount = bound(amount, 0, allowed);

        vm.prank(DEPLOYER);
        token.approve(SPENDER, allowed);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, BOB, amount), "transferFrom returned false");

        assertEq(token.balanceOf(BOB), amount, "recipient balance");
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY - amount, "holder balance");
        assertEq(token.allowance(DEPLOYER, SPENDER), allowed - amount, "allowance");
    }

    function testFuzz_transferFromAboveAllowanceReverts(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY - 1);
        amount = bound(amount, allowed + 1, EXPECTED_SUPPLY);

        vm.prank(DEPLOYER);
        token.approve(SPENDER, allowed);
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, SPENDER, allowed, amount));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, amount);
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY, "nothing moved");
    }

    function testFuzz_chainedTransfersConserveSupply(uint256 first, uint256 second) public {
        first = bound(first, 0, EXPECTED_SUPPLY);
        second = bound(second, 0, first);

        vm.prank(DEPLOYER);
        token.transfer(ALICE, first);
        vm.prank(ALICE);
        token.transfer(BOB, second);

        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY - first, "deployer");
        assertEq(token.balanceOf(ALICE), first - second, "alice");
        assertEq(token.balanceOf(BOB), second, "bob");
        assertEq(
            token.balanceOf(DEPLOYER) + token.balanceOf(ALICE) + token.balanceOf(BOB),
            EXPECTED_SUPPLY,
            "supply not conserved"
        );
    }
}
