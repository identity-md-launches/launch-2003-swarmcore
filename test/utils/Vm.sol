// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The subset of Foundry's cheatcodes these tests use. Cheatcodes are dispatched by selector
/// on the cheatcode address, so only the signatures matter; this file stands in for forge-std so the
/// project vendors no library at all.
interface Vm {
    /// @notice Sets `msg.sender` for the next call or contract creation.
    function prank(address msgSender) external;

    /// @notice Sets `msg.sender` for every call until `stopPrank`.
    function startPrank(address msgSender) external;

    /// @notice Ends a `startPrank`.
    function stopPrank() external;

    /// @notice Sets the ether balance of `account`.
    function deal(address account, uint256 newBalance) external;

    /// @notice Expects the next call to revert with any data.
    function expectRevert() external;

    /// @notice Expects the next call to revert with exactly `revertData`.
    function expectRevert(bytes calldata revertData) external;

    /// @notice Expects the next call to emit the event emitted right after this cheatcode, matching
    /// the indexed topics and data selected.
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;

    /// @notice Discards a fuzz input when `condition` is false.
    function assume(bool condition) external pure;

    /// @notice Labels an address in traces.
    function label(address account, string calldata newLabel) external;
}
