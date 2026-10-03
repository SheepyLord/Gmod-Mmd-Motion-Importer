"""Exercise production heartbeat and timeout code with a deterministic Lua clock.

Run `python -m unittest discover -s tests -p test_build_heartbeat.py` (needs lupa).
"""
from pathlib import Path
import re
import unittest

from lupa.luajit21 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "mmd_vmd_npc/lua/mmd_vmd_npc/sv_commands.lua"


class BuildHeartbeatTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        handler_start = source.index('net.Receive("mmdvmd_build_heartbeat",')
        handler_end = source.index('\nnet.Receive(', handler_start + 1)
        update_start = source.index('local function update_build_job(')
        update_end = source.index('\nhook.Add(', update_start + 1)
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(r'''
            clock, requests, saves, next_jobs = 0, 0, 0, 0
            ply, other = {}, {}
            MMDVMDNPC = { BuildJobs={}, BuildQueues={}, Chat=function() end }
            CurTime = function() return clock end
            IsValid = function(v) return v ~= nil and v ~= false end
            ai_disabled_enabled = function() return true end
            is_usable_npc = function(v) return v ~= nil end
            lookup_required_reference_sequence_info = function() return {} end
            freeze_player_target = function() end
            send_build_progress = function() end
            send_play_status = function() end
            send_build_done = function(p, ok, path, message, buildID)
                done = {ok=ok, message=message, id=buildID}
            end
            clear_build_job = function(p) MMDVMDNPC.BuildJobs[p] = nil end
            start_next_queued_build = function() next_jobs = next_jobs + 1 end
            send_build_frame_request = function(p,job)
                requests = requests + 1
                job.lastRequestAt = CurTime()
            end
            advance_build_save = function() saves = saves + 1 end
            local receiver
            net = {
                Receive=function(name, fn) receiver=fn end,
                ReadUInt=function()
                    local result=message[1]; table.remove(message,1); return result
                end,
            }
            function deliver(p,id,frame)
                message={id,frame}
                receiver(64,p)
            end
        ''')
        constants = []
        for name in ("BUILD_STALL_SECONDS", "BUILD_MAX_RETRIES"):
            constants.append(re.search(r"local " + name + r" = [^\n]+", source).group(0))
        self.update = self.lua.execute("\n".join(constants) + "\n" + source[handler_start:handler_end]
                                       + source[update_start:update_end] + "\nreturn update_build_job")
        self.g = self.lua.globals()
        self.job = self.lua.table_from({"id":7,"currentFrame":100,"endFrame":500,
                                       "lastRequestedBuildFrames":16,"sentPlan":True,
                                       "lastRequestAt":0,"buildRetries":2,
                                       "ent":self.lua.table_from({}),"frames":self.lua.table_from({})})
        self.g.MMDVMDNPC.BuildJobs[self.g.ply] = self.job

    def heartbeat(self, frame, time, build_id=7, player=None):
        self.g.clock = time
        self.g.deliver(player or self.g.ply, build_id, frame)

    def tick(self, time):
        self.g.clock = time
        self.update(self.g.ply, self.job, time)

    def assert_not_refreshed(self, last_request=0, retries=2):
        self.assertEqual(self.job.lastRequestAt,last_request)
        self.assertEqual(self.job.buildRetries,retries)

    def test_progress_refreshes_timeout_without_accepting_unreturned_frames(self):
        self.heartbeat(100,7)
        self.assertEqual(self.job.lastRequestAt,7)
        self.assertEqual(self.job.buildRetries,0)
        self.assertEqual(self.job.lastClientProgress,100)
        self.assertEqual(self.job.currentFrame,100)
        self.assertEqual(len(self.job.frames),0)
        self.tick(14)
        self.assertEqual(self.g.requests,0)
        self.heartbeat(101,14)
        self.tick(21)
        self.assertEqual(self.g.requests,0)
        self.assertIsNotNone(self.g.MMDVMDNPC.BuildJobs[self.g.ply])

    def test_repeated_and_backwards_frames_do_not_refresh(self):
        self.heartbeat(103,4)
        self.heartbeat(103,7)
        self.heartbeat(102,9)
        self.assert_not_refreshed(last_request=4,retries=0)
        self.tick(12)
        self.assertEqual(self.g.requests,1)
        self.assertEqual(self.job.buildRetries,1)

    def test_outside_batch_unknown_player_or_build_cannot_refresh(self):
        for frame in (0,99,116,500,2**32-1):
            self.heartbeat(frame,7)
            self.assert_not_refreshed()
        self.heartbeat(100,7,build_id=8)
        self.heartbeat(100,7,player=self.g.other)
        self.assert_not_refreshed()
        self.assertIsNone(self.job.lastClientProgress)

    def test_unrequested_unplanned_and_saving_jobs_cannot_refresh(self):
        for field,value in (("lastRequestedBuildFrames",None),("lastRequestedBuildFrames",0),
                            ("lastRequestAt",None),("sentPlan",False),
                            ("cacheWriter",self.lua.table_from({}))):
            original = self.job[field]
            self.job[field] = value
            old_time,old_retries = self.job.lastRequestAt,self.job.buildRetries
            self.heartbeat(100,7)
            self.assertEqual(self.job.lastRequestAt,old_time)
            self.assertEqual(self.job.buildRetries,old_retries)
            self.job[field] = original
        self.g.MMDVMDNPC.BuildJobs[self.g.ply] = None
        self.g.MMDVMDNPC.BuildQueues[self.g.ply] = self.lua.table_from([self.job])
        self.heartbeat(100,7)
        self.assert_not_refreshed()

    def test_new_batch_rejects_previous_batch_progress(self):
        self.heartbeat(115,7)
        self.job.currentFrame,self.job.lastRequestAt = 116,8
        self.heartbeat(115,14)
        self.assert_not_refreshed(last_request=8,retries=0)
        self.heartbeat(116,14)
        self.assertEqual(self.job.lastRequestAt,14)
        self.assertEqual(self.job.lastClientProgress,116)

    def test_dead_client_still_retries_then_aborts(self):
        self.job.buildRetries = 0
        for time in (8,16,24):
            self.tick(time)
        self.assertEqual(self.g.requests,3)
        self.tick(32)
        self.assertIsNone(self.g.MMDVMDNPC.BuildJobs[self.g.ply])
        self.assertFalse(self.g.done.ok)
        self.assertEqual(self.g.done.id,7)
        self.assertIn("timed out",self.g.done.message)
        self.assertEqual(self.g.next_jobs,1)

    def test_progress_after_a_retry_recovers_but_replays_still_expire(self):
        self.job.buildRetries = 0
        self.tick(8)
        self.assertEqual(self.job.buildRetries,1)
        self.heartbeat(100,9)
        self.assertEqual(self.job.buildRetries,0)
        for time in (17,25,33,41):
            self.heartbeat(100,time)
            self.tick(time)
        self.assertIsNone(self.g.MMDVMDNPC.BuildJobs[self.g.ply])
        self.assertEqual(self.g.done.id,7)

    def test_saving_job_does_not_retry_client(self):
        self.job.cacheWriter = self.lua.table_from({})
        self.tick(100)
        self.assertEqual(self.g.requests,0)
        self.assertEqual(self.g.saves,1)


if __name__ == "__main__":
    unittest.main()