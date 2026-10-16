// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SepoliaFixture} from "./helpers/SepoliaFixture.sol";
import {Registry} from "src/Registry.sol";
import {OracleAttestation} from "src/interfaces/IOracleConsumer.sol";

/// @notice Random walk using the exact launch addresses and the absent V1 preview selector.
/// Independent ledgers record fees, requests, ownership and daily allowances from successful calls.
/// Dependencies are local mocks; changing the Intake's price models its external price changes.
contract SepoliaAccountingHandler is SepoliaFixture {
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
        bytes4[] memory selectors = new bytes4[](10);
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
}
