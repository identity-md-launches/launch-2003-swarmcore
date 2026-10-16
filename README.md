# SwarmCore (SWARMCORE)

A fixed-supply ERC-20 token for the IdentityMD custom-token launch on Ethereum.

| Parameter | Value |
|-----------|-------|
| Solidity contract name | `SwarmCore` (`src/SwarmCore.sol`) |
| `name()` | `SwarmCore` |
| `symbol()` | `SWARMCORE` |
| `decimals()` | 18 |
| `totalSupply()` | 1,000,000,000 tokens = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Minted to | `msg.sender` of the constructor, once |
| Owner / admin | none |

## What the contract does

- The constructor mints the whole supply to `msg.sender` and emits one `Transfer(address(0), msg.sender, supply)`.
  Under the launch, `msg.sender` is the IdentityMD factory, which then pays the supply out
  (10% to the launch's MerkleDistributor, 80% to the pool seed, the remainder to the requester's address).
- `totalSupply()` returns a compile-time constant. There is no `mint`, no `burn`, no `burnFrom`, no owner,
  no pause, no blacklist, no fee on transfer and no upgrade path. After deployment nobody holds any
  privilege over the token or over any holder's balance.
- `transfer`, `approve` and `transferFrom` follow the ERC-20 standard and return `true`. Failures revert
  with OpenZeppelin-v5-style custom errors (`ERC20InsufficientBalance`, `ERC20InsufficientAllowance`,
  `ERC20InvalidReceiver`, `ERC20InvalidSpender`, `ERC20InvalidSender`, `ERC20InvalidApprover`).
- An allowance of `type(uint256).max` is unlimited and is not decreased by `transferFrom`.
- The contract has no `receive` or `fallback`, so it refuses ether and unknown calls.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, and no library is linked:
  every function is implemented in `src/SwarmCore.sol`.

## Assumptions

- The deployer is whoever runs the constructor. The launch factory deploys the token, so the factory
  receives the supply and distributes it; the contract does not know or care who that is.
- Ethereum mainnet (chain id 1), paired with IMD in the Uniswap v4 pool opened by the launch. The token
  itself has no chain-specific logic and no reference to the pool, the pair token or the factory.
- Transfers to and from the factory, the pool manager, the distributor and every other address move
  exactly the amount requested. No exemptions are needed because nothing is ever taxed or blocked.
- Standard ERC-20 approval semantics apply: `approve` overwrites the allowance, so a holder who changes a
  non-zero allowance should set it to zero first if a front-run matters to them.

## Deployment parameters

The launch is performed by IdentityMD's deployer through the factory; nothing in this repository
deploys, broadcasts or signs. The values the manifest step needs are:

- `token.contract`: `SwarmCore`
- `token.name`: `SwarmCore`
- `token.symbol`: `SWARMCORE`
- `token.decimals`: `18`
- `token.constructorArgs`: `[]`
- `token.totalSupply`: `1000000000000000000000000000`
- Application contracts: none.

Build settings in `foundry.toml`: `solc = "0.8.26"`, `evm_version = "cancun"`, optimizer on with 200
runs, `bytecode_hash = "none"`, no `ffi`, no filesystem permissions, no external libraries.

## Named constants

| Constant | Where | Value | Why |
|----------|-------|-------|-----|
| `DECIMALS` | `SwarmCore` | 18 | The brief's decimals. |
| `TOTAL_SUPPLY` | `SwarmCore` | `1_000_000_000 * 10 ** 18` | The brief's supply, minted once. |

No number in the brief was left open, so there is no other constant to choose.

## After launch

Nothing. The token has no owner-settable value, no setter and no admin function. There is no
address, feed, router or key the owner must configure, and no action the owner can take on the
contract after deployment.

## Operational responsibilities

- **Requester**: holds the remainder of the supply at the address given in the launch economics and is
  responsible for that wallet's keys. Losing them loses those tokens; nothing in the contract can
  recover or reissue them.
- **Holders**: manage their own allowances. The contract cannot revoke, freeze or claw back anything.
- **Nobody**: there is no pause, upgrade, mint or blacklist, so there is no incident response lever on
  the contract itself. This is by design for a fixed-supply launch token; it also means a bug could
  only be addressed by migrating to a new token, not by patching this one.
- **Explorer verification** of the deployed source is the deployer's step after launch, with the
  compiler settings above (`forge verify-contract`, solc 0.8.26, optimizer 200 runs, cancun).

## Layout

```
foundry.toml             compiler pins and build settings
src/SwarmCore.sol        the token
src/interfaces/IERC20.sol the ERC-20 interface it implements
test/SwarmCore.t.sol     success, failure, launch-flow, no-admin and fuzz tests
test/utils/Vm.sol        the Foundry cheatcodes the tests use (no forge-std needed)
test/utils/TestBase.sol  reverting assertions and a bound helper
```

The tests use no external library: `test/utils/Vm.sol` declares the cheatcode signatures the tests
call on Foundry's cheatcode address, so `forge build` and `forge test` run with no `lib/` directory
and no network.

## Checks

```
forge build
forge test
forge fmt --check
```

The fuzz tests take their seed from the environment when the verifier sets one
(`FOUNDRY_FUZZ_SEED`); they bound every input and discard nothing but the zero address, so they pass
for every seed.

## Security notes

Checked against the eth-security reference: no reentrancy surface (no external calls, no ether), no
decimals ambiguity (18, constant), no owner or pausable power to document as a trust assumption, no
unchecked arithmetic that can overflow (balances sum to a constant supply), no `delegatecall`,
`selfdestruct` or proxy. Tests passing are not an audit; an independent adversarial review before
release remains the launch policy's step.
