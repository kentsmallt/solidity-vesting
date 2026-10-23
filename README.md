# VestingVault

[![test](https://github.com/kentsmallt/solidity-vesting/actions/workflows/test.yml/badge.svg)](https://github.com/kentsmallt/solidity-vesting/actions/workflows/test.yml)

A small, production-style ERC20 **token vesting vault** written in Solidity 0.8.24 with OpenZeppelin v5 and tested with Foundry.

- Linear vesting with an optional **cliff**
- **Multiple beneficiaries**, each with any number of independent schedules
- Per-schedule **revocable** flag: the owner can revoke, the vested part is paid out, the unvested part is refunded
- Fully collateralised: tokens are pulled in at schedule creation, never minted or promised
- 100% line / statement / branch / function coverage, fuzz and invariant tests

> Educational / portfolio project. Not audited. Not deployed anywhere.

## Design

```
vested(t) = 0                                   if t < cliff
          = total                               if t >= start + duration
          = total * (t - start) / duration      otherwise
releasable = vested(now) - released
```

| Function | Who | What |
|---|---|---|
| `createSchedule(beneficiary, total, start, cliffDuration, duration, revocable)` | owner | Pulls `total` tokens from the owner and stores a schedule |
| `release(beneficiary, id)` | anyone | Sends the releasable amount **to the beneficiary** (keeper-friendly) |
| `revoke(beneficiary, id)` | owner | Pays vested-but-unreleased to the beneficiary, refunds unvested to the owner |
| `vestedAmount / releasable / getSchedule / scheduleCount` | view | Read helpers |

Storage packs each schedule into two slots (`uint128` amounts, `uint64` timestamps). After revocation, `total` is shrunk to the vested amount so accounting stays exact: `balance == totalAllocated - totalReleased`.

## Security considerations

- **Checks-effects-interactions** + `ReentrancyGuard` on every state-changing function.
- **SafeERC20** for tokens that do not return `bool`.
- **Fee-on-transfer / deflationary tokens are rejected** at creation (received amount is measured), because they would break solvency.
- **Rebasing tokens are not supported.**
- **Ownable2Step**: ownership transfer requires acceptance, avoiding typo'd owners.
- `release` is permissionless but can only pay the beneficiary, so a third party can never redirect funds.
- Non-revocable schedules are a hard guarantee for the beneficiary; the owner has no escape hatch.
- Rounding is floor-division in favour of the vault; the final second always releases the remainder exactly.
- Known trust assumption: the owner of a *revocable* schedule can cancel the unvested part at any time — this is by design.

## How to test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone https://github.com/kentsmallt/solidity-vesting && cd solidity-vesting
forge install --no-git foundry-rs/forge-std
forge install --no-git OpenZeppelin/openzeppelin-contracts@v5.1.0
forge test -vv
forge coverage --no-match-coverage "test|script"
```

`lib/` is git-ignored; the commands above fetch dependencies (CI does the same).

### Test suite (32 tests)

- **Unit + revert (28):** creation, events, multi-schedule, cliff boundary, linear midpoint, end of vesting, future start, third-party release, revoke before/after cliff, after partial/full release, isolation between beneficiaries, two-step ownership
- **Reverts:** non-owner, zero address, zero amount, `uint128` overflow, zero duration, cliff > duration, unknown schedule, nothing to release, non-revocable, double revoke, fee-on-transfer token
- **Fuzz (3 × 1,000 runs):** vested amount is monotonic and bounded; revoke conserves tokens; many partial releases sum exactly to `total`
- **Invariant (128 runs × 64 calls):** random create / release / revoke / warp sequences keep
  - vault balance `== totalAllocated - totalReleased` (solvency)
  - deposits `==` paid to users `+` refunds `+` held (conservation)
  - `totalReleased <= totalAllocated`

### Coverage (measured with `forge coverage`, Foundry 1.8.6)

| File | % Lines | % Statements | % Branches | % Funcs |
|---|---|---|---|---|
| src/VestingVault.sol | 100.00% (58/58) | 100.00% (78/78) | 100.00% (16/16) | 100.00% (10/10) |

## Layout

```
src/VestingVault.sol              contract
test/VestingVault.t.sol           unit + fuzz tests
test/VestingVault.invariant.t.sol handler-based invariant tests
test/mocks/MockERC20.sol          mock + fee-on-transfer token
.github/workflows/test.yml        CI
```

## License

MIT © Kent
