# Responsive in-game animation building

## Findings

The existing addon already has a closed-form retargeter with engine verification and a legacy fallback. Replacing global rotations with a different coordinate convention would risk changing working animations. The remaining pipeline still did all frames of each network batch synchronously inside `net.Receive`. A batch of 32 expensive frames therefore blocked input and rendering until every frame finished. The legacy fallback additionally rebuilt the skeleton between individual bones.

The global-axis rotation helper also repeated axis normalization and trigonometry for its forward and up vectors, constructing many temporary engine Vectors. The same bone hierarchy was sorted again for every motion frame. At completion, the server serialized the entire animation into one large JSON string. Actor selection emitted several status messages, each triggering another metadata refresh, and the tool panel rebuilt unchanged rows.

## Implementation

- Network receivers decode a bounded batch, then a cooperative worker solves it over subsequent client Think calls. The default time budget is **2 ms per game frame**, adjustable from 0.5 to 8 ms in Build Performance (`mmd_vmd_npc_build_budget_ms`). Checkpoints between bones allow both fast and legacy builds to yield. Individual engine calls/model loads remain indivisible, so this is a soft budget.
- The fast solver compiles bone traversal order once and caches normalized model axes. A scalar Rodrigues implementation rotates forward and up together in the original **Y -> X -> Z global-axis order**, avoiding intermediate Vector arithmetic and duplicate trigonometry. The old solver remains unchanged as the compatibility oracle.
- Every fast frame is still checked against Source's bone matrices. Missing matrices, duplicate target bones, changed track layouts or orientation disagreement select the legacy solver. The build model's transform stays fixed when the visible actor moves. Previous pelvis-correction translations are cleared before solving another frame.
- The server's queued transform options are included in a tagged optional plan tail. Build options and flex scales stay consistent while work is suspended; normal preview/playback settings are unaffected. Older payloads remain accepted.
- A batch response is sent only after the complete batch finishes. Retries cannot restart suspended work or duplicate cached frames. Rate-limited progress heartbeats keep slow clients alive only while completed frames advance within the requested batch. Cancellation, failure, reload and shutdown release worker/model/file resources.
- JSON saves serialize at most 32 animation frames per step with a 2 ms soft budget. Only a completed, size-checked temporary file is renamed to the playable cache path. The **existing JSON format and playback path remain compatible**, including old built caches.
- Same-tick metadata requests are coalesced. Unchanged tool rows retain their widgets, selection and scroll position.

Increasing the budget favors completion time; decreasing it favors responsiveness. Network batch size is now a throughput/packet limit rather than the amount of bone work forced into one render frame. Cold motion JSON parsing, initial model loading, and individual filesystem/engine calls can still cause a one-time hitch; this patch does not claim to preempt native engine calls or eliminate those costs.

## Reproduction and validation

Run:

```text
python -m unittest discover -s tests -p "test_*.py" -v
python tests/run_build_worker_tests.py
```

The tests execute production helpers and pipeline code under LuaJIT 2.1 via `lupa`, with controlled engine/network/file mocks. They cover frame ordering, deferred execution, shared budgets, retries, cancellation, option snapshots, legacy payloads, UI refreshes, cache round trips, and failed/short writes. See `tests/README.md` for the opt-in Source-engine differential and end-to-end checks.

The scalar-rotation regression exercises 2,000 random orientation pairs, 1,000 float32 vector-boundary cases, singular orientations, large angle wraps, and the near-zero threshold. For a solve with three nonzero axes, instrumented operation counts fall from 53 Vector creations to 4 and from six calls each of sin/cos to three. These counts exclude the once-per-job axis cache and are not whole-build speed multipliers.

No low-end hardware speed claim follows from mocked timings. Keep engine equivalence results and real-host timing results distinct from frame-budget tests.

## Verified results on this host

- 55 deterministic LuaJIT checks passed (45 Python-driven tests and 10 worker tests); every addon Lua file compiled under LuaJIT 2.1.
- A separate Garry's Mod instance passed 27 end-to-end assertions: fast and forced-legacy cancellation during active slices, complete cache files, disk reload, NPC playback, player proxy playback, and restoration of visibility/weapons/movement on stop.
- Nine Source-engine differential cases (240 frames, 12,864 bone packets) passed on Firefly and stock Kleiner, covering synthetic rotations at three entity orientations and sampled authored keys from the bundled motion. Maximum reported orientation difference was 0.05234 degrees; position difference was 0.000003934 Source units; flex difference was zero. No fallback occurred in these cases.
- Both cancellation tests stopped after three active client slices. The final client had zero worker tasks and zero build jobs.
- The packaged GMA was extracted and all 20 payload files matched source byte for byte.

Raw reports: [server checks](../tests/results/engine_server.json), [client/differential checks](../tests/results/engine_client.json). This validates the tested models and scenarios on this machine, not every Workshop skeleton or low-end hardware configuration. The existing 0.5-degree engine-verification fallback remains enabled for other models. Timing comparisons against the legacy per-bone solver must not be mistaken for a measured speedup over the previous fast solver.
