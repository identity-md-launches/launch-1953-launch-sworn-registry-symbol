# Sepolia rehearsal test additions

These tests exercise the accepted implementation offline. No production adaptation,
deployment, dependency installation or configuration change was made.

| File | Coverage added |
| --- | --- |
| `Floor.t.sol` | Both existing floor deployments now create Renderer, Composer and Registry in one factory call. Check creation order/predictions, EIP-3860 init-code bounds, zero deployment ETH, exactly three factory creations and no constructor-created child contracts. Existing dependency, runtime and authority assertions remain. |
| `helpers/SepoliaFixture.sol` | Exact Sepolia constructor addresses with local Curator, IDMD, TestIMD and Intake mocks. A small executor mock has code and a bridge function but no preview selector or fallback. |
| `SepoliaLaunch.t.sol` | Full-transaction rollback on a mistyped dependency, unsettled Curator, zero price or missing executor code; V1 `BurnSkipped(1)` and full ETH refunds on both sponsored paths; zero/one-wei boundaries; rejected refunds; reentrancy; changing prices and disabled sales; exact abandonment deadline and stale completions; fixed configuration and callback authorization. |
| `SepoliaOracle.t.sol` | Cold Sepolia callbacks with mainnet evidence for uint/bool traits and a 64-address shared fact, signed for an explicit local test signer. Reject a wrong evidence chain or signing domain; handle false answers, retries and stale callbacks; enforce the shared fact's head. The existing protocol-vector conformance test remains in `Attestations.t.sol`. |
| `SepoliaCommunity.t.sol` (revision) | Through the real launch: the seven catalog questions carry the plane's mainnet question hashes, name the mainnet Curator and never the Sepolia one, with the consumer being the launched registry on 11155111; the hash is the same on both chains and bound to the pending request. The game's T1 window and the T5 deploy block register at Sepolia height 1 and at `2^64-1`; the guard off mainnet is exactly the slot-clock bound (`toBlock < bound`, `toBlock + 7200 <= bound`), checked at both edges by a fuzz over time and height; length, order and T5 equality are still refused; a refused spec takes no id and pulls no fee; `validateSpec` ignores its height argument off mainnet and uses it on chain 1; a window refused today registers one slot after the clock passes it; spec fees land in the pool and fund a sponsored request; a community request asks about mainnet and an unsigned result settles it as a miss; a T3 spec is payable only through `requestSharedFact`, never `upgrade` or the pool paths. |
| `SepoliaCommunityOracle.t.sol` (revision) | Signed community answers on Sepolia with the test signer: a T5 spec verifies cold under 200,000 gas and cannot be asked again; a T1 spec misses below its threshold (8), on a window one block off (6), on another claimant's question (10) and on Sepolia evidence (3), then verifies at the threshold with every attempt paid; a T3 spec stores a five-address fact and applies only within its head of two; the mainnet registry at height 26,200,000 still refuses a window at its own height while Sepolia accepts the same spec. |
| `SepoliaInvariant.t.sol` | Four actors and twelve randomized operations with an independent accounting/request model, variable Intake prices, donations, minting/transfers, paid/shared/sponsored requests, invalid results, failure callbacks, abandonment and replay. The revision adds community-spec registration (T1, T3 and T5 with mainnet windows drawn up to the slot-clock bound, or at and past it, at a random Sepolia height) and community requests; refused registrations must fail with `BadSpec("window")`, take no id and pull no fee. Three invariants run for 256 sequences of depth 96. Two deterministic positive-control sequences reach successes, failures, refunds, completion, abandonment, retries, accepted and refused registrations and requests of every spec kind. |

The accounting model checks pool inflows (donations, mint fees and spec fees) less
sponsored spending, the Intake's receipts against all paid prices, conservation of
all 4,000 test IMD, zero residual Intake approvals, and full ETH refunds. Its other
properties check pending records and reverse indexes, daily and lifetime
allowances, immutable card claimants, unchanged launch configuration, dense spec
ids, immutable registered specs whose windows stay below the bound, and no
community credential without a valid signed answer. The original wider invariants
continue to cover successful signed results.

These are mocks at the requested addresses, not live-chain evidence. The executor
mock tests the absent-selector behavior specified in the brief; it does not claim
to reproduce the complete V1 runtime. Signature tests use an explicitly separate
test-signer fixture. No production key is needed. Callback tests retain the stricter
200,000-gas mainnet budget. The existing optional fork tests still require an RPC
and are skipped in the offline run.

The community-window limitation this suite reported in the first round (the
consumer chain's height bounding a mainnet window, so the game's windows failed
`BadSpec("window")` on Sepolia) was fixed by the adapt step in
`Composer.validateSpec`, which off mainnet bounds a window by
`mainnetHeightBound()`, one block per 12-second slot since the merge. The
first-round proof now passes and its assertions are the registration tests above.
The bound is an upper bound by design, about 0.3% above the real height: at the
recorded head (26,204,211 at timestamp 1,792,143,071) it is 26,280,635, so a
Sepolia registration can name a window up to 76,424 blocks (about ten days) past
the real mainnet head and a paid question about it cannot be answered until mainnet
mines it. That is recorded as an informational finding, not asserted as correct by
a test; on chain 1 the guard is the real `block.number`.

Verification uses:

```sh
forge build --offline
FOUNDRY_FUZZ_SEED=0xfdd83bce876c449f233e5d32d70bbf948893be583b9fb7208e2b4c5f7931c909 forge test --offline --summary
```

Final local result: `forge build --offline` passes. The full seeded offline suite
passes with **214 passed, 0 failed, 17 skipped** across 23 suites. The skips are the
existing optional fork tests. The Sepolia invariant campaign executes **24,576
handler calls with zero handler reverts**.
