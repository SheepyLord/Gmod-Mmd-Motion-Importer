#!/usr/bin/env python3
"""Generate the skeleton data of the in-game motion importer.

The GMod addon can import VMD motions inside the game when Model Hotloader's
file access is available (mmd_vmd_npc/lua/mmd_vmd_npc/cl_importer.lua). Its
baker, cl_import_bake.lua, is a Lua port of vmd_baker.py that bakes on the
same bundled PMX skeleton. Everything that depends only on that model and on
the importer's bone and flex maps is computed here, with the Python baker's
own functions, and written to cl_import_data.lua: the evaluation order, the
append and IK specs, the exported track plans, and the cp932 bone and morph
names VMD files store. Only the bones that an exported track, an IK chain, an
append, a ground contact or the placement bone depends on are kept; the others
cannot change anything the importer writes.

Run from the repository root after changing the bundled model or the maps:
    python tools/build_ingame_import_data.py
tests/test_ingame_importer.py fails while the committed file is stale.
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import import_vmd  # noqa: E402
import vmd_baker  # noqa: E402

OUTPUT = import_vmd.ADDON_DIR / "lua" / "mmd_vmd_npc" / "cl_import_data.lua"
FORMAT_VERSION = 1


def lua_string(value: str | bytes) -> str:
    """A Lua string literal. UTF-8 text stays readable; any other byte (the
    cp932 VMD names) becomes a three-digit decimal escape."""
    if isinstance(value, str):
        out = []
        for char in value:
            if char in "\\\"":
                out.append("\\" + char)
            elif ord(char) < 32 or ord(char) == 127:
                out.append("\\%03d" % ord(char))
            else:
                out.append(char)
        return '"' + "".join(out) + '"'
    out = []
    for byte in bytes(value):
        if 32 <= byte < 127 and chr(byte) not in "\\\"":
            out.append(chr(byte))
        else:
            out.append("\\%03d" % byte)
    return '"' + "".join(out) + '"'


def lua_number(value: float) -> str:
    value = float(value)
    if value == 0.0:
        # Keep the sign: the baker's atan2 calls can see these zeros.
        return "-0.0" if math.copysign(1.0, value) < 0 else "0"
    if value == int(value) and abs(value) < 1e15:
        return str(int(value))
    return repr(value)


def cp932(name: str) -> bytes | None:
    try:
        return name.encode("cp932")
    except UnicodeEncodeError:
        return None


def truncated_key(name: str, size: int) -> bytes:
    """The raw bytes behind vmd_baker._cp932_truncated: what MMD writes into a
    fixed-width VMD name field for a long PMX name."""
    return name.encode("cp932", errors="replace")[:size].split(b"\x00", 1)[0]


def needed_bones(model: vmd_baker.BakeModel, plans: list) -> tuple[set[int], set[int]]:
    """Bones (and IK chains) whose transforms can reach an exported value."""
    needed: set[int] = set()
    for plan in plans:
        needed.add(plan.bone)
        if plan.reference >= 0:
            needed.add(plan.reference)
    needed.update(vmd_baker.ground_contact_bones(model))
    needed.add(vmd_baker.placement_bone(model))
    owners: dict[int, list[int]] = {}
    for ik, chain in model.chains.items():
        for bone in chain.affected:
            owners.setdefault(bone, []).append(ik)
    chains: set[int] = set()
    changed = True
    while changed:
        changed = False
        for bone in list(needed):
            extra: list[int] = []
            if model.parent[bone] >= 0:
                extra.append(model.parent[bone])
            spec = model.appends.get(bone)
            if spec is not None:
                extra.append(spec.source)
            for ik in owners.get(bone, []):
                if ik not in chains:
                    chains.add(ik)
                    changed = True
                chain = model.chains[ik]
                extra.extend([ik, chain.effector] + [link.bone for link in chain.links])
            for other in extra:
                if other not in needed:
                    needed.add(other)
                    changed = True
    return needed, chains


def build(output: Path = OUTPUT, bones: list | None = None, model_path: Path | None = None) -> str:
    """Write the data file and return its text. bones/model_path: another
    skeleton than the bundled model's (the tests use small ones)."""
    model_path = model_path or import_vmd.find_default_mmd_model()
    if bones is None:
        bones = import_vmd.parse_pmx_bones(model_path)
    model = vmd_baker.prepare_model(bones)
    bone_map = import_vmd.load_bone_mapping()
    plans = vmd_baker._plan_output_tracks(model, bone_map)
    needed, chains = needed_bones(model, plans)

    # Kept bones in hierarchy order, renumbered from 1 for Lua.
    kept = [bone for bone in model.hierarchy_order if bone in needed]
    index = {bone: position + 1 for position, bone in enumerate(kept)}

    def ref(bone: int) -> int:
        return index.get(bone, 0) if bone >= 0 else 0

    def kept_list(bones_list: list[int]) -> str:
        return "{ " + ", ".join(str(index[bone]) for bone in bones_list if bone in index) + " }"

    lines: list[str] = []
    emit = lines.append
    emit("-- Generated by tools/build_ingame_import_data.py from the bundled PMX model and")
    emit("-- the importer's bone and flex maps. Do not edit; run the script instead.")
    emit("MMDVMDNPC = MMDVMDNPC or {}")
    emit("MMDVMDNPC.ImportData = {")
    emit(f"    version = {FORMAT_VERSION},")
    emit(f"    modelFile = {lua_string(model_path.name)},")
    emit(f"    armature = {lua_string(model_path.stem + '_arm')},")
    emit(f"    boneMapCount = {len(bone_map)},")
    emit(f"    pmxBoneCount = {len(bones)},")
    emit("    hierarchyOverrides = {")
    for child, parent in vmd_baker.SOURCE_PARENT_OVERRIDES.items():
        emit(f"        {{ {lua_string(child)}, {lua_string(parent)} }},")
    emit("    },")

    emit("    -- { Blender name, parent (0 = root), rest position x, y, z }, parents first")
    emit("    bones = {")
    for bone in kept:
        x, y, z = (lua_number(v) for v in model.rest_position[bone])
        emit(f"        {{ {lua_string(model.blender_names[bone])}, {ref(model.parent[bone])}, {x}, {y}, {z} }},")
    emit("    },")

    emit("    -- Bones that carry an append or an IK chain, in PMX transform order.")
    order = [bone for bone in model.transform_order if bone in index and (bone in model.appends or bone in chains)]
    emit(f"    transformOrder = {kept_list(order)},")

    emit("    appends = {")
    for bone in order:
        spec = model.appends.get(bone)
        if spec is None:
            continue
        emit(
            f"        [{index[bone]}] = {{ source = {index[spec.source]}, ratio = {lua_number(spec.ratio)}, "
            f"rotate = {str(spec.rotate).lower()}, translate = {str(spec.translate).lower()}, "
            f"localAppend = {str(spec.local).lower()}, descendants = {kept_list(model.descendants[bone])} }},"
        )
    emit("    },")

    emit("    chains = {")
    for bone in order:
        if bone not in chains:
            continue
        chain = model.chains[bone]
        emit(f"        [{index[bone]}] = {{")
        emit(f"            effector = {index[chain.effector]}, loops = {chain.loops}, unitAngle = {lua_number(chain.unit_angle)},")
        emit(f"            twoBone = {str(chain.two_bone).lower()},")
        emit("            links = {")
        for link, path in zip(chain.links, chain.link_paths):
            parts = [f"bone = {index[link.bone]}", f"plane = {link.plane_axis + 1}"]
            if link.lower is not None:
                parts.append("lower = { " + ", ".join(lua_number(v) for v in link.lower) + " }")
                parts.append("upper = { " + ", ".join(lua_number(v) for v in link.upper) + " }")
            parts.append(f"path = {kept_list(path)}")
            emit("                { " + ", ".join(parts) + " },")
        emit("            },")
        emit(f"            affected = {kept_list(chain.affected)},")
        emit("        },")
    emit("    },")

    emit("    -- Exported tracks: { bone, Blender name, GMod target, role, mode, reference bone }")
    emit("    plans = {")
    for plan in plans:
        emit(
            f"        {{ {index[plan.bone]}, {lua_string(plan.name)}, {lua_string(plan.target)}, "
            f"{lua_string(plan.role)}, {lua_string(plan.mode)}, {ref(plan.reference)} }},"
        )
    emit("    },")

    contacts = vmd_baker.ground_contact_bones(model)
    emit(f"    contacts = {kept_list(contacts)},")
    emit(f"    restHeight = {lua_number(vmd_baker.ground_rest_height(model, contacts)) if contacts else 0},")
    emit(f"    placement = {index[vmd_baker.placement_bone(model)]},")

    # VMD bone and IK names are cp932, cut to a fixed field (15 / 20 bytes).
    # The keys are the raw bytes. A model bone the importer does not keep maps
    # to -(PMX index + 1): its tracks still count, as in the Python baker, but
    # are not evaluated. Same rules as vmd_baker._name_resolver, on PMX indices.
    def resolved(bone: int) -> int:
        return index.get(bone, -(bone + 1))

    exact: dict[bytes, int] = {}
    truncated: dict[int, dict[bytes, int]] = {15: {}, 20: {}}
    ambiguous: dict[int, set[bytes]] = {15: set(), 20: set()}
    for bone, name in enumerate(model.names):
        raw = cp932(name)
        if raw is not None:
            exact.setdefault(raw, bone)
        for size in (15, 20):
            key = truncated_key(name, size)
            table = truncated[size]
            if key in table and table[key] != bone:
                ambiguous[size].add(key)
            table.setdefault(key, bone)
    emit("    exactNames = {")
    for raw in sorted(exact):
        emit(f"        [{lua_string(raw)}] = {resolved(exact[raw])},")
    emit("    },")
    for size in (15, 20):
        emit(f"    truncatedNames{size} = {{")
        for key in sorted(truncated[size]):
            if key not in ambiguous[size]:
                emit(f"        [{lua_string(key)}] = {resolved(truncated[size][key])},")
        emit("    },")

    emit("    -- cp932 morph name -> { name, GMod flex }")
    emit("    flexMap = {")
    flex_map = import_vmd.load_flex_mapping()
    for name in sorted(flex_map):
        raw = cp932(name)
        if raw is None or not flex_map[name]:
            continue
        emit(f"        [{lua_string(raw)}] = {{ {lua_string(name)}, {lua_string(flex_map[name])} }},")
    emit("    },")
    emit("}")
    text = "\n".join(lines) + "\n"
    output.write_text(text, encoding="utf-8", newline="\n")
    return text


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, default=OUTPUT, help="where to write the Lua data file")
    args = parser.parse_args(argv)
    build(args.output)
    print(f"Wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
