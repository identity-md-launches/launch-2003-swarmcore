// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./utils/TestBase.sol";
import {SwarmCore} from "../src/SwarmCore.sol";

/// @notice Drives the token with random, bounded call sequences from a fixed set of actors and keeps
/// a ledger of what every call should have done. The ledger only records call inputs (who sent what
/// to whom, who approved what), so the invariants compare the token's state to the ERC-20 contract of
/// those calls, not to a copy of the token's own arithmetic.
///
/// Every handler either makes a call that must succeed, or makes a call that must fail and checks
/// the failure. A handler never reverts on its own, so the suite runs with fail-on-revert on: a
/// revert anywhere in a sequence is itself a finding.
contract SwarmCoreHandler is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant UNLIMITED = type(uint256).max;

    SwarmCore public immutable token;
    address public immutable deployer;

    /// @dev Everyone who can hold a balance in this harness. Index 0 is the deployer, who starts
    /// with the whole supply; the last entry is the token contract itself, which can receive tokens
    /// (nothing forbids it) but never sends them.
    address[] public holders;

    /// @dev The holders that act: every holder except the token contract.
    uint256 public immutable actorCount;

    /// @dev An address that is not a holder and never receives anything.
    address public constant STRANGER = address(0x57A4);

    // Ghost ledger: tokens that left and arrived at each holder through successful calls.
    mapping(address => uint256) public ghostSent;
    mapping(address => uint256) public ghostReceived;

    // Ghost allowance: what the ERC-20 contract says each (owner, spender) pair should have left.
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    // Call counters, so a run that never exercised a path is visible.
    uint256 public transfers;
    uint256 public transfersFrom;
    uint256 public approvals;
    uint256 public rejectedTransfers;
    uint256 public rejectedTransfersFrom;
    uint256 public rejectedApprovals;
    uint256 public rejectedPrivilegedCalls;

    constructor(SwarmCore token_, address deployer_, address[] memory actors) {
        token = token_;
        deployer = deployer_;
        holders.push(deployer_);
        for (uint256 i = 0; i < actors.length; i++) {
            holders.push(actors[i]);
        }
        actorCount = holders.length;
        holders.push(address(token_));
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    // ---------------------------------------------------------------------------------------------
    // Calls that must succeed
    // ---------------------------------------------------------------------------------------------

    /// @notice An actor moves part (possibly none, possibly all) of its balance to a holder.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _holder(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer within balance returned false");

        _assertMoved(from, to, amount, fromBefore, toBefore);
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        transfers++;
    }

    /// @notice An actor moves its entire balance, which exercises the exact-balance boundary.
    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        address to = _holder(toSeed);
        uint256 amount = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        assertTrue(token.transfer(to, amount), "whole-balance transfer returned false");

        _assertMoved(from, to, amount, amount, toBefore);
        if (from != to) assertEq(token.balanceOf(from), 0, "a whole-balance transfer left something behind");
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        transfers++;
    }

    /// @notice An actor sets a spender's allowance outright: to a bounded value, or to unlimited.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 value, bool unlimited) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (unlimited) value = UNLIMITED;
        else value = bound(value, 0, SUPPLY);

        vm.prank(owner);
        assertTrue(token.approve(spender, value), "approve returned false");

        assertEq(token.allowance(owner, spender), value, "approve did not set the allowance outright");
        ghostAllowance[owner][spender] = value;
        approvals++;
    }

    /// @notice A spender moves tokens within both its allowance and the owner's balance.
    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _holder(toSeed);

        uint256 allowed = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        amount = bound(amount, 0, allowed < balance ? allowed : balance);

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        uint256 spenderBefore = token.balanceOf(spender);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom within allowance returned false");

        _assertMoved(owner, to, amount, ownerBefore, toBefore);
        if (spender != owner && spender != to) {
            assertEq(token.balanceOf(spender), spenderBefore, "the spender's own balance changed");
        }
        if (allowed == UNLIMITED) {
            assertEq(token.allowance(owner, spender), UNLIMITED, "an unlimited allowance was decreased");
        } else {
            assertEq(token.allowance(owner, spender), allowed - amount, "the allowance was not decreased by the amount");
            ghostAllowance[owner][spender] = allowed - amount;
        }
        ghostSent[owner] += amount;
        ghostReceived[to] += amount;
        transfersFrom++;
    }

    // ---------------------------------------------------------------------------------------------
    // Calls that must fail, and must leave everything as it was
    // ---------------------------------------------------------------------------------------------

    /// @notice Moving more than the sender holds reverts with the exact balance error.
    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _holder(toSeed);
        uint256 balance = token.balanceOf(from);
        amount = bound(amount, balance + 1, UNLIMITED);

        vm.prank(from);
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(token.transfer, (to, amount)));
        assertFalse(ok, "a transfer above the balance succeeded");
        _assertRevertData(
            data, abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, from, balance, amount)
        );
        assertEq(token.balanceOf(from), balance, "a rejected transfer changed the sender's balance");
        rejectedTransfers++;
    }

    /// @notice A stranger with no balance cannot move anything, however small.
    function transferFromStranger(uint256 toSeed, uint256 amount) external {
        address to = _holder(toSeed);
        amount = bound(amount, 1, UNLIMITED);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(STRANGER);
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(token.transfer, (to, amount)));
        assertFalse(ok, "a stranger moved tokens it does not hold");
        _assertRevertData(
            data, abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, STRANGER, uint256(0), amount)
        );
        assertEq(token.balanceOf(to), toBefore, "a rejected transfer changed the receiver's balance");
        rejectedTransfers++;
    }

    /// @notice Sending to the zero address reverts, even for zero tokens.
    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 before = token.balanceOf(from);

        vm.prank(from);
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(token.transfer, (address(0), amount)));
        assertFalse(ok, "a transfer to the zero address succeeded");
        _assertRevertData(data, abi.encodeWithSelector(SwarmCore.ERC20InvalidReceiver.selector, address(0)));
        assertEq(token.balanceOf(from), before, "a rejected transfer changed the sender's balance");
        rejectedTransfers++;
    }

    /// @notice A spender cannot move more than its allowance, whatever the owner holds.
    function transferFromAboveAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _holder(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == UNLIMITED) return; // nothing is above an unlimited allowance
        amount = bound(amount, allowed + 1, UNLIMITED);
        uint256 ownerBefore = token.balanceOf(owner);

        vm.prank(spender);
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(token.transferFrom, (owner, to, amount)));
        assertFalse(ok, "a transferFrom above the allowance succeeded");
        _assertRevertData(
            data, abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        assertEq(token.allowance(owner, spender), allowed, "a rejected transferFrom changed the allowance");
        assertEq(token.balanceOf(owner), ownerBefore, "a rejected transferFrom changed the owner's balance");
        rejectedTransfersFrom++;
    }

    /// @notice An allowance does not create tokens: a spender with allowance above the owner's
    /// balance still cannot move more than the balance, and the allowance is not spent on failure.
    function transferFromAboveBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _holder(toSeed);
        uint256 balance = token.balanceOf(owner);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed <= balance) return; // the allowance check fires first; covered above
        amount = bound(amount, balance + 1, allowed);

        vm.prank(spender);
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(token.transferFrom, (owner, to, amount)));
        assertFalse(ok, "a transferFrom above the owner's balance succeeded");
        _assertRevertData(
            data, abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, owner, balance, amount)
        );
        assertEq(token.allowance(owner, spender), allowed, "a failed transferFrom spent the allowance");
        assertEq(token.balanceOf(owner), balance, "a rejected transferFrom changed the owner's balance");
        rejectedTransfersFrom++;
    }

    /// @notice Approving the zero address reverts and leaves other allowances alone.
    function approveZeroSpender(uint256 ownerSeed, uint256 value) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(token.approve, (address(0), value)));
        assertFalse(ok, "an approval of the zero address succeeded");
        _assertRevertData(data, abi.encodeWithSelector(SwarmCore.ERC20InvalidSpender.selector, address(0)));
        rejectedApprovals++;
    }

    /// @notice Nobody, holder or stranger, reaches a mint, burn, pause, freeze or seize: the token
    /// has no such function, and the call must revert without touching state.
    function privilegedCall(uint256 callerSeed, uint256 selectorSeed, uint256 targetSeed, uint256 amount) external {
        address caller = callerSeed % 7 == 0 ? STRANGER : _actor(callerSeed);
        address target = _holder(targetSeed);
        string[16] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "lock(address)",
            "seize(address)",
            "transferOwnership(address)",
            "setMinter(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setTransfersEnabled(bool)"
        ];
        bytes memory data = abi.encodeWithSignature(signatures[selectorSeed % signatures.length], target, amount);
        uint256 targetBefore = token.balanceOf(target);
        uint256 callerBefore = token.balanceOf(caller);

        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "a privileged call succeeded");
        assertEq(token.balanceOf(target), targetBefore, "a privileged call changed a holder's balance");
        assertEq(token.balanceOf(caller), callerBefore, "a privileged call changed the caller's balance");
        rejectedPrivilegedCalls++;
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return holders[seed % actorCount];
    }

    function _holder(uint256 seed) internal view returns (address) {
        return holders[seed % holders.length];
    }

    function _assertMoved(address from, address to, uint256 amount, uint256 fromBefore, uint256 toBefore)
        internal
        view
    {
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "a self transfer changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "the sender was not debited by the amount");
            assertEq(token.balanceOf(to), toBefore + amount, "the receiver was not credited by the amount");
        }
    }

    function _assertRevertData(bytes memory actual, bytes memory expected) internal pure {
        assertTrue(keccak256(actual) == keccak256(expected), "the call reverted with the wrong error");
    }
}

/// @notice Invariants over random call sequences. The token holds every holder's balance, so after
/// any sequence the balances must still sum to the fixed supply, each balance must equal what the
/// ledger says flowed in and out, every allowance must be what the ERC-20 contract of the calls
/// says, and no path may have grown the supply or reached a privileged function.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmCoreInvariantTest is TestBase {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;
    address internal constant DEPLOYER = address(0xFAC7);

    SwarmCore internal token;
    SwarmCoreHandler internal handler;
    address[] internal targets;
    FuzzSelector[] internal selectors;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new SwarmCore();

        address[] memory actors = new address[](4);
        actors[0] = address(0xA11CE);
        actors[1] = address(0xB0B);
        actors[2] = address(0xCA401);
        actors[3] = address(0xDA7E);
        handler = new SwarmCoreHandler(token, DEPLOYER, actors);

        vm.label(address(token), "SwarmCore");
        vm.label(address(handler), "handler");
        vm.label(DEPLOYER, "deployer");

        targets.push(address(handler));
        bytes4[] memory picked = new bytes4[](11);
        picked[0] = handler.transfer.selector;
        picked[1] = handler.transferAll.selector;
        picked[2] = handler.approve.selector;
        picked[3] = handler.transferFrom.selector;
        picked[4] = handler.transferAboveBalance.selector;
        picked[5] = handler.transferFromStranger.selector;
        picked[6] = handler.transferToZero.selector;
        picked[7] = handler.transferFromAboveAllowance.selector;
        picked[8] = handler.transferFromAboveBalance.selector;
        picked[9] = handler.approveZeroSpender.selector;
        picked[10] = handler.privilegedCall.selector;
        selectors.push(FuzzSelector(address(handler), picked));
    }

    /// @dev Read by forge's invariant runner: only the handler is called.
    function targetContracts() external view returns (address[] memory) {
        return targets;
    }

    /// @dev Read by forge's invariant runner: only the handler's action functions are called.
    function targetSelectors() external view returns (FuzzSelector[] memory) {
        return selectors;
    }

    /// @notice The supply never changes, from any sequence.
    function invariant_totalSupplyIsFixed() external view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "the total supply changed");
    }

    /// @notice What the token holds for everyone who can hold it equals the whole supply: nothing
    /// is created, lost or parked anywhere the handler cannot see.
    function invariant_balancesSumToSupply() external view {
        uint256 sum;
        uint256 n = handler.holderCount();
        for (uint256 i = 0; i < n; i++) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, EXPECTED_SUPPLY, "the balances do not sum to the supply");
        assertEq(token.balanceOf(handler.STRANGER()), 0, "a stranger acquired tokens");
        assertEq(token.balanceOf(address(handler)), 0, "the handler acquired tokens");
        assertEq(token.balanceOf(address(0)), 0, "the zero address acquired tokens");
    }

    /// @notice Each balance is exactly what the ledger of successful calls says: the opening balance
    /// plus everything received minus everything sent. Nobody gains without a sender, nobody loses
    /// without a call of their own or of a spender they approved.
    function invariant_balancesMatchTheLedger() external view {
        uint256 n = handler.holderCount();
        for (uint256 i = 0; i < n; i++) {
            address holder = handler.holders(i);
            uint256 opening = holder == DEPLOYER ? EXPECTED_SUPPLY : 0;
            assertEq(
                token.balanceOf(holder) + handler.ghostSent(holder),
                opening + handler.ghostReceived(holder),
                "a balance disagrees with the ledger of calls"
            );
            assertLe(
                handler.ghostSent(holder), opening + handler.ghostReceived(holder), "a holder sent more than it had"
            );
        }
    }

    /// @notice Every allowance is what the last approve set, less what was spent since, with an
    /// unlimited allowance never decreasing.
    function invariant_allowancesMatchTheLedger() external view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < n; j++) {
                address owner = handler.holders(i);
                address spender = handler.holders(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "an allowance disagrees with the ledger of approvals"
                );
            }
        }
    }

    /// @notice No balance exceeds the supply (a corrupted balance would show up here before the sum
    /// overflowed), and the metadata never changes.
    function invariant_noBalanceExceedsSupplyAndMetadataIsConstant() external view {
        uint256 n = handler.holderCount();
        for (uint256 i = 0; i < n; i++) {
            assertLe(token.balanceOf(handler.holders(i)), EXPECTED_SUPPLY, "a balance exceeds the supply");
        }
        assertEq(token.name(), "SwarmCore", "name changed");
        assertEq(token.symbol(), "SWARMCORE", "symbol changed");
        assertEq(uint256(token.decimals()), 18, "decimals changed");
    }

    /// @notice The token itself never holds ether and its code never changes.
    function invariant_tokenHoldsNoEtherAndKeepsItsCode() external view {
        assertEq(address(token).balance, 0, "the token holds ether");
        assertGt(address(token).code.length, 0, "the token lost its code");
    }

    /// @notice Every handler path is reachable and does what it claims, in one fixed sequence: a
    /// handler that silently returned on every input would make the invariants above vacuous.
    function test_handlerExercisesEveryPath() external {
        handler.transfer(0, 1, 5e18); // deployer -> alice
        handler.transferAll(1, 2); // alice -> bob, whole balance
        handler.approve(0, 3, 7e18, false); // deployer approves carol (holder 3)
        handler.transferFrom(0, 3, 2, 3e18); // carol moves deployer -> bob
        handler.approve(0, 1, 0, true); // deployer approves alice unlimited
        handler.transferFrom(0, 1, 1, 1e18); // alice pulls 1 with unlimited allowance
        handler.transferAboveBalance(1, 2, 0);
        handler.transferFromStranger(2, 0);
        handler.transferToZero(0, 1);
        handler.transferFromAboveAllowance(0, 3, 2, 0); // carol has 4e18 left, asks for more
        handler.approve(2, 3, EXPECTED_SUPPLY, false); // bob approves carol more than bob holds
        handler.transferFromAboveBalance(2, 3, 1, 0);
        handler.approveZeroSpender(0, 1);
        for (uint256 i = 0; i < 16; i++) {
            handler.privilegedCall(i, i, i, 1);
        }

        assertEq(handler.transfers(), 2, "transfers");
        assertEq(handler.transfersFrom(), 2, "transfersFrom");
        assertEq(handler.approvals(), 3, "approvals");
        assertEq(handler.rejectedTransfers(), 3, "rejected transfers");
        assertEq(handler.rejectedTransfersFrom(), 2, "rejected transferFroms");
        assertEq(handler.rejectedApprovals(), 1, "rejected approvals");
        assertEq(handler.rejectedPrivilegedCalls(), 16, "rejected privileged calls");

        assertEq(token.balanceOf(address(0xA11CE)), 1e18, "alice");
        assertEq(token.balanceOf(address(0xB0B)), 8e18, "bob");
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY - 9e18, "deployer");
        assertEq(token.allowance(DEPLOYER, address(0xCA401)), 4e18, "carol's allowance");
        assertEq(token.allowance(DEPLOYER, address(0xA11CE)), type(uint256).max, "alice's allowance");

        this.invariant_totalSupplyIsFixed();
        this.invariant_balancesSumToSupply();
        this.invariant_balancesMatchTheLedger();
        this.invariant_allowancesMatchTheLedger();
        this.invariant_noBalanceExceedsSupplyAndMetadataIsConstant();
        this.invariant_tokenHoldsNoEtherAndKeepsItsCode();
    }
}
