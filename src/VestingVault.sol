// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VestingVault
/// @author Kent
/// @notice Holds a single ERC20 token and releases it to multiple beneficiaries
///         on independent linear schedules with an optional cliff.
/// @dev Tokens are pulled from the owner when a schedule is created, so the vault
///      is always fully collateralised: balance >= totalAllocated - totalReleased.
///      Revocation (if allowed per schedule) settles the vested part to the
///      beneficiary and returns the unvested part to the owner.
contract VestingVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice A single vesting schedule.
    struct Schedule {
        uint128 total; // total tokens allocated
        uint128 released; // tokens already released
        uint64 start; // vesting start timestamp
        uint64 cliff; // absolute cliff timestamp (>= start)
        uint64 duration; // vesting duration in seconds (> 0)
        bool revocable; // owner may revoke
        bool revoked; // has been revoked
    }

    /// @notice The vested token.
    IERC20 public immutable token;

    /// @notice beneficiary => schedule id => schedule
    mapping(address => Schedule[]) private _schedules;

    /// @notice Sum of `total` (after revocation adjustment) over all schedules.
    uint256 public totalAllocated;
    /// @notice Sum of `released` over all schedules.
    uint256 public totalReleased;

    event ScheduleCreated(
        address indexed beneficiary,
        uint256 indexed id,
        uint256 total,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable
    );
    event Released(address indexed beneficiary, uint256 indexed id, uint256 amount);
    event Revoked(address indexed beneficiary, uint256 indexed id, uint256 vestedPaid, uint256 refunded);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidDuration();
    error CliffTooLong();
    error AmountTooLarge();
    error UnknownSchedule();
    error NotRevocable();
    error AlreadyRevoked();
    error NothingToRelease();
    error FeeOnTransferNotSupported();

    /// @param token_ ERC20 token to vest.
    /// @param owner_ Admin who funds and may revoke schedules.
    constructor(IERC20 token_, address owner_) Ownable(owner_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    // ---------------------------------------------------------------- admin

    /// @notice Create a schedule and pull `total` tokens from the owner.
    /// @param beneficiary Recipient of vested tokens.
    /// @param total Amount to vest.
    /// @param start Vesting start timestamp (may be in the past or future).
    /// @param cliffDuration Seconds after `start` before anything vests.
    /// @param duration Total vesting length in seconds, measured from `start`.
    /// @param revocable Whether the owner may later revoke the unvested part.
    /// @return id Index of the new schedule for this beneficiary.
    function createSchedule(
        address beneficiary,
        uint256 total,
        uint64 start,
        uint64 cliffDuration,
        uint64 duration,
        bool revocable
    ) external onlyOwner nonReentrant returns (uint256 id) {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (total == 0) revert ZeroAmount();
        if (total > type(uint128).max) revert AmountTooLarge();
        if (duration == 0) revert InvalidDuration();
        if (cliffDuration > duration) revert CliffTooLong();

        id = _schedules[beneficiary].length;
        uint64 cliff = start + cliffDuration;
        _schedules[beneficiary].push(Schedule(uint128(total), 0, start, cliff, duration, revocable, false));
        totalAllocated += total;

        // Measure actual received amount to reject fee-on-transfer tokens.
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), total);
        if (token.balanceOf(address(this)) - before != total) revert FeeOnTransferNotSupported();

        emit ScheduleCreated(beneficiary, id, total, start, cliff, duration, revocable);
    }

    /// @notice Revoke a schedule: pay out what has vested, refund the rest to the owner.
    function revoke(address beneficiary, uint256 id) external onlyOwner nonReentrant {
        Schedule storage s = _get(beneficiary, id);
        if (!s.revocable) revert NotRevocable();
        if (s.revoked) revert AlreadyRevoked();

        uint256 vested = _vested(s, block.timestamp);
        uint256 payout = vested - s.released;
        uint256 refund = uint256(s.total) - vested;

        s.revoked = true;
        s.total = uint128(vested);
        s.released = uint128(vested);
        totalAllocated -= refund;
        totalReleased += payout;

        if (payout > 0) token.safeTransfer(beneficiary, payout);
        if (refund > 0) token.safeTransfer(owner(), refund);
        emit Revoked(beneficiary, id, payout, refund);
    }

    // ------------------------------------------------------------ beneficiary

    /// @notice Release all currently vested tokens of one schedule to its beneficiary.
    /// @dev Callable by anyone; tokens always go to the beneficiary.
    function release(address beneficiary, uint256 id) external nonReentrant returns (uint256 amount) {
        Schedule storage s = _get(beneficiary, id);
        amount = _vested(s, block.timestamp) - s.released;
        if (amount == 0) revert NothingToRelease();
        s.released += uint128(amount);
        totalReleased += amount;
        token.safeTransfer(beneficiary, amount);
        emit Released(beneficiary, id, amount);
    }

    // ------------------------------------------------------------------ views

    /// @notice Number of schedules for `beneficiary`.
    function scheduleCount(address beneficiary) external view returns (uint256) {
        return _schedules[beneficiary].length;
    }

    /// @notice Full schedule data.
    function getSchedule(address beneficiary, uint256 id) external view returns (Schedule memory) {
        return _get(beneficiary, id);
    }

    /// @notice Amount vested at timestamp `t` (including already released).
    function vestedAmount(address beneficiary, uint256 id, uint256 t) external view returns (uint256) {
        return _vested(_get(beneficiary, id), t);
    }

    /// @notice Amount releasable right now.
    function releasable(address beneficiary, uint256 id) external view returns (uint256) {
        Schedule storage s = _get(beneficiary, id);
        return _vested(s, block.timestamp) - s.released;
    }

    // --------------------------------------------------------------- internal

    function _get(address beneficiary, uint256 id) internal view returns (Schedule storage) {
        if (id >= _schedules[beneficiary].length) revert UnknownSchedule();
        return _schedules[beneficiary][id];
    }

    /// @dev Linear vesting from `start`, nothing before `cliff`, everything after `start + duration`.
    function _vested(Schedule storage s, uint256 t) internal view returns (uint256) {
        if (s.revoked) return s.total;
        if (t < s.cliff) return 0;
        uint256 end = uint256(s.start) + s.duration;
        if (t >= end) return s.total;
        return (uint256(s.total) * (t - s.start)) / s.duration;
    }
}
