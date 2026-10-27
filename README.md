<img width="3388" height="1512" alt="ReleaseTC" src="https://github.com/user-attachments/assets/c7504fdf-0048-454c-9d61-2d0879c3a02a" />
# GMod MMD Motion Importer
Visit: https://steamcommunity.com/sharedfiles/filedetails/?id=3718373357

Qt-based Windows importer for converting MMD `.vmd` motions into motion JSON files used by the `mmd_vmd_npc` Garry's Mod addon. The importer can preview PMX/VMD (with camera) motion, bake IK and append (付与) transforms natively (no Blender needed), merge optional face/flex VMDs, convert audio/video to GMod MP3 sound, and optionally package an imported motion as a `.gma` addon.

Please Update to the latest version of the motion importer. 

## Repository Layout

```text
mmd_vmd_npc/                 Garry's Mod addon source
source_models/mmd_model/     Bundled PMX model and textures used for baking/preview
tools/import_vmd.py          CLI importer and cache writer
tools/mmd_vmd_importer_gui.py Qt desktop importer UI
tools/vmd_baker.py           Native MMD pose baker (FK, append, IK) and GMod transform export
tools/blender_bake_vmd.py    Legacy Blender-side bake script (optional --bake-with-blender only)
tools/preview/               OpenGL PMX/VMD preview renderer
tools/i18n/                  Importer UI translation files
tools/build_importer_exe.ps1 PyInstaller build script
tools/build_ingame_import_data.py Generates the in-game importer's skeleton data
tools/requirements_importer.txt Python dependencies
tests/                       Baker tests and the in-game importer's parity tests
```

## Requirements

- Windows 10/11, 64-bit.
- Python 3.10 or newer, 64-bit. Python from python.org is recommended for PyInstaller builds.
- Garry's Mod installed through Steam.
- PowerShell for the EXE build script.

The importer auto-detects Steam Garry's Mod when possible. Blender is not required: MMD IK and append transforms are baked in-process (see [Motion Baking](#motion-baking)).

## Set Up From Source

Open PowerShell in the repository root:

```powershell
cd C:\path\to\enhanced_animation_importer_arc
```

Create and activate a virtual environment:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
```

Install importer dependencies:

```powershell
python -m pip install -r tools/requirements_importer.txt
```

Run the importer UI:

```powershell
python tools/mmd_vmd_importer_gui.py
```

## Build The Windows EXE

Build the standard one-file importer:

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_importer_exe.ps1 -Python .\.venv\Scripts\python.exe
```

The output is:

```text
dist/GmodMMDMotionImporter.exe
```

Build without bundled ffmpeg to reduce file size:

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_importer_exe.ps1 -Python .\.venv\Scripts\python.exe -NoBundledFFmpeg
```

With `-NoBundledFFmpeg`, music/video import still works only if `ffmpeg.exe` is available on `PATH`.

Optional build switches:

```powershell
# Change output EXE name
powershell -ExecutionPolicy Bypass -File tools/build_importer_exe.ps1 -Name MyImporter

# Allow UPX compression if UPX is installed and available
powershell -ExecutionPolicy Bypass -File tools/build_importer_exe.ps1 -UseUPX
```

The build script bundles:

- `tools/mmd_vmd_importer_gui.py`
- `tools/import_vmd.py`
- `tools/vmd_baker.py`
- `tools/preview/`
- `tools/i18n/`
- `tools/assets/`
- `source_models/mmd_model/`
- mapping files from `source_models/`
- the `mmd_vmd_npc/` addon files
- ffmpeg from `imageio-ffmpeg`, unless `-NoBundledFFmpeg` is used

## Using The Importer UI

1. Select a body motion `.vmd`.
2. Optionally add face/flex VMDs.
3. Optionally select a music or video file. The importer extracts/encodes audio to MP3.
4. Preview the motion and adjust audio offset if needed.
5. Click the bake/import button.

Bake options:

- **Disable foot IK** — for motions authored without foot IK.
- **Unify ground height (cancel stage placement)** — for motions that move the character between stage platforms or heights, such as Project Diva PV conversions. The character's feet stay on one floor level for the whole dance (jumps keep their height), and an imported camera is lowered by the same amount every frame so it keeps framing her. The preview shows the result. Leave it off for normal motions.

The preview view follows the character, so motions that travel or carry stage placement stay in view.

Scene cuts need no option. When a motion moves the character to another spot in a single frame (Project Diva PV conversions do this at most camera cuts), the addon plays the jump as a cut. It holds the pose before the cut until the cut's frame instead of sliding the dancer across the stage. It also announces the jump to hair and cloth physics, which Model Hotloader then carries across the cut instead of dragging the hair after the body. The bake log lists the cuts it found. The addon finds the same frames in the built animation, so motions imported before this change get the fix too.

The start of a dance is not a jump either. During the start delay the character stands in its reference pose (the T-pose). Over the last 1.5 seconds of the delay it moves into the dance's first pose and onto its starting spot, so a dance that starts elsewhere on the stage no longer teleports the character there. A character that travels stays visible to the player who started it, even when it leaves the area visible from that player's position. Before this, a character dancing for you could freeze out there while the music went on, then jump ahead.

In game, the tool's Build/Playback tab has **Stage placement and movement** options. They apply when playback starts and change only the character's horizontal travel:

- **Stage placement jumps kept (%)**: 100 keeps the jumps to another spot at scene cuts as authored. 0 removes them, so the character keeps dancing where it stood. Values between shorten the jumps. Without the jumps, the walking of each shot adds up and the character can drift far, so pair this with the movement limit. For several dancers in formation, keep 100.
- **Movement range (%)**: shrinks how far the dance moves the character from where it starts; 0 dances on the spot. Only the dance's path (a one-second moving average) is scaled, not the hip sway around it, so the dance keeps its feel.
- **Movement limit (units, 0 = none)**: keeps the character within this distance of where the dance starts, easing in near the edge instead of stopping as if at a wall.

An imported camera moves with the character, so it keeps framing the character.

The importer writes motion JSON to:

```text
<GarrysMod>/garrysmod/data/mmd_vmd_npc/motions/
```

Imported music is written to:

```text
<GarrysMod>/garrysmod/sound/mmd_vmd_npc/music/
```

The UI remembers Garry's Mod path, language choice, and recent inputs between sessions.

## Importing Inside The Game

With [Model Hotloader](https://steamcommunity.com/sharedfiles/filedetails/?id=3810025467) and its [binary module](https://github.com/SheepyLord/Gmod-Model-Hotloader-with-Vulkan) (2.3.0 or later) installed, motions can be imported without leaving Garry's Mod. Model Hotloader's file access lets the addon read files you choose on your computer: Windows asks you to allow each one (in full screen the dialog opens behind the game; press Alt+Tab). It works in single player and on a server you host.

The tool's Motion tab then shows **Import Animation (VMD)...** above **Open Motion Manager** (the console command `mmdvmd_import` opens it too). Without file access it shows a short notice instead, with a **Resolve** button that explains why and links to both pages.

The import window has the desktop importer's inputs: body motion VMD, music, camera VMD, audio offset, the motion metadata table, face/flex VMDs, **Disable foot IK** and **Unify ground height**. It bakes on the same bundled skeleton with a Lua port of the native baker (`cl_import_bake.lua`), a slice per frame so the game keeps running, and writes the same motion JSON to `data/mmd_vmd_npc/motions/`. The new motion is selected in the tool when the import finishes. Re-importing a motion that changed clears its built animations.

Differences from the desktop importer:

- Music must already be MP3, OGG or WAV. It is copied as it is to `data/mmd_vmd_npc/music/<motion id>.<ext>` (Lua can write only into `data/`). Use the desktop importer to convert other audio or a video.
- There is no preview, no Garry's Mod folder field and no `.gma` export.

The skeleton data the Lua baker uses is generated from the bundled model and the bone/flex maps. After changing any of them, regenerate it:

```powershell
python tools/build_ingame_import_data.py
```

`tests/test_ingame_importer.py` runs the Lua importer under LuaJIT through [lupa](https://pypi.org/project/lupa/) (`python -m pip install lupa`) and compares its output with the Python importer's. It also fails while the generated data is stale.

## CLI Usage

Print the detected Garry's Mod path:

```powershell
python tools/import_vmd.py --print-gmod
```

Bake and import a body VMD:

```powershell
python tools/import_vmd.py "motions\dance.vmd" --cache
```

Import with extra flex VMDs and music:

```powershell
python tools/import_vmd.py "motions\dance.vmd" `
  --cache `
  --flex-vmd "motions\face.vmd" `
  --flex-vmd "motions\mouth.vmd" `
  --music "music\dance.wav" `
  --audio-offset -0.25 `
  --motion-name "My Dance"
```

Override the detected Garry's Mod path:

```powershell
python tools/import_vmd.py "motions\dance.vmd" `
  --cache `
  --gmod-dir "H:\SteamLibrary\steamapps\common\GarrysMod"
```

Also export the imported motion as a `.gma`:

```powershell
python tools/import_vmd.py "motions\dance.vmd" `
  --cache `
  --motion-name "My Dance" `
  --export-addon-gma "dist\MyDance.gma"
```

Cancel stage placement heights (the camera is lowered to match):

```powershell
python tools/import_vmd.py "motions\pv.vmd" `
  --cache `
  --camera-vmd "motions\pv_camera.vmd" `
  --unify-ground
```

Only bake, writing the intermediate parent-corrected rotation JSON:

```powershell
python tools/import_vmd.py "motions\dance.vmd" --bake --output-rotation-json "build\dance_rotations.json"
```

## Motion Baking

`tools/vmd_baker.py` evaluates the body VMD on the bundled PMX skeleton the way MMD does and exports the per-frame GMod bone transforms in the parent-corrected JSON format the addon reads. Frames are independent, so they are evaluated in batches with NumPy; a typical dance bakes in a few seconds.

- Bone keys use the VMD bezier curves, with rotations interpolated by slerp.
- Append (付与) rotation/translation bones (shoulder cancel, twist sub-bones, D bones) are evaluated in PMX transform order.
- Standard leg IK chains (knee hinge + thigh) are solved in closed form, so feet reach their IK targets even when crouching from a straight leg; other IK chains use MMD-style CCD with angle limits. IK on/off keys in the VMD apply per frame, and `--disable-foot-ik` turns all IK off.
- `--unify-ground` (the UI's "Unify ground height") cancels stage placement heights. Each frame it takes the lowest point of the body that can rest on the floor (toes, ankles, knees, hands, hips, head), keeps its lower envelope — airborne phases up to about one second are ignored, steps and slopes are followed — and moves the whole character so that envelope sits on the rest-pose floor. Scene-cut platform changes stay sharp and slower changes are smoothed. Only the pelvis track carries world position, so only its height changes; the camera track is lowered by the same per-frame amount.
- Scene cuts are frames where the pelvis moves more than 8 Source units in one frame, and more than 4 times the median step of the 3 frames on either side. Dancing stays below about 10 units a frame, and faster moves build up over several frames, which the median leaves alone; the Project Diva cuts measured are 8 to 1,000. The motion JSON lists them in `cuts` as VMD frames, taken after ground unification. Ground smoothing never spans one. The addon applies the same rule to its built frames (`MMDVMDNPC.BuiltPoseCuts` in `sh_core.lua`). It holds the pose across each cut and raises the networked counter `MMDVMDNPCPoseCut` one server tick ahead. Clients then run the hook `MMDVMDNPCPoseCut(ent, seconds)`, which Model Hotloader's `mmdhl.MarkTeleport` listens to; other physics addons can listen too.

Differences from the previous Blender bake:

- The body motion is no longer one frame late relative to the music, camera, and facial tracks (mmd_tools placed VMD frame N at Blender frame N+1; the legacy `--bake-with-blender` path is fixed too).
- IK on/off keys after the first frame are honoured; the Blender bake kept the first frame's IK state for the whole motion.
- Knees keep the model's minimum bend (0.5° on the bundled model), as in MMD.
- No intermediate baked VMD is written.

The previous Blender + MMD Tools bake is still available from source as a reference with `--bake-with-blender` (not bundled in the EXE). It needs Blender 4.3 or newer, auto-detected or passed with `--blender`; `--print-blender` shows which install it would use. If MMD Tools is not available in that Blender, the helper installs the vendored `tools/blender_addons` archive, then tries the official extension from:

```text
https://extensions.blender.org/add-ons/mmd-tools/
```

## Troubleshooting

### `_ctypes` or `DLL load failed` when running the EXE

Use the latest `tools/build_importer_exe.ps1`. It explicitly includes Python DLL paths and common runtime DLLs such as libffi. If the issue persists, rebuild using a normal 64-bit CPython install instead of the embeddable Python distribution.

### PyInstaller is missing

Install the requirements again:

```powershell
python -m pip install -r tools/requirements_importer.txt
```

### The EXE is too large

Build without bundled ffmpeg:

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_importer_exe.ps1 -NoBundledFFmpeg
```

The user will need ffmpeg on `PATH` for music/video conversion.

### Garry's Mod is not detected

Pass the path manually in the UI, or use CLI:

```powershell
python tools/import_vmd.py "motions\dance.vmd" --gmod-dir "H:\SteamLibrary\steamapps\common\GarrysMod" --cache
```
