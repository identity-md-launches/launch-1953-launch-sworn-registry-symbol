// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {Registry} from "src/Registry.sol";
import {Composer} from "src/Composer.sol";
import {Spec} from "src/Types.sol";
import {OracleAttestation} from "src/interfaces/IOracleConsumer.sol";

/// @notice Signed answers for community specs registered on Sepolia (chain 11155111) with the game's mainnet
///         windows, which the revised guard now accepts there. Signatures use Base's explicit test signer in
///         the Sepolia consumer domain; the evidence chain of every attestation stays mainnet.
contract SepoliaCommunityOracleTest is Base {
    address internal bob = address(0xB0B);

    function setUp() public override {
        super.setUp();
        vm.chainId(11155111);
        vm.roll(11_926_289);
        assertLt(block.number, B_DEPLOY, "Sepolia is below the mainnet game window");
    }

    function test_communityNonceSpecVerifiesInTheSepoliaDomainUnderTheStipend() public {
        uint16 id = register(C1A1, _nonceSpec(B_DEPLOY));
        assertEq(id, 10001);
        mint(C1A1);
        bytes32 rid = ask(C1A1, id);
        OracleAttestation memory a = attestationFor(rid, word(1));
        assertEq(a.chainId, 1);
        assertEq(a.fromBlock, B_DEPLOY);
        assertEq(a.toBlock, B_DEPLOY);
        assertEq(a.panelSize, 11, "T5 is a panel question");
        vm.cool(address(registry));
        assertTrue(deliver(rid, a), "cold community callback fits 200,000 gas");
        assertTrue(registry.hasTrait(C1A1, id));
        uint16[] memory specs = registry.verifiedSpecsOf(C1A1);
        assertEq(specs.length, 1);
        assertEq(specs[0], id);
        assertEq(registry.pendingOf(C1A1, id), bytes32(0));
        // Verified once: a second request for the same pair is refused.
        fund(C1A1, PRICE);
        uint16[] memory ids = new uint16[](1);
        ids[0] = id;
        vm.prank(C1A1);
        vm.expectRevert(abi.encodeWithSelector(Registry.AlreadyVerified.selector, C1A1, id));
        registry.upgrade(ids, PRICE);
    }

    function test_communityLogCountSpecMissesBelowThresholdOnWrongWindowAndOnWrongQuestion() public {
        uint16 id = register(C1A1, _gameSpec());
        // Below the threshold: a signed, well-formed "1" against a threshold of 2.
        bytes32 rid = ask(C1A1, id);
        _miss(rid, id, attestationFor(rid, word(1)), 8);
        // The spec's window is the rule: an answer over a window one block longer is reason 6.
        rid = ask(C1A1, id);
        OracleAttestation memory a = attestationFor(rid, word(2));
        a.toBlock += 1;
        _miss(rid, id, a, 6);
        // Another claimant's question, correctly signed, cannot settle this pair: reason 10.
        rid = ask(C1A1, id);
        a = attestationFor(rid, word(2));
        (, a.questionHash) = registry.composeBody(id, bob);
        _miss(rid, id, a, 10);
        // Sepolia evidence is refused even in the Sepolia domain: reason 3.
        rid = ask(C1A1, id);
        a = attestationFor(rid, word(2));
        a.chainId = 11155111;
        _miss(rid, id, a, 3);
        // At the threshold, the honest answer verifies.
        rid = ask(C1A1, id);
        assertTrue(deliver(rid, attestationFor(rid, word(2))));
        assertTrue(registry.hasTrait(C1A1, id));
        assertEq(imd.balanceOf(address(intake)), 5 * PRICE, "every attempt was paid; misses refund nothing");
    }

    function test_communitySharedFactVerifiesOnSepoliaAndAppliesWithinItsHead() public {
        Spec memory s = _gameSpec();
        s.kind = 3;
        s.sumArg = "amount";
        s.threshold = 2;
        s.name = "Top two depositors";
        uint16 id = register(C1A1, s);
        fund(bob, PRICE);
        vm.prank(bob);
        registry.requestSharedFact(id, PRICE);
        bytes32 rid = intake.lastId();
        address[] memory list = new address[](5);
        list[0] = address(0x9001);
        list[1] = C1A1;
        list[2] = bob;
        list[3] = address(0x9004);
        list[4] = address(0x9005);
        OracleAttestation memory a = attestationFor(rid, abi.encode(list));
        assertEq(a.answerType, 4);
        vm.cool(address(registry));
        assertTrue(deliver(rid, a));
        (bytes32 stored, bytes32 answerHash, uint16 count) = registry.sharedFact(id);
        assertEq(stored, rid);
        assertEq(answerHash, keccak256(abi.encode(list)));
        assertEq(count, 5);
        vm.prank(C1A1);
        registry.applySharedFact(id, list);
        assertTrue(registry.hasTrait(C1A1, id));
        // Bob paid for the fact but is third in a head of two.
        vm.prank(bob);
        vm.expectRevert(Registry.NotInList.selector);
        registry.applySharedFact(id, list);
        assertFalse(registry.hasTrait(bob, id));
        // The fact is stored once; a second request for it is refused.
        fund(bob, PRICE);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Registry.FactAlreadyStored.selector, id));
        registry.requestSharedFact(id, PRICE);
    }

    function test_sepoliaRegistrationNeverChangesTheMainnetRegistrysBehaviour() public {
        // The same contracts on chain 1 at the recorded mainnet height still refuse a window that
        // mainnet has not mined, whatever the slot clock says.
        vm.chainId(1);
        vm.roll(26_200_000);
        assertGt(composer.mainnetHeightBound(), block.number);
        Spec memory s = _gameSpec();
        s.toBlock = 26_200_000;
        s.fromBlock = s.toBlock - 7199;
        fund(C1A1, registry.SPEC_FEE());
        vm.prank(C1A1);
        vm.expectRevert(abi.encodeWithSelector(Composer.BadSpec.selector, "window"));
        registry.registerSpec(s);
        vm.chainId(11155111);
        vm.prank(C1A1);
        assertEq(registry.registerSpec(s), 10001, "on Sepolia the slot clock is the only bound");
    }

    function _miss(bytes32 rid, uint16 id, OracleAttestation memory a, uint8 reason) internal {
        vm.cool(address(registry));
        vm.expectEmit(false, false, false, true, address(registry));
        emit Registry.Missed(rid, id, reason);
        assertTrue(deliver(rid, a), "miss completes within the stipend");
        assertFalse(registry.hasTrait(C1A1, id));
        assertEq(registry.pendingOf(C1A1, id), bytes32(0));
    }

    function _gameSpec() internal view returns (Spec memory s) {
        s.kind = 1;
        s.target = composer.MAINNET_CURATOR();
        s.item = composer.DEPOSITED();
        s.arg = "contributor";
        s.threshold = 2;
        s.fromBlock = B_DEPLOY;
        s.toBlock = B_END;
        s.name = "Two deposits";
    }

    function _nonceSpec(uint64 at) internal pure returns (Spec memory s) {
        s.kind = 5;
        s.threshold = 20;
        s.fromBlock = at;
        s.toBlock = at;
        s.name = "Pretrained twin";
    }
}
