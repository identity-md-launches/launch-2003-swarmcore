// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "./Vm.sol";

/// @notice A minimal test base: the cheatcode handle and reverting assertions. A test fails when it
/// reverts, so every assertion reverts with its message on mismatch.
abstract contract TestBase {
    /// @dev Foundry's cheatcode address, `address(uint160(uint256(keccak256("hevm cheat code"))))`.
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool condition, string memory err) internal pure {
        if (!condition) revert(string.concat("assertTrue failed: ", err));
    }

    function assertFalse(bool condition, string memory err) internal pure {
        if (condition) revert(string.concat("assertFalse failed: ", err));
    }

    function assertEq(uint256 a, uint256 b, string memory err) internal pure {
        if (a != b) revert(string.concat("assertEq(uint256) failed: ", err));
    }

    function assertEq(address a, address b, string memory err) internal pure {
        if (a != b) revert(string.concat("assertEq(address) failed: ", err));
    }

    function assertEq(string memory a, string memory b, string memory err) internal pure {
        if (keccak256(bytes(a)) != keccak256(bytes(b))) revert(string.concat("assertEq(string) failed: ", err));
    }

    function assertLe(uint256 a, uint256 b, string memory err) internal pure {
        if (a > b) revert(string.concat("assertLe failed: ", err));
    }

    function assertGt(uint256 a, uint256 b, string memory err) internal pure {
        if (a <= b) revert(string.concat("assertGt failed: ", err));
    }

    /// @dev Maps a fuzz input into `[min, max]`.
    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        require(min <= max, "bound: min > max");
        uint256 size = max - min;
        if (size == type(uint256).max) return x;
        return min + (x % (size + 1));
    }
}
