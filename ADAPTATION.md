# Sworn Sepolia launch adaptation

Checked on 2026-10-16. The first round found no production adaptation necessary.
An independent review then reopened the work with two reproducible findings, both
the same kind of mistake: a question that is about Ethereum mainnet by decision
was still built from the deployment chain (its Curator address, its block height).
**This revision changes `src/Composer.sol` only**; `src/Registry.sol`'s runtime is
byte-equal to the accepted tree, the design decisions in the brief are untouched,
and every other finding is answered in `.imd-responses.json` and below.

## Changes

| File | Change | Reason |
|---|---|---|
| `src/Composer.sol` | `catalogSpec` sets the target to the new public constant `MAINNET_CURATOR` (`0xcb0b0531e86a9ac36fa865ca8e3dbccf047fda91`), and the T5 parenthesis of trait 1301 names the same constant; the two `address` parameters of `catalogSpec` and `compose` stay in the ABI, unnamed and unused. | Reviewer finding `206a260d…` (reproduced, proof failed): on Sepolia every catalog question named the Sepolia Curator as a mainnet contract, which has no mainnet code, so every catalog oracle trait was a guaranteed miss and 1201 could never be stored. The question is about mainnet, so it names the mainnet contract whatever chain the registry runs on; the registry's `curator` argument serves the direct reads only. TEMPLATES.md already wrote the fixed address. |
| `src/Composer.sol` | `validateSpec` is a `view`: on chain 1 it bounds the window by the `block.number` the registry passes, exactly as before; on any other chain by `mainnetHeightBound()`, the first post-merge block (15,537,395 at 1,663,224,191) plus one block per 12-second slot since. Length (7200) and ordering checks are unchanged. | Reviewer finding `9a97dce5…` (reproduced, proof failed) and audit finding `91cf6828…`: a window is a range of mainnet blocks, but it was compared with the consumer chain's height, so on Sepolia every game window was `BadSpec("window")` and on a chain above mainnet's height an unmined window would have passed. The slot clock is an upper bound on the mainnet height that the caller cannot forge; it is never below the real height and about 0.3% above it, so the same guard holds on every chain. |
| `test/SepoliaRehearsal.t.sol` | New: eight tests on chain 11155111 with the Curator mock at the Sepolia Curator address. | Every change is tested: registration of the game windows, the guard at its bounds on Sepolia and on mainnet, the bound against five recorded mainnet heights and by fuzz, the seven catalog bodies byte-equal to the mainnet fixtures with only `consumer.chainId` changed and with the plane's question hashes, direct reads on the Sepolia Curator, a Sepolia claimant verifying 701 end to end. |
| `CATALOG.md`, `README.md`, `INTEGRATION.md`, `test/NOTES.md` | The window rule names the mainnet height; the Sepolia notes say the catalog questions name the mainnet Curator; the Intake's Sepolia `callbackGas` of 1,000,000 is recorded next to mainnet's 200,000; the pool's exposure after a key rotation is written into "What can kill the registry". | Documentation of the two fixes and of advisory findings `7e76e9b8…` and `1a09ea86…`. |
| `.imd-responses.json` | One answer per finding. | Required by the revision. |
| `ADAPTATION.md` | This record. | Required by the adaptation acceptance criteria. |

No change to `script/`, existing tests, generated assets, template fixtures,
configuration or dependencies. No dependency was installed. No manifest was
written and no transaction was broadcast. The deployment service supplies the
manifest, factory transaction and confirmed deployment addresses later.

Runtime sizes after this revision (solc 0.8.24, optimizer 200, Cancun, no via-IR):
Registry 24,561 bytes (byte-equal, 15 of headroom), Composer 23,655 bytes (921 of
headroom, was 23,402), Renderer 21,570 bytes (unchanged).

Disposable reproduction scaffolding under `test/scratch/` (the two reviewer proofs
copied there) is deleted before anything is built or submitted.

## Reviewer findings (revision)

- `9a97dce5…` (medium) **fixed**: reproduced with the proof (0 of 2 passed on the
  accepted tree, `BadSpec("window")` for the game window and the T5 deploy-block
  spec at Sepolia height 11,926,383; the same T1 spec registered at chain 1).
  Fixed in `Composer.validateSpec` as in the table; the proof passes.
- `206a260d…` (medium) **fixed**: reproduced with the proof (`composeBody(701)`
  on Sepolia named `0x0919ba50…` and `specOf(701).target` was that address).
  Fixed in `Composer.catalogSpec` and the 1301 parenthesis; the proof passes.
- `1a09ea86…` (low) **disputed, code unchanged**: the behaviour is as described,
  and it is the brief's explicit decision (fixed attester, Intake, action and
  token; no setter; report a dispute, leave the code). The one new consequence,
  that sponsored requests keep drawing pool money after a rotation, is now in
  INTEGRATION.md's list of what can kill the registry.
- `d543592d…` (info) **rehearsal trust gap, not a code defect**: the open
  `set()`/`setOwner()` belong to the Sepolia stand-ins the brief names, not to
  Sworn; on Sepolia anyone can self-grant membership, so the Sepolia pool is
  spendable by anyone and the membership gate is not rehearsed. Mainnet arguments
  point at the settled WhitelistCurator and the real IDMD.
- `7e76e9b8…` (info) **documentation fixed**: `callbackGas()` read live on
  2026-10-16 is 1,000,000 on Sepolia and 200,000 on mainnet; INTEGRATION.md and
  README now say so and point at the unit tests for the mainnet stipend.
- `ada37f2e…` (info) **documented design, no change**: a member can spend the
  pool on ordinals true for one wallet each, 4.5 IMD lifetime per member; the
  pool is an irrevocable donation and every accepted request spends its
  allowance regardless of outcome (CONCEPT.md section 4, DISCLOSURE.md).

## Deployment handoff

Chain: **Sepolia, 11155111**. Collection: **Sworn / SWORN**. Deploy exactly these
three applications, in this order, with zero deployment ETH:

1. `Renderer()`.
2. `Composer()`.
3. `Registry(curator, idmd, imd, intake, attester, renderer, composer, burnExecutor)`.

| Registry argument, in ABI order | Value |
|---|---|
| `curator` | `0x0919ba50b206c3f31d516de818b1fbc7da21653d` |
| `idmd` | `0x2c3013c90a1bb65573aae9a7c64fafb82697e4e4` |
| `imd` | `0x44a1cd38474fb1748400e7deb5f8d786cce3f89a` |
| `intake` | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| `attester` | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| `renderer` | `$contract:Renderer` |
| `composer` | `$contract:Composer` |
| `burnExecutor` | `0x097A19e0f021BBA5072701132625ad2401043A2E` |

All constructors are nonpayable. Registry takes eight static address arguments;
the helpers take none. There is no owner/admin argument, initialization call,
launch token, pool deployment or additional application. Bytecode has no library
link references or immutable references. A scratch CREATE2 probe deployed all
three in one factory call, checked predicted addresses, runtime bounds and
forbidden opcodes, and checked that no application constructor created another
contract. Existing `FloorTest` also checks both parameter sets and absence of
`owner()` and `admin()`.

| Contract | Runtime bytes | EIP-170 headroom | Init code including arguments |
|---|---:|---:|---:|
| Renderer | 21,570 | 3,006 | 21,599 |
| Composer | 23,402 | 1,174 | 23,432 |
| Registry | 24,561 | 15 | 26,610 |

The unchanged project configuration uses solc 0.8.24, optimizer 200 runs, Cancun,
no via-IR, no metadata hash and no CBOR metadata.

The specified design decisions remain intact: only the all-four-empty dependency
floor bypasses constructor dependency checks; personal abandonment is claimant-only
after 14 days and shared abandonment is public; questions concern mainnet while
the consumer/signing domain uses the deployment chain; the action, attester,
Intake and token remain fixed without administration or upgrades. Sponsored calls
forward or refund their own ETH and preserve any pre-existing ETH balance. The
oracle reference's generic recommendations for setters and the launch reference's
generic constructor guidance do not override these explicit decisions.

## Imported audit disposition

### 91cf682819c1afde0b23e38b5afeee81fd63cee412758b7932b7e9921a994e22 — low

**Reproduced; fixed in this revision.** The T1 window 25,769,870–25,789,604
validated at mainnet height 26,203,948 and failed `BadSpec("window")` at Sepolia
height 11,926,230; the T5 single-block window at 25,769,870 likewise. The first
round retained this as a rehearsal limitation; the independent review's finding
`9a97dce5…` (same root cause, with a proof) reopened it. `Composer.validateSpec`
now bounds the window by the mainnet height on every chain (see Changes), so the
game's windows register on Sepolia and an unmined mainnet window is refused
everywhere. `test/SepoliaRehearsal.t.sol` covers both chains and the bound.

### 25e1b004a1da49daad78b243b51297d083ab8cd8f9d835a4b73d63f632dab019 — info

**Reproduced; fixed in this revision.** All nine catalog chain traits and shared
trait 1201 composed mainnet questions targeting the supplied Sepolia Curator,
which has no mainnet code (14 `eth_getLogs` ranges over 25,769,870–25,789,604
returned no logs), so signed zero answers produced `Missed(requestId, traitId, 8)`
(an empty 1201 list: reason 9). The first round recorded this as the stated
design; the independent review's finding `206a260d…` (same root cause, with a
proof) reopened it. `Composer.catalogSpec` and the 1301 parenthesis now name the
mainnet Curator constant on every chain (see Changes); a Sepolia body is the
mainnet fixture with only `consumer.chainId` changed and carries the plane's
question hash. A real claimant still needs the mainnet facts (for 1301, a nonce
of at least 20 at the pinned block). Fresh Intake reads confirm 1,000,000
callback gas on Sepolia versus 200,000 on mainnet, so a successful Sepolia
completion alone does not demonstrate mainnet gas compatibility; the existing
stipend tests do, and INTEGRATION.md now says so.

### 7934e5102db441176cbeb9c1f14e7f6a03b9e06c0a5c14f662362d30f5ab5ffe — info

**The size measurement reproduces; the illustrative constructor edit does not.**
Registry runtime is exactly 24,561 bytes, leaving 15 bytes. However, changing
`"Intake price"` to `"Intake price is zero"` in a disposable copy only increases
creation bytecode from 26,354 to 26,371 bytes. Its deployed runtime is byte-for-byte
identical to Registry's and still 24,561 bytes. Thus the audit's assertion that
this particular edit fails the runtime floor is not reproduced. Runtime-changing
edits still require a fresh size check. The original source was never modified.

### 2a1309d6bd66727ea7dc96d2eb229266fef8ef192bc87f45ad6744036d589762 — info

**Reproduced; preserved as designed.** The supplied Sepolia V1 executor has code
and reverts on `previewBridge()`. A local Sepolia fork at block 11,926,289 deployed
the exact launch arguments and exercised a sponsored claim through the actual
TestIMD, Intake and V1 executor: `BurnSkipped(claimant, 1)`, a pending oracle
request, 0.5 TestIMD spent and the entire attached ETH refunded. Only claimant
membership and funding were synthetic. A separate seeded scratch fuzz test
covers both sponsored entry points and varying attachments with a coded executor
that lacks the selector.

Mainnet V2 returned `(454939975000000000000, 454939975000000000000,
219261761563315)` during this review. All six existing burn fork tests at block
26,202,203 pass, including the cold no-fee atomic revert, exact-fee bridge and
surplus refund. These establish the audit's mainnet distinction; the quote is a
snapshot and must be read again for a future mainnet claim.

The first disposable Sepolia assertion assumed a zero starting ETH balance. Its
deterministic local deployment address was already funded with 0.002 ETH on the
fork. Correcting the test to compare balances before and after confirms that
the claim retains none of its attachment and does not spend pre-existing ETH.
This was a scratch-test assumption, not a production defect.

### 89656fa2d98b68b5c01b140b02472288e444ab9989eb4de5254027fe3f8f811a — info

**Scope record, not a repairable finding.** This adaptation independently reviewed
the constructors, deployment arguments, mainnet question composition, callback
validation, abandonment, registration, sponsored payment/refund paths and runtime
restrictions. The local checks below extend the imported audit by running the
invariants and the burn fork suite. Existing protocol-vector digest/selector,
served-attestation, callback gas, access-control, reentrancy and accounting tests
pass. No change to contract behavior was required.

Live RPC checks on 2026-10-16 confirmed code at Curator, IDMD, IMD, Intake and
executor on each chain, settled Curators and the 0.5 IMD action price. The observed
heads were mainnet 26,203,984 and Sepolia 11,926,289. Public source endpoints:
[Ethereum RPC](https://ethereum-rpc.publicnode.com) and
[Sepolia RPC](https://ethereum-sepolia-rpc.publicnode.com).

The older `MainnetForkTest` could not load pinned block 26,170,000: the RPC answered
`pruned history unavailable: requested 26170000, earliest available 26193911`
(error 4444). Its eleven tests therefore remain unverified by a live fork in this
adaptation; their default offline skips are unchanged. No live Sepolia-domain
plane quote or paid oracle completion was performed. The existing mainnet body
fixtures and recorded plane responses were not changed. Slither and Mythril were
not run. This is a bounded adaptation review, not a replacement for the final
independent audit.

## Validation

Every Foundry test command used
`FOUNDRY_FUZZ_SEED=0xfdd83bce876c449f233e5d32d70bbf948893be583b9fb7208e2b4c5f7931c909`.
The project's fuzz and invariant configuration was unchanged.

Revision (this round):

- `forge build` and `forge build --sizes`: pass; Registry 24,561 (byte-equal),
  Composer 23,655, Renderer 21,570 bytes.
- The two reviewer proofs, copied under `test/scratch/`: **0 of 3 passed on the
  accepted tree** (`BadSpec("window")` twice; the Sepolia Curator named in a
  mainnet question once), **3 of 3 pass** on this tree.
- `forge test` with `CHAINTRAITS_FORK_RPC` unset, proofs included: **185 passed,
  0 failed, 17 skipped** across 20 suites (174 existing, 8 new in
  `test/SepoliaRehearsal.t.sol`, 3 proofs); the skips are the two optional fork
  suites. The three invariant suites ran at 256 runs and depth 64.
- `python3 tools/gen_template.py --check`: **28 generated artifacts match**
  (the fixtures and goldens are unchanged by design).
- `python3 -m unittest discover -s tools`: **18 passed**.
- Opt-in `BurnRuleForkTest` at mainnet block 26,202,203: **not run to completion**
  this round; the public RPC answered that the historical state at that block is
  no longer available. The burn rule is untouched by this revision and the suite
  passed in the first round (below). `MainnetForkTest` remains unavailable at its
  pinned block as described above.
- Live reads on 2026-10-16: Sepolia `callbackGas()` 1,000,000 and mainnet
  200,000; mainnet head 26,204,211 at timestamp 1,792,143,071, and blocks
  15,537,395, 25,769,870, 26,170,000 and 26,200,000 at the timestamps the
  new height-bound test records.

First round (unchanged code, kept for the record):

- `forge test` with `CHAINTRAITS_FORK_RPC` unset: 174 passed, 0 failed,
  17 skipped, across 17 suites.
- Scratch rehearsal tests: 8 passed, including the single-call CREATE2
  deployment, audit reproductions and constructor-string counterexample.
- Sepolia dependency fork at block 11,926,289: 1 passed.
- Existing `BurnRuleForkTest` at mainnet block 26,202,203: 6 passed.
- Existing `MainnetForkTest`: unavailable at its pinned historical block.
