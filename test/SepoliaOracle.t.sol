// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {Registry} from "src/Registry.sol";
import {OracleAttestation} from "src/interfaces/IOracleConsumer.sol";

/// @dev Signature tests use Base's explicit test signer, never the production signer's key.
/// Exact production-address wiring is tested separately in SepoliaLaunchTest.
contract SepoliaOracleTest is Base {
    function setUp() public override {
        super.setUp();
        vm.chainId(11155111);
        vm.roll(11_926_289);
    }

    function test_mainnetEvidenceVerifiesInSepoliaDomainUnderColdCallbackBudget() public {
        mint(C1A1);
        uint16[2] memory ids = [uint16(701), 1301];
        for (uint256 i; i < ids.length; ++i) {
            bytes32 rid = ask(C1A1, ids[i]);
            OracleAttestation memory a = attestationFor(rid, word(1));
            assertEq(a.chainId, 1);
            assertTrue(a.requestId != rid, "oracle UUID and Intake id are distinct");
            bytes memory signature = sign(a);
            vm.cool(address(registry));
            assertTrue(deliver(rid, a, signature), "cold Sepolia callback fits 200,000 gas");
            (bytes32 stored, bytes32 oracleId, uint64 fromBlock, uint64 toBlock) = registry.verified(C1A1, ids[i]);
            assertEq(stored, rid);
            assertEq(oracleId, a.requestId);
            assertEq(fromBlock, a.fromBlock);
            assertEq(toBlock, a.toBlock);
            assertTrue(registry.hasTrait(C1A1, ids[i]));
            assertEq(registry.pendingOf(C1A1, ids[i]), bytes32(0));
        }
    }

    function test_mainnetDomainSignatureIsRejectedThenSepoliaRetrySucceeds() public {
        bytes32 rid = ask(C1A1, 1301);
        OracleAttestation memory a = attestationFor(rid, word(1));
        vm.chainId(1);
        bytes memory wrongDomainSignature = sign(a);
        vm.chainId(11155111);
        _miss(rid, a, wrongDomainSignature, 2);
        rid = ask(C1A1, 1301);
        a = attestationFor(rid, word(1));
        assertTrue(deliver(rid, a));
        assertTrue(registry.hasTrait(C1A1, 1301));
    }

    function test_sepoliaEvidenceChainIsRejectedEvenWithAValidSepoliaSignature() public {
        bytes32 rid = ask(C1A1, 1301);
        OracleAttestation memory a = attestationFor(rid, word(1));
        a.chainId = 11155111;
        _miss(rid, a, sign(a), 3);
    }

    function test_anotherConsumerDomainSignatureCannotAuthorizeTheRegistry() public {
        Registry otherConsumer = new Registry(
            CURATOR_ADDR,
            address(idmd),
            address(imd),
            address(intake),
            attester,
            address(renderer),
            address(composer),
            address(0)
        );
        bytes32 rid = ask(C1A1, 1301);
        OracleAttestation memory a = attestationFor(rid, word(1));
        // The same signer and evidence are insufficient when verifyingContract is another consumer.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTER_KEY, otherConsumer.attestationDigest(a));
        _miss(rid, a, abi.encodePacked(r, s, v), 2);
    }

    function test_noAnswerIsSettledWithoutIssuingACredentialOrRefundingTheSpentPrice() public {
        bytes32 rid = ask(C1A1, 1301);
        OracleAttestation memory a = attestationFor(rid, word(0));
        _miss(rid, a, sign(a), 8);
        assertEq(imd.balanceOf(address(intake)), PRICE);
        assertEq(registry.pool(), 0);
        assertEq(imd.balanceOf(C1A1), 0);
        bytes32 successor = ask(C1A1, 1301);
        assertTrue(successor != rid);
        bytes memory signature = sign(a);
        vm.prank(address(intake));
        registry.onResult(rid, a, signature);
        assertEq(registry.pendingOf(C1A1, 1301), successor);
    }

    function test_maximumSharedFactVerifiesOnSepoliaAndOnlyItsHeadCanApply() public {
        address[] memory list = new address[](64);
        for (uint256 i; i < list.length; ++i) {
            list[i] = address(uint160(100 + i));
        }
        list[31] = C1A1;
        list[32] = AC1A1;
        fund(C1A1, PRICE);
        vm.prank(C1A1);
        registry.requestSharedFact(1201, PRICE);
        bytes32 rid = intake.lastId();
        OracleAttestation memory a = attestationFor(rid, abi.encode(list));
        bytes memory signature = sign(a);
        vm.cool(address(registry));
        assertTrue(deliver(rid, a, signature));
        (bytes32 stored, bytes32 answerHash, uint16 count) = registry.sharedFact(1201);
        assertEq(stored, rid);
        assertEq(answerHash, keccak256(abi.encode(list)));
        assertEq(count, 64);
        vm.prank(C1A1);
        registry.applySharedFact(1201, list);
        vm.prank(AC1A1);
        vm.expectRevert(Registry.NotInList.selector);
        registry.applySharedFact(1201, list);
        assertTrue(registry.hasTrait(C1A1, 1201));
        assertFalse(registry.hasTrait(AC1A1, 1201));
    }

    function _miss(bytes32 rid, OracleAttestation memory a, bytes memory signature, uint8 reason) internal {
        vm.cool(address(registry));
        vm.expectEmit(false, false, false, true, address(registry));
        emit Registry.Missed(rid, 1301, reason);
        assertTrue(deliver(rid, a, signature), "miss completes within the stipend");
        assertFalse(registry.hasTrait(C1A1, 1301));
        assertEq(registry.pendingOf(C1A1, 1301), bytes32(0));
        (,, uint64 requestedAt,) = registry.pendingRequest(rid);
        assertEq(requestedAt, 0);
    }
}
