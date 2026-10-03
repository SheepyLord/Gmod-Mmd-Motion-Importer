"""Actual client pipeline/worker regressions on LuaJIT with mocked engine/network.

Run: python -m unittest discover -s tests -p test_build_pipeline.py
Requires lupa. Numerical retargeting is covered separately by engine diagnostics.
"""
from pathlib import Path
import unittest
from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / 'mmd_vmd_npc/lua/mmd_vmd_npc'


class BuildPipelineTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('''
            now = 0; computes = 0; destroys = 0; creates = 0; logs = {}; settingsSeen = {}
            function SysTime() return now end
            function IsValid(v) return type(v) == "table" and not v.removed end
            function math.Clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
            function LF(_, message) return message end
            function print(message) logs[#logs + 1] = message end
            cvars = { mmd_vmd_npc_build_budget_ms = 2, mmd_vmd_npc_fast_build = 1,
                mmd_vmd_npc_disable_eyes = 0, mmd_vmd_npc_flex_scale_all = 1 }
            function GetConVar(name)
                if cvars[name] == nil then return nil end
                return { GetFloat = function() return cvars[name] end }
            end
            target = { GetModel = function() return "model.mdl" end }
            function Entity() return target end
            MMDVMDNPC = { ClientBuildJobs = {}, BuildStatus = {}, VMDFPS = 30 }
            net = { receivers = {}, sent = {} }
            function net.Receive(name, fn) net.receivers[name] = fn end
            function net.Read() local v = net.input[net.index]; net.index = net.index + 1; return v end
            net.ReadUInt = net.Read; net.ReadInt = net.Read; net.ReadFloat = net.Read
            net.ReadString = net.Read; net.ReadEntity = net.Read; net.ReadBool = net.Read
            function net.BytesLeft() return 1, tailBits or 6 end
            function net.Start(name) net.current = { name = name, args = {} } end
            function net.Write(value) local a = net.current.args; a[#a + 1] = value end
            net.WriteUInt = net.Write; net.WriteInt = net.Write; net.WriteFloat = net.Write
            net.WriteAngle = net.Write
            function net.SendToServer() net.sent[#net.sent + 1] = net.current; net.current = nil end
            function receive(name, input) net.input = input; net.index = 1; net.receivers[name]() end
            hook = { callbacks = {} }
            function hook.Add(event, name, fn) hook.callbacks[event .. ':' .. name] = fn end
            function update_build_status(status) lastStatus = status end
            function show_build_lag_warning() end
            function build_dummy_for_model(model)
                creates = creates + 1; dummy = { model = model }; return dummy
            end
            function destroy_build_dummy() destroys = destroys + 1; if dummy then dummy.removed = true end end
            function packet_to_frame_data(frame, packed, flexPacked)
                return { frame = frame, bones = packed, flexes = flexPacked }
            end
            function compute_build_frame(job, dummy, rows, flexRows)
                while holdAfterComputes and computes >= holdAfterComputes do
                    now = now + .003; build_checkpoint()
                end
                computes = computes + 1
                if failCompute then error('injected solver failure') end
                settingsSeen[#settingsSeen + 1] = MMDVMDNPC.BuildWorker.settings.mmd_vmd_npc_disable_eyes
                for i = 1, 3 do now = now + .001; build_checkpoint() end
                return { { bone = 1, ang = { p = rows[1].x }, pos = { x = 0, y = 0, z = 0 } } }, {}
            end
            function make_job(first, last)
                job = { motionID = "dance", model = "model.mdl", target = target,
                    fps = 30, frame_start = first, frame_end = last,
                    frames = {}, bonesByID = {}, flexesByID = {},
                    boneTracks = { { mmd = "a", source = "a", role = "", resolved = true, bone = 1 } },
                    flexTracks = {} }
                MMDVMDNPC.ClientBuildJobs[1] = job
                return job
            end
            function compact(first, count)
                local input = { 1, "dance", count }
                for f = first, first + count - 1 do
                    input[#input + 1] = f
                    for n = 1, 6 do input[#input + 1] = n end
                end
                receive("mmdvmd_build_compact_request", input)
            end
            function read_frame_payload()
                local f = legacyNext; legacyNext = f + 1
                return 10, 11, f, 0, 0, 30, 0, 1, {},
                    { { mmd = "a", source = "a", role = "", resolved = true, bone = 1, x = 1 } }, {}
            end
        ''')
        self.g = self.lua.globals()
        self.g.MMDVMDNPC.BuildWorker = self.lua.execute((LUA / 'cl_build_worker.lua').read_text(encoding='utf-8-sig'))
        self.lua.execute('function build_checkpoint() MMDVMDNPC.BuildWorker:Checkpoint() end')
        source = (LUA / 'cl_menu.lua').read_text(encoding='utf-8-sig')
        start = source.index('net.Receive("mmdvmd_build_plan"')
        end = source.index('net.Receive("mmdvmd_target_status"', start)
        self.lua.execute(source[start:end])
        start = source.index('function MMDVMDNPC.RequestCancelBuildTasks()')
        end = source.index('function MMDVMDNPC.RequestPlaySelectedMotion()', start)
        self.lua.execute(source[start:end])
        self.think = self.g.hook.callbacks['Think:MMDVMDNPCBuildWorker']

    def finish(self):
        for _ in range(50):
            self.think()
            if self.lua.eval('next(MMDVMDNPC.BuildWorker.tasks) == nil'):
                return
        self.fail('worker did not finish')

    def test_compact_decode_is_deferred_and_batch_send_is_atomic(self):
        self.g.make_job(10, 12); self.g.compact(10, 3)
        self.assertEqual(self.g.computes, 0)
        self.assertEqual(self.g.creates, 0)
        self.think()
        self.assertGreater(self.g.computes, 0)
        self.assertEqual(len(self.g.net.sent), 0)
        self.assertLess(len(self.g.job.frames), 3)
        self.finish()
        self.assertEqual(self.g.computes, 3)
        self.assertEqual(len(self.g.net.sent), 1)
        self.assertEqual(self.g.net.sent[1].name, 'mmdvmd_build_frame_result')
        self.assertEqual(self.g.net.sent[1].args[2], 3)
        self.assertEqual([self.g.job.frames[i].frame for i in range(1, 4)], [10, 11, 12])
        self.assertEqual(self.g.job.nextFrame, 13)

    def test_pending_and_cached_retries_do_not_recompute(self):
        self.g.make_job(10, 12); self.g.compact(10, 2); self.think()
        self.g.compact(10, 2); self.finish()
        self.assertEqual(self.g.computes, 2)
        self.g.compact(10, 2)
        self.assertEqual(len(self.g.net.sent), 2)
        self.assertEqual(self.g.computes, 2)
        self.g.compact(12, 1); self.finish()
        self.assertEqual(self.g.computes, 3)
        self.assertEqual(len(self.g.job.frames), 3)

    def test_future_and_obsolete_batches_are_ignored(self):
        self.g.make_job(10, 12); self.g.compact(11, 1)
        self.assertIsNone(self.g.job.pendingBatch)
        self.g.compact(10, 1); self.finish(); self.g.compact(11, 1); self.finish()
        self.g.compact(10, 1)
        self.assertEqual(self.g.computes, 2)
        self.assertEqual(len(self.g.net.sent), 2)

    def test_cancel_stops_suspended_coroutine_without_late_results(self):
        self.g.make_job(10, 12); self.g.compact(10, 3); self.think()
        self.g.MMDVMDNPC.RequestCancelBuildTasks(); self.finish()
        self.assertTrue(self.g.job.cancelled)
        self.assertEqual(len(self.g.net.sent), 1)
        self.assertEqual(self.g.net.sent[1].name, 'mmdvmd_build_cancel_request')
        self.g.compact(10, 3); self.finish()
        self.assertEqual(len(self.g.net.sent), 1)

    def test_failure_cancels_job_and_removes_dummy(self):
        self.g.make_job(10, 12); self.g.failCompute = True; self.g.compact(10, 3); self.finish()
        self.assertTrue(self.g.job.cancelled)
        self.assertEqual(self.g.destroys, 1)
        self.assertEqual(self.g.net.sent[1].name, 'mmdvmd_build_cancel_request')
        self.assertEqual(len(self.g.job.frames), 0)

    def test_settings_are_frozen_across_slices_and_batches(self):
        self.g.make_job(10, 12); self.g.compact(10, 2)
        self.g.cvars.mmd_vmd_npc_disable_eyes = 1
        self.think(); self.finish(); self.g.compact(12, 1); self.finish()
        self.assertEqual([self.g.settingsSeen[i] for i in range(1, 4)], [0, 0, 0])

    def test_legacy_expanded_payload_uses_same_worker(self):
        self.g.legacyNext = 10
        self.g.receive('mmdvmd_build_frame_request', self.lua.table_from([1, 'dance', 2]))
        self.assertEqual(self.g.computes, 0)
        self.finish()
        self.assertEqual(self.g.computes, 2)
        self.assertEqual(self.g.MMDVMDNPC.ClientBuildJobs[1].model, 'model.mdl')
        self.assertEqual(self.g.net.sent[1].args[2], 2)

    def test_older_build_plan_without_optional_settings_is_accepted(self):
        data = [1, 'dance', self.g.target, 'model.mdl', 30, 10, 12, 2, 1, 'a', 'a', '', True, 1, 0]
        self.g.receive('mmdvmd_build_plan', self.lua.table_from(data)); self.g.compact(10, 3); self.finish()
        self.assertEqual(self.g.computes, 3)
        self.assertEqual(self.g.MMDVMDNPC.ClientBuildJobs[1].nextFrame, 13)


    def test_authoritative_plan_options_override_later_client_changes(self):
        self.g.tailBits = 20
        data = [1, 'dance', self.g.target, 'model.mdl', 30, 10, 12, 2, 1, 'a', 'a', '', True, 1, 0,
                0x4D4D, True, False, True, False]
        self.g.receive('mmdvmd_build_plan', self.lua.table_from(data))
        self.g.compact(10, 3); self.finish()
        settings = self.g.MMDVMDNPC.ClientBuildJobs[1].settings
        self.assertEqual(settings.mmd_vmd_npc_disable_armtwist, 1)
        self.assertEqual(settings.mmd_vmd_npc_disable_handtwist, 0)
        self.assertEqual(settings.mmd_vmd_npc_disable_spine_pelvis_correction, 0)
        self.assertEqual([self.g.settingsSeen[i] for i in range(1, 4)], [1, 1, 1])

    def load_cleanup_hooks(self):
        source = (LUA / 'cl_menu.lua').read_text(encoding='utf-8-sig')
        start = source.index('-- Auto-refresh cannot resume closures')
        end = source.index('-- Build a hidden dummy', start)
        self.lua.execute(source[start:end])

    def test_reload_cancels_orphaned_jobs_and_restores_dummy_resources(self):
        self.g.make_job(10, 12); self.g.compact(10, 3); self.think()
        self.g.MMDVMDNPC.BuildWorkerReloaded = True
        self.load_cleanup_hooks()
        self.assertTrue(self.lua.eval('next(MMDVMDNPC.ClientBuildJobs) == nil'))
        self.assertTrue(self.lua.eval('next(MMDVMDNPC.BuildWorker.tasks) == nil'))
        self.assertEqual(self.g.destroys, 1)
        self.assertEqual(self.g.net.sent[1].name, 'mmdvmd_build_cancel_request')

    def test_shutdown_drops_jobs_without_network_send(self):
        self.load_cleanup_hooks()
        self.g.make_job(10, 12); self.g.compact(10, 3); self.think()
        self.g.hook.callbacks['ShutDown:MMDVMDNPCBuildCleanup']()
        self.assertTrue(self.lua.eval('next(MMDVMDNPC.ClientBuildJobs) == nil'))
        self.assertTrue(self.lua.eval('next(MMDVMDNPC.BuildWorker.tasks) == nil'))
        self.assertEqual(self.g.destroys, 1)
        self.assertEqual(len(self.g.net.sent), 0)


    def load_heartbeat_plan(self, modern):
        data = [1, 'dance', self.g.target, 'model.mdl', 30, 10, 12, 2, 1, 'a', 'a', '', True, 1, 0]
        self.g.tailBits = 20 if modern else 6
        if modern:
            data.extend([0x4D4D, False, False, False, False])
        self.g.receive('mmdvmd_build_plan', self.lua.table_from(data))
        self.g.job = self.g.MMDVMDNPC.ClientBuildJobs[1]
        self.g.compact(10, 3)

    def heartbeats(self):
        return [self.g.net.sent[i] for i in range(1, len(self.g.net.sent) + 1)
                if self.g.net.sent[i].name == 'mmdvmd_build_heartbeat']

    def reach_frame(self, frame):
        for _ in range(10):
            self.think()
            if self.g.job.completedFrame == frame:
                return
        self.fail(f'did not finish frame {frame}')

    def test_heartbeat_reports_advancing_work_once_and_stops_after_completion(self):
        self.g.holdAfterComputes = 1
        self.load_heartbeat_plan(True)
        self.reach_frame(10)
        self.assertEqual(len(self.heartbeats()), 0)
        self.g.now += 1.1; self.think()
        self.assertEqual(len(self.heartbeats()), 1)
        self.assertEqual(self.heartbeats()[0].args[1], 1)
        self.assertEqual(self.heartbeats()[0].args[2], 10)
        self.assertEqual(len(self.g.net.sent), 1)  # No partial batch result.
        self.g.holdAfterComputes = 2
        self.reach_frame(11)
        self.assertEqual(len(self.heartbeats()), 1)  # Advancing work is rate-limited.
        self.g.now += 1.1; self.think()
        self.assertEqual(len(self.heartbeats()), 2)
        self.assertEqual(self.heartbeats()[1].args[2], 11)
        self.g.now += 1.1; self.think()
        self.assertEqual(len(self.heartbeats()), 2)  # No duplicate stalled frame.
        self.g.holdAfterComputes = None; self.finish()
        self.assertIsNone(self.g.job.pendingBatch)
        self.g.now += 2; self.think()
        self.assertEqual(len(self.heartbeats()), 2)
        self.assertEqual(self.g.net.sent[3].name, 'mmdvmd_build_frame_result')

    def test_heartbeat_waits_until_a_frame_has_actually_completed(self):
        self.g.holdAfterComputes = 0
        self.load_heartbeat_plan(True)
        self.think(); self.g.now += 2; self.think()
        self.assertIsNone(self.g.job.completedFrame)
        self.assertEqual(len(self.heartbeats()), 0)
        self.assertEqual(len(self.g.net.sent), 0)

    def test_legacy_plan_never_sends_unknown_heartbeat_message(self):
        self.g.holdAfterComputes = 1
        self.load_heartbeat_plan(False)
        self.reach_frame(10)
        self.g.now += 2; self.think()
        self.assertFalse(self.g.job.serverSupportsHeartbeat)
        self.assertEqual(len(self.heartbeats()), 0)
        self.g.holdAfterComputes = None; self.finish()
        self.assertEqual(len(self.g.net.sent), 1)
        self.assertEqual(self.g.net.sent[1].name, 'mmdvmd_build_frame_result')

    def test_cancellation_prevents_late_heartbeats_and_results(self):
        self.g.holdAfterComputes = 1
        self.load_heartbeat_plan(True)
        self.reach_frame(10)
        self.g.now += 1.1; self.think()
        self.assertEqual(len(self.heartbeats()), 1)
        self.g.MMDVMDNPC.RequestCancelBuildTasks()
        self.g.now += 2; self.think(); self.think()
        self.assertEqual(len(self.heartbeats()), 1)
        self.assertEqual(len(self.g.net.sent), 2)
        self.assertEqual(self.g.net.sent[2].name, 'mmdvmd_build_cancel_request')


if __name__ == '__main__':
    unittest.main()
