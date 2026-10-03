-- Explicit isolated-instance runner. NEVER autorun this file.
-- Launch only with -port 27045 -clientport 27046 +lua_openscript mmd_vmd_npc/tests/sv_engine_smoke.lua
-- tests/bootstrap.lua must be a staged copy of the addon's autorun entry point.
if CLIENT then return end
assert(port and port:GetInt() == 27045, "MMD smoke runner is restricted to isolated test port 27045")
if MMDVMDNPC and MMDVMDNPC.EngineSmokeRunning then return end
MMDVMDNPC = MMDVMDNPC or {}
MMDVMDNPC.EngineSmokeRunning = true
include("mmd_vmd_npc/tests/bootstrap.lua")
AddCSLuaFile("mmd_vmd_npc/tests/bootstrap.lua")
AddCSLuaFile("mmd_vmd_npc/tests/cl_build_regression.lua")
AddCSLuaFile("mmd_vmd_npc/tests/cl_engine_smoke.lua")
util.AddNetworkString("mmdvmd_test_stage")
util.AddNetworkString("mmdvmd_test_control")
RunConsoleCommand("ai_disabled", "1")
local report = { tests = {}, failures = {}, started = SysTime() }
local owner, actor, selectedModel, pendingPath, cancelledPath, motionID, cancelledID
local ownedFiles = {}
local originalPlayer, selfProxy
local phase = "waiting_player"
local started = SysTime()
local options = { disableArmTwist = false, disableHandTwist = false, disableEyes = false, disableSpinePelvisCorrection = false }
local settings = { startDelay = 2, buildFramesPerBatch = 128, playbackHz = 60, musicEnabled = false, loopPlayback = true, pelvisZOffset = 0 }
local function save()
    file.CreateDir("mmd_vmd_npc")
    file.Write("mmd_vmd_npc/performance_smoke_server.json", util.TableToJSON(report, true))
end
local function check(name, ok, detail)
    report.tests[#report.tests + 1] = { name = name, passed = ok == true, detail = tostring(detail or "") }
    if not ok then report.failures[#report.failures + 1] = name .. ": " .. tostring(detail or "failed") end
    print("[MMD ENGINE] " .. (ok and "PASS " or "FAIL ") .. name .. " " .. tostring(detail or ""))
    save()
    return ok
end
local function control(action)
    net.Start("mmdvmd_test_control")
    net.WriteString(action)
    net.Send(owner)
end
local function cleanup()
    if IsValid(owner) then
        MMDVMDNPC.CancelBuildTasksForPlayer(owner)
        MMDVMDNPC.StopSelfPlaybackForPlayer(owner, true)
        if originalPlayer then
            owner:SetModel(originalPlayer.model)
            owner:SetNoDraw(originalPlayer.noDraw)
        end
    end
    if IsValid(actor) then MMDVMDNPC.StopPlayback(actor, true); actor:Remove() end
    for _, path in ipairs(ownedFiles) do
        file.Delete(path)
        if MMDVMDNPC.BuiltCache then MMDVMDNPC.BuiltCache[path] = nil end
        if MMDVMDNPC.ForgetBuiltHeader then MMDVMDNPC.ForgetBuiltHeader(path) end
    end
    for _, id in ipairs({ motionID, cancelledID }) do
        if id and MMDVMDNPC.ForgetMotionMeta then MMDVMDNPC.ForgetMotionMeta(id) end
        if id and MMDVMDNPC.Cache then MMDVMDNPC.Cache[id] = nil end
    end
end
local function finish_report()
    cleanup()
    timer.Remove("MMDVMDNPC.EngineSmoke")
    report.elapsedSeconds = SysTime() - started
    report.finished = true
    save()
    print("[MMD ENGINE] COMPLETE " .. util.TableToJSON(report))
    -- Launcher owns the isolated PID and closes it after reading this report.
    -- GMod deliberately blocks Lua from executing the quit console command.
end
local function finish()
    if phase == "finishing" then return end
    phase = "finishing"
    if IsValid(owner) then control("finish"); timer.Simple(5, function() if phase == "finishing" then finish_report() end end) else finish_report() end
end
local function make_motion(id, count)
    local tracks = {}
    for _, bone in ipairs({ "Pelvis", "Spine", "Spine1", "Spine2", "Spine4", "Neck1", "Head1", "L_Clavicle", "R_Clavicle", "L_UpperArm", "L_Forearm", "L_Hand", "R_UpperArm", "R_Forearm", "R_Hand", "L_Thigh", "L_Calf", "L_Foot", "R_Thigh", "R_Calf", "R_Foot" }) do
        local index = #tracks + 1
        tracks[index] = { g = "ValveBiped.Bip01_" .. bone, m = bone, k = {
            { 0, index, -index * 2, index * 0.5, 0, 0, 0 },
            { count - 1, -index, index * 2, -index * 0.5, bone == "Pelvis" and 5 or 0, 0, 0 },
        } }
    end
    local fixture = { format = "mmd_vmd_npc_parent_corrected_axis_v1", frame_start = 0, frame_end = count - 1, frame_count = count, fps = 30, bones = tracks, flexes = {} }
    local path = MMDVMDNPC.MotionPath(id)
    assert(not file.Exists(path, "DATA"), "test ID unexpectedly exists")
    file.CreateDir(MMDVMDNPC.MotionRoot)
    file.Write(path, util.TableToJSON(fixture))
    ownedFiles[#ownedFiles + 1] = path
end
local function begin_build(id, count, reuseMotion)
    if not reuseMotion then make_motion(id, count) end
    local ok, path = MMDVMDNPC.BeginBuildForPlayer(owner, id, options, settings)
    check("start " .. id, ok, path)
    if not ok then finish(); return nil end
    ownedFiles[#ownedFiles + 1] = path
    return path
end
net.Receive("mmdvmd_test_stage", function(_, ply)
    if ply ~= owner then return end
    local stage = net.ReadString()
    if stage == "comparisons_done" and phase == "comparing" then
        local clientReport = util.JSONToTable(file.Read("mmd_vmd_npc/performance_smoke_client.json", "DATA") or "{}") or {}
        check("client differential comparisons", #(clientReport.failures or {}) == 0 and #(clientReport.comparisons or {}) == 3)
        control("arm_cancel")
        cancelledPath = begin_build(cancelledID, 600)
        if cancelledPath then phase = "cancelling" end
    elseif stage == "client_cancelled" and phase == "cancelling" then
        phase = "cancelled_wait"
    elseif stage == "legacy_ready" and phase == "waiting_legacy" then
        cancelledPath = begin_build(cancelledID, 600, true)
        if cancelledPath then phase = "legacy_cancelling" end
    elseif stage == "client_cancelled" and phase == "legacy_cancelling" then
        phase = "legacy_cancelled_wait"
    elseif stage == "client_finished" and phase == "finishing" then
        local client = util.JSONToTable(file.Read("mmd_vmd_npc/performance_smoke_client.json", "DATA") or "{}") or {}
        local cancelled = client.cancellations or {}
        check("both worker modes cancelled during active slices", #cancelled == 2 and client.legacyModeVerified == true
            and cancelled[1].mode == "fast" and cancelled[2].mode == "legacy"
            and cancelled[1].workerCleared == true and cancelled[2].workerCleared == true
            and cancelled[1].slices >= 3 and cancelled[2].slices >= 3)
        check("client workers and jobs cleaned up", client.buildJobsRemaining == 0 and client.workerTasksRemaining == 0 and #(client.failures or {}) == 0)
        phase = "finished"
        finish_report()
    end
end)
timer.Create("MMDVMDNPC.EngineSmoke", 0.05, 0, function()
    local ok, err = pcall(function()
        if SysTime() - started > 180 then check("test timeout", false, phase); finish(); return end
        if phase == "waiting_player" then
            owner = player.GetHumans()[1]
            if not IsValid(owner) then return end
            actor = ents.Create("npc_citizen")
            assert(IsValid(actor), "failed to create test NPC")
            actor:SetPos(owner:GetPos() + Vector(0, 0, 100))
            actor:Spawn()
            for _, model in ipairs({ "models/sheepylord/honkai_star_rail/firefly.mdl", "models/sheepylord/wuthering_waves/the_shorekeeper.mdl", "models/player/kleiner.mdl" }) do
                if util.IsValidModel(model) then
                    actor:SetModel(model)
                    local reference = MMDVMDNPC.LookupRequiredReferenceSequenceInfo(actor)
                    if reference then selectedModel = model; report.reference = reference.name or tostring(reference.seq); break end
                end
            end
            assert(selectedModel, "no installed test model has a supported Reference sequence")
            report.model = selectedModel
            actor:SetModel(selectedModel)
            local selected, reason = MMDVMDNPC.SelectTargetForPlayer(owner, actor)
            assert(selected, reason)
            local token = util.CRC(tostring(SysTime()) .. tostring(os.time()))
            motionID, cancelledID = "mmd_perftest_" .. token, "mmd_perftest_cancel_" .. token
            phase = "comparing"
            owner:SendLua("include('mmd_vmd_npc/tests/bootstrap.lua'); MMDVMDNPCPerformanceTestModel=" .. string.format("%q", selectedModel) .. "; include('mmd_vmd_npc/tests/cl_engine_smoke.lua')")
            save()
        elseif phase == "cancelled_wait" and not MMDVMDNPC.BuildJobs[owner] then
            check("cancel removed server job and unpublished cache", not file.Exists(cancelledPath, "DATA") and MMDVMDNPC.BuiltCache[cancelledPath] == nil)
            pendingPath = begin_build(motionID, 10)
            if pendingPath then phase = "building" end
        elseif phase == "building" and not MMDVMDNPC.BuildJobs[owner] then
            local contents = file.Read(pendingPath, "DATA")
            local built = contents and util.JSONToTable(contents)
            assert(check("network build publishes readable cache", istable(built), pendingPath))
            assert(check("cache contains all 10 sequential frames", #built.frames == 10 and built.frames[1].frame == 0 and built.frames[10].frame == 9))
            for _, frame in ipairs(built.frames) do assert(#frame.bones > 0, "empty bone frame") end
            check("cache frames have resolved bones", true, #built.frames[1].bones)
            MMDVMDNPC.BuiltCache[pendingPath] = nil
            local played, reason, state = MMDVMDNPC.StartPlaybackForPlayer(owner, motionID, options, settings)
            assert(check("playback reloads saved cache", played, reason))
            assert(state, "missing playback state")
            phase = "playback"
            report.playbackStarted = SysTime()
        elseif phase == "playback" and SysTime() - report.playbackStarted > 3 then
            check("NPC playback remains active", MMDVMDNPC.Playbacks[actor] ~= nil)
            MMDVMDNPC.StopPlayback(actor, true)
            check("NPC stop clears playback", MMDVMDNPC.Playbacks[actor] == nil)
            originalPlayer = {
                model = owner:GetModel(), noDraw = owner:GetNoDraw(), moveType = owner:GetMoveType(),
                frozen = owner:IsFrozen(), weapons = {},
            }
            for _, weapon in ipairs(owner:GetWeapons()) do originalPlayer.weapons[weapon] = weapon:GetNoDraw() end
            owner:SetModel(selectedModel)
            local selected, reason = MMDVMDNPC.SelectTargetForPlayer(owner, owner)
            assert(check("player target selects supported model", selected, reason))
            options.disableSpinePelvisCorrection = true -- Distinct cache key requires a real self build.
            phase = "waiting_legacy"
            control("arm_legacy_cancel")
        elseif phase == "legacy_cancelled_wait" and not MMDVMDNPC.BuildJobs[owner] then
            check("legacy player cancellation leaves no published cache", not file.Exists(cancelledPath, "DATA") and MMDVMDNPC.BuiltCache[cancelledPath] == nil)
            pendingPath = begin_build(motionID, 10, true)
            if pendingPath then phase = "player_building" end
        elseif phase == "player_building" and not MMDVMDNPC.BuildJobs[owner] then
            local contents = file.Read(pendingPath, "DATA")
            local built = contents and util.JSONToTable(contents)
            assert(check("legacy player build publishes readable cache", istable(built), pendingPath))
            assert(check("legacy player cache contains 10 sequential frames", #built.frames == 10 and built.frames[1].frame == 0 and built.frames[10].frame == 9))
            for _, frame in ipairs(built.frames) do assert(#frame.bones > 0, "empty legacy bone frame") end
            MMDVMDNPC.BuiltCache[pendingPath] = nil
            local played, reason, state, proxy = MMDVMDNPC.StartPlaybackForPlayer(owner, motionID, options, settings)
            assert(check("self playback reloads legacy cache", played, reason))
            assert(check("self playback creates dedicated proxy", state and state.selfProxy == true and state.realPlayer == owner and IsValid(proxy) and proxy ~= owner))
            selfProxy = proxy
            check("self playback hides and locks the player", owner:GetNoDraw() and MMDVMDNPC.SelfPlaybackMovementLocks[owner] == true and owner:GetNWBool("MMDVMDNPCSelfPlaybackLock", false))
            phase = "self_playback"
            report.selfPlaybackStarted = SysTime()
        elseif phase == "self_playback" and SysTime() - report.selfPlaybackStarted > 3 then
            check("self playback remains active", IsValid(selfProxy) and MMDVMDNPC.Playbacks[selfProxy] ~= nil)
            MMDVMDNPC.StopSelfPlaybackForPlayer(owner, true)
            check("self stop clears proxy and playback mappings", MMDVMDNPC.SelfPlaybackProxies[owner] == nil and MMDVMDNPC.Playbacks[selfProxy] == nil)
            check("self stop restores player visibility", owner:GetNoDraw() == originalPlayer.noDraw)
            local restoredWeapons = true
            for weapon, noDraw in pairs(originalPlayer.weapons) do
                if IsValid(weapon) and weapon:GetNoDraw() ~= noDraw then restoredWeapons = false end
            end
            check("self stop restores weapon visibility", restoredWeapons)
            check("self stop releases movement", MMDVMDNPC.SelfPlaybackMovementLocks[owner] == nil and not owner:GetNWBool("MMDVMDNPCSelfPlaybackLock", false) and owner:GetMoveType() == originalPlayer.moveType and owner:IsFrozen() == originalPlayer.frozen)
            -- Entity:Remove keeps the entity valid until the next engine tick.
            -- Ownership/state must clear now; test engine removal on a later tick.
            phase = "self_stopped"
            report.selfPlaybackStopped = SysTime()
        elseif phase == "self_stopped" and SysTime() - report.selfPlaybackStopped >= 0.05 then
            check("self stop removes proxy on the next tick", not IsValid(selfProxy))
            finish()
        end
    end)
    if not ok then check("runner error", false, err); finish() end
end)
print("[MMD ENGINE] Isolated smoke runner started on port 27045")
