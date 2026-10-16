// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {Registry} from "../src/Registry.sol";
import {Renderer} from "../src/Renderer.sol";
import {Composer} from "../src/Composer.sol";
import {OracleAttestation} from "../src/interfaces/IOracleConsumer.sol";
import {Spec} from "../src/Types.sol";
import {MockCurator, MockIDMD, MockIMD, MockIntake} from "./mocks/Mocks.sol";

/// @notice The Sepolia rehearsal (chain 11155111) with the launch's Sepolia Curator as `curator`. Every question is
///         about Ethereum mainnet, so (1) `registerSpec` bounds a window by the mainnet height, not Sepolia's, and
///         (2) every catalog question names the mainnet Curator, while the direct reads keep using the deployment
///         chain's Curator. Mainnet behaviour (chain 1) is unchanged and pinned here too.
contract SepoliaRehearsalTest is Base {
    address internal constant SEPOLIA_CURATOR = 0x0919ba50b206C3F31D516De818b1fBc7dA21653D;
    uint256 internal constant SEPOLIA_HEIGHT = 11_926_383; // 2026-10-16
    uint256 internal constant SEPOLIA_TIME = 1_792_000_000;

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

    address internal alice = address(0xA11CE);

    /// @dev Like Base, but on Sepolia with the Curator mock at the Sepolia Curator address.
    function setUp() public override {
        vm.chainId(11155111);
        vm.roll(SEPOLIA_HEIGHT);
        vm.warp(SEPOLIA_TIME);
        attester = vm.addr(ATTESTER_KEY);
        deployCodeTo("Mocks.sol:MockCurator", SEPOLIA_CURATOR);
        curator = MockCurator(SEPOLIA_CURATOR);
        idmd = new MockIDMD();
        imd = new MockIMD();
        intake = new MockIntake(address(imd));
        renderer = new Renderer();
        composer = new Composer();
        deployCodeTo(
            "Registry.sol:Registry",
            abi.encode(
                SEPOLIA_CURATOR,
                address(idmd),
                address(imd),
                address(intake),
                attester,
                address(renderer),
                address(composer),
                address(0)
            ),
            REGISTRY_ADDR
        );
        registry = Registry(REGISTRY_ADDR);
    }

    function gameSpec() internal view returns (Spec memory s) {
        s.kind = 1;
        s.target = SEPOLIA_CURATOR;
        s.item = composer.DEPOSITED();
        s.arg = "contributor";
        s.threshold = 2;
        s.fromBlock = B_DEPLOY;
        s.toBlock = B_END;
        s.name = "Two deposits";
    }

    function nonceSpec(uint64 at) internal pure returns (Spec memory s) {
        s.kind = 5;
        s.threshold = 20;
        s.fromBlock = at;
        s.toBlock = at;
        s.name = "Pretrained twin";
    }

    function _fixture(string memory name) internal view returns (bytes memory body) {
        body = bytes(vm.readFile(string.concat("templates/fixtures/", name, ".json")));
        if (body[body.length - 1] == 0x0a) {
            assembly {
                mstore(body, sub(mload(body), 1))
            }
        }
    }

    // ------------------------------------------------------------------ the window guard

    function test_sepoliaRegistersTheCuratorGameWindow() public {
        assertLt(block.number, B_DEPLOY, "Sepolia is far below the mainnet game window");
        uint16 id = register(alice, gameSpec());
        assertEq(id, 10001);
        assertEq(registry.specOf(id).toBlock, B_END);
        assertEq(registry.specOf(id).fromBlock, B_DEPLOY);
        assertEq(imd.balanceOf(address(registry)), registry.SPEC_FEE(), "fee pulled");
        assertEq(register(alice, nonceSpec(B_DEPLOY)), 10002, "T5 on the Curator deploy block");
        assertEq(registry.nextSpecId(), 10003);
    }

    function test_sepoliaStillRefusesAWindowMainnetCannotHaveMined() public {
        uint256 bound = composer.mainnetHeightBound();
        assertGt(bound, B_END, "the game window is mined");
        assertGt(bound, block.number, "the bound is a mainnet height, not Sepolia's");
        // T1 to T4: toBlock must be below the bound.
        Spec memory s = gameSpec();
        s.toBlock = uint64(bound);
        s.fromBlock = s.toBlock - 7199;
        fund(alice, registry.SPEC_FEE());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Composer.BadSpec.selector, "window"));
        registry.registerSpec(s);
        s.toBlock = uint64(bound - 1);
        s.fromBlock = s.toBlock - 7199;
        assertEq(register(alice, s), 10001, "one below the bound registers");
        // T5: the block must be 7200 blocks old.
        fund(alice, registry.SPEC_FEE());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Composer.BadSpec.selector, "window"));
        registry.registerSpec(nonceSpec(uint64(bound - 7199)));
        assertEq(register(alice, nonceSpec(uint64(bound - 7200))), 10002);
        // Ordering and length are checked as before.
        s = gameSpec();
        s.fromBlock = s.toBlock - 7198;
        fund(alice, registry.SPEC_FEE());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Composer.BadSpec.selector, "window"));
        registry.registerSpec(s);
        s = gameSpec();
        (s.fromBlock, s.toBlock) = (s.toBlock, s.fromBlock);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Composer.BadSpec.selector, "window"));
        registry.registerSpec(s);
        assertEq(registry.nextSpecId(), 10003, "no refused spec took an id");
    }

    function test_mainnetGuardStillUsesTheMainnetBlockNumber() public {
        vm.chainId(1);
        vm.roll(26_200_000);
        vm.warp(T0);
        assertGt(composer.mainnetHeightBound(), block.number, "the slot bound is looser than the real height");
        Spec memory s = gameSpec();
        s.toBlock = 26_200_000;
        s.fromBlock = s.toBlock - 7199;
        fund(alice, registry.SPEC_FEE());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Composer.BadSpec.selector, "window"));
        registry.registerSpec(s);
        s.toBlock = 26_199_999;
        s.fromBlock = s.toBlock - 7199;
        assertEq(register(alice, s), 10001, "mainnet: toBlock < block.number");
        fund(alice, registry.SPEC_FEE());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Composer.BadSpec.selector, "window"));
        registry.registerSpec(nonceSpec(26_192_801));
        assertEq(register(alice, nonceSpec(26_192_800)), 10002, "mainnet: toBlock + 7200 <= block.number");
    }

    /// @dev One block per 12-second slot since the merge: the bound never falls below a recorded mainnet height.
    function test_mainnetHeightBoundIsNeverBelowARecordedHeight() public {
        uint256[2][5] memory recorded = [
            [uint256(1_663_224_191), 15_537_395], // first post-merge block
            [uint256(1_786_910_327), 25_769_870], // the Curator deploy block (CATALOG.md section 2)
            [uint256(1_791_731_219), 26_170_000], // the fork tests' pinned block
            [uint256(1_792_092_371), 26_200_000], // Base's block
            [uint256(1_792_143_071), 26_204_211] // the head read over a public RPC on 2026-10-16
        ];
        for (uint256 i; i < recorded.length; ++i) {
            vm.warp(recorded[i][0]);
            uint256 bound = composer.mainnetHeightBound();
            assertGe(bound, recorded[i][1], "bound below a real height");
            assertLe(bound - recorded[i][1], 100_000, "bound loose by more than ~1% of the post-merge blocks");
        }
        vm.warp(1);
        assertEq(composer.mainnetHeightBound(), 15_537_395, "before the merge the bound is the merge block");
    }

    function test_fuzz_mainnetHeightBoundIsMonotoneInTime(uint64 t1, uint64 t2) public {
        if (t1 > t2) (t1, t2) = (t2, t1);
        vm.warp(t1);
        uint256 b1 = composer.mainnetHeightBound();
        vm.warp(t2);
        uint256 b2 = composer.mainnetHeightBound();
        assertLe(b1, b2);
        assertGe(b1, 15_537_395);
    }

    // ------------------------------------------------------------------ the question's contract

    function test_sepoliaCatalogQuestionsNameTheMainnetCurator() public view {
        assertEq(address(registry.curator()), SEPOLIA_CURATOR, "the registry reads the Sepolia Curator");
        string memory j = vm.readFile("reference/plane/questionHashes.json");
        for (uint256 i; i < CATALOG_IDS.length; ++i) {
            uint16 id = CATALOG_IDS[i];
            Spec memory s = registry.specOf(id);
            assertEq(s.target, id == 1301 ? address(0) : composer.MAINNET_CURATOR(), "catalog target");
            (bytes memory body, bytes32 qh) = registry.composeBody(id, C1A1);
            // The Sepolia body is the mainnet fixture with only the consumer chain changed...
            assertEq(
                string(body),
                vm.replace(
                    string(_fixture(CATALOG_NAMES[i])),
                    '"consumer": {\n    "chainId": 1,',
                    '"consumer": {\n    "chainId": 11155111,'
                ),
                CATALOG_NAMES[i]
            );
            // ...and its question hash is the one the plane quoted for mainnet.
            bytes32 want = vm.parseJsonBytes32(j, string.concat(".", CATALOG_NAMES[i], ".questionHash"));
            assertEq(qh, want, CATALOG_NAMES[i]);
            assertFalse(_contains(body, bytes("0x0919ba50b206c3f31d516de818b1fbc7da21653d")), "Sepolia Curator named");
        }
        // Whatever `curator` the registry holds, the Composer answers the same spec and body.
        (bytes memory viaMainnet,) = composer.compose(
            composer.catalogSpec(701, address(0xBEEF)), C1A1, address(registry), false, address(0xBEEF)
        );
        (bytes memory viaRegistry,) = registry.composeBody(701, C1A1);
        assertEq(viaMainnet, viaRegistry, "the Curator argument does not reach the question");
    }

    function test_sepoliaDirectReadsStillUseTheDeploymentCurator() public {
        assertFalse(registry.hasTrait(alice, 101));
        curator.set(alice, 0, true, 10, 1e18, 1000);
        assertTrue(registry.hasTrait(alice, 101), "Spawned from the Sepolia Curator");
        assertTrue(registry.hasTrait(alice, 202));
        assertTrue(registry.hasTrait(alice, 303));
        assertTrue(registry.hasTrait(alice, 401));
        assertTrue(registry.hasTrait(alice, 501));
        assertFalse(registry.hasTrait(address(0xB0B), 101));
    }

    /// @dev End to end on Sepolia: a claimant asks 701, the answer is signed in the Sepolia consumer domain over
    ///      the mainnet question, and the registry marks the trait: the success path the rehearsal exists for.
    function test_sepoliaClaimantVerifiesACatalogChainTrait() public {
        bytes32 rid = ask(alice, 701);
        (,,, bytes32 qh) = registry.pendingRequest(rid);
        (, bytes32 composed) = registry.composeBody(701, alice);
        assertEq(qh, composed, "pending hash is the composed mainnet question");
        OracleAttestation memory a = attestationFor(rid, word(1));
        assertEq(a.chainId, 1);
        assertTrue(deliver(rid, a), "delivered under the stipend");
        assertTrue(registry.hasTrait(alice, 701), "Uptime verified on Sepolia");
        assertEq(registry.pendingOf(alice, 701), bytes32(0));
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
