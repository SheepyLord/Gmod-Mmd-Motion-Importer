"""Run: python -m unittest discover -s tests -p test_ui_refresh.py (requires lupa).

Executes the actual Lua functions with mocked Derma/net lifecycles.
"""
from pathlib import Path
import unittest
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'mmd_vmd_npc/lua/weapons/gmod_tool/stools/mmd_vmd_npc.lua'
MENU = ROOT / 'mmd_vmd_npc/lua/mmd_vmd_npc/cl_menu.lua'


class UIRefreshTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('''
            unpack = table.unpack or unpack
            function IsValid(v) return type(v) == "table" and not v.removed end
            function istable(v) return type(v) == "table" end
            function L(v) return v end
            selected = "a"
            function GetConVar() return { GetString = function() return selected end } end
            stoolCategoryFilter = ""
            MMDVMDNPC = { MotionDetailsOrdered = {}, MotionDetails = {}, ClientMotions = {} }
            function MMDVMDNPC.CategoryDisplayName(v) return v end
            function MMDVMDNPC.MotionMatchesCategory(meta, category)
                return category == "" or (meta and meta.category == category)
            end
            function motion_display_name(meta)
                if type(meta) == "string" then
                    return (MMDVMDNPC.MotionDetails[meta] or {}).displayName or meta
                end
                return meta.displayName or meta.id
            end
            motionSearch = { query = "", GetValue = function(self) return self.query end }
            motionList = { clears = 0, adds = 0, selects = 0, rows = {} }
            function motionList:Clear()
                self.clears = self.clears + 1
                for _, line in ipairs(self.rows) do line.removed = true end
                self.rows = {}; self.selected = nil
            end
            function motionList:AddLine(...)
                self.adds = self.adds + 1
                local line = { cells = {...} }
                self.rows[#self.rows + 1] = line
                return line
            end
            function motionList:SelectItem(line)
                self.selects = self.selects + 1; self.selected = line
                if self.OnRowSelected then self:OnRowSelected(0, line) end
            end
            function motionList:ClearSelection() self.selected = nil end
            function set_motions(name, duration, built, source)
                local a = { id = "a", displayName = name or "Alpha", englishName = "Alpha",
                    category = "Pack", duration = duration or 4, built = built, sourceName = source }
                local b = { id = "b", displayName = "Beta", englishName = "Beta", category = "Other", duration = 5 }
                MMDVMDNPC.MotionDetailsOrdered = { a, b }; MMDVMDNPC.MotionDetails = { a = a, b = b }
                MMDVMDNPC.ClientMotions = { "a", "b" }
            end
            set_motions()
        ''')
        source = TOOL.read_text(encoding='utf-8')
        start = source.index('    local function duration_text(meta)')
        end = source.index('    -- The list/details hooks fire in bursts', start)
        self.refresh = self.lua.execute(source[start:end] + '''
            motionList.OnRowSelected = function()
                assert(suppressRowSelect, "refresh emitted an interactive selection")
            end
            return refresh_motion_list_now
        ''')
        self.g = self.lua.globals()

    def test_selection_status_retains_rows_and_refreshes_metadata(self):
        self.refresh()
        for i in range(100):
            self.g.set_motions('Alpha', 4, i % 2 == 0, str(i)); self.refresh()
        self.assertEqual(self.g.motionList.clears, 1)
        self.assertEqual(self.g.motionList.adds, 2)
        self.assertEqual(self.g.motionList.selects, 1)
        self.assertEqual(self.g.motionList.rows[1].Meta.sourceName, '99')
        self.assertTrue(self.lua.eval('motionList.rows[1].Meta == MMDVMDNPC.MotionDetails.a'))

    def test_changed_visible_metadata_rebuilds_rows(self):
        self.refresh(); self.g.set_motions('New display name', 6, False, 'replacement'); self.refresh()
        self.assertEqual(self.g.motionList.clears, 2)
        self.assertEqual(self.g.motionList.rows[1].cells[1], 'New display name')
        self.assertEqual(self.g.motionList.rows[1].cells[4], '6.00s')

    def test_filter_keeps_selected_motion_and_restores_it(self):
        self.refresh(); self.g.stoolCategoryFilter = 'Other'; self.refresh()
        self.assertEqual(self.g.motionList.rows[1].MotionID, 'b')
        self.assertEqual(self.g.motionList.rows[2].MotionID, 'a')
        self.assertEqual(self.g.motionList.selected.MotionID, 'a')
        self.g.stoolCategoryFilter = ''; self.g.motionSearch.query = 'no match'; self.refresh()
        self.assertEqual(len(self.g.motionList.rows), 1)
        self.assertEqual(self.g.motionList.rows[1].MotionID, 'a')
        self.g.motionSearch.query = ''; self.refresh()
        self.assertEqual(len(self.g.motionList.rows), 2)

    def test_external_selection_does_not_rebuild_and_can_clear(self):
        self.refresh(); self.g.selected = 'b'; self.refresh()
        self.assertEqual(self.g.motionList.clears, 1)
        self.assertEqual(self.g.motionList.selected.MotionID, 'b')
        self.g.selected = ''; self.refresh()
        self.assertIsNone(self.g.motionList.selected)
        self.assertEqual(self.g.motionList.clears, 1)

    def test_missing_selection_and_bare_list_transition(self):
        self.lua.execute('MMDVMDNPC.MotionDetailsOrdered = {}; MMDVMDNPC.MotionDetails = {}')
        self.refresh()
        self.assertEqual(self.g.motionList.rows[1].cells[4], 'mmd_vmd_npc.ui.loading')
        self.g.set_motions(); self.refresh()
        self.assertEqual(self.g.motionList.rows[1].cells[4], '4.00s')
        self.lua.execute('MMDVMDNPC.MotionDetailsOrdered = {}; MMDVMDNPC.MotionDetails = {}; MMDVMDNPC.ClientMotions = {}')
        self.refresh()
        self.assertEqual(len(self.g.motionList.rows), 1)
        self.assertEqual(self.g.motionList.rows[1].cells[4], 'mmd_vmd_npc.ui.missing')


class RequestCoalescingTests(unittest.TestCase):
    def test_burst_sends_once_with_latest_options_and_allows_later_refresh(self):
        lua = LuaRuntime()
        lua.execute('''
            callbacks = {}; options = {}
            timer = { Simple = function(delay, cb) assert(delay == 0); callbacks[#callbacks + 1] = cb end }
            function selected_options() return options end
            net = { sends = 0, values = {} }
            function net.Start(name) assert(name == "mmdvmd_motion_details_request"); net.values = {} end
            function net.WriteBool(value) net.values[#net.values + 1] = value end
            function net.SendToServer() net.sends = net.sends + 1 end
        ''')
        source = MENU.read_text(encoding='utf-8')
        start = source.index('local motionDetailsRequestQueued = false')
        end = source.index('function MMDVMDNPC.RequestMotionDetails()', start)
        request = lua.execute(source[start:end] + 'return request_motion_details')
        for _ in range(3): request()
        g = lua.globals()
        self.assertEqual(len(g.callbacks), 1)
        self.assertEqual(g.net.sends, 0)
        g.options.disableEyes = True; g.callbacks[1]()
        self.assertEqual(g.net.sends, 1)
        self.assertTrue(g.net["values"][3])
        request(); self.assertEqual(len(g.callbacks), 2); g.callbacks[2]()
        self.assertEqual(g.net.sends, 2)


if __name__ == '__main__':
    unittest.main()
