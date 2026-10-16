# Sworn

Sworn (collection symbol `SWORN`) is an ownerless onchain registry of verifiable wallet feats on Ethereum mainnet: one transferable ERC-721 card per
wallet, traits as facts about the wallet that minted it, every trait backed by evidence anyone can rerun. Direct
reads from the settled `WhitelistCurator` (THE LIST) are free; everything else is attested by the IMD swarm through
the onchain Intake and verified in the registry's callback. `hasTrait(wallet, traitId)` needs no card.

**Status: built (2026-10-12) from the round-2 brief.** `src/` holds `Registry`, `Renderer`, `Composer` and the
interfaces; `test/` the hermetic suite; `script/Deploy.s.sol` the deployment. **Renamed 2026-10-16:** the product is
Sworn, the collection `ERC721("Sworn", "SWORN")`, metadata names `Sworn #<tokenId>`, and the family display names
are Spawned (101), Zero-Shot (201, 202), Hopper (3xx), Bullfrog (4xx), Benchmarked (5xx), Armed (601), Uptime (701),
Holdout (801), Final Token (901), Hotfix (1001), PID (11xx; 1105 keeps `First thousand`), Top Weights (1201) and
Pretrained (1301); `CATALOG.md` section 7 maps them to the working names. The rename lives in one name table
(`Composer.traitName`, `catalogSpec`), the generator's `FAMILIES`, the collection strings and the card template; it
touched no id, rule, window, threshold or address. The same change made `upgrade` refuse 1201 with `NotASharedFact`
(as it does a community T3 id), fixed the T5 `target` guard row of `CATALOG.md` section 5 (must be zero) and the
last sentence of `INTEGRATION.md` check 7 (the golden test hashes the canonical document, not the body).

## Read in this order

1. `CONCEPT.md`: what it is, the card model, flows, rendering, the contracts and the invariants.
2. `CATALOG.md`: the frozen v1 catalog: 25 trait slots, ids, rules, canonical block windows, populations, the
   callback acceptance rule per class, spec registration, the pool rules, the name table.
3. `TEMPLATES.md`: the five question templates and the request body; `templates/fixtures/` holds the exact bodies,
   all ten checked and quoted by the plane.
4. `INTEGRATION.md`: Intake v2 (`requestWithFailure`, `complete`, the 200,000-gas callback, the failure hook), the
   EIP-712 attestation struct and how it binds (`consumer`, `questionHash`), addresses, the Curator's views and their
   traps, the transition table.
5. `reference/`: vendored evidence (both Intakes' verified sources, ABIs, five served attestations including two for
   real consumers, the decoded mainnet completions, block headers, the plane's check and quote responses, the THE LIST
   record NFT whose card model and golden-test method this registry mirrors). `reference/PROVENANCE.md` says what each
   file is and what is only measured, not vendored.
6. `DISCLOSURE.md`.

## Interface summary (the public surface the tests pin)

```solidity
// cards
function mintCard() external returns (uint256 tokenId);                 // 0.1 IMD to the registry, once per wallet
function tokenOf(address wallet) external view returns (uint256);       // 0 = no card
function claimantOf(uint256 tokenId) external view returns (address);   // immutable
function mintedAtBlock(uint256 tokenId) external view returns (uint64); // immutable
function tokenURI(uint256 tokenId) external view returns (string memory);

// traits
function hasTrait(address wallet, uint16 traitId) external view returns (bool);   // no card needed
function traitsOf(address wallet) external view returns (uint16[] memory);        // the 25 catalog ids that are true (all tiers), no specs
function verifiedSpecsOf(address wallet) external view returns (uint16[] memory);  // every verified community spec id
function upgrade(uint16[] calldata traitIds, uint256 maxPrice) external;           // k oracle requests, k x priceOf, priceOf <= maxPrice
function abandon(bytes32 requestId) external;                                      // after 14 days: claimant; anyone for shared facts
function verified(address claimant, uint16 traitId) external view
    returns (bytes32 requestId, bytes32 oracleRequestId, uint64 fromBlock, uint64 toBlock);
function pendingOf(address claimant, uint16 traitId) external view returns (bytes32 requestId);
function composeBody(uint16 traitId, address claimant) external view
    returns (bytes memory body, bytes32 questionHash);                              // the exact body and the plane's hash of it

// Intake consumer (Intake only)
function onResult(bytes32 requestId, OracleAttestation calldata a, bytes calldata signature) external;
function onFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered,
    bytes calldata signature) external;

// community specs
function registerSpec(Spec calldata spec) external returns (uint16 traitId);       // 6.4 IMD to the registry
function specOf(uint16 traitId) external view returns (Spec memory);

// shared facts
function requestSharedFact(uint16 factId, uint256 maxPrice) external;              // one price, no claimant, one pending per fact
function applySharedFact(uint16 factId, address[] calldata list) external;         // gas only; list must hash to the stored answer
function sharedFact(uint16 factId) external view returns (bytes32 requestId, bytes32 answerHash, uint16 length);

// sponsor pool (CONCEPT 4; catalog chain traits only)
function sponsor(uint256 amount) external;
function upgradeSponsored(uint256 idmdTokenId, uint16[] calldata traitIds) external payable; // IDMD holder AND list member, exactly one id, nine per token ever
function claimSponsored(uint16 traitId) external payable;                                   // list member, own wallet, from launch
function poolUsed(address claimant, uint16 traitId) external view returns (bool);
function lastPoolDay(address wallet) external view returns (uint64);                 // UTC day of last pool request; shared across both paths
function idmdSponsored(uint256 idmdTokenId) external view returns (uint8);           // successful pool requests, 0..9, follows the IDMD token
function deployedAt() external view returns (uint64);
function pool() external view returns (uint256);                                     // = IMD.balanceOf(this)
function burnExecutor() external view returns (IBurnExecutor);                       // fixed at construction; zero disables
function BURN_MIN() external view returns (uint256);                                 // 69 ether (IMD, 18 decimals)
function BURN_FEE_CAP() external view returns (uint256);                             // 0.005 ether (native ETH)

// catalog
function traitName(uint16 traitId) external view returns (string memory);
function traitClass(uint16 traitId) external view returns (uint8);                 // 0 direct, 1 chain, 2 panel, 3 shared
```

Events: `CardMinted(address indexed claimant, uint256 indexed tokenId)`, `TraitRequested(address indexed claimant,
uint16 indexed traitId, bytes32 requestId, bytes32 questionHash)`, `Verified(address indexed claimant, uint16 indexed
traitId, bytes32 requestId, bytes32 oracleRequestId)`, `Missed(bytes32 requestId, uint16 traitId, uint8 reason)`,
`NoVerdict(bytes32 requestId, uint16 traitId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered)`,
`Abandoned(bytes32 requestId)`, `SpecRegistered(uint16 indexed traitId, address indexed registrant)`,
`SharedFactStored(uint16 indexed factId, bytes32 requestId, uint16 length)`, `Sponsored(address indexed from, uint256
amount)`, `PoolSpent(address indexed claimant, uint16 indexed traitId, bytes32 requestId)`, and ERC-4906
`MetadataUpdate`. The burn rule adds `BurnTriggered(address indexed claimant, uint256 amount, uint256 nativeFee)`
and `BurnSkipped(address indexed claimant, uint8 code)` (1 preview reverted, 2 bridge reverted, 3 quote over cap).

Both pool paths share **one catalog chain request per wallet per UTC day** (`block.timestamp / 1 days`), from
launch with no 30-day wait. `poolUsed` limits each `(wallet, traitId)` to one request ever, so the nine eligible
traits give **nine per wallet over its lifetime**, across both paths and all IDMD tokens. IDMD holders must also
be list members; `upgradeSponsored` allows nine requests per token over its lifetime, including after transfer.
An empty array reverts `NoTraits`, more than one id reverts `TooManyTraits`, a same-day request for another trait
reverts `PoolDailyLimit(wallet)`, and an exhausted token reverts `IdmdSponsorExhausted(tokenId)`. A reverted
transaction consumes no allowance; a submitted request consumes its day and lifetime allowance even if the
oracle later misses, fails or never answers. Paid `upgrade` and `requestSharedFact` have no daily or sponsored
lifetime limit. The 6.4 IMD spec fee plus a first request at the 0.5 IMD oracle price totals 6.9 IMD (excluding gas).

After 14 days, only the stored claimant may abandon a personal pending request, including a sponsored one;
a stranger gets `NotClaimant()`. A shared fact has no claimant and anyone may abandon it. Abandoning clears the
pending pair, returns no price and restores no sponsored allowance; a late callback for that id leaves a successor
request untouched. A valid late answer can still settle a request that has not been abandoned.

Every oracle question is about Ethereum mainnet (`chainId: 1`). The body's `consumer.chainId` and the EIP-712
signing domain use the deployment chain (11155111 on Sepolia); the canonical question hash excludes `consumer`.
Mainnet bodies remain byte-identical to the committed fixtures. Because the question is about mainnet, two
things do not follow the deployment chain: every catalog question names the mainnet Curator
(`Composer.MAINNET_CURATOR`, `0xcb0b0531e86a9ac36fa865ca8e3dbccf047fda91`) whatever `curator` the registry holds,
so a Sepolia body is the mainnet fixture with only `consumer.chainId` changed and the same question hash; and
`registerSpec` bounds a window by the mainnet height, which is `block.number` on chain 1 and, elsewhere,
`Composer.mainnetHeightBound()`, one block per 12-second slot since the merge (never below the real height, about
0.3% above it). The registry's `curator` argument serves the direct-read traits (101 to 601) only, which do read the
deployment chain's Curator.

Function and event names in this summary are the working names of the interface and did not change in the rename
(only display strings did). Types, arities and the behaviour described in `CONCEPT.md` are the
contract; a builder who finds a reason to change one writes it in the submission's notes rather than silently.

## Free claims and the burn rule

Both sponsored entry points are payable. They still buy one oracle request with pool IMD, then attempt to bridge
IMD already held by BurnExecutor V2 at `0xe29386719C155B6847aD5a4E97C6674f10ffc750` to its configured Base burn
receiver. The claimant supplies only the native LayerZero fee; the registry does not transfer pool IMD to the
executor. Paid upgrades and shared-fact requests remain non-payable and do not run this rule.

After all eligibility checks and the oracle request, the registry calls `previewBridge()` with
**`PREVIEW_GAS` = 600,000** gas. The executor catches its inner OFT quote running out of gas and answers `(0,0,0)`
instead of reverting: measured against the real BurnExecutor V2 on 2026-10-16, an `eth_call` at block 26,202,500
returns zeros below about 272,000 gas at the CALL and the real quote above it, and a cold fork trace at block
26,202,203 shows 264,408 gas. The earlier 200,000 cap therefore never burned on mainnet; 600,000 is 2.2 times the
measured need and below `BURN_GAS`. If the quoted amount is at least **69 IMD** and the native fee is at most
**0.005 ETH**, the caller must attach at least that fee or the whole transaction reverts `BurnFeeRequired(nativeFee)`
(all pool allowances and the oracle request roll back). The registry forwards **all `msg.value`** to
`bridgeToBaseBurnReceiver(amount, msg.sender)` with a CALL gas argument of **800,000**, plus the EVM's 2,300
stipend for nonzero value. On success the executor pays the fee and refunds the surplus directly to the claimant
(a plain call first, a forced send if the claimant rejects it); the registry refunds nothing.

**Attach exactly the fee quoted in the same block.** The executor re-quotes when it bridges and keeps the whole
attachment if that quote rose above the registry's preview; a surplus is returned only when the bridge quote is at
or below what was attached. Read `previewBridge()` in the block of the claim (`eth_call` with at least 300,000 gas)
and attach its `nativeFee`.

A reverting preview skips with code 1; a reverting bridge skips with code 2 and leaves the oracle request pending;
a quote over the cap skips with code 3. Below-threshold and disabled-executor skips emit no burn event. On every
skip the registry returns all attached ETH by a plain call, only when nonzero, and requires success. Thus a
nonpayable contract can claim with no ETH when no fee is due, or with the exact fee (and even surplus) when the
executor succeeds, but cannot reject a nonzero registry refund. `BurnRefundFailed()` rolls back such a transaction.
The registry's ETH balance after each accepted free claim equals its balance before; pre-existing ETH is neither
a precondition nor spent. There is still no `receive` or `fallback`.

**At the pinned block the rule burns.** At mainnet block **26,202,203** the executor holds
454,939,975,535,748,811,691 IMD units and quotes 454,939,975,000,000,000,000 units for 219,261,761,563,315 wei;
with the corrected cap the registry's preview returns that quote, and the fork tests (`test/fork/BurnRule.fork.t.sol`)
make a cold sponsored claim burn through the real executor, OFT and endpoint: `BurnTriggered(claimant, amount, fee)`,
only shared-decimal dust left in the executor, the surplus back from the executor, the registry's ETH balance
unchanged, and the same claim without the fee reverting `BurnFeeRequired(fee)` with no oracle request. The rule
stays best effort: this is the behaviour at one block, not a promise of future liveness.

**Residuals, stated.** Outside the empty dependency floor described below, the constructor rejects a nonzero
`burnExecutor` without code (`ExecutorHasNoCode()`),
because the preview's three return words are decoded outside the `try`/`catch`, and an executor that cannot be
decoded would revert every sponsored claim for ever in a registry nobody can repair. A coded executor that returns
fewer than three words still reverts a claim; no low-level call is added for it. The executor's owner can change
its token, OFT, destination, options and minimum batch, and rescue funds; the OFT and LayerZero have their own
configuration authorities. A future quote needing more than `PREVIEW_GAS` is a skip with code 1, and one above
`BURN_FEE_CAP` a skip with code 3; neither blocks the claim. A successful Ethereum bridge submission is not proof of
the later, asynchronous Base burn. Integrators must monitor those dependencies and message delivery. Neither the
registry nor these tests promise that executor dependencies cannot call the claimant. The registry has no
administrator; `burnExecutor` is its eighth constructor argument, fixed in ordinary storage. See `INTEGRATION.md`
section 5b and `DISCLOSURE.md`.

## Build

```sh
git clone --recursive <this repository>
forge build
forge test                       # hermetic: no RPC, no ffi
forge fmt --check
CHAINTRAITS_FORK_RPC=<mainnet archive RPC URL> forge test --match-path 'test/fork/*'   # the fork tests, block 26,170,000
forge test --match-contract BurnRuleForkTest --fork-url <mainnet archive RPC URL> --fork-block-number 26202203
python3 tools/gen_template.py --check    # the envelope blob, offsets, hive data and goldens are byte-exact
```

`python3 tools/gen_template.py` regenerates `template/blob.hex`, `template/offsets.txt`, `src/TemplateData.sol`,
`src/HiveData.sol` and the goldens under `test/fixtures/`; `--check` and `python3 -m unittest discover -s tools` pass
on a clean tree. There is no SVG template file: the generator's `hive_svg` is the normative drawing of the card
image, and the generator precomputes every coordinate string the Renderer needs (see "The card image" below).

### The card image

The card image is a **hive symbol**: thirteen flat-topped hexagonal cells on a dark ground, one per family in catalog
order, with Armed in the centre, the five Curator families around it and the seven oracle families on the outer ring.
A cell's outline takes the family's class colour (direct `#00cc33`, chain `#00ff41`, shared `#dbfee6`, panel
`#8ff0a4`) when the family has a trait and `#151515` when it has none; a lit cell is filled, and a family that is
part way up its tiers (201 of 202; 301, 302 of 303; 401 to 403 of 404; 501, 502 of 503) is filled with "honey" from
the bottom to `lv/n` of its height, the rest of its rings outlined above the line. The first 39 verified community
specs add up to three concentric rings per cell (spec 1 to 13 the outer ring of each slot, 14 to 26 the middle, 27 to
39 the inner one; the rings are tinted in a lit cell and outlined in a dark one). A white dot marks a rare top tier
(202, 801, 901, 1001, 1101 to 1104, 1201; never 1105). A thin ring hexagon frames the hive; from the fortieth
community spec on, a path runs around it that grows with the eighth power of `community_count`: 2 of 64 steps at 40,
9 at 70, 58 at 5000 and the full ring from 8192 on. The token id is printed at the bottom right. The hive shows no
address and no family label: those stay in the JSON attributes, which the image change did not touch (every key and
byte of the metadata other than the `image` value is as before).

Onchain there is no trigonometry. `tools/gen_template.py` computes every point string of the drawing once (the five
hexagons of each cell, the eight honey/above polygon pairs, the ring, its six corners, the 62 interpolated path end
points and the thirteen cell centres), percent-encodes them exactly as the data URI needs, and writes them to
`src/HiveData.sol` with the fixed markup fragments, colours and opacities. The Renderer selects strings by index and
concatenates them; `Renderer.image(card)` is the percent-encoded SVG, and `python3 tools/gen_template.py --check`
fails if the committed data or any golden drifts from the generator. The eight goldens (`synthetic_direct`,
`synthetic_oracle`, `synthetic_width`, `synthetic_newcomer`, `synthetic_outsider`, `synthetic_honey`,
`synthetic_collector`, `synthetic_fullhouse`) cover an empty hive, a single lit cell, every part-filled tier, every
rare dot, zero to three rings, no path, a short path and a six-segment path; `test/Goldens.t.sol` proves the Solidity
output equal to each of them byte for byte and pins the step table, the rare-dot rule and the ring counts directly.

The fork tests are in `test/fork/Mainnet.fork.t.sol` (eleven tests at the pinned block 26,170,000: the real Curator,
IDMD, IMD and Intake v2, with the registry deployed on top and a request completed by the real `complete` under the
real stipend). Run them by setting `CHAINTRAITS_FORK_RPC` to an Ethereum mainnet RPC URL that serves that block
(archive state), for example `CHAINTRAITS_FORK_RPC=https://ethereum-rpc.publicnode.com forge test --match-path
'test/fork/*' -vv`. They only read the variable; without it they skip, so plain `forge test` stays hermetic and needs
no network. The new `test/fork/BurnRule.fork.t.sol` uses the CLI fork arguments above, reads no environment
variables, checks the chain/block/parent hash, and skips when there is no active fork. Run it separately from the
older fork suite because the block pins differ. Burn unit/fuzz and stateful invariant tests run without a network.

`foundry.toml` pins solc 0.8.24, `bytecode_hash = "none"` and `cbor_metadata = false`: a clean rebuild of a commit
is byte-identical, which is how the deployed runtime code is checked against the reviewed source after launch. That
check also needs **no `immutable` anywhere**, including inherited ones (OpenZeppelin's `EIP712` base has seven; do not
inherit it, see `INTEGRATION.md` section 4). `fs_permissions` allows tests to read `template/`, `templates/fixtures/`,
`test/fixtures/`, `out/` and `reference/{attestations,intake,plane}/`. Submodules: forge-std v1.9.7 and OpenZeppelin
at `cab19933` (both as in the record NFT this mirrors).

## What the builder delivers

- `src/Registry.sol` (working name), `src/Renderer.sol`, `src/interfaces/{IIntake,IOracleConsumer,IBurnExecutor}.sol`, the
  catalog as constants (ids, rules, windows from `CATALOG.md` sections 1 to 3), the name table, the template
  composer for the five templates **and the canonical question document plus its keccak** (`INTEGRATION.md` section
  4, check 7), the `Spec` struct of `CATALOG.md` section 5, no `immutable` anywhere.
- `tools/gen_template.py` as the normative drawing of the hive card (`hive_svg`) and the source of
  `src/TemplateData.sol` and `src/HiveData.sol`; goldens under `test/fixtures/` for synthetic wallets only (the
  convention `0x…c1a1`; never a real wallet).
- Tests for every invariant in `CONCEPT.md` section 6: unit, fuzz, invariant; fork tests against the mainnet Curator
  at a pinned recent block (skipped without `CHAINTRAITS_FORK_RPC`); golden tests that `tokenURI` bytes equal the
  generator's; golden tests that the composed request bodies equal `templates/fixtures/*.json` byte for byte and that
  `questionHashOf` of each fixture's canonical document (not its body) equals `reference/plane/questionHashes.json` for all ten; a gas test that `onResult` stays under the
  Intake's callback stipend in the worst case; signature-recovery tests over the five served attestations in
  `reference/attestations/` (three under the zero domain, two under their consumer's domain; the loader maps the JSON
  `answerType` name to its uint8 code); a test that both artifacts have empty `immutableReferences` and that two
  deployments have identical runtime code; a mock Intake v2 that forwards with the real 200,000 stipend and exercises
  `onResult`, `onFailure`, malformed envelopes and the transition table of `INTEGRATION.md` section 4b.
- A README section **"How to verify a card"**: how a third party reruns a trait's recipe against public RPCs from the
  metadata alone, fetches the served attestation by `oracleRequestId`, and compares the deployed runtime code with a
  rebuild.
- `script/Deploy.s.sol` that deploys renderer, composer and registry with six external addresses, plus the same shape as a
  launch-pipeline input (constructor arguments only).

## How to verify a card

A card proves facts about its **claimant** (`claimantOf(tokenId)`), never about `ownerOf`. Everything below needs
only public RPCs, the plane's public attestation endpoint and this repository. The same steps apply to
`hasTrait(wallet, traitId)` for a wallet without a card.

**1. Read the registry.** `verified(claimant, traitId)` returns `(requestId, oracleRequestId, fromBlock, toBlock)`:
a zero `requestId` means the trait was never verified. `tokenURI(tokenId)` decodes (Base64, then JSON) to a document
whose `oracle` array carries, for every verified oracle trait: `template` (T1 to T5), `evidence`, `fromBlock`,
`toBlock`, `minPanelSize`, `minQuorum`, the Intake `requestId`, the plane's `oracleRequestId`, and the recipe parameters
(`target`, `item`, `arg`, `fixedArg`, `fixedVal`, `sumArg`, `op`, `threshold`). `composeBody(traitId, claimant)`
returns the exact question the registry asked, for free. `minPanelSize` and `minQuorum` are the registry's
acceptance minima (5/3 for chain, 11/7 for panel), not the signed panel values. The signed `panelSize`, `quorum`
and `agreed` are in the served attestation at `/oracle/requests/<oracleRequestId>/attestation` (step 3).
The standard `attributes` array includes the first 32 verified community ids in verification order, as
`{"trait_type":"Community <id>","value":"<spec name>"}`, plus `community_count` with the full count.
The custom `community` array retains those same ids. PID (family 11, working name Ordinal) displays the lowest verified id;
other tier families display their highest id.

**2. Rerun the recipe against two public RPCs** (CATALOG.md section 1 lists endpoints that served these windows;
hex block numbers, chunks of at most 1,500 blocks for `eth_getLogs`):

- Topics come from the stored `item`, never from an assumed layout. `topic0` is `keccak256` of the item's canonical
  event signature: the event name and the parameter types in order, comma-separated, without names, `indexed` or
  spaces (`event Transfer(address indexed from, address indexed to, uint256 value)` gives
  `keccak256("Transfer(address,address,uint256)")`). The indexed parameters then take `topic1`, `topic2`, `topic3` in
  the order they are declared; non-indexed parameters take no topic. The claimant goes in the topic of the indexed
  parameter named `arg` (left-padded to 32 bytes), `fixedVal` (as a 32-byte word) in the topic of the indexed
  parameter named `fixedArg` when it is set, and every other topic position stays open (`null` in the filter). So
  that `Transfer` item with `arg = "to"` puts the claimant in `topic2` and leaves `topic1` open; the catalog's
  `Deposited`, `FirstDeposit` and `HourSaved` items happen to declare the claimant argument first, so for them it is
  `topic1` (and `hour` or `index`, the `fixedArg`, is `topic2`).
- T1 log-count (701, 801, 901, 1001, 1101 to 1105, T1 specs): `eth_getLogs` on `target` with the topics above, from
  `fromBlock` to `toBlock`; the trait holds if the count is at least `threshold`.
- T2 log-sum: the same query; sum `sumArg` (decoded from the log's data, or from its topic if it is indexed) over the
  matching logs.
- T3 log-rank (1201): `eth_getLogs` with only `topic0` set for every `item` log in the window, group by `arg` (read
  from its topic position as above), sum `sumArg`, sort
  descending by sum then ascending by address; the claimant must be within the first `threshold` (32). The list the
  registry hashed is public: it is `a.answer` in the `complete` transaction's calldata and in the served attestation;
  `sharedFact(1201)` returns `keccak256(abi.encode(list))` and its length.
- T4 call-compare: one `eth_call` of `item` with the claimant at block `toBlock`; compare with `threshold` using `op`.
- T5 panel nonce (1301, T5 specs): `eth_getTransactionCount(claimant, toBlock)` on an archive endpoint; the trait
  holds if the nonce is at least `threshold` (20 for 1301).
- Direct-read traits (101 to 601) need no attestation: call the Curator's `firstHourOf`, `txCountOf`,
  `contributedBy`, `pointsOf` or IDMD `balanceOf` at any block since settlement (601 is live and may change).

**3. Fetch and check the attestation.** `GET https://<plane>/oracle/requests/<uuid>/attestation`, where the UUID is
the first 16 bytes of `oracleRequestId` formatted `8-4-4-4-12`. Check `message.questionHash ==
keccak256(canonical document)`, where the document is the body of step 1 reduced as `INTEGRATION.md` section 4,
check 7 describes (`questionHashOf(bytes canonicalDocument)` recomputes the keccak onchain; pass it the canonical
document, **not** the body: the body's keccak is a different value; `reference/plane/questionHashes.json` has ten
worked examples), that `fromBlock`/`toBlock` equal step 1, that `agreed >= quorum`, and recover the signer of the
EIP-712 digest under domain `{IdentityMD Oracle, 2, <deployment chainId>, <registry address>}` (`attestationDigest(a)` on the registry
returns the digest; `cast wallet verify` or any EIP-712 library reproduces it). The signer must be
`0x5598aa9146215bc13eb26f2c692ad1461fd32982`.

**4. Compare the deployed code with a rebuild.** `git checkout <reviewed commit> && forge build`, then
`cast code <registry> --rpc-url <rpc>` must equal `out/Registry.sol/Registry.json` `.deployedBytecode.object`
byte for byte (likewise `Renderer` and `Composer`). `foundry.toml` pins solc 0.8.24, `bytecode_hash = "none"`,
`cbor_metadata = false`, and no contract has an `immutable`, so the comparison is exact. Then read the five addresses
(`curator()`, `idmd()`, `imd()`, `intake()`, `attester()`), `burnExecutor()` and the two helpers (`renderer()`, `composer()`) from the
deployed registry and compare them with `INTEGRATION.md` section 1 and the launch record.

## What was built, and where it deviates from the brief

Everything in "What the builder delivers" is in the tree, with these deviations, each with its reason:

- **Three contracts, eight constructor arguments.** `Registry(curator, idmd, imd, intake, attester, renderer,
  composer, burnExecutor)`. The burn rule adds the eighth; zero still disables it, but both launch parameter sets
  use nonzero executors.
  The brief allowed a sixth address if the pipeline refuses a constructor that creates a contract; here
  the limit is EIP-3860: with both helpers' creation code embedded, the registry's init code was 56,723 bytes
  (> 49,152). `Renderer` and `Composer` take no constructor arguments and hold no storage, so the launch is three
  static deployments with the helpers referenced backward (`script/Deploy.s.sol` does exactly that; the registry
  constructor stores every address in ordinary storage). Unless all four of Curator, IDMD, IMD and Intake lack
  code, it requires IDMD code, `curator.isSettled()`, a nonzero Intake IMD quote and code at a nonzero executor.
  Only that all-four-empty floor skips the checks, allowing the pipeline's empty-chain deployment probe.
- **`src/Composer.sol`** holds the five templates, the body and canonical-document serialisers, the catalog oracle
  traits as `Spec`s (`catalogSpec`), the spec guards (`validateSpec`), the catalog name table (`traitName`), catalog enumeration (`traitsOf`)
  and the unchanged direct-read predicates (`hasDirectTrait`). The registry alone was 41,717 bytes of runtime;
  it was 23,364 after the Registry rules update, 24,495 after the burn rule and is **24,561 after the launch
  corrections**, with **15 bytes** of EIP-170 headroom. Local factoring shares the membership and pool checks
  without changing their order. Composer is **23,655 bytes**, up from 23,402 after the Sepolia rehearsal corrections (921 bytes of headroom), and
  Renderer is unchanged at 21,570 bytes
  with the hive card (3,006 bytes of headroom; it was 11,712 with the text grid); `test/Rename.t.sol` pins the
  Composer budget and `test/Artifacts.t.sol` the EIP-170 limit of all three.
  The registry calls the composer
  only in user transactions and views, never inside `onResult`.
- **`verified()` derives the window from the rule** instead of storing it: check 6 makes the attested window equal
  the trait's canonical window (or the spec's), so storing it would be redundant and cost a third cold slot in
  `onResult`. Worst case measured (community id appended, card to refresh, cold storage): 164,954 gas under the
  200,000 stipend, delivered through the mock Intake's real `call(stipend, ...)`.
- **Added views:** `pendingRequest(requestId)`, `cardOf(tokenId)` (the renderer's input), `attestationDigest(a)`,
  `questionHashOf(bytes canonicalDocument)` (the keccak of the canonical document of `INTEGRATION.md` section 4,
  check 7, not of the body `composeBody` returns), `sharedPending(factId)`, `idmdSponsored(id)`, `lastPoolDay(wallet)`. `traitClass` and
  `specOf` revert for an unknown id; `hasTrait` never does.
- **`template/offsets` and the hive start tables live in the code as ASCII hex**, not packed bytes: the launch's
  opcode scan reads every non-PUSH byte of the runtime, and a packed offset `0x0cf2` would read as `CALLCODE`. The
  envelope blob and the hive strings are ASCII (percent-encoded).
- **Goldens:** eight synthetic cards (`0x…c1a1`, `0x…ac1a1`, `0xff…c1a1`, `0x…3c1a1` to `0x…7c1a1`), two rendered
  through the registry and the mocks, six through the renderer alone (width and escaping, and the hive states listed
  under "The card image"). `tools/rasterize_goldens.py` and its test were removed: they rasterised THE LIST's goldens
  with a pinned macOS font and were never a gate.
- The `Verified` event keeps its name; the storage struct is `VerifiedEntry`.

### Deployment parameters and operational notes

| argument | mainnet value |
|---|---|
| `curator` | `0xcB0b0531e86A9aC36Fa865cA8e3dbccF047FDA91` |
| `idmd` | `0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D` |
| `imd` | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| `intake` | `0xa43e6F75ee006411F79Ac1C84120606C2330DE82` (Intake v2) |
| `attester` | `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982` |
| `renderer`, `composer` | the two helper deployments of the same commit |
| `burnExecutor` (eighth) | `0xe29386719C155B6847aD5a4E97C6674f10ffc750` (BurnExecutor V2) |

`run()` uses `deployForChain()`: chain 11155111 selects these Sepolia overrides; every other chain selects the
mainnet constants above. Intake and attester are the same in both sets; helpers are deployed from the same build.

| argument | Sepolia value (11155111) |
|---|---|
| `curator` | `0x0919ba50b206C3F31D516De818b1fBc7dA21653D` |
| `idmd` | `0x2C3013c90a1Bb65573aae9a7C64fafB82697E4e4` |
| `imd` | `0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A` (TestIMD) |
| `burnExecutor` | `0x097A19e0f021BBA5072701132625ad2401043A2E` (BurnExecutor V1) |

The constructor keeps the seven nonzero-address checks. It skips dependency checks **only when all four of
Curator, IDMD, IMD and Intake lack code**: the launch pipeline's empty-chain floor. On that floor it makes no
external call and also skips the executor code check; the factory can deploy Renderer, Composer and Registry in
order using the real arguments. This proves deployability, not operational readiness.

Otherwise IDMD must have code (`DependencyHasNoCode()`); the Curator must answer `isSettled() == true`
(`"Curator not settled"`); `IIntake(intake).priceOf(ACTION, imd)` must be nonzero (`"Intake price"`); and a nonzero
executor must have code (`ExecutorHasNoCode()`). Unavailable Curator or Intake calls revert construction. The two
view reads move no funds; the quote check confirms a configured action/asset price, not dependency identity or
future availability. The daily counter assumes a deployment after Unix day zero (Ethereum mainnet in
2026); its zero default then never equals the current UTC day. The deployer
must verify the eight constructor addresses and both helpers' runtime code against the reviewed build; none can
be changed later. This assignment deploys nothing.

The registry has no owner: no setter, pause, upgrade, fee switch, `receive` or `fallback`. The
accepted ways the registry can stop working are listed in `INTEGRATION.md` section 1 (Intake price, callback gas or
retirement; attester rotation; a changed attestation struct or canonical document); each needs a successor contract.
The Sepolia executor is a coded V1 whose `previewBridge()` reverts, so free claims there skip the burn with
code 1. On Sepolia the catalog oracle questions still name the mainnet Curator and community specs are bounded by
the mainnet height (see "Every oracle question is about Ethereum mainnet" above), so the rehearsal can register
the game's windows and verify catalog traits; the Sepolia Curator and IDMD stand-ins gate only the direct reads,
membership and the sponsored pool. The Sepolia Intake grants callbacks 1,000,000 gas (mainnet: 200,000), so the
mainnet stipend is proven by the unit tests, not by a Sepolia delivery.
The launch script never selects a zero executor (the launch manifest rejects one). The six-argument
`deploy(curator, idmd, imd, intake, attester, burnExecutor)` remains available for explicit configurations; zero
still disables the rule at the contract level. The constructor never calls the executor and checks its code
outside the all-four-empty floor. No executor setter or new owner role is added to the registry.
Before launch the operator verifies the executor's current `token`, `oft`, `dstEid`, `baseBurnReceiver`,
`extraOptions`, `minBridgeAmount` and ownership, and the OFT peer/LayerZero configuration. After launch they monitor
`BurnTriggered`/`BurnSkipped`, zero previews, quotes, delivery and Base burns; they cannot repair the registry.
The executor and OFT owners remain responsible for their configurations and bridge operation.

Pool money is an irrevocable donation. Users approve the registry for IMD (0.1 mint, 6.4 per spec, `k x priceOf` per
upgrade, read at call time and capped by `maxPrice`).

## License

MIT (`LICENSE`). The vendored THE LIST record NFT under `reference/list-record/` is MIT as well.
