// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title SwarmCore (SWARMCORE)
/// @notice A fixed-supply ERC-20 token. The whole supply of 1,000,000,000 SWARMCORE (18 decimals)
/// is minted once, in the constructor, to the deployer (`msg.sender`). There is no owner, no
/// minter, no pause, no blacklist, no fee and no burn: after deployment the contract has no
/// privileged function at all, and the supply can neither grow nor shrink.
/// @dev The constructor takes no arguments and calls no other contract, so the token deploys on an
/// empty chain. Every function is implemented in this file; no library is linked.
contract SwarmCore is IERC20 {
    /// @dev The token name returned by `name()`.
    string private constant NAME = "SwarmCore";

    /// @dev The token symbol returned by `symbol()`.
    string private constant SYMBOL = "SWARMCORE";

    /// @notice The number of decimals returned by `decimals()`.
    uint8 public constant DECIMALS = 18;

    /// @notice The whole supply in minor units: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice A transfer tried to move more than `sender` holds.
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /// @notice The zero address cannot be a sender.
    error ERC20InvalidSender(address sender);

    /// @notice The zero address cannot be a receiver.
    error ERC20InvalidReceiver(address receiver);

    /// @notice `spender` tried to move more than its allowance.
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /// @notice The zero address cannot grant an allowance.
    error ERC20InvalidApprover(address approver);

    /// @notice The zero address cannot receive an allowance.
    error ERC20InvalidSpender(address spender);

    mapping(address account => uint256 balance) private _balances;

    mapping(address owner => mapping(address spender => uint256 value)) private _allowances;

    /// @notice Mints the whole supply to the deployer, once.
    constructor() {
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    /// @notice The token name.
    function name() external pure returns (string memory) {
        return NAME;
    }

    /// @notice The token symbol.
    function symbol() external pure returns (string memory) {
        return SYMBOL;
    }

    /// @notice The number of decimals the token uses.
    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    /// @notice The total supply, a compile-time constant: nothing mints or burns after the constructor.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @notice The balance of `account`.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice What `spender` may still move on behalf of `owner`.
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @notice Moves `value` tokens from the caller to `to`.
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to `value` outright.
    /// @dev To change a non-zero allowance safely, set it to zero first or approve exactly what the
    /// spender is expected to pull.
    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    /// @notice Moves `value` tokens from `from` to `to` using the caller's allowance.
    /// @dev An allowance of `type(uint256).max` is treated as unlimited and is not decreased.
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        unchecked {
            // The sum of all balances is always TOTAL_SUPPLY, so neither side can overflow.
            _balances[from] = fromBalance - value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value) internal {
        if (owner == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal {
        uint256 current = _allowances[owner][spender];
        if (current != type(uint256).max) {
            if (current < value) revert ERC20InsufficientAllowance(spender, current, value);
            unchecked {
                _allowances[owner][spender] = current - value;
            }
        }
    }
}
