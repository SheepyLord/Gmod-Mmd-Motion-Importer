#!/usr/bin/env python3
"""Native (Blender-free) MMD motion baker.

Evaluates a VMD body motion on a PMX skeleton the way MMD does: bezier
interpolated bone keyframes, append (付与) rotation/translation in transform
order, and IK - standard [knee, thigh] leg chains in closed form (exact hinge
angle, then a minimal-rotation thigh aim), every other chain with MMD-style
CCD including hinge handling for angle-limited links. Every frame is
independent, so the whole pose evaluation is vectorised over frames with
NumPy instead of stepping a Blender scene frame by frame.

The export stage reproduces the parent-corrected rotation JSON that the old
Blender + mmd_tools bake wrote (format "mmd_vmd_npc_parent_corrected_axis_v1"):
the same Blender armature axes and units, the same bone naming, track
selection and keyframe compaction, so the rest of the importer and the GMod
addon consume it unchanged.

Conventions: everything is computed in MMD model space (left-handed, +Y up,
model faces -Z). Quaternions are float64 arrays in (x, y, z, w) order, the
order VMD stores them in.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

import numpy as np


OUTPUT_FORMAT = "mmd_vmd_npc_parent_corrected_axis_v1"
VMD_FPS = 30
# mmd_tools imports PMX/VMD data at 0.08 Blender units per MMD unit, and the
# exported positions use 41.78 Source units per Blender unit.
MMD_TO_BLENDER_SCALE = 0.08
BLENDER_TO_SOURCE_POSITION_SCALE = 41.78
ROTATION_EPSILON_DEGREES = 0.0005
POSITION_EPSILON_SOURCE_UNITS = 0.0005
# Frames evaluated per vectorised batch; bounds memory on long motions.
CHUNK_FRAMES = 2048
# Guard against corrupt PMX loop counts; real models use 15-100.
MAX_IK_LOOPS = 256

# Ground unification (stage placement cancelling). Bones that can rest on the
# floor: the lowest of them each frame is the character's ground contact -
# the feet normally, knees/hands/hips during floor work.
GROUND_CONTACT_BONES = (
    "左つま先", "右つま先", "左足先EX", "右足先EX", "左足首", "右足首",
    "左ひざ", "右ひざ", "左手首", "右手首", "左ひじ", "右ひじ",
    "下半身", "上半身", "上半身2", "首", "頭",
)
# Half-window of the ground envelope: airborne phases up to ~1 s (31 frames)
# keep their height above the floor; anything longer counts as standing on
# a raised surface.
GROUND_AIRBORNE_FRAMES = 15
# Ground changes faster than this (MMD units per frame) are stage cuts or
# drops and stay sharp; slower ones are smoothed over GROUND_SMOOTH_SIGMA
# frames so support-foot switches do not pop.
GROUND_CUT_STEP = 2.0
GROUND_SMOOTH_SIGMA = 2.0

# Scene cuts: frames where the character's placement jumps within one frame,
# as Project Diva and other PV motions move the performer between stage spots
# at their camera cuts. A pelvis step above CUT_MIN_STEP Source units and
# CUT_RATIO times the median step of the CUT_NEIGHBOURS frames on either side
# is a cut: dancing stays below about 10 units a frame, faster moves (the
# dashes of action PVs) build up over several frames, which the median leaves
# alone, and the Project Diva cuts measured are 8 to 1,000. The GMod addon
# holds the frame before a cut instead of blending across it and marks the
# jump for hair and cloth physics; it applies the same rule to its built
# frames (MMDVMDNPC.BuiltPoseCuts in sh_core.lua), so change both together.
CUT_MIN_STEP = 8.0
CUT_RATIO = 4.0
CUT_NEIGHBOURS = 3
# Bones whose world position is the character's placement; the first present wins.
PLACEMENT_BONES = ("下半身", "センター")

PRE_PELVIS_ROLES = {"root", "center", "groove", "waist"}
SOURCE_PELVIS = "ValveBiped.Bip01_Pelvis"
SOURCE_SPINE = "ValveBiped.Bip01_Spine"
SOURCE_PARENT_OVERRIDES = {
    # MMD: 腰 -> 下半身 and 腰 -> 上半身. Source: Pelvis -> Spine.
    SOURCE_SPINE: SOURCE_PELVIS,
    # MMD inserts arm/hand twist bones in the parent chain; Source parents
    # Forearm to UpperArm and Hand to Forearm directly.
    "ValveBiped.Bip01_L_Forearm": "ValveBiped.Bip01_L_UpperArm",
    "ValveBiped.Bip01_R_Forearm": "ValveBiped.Bip01_R_UpperArm",
    "ValveBiped.Bip01_L_Hand": "ValveBiped.Bip01_L_Forearm",
    "ValveBiped.Bip01_R_Hand": "ValveBiped.Bip01_R_Forearm",
}

# PMX bone flags.
FLAG_IK = 0x0020
FLAG_LOCAL_APPEND = 0x0080
FLAG_APPEND_ROTATE = 0x0100
FLAG_APPEND_TRANSLATE = 0x0200
FLAG_AFTER_PHYSICS = 0x1000

# VMD interpolation bytes as (x1, y1, x2, y2) per channel X, Y, Z, rotation.
# Each channel is read from its own 16-byte row (the rows are shifted copies),
# which is what mmd_tools does; it also avoids bytes 2/3 of the first row that
# newer MMD versions overwrite with the per-key physics toggle.
_INTERP_INDEX = np.array(
    [
        [0, 4, 8, 12],
        [16, 20, 24, 28],
        [32, 36, 40, 44],
        [48, 52, 56, 60],
    ],
    dtype=np.intp,
)

ProgressCallback = Callable[[str], None]
CancelCheck = Callable[[], bool]


class BakeCancelled(RuntimeError):
    pass


# --------------------------------------------------------------------------
# Vectorised quaternion helpers, (..., 4) arrays in (x, y, z, w) order.
# --------------------------------------------------------------------------
def _identity(count: int) -> np.ndarray:
    out = np.zeros((count, 4), dtype=np.float64)
    out[:, 3] = 1.0
    return out


def q_mul(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    ax, ay, az, aw = a[..., 0], a[..., 1], a[..., 2], a[..., 3]
    bx, by, bz, bw = b[..., 0], b[..., 1], b[..., 2], b[..., 3]
    return np.stack(
        (
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz,
        ),
        axis=-1,
    )


def q_conj(q: np.ndarray) -> np.ndarray:
    out = q.copy()
    out[..., :3] *= -1.0
    return out


def q_normalize(q: np.ndarray) -> np.ndarray:
    length = np.linalg.norm(q, axis=-1, keepdims=True)
    safe = np.where(length > 1e-12, length, 1.0)
    out = q / safe
    bad = (length[..., 0] <= 1e-12)
    if np.any(bad):
        out[bad] = (0.0, 0.0, 0.0, 1.0)
    return out


def _cross(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    return np.stack(
        (
            a[..., 1] * b[..., 2] - a[..., 2] * b[..., 1],
            a[..., 2] * b[..., 0] - a[..., 0] * b[..., 2],
            a[..., 0] * b[..., 1] - a[..., 1] * b[..., 0],
        ),
        axis=-1,
    )


def q_rotate(q: np.ndarray, v: np.ndarray) -> np.ndarray:
    """Rotate vectors v (..., 3) by unit quaternions q (..., 4)."""
    u = q[..., :3]
    t = 2.0 * _cross(u, v)
    return v + q[..., 3:4] * t + _cross(u, t)


def q_from_axis_angle(axis: np.ndarray, angle: np.ndarray) -> np.ndarray:
    half = 0.5 * np.asarray(angle, dtype=np.float64)
    out = np.empty(half.shape + (4,), dtype=np.float64)
    out[..., :3] = axis * np.sin(half)[..., None]
    out[..., 3] = np.cos(half)
    return out


def q_slerp(a: np.ndarray, b: np.ndarray, t: np.ndarray) -> np.ndarray:
    """Shortest-path spherical interpolation (MMD/D3DX semantics)."""
    dot = np.sum(a * b, axis=-1)
    b = np.where((dot < 0.0)[..., None], -b, b)
    dot = np.minimum(np.abs(dot), 1.0)
    theta = np.arccos(dot)
    sin_theta = np.sin(theta)
    tiny = sin_theta < 1e-10
    safe_sin = np.where(tiny, 1.0, sin_theta)
    s0 = np.where(tiny, 1.0 - t, np.sin((1.0 - t) * theta) / safe_sin)
    s1 = np.where(tiny, t, np.sin(t * theta) / safe_sin)
    return q_normalize(a * s0[..., None] + b * s1[..., None])


def q_nlerp(a: np.ndarray, b: np.ndarray, t: np.ndarray) -> np.ndarray:
    """Component-wise interpolation + normalise (Blender F-curve semantics)."""
    dot = np.sum(a * b, axis=-1)
    b = np.where((dot < 0.0)[..., None], -b, b)
    return q_normalize(a + (b - a) * t[..., None])


def q_power(q: np.ndarray, weight: float) -> np.ndarray:
    """Rotation scaled along its shortest arc: slerp(identity, q, weight).

    Negative weights invert the rotation (MMD's -1 "cancel" append bones)."""
    q = np.where((q[..., 3] < 0.0)[..., None], -q, q)
    vec_len = np.linalg.norm(q[..., :3], axis=-1)
    angle = 2.0 * np.arctan2(vec_len, q[..., 3])
    axis = q[..., :3] / np.where(vec_len > 1e-12, vec_len, 1.0)[..., None]
    out = q_from_axis_angle(axis, angle * weight)
    tiny = vec_len <= 1e-12
    if np.any(tiny):
        out[tiny] = (0.0, 0.0, 0.0, 1.0)
    return out


def q_to_matrix(q: np.ndarray) -> np.ndarray:
    x, y, z, w = q[..., 0], q[..., 1], q[..., 2], q[..., 3]
    xx, yy, zz = x * x, y * y, z * z
    xy, xz, yz = x * y, x * z, y * z
    wx, wy, wz = w * x, w * y, w * z
    m = np.empty(q.shape[:-1] + (3, 3), dtype=np.float64)
    m[..., 0, 0] = 1.0 - 2.0 * (yy + zz)
    m[..., 0, 1] = 2.0 * (xy - wz)
    m[..., 0, 2] = 2.0 * (xz + wy)
    m[..., 1, 0] = 2.0 * (xy + wz)
    m[..., 1, 1] = 1.0 - 2.0 * (xx + zz)
    m[..., 1, 2] = 2.0 * (yz - wx)
    m[..., 2, 0] = 2.0 * (xz - wy)
    m[..., 2, 1] = 2.0 * (yz + wx)
    m[..., 2, 2] = 1.0 - 2.0 * (xx + yy)
    return m


def _normalize_vectors(v: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    length = np.linalg.norm(v, axis=-1)
    return v / np.where(length > 1e-12, length, 1.0)[..., None], length


# --------------------------------------------------------------------------
# Euler helpers for IK links limited on more than one axis.
# --------------------------------------------------------------------------
def _diff_angle(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    diff = np.mod(a - b + math.pi, 2.0 * math.pi) - math.pi
    return diff


def _decompose_xyz(m: np.ndarray, before: np.ndarray) -> np.ndarray:
    """Angles (x, y, z) with m = Rx(x) @ Ry(y) @ Rz(z), choosing the
    equivalent solution closest to `before` (keeps IK clamping continuous)."""
    sy = np.clip(m[..., 0, 2], -1.0, 1.0)
    y = np.arcsin(sy)
    x = np.arctan2(-m[..., 1, 2], m[..., 2, 2])
    z = np.arctan2(-m[..., 0, 1], m[..., 0, 0])
    gimbal = np.abs(sy) > 1.0 - 1e-6
    if np.any(gimbal):
        # Keep the previous X, put the whole remaining roll into Z.
        x = np.where(gimbal, before[..., 0], x)
        z_g = np.arctan2(m[..., 1, 0], m[..., 1, 1]) - np.where(sy > 0, 1.0, -1.0) * x
        z = np.where(gimbal, z_g, z)
    best = np.stack((x, y, z), axis=-1)
    best_err = np.sum(np.abs(_diff_angle(best, before)), axis=-1)
    # (x + pi, pi - y, z + pi) and its 2*pi shifts describe the same rotation.
    pi = math.pi
    for dx, y_base, dz in (
        (pi, pi, pi), (pi, pi, -pi), (pi, -pi, pi), (pi, -pi, -pi),
        (-pi, pi, pi), (-pi, pi, -pi), (-pi, -pi, pi), (-pi, -pi, -pi),
    ):
        cand = np.stack((x + dx, y_base - y, z + dz), axis=-1)
        err = np.sum(np.abs(_diff_angle(cand, before)), axis=-1)
        better = err < best_err
        best = np.where(better[..., None], cand, best)
        best_err = np.where(better, err, best_err)
    return best


def _quat_from_xyz(angles: np.ndarray) -> np.ndarray:
    """Quaternion of Rx(x) @ Ry(y) @ Rz(z)."""
    axes = np.eye(3)
    rotation = q_from_axis_angle(np.broadcast_to(axes[0], angles.shape), angles[:, 0])
    for axis_index in (1, 2):
        rotation = q_mul(rotation, q_from_axis_angle(np.broadcast_to(axes[axis_index], angles.shape), angles[:, axis_index]))
    return rotation


# --------------------------------------------------------------------------
# Bezier interpolation.
# --------------------------------------------------------------------------
def _bezier(s: np.ndarray, p1: np.ndarray, p2: np.ndarray) -> np.ndarray:
    inv = 1.0 - s
    return 3.0 * inv * inv * s * p1 + 3.0 * inv * s * s * p2 + s * s * s


def bezier_progress(x: np.ndarray, x1: np.ndarray, y1: np.ndarray, x2: np.ndarray, y2: np.ndarray) -> np.ndarray:
    """Progress y at abscissa x of the unit cubic bezier (0,0)-(x1,y1)-(x2,y2)-(1,1).

    The x-curve is monotonic for control points in [0, 1], so a fixed-count
    bisection is exact to ~1e-10 and never diverges (Newton can, at x1 = 0)."""
    lo = np.zeros_like(x)
    hi = np.ones_like(x)
    for _ in range(34):
        mid = 0.5 * (lo + hi)
        below = _bezier(mid, x1, x2) < x
        lo = np.where(below, mid, lo)
        hi = np.where(below, hi, mid)
    y = _bezier(0.5 * (lo + hi), y1, y2)
    linear = (x1 == y1) & (x2 == y2)
    return np.where(linear, x, y)


# --------------------------------------------------------------------------
# Model / motion preparation.
# --------------------------------------------------------------------------
_LEFT_NAME = re.compile(r"^(.*)左(.*)$")
_RIGHT_NAME = re.compile(r"^(.*)右(.*)$")


def convert_name_to_lr(name: str, use_underscore: bool = False) -> str:
    """mmd_tools' L/R rename: 左腕 -> 腕.L, 右ひざ -> ひざ.R."""
    delimiter = "_" if use_underscore else "."
    match = _LEFT_NAME.match(name)
    if match:
        name = match.group(1) + match.group(2) + delimiter + "L"
    match = _RIGHT_NAME.match(name)
    if match:
        name = match.group(1) + match.group(2) + delimiter + "R"
    return name


def _truncate_utf8(name: str, limit: int = 63) -> str:
    data = name.encode("utf-8")
    if len(data) <= limit:
        return name
    return data[:limit].decode("utf-8", errors="ignore")


def _unique_name(name: str, used: set[str]) -> str:
    if name not in used:
        return name
    index = 1
    while True:
        candidate = _truncate_utf8(name, 63 - 4) + f".{index:03d}"
        if candidate not in used:
            return candidate
        index += 1


def blender_bone_names(pmx_names: Iterable[str]) -> list[str]:
    """Bone names as mmd_tools leaves them in Blender: created in PMX order
    (63-byte limit, '.001' on collisions), then renamed to L/R suffixes."""
    created: list[str] = []
    used: set[str] = set()
    for raw in pmx_names:
        name = _unique_name(_truncate_utf8(raw or "Bone"), used)
        created.append(name)
        used.add(name)
    renamed: list[str] = []
    for name in created:
        target = convert_name_to_lr(name)
        if target != name:
            used.discard(name)
            target = _unique_name(_truncate_utf8(target), used)
            used.add(target)
        renamed.append(target)
    return renamed


def _cp932_truncated(name: str, size: int) -> str:
    raw = name.encode("cp932", errors="replace")[:size]
    return raw.split(b"\x00", 1)[0].decode("cp932", errors="replace")


def _name_resolver(names: list[str], field_size: int) -> Callable[[str], tuple[int, bool]]:
    """Map a VMD name to (bone index, exact): exact match first, then MMD's
    fixed-width cp932 truncation (VMD stores 15/20 bytes, long PMX names get
    cut). Returns (-1, False) when nothing matches."""
    exact: dict[str, int] = {}
    truncated: dict[str, int] = {}
    ambiguous: set[str] = set()
    for index, name in enumerate(names):
        exact.setdefault(name, index)
        key = _cp932_truncated(name, field_size)
        if key in truncated and truncated[key] != index:
            ambiguous.add(key)
        truncated.setdefault(key, index)

    def resolve(name: str) -> tuple[int, bool]:
        if name in exact:
            return exact[name], True
        if name in truncated and name not in ambiguous:
            return truncated[name], False
        return -1, False

    return resolve


@dataclass
class _Link:
    bone: int
    lower: np.ndarray | None  # radians, per axis, already ordered lower <= upper
    upper: np.ndarray | None
    plane_axis: int  # 0/1/2 for single-axis hinge links, -1 otherwise


@dataclass
class _Chain:
    ik_bone: int
    effector: int
    loops: int
    unit_angle: float
    links: list[_Link]
    link_paths: list[list[int]] = field(default_factory=list)
    affected: list[int] = field(default_factory=list)
    # Standard MMD leg: effector -> hinge link (knee) -> free link (thigh),
    # each the direct parent of the previous. Solved in closed form.
    two_bone: bool = False


@dataclass
class _Append:
    source: int
    ratio: float
    rotate: bool
    translate: bool
    local: bool


@dataclass
class BakeModel:
    names: list[str]
    blender_names: list[str]
    parent: list[int]
    rest_position: np.ndarray
    rest_offset: np.ndarray
    hierarchy_order: list[int]
    transform_order: list[int]
    descendants: list[list[int]]
    appends: dict[int, _Append]
    chains: dict[int, _Chain]
    warnings: list[str]


def _plane_axis(lower: np.ndarray, upper: np.ndarray) -> int:
    # Single-axis test as in saba / babylon-mmd (the reference MMD IK ports).
    def moving(axis: int) -> bool:
        return lower[axis] != 0.0 or upper[axis] != 0.0

    def touches_zero(axis: int) -> bool:
        return lower[axis] == 0.0 or upper[axis] == 0.0

    for axis in range(3):
        others = [other for other in range(3) if other != axis]
        if moving(axis) and all(touches_zero(other) for other in others):
            return axis
    return -1


def prepare_model(bones: list) -> BakeModel:
    """Build evaluation tables from parsed PMX bones (import_vmd.PMXBone)."""
    count = len(bones)
    warnings: list[str] = []
    names = [str(bone.name) for bone in bones]
    parent = [int(bone.parent) if 0 <= int(bone.parent) < count and int(bone.parent) != index else -1 for index, bone in enumerate(bones)]
    rest = np.array([bone.position for bone in bones], dtype=np.float64).reshape(count, 3)
    rest[~np.isfinite(rest)] = 0.0

    children: list[list[int]] = [[] for _ in range(count)]
    for index, par in enumerate(parent):
        if par >= 0:
            children[par].append(index)

    # Parents before children; anything unreachable is a parent cycle.
    hierarchy: list[int] = []
    seen = [False] * count
    stack = [index for index in range(count) if parent[index] < 0][::-1]
    while stack:
        index = stack.pop()
        if seen[index]:
            continue
        seen[index] = True
        hierarchy.append(index)
        stack.extend(reversed(children[index]))
    for index in range(count):
        if not seen[index]:
            warnings.append(f'bone "{names[index]}" is in a parent cycle; treated as a root')
            parent[index] = -1
            seen[index] = True
            hierarchy.append(index)
            pending = list(children[index])
            while pending:
                child = pending.pop()
                if not seen[child]:
                    seen[child] = True
                    hierarchy.append(child)
                    pending.extend(children[child])
    rank = {bone: position for position, bone in enumerate(hierarchy)}

    offset = rest.copy()
    for index, par in enumerate(parent):
        if par >= 0:
            offset[index] = rest[index] - rest[par]

    descendants: list[list[int]] = []
    for index in range(count):
        subtree = []
        pending = [index]
        while pending:
            bone = pending.pop()
            subtree.append(bone)
            pending.extend(children[bone])
        descendants.append(sorted(subtree, key=rank.__getitem__))

    transform_order = sorted(
        range(count),
        key=lambda index: (1 if bones[index].flags & FLAG_AFTER_PHYSICS else 0, int(getattr(bones[index], "transform_level", 0)), index),
    )

    appends: dict[int, _Append] = {}
    for index, bone in enumerate(bones):
        flags = int(bone.flags)
        if not flags & (FLAG_APPEND_ROTATE | FLAG_APPEND_TRANSLATE):
            continue
        source = int(getattr(bone, "append_parent", -1))
        ratio = float(getattr(bone, "append_ratio", 0.0))
        if not (0 <= source < count) or source == index or ratio == 0.0 or not math.isfinite(ratio):
            continue
        appends[index] = _Append(
            source,
            ratio,
            bool(flags & FLAG_APPEND_ROTATE),
            bool(flags & FLAG_APPEND_TRANSLATE),
            bool(flags & FLAG_LOCAL_APPEND),
        )

    chains: dict[int, _Chain] = {}
    for index, bone in enumerate(bones):
        if not int(bone.flags) & FLAG_IK:
            continue
        effector = int(getattr(bone, "ik_target", -1))
        if not (0 <= effector < count):
            warnings.append(f'IK bone "{names[index]}" has an invalid target; skipped')
            continue
        links: list[_Link] = []
        for raw in getattr(bone, "ik_links", []) or []:
            link_bone = int(raw.bone)
            if not (0 <= link_bone < count) or link_bone == effector:
                continue
            lower = upper = None
            plane = -1
            if raw.limit_min is not None and raw.limit_max is not None:
                a = np.array(raw.limit_min, dtype=np.float64)
                b = np.array(raw.limit_max, dtype=np.float64)
                lower, upper = np.minimum(a, b), np.maximum(a, b)
                plane = _plane_axis(lower, upper)
            links.append(_Link(link_bone, lower, upper, plane))
        if not links:
            warnings.append(f'IK bone "{names[index]}" has no usable links; skipped')
            continue
        loops = max(1, min(int(getattr(bone, "ik_loop_count", 1) or 1), MAX_IK_LOOPS))
        unit_angle = float(getattr(bone, "ik_limit_angle", 0.0) or 0.0)
        if not math.isfinite(unit_angle) or unit_angle <= 0.0:
            unit_angle = math.pi
        chain = _Chain(index, effector, loops, unit_angle, links)
        effector_ancestors = []
        cursor = effector
        guard = 0
        while cursor >= 0 and guard <= count:
            effector_ancestors.append(cursor)
            cursor = parent[cursor]
            guard += 1
        for link in links:
            if link.bone in effector_ancestors:
                path = effector_ancestors[: effector_ancestors.index(link.bone) + 1][::-1]
            else:
                path = descendants[link.bone]
            chain.link_paths.append(path)
        affected: set[int] = set()
        for link in links:
            affected.update(descendants[link.bone])
        chain.affected = sorted(affected, key=rank.__getitem__)
        chain.two_bone = (
            len(links) == 2
            and links[0].plane_axis >= 0
            and links[1].lower is None
            and parent[effector] == links[0].bone
            and parent[links[0].bone] == links[1].bone
        )
        chains[index] = chain

    return BakeModel(
        names=names,
        blender_names=blender_bone_names(names),
        parent=parent,
        rest_position=rest,
        rest_offset=offset,
        hierarchy_order=hierarchy,
        transform_order=transform_order,
        descendants=descendants,
        appends=appends,
        chains=chains,
        warnings=warnings,
    )


@dataclass
class _Track:
    frames: np.ndarray  # (K,) float64, strictly increasing
    location: np.ndarray  # (K, 3)
    rotation: np.ndarray  # (K, 4) unit quaternions, xyzw
    curves: np.ndarray  # (K, 4, 4) (x1, y1, x2, y2) per channel, in [0, 1]


def build_tracks(model: BakeModel, bone_frames: dict[str, list]) -> tuple[dict[int, _Track], list[str]]:
    resolve = _name_resolver(model.names, 15)
    tracks: dict[int, _Track] = {}
    exact_match: dict[int, bool] = {}
    unmatched: list[str] = []
    for name, frames in bone_frames.items():
        if not frames:
            continue
        index, exact = resolve(name)
        if index < 0:
            unmatched.append(name)
            continue
        if index in tracks and (exact_match[index] or not exact):
            # Another VMD name already drives this bone; an exact name wins
            # over a truncated-prefix match.
            unmatched.append(name)
            continue
        exact_match[index] = exact
        # Stable sort, then keep the last key of any duplicated frame number.
        ordered = sorted(frames, key=lambda key: key.frame)
        unique: list = []
        for key in ordered:
            if unique and unique[-1].frame == key.frame:
                unique[-1] = key
            else:
                unique.append(key)
        location = np.array([key.location for key in unique], dtype=np.float64).reshape(-1, 3)
        rotation = np.array([key.rotation for key in unique], dtype=np.float64).reshape(-1, 4)
        location[~np.isfinite(location)] = 0.0
        rotation[~np.isfinite(rotation)] = 0.0
        rotation = q_normalize(rotation)
        interp = np.frombuffer(b"".join(bytes(key.interp[:64]).ljust(64, b"\x14") for key in unique), dtype=np.uint8).reshape(-1, 64)
        curves = interp[:, _INTERP_INDEX].astype(np.float64) / 127.0
        tracks[index] = _Track(np.array([float(key.frame) for key in unique]), location, rotation, curves)
    return tracks, unmatched


def _sample_track(track: _Track, frames: np.ndarray, nlerp: bool) -> tuple[np.ndarray, np.ndarray]:
    count = len(track.frames)
    if count == 1:
        return np.repeat(track.location, len(frames), axis=0), np.repeat(track.rotation, len(frames), axis=0)
    index = np.searchsorted(track.frames, frames, side="right") - 1
    i0 = np.clip(index, 0, count - 1)
    i1 = np.clip(index + 1, 0, count - 1)
    between = (index >= 0) & (index < count - 1)
    f0 = track.frames[i0]
    span = np.where(between, track.frames[i1] - f0, 1.0)
    t = np.where(between, (frames - f0) / span, 0.0)

    weights = np.zeros((len(frames), 4), dtype=np.float64)
    need = np.nonzero(t > 0.0)[0]
    if len(need):
        curves = track.curves[i1[need]]  # (n, 4 channels, 4 params)
        tn = np.repeat(t[need][:, None], 4, axis=1)
        weights[need] = bezier_progress(tn, curves[..., 0], curves[..., 1], curves[..., 2], curves[..., 3])

    loc0 = track.location[i0]
    location = loc0 + (track.location[i1] - loc0) * weights[:, :3]
    interpolate = q_nlerp if nlerp else q_slerp
    rotation = interpolate(track.rotation[i0], track.rotation[i1], weights[:, 3])
    return location, rotation


def ik_enabled_masks(model: BakeModel, property_frames: list, frames: np.ndarray, disable_all: bool = False) -> dict[int, np.ndarray]:
    """Per-frame IK on/off for each IK bone from VMD property keys (a step
    function; IK defaults to on before the first key, as in MMD)."""
    masks: dict[int, np.ndarray] = {}
    if disable_all:
        return {ik: np.zeros(len(frames), dtype=bool) for ik in model.chains}
    resolve = _name_resolver(model.names, 20)
    events: dict[int, list[tuple[float, bool]]] = {}
    for prop in sorted(property_frames, key=lambda item: item.frame):
        for name, state in prop.ik_states:
            index, _ = resolve(name)
            if index in model.chains:
                events.setdefault(index, []).append((float(prop.frame), bool(state)))
    for ik in model.chains:
        items = events.get(ik)
        if not items:
            masks[ik] = np.ones(len(frames), dtype=bool)
            continue
        times = np.array([time for time, _ in items])
        states = np.array([state for _, state in items], dtype=bool)
        index = np.searchsorted(times, frames, side="right") - 1
        masks[ik] = np.where(index >= 0, states[np.clip(index, 0, len(states) - 1)], True)
    return masks


# --------------------------------------------------------------------------
# Pose evaluation.
# --------------------------------------------------------------------------
class _Pose:
    """Bone transforms for one batch of frames."""

    def __init__(self, model: BakeModel, count: int, analytic_legs: bool = True) -> None:
        bones = len(model.names)
        self.model = model
        self.count = count
        self.analytic_legs = analytic_legs
        self.anim_t = np.zeros((bones, count, 3))
        self.anim_q = np.tile(_identity(count), (bones, 1, 1))
        self.ik_q = np.tile(_identity(count), (bones, 1, 1))
        self.app_q = np.tile(_identity(count), (bones, 1, 1))
        self.app_t = np.zeros((bones, count, 3))
        self.has_ik = np.zeros(bones, dtype=bool)
        self.has_app = np.zeros(bones, dtype=bool)
        self.local_q = self.anim_q.copy()
        self.local_t = np.repeat(model.rest_offset[:, None, :], count, axis=1)
        self.global_q = np.tile(_identity(count), (bones, 1, 1))
        self.global_p = np.zeros((bones, count, 3))

    def refresh_local(self, bone: int) -> None:
        rotation = self.anim_q[bone]
        if self.has_ik[bone]:
            rotation = q_mul(self.ik_q[bone], rotation)
        if self.has_app[bone]:
            rotation = q_mul(rotation, self.app_q[bone])
        self.local_q[bone] = rotation
        self.local_t[bone] = self.model.rest_offset[bone] + self.anim_t[bone] + self.app_t[bone]

    def refresh_global(self, bones: Iterable[int]) -> None:
        parent = self.model.parent
        for bone in bones:
            par = parent[bone]
            if par < 0:
                self.global_q[bone] = self.local_q[bone]
                self.global_p[bone] = self.local_t[bone]
            else:
                parent_q = self.global_q[par]
                self.global_q[bone] = q_mul(parent_q, self.local_q[bone])
                self.global_p[bone] = self.global_p[par] + q_rotate(parent_q, self.local_t[bone])

    def apply_append(self, bone: int, spec: _Append) -> None:
        source = spec.source
        if spec.rotate:
            if spec.local:
                rotation = self.anim_q[source]
                if self.has_ik[source]:
                    rotation = q_mul(self.ik_q[source], rotation)
            else:
                # User value x IK x the source's own append ("multiple append").
                rotation = self.local_q[source]
            self.app_q[bone] = q_power(rotation, spec.ratio)
            self.has_app[bone] = True
        if spec.translate:
            moved = self.anim_t[source] if spec.local else self.anim_t[source] + self.app_t[source]
            self.app_t[bone] = moved * spec.ratio
        self.refresh_local(bone)
        self.refresh_global(self.model.descendants[bone])

    # -- IK ---------------------------------------------------------------
    def _set_link_rotation(self, link: int, rotation: np.ndarray, frames: np.ndarray) -> None:
        """Make the link's local rotation (without append) equal `rotation`
        on the selected frames by solving for its IK rotation."""
        self.ik_q[link][frames] = q_mul(rotation, q_conj(self.anim_q[link][frames]))

    def solve_ik(self, chain: _Chain, enabled: np.ndarray) -> None:
        if not np.any(enabled):
            return
        links = [link.bone for link in chain.links]
        for bone in links:
            self.has_ik[bone] = True
            self.ik_q[bone][enabled] = (0.0, 0.0, 0.0, 1.0)
            self.refresh_local(bone)
        self.refresh_global(chain.affected)

        if self.analytic_legs and chain.two_bone:
            enabled = self._solve_two_bone(chain, enabled)
            if not np.any(enabled):
                return

        link_count = len(links)
        plane_angle = np.zeros((link_count, self.count))
        prev_angles = np.zeros((link_count, self.count, 3))
        saved = np.stack([self.ik_q[bone].copy() for bone in links])
        best = np.full(self.count, np.inf)
        active = enabled.copy()
        ik_position = self.global_p[chain.ik_bone].copy()

        for iteration in range(chain.loops):
            if not np.any(active):
                break
            for position, link in enumerate(chain.links):
                self._solve_link(chain, position, link, iteration, active, ik_position, plane_angle, prev_angles)
            distance = np.linalg.norm(self.global_p[chain.effector] - ik_position, axis=-1)
            improved = active & (distance < best)
            best = np.where(improved, distance, best)
            for slot, bone in enumerate(links):
                saved[slot][improved] = self.ik_q[bone][improved]
            worse = active & ~improved
            if np.any(worse):
                for slot, bone in enumerate(links):
                    self.ik_q[bone][worse] = saved[slot][worse]
                    self.refresh_local(bone)
                self.refresh_global(chain.affected)
                active &= ~worse
        self.refresh_global(chain.affected)

    def _solve_two_bone(self, chain: _Chain, enabled: np.ndarray) -> np.ndarray:
        """Closed-form solve of a standard leg chain [hinge knee, free thigh].

        CCD stalls when the leg starts straight with the target on the leg
        line (a crouch from the rest pose: the knee sees a near-zero angle, so
        40 iterations bend it only a few degrees and the foot floats). This
        solves the exact hinge angle for the hip-to-target distance, using the
        real rest offsets, then aims the thigh with the minimal rotation from
        its FK pose. Where CCD does converge it lands on nearly the same pose
        (the knee swivel differs by under a degree on average). Returns the
        frames that still need CCD (degenerate geometry only)."""
        hinge, free = chain.links
        knee, thigh, effector = hinge.bone, free.bone, chain.effector
        axis_index = hinge.plane_axis
        i, j = (axis_index + 1) % 3, (axis_index + 2) % 3
        frames = np.nonzero(enabled)[0]

        knee_offset = self.local_t[knee][frames]  # knee origin in the thigh frame
        foot_offset = self.local_t[effector][frames]  # effector origin in the knee frame
        target = self.global_p[chain.ik_bone][frames]
        hip = self.global_p[thigh][frames]
        span_sq = np.sum((target - hip) ** 2, axis=-1)

        # |knee + R(theta) foot|^2 = base + 2 (A cos theta + B sin theta)
        a_term = knee_offset[:, i] * foot_offset[:, i] + knee_offset[:, j] * foot_offset[:, j]
        b_term = knee_offset[:, j] * foot_offset[:, i] - knee_offset[:, i] * foot_offset[:, j]
        base = np.sum(knee_offset ** 2, axis=-1) + np.sum(foot_offset ** 2, axis=-1) + 2.0 * knee_offset[:, axis_index] * foot_offset[:, axis_index]
        radius = np.hypot(a_term, b_term)
        solvable = radius > 1e-9
        leftover = np.zeros_like(enabled)
        leftover[frames[~solvable]] = True
        if not np.any(solvable):
            return leftover
        frames = frames[solvable]
        knee_offset, foot_offset, target, hip = knee_offset[solvable], foot_offset[solvable], target[solvable], hip[solvable]
        span_sq, a_term, b_term, base, radius = span_sq[solvable], a_term[solvable], b_term[solvable], base[solvable], radius[solvable]

        phase = np.arctan2(b_term, a_term)
        spread = np.arccos(np.clip((span_sq - base) / (2.0 * radius), -1.0, 1.0))
        lower, upper = float(hinge.lower[axis_index]), float(hinge.upper[axis_index])
        middle = 0.5 * (lower + upper)

        def fit(theta: np.ndarray) -> np.ndarray:
            # Equivalent angle nearest the limit range, then clamp into it.
            theta = theta + 2.0 * math.pi * np.round((middle - theta) / (2.0 * math.pi))
            return np.clip(theta, lower, upper)

        def reach_error(theta: np.ndarray) -> np.ndarray:
            reach_sq = np.maximum(base + 2.0 * (a_term * np.cos(theta) + b_term * np.sin(theta)), 0.0)
            return np.abs(np.sqrt(reach_sq) - np.sqrt(span_sq))

        first, second = fit(phase + spread), fit(phase - spread)
        err_first, err_second = reach_error(first), reach_error(second)
        tie = np.abs(err_first - err_second) <= 1e-9
        pick_first = np.where(tie, np.abs(first - middle) <= np.abs(second - middle), err_first < err_second)
        theta = np.where(pick_first, first, second)

        axis = np.zeros((len(frames), 3))
        axis[:, axis_index] = 1.0
        knee_rotation = q_from_axis_angle(axis, theta)
        self._set_link_rotation(knee, knee_rotation, frames)

        # Aim the thigh: minimal rotation taking the (re-bent) foot direction
        # onto the target direction, in the thigh's own frame.
        thigh_q = self.global_q[thigh][frames]
        foot_local, _ = _normalize_vectors(knee_offset + q_rotate(knee_rotation, foot_offset))
        target_local, target_len = _normalize_vectors(q_rotate(q_conj(thigh_q), target - hip))
        dot = np.clip(np.sum(foot_local * target_local, axis=-1), -1.0, 1.0)
        cross, cross_len = _normalize_vectors(_cross(foot_local, target_local))
        aim = _identity(len(frames))
        turn = (cross_len > 1e-12) & (target_len > 1e-9)
        if np.any(turn):
            aim[turn] = q_from_axis_angle(cross[turn], np.arccos(dot[turn]))
        flipped = (cross_len <= 1e-12) & (dot < 0.0) & (target_len > 1e-9)
        if np.any(flipped):
            # Exactly opposite: half turn about any axis perpendicular to the foot.
            helper = np.where(np.abs(foot_local[flipped, 0:1]) < 0.9, [[1.0, 0.0, 0.0]], [[0.0, 1.0, 0.0]])
            perpendicular, _ = _normalize_vectors(_cross(foot_local[flipped], helper))
            aim[flipped] = q_from_axis_angle(perpendicular, np.full(int(np.sum(flipped)), math.pi))
        thigh_rotation = q_mul(self.anim_q[thigh][frames], aim)
        self._set_link_rotation(thigh, thigh_rotation, frames)

        self.refresh_local(knee)
        self.refresh_local(thigh)
        self.refresh_global(chain.affected)
        return leftover

    def _solve_link(
        self,
        chain: _Chain,
        position: int,
        link: _Link,
        iteration: int,
        active: np.ndarray,
        ik_position: np.ndarray,
        plane_angle: np.ndarray,
        prev_angles: np.ndarray,
    ) -> None:
        bone = link.bone
        inv_q = q_conj(self.global_q[bone])
        origin = self.global_p[bone]
        effector_local, effector_len = _normalize_vectors(q_rotate(inv_q, self.global_p[chain.effector] - origin))
        target_local, target_len = _normalize_vectors(q_rotate(inv_q, ik_position - origin))
        valid = active & (effector_len > 1e-9) & (target_len > 1e-9)
        dot = np.clip(np.sum(effector_local * target_local, axis=-1), -1.0, 1.0)
        angle = np.minimum(np.arccos(dot), chain.unit_angle)

        if link.plane_axis >= 0:
            axis_index = link.plane_axis
            axis = np.zeros((self.count, 3))
            axis[:, axis_index] = 1.0
            rotated_pos = q_rotate(q_from_axis_angle(axis, angle), effector_local)
            rotated_neg = q_rotate(q_from_axis_angle(axis, -angle), effector_local)
            dot_pos = np.sum(rotated_pos * target_local, axis=-1)
            dot_neg = np.sum(rotated_neg * target_local, axis=-1)
            new_angle = plane_angle[position] + np.where(dot_pos > dot_neg, angle, -angle)
            lower = link.lower[axis_index]
            upper = link.upper[axis_index]
            if iteration == 0:
                outside = (new_angle < lower) | (new_angle > upper)
                mirror_ok = (-new_angle > lower) & (-new_angle < upper)
                half = 0.5 * (lower + upper)
                flip = outside & (mirror_ok | (np.abs(half - new_angle) > np.abs(half + new_angle)))
                new_angle = np.where(flip, -new_angle, new_angle)
            new_angle = np.clip(new_angle, lower, upper)
            plane_angle[position] = np.where(valid, new_angle, plane_angle[position])
            selected = np.nonzero(valid)[0]
            if len(selected) == 0:
                return
            rotation = q_from_axis_angle(axis[selected], new_angle[selected])
        else:
            selected = np.nonzero(valid & (np.degrees(angle) >= 1e-3))[0]
            if len(selected) == 0:
                return
            cross, cross_len = _normalize_vectors(_cross(effector_local[selected], target_local[selected]))
            keep = cross_len > 1e-12
            selected = selected[keep]
            if len(selected) == 0:
                return
            step = q_from_axis_angle(cross[keep], angle[selected])
            current = self.anim_q[bone][selected]
            if self.has_ik[bone]:
                current = q_mul(self.ik_q[bone][selected], current)
            rotation = q_mul(current, step)
            if link.lower is not None:
                before = prev_angles[position][selected]
                angles = _decompose_xyz(q_to_matrix(rotation), before)
                angles = np.clip(angles, link.lower, link.upper)
                angles = np.clip(angles - before, -chain.unit_angle, chain.unit_angle) + before
                prev_angles[position][selected] = angles
                rotation = _quat_from_xyz(angles)
        self._set_link_rotation(bone, rotation, selected)
        self.refresh_local(bone)
        self.refresh_global(chain.link_paths[position])


def evaluate_frames(
    model: BakeModel,
    tracks: dict[int, _Track],
    frames: np.ndarray,
    ik_masks: dict[int, np.ndarray],
    nlerp: bool = False,
    analytic_legs: bool = True,
) -> _Pose:
    """MMD bone update for a batch of frames: local transforms, global
    transforms, then append and IK in transform order, then a final global
    pass (no physics)."""
    pose = _Pose(model, len(frames), analytic_legs=analytic_legs)
    for bone, track in tracks.items():
        location, rotation = _sample_track(track, frames, nlerp)
        pose.anim_t[bone] = location
        pose.anim_q[bone] = rotation
        pose.local_q[bone] = rotation
        pose.local_t[bone] = model.rest_offset[bone] + location
    pose.refresh_global(model.hierarchy_order)
    for bone in model.transform_order:
        spec = model.appends.get(bone)
        if spec is not None:
            pose.apply_append(bone, spec)
        chain = model.chains.get(bone)
        if chain is not None:
            pose.solve_ik(chain, ik_masks[bone])
    pose.refresh_global(model.hierarchy_order)
    return pose


# --------------------------------------------------------------------------
# Ground unification: cancel stage placement heights (platforms, risers,
# drops between scenes) so the character dances on one floor level.
# --------------------------------------------------------------------------
def ground_contact_bones(model: BakeModel) -> list[int]:
    index = {name: bone for bone, name in enumerate(model.names)}
    return [index[name] for name in GROUND_CONTACT_BONES if name in index]


def ground_rest_height(model: BakeModel, contacts: list[int]) -> float:
    """Height of the lowest contact bone in the rest pose: where the floor is."""
    return float(model.rest_position[contacts, 1].min())


def lowest_contact_heights(pose: _Pose, contacts: list[int]) -> np.ndarray:
    return pose.global_p[contacts][:, :, 1].min(axis=0)


def _sliding_reduce(values: np.ndarray, half: int, reducer: Callable) -> np.ndarray:
    padded = np.pad(values, half, mode="edge")
    return reducer(np.lib.stride_tricks.sliding_window_view(padded, 2 * half + 1), axis=1)


def _gaussian_smooth(values: np.ndarray, sigma: float) -> np.ndarray:
    radius = int(math.ceil(3.0 * sigma))
    if sigma <= 0 or radius < 1 or len(values) < 2:
        return values.copy()
    taps = np.arange(-radius, radius + 1, dtype=np.float64)
    kernel = np.exp(-0.5 * (taps / sigma) ** 2)
    kernel /= kernel.sum()
    padded = np.pad(values, radius, mode="edge")
    return np.convolve(padded, kernel, mode="valid")


def ground_offsets(
    lowest: np.ndarray,
    rest_height: float,
    airborne_frames: int = GROUND_AIRBORNE_FRAMES,
    cut_step: float = GROUND_CUT_STEP,
    smooth_sigma: float = GROUND_SMOOTH_SIGMA,
    pose_cuts=(),
) -> np.ndarray:
    """Per-frame height (MMD units) to subtract from the whole character so its
    ground contact stays on the rest-pose floor.

    The floor under the character is the morphological opening of the lowest
    contact height: it ignores upward spikes shorter than 2*airborne_frames+1
    frames (jumps keep their height) but follows steps and slopes exactly
    (scene-cut platform changes, risers, drops). Changes slower than cut_step
    per frame are smoothed so support switches between the feet do not pop;
    the smoothing never spans a scene cut (pose_cuts, indices into lowest),
    where a smaller platform change would otherwise leak into the shots
    around it.
    """
    lowest = np.asarray(lowest, dtype=np.float64)
    if lowest.size == 0:
        return np.zeros(0)
    half = max(0, int(airborne_frames))
    floor = _sliding_reduce(_sliding_reduce(lowest, half, np.min), half, np.max) if half else lowest.copy()
    cuts = np.flatnonzero(np.abs(np.diff(floor)) > cut_step) + 1
    if len(pose_cuts):
        cuts = np.union1d(cuts, np.asarray(pose_cuts, dtype=np.int64))
    smoothed = np.empty_like(floor)
    for run in np.split(np.arange(len(floor)), cuts):
        smoothed[run] = _gaussian_smooth(floor[run], smooth_sigma)
    return smoothed - rest_height


def compute_ground_offsets(
    bones: list,
    vmd,
    frame_start: int,
    frame_end: int,
    *,
    disable_ik: bool = False,
    nlerp: bool = False,
    analytic_legs: bool = True,
) -> np.ndarray | None:
    """ground_offsets for frames frame_start..frame_end of `vmd` on `bones`,
    evaluated exactly as bake_motion does; None when the model has none of the
    standard contact bones."""
    model = prepare_model(bones)
    contacts = ground_contact_bones(model)
    if not contacts:
        return None
    tracks, _ = build_tracks(model, vmd.bone_frames)
    all_frames = np.arange(frame_start, frame_end + 1, dtype=np.float64)
    masks = ik_enabled_masks(model, vmd.property_frames, all_frames, disable_all=disable_ik)
    placement = placement_bone(model)
    lowest, placements = [], []
    for start in range(0, len(all_frames), CHUNK_FRAMES):
        stop = min(len(all_frames), start + CHUNK_FRAMES)
        pose = evaluate_frames(
            model,
            tracks,
            all_frames[start:stop],
            {ik: mask[start:stop] for ik, mask in masks.items()},
            nlerp=nlerp,
            analytic_legs=analytic_legs,
        )
        lowest.append(lowest_contact_heights(pose, contacts))
        placements.append(pose.global_p[placement])
    return ground_offsets(np.concatenate(lowest), ground_rest_height(model, contacts), pose_cuts=placement_cuts(placements))


def ground_offset_at(offsets, frame_start: int, frame: float) -> float:
    """Linearly interpolated offset at a (fractional) frame, held past the ends."""
    if offsets is None or len(offsets) == 0:
        return 0.0
    position = min(max(float(frame) - frame_start, 0.0), float(len(offsets) - 1))
    low = int(math.floor(position))
    high = min(low + 1, len(offsets) - 1)
    fraction = position - low
    return float(offsets[low] + (offsets[high] - offsets[low]) * fraction)


# --------------------------------------------------------------------------
# Scene cuts: one-frame jumps of the character's placement (see CUT_MIN_STEP).
# --------------------------------------------------------------------------
def detect_pose_cuts(
    positions,
    min_step: float = CUT_MIN_STEP,
    ratio: float = CUT_RATIO,
    neighbours: int = CUT_NEIGHBOURS,
) -> list[int]:
    """Row indices i where positions[i] (one row per frame, Source units)
    jumps from positions[i - 1]."""
    positions = np.asarray(positions, dtype=np.float64)
    if positions.ndim != 2 or len(positions) < 2:
        return []
    step = np.zeros(len(positions))
    step[1:] = np.linalg.norm(np.diff(positions, axis=0), axis=1)
    window = np.lib.stride_tricks.sliding_window_view
    before = window(np.pad(step, (neighbours, 0)), neighbours)[:-1]
    after = window(np.pad(step, (0, neighbours)), neighbours)[1:]
    # The median, not the largest: two cuts a few frames apart (out and back,
    # or a cut drawn over two frames) must not hide each other.
    typical = np.median(np.concatenate((before, after), axis=1), axis=1)
    jumps = (step > min_step) & (step > ratio * typical)
    return [int(i) for i in np.flatnonzero(jumps)]


def placement_bone(model: BakeModel) -> int:
    index = {name: bone for bone, name in enumerate(model.names)}
    return next((index[name] for name in PLACEMENT_BONES if name in index), 0)


def placement_cuts(chunks: list[np.ndarray]) -> list[int]:
    """Scene cuts (frame indices) in the placement bone's world positions,
    given per bake chunk in MMD units."""
    if not chunks:
        return []
    return detect_pose_cuts(np.concatenate(chunks) * (MMD_TO_BLENDER_SCALE * BLENDER_TO_SOURCE_POSITION_SCALE))


def document_pose_cuts(document: dict) -> list[int]:
    """Scene cut frames of a parent-corrected rotation document, read from its
    pelvis track: for documents baked through Blender or before cuts were
    recorded."""
    pelvis = next(
        (track for track in document.get("bones") or [] if track.get("role") == "pelvis_global" or track.get("g") == SOURCE_PELVIS),
        None,
    )
    keys = pelvis.get("k") if pelvis else None
    if not keys:
        return []
    start = int(document.get("frame_start", keys[0][0]))
    end = int(document.get("frame_end", keys[-1][0]))
    frames = np.arange(start, end + 1, dtype=np.float64)
    key_frames = [float(k[0]) for k in keys]
    # Compaction keeps the last frame of every hold, so linear interpolation restores each baked frame.
    positions = np.stack([np.interp(frames, key_frames, [float(k[column]) for k in keys]) for column in (4, 5, 6)], axis=-1)
    return [start + i for i in detect_pose_cuts(positions)]


# --------------------------------------------------------------------------
# Parent-corrected export (mirrors the old Blender-side exporter).
# --------------------------------------------------------------------------
def strip_blender_collision_suffix(name: str) -> str:
    if len(name) > 4 and name[-4] in "._" and name[-3:].isdigit():
        return name[:-4]
    return name


def target_bone_for(source_name: str, role: str) -> str:
    if source_name:
        return source_name
    if role in PRE_PELVIS_ROLES:
        return SOURCE_PELVIS
    return ""


def bone_target_info(name: str, bone_map: dict[str, tuple[str, str]]) -> tuple[str, str, str]:
    source_name, role = bone_map.get(name, ("", ""))
    if not source_name and not role:
        source_name, role = bone_map.get(strip_blender_collision_suffix(name), ("", ""))
    return source_name, role, target_bone_for(source_name, role)


def _blender_quaternion(q: np.ndarray) -> np.ndarray:
    """MMD-space rotation -> Blender armature space. mmd_tools maps MMD
    (x, y, z) to Blender (x, z, y); a mirror, so the axis also flips sign."""
    return np.stack((-q[..., 0], -q[..., 2], -q[..., 1], q[..., 3]), axis=-1)


def _extrinsic_xyz_degrees(q_blender: np.ndarray) -> np.ndarray:
    """Fixed-axis XYZ decomposition, R = Rz(z) @ Ry(y) @ Rx(x), rounded like
    the Blender exporter (6 decimals, ROTATION_EPSILON snapped to zero)."""
    m = q_to_matrix(q_normalize(q_blender))
    sy = np.clip(-m[:, 2, 0], -1.0, 1.0)
    y = np.arcsin(sy)
    cy = np.cos(y)
    regular = np.abs(cy) > 1e-8
    x = np.where(regular, np.arctan2(m[:, 2, 1], m[:, 2, 2]), np.where(sy > 0, np.arctan2(m[:, 0, 1], m[:, 1, 1]), np.arctan2(-m[:, 0, 1], m[:, 1, 1])))
    z = np.where(regular, np.arctan2(m[:, 1, 0], m[:, 0, 0]), 0.0)
    out = np.degrees(np.stack((x, y, z), axis=-1))
    out = np.where(np.abs(out) < 1e-9, 0.0, out)
    out = np.round(out, 6)
    return np.where(np.abs(out) < ROTATION_EPSILON_DEGREES, 0.0, out)


def _source_position(delta_mmd: np.ndarray, flip_forward: bool = False) -> np.ndarray:
    """MMD-space offset -> the Blender exporter's GMod bone-position columns:
    (Blender y, Blender x, Blender z) * 41.78, i.e. (MMD z, MMD x, MMD y)."""
    scale = MMD_TO_BLENDER_SCALE * BLENDER_TO_SOURCE_POSITION_SCALE
    out = np.stack((delta_mmd[:, 2], delta_mmd[:, 0], delta_mmd[:, 1]), axis=-1) * scale
    out = np.where(np.abs(out) < POSITION_EPSILON_SOURCE_UNITS, 0.0, out)
    out = np.round(out, 6)
    out = np.where(np.abs(out) < POSITION_EPSILON_SOURCE_UNITS, 0.0, out)
    if flip_forward:
        out[:, 0] = np.where(out[:, 0] == 0.0, 0.0, -out[:, 0])
    return out


@dataclass
class _OutputTrack:
    bone: int
    name: str
    target: str
    role: str
    mode: str  # "parent", "pelvis", "override", "override_rotation"
    reference: int  # parent (or Source parent override) bone, -1 for none
    samples: list[np.ndarray] = field(default_factory=list)


def _plan_output_tracks(model: BakeModel, bone_map: dict[str, tuple[str, str]]) -> list[_OutputTrack]:
    mapped: list[tuple[int, str, str, str]] = []
    source_parent: dict[str, int] = {}
    for index, name in enumerate(model.blender_names):
        source_name, role, target = bone_target_info(name, bone_map)
        if source_name and target and role not in PRE_PELVIS_ROLES:
            source_parent.setdefault(target, index)
        if target and role not in PRE_PELVIS_ROLES:
            mapped.append((index, source_name, role, target))

    plans: list[_OutputTrack] = []
    for index, source_name, role, target in mapped:
        name = model.blender_names[index]
        if source_name == SOURCE_PELVIS:
            plans.append(_OutputTrack(index, name, target, "pelvis_global", "pelvis", -1))
        elif source_name in SOURCE_PARENT_OVERRIDES and SOURCE_PARENT_OVERRIDES[source_name] in source_parent:
            mode = "override_rotation" if source_name == SOURCE_SPINE else "override"
            plans.append(_OutputTrack(index, name, target, "source_parent_override", mode, source_parent[SOURCE_PARENT_OVERRIDES[source_name]]))
        else:
            plans.append(_OutputTrack(index, name, target, role, "parent", model.parent[index]))
    return plans


def _track_samples(model: BakeModel, pose: _Pose, plan: _OutputTrack) -> np.ndarray:
    current = pose.global_q[plan.bone]
    position = np.zeros((pose.count, 3))
    if plan.mode == "pelvis":
        delta = current
        position = _source_position(pose.global_p[plan.bone] - model.rest_position[plan.bone], flip_forward=True)
    elif plan.reference >= 0:
        delta = q_mul(current, q_conj(pose.global_q[plan.reference]))
        if plan.mode == "override":
            # Move the Source child back onto the baked MMD child origin.
            ref = plan.reference
            rest_offset = model.rest_position[plan.bone] - model.rest_position[ref]
            predicted = pose.global_p[ref] + q_rotate(pose.global_q[ref], np.broadcast_to(rest_offset, (pose.count, 3)))
            position = _source_position(pose.global_p[plan.bone] - predicted)
    else:
        delta = current
    rotation = _extrinsic_xyz_degrees(_blender_quaternion(delta))
    return np.concatenate((rotation, position), axis=1)


def _lower_pelvis_tracks(plans: list[_OutputTrack], offsets_mmd: np.ndarray) -> None:
    """Move the whole character down by offsets_mmd (per frame, MMD units).
    Only the pelvis track carries a world position - every other track is
    parent-relative - so shifting its vertical column moves the full body."""
    scale = MMD_TO_BLENDER_SCALE * BLENDER_TO_SOURCE_POSITION_SCALE
    for plan in plans:
        if plan.mode != "pelvis" or not plan.samples:
            continue
        samples = np.concatenate(plan.samples, axis=0)
        # Pelvis position columns are (MMD z, MMD x, MMD y) * scale; see _source_position.
        height = samples[:, 5] - offsets_mmd[: len(samples)] * scale
        height = np.where(np.abs(height) < POSITION_EPSILON_SOURCE_UNITS, 0.0, np.round(height, 6))
        samples[:, 5] = np.where(np.abs(height) < POSITION_EPSILON_SOURCE_UNITS, 0.0, height)
        plan.samples = [samples]


def _pelvis_cut_frames(plans: list[_OutputTrack], frame_start: int) -> list[int]:
    """Scene cuts of the exported pelvis track, as VMD frames: after ground
    unification, which can remove a cut or shrink it."""
    for plan in plans:
        if plan.mode == "pelvis" and plan.samples:
            return [frame_start + i for i in detect_pose_cuts(np.concatenate(plan.samples, axis=0)[:, 3:6])]
    return []


def _values_equal(a: tuple, b: tuple) -> bool:
    for index in range(len(a)):
        epsilon = ROTATION_EPSILON_DEGREES if index < 3 else POSITION_EPSILON_SOURCE_UNITS
        if abs(a[index] - b[index]) > epsilon:
            return False
    return True


def compact_keyframes(frames: list[int], values: list[tuple]) -> list[list[float]]:
    """Drop held samples but keep the last frame of every hold, so linear
    playback between kept keys reproduces each baked frame."""
    if not frames:
        return []
    keys: list[list[float]] = []
    last_added: tuple | None = None
    previous_frame: int | None = None
    previous_value: tuple | None = None
    for frame, value in zip(frames, values):
        if last_added is None:
            keys.append([frame, *value])
            last_added = value
        elif not _values_equal(value, last_added):
            if previous_frame is not None and previous_value is not None and keys[-1][0] != previous_frame and _values_equal(previous_value, last_added):
                keys.append([previous_frame, *previous_value])
            keys.append([frame, *value])
            last_added = value
        previous_frame = frame
        previous_value = value
    if keys[-1][0] != frames[-1]:
        keys.append([frames[-1], *values[-1]])
    return keys


def _is_zero_transform(value: tuple) -> bool:
    return all(abs(v) <= ROTATION_EPSILON_DEGREES for v in value[:3]) and all(abs(v) <= POSITION_EPSILON_SOURCE_UNITS for v in value[3:])


def bake_motion(
    bones: list,
    vmd,
    bone_map: dict[str, tuple[str, str]],
    frame_start: int,
    frame_end: int,
    *,
    model_path: Path | str = "",
    input_vmd: Path | str = "",
    disable_ik: bool = False,
    nlerp: bool = False,
    analytic_legs: bool = True,
    unify_ground: bool = False,
    progress: ProgressCallback | None = None,
    cancel_check: CancelCheck | None = None,
) -> dict:
    """Bake `vmd` (import_vmd.ParsedVMD) on `bones` (import_vmd.PMXBone list)
    and return the parent-corrected rotation document.

    unify_ground keeps the character's ground contact on one floor level
    (see ground_offsets). The per-frame offsets that were removed are returned
    in the document's private "_ground_offsets_mmd" list so an imported camera
    can be shifted by the same amount; write_motion_json drops that key."""

    def emit(message: str) -> None:
        if progress:
            progress(message)

    if frame_end < frame_start:
        raise ValueError("frame_end must be greater than or equal to frame_start")

    model = prepare_model(bones)
    for warning in model.warnings:
        emit(f"Warning: {warning}")
    tracks, unmatched = build_tracks(model, vmd.bone_frames)
    if unmatched:
        preview = ", ".join(unmatched[:8]) + (" ..." if len(unmatched) > 8 else "")
        emit(f"{len(unmatched)} VMD bone track(s) have no matching model bone: {preview}")
    emit(f"Loaded motion: {len(tracks)} animated bone(s), {len(model.chains)} IK chain(s), {len(model.appends)} append bone(s)")

    plans = _plan_output_tracks(model, bone_map)
    all_frames = np.arange(frame_start, frame_end + 1, dtype=np.float64)
    masks = ik_enabled_masks(model, vmd.property_frames, all_frames, disable_all=disable_ik)
    if disable_ik:
        emit("Foot IK disabled for this bake (motion authored without IK).")
    contacts = ground_contact_bones(model) if unify_ground else []
    if unify_ground and not contacts:
        emit("Warning: ground unification skipped: the model has none of the standard foot/leg bones.")
    placement = placement_bone(model)
    lowest_chunks: list[np.ndarray] = []
    placement_chunks: list[np.ndarray] = []

    total = len(all_frames)
    emit(f"Baking pose frames {frame_start}..{frame_end} ({total} frames).")
    for start in range(0, total, CHUNK_FRAMES):
        if cancel_check and cancel_check():
            raise BakeCancelled("VMD bake was cancelled")
        stop = min(total, start + CHUNK_FRAMES)
        chunk = all_frames[start:stop]
        pose = evaluate_frames(
            model,
            tracks,
            chunk,
            {ik: mask[start:stop] for ik, mask in masks.items()},
            nlerp=nlerp,
            analytic_legs=analytic_legs,
        )
        for plan in plans:
            plan.samples.append(_track_samples(model, pose, plan))
        if contacts:
            lowest_chunks.append(lowest_contact_heights(pose, contacts))
        placement_chunks.append(pose.global_p[placement])
        emit(f"Baked frames {frame_start + start}..{frame_start + stop - 1} of {frame_end}")

    ground = None
    if contacts:
        ground = ground_offsets(np.concatenate(lowest_chunks), ground_rest_height(model, contacts), pose_cuts=placement_cuts(placement_chunks))
        _lower_pelvis_tracks(plans, ground)
        lifted = float(np.abs(ground).max()) if len(ground) else 0.0
        emit(
            f"Unified ground height: shifted the character by up to {lifted:.2f} MMD units "
            f"({lifted * MMD_TO_BLENDER_SCALE:.2f} m) to keep it on one floor level."
        )
    cut_frames = _pelvis_cut_frames(plans, frame_start)
    if cut_frames:
        preview = ", ".join(str(frame) for frame in cut_frames[:12]) + (" ..." if len(cut_frames) > 12 else "")
        emit(f"Scene cuts (the character jumps to another spot in one frame): {len(cut_frames)} at frame(s) {preview}")

    emit("Exporting parent-corrected bone rotations.")
    frame_list = [int(frame) for frame in all_frames.tolist()]
    target_groups: dict[str, list[tuple[float, int, dict]]] = {}
    identity_tracks = 0
    for plan in plans:
        samples = np.concatenate(plan.samples, axis=0) if plan.samples else np.zeros((0, 6))
        values = [tuple(row) for row in samples.tolist()]
        if not any(not _is_zero_transform(value) for value in values):
            identity_tracks += 1
        keys = compact_keyframes(frame_list, values)
        if not keys:
            continue
        entry = {"m": plan.name, "g": plan.target, "k": keys}
        if plan.role:
            entry["role"] = plan.role
        score = float(np.abs(samples[:, :3]).sum())
        target_groups.setdefault(plan.target, []).append((score, len(keys), entry))

    bones_out = []
    duplicate_targets = 0
    for target in sorted(target_groups):
        candidates = target_groups[target]
        duplicate_targets += len(candidates) - 1
        candidates.sort(key=lambda item: (item[0], item[1], str(item[2].get("m", ""))), reverse=True)
        bones_out.append(candidates[0][2])

    model_path = Path(model_path) if model_path else Path("model.pmx")
    input_vmd = Path(input_vmd) if input_vmd else Path("motion.vmd")
    document = {
        "format": OUTPUT_FORMAT,
        "armature": f"{model_path.stem}_arm",
        "input_vmd": str(input_vmd),
        "mmd_model": str(model_path),
        "space": "ARMATURE_OBJECT",
        "axis": ["+X model left", "+Y model front", "+Z model top"],
        "order": "fixed_xyz_extrinsic",
        "matrix_order": "Rz @ Ry @ Rx",
        "units": "degrees",
        "position_units": "source_units",
        "columns": ["frame", "x_deg", "y_deg", "z_deg", "pos_x", "pos_y", "pos_z"],
        "pelvis_track": "global_lower_body_includes_mmd_root_center_groove_waist",
        "hierarchy_overrides": dict(SOURCE_PARENT_OVERRIDES),
        "frame_start": int(frame_start),
        "frame_end": int(frame_end),
        "frame_count": int(frame_end - frame_start + 1),
        "fps": VMD_FPS,
        "cuts": cut_frames,
        "source_bone_map_count": len(bone_map),
        "mapped_track_count": len(plans),
        "identity_track_count": identity_tracks,
        "duplicate_target_count": duplicate_targets,
        "bone_count": len(bones_out),
        "bones": bones_out,
        "baker": "native",
    }
    if ground is not None:
        document["ground_unified"] = True
        document["ground_offset_range_mmd"] = [round(float(ground.min()), 4), round(float(ground.max()), 4)]
        document["_ground_offsets_mmd"] = [round(float(value), 5) for value in ground]
    emit(f"Exported parent-corrected bone rotations: {len(bones_out)} bone track(s).")
    return document
