// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {MockERC20, FeeToken} from "./mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VestingVaultTest is Test {
    VestingVault vault;
    MockERC20 tok;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint64 T0 = 1_000_000;

    function setUp() public {
        vm.warp(T0);
        tok = new MockERC20();
        vault = new VestingVault(IERC20(address(tok)), owner);
        tok.mint(owner, 1e30);
        vm.prank(owner);
        tok.approve(address(vault), type(uint256).max);
    }

    function _create(address b, uint256 amt, uint64 cliff, uint64 dur, bool rev) internal returns (uint256) {
        vm.prank(owner);
        return vault.createSchedule(b, amt, T0, cliff, dur, rev);
    }

    // ---- constructor
    function test_ConstructorZeroToken() public {
        vm.expectRevert(VestingVault.ZeroAddress.selector);
        new VestingVault(IERC20(address(0)), owner);
    }

    function test_ConstructorZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new VestingVault(IERC20(address(tok)), address(0));
    }

    // ---- create
    function test_CreatePullsTokens() public {
        uint256 id = _create(alice, 1000, 100, 1000, true);
        assertEq(id, 0);
        assertEq(tok.balanceOf(address(vault)), 1000);
        assertEq(vault.totalAllocated(), 1000);
        VestingVault.Schedule memory s = vault.getSchedule(alice, 0);
        assertEq(s.total, 1000);
        assertEq(s.cliff, T0 + 100);
        assertTrue(s.revocable);
    }

    function test_MultipleSchedulesAndBeneficiaries() public {
        _create(alice, 1000, 0, 1000, false);
        assertEq(_create(alice, 500, 0, 500, false), 1);
        _create(bob, 300, 0, 300, true);
        assertEq(vault.scheduleCount(alice), 2);
        assertEq(vault.scheduleCount(bob), 1);
        assertEq(vault.totalAllocated(), 1800);
    }

    function test_CreateEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit VestingVault.ScheduleCreated(alice, 0, 1000, T0, T0 + 10, 100, false);
        _create(alice, 1000, 10, 100, false);
    }

    function test_RevertCreateNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.createSchedule(alice, 1, T0, 0, 1, false);
    }

    function test_RevertCreateZeroBeneficiary() public {
        vm.expectRevert(VestingVault.ZeroAddress.selector);
        _create(address(0), 1, 0, 1, false);
    }

    function test_RevertCreateZeroAmount() public {
        vm.expectRevert(VestingVault.ZeroAmount.selector);
        _create(alice, 0, 0, 1, false);
    }

    function test_RevertCreateTooLarge() public {
        vm.expectRevert(VestingVault.AmountTooLarge.selector);
        _create(alice, uint256(type(uint128).max) + 1, 0, 1, false);
    }

    function test_RevertCreateZeroDuration() public {
        vm.expectRevert(VestingVault.InvalidDuration.selector);
        _create(alice, 1, 0, 0, false);
    }

    function test_RevertCreateCliffTooLong() public {
        vm.expectRevert(VestingVault.CliffTooLong.selector);
        _create(alice, 1, 11, 10, false);
    }

    function test_RevertFeeOnTransferToken() public {
        FeeToken ft = new FeeToken();
        VestingVault v2 = new VestingVault(IERC20(address(ft)), owner);
        ft.mint(owner, 1e18);
        vm.startPrank(owner);
        ft.approve(address(v2), type(uint256).max);
        vm.expectRevert(VestingVault.FeeOnTransferNotSupported.selector);
        v2.createSchedule(alice, 1e18, T0, 0, 1, false);
        vm.stopPrank();
    }

    // ---- vesting math
    function test_NothingBeforeCliff() public {
        _create(alice, 1000, 100, 1000, false);
        vm.warp(T0 + 99);
        assertEq(vault.releasable(alice, 0), 0);
        vm.expectRevert(VestingVault.NothingToRelease.selector);
        vault.release(alice, 0);
    }

    function test_JumpAtCliff() public {
        _create(alice, 1000, 100, 1000, false);
        vm.warp(T0 + 100);
        assertEq(vault.releasable(alice, 0), 100);
    }

    function test_LinearMidway() public {
        _create(alice, 1000, 0, 1000, false);
        vm.warp(T0 + 500);
        vault.release(alice, 0);
        assertEq(tok.balanceOf(alice), 500);
        vm.warp(T0 + 750);
        vault.release(alice, 0);
        assertEq(tok.balanceOf(alice), 750);
    }

    function test_FullAfterEnd() public {
        _create(alice, 1000, 100, 1000, false);
        vm.warp(T0 + 5000);
        assertEq(vault.release(alice, 0), 1000);
        assertEq(vault.totalReleased(), 1000);
        vm.expectRevert(VestingVault.NothingToRelease.selector);
        vault.release(alice, 0);
    }

    function test_FutureStart() public {
        vm.prank(owner);
        vault.createSchedule(alice, 1000, T0 + 1000, 0, 1000, false);
        assertEq(vault.vestedAmount(alice, 0, T0 + 999), 0);
        assertEq(vault.vestedAmount(alice, 0, T0 + 1500), 500);
    }

    function test_ReleaseByThirdPartyGoesToBeneficiary() public {
        _create(alice, 1000, 0, 1000, false);
        vm.warp(T0 + 1000);
        vm.prank(bob);
        vault.release(alice, 0);
        assertEq(tok.balanceOf(alice), 1000);
        assertEq(tok.balanceOf(bob), 0);
    }

    function test_RevertUnknownSchedule() public {
        vm.expectRevert(VestingVault.UnknownSchedule.selector);
        vault.release(alice, 0);
        vm.expectRevert(VestingVault.UnknownSchedule.selector);
        vault.getSchedule(alice, 3);
    }

    // ---- revoke
    function test_RevokeSplitsVestedAndUnvested() public {
        _create(alice, 1000, 0, 1000, true);
        vm.warp(T0 + 300);
        uint256 ob = tok.balanceOf(owner);
        vm.prank(owner);
        vault.revoke(alice, 0);
        assertEq(tok.balanceOf(alice), 300);
        assertEq(tok.balanceOf(owner) - ob, 700);
        assertEq(tok.balanceOf(address(vault)), 0);
        assertEq(vault.totalAllocated(), 300);
        assertEq(vault.releasable(alice, 0), 0);
        vm.warp(T0 + 2000);
        assertEq(vault.releasable(alice, 0), 0);
    }

    function test_RevokeAfterPartialRelease() public {
        _create(alice, 1000, 0, 1000, true);
        vm.warp(T0 + 200);
        vault.release(alice, 0);
        vm.warp(T0 + 400);
        vm.prank(owner);
        vault.revoke(alice, 0);
        assertEq(tok.balanceOf(alice), 400);
        assertEq(tok.balanceOf(address(vault)), 0);
    }

    function test_RevokeBeforeCliffRefundsAll() public {
        _create(alice, 1000, 500, 1000, true);
        vm.warp(T0 + 100);
        vm.prank(owner);
        vault.revoke(alice, 0);
        assertEq(tok.balanceOf(alice), 0);
        assertEq(vault.totalAllocated(), 0);
    }

    function test_RevokeAfterFullyReleasedNoTransfers() public {
        _create(alice, 1000, 0, 1000, true);
        vm.warp(T0 + 1000);
        vault.release(alice, 0);
        vm.prank(owner);
        vault.revoke(alice, 0);
        assertEq(tok.balanceOf(alice), 1000);
    }

    function test_RevertRevokeNotRevocable() public {
        _create(alice, 1000, 0, 1000, false);
        vm.prank(owner);
        vm.expectRevert(VestingVault.NotRevocable.selector);
        vault.revoke(alice, 0);
    }

    function test_RevertRevokeTwice() public {
        _create(alice, 1000, 0, 1000, true);
        vm.startPrank(owner);
        vault.revoke(alice, 0);
        vm.expectRevert(VestingVault.AlreadyRevoked.selector);
        vault.revoke(alice, 0);
        vm.stopPrank();
    }

    function test_RevertRevokeNotOwner() public {
        _create(alice, 1000, 0, 1000, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.revoke(alice, 0);
    }

    function test_RevokeOneDoesNotAffectOthers() public {
        _create(alice, 1000, 0, 1000, true);
        _create(bob, 1000, 0, 1000, true);
        vm.warp(T0 + 500);
        vm.prank(owner);
        vault.revoke(alice, 0);
        vm.warp(T0 + 1000);
        vault.release(bob, 0);
        assertEq(tok.balanceOf(bob), 1000);
    }

    function test_OwnershipTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(bob);
        assertEq(vault.owner(), owner);
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob);
    }

    // ---- fuzz
    function testFuzz_VestedMonotonicAndBounded(uint128 amt, uint32 cliff, uint32 dur, uint32 t1, uint32 t2) public {
        amt = uint128(bound(amt, 1, 1e30));
        dur = uint32(bound(dur, 1, type(uint32).max));
        cliff = uint32(bound(cliff, 0, dur));
        _create(alice, amt, cliff, dur, false);
        (uint256 a, uint256 b) = t1 < t2 ? (uint256(t1), uint256(t2)) : (uint256(t2), uint256(t1));
        uint256 va = vault.vestedAmount(alice, 0, T0 + a);
        uint256 vb = vault.vestedAmount(alice, 0, T0 + b);
        assertLe(va, vb);
        assertLe(vb, amt);
        if (a < cliff) assertEq(va, 0);
        if (b >= dur) assertEq(vb, amt);
    }

    function testFuzz_RevokeConservesTokens(uint128 amt, uint32 dur, uint32 when) public {
        amt = uint128(bound(amt, 1, 1e30));
        dur = uint32(bound(dur, 1, 10 * 365 days));
        _create(alice, amt, 0, dur, true);
        vm.warp(T0 + uint256(when));
        uint256 ob = tok.balanceOf(owner);
        vm.prank(owner);
        vault.revoke(alice, 0);
        assertEq(tok.balanceOf(alice) + (tok.balanceOf(owner) - ob), amt);
        assertEq(tok.balanceOf(address(vault)), 0);
    }

    function testFuzz_ManyReleasesSumToTotal(uint128 amt, uint32 dur, uint8 steps) public {
        amt = uint128(bound(amt, 1, 1e30));
        dur = uint32(bound(dur, 1, 365 days));
        steps = uint8(bound(steps, 1, 20));
        _create(alice, amt, 0, dur, false);
        for (uint256 i = 1; i <= steps; i++) {
            vm.warp(T0 + (uint256(dur) * i) / steps);
            if (vault.releasable(alice, 0) > 0) vault.release(alice, 0);
        }
        assertEq(tok.balanceOf(alice), amt);
    }
}
