# Sworn Sepolia launch adaptation

Checked on 2026-10-16. **No production adaptation was necessary.** The existing
contracts and deployment script already support the requested contracts-only
Sepolia rehearsal. No reproduced finding required a behavior change under this
assignment's explicit design decisions.

## Changes

| File | Change | Reason |
|---|---|---|
| `ADAPTATION.md` | Added this launch handoff, audit disposition and validation record. | Required by the adaptation acceptance criteria. |

There are no changes to `src/`, `script/`, existing tests, generated assets,
configuration or dependencies. No dependency was installed. No manifest was
written and no transaction was broadcast. The deployment service supplies the
manifest, factory transaction and confirmed deployment addresses later.

Disposable reproduction scaffolding was created in `test/scratch/Rehearsal.t.sol`,
`test/scratch/RegistrySizeOnly.sol` and `test/scratch/SepoliaDependencies.t.sol`.
It was used only for the checks described below and removed from the repository
before the final build and test. It is not part of the submission.

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

**Reproduced; retained as the specified rehearsal limitation.** The T1 window
25,769,870–25,789,604 validates at mainnet height 26,203,948 and fails
`BadSpec("window")` at Sepolia height 11,926,230. The T5 single-block window at
25,769,870 behaves likewise. Calling `registerSpec` on simulated Sepolia rejects
both without charging the registration fee or advancing `nextSpecId`; the T1
registration succeeds at the mainnet height with id 10001.

This prevents community specs using the game's mainnet windows in the rehearsal.
It does not prohibit every possible community spec: sufficiently old mainnet
windows below Sepolia's height can satisfy the existing guard. Adding an evidence
height constant, argument or oracle would change the agreed design and is not
required by this finding, so the guard is unchanged.

### 25e1b004a1da49daad78b243b51297d083ab8cd8f9d835a4b73d63f632dab019 — info

**Reproduced, with a reason-code qualification.** All nine catalog chain traits
and shared trait 1201 compose mainnet questions targeting the supplied Sepolia
Curator, while `consumer.chainId` is 11155111. Mainnet code at that address was
empty, and 14 `eth_getLogs` ranges covering blocks 25,769,870–25,789,604 returned
no logs. Signed zero-count test answers for all nine personal traits produce
`Missed(requestId, traitId, 8)` and clear the pending request. An empty 1201 list
produces **reason 9**, not 8; a plane refusal instead follows `onFailure`.

A scratch test verifies a valid true answer for 1301 in the Sepolia domain with
attestation chainId 1 under 200,000 gas. This establishes callback compatibility,
not a live oracle verdict. A real claimant must have mainnet nonce at least 20 at
the pinned block. Community T5 specs remain subject to the window limitation
above. Fresh Intake reads confirm 1,000,000 callback gas on Sepolia versus
200,000 on mainnet, so a successful Sepolia completion alone does not demonstrate
mainnet gas compatibility. The existing stipend tests remain relevant.

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

- `forge build` and `forge build --sizes`: pass; sizes are listed above.
- `forge test` with `CHAINTRAITS_FORK_RPC` unset: **174 passed, 0 failed,
  17 skipped**, across 17 suites. This includes the three invariant suites at
  256 runs and depth 64; the skips are the two optional fork suites.
- Scratch rehearsal tests: **8 passed**, including the single-call CREATE2
  deployment, audit reproductions and constructor-string counterexample.
- Sepolia dependency fork at block 11,926,289: **1 passed**.
- Existing `BurnRuleForkTest` at mainnet block 26,202,203: **6 passed**.
- Existing `MainnetForkTest`: unavailable at its pinned historical block, as
  described above; no production change or test relaxation was made for it.
- `python3 tools/gen_template.py --check`: **28 generated artifacts match**.
- `python3 -m unittest discover -s tools`: **18 passed**.

The final build and full seeded offline suite were run after removing scratch
sources. A file-content comparison against the starting tree confirms that the
only submitted change is this document.
