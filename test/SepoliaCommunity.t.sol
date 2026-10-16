// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SepoliaFixture} from "./helpers/SepoliaFixture.sol";
import {Registry} from "src/Registry.sol";
import {Composer} from "src/Composer.sol";
import {Spec} from "src/Types.sol";
import {OracleAttestation} from "src/interfaces/IOracleConsumer.sol";

/// @notice The revised Composer through the real Sepolia launch (exact arguments, one factory call):
///         every question is about mainnet, so the catalog questions name the mainnet Curator and the
///         community-spec window guard follows the mainnet height bound, never Sepolia's own height.
///         Unsigned paths only; signed community answers are in SepoliaCommunityOracleTest below.
contract SepoliaCommunityLaunchTest is SepoliaFixture {
    uint256 internal constant MERGE_BLOCK = 15_537_395;
    uint256 internal constant MERGE_TIME = 1_663_224_191;
    uint64 internal constant B_DEPLOY = 0x189378e;
    uint64 internal constant B_END = 0x18984a4;
    address internal constant C1A1 = 0x000000000000000000000000000000000000C1a1;

    string[7] internal CATALOG_NAMES = [
        "701-still-here",
        "801-last-stand",
        "1001-hour-savior",
        "1102-ordinal-1000",
        "1105-first-thousand",
        "1201-top-32",
        "1301-not-born-yesterday"
    ];
    uint16[7] internal CATALOG_IDS = [701, 801, 1001, 1102, 1105, 1201, 1301];

    address internal alice;

    function setUp() public override {
        super.setUp();
        alice = makeAddr("Sepolia community registrant");
    }

    // ------------------------------------------------------------------ the question's contract

    function test_launchedRegistryAsksThePlanesMainnetQuestionsFromSepolia() public view {
        assertEq(address(registry.curator()), CURATOR, "the registry holds the Sepolia Curator");
        string memory hashes = vm.readFile("reference/plane/questionHashes.json");
        for (uint256 i; i < CATALOG_IDS.length; ++i) {
            uint16 id = CATALOG_IDS[i];
            Spec memory s = registry.specOf(id);
            assertEq(s.target, id == 1301 ? address(0) : Composer(applications[1]).MAINNET_CURATOR(), "target");
            (bytes memory body, bytes32 qh) = registry.composeBody(id, C1A1);
            bytes32 want = vm.parseJsonBytes32(hashes, string.concat(".", CATALOG_NAMES[i], ".questionHash"));
            assertEq(qh, want, CATALOG_NAMES[i]);
            string memory json = string(body);
            assertEq(vm.parseJsonUint(json, ".chainId"), 1, "the question is about mainnet");
            assertEq(vm.parseJsonUint(json, ".consumer.chainId"), SEPOLIA, "the consumer is the Sepolia registry");
            assertEq(vm.parseJsonAddress(json, ".consumer.verifyingContract"), address(registry));
            bytes memory question = bytes(vm.parseJsonString(json, ".question"));
            assertTrue(_contains(question, bytes("0xcb0b0531e86a9ac36fa865ca8e3dbccf047fda91")), "mainnet Curator");
            assertFalse(_contains(question, bytes("0x0919ba50b206c3f31d516de818b1fbc7da21653d")), "Sepolia Curator");
        }
    }

    function test_catalogQuestionHashIsTheSameOnBothChainsAndBoundToThePendingRequest() public {
        (, bytes32 sepoliaHash) = registry.composeBody(1301, C1A1);
        vm.chainId(1);
        (, bytes32 mainnetHash) = registry.composeBody(1301, C1A1);
        vm.chainId(SEPOLIA);
        assertEq(sepoliaHash, mainnetHash, "the canonical document excludes the consumer");
        _member(alice, 7);
        bytes32 rid = _ask(alice, 1301);
        (,,, bytes32 pendingHash) = registry.pendingRequest(rid);
        (, bytes32 forAlice) = registry.composeBody(1301, alice);
        assertEq(pendingHash, forAlice);
        assertTrue(forAlice != sepoliaHash, "the claimant is part of the question");
    }

    // ------------------------------------------------------------------ the window guard

    function test_gameWindowsRegisterThroughTheLaunchWhateverSepoliasHeightIs() public {
        vm.roll(1);
        assertEq(_register(alice, _gameSpec()), 10001, "T1 over the whole game at Sepolia height 1");
        vm.roll(type(uint64).max);
        assertEq(_register(alice, _nonceSpec(B_DEPLOY)), 10002, "T5 on the deploy block at a huge Sepolia height");
        vm.roll(11_926_289);
        Spec memory s = registry.specOf(10001);
        assertEq(s.fromBlock, B_DEPLOY);
        assertEq(s.toBlock, B_END);
        assertEq(registry.specOf(10002).toBlock, B_DEPLOY);
        assertEq(registry.nextSpecId(), 10003);
        // Registration fees are the registry's IMD balance, which is the sponsor pool.
        assertEq(registry.pool(), 2 * registry.SPEC_FEE(), "spec fees land in the pool");
        assertEq(imd.balanceOf(alice), 0);
        _member(alice, 7);
        vm.prank(alice);
        registry.claimSponsored(701);
        assertEq(registry.pool(), 2 * registry.SPEC_FEE() - PRICE, "a member can draw a request from fee money");
    }

    function test_sepoliaGuardIsExactlyTheSlotClockBound() public {
        uint256 bound = MERGE_BLOCK + (START - MERGE_TIME) / 12;
        Composer composer = Composer(applications[1]);
        assertEq(composer.mainnetHeightBound(), bound);
        assertEq(bound, 26_243_712, "one block per slot since the merge, at the fixture's timestamp");
        assertGt(bound, block.number, "Sepolia's own height is far below the mainnet bound");
        _fund(alice, 10 * registry.SPEC_FEE());
        // T1 to T4: toBlock strictly below the bound.
        Spec memory s = _gameSpec();
        s.toBlock = uint64(bound);
        s.fromBlock = s.toBlock - 7199;
        _refuse(alice, s);
        s.toBlock = uint64(bound - 1);
        s.fromBlock = s.toBlock - 7199;
        vm.prank(alice);
        assertEq(registry.registerSpec(s), 10001);
        // T5: the block plus 7200 at most the bound.
        _refuse(alice, _nonceSpec(uint64(bound - 7199)));
        vm.prank(alice);
        assertEq(registry.registerSpec(_nonceSpec(uint64(bound - 7200))), 10002);
        // Length and order are still checked, on the mainnet numbers.
        s = _gameSpec();
        s.fromBlock = s.toBlock - 7198;
        _refuse(alice, s);
        s = _gameSpec();
        (s.fromBlock, s.toBlock) = (s.toBlock, s.fromBlock);
        _refuse(alice, s);
        Spec memory t5 = _nonceSpec(B_DEPLOY);
        t5.toBlock = B_DEPLOY + 1;
        _refuse(alice, t5);
        assertEq(registry.nextSpecId(), 10003, "a refused spec takes no id");
        assertEq(imd.balanceOf(alice), 8 * registry.SPEC_FEE(), "a refused spec pulls no fee");
    }

    /// @dev Off mainnet the guard depends on the timestamp alone; the block number of the consumer chain
    ///      is ignored at every height, and the bound is exact at both edges.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_sepoliaGuardFollowsTimeNotHeight(uint64 at, uint64 height, bool t5) public {
        uint256 time = bound(at, MERGE_TIME + 7200 * 12, uint256(type(uint48).max));
        vm.warp(time);
        vm.roll(height);
        uint256 expected = MERGE_BLOCK + (time - MERGE_TIME) / 12;
        assertEq(Composer(applications[1]).mainnetHeightBound(), expected);
        _fund(alice, 2 * registry.SPEC_FEE());
        Spec memory ok = t5 ? _nonceSpec(uint64(expected - 7200)) : _gameSpec();
        Spec memory bad = t5 ? _nonceSpec(uint64(expected - 7199)) : _gameSpec();
        if (!t5) {
            ok.toBlock = uint64(expected - 1);
            ok.fromBlock = ok.toBlock - 7199;
            bad.toBlock = uint64(expected);
            bad.fromBlock = bad.toBlock - 7199;
        }
        _refuse(alice, bad);
        vm.prank(alice);
        assertEq(registry.registerSpec(ok), 10001);
        assertEq(registry.nextSpecId(), 10002);
    }

    function test_validateSpecIgnoresTheHeightArgumentOffMainnetOnly() public {
        Composer composer = Composer(applications[1]);
        Spec memory s = _gameSpec();
        composer.validateSpec(s, 0);
        composer.validateSpec(s, type(uint256).max);
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Composer.BadSpec.selector, "window"));
        composer.validateSpec(s, 0);
        vm.expectRevert(abi.encodeWithSelector(Composer.BadSpec.selector, "window"));
        composer.validateSpec(s, B_END);
        composer.validateSpec(s, uint256(B_END) + 1);
        vm.chainId(SEPOLIA);
    }

    function test_aWindowRefusedTodayRegistersOnceTheSlotClockReachesIt() public {
        uint256 bound = Composer(applications[1]).mainnetHeightBound();
        Spec memory s = _gameSpec();
        s.toBlock = uint64(bound + 7200);
        s.fromBlock = s.toBlock - 7199;
        _fund(alice, registry.SPEC_FEE());
        _refuse(alice, s);
        vm.warp(START + 7200 * 12);
        _refuse(alice, s);
        vm.warp(START + 7201 * 12);
        vm.prank(alice);
        assertEq(registry.registerSpec(s), 10001, "one slot past toBlock the window is below the bound");
    }

    // ------------------------------------------------------------------ community requests on Sepolia

    function test_communitySpecRequestOnSepoliaAsksAboutMainnetAndSettlesWithoutASignature() public {
        uint16 id = _register(alice, _gameSpec());
        bytes32 rid = _ask(alice, id);
        string memory body = string(intake.bodyOf(rid));
        assertEq(vm.parseJsonUint(body, ".chainId"), 1);
        assertEq(vm.parseJsonUint(body, ".consumer.chainId"), SEPOLIA);
        assertEq(vm.parseJsonUint(body, ".window.fromBlock"), B_DEPLOY);
        assertEq(vm.parseJsonUint(body, ".window.toBlock"), B_END);
        bytes memory question = bytes(vm.parseJsonString(body, ".question"));
        assertTrue(_contains(question, bytes("0xcb0b0531e86a9ac36fa865ca8e3dbccf047fda91")), "spec target");
        assertTrue(_contains(question, bytes("0x189378e")), "fromBlock in hex");
        assertTrue(_contains(question, bytes("0x18984a4")), "toBlock in hex");
        (,,, bytes32 pendingHash) = registry.pendingRequest(rid);
        (, bytes32 composed) = registry.composeBody(id, alice);
        assertEq(pendingHash, composed);
        // A result that carries no signature settles the pair as a miss and issues nothing.
        OracleAttestation memory a;
        a.chainId = 1;
        a.answerType = 3;
        a.answer = abi.encode(uint256(2));
        vm.cool(address(registry));
        vm.expectEmit(false, false, false, true, address(registry));
        emit Registry.Missed(rid, id, 2);
        assertTrue(intake.complete(rid, 0, abi.encode(rid, a, bytes(""))));
        assertFalse(registry.hasTrait(alice, id));
        assertEq(registry.pendingOf(alice, id), bytes32(0));
        assertEq(registry.verifiedSpecsOf(alice).length, 0);
    }

    function test_communitySharedFactOnSepoliaIsPaidOnlyThroughRequestSharedFact() public {
        Spec memory s = _gameSpec();
        s.kind = 3;
        s.sumArg = "amount";
        s.threshold = 2;
        s.name = "Top two";
        uint16 id = _register(alice, s);
        _fund(alice, 3 * PRICE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Registry.NotASharedFact.selector, id));
        registry.upgrade(_one(id), PRICE);
        _member(alice, 7);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Registry.NotACatalogChainTrait.selector, id));
        registry.claimSponsored(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Registry.NotACatalogChainTrait.selector, id));
        registry.upgradeSponsored(7, _one(id));
        vm.prank(alice);
        registry.requestSharedFact(id, PRICE);
        bytes32 rid = registry.sharedPending(id);
        assertTrue(rid != bytes32(0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Registry.AlreadyPending.selector, address(0), id));
        registry.requestSharedFact(id, PRICE);
        // Personal specs cannot be asked as shared facts either.
        uint16 personal = _register(alice, _gameSpec());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Registry.NotASharedFact.selector, personal));
        registry.requestSharedFact(personal, PRICE);
        assertEq(imd.balanceOf(INTAKE), PRICE, "exactly one request was paid");
    }

    // ------------------------------------------------------------------ helpers

    function _gameSpec() internal view returns (Spec memory s) {
        s.kind = 1;
        s.target = Composer(applications[1]).MAINNET_CURATOR();
        s.item = Composer(applications[1]).DEPOSITED();
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

    function _register(address who, Spec memory s) internal returns (uint16 id) {
        _fund(who, registry.SPEC_FEE());
        vm.prank(who);
        id = registry.registerSpec(s);
    }

    function _refuse(address who, Spec memory s) internal {
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(Composer.BadSpec.selector, "window"));
        registry.registerSpec(s);
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length > haystack.length) return false;
        for (uint256 i; i + needle.length <= haystack.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
