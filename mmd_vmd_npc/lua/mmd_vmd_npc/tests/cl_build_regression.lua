-- Developer-only differential check. Never included by the addon autorun.
-- Load: lua_openscript_cl mmd_vmd_npc/tests/cl_build_regression.lua
-- Run:  mmd_vmd_npc_test_build [models/your_model.mdl]
-- Optional shipped-motion check: mmd_vmd_npc_test_build_motion [model] [motion_id]
-- Comparisons create and remove dedicated invisible models. No player/NPC is posed,
-- no network messages are sent, and no build caches or settings are changed.
if SERVER then return end
local command = "mmd_vmd_npc_test_build"
local timerName = "MMDVMDNPC.DeveloperBuildRegression"
local reportPath = "mmd_vmd_npc/build_regression.json"
local active = false

local boneNames = {
    "ValveBiped.Bip01_Pelvis", "ValveBiped.Bip01_Spine", "ValveBiped.Bip01_Spine1",
    "ValveBiped.Bip01_Spine2", "ValveBiped.Bip01_Spine4", "ValveBiped.Bip01_Neck1",
    "ValveBiped.Bip01_Head1", "ValveBiped.Bip01_L_Clavicle", "ValveBiped.Bip01_R_Clavicle",
}
for _, side in ipairs({ "L", "R" }) do
    for _, part in ipairs({ "UpperArm", "Forearm", "Hand", "Thigh", "Calf", "Foot", "Toe0" }) do
        boneNames[#boneNames + 1] = "ValveBiped.Bip01_" .. side .. "_" .. part
    end
    for finger = 0, 4 do
        for _, suffix in ipairs({ "", "1", "2" }) do
            boneNames[#boneNames + 1] = "ValveBiped.Bip01_" .. side .. "_Finger" .. finger .. suffix
        end
    end
end
boneNames[#boneNames + 1] = "MMD_TEST_missing_bone"

local function synthetic_frames()
    local frames = {}
    -- Neutral -> motion -> neutral catches residual manipulations. Large wraps,
    -- near-gimbal rotations, translated pelvis, and reordered input exercise
    -- conversion without depending on math.random or changing its global seed.
    for frame = 1, 32 do
        local rows = {}
        for i, source in ipairs(boneNames) do
            local neutral = frame == 1 or frame == 16 or frame == 32
            local phase = frame * 0.31 + i * 0.71
            local x = neutral and 0 or math.sin(phase) * 85
            local y = neutral and 0 or math.cos(phase * 0.73) * 110
            local z = neutral and 0 or math.sin(phase * 0.47) * 175
            if frame == 8 then x, y, z = 89.999, -179.99, 179.99 end
            if frame == 9 then x, y, z = -89.999, 179.99, -179.99 end
            if frame == 10 then x, y, z = 270, -360, 540 end
            local root = source == "ValveBiped.Bip01_Pelvis"
            local row = {
                source = source, x = x, y = y, z = z,
                px = root and not neutral and math.sin(phase) * 25 or 0,
                py = root and not neutral and math.cos(phase) * 20 or 0,
                pz = root and not neutral and math.sin(phase * 0.5) * 8 or 0,
            }
            if source == "ValveBiped.Bip01_Spine" then row.role = "source_parent_override" end
            table.insert(rows, 1, row) -- Stable but deliberately reversed hierarchy order.
        end
        frames[#frames + 1] = {
            rows = rows,
            flexRows = {
                { resolved = true, flexID = 0, weight = (frame % 5) / 4, source = "mouth_a" },
                { resolved = true, flexID = 1, weight = 1.5, source = "blink" },
                { resolved = true, flexID = 2, weight = -0.1, source = "brow_up" },
                { resolved = false, flexID = -1, weight = 0.8, source = "unresolved" },
            },
        }
    end
    return frames
end

local function motion_frames(id)
    if not string.match(id, "^[%w_%-]+$") then return nil, "invalid motion id" end
    local relative = "mmd_vmd_npc/motions/" .. id .. ".json"
    local contents = file.Read(relative, "DATA") or file.Read("data_static/" .. relative, "GAME")
    if not contents then return nil, "motion JSON not found: " .. relative end
    local motion = util.JSONToTable(contents)
    if not motion or not istable(motion.bones) then return nil, "invalid motion JSON" end
    local frames = {}
    for index = 0, 15 do
        local frameNumber = (motion.frame_start or 0) + ((motion.frame_end or 0) - (motion.frame_start or 0)) * index / 15
        local rows = {}
        for _, track in ipairs(motion.bones) do
            -- Sample an actual key at/before each timeline point. The purpose is
            -- real authored rotation coverage, not testing the motion sampler.
            local keys = track.k or {}
            local low, high = 1, #keys
            while low < high do
                local mid = math.ceil((low + high) / 2)
                if keys[mid][1] <= frameNumber then low = mid else high = mid - 1 end
            end
            local key = keys[low]
            if key then
                rows[#rows + 1] = {
                    source = track.g or "", mmd = track.m or "", role = track.role or "",
                    x = key[2] or 0, y = key[3] or 0, z = key[4] or 0,
                    px = key[5] or 0, py = key[6] or 0, pz = key[7] or 0,
                }
            end
        end
        frames[#frames + 1] = { rows = rows, flexRows = {} }
    end
    return frames
end

local function run(args, motionID)
    if active then print("[MMD TEST] A regression is already running."); return end
    if not MMDVMDNPC or not MMDVMDNPC.CompareBuildPaths then
        print("[MMD TEST] This addon version does not expose CompareBuildPaths.")
        return
    end
    if next(MMDVMDNPC.ClientBuildJobs or {}) ~= nil then
        print("[MMD TEST] Finish/cancel the current animation build before running the regression.")
        return
    end
    local models = args[1] and { args[1] } or { "models/player/kleiner.mdl", "models/alyx.mdl" }
    local frames, err
    if motionID then frames, err = motion_frames(motionID) else frames = synthetic_frames() end
    if not frames then print("[MMD TEST] " .. tostring(err)); return end
    local tests = {}
    for _, model in ipairs(models) do
        for _, angles in ipairs({ Angle(0, 0, 0), Angle(0, 123, 0), Angle(17, -71, 11) }) do
            tests[#tests + 1] = { model = model, angles = angles }
        end
    end
    local output = { source = motionID or "synthetic", results = {}, passed = 0, failed = 0, settings = {} }
    for _, name in ipairs({ "disable_armtwist", "disable_handtwist", "disable_eyes", "disable_spine_pelvis_correction", "fast_build" }) do
        local cv = GetConVar("mmd_vmd_npc_" .. name)
        output.settings[name] = cv and cv:GetString() or "unavailable"
    end
    active = true
    local index = 0
    timer.Create(timerName, 0.1, #tests, function()
        index = index + 1
        local test = tests[index]
        local ok, result, failure = pcall(MMDVMDNPC.CompareBuildPaths, test.model, frames, { angles = test.angles })
        if not ok then failure, result = result, nil end
        local passed = result ~= nil
            and (result.frameCount or 0) == #frames and (result.packetCount or 0) > 0
            and (result.maxAngularError or math.huge) <= 0.5
            and (result.maxPositionError or math.huge) <= 0.01
            and (result.maxFlexError or math.huge) <= 0.000001
        local entry = { model = test.model, angles = { test.angles.p, test.angles.y, test.angles.r }, passed = passed, report = result, error = failure }
        output.results[#output.results + 1] = entry
        local counter = passed and "passed" or "failed"
        output[counter] = output[counter] + 1
        print("[MMD TEST] " .. (passed and "PASS " or "FAIL ") .. util.TableToJSON(entry))
        if index == #tests then
            active = false
            file.CreateDir("mmd_vmd_npc")
            file.Write(reportPath, util.TableToJSON(output, true))
            hook.Run("MMDVMDNPCBuildRegressionComplete", output)
            print(string.format("[MMD TEST] COMPLETE: %d passed, %d failed; data/%s", output.passed, output.failed, reportPath))
        end
    end)
end

concommand.Add(command, function(_, _, args) run(args) end)
concommand.Add(command .. "_motion", function(_, _, args)
    run(args, args[2] or "motion_8f38d4be83_98de5fe977")
end)
concommand.Add(command .. "_cancel", function()
    timer.Remove(timerName)
    active = false
    print("[MMD TEST] Pending regression cases cancelled.")
end)
print("[MMD TEST] Loaded. Run " .. command .. " [models/your_model.mdl] or " .. command .. "_motion [model] [motion_id].")
