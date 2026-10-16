# INTEGRATION.md: the Intake, the attestation, the external contracts

The registry is Sworn (`ERC721("Sworn", "SWORN")`). Everything the registry talks to, as measured on Ethereum mainnet on 2026-10-10 to 2026-10-12. Sources are vendored
under `reference/` (see `reference/PROVENANCE.md`). Where this file and a skill disagree, re-read the verified
source in `reference/IntakeV2.sol`; it is the contract that runs.

**Round 2 (2026-10-12) changed this file in five places**, each from a measurement, each with its evidence vendored:
the plane moved to Intake v2 (section 1); the attestation's signed `requestId` is the plane's own id, not the Intake's
(section 4, check 1); the domain's `verifyingContract` is the body's `consumer` field (section 4); the plane's
`questionHash` is a keccak of a canonical JSON document the registry can recompute, which is now the binding between
a pending request and its attestation (section 4, check 7); and Intake v2's failure hook delivers refusals and failed
panels (section 3).

## 1. Addresses (Ethereum mainnet, chainId 1)

| what | address |
|---|---|
| WhitelistCurator (THE LIST) | `0xcB0b0531e86A9aC36Fa865cA8e3dbccF047FDA91` |
| IdentityMD collection (IDMD, ERC-721, 2,000 tokens) | `0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D` |
| IMD token (ERC-20, 18 decimals, a LayerZero OFT, **no `permit`**) | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| **IMD Intake v2** (pay and ask in one transaction; the one the registry uses) | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| IMD Intake v1 (legacy; `/health.intake.chains[].legacyIntakes`; still priced and still completed) | `0x1397434cd35e8a9c8ac312a61d3a285eb31dea56` |
| oracle attester (signs attestations) | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| IMD BurnExecutor V2 (free-claim bridge) | `0xe29386719C155B6847aD5a4E97C6674f10ffc750` |
| Intake writer (calls `complete`) | `0x3d3c0df7c1a17d384545e9d7c8228897bd9625cb` |

Intake v2 was deployed through CREATE2 at the same address on every chain the plane serves; `/health` lists it as
`intake` for chains 1, 4663 and 11155111 with v1 under `legacyIntakes`. Its source says "every function, event and
getter of version 1 is here unchanged"; `requestWithFailure`, `failureSelectorOf` and `FailureHookSet` are new. Both
addresses return `priceOf` 0.5 IMD, `callbackGas` 200,000 and the same writer (read 2026-10-12 00:30 UTC) on
mainnet. The same Intake v2 on Sepolia returns `callbackGas` 1,000,000 (read 2026-10-16), so a Sepolia completion
does not exercise the mainnet stipend; the 200,000-gas budget is proven by the unit tests (section 3, `test_onResultGasWorstCase`).

On Sepolia (11155111), `Deploy.deployForChain()` uses Curator
`0x0919ba50b206C3F31D516De818b1fBc7dA21653D`, IDMD `0x2C3013c90a1Bb65573aae9a7C64fafB82697E4e4`,
TestIMD `0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A` and BurnExecutor V1
`0x097A19e0f021BBA5072701132625ad2401043A2E`, with the same Intake v2 and attester as above. Every other chain
selects the mainnet constants. `run()` calls this function; no environment or caller-dependent choice is involved.
The Sepolia V1 has code but its `previewBridge()` reverts, so the burn rule skips with code 1 there.
Two things never follow the deployment chain, because every question is about mainnet: the catalog questions name
the mainnet Curator (`Composer.MAINNET_CURATOR`), not the `curator` argument, so a Sepolia body is the mainnet body
with only `consumer.chainId` changed and carries the same question hash; and `registerSpec` bounds a window by the
mainnet height (`block.number` on chain 1, else `Composer.mainnetHeightBound()`, the slot-clock upper bound), so
the game's windows register on Sepolia. The `curator` argument serves the direct reads (101 to 601) only.

The launch is three contracts, `Renderer`, `Composer` and `Registry`. The registry takes eight constructor arguments,
`(curator, idmd, imd, intake, attester, renderer, composer, burnExecutor)`: the original five external addresses,
the burn executor and the two helpers,
deployed first from the same commit and passed in as static addresses (README, "What was built, and where it deviates
from the brief": with both helpers embedded the registry's init code exceeded EIP-3860). The launch pipeline allows
only static address, uint, bool and bytes32 arguments, at most 16; "passive" means the constructor stores its
arguments and may read views, but creates no contract, moves no funds and takes no external callback.
The seven nonzero-address checks always apply. Dependency checks are skipped **only when all four of Curator,
IDMD, IMD and Intake lack code**. This empty-chain floor also skips the executor code check and makes no external
call, so the pipeline's factory probe can deploy the three creation codes with their actual launch arguments.
If any of those four has code, IDMD must have code (`DependencyHasNoCode()`), the Curator must answer
`isSettled() == true` (`"Curator not settled"`), the Intake must quote a nonzero `priceOf(ACTION, imd)`
(`"Intake price"`), and a nonzero executor must have code (`ExecutorHasNoCode()`). Unavailable Curator or Intake
calls also revert. The executor is never called by the constructor. Zero still disables the burn rule at the
contract level, but the mainnet and Sepolia launch sets both use nonzero executors; the launch manifest rejects
zero. The deployer must verify the addresses, helper code and operational dependencies before launch: a floor
probe is not that verification. The registry has no setter for any dependency.
The writer is not a constructor argument: the registry trusts the Intake as `msg.sender` of the callback and the
attester as the signer, never the writer. **Store the eight addresses in ordinary storage, not `immutable`:** immutables
are patched into the runtime code at deployment, and the launch check compares the deployed runtime code with a clean
rebuild byte for byte. The same holds for the renderer (`bytes constant`, never an SSTORE2 pointer in an immutable)
and for the EIP-712 domain (section 4: computed at verification time, never OpenZeppelin's `EIP712` base, which holds
seven immutables).

### What can kill the registry (accepted, written down for the audit)

The registry is ownerless, so none of these has a remedy inside it; each needs a successor contract.

- The Intake's owner can `setPrice(action, IMD, 0)`: `request` then reverts `ActionNotSold` and every `upgrade`
  reverts. It can `setCallbackGas` below what `onResult` needs: every callback then fails and no oracle trait can ever
  be verified. It can `setWriter`, `setPayTo`, `setSigner`. The plane can retire v2 for a v3 as it retired v1.
- The attester `0x5598…` is a constant; if the plane rotates the key, every later attestation is a miss. The
  registry cannot tell: `claimSponsored` and `upgradeSponsored` keep forwarding 0.5 IMD of pool money per request
  for answers that can no longer verify, until the pool is empty, and nothing in the registry can recover it.
- The plane may change the attestation struct or the action version string. It did change the struct once before
  2026-10-10 (an earlier record shows a shape without the three panel fields); every completion measured since (five,
  on both Intakes, `reference/intake/completions.json`) carries the 15-field shape, and the registry accepts only that.
- The plane may change the canonical question document behind `questionHash` (section 4, check 7); every later
  attestation then misses with reason 10. A live mainnet consumer (`SwarmFeed`, the one behind the Intake v2
  completions) recomputes the same document onchain, so the format is relied upon beyond this registry.
- The Curator is settled and its state is final. IDMD's code is immutable, but ownership is live: the Armed trait
  (601) changes when an IDMD moves, by design (`CATALOG.md` section 3).

## 2. Asking: `Intake.requestWithFailure`

```solidity
struct Callback { address target; bytes4 selector; }
function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
    external payable returns (bytes32 requestId);
function requestWithFailure(bytes32 action, bytes calldata body, Callback calldata callback, bytes4 onFailure,
    address asset, uint256 amount) external payable returns (bytes32 requestId);
function priceOf(bytes32 action, address asset) external view returns (uint256);
function callbackGas() external view returns (uint64);
function failureSelectorOf(bytes32 requestId) external view returns (bytes4);
```

- The registry calls **`requestWithFailure`** with `callback = (address(this), this.onResult.selector)` and
  `onFailure = this.onFailure.selector`, so a refusal or a failed panel reaches the registry too (section 3).
- `action` is the action name, an at sign and the version, as a right-padded `bytes32`:
  **`oracle.request@oracle-1`** = `0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000`.
  `priceOf(action, IMD)` returned `500000000000000000` (0.5 IMD) on 2026-10-12; the other spellings return 0 and
  `request` reverts `ActionNotSold`. Read `priceOf` at call time and pay exactly that: the registry must never
  hard-code 0.5 IMD, and the claimant's `upgrade` charges `k * priceOf(...)`.
- `body` is the UTF-8 JSON of `TEMPLATES.md`, at most `MAX_BODY_BYTES` = 16,384 bytes. **It carries
  `"consumer": {"chainId": <deployment chainId>, "verifyingContract": "<the registry, lowercase hex>"}`**:
  `consumer.chainId` is `block.chainid` (11155111 on Sepolia), and that field supplies the EIP-712 domain
  (section 4). The top-level question `chainId` stays 1: every question is about Ethereum mainnet.
- `asset` is the IMD token; the Intake pulls `amount` with `transferFrom`, so the registry approves the Intake for
  the amount before calling. The claimant approves the registry; the registry pulls, then forwards.
- `requestId = keccak256(abi.encode(block.chainid, address(intake), ++nonce))` is returned and emitted in
  `Requested(requestId, payer, action, body, callbackTarget, callbackSelector, asset, amount)`, followed by
  `FailureHookSet(requestId, onFailure)`. **This id is the Intake's. The plane gives the same request a second id, a
  UUID, and that is the one it signs** (section 4).
- The plane reads `Requested`, admits or refuses the body, pins `toBlockHash`, runs the panel, and the writer calls
  `complete`.

## 3. Answering: what reaches `onResult` and `onFailure`

```solidity
function complete(bytes32 requestId, uint8 status, bytes32 resultHash, string calldata uri, bytes calldata args)
```

`status` 0 = a result, 1 = refused, 2 = ended without a result (a panel that disagreed, `not_answerable`). The Intake
sends `bytes.concat(selector, args)` to `callback.target` with a fixed gas stipend of **`callbackGas()` = 200,000**
(read it; it is settable by the Intake's owner), no value, and records `delivered` without reverting the writer's
transaction. A callback that reverts or runs out of gas is simply `delivered == false`: the request is still
`completed` and will never be retried.

- **Status 0** calls the result selector with `args = abi.encode(bytes32 requestId, OracleAttestation a, bytes
  signature)`:

  ```solidity
  function onResult(bytes32 requestId, OracleAttestation calldata a, bytes calldata signature) external;
  ```

- **Status 1 and 2** call the failure selector the request named, with `args = abi.encode(bytes32 requestId, uint8
  status, bytes32 reason, uint16 agreed, uint16 answered, bytes signature)`. The Intake itself checks that the first
  two words equal this request and this status (`FailureArgsMismatch` otherwise), and calls nothing when `args` is
  empty:

  ```solidity
  function onFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered,
      bytes calldata signature) external;
  ```

  The registry checks `msg.sender == intake` and that `pending[requestId]` exists, clears the pending pair, emits
  `NoVerdict(requestId, traitId, status, reason, agreed, answered)` and never marks a trait. It does not interpret
  `signature` (its scheme is undocumented; the Intake and the writer authenticate the call). A claimant may request
  the same trait again afterwards.

- `onResult` must finish well inside 200,000 gas: one `ecrecover` (3,000), the digest, a few `sload`s, three or four
  `sstore`s, two events. The only loop is the `head`-bounded envelope check of T3 (at most 64 words).
- `onResult` and `onFailure` never revert on an ABI-valid envelope with bad content; they record a miss
  (`Missed(requestId, traitId, reason)`) and return. Calldata that does not decode as the declared tuple fails in
  Solidity's decoder before the function body runs; the Intake records that as `delivered == false`. The promise is
  therefore scoped to envelopes that decode, and the tests exercise the two cases separately.
- A request the plane never completes (three of the first seven Ethereum requests stayed `admitted`) stays pending
  until `abandon(requestId)` after 14 days.

The registry checks `msg.sender == intake` first in both functions. For a pending result, it bounds both dynamic
fields directly in calldata before copying signature bytes or hashing the answer. Even an ABI-valid 262,144-byte
signature or answer must finish as a miss under the stipend, clear its pending record and reverse index, and allow
an immediate paid retry. An unknown request still returns reason 1 without inspecting these fields.

## 4. The attestation

EIP-712, domain `{ name: "IdentityMD Oracle", version: "2", chainId: <deployment chainId>, verifyingContract: <consumer> }`.
The body supplies `consumer.chainId = block.chainid`; the signed message's `chainId` and the top-level body
`chainId` are both 1, the question's Ethereum mainnet evidence chain. These are separate checks: a mainnet
question signed under the Sepolia consumer domain is valid on Sepolia, while `a.chainId == 11155111` is reason 3.

**`verifyingContract` is the body's `consumer.verifyingContract`**, measured on two third-party requests: for one the
consumer equals the callback target, for the other it is a different contract (a `SwarmFeed`), and the attester signed
the consumer, not the callback target (`reference/attestations/2026-10-10-meatbag-consumer.json`,
`2026-10-11-feed-consumer-v2.json`, both verified with `cast wallet verify` under their domain and refused under the
zero domain). Requests without a `consumer` field were signed for the zero address (the three pilot attestations).
The registry therefore writes its own address into every body and verifies with
`verifyingContract = address(this)`.

Primary type and field order, identical on five mainnet completions and five served attestations:

```solidity
struct OracleAttestation {
    bytes32 requestId;      // the plane's oracle request UUID, right-padded to 32 bytes; NOT the Intake's requestId
    uint256 chainId;
    bytes32 questionHash;   // keccak256 of the canonical question document (check 7)
    uint8   answerType;     // 0 bool, 1 address, 2 bytes32, 3 uint256, 4 address[], 5 bytes32[]
    bytes   answer;         // abi.encode of the value: bool -> 32 bytes 0/1; uint256 -> 32 bytes; address[] -> abi.encode(address[])
    uint256 figure;         // the number behind the answer where there is one; the plane leaves it 0 for panel answers
    uint64  fromBlock;
    uint64  toBlock;
    bytes32 blockHash;      // the hash of toBlock, pinned by the plane at admission
    bytes32 panelJobId;
    uint16  panelSize;
    uint16  quorum;
    uint16  agreed;
    uint64  issuedAt;
    uint64  expiresAt;
}
```

Type string for the struct hash:
`OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)`
(`bytes answer` hashes as `keccak256(answer)` per EIP-712). The signature is 65 bytes r, s, v.

**Digest without immutables.** Do not inherit OpenZeppelin's `EIP712` (its cached domain separator and name/version
fallbacks are seven immutables, and two deployments of the same source produce different runtime code; measured by
the round-2 reviewer). Compute at verification time:

```solidity
bytes32 domainSeparator = keccak256(abi.encode(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    keccak256("IdentityMD Oracle"), keccak256("2"), block.chainid, address(this)));
bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);   // keccak256("\x19\x01" . ds . sh)
(address signer, ECDSA.RecoverError err, ) = ECDSA.tryRecover(digest, signature); // never ECDSA.recover: it reverts
```

A `tryRecover` error, a zero signer or a signer other than the attester is reason 2. The compiler artifact's
`immutableReferences` must be empty for both contracts (a test asserts it, and deploys the pair twice to compare
runtime bytes).

**What the registry verifies before marking a trait** (`CATALOG.md` section 4; reason codes below):

1. `msg.sender == intake`; `pending[requestId]` exists (the `requestId` argument is the Intake's id, which the
   registry stored when it sent the request). **`a.requestId` is not compared with it**: the signed id is the plane's
   UUID. It is stored in the `verified` tuple as `oracleRequestId`, so a third party can fetch
   `/oracle/requests/<uuid>/attestation` from it.
2. Before any dynamic copy or hash: `signature.length == 65` (otherwise reason 2); then
   `a.answer.length <= 2112` (64 ABI-encoded addresses) and, for the pending bool/uint256 kind,
   `a.answer.length == 32` (otherwise reason 9). The expected kind comes from the pending trait, not the untrusted
   `a.answerType`. Only then check `a.chainId == QUESTION_CHAIN_ID` (1), followed by the recovered signer == attester.
3. `a.answerType` equals the template's type; `a.agreed >= a.quorum`, `a.quorum >= the template's quorum` (3 for
   chain, 7 for panel), `a.panelSize >= the template's panel size`.
4. `a.fromBlock` and `a.toBlock` equal the pending request's window (the trait's canonical window or the spec's).
5. `block.timestamp <= a.expiresAt` and `a.issuedAt <= block.timestamp + 1 hours` (the plane's clock may run ahead of
   block time; a stricter lower bound would turn clock skew into an unrecoverable miss).
6. After the question-hash check (7), the decoded answer passes the rule: `>= threshold`, `== true`, or (T3) the envelope is canonical (check 8).
7. **`a.questionHash == pending.questionHash`.** The plane's `questionHash` is
   `keccak256(canonical JSON document)` where the document is the request body reduced to
   `{answerType, chainId, definitions, question, v, window: {fromBlock, toBlock}}`, plus `head` when the body has one
   and `evidence` only when it is `"panel"` (the default `"chain"` is omitted), serialised as RFC 8785 canonical JSON:
   keys sorted, no whitespace, integers as decimal digits, strings escaped only for `"`, `\` and control characters.
   `panelSize`, `quorum`, `validForSeconds`, `consumer` and the pinned `toBlockHash` are **not** in the document.
   Changing the consumer chain therefore does not change the question hash; on chain 1 every body byte remains
   identical to the mainnet fixtures.
   Measured on 14 free quotes (ten fixtures with their vendored quotes in `reference/plane/quotes/`, four probes) and
   on the x402 pilot, whose quote hash equals its attested hash. The registry computes the document from the same
   parameters it composes the body from, at request time, and stores the hash in the pending record; the callback
   compares one word. This binds the attestation to the exact question the registry asked, so a writer that pairs
   claimant A's attestation with claimant B's request, or one trait's with another's, produces a miss, not a trait.
   The golden test asserts that the `questionHash` of the canonical document (`questionHashOf(canonicalDocument)`,
   the keccak of the document, never of the body: the body's keccak is a different value) equals the plane's value
   for all ten fixtures (`reference/plane/questionHashes.json`).
8. **Decode defensively, never revert.** `a.answer` for `bool` and `uint256` must be exactly 32 bytes (and for `bool`
   the word 0 or 1); otherwise reason 9. For `address[]` (T3) the callback does not decode the list; it checks the
   canonical envelope: `answer.length == 64 + 32 * n`, word 0 == `0x20`, word 1 == `n`, `1 <= n <= 64`, and the upper
   12 bytes of every element word are zero. A malformed envelope is reason 9 and **does not store the shared fact**,
   so the fact can be requested again. On success it stores `(requestId, keccak256(a.answer), n)`, nothing else.
   A plain `abi.decode` on hostile bytes reverts, and a revert in `onResult` is a permanent `delivered == false`.
9. One shape. The registry accepts the 15-field struct only. A different wire tuple does not decode as this function's
   arguments and is `delivered == false` at the Intake (section 3); no second type string is tried.

**Diagnostic precedence**, after the Intake caller and pending-request checks: signature length (2), answer
length (9), chainId (3), signer (2), answerType (4), panel/quorum (5), window (6), expiry/issuedAt (7), questionHash
(10), then defensive decoding (9) and the rule (8). When several fields are invalid, the first failed check wins.
The size checks precede EIP-712 hashing and signature recovery; the subsequent quorum rule and canonical question
document are unchanged.

**`Missed` reason codes** (uint8): 1 not pending, 2 signer, 3 chainId, 4 answerType, 5 panel or quorum, 6 window,
7 expiry, 8 rule, 9 decode, 10 questionHash. (The round-1 code 10, "requestId mismatch", is retired: the signed id is
not the Intake id.)

### 4b. Transition table (every pending request ends in exactly one row)

The pending record is `pending[requestId] = (address claimant, uint16 traitId, uint64 requestedAt, bytes32
questionHash)`; for a shared-fact request `claimant == address(0)` and `traitId` is the fact id. The reverse index is
`pendingOf[claimant][traitId] = requestId` (for shared facts `sharedPending[factId]`). "Clear" means: delete
`pending[requestId]`, and delete the reverse index **only if it still equals this `requestId`**.

| event | who | effect on the pair | stored | event emitted |
|---|---|---|---|---|
| `onResult`, all checks pass, personal | Intake | clear | `verified[claimant][traitId] = (requestId, a.requestId, fromBlock, toBlock)`; a community id is appended to `verifiedSpecsOf(claimant)` | `Verified`, `MetadataUpdate(tokenOf[claimant])` if a card exists |
| `onResult`, all checks pass, shared | Intake | clear | `sharedFact[factId] = (requestId, keccak256(a.answer), n)` | `SharedFactStored` |
| `onResult`, rule false (reason 8) | Intake | clear | nothing; the pair may be requested again (paid by the claimant) | `Missed` |
| `onResult`, any other reason 2 to 10 | Intake | clear | nothing | `Missed` |
| `onResult` or `onFailure`, `requestId` unknown (abandoned, consumed, never ours) | Intake | nothing | nothing | `Missed(reason 1)` |
| `onFailure` (status 1 or 2) | Intake | clear | nothing; the pair may be requested again | `NoVerdict` |
| `abandon(requestId)` at `requestedAt + 14 days` or later, personal (paid or sponsored) | stored claimant only | clear | nothing | `Abandoned` |
| `abandon(requestId)` at `requestedAt + 14 days` or later, shared (`claimant == 0`) | anyone | clear | nothing | `Abandoned` |
| `abandon` of a personal request after the deadline by a stranger | anyone but its claimant | revert `NotClaimant()` | | |
| `abandon` earlier | anyone | revert `TooEarly()` | | |
| late callback for an abandoned request | Intake | as the unknown-id row: the successor request's reverse index is untouched, because the index is cleared only when it equals the stale id | | `Missed(reason 1)` |
| not called back, not abandoned | | stays pending; at most one pending request per pair, so a new `upgrade` for the pair reverts | | |

A miss never blocks a claimant-paid retry. The pool's once-per-pair rule is about pool money (`poolUsed`), set when
the pool funds a request, whatever the outcome (`CONCEPT.md` section 4). Pool-funded requests are made by the claimant
for the claimant, so a third party cannot create a miss in someone else's name or discard a late answer by
abandoning it. Abandoning returns no price and restores neither the daily allowance nor `poolUsed` or the IDMD
counter. A valid late callback still settles a request that its claimant has left pending.

Measured traps that shaped these rules: panel members mis-convert decimal block numbers (hence hex in every text);
`rpc.flashbots.net` and `cloudflare-eth.com` answer `null` for mined transactions (hence "null is not evidence" in
panel definitions); three of the first seven Ethereum requests never completed (hence `abandon`);
`completion.resultHash` in the plane's API is not the keccak of the served attestation; the served attestation JSON
spells `answerType` as a name (`"bool"`) while the signed field is `uint8`, so a test loader maps the name to its code
and rejects unknown names.

## 5. Paying

- Card mint: 0.1 IMD from the claimant to the registry (`transferFrom`; the claimant approves the registry first; IMD
  has no `permit`).
- Oracle trait: `priceOf` per request read in the same transaction, pulled from the claimant, approved to the Intake,
  paid in `requestWithFailure`. `upgrade` and `requestSharedFact` take a `maxPrice` argument and revert when `priceOf`
  exceeds it, so a price change between the user's approval and inclusion never pulls more than the user agreed to.
- `mintCard`: pull the fee first, then `_mint` (not `_safeMint`; no receiver callback). IMD is a plain OFT ERC-20
  without transfer hooks (its verified ABI is vendored; the token's internals are an assumption the tests probe with a
  malicious mock); the order is fee, then state, then mint, and a reentrancy guard covers every function that moves
  IMD.
- `registerSpec`: 1 IMD to the registry. `sponsor(amount)`: any amount.
- **The pool is the registry's IMD balance.** There is no separate counter: `pool()` returns `IMD.balanceOf(this)`.
  Fees, sponsorships and plain `IMD.transfer(registry, x)` donations are the same thing; the balance only ever leaves
  through `requestWithFailure` on a pool-funded path (`claimSponsored`, `upgradeSponsored`), and a claimant-paid
  request pulls and forwards in one transaction, so the balance after equals the balance before. Pool money is an
  irrevocable donation: nobody can withdraw it, and a remainder below `priceOf` stays until someone adds to it.

## 5b. BurnExecutor V2 on sponsored claims

`upgradeSponsored` and `claimSponsored` are the only payable registry entry points. All paid IMD paths remain
non-payable. `IBurnExecutor` declares the three selectors the integration uses or exposes for quoting:

```solidity
function tokenBalance() external view returns (uint256);
function previewBridge() external view
    returns (uint256 amountToSend, uint256 minAmountToReceive, uint256 nativeFee);
function bridgeToBaseBurnReceiver(uint256 requested, address refundTo) external payable;
```

The deployed bridge function also returns receipt structs; the registry intentionally ignores them. Its selector
and argument encoding are unchanged by omitting return types from this narrow interface. `tokenBalance()` is a
client-facing view of raw holdings. The registry bases the threshold on the **bridgeable amount from the whole
balance preview**, which accounts for OFT limits and dust, not on raw `tokenBalance()`.

All existing pool checks, allowance effects and the Intake request occur first. The registry then tries the
preview with **`PREVIEW_GAS` = 600,000 gas**. The cap is sized from a measurement of the deployed executor on
2026-10-16: it catches its inner `quoteOFT`/`quoteSend` running out of gas and returns `(0,0,0)` rather than
reverting, so an `eth_call` at block 26,202,500 answers zeros below about 272,000 gas at the CALL and the real
quote above it, and a cold fork trace at block 26,202,203 shows 264,408 gas. 600,000 is 2.2 times that need and
below `BURN_GAS`; the previous 200,000 cap read zeros on mainnet and never burned. The registry does not copy
revert data into events. If the preview returns at least
`BURN_MIN = 69 ether` (69 IMD, 18 decimals) and `nativeFee <= BURN_FEE_CAP = 0.005 ether`, it requires
`msg.value >= nativeFee` or reverts `BurnFeeRequired(nativeFee)`. On that revert, the earlier Intake request,
IMD payment and both pool allowance counters roll back too.

With sufficient ETH the registry tries `bridgeToBaseBurnReceiver(amountToSend, msg.sender)`, forwarding **all
`msg.value`** with **`BURN_GAS = 800_000` as the CALL gas argument**. Nonzero value adds the EVM's 2,300-gas stipend;
EIP-150 may reduce forwarding if the outer transaction has insufficient gas. The executor quotes again, pays
LayerZero, and returns the surplus over *its* quote to `refundTo` (a 100,000-gas call first, a forced send if that
fails). A claimant should attach exactly the `nativeFee` quoted by `previewBridge()` in the same block: if the
executor's own quote at bridge time is higher than the registry's preview, the executor keeps the whole attachment
up to its quote and refunds only what is left, and if it is higher than the attachment the bridge reverts and the
registry skips with code 2 and returns the attachment. A successful registry call emits
`BurnTriggered(claimant, amountToSend, nativeFee)`. Those fields are the registry's preview, not a promise that
Base delivery has completed. Inspect the executor's `TokensBridgedForBurn` and the OFT receipt for actual send
amounts and the LayerZero GUID.

| outcome | event | native ETH handling | oracle request |
|---|---|---|---|
| executor unset | none | return all `msg.value` | pending |
| preview reverts, including exhausted preview gas | `BurnSkipped(claimant, 1)` | return all `msg.value` | pending |
| preview amount below 69 IMD (including zero) | none | return all `msg.value` | pending |
| amount due, quote above 0.005 ETH | `BurnSkipped(claimant, 3)` | return all `msg.value` | pending |
| amount due, quote within cap, attached ETH below quote | `BurnFeeRequired(nativeFee)` revert | entire transaction rolls back | not created |
| bridge reverts, including exhausted call gas | `BurnSkipped(claimant, 2)` | return all `msg.value` | pending |
| bridge succeeds | `BurnTriggered(claimant, amount, nativeFee)` | executor spends fee and force-refunds surplus; registry refunds nothing | pending |

A **registry refund** is a plain `msg.sender.call{value: msg.value}("")`, performed only for a nonzero amount.
Failure reverts `BurnRefundFailed()` and the whole transaction. A nonpayable contract therefore works with no
value on a no-burn path and with an exact fee on a successful burn; executor surplus refunds are also
unrejectable. It cannot reject a nonzero registry refund and still complete that claim. Both sponsored entry
points retain `nonReentrant`, covering the bridge and refund interactions. The executor's refund helper may try
a call before forcing the transfer, and the OFT/LayerZero dependencies may also call the claimant: no
no-callback guarantee is made.

The registry's native balance after an accepted free claim equals its balance before. It forwards or returns
only this call's `msg.value`, never its full balance, and does not require an initially empty balance. ETH
force-sent during execution is outside this accounting invariant. There is no `receive` or `fallback` and no ETH
withdrawal mechanism; an unsolicited pre-existing balance is not swept.

### Dependencies, deployment and operation

The registry remains ownerless and non-upgradeable. Its eighth constructor argument is stored as
`IBurnExecutor public burnExecutor`, without an immutable or setter. `Deploy.BURN_EXECUTOR` is the mainnet V2
address above. `run()` calls `deployForChain()`, selecting the nonzero Sepolia V1 on chain 11155111 and the
mainnet constants on every other chain (section 1). The six-argument `deploy` still accepts an explicit zero to
disable the rule, though the launch manifest does not. The constructor never calls the executor. Outside the
all-four-empty dependency floor it reverts `ExecutorHasNoCode()` for a nonzero executor address without code: the three preview return words are decoded outside the registry's
`try`/`catch`, so an executor that returns no data would revert `claimSponsored` and `upgradeSponsored` for every
wallet for ever, and an ownerless registry cannot repair that. Residual: a coded executor that returns fewer than
three words still reverts a claim; no low-level call is added for it. The offline deploy-script test installs a
mock at both executor constants with `deployCodeTo` before checking the script's chain selections.

**The external dependencies are owner-configurable.** The executor's owner can call `setBridgeConfig` to change
the token, OFT, destination endpoint id, Base receiver and options; `setBaseBurnReceiver`, `setExtraOptions` and
`setMinBridgeAmount` change individual settings. It can rescue tokens and ETH. The OFT owner/configuration
authorities control peers and LayerZero configuration; the configured destination receiver is not fixed by
this registry. A registry deployment does not confer ownership of any of these contracts. The operator must
verify these settings and their owners before launch, then monitor configuration events, quotes, zero previews,
skip rates, executor token balances, receipts and eventual Base burns. Do not infer current destination or
ownership from a constant in the executor's source. There is no new token or executor deployment in this step.

**At the pinned block the rule burns; it stays best effort.** At block **26,202,203**, hash
`0x21d8ce848d55043d0539b2c88ca2c5dd6c0e9072137ae295a5906bc0cabae2bd`, the executor holds
`454939975535748811691` IMD units and the preview quotes `454939975000000000000` units for `219261761563315`
wei. With `PREVIEW_GAS` the registry's preview returns that quote, and the fork tests
(`test/fork/BurnRule.fork.t.sol`, opt-in, `--fork-block-number 26202203`) make a cold sponsored claim (no quote
read before it, so nothing is warm) burn through the real executor, OFT and endpoint: `BurnTriggered(claimant,
454939975000000000000, 219261761563315)`, `tokenBalance()` afterwards equal to the pinned balance minus the
amount (the shared-decimal dust), the registry's ETH balance unchanged, the executor keeping nothing, the surplus
back to the claimant from the executor; the same claim with the exact fee from a nonpayable contract succeeds;
the same claim without the fee reverts `BurnFeeRequired(219261761563315)` with no oracle request. Separate fork
assertions execute the real bridge and OFT directly with the 800,000 CALL gas argument, exact fees and surplus
force-refunds to a nonpayable recipient. They do not mock or replace the executor, OFT or LayerZero code, and do
not execute the asynchronous Base delivery. This is the behaviour at one block, not a promise of future liveness:
a future quote needing more than `PREVIEW_GAS` is a skip with code 1 and one above `BURN_FEE_CAP` a skip with
code 3; a failing bridge is a skip with code 2; none blocks the claim, and the caller still must satisfy the fee
and refund requirements above. The Base burn is asynchronous and depends on LayerZero delivery and the configured
receiver.

Verified executor source, ABI and provenance are in `reference/burn/` as reference data, not build dependencies.
The source was retrieved from [Sourcify](https://sourcify.dev/server/v2/contract/1/0xe29386719C155B6847aD5a4E97C6674f10ffc750?fields=all)
and its reported onchain runtime matched `eth_getCode`; this is not an independent security audit.

## 6. The Curator's views the registry reads (all `view`, all frozen since the Curator settled)

| view | returns | used by |
|---|---|---|
| `firstHourOf(address)` | `(uint256 hour, bool hasJoined)`; a non-member is `(0, false)` | 101, 201, 202 |
| `txCountOf(address)` | `uint256` deposits | 301 to 303 |
| `contributedBy(address)` | `uint256` wei, the largest single send (`highWater`) | 401 to 404 |
| `pointsOf(address)` | `uint256` points (1000 x sqrt(weight in ETH)) | 501 to 503 |
| `isSettled()` | `bool`, true since hour 66 | sanity check in the constructor outside the all-four-empty floor, nothing else |

Never read `contributors(address)` for the hour: its fourth word is `firstHour + 1`. IDMD: `balanceOf(address)` for
the Armed trait (601, live; guard `address(0)`, whose `balanceOf` reverts in OpenZeppelin), `ownerOf(uint256)` for
`upgradeSponsored`.
