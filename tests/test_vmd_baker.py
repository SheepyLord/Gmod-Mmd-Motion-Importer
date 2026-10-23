"""Regression tests for the native VMD baker.

Run from the repository root:
    python -m unittest discover -s tests
"""

from __future__ import annotations

import json
import math
import struct
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

import import_vmd  # noqa: E402
import vmd_baker  # noqa: E402


def linear_interp() -> bytes:
    data = bytearray(64)
    for channel in range(4):
        data[16 * channel + 0] = 20  # x1
        data[16 * channel + 4] = 20  # y1
        data[16 * channel + 8] = 107  # x2
        data[16 * channel + 12] = 107  # y2
    return bytes(data)


def axis_quat(axis: tuple[float, float, float], degrees: float) -> tuple[float, float, float, float]:
    half = math.radians(degrees) / 2.0
    return (axis[0] * math.sin(half), axis[1] * math.sin(half), axis[2] * math.sin(half), math.cos(half))


def key(frame: int, location=(0.0, 0.0, 0.0), rotation=(0.0, 0.0, 0.0, 1.0)) -> import_vmd.BoneFrame:
    return import_vmd.BoneFrame(frame, tuple(location), tuple(rotation), linear_interp())


def motion(bone_frames: dict, property_frames=None, max_frame: int = 0) -> import_vmd.ParsedVMD:
    return import_vmd.ParsedVMD("test", bone_frames, {}, list(property_frames or []), max_frame)


def write_vmd(path: Path, camera_keys: list[tuple[int, float, tuple, tuple]] = ()) -> Path:
    """Minimal VMD: no bones or morphs, optional camera keys
    (frame, distance, target, rotation) with linear interpolation."""
    out = bytearray(b"Vocaloid Motion Data 0002".ljust(30, b"\x00") + b"camera".ljust(20, b"\x00"))
    out += struct.pack("<II", 0, 0)
    out += struct.pack("<I", len(camera_keys))
    for frame, distance, target, rotation in camera_keys:
        out += struct.pack("<If3f3f", frame, distance, *target, *rotation)
        out += bytes([20, 107, 20, 107] * 6)
        out += struct.pack("<IB", 30, 0)
    out += struct.pack("<III", 0, 0, 0)
    path.write_bytes(bytes(out))
    return path


class BakerTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.model_path = import_vmd.find_default_mmd_model()
        cls.bones = import_vmd.parse_pmx_bones(cls.model_path)
        cls.bone_map = import_vmd.load_bone_mapping()
        cls.model = vmd_baker.prepare_model(cls.bones)
        cls.index = {name: i for i, name in enumerate(cls.model.names)}

    def bake(self, vmd: import_vmd.ParsedVMD, **kwargs) -> dict:
        return vmd_baker.bake_motion(self.bones, vmd, self.bone_map, 0, vmd.max_frame, model_path=self.model_path, **kwargs)

    def pose(self, vmd: import_vmd.ParsedVMD, frames, disable_ik: bool = False):
        frames = np.asarray(frames, dtype=np.float64)
        tracks, _ = vmd_baker.build_tracks(self.model, vmd.bone_frames)
        masks = vmd_baker.ik_enabled_masks(self.model, vmd.property_frames, frames, disable_all=disable_ik)
        return vmd_baker.evaluate_frames(self.model, tracks, frames, masks)

    @staticmethod
    def track(document: dict, target: str) -> dict:
        return next(bone for bone in document["bones"] if bone["g"] == target)

    @staticmethod
    def sample(track: dict, frame: int) -> list[float]:
        keys = track["k"]
        frames = [k[0] for k in keys]
        return [float(np.interp(frame, frames, [k[c] for k in keys])) for c in range(1, 7)]


class MathTests(unittest.TestCase):
    def test_bezier_linear_curve_is_identity(self) -> None:
        x = np.linspace(0.0, 1.0, 11)
        p = np.full_like(x, 20 / 127)
        q = np.full_like(x, 107 / 127)
        np.testing.assert_allclose(vmd_baker.bezier_progress(x, p, p, q, q), x, atol=1e-12)

    def test_bezier_ease_is_monotonic_with_fixed_ends(self) -> None:
        x = np.linspace(0.0, 1.0, 101)
        ones = np.ones_like(x)
        y = vmd_baker.bezier_progress(x, 0.9 * ones, 0.0 * ones, 0.1 * ones, 1.0 * ones)
        self.assertAlmostEqual(y[0], 0.0, places=9)
        self.assertAlmostEqual(y[-1], 1.0, places=9)
        self.assertTrue(np.all(np.diff(y) >= -1e-12))
        self.assertLess(y[25], 0.25)  # eases in

    def test_append_power_inverts_and_halves(self) -> None:
        q = np.array([axis_quat((0.3, 0.8, -0.52), 70.0)])
        q = vmd_baker.q_normalize(q)
        np.testing.assert_allclose(vmd_baker.q_power(q, -1.0), vmd_baker.q_conj(q), atol=1e-12)
        half = vmd_baker.q_power(q, 0.5)
        np.testing.assert_allclose(vmd_baker.q_mul(half, half), q, atol=1e-12)

    def test_blender_axis_conversion(self) -> None:
        # +30 deg about MMD up (+Y) is -30 deg about Blender up (+Z): mmd_tools
        # maps MMD (x, y, z) to Blender (x, z, y), a mirror.
        q = np.array([axis_quat((0.0, 1.0, 0.0), 30.0)])
        euler = vmd_baker._extrinsic_xyz_degrees(vmd_baker._blender_quaternion(q))
        np.testing.assert_allclose(euler[0], [0.0, 0.0, -30.0], atol=1e-6)

    def test_compaction_keeps_last_frame_of_each_hold(self) -> None:
        values = [(0.0,) * 6] * 5 + [(10.0, 0, 0, 0, 0, 0)] + [(10.0, 0, 0, 0, 0, 0)] * 3
        keys = vmd_baker.compact_keyframes(list(range(9)), values)
        self.assertEqual([k[0] for k in keys], [0, 4, 5, 8])

    def test_euler_decomposition_round_trips(self) -> None:
        rng = np.random.default_rng(7)
        angles = rng.uniform(-1.4, 1.4, size=(64, 3))
        quats = vmd_baker._quat_from_xyz(angles)
        recovered = vmd_baker._decompose_xyz(vmd_baker.q_to_matrix(quats), angles)
        np.testing.assert_allclose(recovered, angles, atol=1e-9)

    def test_ccd_respects_multi_axis_limits(self) -> None:
        # A single link limited to +-0.3 rad on X and Z (not a hinge) whose
        # target needs 0.6 rad about Z: CCD must stop at the Z limit.
        reach = 0.6
        bones = [
            import_vmd.PMXBone(0, "root", "", (0.0, 0.0, 0.0), -1, 0x1E, None, (0.0, 1.0, 0.0), None, None),
            import_vmd.PMXBone(1, "link", "", (0.0, 0.0, 0.0), 0, 0x1E, None, (0.0, -5.0, 0.0), None, None),
            import_vmd.PMXBone(2, "tip", "", (0.0, -5.0, 0.0), 1, 0x1E, None, (0.0, -1.0, 0.0), None, None),
            import_vmd.PMXBone(
                3, "ik", "", (5.0 * math.sin(reach), -5.0 * math.cos(reach), 0.0), 0, 0x3E, None, (0.0, 1.0, 0.0), None, None,
                ik_target=2, ik_loop_count=40, ik_limit_angle=1.0,
                ik_links=[import_vmd.PMXIKLink(1, (-0.3, 0.0, -0.3), (0.3, 0.0, 0.3))],
            ),
        ]
        model = vmd_baker.prepare_model(bones)
        self.assertEqual(model.chains[3].links[0].plane_axis, -1)
        frames = np.array([0.0])
        pose = vmd_baker.evaluate_frames(model, {}, frames, vmd_baker.ik_enabled_masks(model, [], frames))
        angles = vmd_baker._decompose_xyz(vmd_baker.q_to_matrix(pose.local_q[1]), np.zeros((1, 3)))[0]
        np.testing.assert_allclose(angles, [0.0, 0.0, 0.3], atol=1e-6)

    def test_lr_rename_matches_mmd_tools(self) -> None:
        self.assertEqual(vmd_baker.convert_name_to_lr("左ひざ"), "ひざ.L")
        self.assertEqual(vmd_baker.convert_name_to_lr("右人指１"), "人指１.R")
        self.assertEqual(vmd_baker.blender_bone_names(["a", "a", "左a"]), ["a", "a.001", "a.L"])


class BakeTests(BakerTestCase):
    def test_document_shape(self) -> None:
        doc = self.bake(motion({"左腕": [key(0), key(10, rotation=axis_quat((0, 0, 1), 30))]}, max_frame=10))
        self.assertEqual(doc["format"], "mmd_vmd_npc_parent_corrected_axis_v1")
        self.assertEqual(doc["columns"], ["frame", "x_deg", "y_deg", "z_deg", "pos_x", "pos_y", "pos_z"])
        self.assertEqual((doc["frame_start"], doc["frame_end"], doc["frame_count"], doc["fps"]), (0, 10, 11, 30))
        self.assertEqual(doc["armature"], f"{self.model_path.stem}_arm")
        self.assertEqual(doc["bone_count"], len(doc["bones"]))
        targets = [bone["g"] for bone in doc["bones"]]
        self.assertEqual(targets, sorted(targets))
        pelvis = self.track(doc, "ValveBiped.Bip01_Pelvis")
        self.assertEqual((pelvis["m"], pelvis["role"]), ("下半身", "pelvis_global"))
        self.assertEqual(self.track(doc, "ValveBiped.Bip01_L_Forearm")["role"], "source_parent_override")
        self.assertEqual(self.track(doc, "ValveBiped.Bip01_L_Calf")["m"], "ひざ.L")

    def test_fk_rotation_lands_on_its_own_frame(self) -> None:
        # The old Blender bake was one frame late; a key at frame 10 must
        # reach its value at frame 10, not 11.
        doc = self.bake(motion({"左腕": [key(0), key(10, rotation=axis_quat((0, 0, 1), 30)), key(20, rotation=axis_quat((0, 0, 1), 30))]}, max_frame=20))
        upper_arm = self.track(doc, "ValveBiped.Bip01_L_UpperArm")
        np.testing.assert_allclose(self.sample(upper_arm, 10)[:3], [0.0, -30.0, 0.0], atol=1e-5)
        np.testing.assert_allclose(self.sample(upper_arm, 5)[:3], [0.0, -15.0, 0.0], atol=1e-5)
        np.testing.assert_allclose(self.sample(upper_arm, 0)[:3], [0.0, 0.0, 0.0], atol=1e-6)

    def test_crouch_keeps_feet_on_ik_targets(self) -> None:
        crouch = motion({"センター": [key(0), key(30, location=(0.0, -3.0, 0.0))]}, max_frame=30)
        pose = self.pose(crouch, range(31))
        for side in "左右":
            ankle = pose.global_p[self.index[side + "足首"]]
            target = pose.global_p[self.index[side + "足ＩＫ"]]
            # Frame 0 is the rest pose: the 0.5 deg minimum knee bend leaves the
            # straight-leg target just out of reach, as in MMD.
            self.assertLess(np.linalg.norm(ankle[0] - target[0]), 2e-3)
            np.testing.assert_allclose(ankle[3:], target[3:], atol=1e-6)
            knee = pose.local_q[self.index[side + "ひざ"]][-1]
            bend = math.degrees(2.0 * math.atan2(np.linalg.norm(knee[:3]), knee[3]))
            self.assertGreater(bend, 40.0)
            self.assertLess(knee[0], 0.0)  # bends about -X, i.e. forward
            # Toe IK (single-link CCD) keeps the toe on its target too.
            toe = pose.global_p[self.index[side + "つま先"]]
            toe_target = pose.global_p[self.index[side + "つま先ＩＫ"]]
            self.assertLess(float(np.max(np.linalg.norm(toe[3:] - toe_target[3:], axis=-1))), 1e-3)
        doc = self.bake(crouch)
        pelvis = self.track(doc, "ValveBiped.Bip01_Pelvis")
        scale = vmd_baker.MMD_TO_BLENDER_SCALE * vmd_baker.BLENDER_TO_SOURCE_POSITION_SCALE
        self.assertAlmostEqual(self.sample(pelvis, 30)[5], -3.0 * scale, places=4)

    def test_knee_keeps_minimum_bend_when_straight(self) -> None:
        pose = self.pose(motion({}, max_frame=0), [0])
        knee = pose.local_q[self.index["左ひざ"]][0]
        bend = math.degrees(2.0 * math.atan2(np.linalg.norm(knee[:3]), knee[3]))
        self.assertAlmostEqual(bend, 0.5, places=4)

    def test_disable_ik_leaves_fk_legs(self) -> None:
        crouch = motion({"センター": [key(0), key(30, location=(0.0, -3.0, 0.0))]}, max_frame=30)
        pose = self.pose(crouch, [30], disable_ik=True)
        np.testing.assert_allclose(pose.local_q[self.index["左ひざ"]][0], [0.0, 0.0, 0.0, 1.0], atol=1e-12)

    def test_ik_toggle_applies_per_frame(self) -> None:
        props = [import_vmd.PropertyFrame(10, True, [("左足ＩＫ", False)])]
        crouch = motion({"センター": [key(0, location=(0.0, -3.0, 0.0))]}, props, max_frame=20)
        pose = self.pose(crouch, [5, 15])
        knee = pose.local_q[self.index["左ひざ"]]
        self.assertGreater(abs(knee[0][0]), 0.1)  # IK on: bent
        np.testing.assert_allclose(knee[1], [0.0, 0.0, 0.0, 1.0], atol=1e-12)  # IK off: FK
        right = pose.local_q[self.index["右ひざ"]]
        self.assertGreater(abs(right[1][0]), 0.1)  # other leg unaffected

    def test_shoulder_cancel_append(self) -> None:
        # 左肩C appends -1 x 左肩P, so a 左肩P rotation does not reach the arm.
        vmd = motion({"左肩P": [key(0, rotation=axis_quat((0, 0, 1), 25))]}, max_frame=0)
        pose = self.pose(vmd, [0])
        arm_global = pose.global_q[self.index["左腕"]][0]
        np.testing.assert_allclose(np.abs(arm_global), [0.0, 0.0, 0.0, 1.0], atol=1e-9)

    def test_twist_sub_bone_appends_half(self) -> None:
        vmd = motion({"左腕捩": [key(0, rotation=axis_quat((0.8, -0.6, 0.0), 40))]}, max_frame=0)
        pose = self.pose(vmd, [0])
        sub = pose.local_q[self.index["左腕捩1"]][0]
        angle = math.degrees(2.0 * math.atan2(np.linalg.norm(sub[:3]), sub[3]))
        self.assertAlmostEqual(angle, 20.0, places=6)

    def test_cancel_check_stops_the_bake(self) -> None:
        vmd = motion({"左腕": [key(0), key(5000)]}, max_frame=5000)
        with self.assertRaises(vmd_baker.BakeCancelled):
            self.bake(vmd, cancel_check=lambda: True)


class GroundUnifyTests(BakerTestCase):
    def test_floor_envelope_keeps_cuts_sharp_and_jumps_high(self) -> None:
        lowest = np.zeros(300)
        lowest[100:200] = 50.0  # scene cut onto a platform
        lowest[140:151] += 6.0  # an 11-frame jump on the platform
        lowest[200:230] = np.linspace(50.0, 80.0, 30)  # a riser
        lowest[230:] = 80.0
        offsets = vmd_baker.ground_offsets(lowest, rest_height=0.0)
        np.testing.assert_allclose(offsets[:100], 0.0, atol=1e-9)
        np.testing.assert_allclose(offsets[100:135], 50.0, atol=1e-9)  # cut stays a clean step
        np.testing.assert_allclose(offsets[140:151], 50.0, atol=1e-9)  # the jump keeps its 6 units
        np.testing.assert_allclose(offsets[212:218], lowest[212:218], atol=0.05)  # riser followed
        np.testing.assert_allclose(offsets[240:], 80.0, atol=1e-9)

    def test_rest_floor_is_the_lowest_contact_bone(self) -> None:
        contacts = vmd_baker.ground_contact_bones(self.model)
        self.assertIn(self.index["左つま先"], contacts)
        pose = self.pose(motion({}, max_frame=0), [0])
        lowest = vmd_baker.lowest_contact_heights(pose, contacts)
        self.assertAlmostEqual(float(lowest[0]), vmd_baker.ground_rest_height(self.model, contacts), places=3)

    def test_unify_ground_cancels_a_stage_platform(self) -> None:
        # 全ての親 lifts the whole character onto a 40-unit platform at a cut.
        stage = motion(
            {"全ての親": [key(0), key(20), key(21, location=(0.0, 40.0, 0.0)), key(60, location=(0.0, 40.0, 0.0))]},
            max_frame=60,
        )
        scale = vmd_baker.MMD_TO_BLENDER_SCALE * vmd_baker.BLENDER_TO_SOURCE_POSITION_SCALE
        plain = self.track(self.bake(stage), "ValveBiped.Bip01_Pelvis")
        self.assertAlmostEqual(self.sample(plain, 40)[5] - self.sample(plain, 10)[5], 40.0 * scale, places=3)

        document = self.bake(stage, unify_ground=True)
        pelvis = self.track(document, "ValveBiped.Bip01_Pelvis")
        self.assertAlmostEqual(self.sample(pelvis, 40)[5], self.sample(pelvis, 10)[5], places=3)
        # Standing frames stay where they were (within the rest pose's 0.5 deg knee-bend lift).
        self.assertAlmostEqual(self.sample(pelvis, 10)[5], self.sample(plain, 10)[5], delta=0.01)
        offsets = document["_ground_offsets_mmd"]
        self.assertEqual(len(offsets), 61)
        self.assertAlmostEqual(offsets[40] - offsets[10], 40.0, places=3)
        self.assertTrue(document["ground_unified"])
        self.assertNotIn("_ground_offsets_mmd", self.bake(stage))

    def test_camera_is_lowered_with_the_character(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            camera = write_vmd(Path(tmp) / "camera.vmd", [(0, -45.0, (0.0, 10.0, 0.0), (0.0, 0.0, 0.0)), (60, -45.0, (0.0, 10.0, 0.0), (0.0, 0.0, 0.0))])
            offsets = [0.0] * 21 + [40.0] * 40
            plain = import_vmd.build_camera_track(camera)
            lowered = import_vmd.build_camera_track(camera, ground_offsets=offsets)

        def height(track: dict, frame: int) -> float:
            keys = track["keys"]
            return float(np.interp(frame, [k[0] for k in keys], [k[3] for k in keys]))

        self.assertNotIn("ground_unified", plain)
        self.assertTrue(lowered["ground_unified"])
        self.assertAlmostEqual(height(lowered, 10), height(plain, 10), places=3)
        self.assertAlmostEqual(height(plain, 40) - height(lowered, 40), 40.0 * import_vmd.CAMERA_POSITION_SCALE, places=2)
        self.assertAlmostEqual(height(plain, 60) - height(lowered, 60), 40.0 * import_vmd.CAMERA_POSITION_SCALE, places=2)

    def test_motion_json_omits_bake_working_data(self) -> None:
        stage = motion({"全ての親": [key(0), key(10, location=(0.0, 5.0, 0.0))]}, max_frame=10)
        with tempfile.TemporaryDirectory() as tmp:
            body = write_vmd(Path(tmp) / "body.vmd")
            document = vmd_baker.bake_motion(
                self.bones, stage, self.bone_map, 0, 10, model_path=self.model_path, input_vmd=body, unify_ground=True
            )
            self.assertIn("_ground_offsets_mmd", document)
            output = import_vmd.write_motion_json(document, Path(tmp) / "out", "stage test", body)
            written = json.loads(output.read_text(encoding="utf-8"))
        self.assertFalse(any(key.startswith("_") for key in written))
        self.assertTrue(written["ground_unified"])

    def test_floor_smoothing_never_spans_a_scene_cut(self) -> None:
        lowest = np.zeros(100)
        lowest[50:] = 1.5  # a platform change smaller than GROUND_CUT_STEP, at a cut
        smoothed = vmd_baker.ground_offsets(lowest, rest_height=0.0)
        sharp = vmd_baker.ground_offsets(lowest, rest_height=0.0, pose_cuts=[50])
        self.assertGreater(float(smoothed[49]), 1e-3)  # leaks into the shot before the cut
        np.testing.assert_allclose(sharp[:50], 0.0, atol=1e-12)
        np.testing.assert_allclose(sharp[50:], 1.5, atol=1e-12)


class SceneCutTests(BakerTestCase):
    def test_single_frame_jumps_are_cuts_and_motion_is_not(self) -> None:
        run = np.zeros((60, 3))
        run[:, 0] = np.arange(60) * 5.0  # running at 5 units a frame
        self.assertEqual(vmd_baker.detect_pose_cuts(run), [])
        jump = run.copy()
        jump[30:, 0] += 40.0
        self.assertEqual(vmd_baker.detect_pose_cuts(jump), [30])
        small = np.zeros((40, 3))
        small[20:, 0] = 7.0  # below CUT_MIN_STEP
        self.assertEqual(vmd_baker.detect_pose_cuts(small), [])
        # An accelerating dash is fast but continuous.
        dash = np.zeros((40, 3))
        dash[:, 0] = np.cumsum(np.r_[np.zeros(15), np.linspace(10, 60, 10), np.linspace(60, 10, 10), np.zeros(5)])
        self.assertEqual(vmd_baker.detect_pose_cuts(dash), [])
        # Out to another spot and back two frames later: neither cut hides the other.
        out_and_back = np.zeros((40, 3))
        out_and_back[20:22, 2] = 100.0
        self.assertEqual(vmd_baker.detect_pose_cuts(out_and_back), [20, 22])

    def test_bake_records_scene_cuts_in_the_motion_json(self) -> None:
        # 全ての親 moves the character 30 MMD units (about 100 Source units) in one frame.
        stage = motion(
            {"全ての親": [key(0), key(20), key(21, location=(30.0, 0.0, 0.0)), key(40, location=(30.0, 0.0, 0.0))]},
            max_frame=40,
        )
        document = self.bake(stage)
        self.assertEqual(document["cuts"], [21])
        walk = motion({"センター": [key(0), key(40, location=(0.0, 0.0, 30.0))]}, max_frame=40)
        self.assertEqual(self.bake(walk)["cuts"], [])
        # A rotation document without the field (Blender, older bakes) gets it from the pelvis track.
        legacy = {name: value for name, value in document.items() if name != "cuts"}
        self.assertEqual(vmd_baker.document_pose_cuts(legacy), [21])
        with tempfile.TemporaryDirectory() as tmp:
            body = write_vmd(Path(tmp) / "body.vmd")
            output = import_vmd.write_motion_json(legacy, Path(tmp) / "out", "cut test", body)
            written = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(written["cuts"], [21])


if __name__ == "__main__":
    unittest.main()
