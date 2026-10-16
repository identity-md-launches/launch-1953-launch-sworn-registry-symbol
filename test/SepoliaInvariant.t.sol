// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SepoliaFixture} from "./helpers/SepoliaFixture.sol";
import {Registry} from "src/Registry.sol";
import {Composer} from "src/Composer.sol";
import {Spec} from "src/Types.sol";
import {OracleAttestation} from "src/interfaces/IOracleConsumer.sol";

/// @notice Random walk using the exact launch addresses and the absent V1 preview selector.
/// Independent ledgers record fees, requests, ownership and daily allowances from successful calls.
/// Dependencies are local mocks; changing the Intake's price models its external price changes.
/// Community specs are registered with mainnet windows at and around the slot-clock bound the
/// revised guard applies off mainnet; their fees join the pool and their requests the ledger.
contract SepoliaAccountingHandler is SepoliaFixture {
    uint64 internal constant B_DEPLOY = 0x189378e;
    uint64 internal constant B_END = 0x18984a4;

    struct Request {
        bytes32 id;
        address claimant;
        uint16 trait;
        uint64 requestedAt;
        bytes32 questionHash;
        bool open;
    }

    address[4] public actors;
    uint16[10] internal traits = [701, 801, 901, 1001, 1101, 1102, 1103, 1104, 1105, 1301];
    Request[] internal requests;
    mapping(address => mapping(uint16 => bytes32)) public expectedPending;
    mapping(address => mapping(uint16 => bool)) public expectedUsed;
    mapping(address => uint256) public expectedDay;
    mapping(uint256 => uint256) public expectedIdmdUses;
    mapping(address => uint256) public mintedToken;
    mapping(uint256 => address) public expectedOwner;
    uint256 public poolIn;
    uint256 public poolSpent;
    uint256 public paidSpent;
    uint256 public mintedCards;
    uint256 public successfulRequests;
    uint256 public rejectedCalls;
    uint256 public finishedRequests;
    uint256 public abandonedRequests;
    uint256 public replayedRequests;
    uint256 public sponsoredRequests;
    uint16[] public specIds;
    mapping(uint16 => bytes32) public specHash;
    uint256 public refusedSpecs;
    uint256 public communityRequests;

    constructor() {
        setUp();
        for (uint256 i; i < actors.length; ++i) {
            address who = makeAddr(string.concat("Sepolia invariant actor ", vm.toString(i)));
            actors[i] = who;
            _member(who, i + 1);
            _fund(who, 1000 ether);
            vm.deal(who, 10 ether);
        }
        vm.prank(actors[0]);
        registry.sponsor(10 ether);
        poolIn = 10 ether;
    }

    function deposit(uint256 actorSeed, uint96 amountSeed, bool direct) public {
        address who = actors[actorSeed % 4];
        uint256 amount = bound(amountSeed, 0, _min(imd.balanceOf(who), 5 ether));
        vm.prank(who);
        if (direct) assertTrue(imd.transfer(address(registry), amount));
        else registry.sponsor(amount);
        poolIn += amount;
    }

    function mint(uint256 actorSeed) public {
        address who = actors[actorSeed % 4];
        if (mintedToken[who] != 0) return;
        vm.prank(who);
        uint256 id = registry.mintCard();
        assertEq(id, ++mintedCards);
        mintedToken[who] = id;
        expectedOwner[id] = who;
        poolIn += 0.1 ether;
    }

    function transfer(uint256 tokenSeed, uint256 recipientSeed) public {
        if (mintedCards == 0) return;
        uint256 token = tokenSeed % mintedCards + 1;
        address to = actors[recipientSeed % 4];
        address from = expectedOwner[token];
        vm.prank(from);
        registry.transferFrom(from, to, token);
        expectedOwner[token] = to;
    }

    function changePrice(uint96 amount) public {
        intake.setPrice(bound(amount, 0, 2 ether));
    }

    function advanceTime(uint32 elapsed) public {
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 1, 15 days));
    }

    function askPaid(uint256 actorSeed, uint256 traitSeed, bool shared, bool staleQuote) public {
        address who = actors[actorSeed % 4];
        uint16 trait = shared ? 1201 : traits[traitSeed % traits.length];
        address claimant = shared ? address(0) : who;
        uint256 price = intake.price();
        uint256 maxPrice = staleQuote && price != 0 ? price - 1 : price;
        uint256 beforePayer = imd.balanceOf(who);
        uint256 beforePool = registry.pool();
        bool shouldSucceed = price != 0 && maxPrice >= price && expectedPending[claimant][trait] == 0;
        bytes memory payload = shared
            ? abi.encodeCall(Registry.requestSharedFact, (trait, maxPrice))
            : abi.encodeCall(Registry.upgrade, (_one(trait), maxPrice));
        vm.prank(who);
        (bool ok,) = address(registry).call(payload);
        assertEq(ok, shouldSucceed, "paid request outcome");
        if (ok) {
            paidSpent += price;
            _recordRequest(claimant, trait);
        } else {
            rejectedCalls++;
        }
        assertEq(imd.balanceOf(who), beforePayer - (ok ? price : 0), "only accepted requests charge payer");
        assertEq(registry.pool(), beforePool, "paid requests never spend the pool");
    }

    function claim(uint256 actorSeed, uint256 traitSeed, bool throughIdmd, uint96 valueSeed) public {
        uint256 index = actorSeed % 4;
        address who = actors[index];
        uint16 trait = traits[traitSeed % 9];
        uint256 value = bound(valueSeed, 0, 0.01 ether);
        uint256 price = intake.price();
        uint256 beforePool = registry.pool();
        uint256 beforePayer = imd.balanceOf(who);
        bool shouldSucceed = price != 0 && beforePool >= price && !expectedUsed[who][trait]
            && expectedPending[who][trait] == 0 && expectedDay[who] != block.timestamp / 1 days
            && (!throughIdmd || expectedIdmdUses[index + 1] < 9);
        bytes memory payload = throughIdmd
            ? abi.encodeCall(Registry.upgradeSponsored, (index + 1, _one(trait)))
            : abi.encodeCall(Registry.claimSponsored, (trait));
        vm.prank(who);
        (bool ok,) = address(registry).call{value: value}(payload);
        assertEq(ok, shouldSucceed, "sponsored request outcome");
        if (ok) {
            poolSpent += price;
            sponsoredRequests++;
            expectedUsed[who][trait] = true;
            expectedDay[who] = block.timestamp / 1 days;
            if (throughIdmd) expectedIdmdUses[index + 1]++;
            _recordRequest(who, trait);
        } else {
            rejectedCalls++;
        }
        assertEq(registry.pool(), beforePool - (ok ? price : 0));
        assertEq(imd.balanceOf(who), beforePayer, "sponsored caller pays no IMD");
        assertEq(who.balance, 10 ether, "V1 skip refunds every attached wei, including on reverts");
    }

    /// @dev A T1, T3 or T5 spec whose window ends at a random mainnet block up to the slot-clock bound, or
    ///      (`beyond`) at or past it. The Sepolia height is rolled at random and must not matter.
    function registerSpec(uint256 actorSeed, uint8 kindSeed, uint64 endSeed, bool beyond, uint64 heightSeed) public {
        if (specIds.length >= 6) return;
        address who = actors[actorSeed % 4];
        vm.roll(heightSeed);
        uint256 limit = Composer(applications[1]).mainnetHeightBound();
        uint8 kind = [1, 3, 5][kindSeed % 3];
        Spec memory s;
        s.kind = kind;
        s.name = string.concat("Sepolia spec ", vm.toString(specIds.length));
        s.threshold = 2;
        if (kind == 5) {
            uint256 at = beyond ? bound(endSeed, limit - 7199, limit) : bound(endSeed, B_DEPLOY, limit - 7200);
            s.fromBlock = uint64(at);
            s.toBlock = uint64(at);
        } else {
            s.target = Composer(applications[1]).MAINNET_CURATOR();
            s.item = Composer(applications[1]).DEPOSITED();
            s.arg = "contributor";
            if (kind == 3) s.sumArg = "amount";
            uint256 end = beyond ? bound(endSeed, limit, limit + 1_000_000) : bound(endSeed, B_END, limit - 1);
            s.toBlock = uint64(end);
            s.fromBlock = uint64(end - 7199);
        }
        uint256 fee = registry.SPEC_FEE();
        uint256 beforePayer = imd.balanceOf(who);
        uint16 next = registry.nextSpecId();
        bool shouldSucceed = !beyond && beforePayer >= fee;
        vm.prank(who);
        (bool ok, bytes memory ret) = address(registry).call(abi.encodeCall(Registry.registerSpec, (s)));
        assertEq(ok, shouldSucceed, "registration outcome");
        if (ok) {
            uint16 id = abi.decode(ret, (uint16));
            assertEq(id, next);
            poolIn += fee;
            specIds.push(id);
            specHash[id] = keccak256(abi.encode(registry.specOf(id)));
        } else {
            if (beyond) {
                assertEq(ret, abi.encodeWithSelector(Composer.BadSpec.selector, "window"), "refused for the window");
            }
            refusedSpecs++;
            rejectedCalls++;
        }
        assertEq(registry.nextSpecId(), ok ? next + 1 : next, "ids only for accepted specs");
        assertEq(imd.balanceOf(who), beforePayer - (ok ? fee : 0), "fee only for accepted specs");
    }

    /// @dev Pays for a registered community spec: `upgrade` for T1 and T5, `requestSharedFact` for T3.
    function askCommunity(uint256 actorSeed, uint256 specSeed, bool staleQuote) public {
        if (specIds.length == 0) return;
        address who = actors[actorSeed % 4];
        uint16 trait = specIds[specSeed % specIds.length];
        bool shared = registry.specOf(trait).kind == 3;
        address claimant = shared ? address(0) : who;
        uint256 price = intake.price();
        uint256 maxPrice = staleQuote && price != 0 ? price - 1 : price;
        uint256 beforePayer = imd.balanceOf(who);
        uint256 beforePool = registry.pool();
        bool shouldSucceed =
            price != 0 && maxPrice >= price && expectedPending[claimant][trait] == 0 && beforePayer >= price;
        bytes memory payload = shared
            ? abi.encodeCall(Registry.requestSharedFact, (trait, maxPrice))
            : abi.encodeCall(Registry.upgrade, (_one(trait), maxPrice));
        vm.prank(who);
        (bool ok,) = address(registry).call(payload);
        assertEq(ok, shouldSucceed, "community request outcome");
        if (ok) {
            paidSpent += price;
            communityRequests++;
            _recordRequest(claimant, trait);
        } else {
            rejectedCalls++;
        }
        assertEq(imd.balanceOf(who), beforePayer - (ok ? price : 0));
        assertEq(registry.pool(), beforePool, "community requests never spend the pool");
    }

    function _recordRequest(address claimant, uint16 trait) internal {
        bytes32 rid = intake.lastId();
        (, bytes32 questionHash) = registry.composeBody(trait, claimant);
        expectedPending[claimant][trait] = rid;
        requests.push(Request(rid, claimant, trait, uint64(block.timestamp), questionHash, true));
        successfulRequests++;
    }

    function complete(uint256 seed, uint8 outcome) public {
        if (requests.length == 0) return;
        Request storage r = requests[seed % requests.length];
        if (!r.open) return;
        bool delivered;
        if (outcome % 3 == 0) {
            // No forged signatures: an ABI-valid envelope with an empty signature must be a miss.
            OracleAttestation memory a;
            a.chainId = 1;
            a.answer = abi.encode(true);
            bytes memory args = abi.encode(r.id, a, bytes(""));
            vm.cool(address(registry));
            delivered = intake.complete(r.id, 0, args);
        } else {
            uint8 status = outcome % 3;
            bytes memory args = abi.encode(r.id, status, bytes32("disagreed"), uint16(0), uint16(5), bytes(""));
            vm.cool(address(registry));
            delivered = intake.complete(r.id, status, args);
        }
        assertTrue(delivered, "miss/failure is delivered within 200,000 gas");
        _consume(r);
        finishedRequests++;
    }

    function abandon(uint256 seed) public {
        if (requests.length == 0) return;
        Request storage r = requests[seed % requests.length];
        if (!r.open || block.timestamp < uint256(r.requestedAt) + 14 days) return;
        address caller = r.claimant == address(0) ? actors[(seed % 4 + 1) % 4] : r.claimant;
        vm.prank(caller);
        registry.abandon(r.id);
        _consume(r);
        abandonedRequests++;
    }

    function replay(uint256 seed) public {
        if (requests.length == 0) return;
        Request storage r = requests[seed % requests.length];
        if (r.open) return;
        // A stale authorized callback must not clear a newer request for the same pair.
        vm.prank(INTAKE);
        registry.onFailure(r.id, 1, bytes32("body_invalid"), 0, 0, bytes(""));
        replayedRequests++;
    }

    function _consume(Request storage r) internal {
        r.open = false;
        delete expectedPending[r.claimant][r.trait];
    }

    /// @dev SHOULD-HOLD: exact accounting identity, plus the brief's V1 refund decision.
    function assertAccounting() external view {
        assertEq(registry.pool(), poolIn - poolSpent, "pool = deposits + mint fees - sponsored prices");
        assertEq(imd.balanceOf(INTAKE), paidSpent + poolSpent, "every request pays exactly its current price");
        assertEq(imd.allowance(address(registry), INTAKE), 0, "no residual approval after payment or failure");
        uint256 held = registry.pool() + imd.balanceOf(INTAKE);
        for (uint256 i; i < 4; ++i) {
            held += imd.balanceOf(actors[i]);
            assertEq(actors[i].balance, 10 ether);
        }
        assertEq(held, 4000 ether);
        assertEq(imd.totalSupply(), 4000 ether);
        assertEq(address(registry).balance, 0);
        assertEq(EXECUTOR.balance, 0);
        assertEq(executor.calls(), 0);
        assertEq(intake.nonce(), successfulRequests, "failed calls never leave paid requests behind");
    }

    /// @dev SHOULD-HOLD: the paid request is consumed once; allowances survive failures/abandonment.
    function assertRequestsAndAllowances() external view {
        for (uint256 i; i < requests.length; ++i) {
            Request storage r = requests[i];
            (address claimant, uint16 trait, uint64 requestedAt, bytes32 qh) = registry.pendingRequest(r.id);
            if (r.open) {
                assertEq(claimant, r.claimant);
                assertEq(trait, r.trait);
                assertEq(requestedAt, r.requestedAt);
                assertEq(qh, r.questionHash);
                assertEq(expectedPending[r.claimant][r.trait], r.id);
            } else {
                assertEq(claimant, address(0));
                assertEq(trait, 0);
                assertEq(requestedAt, 0);
                assertEq(qh, bytes32(0));
            }
        }
        for (uint256 i; i < 4; ++i) {
            address who = actors[i];
            assertEq(registry.lastPoolDay(who), expectedDay[who]);
            assertEq(registry.idmdSponsored(i + 1), expectedIdmdUses[i + 1]);
            assertLe(expectedIdmdUses[i + 1], 9);
            for (uint256 j; j < traits.length; ++j) {
                uint16 trait = traits[j];
                assertEq(registry.pendingOf(who, trait), expectedPending[who][trait]);
                assertEq(registry.poolUsed(who, trait), expectedUsed[who][trait]);
                assertFalse(registry.hasTrait(who, trait), "unsigned/invalid results never issue credentials");
            }
        }
        assertEq(registry.sharedPending(1201), expectedPending[address(0)][1201]);
        (bytes32 stored,,) = registry.sharedFact(1201);
        assertEq(stored, bytes32(0));
        // Community specs: one id per accepted registration, immutable once stored, no credential without a
        // valid signed answer, and the same pending bookkeeping as the catalog.
        assertEq(registry.nextSpecId(), 10001 + specIds.length, "ids are dense and only accepted specs take one");
        for (uint256 i; i < specIds.length; ++i) {
            uint16 id = specIds[i];
            Spec memory s = registry.specOf(id);
            assertEq(keccak256(abi.encode(s)), specHash[id], "a registered spec never changes");
            assertLt(s.toBlock, Composer(applications[1]).mainnetHeightBound(), "windows stay below the bound");
            if (s.kind == 3) {
                assertEq(registry.sharedPending(id), expectedPending[address(0)][id]);
                (bytes32 fact,,) = registry.sharedFact(id);
                assertEq(fact, bytes32(0));
            }
            for (uint256 j; j < 4; ++j) {
                assertEq(registry.pendingOf(actors[j], id), expectedPending[actors[j]][id]);
                assertFalse(registry.hasTrait(actors[j], id));
            }
            assertEq(registry.verifiedSpecsOf(actors[i % 4]).length, 0);
        }
        uint16 unassigned = uint16(10001 + specIds.length);
        (bool ok, bytes memory ret) = address(registry).staticcall(abi.encodeCall(Registry.specOf, (unassigned)));
        assertFalse(ok, "the next id is not a trait yet");
        assertEq(ret, abi.encodeWithSelector(Registry.NotAnOracleTrait.selector, unassigned));
    }

    /// @dev SHOULD-HOLD: transfers change ownership but never the card's original claimant.
    function assertCardsAndConfiguration() external view {
        for (uint256 i; i < 4; ++i) {
            address who = actors[i];
            uint256 token = mintedToken[who];
            assertEq(registry.tokenOf(who), token);
            if (token != 0) {
                assertEq(registry.claimantOf(token), who);
                assertEq(registry.ownerOf(token), expectedOwner[token]);
            }
        }
        assertEq(address(registry.curator()), CURATOR);
        assertEq(address(registry.idmd()), IDMD);
        assertEq(address(registry.imd()), IMD);
        assertEq(address(registry.intake()), INTAKE);
        assertEq(registry.attester(), ATTESTER);
        assertEq(address(registry.burnExecutor()), EXECUTOR);
        assertEq(registry.ACTION(), bytes32("oracle.request@oracle-1"));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract SepoliaInvariantTest is Test {
    SepoliaAccountingHandler internal handler;

    function setUp() public {
        handler = new SepoliaAccountingHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](12);
        selectors[10] = handler.registerSpec.selector;
        selectors[11] = handler.askCommunity.selector;
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.mint.selector;
        selectors[2] = handler.transfer.selector;
        selectors[3] = handler.changePrice.selector;
        selectors[4] = handler.advanceTime.selector;
        selectors[5] = handler.askPaid.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.complete.selector;
        selectors[8] = handler.abandon.selector;
        selectors[9] = handler.replay.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_tokenAndEtherConservation() public view {
        handler.assertAccounting();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_pendingRequestsAndDailyLimitsMatchTheModel() public view {
        handler.assertRequestsAndAllowances();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_claimantsAndLaunchConfigurationNeverChange() public view {
        handler.assertCardsAndConfiguration();
    }

    /// @notice Positive control: every stateful branch is reached without relying on random luck.
    function test_handlerExercisesChangingPricesRefundsFailuresAndRetries() public {
        handler.deposit(0, 5 ether, false);
        handler.deposit(1, 1, true);
        handler.mint(0);
        handler.transfer(0, 1);
        handler.changePrice(1);
        handler.askPaid(0, 9, false, false); // request 0, personal bool
        handler.complete(0, 0); // invalid signature clears it
        handler.askPaid(0, 9, false, false); // request 1, successor
        handler.replay(0); // successor survives
        handler.changePrice(2 ether);
        handler.askPaid(1, 0, true, true); // price cap rejects
        handler.askPaid(1, 0, true, false); // request 2, shared
        handler.complete(2, 2); // no verdict
        handler.claim(0, 0, true, 0.01 ether); // request 3, full refund
        handler.claim(0, 1, false, 1); // daily limit rejects
        handler.changePrice(0);
        handler.claim(1, 0, false, 1); // sale disabled; nothing is consumed
        handler.advanceTime(uint32(14 days));
        handler.abandon(1);
        handler.abandon(3);
        handler.replay(3);
        handler.changePrice(0.5 ether);
        handler.claim(0, 0, false, 1); // lifetime pair remains used after abandonment
        handler.claim(0, 1, false, 1); // request 4 on the new UTC day
        handler.complete(4, 1);
        handler.assertAccounting();
        handler.assertRequestsAndAllowances();
        handler.assertCardsAndConfiguration();
        assertEq(handler.successfulRequests(), 5);
        assertEq(handler.sponsoredRequests(), 2);
        assertEq(handler.rejectedCalls(), 4);
        assertEq(handler.finishedRequests(), 3);
        assertEq(handler.abandonedRequests(), 2);
        assertEq(handler.replayedRequests(), 2);
        assertEq(handler.mintedCards(), 1);
    }

    /// @notice Positive control for the community operations: accepted and refused registrations at the
    ///         slot-clock bound, requests of every spec kind, and their failure, abandonment and retry.
    function test_handlerRegistersAndAsksCommunitySpecsOnSepolia() public {
        handler.registerSpec(0, 0, 0, false, 1); // 10001: T1 over the game window, at Sepolia height 1
        handler.registerSpec(1, 1, type(uint64).max, false, type(uint64).max); // 10002: T3 ending just below the bound
        handler.registerSpec(2, 2, 0, false, 0); // 10003: T5 on the deploy block
        handler.registerSpec(3, 0, 0, true, 7); // refused: T1 ending at the bound
        handler.registerSpec(3, 2, 0, true, 7); // refused: T5 younger than 7200 blocks
        assertEq(handler.refusedSpecs(), 2);
        assertEq(handler.specIds(0), 10001);
        assertEq(handler.specIds(2), 10003);
        handler.askCommunity(0, 0, false); // request 0: personal T1
        handler.askCommunity(1, 1, false); // request 1: shared T3
        handler.askCommunity(2, 2, true); // stale quote rejects
        handler.askCommunity(2, 2, false); // request 2: personal T5
        handler.askCommunity(3, 1, false); // shared fact already pending rejects
        handler.complete(0, 0); // unsigned result: a miss, no credential
        handler.complete(1, 1); // the shared fact is refused by the plane
        handler.advanceTime(uint32(14 days));
        handler.abandon(2);
        handler.replay(2);
        handler.askCommunity(2, 2, false); // request 3: the T5 pair can be asked again after abandonment
        handler.registerSpec(0, 0, type(uint64).max, false, 5); // 10004: the bound moved with time
        handler.assertAccounting();
        handler.assertRequestsAndAllowances();
        handler.assertCardsAndConfiguration();
        assertEq(handler.communityRequests(), 4);
        assertEq(handler.successfulRequests(), 4);
        assertEq(handler.rejectedCalls(), 4);
        assertEq(handler.finishedRequests(), 2);
        assertEq(handler.abandonedRequests(), 1);
        assertEq(handler.replayedRequests(), 1);
        assertEq(handler.poolIn(), 10 ether + 4 * 6.4 ether);
    }
}
