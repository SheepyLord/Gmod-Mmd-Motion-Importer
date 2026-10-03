"""Run deterministic cooperative-worker regressions on real LuaJIT 2.1.

Usage: python tests/run_build_worker_tests.py
Requires lupa (pip install lupa) only for this development test.
No GMod installation, running game, or network is used.
"""
from pathlib import Path
from lupa.luajit21 import LuaRuntime

root = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().worker_source = (root / "mmd_vmd_npc/lua/mmd_vmd_npc/cl_build_worker.lua").read_text(encoding="utf-8-sig")
lua.execute((root / "tests/build_worker_spec.lua").read_text(encoding="utf-8-sig"))
