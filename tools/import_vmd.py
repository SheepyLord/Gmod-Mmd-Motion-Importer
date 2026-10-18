#!/usr/bin/env python3
"""Import baked MMD VMD motion into Garry's Mod compact motion JSON."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable


CACHE_MAGIC = b"MVMDNPC1"
CACHE_VERSION = 3
DEBUG_MAGIC = b"DBG1"
VMD_FPS = 30
SAMPLE_FPS = 60
# The supplied simple VMD moves 全ての親 by +25 MMD units for a 2 m move.
# On the supplied Source model that must become +64 local Source units.
SOURCE_SCALE = 64.0 / 25.0

def _tool_root() -> Path:
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        return Path(sys._MEIPASS)
    return Path(__file__).resolve().parents[1]


ROOT = _tool_root()
ADDON_DIR = ROOT / "mmd_vmd_npc"
SOURCE_MODELS = ROOT / "source_models"
BONE_SCRIPT = SOURCE_MODELS / "bone_mmd_to_source.py"
FLEX_SCRIPT = SOURCE_MODELS / "flex_mmd_to_source.py"
DEFAULT_MMD_MODEL_DIR = SOURCE_MODELS / "mmd_model"
DEFAULT_MMD_MODEL_NAME = "李织烟.pmx"
DEFAULT_SOURCE_SMD = SOURCE_MODELS / "mmd_model_source_format" / "Body.smd"
# Legacy reference bake through Blender + mmd_tools (CLI --bake-with-blender
# only). The importer itself bakes natively with vmd_baker and needs no Blender.
BLENDER_BAKE_SCRIPT = ROOT / "tools" / "blender_bake_vmd.py"
# Upper bound on the bake range (~2.3 hours at 30fps); anything larger is almost
# certainly a corrupt VMD frame count rather than a real motion.
MAX_BAKE_FRAMES = 250000
BAKED_OUTPUT_DIR = ROOT / "build" / "mmd_vmd_npc" / "baked"
PARENT_CORRECTED_ROTATION_JSON = "bone_parent_corrected_rotation_degrees.json"
STEAM_BLENDER_APP_ID = "365670"
STEAM_BLENDER_URL = "https://store.steampowered.com/app/365670/Blender/"
MIN_SUPPORTED_BLENDER_VERSION = (4, 3, 0)

# A completed portable Blender extraction always contains a sibling `portable`
# directory beside blender.exe; it doubles as an "extraction finished" marker.
BLENDER_PORTABLE_MARKER = "portable"
# This importer's own local-data folder (Motion Manager index).
APP_LOCAL_DIR_NAME = "MMDVMDNPC"
# Vendored mmd_tools zip so the legacy Blender bake can install it offline.
BLENDER_ADDONS_SUBDIR = "blender_addons"
# The sibling "Simple Character Model Importer" extracts a portable Blender 4.5
# (with mmd_tools installed) under its local-data folder; the legacy Blender
# bake reuses it when present.
SCMI_APP_DIR_NAME = "MMDCharacterImporter"

GMOD_SOUND_SUBDIR = "mmd_vmd_npc/music"
MUSIC_SAMPLE_RATE = 44100
MUSIC_BITRATE = "192k"
ProgressCallback = Callable[[str], None]
CancelCheck = Callable[[], bool]


EXTRA_BONE_ROLES = {
    "全ての親": ("", "root"),
    "mother": ("", "root"),
    "センター": ("", "center"),
    "center": ("", "center"),
    "グルーブ": ("", "groove"),
    "groove": ("", "groove"),
    "腰": ("", "waist"),
    "waist": ("", "waist"),
    "左足ＩＫ": ("", "left_foot_ik"),
    "左足IK": ("", "left_foot_ik"),
    "left leg IK": ("", "left_foot_ik"),
    "右足ＩＫ": ("", "right_foot_ik"),
    "右足IK": ("", "right_foot_ik"),
    "right leg IK": ("", "right_foot_ik"),
    "左つま先ＩＫ": ("", "left_toe_ik"),
    "左つま先IK": ("", "left_toe_ik"),
    "右つま先ＩＫ": ("", "right_toe_ik"),
    "右つま先IK": ("", "right_toe_ik"),
}

EXTRA_BONE_ALIASES = {
    "下半身": ("ValveBiped.Bip01_Pelvis", ""),
    "上半身": ("ValveBiped.Bip01_Spine", ""),
    "上半身1": ("ValveBiped.Bip01_Spine1", ""),
    "上半身2": ("ValveBiped.Bip01_Spine2", ""),
    "胸": ("ValveBiped.Bip01_Spine4", ""),
    "首": ("ValveBiped.Bip01_Neck1", ""),
    "頭": ("ValveBiped.Bip01_Head1", ""),
    "目.L": ("ValveBiped.Bip01_L_Eye", ""),
    "目.R": ("ValveBiped.Bip01_R_Eye", ""),
    "肩.L": ("ValveBiped.Bip01_L_Clavicle", ""),
    "肩.R": ("ValveBiped.Bip01_R_Clavicle", ""),
    "腕.L": ("ValveBiped.Bip01_L_UpperArm", ""),
    "腕.R": ("ValveBiped.Bip01_R_UpperArm", ""),
    "腕捩.L": ("ZArmTwist_L", ""),
    "腕捩.R": ("ZArmTwist_R", ""),
    "腕捩1.L": ("ZArmTwist_L", ""),
    "腕捩1.R": ("ZArmTwist_R", ""),
    "ひじ.L": ("ValveBiped.Bip01_L_Forearm", ""),
    "ひじ.R": ("ValveBiped.Bip01_R_Forearm", ""),
    "手捩.L": ("ZHandTwist_L", ""),
    "手捩.R": ("ZHandTwist_R", ""),
    "手捩1.L": ("ZHandTwist_L", ""),
    "手捩1.R": ("ZHandTwist_R", ""),
    "手首.L": ("ValveBiped.Bip01_L_Hand", ""),
    "手首.R": ("ValveBiped.Bip01_R_Hand", ""),
    "足.L": ("ValveBiped.Bip01_L_Thigh", ""),
    "足.R": ("ValveBiped.Bip01_R_Thigh", ""),
    "ひざ.L": ("ValveBiped.Bip01_L_Calf", ""),
    "ひざ.R": ("ValveBiped.Bip01_R_Calf", ""),
    "足首.L": ("ValveBiped.Bip01_L_Foot", ""),
    "足首.R": ("ValveBiped.Bip01_R_Foot", ""),
    "つま先.L": ("ValveBiped.Bip01_L_Toe0", ""),
    "つま先.R": ("ValveBiped.Bip01_R_Toe0", ""),
    "上半身1": ("ValveBiped.Bip01_Spine1", ""),
    "上半身3": ("ValveBiped.Bip01_Spine1", ""),
    "upper body2": ("ValveBiped.Bip01_Spine1", ""),
    "上半身2": ("ValveBiped.Bip01_Spine2", ""),
    "upper body3": ("ValveBiped.Bip01_Spine2", ""),
}


def build_blender_finger_bone_aliases() -> dict[str, tuple[str, str]]:
    """Map MMD Tools' Blender-style finger names to ValveBiped fingers."""

    digit_variants = {
        "0": ("\uFF10", "0"),
        "1": ("\uFF11", "1"),
        "2": ("\uFF12", "2"),
        "3": ("\uFF13", "3"),
    }
    finger_specs = [
        ("\u89AA\u6307", "0", "Finger0"),
        ("\u89AA\u6307", "1", "Finger01"),
        ("\u89AA\u6307", "2", "Finger02"),
        ("\u4EBA\u6307", "1", "Finger1"),
        ("\u4EBA\u6307", "2", "Finger11"),
        ("\u4EBA\u6307", "3", "Finger12"),
        ("\u4E2D\u6307", "1", "Finger2"),
        ("\u4E2D\u6307", "2", "Finger21"),
        ("\u4E2D\u6307", "3", "Finger22"),
        ("\u85AC\u6307", "1", "Finger3"),
        ("\u85AC\u6307", "2", "Finger31"),
        ("\u85AC\u6307", "3", "Finger32"),
        ("\u5C0F\u6307", "1", "Finger4"),
        ("\u5C0F\u6307", "2", "Finger41"),
        ("\u5C0F\u6307", "3", "Finger42"),
    ]

    aliases: dict[str, tuple[str, str]] = {}
    for suffix, source_side in ((".L", "L"), (".R", "R")):
        for base_name, digit_key, source_finger in finger_specs:
            source_name = f"ValveBiped.Bip01_{source_side}_{source_finger}"
            for digit in digit_variants[digit_key]:
                aliases[f"{base_name}{digit}{suffix}"] = (source_name, "")
    return aliases


BLENDER_FINGER_BONE_ALIASES = build_blender_finger_bone_aliases()


BLENDER_BONE_ROLES = {
    "全ての親": ("", "root"),
    "センター": ("", "center"),
    "グルーブ": ("", "groove"),
    "腰": ("", "waist"),
}


@dataclass
class BoneFrame:
    frame: int
    location: tuple[float, float, float]
    rotation: tuple[float, float, float, float]
    interp: bytes


@dataclass
class MorphFrame:
    frame: int
    weight: float


@dataclass
class PropertyFrame:
    frame: int
    visible: bool
    ik_states: list[tuple[str, bool]]


@dataclass
class PMXIKLink:
    bone: int
    limit_min: tuple[float, float, float] | None
    limit_max: tuple[float, float, float] | None


@dataclass
class PMXBone:
    index: int
    name: str
    english_name: str
    position: tuple[float, float, float]
    parent: int
    flags: int
    tail_index: int | None
    tail_offset: tuple[float, float, float] | None
    local_axis_x: tuple[float, float, float] | None
    local_axis_z: tuple[float, float, float] | None
    transform_level: int = 0
    append_parent: int = -1
    append_ratio: float = 0.0
    fixed_axis: tuple[float, float, float] | None = None
    ik_target: int = -1
    ik_loop_count: int = 0
    ik_limit_angle: float = 0.0
    ik_links: list[PMXIKLink] = field(default_factory=list)


@dataclass
class SMDBone:
    index: int
    name: str
    parent: int
    local_pos: tuple[float, float, float]
    local_ang: tuple[float, float, float]
    local_basis: list[list[float]]
    world_basis: list[list[float]]


@dataclass
class BoneRetarget:
    source_name: str
    mmd_name: str
    matrix: list[list[float]]
    inverse: list[list[float]]
    source_basis: list[list[float]]


@dataclass
class CameraFrame:
    frame: int
    distance: float
    position: tuple[float, float, float]
    rotation: tuple[float, float, float]  # radians, raw VMD values
    interp: bytes  # 24 bytes: 6 channels (X, Y, Z, rotation, distance, fov) x (x1, x2, y1, y2)
    fov: float  # vertical field of view in degrees
    perspective: bool


@dataclass
class ParsedVMD:
    model_name: str
    bone_frames: dict[str, list[BoneFrame]]
    morph_frames: dict[str, list[MorphFrame]]
    property_frames: list[PropertyFrame]
    max_frame: int
    camera_frames: list[CameraFrame] = field(default_factory=list)


def read_exact(handle, size: int) -> bytes:
    data = handle.read(size)
    if len(data) != size:
        raise EOFError("unexpected end of VMD")
    return data


def read_u32(handle) -> int:
    return struct.unpack("<L", read_exact(handle, 4))[0]


def decode_cp932(raw: bytes) -> str:
    raw = raw.split(b"\x00", 1)[0]
    return raw.decode("cp932", errors="replace")


def read_count_or_zero(handle) -> int:
    data = handle.read(4)
    if len(data) < 4:
        return 0
    return struct.unpack("<L", data)[0]


def parse_vmd(path: Path) -> ParsedVMD:
    bone_frames: dict[str, list[BoneFrame]] = {}
    morph_frames: dict[str, list[MorphFrame]] = {}
    property_frames: list[PropertyFrame] = []
    camera_frames: list[CameraFrame] = []
    max_frame = 0

    with path.open("rb") as handle:
        signature = read_exact(handle, 30)
        # VMD v2 ("...0002") stores a 20-byte model name; the legacy v1
        # ("...file") stores only 10 bytes. Reading 20 for a v1 file would
        # desync every subsequent field, so pick the width from the signature.
        if signature.startswith(b"Vocaloid Motion Data 0002"):
            model_name = decode_cp932(read_exact(handle, 20))
        elif signature.startswith(b"Vocaloid Motion Data file"):
            model_name = decode_cp932(read_exact(handle, 10))
        elif signature.startswith(b"Vocaloid Motion Data"):
            # Unknown minor version: assume the modern 20-byte layout.
            model_name = decode_cp932(read_exact(handle, 20))
        else:
            raise ValueError(f"{path} is not a VMD file")

        for _ in range(read_u32(handle)):
            name = decode_cp932(read_exact(handle, 15))
            frame = read_u32(handle)
            location = struct.unpack("<fff", read_exact(handle, 12))
            rotation = struct.unpack("<ffff", read_exact(handle, 16))
            if not any(rotation):
                rotation = (0.0, 0.0, 0.0, 1.0)
            interp = read_exact(handle, 64)
            bone_frames.setdefault(name, []).append(BoneFrame(frame, location, rotation, interp))
            max_frame = max(max_frame, frame)

        for _ in range(read_count_or_zero(handle)):
            name = decode_cp932(read_exact(handle, 15))
            frame = read_u32(handle)
            weight = struct.unpack("<f", read_exact(handle, 4))[0]
            morph_frames.setdefault(name, []).append(MorphFrame(frame, weight))
            max_frame = max(max_frame, frame)

        # Camera records: frame u32, distance f32, target position 3xf32,
        # rotation 3xf32 (radians), 24 interpolation bytes, fov u32 (degrees),
        # perspective-off flag u8 (stored for completeness; orthographic
        # segments are rare and rendered as perspective downstream).
        # Camera frames deliberately do NOT extend max_frame: max_frame drives
        # the body bake/preview length, and a dance VMD with embedded camera
        # keys past the last bone key must keep its historical imported length.
        for _ in range(read_count_or_zero(handle)):
            frame = read_u32(handle)
            distance = struct.unpack("<f", read_exact(handle, 4))[0]
            position = struct.unpack("<fff", read_exact(handle, 12))
            rotation = struct.unpack("<fff", read_exact(handle, 12))
            interp = read_exact(handle, 24)
            fov = float(read_u32(handle))
            perspective_off = struct.unpack("<B", read_exact(handle, 1))[0]
            camera_frames.append(CameraFrame(frame, distance, position, rotation, interp, fov, perspective_off == 0))

        # Light and self-shadow records are parsed only far enough to reach property frames.
        for _ in range(read_count_or_zero(handle)):
            read_exact(handle, 28)
        for _ in range(read_count_or_zero(handle)):
            read_exact(handle, 9)

        for _ in range(read_count_or_zero(handle)):
            frame = read_u32(handle)
            visible = struct.unpack("<b", read_exact(handle, 1))[0] != 0
            count = read_u32(handle)
            states: list[tuple[str, bool]] = []
            for _ in range(count):
                name = decode_cp932(read_exact(handle, 20))
                state = struct.unpack("<b", read_exact(handle, 1))[0] != 0
                states.append((name, state))
            property_frames.append(PropertyFrame(frame, visible, states))
            max_frame = max(max_frame, frame)

    for frames in bone_frames.values():
        frames.sort(key=lambda item: item.frame)
    for frames in morph_frames.values():
        frames.sort(key=lambda item: item.frame)
    property_frames.sort(key=lambda item: item.frame)
    camera_frames.sort(key=lambda item: item.frame)

    return ParsedVMD(model_name, bone_frames, morph_frames, property_frames, max_frame, camera_frames)


def extract_literal_dict(path: Path, variable: str) -> dict:
    module = ast.parse(path.read_text(encoding="utf-8"))
    for node in module.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == variable:
                    return ast.literal_eval(node.value)
    raise KeyError(f"{variable} not found in {path}")


def load_bone_mapping() -> dict[str, tuple[str, str]]:
    valve_to_mmd = extract_literal_dict(BONE_SCRIPT, "JP_MAP_BASE")
    mapping = {mmd: (valve, "") for valve, mmd in valve_to_mmd.items()}
    mapping.update(EXTRA_BONE_ALIASES)
    mapping.update(BLENDER_FINGER_BONE_ALIASES)
    mapping.update(EXTRA_BONE_ROLES)
    mapping.update(BLENDER_BONE_ROLES)
    return mapping


def load_flex_mapping() -> dict[str, str]:
    mapping = extract_literal_dict(FLEX_SCRIPT, "special_replacement_dict_jp")
    # Motions sometimes already use the renamed Source flex names.
    for value in list(mapping.values()):
        mapping.setdefault(value, value)
    return mapping


class PMXReader:
    def __init__(self, data: bytes):
        self.data = data
        self.offset = 0
        self.encoding = "utf-16le"
        self.extra_uv = 0
        self.vertex_index_size = 4
        self.texture_index_size = 4
        self.material_index_size = 4
        self.bone_index_size = 4
        self.morph_index_size = 4
        self.rigidbody_index_size = 4

    def read(self, size: int) -> bytes:
        out = self.data[self.offset : self.offset + size]
        if len(out) != size:
            raise EOFError("unexpected end of PMX")
        self.offset += size
        return out

    def unpack(self, fmt: str):
        values = struct.unpack_from(fmt, self.data, self.offset)
        self.offset += struct.calcsize(fmt)
        return values if len(values) > 1 else values[0]

    def read_text(self) -> str:
        size = self.unpack("<i")
        if size <= 0:
            return ""
        return self.read(size).decode(self.encoding, errors="replace")

    def read_index(self, size: int) -> int:
        if size == 1:
            return self.unpack("<b")
        if size == 2:
            return self.unpack("<h")
        if size == 4:
            return self.unpack("<i")
        raise ValueError(f"unsupported PMX index size {size}")

    def parse_header(self) -> None:
        if self.read(4) != b"PMX ":
            raise ValueError("not a PMX file")
        version = self.unpack("<f")
        if version < 2.0:
            raise ValueError(f"unsupported PMX version {version}")
        header_size = self.unpack("<B")
        header = self.read(header_size)
        if len(header) < 8:
            raise ValueError("invalid PMX header")
        self.encoding = "utf-8" if header[0] == 1 else "utf-16le"
        self.extra_uv = header[1]
        self.vertex_index_size = header[2]
        self.texture_index_size = header[3]
        self.material_index_size = header[4]
        self.bone_index_size = header[5]
        self.morph_index_size = header[6]
        self.rigidbody_index_size = header[7]

    def skip_vertices(self) -> None:
        for _ in range(self.unpack("<i")):
            self.offset += 12 + 12 + 8 + self.extra_uv * 16
            weight_type = self.unpack("<B")
            if weight_type == 0:
                self.read_index(self.bone_index_size)
            elif weight_type == 1:
                self.read_index(self.bone_index_size)
                self.read_index(self.bone_index_size)
                self.offset += 4
            elif weight_type in (2, 4):
                for _ in range(4):
                    self.read_index(self.bone_index_size)
                self.offset += 16
            elif weight_type == 3:
                self.read_index(self.bone_index_size)
                self.read_index(self.bone_index_size)
                self.offset += 4 + 36
            else:
                raise ValueError(f"unsupported PMX weight type {weight_type}")
            self.offset += 4

    def skip_faces(self) -> None:
        face_index_count = self.unpack("<i")
        self.offset += face_index_count * self.vertex_index_size

    def skip_textures(self) -> None:
        for _ in range(self.unpack("<i")):
            self.read_text()

    def skip_materials(self) -> None:
        for _ in range(self.unpack("<i")):
            self.read_text()
            self.read_text()
            self.offset += 4 * 4 + 3 * 4 + 4 + 3 * 4 + 1 + 4 * 4 + 4
            self.read_index(self.texture_index_size)
            self.read_index(self.texture_index_size)
            self.offset += 1
            if self.unpack("<B") == 0:
                self.read_index(self.texture_index_size)
            else:
                self.offset += 1
            self.read_text()
            self.offset += 4

    def read_bones(self) -> list[PMXBone]:
        bones: list[PMXBone] = []
        for index in range(self.unpack("<i")):
            name = self.read_text()
            english_name = self.read_text()
            position = self.unpack("<fff")
            parent = self.read_index(self.bone_index_size)
            transform_level = self.unpack("<i")
            flags = self.unpack("<H")
            tail_index = None
            tail_offset = None
            if flags & 0x0001:
                tail_index = self.read_index(self.bone_index_size)
            else:
                tail_offset = self.unpack("<fff")
            append_parent = -1
            append_ratio = 0.0
            if flags & (0x0100 | 0x0200):
                append_parent = self.read_index(self.bone_index_size)
                append_ratio = float(self.unpack("<f"))
            local_axis_x = None
            local_axis_z = None
            fixed_axis = None
            if flags & 0x0400:
                fixed_axis = self.unpack("<fff")
            if flags & 0x0800:
                local_axis_x = self.unpack("<fff")
                local_axis_z = self.unpack("<fff")
            if flags & 0x2000:
                self.offset += 4
            ik_target = -1
            ik_loop_count = 0
            ik_limit_angle = 0.0
            ik_links: list[PMXIKLink] = []
            if flags & 0x0020:
                ik_target = self.read_index(self.bone_index_size)
                ik_loop_count = self.unpack("<i")
                ik_limit_angle = float(self.unpack("<f"))
                for _ in range(self.unpack("<i")):
                    link_bone = self.read_index(self.bone_index_size)
                    limit_min = limit_max = None
                    if self.unpack("<B"):
                        limit_min = self.unpack("<fff")
                        limit_max = self.unpack("<fff")
                    ik_links.append(PMXIKLink(link_bone, limit_min, limit_max))
            bones.append(
                PMXBone(
                    index,
                    name,
                    english_name,
                    position,
                    parent,
                    flags,
                    tail_index,
                    tail_offset,
                    local_axis_x,
                    local_axis_z,
                    transform_level=transform_level,
                    append_parent=append_parent,
                    append_ratio=append_ratio,
                    fixed_axis=fixed_axis,
                    ik_target=ik_target,
                    ik_loop_count=ik_loop_count,
                    ik_limit_angle=ik_limit_angle,
                    ik_links=ik_links,
                )
            )
        return bones


def parse_pmx_bones(path: Path) -> list[PMXBone]:
    reader = PMXReader(path.read_bytes())
    reader.parse_header()
    for _ in range(4):
        reader.read_text()
    reader.skip_vertices()
    reader.skip_faces()
    reader.skip_textures()
    reader.skip_materials()
    return reader.read_bones()


def bezier_point(t: float, p0: float, p1: float, p2: float, p3: float) -> float:
    inv = 1.0 - t
    return inv * inv * inv * p0 + 3 * inv * inv * t * p1 + 3 * inv * t * t * p2 + t * t * t * p3


def bezier_weight(x: float, interp: bytes, axis: int) -> float:
    # VMD stores the four control-point bytes of each axis strided by 4, not
    # contiguously: for axis a (0=X, 1=Y, 2=Z, 3=rotation) the parameters are
    # x1=interp[a], y1=interp[a+4], x2=interp[a+8], y2=interp[a+12]. Reading four
    # contiguous bytes instead mixes other axes' curves into this one.
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0

    x1 = interp[axis] / 127.0
    y1 = interp[axis + 4] / 127.0
    x2 = interp[axis + 8] / 127.0
    y2 = interp[axis + 12] / 127.0

    if abs(x1 - y1) < 1e-6 and abs(x2 - y2) < 1e-6:
        return x

    lo, hi = 0.0, 1.0
    for _ in range(20):
        mid = (lo + hi) * 0.5
        bx = bezier_point(mid, 0.0, x1, x2, 1.0)
        if bx < x:
            lo = mid
        else:
            hi = mid
    return bezier_point((lo + hi) * 0.5, 0.0, y1, y2, 1.0)


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def normalize_quat(q: tuple[float, float, float, float]) -> tuple[float, float, float, float]:
    x, y, z, w = q
    length = math.sqrt(x * x + y * y + z * z + w * w)
    if length <= 1e-8:
        return (0.0, 0.0, 0.0, 1.0)
    return (x / length, y / length, z / length, w / length)


def slerp_quat(a: tuple[float, float, float, float], b: tuple[float, float, float, float], t: float) -> tuple[float, float, float, float]:
    ax, ay, az, aw = normalize_quat(a)
    bx, by, bz, bw = normalize_quat(b)
    dot = ax * bx + ay * by + az * bz + aw * bw
    if dot < 0:
        bx, by, bz, bw = -bx, -by, -bz, -bw
        dot = -dot
    if dot > 0.9995:
        return normalize_quat((lerp(ax, bx, t), lerp(ay, by, t), lerp(az, bz, t), lerp(aw, bw, t)))

    theta_0 = math.acos(max(-1.0, min(1.0, dot)))
    sin_theta_0 = math.sin(theta_0)
    theta = theta_0 * t
    sin_theta = math.sin(theta)
    s0 = math.cos(theta) - dot * sin_theta / sin_theta_0
    s1 = sin_theta / sin_theta_0
    return (ax * s0 + bx * s1, ay * s0 + by * s1, az * s0 + bz * s1, aw * s0 + bw * s1)


def quat_to_matrix(q: tuple[float, float, float, float]) -> list[list[float]]:
    x, y, z, w = normalize_quat(q)
    xx, yy, zz = x * x, y * y, z * z
    xy, xz, yz = x * y, x * z, y * z
    wx, wy, wz = w * x, w * y, w * z
    return [
        [1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy)],
        [2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx)],
        [2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy)],
    ]


def mat_mul(a: list[list[float]], b: list[list[float]]) -> list[list[float]]:
    return [[sum(a[r][k] * b[k][c] for k in range(3)) for c in range(3)] for r in range(3)]


def mat_transpose(a: list[list[float]]) -> list[list[float]]:
    return [[a[c][r] for c in range(3)] for r in range(3)]


def mat_vec_mul(a: list[list[float]], v: tuple[float, float, float]) -> tuple[float, float, float]:
    return (
        a[0][0] * v[0] + a[0][1] * v[1] + a[0][2] * v[2],
        a[1][0] * v[0] + a[1][1] * v[1] + a[1][2] * v[2],
        a[2][0] * v[0] + a[2][1] * v[1] + a[2][2] * v[2],
    )


def mat_identity() -> list[list[float]]:
    return [
        [1.0, 0.0, 0.0],
        [0.0, 1.0, 0.0],
        [0.0, 0.0, 1.0],
    ]


def vec_dot(a: tuple[float, float, float], b: tuple[float, float, float]) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def vec_cross(a: tuple[float, float, float], b: tuple[float, float, float]) -> tuple[float, float, float]:
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def vec_sub(a: tuple[float, float, float], b: tuple[float, float, float]) -> tuple[float, float, float]:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def vec_len(v: tuple[float, float, float]) -> float:
    return math.sqrt(vec_dot(v, v))


def vec_normalize(v: tuple[float, float, float], fallback: tuple[float, float, float] = (1.0, 0.0, 0.0)) -> tuple[float, float, float]:
    length = vec_len(v)
    if length <= 1e-8:
        return fallback
    return (v[0] / length, v[1] / length, v[2] / length)


def basis_from_axes(x_axis: tuple[float, float, float], z_hint: tuple[float, float, float]) -> list[list[float]]:
    x_axis = vec_normalize(x_axis)
    z_hint = vec_normalize(z_hint, (0.0, 0.0, 1.0))
    if abs(vec_dot(x_axis, z_hint)) > 0.98:
        z_hint = (0.0, 1.0, 0.0) if abs(x_axis[1]) < 0.98 else (0.0, 0.0, 1.0)
    y_axis = vec_normalize(vec_cross(z_hint, x_axis), (0.0, 1.0, 0.0))
    z_axis = vec_normalize(vec_cross(x_axis, y_axis), (0.0, 0.0, 1.0))
    return [
        [x_axis[0], y_axis[0], z_axis[0]],
        [x_axis[1], y_axis[1], z_axis[1]],
        [x_axis[2], y_axis[2], z_axis[2]],
    ]


def source_angle_to_matrix(angle: tuple[float, float, float]) -> list[list[float]]:
    pitch, yaw, roll = (math.radians(value) for value in angle)
    sp, cp = math.sin(pitch), math.cos(pitch)
    sy, cy = math.sin(yaw), math.cos(yaw)
    sr, cr = math.sin(roll), math.cos(roll)
    return [
        [cp * cy, sr * sp * cy - cr * sy, cr * sp * cy + sr * sy],
        [cp * sy, sr * sp * sy + cr * cy, cr * sp * sy - sr * cy],
        [-sp, sr * cp, cr * cp],
    ]


def source_angle_from_matrix(m: list[list[float]]) -> tuple[float, float, float]:
    pitch = math.degrees(math.atan2(-m[2][0], math.sqrt(m[0][0] * m[0][0] + m[1][0] * m[1][0])))
    yaw = math.degrees(math.atan2(m[1][0], m[0][0]))
    roll = math.degrees(math.atan2(m[2][1], m[2][2]))
    return (pitch, yaw, roll)


def matrix_to_quat(m: list[list[float]]) -> tuple[float, float, float, float]:
    trace = m[0][0] + m[1][1] + m[2][2]
    if trace > 0.0:
        scale = math.sqrt(trace + 1.0) * 2.0
        return normalize_quat(
            (
                (m[2][1] - m[1][2]) / scale,
                (m[0][2] - m[2][0]) / scale,
                (m[1][0] - m[0][1]) / scale,
                0.25 * scale,
            )
        )

    if m[0][0] > m[1][1] and m[0][0] > m[2][2]:
        scale = math.sqrt(max(0.0, 1.0 + m[0][0] - m[1][1] - m[2][2])) * 2.0
        if scale <= 1e-8:
            return (0.0, 0.0, 0.0, 1.0)
        return normalize_quat(
            (
                0.25 * scale,
                (m[0][1] + m[1][0]) / scale,
                (m[0][2] + m[2][0]) / scale,
                (m[2][1] - m[1][2]) / scale,
            )
        )

    if m[1][1] > m[2][2]:
        scale = math.sqrt(max(0.0, 1.0 + m[1][1] - m[0][0] - m[2][2])) * 2.0
        if scale <= 1e-8:
            return (0.0, 0.0, 0.0, 1.0)
        return normalize_quat(
            (
                (m[0][1] + m[1][0]) / scale,
                0.25 * scale,
                (m[1][2] + m[2][1]) / scale,
                (m[0][2] - m[2][0]) / scale,
            )
        )

    scale = math.sqrt(max(0.0, 1.0 + m[2][2] - m[0][0] - m[1][1])) * 2.0
    if scale <= 1e-8:
        return (0.0, 0.0, 0.0, 1.0)
    return normalize_quat(
        (
            (m[0][2] + m[2][0]) / scale,
            (m[1][2] + m[2][1]) / scale,
            0.25 * scale,
            (m[1][0] - m[0][1]) / scale,
        )
    )


def quat_mul(
    a: tuple[float, float, float, float],
    b: tuple[float, float, float, float],
) -> tuple[float, float, float, float]:
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return normalize_quat(
        (
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz,
        )
    )


def quat_inv(q: tuple[float, float, float, float]) -> tuple[float, float, float, float]:
    x, y, z, w = normalize_quat(q)
    return (-x, -y, -z, w)


def rotation_vector_from_source_matrix(source_matrix: list[list[float]]) -> tuple[float, float, float]:
    x, y, z, w = matrix_to_quat(source_matrix)
    axis_length = math.sqrt(x * x + y * y + z * z)
    if axis_length <= 1e-8:
        return (0.0, 0.0, 0.0)

    # Cache a quaternion rotation vector instead of an Euler decomposition.
    # GMod still receives an Angle later, but this avoids pitch/yaw/roll branch
    # flips caused by decomposing rotations near 90/180 degrees.
    angle = 2.0 * math.atan2(axis_length, w)
    scale = math.degrees(angle) / axis_length
    return (-x * scale, z * scale, -y * scale)


MMD_TO_SOURCE_BASIS = [
    [0.0, 0.0, 1.0],
    [1.0, 0.0, 0.0],
    [0.0, 1.0, 0.0],
]
SOURCE_TO_MMD_BASIS = mat_transpose(MMD_TO_SOURCE_BASIS)


def convert_direction(direction: tuple[float, float, float]) -> tuple[float, float, float]:
    x, y, z = direction
    return (z, x, y)


def convert_position(location: tuple[float, float, float]) -> tuple[float, float, float]:
    x, y, z = location
    return (z * SOURCE_SCALE, x * SOURCE_SCALE, y * SOURCE_SCALE)


def parse_smd_reference(path: Path) -> dict[str, SMDBone]:
    text = path.read_text(encoding="utf-8", errors="replace").splitlines()
    parents: dict[int, tuple[str, int]] = {}
    bones: dict[str, SMDBone] = {}
    in_nodes = False
    in_time0 = False

    node_re = re.compile(r'^\s*(\d+)\s+"([^"]+)"\s+(-?\d+)')
    pose_re = re.compile(
        r"^\s*(\d+)\s+"
        r"([-+0-9.eE]+)\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)\s+"
        r"([-+0-9.eE]+)\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)"
    )

    for line in text:
        stripped = line.strip()
        if stripped == "nodes":
            in_nodes = True
            continue
        if stripped == "skeleton":
            in_nodes = False
            continue
        if in_nodes:
            if stripped == "end":
                in_nodes = False
                continue
            match = node_re.match(line)
            if match:
                parents[int(match.group(1))] = (match.group(2), int(match.group(3)))
            continue

        if stripped == "time 0":
            in_time0 = True
            continue
        if in_time0 and stripped.startswith("time "):
            break
        if not in_time0:
            continue

        match = pose_re.match(line)
        if not match:
            continue
        index = int(match.group(1))
        name, parent = parents.get(index, ("", -1))
        if not name:
            continue
        pos = (float(match.group(2)), float(match.group(3)), float(match.group(4)))
        rx, ry, rz = float(match.group(5)), float(match.group(6)), float(match.group(7))
        local_ang = (math.degrees(ry), math.degrees(rz), math.degrees(rx))
        local_basis = source_angle_to_matrix(local_ang)
        parent_name = parents.get(parent, ("", -1))[0]
        parent_basis = bones[parent_name].world_basis if parent_name in bones else mat_identity()
        bones[name] = SMDBone(index, name, parent, pos, local_ang, local_basis, mat_mul(parent_basis, local_basis))

    return bones


def mmd_bone_tail_vector(bone: PMXBone, bones: list[PMXBone], children: dict[int, list[int]]) -> tuple[float, float, float]:
    if bone.tail_index is not None and 0 <= bone.tail_index < len(bones):
        return vec_sub(bones[bone.tail_index].position, bone.position)
    if bone.tail_offset is not None and vec_len(bone.tail_offset) > 1e-8:
        return bone.tail_offset
    for child_index in children.get(bone.index, []):
        child = bones[child_index]
        delta = vec_sub(child.position, bone.position)
        if vec_len(delta) > 1e-8:
            return delta
    return (1.0, 0.0, 0.0)


def build_pmx_source_bases(bones: list[PMXBone]) -> dict[str, list[list[float]]]:
    children: dict[int, list[int]] = {}
    for bone in bones:
        if bone.parent >= 0:
            children.setdefault(bone.parent, []).append(bone.index)

    bases: dict[str, list[list[float]]] = {}
    for bone in bones:
        if bone.local_axis_x is not None and bone.local_axis_z is not None:
            x_axis = convert_direction(bone.local_axis_x)
            z_axis = convert_direction(bone.local_axis_z)
        else:
            x_axis = convert_direction(mmd_bone_tail_vector(bone, bones, children))
            z_axis = (0.0, 0.0, 1.0)
        bases[bone.name] = basis_from_axes(x_axis, z_axis)
    return bases


def mmd_tools_converter_from_source_basis(source_basis: list[list[float]]) -> list[list[float]]:
    """Build the same bone-space VMD converter shape used by MMD Tools.

    Body.smd is the supplied PMX model after conversion to Source format. Its
    model-space rest basis is therefore a better canonical armature basis than
    reconstructing a PMX roll from only a bone tail vector. MMD Tools converts a
    VMD quaternion through the pose bone's matrix_local, swaps the Y/Z rows for
    MMD axis conventions, then transposes the matrix before quaternion
    conjugation. Reusing that convention keeps the baked VMD bend axes aligned
    with Source's reference skeleton instead of turning leg bends into pitch
    twists.
    """

    mat = [row[:] for row in source_basis]
    mat[1], mat[2] = mat[2], mat[1]
    return mat_transpose(mat)


def build_retarget_table(
    bone_map: dict[str, tuple[str, str]],
    pmx_path: Path | None = None,
    smd_path: Path | None = None,
) -> tuple[dict[str, BoneRetarget], list[str]]:
    diagnostics: list[str] = []
    pmx_path = pmx_path or find_default_mmd_model()
    smd_path = smd_path or DEFAULT_SOURCE_SMD

    if not pmx_path.exists():
        return {}, [f"PMX model not found: {pmx_path}"]
    if not smd_path.exists():
        return {}, [f"Source SMD not found: {smd_path}"]

    pmx_bones = parse_pmx_bones(pmx_path)
    pmx_by_name = {bone.name: bone for bone in pmx_bones}
    smd_bones = parse_smd_reference(smd_path)

    table: dict[str, BoneRetarget] = {}
    for mmd_name, (source_name, role) in bone_map.items():
        if role or not source_name:
            continue
        if mmd_name not in pmx_by_name:
            if mmd_name in EXTRA_BONE_ALIASES or mmd_name in BLENDER_FINGER_BONE_ALIASES or mmd_name in BLENDER_BONE_ROLES:
                continue
            diagnostics.append(f'unmapped PMX bone for VMD name "{mmd_name}"')
            continue
        source_bone = smd_bones.get(source_name)
        if source_bone is None:
            diagnostics.append(f'unmapped Source rest bone "{source_name}" for MMD "{mmd_name}"')
            continue
        source_basis = source_bone.world_basis
        matrix = mmd_tools_converter_from_source_basis(source_basis)
        table[mmd_name] = BoneRetarget(source_name, mmd_name, matrix, mat_transpose(matrix), source_basis)

    return table, diagnostics


def convert_rotation_with_retarget(
    rotation: tuple[float, float, float, float],
    retarget: BoneRetarget,
) -> tuple[float, float, float]:
    q_basis = matrix_to_quat(retarget.matrix)
    q_src = quat_mul(quat_mul(q_basis, normalize_quat(rotation)), quat_inv(q_basis))
    return rotation_vector_from_source_matrix(quat_to_matrix(q_src))


def convert_rotation(rotation: tuple[float, float, float, float]) -> tuple[float, float, float]:
    mmd_matrix = quat_to_matrix(rotation)
    source_matrix = mat_mul(mat_mul(MMD_TO_SOURCE_BASIS, mmd_matrix), SOURCE_TO_MMD_BASIS)
    return rotation_vector_from_source_matrix(source_matrix)


def source_bone_uses_pelvis_orientation(source_name: str, role: str) -> bool:
    return source_name == "ValveBiped.Bip01_Pelvis" or role in {"root", "center", "groove", "waist"}


def apply_source_bone_orientation(
    angle: tuple[float, float, float],
    source_name: str = "",
    role: str = "",
) -> tuple[float, float, float]:
    if not source_name or source_bone_uses_pelvis_orientation(source_name, role):
        return angle

    pitch, yaw, roll = angle
    # ValveBiped child bones use a different ManipulateBoneAngles basis than the
    # pelvis/root transform. In game the imported Roll axis is the child's Yaw.
    return (pitch, roll, yaw)


def convert_rotation_for_source_bone(
    rotation: tuple[float, float, float, float],
    source_name: str = "",
    role: str = "",
    retarget: BoneRetarget | None = None,
) -> tuple[float, float, float]:
    if retarget is not None:
        return convert_rotation_with_retarget(rotation, retarget)
    return apply_source_bone_orientation(convert_rotation(rotation), source_name, role)


def unwrap_angle_axis(value: float, reference: float) -> float:
    return value + 360.0 * round((reference - value) / 360.0)


def collapse_near_half_turn(value: float) -> float:
    if value >= 0.0:
        return 180.0 - value
    return -180.0 - value


def equivalent_source_angle_bases(angle: tuple[float, float, float]) -> list[tuple[float, float, float]]:
    p, y, r = angle
    # Source QAngle uses the same matrix for (p, y, r) and
    # (180 - p, y + 180, r + 180). Include shifted variants so later
    # per-axis unwrapping can choose the closest branch to the previous sample.
    return [
        (p, y, r),
        (180.0 - p, y + 180.0, r + 180.0),
        (180.0 - p, y - 180.0, r - 180.0),
        (-180.0 - p, y + 180.0, r + 180.0),
        (-180.0 - p, y - 180.0, r - 180.0),
    ]


def gimbal_continuation_candidates(
    angle: tuple[float, float, float],
    reference: tuple[float, float, float],
) -> list[tuple[float, float, float]]:
    candidates: list[tuple[float, float, float]] = []
    values = list(angle)

    for axis in range(3):
        ref = reference[axis]
        value = values[axis]
        if abs(ref) < 75.0 or abs(value) < 75.0 or ref * value <= 0.0:
            continue

        other_axes = [index for index in range(3) if index != axis]
        if not all(abs(values[index]) >= 120.0 for index in other_axes):
            continue

        continued = values[:]
        continued[axis] = math.copysign(180.0 - abs(value), ref)
        for index in other_axes:
            continued[index] = collapse_near_half_turn(values[index])
        candidates.append((continued[0], continued[1], continued[2]))

    return candidates


def nearest_equivalent_source_angle(
    angle: tuple[float, float, float],
    reference: tuple[float, float, float],
) -> tuple[float, float, float]:
    best: tuple[float, float, float] | None = None
    best_score: float | None = None

    for base in equivalent_source_angle_bases(angle) + gimbal_continuation_candidates(angle, reference):
        candidate = (
            unwrap_angle_axis(base[0], reference[0]),
            unwrap_angle_axis(base[1], reference[1]),
            unwrap_angle_axis(base[2], reference[2]),
        )
        score = (
            (candidate[0] - reference[0]) ** 2
            + (candidate[1] - reference[1]) ** 2
            + (candidate[2] - reference[2]) ** 2
        )
        if best_score is None or score < best_score:
            best = candidate
            best_score = score

    return best or angle


def nearest_rotation_vector(
    angle: tuple[float, float, float],
    reference: tuple[float, float, float],
) -> tuple[float, float, float]:
    return (
        unwrap_angle_axis(angle[0], reference[0]),
        unwrap_angle_axis(angle[1], reference[1]),
        unwrap_angle_axis(angle[2], reference[2]),
    )


def stabilize_bone_samples(
    samples: list[tuple[tuple[float, float, float], tuple[float, float, float]]]
) -> list[tuple[tuple[float, float, float], tuple[float, float, float]]]:
    stable = []
    previous_angle: tuple[float, float, float] | None = None
    for pos, ang in samples:
        if previous_angle is not None:
            ang = nearest_rotation_vector(ang, previous_angle)
        stable.append((pos, ang))
        previous_angle = ang
    return stable


def find_segment(frames: list, frame: float):
    if not frames:
        return None, None, 0.0
    if frame <= frames[0].frame:
        return frames[0], frames[0], 0.0
    if frame >= frames[-1].frame:
        return frames[-1], frames[-1], 0.0

    lo, hi = 0, len(frames) - 1
    while lo + 1 < hi:
        mid = (lo + hi) // 2
        if frames[mid].frame <= frame:
            lo = mid
        else:
            hi = mid

    a = frames[lo]
    b = frames[hi]
    span = max(1, b.frame - a.frame)
    return a, b, (frame - a.frame) / span


def sample_bone(
    frames: list[BoneFrame],
    frame: float,
    source_name: str = "",
    role: str = "",
    retarget: BoneRetarget | None = None,
) -> tuple[tuple[float, float, float], tuple[float, float, float]]:
    a, b, t = find_segment(frames, frame)
    if a is None:
        return (0.0, 0.0, 0.0), (0.0, 0.0, 0.0)
    if a is b:
        return convert_position(a.location), convert_rotation_for_source_bone(a.rotation, source_name, role, retarget)

    tx = bezier_weight(t, b.interp, 0)
    ty = bezier_weight(t, b.interp, 1)
    tz = bezier_weight(t, b.interp, 2)
    tr = bezier_weight(t, b.interp, 3)
    loc = (
        lerp(a.location[0], b.location[0], tx),
        lerp(a.location[1], b.location[1], ty),
        lerp(a.location[2], b.location[2], tz),
    )
    rot = slerp_quat(a.rotation, b.rotation, tr)
    return convert_position(loc), convert_rotation_for_source_bone(rot, source_name, role, retarget)


def sample_morph(frames: list[MorphFrame], frame: float) -> float:
    a, b, t = find_segment(frames, frame)
    if a is None:
        return 0.0
    if a is b:
        return a.weight
    return lerp(a.weight, b.weight, t)


def sample_ik(property_frames: list[PropertyFrame], max_frame: int, sample_fps: int = VMD_FPS) -> dict[str, list[bool]]:
    all_names = sorted({name for frame in property_frames for name, _ in frame.ik_states})
    sample_count = int(math.floor(max_frame * sample_fps / VMD_FPS)) + 1
    states = {name: [True] * sample_count for name in all_names}
    current = {name: True for name in all_names}
    sorted_props = sorted(property_frames, key=lambda item: item.frame)
    prop_index = 0

    for sample_index in range(sample_count):
        vmd_frame = sample_index * VMD_FPS / sample_fps
        while prop_index < len(sorted_props) and sorted_props[prop_index].frame <= vmd_frame:
            for name, state in sorted_props[prop_index].ik_states:
                current[name] = state
            prop_index += 1
        for name in all_names:
            states[name][sample_index] = current.get(name, True)
    return states


def pack_string(value: str) -> bytes:
    data = (value or "").encode("utf-8")
    if len(data) > 65535:
        data = data[:65535]
    return struct.pack("<H", len(data)) + data


def pack_vec(values: tuple[float, float, float]) -> bytes:
    return struct.pack("<fff", *values)


def pack_mat3(matrix: list[list[float]]) -> bytes:
    return b"".join(pack_vec((row[0], row[1], row[2])) for row in matrix)


def format_matrix(matrix: list[list[float]]) -> str:
    return "[" + "; ".join(", ".join(f"{value:.6f}" for value in row) for row in matrix) + "]"


def debug_target(source_name: str, role: str) -> str:
    if source_name:
        return source_name
    if role in {"root", "center", "groove", "waist"}:
        return "ValveBiped.Bip01_Pelvis"
    if role == "left_foot_ik":
        return "left leg IK/property record"
    if role == "right_foot_ik":
        return "right leg IK/property record"
    return ""


def build_debug_rows(
    vmd: ParsedVMD,
    bone_map: dict[str, tuple[str, str]],
    flex_map: dict[str, str],
    retarget_table: dict[str, BoneRetarget] | None = None,
) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    retarget_table = retarget_table or {}

    for mmd_name, frames in vmd.bone_frames.items():
        source_name, role = bone_map.get(mmd_name, ("", ""))
        if not source_name and not role:
            continue
        target = debug_target(source_name, role)
        retarget = retarget_table.get(mmd_name)
        previous_angle: tuple[float, float, float] | None = None
        for frame in frames:
            angle = convert_rotation_for_source_bone(frame.rotation, source_name, role, retarget)
            if previous_angle is not None:
                angle = nearest_rotation_vector(angle, previous_angle)
            previous_angle = angle
            rows.append(
                {
                    "frame": frame.frame,
                    "kind": 1,
                    "mmd": mmd_name,
                    "source": target,
                    "role": role,
                    "pos": convert_position(frame.location),
                    "ang": angle,
                    "weight": 0.0,
                    "state": True,
                }
            )

    for mmd_name, frames in vmd.morph_frames.items():
        source_name = flex_map.get(mmd_name, "")
        if not source_name:
            continue
        for frame in frames:
            rows.append(
                {
                    "frame": frame.frame,
                    "kind": 2,
                    "mmd": mmd_name,
                    "source": source_name,
                    "role": "flex",
                    "pos": (0.0, 0.0, 0.0),
                    "ang": (0.0, 0.0, 0.0),
                    "weight": max(0.0, min(1.0, frame.weight)),
                    "state": True,
                }
            )

    for prop in vmd.property_frames:
        for name, state in prop.ik_states:
            _, role = bone_map.get(name, ("", ""))
            rows.append(
                {
                    "frame": prop.frame,
                    "kind": 3,
                    "mmd": name,
                    "source": debug_target("", role),
                    "role": "ik",
                    "pos": (0.0, 0.0, 0.0),
                    "ang": (0.0, 0.0, 0.0),
                    "weight": 0.0,
                    "state": state,
                }
            )

    rows.sort(key=lambda item: (int(item["frame"]), int(item["kind"]), str(item["mmd"])))
    return rows


def pack_debug_rows(rows: list[dict[str, object]]) -> bytes:
    out = bytearray()
    out += DEBUG_MAGIC
    out += struct.pack("<L", len(rows))
    for row in rows:
        out += struct.pack("<LB", int(row["frame"]), int(row["kind"]))
        out += pack_string(str(row["mmd"]))
        out += pack_string(str(row["source"]))
        out += pack_string(str(row["role"]))
        out += pack_vec(row["pos"])  # type: ignore[arg-type]
        out += pack_vec(row["ang"])  # type: ignore[arg-type]
        out += struct.pack("<fB", float(row["weight"]), 1 if row["state"] else 0)
    return bytes(out)


def source_basis_for_track(
    source_name: str,
    role: str,
    retarget: BoneRetarget | None,
    smd_bones: dict[str, SMDBone],
) -> list[list[float]]:
    if retarget is not None:
        return retarget.source_basis

    target = source_name
    if not target and role in {"root", "center", "groove", "waist"}:
        target = "ValveBiped.Bip01_Pelvis"

    source_bone = smd_bones.get(target)
    if source_bone is not None:
        return source_bone.world_basis

    return mat_identity()


def build_cache(vmd: ParsedVMD, source_path: Path, source_hash: str, debug_retarget: bool = False) -> bytes:
    bone_map = load_bone_mapping()
    flex_map = load_flex_mapping()
    retarget_table, diagnostics = build_retarget_table(bone_map)
    try:
        smd_bones = parse_smd_reference(DEFAULT_SOURCE_SMD)
    except Exception:
        smd_bones = {}
    if debug_retarget:
        print(f"Retarget basis converters: {len(retarget_table)}")
        for mmd_name, retarget in sorted(retarget_table.items(), key=lambda item: (item[1].source_name, item[0])):
            print(
                f'Retarget bone: "{mmd_name}" -> "{retarget.source_name}" '
                f"K={format_matrix(retarget.matrix)} source_basis={format_matrix(retarget.source_basis)}"
            )
        for warning in diagnostics[:200]:
            print("Retarget warning:", warning)
    frame_count = int(math.floor(vmd.max_frame * SAMPLE_FPS / VMD_FPS)) + 1
    sample_times = [frame * VMD_FPS / SAMPLE_FPS for frame in range(frame_count)]

    bone_tracks = []
    for mmd_name, frames in sorted(vmd.bone_frames.items()):
        source_name, role = bone_map.get(mmd_name, ("", ""))
        if not source_name and not role:
            continue
        retarget = retarget_table.get(mmd_name)
        samples = stabilize_bone_samples([sample_bone(frames, frame, source_name, role, retarget) for frame in sample_times])
        source_basis = source_basis_for_track(source_name, role, retarget, smd_bones)
        bone_tracks.append((source_name, mmd_name, role, source_basis, samples))

    morph_tracks = []
    for mmd_name, frames in sorted(vmd.morph_frames.items()):
        source_name = flex_map.get(mmd_name, "")
        if not source_name:
            continue
        samples = [sample_morph(frames, frame) for frame in sample_times]
        morph_tracks.append((source_name, mmd_name, samples))

    ik_tracks = sample_ik(vmd.property_frames, vmd.max_frame, SAMPLE_FPS)

    out = bytearray()
    out += CACHE_MAGIC
    out += struct.pack("<HHIfL", CACHE_VERSION, SAMPLE_FPS, frame_count, vmd.max_frame / VMD_FPS, vmd.max_frame)
    out += pack_string(vmd.model_name)
    out += pack_string(str(source_path))
    out += pack_string(source_hash)

    out += struct.pack("<H", len(bone_tracks))
    for source_name, mmd_name, role, source_basis, samples in bone_tracks:
        out += pack_string(source_name)
        out += pack_string(mmd_name)
        out += pack_string(role)
        out += struct.pack("<B", 0)
        out += pack_mat3(source_basis)
        for pos, ang in samples:
            out += pack_vec(pos)
            out += pack_vec(ang)

    out += struct.pack("<H", len(morph_tracks))
    for source_name, mmd_name, samples in morph_tracks:
        out += pack_string(source_name)
        out += pack_string(mmd_name)
        for weight in samples:
            out += struct.pack("<f", max(0.0, min(1.0, weight)))

    out += struct.pack("<H", len(ik_tracks))
    for name, samples in sorted(ik_tracks.items()):
        out += pack_string(name)
        out += bytes(1 if state else 0 for state in samples)

    out += pack_debug_rows(build_debug_rows(vmd, bone_map, flex_map, retarget_table))

    return bytes(out)


def motion_source_stem(path_or_name: Path | str) -> str:
    value = str(path_or_name or "").strip()
    if not value:
        return "motion"

    path = Path(value)
    looks_like_path = isinstance(path_or_name, Path) or "/" in value or "\\" in value or path.suffix.lower() in {
        ".vmd",
        ".json",
        ".mp3",
        ".wav",
        ".ogg",
        ".flac",
        ".m4a",
        ".aac",
        ".wma",
        ".mp4",
        ".mkv",
        ".mov",
        ".avi",
        ".webm",
    }
    if looks_like_path:
        return path.stem.strip() or value
    return value


def slugify(path: Path | str) -> str:
    raw_stem = motion_source_stem(path)
    stem = raw_stem.lower()
    stem = re.sub(r"[^a-z0-9_.-]+", "_", stem)
    stem = stem.strip("._-")
    if stem:
        return stem

    digest = hashlib.sha1(raw_stem.encode("utf-8", errors="replace")).hexdigest()[:10]
    return f"motion_{digest}"


def short_file_hash(path: Path | str | None, length: int = 10) -> str:
    if not path:
        return ""
    try:
        source = Path(path)
        if not source.is_file():
            return ""
        return hashlib.sha1(source.read_bytes()).hexdigest()[: max(1, int(length))]
    except OSError:
        return ""


def motion_id_with_vmd_hash(motion_name_source: Path | str, vmd_path: Path | str | None = None) -> str:
    base = slugify(motion_name_source)
    digest = short_file_hash(vmd_path)
    if not digest:
        return base
    return f"{base}_{digest}"


def motion_display_name(path_or_name: Path | str) -> str:
    return motion_source_stem(path_or_name).strip() or "motion"


def emit_progress(callback: ProgressCallback | None, message: str) -> None:
    if callback:
        callback(message)


def gmod_sound_relative_path(sound_identifier: str) -> str:
    return f"{GMOD_SOUND_SUBDIR}/{sound_identifier}.mp3"


def gmod_sound_output_path(gmod_dir: Path, sound_identifier: str) -> Path:
    return gmod_dir / "garrysmod" / "sound" / GMOD_SOUND_SUBDIR / f"{sound_identifier}.mp3"


# --- Installed-motion inspection (Motion Manager tab) ------------------------
def gmod_motions_dir(gmod_dir: Path) -> Path:
    """Where imported motion JSONs live in a GMod install (what the addon reads
    and what the importer writes to)."""
    return gmod_dir / "garrysmod" / "data" / "mmd_vmd_npc" / "motions"


def _header_find_int(text: str, key: str) -> int | None:
    match = re.search(rf'"{re.escape(key)}":\s*(-?\d+)', text)
    return int(match.group(1)) if match else None


def _header_find_str(text: str, key: str) -> str | None:
    match = re.search(rf'"{re.escape(key)}":"((?:[^"\\]|\\.)*)"', text)
    if not match:
        return None
    try:
        return json.loads('"' + match.group(1) + '"')
    except ValueError:
        return match.group(1)


def read_motion_header(path: Path) -> dict:
    """Extract the display-worthy header fields of an imported motion JSON.

    Motion JSONs embed multi-MB `bones`/`camera` arrays, so this avoids a full
    ``json.loads`` (which would build millions of Python floats) by scanning for
    the handful of scalar fields, and only falls back to a full parse when that
    fast path cannot find the essentials. All scalar top-level fields precede the
    camera block, so the first regex match is always the top-level value."""
    text = path.read_text(encoding="utf-8", errors="replace")

    motion_id = _header_find_str(text, "motion_id")
    fps = _header_find_int(text, "fps")
    if motion_id is None or fps is None:
        # Unexpected layout — pay for a correct full parse rather than guess.
        data = json.loads(text)
        motion_id = str(data.get("motion_id") or path.stem)
        fps = int(data.get("fps") or VMD_FPS)
        frame_start = int(data.get("frame_start") or 0)
        frame_end = int(data.get("frame_end") or 0)
        frame_count = data.get("frame_count")
        display = data.get("display_name") or data.get("motion_name") or motion_id
        motion_name = data.get("motion_name") or display
        flex_count = data.get("flex_count")
        if flex_count is None and isinstance(data.get("flexes"), list):
            flex_count = len(data["flexes"])
        music = data.get("music") if isinstance(data.get("music"), dict) else None
        camera = data.get("camera") if isinstance(data.get("camera"), dict) else None
        music_sound = str(music.get("sound")) if music and music.get("sound") else ""
        camera_keys = int(camera.get("key_count") or 0) if camera else 0
        is_addon = bool(data.get("is_addon"))
    else:
        frame_start = _header_find_int(text, "frame_start") or 0
        frame_end = _header_find_int(text, "frame_end") or 0
        frame_count = _header_find_int(text, "frame_count")
        display = _header_find_str(text, "display_name") or _header_find_str(text, "motion_name") or motion_id
        motion_name = _header_find_str(text, "motion_name") or display
        flex_count = _header_find_int(text, "flex_count")
        music_sound = _header_find_str(text, "sound") or ""
        camera_keys = _header_find_int(text, "key_count") or 0
        is_addon = '"is_addon":true' in text

    fps = fps if fps and fps > 0 else VMD_FPS
    if frame_count is None:
        frame_count = max(0, frame_end - frame_start + 1)
    duration = max(0.0, (frame_end - frame_start) / fps) if fps else 0.0

    return {
        "motion_id": str(motion_id or path.stem),
        "display_name": str(display or path.stem),
        "motion_name": str(motion_name or display or path.stem),
        "fps": int(fps),
        "frame_start": int(frame_start),
        "frame_end": int(frame_end),
        "frame_count": int(frame_count),
        "duration": float(duration),
        "has_music": bool(music_sound),
        "music_sound": str(music_sound),
        "has_camera": bool(camera_keys > 0),
        "camera_key_count": int(camera_keys),
        "flex_count": int(flex_count or 0),
        "is_addon": bool(is_addon),
    }


def rename_motion_display_name(path: Path, new_display_name: str) -> str:
    """Rewrite an imported motion JSON's in-game name in place, preserving the
    file/motion_id (which the addon keys motions and built caches by). Returns the
    saved name."""
    new_display_name = str(new_display_name or "").strip()
    if not new_display_name:
        raise ValueError("motion name cannot be empty")
    data = json.loads(path.read_text(encoding="utf-8"))
    data["motion_name"] = new_display_name
    data["display_name"] = new_display_name
    atomic_write_text(path, json.dumps(data, ensure_ascii=False, separators=(",", ":")))
    return new_display_name


# --- MMD camera track -------------------------------------------------------
# Validated at machine precision against Blender mmd_tools (see repo history):
#   R = RotY(-ry) @ RotX(-rx) @ RotZ(-rz)
#   eye     = target + R @ (0, 0, distance)   (distance < 0 puts the camera in
#                                              front of the character; > 0 behind
#                                              the target plane, same view axis)
#   forward = R @ (0, 0, 1)                    (NOT normalize(target - eye): a
#                                              positive distance would flip it)
#   up      = R @ (0, 1, 0)
#   fov     = vertical degrees
# MMD world axes: +X viewer right, +Y up, +Z into screen; the character faces
# -Z. GMod entity-local axes: +X forward, +Y left, +Z up. The handedness flip
# maps MMD (x, y, z) -> GMod local (-z, x, y).
CAMERA_POSITION_SCALE = 41.78 * 0.08  # MMD unit -> Source unit, matches the body pipeline
CAMERA_TRACK_FORMAT = 1
# Decimation tolerances: a sampled frame is dropped only when linear
# interpolation (the exact math the GMod client uses) reproduces it within
# these bounds.
CAMERA_DECIMATE_POS_EPS = 0.1     # source units
CAMERA_DECIMATE_ANG_EPS = 0.05    # degrees
CAMERA_DECIMATE_FOV_EPS = 0.02    # degrees


def camera_bezier_weight(t: float, interp: bytes, channel: int) -> float:
    """Camera interpolation uses 6 channels (X, Y, Z, rotation, distance, fov)
    of 4 bytes each laid out (x1, x2, y1, y2) — unlike bone curves."""
    if t <= 0:
        return 0.0
    if t >= 1:
        return 1.0

    base = channel * 4
    x1 = interp[base] / 127.0
    x2 = interp[base + 1] / 127.0
    y1 = interp[base + 2] / 127.0
    y2 = interp[base + 3] / 127.0

    if abs(x1 - y1) < 1e-6 and abs(x2 - y2) < 1e-6:
        return t

    lo, hi = 0.0, 1.0
    for _ in range(32):
        mid = (lo + hi) * 0.5
        if bezier_point(mid, 0.0, x1, x2, 1.0) < t:
            lo = mid
        else:
            hi = mid
    s = (lo + hi) * 0.5
    return bezier_point(s, 0.0, y1, y2, 1.0)


def sample_camera_frames(frames: list[CameraFrame], frame: float) -> tuple[tuple[float, float, float], tuple[float, float, float], float, float]:
    """Interpolate (target, rotation, distance, fov) at a fractional frame."""
    if not frames:
        return (0.0, 10.0, 0.0), (0.0, 0.0, 0.0), -45.0, 30.0

    if frame <= frames[0].frame:
        key = frames[0]
        return key.position, key.rotation, key.distance, key.fov
    if frame >= frames[-1].frame:
        key = frames[-1]
        return key.position, key.rotation, key.distance, key.fov

    lo, hi = 0, len(frames) - 1
    while lo < hi - 1:
        mid = (lo + hi) // 2
        if frames[mid].frame <= frame:
            lo = mid
        else:
            hi = mid
    a, b = frames[lo], frames[hi]
    span = max(1e-9, float(b.frame - a.frame))
    t = (frame - a.frame) / span

    wx = camera_bezier_weight(t, b.interp, 0)
    wy = camera_bezier_weight(t, b.interp, 1)
    wz = camera_bezier_weight(t, b.interp, 2)
    wr = camera_bezier_weight(t, b.interp, 3)
    wd = camera_bezier_weight(t, b.interp, 4)
    wf = camera_bezier_weight(t, b.interp, 5)

    position = (
        lerp(a.position[0], b.position[0], wx),
        lerp(a.position[1], b.position[1], wy),
        lerp(a.position[2], b.position[2], wz),
    )
    # MMD camera rotations are cumulative euler values (can exceed +-pi) and
    # interpolate component-wise; do not normalize before interpolating.
    rotation = (
        lerp(a.rotation[0], b.rotation[0], wr),
        lerp(a.rotation[1], b.rotation[1], wr),
        lerp(a.rotation[2], b.rotation[2], wr),
    )
    distance = lerp(a.distance, b.distance, wd)
    fov = lerp(a.fov, b.fov, wf)
    return position, rotation, distance, fov


def mmd_camera_pose(target, rotation, distance):
    """Eye, forward, up in MMD space for interpolated camera channels."""
    rx, ry, rz = rotation
    cx, sx = math.cos(-rx), math.sin(-rx)
    cy, sy = math.cos(-ry), math.sin(-ry)
    cz, sz = math.cos(-rz), math.sin(-rz)
    # R = RotY(-ry) @ RotX(-rx) @ RotZ(-rz), expanded column products.
    m00 = cy * cz + sy * sx * sz
    m01 = -cy * sz + sy * sx * cz
    m02 = sy * cx
    m10 = cx * sz
    m11 = cx * cz
    m12 = -sx
    m20 = -sy * cz + cy * sx * sz
    m21 = sy * sz + cy * sx * cz
    m22 = cy * cx

    eye = (
        target[0] + m02 * distance,
        target[1] + m12 * distance,
        target[2] + m22 * distance,
    )
    forward = (m02, m12, m22)
    up = (m01, m11, m21)
    return eye, forward, up


def _mmd_to_gmod_vec(v):
    return (-v[2], v[0], v[1])


def _source_angles_from_forward_up(forward, up):
    """Source VectorAngles(forward, pseudo-up) -> (pitch, yaw, roll) degrees."""
    fx, fy, fz = forward
    lx = up[1] * fz - up[2] * fy
    ly = up[2] * fx - up[0] * fz
    lz = up[0] * fy - up[1] * fx
    length = math.sqrt(lx * lx + ly * ly + lz * lz)
    if length > 1e-9:
        lx, ly, lz = lx / length, ly / length, lz / length

    xy_dist = math.sqrt(fx * fx + fy * fy)
    if xy_dist > 0.001:
        yaw = math.atan2(fy, fx)
        pitch = math.atan2(-fz, xy_dist)
        up_z = ly * fx - lx * fy
        roll = math.atan2(lz, up_z)
    else:
        yaw = math.atan2(-lx, ly)
        pitch = math.atan2(-fz, xy_dist)
        roll = 0.0
    return math.degrees(pitch), math.degrees(yaw), math.degrees(roll)


def sample_camera_gmod(frames: list[CameraFrame], frame: float) -> tuple[float, float, float, float, float, float, float]:
    """Entity-local GMod camera sample: (px, py, pz, pitch, yaw, roll, vfov)."""
    target, rotation, distance, fov = sample_camera_frames(frames, frame)
    eye, forward, up = mmd_camera_pose(target, rotation, distance)
    px, py, pz = (_mmd_to_gmod_vec(eye)[i] * CAMERA_POSITION_SCALE for i in range(3))
    pitch, yaw, roll = _source_angles_from_forward_up(_mmd_to_gmod_vec(forward), _mmd_to_gmod_vec(up))
    return px, py, pz, pitch, yaw, roll, fov


def _normalize_angle_deg(value: float) -> float:
    return ((value + 180.0) % 360.0) - 180.0


def _lerp_angle_deg(a: float, b: float, t: float) -> float:
    return a + _normalize_angle_deg(b - a) * t


def _camera_sample_lerp(a, b, t):
    """Linear interpolation between two decimated samples, matching the Lua
    playback math exactly (angles take the shortest normalized path)."""
    return (
        lerp(a[0], b[0], t),
        lerp(a[1], b[1], t),
        lerp(a[2], b[2], t),
        _lerp_angle_deg(a[3], b[3], t),
        _lerp_angle_deg(a[4], b[4], t),
        _lerp_angle_deg(a[5], b[5], t),
        lerp(a[6], b[6], t),
    )


def _camera_samples_close(a, b) -> bool:
    for i in range(3):
        if abs(a[i] - b[i]) > CAMERA_DECIMATE_POS_EPS:
            return False
    for i in range(3, 6):
        if abs(_normalize_angle_deg(a[i] - b[i])) > CAMERA_DECIMATE_ANG_EPS:
            return False
    return abs(a[6] - b[6]) <= CAMERA_DECIMATE_FOV_EPS


def build_camera_track(camera_vmd_path: Path, progress: ProgressCallback | None = None) -> dict | None:
    """Parse a camera VMD and produce the GMod-local camera track dict, or None
    when the file holds no camera frames."""
    parsed = parse_vmd(camera_vmd_path)
    frames = parsed.camera_frames
    if not frames:
        emit_progress(progress, f"No camera frames found in {camera_vmd_path}")
        return None

    frame_start = 0
    frame_end = frames[-1].frame
    # The frame index is a raw u32; a corrupt file can claim billions of frames
    # and per-frame sampling would exhaust memory. Same guard class as the body
    # bake's MAX_BAKE_FRAMES check.
    if frame_end - frame_start > MAX_BAKE_FRAMES:
        raise ValueError(
            f"camera VMD frame range 0..{frame_end} exceeds the {MAX_BAKE_FRAMES}-frame limit; "
            f"the file may be corrupted: {camera_vmd_path}"
        )
    samples = [sample_camera_gmod(frames, f) for f in range(frame_start, frame_end + 1)]
    # Normalize angles once at the sample level; playback interpolates via
    # shortest-path deltas so cumulative multi-turn values are unnecessary.
    samples = [
        (s[0], s[1], s[2], _normalize_angle_deg(s[3]), _normalize_angle_deg(s[4]), _normalize_angle_deg(s[5]), s[6])
        for s in samples
    ]

    # Greedy decimation: keep a sample only when linear interpolation between
    # the previous kept sample and the candidate fails to reproduce EVERY
    # intermediate frame within tolerance.
    kept: list[int] = [0]
    last = 0
    index = 1
    total = len(samples)
    while index < total - 1:
        candidate = index + 1
        span = candidate - last
        ok = True
        for mid in range(last + 1, candidate):
            t = (mid - last) / span
            approx = _camera_sample_lerp(samples[last], samples[candidate], t)
            if not _camera_samples_close(approx, samples[mid]):
                ok = False
                break
        if ok:
            index += 1
        else:
            kept.append(index)
            last = index
            index += 1
    if total > 1:
        kept.append(total - 1)

    # The GMod loader caps camera tracks at 20000 keys; thin uniformly (keeping
    # the endpoints) rather than letting the addon truncate the tail.
    max_keys = 20000
    if len(kept) > max_keys:
        stride = (len(kept) - 1) / (max_keys - 1)
        thinned = [kept[round(i * stride)] for i in range(max_keys)]
        thinned[-1] = kept[-1]
        kept = thinned
        emit_progress(progress, f"Camera track thinned to {max_keys} keys to fit the addon limit")

    keys = []
    for sample_index in kept:
        s = samples[sample_index]
        keys.append([
            frame_start + sample_index,
            round(s[0], 3), round(s[1], 3), round(s[2], 3),
            round(s[3], 3), round(s[4], 3), round(s[5], 3),
            round(s[6], 3),
        ])

    emit_progress(
        progress,
        f"Camera track: {len(frames)} VMD key(s) over frames {frame_start}-{frame_end}, exported {len(keys)} sampled key(s)",
    )
    return {
        "format": CAMERA_TRACK_FORMAT,
        "fps": VMD_FPS,
        "frame_start": frame_start,
        "frame_end": frame_end,
        "position_scale": round(CAMERA_POSITION_SCALE, 6),
        "key_count": len(keys),
        "source": camera_vmd_path.name,
        "keys": keys,
    }


def atomic_write_text(target: Path, text: str, encoding: str = "utf-8") -> None:
    """Write text via a temp file + os.replace so a crash or kill mid-write can
    never leave a truncated (unparseable) file at the destination path."""
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(target.parent), prefix=target.name + ".", suffix=".tmp")
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding=encoding) as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, target)
    except BaseException:
        tmp_path.unlink(missing_ok=True)
        raise


def safe_relative_path(value: str) -> Path:
    parts = [
        part
        for part in str(value or "").replace("\\", "/").split("/")
        if part and part not in {".", ".."}
    ]
    if not parts:
        raise ValueError("empty relative path")
    result = Path(*parts)
    # A leading part like "C:" makes the result drive-anchored, so joining it onto
    # a base directory would escape that base (e.g. deleting a file on another
    # drive). A genuine relative path (mmd_vmd_npc/music/x.mp3) has neither.
    if result.is_absolute() or result.drive:
        raise ValueError(f"unsafe absolute or drive-anchored path: {value!r}")
    return result


def find_gmad_executable(gmod_dir: Path) -> Path:
    gmad = gmod_dir / "bin" / "gmad.exe"
    if gmad.exists():
        return gmad
    found = shutil.which("gmad.exe") or shutil.which("gmad")
    if found:
        return Path(found)
    raise FileNotFoundError(f"gmad.exe was not found under {gmod_dir / 'bin'}")


def export_motion_addon_gma(
    motion_json_path: Path,
    music: dict[str, object] | None,
    gmod_dir: Path,
    motion_name_source: Path | str,
    output_gma_path: Path,
    progress: ProgressCallback | None = None,
) -> Path:
    """Package one imported motion JSON and optional music into a distributable .gma."""

    if not motion_json_path.exists():
        raise FileNotFoundError(f"motion JSON not found: {motion_json_path}")

    gmad = find_gmad_executable(gmod_dir)
    output_gma_path = output_gma_path.with_suffix(".gma")
    output_gma_path.parent.mkdir(parents=True, exist_ok=True)
    folder_name = f"MMDMotionPlayer_{slugify(motion_name_source)}"

    with tempfile.TemporaryDirectory(prefix="mmd_vmd_gma_") as tmp:
        addon_folder = Path(tmp) / folder_name
        addon_folder.mkdir(parents=True, exist_ok=True)
        addon_json = {
            "title": f"MMD Motion Player - {motion_display_name(motion_name_source)}",
            "type": "effects",
            "tags": ["fun"],
            "ignore": [],
        }
        (addon_folder / "addon.json").write_text(json.dumps(addon_json, ensure_ascii=False, indent=2), encoding="utf-8")

        motion_dst = addon_folder / "data_static" / "mmd_vmd_npc" / "motions" / motion_json_path.name
        motion_dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(motion_json_path, motion_dst)

        sound_rel = str((music or {}).get("sound") or "")
        if sound_rel:
            try:
                safe_sound_rel = safe_relative_path(sound_rel)
                sound_src = gmod_dir / "garrysmod" / "sound" / safe_sound_rel
                # Match the accepted GMod addon layout:
                #   data_static/mmd_vmd_npc/motions/<motion>.json
                #   sound/mmd_vmd_npc/music/<motion>.mp3
                sound_dst = addon_folder / "sound" / safe_sound_rel
                if sound_src.exists():
                    sound_dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(sound_src, sound_dst)
                else:
                    emit_progress(progress, f"Warning: music file was not found for addon packaging: {sound_src}")
            except Exception as exc:
                emit_progress(progress, f"Warning: skipped addon music packaging: {exc}")

        command = [
            str(gmad),
            "create",
            "-folder",
            str(addon_folder),
            "-out",
            str(output_gma_path),
        ]
        if output_gma_path.exists():
            output_gma_path.unlink()
        emit_progress(progress, f"Packaging GMod addon: {output_gma_path}")
        try:
            completed = subprocess.run(
                command,
                text=True,
                encoding="utf-8",
                errors="replace",
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=300,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(f"gmad packaging timed out after {exc.timeout:.0f}s") from exc
        if completed.returncode != 0:
            raise RuntimeError(f"gmad failed with exit code {completed.returncode}\n{completed.stdout}")
        if not output_gma_path.exists():
            raise RuntimeError(f"gmad completed but did not write {output_gma_path}\n{completed.stdout}")

    emit_progress(progress, f"Wrote GMod addon package: {output_gma_path}")
    return output_gma_path


def find_ffmpeg_executable() -> Path:
    try:
        import imageio_ffmpeg

        return Path(imageio_ffmpeg.get_ffmpeg_exe())
    except Exception:
        found = shutil.which("ffmpeg")
        if found:
            return Path(found)
    raise RuntimeError("ffmpeg is unavailable. Install imageio-ffmpeg or place ffmpeg on PATH.")


def convert_music_to_gmod_mp3(
    music_path: Path,
    gmod_dir: Path,
    motion_name_source: Path | str,
    progress: ProgressCallback | None = None,
    vmd_path: Path | str | None = None,
) -> dict[str, object]:
    if not music_path.exists():
        raise FileNotFoundError(f"music file not found: {music_path}")

    # Name the sound with the same slug+content-hash identifier the motion JSON
    # uses, so two motions imported from same-named source files own distinct
    # MP3s instead of the second silently overwriting the first's audio.
    sound_identifier = motion_id_with_vmd_hash(motion_name_source, vmd_path)
    output = gmod_sound_output_path(gmod_dir, sound_identifier)
    output.parent.mkdir(parents=True, exist_ok=True)
    ffmpeg = find_ffmpeg_executable()
    command = [
        str(ffmpeg),
        "-y",
        "-i",
        str(music_path),
        "-vn",
        "-ar",
        str(MUSIC_SAMPLE_RATE),
        "-ac",
        "2",
        "-b:a",
        MUSIC_BITRATE,
        str(output),
    ]
    emit_progress(progress, f"Converting music to MP3: {music_path}")
    try:
        completed = subprocess.run(
            command,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=600,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"ffmpeg music conversion timed out after {exc.timeout:.0f}s: {music_path}") from exc
    if completed.returncode != 0:
        raise RuntimeError(f"ffmpeg music conversion failed with exit code {completed.returncode}\n{completed.stdout}")
    if not output.exists():
        raise RuntimeError(f"ffmpeg completed but did not write {output}\n{completed.stdout}")
    emit_progress(progress, f"Wrote GMod sound: {output}")
    return {
        "sound": gmod_sound_relative_path(sound_identifier),
        "sample_rate": MUSIC_SAMPLE_RATE,
        "source": music_path.name,
    }


def parse_vdf(text: str):
    tokens = re.findall(r'"((?:\\.|[^"\\])*)"|([{}])', text)
    flat = [m[0].replace("\\\\", "\\") if m[0] else m[1] for m in tokens]
    index = 0

    def parse_obj():
        nonlocal index
        obj = {}
        while index < len(flat):
            token = flat[index]
            index += 1
            if token == "}":
                break
            key = token
            if index < len(flat) and flat[index] == "{":
                index += 1
                obj[key] = parse_obj()
            elif index < len(flat):
                obj[key] = flat[index]
                index += 1
        return obj

    result = {}
    while index < len(flat):
        key = flat[index]
        index += 1
        if index < len(flat) and flat[index] == "{":
            index += 1
            result[key] = parse_obj()
        elif index < len(flat):
            result[key] = flat[index]
            index += 1
    return result


def steam_path_from_registry() -> Path | None:
    if os.name != "nt":
        return None
    try:
        import winreg
    except ImportError:
        return None
    candidates = [
        (winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"),
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
    ]
    for root, subkey, value in candidates:
        try:
            with winreg.OpenKey(root, subkey) as key:
                raw, _ = winreg.QueryValueEx(key, value)
            path = Path(str(raw).replace("/", "\\"))
            if path.exists():
                return path
        except OSError:
            continue
    return None


def find_gmod_install() -> Path:
    env = os.environ.get("GMOD_DIR") or os.environ.get("GARRYSMOD_DIR")
    if env and Path(env).exists():
        return Path(env)

    steam = steam_path_from_registry()
    if not steam:
        env_steam = os.environ.get("STEAM_DIR")
        steam = Path(env_steam) if env_steam else None
    if not steam:
        raise FileNotFoundError("could not locate Steam; set GMOD_DIR or STEAM_DIR")

    library_file = steam / "steamapps" / "libraryfolders.vdf"
    if not library_file.exists():
        raise FileNotFoundError(f"missing Steam library file: {library_file}")

    parsed = parse_vdf(library_file.read_text(encoding="utf-8", errors="replace"))
    folders = parsed.get("libraryfolders", {})
    for value in folders.values():
        if not isinstance(value, dict):
            continue
        apps = value.get("apps", {})
        if "4000" not in apps:
            continue
        library = Path(value.get("path", ""))
        manifest = library / "steamapps" / "appmanifest_4000.acf"
        install_dir = "GarrysMod"
        if manifest.exists():
            app_state = parse_vdf(manifest.read_text(encoding="utf-8", errors="replace")).get("AppState", {})
            install_dir = app_state.get("installdir", install_dir)
        gmod = library / "steamapps" / "common" / install_dir
        if gmod.exists():
            return gmod

    raise FileNotFoundError("Garry's Mod app 4000 was not found in Steam libraries")


def find_steam_app_install(app_id: str, default_install_dir: str) -> Path | None:
    steam = steam_path_from_registry()
    if not steam:
        env_steam = os.environ.get("STEAM_DIR")
        steam = Path(env_steam) if env_steam else None
    if not steam:
        return None

    library_file = steam / "steamapps" / "libraryfolders.vdf"
    if not library_file.exists():
        return None

    parsed = parse_vdf(library_file.read_text(encoding="utf-8", errors="replace"))
    folders = parsed.get("libraryfolders", {})
    for value in folders.values():
        if not isinstance(value, dict):
            continue
        apps = value.get("apps", {})
        if app_id not in apps:
            continue
        library = Path(value.get("path", ""))
        manifest = library / "steamapps" / f"appmanifest_{app_id}.acf"
        install_dir = default_install_dir
        if manifest.exists():
            app_state = parse_vdf(manifest.read_text(encoding="utf-8", errors="replace")).get("AppState", {})
            install_dir = app_state.get("installdir", install_dir)
        install = library / "steamapps" / "common" / install_dir
        if install.exists():
            return install

    return None


def find_default_mmd_model() -> Path:
    model = DEFAULT_MMD_MODEL_DIR / DEFAULT_MMD_MODEL_NAME
    if not model.exists():
        raise FileNotFoundError(f"required PMX model not found: {model}")
    if not model.is_file():
        raise FileNotFoundError(f"required PMX model is not a file: {model}")
    return model


def steam_blender_candidates() -> list[Path]:
    candidates: list[Path] = []
    if os.name == "nt":
        roots = [
            os.environ.get("PROGRAMFILES(X86)"),
            os.environ.get("PROGRAMFILES"),
            r"C:\Program Files (x86)",
            r"C:\Program Files",
        ]
        for root in roots:
            if root:
                candidates.append(Path(root) / "Steam" / "steamapps" / "common" / "Blender" / "blender.exe")

    steam_blender = find_steam_app_install(STEAM_BLENDER_APP_ID, "Blender")
    if steam_blender:
        candidates.append(steam_blender / "blender.exe")

    out: list[Path] = []
    seen: set[str] = set()
    for path in candidates:
        key = str(path).lower()
        if key not in seen:
            out.append(path)
            seen.add(key)
    return out


def find_steam_blender_executable() -> Path | None:
    for candidate in steam_blender_candidates():
        if candidate.exists():
            return candidate
    return None


def blender_path_version_key(path: Path) -> tuple[int, int, int]:
    """Best-effort numeric version parsed from a Blender install path so that,
    e.g., 'Blender 4.10' sorts above 'Blender 4.3' (a lexicographic sort does
    not). Returns (0, 0, 0) when no version-like segment is present."""
    match = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", str(path))
    if not match:
        return (0, 0, 0)
    return (int(match.group(1)), int(match.group(2)), int(match.group(3) or 0))


def app_local_dir() -> Path:
    """This importer's own local-data folder (Motion Manager index)."""
    local = os.environ.get("LOCALAPPDATA")
    if local:
        return Path(local) / APP_LOCAL_DIR_NAME
    return Path.home() / f".{APP_LOCAL_DIR_NAME}"


def scmi_app_local_dir() -> Path:
    """Local-data folder of the sibling Simple Character Model Importer.

    Overridable with MMDVMDNPC_SCMI_APP_DIR for non-default machines."""
    override = os.environ.get("MMDVMDNPC_SCMI_APP_DIR")
    if override:
        return Path(override)
    local = os.environ.get("LOCALAPPDATA")
    if local:
        return Path(local) / SCMI_APP_DIR_NAME
    return Path.home() / f".{SCMI_APP_DIR_NAME}"


def blender_exe_in_dir(root: Path) -> Path | None:
    """Locate blender.exe directly in `root`, then anywhere beneath it."""
    try:
        direct = root / "blender.exe"
        if direct.is_file():
            return direct
        return next(iter(root.rglob("blender.exe")), None)
    except OSError:
        return None


def blender_install_is_complete(blender_exe: Path | None) -> bool:
    """A fully extracted portable Blender always has a `portable` folder beside
    the executable; its presence means the extraction finished (not interrupted)."""
    if not blender_exe:
        return False
    try:
        return blender_exe.is_file() and (blender_exe.parent / BLENDER_PORTABLE_MARKER).is_dir()
    except OSError:
        return False


def scmi_managed_blender() -> Path | None:
    """Reuse the Blender 4.5.x that the Simple Character Model Importer already
    extracted (it also pre-installs mmd_tools, so the bake needs no download).

    Prefers the exe recorded in its verified setup_state.json, then falls back to
    scanning its managed blender folder."""
    app = scmi_app_local_dir()

    state_path = app / "setup" / "setup_state.json"
    try:
        if state_path.is_file():
            state = json.loads(state_path.read_text(encoding="utf-8"))
            raw = str(state.get("blender_exe") or "")
            if raw:
                exe = Path(raw)
                version = str(state.get("blender_version") or "") or (infer_blender_version_from_path(exe) or "")
                if version.startswith("4.5") and blender_install_is_complete(exe):
                    return exe
    except (OSError, ValueError):
        pass

    managed_root = app / "software" / "blender"
    try:
        version_dirs = sorted(
            (d for d in managed_root.glob("4.5*") if d.is_dir()),
            key=lambda d: blender_path_version_key(d),
            reverse=True,
        )
    except OSError:
        version_dirs = []
    for version_dir in version_dirs:
        exe = blender_exe_in_dir(version_dir)
        if blender_install_is_complete(exe):
            return exe
    return None


def infer_blender_version_from_path(path: Path | str) -> str | None:
    match = re.search(r"blender-(\d+\.\d+(?:\.\d+)?)-windows-x64", str(path), re.IGNORECASE)
    return match.group(1) if match else None


def path_blender_version_supported(path: Path | str) -> bool:
    """True only when the `blender-X.Y.Z-windows-x64` version parsed from the path
    is a supported release. Returns False when no version is present, so callers
    fall back to the real `--version` probe rather than trusting an unknown build."""
    version_text = infer_blender_version_from_path(path)
    if not version_text:
        return False
    try:
        parts = tuple(int(x) for x in version_text.split(".")[:3])
    except ValueError:
        return False
    parts = parts + (0,) * (3 - len(parts))
    return is_blender_version_supported(parts)


def vendored_mmd_tools_archive() -> Path | None:
    """The mmd_tools zip vendored in tools/blender_addons, so the legacy Blender
    bake can install mmd_tools offline. Returns None (and the bake falls back to
    its network download) when it is missing."""
    root = ROOT / "tools" / BLENDER_ADDONS_SUBDIR
    try:
        if not root.is_dir():
            return None
        direct = root / "mmd_tools.zip"
        if direct.is_file():
            return direct
        matches = sorted(root.glob("*mmd*tools*.zip"))
    except OSError:
        return None
    return matches[0] if matches else None


def blender_is_trusted_install(blender: Path | None) -> bool:
    """True when `blender` is the Simple Character Model Importer's managed
    portable install AND its path names a supported version, so the `--version`
    probe can be skipped. Any other path — including a managed install of an
    unsupported version — is still verified so the 'Blender X is not supported'
    error is never silently skipped."""
    if not blender:
        return False
    if not blender_install_is_complete(blender):
        return False
    if not path_blender_version_supported(blender):
        return False
    try:
        blender.resolve().relative_to(scmi_app_local_dir().resolve())
        return True
    except (OSError, ValueError):
        return False


def find_blender_executable(progress: ProgressCallback | None = None) -> Path:
    """Blender for the legacy --bake-with-blender reference bake."""
    # 0. Explicit override for advanced users / development.
    env = os.environ.get("MMDVMDNPC_BLENDER_EXE") or os.environ.get("BLENDER_EXE")
    if env and Path(env).exists():
        return Path(env)

    # 1. Reuse the Blender the Simple Character Model Importer already provisioned.
    scmi = scmi_managed_blender()
    if scmi:
        emit_progress(progress, f"Using Blender installed by Simple Character Model Importer: {scmi}")
        return scmi

    # 2. An ordinary system Blender install.
    return detect_system_blender()


def detect_system_blender() -> Path:
    # An explicit override wins over auto-detection; otherwise the documented
    # BLENDER_EXE is silently ignored whenever any Steam Blender exists.
    env = os.environ.get("BLENDER_EXE")
    if env and Path(env).exists():
        return Path(env)

    steam_blender = find_steam_blender_executable()
    if steam_blender:
        return steam_blender

    candidates: list[Path] = []
    if os.name == "nt":
        for root_name in ("PROGRAMFILES", "PROGRAMFILES(X86)"):
            root = os.environ.get(root_name)
            if not root:
                continue
            blender_root = Path(root) / "Blender Foundation"
            if blender_root.exists():
                candidates.extend(blender_root.glob("Blender*/blender.exe"))
        local = os.environ.get("LOCALAPPDATA")
        if local:
            candidates.extend((Path(local) / "Programs").glob("Blender*/blender.exe"))
    else:
        candidates.extend(Path("/usr/bin").glob("blender"))
        candidates.extend(Path("/Applications").glob("Blender.app/Contents/MacOS/Blender"))

    path_blender = shutil.which("blender")
    if path_blender:
        candidates.append(Path(path_blender))

    existing = [path for path in candidates if path.exists()]
    if existing:
        # Prefer the highest actual version, not the lexicographically-last path.
        return sorted(existing, key=blender_path_version_key)[-1]

    raise FileNotFoundError("could not locate Blender; set MMDVMDNPC_BLENDER_EXE or pass --blender")


def detect_blender() -> Path:
    return find_blender_executable()


def parse_blender_version(text: str) -> tuple[int, int, int] | None:
    match = re.search(r"Blender\s+(\d+)\.(\d+)(?:\.(\d+))?", text or "")
    if not match:
        return None
    return (
        int(match.group(1)),
        int(match.group(2)),
        int(match.group(3) or 0),
    )


def format_blender_version(version: tuple[int, int, int] | None) -> str:
    if not version:
        return "unknown"
    return f"{version[0]}.{version[1]}.{version[2]}"


def blender_version(blender: Path) -> tuple[int, int, int]:
    completed = subprocess.run(
        [str(blender), "--version"],
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=30,
    )
    version = parse_blender_version(completed.stdout or "")
    if not version:
        raise RuntimeError(f"could not determine Blender version from {blender}\n{completed.stdout}")
    return version


def is_blender_version_supported(version: tuple[int, int, int]) -> bool:
    return version[:2] > (4, 2)


def require_supported_blender(blender: Path) -> Path:
    # The sibling importer's managed portable Blender is a known-good 4.5.x; skip
    # the ~1s `blender --version` subprocess for it and only probe unknown installs.
    if blender_is_trusted_install(blender):
        return blender
    version = blender_version(blender)
    if not is_blender_version_supported(version):
        raise RuntimeError(
            "Blender "
            + format_blender_version(version)
            + " is not supported. Install Blender 4.3 or newer from "
            + STEAM_BLENDER_URL
        )
    return blender


def _load_vmd_baker():
    try:
        from tools import vmd_baker
    except ModuleNotFoundError:
        import vmd_baker  # type: ignore[no-redef]
    return vmd_baker


def bake_vmd_native(
    vmd_path: Path,
    mmd_model: Path | None = None,
    frame_start: int = 0,
    frame_end: int | None = None,
    output_rotation_json: Path | None = None,
    progress: ProgressCallback | None = None,
    cancel_check: CancelCheck | None = None,
    disable_foot_ik: bool = False,
) -> dict:
    """Bake MMD IK and append transforms in-process (no Blender) and return the
    parent-corrected rotation document that write_motion_json consumes. The
    document is also written to `output_rotation_json` when one is given."""
    if not vmd_path.exists():
        raise FileNotFoundError(vmd_path)
    mmd_model = mmd_model or find_default_mmd_model()
    if not mmd_model.exists():
        raise FileNotFoundError(f"MMD model not found: {mmd_model}")

    emit_progress(progress, "Starting native motion bake...")
    started = time.monotonic()
    emit_progress(progress, f"Importing MMD model: {mmd_model}")
    bones = parse_pmx_bones(mmd_model)
    emit_progress(progress, f"Imported MMD model: {mmd_model.name} ({len(bones)} bones)")
    emit_progress(progress, f"Importing VMD motion: {vmd_path}")
    parsed = parse_vmd(vmd_path)
    emit_progress(progress, f"Imported VMD motion: {len(parsed.bone_frames)} bone track(s), max frame {parsed.max_frame}")

    frame_end = parsed.max_frame if frame_end is None else frame_end
    if frame_end < frame_start:
        raise ValueError("frame_end must be greater than or equal to frame_start")
    # A corrupt VMD can report a garbage max frame (the field is a raw u32);
    # reject an implausibly long range up front with a clear message.
    if (frame_end - frame_start) > MAX_BAKE_FRAMES:
        raise ValueError(
            f"VMD frame range {frame_start}..{frame_end} exceeds the {MAX_BAKE_FRAMES}-frame limit; "
            "the file may be corrupted, or pass an explicit --frame-end"
        )

    vmd_baker = _load_vmd_baker()
    try:
        document = vmd_baker.bake_motion(
            bones,
            parsed,
            load_bone_mapping(),
            frame_start,
            frame_end,
            model_path=mmd_model,
            input_vmd=vmd_path.resolve(),
            disable_ik=disable_foot_ik,
            progress=progress,
            cancel_check=cancel_check,
        )
    except vmd_baker.BakeCancelled as exc:
        raise RuntimeError("VMD bake was cancelled") from exc

    if output_rotation_json is not None:
        atomic_write_text(output_rotation_json, json.dumps(document, ensure_ascii=False, separators=(",", ":")))
        emit_progress(progress, f"Wrote parent-corrected rotation JSON: {output_rotation_json}")
    emit_progress(progress, f"Native bake finished in {time.monotonic() - started:.1f}s")
    return document


def build_blender_bake_command(
    blender: Path,
    input_vmd: Path,
    output_vmd: Path,
    mmd_model: Path,
    frame_start: int,
    frame_end: int,
    output_rotation_json: Path | None = None,
    disable_foot_ik: bool = False,
) -> list[str]:
    command = [
        str(blender),
        "--background",
        "--factory-startup",
        "--python",
        str(BLENDER_BAKE_SCRIPT),
        "--",
        "--input-vmd",
        str(input_vmd),
        "--output-vmd",
        str(output_vmd),
        "--mmd-model",
        str(mmd_model),
        "--frame-start",
        str(frame_start),
        "--frame-end",
        str(frame_end),
    ]
    if disable_foot_ik:
        command.append("--disable-foot-ik")
    if output_rotation_json is not None:
        command.extend(
            [
                "--output-rotation-json",
                str(output_rotation_json),
                "--bone-map-json",
                json.dumps(load_bone_mapping(), ensure_ascii=False),
            ]
        )
    return command


def bake_vmd_with_blender(
    vmd_path: Path,
    blender: Path | None = None,
    mmd_model: Path | None = None,
    output_dir: Path | None = None,
    frame_start: int = 0,
    frame_end: int | None = None,
    output_rotation_json: Path | None = None,
    progress: ProgressCallback | None = None,
    cancel_check: CancelCheck | None = None,
    disable_foot_ik: bool = False,
) -> Path:
    if not vmd_path.exists():
        raise FileNotFoundError(vmd_path)
    if not BLENDER_BAKE_SCRIPT.exists():
        raise FileNotFoundError(f"missing Blender bake script: {BLENDER_BAKE_SCRIPT}")

    blender = require_supported_blender(blender or find_blender_executable(progress))
    mmd_model = mmd_model or find_default_mmd_model()
    if not blender.exists():
        raise FileNotFoundError(f"Blender executable not found: {blender}")
    if not mmd_model.exists():
        raise FileNotFoundError(f"MMD model not found: {mmd_model}")

    parsed = parse_vmd(vmd_path)
    frame_end = parsed.max_frame if frame_end is None else frame_end
    if frame_end < frame_start:
        raise ValueError("frame_end must be greater than or equal to frame_start")
    # A corrupt VMD can report a garbage max frame (the field is a raw u32).
    # Baking that range would spin Blender for effectively forever, so reject an
    # implausibly long range up front with a clear message.
    if (frame_end - frame_start) > MAX_BAKE_FRAMES:
        raise ValueError(
            f"VMD frame range {frame_start}..{frame_end} exceeds the {MAX_BAKE_FRAMES}-frame limit; "
            "the file may be corrupted, or pass an explicit --frame-end"
        )

    output_dir = output_dir or BAKED_OUTPUT_DIR
    output_dir.mkdir(parents=True, exist_ok=True)
    output_vmd = output_dir / f"{slugify(vmd_path)}_baked.vmd"
    output_rotation_json = output_rotation_json or (output_dir / PARENT_CORRECTED_ROTATION_JSON)

    command = build_blender_bake_command(
        blender,
        vmd_path.resolve(),
        output_vmd.resolve(),
        mmd_model.resolve(),
        frame_start,
        frame_end,
        output_rotation_json.resolve(),
        disable_foot_ik=disable_foot_ik,
    )
    if disable_foot_ik:
        emit_progress(progress, "Foot IK disabled for this bake (motion authored without IK).")
    emit_progress(progress, "Starting Blender bake process...")
    started = time.monotonic()
    bake_env = os.environ.copy()
    mmd_tools_archive = vendored_mmd_tools_archive()
    if mmd_tools_archive:
        bake_env["MMDVMDNPC_MMD_TOOLS_ARCHIVE"] = str(mmd_tools_archive)
        emit_progress(progress, f"Using vendored mmd_tools archive: {mmd_tools_archive}")
    process = subprocess.Popen(
        command,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=1,
        env=bake_env,
    )
    output_lines: list[str] = []
    assert process.stdout is not None
    while True:
        if cancel_check and cancel_check():
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
            raise RuntimeError("Blender VMD bake was cancelled")

        line = process.stdout.readline()
        if line:
            line = line.rstrip("\r\n")
            output_lines.append(line)
            if line:
                emit_progress(progress, f"[Blender] {line}")
            continue

        if process.poll() is not None:
            break
        time.sleep(0.05)
    return_code = process.wait()
    stdout = "\n".join(output_lines)
    emit_progress(progress, f"Blender bake process finished in {time.monotonic() - started:.1f}s")
    if return_code != 0:
        raise RuntimeError(f"Blender VMD bake failed with exit code {return_code}\n{stdout}")
    if not output_vmd.exists():
        raise RuntimeError(f"Blender completed but did not write {output_vmd}\n{stdout}")
    if output_rotation_json and not output_rotation_json.exists():
        raise RuntimeError(f"Blender completed but did not write {output_rotation_json}\n{stdout}")
    return output_vmd


def write_cache(vmd_path: Path, output_dir: Path, debug_retarget: bool = False) -> Path:
    data = vmd_path.read_bytes()
    digest = hashlib.sha1(data).hexdigest()
    parsed = parse_vmd(vmd_path)
    cache = build_cache(parsed, vmd_path.resolve(), digest, debug_retarget=debug_retarget)
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"{slugify(vmd_path)}.json"
    output.write_bytes(cache)
    return output


def compact_morph_keyframes(frames: list[MorphFrame]) -> list[list[float]]:
    # These keys are played back with LINEAR interpolation, so a key may only
    # be dropped when it is the INTERIOR of a constant run — same weight as
    # both the previous kept key and the next key. Dropping any key whose
    # weight merely equals the last kept one (the old rule) also removed the
    # LAST key of a run, turning an instant 0->1 pop at frame N into a ramp
    # that starts at the previous value change, potentially hundreds of frames
    # earlier (bikkuri read 0.94 at frame 202 instead of 0 because its
    # (210, 0.0) hold key was deleted and only (214, 1.0) survived).
    ordered = sorted(frames, key=lambda item: item.frame)
    count = len(ordered)
    keys: list[list[float]] = []
    for index, frame in enumerate(ordered):
        weight = max(0.0, min(1.0, float(frame.weight)))
        if index > 0 and index < count - 1:
            prev_weight = keys[-1][1]
            next_weight = max(0.0, min(1.0, float(ordered[index + 1].weight)))
            if abs(weight - prev_weight) <= 0.000001 and abs(next_weight - weight) <= 0.000001:
                continue
        keys.append([int(frame.frame), round(weight, 6)])
    return keys


def morph_frames_are_meaningful(frames: list[MorphFrame], epsilon: float = 0.000001) -> bool:
    return any(abs(float(frame.weight)) > epsilon for frame in frames)


def combine_morph_frames_additive(frame_sets: list[list[MorphFrame]]) -> list[MorphFrame]:
    active_sets = [frames for frames in frame_sets if frames]
    if not active_sets:
        return []

    sample_frames = sorted({int(frame.frame) for frames in active_sets for frame in frames})
    weights = [
        max(0.0, min(1.0, sum(sample_morph(frames, frame) for frames in active_sets)))
        for frame in sample_frames
    ]
    # Same run-boundary rule as compact_morph_keyframes: linear playback means
    # only interior keys of constant runs are redundant.
    combined: list[MorphFrame] = []
    count = len(sample_frames)
    for index, frame in enumerate(sample_frames):
        weight = weights[index]
        if index > 0 and index < count - 1:
            if abs(weight - combined[-1].weight) <= 0.000001 and abs(weights[index + 1] - weight) <= 0.000001:
                continue
        combined.append(MorphFrame(frame, weight))
    return combined


def flex_track_is_meaningful(track: dict[str, object], epsilon: float = 0.000001) -> bool:
    for key in track.get("k") or track.get("keys") or []:
        try:
            if isinstance(key, (list, tuple)) and len(key) >= 2 and abs(float(key[1])) > epsilon:
                return True
        except (TypeError, ValueError):
            continue
    return False


def flex_track_to_morph_frames(track: dict[str, object]) -> list[MorphFrame]:
    frames: list[MorphFrame] = []
    for key in track.get("k") or track.get("keys") or []:
        if not isinstance(key, (list, tuple)) or len(key) < 2:
            continue
        try:
            frames.append(MorphFrame(int(key[0]), float(key[1])))
        except (TypeError, ValueError):
            continue
    return frames


def additive_merge_flex_tracks(existing: dict[str, object], incoming: dict[str, object]) -> dict[str, object]:
    source = str(existing.get("g") or incoming.get("g") or "")
    existing_name = str(existing.get("m") or "")
    incoming_name = str(incoming.get("m") or "")
    if incoming_name and incoming_name != existing_name:
        mmd_name = f"{existing_name}+{incoming_name}" if existing_name else incoming_name
    else:
        mmd_name = existing_name or incoming_name
    frames = combine_morph_frames_additive([
        flex_track_to_morph_frames(existing),
        flex_track_to_morph_frames(incoming),
    ])
    return {"m": mmd_name, "g": source, "k": compact_morph_keyframes(frames)}


def build_motion_json_flex_tracks_from_vmd(vmd_path: Path) -> list[dict[str, object]]:
    motion = parse_vmd(vmd_path)
    flex_map = load_flex_mapping()
    flexes: list[dict[str, object]] = []

    for mmd_name, frames in sorted(motion.morph_frames.items()):
        source_name = flex_map.get(mmd_name, "")
        if not source_name:
            continue
        keys = compact_morph_keyframes(frames)
        if keys:
            flexes.append({"m": mmd_name, "g": source_name, "k": keys})

    return flexes


def merge_motion_json_flex_tracks(
    main_vmd_path: Path | None,
    extra_flex_vmd_paths: list[Path] | None = None,
    progress: ProgressCallback | None = None,
) -> tuple[list[dict[str, object]], list[str]]:
    flexes: list[dict[str, object]] = []
    warnings: list[str] = []
    seen_sources: dict[str, tuple[int, bool, str]] = {}

    def add_tracks(vmd_path: Path, source_label: str, main: bool) -> None:
        nonlocal flexes
        if not vmd_path.exists():
            warnings.append(f"Skipped missing {source_label} flex VMD: {vmd_path}")
            return
        tracks = build_motion_json_flex_tracks_from_vmd(vmd_path)
        emit_progress(progress, f"Parsed {len(tracks)} mapped flex track(s) from {source_label}: {vmd_path}")
        for track in tracks:
            source = str(track.get("g") or "")
            if not source:
                continue
            if source in seen_sources:
                existing_index, existing_meaningful, existing_origin = seen_sources[source]
                track_meaningful = flex_track_is_meaningful(track)
                if track_meaningful and not existing_meaningful:
                    flexes[existing_index] = track
                    seen_sources[source] = (existing_index, True, source_label)
                    warnings.append(f"Replaced zero placeholder flex {source} from {existing_origin} with {source_label}: {vmd_path}")
                    continue
                if track_meaningful and existing_meaningful:
                    flexes[existing_index] = additive_merge_flex_tracks(flexes[existing_index], track)
                    seen_sources[source] = (existing_index, True, existing_origin)
                    warnings.append(f"Added duplicate flex {source} from {source_label} additively: {vmd_path}")
                    continue
                origin = "main VMD" if main else source_label
                warnings.append(f"Skipped duplicate flex {source} from {origin}: {vmd_path}")
                continue
            seen_sources[source] = (
                len(flexes),
                flex_track_is_meaningful(track),
                source_label,
            )
            flexes.append(track)

    if main_vmd_path and main_vmd_path.exists():
        add_tracks(main_vmd_path, "main VMD", True)
    for index, flex_vmd in enumerate(extra_flex_vmd_paths or [], start=1):
        add_tracks(flex_vmd, f"extra flex VMD #{index}", False)

    return flexes, warnings


def build_motion_json_flex_tracks(vmd_path: Path) -> list[dict[str, object]]:
    flexes, _ = merge_motion_json_flex_tracks(vmd_path, [])
    return flexes


# Column order of the importer's metadata table; also the canonical key set of
# the motion JSON's "meta" block read by the GMod addon (sv_cache read_motion_file).
MOTION_META_FIELDS = (
    "category",
    "display_name",
    "english_name",
    "artist",
    "language",
    "link",
    "motion_artist",
)


def normalize_motion_meta(meta: dict | None, fallback_display_name: str) -> dict[str, str]:
    """Coerce a user-supplied metadata mapping to the canonical string-only meta
    block. Every canonical key is always present (empty string when unknown) so
    downstream readers never need existence checks; display_name falls back to
    the computed display name so the block is self-sufficient."""
    source = meta or {}
    block = {key: str(source.get(key) or "").strip() for key in MOTION_META_FIELDS}
    if not block["display_name"]:
        block["display_name"] = fallback_display_name
    return block


def write_motion_json(
    rotation_source: Path | dict,
    output_dir: Path,
    motion_name_source: Path | str,
    flex_vmd_path: Path | None = None,
    extra_flex_vmd_paths: list[Path] | None = None,
    music: dict[str, object] | None = None,
    audio_offset: float | None = None,
    is_addon: bool = False,
    progress: ProgressCallback | None = None,
    camera_track: dict | None = None,
    meta: dict | None = None,
) -> Path:
    """Write the GMod motion JSON from a parent-corrected rotation document,
    given in memory (bake_vmd_native) or as a JSON file path."""
    if isinstance(rotation_source, dict):
        parsed = dict(rotation_source)
    else:
        if not rotation_source.exists():
            raise FileNotFoundError(rotation_source)
        parsed = json.loads(rotation_source.read_text(encoding="utf-8"))
    if parsed.get("format") != "mmd_vmd_npc_parent_corrected_axis_v1":
        raise ValueError(f"unsupported parent-corrected motion JSON format: {parsed.get('format')!r}")

    original_input_vmd = parsed.get("input_vmd")
    if flex_vmd_path is None and original_input_vmd:
        flex_vmd_path = Path(str(original_input_vmd))
    flexes, flex_warnings = merge_motion_json_flex_tracks(flex_vmd_path, extra_flex_vmd_paths or [], progress)
    parsed["flexes"] = flexes
    parsed["flex_count"] = len(flexes)
    if flex_warnings:
        parsed["flex_warnings"] = flex_warnings
        for warning in flex_warnings:
            emit_progress(progress, f"Warning: {warning}")
    if music:
        parsed["music"] = dict(music)
    if camera_track:
        parsed["camera"] = dict(camera_track)
    if audio_offset is not None:
        offset = round(max(-5.0, min(5.0, float(audio_offset))), 3)
        parsed["audio_offset"] = offset
        if parsed.get("music") and isinstance(parsed["music"], dict):
            parsed["music"]["offset"] = offset
            parsed["music"]["default_offset"] = offset

    display_name = motion_display_name(motion_name_source)
    meta_block = normalize_motion_meta(meta, display_name)
    display_name = meta_block["display_name"]
    parsed["motion_id"] = motion_id_with_vmd_hash(motion_name_source, flex_vmd_path)
    parsed["motion_name"] = display_name
    parsed["display_name"] = display_name
    parsed["meta"] = meta_block
    if is_addon:
        parsed["is_addon"] = True

    for key in ("input_vmd", "baked_vmd", "mmd_model"):
        if parsed.get(key):
            parsed[key] = Path(str(parsed[key])).name

    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"{parsed['motion_id']}.json"
    atomic_write_text(output, json.dumps(parsed, ensure_ascii=False, separators=(",", ":")))
    return output


def configure_output_streams() -> None:
    """Keep progress printing alive on narrow console codepages.

    Motion, model, and music paths routinely contain CJK characters that a
    Windows console codepage such as cp932/cp936 cannot encode; without this,
    a fully successful bake dies on the final progress print.
    """

    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is None:
            continue
        try:
            reconfigure(errors="replace")
        except (ValueError, OSError):
            pass


def main(argv: list[str]) -> int:
    configure_output_streams()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vmd", type=Path, nargs="?", help="VMD file to import")
    parser.add_argument("--cache", action="store_true", help="bake the VMD and write the compact parent-corrected motion JSON for GMod")
    parser.add_argument("--bake", action="store_true", help="bake MMD IK/append transforms natively (no Blender) and write the parent-corrected rotation JSON; implied by --cache")
    parser.add_argument("--bake-with-blender", action="store_true", help="legacy reference bake through Blender + mmd_tools instead of the native baker (requires Blender 4.3+)")
    parser.add_argument("--blender", type=Path, help="Blender executable for --bake-with-blender")
    parser.add_argument("--mmd-model", type=Path, help="PMX model to bake on; defaults to the bundled model")
    parser.add_argument("--baked-output-dir", type=Path, help="directory for intermediate bake output")
    parser.add_argument("--output-rotation-json", type=Path, help="parent-corrected rotation JSON: output path when baking, or a pre-baked input for --cache")
    parser.add_argument("--flex-vmd", type=Path, action="append", default=[], help="additional facial/flex VMD to merge; may be repeated")
    parser.add_argument("--camera-vmd", type=Path, help="optional camera VMD; exports an entity-anchored camera path for the GMod addon")
    parser.add_argument("--music", type=Path, help="optional music/audio or video file; audio is extracted and converted to GMod MP3 sound")
    parser.add_argument("--audio-offset", type=float, default=0.0, help="default music offset in seconds; positive starts music later, negative starts advanced")
    parser.add_argument("--motion-name", help="optional imported motion name; controls the GMod JSON and music filename")
    parser.add_argument("--export-addon-gma", type=Path, help="also package the imported motion and optional music as a .gma file")
    parser.add_argument("--frame-start", type=int, default=0, help="first VMD frame to bake")
    parser.add_argument("--frame-end", type=int, help="last VMD frame to bake; defaults to the VMD max frame")
    parser.add_argument("--disable-foot-ik", action="store_true",
                        help="mute all IK on the model before baking; use for motions authored without foot IK")
    parser.add_argument("--install-addon", action="store_true", help="legacy no-op; addon installation is no longer performed")
    parser.add_argument("--output-dir", type=Path, help="override GMod motion JSON output directory")
    parser.add_argument("--gmod-dir", type=Path, help="override Garry's Mod installation directory")
    parser.add_argument("--print-gmod", action="store_true", help="print the detected Garry's Mod path")
    parser.add_argument("--print-blender", action="store_true", help="print the Blender executable --bake-with-blender would use")
    parser.add_argument("--debug-retarget", action="store_true", help="legacy binary-cache retarget diagnostic flag")
    args = parser.parse_args(argv)

    gmod_dir = args.gmod_dir
    if args.cache or args.print_gmod:
        gmod_dir = gmod_dir or find_gmod_install()
    if args.print_gmod:
        print(gmod_dir)
    if args.print_blender:
        print(args.blender or detect_blender())

    if args.install_addon:
        print("Skipped addon install: importer no longer modifies garrysmod/addons. Install or update the addon manually.")

    if args.bake and args.bake_with_blender:
        parser.error("choose either --bake or --bake-with-blender")
    rotation_source: Path | dict | None = None
    if args.bake_with_blender:
        if not args.vmd:
            parser.error("--bake-with-blender requires a VMD file")
        rotation_source = args.output_rotation_json or ((args.baked_output_dir or BAKED_OUTPUT_DIR) / PARENT_CORRECTED_ROTATION_JSON)
        baked_vmd = bake_vmd_with_blender(
            args.vmd,
            blender=args.blender,
            mmd_model=args.mmd_model,
            output_dir=args.baked_output_dir,
            frame_start=args.frame_start,
            frame_end=args.frame_end,
            output_rotation_json=rotation_source,
            disable_foot_ik=args.disable_foot_ik,
        )
        print(f"Baked VMD: {baked_vmd}")
        print(f"Parent-corrected rotation JSON: {rotation_source}")
    elif args.bake or (args.cache and args.vmd and not args.output_rotation_json):
        if not args.vmd:
            parser.error("--bake requires a VMD file")
        rotation_json_out = args.output_rotation_json
        if rotation_json_out is None and not args.cache:
            rotation_json_out = (args.baked_output_dir or BAKED_OUTPUT_DIR) / PARENT_CORRECTED_ROTATION_JSON
        rotation_source = bake_vmd_native(
            args.vmd,
            mmd_model=args.mmd_model,
            frame_start=args.frame_start,
            frame_end=args.frame_end,
            output_rotation_json=rotation_json_out,
            progress=print,
            disable_foot_ik=args.disable_foot_ik,
        )
    elif args.output_rotation_json:
        rotation_source = args.output_rotation_json

    if args.cache:
        if rotation_source is None:
            parser.error("--cache requires a VMD file to bake, or --output-rotation-json with a pre-baked rotation JSON")
        output_dir = args.output_dir or (gmod_dir / "garrysmod" / "data" / "mmd_vmd_npc" / "motions")
        music_metadata = None
        motion_name_source = args.motion_name or args.vmd or args.output_rotation_json
        if args.music:
            music_metadata = convert_music_to_gmod_mp3(args.music, gmod_dir, motion_name_source, vmd_path=args.vmd)
            print(f"Wrote music: {music_metadata['sound']}")
        camera_track = None
        if args.camera_vmd:
            if not args.camera_vmd.exists():
                raise FileNotFoundError(f"camera VMD not found: {args.camera_vmd}")
            camera_track = build_camera_track(args.camera_vmd, print)
        output = write_motion_json(
            rotation_source,
            output_dir,
            motion_name_source,
            args.vmd,
            extra_flex_vmd_paths=args.flex_vmd,
            music=music_metadata,
            audio_offset=args.audio_offset,
            is_addon=args.export_addon_gma is not None,
            progress=print,
            camera_track=camera_track,
        )
        print(f"Wrote motion JSON: {output}")
        if args.export_addon_gma:
            gma = export_motion_addon_gma(output, music_metadata, gmod_dir, motion_name_source, args.export_addon_gma, print)
            print(f"Wrote GMod addon: {gma}")

    if not args.cache and not args.install_addon and not args.print_gmod and not args.print_blender and not args.bake and not args.bake_with_blender:
        parser.print_help()

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
