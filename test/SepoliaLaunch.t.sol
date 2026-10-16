// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SepoliaFixture} from "./helpers/SepoliaFixture.sol";
import {Registry} from "src/Registry.sol";
import {OracleAttestation} from "src/interfaces/IOracleConsumer.sol";
import {NonpayableBurnClaimant, ReentrantBurnClaimant} from "./mocks/MockBurnExecutor.sol";

contract SepoliaLaunchTest is SepoliaFixture {
    address internal alice;
    address internal bob;

    function setUp() public override {
        super.setUp();
        alice = makeAddr("Sepolia claimant");
        bob = makeAddr("Sepolia second claimant");
        _member(alice, 7);
        _fund(bob, 10 ether);
        vm.prank(bob);
        registry.sponsor(10 ether);
        vm.deal(alice, 1 ether);
    }

    function test_launchUsesExactArgumentsAndCreatesOnlyThreeApplications() public view {
        assertEq(block.chainid, SEPOLIA);
        assertEq(applications.length, 3);
        assertEq(vm.getNonce(address(factory)), 4);
        for (uint256 i; i < 3; ++i) {
            assertEq(vm.getNonce(applications[i]), 1, "no constructor-created children");
            assertGt(applications[i].code.length, 0);
            assertLe(applications[i].code.length, 24_576);
            assertEq(applications[i].balance, 0);
        }
        assertEq(address(registry.renderer()), applications[0]);
        assertEq(address(registry.composer()), applications[1]);
        assertEq(address(registry.curator()), CURATOR);
        assertEq(address(registry.idmd()), IDMD);
        assertEq(address(registry.imd()), IMD);
        assertEq(address(registry.intake()), INTAKE);
        assertEq(registry.attester(), ATTESTER);
        assertEq(address(registry.burnExecutor()), EXECUTOR);
        assertEq(registry.name(), "Sworn");
        assertEq(registry.symbol(), "SWORN");
        assertEq(registry.ACTION(), bytes32("oracle.request@oracle-1"));
        assertEq(intake.nonce(), 0, "deployment creates no oracle request");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_badLiveDependencyRollsBackTheWholeLaunch(uint8 which) public {
        which %= 4;
        address[6] memory deps = _dependencies();
        deps[which] = makeAddr("mistyped launch dependency");
        bytes memory error = which == 1
            ? abi.encodeWithSelector(Registry.DependencyHasNoCode.selector)
            : which == 2 ? abi.encodeWithSignature("Error(string)", "Intake price") : bytes("");
        _rejectLaunch(deps, error);
    }

    function test_unsettledCuratorZeroPriceAndMissingExecutorEachRollBackLaunch() public {
        vm.mockCall(CURATOR, abi.encodeWithSignature("isSettled()"), abi.encode(false));
        _rejectLaunch(_dependencies(), abi.encodeWithSignature("Error(string)", "Curator not settled"));
        vm.clearMockedCalls();
        intake.setPrice(0);
        _rejectLaunch(_dependencies(), abi.encodeWithSignature("Error(string)", "Intake price"));
        intake.setPrice(PRICE);
        vm.etch(EXECUTOR, bytes(""));
        _rejectLaunch(_dependencies(), abi.encodeWithSelector(Registry.ExecutorHasNoCode.selector));
    }

    function _rejectLaunch(address[6] memory deps, bytes memory error) internal {
        (bytes[] memory codes, bytes32[] memory salts, address[] memory predicted) =
            _launchCodes(bytes32("rejected"), deps);
        uint64 nonce = vm.getNonce(address(factory));
        vm.expectRevert(error);
        factory.deployAll(codes, salts);
        assertEq(vm.getNonce(address(factory)), nonce, "rejected constructor rolls back helper deployments");
        for (uint256 i; i < 3; ++i) {
            assertEq(predicted[i].code.length, 0);
        }
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_v1MissingPreviewRefundsTheWholeAttachment(bool throughIdmd, uint96 attachment) public {
        uint256 value = bound(attachment, 0, 1 ether);
        // Check the actual missing-selector condition, rather than a configurable mock revert.
        (bool preview,) = EXECUTOR.staticcall(abi.encodeWithSignature("previewBridge()"));
        assertFalse(preview);
        assertGt(EXECUTOR.code.length, 0);
        vm.expectEmit(true, false, false, true, address(registry));
        emit Registry.BurnSkipped(alice, 1);
        _claim(alice, throughIdmd, 701, value);
        assertEq(alice.balance, 1 ether, "attachment returned in full");
        assertEq(address(registry).balance, 0);
        assertEq(EXECUTOR.balance, 0);
        assertEq(executor.calls(), 0);
        assertEq(registry.pool(), 10 ether - PRICE);
        assertEq(imd.balanceOf(INTAKE), PRICE);
        assertEq(intake.nonce(), 1);
        assertEq(registry.idmdSponsored(7), throughIdmd ? 1 : 0);
        assertEq(registry.lastPoolDay(alice), START / 1 days);
        assertTrue(registry.poolUsed(alice, 701));
        bytes32 rid = registry.pendingOf(alice, 701);
        assertTrue(rid != bytes32(0));
        (address payer, address target, bytes4 selector, bytes4 failure,, bool completed) = intake.requests(rid);
        assertEq(payer, address(registry));
        assertEq(target, address(registry));
        assertEq(selector, registry.onResult.selector);
        assertEq(failure, registry.onFailure.selector);
        assertFalse(completed);
        string memory body = string(intake.bodyOf(rid));
        assertEq(vm.parseJsonUint(body, ".chainId"), 1);
        assertEq(vm.parseJsonUint(body, ".consumer.chainId"), SEPOLIA);
        assertEq(vm.parseJsonAddress(body, ".consumer.verifyingContract"), address(registry));
    }

    function test_v1MissingPreviewWorksAtZeroAndOneWeiForBothEntryPoints() public {
        for (uint256 i; i < 4; ++i) {
            address who = address(uint160(uint256(keccak256(abi.encode("refund boundary", i)))));
            _member(who, 7);
            vm.deal(who, 1);
            _claim(who, i % 2 == 1, 701, i / 2);
            assertEq(who.balance, 1);
        }
        assertEq(address(registry).balance, 0);
        assertEq(executor.calls(), 0);
        assertEq(registry.pool(), 10 ether - 4 * PRICE);
    }

    function test_rejectedV1RefundRollsBackPaymentRequestAndAllowances() public {
        NonpayableBurnClaimant rejecting = new NonpayableBurnClaimant();
        _member(address(rejecting), 7);
        vm.deal(address(rejecting), 1);
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(Registry.BurnRefundFailed.selector);
            rejecting.claim(registry, i == 1, 701, 1);
            assertEq(registry.pool(), 10 ether);
            assertEq(imd.balanceOf(INTAKE), 0);
            assertEq(imd.allowance(address(registry), INTAKE), 0);
            assertEq(intake.nonce(), 0);
            assertEq(registry.idmdSponsored(7), 0);
            assertEq(registry.lastPoolDay(address(rejecting)), 0);
            assertFalse(registry.poolUsed(address(rejecting), 701));
            assertEq(registry.pendingOf(address(rejecting), 701), bytes32(0));
            assertEq(address(rejecting).balance, 1);
        }
        // The same contract is usable when there is no refund to receive.
        rejecting.claim(registry, true, 701, 0);
        assertEq(registry.pool(), 10 ether - PRICE);
    }

    function test_v1RefundCannotReenterTheOtherSponsoredPath() public {
        ReentrantBurnClaimant claimant = new ReentrantBurnClaimant();
        _member(address(claimant), 7);
        claimant.arm(registry);
        vm.deal(address(claimant), 1);
        claimant.claim(registry, true, 701, 1);
        assertEq(claimant.refunds(), 1);
        assertFalse(claimant.reentrySucceeded());
        assertEq(claimant.reentryError(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        assertEq(intake.nonce(), 1);
        assertFalse(registry.poolUsed(address(claimant), 801));
        assertEq(address(claimant).balance, 1);
        assertEq(address(registry).balance, 0);
    }

    function test_livePriceChangesAreRespectedAndDisabledSaleIsAtomic() public {
        intake.setPrice(PRICE + 1);
        _fund(alice, PRICE + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Registry.PriceAboveMax.selector, PRICE + 1, PRICE));
        registry.upgrade(_one(701), PRICE);
        assertEq(imd.balanceOf(alice), PRICE + 1);
        assertEq(intake.nonce(), 0);
        vm.prank(alice);
        registry.upgrade(_one(701), PRICE + 1);
        assertEq(imd.balanceOf(alice), 0);
        assertEq(registry.pool(), 10 ether, "claimant-paid request does not consume pool funds");
        assertEq(imd.balanceOf(INTAKE), PRICE + 1);
        intake.setPrice(0);
        vm.prank(alice);
        vm.expectRevert(bytes("ActionNotSold"));
        registry.claimSponsored{value: 1}(801);
        assertEq(alice.balance, 1 ether);
        assertEq(registry.lastPoolDay(alice), 0);
        assertFalse(registry.poolUsed(alice, 801));
        assertEq(registry.pool(), 10 ether);
        intake.setPrice(1);
        _claim(alice, false, 801, 1);
        assertEq(registry.pool(), 10 ether - 1);
        assertEq(imd.balanceOf(INTAKE), PRICE + 2);
        assertEq(imd.allowance(address(registry), INTAKE), 0);
    }

    function test_personalAndSharedAbandonmentAtTheExactDeadline() public {
        bytes32 personal = _ask(alice, 1301);
        _fund(bob, PRICE);
        vm.prank(bob);
        registry.requestSharedFact(1201, PRICE);
        bytes32 shared = registry.sharedPending(1201);
        vm.warp(START + 14 days - 1);
        vm.prank(alice);
        vm.expectRevert(Registry.TooEarly.selector);
        registry.abandon(personal);
        vm.prank(bob);
        vm.expectRevert(Registry.TooEarly.selector);
        registry.abandon(shared);
        vm.warp(START + 14 days);
        vm.prank(bob);
        vm.expectRevert(Registry.NotClaimant.selector);
        registry.abandon(personal);
        vm.prank(alice);
        registry.abandon(personal);
        // Alice did not pay for the shared fact; shared cleanup is nevertheless public.
        vm.prank(alice);
        registry.abandon(shared);
        assertEq(registry.pendingOf(alice, 1301), bytes32(0));
        assertEq(registry.sharedPending(1201), bytes32(0));
        assertEq(imd.balanceOf(INTAKE), 2 * PRICE, "already-spent oracle fees are not refundable");
        assertEq(registry.pool(), 10 ether);
        bytes32 successor = _ask(alice, 1301);
        _fund(bob, PRICE);
        vm.prank(bob);
        registry.requestSharedFact(1201, PRICE);
        bytes32 nextShared = registry.sharedPending(1201);
        // An old completion is harmless even after the pair/fact has a successor.
        assertTrue(intake.complete(personal, 1, _failureArgs(personal, 1)));
        assertTrue(intake.complete(shared, 2, _failureArgs(shared, 2)));
        assertEq(registry.pendingOf(alice, 1301), successor);
        assertEq(registry.sharedPending(1201), nextShared);
        assertFalse(registry.hasTrait(alice, 1301));
    }

    function test_fixedAttesterAndIntakeCannotBeBypassedOrReconfigured() public {
        bytes32 rid = _ask(alice, 1301);
        OracleAttestation memory a;
        a.chainId = 1;
        a.answerType = 0;
        a.answer = abi.encode(true);
        vm.prank(alice);
        vm.expectRevert(Registry.NotIntake.selector);
        registry.onResult(rid, a, bytes(""));
        vm.prank(alice);
        vm.expectRevert(Registry.NotIntake.selector);
        registry.onFailure(rid, 1, bytes32("body_invalid"), 0, 0, bytes(""));
        assertEq(registry.pendingOf(alice, 1301), rid);
        bytes4[7] memory selectors = [
            bytes4(keccak256("setAttester(address)")),
            bytes4(keccak256("setIntake(address)")),
            bytes4(keccak256("setImd(address)")),
            bytes4(keccak256("setBurnExecutor(address)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("setAction(bytes32)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            vm.prank(address(factory));
            (bool ok,) = address(registry).call(abi.encodeWithSelector(selectors[i], bob));
            assertFalse(ok, "no factory administration");
        }
        vm.expectEmit(false, false, false, true, address(registry));
        emit Registry.Missed(rid, 1301, 2);
        assertTrue(intake.complete(rid, 0, abi.encode(rid, a, bytes(""))));
        assertEq(registry.pendingOf(alice, 1301), bytes32(0));
        assertFalse(registry.hasTrait(alice, 1301));
        assertEq(registry.attester(), ATTESTER);
        assertEq(address(registry.intake()), INTAKE);
        assertEq(address(registry.imd()), IMD);
        assertEq(address(registry.burnExecutor()), EXECUTOR);
        assertEq(registry.ACTION(), bytes32("oracle.request@oracle-1"));
    }

    function _failureArgs(bytes32 rid, uint8 status) internal pure returns (bytes memory) {
        return abi.encode(rid, status, bytes32("body_invalid"), uint16(0), uint16(0), bytes(""));
    }
}
