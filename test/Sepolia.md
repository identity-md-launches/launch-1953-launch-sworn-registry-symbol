# Sepolia rehearsal test additions

These tests exercise the accepted implementation offline. No production adaptation,
deployment, dependency installation or configuration change was made.

| File | Coverage added |
| --- | --- |
| `Floor.t.sol` | Both existing floor deployments now create Renderer, Composer and Registry in one factory call. Check creation order/predictions, EIP-3860 init-code bounds, zero deployment ETH, exactly three factory creations and no constructor-created child contracts. Existing dependency, runtime and authority assertions remain. |
| `helpers/SepoliaFixture.sol` | Exact Sepolia constructor addresses with local Curator, IDMD, TestIMD and Intake mocks. A small executor mock has code and a bridge function but no preview selector or fallback. |
| `SepoliaLaunch.t.sol` | Full-transaction rollback on a mistyped dependency, unsettled Curator, zero price or missing executor code; V1 `BurnSkipped(1)` and full ETH refunds on both sponsored paths; zero/one-wei boundaries; rejected refunds; reentrancy; changing prices and disabled sales; exact abandonment deadline and stale completions; fixed configuration and callback authorization. |
| `SepoliaOracle.t.sol` | Cold Sepolia callbacks with mainnet evidence for uint/bool traits and a 64-address shared fact, signed for an explicit local test signer. Reject a wrong evidence chain or signing domain; handle false answers, retries and stale callbacks; enforce the shared fact's head. The existing protocol-vector conformance test remains in `Attestations.t.sol`. |
| `SepoliaInvariant.t.sol` | Four actors and ten randomized operations with an independent accounting/request model, variable Intake prices, donations, minting/transfers, paid/shared/sponsored requests, invalid results, failure callbacks, abandonment and replay. Three invariants run for 256 sequences of depth 96. A deterministic positive-control sequence reaches successes, failures, refunds, completion, abandonment and retries. |

The accounting model checks pool inflows less sponsored spending, the Intake's
receipts against all paid prices, conservation of all 4,000 test IMD, zero residual
Intake approvals, and full ETH refunds. Its other properties check pending records
and reverse indexes, daily and lifetime allowances, immutable card claimants and
unchanged launch configuration. The original wider invariants continue to cover
community registration and successful signed results.

These are mocks at the requested addresses, not live-chain evidence. The executor
mock tests the absent-selector behavior specified in the brief; it does not claim
to reproduce the complete V1 runtime. Signature tests use an explicitly separate
test-signer fixture. No production key is needed. Callback tests retain the stricter
200,000-gas mainnet budget. The existing optional fork tests still require an RPC
and are skipped in the offline run.

The previously documented community-window limitation is independently reproduced
in `.imd-findings.json`, with the complete runnable proof. Registration uses the
consumer's block height to validate mainnet windows. Both the historical log
window and nonce window fail on simulated Sepolia, while the same log spec passes
at the recorded mainnet height. The failing assertions are included in the report,
not converted into tests that endorse the rejection. No source fix is included.

Verification uses:

```sh
forge build --offline
FOUNDRY_FUZZ_SEED=0xfdd83bce876c449f233e5d32d70bbf948893be583b9fb7208e2b4c5f7931c909 forge test --offline --summary
```

Final local result: `forge build --offline` passes. The full seeded offline suite
passes with **192 passed, 0 failed, 17 skipped** across 20 suites. The skips are the
existing optional fork tests. The new invariant campaign executes **24,576 handler
calls with zero handler reverts**. The separate finding proof produces one passing
control and two `BadSpec("window")` failures, as reported.
