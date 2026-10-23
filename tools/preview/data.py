"""PMX/VMD data preparation for the embedded importer preview.

This module keeps the preview independent from Blender while still parsing the
PMX data needed for a useful real-time viewer: mesh buffers, materials,
textures, vertex/group morphs, and IK chains. The widget owns rendering and
per-frame pose evaluation.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

try:
    from tools import import_vmd, vmd_baker
except ModuleNotFoundError:  # running from tools/ as a bundled script
    import import_vmd  # type: ignore[no-redef]
    import vmd_baker  # type: ignore[no-redef]


ROOT_MOTION_NAMES = {
    "\u5168\u3066\u306e\u89aa",  # all parent
    "\u30bb\u30f3\u30bf\u30fc",  # center
    "\u30b0\u30eb\u30fc\u30d6",  # groove
    "\u4e0b\u534a\u8eab",  # lower body
    "mother",
    "center",
    "groove",
    "lower body",
}

MORPH_TYPE_GROUP = 0
MORPH_TYPE_VERTEX = 1
MORPH_TYPE_BONE = 2
MORPH_TYPE_UV_MIN = 3
MORPH_TYPE_UV_MAX = 7
MORPH_TYPE_MATERIAL = 8
MORPH_TYPE_FLIP = 9
MORPH_TYPE_IMPULSE = 10


@dataclass
class PreviewIKLink:
    bone_index: int
    has_limits: bool
    min_angle: tuple[float, float, float]
    max_angle: tuple[float, float, float]


@dataclass
class PreviewIK:
    target_index: int
    iterations: int
    limit_radian: float
    links: list[PreviewIKLink]


@dataclass
class PreviewBone:
    name: str
    english_name: str
    parent: int
    position: tuple[float, float, float]
    ik: PreviewIK | None = None


@dataclass
class PreviewVertex:
    position: tuple[float, float, float]
    normal: tuple[float, float, float]
    uv: tuple[float, float]
    bone_indices: tuple[int, int, int, int]
    bone_weights: tuple[float, float, float, float]


@dataclass
class PreviewMaterial:
    name: str
    diffuse: tuple[float, float, float, float]
    texture_path: Path | None
    index_start: int
    index_count: int


@dataclass
class PreviewMesh:
    vertices: list[PreviewVertex]
    indices: list[int]
    materials: list[PreviewMaterial]


@dataclass
class PreviewMorph:
    name: str
    english_name: str
    morph_type: int
    vertex_offsets: list[tuple[int, tuple[float, float, float]]] = field(default_factory=list)
    group_offsets: list[tuple[int, float]] = field(default_factory=list)


@dataclass
class PreviewMorphTrack:
    morph_index: int
    name: str
    frames: list[import_vmd.MorphFrame]


@dataclass
class PreviewScene:
    model_path: Path
    body_vmd_path: Path
    flex_vmd_paths: list[Path]
    music_path: Path | None
    bones: list[PreviewBone]
    mesh: PreviewMesh | None
    textures: list[Path]
    bone_tracks: dict[int, list[import_vmd.BoneFrame]]
    morphs: list[PreviewMorph]
    morph_tracks: dict[int, PreviewMorphTrack]
    property_frames: list[import_vmd.PropertyFrame]
    root_motion_tracks: list[list[import_vmd.BoneFrame]]
    frame_start: int
    frame_end: int
    fps: int
    flex_count: int
    warnings: list[str] = field(default_factory=list)
    camera_vmd_path: Path | None = None
    camera_frames: list[import_vmd.CameraFrame] = field(default_factory=list)
    motion: import_vmd.ParsedVMD | None = None
    # Per-frame heights (MMD units, from frame 0) the import's "unify ground
    # height" option removes; None when the option is off.
    ground_offsets: object | None = None


class PreviewPMXReader(import_vmd.PMXReader):
    def read_vertex_index(self) -> int:
        if self.vertex_index_size == 1:
            return self.unpack("<B")
        if self.vertex_index_size == 2:
            return self.unpack("<H")
        if self.vertex_index_size == 4:
            return self.unpack("<i")
        raise ValueError(f"unsupported PMX vertex index size {self.vertex_index_size}")

    def read_vertices(self) -> list[PreviewVertex]:
        vertices: list[PreviewVertex] = []
        for _ in range(self.unpack("<i")):
            position = self.unpack("<fff")
            normal = self.unpack("<fff")
            uv = self.unpack("<ff")
            self.offset += self.extra_uv * 16
            weight_type = self.unpack("<B")

            bone_indices = [-1, -1, -1, -1]
            bone_weights = [0.0, 0.0, 0.0, 0.0]
            if weight_type == 0:  # BDEF1
                bone_indices[0] = self.read_index(self.bone_index_size)
                bone_weights[0] = 1.0
            elif weight_type == 1:  # BDEF2
                bone_indices[0] = self.read_index(self.bone_index_size)
                bone_indices[1] = self.read_index(self.bone_index_size)
                weight = float(self.unpack("<f"))
                bone_weights[0] = weight
                bone_weights[1] = 1.0 - weight
            elif weight_type in (2, 4):  # BDEF4 / QDEF
                for index in range(4):
                    bone_indices[index] = self.read_index(self.bone_index_size)
                for index in range(4):
                    bone_weights[index] = float(self.unpack("<f"))
            elif weight_type == 3:  # SDEF, previewed as BDEF2
                bone_indices[0] = self.read_index(self.bone_index_size)
                bone_indices[1] = self.read_index(self.bone_index_size)
                weight = float(self.unpack("<f"))
                bone_weights[0] = weight
                bone_weights[1] = 1.0 - weight
                self.offset += 36
            else:
                raise ValueError(f"unsupported PMX weight type {weight_type}")

            self.offset += 4  # edge scale
            total = sum(max(0.0, value) for value in bone_weights)
            if total <= 1e-8:
                bone_indices = [max(0, bone_indices[0]), -1, -1, -1]
                bone_weights = [1.0, 0.0, 0.0, 0.0]
            else:
                bone_weights = [max(0.0, value) / total for value in bone_weights]

            vertices.append(
                PreviewVertex(
                    position=position,
                    normal=normal,
                    uv=uv,
                    bone_indices=tuple(bone_indices),  # type: ignore[arg-type]
                    bone_weights=tuple(bone_weights),  # type: ignore[arg-type]
                )
            )
        return vertices

    def read_faces(self) -> list[int]:
        return [self.read_vertex_index() for _ in range(self.unpack("<i"))]

    def read_textures(self) -> list[str]:
        return [self.read_text() for _ in range(self.unpack("<i"))]

    def read_materials_with_paths(self, model_path: Path, texture_names: list[str]) -> list[PreviewMaterial]:
        texture_files = _texture_files(model_path)
        texture_lookup = {path.name.lower(): path for path in texture_files}
        materials: list[PreviewMaterial] = []
        index_start = 0

        for _ in range(self.unpack("<i")):
            name = self.read_text()
            self.read_text()
            diffuse = self.unpack("<ffff")
            self.offset += 3 * 4 + 4 + 3 * 4 + 1 + 4 * 4 + 4
            texture_index = self.read_index(self.texture_index_size)
            self.read_index(self.texture_index_size)
            self.offset += 1
            if self.unpack("<B") == 0:
                self.read_index(self.texture_index_size)
            else:
                self.offset += 1
            self.read_text()
            index_count = self.unpack("<i")
            materials.append(
                PreviewMaterial(
                    name=name,
                    diffuse=diffuse,
                    texture_path=_resolve_texture_path(model_path, texture_names, texture_index, texture_lookup),
                    index_start=index_start,
                    index_count=index_count,
                )
            )
            index_start += index_count

        return materials

    def read_bones_with_ik(self) -> list[PreviewBone]:
        bones: list[PreviewBone] = []
        for _ in range(self.unpack("<i")):
            name = self.read_text()
            english_name = self.read_text()
            position = self.unpack("<fff")
            parent = self.read_index(self.bone_index_size)
            self.offset += 4  # transform level
            flags = self.unpack("<H")

            if flags & 0x0001:
                self.read_index(self.bone_index_size)
            else:
                self.offset += 12
            if flags & (0x0100 | 0x0200):
                self.read_index(self.bone_index_size)
                self.offset += 4
            if flags & 0x0400:
                self.offset += 12
            if flags & 0x0800:
                self.offset += 24
            if flags & 0x2000:
                self.offset += 4

            ik = None
            if flags & 0x0020:
                target_index = self.read_index(self.bone_index_size)
                iterations = self.unpack("<i")
                limit_radian = float(self.unpack("<f"))
                links: list[PreviewIKLink] = []
                for _ in range(self.unpack("<i")):
                    bone_index = self.read_index(self.bone_index_size)
                    has_limits = self.unpack("<B") != 0
                    min_angle = (0.0, 0.0, 0.0)
                    max_angle = (0.0, 0.0, 0.0)
                    if has_limits:
                        min_angle = self.unpack("<fff")
                        max_angle = self.unpack("<fff")
                    links.append(PreviewIKLink(bone_index, has_limits, min_angle, max_angle))
                ik = PreviewIK(target_index, iterations, limit_radian, links)

            bones.append(PreviewBone(name, english_name, parent, position, ik))
        return bones

    def read_morphs(self, warnings: list[str]) -> list[PreviewMorph]:
        morphs: list[PreviewMorph] = []
        for _ in range(self.unpack("<i")):
            name = self.read_text()
            english_name = self.read_text()
            self.offset += 1  # panel
            morph_type = self.unpack("<B")
            offset_count = self.unpack("<i")
            morph = PreviewMorph(name, english_name, morph_type)

            if morph_type == MORPH_TYPE_GROUP or morph_type == MORPH_TYPE_FLIP:
                for _ in range(offset_count):
                    morph.group_offsets.append((self.read_index(self.morph_index_size), float(self.unpack("<f"))))
            elif morph_type == MORPH_TYPE_VERTEX:
                for _ in range(offset_count):
                    morph.vertex_offsets.append((self.read_vertex_index(), self.unpack("<fff")))
            elif morph_type == MORPH_TYPE_BONE:
                self.offset += offset_count * (self.bone_index_size + 28)
                warnings.append(f'Preview ignores bone morph "{name}"')
            elif MORPH_TYPE_UV_MIN <= morph_type <= MORPH_TYPE_UV_MAX:
                self.offset += offset_count * (self.vertex_index_size + 16)
                warnings.append(f'Preview ignores UV morph "{name}"')
            elif morph_type == MORPH_TYPE_MATERIAL:
                self.offset += offset_count * (self.material_index_size + 1 + 4 * 4 + 3 * 4 + 4 + 3 * 4 + 4 * 4 + 4 + 4 * 4 + 4 * 4 + 4 * 4)
                warnings.append(f'Preview ignores material morph "{name}"')
            elif morph_type == MORPH_TYPE_IMPULSE:
                self.offset += offset_count * (self.rigidbody_index_size + 1 + 24)
                warnings.append(f'Preview ignores impulse morph "{name}"')
            else:
                raise ValueError(f"unsupported PMX morph type {morph_type} for {name}")

            morphs.append(morph)
        return morphs


def _texture_files(model_path: Path) -> list[Path]:
    root = model_path.parent
    texture_root = root / "textures"
    exts = {".png", ".jpg", ".jpeg", ".bmp", ".tga", ".dds"}
    out: list[Path] = []
    for base in (root, texture_root):
        if base.exists():
            out.extend(path for path in base.rglob("*") if path.suffix.lower() in exts)
    return sorted(set(out))


def _resolve_texture_path(
    model_path: Path,
    texture_names: list[str],
    texture_index: int,
    texture_lookup: dict[str, Path],
) -> Path | None:
    if texture_index < 0 or texture_index >= len(texture_names):
        return None

    raw = texture_names[texture_index].replace("\\", "/").strip()
    if not raw or raw.startswith("*"):
        return None

    relative = Path(raw)
    candidates = [
        model_path.parent / relative,
        model_path.parent / "textures" / relative.name,
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return texture_lookup.get(relative.name.lower())


def _preview_model(model_path: Path, warnings: list[str]) -> tuple[list[PreviewBone], PreviewMesh, list[PreviewMorph]]:
    reader = PreviewPMXReader(model_path.read_bytes())
    reader.parse_header()
    for _ in range(4):
        reader.read_text()

    vertices = reader.read_vertices()
    face_indices = reader.read_faces()
    texture_names = reader.read_textures()
    materials = reader.read_materials_with_paths(model_path, texture_names)
    bones = reader.read_bones_with_ik()
    morphs = reader.read_morphs(warnings)
    return bones, PreviewMesh(vertices, face_indices, materials), morphs


def _morph_track_merge_key(mmd_name: str, flex_map: dict[str, str]) -> str:
    return flex_map.get(mmd_name, mmd_name)


def _normalized_morph_key(name: str) -> str:
    return "".join(char for char in name.casefold().strip() if char not in " _-.")


def _add_morph_lookup_alias(lookup: dict[str, int], name: str, index: int) -> None:
    if not name:
        return

    clean_name = name.strip()
    if not clean_name:
        return

    lookup.setdefault(clean_name, index)
    normalized = _normalized_morph_key(clean_name)
    if normalized:
        lookup.setdefault(normalized, index)


def _build_reverse_flex_map(flex_map: dict[str, str]) -> dict[str, list[str]]:
    reverse: dict[str, list[str]] = {}
    for mmd_name, source_name in flex_map.items():
        for key in (source_name, _normalized_morph_key(source_name)):
            if not key:
                continue
            reverse.setdefault(key, [])
            if mmd_name not in reverse[key]:
                reverse[key].append(mmd_name)
    return reverse


def _resolve_preview_morph_index(
    name: str,
    morph_lookup: dict[str, int],
    flex_map: dict[str, str],
    reverse_flex_map: dict[str, list[str]],
) -> int | None:
    candidates: list[str] = []
    seen: set[str] = set()

    def add_candidate(value: str | None) -> None:
        if not value:
            return
        clean_value = value.strip()
        if clean_value and clean_value not in seen:
            seen.add(clean_value)
            candidates.append(clean_value)

    add_candidate(name)
    mapped_name = flex_map.get(name)
    normalized_name = _normalized_morph_key(name)
    if mapped_name is None:
        mapped_name = flex_map.get(normalized_name)
    add_candidate(mapped_name)

    for alias in reverse_flex_map.get(name, []):
        add_candidate(alias)
    for alias in reverse_flex_map.get(normalized_name, []):
        add_candidate(alias)
    if mapped_name is not None:
        for alias in reverse_flex_map.get(mapped_name, []):
            add_candidate(alias)
        for alias in reverse_flex_map.get(_normalized_morph_key(mapped_name), []):
            add_candidate(alias)

    for candidate in candidates:
        morph_index = morph_lookup.get(candidate)
        if morph_index is not None:
            return morph_index
        morph_index = morph_lookup.get(_normalized_morph_key(candidate))
        if morph_index is not None:
            return morph_index

    return None


def _merged_vmd_morph_tracks(
    main_motion: import_vmd.ParsedVMD,
    extra_flex_vmd_paths: list[Path],
    warnings: list[str],
) -> dict[str, list[import_vmd.MorphFrame]]:
    try:
        flex_map = import_vmd.load_flex_mapping()
    except Exception:
        flex_map = {}

    out: dict[str, list[import_vmd.MorphFrame]] = {}
    seen: dict[str, tuple[str, bool, str]] = {}

    def add_track(name: str, frames: list[import_vmd.MorphFrame], key: str, source_label: str) -> None:
        meaningful = import_vmd.morph_frames_are_meaningful(frames)
        if key in seen:
            existing_name, existing_meaningful, existing_label = seen[key]
            if meaningful and not existing_meaningful:
                out.pop(existing_name, None)
                out[name] = frames
                seen[key] = (name, True, source_label)
                return
            if meaningful and existing_meaningful:
                out[existing_name] = import_vmd.combine_morph_frames_additive([out.get(existing_name, []), frames])
                warnings.append(f'Added duplicate preview morph "{name}" from {source_label} additively into "{existing_name}"')
                return
            warnings.append(f'Skipped duplicate preview morph "{name}" from {source_label}; "{existing_name}" already supplies {key}')
            return

        out[name] = frames
        seen[key] = (name, meaningful, source_label)

    for name, frames in main_motion.morph_frames.items():
        key = _morph_track_merge_key(name, flex_map)
        add_track(name, frames, key, "main VMD")

    for path in extra_flex_vmd_paths:
        motion = import_vmd.parse_vmd(path)
        for name, frames in motion.morph_frames.items():
            key = _morph_track_merge_key(name, flex_map)
            add_track(name, frames, key, path.name)

    return out


def sample_bone_motion(
    frames: list[import_vmd.BoneFrame] | None,
    frame: float,
) -> tuple[tuple[float, float, float], tuple[float, float, float, float]]:
    if not frames:
        return (0.0, 0.0, 0.0), (0.0, 0.0, 0.0, 1.0)

    a, b, t = import_vmd.find_segment(frames, frame)
    if a is None:
        return (0.0, 0.0, 0.0), (0.0, 0.0, 0.0, 1.0)
    if a is b:
        return a.location, import_vmd.normalize_quat(a.rotation)

    tx = import_vmd.bezier_weight(t, b.interp, 0)
    ty = import_vmd.bezier_weight(t, b.interp, 1)
    tz = import_vmd.bezier_weight(t, b.interp, 2)
    tr = import_vmd.bezier_weight(t, b.interp, 3)
    loc = (
        import_vmd.lerp(a.location[0], b.location[0], tx),
        import_vmd.lerp(a.location[1], b.location[1], ty),
        import_vmd.lerp(a.location[2], b.location[2], tz),
    )
    rot = import_vmd.slerp_quat(a.rotation, b.rotation, tr)
    return loc, rot


def sample_ik_enabled(property_frames: list[import_vmd.PropertyFrame], frame: float) -> dict[str, bool]:
    states: dict[str, bool] = {}
    for prop in sorted(property_frames, key=lambda item: item.frame):
        if prop.frame > frame:
            break
        for name, enabled in prop.ik_states:
            states[name] = enabled
    return states


def preview_ground_offsets(
    model_path: Path,
    motion: import_vmd.ParsedVMD,
    disable_ik: bool = False,
    warnings: list[str] | None = None,
):
    """The same per-frame ground offsets the import bakes with "unify ground
    height", so the preview shows exactly what the import will produce."""
    offsets = vmd_baker.compute_ground_offsets(
        import_vmd.parse_pmx_bones(model_path),
        motion,
        0,
        motion.max_frame,
        disable_ik=disable_ik,
    )
    if offsets is None and warnings is not None:
        warnings.append("Ground unification needs the standard leg bones; showing the original heights")
    return offsets


def load_preview_scene(
    model_path: Path,
    body_vmd_path: Path,
    flex_vmd_paths: list[Path] | None = None,
    music_path: Path | None = None,
    camera_vmd_path: Path | None = None,
    unify_ground: bool = False,
    disable_ik: bool = False,
) -> PreviewScene:
    if not model_path.exists():
        raise FileNotFoundError(model_path)
    if not body_vmd_path.exists():
        raise FileNotFoundError(body_vmd_path)

    warnings: list[str] = []
    motion = import_vmd.parse_vmd(body_vmd_path)

    camera_frames: list[import_vmd.CameraFrame] = []
    if camera_vmd_path:
        if not camera_vmd_path.exists():
            warnings.append(f"Camera VMD not found: {camera_vmd_path}")
        else:
            try:
                camera_frames = import_vmd.parse_vmd(camera_vmd_path).camera_frames
                if not camera_frames:
                    warnings.append(f"No camera frames found in {camera_vmd_path.name}")
            except Exception as exc:
                warnings.append(f"Failed to parse camera VMD {camera_vmd_path.name}: {exc}")
    bones, mesh, morphs = _preview_model(model_path, warnings)
    try:
        flex_map = import_vmd.load_flex_mapping()
    except Exception:
        flex_map = {}
    reverse_flex_map = _build_reverse_flex_map(flex_map)

    bone_tracks: dict[int, list[import_vmd.BoneFrame]] = {}
    for index, bone in enumerate(bones):
        frames = motion.bone_frames.get(bone.name) or motion.bone_frames.get(bone.english_name)
        if frames:
            bone_tracks[index] = frames

    morph_lookup: dict[str, int] = {}
    for index, morph in enumerate(morphs):
        _add_morph_lookup_alias(morph_lookup, morph.name, index)
        _add_morph_lookup_alias(morph_lookup, morph.english_name, index)
    for mmd_name, source_name in flex_map.items():
        morph_index = _resolve_preview_morph_index(mmd_name, morph_lookup, {}, {})
        if morph_index is None:
            morph_index = _resolve_preview_morph_index(source_name, morph_lookup, {}, {})
        if morph_index is None:
            continue
        _add_morph_lookup_alias(morph_lookup, mmd_name, morph_index)
        _add_morph_lookup_alias(morph_lookup, source_name, morph_index)

    flex_paths = [path for path in flex_vmd_paths or [] if path.exists()]
    merged_morphs = _merged_vmd_morph_tracks(motion, flex_paths, warnings)
    morph_tracks: dict[int, PreviewMorphTrack] = {}
    frame_end = motion.max_frame
    for name, frames in merged_morphs.items():
        morph_index = _resolve_preview_morph_index(name, morph_lookup, flex_map, reverse_flex_map)
        if morph_index is None:
            continue
        if morph_index in morph_tracks:
            existing = morph_tracks[morph_index].name
            morph_tracks[morph_index].frames = import_vmd.combine_morph_frames_additive([morph_tracks[morph_index].frames, frames])
            warnings.append(f'Added duplicate preview morph "{name}" additively into "{existing}" for {morphs[morph_index].name}')
            if frames:
                frame_end = max(frame_end, max(frame.frame for frame in frames))
            continue
        if frames:
            frame_end = max(frame_end, max(frame.frame for frame in frames))
        morph_tracks[morph_index] = PreviewMorphTrack(morph_index, morphs[morph_index].name, frames)

    root_tracks = [frames for name, frames in motion.bone_frames.items() if name in ROOT_MOTION_NAMES]
    # The playback length stays the body motion's: in-game playback also ends
    # with the body motion and the camera simply clamps at its last key, so a
    # camera tail past the dance is not previewed either.
    return PreviewScene(
        model_path=model_path,
        body_vmd_path=body_vmd_path,
        flex_vmd_paths=flex_paths,
        music_path=music_path if music_path and music_path.exists() else None,
        bones=bones,
        mesh=mesh,
        textures=_texture_files(model_path),
        bone_tracks=bone_tracks,
        morphs=morphs,
        morph_tracks=morph_tracks,
        property_frames=motion.property_frames,
        root_motion_tracks=root_tracks,
        frame_start=0,
        frame_end=frame_end,
        fps=import_vmd.VMD_FPS,
        flex_count=len(morph_tracks),
        warnings=warnings,
        camera_vmd_path=camera_vmd_path if camera_frames else None,
        camera_frames=camera_frames,
        motion=motion,
        ground_offsets=preview_ground_offsets(model_path, motion, disable_ik, warnings) if unify_ground else None,
    )
