"""Run the real server cache writer under LuaJIT with a fault-injectable GMod file API.

Requires `pip install lupa`; run `python -m unittest discover -s tests -p test_build_writer.py`.
The encoder stub uses JSON exactly as the engine adapter does: the implementation
must preserve the semantic document regardless of key order or whitespace.
"""
import json
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
CACHE_SOURCE = ROOT / "mmd_vmd_npc/lua/mmd_vmd_npc/sv_cache.lua"


class BuiltCacheWriterTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.encodes = []
        self.lua.globals().encode_json = self.encode_json
        self.lua.execute(r'''
            MMDVMDNPC = { MotionRoot = "motions", BuiltRoot = "built" }
            istable = function(v) return type(v) == "table" end
            isstring = function(v) return type(v) == "string" end
            timer = { Simple = function() end }
            hooks = {}; hook = { Add = function(event, name, fn) hooks[event] = fn end }
            clock, clockStep = 0, 0
            SysTime = function() clock = clock + clockStep; return clock end
            string.GetPathFromFilename = function(v) return v:match("^(.*)/") or "" end
            util = { TableToJSON = function(v) return encode_json(v) end }
            files, handles = {}, {}
            file = {
                CreateDir = function() end,
                Open = function(path)
                    if failOpen then return nil end
                    files[path] = ""
                    local handle = { closed = false }
                    function handle:Write(text)
                        assert(not self.closed, "write after close")
                        if failWrite then error("injected write error") end
                        files[path] = files[path] .. (shortWrite and text:sub(1, -2) or text)
                    end
                    function handle:Close() self.closed = true end
                    handles[#handles + 1] = handle
                    return handle
                end,
                Delete = function(path) files[path] = nil end,
                Size = function(path) return files[path] and #files[path] or -1 end,
                Exists = function(path) return files[path] ~= nil end,
                Rename = function(source, target)
                    if failRename or files[target] then return false end
                    files[target], files[source] = files[source], nil
                    return true
                end,
            }
        ''')
        self.lua.execute(CACHE_SOURCE.read_text(encoding="utf-8"))
        self.api = self.lua.globals().MMDVMDNPC
        self.path = "built/motion_model.json"

    def to_python(self, value):
        if not hasattr(value, "items"):
            return value
        pairs = dict(value.items())
        if not pairs:
            return []
        if set(pairs) == set(range(1, len(pairs) + 1)):
            return [self.to_python(pairs[i]) for i in range(1, len(pairs) + 1)]
        return {str(k): self.to_python(v) for k, v in pairs.items()}

    def encode_json(self, value):
        converted = self.to_python(value)
        self.encodes.append(converted)
        return json.dumps(converted, ensure_ascii=False, separators=(",", ":"))

    def built(self, frame_count=77):
        return {
            "format": "mmd_vmd_npc_built_v1", "motion_id": '踊る "quoted" \\ dance',
            "model": "models/test.mdl", "fps": 30, "frame_start": 12,
            "frame_end": 12 + frame_count - 1, "frame_count": frame_count,
            "options": {"disable_eyes": True, "disable_armtwist": False},
            "bones": [{"id": 0, "name": "pelvis", "source": "骨"}],
            "flexes": [], "music": {"sound": "track.mp3", "offset": -1.25},
            "frames": [{"frame": f + 12, "bones": [[0, 1.2, -359.9, 0, 2, 3, 4]],
                        "flexes": [[1, 0.75]]} for f in range(frame_count)],
        }

    def begin(self, built=None, token=1):
        return self.api.BeginBuiltCacheWrite(
            self.path, self.lua.table_from(built or self.built(), recursive=True), token)

    def finish(self, writer):
        for _ in range(1000):
            result = self.api.StepBuiltCacheWrite(writer, 0.002)
            if result is not False:
                return result
        self.fail("writer never completed")

    def assert_clean(self):
        self.assertEqual(dict(self.lua.globals().files.items()), {})
        self.assertEqual(dict(self.api.ActiveBuiltCacheWriters.items()), {})
        for handle in self.lua.globals().handles.values():
            self.assertTrue(handle.closed)

    def test_round_trip_and_bounded_work_with_coarse_clock(self):
        built = self.built()
        writer = self.begin(built)
        temp = writer.tempPath
        self.assertIsNone(self.lua.globals().files[self.path])
        self.assertEqual(len(self.encodes), 1)
        self.assertNotIn("frames", self.encodes[0])
        self.assertFalse(self.api.StepBuiltCacheWrite(writer, 0.002))
        self.assertLessEqual(writer.nextFrame - 1, 32)
        self.assertIsNone(self.lua.globals().files[self.path])
        self.assertTrue(self.finish(writer))
        self.assertIsNone(self.lua.globals().files[temp])
        self.assertEqual(json.loads(self.lua.globals().files[self.path]), built)
        self.assertEqual(len(self.encodes), 1 + len(built["frames"]))
        self.assertTrue(self.api.StepBuiltCacheWrite(writer, 0.002))
        self.assertTrue(all(h.closed for h in self.lua.globals().handles.values()))

    def test_time_budget_yields_after_one_expensive_frame(self):
        writer = self.begin()
        self.lua.globals().clockStep = 0.003
        self.assertFalse(self.api.StepBuiltCacheWrite(writer, 0.002))
        self.assertEqual(writer.nextFrame, 2)

    def test_cancel_removes_partial_and_never_publishes(self):
        writer = self.begin()
        self.api.StepBuiltCacheWrite(writer, 0.002)
        self.api.CancelBuiltCacheWrite(writer)
        self.api.CancelBuiltCacheWrite(writer)
        self.assert_clean()

    def test_empty_frames_form_valid_json(self):
        built = self.built(0)
        writer = self.begin(built)
        self.assertTrue(self.finish(writer))
        self.assertEqual(json.loads(self.lua.globals().files[self.path]), built)

    def test_short_write_is_not_published(self):
        writer = self.begin(self.built(1))
        self.lua.globals().shortWrite = True
        done, err = self.finish(writer)
        self.assertIsNone(done)
        self.assertIn("incomplete", err)
        self.assert_clean()

    def test_encoder_exception_closes_and_removes_partial(self):
        writer = self.begin(self.built(1))
        self.lua.execute('util.TableToJSON = function() error("injected encode failure") end')
        done, err = self.finish(writer)
        self.assertIsNone(done)
        self.assertIn("encode failure", err)
        self.assert_clean()

    def test_open_and_write_failures_leave_no_partial(self):
        self.lua.globals().failOpen = True
        writer, err = self.begin()
        self.assertIsNone(writer)
        self.assertIn("could not open", err)
        self.assert_clean()
        self.lua.globals().failOpen = False
        writer = self.begin(self.built(1))
        self.lua.globals().failWrite = True
        done, err = self.finish(writer)
        self.assertIsNone(done)
        self.assertIn("write error", err)
        self.assert_clean()

    def test_rename_failure_removes_partial(self):
        writer = self.begin(self.built(1))
        self.lua.globals().failRename = True
        done, err = self.finish(writer)
        self.assertIsNone(done)
        self.assertIn("could not publish", err)
        self.assert_clean()

    def test_hot_reload_does_not_reuse_an_active_temporary_path(self):
        first = self.begin(token=1)
        first_path = first.tempPath
        first_data = self.lua.globals().files[first_path]
        self.lua.execute(CACHE_SOURCE.read_text(encoding="utf-8"))
        second = self.begin(token=1)
        self.assertNotEqual(first_path, second.tempPath)
        self.assertEqual(self.lua.globals().files[first_path], first_data)
        self.api.CancelBuiltCacheWrite(first)
        self.api.CancelBuiltCacheWrite(second)
        self.assert_clean()

    def test_shutdown_closes_all_writers_and_deletes_partial_files(self):
        self.begin(token=1)
        self.begin(token=2)
        self.lua.globals().hooks.ShutDown()
        self.assert_clean()

    def test_concurrent_winner_is_preserved(self):
        first = self.begin(self.built(1), token=1)
        second = self.begin(self.built(2), token=2)
        self.assertNotEqual(first.tempPath, second.tempPath)
        self.assertTrue(self.finish(first))
        winner = self.lua.globals().files[self.path]
        done, err = self.finish(second)
        self.assertIsNone(done)
        self.assertIn("already exists", err)
        self.assertEqual(dict(self.lua.globals().files.items()), {self.path: winner})


if __name__ == "__main__":
    unittest.main()