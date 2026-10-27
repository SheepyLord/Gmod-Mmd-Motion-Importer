"""Parity tests for the GMod addon's in-game importer.

mmd_vmd_npc/lua/mmd_vmd_npc/cl_import_bake.lua is a Lua port of the native
baker and of the importer steps around it. These tests run it under LuaJIT
(through lupa, both GMod runtimes when available) and compare its motion JSON
with the Python importer's on synthetic VMDs. They also check that the
generated skeleton data (cl_import_data.lua) is current.

Run from the repository root:
    python -m pip install lupa
    python -m unittest discover -s tests
"""

from __future__ import annotations

import hashlib
import importlib
import json
import math
import struct
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import build_ingame_import_data  # noqa: E402
import import_vmd  # noqa: E402
import vmd_baker  # noqa: E402

LUA_DIR = ROOT / "mmd_vmd_npc" / "lua" / "mmd_vmd_npc"


def lua_runtimes() -> list[str]:
    names = []
    for name in ("luajit20", "luajit21"):
        try:
            importlib.import_module("lupa." + name)
            names.append(name)
        except ImportError:
            continue
    return names


RUNTIMES = lua_runtimes()

RUN_IMPORT = rb"""
function(body, camera, flexes, flexPaths, unify, noik, name, bodyName, bodyPath, cameraName, bodyHash, audioOffset)
    local Bake = MMDVMDNPC.ImportBake
    local parsed = Bake.ParseVMD(body, {})
    local doc, ground = Bake.BakeMotion(parsed, { disableIK = noik, unifyGround = unify, inputName = bodyName })
    local sources = { { parsed = parsed, label = "main VMD", path = bodyPath, main = true } }
    for i = 1, #flexes do
        sources[#sources + 1] = { parsed = Bake.ParseVMD(flexes[i], { bones = false }), label = "extra flex VMD #" .. i, path = flexPaths[i] }
    end
    local flexOut, warnings = Bake.MergeFlexTracks(sources)
    local cameraTrack
    if camera then
        cameraTrack = Bake.CameraTrack(Bake.ParseVMD(camera, { bones = false, morphs = false }), cameraName, ground)
    end
    return (Bake.MotionJSON(doc, {
        flexes = flexOut, flexWarnings = warnings, camera = cameraTrack, audioOffset = audioOffset,
        motionID = Bake.MotionID(name, false, bodyHash), nameSource = name, nameIsPath = false,
        meta = { display_name = name, artist = "Artist", link = "https://example.com" },
    }))
end
"""


def load_lua(runtime: str, data_file: Path | None = None):
    lupa = importlib.import_module("lupa." + runtime)
    lua = lupa.LuaRuntime(encoding=None, unpack_returned_tuples=True)
    lua.execute(b"MMDVMDNPC = {}")
    for path in (data_file or LUA_DIR / "cl_import_data.lua", LUA_DIR / "cl_import_bake.lua"):
        lua.execute(path.read_bytes())
    bake = lua.eval(b"MMDVMDNPC.ImportBake")
    bake[b"SHA1"] = lambda data: hashlib.sha1(bytes(data)).hexdigest().encode()
    return lua


def random_interp(rng: np.random.Generator) -> bytes:
    data = bytearray(rng.integers(0, 128, size=64, dtype=np.uint8).tobytes())
    if rng.random() < 0.3:
        for channel in range(4):  # the default linear curve
            data[16 * channel: 16 * channel + 13: 4] = bytes([20, 20, 107, 107])
    return bytes(data)


def random_quat(rng: np.random.Generator, spread: float = 1.0) -> tuple[float, ...]:
    axis = rng.normal(size=3)
    axis /= np.linalg.norm(axis)
    half = 0.5 * rng.uniform(-spread, spread)
    return (*(axis * math.sin(half)), math.cos(half))


def vmd_bytes(bones=(), morphs=(), cameras=(), properties=(), legacy: bool = False) -> bytes:
    out = bytearray((b"Vocaloid Motion Data file" if legacy else b"Vocaloid Motion Data 0002").ljust(30, b"\x00"))
    out += b"model".ljust(10 if legacy else 20, b"\x00")
    out += struct.pack("<I", len(bones))
    for name, frame, location, rotation, interp in bones:
        out += name.encode("cp932")[:15].ljust(15, b"\x00") + struct.pack("<I3f4f", frame, *location, *rotation) + interp
    out += struct.pack("<I", len(morphs))
    for name, frame, weight in morphs:
        out += name.encode("cp932")[:15].ljust(15, b"\x00") + struct.pack("<If", frame, weight)
    out += struct.pack("<I", len(cameras))
    for frame, distance, target, rotation, interp, fov in cameras:
        out += struct.pack("<If3f3f", frame, distance, *target, *rotation) + interp + struct.pack("<IB", fov, 0)
    out += struct.pack("<II", 0, 0)
    out += struct.pack("<I", len(properties))
    for frame, states in properties:
        out += struct.pack("<IBI", frame, 1, len(states))
        for name, state in states:
            out += name.encode("cp932")[:20].ljust(20, b"\x00") + struct.pack("<B", 1 if state else 0)
    return bytes(out)


def dance(seed: int, frames: int = 150) -> tuple[bytes, bytes, bytes]:
    """A body VMD exercising FK curves, appends, both IK solvers, IK toggles,
    unsorted and duplicated keys, unknown bones and a scene cut; a face VMD
    overlapping its morphs; and a camera VMD."""
    rng = np.random.default_rng(seed)
    bones = []
    rotating = ["上半身", "上半身2", "首", "頭", "左腕", "右腕", "左ひじ", "右ひじ", "左手首", "左腕捩", "左肩P",
                "右親指１", "左人指２", "下半身", "腰", "左足", "右ひざ", "左目", "存在しない骨"]
    for name in rotating:
        for frame in sorted(rng.choice(frames, size=6, replace=False)):
            bones.append((name, int(frame), (0.0, 0.0, 0.0), random_quat(rng, 1.4), random_interp(rng)))
    for name, scale in (("センター", 2.0), ("グルーブ", 1.0), ("左足ＩＫ", 3.0), ("右足ＩＫ", 3.0), ("左つま先ＩＫ", 1.0)):
        for frame in sorted(rng.choice(frames, size=5, replace=False)):
            location = tuple(float(v) for v in rng.uniform(-scale, scale, size=3))
            bones.append((name, int(frame), location, random_quat(rng, 0.5), random_interp(rng)))
    # The whole character jumps to another spot at frame 100 (a scene cut).
    bones += [("全ての親", 0, (0.0, 0.0, 0.0), (0.0, 0.0, 0.0, 1.0), random_interp(rng)),
              ("全ての親", 99, (0.0, 0.0, 0.0), (0.0, 0.0, 0.0, 1.0), random_interp(rng)),
              ("全ての親", 100, (25.0, 4.0, -10.0), (0.0, 0.0, 0.0, 1.0), random_interp(rng))]
    bones.append(("左腕", 20, (0.0, 0.0, 0.0), random_quat(rng), random_interp(rng)))  # a duplicated frame
    rng.shuffle(bones)  # keys in no particular order
    properties = [(40, [("左足ＩＫ", False), ("右つま先ＩＫ", False)]), (90, [("左足ＩＫ", True)])]
    morphs = []
    for name in ("あ", "い", "まばたき", "笑い", "ウィンク", "not a morph"):
        for frame in sorted(rng.choice(frames, size=8, replace=False)):
            morphs.append((name, int(frame), float(rng.choice([0.0, 0.0, 1.0, rng.uniform(0, 1)]))))
    morphs.append(("お", 0, 0.0))  # a zero placeholder the face VMD replaces
    body = vmd_bytes(bones, morphs, properties=properties)
    face = vmd_bytes(morphs=[(n, int(f), float(rng.uniform(0, 1))) for n in ("あ", "お", "じと目") for f in range(0, frames, 7)])
    cameras = []
    for frame in sorted(rng.choice(frames, size=12, replace=False)):
        target = tuple(float(v) for v in rng.uniform(-5, 15, size=3))
        rotation = tuple(float(v) for v in rng.uniform(-3, 3, size=3))
        cameras.append((int(frame), float(rng.uniform(-60, -10)), target, rotation, rng.integers(0, 128, size=24, dtype=np.uint8).tobytes(), int(rng.integers(15, 60))))
    camera = vmd_bytes(cameras=cameras, legacy=True)
    return body, face, camera


class DataFileTests(unittest.TestCase):
    def test_generated_skeleton_data_is_current(self) -> None:
        committed = (LUA_DIR / "cl_import_data.lua").read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as tmp:
            fresh = build_ingame_import_data.build(Path(tmp) / "cl_import_data.lua")
        self.assertEqual(committed, fresh, "run python tools/build_ingame_import_data.py")

    def test_motion_manager_finds_music_of_both_importers(self) -> None:
        gmod = Path("G:/GarrysMod")
        music, root = import_vmd.gmod_music_file(gmod, "mmd_vmd_npc/music/dance_0123456789.mp3")
        self.assertEqual((music, root), (gmod / "garrysmod/sound/mmd_vmd_npc/music/dance_0123456789.mp3", gmod / "garrysmod/sound"))
        music, root = import_vmd.gmod_music_file(gmod, "data/mmd_vmd_npc/music/dance_0123456789.ogg")
        self.assertEqual((music, root), (gmod / "garrysmod/data/mmd_vmd_npc/music/dance_0123456789.ogg", gmod / "garrysmod/data/mmd_vmd_npc/music"))
        music, root = import_vmd.gmod_music_file(gmod, "data/../../cfg/config.cfg")
        self.assertNotIn(root, music.parents)


@unittest.skipUnless(RUNTIMES, "lupa (LuaJIT) is not installed")
class ParityTests(unittest.TestCase):
    def python_import(self, tmp: Path, body: Path, face: Path, camera: Path, name: str, unify: bool, noik: bool) -> dict:
        rotation = import_vmd.bake_vmd_native(body, disable_foot_ik=noik, unify_ground=unify)
        track = import_vmd.build_camera_track(camera, ground_offsets=import_vmd.rotation_ground_offsets(rotation))
        out = import_vmd.write_motion_json(
            rotation, tmp / "out", name, body, extra_flex_vmd_paths=[face], audio_offset=0.25, camera_track=track,
            meta={"display_name": name, "artist": "Artist", "link": "https://example.com"},
        )
        return json.loads(out.read_text(encoding="utf-8"))

    def lua_import(self, runtime: str, body: Path, face: Path, camera: Path, name: str, unify: bool, noik: bool) -> dict:
        lua = load_lua(runtime)
        data = body.read_bytes()
        text = lua.eval(RUN_IMPORT)(
            data, camera.read_bytes(), lua.table_from([face.read_bytes()]), lua.table_from([str(face).encode()]),
            unify, noik, name.encode(), body.name.encode(), str(body).encode(), camera.name.encode(),
            hashlib.sha1(data).hexdigest().encode(), 0.25,
        )
        return json.loads(bytes(text).decode("utf-8"))

    def assert_same(self, lua_value, py_value, path: str = "doc") -> None:
        if isinstance(py_value, dict):
            self.assertIsInstance(lua_value, dict, path)
            self.assertEqual(list(lua_value), list(py_value), f"{path}: keys")
            for key in py_value:
                self.assert_same(lua_value[key], py_value[key], f"{path}.{key}")
        elif isinstance(py_value, list):
            self.assertIsInstance(lua_value, list, path)
            self.assertEqual(len(lua_value), len(py_value), f"{path}: length")
            for index, (a, b) in enumerate(zip(lua_value, py_value)):
                self.assert_same(a, b, f"{path}[{index}]")
        elif isinstance(py_value, (int, float)) and not isinstance(py_value, bool):
            self.assertAlmostEqual(float(lua_value), float(py_value), delta=2.5e-6, msg=path)
        else:
            self.assertEqual(lua_value, py_value, path)

    def check(self, seed: int, unify: bool = False, noik: bool = False) -> dict:
        body_data, face_data, camera_data = dance(seed)
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            body, face, camera = tmp / "body.vmd", tmp / "face.vmd", tmp / "camera.vmd"
            body.write_bytes(body_data)
            face.write_bytes(face_data)
            camera.write_bytes(camera_data)
            expected = self.python_import(tmp, body, face, camera, "Parity Dance", unify, noik)
            for runtime in RUNTIMES:
                with self.subTest(runtime=runtime):
                    self.assert_same(self.lua_import(runtime, body, face, camera, "Parity Dance", unify, noik), expected)
        return expected

    def test_dance_matches_python(self) -> None:
        expected = self.check(seed=1)
        self.assertEqual(expected["cuts"], [100])
        self.assertTrue(expected.get("flex_warnings"))

    def test_unified_ground_matches_python(self) -> None:
        self.assertTrue(self.check(seed=2, unify=True)["ground_unified"])

    def test_disabled_ik_matches_python(self) -> None:
        self.check(seed=3, noik=True)

    def test_motion_ids_match_python(self) -> None:
        lua = load_lua(RUNTIMES[0])
        motion_id = lua.eval(b"MMDVMDNPC.ImportBake.MotionID")
        digest = "0123456789abcdef"
        for name, is_path in (("My Dance", False), ("炉心融解", False), ("  Spaces  & Symbols!  ", False),
                              ("Ａｂｃ", False), ("dance.vmd", False), ("C:\\motions\\My Dance.vmd", True),
                              ("folder/song.mp3", False), ("v1.2 remix", False), ("", False)):
            with self.subTest(name=name):
                source = Path(name) if is_path else name
                slug = import_vmd.slugify(source)
                expected = f"{slug}_{digest[:10]}"
                self.assertEqual(bytes(motion_id(name.encode(), is_path, digest.encode())).decode(), expected)

    def test_ccd_solvers_match_python(self) -> None:
        # The bundled model solves its legs in closed form; this skeleton
        # takes the other IK paths: CCD on a hinge link (limited on X only)
        # and on a link limited on two axes (Euler decomposition).
        bone, link = import_vmd.PMXBone, import_vmd.PMXIKLink
        skeleton = [
            bone(0, "下半身", "", (0.0, 10.0, 0.0), -1, 0x1E, None, (0.0, 1.0, 0.0), None, None),
            bone(1, "左腕", "", (0.0, 10.0, 0.0), 0, 0x1E, None, (0.0, -5.0, 0.0), None, None),
            bone(2, "左ひじ", "", (0.0, 5.0, 0.0), 1, 0x1E, None, (0.0, -1.0, 0.0), None, None),
            bone(3, "ik1", "", (2.0, 5.5, 0.0), 0, 0x3E, None, (0.0, 1.0, 0.0), None, None,
                 ik_target=2, ik_loop_count=40, ik_limit_angle=0.4, ik_links=[link(1, (-0.3, 0.0, -0.6), (0.3, 0.0, 0.6))]),
            bone(4, "右腕", "", (0.0, 10.0, 0.0), 0, 0x1E, None, (0.0, -5.0, 0.0), None, None),
            bone(5, "右ひじ", "", (0.0, 5.0, 0.0), 4, 0x1E, None, (0.0, -1.0, 0.0), None, None),
            bone(6, "ik2", "", (0.0, 6.0, 2.0), 0, 0x3E, None, (0.0, 1.0, 0.0), None, None,
                 ik_target=5, ik_loop_count=40, ik_limit_angle=0.3, ik_links=[link(4, (-1.2, 0.0, 0.0), (1.2, 0.0, 0.0))]),
        ]
        rng = np.random.default_rng(11)
        keys = []
        for name in ("ik1", "ik2"):
            for frame in (0, 20, 40, 60):
                keys.append((name, frame, tuple(float(v) for v in rng.uniform(-4, 4, size=3)), (0.0, 0.0, 0.0, 1.0), random_interp(rng)))
        for name in ("左腕", "右腕"):
            for frame in (0, 30, 60):
                keys.append((name, frame, (0.0, 0.0, 0.0), random_quat(rng, 0.8), random_interp(rng)))
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            data_file = tmp / "solver_data.lua"
            build_ingame_import_data.build(data_file, bones=skeleton, model_path=tmp / "solver.pmx")
            vmd = tmp / "solver.vmd"
            vmd.write_bytes(vmd_bytes(keys))
            parsed = import_vmd.parse_vmd(vmd)
            model = vmd_baker.prepare_model(skeleton)
            self.assertEqual([chain.links[0].plane_axis for chain in model.chains.values()], [-1, 0])
            expected = vmd_baker.bake_motion(skeleton, parsed, import_vmd.load_bone_mapping(), 0, parsed.max_frame, input_vmd=vmd)
            for runtime in RUNTIMES:
                with self.subTest(runtime=runtime):
                    lua = load_lua(runtime, data_file)
                    text = lua.eval(b"function(data) local Bake = MMDVMDNPC.ImportBake return Bake.EncodeJSON((Bake.BakeMotion(Bake.ParseVMD(data, {}), {}))) end")(vmd.read_bytes())
                    self.assert_same(json.loads(bytes(text).decode("utf-8"))["bones"], expected["bones"])
        self.assertEqual(len(expected["bones"]), 5)

    def test_truncated_vmd_is_an_error(self) -> None:
        lua = load_lua(RUNTIMES[0])
        body, _, _ = dance(seed=4)
        parse = lua.eval(b"function(data) local ok, err = pcall(MMDVMDNPC.ImportBake.ParseVMD, data) return ok, err end")
        ok, err = parse(body[:-40])
        self.assertFalse(ok)
        self.assertIn(b"unexpected end of VMD", bytes(err))
        ok, err = parse(b"not a motion file at all, just text" * 2)
        self.assertFalse(ok)
        self.assertIn(b"not a VMD file", bytes(err))


if __name__ == "__main__":
    unittest.main()
