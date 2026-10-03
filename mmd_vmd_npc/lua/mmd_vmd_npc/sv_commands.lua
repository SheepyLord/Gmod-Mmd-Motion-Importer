MMDVMDNPC = MMDVMDNPC or {}
MMDVMDNPC.DebugTargets = MMDVMDNPC.DebugTargets or {}
MMDVMDNPC.AssignedActors = MMDVMDNPC.AssignedActors or {}
MMDVMDNPC.BuildJobs = MMDVMDNPC.BuildJobs or {}
MMDVMDNPC.BuildQueues = MMDVMDNPC.BuildQueues or {}
MMDVMDNPC.BuiltCache = MMDVMDNPC.BuiltCache or {}
MMDVMDNPC.Playbacks = MMDVMDNPC.Playbacks or {}
MMDVMDNPC.SelfPlaybackProxies = MMDVMDNPC.SelfPlaybackProxies or {}
MMDVMDNPC.SelfPlaybackVisuals = MMDVMDNPC.SelfPlaybackVisuals or {}
MMDVMDNPC.SelfPlaybackMovementLocks = MMDVMDNPC.SelfPlaybackMovementLocks or {}
MMDVMDNPC.EyeTrackCameraTargets = MMDVMDNPC.EyeTrackCameraTargets or {}
MMDVMDNPC.CVarSuppressions = MMDVMDNPC.CVarSuppressions or {}
MMDVMDNPC.CVarOriginals = MMDVMDNPC.CVarOriginals or {}
MMDVMDNPC.RPEBodySuppressionToken = MMDVMDNPC.RPEBodySuppressionToken or nil
MMDVMDNPC.AudioOffsets = MMDVMDNPC.AudioOffsets or nil

MMDVMDNPC.PendingBuildConfirm = MMDVMDNPC.PendingBuildConfirm or {}  
MMDVMDNPC.PendingAutoPlay = MMDVMDNPC.PendingAutoPlay or {}          

local ZERO_VECTOR = Vector(0, 0, 0)
local ZERO_ANGLE = Angle(0, 0, 0)
local ONE_SCALE = Vector(1, 1, 1)
local BUILD_PACKET_LIMIT = 4096
-- Hard ceiling on how many frames a single build may accumulate. A build with
-- more source frames than this is rejected up front; without it, a client could
-- stream an unbounded number of frames into job.frames and blow up server RAM
-- and the on-disk JSON.
local BUILD_MAX_FRAMES = 200000
-- Seconds to wait for a client batch reply before re-requesting, and how many
-- re-requests before the stuck job is aborted.
local BUILD_STALL_SECONDS = 8
local BUILD_MAX_RETRIES = 3
local BUILD_FRAMES_PER_BATCH = 64

-- Replace NaN/Inf coming off the wire with 0 so a malformed client cannot write
-- non-finite numbers into the built-cache JSON (which util.JSONToTable then
-- refuses to parse, permanently bricking the cache).
local function finite_number(value)
    value = tonumber(value) or 0
    if value ~= value or value == math.huge or value == -math.huge then
        return 0
    end
    return value
end

-- BuiltCache holds the fully decoded per-frame tables of every built animation.
-- Each entry can be tens of MB, and the JSON always stays on disk, so keep only
-- a bounded MRU set in memory. Entries referenced by an active playback are
-- never evicted (playback also holds its own reference, so eviction is safe —
-- a later playback just re-reads from disk).
MMDVMDNPC.BuiltCacheOrder = MMDVMDNPC.BuiltCacheOrder or {}
local BUILT_CACHE_MAX_ENTRIES = 16

local function built_cache_path_in_use(path)
    for _, state in pairs(MMDVMDNPC.Playbacks or {}) do
        if state and state.path == path then return true end
    end
    return false
end

local function store_built_cache(path, built)
    if not path or path == "" then return end
    MMDVMDNPC.BuiltCache[path] = built
    -- Record the tiny header so clears/deletes can match this file without
    -- re-parsing its multi-MB body (the file is already on disk by here).
    if MMDVMDNPC.NoteBuiltHeader then MMDVMDNPC.NoteBuiltHeader(path, built) end

    local order = MMDVMDNPC.BuiltCacheOrder
    for i = #order, 1, -1 do
        if order[i] == path then table.remove(order, i) end
    end
    order[#order + 1] = path

    local index = 1
    while #order > BUILT_CACHE_MAX_ENTRIES and index <= #order do
        local candidate = order[index]
        if candidate ~= path and not built_cache_path_in_use(candidate) then
            MMDVMDNPC.BuiltCache[candidate] = nil
            table.remove(order, index)
        else
            index = index + 1
        end
    end
end
local PLAYBACK_HZ = 120
local SOURCE_PELVIS = "ValveBiped.Bip01_Pelvis"
local SOURCE_RIGHT_UPPER_ARM = "ValveBiped.Bip01_R_UpperArm"
local SOURCE_RIGHT_FOREARM = "ValveBiped.Bip01_R_Forearm"
local RPE_BODY_CVAR = "sv_rpe_living_body_enable"
local SKIRT_VRD_AUTO_APPLY_CVAR = "skirt_vrd_auto_apply_all"
local RPE_BODY_SUPPRESSED_CVARS = { RPE_BODY_CVAR }
local BUILD_SUPPRESSED_CVARS = { RPE_BODY_CVAR, SKIRT_VRD_AUTO_APPLY_CVAR }
local PLAYBACK_SUPPRESSED_CVARS = { "sv_rpe_living_combat_enable", "sv_rpe_eye_track_enable" }
local DEBUG_REFERENCE_FRAME = -1
local EYE_TRACK_BONE_MOVE_BACK = 0.08
local EYE_TRACK_BONE_POS_UD = 0.75
local EYE_TRACK_BONE_POS_LR = 0.75
local EYE_TRACK_SMOOTH = 20
local nextBuildID = 1
local cleanup_self_proxy_for_player
local clear_build_job
local update_rpe_body_suppression
local force_reference_pose
local clear_all_bone_manipulations
local clear_all_flex_weights
local pose_selected_npc_reference
local require_reference_sequence_for_actor


local MAX_NET_MESSAGE_BYTES = 60000


local EYE_BONE_LEFT_CANDIDATES = {
    "Eye_LD",
    "eye_LD",
    "左目D",
    "目D.L",
    "ValveBiped.Bip01_Eye_L",
    "ValveBiped.Bip01_L_Eye",
    "Eye_L",
    "eye_L",
    "eye_l",
    "EyeL",
    "Eye_l",
    "Left_Eye",
    "left_eye",
    "LeftEye",
    "lefteye",
    "LeftEyeReturn",
    "EyeReturn_L",
    "左目",
    "目.L",
}

local EYE_BONE_RIGHT_CANDIDATES = {
    "Eye_RD",
    "eye_RD",
    "右目D",
    "目D.R",
    "ValveBiped.Bip01_Eye_R",
    "ValveBiped.Bip01_R_Eye",
    "Eye_R",
    "eye_R",
    "eye_r",
    "EyeR",
    "Eye_r",
    "Right_Eye",
    "right_eye",
    "RightEye",
    "righteye",
    "RightEyeReturn",
    "EyeReturn_R",
    "右目",
    "目.R",
}

local EYE_ATTACHMENT_CANDIDATES = {
    "eyes",
    "anim_attachment_eyes",
    "anim_attachment_head",
    "head",
}

local function L(key, fallback)
    return MMDVMDNPC.L and MMDVMDNPC.L(key, fallback) or (fallback or key)
end

local function LF(key, ...)
    return MMDVMDNPC.LFormat and MMDVMDNPC.LFormat(key, ...) or string.format(L(key, key), ...)
end

-- Who may mutate/delete shared server content (motions, built caches, flex
-- overrides, audio offsets). "admin" (default) restricts it to admins; set to
-- "all" to let any player edit. Singleplayer and listen hosts are admins, so
-- the default does not affect solo use — it only blocks non-admin clients on
-- dedicated servers from wiping content for everyone.
local EDIT_PERMISSION_CVAR = CreateConVar(
    "mmd_vmd_npc_edit_permission",
    "admin",
    FCVAR_ARCHIVE + FCVAR_NOTIFY,
    "Who may delete/modify shared MMD VMD content: 'admin' or 'all'."
)

local function player_can_edit_content(ply)
    if not IsValid(ply) then return true end -- console / server-side callers
    if string.lower(EDIT_PERMISSION_CVAR:GetString()) == "all" then return true end
    if game.SinglePlayer() then return true end
    return ply:IsAdmin()
end

local function deny_edit_permission(ply)
    if IsValid(ply) then
        MMDVMDNPC.Chat(ply, L("mmd_vmd_npc.status.edit_permission_denied", "only admins may modify or delete shared MMD VMD content on this server"))
    end
end

hook.Add("PlayerDisconnected", "MMDVMDNPCDebugTargetCleanup", function(ply)
    if cleanup_self_proxy_for_player then cleanup_self_proxy_for_player(ply) end
    local debugTarget = MMDVMDNPC.DebugTargets[ply]
    if IsValid(debugTarget) and MMDVMDNPC.DebugFlexHolds then
        MMDVMDNPC.DebugFlexHolds[debugTarget] = nil
    end
    if MMDVMDNPC.LastDebugFrame then MMDVMDNPC.LastDebugFrame[ply] = nil end
    MMDVMDNPC.DebugTargets[ply] = nil
    MMDVMDNPC.AssignedActors[ply] = nil
    if clear_build_job then clear_build_job(ply) else MMDVMDNPC.BuildJobs[ply] = nil end
    MMDVMDNPC.BuildQueues[ply] = nil
    MMDVMDNPC.SelfPlaybackMovementLocks[ply] = nil
    MMDVMDNPC.EyeTrackCameraTargets[ply] = nil
    if update_rpe_body_suppression then update_rpe_body_suppression() end

    MMDVMDNPC.PendingBuildConfirm[ply] = nil
    MMDVMDNPC.PendingAutoPlay[ply] = nil
    MMDVMDNPC.CameraDebugCooldown[ply] = nil
end)

hook.Add("PlayerSay", "MMDVMDNPC_MissingBuildConfirm", function(ply, text)
    local pending = MMDVMDNPC.PendingBuildConfirm[ply]
    if not pending then return end  

    text = string.Trim(text or "")
    if text == "1" then
        MMDVMDNPC.PendingBuildConfirm[ply] = nil
        MMDVMDNPC.PendingAutoPlay[ply] = { motionID = pending.motionID, settings = pending.settings }
        MMDVMDNPC.Chat(ply, "Start build...")
        MMDVMDNPC.BeginBuildForPlayer(ply, pending.motionID, pending.options, pending.settings)
        return ""
    elseif text == "2" then
        MMDVMDNPC.PendingBuildConfirm[ply] = nil
        MMDVMDNPC.Chat(ply, "Build cancelled.")
        return ""
    end
end)

hook.Add("PlayerDeath", "MMDVMDNPCSelfProxyDeathCleanup", function(ply)
    if cleanup_self_proxy_for_player then cleanup_self_proxy_for_player(ply) end
end)

local function send_motion_list(ply)
    local list = MMDVMDNPC.ListMotions()
    net.Start("mmdvmd_list_response")
        net.WriteUInt(#list, 16)
        for _, id in ipairs(list) do
            net.WriteString(id)
        end
    net.Send(ply)
end

local function is_playable_player(ent)
    return IsValid(ent) and ent.IsPlayer and ent:IsPlayer()
        and ent.GetBoneCount and (ent:GetBoneCount() or 0) > 0
end

local function is_playable_npc(ent)
    return IsValid(ent) and ent.IsNPC and ent:IsNPC()
        and ent.GetBoneCount and (ent:GetBoneCount() or 0) > 0
end

local function is_usable_actor(ent)
    return is_playable_npc(ent) or is_playable_player(ent)
end

local function is_playback_proxy(ent)
    return IsValid(ent) and ent.MMDVMDNPCProxy == true
        and ent.GetBoneCount and (ent:GetBoneCount() or 0) > 0
end

local function is_self_playback_proxy(ent)
    if not IsValid(ent) then return false end
    if ent.MMDVMDNPCProxy == true then return true end
    if ent.GetNWBool and ent:GetNWBool("MMDVMDNPCSelfProxy", false) then return true end

    for _, proxy in pairs(MMDVMDNPC.SelfPlaybackProxies or {}) do
        if proxy == ent then return true end
    end
    return false
end

local function is_usable_npc(ent)
    return is_usable_actor(ent) or is_playback_proxy(ent)
end

local function actor_label(ent)
    if is_playable_player(ent) then
        return L("mmd_vmd_npc.status.actor_playermodel", "playermodel")
    end
    if is_playable_npc(ent) then
        return L("mmd_vmd_npc.status.actor_npc", "NPC")
    end
    return L("mmd_vmd_npc.status.actor_generic", "actor")
end

local function actor_select_prompt()
    return L("mmd_vmd_npc.status.actor_select_prompt", "left-click a valid NPC/player, press R to select yourself, Shift+R to build yourself, or E+R to play yourself")
end

local function clamp_start_delay(value)
    return math.max(MMDVMDNPC.MinStartDelay or 2, tonumber(value) or MMDVMDNPC.DefaultStartDelay or 2)
end

local function clamp_build_frames_per_batch(value)
    return math.Clamp(
        math.floor(tonumber(value) or MMDVMDNPC.DefaultBuildFramesPerBatch or BUILD_FRAMES_PER_BATCH),
        MMDVMDNPC.MinBuildFramesPerBatch or 1,
        math.min(255, MMDVMDNPC.MaxBuildFramesPerBatch or 128)
    )
end

local function clamp_playback_hz(value)
    return math.Clamp(
        tonumber(value) or MMDVMDNPC.DefaultPlaybackHz or PLAYBACK_HZ,
        MMDVMDNPC.MinPlaybackHz or 10,
        MMDVMDNPC.MaxPlaybackHz or PLAYBACK_HZ
    )
end

local function playback_settings_from_values(startDelay, pelvisZOffset)
    return {
        startDelay = clamp_start_delay(startDelay),
        pelvisZOffset = tonumber(pelvisZOffset) or MMDVMDNPC.DefaultPelvisZOffset or -2.5,
        eyeTrackMode = MMDVMDNPC.NormalizeEyeTrackMode and MMDVMDNPC.NormalizeEyeTrackMode(nil) or "off",
        eyeTrackSmooth = MMDVMDNPC.DefaultEyeTrackSmooth or EYE_TRACK_SMOOTH,
        eyeTrackMoveBack = MMDVMDNPC.DefaultEyeTrackBoneMoveBack or EYE_TRACK_BONE_MOVE_BACK,
        eyeTrackPosUD = MMDVMDNPC.DefaultEyeTrackBonePosUD or EYE_TRACK_BONE_POS_UD,
        eyeTrackPosLR = MMDVMDNPC.DefaultEyeTrackBonePosLR or EYE_TRACK_BONE_POS_LR,
        musicEnabled = MMDVMDNPC.DefaultMusicEnabled ~= false,
        musicVolume = MMDVMDNPC.DefaultMusicVolume or 1,
        loopPlayback = MMDVMDNPC.DefaultLoopPlayback == true,
        buildFramesPerBatch = MMDVMDNPC.DefaultBuildFramesPerBatch or BUILD_FRAMES_PER_BATCH,
        playbackHz = MMDVMDNPC.DefaultPlaybackHz or PLAYBACK_HZ,
    }
end

function MMDVMDNPC.NormalizeEyeTrackMode(mode)
    mode = string.lower(tostring(mode or MMDVMDNPC.DefaultEyeTrackMode or "camera"))
    if mode == "1" or mode == "true" or mode == "on" or mode == "yes" or mode == "enable" or mode == "enabled" then
        return "camera"
    end
    if mode == "camera" or mode == "cam" or mode == "view" then return "camera" end
    if mode == "player" or mode == "ply" or mode == "owner" then return "player" end
    return "off"
end

local function setting_enabled(value, default)
    if value == nil then return default ~= false end
    if value == true then return true end
    if value == false then return false end
    if isnumber and isnumber(value) then return value ~= 0 end
    local raw = string.lower(tostring(value))
    raw = string.Trim and string.Trim(raw) or string.gsub(raw, "^%s*(.-)%s*$", "%1")
    if raw == "" then return default ~= false end
    if raw == "0" or raw == "false" or raw == "off" or raw == "no" or raw == "disabled" then return false end
    if raw == "1" or raw == "true" or raw == "on" or raw == "yes" or raw == "enabled" then return true end
    return default ~= false
end

local function playback_settings_with_eye_track(startDelay, pelvisZOffset, eyeTrackMode, eyeTrackSmooth, eyeTrackMoveBack, eyeTrackPosUD, eyeTrackPosLR, musicEnabled, musicVolume, buildFramesPerBatch, playbackHz, loopPlayback)
    local settings = playback_settings_from_values(startDelay, pelvisZOffset)
    settings.eyeTrackMode = MMDVMDNPC.NormalizeEyeTrackMode(eyeTrackMode)
    settings.eyeTrackSmooth = math.Clamp(tonumber(eyeTrackSmooth) or settings.eyeTrackSmooth, 0.1, 120)
    settings.eyeTrackMoveBack = math.Clamp(tonumber(eyeTrackMoveBack) or settings.eyeTrackMoveBack, -0.25, 1)
    settings.eyeTrackPosUD = math.Clamp(tonumber(eyeTrackPosUD) or settings.eyeTrackPosUD, 0, 2)
    settings.eyeTrackPosLR = math.Clamp(tonumber(eyeTrackPosLR) or settings.eyeTrackPosLR, 0, 2)
    settings.musicEnabled = setting_enabled(musicEnabled, settings.musicEnabled)
    settings.musicVolume = math.Clamp(tonumber(musicVolume) or settings.musicVolume, 0, 2)
    settings.buildFramesPerBatch = clamp_build_frames_per_batch(buildFramesPerBatch)
    settings.playbackHz = clamp_playback_hz(playbackHz)
    settings.loopPlayback = setting_enabled(loopPlayback, settings.loopPlayback)
    return settings
end

local function optional_convar(name)
    if not GetConVar then return nil end
    return GetConVar(name)
end

-- Cvar changes go through RunConsoleCommand: ConVar:SetString throws
-- "attempted to modify ConVar not created by Lua" for the other addon's
-- (engine-registered) cvars, which is exactly what we suppress. RunConsoleCommand
-- is deferred to end of frame, so we must NOT re-read the live cvar to recover
-- its original value during a same-frame release/re-acquire (build->play, or
-- stop->replay) — it would still read the suppressed "0" and pin the cvar off
-- permanently. Instead the true original is remembered in CVarOriginals and only
-- forgotten a frame after the last release, once the restore has actually run.
local function forget_cvar_original(name)
    if not MMDVMDNPC.CVarSuppressions[name] then
        MMDVMDNPC.CVarOriginals[name] = nil
    end
end

local function begin_scoped_cvar_suppression(names)
    local token = {}
    for _, name in ipairs(names or {}) do
        local cvar = optional_convar(name)
        if cvar then
            local state = MMDVMDNPC.CVarSuppressions[name]
            if not state then
                if MMDVMDNPC.CVarOriginals[name] == nil then
                    MMDVMDNPC.CVarOriginals[name] = cvar:GetString()
                end
                state = { count = 0 }
                MMDVMDNPC.CVarSuppressions[name] = state
                RunConsoleCommand(name, "0")
            end
            state.count = (state.count or 0) + 1
            token[#token + 1] = name
        end
    end
    return #token > 0 and token or nil
end

local function end_scoped_cvar_suppression(token)
    for _, name in ipairs(token or {}) do
        local state = MMDVMDNPC.CVarSuppressions[name]
        if state then
            state.count = math.max(0, (state.count or 1) - 1)
            if state.count <= 0 then
                MMDVMDNPC.CVarSuppressions[name] = nil
                if optional_convar(name) then
                    local original = MMDVMDNPC.CVarOriginals[name]
                    RunConsoleCommand(name, tostring(original ~= nil and original or "0"))
                end
                -- Forget next frame, once the restore has applied and unless a
                -- re-acquire re-suppressed the cvar in the meantime.
                timer.Simple(0, function() forget_cvar_original(name) end)
            end
        end
    end
end

local function has_active_animation_playback()
    for ent, state in pairs(MMDVMDNPC.Playbacks or {}) do
        if state and IsValid(ent) then
            return true
        end
    end
    return false
end

-- Debug-window flex poses being HELD per entity ({[flexID] = weight}). A
-- one-shot SetFlexWeight from the debug apply is stomped back to neutral on
-- the next tick by external flex drivers (the RPE living-body addon, NPC AI
-- expressions), so the Think hook re-asserts these until ownership moves on
-- (playback start / reference pose / debug close / entity gone).
MMDVMDNPC.DebugFlexHolds = MMDVMDNPC.DebugFlexHolds or {}

local function has_debug_flex_hold()
    for ent in pairs(MMDVMDNPC.DebugFlexHolds) do
        if IsValid(ent) then return true end
        MMDVMDNPC.DebugFlexHolds[ent] = nil
    end
    return false
end

update_rpe_body_suppression = function()
    -- Only suppress the other addon's body/eye driving while a dance is
    -- ACTUALLY playing. Keying off a lingering NPC selection kept the cvars
    -- forced to 0 after the dance ended (and the NPC stayed selected), so the
    -- other addon never resumed until the selection was cleared. A play request
    -- creates the Playbacks entry before its countdown, so this still covers the
    -- pre-roll where the NPC must hold the reference pose. A held debug flex
    -- pose counts too: the debug window's face would otherwise be overwritten.
    local needed = has_active_animation_playback() or has_debug_flex_hold()
    local token = MMDVMDNPC.RPEBodySuppressionToken
    if needed and not token then
        MMDVMDNPC.RPEBodySuppressionToken = begin_scoped_cvar_suppression(RPE_BODY_SUPPRESSED_CVARS)
    elseif not needed and token then
        end_scoped_cvar_suppression(token)
        MMDVMDNPC.RPEBodySuppressionToken = nil
    end
end

function MMDVMDNPC.UpdateRPEBodySuppression()
    if update_rpe_body_suppression then update_rpe_body_suppression() end
end

clear_build_job = function(ply)
    local job = MMDVMDNPC.BuildJobs[ply]
    if job and job.cvarSuppression then
        end_scoped_cvar_suppression(job.cvarSuppression)
        job.cvarSuppression = nil
    end
    MMDVMDNPC.BuildJobs[ply] = nil
end

local function normalize_options(disableArmTwist, disableHandTwist, disableEyes, disableSpinePelvisCorrection)
    return {
        disableArmTwist = disableArmTwist == true,
        disableHandTwist = disableHandTwist == true,
        disableEyes = disableEyes == true,
        disableSpinePelvisCorrection = disableSpinePelvisCorrection == true,
    }
end

function MMDVMDNPC.ToolOptions(tool)
    if not tool then return normalize_options(false, false, false, false) end
    return normalize_options(
        tonumber(tool:GetClientInfo("disable_armtwist") or 0) == 1,
        tonumber(tool:GetClientInfo("disable_handtwist") or 0) == 1,
        tonumber(tool:GetClientInfo("disable_eyes") or 0) == 1,
        tonumber(tool:GetClientInfo("disable_spine_pelvis_correction") or 0) == 1
    )
end

function MMDVMDNPC.ToolPlaybackSettings(tool)
    if not tool then return playback_settings_with_eye_track(nil, nil, nil) end
    return playback_settings_with_eye_track(
        tool:GetClientInfo("start_delay"),
        tool:GetClientInfo("pelvis_z_offset"),
        tool:GetClientInfo("eye_track"),
        tool:GetClientInfo("eye_track_smooth"),
        tool:GetClientInfo("eye_track_moveback"),
        tool:GetClientInfo("eye_track_pos_ud"),
        tool:GetClientInfo("eye_track_pos_lr"),
        tool:GetClientInfo("music_enabled"),
        tool:GetClientInfo("music_volume"),
        tool:GetClientInfo("build_frames_per_batch"),
        tool:GetClientInfo("playback_hz"),
        tool:GetClientInfo("loop_playback")
    )
end

local function assignment_set(ply)
    MMDVMDNPC.AssignedActors[ply] = MMDVMDNPC.AssignedActors[ply] or {
        order = {},
        byEnt = {},
    }
    local set = MMDVMDNPC.AssignedActors[ply]
    set.order = set.order or {}
    set.byEnt = set.byEnt or {}
    return set
end

local function compact_assignments(ply)
    local set = assignment_set(ply)
    local newOrder = {}
    local newByEnt = {}
    for _, ent in ipairs(set.order) do
        local assignment = set.byEnt[ent]
        if assignment and is_playable_npc(ent) then
            assignment.ent = ent
            assignment.model = ent:GetModel() or assignment.model or ""
            newOrder[#newOrder + 1] = ent
            newByEnt[ent] = assignment
        end
    end
    set.order = newOrder
    set.byEnt = newByEnt
    return set
end

local function assignment_count(ply)
    return #compact_assignments(ply).order
end

function MMDVMDNPC.HasAssignedActorsForPlayer(ply)
    return assignment_count(ply) > 0
end

local function path_is_queued(ply, path)
    for _, request in ipairs(MMDVMDNPC.BuildQueues[ply] or {}) do
        if tostring(request.path or "") == tostring(path or "") then return true end
    end
    return false
end

local function assignment_build_status(ply, assignment)
    if not assignment then return "missing" end
    local path = assignment.path
    if not path or path == "" then return "missing" end
    local job = MMDVMDNPC.BuildJobs[ply]
    if job and tostring(job.path or "") == tostring(path) then return "building" end
    if path_is_queued(ply, path) then return "queued" end
    if MMDVMDNPC.BuiltCache[path] ~= nil or file.Exists(path, "DATA") then return "built" end
    return "missing"
end

local function first_assignment_ent(ply)
    local set = compact_assignments(ply)
    return set.order[1]
end

local function send_assignment_status(ply)
    if not IsValid(ply) then return end

    local set = compact_assignments(ply)
    if update_rpe_body_suppression then update_rpe_body_suppression() end
    net.Start("mmdvmd_assignment_status")
        net.WriteUInt(math.min(#set.order, 65535), 16)
        for i = 1, math.min(#set.order, 65535) do
            local ent = set.order[i]
            local assignment = set.byEnt[ent] or {}
            net.WriteEntity(ent)
            net.WriteUInt(i, 16)
            net.WriteBool(i == 1)
            net.WriteString(tostring(assignment.motionID or ""))
            net.WriteString(tostring(assignment.model or (IsValid(ent) and ent:GetModel() or "")))
            net.WriteString(assignment_build_status(ply, assignment))
        end
    net.Send(ply)
end

local function send_target_status(ply, message)
    if not IsValid(ply) then return end

    local ent = MMDVMDNPC.DebugTargets[ply]
    local valid = is_usable_actor(ent)
    net.Start("mmdvmd_target_status")
        net.WriteBool(valid)
        net.WriteEntity(valid and ent or NULL)
        net.WriteString(valid and (ent:GetModel() or "") or "")
        net.WriteString(valid and actor_label(ent) or "")
        net.WriteString(tostring(message or ""))
    net.Send(ply)
end

-- buildID identifies the client-side streaming job this result belongs to.
-- 0 means "notification not tied to an in-flight build" (cache already exists,
-- invalid request, queue message); the client must not tear down a running
-- build for those. Only finalize/abort paths for the active job pass job.id.
local function send_build_done(ply, ok, path, message, buildID)
    if not IsValid(ply) then return end

    net.Start("mmdvmd_build_done")
        net.WriteBool(ok == true)
        net.WriteString(tostring(path or ""))
        net.WriteString(tostring(message or ""))
        net.WriteUInt(math.max(0, tonumber(buildID) or 0), 32)
    net.Send(ply)
end

local function build_queue_count(ply)
    local queue = MMDVMDNPC.BuildQueues[ply]
    return istable(queue) and #queue or 0
end

local function send_build_progress(ply, status, job, message)
    if not IsValid(ply) then return end

    job = job or {}
    net.Start("mmdvmd_build_progress")
        net.WriteString(tostring(status or "idle"))
        net.WriteString(tostring(message or ""))
        net.WriteUInt(math.max(0, tonumber(job.id) or 0), 32)
        net.WriteString(tostring(job.motionID or ""))
        net.WriteString(tostring(job.model or ""))
        net.WriteUInt(math.max(0, tonumber(job.currentFrame) or 0), 32)
        net.WriteUInt(math.max(0, tonumber(job.startFrame) or 0), 32)
        net.WriteUInt(math.max(0, tonumber(job.endFrame) or 0), 32)
        net.WriteUInt(math.Clamp(build_queue_count(ply), 0, 65535), 16)
    net.Send(ply)
end

-- startedTime: the playback's authoritative epoch (state.started), passed for
-- "playing"/resume statuses together with the server's CurTime at send. The
-- client anchors its local interpolated poser as
--     localStarted = clientCurTime - (serverNow - started)
-- i.e. by ELAPSED dance time, which stays correct even when the client's
-- CurTime estimate carries a residual offset against the server clock (the
-- engine's clock correction can settle offset after an alt-tab pause; both
-- pose writers anchoring and ticking in their own realm's CurTime made that
-- offset a PERMANENT per-frame flicker between two nearby dance timestamps,
-- for every dance, until the game restarted). The entity INDEX also rides
-- along: net.WriteEntity resolves to NULL when the entity has not reached the
-- client yet (net beats snapshots — same race the camera system handles), and
-- the index lets the client retry instead of misaddressing another entity.
local function send_play_status(ply, status, message, ent, startedTime)
    if not IsValid(ply) then return end

    net.Start("mmdvmd_play_status")
        net.WriteString(tostring(status or ""))
        net.WriteString(tostring(message or ""))
        net.WriteEntity(IsValid(ent) and ent or NULL)
        net.WriteUInt(IsValid(ent) and ent:EntIndex() or 0, 16)
        net.WriteDouble(tonumber(startedTime) or 0)
        net.WriteDouble(CurTime())
    net.Send(ply)
end

-- Periodic body-pose clock sync for the initiator's local poser. Every signal
-- carries (started, serverNow) so a one-off delivery hitch (a message that
-- sat buffered through an alt-tab) is corrected by the NEXT sync instead of
-- lasting the whole dance; it also lets the client REAP local poser states
-- the server no longer confirms — the belt-and-braces kill for any leaked
-- second writer that used to flicker until game restart.
local function send_playback_body_sync(state, ent)
    if not state or not IsValid(state.ply) or not IsValid(ent) then return end
    net.Start("mmdvmd_playback_sync")
        net.WriteUInt(ent:EntIndex(), 16)
        net.WriteDouble(tonumber(state.started) or 0)
        net.WriteDouble(CurTime())
    net.Send(state.ply)
end

function MMDVMDNPC.CancelBuildTasksForPlayer(ply)
    if not IsValid(ply) then return false, L("mmd_vmd_npc.status.invalid_player", "invalid player") end

    local activeCount = MMDVMDNPC.BuildJobs[ply] and 1 or 0
    local queuedCount = build_queue_count(ply)
    local message = MMDVMDNPC.LFormat
        and MMDVMDNPC.LFormat("mmd_vmd_npc.console.build_cancelled_fmt", activeCount, queuedCount)
        or string.format("cancelled build task(s): active %d, queued %d", activeCount, queuedCount)

    MMDVMDNPC.BuildQueues[ply] = nil
    clear_build_job(ply)
    send_build_done(ply, false, "", message)
    send_build_progress(ply, "cancelled", {}, message)
    send_play_status(ply, "blocked", message)
    send_assignment_status(ply)
    return true, message
end

local function resolved_flex_name_on_entity(ent, flexName)
    if not IsValid(ent) or not ent.GetFlexNum or not ent.GetFlexName then return nil end

    flexName = tostring(flexName or "")
    if flexName == "" then return nil end

    if MMDVMDNPC.FindExactFlexOnEntity then
        local exactID, exactName = MMDVMDNPC.FindExactFlexOnEntity(ent, flexName)
        if exactID and exactID >= 0 then
            return exactName or flexName, exactID
        end
    end

    if ent.GetFlexNum and ent.GetFlexName then
        local maxFlex = ent:GetFlexNum() or 0
        for flexID = 0, maxFlex - 1 do
            local current = tostring(ent:GetFlexName(flexID) or "")
            if current == flexName then
                return current, flexID
            end
        end

        local wantedLower = string.lower(flexName)
        for flexID = 0, maxFlex - 1 do
            local current = tostring(ent:GetFlexName(flexID) or "")
            if string.lower(current) == wantedLower then
                return current, flexID
            end
        end
    end

    if ent.GetFlexIDByName then
        local directID = ent:GetFlexIDByName(flexName)
        if directID and directID >= 0 then
            return ent:GetFlexName(directID) or flexName, directID
        end
    end

    return nil
end

local function invalidate_built_for_model(modelPath)
    modelPath = tostring(modelPath or "")
    if modelPath == "" then return 0 end

    -- Filenames cannot be parsed back into (id, model): both may contain '_',
    -- and current files put a CRC segment between the model name and the
    -- options suffix — the old "*_<model>_tw*" glob matched NOTHING, silently
    -- deleting 0 caches. Confirm every candidate against the exact model via
    -- the cheap mtime-keyed header index instead.
    -- Narrow candidates with the safe-model-name glob FIRST (every file for
    -- this model contains "_<safeName>_"): BuiltHeader falls back to a full
    -- multi-MB parse for unindexed files, so header-confirming the whole
    -- directory on a cold index would freeze the frame this click runs in.
    local removed = 0
    local safeName = MMDVMDNPC.SafeModelName(modelPath)
    for _, name in ipairs(file.Find(MMDVMDNPC.BuiltRoot .. "/*_" .. safeName .. "_*" .. MMDVMDNPC.CacheExtension, "DATA") or {}) do
        local path = MMDVMDNPC.BuiltRoot .. "/" .. name
        local header = MMDVMDNPC.BuiltHeader and MMDVMDNPC.BuiltHeader(path, MMDVMDNPC.BuiltCache[path]) or nil
        if header and tostring(header.model or "") == modelPath then
            file.Delete(path)
            MMDVMDNPC.BuiltCache[path] = nil
            if MMDVMDNPC.ForgetBuiltHeader then MMDVMDNPC.ForgetBuiltHeader(path) end
            removed = removed + 1
        end
    end

    -- Clients keep their own built replicas (ClientBuiltCache) for the local
    -- interpolated poser; tell them theirs are stale too, or they would keep
    -- replaying the pre-edit build under the same path key.
    net.Start("mmdvmd_client_built_invalidate")
        net.WriteString(modelPath)
    net.Broadcast()
    return removed
end

local function pause_cvar_number(name)
    local cvar = optional_convar(name)
    if not cvar then return 0 end
    return tonumber(cvar:GetString()) or 0
end

local function send_pause_status(ply)
    if not IsValid(ply) then return end
    net.Start("mmdvmd_pause_status_response")
        net.WriteFloat(pause_cvar_number("sv_pause"))
        net.WriteFloat(pause_cvar_number("sv_pause_sp"))
    net.Send(ply)
end

function MMDVMDNPC.NotifyBlocked(ply, message, ent)
    message = tostring(message or "action blocked")
    send_play_status(ply, "blocked", message, ent)
    MMDVMDNPC.Chat(ply, message)
end

local function send_clear_built_done(ply, ok, removed, message)
    if not IsValid(ply) then return end

    net.Start("mmdvmd_clear_built_done")
        net.WriteBool(ok == true)
        net.WriteUInt(math.max(0, removed or 0), 16)
        net.WriteString(tostring(message or ""))
    net.Send(ply)
end

local function send_delete_motion_done(ply, ok, motionID, message, removedBuilt, musicPath, musicRemoved)
    if not IsValid(ply) then return end

    net.Start("mmdvmd_delete_motion_done")
        net.WriteBool(ok == true)
        net.WriteString(tostring(motionID or ""))
        net.WriteString(tostring(message or ""))
        net.WriteUInt(math.Clamp(tonumber(removedBuilt) or 0, 0, 65535), 16)
        net.WriteString(tostring(musicPath or ""))
        net.WriteBool(musicRemoved == true)
    net.Send(ply)
end

local function load_audio_offsets()
    if MMDVMDNPC.AudioOffsets then return MMDVMDNPC.AudioOffsets end

    local raw = file.Read(MMDVMDNPC.AudioOffsetPath, "DATA")
    local parsed = raw and util.JSONToTable(raw) or nil
    MMDVMDNPC.AudioOffsets = istable(parsed) and parsed or {}
    return MMDVMDNPC.AudioOffsets
end

local function save_audio_offsets()
    file.CreateDir(MMDVMDNPC.DataRoot)
    file.CreateDir(MMDVMDNPC.SettingsRoot)
    file.Write(MMDVMDNPC.AudioOffsetPath, util.TableToJSON(load_audio_offsets(), false))
end

local function audio_offset_for_motion(motionID)
    local id = MMDVMDNPC.NormalizeMotionID(motionID)
    if not id then return 0 end
    local offsets = load_audio_offsets()
    if offsets[id] ~= nil then
        return tonumber(offsets[id]) or 0
    end
    local meta = MMDVMDNPC.MotionMetadata and MMDVMDNPC.MotionMetadata(id) or nil
    return tonumber(meta and meta.musicOffset) or 0
end

local function send_audio_settings(ply, motionID)
    if not IsValid(ply) then return end

    local id = MMDVMDNPC.NormalizeMotionID(motionID) or tostring(motionID or "")
    local meta = id ~= "" and MMDVMDNPC.MotionMetadata and MMDVMDNPC.MotionMetadata(id) or nil
    net.Start("mmdvmd_audio_settings_response")
        net.WriteString(id)
        net.WriteFloat(audio_offset_for_motion(id))
        net.WriteString(meta and meta.musicSound or "")
    net.Send(ply)
end

-- Belt-and-suspenders for the details stream: meta strings are clamped at
-- parse time (sv_cache clamp_meta_string), but entries can come from an old
-- persisted index or any future caller, so never write an unbounded string.
local function net_safe_string(value, limit)
    value = string.gsub(tostring(value or ""), "%z", "")
    return string.sub(value, 1, limit or 256)
end

local function write_motion_details_entry(meta, built)
    net.WriteString(net_safe_string(meta.id))
    net.WriteString(net_safe_string(meta.displayName or meta.id))
    net.WriteUInt(math.max(1, tonumber(meta.fps) or MMDVMDNPC.VMDFPS or 30), 16)
    net.WriteUInt(math.max(0, tonumber(meta.frameStart) or 0), 32)
    net.WriteUInt(math.max(0, tonumber(meta.frameEnd) or 0), 32)
    net.WriteUInt(math.max(0, tonumber(meta.frameCount) or 0), 32)
    net.WriteFloat(tonumber(meta.duration) or 0)
    net.WriteUInt(math.Clamp(tonumber(meta.boneCount) or 0, 0, 65535), 16)
    net.WriteUInt(math.Clamp(tonumber(meta.flexCount) or 0, 0, 65535), 16)
    -- Unix mtime as UInt32, NOT WriteFloat: float32 buckets current-epoch
    -- values to ~128s, hiding same-bucket re-imports from the client's
    -- change detection (the manager's populate signature keys on this).
    net.WriteUInt(math.max(0, math.floor(tonumber(meta.modified) or 0)), 32)
    net.WriteString(net_safe_string(meta.sourceName))
    net.WriteString(net_safe_string(meta.musicSound))
    net.WriteString(net_safe_string(meta.musicSource))
    net.WriteBool(meta.isAddon == true)
    net.WriteBool(built == true)
    net.WriteBool(meta.hasCamera == true)
    -- v2 descriptive metadata (category system). Reader must stay in lockstep
    -- with cl_menu's mmdvmd_motion_details_response handler.
    net.WriteBool(meta.fromAddon == true)
    net.WriteString(net_safe_string(meta.category, 128))
    net.WriteString(net_safe_string(meta.englishName))
    net.WriteString(net_safe_string(meta.artist))
    net.WriteString(net_safe_string(meta.language, 64))
    net.WriteString(net_safe_string(meta.link, 512))
    net.WriteString(net_safe_string(meta.motionArtist))
end

-- Upper bound of one entry's wire size (fixed fields + every clamped string
-- with its terminator). Used to keep each chunk safely under the 64KB cap.
local function motion_details_entry_bytes(meta)
    local bytes = 40 -- numeric/bool fields + string terminators, rounded up
    for _, value in ipairs({
        meta.id, meta.displayName, meta.sourceName, meta.musicSound,
        meta.musicSource, meta.category, meta.englishName, meta.artist,
        meta.language, meta.link, meta.motionArtist,
    }) do
        bytes = bytes + math.min(#tostring(value or ""), 512) + 1
    end
    return bytes
end

-- Net messages are hard-capped at 64KB, so the details are streamed in chunks
-- (the client accumulates until the done flag). Chunks are bounded BOTH by
-- entry count and by accumulated bytes: strings are clamped, but 40 worst-case
-- entries could still exceed the cap on count alone.
local MOTION_DETAILS_CHUNK = 40
local MOTION_DETAILS_BYTE_BUDGET = 45000

local function send_motion_details_chunks(ply, entries)
    local total = math.min(#entries, 65535)
    local index = 1
    local first = true
    repeat
        local chunkStart = index
        local count = 0
        local bytes = 0
        while index <= total and count < MOTION_DETAILS_CHUNK do
            local cost = motion_details_entry_bytes(entries[index].meta)
            if count > 0 and bytes + cost > MOTION_DETAILS_BYTE_BUDGET then break end
            count = count + 1
            bytes = bytes + cost
            index = index + 1
        end
        local done = index > total
        net.Start("mmdvmd_motion_details_response")
            net.WriteBool(first)   -- first chunk: reset accumulator
            net.WriteBool(done)    -- last chunk: commit
            net.WriteUInt(count, 16)
            for i = chunkStart, chunkStart + count - 1 do
                write_motion_details_entry(entries[i].meta, entries[i].built)
            end
        net.Send(ply)
        first = false
    until done
end

-- Building a details response derives metadata for every motion. For motions
-- already in the persisted meta index that is trivially cheap — but every
-- UNCACHED one costs a full util.JSONToTable of a multi-MB baked file. The
-- first menu open after mounting a pack with dozens of dances used to run ALL
-- of those parses inside one frame, freezing (and with enough motions,
-- crashing) the game. The walk is therefore time-sliced: at most this many
-- expensive parses per engine tick, cheap index hits unbudgeted.
local MOTION_DETAILS_PARSES_PER_TICK = 1

local detailsBuildCounter = 0

local function send_motion_details(ply, options)
    local list = MMDVMDNPC.ListMotions()
    detailsBuildCounter = detailsBuildCounter + 1
    local token = detailsBuildCounter
    -- A newer request supersedes an in-flight walk (the newest options win and
    -- the stale build stops touching the player).
    ply.MMDVMDNPCDetailsToken = token

    local entries = {}
    local index = 1

    local function finish()
        -- The per-target "built" flag is resolved at send time so it reflects
        -- the target as of the freshest data, not walk start.
        local ent = MMDVMDNPC.DebugTargets[ply]
        local hasTarget = is_usable_actor(ent)
        for _, entry in ipairs(entries) do
            if hasTarget then
                local path = MMDVMDNPC.BuiltPath(entry.meta.id, ent:GetModel() or "", options)
                entry.built = path ~= nil and (MMDVMDNPC.BuiltCache[path] ~= nil or file.Exists(path, "DATA"))
            end
        end
        send_motion_details_chunks(ply, entries)
    end

    local function step()
        if not IsValid(ply) or ply.MMDVMDNPCDetailsToken ~= token then return end
        local parseBudget = MOTION_DETAILS_PARSES_PER_TICK
        while index <= #list do
            local id = list[index]
            if not (MMDVMDNPC.HasMotionMetadataCached and MMDVMDNPC.HasMotionMetadataCached(id)) then
                if parseBudget <= 0 then break end
                parseBudget = parseBudget - 1
            end
            local meta = MMDVMDNPC.MotionMetadata and MMDVMDNPC.MotionMetadata(id) or nil
            if meta then
                entries[#entries + 1] = { meta = meta, built = false }
            end
            index = index + 1
        end
        if index > #list then
            finish()
        else
            timer.Simple(0, step)
        end
    end
    step()
end

-- Coalesce request bursts: the client re-requests details after nearly every
-- UI action (and a client could spam the net message); at most one full
-- metadata walk + stream per player per half second, with the latest options.
local MOTION_DETAILS_MIN_INTERVAL = 0.5

local function queue_motion_details(ply, options)
    if not IsValid(ply) then return end
    local now = CurTime()
    local nextAllowed = tonumber(ply.MMDVMDNPCDetailsNext) or 0
    ply.MMDVMDNPCDetailsOptions = options
    if now < nextAllowed then
        timer.Create("MMDVMDNPCDetails" .. ply:EntIndex(), nextAllowed - now, 1, function()
            if not IsValid(ply) then return end
            ply.MMDVMDNPCDetailsNext = CurTime() + MOTION_DETAILS_MIN_INTERVAL
            send_motion_details(ply, ply.MMDVMDNPCDetailsOptions)
        end)
        return
    end
    ply.MMDVMDNPCDetailsNext = now + MOTION_DETAILS_MIN_INTERVAL
    send_motion_details(ply, options)
end

local function ai_disabled_enabled()
    return true;
end

local function ai_disabled_required_message()
    return L("mmd_vmd_npc.status.ai_disabled_required", "AI thinking must be disabled: run ai_disabled 1 before building or playing MMD VMD animations")
end

local function build_missing_instruction()
    return L("mmd_vmd_npc.status.build_missing_instruction", " Use Shift + left click to build the selected NPC animation(s).")
end

local function fail_ai_disabled_required(ply, forBuild)
    local message = ai_disabled_required_message()
    if forBuild then
        send_build_done(ply, false, "", message)
    end
    send_play_status(ply, "error", message)
    MMDVMDNPC.Chat(ply, message)
    return false, message
end

local function ai_thinking_disabled()
    -- `ai_disabled` is a server convar; the server is authoritative here. When the
    -- convar is somehow missing we treat AI as "unknown" and stay silent rather
    -- than nagging on every build/play.
    local cv = GetConVar("ai_disabled")
    if not cv then return true end
    return cv:GetBool()
end

-- Non-blocking notice: applying a dance to an NPC while AI thinking is on lets the
-- NPC wander/fight mid-performance. We warn (once per few seconds so a group action
-- does not spam) and then let the build/playback proceed anyway.
-- Push a chat line to one player. isWarning => the client prints it red and plays
-- an alert sound (see the mmdvmd_chat_notice receiver in cl_menu.lua).
local function send_chat_notice(ply, message, isWarning)
    if not IsValid(ply) then return end
    net.Start("mmdvmd_chat_notice")
        net.WriteString(tostring(message or ""))
        net.WriteBool(isWarning == true)
    net.Send(ply)
end

local function warn_if_ai_enabled(ply, ent)
    if not IsValid(ply) then return end
    if not is_playable_npc(ent) or is_playback_proxy(ent) then return end
    if ai_thinking_disabled() then return end

    local now = SysTime()
    if (ply.MMDVMDNPCAiWarnNext or 0) > now then return end
    -- Short window: dedupes the per-NPC burst of a group play (all in one tick)
    -- without feeling unresponsive when the user re-selects to test.
    ply.MMDVMDNPCAiWarnNext = now + 2

    local message = L(
        "mmd_vmd_npc.status.ai_enabled_warning",
        "Warning: NPC AI is enabled (ai_disabled 0), so NPCs may walk or fight during the dance. Run ai_disabled 1 for a clean performance. Playing anyway."
    )
    -- Red + alert sound in chat so a user looking at the NPC still notices.
    send_chat_notice(ply, message, true)
    send_play_status(ply, "warning", message, ent)
end

-- Selecting an NPC while NPC AI is enabled is REFUSED (the NPC would wander or
-- fight mid-dance). Returns the denial message when blocked, nil when fine.
-- Players/self-proxies are unaffected; playback/build paths keep the softer
-- warn_if_ai_enabled for actors that were selected before AI got re-enabled.
local function deny_select_if_ai_enabled(ply, ent)
    if not IsValid(ply) then return nil end
    if not is_playable_npc(ent) or is_playback_proxy(ent) then return nil end
    if ai_thinking_disabled() then return nil end
    local message = L(
        "mmd_vmd_npc.status.ai_enabled_select_blocked",
        "NPC selection blocked: NPC AI is enabled. Run ai_disabled 1 before selecting an NPC to dance."
    )
    send_chat_notice(ply, message, true)
    return message
end

function MMDVMDNPC.SelectTargetForPlayer(ply, ent)
    if not IsValid(ply) then return false, L("mmd_vmd_npc.status.invalid_player", "invalid player") end
    if not is_usable_actor(ent) then
        local message = actor_select_prompt()
        send_target_status(ply, message)
        return false, message
    end
    if not ai_disabled_enabled() then
        local ok, message = fail_ai_disabled_required(ply, false)
        send_target_status(ply, message)
        return ok, message
    end
    local aiBlockMessage = deny_select_if_ai_enabled(ply, ent)
    if aiBlockMessage then
        send_target_status(ply, aiBlockMessage)
        send_play_status(ply, "error", aiBlockMessage, ent)
        return false, aiBlockMessage
    end
    local ok, referenceOrErr = require_reference_sequence_for_actor(ply, ent, false)
    if not ok then return false, referenceOrErr end

    MMDVMDNPC.DebugTargets[ply] = ent
    if is_playable_npc(ent) and pose_selected_npc_reference then
        pose_selected_npc_reference(ent)
    end
    if update_rpe_body_suppression then update_rpe_body_suppression() end
    send_target_status(ply, LF("mmd_vmd_npc.status.selected_actor_fmt", actor_label(ent), tostring(ent:GetClass() or ent:Nick() or "")))
    return true
end

local function lookup_reference_sequence(ent)
    return MMDVMDNPC.LookupReferenceSequence and MMDVMDNPC.LookupReferenceSequence(ent) or -1
end

local function lookup_reference_sequence_info(ent)
    if not MMDVMDNPC.LookupReferenceSequenceInfo then return nil end
    return MMDVMDNPC.LookupReferenceSequenceInfo(ent)
end

local function lookup_required_reference_sequence_info(ent)
    if not MMDVMDNPC.LookupRequiredReferenceSequenceInfo then return nil end
    return MMDVMDNPC.LookupRequiredReferenceSequenceInfo(ent)
end

local function missing_reference_sequence_message()
    if MMDVMDNPC.L then
        return MMDVMDNPC.L("mmd_vmd_npc.error.missing_reference_sequence", "Selected NPC/player has no Reference sequence. This model is not supported yet.")
    end
    return "Selected NPC/player has no Reference sequence. This model is not supported yet."
end

local function warn_referencef_build_if_needed(ply, ent, referenceInfo)
    if not IsValid(ply) or not istable(referenceInfo) or referenceInfo.adaptiveReference ~= true then return end

    local sequenceName = MMDVMDNPC.ReferenceSequenceDisplayName and MMDVMDNPC.ReferenceSequenceDisplayName(referenceInfo)
        or tostring(referenceInfo.displayName or referenceInfo.lookupName or referenceInfo.name or "Referencef")
    local message = LF("mmd_vmd_npc.status.referencef_build_warning_fmt", tostring(ent:GetModel() or ""), tostring(sequenceName))
    send_play_status(ply, "warning", message, ent)
    MMDVMDNPC.Chat(ply, message)
end

require_reference_sequence_for_actor = function(ply, ent, forBuild)
    local info, referenceErr = lookup_required_reference_sequence_info(ent)
    if info then
        if forBuild then warn_referencef_build_if_needed(ply, ent, info) end
        return true, info
    end

    local message = referenceErr or missing_reference_sequence_message()
    if IsValid(ply) then
        send_target_status(ply, message)
        send_play_status(ply, "error", message, ent)
        if forBuild then
            send_build_done(ply, false, "", message)
        end
        MMDVMDNPC.Chat(ply, message)
    end
    return false, message
end

local function setup_bones_now(ent)
    if not IsValid(ent) then return end
    if ent.InvalidateBoneCache then ent:InvalidateBoneCache() end
    if ent.SetupBones then ent:SetupBones() end
end

local function resolve_eye_bones(ent)
    if not IsValid(ent) or not ent.LookupBone then return nil, nil end

    local leftBone
    for _, name in ipairs(EYE_BONE_LEFT_CANDIDATES) do
        local bone = ent:LookupBone(name)
        if bone and bone >= 0 then
            leftBone = bone
            break
        end
    end

    local rightBone
    for _, name in ipairs(EYE_BONE_RIGHT_CANDIDATES) do
        local bone = ent:LookupBone(name)
        if bone and bone >= 0 then
            rightBone = bone
            break
        end
    end
    -- print("Resolved eye bones for " .. tostring(ent:GetModel() or "") .. ": left=" .. tostring(leftBone) .. ", right=" .. tostring(rightBone))
    return leftBone, rightBone
end

local function get_eye_attachment(ent)
    if not IsValid(ent) or not ent.LookupAttachment or not ent.GetAttachment then return nil end

    for _, name in ipairs(EYE_ATTACHMENT_CANDIDATES) do
        local id = ent:LookupAttachment(name)
        if id and id > 0 then
            local att = ent:GetAttachment(id)
            if att and att.Pos and att.Ang then return att end
        end
    end

    return nil
end

local function apply_set_eye_target(ent, targetWorld)
    if not IsValid(ent) or not ent.SetEyeTarget or not isvector(targetWorld) then return false end

    local target = targetWorld
    if ent.IsRagdoll and ent:IsRagdoll() then
        local att = get_eye_attachment(ent)
        if not att then return false end
        target = WorldToLocal(targetWorld, ZERO_ANGLE, att.Pos, att.Ang)
    end

    local ok = pcall(ent.SetEyeTarget, ent, target)
    return ok == true
end

local function compute_look_controls(ent, targetWorld)
    if not IsValid(ent) or not isvector(targetWorld) then return 0, 0, 0 end

    local att = get_eye_attachment(ent)
    if att then
        local localTarget = WorldToLocal(targetWorld, ZERO_ANGLE, att.Pos, att.Ang)
        local dir = localTarget:GetNormalized()
        local sum = math.abs(dir.y) + math.abs(dir.z)
        local sumMax = math.max(sum, 1.5)
        return math.Clamp(dir.y / sumMax, -1, 1),
            math.Clamp(dir.z / sumMax, -1, 1),
            math.Clamp(sum / sumMax, 0, 1)
    end

    local eyePos = ent.EyePos and ent:EyePos() or ent:GetPos()
    if not isvector(eyePos) then eyePos = ent:GetPos() end
    local dirWorld = (targetWorld - eyePos):GetNormalized()
    local right = ent.GetRight and ent:GetRight() or Vector(0, 1, 0)
    local up = ent.GetUp and ent:GetUp() or Vector(0, 0, 1)
    local y = dirWorld:Dot(right)
    local z = dirWorld:Dot(up)
    local sum = math.abs(y) + math.abs(z)
    local sumMax = math.max(sum, 1.5)

    return math.Clamp(y / sumMax, -1, 1),
        math.Clamp(z / sumMax, -1, 1),
        math.Clamp(sum / sumMax, 0, 1)
end

local function reset_runtime_eye_tracking(ent, eyeState)
    if not IsValid(ent) then return end

    if eyeState then
        if eyeState.eyeBoneL ~= nil and ent.ManipulateBonePosition then
            ent:ManipulateBonePosition(eyeState.eyeBoneL, ZERO_VECTOR)
        end
        if eyeState.eyeBoneR ~= nil and ent.ManipulateBonePosition then
            ent:ManipulateBonePosition(eyeState.eyeBoneR, ZERO_VECTOR)
        end
        eyeState.curL = 0
        eyeState.curU = 0
        eyeState.curB = 0
        eyeState.target = nil
    end

    if ent.SetEyeTarget then
        pcall(ent.SetEyeTarget, ent, ZERO_VECTOR)
    end
end

force_reference_pose = function(ent)
    if not is_usable_npc(ent) then return false end

    local info = lookup_reference_sequence_info(ent)
    local seq = info and info.seq or lookup_reference_sequence(ent)
    if not seq or seq < 0 then return false end

    if ent.SetSequence then
        ent:SetSequence(seq)
    end
    if ent.ResetSequence then
        ent:ResetSequence(seq)
    end
    if ent.ResetSequenceInfo then ent:ResetSequenceInfo() end
    if ent.SetCycle then ent:SetCycle(0) end
    if ent.SetPlaybackRate then ent:SetPlaybackRate(0) end
    if ent.SetIK then ent:SetIK(false) end
    if ent.FrameAdvance then ent:FrameAdvance(0) end
    if ent.SetNPCState and NPC_STATE_SCRIPT then ent:SetNPCState(NPC_STATE_SCRIPT) end
    setup_bones_now(ent)
    ent.MMDVMDNPCReferenceInfo = info
    return true, info
end

clear_all_bone_manipulations = function(ent)
    if not is_usable_npc(ent) then return end

    local count = ent:GetBoneCount() or 0
    for bone = 0, count - 1 do
        if ent.ManipulateBoneAngles then ent:ManipulateBoneAngles(bone, ZERO_ANGLE, true) end
        if ent.ManipulateBonePosition then ent:ManipulateBonePosition(bone, ZERO_VECTOR) end
        if ent.ManipulateBoneScale then ent:ManipulateBoneScale(bone, ONE_SCALE) end
        -- 0 = model default: restores any jigglebones disabled during playback.
        if ent.ManipulateBoneJiggle then ent:ManipulateBoneJiggle(bone, 0) end
    end
    setup_bones_now(ent)
end

-- Type 2 = "force disable jiggle bone" for every bone, so a model's jigglebones
-- stop fighting the imported pose while a motion plays. Reset by
-- clear_all_bone_manipulations (type 0) on stop.
local function disable_all_bone_jiggle(ent)
    if not is_usable_npc(ent) or not ent.ManipulateBoneJiggle then return end
    local count = ent:GetBoneCount() or 0
    for bone = 0, count - 1 do
        ent:ManipulateBoneJiggle(bone, 2)
    end
end

clear_all_flex_weights = function(ent)
    if not is_usable_npc(ent) or not ent.GetFlexNum or not ent.SetFlexWeight then return end

    for flexID = 0, (ent:GetFlexNum() or 0) - 1 do
        ent:SetFlexWeight(flexID, 0)
    end
end

local function freeze_player_target(ent, frozen)
    if is_playable_player(ent) and ent.Freeze then
        ent:Freeze(frozen == true)
    end
end

local function set_self_player_movement_locked(ply, locked)
    if not is_playable_player(ply) then return end

    if locked then
        MMDVMDNPC.SelfPlaybackMovementLocks[ply] = true
        if ply.SetVelocity then ply:SetVelocity(ZERO_VECTOR) end
    else
        MMDVMDNPC.SelfPlaybackMovementLocks[ply] = nil
        freeze_player_target(ply, false)
    end
    -- Mirrored to the client so its prediction strips the same buttons the
    -- server strips in StartCommand (no predicted muzzle flash / fire sound).
    if ply.SetNWBool then ply:SetNWBool("MMDVMDNPCSelfPlaybackLock", locked == true) end
end

hook.Add("SetupMove", "MMDVMDNPCSelfPlaybackMovementLock", function(ply, mv, cmd)
    if not MMDVMDNPC.SelfPlaybackMovementLocks[ply] then return end

    if mv.SetForwardSpeed then mv:SetForwardSpeed(0) end
    if mv.SetSideSpeed then mv:SetSideSpeed(0) end
    if mv.SetUpSpeed then mv:SetUpSpeed(0) end
    if mv.SetMaxSpeed then mv:SetMaxSpeed(0) end
    if mv.SetMaxClientSpeed then mv:SetMaxClientSpeed(0) end
    if mv.SetVelocity then mv:SetVelocity(ZERO_VECTOR) end

    if cmd then
        if cmd.ClearMovement then
            cmd:ClearMovement()
        else
            if cmd.SetForwardMove then cmd:SetForwardMove(0) end
            if cmd.SetSideMove then cmd:SetSideMove(0) end
            if cmd.SetUpMove then cmd:SetUpMove(0) end
        end
    end
end)

-- Movement zeroing alone still lets a locked player shoot, +use, reload and
-- fire the toolgun while their dance proxy performs; strip those buttons from
-- the usercmd before weapons process it. Jump/duck are stripped too so the
-- hidden player's hull and eye position stay put under the animated camera.
local SELF_PLAYBACK_LOCKED_BUTTONS = bit.bor(
    IN_ATTACK, IN_ATTACK2, IN_USE, IN_RELOAD, IN_JUMP, IN_DUCK, IN_ZOOM
)
-- With this addon's own toolgun mode active, the documented in-world controls
-- must keep working mid-dance: right-click pauses (TOOL:RightClick) and E+R
-- stops (TOOL:Reload with IN_USE held). Attacks stay blocked for every other
-- weapon and for the toolgun's left click.
local SELF_PLAYBACK_TOOL_ALLOWED = bit.bor(IN_ATTACK2, IN_USE, IN_RELOAD)

local function self_playback_locked_mask(ply)
    local mask = SELF_PLAYBACK_LOCKED_BUTTONS
    local weapon = ply.GetActiveWeapon and ply:GetActiveWeapon() or nil
    if IsValid(weapon) and weapon:GetClass() == "gmod_tool"
        and (ply.GetInfo and ply:GetInfo("gmod_toolmode") or "") == "mmd_vmd_npc" then
        mask = bit.band(mask, bit.bnot(SELF_PLAYBACK_TOOL_ALLOWED))
    end
    -- +use is also how a seated player leaves a vehicle; never trap them.
    if ply.InVehicle and ply:InVehicle() then
        mask = bit.band(mask, bit.bnot(IN_USE))
    end
    return mask
end

hook.Add("StartCommand", "MMDVMDNPCSelfPlaybackActionLock", function(ply, cmd)
    if not MMDVMDNPC.SelfPlaybackMovementLocks[ply] then return end
    cmd:SetButtons(bit.band(cmd:GetButtons(), bit.bnot(self_playback_locked_mask(ply))))
end)

hook.Add("PlayerCanPickupWeapon", "MMDVMDNPCSelfPlaybackNoPickup", function(ply)
    -- A newly picked-up weapon would render next to the hidden player (only
    -- weapons carried at hide time get SetNoDraw), so block pickups entirely.
    if MMDVMDNPC.SelfPlaybackMovementLocks[ply] then return false end
end)

local function set_self_player_hidden(ply, hidden)
    if not is_playable_player(ply) then return end

    if hidden then
        local visual = MMDVMDNPC.SelfPlaybackVisuals[ply]
        if not visual then
            visual = {
                playerNoDraw = ply.GetNoDraw and ply:GetNoDraw() or false,
                weapons = {},
            }
            MMDVMDNPC.SelfPlaybackVisuals[ply] = visual
        end

        if ply.SetNoDraw then ply:SetNoDraw(true) end

        local weapons = ply.GetWeapons and ply:GetWeapons() or {}
        for _, weapon in ipairs(weapons) do
            if IsValid(weapon) then
                if visual.weapons[weapon] == nil then
                    visual.weapons[weapon] = weapon.GetNoDraw and weapon:GetNoDraw() or false
                end
                if weapon.SetNoDraw then weapon:SetNoDraw(true) end
            end
        end

        local activeWeapon = ply.GetActiveWeapon and ply:GetActiveWeapon() or nil
        if IsValid(activeWeapon) then
            if visual.weapons[activeWeapon] == nil then
                visual.weapons[activeWeapon] = activeWeapon.GetNoDraw and activeWeapon:GetNoDraw() or false
            end
            if activeWeapon.SetNoDraw then activeWeapon:SetNoDraw(true) end
        end
        return
    end

    local visual = MMDVMDNPC.SelfPlaybackVisuals[ply]
    if not visual then
        if ply.SetNoDraw then ply:SetNoDraw(false) end
        return
    end

    if ply.SetNoDraw then ply:SetNoDraw(visual.playerNoDraw == true) end
    for weapon, oldNoDraw in pairs(visual.weapons or {}) do
        if IsValid(weapon) and weapon.SetNoDraw then
            weapon:SetNoDraw(oldNoDraw == true)
        end
    end
    MMDVMDNPC.SelfPlaybackVisuals[ply] = nil
end

local function copy_player_appearance_to_proxy(ply, proxy)
    if not IsValid(ply) or not IsValid(proxy) then return end

    if proxy.SetSkin and ply.GetSkin then proxy:SetSkin(ply:GetSkin() or 0) end
    if proxy.SetColor and ply.GetColor then proxy:SetColor(ply:GetColor()) end
    if proxy.SetMaterial and ply.GetMaterial then proxy:SetMaterial(ply:GetMaterial() or "") end
    if proxy.SetModelScale and ply.GetModelScale then proxy:SetModelScale(ply:GetModelScale() or 1, 0) end
    if proxy.SetPlayerColor and ply.GetPlayerColor then proxy:SetPlayerColor(ply:GetPlayerColor()) end

    if proxy.SetBodygroup and ply.GetNumBodyGroups and ply.GetBodygroup then
        for group = 0, (ply:GetNumBodyGroups() or 0) - 1 do
            proxy:SetBodygroup(group, ply:GetBodygroup(group) or 0)
        end
    end
end

local function create_self_playback_proxy(ply)
    if not is_playable_player(ply) then return nil, "invalid playermodel target" end

    local oldProxy = MMDVMDNPC.SelfPlaybackProxies[ply]
    if IsValid(oldProxy) then
        if MMDVMDNPC.Playbacks[oldProxy] then
            MMDVMDNPC.StopPlayback(oldProxy, true)
        else
            oldProxy:Remove()
            MMDVMDNPC.SelfPlaybackProxies[ply] = nil
        end
    end

    local proxy = ents.Create("prop_dynamic")
    if not IsValid(proxy) then
        proxy = ents.Create("prop_dynamic_override")
    end
    if not IsValid(proxy) then
        return nil, "failed to create self playback model"
    end

    proxy:SetModel(ply:GetModel() or "")
    proxy:SetPos(ply:GetPos())
    proxy:SetAngles(Angle(0, ply:EyeAngles().y, 0))
    proxy.MMDVMDNPCProxy = true
    proxy.MMDVMDNPCOwner = ply
    if proxy.SetNWBool then proxy:SetNWBool("MMDVMDNPCSelfProxy", true) end
    if proxy.SetNWEntity then proxy:SetNWEntity("MMDVMDNPCSelfProxyOwner", ply) end
    proxy:Spawn()
    proxy:Activate()
    if proxy.SetNWBool then proxy:SetNWBool("MMDVMDNPCSelfProxy", true) end
    if proxy.SetNWEntity then proxy:SetNWEntity("MMDVMDNPCSelfProxyOwner", ply) end

    if proxy.SetSolid then proxy:SetSolid(SOLID_NONE) end
    if proxy.SetMoveType then proxy:SetMoveType(MOVETYPE_NONE) end
    if proxy.SetCollisionGroup then proxy:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE) end
    if proxy.DrawShadow then proxy:DrawShadow(false) end
    copy_player_appearance_to_proxy(ply, proxy)
    force_reference_pose(proxy)

    MMDVMDNPC.SelfPlaybackProxies[ply] = proxy
    return proxy
end

local function cleanup_self_proxy_state(state)
    if not state or not state.selfProxy then return end

    local ply = state.realPlayer or state.ply
    if IsValid(ply) then
        set_self_player_movement_locked(ply, false)
        set_self_player_hidden(ply, false)
        if MMDVMDNPC.SelfPlaybackProxies[ply] == state.ent then
            MMDVMDNPC.SelfPlaybackProxies[ply] = nil
        end
    end

    if IsValid(state.ent) then
        state.ent.MMDVMDNPCProxy = nil
        state.ent.MMDVMDNPCOwner = nil
        state.ent:Remove()
    end
end

cleanup_self_proxy_for_player = function(ply)
    local proxy = MMDVMDNPC.SelfPlaybackProxies[ply]
    if IsValid(proxy) and MMDVMDNPC.Playbacks[proxy] then
        MMDVMDNPC.StopPlayback(proxy, true)
    else
        if IsValid(proxy) then proxy:Remove() end
        MMDVMDNPC.SelfPlaybackProxies[ply] = nil
        set_self_player_hidden(ply, false)
        set_self_player_movement_locked(ply, false)
    end
end

local function stop_actor_motion(ent)
    if IsValid(ent) and ent.SetVelocity and not ent:IsPlayer() then
        ent:SetVelocity(ZERO_VECTOR)
    end
end

pose_selected_npc_reference = function(ent)
    if not is_playable_npc(ent) then return false end

    if MMDVMDNPC.Playbacks and MMDVMDNPC.Playbacks[ent] and MMDVMDNPC.StopPlayback then
        MMDVMDNPC.StopPlayback(ent, true)
        return true
    end

    MMDVMDNPC.DebugFlexHolds[ent] = nil
    clear_all_bone_manipulations(ent)
    clear_all_flex_weights(ent)
    local ok, info = force_reference_pose(ent)
    stop_actor_motion(ent)
    return ok, info
end

local function bone_world_position(ent, bone)
    local matrix = ent.GetBoneMatrix and ent:GetBoneMatrix(bone) or nil
    if matrix then return matrix:GetTranslation() end

    if ent.GetBonePosition then
        local pos = ent:GetBonePosition(bone)
        if pos then return pos end
    end

    return nil
end

local function print_reference_arm_axis_diagnostic(ent, motionID)
    if not is_usable_npc(ent) or not ent.LookupBone then return nil end

    local ok, referenceInfo = force_reference_pose(ent)
    clear_all_bone_manipulations(ent)
    setup_bones_now(ent)
    if not ok then
        print("[MMD VMD] Reference arm axis diagnostic unavailable: failed to force reference pose for " .. tostring(ent))
        return nil
    end

    local upperArm = ent:LookupBone(SOURCE_RIGHT_UPPER_ARM)
    local forearm = ent:LookupBone(SOURCE_RIGHT_FOREARM)
    if not upperArm or upperArm < 0 or not forearm or forearm < 0 then
        print(string.format(
            "[MMD VMD] Reference arm axis diagnostic unavailable for %s (%s): missing %s=%s or %s=%s",
            tostring(ent),
            tostring(ent:GetModel() or ""),
            SOURCE_RIGHT_UPPER_ARM,
            tostring(upperArm),
            SOURCE_RIGHT_FOREARM,
            tostring(forearm)
        ))
        return nil
    end

    local upperPos = bone_world_position(ent, upperArm)
    local forearmPos = bone_world_position(ent, forearm)
    if not upperPos or not forearmPos then
        print("[MMD VMD] Reference arm axis diagnostic unavailable: failed to read right arm bone positions")
        return nil
    end

    local armVector = forearmPos - upperPos
    if armVector:LengthSqr() <= 0.000001 then
        print("[MMD VMD] Reference arm axis diagnostic unavailable: right upper-arm to forearm vector has zero length")
        return nil
    end

    armVector:Normalize()
    local modelNegZ = (ent.GetUp and ent:GetUp() or Vector(0, 0, 1)) * -1
    if modelNegZ:LengthSqr() <= 0.000001 then modelNegZ = Vector(0, 0, -1) end
    modelNegZ:Normalize()

    local dot = math.Clamp(armVector:Dot(modelNegZ), -1, 1)
    local angle = math.deg(math.acos(dot))

    local selectedName = MMDVMDNPC.ReferenceSequenceDisplayName and MMDVMDNPC.ReferenceSequenceDisplayName(referenceInfo)
        or tostring(referenceInfo and (referenceInfo.displayName or referenceInfo.lookupName or referenceInfo.name) or "unknown")
    if selectedName == "" then selectedName = "unknown" end

    if referenceInfo and referenceInfo.adaptiveReference then
        print(string.format(
            "[MMD VMD] Reference arm axis diagnostic for %s (%s), motion %s: selected reference %s (#%s), fallback from %s (#%s); Reference probe angle %s->%s to model -Z = %.3f deg, selected-sequence angle = %.3f deg",
            tostring(ent),
            tostring(ent:GetModel() or ""),
            tostring(motionID or ""),
            tostring(selectedName),
            tostring(referenceInfo.seq or "?"),
            tostring(referenceInfo.fallbackFromDisplayName or referenceInfo.fallbackFrom or "Reference"),
            tostring(referenceInfo.fallbackFromSeq or "?"),
            SOURCE_RIGHT_UPPER_ARM,
            SOURCE_RIGHT_FOREARM,
            tonumber(referenceInfo.referenceProbeArmAxisAngle or referenceInfo.armAxisAngle) or angle,
            angle
        ))
    else
        print(string.format(
            "[MMD VMD] Reference arm axis diagnostic for %s (%s), motion %s: selected reference %s (#%s), angle %s->%s to model -Z = %.3f deg",
            tostring(ent),
            tostring(ent:GetModel() or ""),
            tostring(motionID or ""),
            tostring(selectedName),
            tostring(referenceInfo and referenceInfo.seq or "?"),
            SOURCE_RIGHT_UPPER_ARM,
            SOURCE_RIGHT_FOREARM,
            angle
        ))
    end
    return angle
end

local function bone_depth(ent, bone)
    local depth = 0
    local parent = ent.GetBoneParent and ent:GetBoneParent(bone) or -1
    local guard = 0

    while parent and parent >= 0 and guard < 512 do
        depth = depth + 1
        parent = ent:GetBoneParent(parent)
        guard = guard + 1
    end

    return depth
end

local function lerp_value(a, b, fraction)
    return (a or 0) + ((b or 0) - (a or 0)) * fraction
end

-- Largest index i with keys[i].frame <= frame. Keys are sorted ascending on
-- load (sv_cache normalize_track), so builds sampling thousands of baked
-- keyframes stay O(log n) per sample instead of scanning the whole track.
local function track_span_index(keys, frame)
    local low, high = 1, #keys
    while low < high do
        local mid = math.floor((low + high + 1) / 2)
        if keys[mid].frame <= frame then
            low = mid
        else
            high = mid - 1
        end
    end
    return low
end

local function sample_track(track, frame)
    local keys = track and track.keys or {}
    if #keys <= 0 then return 0, 0, 0, 0, 0, 0 end

    if frame <= keys[1].frame then
        local key = keys[1]
        return key.x, key.y, key.z, key.px, key.py, key.pz
    end
    if frame >= keys[#keys].frame then
        local key = keys[#keys]
        return key.x, key.y, key.z, key.px, key.py, key.pz
    end

    local index = track_span_index(keys, frame)
    local a = keys[index]
    local b = keys[index + 1] or a
    local span = math.max(0.000001, b.frame - a.frame)
    local fraction = (frame - a.frame) / span
    return lerp_value(a.x, b.x, fraction),
        lerp_value(a.y, b.y, fraction),
        lerp_value(a.z, b.z, fraction),
        lerp_value(a.px, b.px, fraction),
        lerp_value(a.py, b.py, fraction),
        lerp_value(a.pz, b.pz, fraction)
end

local function sample_flex_track(track, frame)
    local keys = track and track.keys or {}
    if #keys <= 0 then return 0 end

    if frame <= keys[1].frame then
        return keys[1].weight or 0
    end
    if frame >= keys[#keys].frame then
        return keys[#keys].weight or 0
    end

    local index = track_span_index(keys, frame)
    local a = keys[index]
    local b = keys[index + 1] or a
    local span = math.max(0.000001, b.frame - a.frame)
    local fraction = (frame - a.frame) / span
    return math.Clamp(lerp_value(a.weight, b.weight, fraction), 0, 1)
end

local function clamp_frame(motion, requestedFrame)
    local startFrame = math.floor(tonumber(motion.frameStart) or 0)
    local endFrame = math.floor(tonumber(motion.frameEnd) or startFrame)
    if endFrame < startFrame then endFrame = startFrame end

    local frame = math.floor(tonumber(requestedFrame) or startFrame)
    return math.Clamp(frame, startFrame, endFrame), startFrame, endFrame
end

local function is_debug_reference_frame(activeFrame)
    return math.floor(tonumber(activeFrame) or 0) <= DEBUG_REFERENCE_FRAME
end

local function build_pose_rows(ply, motion, activeFrame, noPoseReset, targetOverride)
    local tracks = motion.boneTracks or {}
    local rows = {}
    local target = targetOverride or MMDVMDNPC.DebugTargets[ply]
    local hasTarget = is_usable_npc(target)
    local referenceInfo = hasTarget and lookup_reference_sequence_info(target) or nil
    local referenceOnly = is_debug_reference_frame(activeFrame)

    if hasTarget and not noPoseReset then
        local _, forcedInfo = force_reference_pose(target)
        referenceInfo = forcedInfo or referenceInfo
        clear_all_bone_manipulations(target)
        clear_all_flex_weights(target)
    end

    for index, track in ipairs(tracks) do
        local x, y, z, px, py, pz = 0, 0, 0, 0, 0, 0
        if not referenceOnly then
            x, y, z, px, py, pz = sample_track(track, activeFrame)
        end
        local bone = hasTarget and target.LookupBone and target:LookupBone(track.source or "") or nil
        rows[#rows + 1] = {
            index = index,
            track = track,
            rawX = x,
            rawY = y,
            rawZ = z,
            posX = px,
            posY = py,
            posZ = pz,
            bone = bone,
            depth = bone and bone_depth(target, bone) or 999999,
            manip = ZERO_ANGLE,
            resolved = bone ~= nil,
        }
    end

    if hasTarget then
        table.sort(rows, function(a, b)
            if a.resolved ~= b.resolved then return a.resolved end
            if a.depth ~= b.depth then return a.depth < b.depth end
            if (a.bone or 999999) ~= (b.bone or 999999) then return (a.bone or 999999) < (b.bone or 999999) end
            return (a.index or 0) < (b.index or 0)
        end)
    end

    return rows, hasTarget and target:EntIndex() or 0, referenceInfo
end

local function build_flex_rows(ply, motion, activeFrame, targetOverride)
    local tracks = motion.flexTracks or {}
    local rows = {}
    local target = targetOverride or MMDVMDNPC.DebugTargets[ply]
    local hasTarget = is_usable_npc(target)
    local referenceOnly = is_debug_reference_frame(activeFrame)

    for index, track in ipairs(tracks) do
        local flexID = -1
        local resolvedName = ""
        if hasTarget and MMDVMDNPC.ResolveFlexID then
            flexID, resolvedName = MMDVMDNPC.ResolveFlexID(target, track.source or "", track.mmd or "")
        end
        rows[#rows + 1] = {
            index = index,
            track = track,
            weight = referenceOnly and 0 or sample_flex_track(track, activeFrame),
            flexID = flexID or -1,
            resolvedName = resolvedName or "",
            resolved = flexID ~= nil and flexID >= 0,
        }
    end

    table.sort(rows, function(a, b)
        return (a.index or 0) < (b.index or 0)
    end)

    return rows
end

local function write_frame_payload(motion, motionID, activeFrame, startFrame, endFrame, prevFrame, nextFrame, targetEntIndex, referenceInfo, rows, flexRows)
    local count = math.min(#rows, 65535)
    local flexCount = math.min(#flexRows, 65535)

    net.WriteInt(math.floor(tonumber(startFrame) or 0), 32)
    net.WriteInt(math.floor(tonumber(endFrame) or 0), 32)
    net.WriteInt(math.floor(tonumber(activeFrame) or 0), 32)
    net.WriteInt(math.floor(tonumber(prevFrame) or 0), 32)
    net.WriteInt(math.floor(tonumber(nextFrame) or 0), 32)
    net.WriteUInt(motion.fps or MMDVMDNPC.VMDFPS or 30, 16)
    net.WriteFloat(motion.duration or 0)
    net.WriteUInt(math.max(0, targetEntIndex or 0), 16)
    net.WriteInt(math.max(-1, tonumber(referenceInfo and referenceInfo.seq) or -1), 16)
    net.WriteString(MMDVMDNPC.ReferenceSequenceDisplayName and MMDVMDNPC.ReferenceSequenceDisplayName(referenceInfo) or tostring(referenceInfo and (referenceInfo.displayName or referenceInfo.lookupName or referenceInfo.name) or ""))
    net.WriteString(tostring(referenceInfo and referenceInfo.basis or ""))
    net.WriteString(MMDVMDNPC.ReferenceSequenceAxisText and MMDVMDNPC.ReferenceSequenceAxisText(referenceInfo) or "")
    net.WriteUInt(count, 16)
    for i = 1, count do
        local row = rows[i]
        local track = row.track
        net.WriteString(track.mmd or "")
        net.WriteString(track.source or "")
        net.WriteString(track.role or "")
        net.WriteFloat(row.rawX or 0)
        net.WriteFloat(row.rawY or 0)
        net.WriteFloat(row.rawZ or 0)
        net.WriteFloat(row.posX or 0)
        net.WriteFloat(row.posY or 0)
        net.WriteFloat(row.posZ or 0)
        net.WriteFloat(row.manip.p or 0)
        net.WriteFloat(row.manip.y or 0)
        net.WriteFloat(row.manip.r or 0)
        net.WriteBool(row.resolved == true)
    end
    net.WriteUInt(flexCount, 16)
    for i = 1, flexCount do
        local row = flexRows[i]
        local track = row.track
        net.WriteString(track.mmd or "")
        net.WriteString(track.source or "")
        net.WriteString(row.resolvedName or "")
        net.WriteFloat(row.weight or 0)
        net.WriteInt(row.flexID or -1, 16)
        net.WriteBool(row.resolved == true)
    end
end

local function send_debug_frame(ply, motionID, requestedFrame)
    local motion, err = MMDVMDNPC.LoadMotion(motionID)
    if not motion then
        net.Start("mmdvmd_debug_response")
            net.WriteBool(false)
            net.WriteString(tostring(motionID or ""))
            net.WriteString(tostring(err or "failed to load motion"))
        net.Send(ply)
        return
    end

    local activeFrame, startFrame, endFrame = clamp_frame(motion, requestedFrame)
    local requested = math.floor(tonumber(requestedFrame) or startFrame)
    if requested <= DEBUG_REFERENCE_FRAME then
        activeFrame = DEBUG_REFERENCE_FRAME
    end

    local prevFrame
    local nextFrame
    if activeFrame <= DEBUG_REFERENCE_FRAME then
        prevFrame = DEBUG_REFERENCE_FRAME
        nextFrame = startFrame
    else
        prevFrame = activeFrame <= startFrame and DEBUG_REFERENCE_FRAME or math.max(startFrame, activeFrame - 1)
        nextFrame = math.min(endFrame, activeFrame + 1)
    end
    local rows, targetEntIndex, referenceInfo = build_pose_rows(ply, motion, activeFrame)
    local flexRows = build_flex_rows(ply, motion, activeFrame)

    net.Start("mmdvmd_debug_response")
        net.WriteBool(true)
        net.WriteString(motion.id or tostring(motionID or ""))
        net.WriteString("")
        write_frame_payload(motion, motionID, activeFrame, startFrame, endFrame, prevFrame, nextFrame, targetEntIndex, referenceInfo, rows, flexRows)
    net.Send(ply)
end

local start_next_queued_build

local function safe_batch_count(job, requestedBatch)
    local boneCount = #(job.motion.boneTracks or {})
    local flexCount = #(job.motion.flexTracks or {})
    -- Bound the batch by BOTH message directions. The server->client request is
    -- 4 + 24*bones + 4*flexes bytes/frame; the client->server reply is larger
    -- per resolved track (a bone entry is ~26 B, a flex entry 6 B, plus 8 B of
    -- per-frame overhead vs 4). A batch that only fits the request can overflow
    -- the 64KB reply and stall the build, so size against the worst of the two.
    local requestPerFrame = 4 + boneCount * 24 + flexCount * 4
    local replyPerFrame = 8 + boneCount * 26 + flexCount * 6
    local perFrameBytes = math.max(requestPerFrame, replyPerFrame)
    if perFrameBytes <= 0 then return requestedBatch end

    local maxFrames = math.floor((MAX_NET_MESSAGE_BYTES - 64) / perFrameBytes)
    return math.max(1, math.min(requestedBatch, maxFrames))
end

local function send_build_frame_request(ply, job)
    if not IsValid(ply) or not job then return end
    if not ai_disabled_enabled() then
        clear_build_job(ply)
        MMDVMDNPC.BuildQueues[ply] = nil
        fail_ai_disabled_required(ply, true)
        return
    end
    if not is_usable_npc(job.ent) then
        local abortedID = job.id
        clear_build_job(ply)
        send_build_done(ply, false, "", "selected actor is no longer valid", abortedID)
        if start_next_queued_build then start_next_queued_build(ply) end
        return
    end

    local batchCount = math.min(clamp_build_frames_per_batch(job.buildFramesPerBatch), job.endFrame - job.currentFrame + 1)
    batchCount = safe_batch_count(job, batchCount)
    if batchCount <= 0 then return end
    job.lastRequestedBuildFrames = batchCount
    job.lastRequestAt = CurTime()
    send_build_progress(
        ply,
        "building",
        job,
        string.format("building frames %d-%d / %d", job.currentFrame, math.min(job.endFrame, job.currentFrame + batchCount - 1), job.endFrame)
    )
    net.Start("mmdvmd_build_compact_request")
        net.WriteUInt(job.id, 32)
        net.WriteString(job.motionID)
        net.WriteUInt(batchCount, 8)
        for offset = 0, batchCount - 1 do
            local activeFrame = job.currentFrame + offset
            net.WriteUInt(math.max(0, activeFrame), 32)
            for _, track in ipairs(job.motion.boneTracks or {}) do
                local x, y, z, px, py, pz = sample_track(track, activeFrame)
                net.WriteFloat(x or 0)
                net.WriteFloat(y or 0)
                net.WriteFloat(z or 0)
                net.WriteFloat(px or 0)
                net.WriteFloat(py or 0)
                net.WriteFloat(pz or 0)
            end
            for _, track in ipairs(job.motion.flexTracks or {}) do
                net.WriteFloat(sample_flex_track(track, activeFrame) or 0)
            end
        end
    net.Send(ply)

    send_play_status(ply, "building", string.format("building frames %d-%d / %d", job.currentFrame, math.min(job.endFrame, job.currentFrame + batchCount - 1), job.endFrame))
end

local function send_build_plan(ply, job)
    if not IsValid(ply) or not job then return end

    local boneTracks = job.motion.boneTracks or {}
    local flexTracks = job.motion.flexTracks or {}
    net.Start("mmdvmd_build_plan")
        net.WriteUInt(job.id, 32)
        net.WriteString(job.motionID)
        net.WriteEntity(job.ent)
        net.WriteString(job.model or "")
        net.WriteUInt(math.max(1, job.motion.fps or MMDVMDNPC.VMDFPS or 30), 16)
        net.WriteUInt(math.max(0, job.startFrame or 0), 32)
        net.WriteUInt(math.max(0, job.endFrame or 0), 32)
        net.WriteFloat(job.startDelay or MMDVMDNPC.DefaultStartDelay or 2)
        net.WriteUInt(math.min(#boneTracks, 4096), 16)
        for i = 1, math.min(#boneTracks, 4096) do
            local track = boneTracks[i]
            local bone = job.ent.LookupBone and job.ent:LookupBone(track.source or "") or nil
            net.WriteString(track.mmd or "")
            net.WriteString(track.source or "")
            net.WriteString(track.role or "")
            net.WriteBool(bone ~= nil)
            net.WriteUInt(math.max(0, bone or 0), 16)
            if bone then
                job.bones[bone] = {
                    name = job.ent.GetBoneName and (job.ent:GetBoneName(bone) or "") or "",
                    source = track.source or "",
                    mmd = track.mmd or "",
                    role = track.role or "",
                }
            end
        end
        net.WriteUInt(math.min(#flexTracks, 4096), 16)
        for i = 1, math.min(#flexTracks, 4096) do
            local track = flexTracks[i]
            local flexID, resolvedName = MMDVMDNPC.ResolveFlexID(job.ent, track.source or "", track.mmd or "")
            net.WriteString(track.mmd or "")
            net.WriteString(track.source or "")
            net.WriteString(resolvedName or "")
            net.WriteBool(flexID ~= nil and flexID >= 0)
            net.WriteInt(flexID or -1, 16)
            if flexID and flexID >= 0 then
                job.flexes[flexID] = {
                    name = job.ent.GetFlexName and (job.ent:GetFlexName(flexID) or "") or "",
                    source = track.source or "",
                    mmd = track.mmd or "",
                    resolved = resolvedName or "",
                }
            end
        end
    net.Send(ply)
end

local function sorted_metadata(map)
    local out = {}
    for id, meta in pairs(map or {}) do
        if istable(meta) then
            out[#out + 1] = {
                id = tonumber(id) or id,
                name = tostring(meta.name or ""),
                source = tostring(meta.source or ""),
                mmd = tostring(meta.mmd or ""),
                role = tostring(meta.role or ""),
                resolved = tostring(meta.resolved or ""),
            }
        else
            out[#out + 1] = { id = tonumber(id) or id, name = tostring(meta or "") }
        end
    end
    table.sort(out, function(a, b) return (a.id or 0) < (b.id or 0) end)
    return out
end

local function finalize_build(ply, job)
    local path = MMDVMDNPC.BuiltPath(job.motionID, job.model, job.options)
    if not path then
        clear_build_job(ply)
        send_build_done(ply, false, "", "invalid built cache path")
        return
    end

    table.sort(job.frames, function(a, b) return (a.frame or 0) < (b.frame or 0) end)

    local built = {
        format = MMDVMDNPC.BuiltFormat,
        motion_id = job.motionID,
        model = job.model,
        fps = job.motion.fps or MMDVMDNPC.VMDFPS or 30,
        playback_hz = clamp_playback_hz(job.playbackHz),
        frame_start = job.startFrame,
        frame_end = job.endFrame,
        frame_count = #job.frames,
        source_modified = job.sourceModified or 0,
        music = job.motion.music or nil,
        reference = job.referenceInfo and {
            sequence = MMDVMDNPC.ReferenceSequenceDisplayName and MMDVMDNPC.ReferenceSequenceDisplayName(job.referenceInfo) or (job.referenceInfo.displayName or job.referenceInfo.lookupName or job.referenceInfo.name or ""),
            sequence_index = job.referenceInfo.seq or -1,
            basis = job.referenceInfo.basis or "reference",
            axes = MMDVMDNPC.ReferenceSequenceAxisText and MMDVMDNPC.ReferenceSequenceAxisText(job.referenceInfo) or "",
        } or nil,
        options = {
            disable_armtwist = job.options.disableArmTwist == true,
            disable_handtwist = job.options.disableHandTwist == true,
            disable_eyes = job.options.disableEyes == true,
            disable_spine_pelvis_correction = job.options.disableSpinePelvisCorrection == true,
        },
        bones = sorted_metadata(job.bones),
        flexes = sorted_metadata(job.flexes),
        frames = job.frames,
    }

    file.CreateDir(MMDVMDNPC.BuiltRoot)
    file.Write(path, util.TableToJSON(built, false))
    store_built_cache(path, built)
    clear_build_job(ply)
    send_assignment_status(ply)

    send_build_done(ply, true, path, string.format("built %d frame(s)", #job.frames), job.id)
    send_play_status(ply, "built", path)
    local pendingPlay = MMDVMDNPC.PendingAutoPlay[ply]
    if pendingPlay and pendingPlay.motionID == job.motionID then
        MMDVMDNPC.PendingAutoPlay[ply] = nil
        MMDVMDNPC.StartPlaybackForPlayer(ply, job.motionID, job.options, pendingPlay.settings)
    end
    if start_next_queued_build then start_next_queued_build(ply) end
end

local function load_built_animation(motionID, ent, options)
    local path = MMDVMDNPC.BuiltPath(motionID, ent:GetModel() or "", options)
    if not path then return nil, "invalid built cache path" end

    local cached = MMDVMDNPC.BuiltCache[path]
    if cached then return cached, path end

    local raw = file.Read(path, "DATA")
    if not raw then return nil, "build the animation for this actor model first", "missing" end

    local parsed = util.JSONToTable(raw)
    if not istable(parsed) then return nil, "built animation JSON is invalid" end
    if parsed.format ~= MMDVMDNPC.BuiltFormat then
        return nil, "unsupported built animation format: " .. tostring(parsed.format or "missing")
    end
    if tostring(parsed.model or "") ~= tostring(ent:GetModel() or "") then
        return nil, "built animation model does not match selected actor"
    end

    store_built_cache(path, parsed)
    return parsed, path
end

function MMDVMDNPC.HasBuiltAnimationForPlayer(ply, motionID, options)
    local ent = MMDVMDNPC.DebugTargets[ply]
    if not is_usable_npc(ent) then return false end
    local path = MMDVMDNPC.BuiltPath(motionID, ent:GetModel() or "", options)
    local exists = path ~= nil and (MMDVMDNPC.BuiltCache[path] ~= nil or file.Exists(path, "DATA"))
    return exists == true, path
end

function MMDVMDNPC.ReportBuiltStatusForPlayer(ply, motionID, options)
    local hasBuilt, path = MMDVMDNPC.HasBuiltAnimationForPlayer(ply, motionID, options)
    if hasBuilt then
        send_build_done(ply, true, path, "built cache already exists")
    else
        send_play_status(ply, "missing_build", L("mmd_vmd_npc.status.built_cache_missing_options", "built cache missing for selected model/options.") .. build_missing_instruction())
    end
    return hasBuilt, path
end

local function built_matches_scope(built, motionID, model)
    if not istable(built) then return false end
    if built.format ~= MMDVMDNPC.BuiltFormat then return false end
    if tostring(built.motion_id or "") ~= tostring(motionID or "") then return false end
    if model ~= nil and tostring(built.model or "") ~= tostring(model or "") then return false end
    return true
end


local function remove_matching_built_cache(motionID, model)
    local removed = 0
    local id = tostring(motionID or "")
    if id == "" then return 0 end

    local wantModel = model ~= nil and tostring(model) or nil

    -- BuiltPath() names files "<id>_<modelName>[_<modelHash>]_<opts>.json". Both
    -- the motion id and the model's safe name may themselves contain '_', so a
    -- filename PREFIX cannot be parsed back into (id, model) unambiguously — e.g.
    -- "motion_2_alyx_..._tw0..." is an equally valid file for id "motion" (model
    -- "2_alyx") and for id "motion_2" (model "alyx"), and a bare-digit CRC segment
    -- is indistinguishable from a numeric tail of a sibling model name ("miku" vs
    -- "miku_2"). Matching by filename alone therefore over-deletes sibling motions'
    -- / models' caches (confirmed review finding). We instead use the fast glob
    -- only to NARROW to candidates, then confirm each against the exact
    -- motion_id/model via the cheap mtime-keyed header index (BuiltHeader): once a
    -- file is indexed (every build notes its header) this reads no file body, so
    -- the clear stays fast — no full-directory JSON scan — but is collision-free.
    local function drop(path)
        MMDVMDNPC.BuiltCache[path] = nil
        if MMDVMDNPC.ForgetBuiltHeader then MMDVMDNPC.ForgetBuiltHeader(path) end
        file.Delete(path)
        removed = removed + 1
    end

    local glob
    if wantModel ~= nil then
        glob = id .. "_" .. MMDVMDNPC.SafeModelName(model) .. "_*" .. MMDVMDNPC.CacheExtension
    else
        glob = id .. "_*" .. MMDVMDNPC.CacheExtension
    end

    local seen = {}
    for _, name in ipairs(file.Find(MMDVMDNPC.BuiltRoot .. "/" .. glob, "DATA") or {}) do
        local path = MMDVMDNPC.BuiltRoot .. "/" .. name
        seen[path] = true
        local header = MMDVMDNPC.BuiltHeader and MMDVMDNPC.BuiltHeader(path, MMDVMDNPC.BuiltCache[path]) or nil
        if header and tostring(header.motion_id or "") == id
            and (wantModel == nil or tostring(header.model or "") == wantModel) then
            drop(path)
        end
    end

    -- Defensive: drop any in-memory cache entries the glob could not cover (e.g. a
    -- BuiltCache path whose on-disk file was already removed). Skip already-handled
    -- paths so the removed count is not double-incremented.
    for path, built in pairs(MMDVMDNPC.BuiltCache) do
        if not seen[path] and built_matches_scope(built, motionID, model) then
            MMDVMDNPC.BuiltCache[path] = nil
            if MMDVMDNPC.ForgetBuiltHeader then MMDVMDNPC.ForgetBuiltHeader(path) end
            removed = removed + 1
        end
    end

    return removed
end

function MMDVMDNPC.ClearBuiltForPlayer(ply, motionID, scope)
    local id = MMDVMDNPC.NormalizeMotionID(motionID)
    if not id then
        send_clear_built_done(ply, false, 0, "select a motion JSON first")
        return false
    end

    local model = nil
    if scope == "model" then
        local ent = MMDVMDNPC.DebugTargets[ply]
        if not is_usable_npc(ent) then
            send_clear_built_done(ply, false, 0, actor_select_prompt())
            return false
        end
        model = ent:GetModel() or ""
        if is_playable_player(ent) and MMDVMDNPC.StopSelfPlaybackForPlayer then
            MMDVMDNPC.StopSelfPlaybackForPlayer(ply, true)
        else
            MMDVMDNPC.StopPlayback(ent, true)
        end
    elseif scope ~= "all" then
        send_clear_built_done(ply, false, 0, "unknown clear scope")
        return false
    end

    if scope == "all" then
        for ent, state in pairs(MMDVMDNPC.Playbacks) do
            if state and state.built and tostring(state.built.motion_id or "") == id then
                MMDVMDNPC.StopPlayback(ent, true)
            end
        end
    end

    local removed = remove_matching_built_cache(id, model)
    local message = scope == "model"
        and string.format("cleared %d build(s) for %s on %s", removed, id, model)
        or string.format("cleared %d build(s) for %s on all models", removed, id)
    send_clear_built_done(ply, true, removed, message)
    send_play_status(ply, "cleared_build", message)
    send_assignment_status(ply)
    return true
end

local function safe_music_sound_path(soundPath)
    soundPath = tostring(soundPath or "")
    soundPath = string.Replace(soundPath, "\\", "/")
    soundPath = string.gsub(soundPath, "^sound/", "")
    soundPath = string.Trim(soundPath)
    if soundPath == "" then return nil end
    if string.find(soundPath, "..", 1, true) then return nil end
    if string.sub(soundPath, 1, 1) == "/" then return nil end
    if not string.match(string.lower(soundPath), "^mmd_vmd_npc/music/[%w_%-%. ]+%.mp3$") then return nil end
    return soundPath
end

local function try_delete_imported_music(soundPath)
    local safe = safe_music_sound_path(soundPath)
    if not safe then return "", false, false end

    local gamePath = "sound/" .. safe
    local existed = file.Exists(gamePath, "GAME") == true
    file.Delete(gamePath)
    file.Delete(safe)
    local stillExists = file.Exists(gamePath, "GAME") == true
    return gamePath, existed and not stillExists, existed
end

local function remove_motion_assignments(motionID)
    for ply, set in pairs(MMDVMDNPC.AssignedActors or {}) do
        if istable(set) then
            for i = #(set.order or {}), 1, -1 do
                local ent = set.order[i]
                local assignment = set.byEnt and set.byEnt[ent] or nil
                if assignment and tostring(assignment.motionID or "") == tostring(motionID or "") then
                    if set.byEnt then set.byEnt[ent] = nil end
                    table.remove(set.order, i)
                end
            end
            if IsValid(ply) then
                MMDVMDNPC.DebugTargets[ply] = first_assignment_ent(ply)
                send_assignment_status(ply)
            end
        end
    end
end

local function remove_motion_build_jobs(motionID)
    for ply, job in pairs(MMDVMDNPC.BuildJobs or {}) do
        if job and tostring(job.motionID or "") == tostring(motionID or "") then
            clear_build_job(ply)
            if IsValid(ply) then
                send_build_done(ply, false, "", "motion was deleted")
            end
        end
    end

    for ply, queue in pairs(MMDVMDNPC.BuildQueues or {}) do
        if istable(queue) then
            for i = #queue, 1, -1 do
                if tostring(queue[i].motionID or "") == tostring(motionID or "") then
                    table.remove(queue, i)
                end
            end
            if #queue <= 0 then
                MMDVMDNPC.BuildQueues[ply] = nil
            end
        end
    end
end

function MMDVMDNPC.DeleteMotionForPlayer(ply, motionID)
    local path, id = MMDVMDNPC.MotionPath(motionID)
    if not path or not id then
        send_delete_motion_done(ply, false, "", "select a motion JSON first", 0, "", false)
        return false, "select a motion JSON first"
    end

    local motion = MMDVMDNPC.LoadMotion(id)
    local musicSound = motion and motion.music and motion.music.sound or ""
    local existed = file.Exists(path, "DATA") == true
    if not existed then
        MMDVMDNPC.Cache[id] = nil
        send_delete_motion_done(ply, false, id, "motion JSON not found: " .. path, 0, "", false)
        return false, "motion JSON not found"
    end

    local playbackTargets = {}
    for ent, state in pairs(MMDVMDNPC.Playbacks or {}) do
        local stateMotion = state and (
            (state.motion and state.motion.id)
            or (state.built and state.built.motion_id)
            or ""
        ) or ""
        if tostring(stateMotion or "") == id then
            playbackTargets[#playbackTargets + 1] = ent
        end
    end
    for _, ent in ipairs(playbackTargets) do
        MMDVMDNPC.StopPlayback(ent, true)
    end

    remove_motion_build_jobs(id)
    remove_motion_assignments(id)
    local removedBuilt = remove_matching_built_cache(id, nil)

    file.Delete(path)
    MMDVMDNPC.Cache[id] = nil
    if MMDVMDNPC.ForgetMotionMeta then MMDVMDNPC.ForgetMotionMeta(id) end

    local musicPath, musicRemoved, musicExisted = try_delete_imported_music(musicSound)
    local deleted = file.Exists(path, "DATA") ~= true
    local message = deleted
        and string.format("deleted motion %s and %d built cache(s)", id, removedBuilt)
        or string.format("failed to delete motion JSON %s", path)

    if musicPath ~= "" then
        if musicRemoved then
            message = message .. "; deleted music " .. musicPath
        elseif musicExisted then
            message = message .. "; music may need manual deletion: garrysmod/" .. musicPath
        else
            message = message .. "; music file was not found: garrysmod/" .. musicPath
        end
    end

    send_delete_motion_done(ply, deleted, id, message, removedBuilt, musicPath, musicRemoved)
    send_play_status(ply, deleted and "deleted_motion" or "error", message)
    send_motion_list(ply)
    queue_motion_details(ply, normalize_options(false, false, false, false))
    return deleted, message
end

local function normalize_angle_delta(a, b)
    return math.NormalizeAngle((b or 0) - (a or 0))
end

local function lerp_angle_value(a, b, fraction)
    return (a or 0) + normalize_angle_delta(a or 0, b or 0) * fraction
end

local function send_audio_stop(state)
    if not state or not state.audioToken then return end
    net.Start("mmdvmd_audio_stop")
        net.WriteUInt(state.audioToken, 32)
    net.Broadcast()
end

local function send_audio_pause(state, paused)
    if not state or not state.audioStarted or not state.audioToken then return end
    net.Start("mmdvmd_audio_pause")
        net.WriteUInt(state.audioToken, 32)
        net.WriteBool(paused == true)
    net.Broadcast()
end

local function send_audio_start(state)
    if not state or state.audioStarted then return end
    if state.musicEnabled == false then return end
    local motion = state.motion or {}
    local soundPath = motion.music and motion.music.sound or ""
    if soundPath == "" then return end

    state.audioStarted = true
    state.audioToken = state.audioToken or math.random(1, 2147483647)

    local ply = state.ply
    -- The DANCER is the audio anchor: clients gate the omni volume (and 3D
    -- position) on their distance to it, so anchoring on the initiating player
    -- would pin the initiator's own music at full volume forever.
    local sourceEnt = IsValid(state.ent) and state.ent or (IsValid(ply) and ply or nil)
    local origin = sourceEnt and sourceEnt:GetPos() or vector_origin
    local filter = RecipientFilter()
    filter:AddPAS(origin)
    if IsValid(ply) then filter:AddPlayer(ply) end

    net.Start("mmdvmd_audio_start")
        net.WriteUInt(state.audioToken, 32)
        net.WriteString(soundPath)
        -- Entity index, not an entity handle: recipients outside the dancer's
        -- PVS would read a permanently NULL handle; an index can be
        -- re-resolved client-side once the entity is networked to them.
        net.WriteUInt(sourceEnt and sourceEnt:EntIndex() or 0, 16)
        net.WriteFloat(tonumber(state.audioOffset) or 0)
        net.WriteFloat(tonumber(state.started) or CurTime())
        net.WriteFloat(math.Clamp(tonumber(state.musicVolume) or MMDVMDNPC.DefaultMusicVolume or 1, 0, 2))
    net.Send(filter)
end

local function restart_audio_for_loop(state)
    if not state or state.musicEnabled == false then return end
    if state.audioStarted then
        send_audio_stop(state)
    end
    state.audioStarted = false
    state.audioToken = math.random(1, 2147483647)
    send_audio_start(state)
end

-- Camera track streaming ------------------------------------------------------
-- Camera paths live in the motion JSON server-side; the initiating player's
-- client needs the keys to render the animated view, so they are streamed in
-- bounded binary chunks (32 bytes/key; chunks stay well under the 64KB cap).
local CAMERA_KEYS_PER_MESSAGE = 900
MMDVMDNPC.NextCameraTransferID = MMDVMDNPC.NextCameraTransferID or 1

local function send_camera_track(ply, anchorEnt, motion, opts)
    if not IsValid(ply) then return false end
    opts = opts or {}
    local camera = motion and motion.camera or nil
    local keys = istable(camera) and camera.keys or nil
    local total = istable(keys) and math.min(#keys, 65535) or 0
    if total <= 0 and opts.debug ~= true then return false end

    local transferID = MMDVMDNPC.NextCameraTransferID
    MMDVMDNPC.NextCameraTransferID = transferID % 1000000 + 1

    net.Start("mmdvmd_camera_begin")
        net.WriteUInt(transferID, 32)
        net.WriteUInt(math.max(0, IsValid(anchorEnt) and anchorEnt:EntIndex() or 0), 16)
        net.WriteString(tostring(motion and motion.id or opts.motionID or ""))
        -- Anchor transform snapshot at dance start: root-motion playback moves
        -- the entity origin during the dance, and the camera VMD already
        -- contains the character's travel, so the client must not re-anchor
        -- the camera path to the live entity (it would double-count it).
        net.WriteVector(IsValid(anchorEnt) and anchorEnt:GetPos() or Vector(0, 0, 0))
        net.WriteFloat(IsValid(anchorEnt) and (anchorEnt:GetAngles().y or 0) or 0)
        net.WriteUInt(math.Clamp(math.floor(istable(camera) and camera.fps or 30), 1, 1000), 16)
        net.WriteUInt(math.max(0, math.floor(istable(camera) and camera.frameStart or 0)), 32)
        net.WriteUInt(math.max(0, math.floor(istable(camera) and camera.frameEnd or 0)), 32)
        net.WriteFloat(tonumber(opts.startAt) or 0)
        net.WriteBool(opts.loop == true)
        -- Loop period in SECONDS of the BODY motion: looping restarts follow the
        -- dance, not the camera's own (possibly shorter) frame range.
        net.WriteFloat(math.max(0, tonumber(opts.loopSeconds) or 0))
        net.WriteBool(opts.autoEnter == true)
        net.WriteBool(opts.debug == true)
        net.WriteUInt(total, 16)
    net.Send(ply)

    local function send_chunk(index)
        local count = math.min(CAMERA_KEYS_PER_MESSAGE, total - index + 1)
        net.Start("mmdvmd_camera_keys")
            net.WriteUInt(transferID, 32)
            net.WriteUInt(index, 16)
            net.WriteUInt(count, 16)
            for i = index, index + count - 1 do
                local key = keys[i]
                net.WriteUInt(math.max(0, math.floor(key.frame)), 32)
                net.WriteFloat(key.x)
                net.WriteFloat(key.y)
                net.WriteFloat(key.z)
                net.WriteFloat(key.p)
                net.WriteFloat(key.yw)
                net.WriteFloat(key.r)
                net.WriteFloat(key.fov)
            end
        net.Send(ply)
        return index + count
    end

    -- Send the first chunks immediately (covers virtually every real track);
    -- pace any additional ones across ticks so a huge track cannot flood the
    -- client's reliable channel in a single burst.
    local index = 1
    local immediate = 0
    while index <= total and immediate < 2 do
        index = send_chunk(index)
        immediate = immediate + 1
    end
    local delay = 0
    while index <= total do
        local chunkStart = index
        delay = delay + 0.1
        timer.Simple(delay, function()
            if not IsValid(ply) then return end
            send_chunk(chunkStart)
        end)
        index = index + math.min(CAMERA_KEYS_PER_MESSAGE, total - index + 1)
    end
    return total > 0
end

local function send_camera_stop(ply, anchorEntIndex)
    if not IsValid(ply) then return end
    net.Start("mmdvmd_camera_stop")
        net.WriteUInt(math.max(0, tonumber(anchorEntIndex) or 0), 16)
    net.Send(ply)
end

local function send_camera_sync(state)
    if not state or not state.cameraSent or not IsValid(state.ply) then return end
    net.Start("mmdvmd_camera_sync")
        net.WriteUInt(math.max(0, tonumber(state.cameraEntIndex) or 0), 16)
        net.WriteBool(state.paused == true)
        net.WriteFloat(tonumber(state.started) or 0)
    net.Send(state.ply)
end

local function stop_camera_for_state(state)
    if not state or not state.cameraSent then return end
    state.cameraSent = nil
    if IsValid(state.ply) then
        send_camera_stop(state.ply, state.cameraEntIndex)
    end
end

-- Root motion: the pelvis track's horizontal travel is carried on the ENTITY
-- ORIGIN instead of a bone position manipulation. Networked bone position
-- manipulations are range-limited by the engine, which visibly froze dances
-- that walk far from the start point (the imported/built data itself holds the
-- full travel); SetPos has full range and clients interpolate it smoothly.
-- Replicated so the client-side interpolated poser (cl_menu apply_local_built_sample)
-- can mirror this split exactly: when root motion is on, the SERVER carries the
-- pelvis horizontal on the entity origin (SetPos) and zeroes it in the bone
-- manipulation. If the client poser kept the full horizontal in its own manip it
-- would stack on top of the networked origin -> the model renders at DOUBLE the
-- travel on the initiating player's screen. The client must know the mode.
local cv_root_motion_origin = CreateConVar(
    "mmd_vmd_npc_root_motion_origin", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED),
    "Carry the dance's root travel on the entity origin so characters can walk any distance (0 = legacy bone-offset only)"
)

local function apply_built_sample(ent, frameA, frameB, fraction, pelvisZOffset, state)
    if not is_usable_npc(ent) then return end

    frameA = frameA or {}
    frameB = frameB or frameA
    fraction = math.Clamp(tonumber(fraction) or 0, 0, 1)
    pelvisZOffset = tonumber(pelvisZOffset) or 0
    local pelvisBone = ent.LookupBone and ent:LookupBone(SOURCE_PELVIS) or nil
    local rootMotion = state ~= nil and cv_root_motion_origin:GetBool()

    for index, boneA in ipairs(frameA.bones or {}) do
        local boneB = (frameB.bones or {})[index] or boneA
        local bone = tonumber(boneA[1]) or -1
        if bone >= 0 then
            local ang = Angle(
                lerp_angle_value(boneA[2], boneB[2], fraction),
                lerp_angle_value(boneA[3], boneB[3], fraction),
                lerp_angle_value(boneA[4], boneB[4], fraction)
            )
            local pos = Vector(
                lerp_value(boneA[5], boneB[5], fraction),
                lerp_value(boneA[6], boneB[6], fraction),
                lerp_value(boneA[7], boneB[7], fraction)
            )
            if pelvisBone and bone == pelvisBone then
                pos.z = pos.z + pelvisZOffset
                if rootMotion then
                    -- Anchor once to the dance-start transform (set eagerly at
                    -- playback start; guarded here for safety), then move the
                    -- origin by the pelvis's horizontal travel rotated into
                    -- world space. The manipulation keeps only the vertical
                    -- component, which stays far inside the networked range.
                    if not state.rootBase then
                        state.rootBase = ent:GetPos()
                        state.rootYaw = Angle(0, ent:GetAngles().y or 0, 0)
                    end
                    local travel = Vector(pos.x, pos.y, 0)
                    travel:Rotate(state.rootYaw)
                    ent:SetPos(state.rootBase + travel)
                    pos.x = 0
                    pos.y = 0
                end
            end
            ent:ManipulateBoneAngles(bone, ang, true)
            if ent.ManipulateBonePosition then
                ent:ManipulateBonePosition(bone, pos)
            end
        end
    end

    if ent.SetFlexWeight then
        for index, flexA in ipairs(frameA.flexes or {}) do
            local flexB = (frameB.flexes or {})[index] or flexA
            local flexID = tonumber(flexA[1]) or -1
            if flexID >= 0 then
                ent:SetFlexWeight(flexID, math.Clamp(lerp_value(flexA[2], flexB[2], fraction), 0, 1))
            end
        end
    end

    setup_bones_now(ent)
end

local function playback_initiator(state)
    if state and IsValid(state.initiator) then return state.initiator end
    if state and IsValid(state.ply) then return state.ply end
    return nil
end

local function active_eye_track_camera_data(state, now)
    local owner = playback_initiator(state)
    local data = owner ~= nil and MMDVMDNPC.EyeTrackCameraTargets[owner] or nil
    if istable(data) and data.active and isvector(data.pos) and (tonumber(data.expires) or 0) >= now then
        return data
    end
    return nil
end

local function eye_tracking_target_position(state, now)
    local cameraData = active_eye_track_camera_data(state, now)
    if cameraData then return cameraData.pos end

    local mode = MMDVMDNPC.NormalizeEyeTrackMode(state and state.eyeTrackMode)
    if mode == "off" or mode == "camera" then return nil end

    local ply = playback_initiator(state)
    if IsValid(ply) then
        local eyePos = ply.EyePos and ply:EyePos() or nil
        if isvector(eyePos) then return eyePos end
        return ply:GetPos() + Vector(0, 0, 64)
    end

    return nil
end

local function apply_runtime_eye_tracking(ent, state, now)
    if not is_usable_npc(ent) or not state then return end

    local targetWorld = eye_tracking_target_position(state, now)
    if not isvector(targetWorld) then
        if state.eyeTrack then reset_runtime_eye_tracking(ent, state.eyeTrack) end
        return
    end

    local eyeState = state.eyeTrack
    if not eyeState then
        eyeState = {}
        state.eyeTrack = eyeState
    end
    if not eyeState.eyeBonesResolved then
        eyeState.eyeBoneL, eyeState.eyeBoneR = resolve_eye_bones(ent)
        eyeState.eyeBonesResolved = true
    end

    local lookLeftRight, lookUpDown, lookBack = compute_look_controls(ent, targetWorld)
    local dt = math.max(0.001, now - (eyeState.lastApply or now))
    eyeState.lastApply = now
    local cameraData = active_eye_track_camera_data(state, now)
    local smooth = istable(cameraData) and cameraData.smooth or state.eyeTrackSmooth
    local moveback = istable(cameraData) and cameraData.moveback or state.eyeTrackMoveBack
    local posUD = istable(cameraData) and cameraData.posUD or state.eyeTrackPosUD
    local posLR = istable(cameraData) and cameraData.posLR or state.eyeTrackPosLR
    local alpha = 1 - math.exp(-dt * math.max(0.1, tonumber(smooth) or EYE_TRACK_SMOOTH))

    eyeState.curL = (eyeState.curL or 0) + (lookLeftRight - (eyeState.curL or 0)) * alpha
    eyeState.curU = (eyeState.curU or 0) + (lookUpDown - (eyeState.curU or 0)) * alpha
    eyeState.curB = (eyeState.curB or 0) + (lookBack - (eyeState.curB or 0)) * alpha
    eyeState.target = targetWorld

    if ent.ManipulateBonePosition and (eyeState.eyeBoneL ~= nil or eyeState.eyeBoneR ~= nil) then
        local eyeVec = eyeState.eyeVec or Vector(0, 0, 0)
        eyeState.eyeVec = eyeVec
        eyeVec.x = math.Clamp(eyeState.curU or 0, -1, 1) * (tonumber(posUD) or EYE_TRACK_BONE_POS_UD)
        eyeVec.y = math.Clamp(eyeState.curB or 0, 0, 1) * (tonumber(moveback) or EYE_TRACK_BONE_MOVE_BACK)
        eyeVec.z = -math.Clamp(eyeState.curL or 0, -1, 1) * (tonumber(posLR) or EYE_TRACK_BONE_POS_LR)

        if eyeState.eyeBoneL ~= nil then ent:ManipulateBonePosition(eyeState.eyeBoneL, eyeVec) end
        if eyeState.eyeBoneR ~= nil then ent:ManipulateBonePosition(eyeState.eyeBoneR, eyeVec) end
        setup_bones_now(ent)
    end
end

function MMDVMDNPC.StopPlayback(ent, clearPose)
    if not is_usable_npc(ent) then return end
    MMDVMDNPC.DebugFlexHolds[ent] = nil
    local state = MMDVMDNPC.Playbacks[ent]
    MMDVMDNPC.Playbacks[ent] = nil
    if update_rpe_body_suppression then update_rpe_body_suppression() end
    if state then send_audio_stop(state) end
    stop_camera_for_state(state)
    if state and state.cvarSuppression then
        end_scoped_cvar_suppression(state.cvarSuppression)
        state.cvarSuppression = nil
    end
    if state then reset_runtime_eye_tracking(ent, state.eyeTrack) end
    if state and state.selfProxy then
        set_self_player_movement_locked(state.realPlayer, false)
    else
        freeze_player_target(ent, false)
    end

    if clearPose ~= false then
        -- Root motion moved the origin along the dance; put the actor back at
        -- its start spot, matching how clearing manipulations resets the pose.
        if state and state.rootBase and ent.SetPos then
            ent:SetPos(state.rootBase)
        end
        clear_all_bone_manipulations(ent)
        clear_all_flex_weights(ent)
        force_reference_pose(ent)
    end

    if state and IsValid(state.ply) then
        send_play_status(state.ply, "stopped", "playback stopped", ent)
    end
    cleanup_self_proxy_state(state)
end

function MMDVMDNPC.StopAllPlaybacksForPlayer(ply)
    local targets = {}
    for ent in pairs(MMDVMDNPC.Playbacks or {}) do
        targets[#targets + 1] = ent
    end

    local stopped = 0
    for _, ent in ipairs(targets) do
        local state = MMDVMDNPC.Playbacks[ent]
        if is_playable_npc(ent) and not is_self_playback_proxy(ent) and not (state and state.selfProxy) then
            MMDVMDNPC.StopPlayback(ent, true)
            stopped = stopped + 1
        elseif not is_usable_npc(ent) then
            -- Tear the state down the same way update_playback_state does for an
            -- invalidated entity: otherwise a self-proxy whose realPlayer is
            -- still valid leaves that player permanently hidden/movement-locked.
            MMDVMDNPC.Playbacks[ent] = nil
            if state then
                send_audio_stop(state)
                if state.cvarSuppression then
                    end_scoped_cvar_suppression(state.cvarSuppression)
                    state.cvarSuppression = nil
                end
                stop_camera_for_state(state)
                cleanup_self_proxy_state(state)
            end
        end
    end
    if update_rpe_body_suppression then update_rpe_body_suppression() end

    local message = string.format("stopped %d NPC playback(s)", stopped)
    if IsValid(ply) then
        send_play_status(ply, "stopped_all", message)
    end
    return stopped, message
end

local function start_playback_on_entity(ply, ent, motionID, options, playbackSettings, sharedStart, sharedDelayUntil, suppressMusic, preparedBuilt, preparedPath, preparedMotion, suppressCamera)
    if not is_usable_npc(ent) then
        local message = actor_select_prompt()
        send_play_status(ply, "error", message)
        return false, message
    end
    local referenceOK, referenceErr = require_reference_sequence_for_actor(ply, ent, false)
    if not referenceOK then return false, referenceErr end
    if not ai_disabled_enabled() then
        return fail_ai_disabled_required(ply, false)
    end
    warn_if_ai_enabled(ply, ent)

    local built, pathOrErr, errCode = preparedBuilt, preparedPath, nil
    if not built then
        built, pathOrErr, errCode = load_built_animation(motionID, ent, options)
    end
    if not built then
        if errCode == "missing" then
            MMDVMDNPC.PendingBuildConfirm[ply] = {
                motionID = motionID,
                options = options,
                settings = playbackSettings,
            }
            send_play_status(ply, "missing_build",
                pathOrErr .. build_missing_instruction() ..
                "1 — build + play, 2 — cancel.")
        else
            send_play_status(ply, "error", pathOrErr)
            local pendingPlay = MMDVMDNPC.PendingAutoPlay[ply]
        end
        return false, pathOrErr
    end

    local playbackEnt = ent
    local selfProxy = is_playable_player(ent)
    if selfProxy then
        -- Dance on foot: a seated player would leave the proxy performing at
        -- the vehicle while the hidden driver could still throttle it away.
        if ent.InVehicle and ent:InVehicle() and ent.ExitVehicle then
            ent:ExitVehicle()
        end
        local proxy, proxyErr = create_self_playback_proxy(ent)
        if not IsValid(proxy) then
            send_play_status(ply, "error", proxyErr or "failed to create self playback model")
            return false, proxyErr or "failed to create self playback model"
        end
        playbackEnt = proxy
        set_self_player_hidden(ent, true)
        set_self_player_movement_locked(ent, true)
    else
        MMDVMDNPC.StopPlayback(playbackEnt, true)
    end

    force_reference_pose(playbackEnt)
    clear_all_bone_manipulations(playbackEnt)
    -- Optional: kill the model's jigglebones for the duration of this dance so
    -- they don't fight the imported pose. The tool convar is USERINFO, so it is
    -- readable server-side for every play path (tool, wheel, group).
    if IsValid(ply) and ply:GetInfoNum("mmd_vmd_npc_disable_jiggle", 0) == 1 then
        disable_all_bone_jiggle(playbackEnt)
    end
    clear_all_flex_weights(playbackEnt)
    freeze_player_target(playbackEnt, true)

    playbackSettings = playbackSettings or playback_settings_from_values(nil, nil)
    local delay = clamp_start_delay(playbackSettings.startDelay)
    local now = CurTime()
    local startAt = tonumber(sharedStart) or (now + delay)
    local delayUntil = tonumber(sharedDelayUntil) or startAt
    local motion = preparedMotion or MMDVMDNPC.LoadMotion(motionID) or {}
    if not motion.music and built.music then
        motion.music = built.music
    end
    -- Playback owns the face from here on; a lingering debug hold would fight
    -- the sampled flex weights the moment the dance ends.
    MMDVMDNPC.DebugFlexHolds[playbackEnt] = nil
    MMDVMDNPC.Playbacks[playbackEnt] = {
        ply = ply,
        initiator = ply,
        ent = playbackEnt,
        realPlayer = selfProxy and ent or nil,
        selfProxy = selfProxy,
        -- Dance-start transform: root-motion playback moves the origin along
        -- the pelvis track and restores it here on stop. Captured after any
        -- group alignment, and matching the camera track's anchor snapshot.
        rootBase = playbackEnt:GetPos(),
        rootYaw = Angle(0, playbackEnt:GetAngles().y or 0, 0),
        built = built,
        motion = motion,
        path = pathOrErr,
        started = startAt,
        delayUntil = delayUntil,
        startDelay = delay,
        pelvisZOffset = playbackSettings.pelvisZOffset,
        audioOffset = audio_offset_for_motion(motionID),
        audioToken = math.random(1, 2147483647),
        musicEnabled = playbackSettings.musicEnabled ~= false and suppressMusic ~= true,
        musicVolume = playbackSettings.musicVolume,
        loopPlayback = playbackSettings.loopPlayback == true,
        playbackHz = clamp_playback_hz(playbackSettings.playbackHz),
        eyeTrackMode = MMDVMDNPC.NormalizeEyeTrackMode(playbackSettings.eyeTrackMode),
        eyeTrackSmooth = playbackSettings.eyeTrackSmooth,
        eyeTrackMoveBack = playbackSettings.eyeTrackMoveBack,
        eyeTrackPosUD = playbackSettings.eyeTrackPosUD,
        eyeTrackPosLR = playbackSettings.eyeTrackPosLR,
        cvarSuppression = begin_scoped_cvar_suppression(PLAYBACK_SUPPRESSED_CVARS),
        sentPlaying = false,
        nextTick = 0,
    }
    if update_rpe_body_suppression then update_rpe_body_suppression() end

    -- Stream the motion's camera path (if any) to the initiating player so
    -- their client can render the animated view anchored to this entity.
    local state = MMDVMDNPC.Playbacks[playbackEnt]
    if suppressCamera ~= true and istable(motion.camera) then
        state.cameraEntIndex = playbackEnt:EntIndex()
        state.cameraSent = send_camera_track(ply, playbackEnt, motion, {
            startAt = startAt,
            loop = state.loopPlayback == true,
            loopSeconds = math.max(0, ((built.frame_end or 0) - (built.frame_start or 0)) / math.max(1, built.fps or motion.fps or 30)),
            -- The client decides whether to actually enter via its
            -- mmd_vmd_npc_camera_auto convar; every playback the player
            -- started (wheel, self via menu, NPC, group) is eligible.
            autoEnter = true,
        })
    end

    send_play_status(ply, "countdown", string.format("%s starts in %.1f seconds", pathOrErr, math.max(0, delayUntil - now)), playbackEnt)
    return true, pathOrErr, MMDVMDNPC.Playbacks[playbackEnt], playbackEnt
end

function MMDVMDNPC.StartPlaybackForPlayer(ply, motionID, options, playbackSettings)
    local ent = MMDVMDNPC.DebugTargets[ply]
    return start_playback_on_entity(ply, ent, motionID, options, playbackSettings)
end

-- One-shot "play this motion on myself" used by the radial wheel: select the
-- player as the target, then play if a built cache already exists for their
-- playermodel+options, otherwise build it and auto-play the instant it finishes
-- (no chat confirmation, unlike the manual play path).
function MMDVMDNPC.PlayOrBuildSelfForPlayer(ply, motionID, options, playbackSettings)
    if not IsValid(ply) then return false, L("mmd_vmd_npc.status.invalid_player", "invalid player") end

    options = normalize_options(options and options.disableArmTwist, options and options.disableHandTwist, options and options.disableEyes, options and options.disableSpinePelvisCorrection)
    playbackSettings = playbackSettings or playback_settings_from_values(nil, nil)

    local ok, err = MMDVMDNPC.SelectTargetForPlayer(ply, ply)
    if not ok then
        if err then MMDVMDNPC.Chat(ply, err) end
        return false, err
    end

    if MMDVMDNPC.HasBuiltAnimationForPlayer(ply, motionID, options) then
        return MMDVMDNPC.StartPlaybackForPlayer(ply, motionID, options, playbackSettings)
    end

    MMDVMDNPC.PendingAutoPlay[ply] = {
        motionID = MMDVMDNPC.NormalizeMotionID(motionID) or tostring(motionID or ""),
        settings = playbackSettings,
    }
    send_play_status(ply, "building", "building this motion for your playermodel, then playing automatically")
    local buildOK, buildErr = MMDVMDNPC.BeginBuildForPlayer(ply, motionID, options, playbackSettings)
    if not buildOK then
        MMDVMDNPC.PendingAutoPlay[ply] = nil
    end
    return buildOK, buildErr
end

local function copy_playback_settings(settings)
    settings = settings or playback_settings_from_values(nil, nil)
    return {
        startDelay = settings.startDelay,
        pelvisZOffset = settings.pelvisZOffset,
        eyeTrackMode = settings.eyeTrackMode,
        eyeTrackSmooth = settings.eyeTrackSmooth,
        eyeTrackMoveBack = settings.eyeTrackMoveBack,
        eyeTrackPosUD = settings.eyeTrackPosUD,
        eyeTrackPosLR = settings.eyeTrackPosLR,
        musicEnabled = settings.musicEnabled,
        musicVolume = settings.musicVolume,
        loopPlayback = settings.loopPlayback == true,
        buildFramesPerBatch = settings.buildFramesPerBatch,
        playbackHz = settings.playbackHz,
    }
end

function MMDVMDNPC.StartAssignedGroupPlaybackForPlayer(ply, playbackSettings)
    if not IsValid(ply) then return false, L("mmd_vmd_npc.status.invalid_player", "invalid player") end
    if not ai_disabled_enabled() then
        return fail_ai_disabled_required(ply, false)
    end

    local set = compact_assignments(ply)
    if #set.order <= 0 then
        local message = L("mmd_vmd_npc.status.select_npcs_before_group_play", "select one or more NPCs before starting a coordinated dance")
        send_play_status(ply, "error", message)
        return false, message
    end

    local prepared = {}
    local missing = {}
    local unsupported = {}
    for _, ent in ipairs(set.order) do
        local assignment = set.byEnt[ent]
        if assignment and is_playable_npc(ent) then
            local referenceInfo, referenceErr = lookup_required_reference_sequence_info(ent)
            if not referenceInfo then
                unsupported[#unsupported + 1] = tostring(ent) .. ": " .. tostring(referenceErr or missing_reference_sequence_message())
            else
                local built, pathOrErr = load_built_animation(assignment.motionID, ent, assignment.options)
                if not built then
                    missing[#missing + 1] = tostring(assignment.motionID or "?") .. " on " .. tostring(ent)
                else
                    local motion = MMDVMDNPC.LoadMotion(assignment.motionID) or {}
                    if not motion.music and built.music then motion.music = built.music end
                    prepared[#prepared + 1] = {
                        ent = ent,
                        assignment = assignment,
                        built = built,
                        path = pathOrErr,
                        motion = motion,
                    }
                end
            end
        end
    end

    if #unsupported > 0 then
        local message = table.concat(unsupported, "; ")
        send_play_status(ply, "error", message)
        MMDVMDNPC.Chat(ply, message)
        send_assignment_status(ply)
        return false, message
    end
    if #missing > 0 then
        local message = LF("mmd_vmd_npc.status.build_missing_group_fmt", table.concat(missing, "; ")) .. build_missing_instruction()
        send_play_status(ply, "missing_build", message)
        MMDVMDNPC.Chat(ply, message)
        send_assignment_status(ply)
        return false, message
    end
    if #prepared <= 0 then
        local message = L("mmd_vmd_npc.status.no_valid_selected_npcs", "no valid selected NPCs to play")
        send_play_status(ply, "error", message)
        send_assignment_status(ply)
        return false, message
    end

    playbackSettings = playbackSettings or playback_settings_from_values(nil, nil)
    local delay = clamp_start_delay(playbackSettings.startDelay)
    local now = CurTime()
    local startAt = now + delay
    local started = 0

    for index, item in ipairs(prepared) do
        local settings = copy_playback_settings(item.assignment.playbackSettings)
        settings.startDelay = delay
        settings.loopPlayback = playbackSettings.loopPlayback == true
        local suppressMusic = index ~= 1

        -- Camera pivots on the first character in the group: only its motion's
        -- camera path is streamed.
        local ok = start_playback_on_entity(
            ply,
            item.ent,
            item.assignment.motionID,
            item.assignment.options,
            settings,
            startAt,
            startAt,
            suppressMusic,
            item.built,
            item.path,
            item.motion,
            index ~= 1
        )
        if ok then started = started + 1 end
    end

    local firstEnt = prepared[1] and prepared[1].ent or nil
    send_play_status(ply, "countdown", LF("mmd_vmd_npc.status.group_countdown_fmt", started, delay), firstEnt)
    return started > 0, LF("mmd_vmd_npc.status.started_group_fmt", started)
end

function MMDVMDNPC.AlignAssignedActorsToFirstForPlayer(ply)
    if not IsValid(ply) then return false, L("mmd_vmd_npc.status.invalid_player", "invalid player") end
    local set = compact_assignments(ply)
    local firstEnt = set.order[1]
    if not is_playable_npc(firstEnt) then
        local message = L("mmd_vmd_npc.status.select_first_npc_align", "select a first NPC before aligning coordinated dance NPCs")
        send_play_status(ply, "error", message)
        send_assignment_status(ply)
        return false, message
    end

    for _, ent in ipairs(set.order) do
        if is_playable_npc(ent) and MMDVMDNPC.Playbacks[ent] then
            MMDVMDNPC.StopPlayback(ent, true)
        end
    end

    local pos = firstEnt:GetPos()
    local ang = firstEnt:GetAngles()
    local targetAng = Angle(0, ang.y or 0, 0)
    local moved = 0

    for index, ent in ipairs(set.order) do
        if index > 1 and is_playable_npc(ent) then
            ent:SetPos(pos)
            ent:SetAngles(targetAng)
            if ent.SetEyeTarget then pcall(ent.SetEyeTarget, ent, ZERO_VECTOR) end
            setup_bones_now(ent)
            moved = moved + 1
        end
    end

    MMDVMDNPC.DebugTargets[ply] = firstEnt
    send_assignment_status(ply)
    local message = LF("mmd_vmd_npc.status.aligned_selected_npcs_fmt", moved)
    send_play_status(ply, "aligned", message, firstEnt)
    return true, message
end

function MMDVMDNPC.ClearAssignedActorsForPlayer(ply, mode)
    local set = compact_assignments(ply)
    local removed = 0

    if mode == "missing" then
        for i = #set.order, 1, -1 do
            local ent = set.order[i]
            local assignment = set.byEnt[ent]
            if not assignment or assignment_build_status(ply, assignment) == "missing" then
                set.byEnt[ent] = nil
                table.remove(set.order, i)
                removed = removed + 1
            end
        end
    else
        removed = #set.order
        set.order = {}
        set.byEnt = {}
    end

    MMDVMDNPC.DebugTargets[ply] = first_assignment_ent(ply)
    if update_rpe_body_suppression then update_rpe_body_suppression() end
    send_target_status(ply, removed > 0 and string.format("removed %d coordinated selection(s)", removed) or "no coordinated selections removed")
    send_assignment_status(ply)
    return true, removed
end

function MMDVMDNPC.IsSelfPlaybackRunningForPlayer(ply)
    local proxy = MMDVMDNPC.SelfPlaybackProxies[ply]
    return IsValid(proxy) and MMDVMDNPC.Playbacks[proxy] ~= nil
end

function MMDVMDNPC.StopSelfPlaybackForPlayer(ply, clearPose)
    local proxy = MMDVMDNPC.SelfPlaybackProxies[ply]
    if IsValid(proxy) and MMDVMDNPC.Playbacks[proxy] then
        MMDVMDNPC.StopPlayback(proxy, clearPose ~= false)
        return true
    end
    cleanup_self_proxy_for_player(ply)
    return false
end

function MMDVMDNPC.ForceResetSelfPlaybackForPlayer(ply)
    if not IsValid(ply) then return false end

    local stopped = MMDVMDNPC.StopSelfPlaybackForPlayer(ply, true)
    cleanup_self_proxy_for_player(ply)
    set_self_player_hidden(ply, false)
    set_self_player_movement_locked(ply, false)
    MMDVMDNPC.EyeTrackCameraTargets[ply] = nil

    local selected = MMDVMDNPC.DebugTargets[ply]
    if selected == ply or is_playable_player(selected) then
        MMDVMDNPC.DebugTargets[ply] = first_assignment_ent(ply)
    end

    local message = L("mmd_vmd_npc.status.self_playback_force_reset", "self playback reset; normal view restored")
    send_target_status(ply, message)
    send_assignment_status(ply)
    send_play_status(ply, "self_reset", message, NULL)
    MMDVMDNPC.Chat(ply, message)
    return stopped, message
end

local function playback_entity_for_player(ply, ent)
    if is_usable_npc(ent) and MMDVMDNPC.Playbacks[ent] then return ent end

    local selected = MMDVMDNPC.DebugTargets[ply]
    if is_usable_npc(selected) and MMDVMDNPC.Playbacks[selected] then return selected end

    local proxy = MMDVMDNPC.SelfPlaybackProxies[ply]
    if is_usable_npc(proxy) and MMDVMDNPC.Playbacks[proxy] then return proxy end

    for playbackEnt, state in pairs(MMDVMDNPC.Playbacks or {}) do
        if state and state.ply == ply and is_usable_npc(playbackEnt) then
            return playbackEnt
        end
    end

    return nil
end

local function set_playback_paused(playbackEnt, state, paused, ply)
    if not state or not is_usable_npc(playbackEnt) then return false end
    local now = CurTime()

    if paused == true then
        if state.paused then return true end
        state.paused = true
        state.pauseStarted = now
        state.nextPausedStatus = 0
        send_audio_pause(state, true)
        send_camera_sync(state)
        send_play_status(state.ply or ply, "paused", "playback paused", playbackEnt)
        return true
    end

    if not state.paused then return true end
    local pausedFor = math.max(0, now - (tonumber(state.pauseStarted) or now))
    state.paused = false
    state.pauseStarted = nil
    state.started = (tonumber(state.started) or now) + pausedFor
    if tonumber(state.delayUntil) and state.delayUntil > now then
        state.delayUntil = state.delayUntil + pausedFor
    end
    state.nextTick = 0
    state.nextPausedStatus = nil
    send_audio_pause(state, false)
    send_camera_sync(state)
    send_play_status(state.ply or ply, state.sentPlaying and "playing" or "countdown", "playback resumed", playbackEnt, state.started)
    return true
end

function MMDVMDNPC.ToggleAssignedPlaybackPauseForPlayer(ply)
    local set = compact_assignments(ply)
    local active = {}
    for _, ent in ipairs(set.order) do
        local state = MMDVMDNPC.Playbacks[ent]
        if state then
            active[#active + 1] = { ent = ent, state = state }
        end
    end

    if #active <= 0 then
        return false, L("mmd_vmd_npc.status.no_active_selected_playback_pause", "no active selected playback to pause")
    end

    local shouldPause = false
    for _, item in ipairs(active) do
        if item.state.paused ~= true then
            shouldPause = true
            break
        end
    end

    for _, item in ipairs(active) do
        set_playback_paused(item.ent, item.state, shouldPause, ply)
    end

    local message = shouldPause and L("mmd_vmd_npc.status.coordinated_playback_paused", "coordinated playback paused") or L("mmd_vmd_npc.status.coordinated_playback_resumed", "coordinated playback resumed")
    send_play_status(ply, shouldPause and "paused" or "group_resumed", message, active[1].ent)
    return true, message
end

function MMDVMDNPC.TogglePlaybackPauseForPlayer(ply, ent)
    local playbackEnt = playback_entity_for_player(ply, ent)
    if not is_usable_npc(playbackEnt) then
        local message = L("mmd_vmd_npc.status.no_active_playback_pause", "no active playback to pause")
        send_play_status(ply, "error", message)
        return false, message
    end

    local state = MMDVMDNPC.Playbacks[playbackEnt]
    if not state then
        local message = L("mmd_vmd_npc.status.no_active_playback_pause", "no active playback to pause")
        send_play_status(ply, "error", message)
        return false, message
    end

    local paused = state.paused ~= true
    set_playback_paused(playbackEnt, state, paused, ply)
    return true, paused and "paused" or "resumed"
end

local function update_playback_state(ent, state, now)
    if not is_usable_npc(ent) then
        MMDVMDNPC.Playbacks[ent] = nil
        if update_rpe_body_suppression then update_rpe_body_suppression() end
        if state and state.cvarSuppression then
            end_scoped_cvar_suppression(state.cvarSuppression)
            state.cvarSuppression = nil
        end
        stop_camera_for_state(state)
        cleanup_self_proxy_state(state)
        return
    end
    if not ai_disabled_enabled() then
        local ply = state.ply
        MMDVMDNPC.StopPlayback(ent, true)
        if IsValid(ply) then
            fail_ai_disabled_required(ply, false)
        end
        return
    end
    if state.selfProxy then
        if not is_playable_player(state.realPlayer) then
            MMDVMDNPC.StopPlayback(ent, true)
            return
        end
        set_self_player_hidden(state.realPlayer, true)
        set_self_player_movement_locked(state.realPlayer, true)
    end
    if state.paused then
        if state.sentPlaying then
            apply_runtime_eye_tracking(ent, state, now)
        else
            force_reference_pose(ent)
            stop_actor_motion(ent)
            apply_runtime_eye_tracking(ent, state, now)
        end
        if now >= (state.nextPausedStatus or 0) then
            state.nextPausedStatus = now + 1
            if IsValid(state.ply) then
                send_play_status(state.ply, "paused", "playback paused", ent)
            end
        end
        return
    end
    local delayUntil = tonumber(state.delayUntil) or 0
    if delayUntil > now then
        force_reference_pose(ent)
        stop_actor_motion(ent)
        apply_runtime_eye_tracking(ent, state, now)
        if now >= (state.nextCountdownStatus or 0) then
            state.nextCountdownStatus = now + 0.25
            if IsValid(state.ply) then
                send_play_status(state.ply, "countdown", string.format("playback starts in %.1f seconds", delayUntil - now), ent)
            end
        end
        return
    end
    if not state.sentPlaying then
        state.sentPlaying = true
        state.started = tonumber(state.started) or now
        if state.selfProxy then
            set_self_player_movement_locked(state.realPlayer, true)
        else
            freeze_player_target(ent, is_playable_player(ent))
        end
        if IsValid(state.ply) then
            send_play_status(state.ply, "playing", state.path or "", ent, state.started)
        end
        send_audio_start(state)
    end
    if now < (state.nextTick or 0) then return end
    state.nextTick = now + (1 / clamp_playback_hz(state.playbackHz))

    local built = state.built or {}
    local frames = built.frames or {}
    if #frames <= 0 then
        MMDVMDNPC.Playbacks[ent] = nil
        if update_rpe_body_suppression then update_rpe_body_suppression() end
        if state.cvarSuppression then
            end_scoped_cvar_suppression(state.cvarSuppression)
            state.cvarSuppression = nil
        end
        stop_camera_for_state(state)
        cleanup_self_proxy_state(state)
        return
    end

    local startFrame = math.floor(tonumber(built.frame_start) or 0)
    local endFrame = math.floor(tonumber(built.frame_end) or startFrame)
    local sourceFPS = math.max(1, tonumber(built.fps) or MMDVMDNPC.VMDFPS or 30)
    local sourceFrame = startFrame + (now - (state.started or now)) * sourceFPS
    local finished = sourceFrame >= endFrame
    if finished and state.loopPlayback == true then
        local duration = math.max(0, (endFrame - startFrame) / sourceFPS)
        if duration > 0 then
            local elapsed = math.max(0, now - (tonumber(state.started) or now))
            local loops = math.max(1, math.floor(elapsed / duration))
            state.started = (tonumber(state.started) or now) + loops * duration
            sourceFrame = startFrame + (now - (state.started or now)) * sourceFPS
            finished = false
            restart_audio_for_loop(state)
            send_camera_sync(state)
            state.nextBodySync = 0
        end
    end
    sourceFrame = math.Clamp(sourceFrame, startFrame, endFrame)

    if now >= (state.nextBodySync or 0) then
        state.nextBodySync = now + 2
        send_playback_body_sync(state, ent)
    end

    local lowerFrame = math.floor(sourceFrame)
    local upperFrame = math.min(endFrame, lowerFrame + 1)
    local fraction = sourceFrame - lowerFrame
    local lowerIndex = math.Clamp(lowerFrame - startFrame + 1, 1, #frames)
    local upperIndex = math.Clamp(upperFrame - startFrame + 1, 1, #frames)

    if ent.SetCycle then ent:SetCycle(0) end
    if ent.SetPlaybackRate then ent:SetPlaybackRate(0) end
    apply_built_sample(ent, frames[lowerIndex], frames[upperIndex], fraction, state.pelvisZOffset or 0, state)
    apply_runtime_eye_tracking(ent, state, now)

    if finished then
         
        if state.selfProxy and IsValid(state.realPlayer) then
             
            MMDVMDNPC.ForceResetSelfPlaybackForPlayer(state.realPlayer)
        else
             
            MMDVMDNPC.StopPlayback(ent, true)
        end
    end
end

local function update_build_job(ply, job, now)
    if not IsValid(ply) or not job then return end
    if not ai_disabled_enabled() then
        clear_build_job(ply)
        MMDVMDNPC.BuildQueues[ply] = nil
        freeze_player_target(job.ent, false)
        fail_ai_disabled_required(ply, true)
        return
    end
    if not is_usable_npc(job.ent) then
        local abortedID = job.id
        clear_build_job(ply)
        freeze_player_target(job.ent, false)
        send_build_done(ply, false, "", "selected actor is no longer valid", abortedID)
        if start_next_queued_build then start_next_queued_build(ply) end
        return
    end
    local referenceInfo, referenceErr = lookup_required_reference_sequence_info(job.ent)
    if not referenceInfo then
        local message = referenceErr or missing_reference_sequence_message()
        local abortedID = job.id
        clear_build_job(ply)
        freeze_player_target(job.ent, false)
        send_build_done(ply, false, "", message, abortedID)
        send_play_status(ply, "error", message, job.ent)
        MMDVMDNPC.Chat(ply, message)
        if start_next_queued_build then start_next_queued_build(ply) end
        return
    end

    local delayUntil = tonumber(job.delayUntil) or 0
    if delayUntil > now then
        if job.holdVisibleReference ~= false then
            force_reference_pose(job.ent)
            stop_actor_motion(job.ent)
        end
        if now >= (job.nextCountdownStatus or 0) then
            job.nextCountdownStatus = now + 0.25
            send_build_progress(ply, "countdown", job, string.format("build starts in %.1f seconds", delayUntil - now))
        end
        return
    end

    if not job.sentPlan then
        job.sentPlan = true
        if job.holdVisibleReference ~= false then
            freeze_player_target(job.ent, false)
        end
        send_build_plan(ply, job)
        send_build_progress(ply, "building", job, "starting hidden-model build")
        send_play_status(ply, "building", "starting hidden-model build")
        send_build_frame_request(ply, job)
        return
    end

    -- Progress otherwise depends entirely on the client answering each batch.
    -- If it never replies (Lua error, dropped request, oversized reply), the job
    -- would sit here forever holding cvar suppression and the frozen actor.
    -- Re-request the pending batch a few times, then abort so the queue and
    -- suppressed cvars are released.
    local lastRequestAt = tonumber(job.lastRequestAt) or now
    if now - lastRequestAt >= BUILD_STALL_SECONDS then
        job.buildRetries = (tonumber(job.buildRetries) or 0) + 1
        if job.buildRetries > BUILD_MAX_RETRIES then
            local abortedID = job.id
            clear_build_job(ply)
            freeze_player_target(job.ent, false)
            send_build_done(ply, false, "", "build timed out waiting for the client; try again", abortedID)
            send_play_status(ply, "error", "build timed out waiting for the client", job.ent)
            if start_next_queued_build then start_next_queued_build(ply) end
            return
        end
        send_build_progress(ply, "building", job, string.format("client stalled; retrying batch (%d/%d)", job.buildRetries, BUILD_MAX_RETRIES))
        send_build_frame_request(ply, job)
    end
end

hook.Add("Think", "MMDVMDNPCBuiltPlaybackThink", function()
    local now = CurTime()
    for ply, job in pairs(MMDVMDNPC.BuildJobs) do
        update_build_job(ply, job, now)
    end
    for ent, state in pairs(MMDVMDNPC.Playbacks) do
        update_playback_state(ent, state, now)
    end
    -- Re-assert held debug flex poses every tick so external flex drivers
    -- cannot stomp them back to neutral. Playback entities are skipped —
    -- apply_built_sample owns their faces. INVARIANT: a hold is only valid
    -- while its entity is still SOME player's debug target; anything else
    -- (disconnect, target switch, alignment reshuffle) is an orphan that
    -- would otherwise pin the face — and the RPE cvar suppression — forever.
    for ent, held in pairs(MMDVMDNPC.DebugFlexHolds) do
        local owned = false
        if IsValid(ent) then
            for _, target in pairs(MMDVMDNPC.DebugTargets or {}) do
                if target == ent then
                    owned = true
                    break
                end
            end
        end
        if not owned then
            MMDVMDNPC.DebugFlexHolds[ent] = nil
        elseif not MMDVMDNPC.Playbacks[ent] and ent.SetFlexWeight then
            for flexID, weight in pairs(held) do
                ent:SetFlexWeight(flexID, weight)
            end
        end
    end
    if update_rpe_body_suppression then update_rpe_body_suppression() end
end)

function MMDVMDNPC.OpenDebugForPlayer(ply, ent, motionID, vmdFrame)
    if not IsValid(ply) then return false, L("mmd_vmd_npc.status.invalid_player", "invalid player") end

    if is_usable_npc(ent) then
        -- Selection can now be DENIED (NPC AI enabled): opening the debug
        -- window anyway would bind it to the previous target, so fail cleanly.
        local ok, err = MMDVMDNPC.SelectTargetForPlayer(ply, ent)
        if not ok then
            return false, err or actor_select_prompt()
        end
    elseif ent ~= nil and IsValid(ent) then
        return false, actor_select_prompt()
    end

    motionID = tostring(motionID or "")
    if motionID == "" then
        return false, L("mmd_vmd_npc.error.select_motion", "Please select a motion JSON first")
    end

    vmdFrame = math.max(DEBUG_REFERENCE_FRAME, math.floor(tonumber(vmdFrame) or DEBUG_REFERENCE_FRAME))
    net.Start("mmdvmd_debug_open")
        net.WriteString(motionID)
        net.WriteInt(vmdFrame, 32)
    net.Send(ply)

    return true
end

net.Receive("mmdvmd_list_request", function(_, ply)
    send_motion_list(ply)
end)

net.Receive("mmdvmd_motion_details_request", function(_, ply)
    local options = normalize_options(net.ReadBool(), net.ReadBool(), net.ReadBool(), net.ReadBool())
    queue_motion_details(ply, options)
end)

net.Receive("mmdvmd_pause_status_request", function(_, ply)
    send_pause_status(ply)
end)

net.Receive("mmdvmd_audio_settings_request", function(_, ply)
    send_audio_settings(ply, net.ReadString())
end)

net.Receive("mmdvmd_audio_settings_save", function(_, ply)
    local id = MMDVMDNPC.NormalizeMotionID(net.ReadString())
    local offset = math.Clamp(net.ReadFloat(), -5, 5)
    if not id then return end
    if not player_can_edit_content(ply) then return deny_edit_permission(ply) end

    local offsets = load_audio_offsets()
    offsets[id] = offset
    save_audio_offsets()
    send_audio_settings(ply, id)
end)

MMDVMDNPC.LastDebugFrame = MMDVMDNPC.LastDebugFrame or {}

net.Receive("mmdvmd_debug_request", function(_, ply)
    local motionID = net.ReadString()
    local frame = net.ReadInt(32)
    -- Remembered so a flex-mapping change can push a refreshed frame back
    -- immediately (no race against the client's blind re-request timer).
    MMDVMDNPC.LastDebugFrame[ply] = { motionID = motionID, frame = frame }
    send_debug_frame(ply, motionID, frame)
end)

local function push_debug_frame_refresh(ply)
    local last = MMDVMDNPC.LastDebugFrame[ply]
    if last then
        send_debug_frame(ply, last.motionID, last.frame)
    end
end

net.Receive("mmdvmd_debug_apply", function(_, ply)
    local ent = net.ReadEntity()
    local count = math.Clamp(net.ReadUInt(16), 0, 4096)
    if not is_usable_npc(ent) or MMDVMDNPC.DebugTargets[ply] ~= ent then return end

    force_reference_pose(ent)
    clear_all_bone_manipulations(ent)
    clear_all_flex_weights(ent)

    local maxBones = ent:GetBoneCount() or 0
    for _ = 1, count do
        local bone = net.ReadUInt(16)
        local ang = net.ReadAngle()
        local pos = Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat())
        if bone >= 0 and bone < maxBones then
            ent:ManipulateBoneAngles(bone, ang, true)
            if ent.ManipulateBonePosition then
                ent:ManipulateBonePosition(bone, pos)
            end
        end
    end

    local flexCount = math.Clamp(net.ReadUInt(16), 0, 4096)
    local maxFlexes = ent.GetFlexNum and (ent:GetFlexNum() or 0) or 0
    local held = {}
    for _ = 1, flexCount do
        local flexID = net.ReadInt(16)
        local weight = math.Clamp(net.ReadFloat(), 0, 1)
        if ent.SetFlexWeight and flexID >= 0 and flexID < maxFlexes then
            ent:SetFlexWeight(flexID, weight)
            held[flexID] = weight
        end
    end

    -- Hold the applied face: without this the pose survives exactly one tick
    -- before an external flex driver (RPE living body, NPC AI expressions)
    -- resets it to neutral — "bones apply, face stays blank".
    MMDVMDNPC.DebugFlexHolds[ent] = next(held) ~= nil and held or nil
    if update_rpe_body_suppression then update_rpe_body_suppression() end

    setup_bones_now(ent)
end)

-- The debug window closed: drop the held flex pose and, when the target is not
-- mid-playback, restore the clean reference state the debug session replaced.
net.Receive("mmdvmd_debug_close", function(_, ply)
    if not IsValid(ply) then return end
    if MMDVMDNPC.LastDebugFrame then MMDVMDNPC.LastDebugFrame[ply] = nil end
    local ent = MMDVMDNPC.DebugTargets[ply]
    if is_usable_npc(ent) then
        MMDVMDNPC.DebugFlexHolds[ent] = nil
        -- Players are excluded from the restore: their anim system re-asserts
        -- next tick anyway and a forced reference pose would visibly pop.
        if not MMDVMDNPC.Playbacks[ent] and not is_playable_player(ent) then
            clear_all_bone_manipulations(ent)
            clear_all_flex_weights(ent)
            force_reference_pose(ent)
            setup_bones_now(ent)
        end
    end
    if update_rpe_body_suppression then update_rpe_body_suppression() end
end)

net.Receive("mmdvmd_flex_override_save", function(_, ply)
    local ent = net.ReadEntity()
    local motionID = net.ReadString()
    local mmdName = net.ReadString()
    local sourceName = net.ReadString()
    local flexName = net.ReadString()

    if not is_usable_npc(ent) or MMDVMDNPC.DebugTargets[ply] ~= ent then
        -- Silent returns here made the mapping buttons look dead; say why.
        send_play_status(ply, "error", L("mmd_vmd_npc.status.flex_override_target_mismatch", "flex mapping not saved: the debug window's NPC is no longer your selected target"), ent)
        return
    end
    if not player_can_edit_content(ply) then return deny_edit_permission(ply) end
    local resolvedName = resolved_flex_name_on_entity(ent, flexName)
    if not resolvedName then
        send_play_status(ply, "error", "selected model flex was not found", ent)
        return
    end

    if not MMDVMDNPC.SetFlexOverrideForModel or not MMDVMDNPC.SetFlexOverrideForModel(ent:GetModel() or "", mmdName, sourceName, resolvedName) then
        send_play_status(ply, "error", "failed to save flex mapping", ent)
        return
    end

    local removed = invalidate_built_for_model(ent:GetModel() or "")
    send_play_status(
        ply,
        "built",
        string.format("saved flex mapping for %s; removed %d built cache(s) for this model", tostring(mmdName ~= "" and mmdName or sourceName), removed),
        ent
    )
    queue_motion_details(ply, MMDVMDNPC.ToolOptions())
    -- Push the refreshed frame straight back so the debug window's table
    -- updates immediately (no race with the client's blind 0.2s re-request).
    push_debug_frame_refresh(ply)
end)

net.Receive("mmdvmd_flex_override_clear", function(_, ply)
    local ent = net.ReadEntity()
    local motionID = net.ReadString()
    local mmdName = net.ReadString()
    local sourceName = net.ReadString()

    if not is_usable_npc(ent) or MMDVMDNPC.DebugTargets[ply] ~= ent then
        -- Silent returns here made the mapping buttons look dead; say why.
        send_play_status(ply, "error", L("mmd_vmd_npc.status.flex_override_target_mismatch", "flex mapping not saved: the debug window's NPC is no longer your selected target"), ent)
        return
    end
    if not player_can_edit_content(ply) then return deny_edit_permission(ply) end
    if not MMDVMDNPC.ClearFlexOverrideForModel or not MMDVMDNPC.ClearFlexOverrideForModel(ent:GetModel() or "", mmdName, sourceName) then
        send_play_status(ply, "error", "no saved flex mapping was found", ent)
        return
    end

    local removed = invalidate_built_for_model(ent:GetModel() or "")
    send_play_status(
        ply,
        "built",
        string.format("cleared flex mapping for %s; removed %d built cache(s) for this model", tostring(mmdName ~= "" and mmdName or sourceName), removed),
        ent
    )
    queue_motion_details(ply, MMDVMDNPC.ToolOptions())
    -- Push the refreshed frame straight back so the debug window's table
    -- updates immediately (no race with the client's blind 0.2s re-request).
    push_debug_frame_refresh(ply)
end)

net.Receive("mmdvmd_flex_override_unassign", function(_, ply)
    local ent = net.ReadEntity()
    local motionID = net.ReadString()
    local mmdName = net.ReadString()
    local sourceName = net.ReadString()

    if not is_usable_npc(ent) or MMDVMDNPC.DebugTargets[ply] ~= ent then
        -- Silent returns here made the mapping buttons look dead; say why.
        send_play_status(ply, "error", L("mmd_vmd_npc.status.flex_override_target_mismatch", "flex mapping not saved: the debug window's NPC is no longer your selected target"), ent)
        return
    end
    if not player_can_edit_content(ply) then return deny_edit_permission(ply) end
    if not MMDVMDNPC.SetFlexUnassignedForModel or not MMDVMDNPC.SetFlexUnassignedForModel(ent:GetModel() or "", mmdName, sourceName) then
        send_play_status(ply, "error", "failed to unassign flex mapping", ent)
        return
    end

    local removed = invalidate_built_for_model(ent:GetModel() or "")
    send_play_status(
        ply,
        "built",
        string.format("unassigned flex mapping for %s; removed %d built cache(s) for this model", tostring(mmdName ~= "" and mmdName or sourceName), removed),
        ent
    )
    queue_motion_details(ply, MMDVMDNPC.ToolOptions())
    -- Push the refreshed frame straight back so the debug window's table
    -- updates immediately (no race with the client's blind 0.2s re-request).
    push_debug_frame_refresh(ply)
end)

net.Receive("mmdvmd_select_target", function(_, ply)
    local ent = net.ReadEntity()
    local ok, err = MMDVMDNPC.SelectTargetForPlayer(ply, ent)
    if not ok and err then MMDVMDNPC.Chat(ply, err) end
end)

local function build_request_matches_path(request, path)
    return istable(request) and tostring(request.path or "") == tostring(path or "")
end

local function queue_has_path(ply, path)
    for _, request in ipairs(MMDVMDNPC.BuildQueues[ply] or {}) do
        if build_request_matches_path(request, path) then return true end
    end
    return false
end

local function built_cache_exists(path)
    return path ~= nil and path ~= "" and (MMDVMDNPC.BuiltCache[path] ~= nil or file.Exists(path, "DATA"))
end

local function warn_built_cache_exists(ply, path, ent)
    local message = LF("mmd_vmd_npc.status.built_cache_exists_skip_fmt", tostring(path or ""))
    if IsValid(ply) then
        send_build_done(ply, true, tostring(path or ""), message)
        send_play_status(ply, "warning", message, ent)
        MMDVMDNPC.Chat(ply, message)
    end
    return true, path
end

local function start_build_for_entity(ply, ent, motionID, options, playbackSettings)
    if not is_usable_npc(ent) then
        return false, "selected actor is no longer valid"
    end
    local referenceOK, referenceErr = require_reference_sequence_for_actor(ply, ent, true)
    if not referenceOK then return false, referenceErr end
    if not ai_disabled_enabled() then
        return fail_ai_disabled_required(ply, true)
    end
    warn_if_ai_enabled(ply, ent)

    local motion, err = MMDVMDNPC.LoadMotion(motionID)
    if not motion then
        return false, err or "failed to load motion"
    end

    local _, startFrame, endFrame = clamp_frame(motion, motion.frameStart or 0)
    if (endFrame - startFrame + 1) > BUILD_MAX_FRAMES then
        return false, string.format("motion is too long to build (%d frames, max %d)", endFrame - startFrame + 1, BUILD_MAX_FRAMES)
    end
    local path, normalizedID = MMDVMDNPC.BuiltPath(motionID, ent:GetModel() or "", options)
    if not path then
        return false, "invalid motion id"
    end
    if built_cache_exists(path) then
        return warn_built_cache_exists(ply, path, ent)
    end

    local buildTargetIsPlayer = is_playable_player(ent)
    if MMDVMDNPC.Playbacks[ent] then
        MMDVMDNPC.StopPlayback(ent, true)
    elseif not buildTargetIsPlayer then
        MMDVMDNPC.StopPlayback(ent, true)
        force_reference_pose(ent)
    end
    print_reference_arm_axis_diagnostic(ent, motionID)

    playbackSettings = playbackSettings or playback_settings_from_values(nil, nil)
    local delay = clamp_start_delay(playbackSettings.startDelay)
    local now = CurTime()
    local motionPath = MMDVMDNPC.MotionPath(motionID)
    local referenceInfo = lookup_reference_sequence_info(ent)
    local job = {
        id = nextBuildID,
        ply = ply,
        ent = ent,
        motionID = normalizedID or MMDVMDNPC.NormalizeMotionID(motionID) or tostring(motionID or ""),
        motion = motion,
        model = ent:GetModel() or "",
        options = options,
        path = path,
        startFrame = startFrame,
        endFrame = endFrame,
        currentFrame = startFrame,
        sourceModified = motionPath and (file.Time(motionPath, "DATA") or 0) or 0,
        referenceInfo = referenceInfo,
        frames = {},
        bones = {},
        flexes = {},
        buildFramesPerBatch = clamp_build_frames_per_batch(playbackSettings.buildFramesPerBatch),
        playbackHz = clamp_playback_hz(playbackSettings.playbackHz),
        startDelay = delay,
        delayUntil = now + delay,
        holdVisibleReference = not buildTargetIsPlayer,
        sentPlan = false,
        cvarSuppression = begin_scoped_cvar_suppression(BUILD_SUPPRESSED_CVARS),
    }
    nextBuildID = nextBuildID + 1
    MMDVMDNPC.BuildJobs[ply] = job
    send_assignment_status(ply)
    if job.holdVisibleReference then
        send_play_status(ply, "countdown", string.format("build starts in %.1f seconds", delay))
        send_build_progress(ply, "countdown", job, string.format("freezing reference pose for %.1f seconds before build", delay))
    else
        send_play_status(ply, "building", string.format("hidden-model build starts in %.1f seconds", delay))
        send_build_progress(ply, "countdown", job, string.format("hidden-model build starts in %.1f seconds", delay))
    end
    return true, path
end

local function queue_build_for_player(ply, ent, motionID, options, path, playbackSettings)
    local referenceOK, referenceErr = require_reference_sequence_for_actor(ply, ent, true)
    if not referenceOK then return false, referenceErr end
    if not ai_disabled_enabled() then
        return fail_ai_disabled_required(ply, true)
    end

    local active = MMDVMDNPC.BuildJobs[ply]
    if built_cache_exists(path) then
        return warn_built_cache_exists(ply, path, ent)
    end
    if active and build_request_matches_path(active, path) then
        local message = "this model/options build is already running"
        send_build_progress(ply, "building", active, message)
        send_play_status(ply, "building", message)
        return true, message
    end

    MMDVMDNPC.BuildQueues[ply] = MMDVMDNPC.BuildQueues[ply] or {}
    if queue_has_path(ply, path) then
        local message = "this model/options build is already queued"
        send_build_progress(ply, "building", active or {}, message)
        send_play_status(ply, "building", message)
        return true, message
    end

    local request = {
        ent = ent,
        motionID = MMDVMDNPC.NormalizeMotionID(motionID) or tostring(motionID or ""),
        model = ent:GetModel() or "",
        options = options,
        path = path,
        playbackSettings = playbackSettings or playback_settings_from_values(nil, nil),
    }
    table.insert(MMDVMDNPC.BuildQueues[ply], request)
    send_assignment_status(ply)

    local message = string.format("queued build %d for %s", build_queue_count(ply), request.model)
    send_build_progress(ply, "building", active or request, message)
    send_play_status(ply, "building", message)
    return true, message
end

start_next_queued_build = function(ply)
    if not IsValid(ply) or MMDVMDNPC.BuildJobs[ply] then return false end

    local queue = MMDVMDNPC.BuildQueues[ply]
    while istable(queue) and #queue > 0 do
        local request = table.remove(queue, 1)
        if is_usable_npc(request.ent) then
            MMDVMDNPC.DebugTargets[ply] = request.ent
            send_target_status(ply, "selected queued " .. actor_label(request.ent))
            local referenceInfo, referenceErr = lookup_required_reference_sequence_info(request.ent)
            if not referenceInfo then
                local message = referenceErr or missing_reference_sequence_message()
                send_build_done(ply, false, "", message)
                send_play_status(ply, "error", message, request.ent)
                MMDVMDNPC.Chat(ply, message)
                send_assignment_status(ply)
            elseif built_cache_exists(request.path) then
                warn_built_cache_exists(ply, request.path, request.ent)
                send_assignment_status(ply)
            else
                local ok, err = start_build_for_entity(ply, request.ent, request.motionID, request.options, request.playbackSettings)
                if ok then return true end
                send_build_done(ply, false, "", err or "queued build failed")
            end
        else
            send_build_done(ply, false, "", "queued actor is no longer valid")
        end
    end

    return false
end

function MMDVMDNPC.BeginBuildForPlayer(ply, motionID, options, playbackSettings)
    options = normalize_options(options and options.disableArmTwist, options and options.disableHandTwist, options and options.disableEyes, options and options.disableSpinePelvisCorrection)
    playbackSettings = playbackSettings or playback_settings_from_values(nil, nil)
    local ent = MMDVMDNPC.DebugTargets[ply]
    if not is_usable_npc(ent) then
        local message = actor_select_prompt()
        send_build_done(ply, false, "", message)
        return false, message
    end
    local referenceOK, referenceErr = require_reference_sequence_for_actor(ply, ent, true)
    if not referenceOK then return false, referenceErr end
    if not ai_disabled_enabled() then
        return fail_ai_disabled_required(ply, true)
    end

    local path = MMDVMDNPC.BuiltPath(motionID, ent:GetModel() or "", options)
    if not path then
        send_build_done(ply, false, "", "invalid motion id")
        return false, "invalid motion id"
    end
    if built_cache_exists(path) then
        return warn_built_cache_exists(ply, path, ent)
    end

    if MMDVMDNPC.BuildJobs[ply] then
        return queue_build_for_player(ply, ent, motionID, options, path, playbackSettings)
    end

    local ok, result = start_build_for_entity(ply, ent, motionID, options, playbackSettings)
    if not ok then
        send_build_done(ply, false, "", result or "failed to start build")
    end
    return ok, result
end

function MMDVMDNPC.BeginBuildForAssignedActorsForPlayer(ply, playbackSettings)
    if not IsValid(ply) then return false, L("mmd_vmd_npc.status.invalid_player", "invalid player") end
    if not ai_disabled_enabled() then
        return fail_ai_disabled_required(ply, true)
    end

    local set = compact_assignments(ply)
    if #set.order <= 0 then
        local message = L("mmd_vmd_npc.status.select_npcs_before_build", "select one or more NPCs before building selected NPC animations")
        send_build_done(ply, false, "", message)
        send_play_status(ply, "error", message)
        return false, message
    end

    local started = 0
    local skippedBuilt = 0
    local failed = {}

    for _, ent in ipairs(set.order) do
        local assignment = set.byEnt[ent]
        if assignment and is_playable_npc(ent) then
            local referenceOK, referenceErr = require_reference_sequence_for_actor(ply, ent, true)
            if not referenceOK then
                failed[#failed + 1] = tostring(ent) .. ": " .. tostring(referenceErr or missing_reference_sequence_message())
            else
                local options = assignment.options or {}
                local motionID = assignment.motionID
                local path = MMDVMDNPC.BuiltPath(motionID, ent:GetModel() or "", options)
                if not path then
                    failed[#failed + 1] = tostring(ent) .. ": invalid motion id"
                elseif built_cache_exists(path) then
                    skippedBuilt = skippedBuilt + 1
                    warn_built_cache_exists(ply, path, ent)
                elseif MMDVMDNPC.BuildJobs[ply] then
                    local ok, err = queue_build_for_player(ply, ent, motionID, options, path, playbackSettings or assignment.playbackSettings)
                    if ok then
                        started = started + 1
                    else
                        failed[#failed + 1] = tostring(ent) .. ": " .. tostring(err or "failed to queue build")
                    end
                else
                    local ok, err = start_build_for_entity(ply, ent, motionID, options, playbackSettings or assignment.playbackSettings)
                    if ok then
                        started = started + 1
                    else
                        failed[#failed + 1] = tostring(ent) .. ": " .. tostring(err or "failed to start build")
                    end
                end
            end
        end
    end

    send_assignment_status(ply)

    if started > 0 then
        local message = LF("mmd_vmd_npc.status.started_queued_builds_fmt", started, skippedBuilt)
        if #failed > 0 then message = message .. L("mmd_vmd_npc.status.failed_suffix", "; failed: ") .. table.concat(failed, "; ") end
        send_play_status(ply, "building", message)
        return true, message
    end

    if skippedBuilt > 0 and #failed <= 0 then
        local message = LF("mmd_vmd_npc.status.all_builds_exist_fmt", skippedBuilt)
        send_build_done(ply, true, "", message)
        send_play_status(ply, "built", message)
        return true, message
    end

    local message = #failed > 0 and table.concat(failed, "; ") or L("mmd_vmd_npc.status.no_selected_build_needed", "no selected NPCs needed a build")
    send_build_done(ply, false, "", message)
    send_play_status(ply, "error", message)
    return false, message
end

local function remove_assignment(set, ent)
    set.byEnt[ent] = nil
    for i = #set.order, 1, -1 do
        if set.order[i] == ent then
            table.remove(set.order, i)
        end
    end
end

function MMDVMDNPC.AssignActorForPlayer(ply, ent, motionID, options, playbackSettings)
    if not IsValid(ply) then return false, L("mmd_vmd_npc.status.invalid_player", "invalid player") end
    if not is_playable_npc(ent) then
        local message = L("mmd_vmd_npc.error.left_click_valid_npc", "left-click a valid NPC for a coordinated dance selection")
        send_target_status(ply, message)
        send_assignment_status(ply)
        return false, message
    end
    if not ai_disabled_enabled() then
        local ok, message = fail_ai_disabled_required(ply, false)
        send_target_status(ply, message)
        send_assignment_status(ply)
        return ok, message
    end

    local set = compact_assignments(ply)
    if set.byEnt[ent] then
        remove_assignment(set, ent)
        if MMDVMDNPC.DebugTargets[ply] == ent then
            MMDVMDNPC.DebugTargets[ply] = first_assignment_ent(ply)
        end
        send_target_status(ply, L("mmd_vmd_npc.status.removed_npc_selection", "removed NPC from coordinated dance selection"))
        send_assignment_status(ply)
        return true, "removed"
    end
    local aiBlockMessage = deny_select_if_ai_enabled(ply, ent)
    if aiBlockMessage then
        send_play_status(ply, "error", aiBlockMessage, ent)
        send_assignment_status(ply)
        return false, aiBlockMessage
    end
    local referenceOK, referenceErr = require_reference_sequence_for_actor(ply, ent, true)
    if not referenceOK then
        send_assignment_status(ply)
        return false, referenceErr
    end

    local id = MMDVMDNPC.NormalizeMotionID(motionID)
    if not id then
        local message = L("mmd_vmd_npc.error.select_motion", "Please select a motion JSON first")
        send_target_status(ply, message)
        send_assignment_status(ply)
        return false, message
    end

    options = normalize_options(options and options.disableArmTwist, options and options.disableHandTwist, options and options.disableEyes, options and options.disableSpinePelvisCorrection)
    playbackSettings = playbackSettings or playback_settings_from_values(nil, nil)
    local path = MMDVMDNPC.BuiltPath(id, ent:GetModel() or "", options)
    if not path then
        local message = L("mmd_vmd_npc.status.invalid_motion_id", "invalid motion id")
        send_assignment_status(ply)
        return false, message
    end

    local assignment = {
        ent = ent,
        motionID = id,
        options = options,
        playbackSettings = playbackSettings,
        model = ent:GetModel() or "",
        path = path,
    }
    set.order[#set.order + 1] = ent
    set.byEnt[ent] = assignment
    MMDVMDNPC.DebugTargets[ply] = ent
    pose_selected_npc_reference(ent)
    send_target_status(ply, LF("mmd_vmd_npc.status.assigned_motion_to_npc_fmt", id, tostring(ent)))

    local status = assignment_build_status(ply, assignment)
    if status == "built" then
        send_build_done(ply, true, path, L("mmd_vmd_npc.status.built_cache_exists", "built cache already exists"))
    elseif status == "building" or status == "queued" then
        send_build_progress(ply, status, MMDVMDNPC.BuildJobs[ply] or assignment, LF("mmd_vmd_npc.status.build_already_fmt", status))
    else
        send_play_status(ply, "missing_build", L("mmd_vmd_npc.status.assigned_motion_missing_build", "assigned motion; built cache is missing.") .. build_missing_instruction(), ent)
    end

    send_assignment_status(ply)
    return true, path
end

net.Receive("mmdvmd_build_begin", function(_, ply)
    local motionID = net.ReadString()
    local options = normalize_options(net.ReadBool(), net.ReadBool(), net.ReadBool(), net.ReadBool())
    local settings = playback_settings_with_eye_track(net.ReadFloat(), net.ReadFloat(), net.ReadString(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat(), net.ReadBool(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat(), net.ReadBool())
    MMDVMDNPC.BeginBuildForPlayer(ply, motionID, options, settings)
end)

net.Receive("mmdvmd_build_cancel_request", function(_, ply)
    MMDVMDNPC.CancelBuildTasksForPlayer(ply)
end)

net.Receive("mmdvmd_build_frame_result", function(_, ply)
    local buildID = net.ReadUInt(32)
    local resultCount = net.ReadUInt(8)
    local job = MMDVMDNPC.BuildJobs[ply]
    if not job or job.id ~= buildID then return end
    -- Reject frame results that arrive before a batch was actually requested:
    -- without a matching request a client could fabricate and persist a whole
    -- built animation with no client-side retargeting pass.
    if not job.sentPlan or not job.lastRequestedBuildFrames then return end
    resultCount = math.Clamp(resultCount, 0, math.min(clamp_build_frames_per_batch(job.buildFramesPerBatch), tonumber(job.lastRequestedBuildFrames) or 255))
    if not ai_disabled_enabled() then
        clear_build_job(ply)
        MMDVMDNPC.BuildQueues[ply] = nil
        fail_ai_disabled_required(ply, true)
        return
    end
    if not is_usable_npc(job.ent) then
        local abortedID = job.id
        clear_build_job(ply)
        send_build_done(ply, false, "", "selected actor is no longer valid", abortedID)
        if start_next_queued_build then start_next_queued_build(ply) end
        return
    end

    -- The client can only legitimately report as many tracks as the motion has;
    -- bound the per-frame counts to the motion so a malicious client cannot
    -- inflate every frame to 4096 tracks and exhaust server memory/disk.
    local maxBoneCount = math.min(BUILD_PACKET_LIMIT, #(job.motion.boneTracks or {}))
    local maxFlexCount = math.min(BUILD_PACKET_LIMIT, #(job.motion.flexTracks or {}))

    local expectedFrame = job.currentFrame
    for _ = 1, resultCount do
        local frame = net.ReadUInt(32)
        local boneCount = math.Clamp(net.ReadUInt(16), 0, maxBoneCount)
        if frame ~= expectedFrame then
            local abortedID = job.id
            clear_build_job(ply)
            send_build_done(ply, false, "", "build frame order mismatch", abortedID)
            if start_next_queued_build then start_next_queued_build(ply) end
            return
        end

        local frameData = {
            frame = frame,
            bones = {},
            flexes = {},
        }
        for _ = 1, boneCount do
            local bone = net.ReadUInt(16)
            local ang = net.ReadAngle()
            local pos = Vector(finite_number(net.ReadFloat()), finite_number(net.ReadFloat()), finite_number(net.ReadFloat()))
            frameData.bones[#frameData.bones + 1] = { bone, finite_number(ang.p), finite_number(ang.y), finite_number(ang.r), pos.x, pos.y, pos.z }
            if not job.bones[bone] then
                job.bones[bone] = job.ent.GetBoneName and (job.ent:GetBoneName(bone) or "") or ""
            end
        end

        local flexCount = math.Clamp(net.ReadUInt(16), 0, maxFlexCount)
        for _ = 1, flexCount do
            local flexID = net.ReadInt(16)
            local weight = math.Clamp(finite_number(net.ReadFloat()), 0, 1)
            frameData.flexes[#frameData.flexes + 1] = { flexID, weight }
            if flexID >= 0 and not job.flexes[flexID] then
                job.flexes[flexID] = job.ent.GetFlexName and (job.ent:GetFlexName(flexID) or "") or ""
            end
        end

        job.frames[#job.frames + 1] = frameData
        expectedFrame = expectedFrame + 1
    end

    job.currentFrame = expectedFrame
    job.buildRetries = 0
    if job.currentFrame > job.endFrame then
        finalize_build(ply, job)
    else
        send_build_progress(ply, "building", job, string.format("built through frame %d / %d", expectedFrame - 1, job.endFrame))
        send_build_frame_request(ply, job)
    end
end)

net.Receive("mmdvmd_play_request", function(_, ply)
    local motionID = net.ReadString()
    local options = normalize_options(net.ReadBool(), net.ReadBool(), net.ReadBool(), net.ReadBool())
    local settings = playback_settings_with_eye_track(net.ReadFloat(), net.ReadFloat(), net.ReadString(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat(), net.ReadBool(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat(), net.ReadBool())
    local ok, err = MMDVMDNPC.StartPlaybackForPlayer(ply, motionID, options, settings)
    if not ok and err then MMDVMDNPC.Chat(ply, err) end
end)

net.Receive("mmdvmd_play_self_auto", function(_, ply)
    local motionID = net.ReadString()
    local options = normalize_options(net.ReadBool(), net.ReadBool(), net.ReadBool(), net.ReadBool())
    local settings = playback_settings_with_eye_track(net.ReadFloat(), net.ReadFloat(), net.ReadString(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat(), net.ReadBool(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat(), net.ReadBool())
    local ok, err = MMDVMDNPC.PlayOrBuildSelfForPlayer(ply, motionID, options, settings)
    if not ok and err then MMDVMDNPC.Chat(ply, err) end
end)

net.Receive("mmdvmd_assignment_play_request", function(_, ply)
    local settings = playback_settings_with_eye_track(net.ReadFloat(), net.ReadFloat(), net.ReadString(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat(), net.ReadBool(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat(), net.ReadBool())
    local ok, err = MMDVMDNPC.StartAssignedGroupPlaybackForPlayer(ply, settings)
    if not ok and err then MMDVMDNPC.Chat(ply, err) end
end)

net.Receive("mmdvmd_assignment_clear_request", function(_, ply)
    local mode = net.ReadString()
    MMDVMDNPC.ClearAssignedActorsForPlayer(ply, mode == "missing" and "missing" or "all")
end)

-- Debug/preview camera track fetch: streams the camera keys for a motion with
-- no playback attached (debug flag set, anchored to the player's debug target
-- when one is selected). Rate limited; a camera-less motion answers with an
-- empty begin so the client can report "no camera animation".
MMDVMDNPC.CameraDebugCooldown = MMDVMDNPC.CameraDebugCooldown or {}

net.Receive("mmdvmd_camera_debug_request", function(_, ply)
    if not IsValid(ply) then return end
    local now = CurTime()
    if (MMDVMDNPC.CameraDebugCooldown[ply] or 0) > now then return end
    MMDVMDNPC.CameraDebugCooldown[ply] = now + 0.5

    local motionID = MMDVMDNPC.NormalizeMotionID(net.ReadString())
    if not motionID then return end
    local motion = MMDVMDNPC.LoadMotion(motionID)
    if not motion then return end

    local anchor = MMDVMDNPC.DebugTargets[ply]
    send_camera_track(ply, is_usable_npc(anchor) and anchor or nil, motion, {
        debug = true,
        motionID = motionID,
        startAt = 0,
    })
end)

net.Receive("mmdvmd_eye_track_camera", function(_, ply)
    local active = net.ReadBool()
    if not active then
        MMDVMDNPC.EyeTrackCameraTargets[ply] = nil
        return
    end

    local pos = net.ReadVector()
    if not isvector(pos) then return end
    MMDVMDNPC.EyeTrackCameraTargets[ply] = {
        active = true,
        pos = pos,
        smooth = math.Clamp(tonumber(net.ReadFloat()) or MMDVMDNPC.DefaultEyeTrackSmooth or EYE_TRACK_SMOOTH, 0.1, 120),
        moveback = math.Clamp(tonumber(net.ReadFloat()) or MMDVMDNPC.DefaultEyeTrackBoneMoveBack or EYE_TRACK_BONE_MOVE_BACK, -0.25, 1),
        posUD = math.Clamp(tonumber(net.ReadFloat()) or MMDVMDNPC.DefaultEyeTrackBonePosUD or EYE_TRACK_BONE_POS_UD, 0, 2),
        posLR = math.Clamp(tonumber(net.ReadFloat()) or MMDVMDNPC.DefaultEyeTrackBonePosLR or EYE_TRACK_BONE_POS_LR, 0, 2),
        expires = CurTime() + 0.35,
    }
end)

net.Receive("mmdvmd_stop_request", function(_, ply)
    if MMDVMDNPC.StopSelfPlaybackForPlayer(ply, true) then return end

    local ent = MMDVMDNPC.DebugTargets[ply]
    if is_usable_npc(ent) then
        MMDVMDNPC.StopPlayback(ent, true)
    else
        send_play_status(ply, "error", actor_select_prompt())
    end
end)

net.Receive("mmdvmd_stop_npc_playbacks_request", function(_, ply)
    if not IsValid(ply) then return end
    if MMDVMDNPC.StopAllPlaybacksForPlayer then
        MMDVMDNPC.StopAllPlaybacksForPlayer(ply)
    end
end)

net.Receive("mmdvmd_assignment_align_request", function(_, ply)
    if not IsValid(ply) then return end
    if MMDVMDNPC.AlignAssignedActorsToFirstForPlayer then
        MMDVMDNPC.AlignAssignedActorsToFirstForPlayer(ply)
    end
end)

-- The Force Reset button is the addon's panic button: beyond restoring the
-- self view it cancels the player's build tasks, stops every dance they
-- started (self and NPCs), clears the group assignments AND the selection.
net.Receive("mmdvmd_force_self_reset_request", function(_, ply)
    if not IsValid(ply) then return end
    if MMDVMDNPC.CancelBuildTasksForPlayer then
        MMDVMDNPC.CancelBuildTasksForPlayer(ply)
    end
    -- Stop every dance THIS player started (the self playback is handled by
    -- the force reset below). Scoped by playback owner — unlike the global
    -- StopAllPlaybacksForPlayer — so one player's panic button can never end
    -- another player's dances on a shared server.
    local owned = {}
    for ent, state in pairs(MMDVMDNPC.Playbacks or {}) do
        if state and state.ply == ply and not state.selfProxy then
            owned[#owned + 1] = ent
        end
    end
    for _, ent in ipairs(owned) do
        MMDVMDNPC.StopPlayback(ent, true)
    end
    if MMDVMDNPC.ClearAssignedActorsForPlayer then
        MMDVMDNPC.ClearAssignedActorsForPlayer(ply, "all")
    end
    if MMDVMDNPC.ForceResetSelfPlaybackForPlayer then
        MMDVMDNPC.ForceResetSelfPlaybackForPlayer(ply)
    end
    -- ForceReset re-picks a target from the assignments; those are gone, so
    -- drop the selection outright (and any held debug face) and tell the client.
    local debugTarget = MMDVMDNPC.DebugTargets[ply]
    if IsValid(debugTarget) and MMDVMDNPC.DebugFlexHolds then
        MMDVMDNPC.DebugFlexHolds[debugTarget] = nil
    end
    if MMDVMDNPC.LastDebugFrame then MMDVMDNPC.LastDebugFrame[ply] = nil end
    MMDVMDNPC.DebugTargets[ply] = nil
    send_target_status(ply, L("mmd_vmd_npc.status.selection_cleared", "selection cleared"))
    send_assignment_status(ply)
end)

net.Receive("mmdvmd_clear_built_request", function(_, ply)
    local motionID = net.ReadString()
    local scope = net.ReadString()
    if not player_can_edit_content(ply) then return deny_edit_permission(ply) end
    MMDVMDNPC.ClearBuiltForPlayer(ply, motionID, scope)
end)

net.Receive("mmdvmd_delete_motion_request", function(_, ply)
    local motionID = net.ReadString()
    if not player_can_edit_content(ply) then return deny_edit_permission(ply) end
    MMDVMDNPC.DeleteMotionForPlayer(ply, motionID)
end)

concommand.Add("mmdvmd_list", function(ply)
    if IsValid(ply) then
        send_motion_list(ply)
        return
    end

    print("[MMD VMD] Motion JSON files:")
    for _, id in ipairs(MMDVMDNPC.ListMotions()) do
        print("  " .. id)
    end
end)

concommand.Add("mmdvmd_debug", function(ply, _, args)
    local motionID = args and args[1] or ""
    local frame = args and args[2] or DEBUG_REFERENCE_FRAME
    if motionID == "" then
        MMDVMDNPC.Chat(ply, "Usage: mmdvmd_debug <motion_id> [frame]")
        return
    end

    if IsValid(ply) then
        local tr = ply:GetEyeTrace()
        local ent = tr and is_usable_npc(tr.Entity) and tr.Entity or nil
        MMDVMDNPC.OpenDebugForPlayer(ply, ent, motionID, frame)
    else
        print("[MMD VMD] mmdvmd_debug opens a client menu and must be run by a player.")
    end
end)

concommand.Add("mmdvmd_play", function(ply, _, args)
    local motionID = args and args[1] or ""
    if motionID == "" then
        MMDVMDNPC.Chat(ply, "Usage: mmdvmd_play <motion_id>")
        return
    end

    if IsValid(ply) then
        MMDVMDNPC.StartPlaybackForPlayer(ply, motionID, normalize_options(false, false, false, false))
    else
        print("[MMD VMD] mmdvmd_play must be run by a player with a selected actor.")
    end
end)

concommand.Add("mmdvmd_stop", function(ply)
    if not IsValid(ply) then return end
    if MMDVMDNPC.StopSelfPlaybackForPlayer(ply, true) then return end

    local ent = MMDVMDNPC.DebugTargets[ply]
    if is_usable_npc(ent) then
        MMDVMDNPC.StopPlayback(ent, true)
    end
end)
