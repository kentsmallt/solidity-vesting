// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Drives random create / release / revoke / warp sequences.
contract Handler is Test {
    VestingVault public vault;
    MockERC20 public tok;
    address public owner;
    address[3] public users;
    uint256 public ghostDeposited;
    uint256 public ghostRefunded;

    constructor(VestingVault v, MockERC20 t, address o) {
        vault = v;
        tok = t;
        owner = o;
        users = [makeAddr("u0"), makeAddr("u1"), makeAddr("u2")];
    }

    function create(uint256 u, uint128 amt, uint32 cliff, uint32 dur, bool rev) external {
        amt = uint128(bound(amt, 1, 1e24));
        dur = uint32(bound(dur, 1, 4 * 365 days));
        cliff = uint32(bound(cliff, 0, dur));
        tok.mint(owner, amt);
        vm.prank(owner);
        vault.createSchedule(users[u % 3], amt, uint64(block.timestamp), cliff, dur, rev);
        ghostDeposited += amt;
    }

    function release(uint256 u, uint256 id) external {
        address b = users[u % 3];
        uint256 n = vault.scheduleCount(b);
        if (n == 0) return;
        id %= n;
        if (vault.releasable(b, id) == 0) return;
        vault.release(b, id);
    }

    function revoke(uint256 u, uint256 id) external {
        address b = users[u % 3];
        uint256 n = vault.scheduleCount(b);
        if (n == 0) return;
        id %= n;
        VestingVault.Schedule memory s = vault.getSchedule(b, id);
        if (!s.revocable || s.revoked) return;
        uint256 before = tok.balanceOf(owner);
        vm.prank(owner);
        vault.revoke(b, id);
        ghostRefunded += tok.balanceOf(owner) - before;
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 90 days));
    }

    function userBalances() external view returns (uint256 s) {
        for (uint256 i; i < 3; i++) {
            s += tok.balanceOf(users[i]);
        }
    }
}

contract VestingVaultInvariantTest is Test {
    VestingVault vault;
    MockERC20 tok;
    Handler h;
    address owner = makeAddr("owner");

    function setUp() public {
        tok = new MockERC20();
        vault = new VestingVault(IERC20(address(tok)), owner);
        h = new Handler(vault, tok, owner);
        vm.prank(owner);
        tok.approve(address(vault), type(uint256).max);
        targetContract(address(h));
    }

    /// Vault always holds exactly what is still owed.
    function invariant_Solvent() public view {
        assertEq(tok.balanceOf(address(vault)), vault.totalAllocated() - vault.totalReleased());
    }

    /// No tokens created or lost: deposits = paid to users + refunds + still held.
    function invariant_Conservation() public view {
        assertEq(h.ghostDeposited(), h.userBalances() + h.ghostRefunded() + tok.balanceOf(address(vault)));
    }

    function invariant_ReleasedLeAllocated() public view {
        assertLe(vault.totalReleased(), vault.totalAllocated());
    }
}
