# Build performance regression checks

Run the deterministic scheduler tests with `python tests/run_build_worker_tests.py`.
They use the `lupa.luajit21` runtime (`pip install lupa`) and need no game or network.
The fake clock verifies that a build yields at its budget, resumes without losing
frames, cancels without sending a stale result, and keeps synchronous debug calls
working. These tests do not claim to reproduce Source engine bone evaluation.

For the actual engine comparison, mount the addon in a local Garry's Mod session,
finish any active build, and execute in the client console:

```
lua_openscript_cl mmd_vmd_npc/tests/cl_build_regression.lua
mmd_vmd_npc_test_build
```

This runs stock Kleiner and Alyx at three entity orientations. Supply a custom
model path to cover its reference sequence, auxiliary bones, and arm correction:

```
mmd_vmd_npc_test_build "models/your_model.mdl"
mmd_vmd_npc_test_build_motion "models/your_model.mdl"
```

The first command covers neutral-to-animated-to-neutral transitions, root
translation, large wrapped rotations, near-gimbal angles, missing bones, reordered
rows, spine correction, and flex scaling/clamping. The second samples authored
keys from the shipped motion (an optional second argument selects another motion
ID). It checks conversion on real imported rotations, not sampler interpolation.

Each comparison uses separate hidden models and compares fast and legacy output
bone sets, orientation bases, translations, and flex values. A case requires
nonempty output, angular error at most 0.5 degrees, position error at most 0.01
Source units, and flex error at most 0.000001. Reports include timings and fallback
counts; a correct fallback is a compatibility pass, not a speed improvement.
Reports are printed to the console and saved to
`garrysmod/data/mmd_vmd_npc/build_regression.json`. Commands never start playback,
pose existing entities, change settings, send build packets, or overwrite caches.
The harness is never loaded by autorun. These are deliberately synchronous
comparisons of the two solvers, so a case can briefly pause the development
session; `mmd_vmd_npc_test_build_cancel` cancels subsequent cases.

Repeat the engine comparison with a supported custom model, a nonstandard arm
reference pose, disabled twist/eye controls, and both spine-correction settings.
For end-to-end acceptance, build the same long motion with fast build enabled and
disabled, cancel during a batch, rebuild, then play and seek it on an NPC and on
the player. Confirm responsive selection/UI, full frame count, smooth playback,
correct root/flex motion, and successful cache reuse after reconnecting. Timings
from one host do not establish low-end hardware performance.

## Isolated full engine smoke run

The additional `sv_engine_smoke.lua` and `cl_engine_smoke.lua` files are intended
for a disposable local development instance, not an existing user session. The
server runner refuses any `hostport` other than `27045`. Stage the addon's
`lua/mmd_vmd_npc` directory into that instance's Lua search path, and stage a copy
of `lua/autorun/mmd_vmd_npc.lua` as
`lua/mmd_vmd_npc/tests/bootstrap.lua`. Also make the shipped motion JSON available
under its normal `data_static/mmd_vmd_npc/motions` path. Installed Firefly or
Shorekeeper models are preferred; the runner probes for a supported Reference
sequence and reports failure if no suitable installed model exists.

Launch the disposable instance with `-multirun -port 27045 -clientport 27046`
and `+sv_cheats 1 +sv_allowcslua 1 +ai_disabled 1 +map gm_construct`, using the
Garry's Mod installation root as the process working directory. Start the runner
from the server console after the map loads:

```text
lua_openscript mmd_vmd_npc/tests/sv_engine_smoke.lua
```

The tested engine did not execute this Lua command from startup arguments. For
an unattended run, temporarily stage this file under `lua/autorun/server/`:

```lua
local port = GetConVar("hostport")
if SERVER and port and port:GetInt() == 27045 then
    include("mmd_vmd_npc/tests/sv_engine_smoke.lua")
end
```

Remove that loader and only the files you staged after the run. Do not issue
`-hijack` to an existing game. The smoke runner performs synthetic and authored differential
comparisons, cancels an active network build, rebuilds a 10-frame fixture, reads
and validates its persisted cache, clears its memory cache, then starts/stops NPC
playback from disk. It also compares the stock Kleiner skeleton, cancels a legacy
worker build on the player, builds and reloads a separate player cache, verifies
self playback uses a proxy, and checks that stopping restores player/weapon
visibility and movement. The client temporarily sets fast build and a 0.5 ms budget
and restores their original values before exit. The fixture uses a unique motion
ID and only its own motion/cache files and NPC are cleaned up.

Results are saved under `garrysmod/data/mmd_vmd_npc/` as
`performance_smoke_client.json` and `performance_smoke_server.json`. The runner marks its report finished after completion or a recorded timeout; the
launcher must stop only the isolated process it started. GMod blocks Lua from
issuing `quit`. These scripted checks
verify engine execution and lifecycle; visual playback quality and low-end frame
times still need the acceptance checks above.
