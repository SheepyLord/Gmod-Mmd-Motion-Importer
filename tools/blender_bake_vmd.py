#!/usr/bin/env python3
"""Blender-side helper that bakes an MMD VMD to plain pose keyframes."""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import tempfile
import urllib.request
from pathlib import Path

import bpy


MMD_TOOLS_EXTENSION_API = "https://extensions.blender.org/api/v1/extensions/"
MMD_TOOLS_EXTENSION_PAGE = "https://extensions.blender.org/add-ons/mmd-tools/"
HTTP_USER_AGENT = "MMDVMDNpcImporter/1.0 BlenderExtensionInstaller"
ROTATION_EPSILON_DEGREES = 0.0005
POSITION_EPSILON_SOURCE_UNITS = 0.0005
# The legacy raw VMD importer scales VMD position units by 64 / 25.
# This Blender helper receives baked armature-space coordinates instead:
# one Blender/model unit in the supplied PMX/SMD pair corresponds to about
# 41.78 Source/GMod units.
BLENDER_TO_SOURCE_POSITION_SCALE = 41.78
PRE_PELVIS_ROLES = {"root", "center", "groove", "waist"}
SOURCE_PELVIS = "ValveBiped.Bip01_Pelvis"
SOURCE_SPINE = "ValveBiped.Bip01_Spine"
SOURCE_LEFT_UPPER_ARM = "ValveBiped.Bip01_L_UpperArm"
SOURCE_RIGHT_UPPER_ARM = "ValveBiped.Bip01_R_UpperArm"
SOURCE_LEFT_FOREARM = "ValveBiped.Bip01_L_Forearm"
SOURCE_RIGHT_FOREARM = "ValveBiped.Bip01_R_Forearm"
SOURCE_LEFT_HAND = "ValveBiped.Bip01_L_Hand"
SOURCE_RIGHT_HAND = "ValveBiped.Bip01_R_Hand"
SOURCE_PARENT_OVERRIDES = {
    # MMD: 腰 -> 下半身 and 腰 -> 上半身.
    # Source: Pelvis -> Spine. Compute Spine against the exported pelvis pose.
    SOURCE_SPINE: SOURCE_PELVIS,
    # MMD inserts arm/hand twist bones in the parent chain.
    # Source/GMod does not parent Forearm/Hand through those twist bones.
    # Source/GMod keeps those twist bones as siblings while Forearm is parented
    # to UpperArm and Hand is parented to Forearm.
    SOURCE_LEFT_FOREARM: SOURCE_LEFT_UPPER_ARM,
    SOURCE_RIGHT_FOREARM: SOURCE_RIGHT_UPPER_ARM,
    SOURCE_LEFT_HAND: SOURCE_LEFT_FOREARM,
    SOURCE_RIGHT_HAND: SOURCE_RIGHT_FOREARM,
}


def parse_args() -> argparse.Namespace:
    argv = sys.argv
    if "--" in argv:
        argv = argv[argv.index("--") + 1 :]
    else:
        argv = []

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-vmd", type=Path, required=True)
    parser.add_argument("--output-vmd", type=Path, required=True)
    parser.add_argument("--mmd-model", type=Path, required=True)
    parser.add_argument("--frame-start", type=int, required=True)
    parser.add_argument("--frame-end", type=int, required=True)
    parser.add_argument("--output-rotation-json", type=Path)
    parser.add_argument("--bone-map-json", default="{}")
    parser.add_argument("--disable-foot-ik", action="store_true",
                        help="mute all IK on the model before baking (for motions authored without foot IK)")
    return parser.parse_args(argv)


def operator_keywords(operator, desired: dict[str, object]) -> dict[str, object]:
    try:
        props = {prop.identifier for prop in operator.get_rna_type().properties}
    except Exception:
        return desired
    return {key: value for key, value in desired.items() if key in props}


def call_operator(operator, **desired):
    kwargs = operator_keywords(operator, desired)
    try:
        return operator(**kwargs)
    except Exception as exc:
        raise RuntimeError(f"{operator.idname()} failed with arguments {sorted(kwargs)}: {exc}") from exc


def mmd_tools_registered() -> bool:
    try:
        bpy.ops.mmd_tools.import_model.get_rna_type()
        bpy.ops.mmd_tools.import_vmd.get_rna_type()
        bpy.ops.mmd_tools.export_vmd.get_rna_type()
        return True
    except Exception:
        return False


def mmd_tools_module_candidates(addon_utils) -> list[str]:
    preferred = [
        "bl_ext.blender_org.mmd_tools",
        "bl_ext.user_default.mmd_tools",
        "mmd_tools",
        "blender_mmd_tools",
    ]
    discovered: list[str] = []
    try:
        for module in addon_utils.modules(refresh=True):
            name = module.__name__
            if name == "mmd_tools" or name.endswith(".mmd_tools") or name == "blender_mmd_tools":
                discovered.append(name)
    except Exception:
        pass

    out: list[str] = []
    for name in preferred + discovered:
        if name not in out:
            out.append(name)
    return out


def enable_mmd_tools_modules(addon_utils) -> list[str]:
    errors: list[str] = []
    for module_name in mmd_tools_module_candidates(addon_utils):
        try:
            addon_utils.enable(module_name, default_set=False, persistent=False)
            if mmd_tools_registered():
                print(f"Enabled mmd_tools add-on module: {module_name}")
                return errors
        except Exception as exc:
            errors.append(f"{module_name}: {exc}")
    return errors


def fetch_mmd_tools_archive_url() -> str:
    request = urllib.request.Request(MMD_TOOLS_EXTENSION_API, headers={"User-Agent": HTTP_USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)
    for item in payload.get("data", []):
        if item.get("id") == "mmd_tools" and item.get("archive_url"):
            return str(item["archive_url"])
    raise RuntimeError(f"mmd_tools was not found in {MMD_TOOLS_EXTENSION_API}")


def download_file(url: str, target: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": HTTP_USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response, target.open("wb") as handle:
        while True:
            chunk = response.read(1024 * 128)
            if not chunk:
                break
            handle.write(chunk)


def install_mmd_tools_from_local_archive() -> list[str]:
    """Install mmd_tools from a bundled local zip (path passed by the importer via
    MMDVMDNPC_MMD_TOOLS_ARCHIVE) so a freshly-extracted bundled Blender can bake
    fully offline. A no-op when the variable is unset, so the network path and the
    bake result are unchanged when nothing is bundled."""
    archive = os.environ.get("MMDVMDNPC_MMD_TOOLS_ARCHIVE", "")
    if not archive:
        return []
    archive_path = Path(archive)
    if not archive_path.is_file():
        return [f"bundled mmd_tools archive not found: {archive_path}"]
    errors: list[str] = []
    print(f"Installing MMD Tools from bundled archive: {archive_path}")
    try:
        bpy.ops.extensions.package_install_files(
            filepath=str(archive_path),
            repo="user_default",
            enable_on_install=True,
            overwrite=True,
        )
        if mmd_tools_registered():
            return errors
    except Exception as exc:
        errors.append(f"bundled extension file install failed: {exc}")

    try:
        bpy.ops.preferences.addon_install(
            filepath=str(archive_path),
            overwrite=True,
            enable_on_install=True,
        )
        if mmd_tools_registered():
            return errors
    except Exception as exc:
        errors.append(f"bundled legacy add-on install failed: {exc}")

    return errors


def install_mmd_tools_from_extension_site() -> list[str]:
    errors: list[str] = []
    try:
        archive_url = fetch_mmd_tools_archive_url()
        print(f"Downloading MMD Tools extension metadata from {MMD_TOOLS_EXTENSION_API}")
        print(f"Installing MMD Tools from {archive_url}")
    except Exception as exc:
        return [f"extension API lookup failed: {exc}"]

    try:
        bpy.ops.extensions.package_install(url=archive_url, enable_on_install=True)
        if mmd_tools_registered():
            return errors
    except Exception as exc:
        errors.append(f"Blender extension URL install failed: {exc}")

    try:
        with tempfile.TemporaryDirectory(prefix="mmd_tools_ext_") as temp_dir:
            archive_path = Path(temp_dir) / "mmd_tools.zip"
            download_file(archive_url, archive_path)
            bpy.ops.extensions.package_install_files(
                filepath=str(archive_path),
                repo="user_default",
                enable_on_install=True,
                overwrite=True,
            )
            if mmd_tools_registered():
                return errors
    except Exception as exc:
        errors.append(f"Blender extension file install failed: {exc}")

    try:
        with tempfile.TemporaryDirectory(prefix="mmd_tools_addon_") as temp_dir:
            archive_path = Path(temp_dir) / "mmd_tools.zip"
            download_file(archive_url, archive_path)
            bpy.ops.preferences.addon_install(
                filepath=str(archive_path),
                overwrite=True,
                enable_on_install=True,
            )
            if mmd_tools_registered():
                return errors
    except Exception as exc:
        errors.append(f"legacy add-on file install failed: {exc}")

    return errors


def enable_mmd_tools() -> None:
    try:
        import addon_utils
    except Exception as exc:
        raise RuntimeError(f"Blender addon utilities are unavailable: {exc}") from exc

    if mmd_tools_registered():
        print("mmd_tools operators are already available.")
        return

    errors = enable_mmd_tools_modules(addon_utils)
    if mmd_tools_registered():
        return

    errors.extend(install_mmd_tools_from_local_archive())
    errors.extend(enable_mmd_tools_modules(addon_utils))
    if mmd_tools_registered():
        return

    errors.extend(install_mmd_tools_from_extension_site())
    errors.extend(enable_mmd_tools_modules(addon_utils))
    if mmd_tools_registered():
        return

    detail = "; ".join(errors) if errors else "no mmd_tools module candidates were found"
    raise RuntimeError(
        "mmd_tools is not available in this Blender install. "
        f"The importer tried to enable it and install it from {MMD_TOOLS_EXTENSION_PAGE}. "
        f"Details: {detail}"
    )


def clear_scene() -> None:
    if bpy.ops.object.mode_set.poll():
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()


def set_active(obj: bpy.types.Object) -> None:
    if bpy.ops.object.mode_set.poll():
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def find_imported_armature(before: set[str]) -> bpy.types.Object:
    imported = [obj for obj in bpy.data.objects if obj.name not in before]
    armatures = [obj for obj in imported if obj.type == "ARMATURE"]
    if not armatures:
        armatures = [obj for obj in bpy.data.objects if obj.type == "ARMATURE"]
    if not armatures:
        raise RuntimeError("MMD model import did not create an armature")
    return armatures[0]


def import_model(model_path: Path) -> bpy.types.Object:
    before = {obj.name for obj in bpy.data.objects}
    print(f"Importing MMD model: {model_path}")
    print("Importing PMX without rigid bodies or joints; they are not needed for visual baking.")
    call_operator(
        bpy.ops.mmd_tools.import_model,
        filepath=str(model_path),
        types={"MESH", "ARMATURE", "DISPLAY", "MORPHS"},
    )
    armature = find_imported_armature(before)
    set_active(armature)
    print(f"Imported MMD model: {model_path}")
    print(f"Using armature: {armature.name}")
    return armature


def import_motion(armature: bpy.types.Object, vmd_path: Path) -> None:
    set_active(armature)
    # mmd_tools inserts VMD frame N at scene.frame_current + N; a factory scene
    # sits on frame 1, which made every bake one frame late.
    bpy.context.scene.frame_current = 0
    print(f"Importing VMD motion: {vmd_path}")
    call_operator(bpy.ops.mmd_tools.import_vmd, filepath=str(vmd_path))
    print(f"Imported VMD motion: {vmd_path}")


def disable_foot_ik(armature: bpy.types.Object) -> None:
    """Force every IK constraint on the model off before baking.

    Motions authored WITHOUT foot IK leave the IK target bones at the rest
    pose; baking them with IK enabled pins the legs to those resting targets
    while the FK keyframes dance. Runs after import_motion so it also wins
    over any IK on/off animation the VMD itself carried:

    1. Drop imported fcurves on pose.bones[...].mmd_ik_toggle (mmd_tools
       imports VMD IK on/off frames as animation of that property).
    2. Set mmd_ik_toggle = False on every pose bone — mmd_tools' update
       callback zeroes the influence of the matching IK constraints AND the
       chain's LIMIT_ROTATION (mmd_ik_limit_override) constraints, exactly
       like toggling IK off in MMD.
    3. Belt and braces: mute + zero every IK-type constraint directly, in
       case the model was not imported through mmd_tools.
    """
    anim = armature.animation_data
    action = anim.action if anim else None
    if action:
        for fcurve in [f for f in action.fcurves if "mmd_ik_toggle" in (f.data_path or "")]:
            action.fcurves.remove(fcurve)

    toggled = 0
    for pbone in armature.pose.bones:
        try:
            if getattr(pbone, "mmd_ik_toggle", None):
                pbone.mmd_ik_toggle = False
                toggled += 1
        except Exception as exc:
            print(f"mmd_ik_toggle off failed on {pbone.name}: {exc}")

    muted = 0
    for pbone in armature.pose.bones:
        for constraint in pbone.constraints:
            if constraint.type == "IK":
                constraint.mute = True
                constraint.influence = 0.0
                muted += 1
    print(f"Disabled foot IK: toggled {toggled} MMD IK bone(s) off, muted {muted} IK constraint(s).")


def bake_pose(armature: bpy.types.Object, frame_start: int, frame_end: int) -> None:
    scene = bpy.context.scene
    scene.frame_start = frame_start
    scene.frame_end = frame_end
    scene.frame_set(frame_start)

    set_active(armature)
    print(f"Starting Blender visual bake frames {frame_start}..{frame_end}.")
    bpy.ops.object.mode_set(mode="POSE")
    bpy.ops.pose.select_all(action="SELECT")
    call_operator(
        bpy.ops.nla.bake,
        frame_start=frame_start,
        frame_end=frame_end,
        step=1,
        only_selected=True,
        visual_keying=True,
        clear_constraints=True,
        clear_parents=False,
        use_current_action=True,
        clean_curves=False,
        bake_types={"POSE"},
    )
    bpy.ops.object.mode_set(mode="OBJECT")
    print(f"Baked pose frames {frame_start}..{frame_end} with visual keying.")


def export_motion(armature: bpy.types.Object, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    set_active(armature)
    print(f"Exporting baked VMD: {output_path}")
    call_operator(bpy.ops.mmd_tools.export_vmd, filepath=str(output_path))
    print(f"Exported baked VMD: {output_path}")


def round_small(value: float, epsilon: float = 1e-9) -> float:
    if abs(value) < epsilon:
        return 0.0
    return value


def clean_quat_from_matrix(matrix):
    quat = matrix.to_quaternion()
    quat.normalize()
    return quat


def quat_to_matrix3(quat):
    quat = quat.copy()
    quat.normalize()
    return quat.to_matrix().to_3x3()


def decompose_extrinsic_xyz_degrees(rot_mat, decimals: int = 6) -> dict[str, float]:
    """Fixed/global-axis XYZ: first +X, then +Y, then +Z.

    Matrix convention: R = Rz(z) @ Ry(y) @ Rx(x).
    The exported axes are the model axes used by the GMod retarget debugger:
    +X left, +Y front, +Z top.
    """

    sy = max(-1.0, min(1.0, -rot_mat[2][0]))
    y = math.asin(sy)
    cy = math.cos(y)

    if abs(cy) > 1e-8:
        x = math.atan2(rot_mat[2][1], rot_mat[2][2])
        z = math.atan2(rot_mat[1][0], rot_mat[0][0])
    else:
        z = 0.0
        if sy > 0:
            x = math.atan2(rot_mat[0][1], rot_mat[1][1])
        else:
            x = math.atan2(-rot_mat[0][1], rot_mat[1][1])

    return {
        "x_deg": round(round_small(math.degrees(x)), decimals),
        "y_deg": round(round_small(math.degrees(y)), decimals),
        "z_deg": round(round_small(math.degrees(z)), decimals),
    }


def rounded_quaternion_wxyz(quat, decimals: int = 6) -> dict[str, float]:
    quat = quat.copy()
    quat.normalize()
    return {
        "w": round(round_small(quat.w), decimals),
        "x": round(round_small(quat.x), decimals),
        "y": round(round_small(quat.y), decimals),
        "z": round(round_small(quat.z), decimals),
    }


def transform_is_zero(values: list[float]) -> bool:
    return all(abs(value) <= ROTATION_EPSILON_DEGREES for value in values[:3]) and all(
        abs(value) <= POSITION_EPSILON_SOURCE_UNITS for value in values[3:]
    )


def rotations_equal(a: list[float], b: list[float]) -> bool:
    if len(a) != len(b):
        return False
    for index in range(len(a)):
        epsilon = ROTATION_EPSILON_DEGREES if index < 3 else POSITION_EPSILON_SOURCE_UNITS
        if abs(a[index] - b[index]) > epsilon:
            return False
    return True


def compact_keyframes(samples: list[tuple[int, list[float]]]) -> list[list[float]]:
    if not samples:
        return []

    keys: list[list[float]] = []
    last_added: list[float] | None = None
    previous_frame: int | None = None
    previous_rotation: list[float] | None = None
    for frame, rotation in samples:
        if last_added is None:
            keys.append([frame] + list(rotation))
            last_added = rotation
        elif not rotations_equal(rotation, last_added):
            # Preserve the last held baked frame before a value changes. Without
            # this, compacted tracks interpolate from the start of a hold to the
            # later change frame and alter earlier integer frames.
            if (
                previous_frame is not None
                and previous_rotation is not None
                and keys[-1][0] != previous_frame
                and rotations_equal(previous_rotation, last_added)
            ):
                keys.append([previous_frame] + list(previous_rotation))

            keys.append([frame] + list(rotation))
            last_added = rotation

        previous_frame = frame
        previous_rotation = rotation

    final_frame, final_rotation = samples[-1]
    if keys and keys[-1][0] != final_frame:
        keys.append([final_frame] + list(final_rotation))

    return keys


def track_motion_score(samples: list[tuple[int, list[float]]]) -> float:
    return sum(abs(rotation[0]) + abs(rotation[1]) + abs(rotation[2]) for _, rotation in samples)


def strip_blender_collision_suffix(name: str) -> str:
    if len(name) > 4 and name[-4] == "." and name[-3:].isdigit():
        return name[:-4]
    if len(name) > 4 and name[-4] == "_" and name[-3:].isdigit():
        return name[:-4]
    return name


def parse_bone_map_json(raw: str) -> dict[str, tuple[str, str]]:
    try:
        loaded = json.loads(raw or "{}")
    except Exception as exc:
        raise RuntimeError(f"invalid --bone-map-json: {exc}") from exc

    mapping: dict[str, tuple[str, str]] = {}
    if not isinstance(loaded, dict):
        return mapping

    for bone_name, value in loaded.items():
        source_name = ""
        role = ""
        if isinstance(value, dict):
            source_name = str(value.get("source") or value.get("source_name") or "")
            role = str(value.get("role") or "")
        elif isinstance(value, (list, tuple)):
            if len(value) > 0:
                source_name = str(value[0] or "")
            if len(value) > 1:
                role = str(value[1] or "")
        elif isinstance(value, str):
            source_name = value
        mapping[str(bone_name)] = (source_name, role)
    return mapping


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


def parent_corrected_delta_quaternion(pose_bone, armature_world_quat, use_world_space: bool = False):
    q_current_obj = clean_quat_from_matrix(pose_bone.matrix)
    q_rest_obj = clean_quat_from_matrix(pose_bone.bone.matrix_local)

    parent = pose_bone.parent
    if parent is None:
        q_reference_obj = q_rest_obj
    else:
        q_parent_current_obj = clean_quat_from_matrix(parent.matrix)
        q_parent_rest_obj = clean_quat_from_matrix(parent.bone.matrix_local)
        q_child_rest_relative = q_parent_rest_obj.inverted() @ q_rest_obj
        q_child_rest_relative.normalize()
        q_reference_obj = q_parent_current_obj @ q_child_rest_relative
        q_reference_obj.normalize()

    if use_world_space:
        q_current = armature_world_quat @ q_current_obj
        q_reference = armature_world_quat @ q_reference_obj
    else:
        q_current = q_current_obj
        q_reference = q_reference_obj

    q_current.normalize()
    q_reference.normalize()
    q_delta = q_current @ q_reference.inverted()
    q_delta.normalize()
    return q_delta


def parent_corrected_delta_quaternion_with_parent(
    pose_bone,
    source_parent_pose_bone,
    armature_world_quat,
    use_world_space: bool = False,
):
    q_current_obj = clean_quat_from_matrix(pose_bone.matrix)
    q_rest_obj = clean_quat_from_matrix(pose_bone.bone.matrix_local)
    q_parent_current_obj = clean_quat_from_matrix(source_parent_pose_bone.matrix)
    q_parent_rest_obj = clean_quat_from_matrix(source_parent_pose_bone.bone.matrix_local)
    q_child_rest_relative = q_parent_rest_obj.inverted() @ q_rest_obj
    q_child_rest_relative.normalize()
    q_reference_obj = q_parent_current_obj @ q_child_rest_relative
    q_reference_obj.normalize()

    if use_world_space:
        q_current = armature_world_quat @ q_current_obj
        q_reference = armature_world_quat @ q_reference_obj
    else:
        q_current = q_current_obj
        q_reference = q_reference_obj

    q_current.normalize()
    q_reference.normalize()
    q_delta = q_current @ q_reference.inverted()
    q_delta.normalize()
    return q_delta


def source_parent_position_correction(pose_bone, source_parent_pose_bone):
    """Offset a child whose Source parent differs from its MMD parent.

    Source may place a child under a different parent than the imported MMD
    armature. Return the object-space correction that moves the Source child
    origin back to the baked MMD child origin. The Pelvis/Spine position case
    is handled at preview time in GMod, so this exporter uses the correction for
    the arm and hand Source-parent overrides only.
    """

    child_current_pos = pose_bone.matrix.translation
    child_rest_pos = pose_bone.bone.matrix_local.translation
    parent_current_pos = source_parent_pose_bone.matrix.translation
    parent_rest_pos = source_parent_pose_bone.bone.matrix_local.translation

    q_parent_current = clean_quat_from_matrix(source_parent_pose_bone.matrix)
    q_parent_rest = clean_quat_from_matrix(source_parent_pose_bone.bone.matrix_local)

    child_rest_in_parent = q_parent_rest.inverted() @ (child_rest_pos - parent_rest_pos)
    predicted_source_child_pos = parent_current_pos + (q_parent_current @ child_rest_in_parent)
    return child_current_pos - predicted_source_child_pos


def global_delta_quaternion(pose_bone, armature_world_quat, use_world_space: bool = False):
    q_current_obj = clean_quat_from_matrix(pose_bone.matrix)
    q_rest_obj = clean_quat_from_matrix(pose_bone.bone.matrix_local)

    if use_world_space:
        q_current = armature_world_quat @ q_current_obj
        q_rest = armature_world_quat @ q_rest_obj
    else:
        q_current = q_current_obj
        q_rest = q_rest_obj

    q_current.normalize()
    q_rest.normalize()
    q_delta = q_current @ q_rest.inverted()
    q_delta.normalize()
    return q_delta


def source_position_from_blender_delta(delta, decimals: int = 6) -> list[float]:
    """Convert a baked Blender armature-space delta to GMod bone-position units.

    Blender-baked armature space is not raw VMD space. Keep Blender/model Z as
    GMod Z so vertical/root-height motion does not become Source X movement.
    Blender/model X remains the GMod second component, matching the supplied
    PMX/SMD model orientation. One Blender unit should move about 36 GMod units.
    """

    return [
        round(round_small(float(delta.y) * BLENDER_TO_SOURCE_POSITION_SCALE, POSITION_EPSILON_SOURCE_UNITS), decimals),
        round(round_small(float(delta.x) * BLENDER_TO_SOURCE_POSITION_SCALE, POSITION_EPSILON_SOURCE_UNITS), decimals),
        round(round_small(float(delta.z) * BLENDER_TO_SOURCE_POSITION_SCALE, POSITION_EPSILON_SOURCE_UNITS), decimals),
    ]


def lower_body_source_position_from_blender_delta(delta, decimals: int = 6) -> list[float]:
    position = source_position_from_blender_delta(delta, decimals)
    position[0] = -position[0]
    return position


def compact_transform_values(rotation: dict[str, float], position: list[float] | None = None) -> list[float]:
    position = position or [0.0, 0.0, 0.0]
    return [
        round_small(float(rotation["x_deg"]), ROTATION_EPSILON_DEGREES),
        round_small(float(rotation["y_deg"]), ROTATION_EPSILON_DEGREES),
        round_small(float(rotation["z_deg"]), ROTATION_EPSILON_DEGREES),
        round_small(float(position[0]), POSITION_EPSILON_SOURCE_UNITS),
        round_small(float(position[1]), POSITION_EPSILON_SOURCE_UNITS),
        round_small(float(position[2]), POSITION_EPSILON_SOURCE_UNITS),
    ]


def export_parent_corrected_bone_rotations(
    armature: bpy.types.Object,
    output_path: Path,
    frame_start: int,
    frame_end: int,
    bone_map: dict[str, tuple[str, str]],
    input_vmd: Path,
    baked_vmd: Path,
    mmd_model: Path,
) -> None:
    scene = bpy.context.scene
    original_frame = scene.frame_current
    tracks: dict[str, dict[str, object]] = {}
    print(f"Exporting parent-corrected rotation JSON frames {frame_start}..{frame_end}: {output_path}")

    # The name -> (source, role, target) mapping is constant across frames, so
    # resolve it once instead of per bone per frame inside the export loop.
    mapped_bones: list[tuple[str, str, str, str]] = []
    source_parent_names: dict[str, str] = {}
    for bone in armature.pose.bones:
        source_name, role, target_bone = bone_target_info(bone.name, bone_map)
        if source_name and target_bone and role not in PRE_PELVIS_ROLES:
            source_parent_names.setdefault(target_bone, bone.name)
        if target_bone and role not in PRE_PELVIS_ROLES:
            mapped_bones.append((bone.name, source_name, role, target_bone))

    try:
        for frame in range(frame_start, frame_end + 1):
            scene.frame_set(frame)

            depsgraph = bpy.context.evaluated_depsgraph_get()
            armature_eval = armature.evaluated_get(depsgraph)
            q_arm_world = clean_quat_from_matrix(armature_eval.matrix_world)
            eval_pose_bones = armature_eval.pose.bones
            source_pose_bones = {
                target: eval_pose_bones[name]
                for target, name in source_parent_names.items()
                if name in eval_pose_bones
            }

            for bone_name, source_name, role, target_bone in mapped_bones:
                pose_bone = eval_pose_bones.get(bone_name)
                if pose_bone is None:
                    continue

                position = [0.0, 0.0, 0.0]
                if source_name == SOURCE_PELVIS:
                    # Source has no MMD root/center/groove/waist chain. Use
                    # the baked global lower-body transform as the single
                    # Source pelvis transform so all pre-lower-body motion is
                    # already included.
                    q_delta = global_delta_quaternion(pose_bone, q_arm_world)
                    position = lower_body_source_position_from_blender_delta(
                        pose_bone.matrix.translation - pose_bone.bone.matrix_local.translation
                    )
                    role = "pelvis_global"
                elif source_name in SOURCE_PARENT_OVERRIDES and SOURCE_PARENT_OVERRIDES[source_name] in source_pose_bones:
                    source_parent_pose_bone = source_pose_bones[SOURCE_PARENT_OVERRIDES[source_name]]
                    q_delta = parent_corrected_delta_quaternion_with_parent(
                        pose_bone,
                        source_parent_pose_bone,
                        q_arm_world,
                    )
                    if source_name != SOURCE_SPINE:
                        position = source_position_from_blender_delta(
                            source_parent_position_correction(pose_bone, source_parent_pose_bone)
                        )
                    role = "source_parent_override"
                else:
                    q_delta = parent_corrected_delta_quaternion(pose_bone, q_arm_world)

                track = tracks.get(pose_bone.name)
                if track is None:
                    track = {
                        "m": pose_bone.name,
                        "g": target_bone,
                        "role": role,
                        "samples": [],
                    }
                    tracks[pose_bone.name] = track

                rotation = compact_transform_values(decompose_extrinsic_xyz_degrees(quat_to_matrix3(q_delta)), position)
                track["samples"].append((frame, rotation))
    finally:
        scene.frame_set(original_frame)
        bpy.context.view_layer.update()

    target_groups: dict[str, list[tuple[float, int, dict[str, object]]]] = {}
    identity_track_count = 0
    for track in tracks.values():
        samples = track["samples"]
        if not any(not transform_is_zero(rotation) for _, rotation in samples):
            identity_track_count += 1

        keys = compact_keyframes(samples)
        if not keys:
            continue

        bone_entry = {
            "m": track["m"],
            "g": track["g"],
            "k": keys,
        }
        if track.get("role"):
            bone_entry["role"] = track["role"]

        target_groups.setdefault(str(track["g"]), []).append((track_motion_score(samples), len(keys), bone_entry))

    bones = []
    duplicate_target_count = 0
    for target_bone in sorted(target_groups):
        candidates = target_groups[target_bone]
        if len(candidates) > 1:
            duplicate_target_count += len(candidates) - 1
        candidates.sort(key=lambda item: (item[0], item[1], str(item[2].get("m", ""))), reverse=True)
        bones.append(candidates[0][2])

    output = {
        "format": "mmd_vmd_npc_parent_corrected_axis_v1",
        "armature": armature.name,
        "input_vmd": str(input_vmd),
        "baked_vmd": str(baked_vmd),
        "mmd_model": str(mmd_model),
        "space": "ARMATURE_OBJECT",
        "axis": ["+X model left", "+Y model front", "+Z model top"],
        "order": "fixed_xyz_extrinsic",
        "matrix_order": "Rz @ Ry @ Rx",
        "units": "degrees",
        "position_units": "source_units",
        "columns": ["frame", "x_deg", "y_deg", "z_deg", "pos_x", "pos_y", "pos_z"],
        "pelvis_track": "global_lower_body_includes_mmd_root_center_groove_waist",
        "hierarchy_overrides": SOURCE_PARENT_OVERRIDES,
        "frame_start": frame_start,
        "frame_end": frame_end,
        "frame_count": frame_end - frame_start + 1,
        "fps": scene.render.fps,
        "source_bone_map_count": len(bone_map),
        "mapped_track_count": len(tracks),
        "identity_track_count": identity_track_count,
        "duplicate_target_count": duplicate_target_count,
        "bone_count": len(bones),
        "bones": bones,
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(output, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"Exported parent-corrected bone rotations: {output_path}")


def configure_output_streams() -> None:
    # Motion/model paths often contain CJK characters; keep progress prints
    # alive when stdout is piped through a narrow console codepage.
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is None:
            continue
        try:
            reconfigure(errors="replace")
        except (ValueError, OSError):
            pass


def main() -> int:
    configure_output_streams()
    args = parse_args()
    for path in (args.input_vmd, args.mmd_model):
        if not path.exists():
            raise FileNotFoundError(path)
    if args.frame_end < args.frame_start:
        raise ValueError("frame_end must be greater than or equal to frame_start")

    enable_mmd_tools()
    clear_scene()
    armature = import_model(args.mmd_model)
    import_motion(armature, args.input_vmd)
    if args.disable_foot_ik:
        disable_foot_ik(armature)
    bake_pose(armature, args.frame_start, args.frame_end)
    if args.output_rotation_json:
        export_parent_corrected_bone_rotations(
            armature,
            args.output_rotation_json,
            args.frame_start,
            args.frame_end,
            parse_bone_map_json(args.bone_map_json),
            args.input_vmd,
            args.output_vmd,
            args.mmd_model,
        )
    export_motion(armature, args.output_vmd)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
