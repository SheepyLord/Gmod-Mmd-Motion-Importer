include("mmd_vmd_npc/cl_radial.lua")
MMDVMDNPC = MMDVMDNPC or {}
MMDVMDNPC.ClientMotions = MMDVMDNPC.ClientMotions or {}
MMDVMDNPC.TargetStatus = MMDVMDNPC.TargetStatus or {}
MMDVMDNPC.BuildStatus = MMDVMDNPC.BuildStatus or {}
MMDVMDNPC.PlayStatus = MMDVMDNPC.PlayStatus or {}
MMDVMDNPC.ClientBuildJobs = MMDVMDNPC.ClientBuildJobs or {}
MMDVMDNPC.ClientBuiltCache = MMDVMDNPC.ClientBuiltCache or {}
MMDVMDNPC.MotionDetails = MMDVMDNPC.MotionDetails or {}
MMDVMDNPC.AssignedActors = MMDVMDNPC.AssignedActors or { order = {}, byEnt = {} }
MMDVMDNPC.PauseStatus = MMDVMDNPC.PauseStatus or { svPause = 0, svPauseSP = 0 }
MMDVMDNPC.AudioOffsets = MMDVMDNPC.AudioOffsets or {}
MMDVMDNPC.AudioChannels = MMDVMDNPC.AudioChannels or {}
MMDVMDNPC.LocalPlaybacks = MMDVMDNPC.LocalPlaybacks or {}
MMDVMDNPC.ActivePlaybackEnts = MMDVMDNPC.ActivePlaybackEnts or {}
MMDVMDNPC.ClientCVarSuppressions = MMDVMDNPC.ClientCVarSuppressions or {}
MMDVMDNPC.SelfPlaybackCameraEnt = MMDVMDNPC.SelfPlaybackCameraEnt or nil
MMDVMDNPC.SelfCameraDistance = MMDVMDNPC.SelfCameraDistance or nil
MMDVMDNPC.SelfCameraYaw = MMDVMDNPC.SelfCameraYaw or nil
MMDVMDNPC.SelfCameraPitch = MMDVMDNPC.SelfCameraPitch or nil
MMDVMDNPC.SelfCameraBaseCenter = MMDVMDNPC.SelfCameraBaseCenter or nil
MMDVMDNPC.SelfCameraCenterOffset = MMDVMDNPC.SelfCameraCenterOffset or Vector(0, 0, 0)



local DEBUG_REFERENCE_FRAME = -1
local DEBUG_PREVIEW_TIMER = "MMDVMDNPCDebugPreviewPlay"
local BUILD_DUMMY_SUPPRESSED_CVARS = { "skirt_vrd_auto_apply_all" }

local function L(key, fallback)
    return MMDVMDNPC.L and MMDVMDNPC.L(key, fallback) or (fallback or key)
end

local function LF(key, ...)
    return MMDVMDNPC.LFormat and MMDVMDNPC.LFormat(key, ...) or string.format(L(key, key), ...)
end

-- User-adjustable size for the Motion Manager and Raw Animation Debug windows.
CreateClientConVar("mmd_vmd_npc_menu_scale", "1", true, false, "Size multiplier for the Motion Manager and debug windows")

function MMDVMDNPC.MenuScale()
    local cv = GetConVar("mmd_vmd_npc_menu_scale")
    return math.Clamp(cv and cv:GetFloat() or 1, 0.6, 2.0)
end

-- Named fonts, recreated at (base size * menu scale). Recreating a font under the
-- same name updates every widget that references it by name on the next paint, so
-- changing the scale live-resizes the manager/debug text without rebuilding panels.
local MENU_FONT_BASE = {
    MMDVMDNPCManagerText = { size = 18, weight = 500 },
    MMDVMDNPCManagerTextBold = { size = 18, weight = 700 },
    MMDVMDNPCManagerDetails = { size = 17, weight = 500 },
    MMDVMDNPCDebugText = { size = 15, weight = 500 },
    MMDVMDNPCDebugBold = { size = 15, weight = 700 },
}

local function rebuild_menu_fonts()
    local scale = MMDVMDNPC.MenuScale()
    for name, def in pairs(MENU_FONT_BASE) do
        surface.CreateFont(name, {
            font = "Tahoma",
            size = math.max(8, math.floor(def.size * scale + 0.5)),
            weight = def.weight,
            extended = true,
        })
    end
end
rebuild_menu_fonts()
if cvars and cvars.AddChangeCallback then
    cvars.AddChangeCallback("mmd_vmd_npc_menu_scale", function()
        rebuild_menu_fonts()
    end, "MMDVMDNPCMenuScaleFonts")
end

local function set_manager_font(panel, fontName)
    if IsValid(panel) and panel.SetFont then
        panel:SetFont(fontName or "MMDVMDNPCManagerText")
    end
end

local function style_manager_button(button, width)
    if not IsValid(button) then return end
    set_manager_font(button, "MMDVMDNPCManagerText")
    if width then button:SetWide(width) end
end

local function style_manager_list_line(line)
    if not IsValid(line) then return end
    if line.SetTall then line:SetTall(math.floor(30 * MMDVMDNPC.MenuScale())) end
    if line.Columns then
        for _, label in ipairs(line.Columns) do
            set_manager_font(label, "MMDVMDNPCManagerText")
        end
    end
end

CreateClientConVar("mmd_vmd_npc_show_halos", "1", true, false, "ON/OFF NPC's halos") -- ADDED


CreateClientConVar("mmd_vmd_npc_disable_armtwist", "0", true, false, L("mmd_vmd_npc.ui.disable_armtwist"))
CreateClientConVar("mmd_vmd_npc_disable_handtwist", "0", true, false, L("mmd_vmd_npc.ui.disable_handtwist"))
CreateClientConVar("mmd_vmd_npc_disable_eyes", "0", true, false, L("mmd_vmd_npc.ui.disable_eyes"))
CreateClientConVar("mmd_vmd_npc_disable_spine_pelvis_correction", "0", true, false, L("mmd_vmd_npc.ui.disable_spine_pelvis"))
CreateClientConVar("mmd_vmd_npc_start_delay", tostring(MMDVMDNPC.DefaultStartDelay or 2), true, false, L("mmd_vmd_npc.ui.start_delay"))
CreateClientConVar("mmd_vmd_npc_pelvis_z_offset", tostring(MMDVMDNPC.DefaultPelvisZOffset or -2.5), true, false, L("mmd_vmd_npc.ui.pelvis_z_offset"))
CreateClientConVar("mmd_vmd_npc_thirdperson_distance", tostring(MMDVMDNPC.DefaultThirdPersonDistance or 120), true, false, L("mmd_vmd_npc.ui.thirdperson_distance"))
CreateClientConVar("mmd_vmd_npc_thirdperson_height", tostring(MMDVMDNPC.DefaultThirdPersonHeight or 24), true, false, L("mmd_vmd_npc.ui.thirdperson_height"))
CreateClientConVar("mmd_vmd_npc_eye_track", "1", true, false, L("mmd_vmd_npc.ui.enable_eye_tracking"))
CreateClientConVar("mmd_vmd_npc_eye_track_smooth", tostring(MMDVMDNPC.DefaultEyeTrackSmooth or 20), true, false, L("mmd_vmd_npc.ui.eye_smoothing"))
CreateClientConVar("mmd_vmd_npc_eye_track_moveback", tostring(MMDVMDNPC.DefaultEyeTrackBoneMoveBack or 0.10), true, false, L("mmd_vmd_npc.ui.eye_moveback"))
CreateClientConVar("mmd_vmd_npc_eye_track_pos_ud", tostring(MMDVMDNPC.DefaultEyeTrackBonePosUD or 0.5), true, false, L("mmd_vmd_npc.ui.eye_pos_ud"))
CreateClientConVar("mmd_vmd_npc_eye_track_pos_lr", tostring(MMDVMDNPC.DefaultEyeTrackBonePosLR or 0.5), true, false, L("mmd_vmd_npc.ui.eye_pos_lr"))
CreateClientConVar("mmd_vmd_npc_music_enabled", "1", true, false, L("mmd_vmd_npc.ui.play_imported_music"))
CreateClientConVar("mmd_vmd_npc_music_volume", tostring(MMDVMDNPC.DefaultMusicVolume or 1), true, false, L("mmd_vmd_npc.ui.music_volume"))
CreateClientConVar("mmd_vmd_npc_music_omni", "1", true, false, L("mmd_vmd_npc.ui.music_omni"))
CreateClientConVar("mmd_vmd_npc_music_range", "1500", true, false, L("mmd_vmd_npc.ui.music_range"))
CreateClientConVar("mmd_vmd_npc_music_fade", "300", true, false, L("mmd_vmd_npc.ui.music_fade"))
CreateClientConVar("mmd_vmd_npc_loop_playback", "0", true, false, L("mmd_vmd_npc.ui.loop_playback"))
CreateClientConVar("mmd_vmd_npc_build_frames_per_batch", tostring(MMDVMDNPC.DefaultBuildFramesPerBatch or 16), true, false, L("mmd_vmd_npc.ui.build_frames_per_batch"))
CreateClientConVar("mmd_vmd_npc_playback_hz", tostring(MMDVMDNPC.DefaultPlaybackHz or 120), true, false, L("mmd_vmd_npc.ui.playback_updates_per_second"))
CreateClientConVar("mmd_vmd_npc_hide_hud", "1", true, false, L("mmd_vmd_npc.ui.hide_hud"))
CreateClientConVar("mmd_vmd_npc_hide_hud_key", "0", true, false, "Key code that toggles hiding the HUD during camera motion")
CreateClientConVar("mmd_vmd_npc_flex_scale_all", "1", true, false, L("mmd_vmd_npc.debug.flex_scale_all"))
CreateClientConVar("mmd_vmd_npc_flex_scale_eye", "1", true, false, L("mmd_vmd_npc.debug.flex_scale_eye"))
CreateClientConVar("mmd_vmd_npc_flex_scale_brow", "1", true, false, L("mmd_vmd_npc.debug.flex_scale_brow"))
CreateClientConVar("mmd_vmd_npc_flex_scale_mouth", "1", true, false, L("mmd_vmd_npc.debug.flex_scale_mouth"))

-- Server-driven chat notices. Warnings print in red and play an alert sound so a
-- glanced-away user still notices (e.g. the AI-not-disabled reminder).
net.Receive("mmdvmd_chat_notice", function()
    local message = net.ReadString()
    local isWarning = net.ReadBool()
    if isWarning then
        chat.AddText(Color(255, 70, 70), "[MMD VMD] ", Color(255, 150, 150), message)
        surface.PlaySound("buttons/button10.wav")
    else
        chat.AddText(Color(120, 200, 255), "[MMD VMD] ", color_white, message)
    end
end)

local selected_options
local play_ui_cue
local force_self_view_cleanup

local function request_list()
    net.Start("mmdvmd_list_request")
    net.SendToServer()
end

function MMDVMDNPC.RequestMotionList()
    request_list()
end

local function request_motion_details()
    net.Start("mmdvmd_motion_details_request")
        local options = selected_options and selected_options() or {}
        net.WriteBool(options.disableArmTwist == true)
        net.WriteBool(options.disableHandTwist == true)
        net.WriteBool(options.disableEyes == true)
        net.WriteBool(options.disableSpinePelvisCorrection == true)
    net.SendToServer()
end

function MMDVMDNPC.RequestMotionDetails()
    request_motion_details()
end

function MMDVMDNPC.RequestPauseStatus()
    net.Start("mmdvmd_pause_status_request")
    net.SendToServer()
end

function MMDVMDNPC.RequestSelectSelf()
    net.Start("mmdvmd_select_target")
        net.WriteEntity(LocalPlayer())
    net.SendToServer()
end

selected_options = function()
    local armTwist = GetConVar("mmd_vmd_npc_disable_armtwist")
    local handTwist = GetConVar("mmd_vmd_npc_disable_handtwist")
    local eyes = GetConVar("mmd_vmd_npc_disable_eyes")
    local spinePelvis = GetConVar("mmd_vmd_npc_disable_spine_pelvis_correction")
    return {
        disableArmTwist = armTwist and armTwist:GetBool() or false,
        disableHandTwist = handTwist and handTwist:GetBool() or false,
        disableEyes = eyes and eyes:GetBool() or false,
        disableSpinePelvisCorrection = spinePelvis and spinePelvis:GetBool() or false,
    }
end

local function write_selected_options()
    local options = selected_options()
    net.WriteBool(options.disableArmTwist)
    net.WriteBool(options.disableHandTwist)
    net.WriteBool(options.disableEyes)
    net.WriteBool(options.disableSpinePelvisCorrection)
end

local function eye_tracking_enabled()
    local eyeTrack = GetConVar("mmd_vmd_npc_eye_track")
    local raw = string.lower(tostring(eyeTrack and eyeTrack:GetString() or "1"))
    return raw == "1" or raw == "true" or raw == "on" or raw == "yes" or raw == "camera" or raw == "player"
end

local function selected_playback_settings()
    local delay = GetConVar("mmd_vmd_npc_start_delay")
    local pelvis = GetConVar("mmd_vmd_npc_pelvis_z_offset")
    local smooth = GetConVar("mmd_vmd_npc_eye_track_smooth")
    local moveback = GetConVar("mmd_vmd_npc_eye_track_moveback")
    local posUD = GetConVar("mmd_vmd_npc_eye_track_pos_ud")
    local posLR = GetConVar("mmd_vmd_npc_eye_track_pos_lr")
    local musicEnabled = GetConVar("mmd_vmd_npc_music_enabled")
    local musicVolume = GetConVar("mmd_vmd_npc_music_volume")
    local loopPlayback = GetConVar("mmd_vmd_npc_loop_playback")
    local buildFrames = GetConVar("mmd_vmd_npc_build_frames_per_batch")
    local playbackHz = GetConVar("mmd_vmd_npc_playback_hz")
    local loopPlaybackEnabled = MMDVMDNPC.DefaultLoopPlayback == true
    if loopPlayback then
        loopPlaybackEnabled = loopPlayback:GetBool()
    end
    return {
        startDelay = math.max(MMDVMDNPC.MinStartDelay or 2, delay and delay:GetFloat() or MMDVMDNPC.DefaultStartDelay or 2),
        -- pelvisZOffset = pelvis and pelvis:GetFloat() or MMDVMDNPC.DefaultPelvisZOffset or -2.5,
        pelvisZOffset = -2.5, -- bugged
        eyeTrackMode = eye_tracking_enabled() and "camera" or "off",
        eyeTrackSmooth = smooth and smooth:GetFloat() or MMDVMDNPC.DefaultEyeTrackSmooth or 20,
        eyeTrackMoveBack = moveback and moveback:GetFloat() or MMDVMDNPC.DefaultEyeTrackBoneMoveBack or 0.10,
        eyeTrackPosUD = posUD and posUD:GetFloat() or MMDVMDNPC.DefaultEyeTrackBonePosUD or 0.5,
        eyeTrackPosLR = posLR and posLR:GetFloat() or MMDVMDNPC.DefaultEyeTrackBonePosLR or 0.5,
        musicEnabled = not musicEnabled or musicEnabled:GetBool(),
        musicVolume = math.Clamp(musicVolume and musicVolume:GetFloat() or MMDVMDNPC.DefaultMusicVolume or 1, 0, 2),
        loopPlayback = loopPlaybackEnabled,
        buildFramesPerBatch = math.Clamp(math.floor(buildFrames and buildFrames:GetFloat() or MMDVMDNPC.DefaultBuildFramesPerBatch or 16), MMDVMDNPC.MinBuildFramesPerBatch or 1, 1024),
        playbackHz = math.Clamp(playbackHz and playbackHz:GetFloat() or MMDVMDNPC.DefaultPlaybackHz or 120, MMDVMDNPC.MinPlaybackHz or 10, MMDVMDNPC.MaxPlaybackHz or 240),
    }
end

local function write_selected_playback_settings()
    local settings = selected_playback_settings()
    net.WriteFloat(settings.startDelay)
    net.WriteFloat(settings.pelvisZOffset)
    net.WriteString(settings.eyeTrackMode or "off")
    net.WriteFloat(settings.eyeTrackSmooth or MMDVMDNPC.DefaultEyeTrackSmooth or 20)
    net.WriteFloat(settings.eyeTrackMoveBack or MMDVMDNPC.DefaultEyeTrackBoneMoveBack or 0.10)
    net.WriteFloat(settings.eyeTrackPosUD or MMDVMDNPC.DefaultEyeTrackBonePosUD or 0.5)
    net.WriteFloat(settings.eyeTrackPosLR or MMDVMDNPC.DefaultEyeTrackBonePosLR or 0.5)
    net.WriteBool(settings.musicEnabled ~= false)
    net.WriteFloat(settings.musicVolume or MMDVMDNPC.DefaultMusicVolume or 1)
    net.WriteFloat(settings.buildFramesPerBatch or MMDVMDNPC.DefaultBuildFramesPerBatch or 16)
    net.WriteFloat(settings.playbackHz or MMDVMDNPC.DefaultPlaybackHz or 120)
    net.WriteBool(settings.loopPlayback == true)
end

function MMDVMDNPC.RequestBuildSelectedMotion()
    local current = GetConVar("mmd_vmd_npc_motion")
    local motionID = current and current:GetString() or ""
    if motionID == "" then
        play_ui_cue("blocked")
        print("[MMD VMD] " .. L("mmd_vmd_npc.error.select_motion"))
        return
    end

    net.Start("mmdvmd_build_begin")
        net.WriteString(motionID)
        write_selected_options()
        write_selected_playback_settings()
    net.SendToServer()
end

function MMDVMDNPC.RequestCancelBuildTasks()
    net.Start("mmdvmd_build_cancel_request")
    net.SendToServer()
end

function MMDVMDNPC.RequestPlaySelectedMotion()
    local current = GetConVar("mmd_vmd_npc_motion")
    local motionID = current and current:GetString() or ""
    if motionID == "" then
        play_ui_cue("blocked")
        print("[MMD VMD] " .. L("mmd_vmd_npc.error.select_motion"))
        return
    end

    net.Start("mmdvmd_play_request")
        net.WriteString(motionID)
        write_selected_options()
        write_selected_playback_settings()
    net.SendToServer()
end

function MMDVMDNPC.RequestPlayAssignedGroup()
    net.Start("mmdvmd_assignment_play_request")
        write_selected_playback_settings()
    net.SendToServer()
end

-- Play a motion on the local player, building it first if the playermodel has no
-- cache yet. Used by the radial wheel so a single selection always results in
-- playback without a manual build step.
function MMDVMDNPC.RequestPlaySelfAuto(motionID)
    motionID = tostring(motionID or "")
    if motionID == "" then
        local current = GetConVar("mmd_vmd_npc_motion")
        motionID = current and current:GetString() or ""
    end
    if motionID == "" then
        play_ui_cue("blocked")
        print("[MMD VMD] " .. L("mmd_vmd_npc.error.select_motion"))
        return
    end

    RunConsoleCommand("mmd_vmd_npc_motion", motionID)
    net.Start("mmdvmd_play_self_auto")
        net.WriteString(motionID)
        write_selected_options()
        write_selected_playback_settings()
    net.SendToServer()
end

function MMDVMDNPC.RequestStopSelectedMotion()
    net.Start("mmdvmd_stop_request")
    net.SendToServer()
end

function MMDVMDNPC.RequestForceSelfPlaybackReset()
    if force_self_view_cleanup then
        force_self_view_cleanup()
    end

    net.Start("mmdvmd_force_self_reset_request")
    net.SendToServer()
end

function MMDVMDNPC.RequestClearAssignedActors(mode)
    net.Start("mmdvmd_assignment_clear_request")
        net.WriteString(mode == "missing" and "missing" or "all")
    net.SendToServer()
end

function MMDVMDNPC.RequestClearBuiltSelectedMotion(scope)
    local current = GetConVar("mmd_vmd_npc_motion")
    local motionID = current and current:GetString() or ""
    if motionID == "" then
        play_ui_cue("blocked")
        print("[MMD VMD] " .. L("mmd_vmd_npc.error.select_motion"))
        return
    end

    scope = scope == "all" and "all" or "model"
    MMDVMDNPC.PendingClearBuilt = {
        motionID = motionID,
        scope = scope,
        model = MMDVMDNPC.TargetStatus and MMDVMDNPC.TargetStatus.model or "",
    }

    net.Start("mmdvmd_clear_built_request")
        net.WriteString(motionID)
        net.WriteString(scope)
    net.SendToServer()
end

function MMDVMDNPC.RequestDeleteSelectedMotion(motionID)
    motionID = tostring(motionID or "")
    if motionID == "" then
        local current = GetConVar("mmd_vmd_npc_motion")
        motionID = current and current:GetString() or ""
    end
    if motionID == "" then
        play_ui_cue("blocked")
        print("[MMD VMD] " .. L("mmd_vmd_npc.error.select_motion"))
        return
    end

    net.Start("mmdvmd_delete_motion_request")
        net.WriteString(motionID)
    net.SendToServer()
end

net.Receive("mmdvmd_list_response", function()
    local count = net.ReadUInt(16)
    local list = {}
    for i = 1, count do
        list[#list + 1] = net.ReadString()
    end

    MMDVMDNPC.ClientMotions = list
    hook.Run("MMDVMDNPCMotionListUpdated", list)
    request_motion_details()

    if count == 0 then
        print("[MMD VMD] " .. L("mmd_vmd_npc.console.no_motions"))
    else
        print("[MMD VMD] " .. L("mmd_vmd_npc.console.motion_files"))
        for _, id in ipairs(list) do
            print("  " .. id)
        end
    end
end)

-- Details arrive in chunks (64KB net cap; see sv_commands send_motion_details).
-- Accumulate into a pending buffer and only swap the live tables + fire the
-- update hook on the final chunk, so the UI never renders a half list.
local pendingMotionDetails = nil

net.Receive("mmdvmd_motion_details_response", function()
    local reset = net.ReadBool()
    local done = net.ReadBool()
    local count = net.ReadUInt(16)

    if reset or not pendingMotionDetails then
        pendingMotionDetails = { details = {}, ordered = {} }
    end
    local details = pendingMotionDetails.details
    local ordered = pendingMotionDetails.ordered

    for _ = 1, count do
        local id = net.ReadString()
        local meta = {
            id = id,
            displayName = net.ReadString(),
            fps = net.ReadUInt(16),
            frameStart = net.ReadUInt(32),
            frameEnd = net.ReadUInt(32),
            frameCount = net.ReadUInt(32),
            duration = net.ReadFloat(),
            boneCount = net.ReadUInt(16),
            flexCount = net.ReadUInt(16),
            modified = net.ReadUInt(32),
            sourceName = net.ReadString(),
            musicSound = net.ReadString(),
            musicSource = net.ReadString(),
            isAddon = net.ReadBool(),
            built = net.ReadBool(),
            hasCamera = net.ReadBool(),
            fromAddon = net.ReadBool(),
            category = net.ReadString(),
            englishName = net.ReadString(),
            artist = net.ReadString(),
            language = net.ReadString(),
            link = net.ReadString(),
            motionArtist = net.ReadString(),
        }
        details[id] = meta
        ordered[#ordered + 1] = meta
    end

    if not done then return end
    pendingMotionDetails = nil
    MMDVMDNPC.MotionDetails = details
    MMDVMDNPC.MotionDetailsOrdered = ordered
    hook.Run("MMDVMDNPCMotionDetailsUpdated", ordered, details)
end)

-- The distinct categories present in the current details, for filter dropdowns:
-- User Import first, authored addon categories alphabetical, addon-other last.
function MMDVMDNPC.MotionCategories()
    local seen, authored = {}, {}
    local hasUser, hasOther = false, false
    for _, meta in ipairs(MMDVMDNPC.MotionDetailsOrdered or {}) do
        local category = tostring(meta.category or "")
        if category == "" or category == MMDVMDNPC.CategoryUserImport then
            hasUser = true
        elseif category == MMDVMDNPC.CategoryAddonOther then
            hasOther = true
        elseif not seen[category] then
            seen[category] = true
            authored[#authored + 1] = category
        end
    end
    table.sort(authored, function(a, b) return string.lower(a) < string.lower(b) end)
    local out = {}
    if hasUser then out[#out + 1] = MMDVMDNPC.CategoryUserImport end
    for _, category in ipairs(authored) do out[#out + 1] = category end
    if hasOther then out[#out + 1] = MMDVMDNPC.CategoryAddonOther end
    return out
end

-- Shared filter predicate: does this motion belong to the selected category?
-- "" or "*" means All.
function MMDVMDNPC.MotionMatchesCategory(meta, category)
    category = tostring(category or "")
    if category == "" or category == "*" then return true end
    local own = tostring(istable(meta) and meta.category or "")
    if own == "" then own = MMDVMDNPC.CategoryUserImport end
    return own == category
end

-- The server invalidated every built cache for a model (flex-mapping edit):
-- drop our client-side replicas too, or the local interpolated poser would
-- keep replaying the pre-edit build under the same path key while the server
-- plays the rebuilt one — the two would visibly disagree. Running local
-- playbacks captured a `built` reference at start, so they must stop too
-- (the server's networked pose takes over alone until the next dance).
net.Receive("mmdvmd_client_built_invalidate", function()
    local model = net.ReadString()
    if model == "" then return end
    for ent, state in pairs(MMDVMDNPC.LocalPlaybacks or {}) do
        local built = state and state.built or nil
        if built and tostring(built.model or "") == model and MMDVMDNPC.StopLocalPlaybackFor then
            MMDVMDNPC.StopLocalPlaybackFor(ent, false)
        end
    end
    for path, built in pairs(MMDVMDNPC.ClientBuiltCache or {}) do
        if built and tostring(built.model or "") == model then
            MMDVMDNPC.ClientBuiltCache[path] = nil
        end
    end
end)

net.Receive("mmdvmd_pause_status_response", function()
    MMDVMDNPC.PauseStatus = {
        svPause = net.ReadFloat(),
        svPauseSP = net.ReadFloat(),
    }
    hook.Run("MMDVMDNPCPauseStatusUpdated", MMDVMDNPC.PauseStatus)
end)

local function request_audio_settings(motionID)
    net.Start("mmdvmd_audio_settings_request")
        net.WriteString(tostring(motionID or ""))
    net.SendToServer()
end

function MMDVMDNPC.RequestAudioSettings(motionID)
    request_audio_settings(motionID)
end

function MMDVMDNPC.SaveAudioOffset(motionID, offset)
    net.Start("mmdvmd_audio_settings_save")
        net.WriteString(tostring(motionID or ""))
        net.WriteFloat(tonumber(offset) or 0)
    net.SendToServer()
end

net.Receive("mmdvmd_audio_settings_response", function()
    local motionID = net.ReadString()
    local offset = net.ReadFloat()
    local soundPath = net.ReadString()
    MMDVMDNPC.AudioOffsets[motionID] = offset
    local details = MMDVMDNPC.MotionDetails[motionID]
    if details then details.musicSound = soundPath ~= "" and soundPath or details.musicSound end
    hook.Run("MMDVMDNPCAudioSettingsUpdated", motionID, offset, soundPath)
end)

local function request_debug(motionID, vmdFrame)
    vmdFrame = math.max(DEBUG_REFERENCE_FRAME, math.floor(tonumber(vmdFrame) or DEBUG_REFERENCE_FRAME))
    net.Start("mmdvmd_debug_request")
        net.WriteString(tostring(motionID or ""))
        net.WriteInt(vmdFrame, 32)
    net.SendToServer()
end

local function fmt_num(value)
    return string.format("%.3f", tonumber(value) or 0)
end

local function fmt_angle(pitch, yaw, roll)
    return string.format("%.3f, %.3f, %.3f", tonumber(pitch) or 0, tonumber(yaw) or 0, tonumber(roll) or 0)
end

local function fmt_vec(x, y, z)
    return string.format("%.3f, %.3f, %.3f", tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
end

local function fmt_eta(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local minutes = math.floor(seconds / 60)
    seconds = seconds % 60
    return string.format("%02d:%02d", minutes, seconds)
end

local UI_CUE_SOUNDS = {
    blocked = "buttons/button10.wav",
    warning = "buttons/button14.wav",
    success = "buttons/button15.wav",
    pause = "buttons/button3.wav",
}

play_ui_cue = function(kind)
    kind = UI_CUE_SOUNDS[kind or ""] and kind or "blocked"
    local soundPath = UI_CUE_SOUNDS[kind]
    local now = CurTime()
    MMDVMDNPC.LastUICueTimes = MMDVMDNPC.LastUICueTimes or {}
    local nextAllowed = MMDVMDNPC.LastUICueTimes[kind] or 0
    if now < nextAllowed then return end

    MMDVMDNPC.LastUICueTimes[kind] = now + 0.25
    if surface and surface.PlaySound then
        surface.PlaySound(soundPath)
    end
end

function MMDVMDNPC.PlayUICue(kind)
    play_ui_cue(kind)
end

local function show_build_lag_warning(buildID, motionID, startFrame, endFrame)
    buildID = tonumber(buildID) or 0
    if buildID > 0 and MMDVMDNPC.LastBuildLagWarningID == buildID then return end
    MMDVMDNPC.LastBuildLagWarningID = buildID
    play_ui_cue("warning")

    local frameCount = math.max(0, (tonumber(endFrame) or 0) - (tonumber(startFrame) or 0) + 1)
    local message = LF(
        "mmd_vmd_npc.warning.build_lag_fmt",
        tostring(motionID or L("mmd_vmd_npc.ui.motion")),
        frameCount
    )

    if notification and notification.AddLegacy then
        notification.AddLegacy(message, NOTIFY_HINT or 3, 8)
    end
end

local function play_status_cue(status, message)
    status = tostring(status or "")
    message = tostring(message or "")
    local previousStatus = MMDVMDNPC.LastStatusCueStatus
    MMDVMDNPC.LastStatusCueStatus = status

    local cue
    if status == "error" or status == "blocked" or status == "missing_build" then
        cue = "blocked"
    elseif status == "paused" then
        if previousStatus == "paused" then return end
        cue = "pause"
    elseif status == "playing" and message == "playback resumed" then
        cue = "success"
    elseif status == "stopped" or status == "stopped_all" or status == "finished" or status == "built" or status == "aligned" then
        cue = "success"
    end
    if not cue then return end

    local key = cue .. "|" .. status .. "|" .. message
    local now = CurTime()
    if MMDVMDNPC.LastStatusCueKey == key and now < (MMDVMDNPC.LastStatusCueUntil or 0) then return end
    MMDVMDNPC.LastStatusCueKey = key
    MMDVMDNPC.LastStatusCueUntil = now + 3
    play_ui_cue(cue)
    if (status == "error" or status == "blocked") and string.find(string.lower(message), "ai_disabled", 1, true) then
        if notification and notification.AddLegacy then
            notification.AddLegacy(message, NOTIFY_ERROR or 1, 6)
        end
    end
end

local function update_build_status(status)
    status = status or {}
    local previous = MMDVMDNPC.BuildStatus or {}
    local now = CurTime()
    local startFrame = math.floor(tonumber(status.startFrame) or 0)
    local endFrame = math.floor(tonumber(status.endFrame) or startFrame)
    if endFrame < startFrame then endFrame = startFrame end

    local currentFrame = math.floor(tonumber(status.currentFrame) or startFrame)
    local total = math.max(1, endFrame - startFrame + 1)
    local completed = math.Clamp(currentFrame - startFrame, 0, total)
    if currentFrame > endFrame then completed = total end
    local progress = math.Clamp(completed / total, 0, 1)
    if status.progress ~= nil then
        progress = math.Clamp(tonumber(status.progress) or progress, 0, 1)
    end

    local buildID = tonumber(status.buildID) or 0
    local startedAt = previous.startedAt
    if previous.buildID ~= buildID or previous.status ~= "building" then
        startedAt = now
    end

    local eta = nil
    if status.status == "building" and progress > 0 and progress < 1 then
        eta = (now - startedAt) * (1 - progress) / progress
    end

    local message = tostring(status.message or status.status or "idle")
    if status.status == "building" then
        message = string.format(
            "%s | %.0f%% | ETA %s | queued %d",
            message,
            progress * 100,
            eta and fmt_eta(eta) or "--:--",
            tonumber(status.queued) or 0
        )
    elseif status.status == "queued" then
        message = string.format("%s | queued %d", message, tonumber(status.queued) or 0)
    end

    MMDVMDNPC.BuildStatus = {
        ok = status.ok,
        status = status.status,
        path = status.path,
        message = message,
        rawMessage = status.message,
        buildID = buildID,
        motionID = status.motionID,
        model = status.model,
        currentFrame = currentFrame,
        startFrame = startFrame,
        endFrame = endFrame,
        queued = tonumber(status.queued) or 0,
        progress = progress,
        eta = eta,
        startedAt = startedAt,
        updatedAt = now,
    }
    hook.Run("MMDVMDNPCBuildStatusUpdated", MMDVMDNPC.BuildStatus)
end

local ZERO_VECTOR = Vector(0, 0, 0)
local ZERO_ANGLE = Angle(0, 0, 0)
-- Reused engine objects: ManipulateBone*/net.WriteAngle copy their argument,
-- so one scratch object replaces a fresh allocation per call.
local scratch_angle, scratch_vector
do
    local angleMeta = FindMetaTable and FindMetaTable("Angle") or nil
    local vectorMeta = FindMetaTable and FindMetaTable("Vector") or nil
    local setAngle = angleMeta and angleMeta.SetUnpacked or function(a, p, y, r) a.p, a.y, a.r = p, y, r end
    local setVector = vectorMeta and vectorMeta.SetUnpacked or function(v, x, y, z) v.x, v.y, v.z = x, y, z end
    local angle, vector = Angle(0, 0, 0), Vector(0, 0, 0)
    scratch_angle = function(p, y, r)
        setAngle(angle, p, y, r)
        return angle
    end
    scratch_vector = function(x, y, z)
        setVector(vector, x, y, z)
        return vector
    end
end
local SOURCE_PELVIS = "ValveBiped.Bip01_Pelvis"
local SOURCE_SPINE = "ValveBiped.Bip01_Spine"
local LOCAL_PLAYBACK_HZ = 120
local EYE_TRACK_BONE_MOVE_BACK = 0.10
local EYE_TRACK_BONE_POS_UD = 0.5
local EYE_TRACK_BONE_POS_LR = 0.5
local EYE_TRACK_SMOOTH = 20

local function local_playback_hz()
    local cvar = GetConVar("mmd_vmd_npc_playback_hz")
    return math.Clamp(
        cvar and cvar:GetFloat() or MMDVMDNPC.DefaultPlaybackHz or LOCAL_PLAYBACK_HZ,
        MMDVMDNPC.MinPlaybackHz or 10,
        MMDVMDNPC.MaxPlaybackHz or LOCAL_PLAYBACK_HZ
    )
end

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

local function lerp_value(a, b, fraction)
    return (tonumber(a) or 0) + ((tonumber(b) or 0) - (tonumber(a) or 0)) * fraction
end

local function clean_angle(ang)
    ang = ang or ZERO_ANGLE
    local function clean(value)
        value = tonumber(value) or 0
        value = math.NormalizeAngle and math.NormalizeAngle(value) or (((value + 180) % 360) - 180)
        if math.abs(value) < 0.00001 then return 0 end
        return value
    end

    return Angle(clean(ang.p), clean(ang.y), clean(ang.r))
end

local function normalize_angle_delta(a, b)
    if math.NormalizeAngle then
        return math.NormalizeAngle((tonumber(b) or 0) - (tonumber(a) or 0))
    end
    return ((((tonumber(b) or 0) - (tonumber(a) or 0)) + 180) % 360) - 180
end

local function lerp_angle_value(a, b, fraction)
    return (tonumber(a) or 0) + normalize_angle_delta(a, b) * fraction
end

local function setup_bones_now(ent)
    if not IsValid(ent) then return end
    if ent.InvalidateBoneCache then ent:InvalidateBoneCache() end
    if ent.SetupBones then ent:SetupBones() end
end

local function lookup_reference_sequence(ent)
    return MMDVMDNPC.LookupReferenceSequence and MMDVMDNPC.LookupReferenceSequence(ent) or -1
end

local function lookup_reference_sequence_info(ent)
    return MMDVMDNPC.LookupReferenceSequenceInfo and MMDVMDNPC.LookupReferenceSequenceInfo(ent) or nil
end

local function force_reference_pose(ent)
    if not IsValid(ent) then return false end

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
    setup_bones_now(ent)
    ent.MMDVMDNPCReferenceInfo = info
    return true, info
end

local function clear_all_bone_manipulations(ent)
    if not IsValid(ent) or not ent.GetBoneCount then return end

    local count = ent:GetBoneCount() or 0
    for bone = 0, count - 1 do
        if ent.ManipulateBoneAngles then ent:ManipulateBoneAngles(bone, ZERO_ANGLE, false) end
        if ent.ManipulateBonePosition then ent:ManipulateBonePosition(bone, ZERO_VECTOR) end
    end
    setup_bones_now(ent)
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

local function rotate_vector_around_axis(vec, axis, degrees)
    degrees = tonumber(degrees) or 0
    if math.abs(degrees) < 0.00001 then
        return Vector(vec.x, vec.y, vec.z)
    end

    local normal = Vector(axis.x, axis.y, axis.z)
    if normal:LengthSqr() <= 0.0000001 then return Vector(vec.x, vec.y, vec.z) end
    normal:Normalize()

    local rad = math.rad(degrees)
    local cos = math.cos(rad)
    local sin = math.sin(rad)
    local dot = vec:Dot(normal)

    return (vec * cos) + (normal:Cross(vec) * sin) + (normal * dot * (1 - cos))
end

local function rotate_angle_around_sequential_model_axes(baseline, modelAng, degrees)
    degrees = degrees or {}

    local forward = baseline:Forward()
    local up = baseline:Up()

    local modelX = modelAng:Forward()
    local modelY = modelAng:Right()
    local modelZ = modelAng:Up()

    forward = rotate_vector_around_axis(forward, modelY, degrees.y)
    up = rotate_vector_around_axis(up, modelY, degrees.y)

    forward = rotate_vector_around_axis(forward, modelX, degrees.x)
    up = rotate_vector_around_axis(up, modelX, degrees.x)

    forward = rotate_vector_around_axis(forward, modelZ, degrees.z)
    up = rotate_vector_around_axis(up, modelZ, degrees.z)

    forward:Normalize()
    up:Normalize()

    return clean_angle(forward:AngleEx(up))
end

local function reference_basis_is_idlenoise(referenceInfo)
    return istable(referenceInfo) and tostring(referenceInfo.basis or "") == "idlenoise"
end

local function transform_reference_vector_to_sequence_basis(vec, referenceInfo)
    vec = vec or ZERO_VECTOR
    if reference_basis_is_idlenoise(referenceInfo) then
        return Vector(-(vec.y or 0), vec.x or 0, vec.z or 0)
    end
    return Vector(vec.x or 0, vec.y or 0, vec.z or 0)
end

local function transform_reference_degrees_to_sequence_basis(degrees, referenceInfo)
    degrees = degrees or {}
    if reference_basis_is_idlenoise(referenceInfo) then
        return {
            x = -(degrees.y or 0),
            y = degrees.x or 0,
            z = degrees.z or 0,
        }
    end
    return {
        x = degrees.x or 0,
        y = degrees.y or 0,
        z = degrees.z or 0,
    }
end

local function raw_axis_to_model_axis_degrees(x, y, z, referenceInfo)
    local referenceDegrees = {
        x = -(y or 0),
        y = -(x or 0),
        z = z or 0,
    }
    return transform_reference_degrees_to_sequence_basis(referenceDegrees, referenceInfo)
end

local function is_zero_degrees(degrees)
    return not degrees
        or (math.abs(degrees.x or 0) < 0.00001
            and math.abs(degrees.y or 0) < 0.00001
            and math.abs(degrees.z or 0) < 0.00001)
end

local function is_zero_angle(ang)
    return not ang
        or (math.abs(ang.p or 0) < 0.00001
            and math.abs(ang.y or 0) < 0.00001
            and math.abs(ang.r or 0) < 0.00001)
end

local function is_zero_vector(vec)
    return not vec or vec:LengthSqr() <= 0.0000001
end

local function copy_vector(vec)
    vec = vec or ZERO_VECTOR
    return Vector(vec.x or 0, vec.y or 0, vec.z or 0)
end

local function convar_bool(name, fallback)
    local cvar = GetConVar(name)
    if not cvar then return fallback == true end
    return cvar:GetBool()
end

local function source_is_arm_twist(source)
    source = string.lower(tostring(source or ""))
    return string.find(source, "zarmtwist", 1, true) ~= nil
end

local function source_is_hand_twist(source)
    source = string.lower(tostring(source or ""))
    return string.find(source, "zhandtwist", 1, true) ~= nil
        or string.find(source, "handtwist", 1, true) ~= nil
        or string.find(source, "手捩", 1, true) ~= nil
        or string.find(source, "手首捩", 1, true) ~= nil
end

local function source_is_eye(source)
    source = string.lower(tostring(source or ""))
    return string.find(source, "eye", 1, true) ~= nil
end

-- options: a build job's option snapshot (sent with the build plan). Without
-- it the live convars apply (debug preview).
local function transforms_disabled_for_source(source, options)
    local armTwist, handTwist, eyes
    if options then
        armTwist, handTwist, eyes = options.disableArmTwist == true, options.disableHandTwist == true, options.disableEyes == true
    else
        armTwist = convar_bool("mmd_vmd_npc_disable_armtwist", false)
        handTwist = convar_bool("mmd_vmd_npc_disable_handtwist", false)
        eyes = convar_bool("mmd_vmd_npc_disable_eyes", false)
    end
    if armTwist and source_is_arm_twist(source) then
        return true
    end
    if handTwist and source_is_hand_twist(source) then
        return true
    end
    if eyes and source_is_eye(source) then
        return true
    end
    return false
end

local function spine_pelvis_correction_enabled(options)
    if options then return options.disableSpinePelvisCorrection ~= true end
    return not convar_bool("mmd_vmd_npc_disable_spine_pelvis_correction", false)
end

local function row_uses_runtime_spine_position(row)
    return (tostring(row and row.source or "") == SOURCE_SPINE)
        and (tostring(row and row.role or "") == "source_parent_override")
end

local function bone_baseline_angle(ent, bone)
    local matrix = ent.GetBoneMatrix and ent:GetBoneMatrix(bone) or nil
    if matrix then return matrix:GetAngles() end

    if ent.GetBonePosition then
        local _, ang = ent:GetBonePosition(bone)
        return ang or ZERO_ANGLE
    end

    return ZERO_ANGLE
end

local function bone_world_position(ent, bone)
    local matrix = ent.GetBoneMatrix and ent:GetBoneMatrix(bone) or nil
    if matrix then return matrix:GetTranslation() end

    if ent.GetBonePosition then
        local pos = ent:GetBonePosition(bone)
        return pos or ZERO_VECTOR
    end

    return ZERO_VECTOR
end

-- Reference arm-pose correction ------------------------------------------------
-- Motion rows are rotation DELTAS applied on top of the model's REFERENCE pose
-- and are tuned against the standard ValveBiped A-pose reference: upper arms
-- 37.42° below horizontal (measured from the SCMI reference skeleton the
-- supported models compile against). ANY model whose reference holds the arms
-- at a different inclination plays every frame offset by the difference — a
-- T-pose (NewFlan: 3.1° ⇒ arms ~34° high, the original -pi/4 report) or a
-- drooped A-pose (vesna: 55.3° ⇒ arms ~18° low). The posed reference skeleton
-- is measured and each upper arm's DESIRED orientation is re-inclined to the
-- standard angle. Only the INCLINATION is corrected, never the azimuth:
-- measured correct models legitimately differ by ±4° in forward sweep
-- (furina +88.5° vs alf +83.8°), so there is no azimuth ground truth. The
-- dead-band keeps genuinely standard models on the exact untouched code path
-- (furina 38.44° and alf 35.28° both sit inside it; the SCMI reference is
-- 37.42°). The manipulation is still computed against the model's real
-- baseline, so the fast path's self-verification is untouched, and the whole
-- forearm/hand chain inherits the correction through its parent's world
-- orientation.
local ARM_STANDARD_DOWN_DEG = 37.42
local ARM_CORRECTION_DEADBAND_DEG = 3.5

local ARM_CORRECTION_BONES = {
    { upper = "ValveBiped.Bip01_L_UpperArm", lower = "ValveBiped.Bip01_L_Forearm" },
    { upper = "ValveBiped.Bip01_R_UpperArm", lower = "ValveBiped.Bip01_R_Forearm" },
}

-- Must run while the entity is posed at its reference sequence with all bone
-- manipulations cleared. Returns nil for standard-reference models.
local function arm_reference_corrections(ent)
    if not ent.LookupBone then return nil end
    local corrections = nil
    local entPos = ent:GetPos()
    local entAng = ent:GetAngles()
    for _, pair in ipairs(ARM_CORRECTION_BONES) do
        local upper = ent:LookupBone(pair.upper)
        local lower = ent:LookupBone(pair.lower)
        if upper and lower then
            local upperLocal = WorldToLocal(bone_world_position(ent, upper), ZERO_ANGLE, entPos, entAng)
            local lowerLocal = WorldToLocal(bone_world_position(ent, lower), ZERO_ANGLE, entPos, entAng)
            local dir = lowerLocal - upperLocal
            if dir:LengthSqr() > 0.25 then
                dir:Normalize()
                local downDeg = math.deg(math.asin(math.Clamp(-dir.z, -1, 1)))
                if math.abs(downDeg - ARM_STANDARD_DOWN_DEG) > ARM_CORRECTION_DEADBAND_DEG then
                    -- Same azimuth, re-inclined to the standard A-pose angle.
                    local horizontal = Vector(dir.x, dir.y, 0)
                    if horizontal:LengthSqr() > 0.000001 then
                        horizontal:Normalize()
                        local rad = math.rad(ARM_STANDARD_DOWN_DEG)
                        local target = horizontal * math.cos(rad) - Vector(0, 0, math.sin(rad))
                        local axis = dir:Cross(target)
                        local matrix = ent.GetBoneMatrix and ent:GetBoneMatrix(upper) or nil
                        if axis:LengthSqr() > 0.000001 and matrix then
                            axis:Normalize()
                            local degreesCorr = math.deg(math.acos(math.Clamp(dir:Dot(target), -1, 1)))
                            -- Store the correction as a constant BONE-LOCAL
                            -- post-rotation L = ref⁻¹·C·ref (C = the reference-
                            -- frame rotation re-inclining the arm). Applied as
                            -- baseline(t)·L at frame time it rides the animated
                            -- shoulder chain: D(t)·ref·L = D(t)·C·ref — exact
                            -- whatever the torso does. A fixed entity-frame
                            -- pre-rotation would only be exact at the
                            -- reference pose and drift with torso bends.
                            local _, refAng = WorldToLocal(ZERO_VECTOR, matrix:GetAngles(), ZERO_VECTOR, entAng)
                            local correctedRef = Angle(refAng.p, refAng.y, refAng.r)
                            correctedRef:RotateAroundAxis(axis, degreesCorr)
                            local _, localDelta = WorldToLocal(ZERO_VECTOR, correctedRef, ZERO_VECTOR, refAng)
                            corrections = corrections or {}
                            corrections[upper] = {
                                localDelta = clean_angle(localDelta),
                                degrees = degreesCorr,
                                boneName = pair.upper,
                            }
                        end
                    end
                end
            end
        end
    end
    return corrections
end

-- Post-rotates a bone's frame baseline by its constant bone-local T-pose
-- correction. Identity passthrough when the model needed no correction.
local function arm_corrected_baseline(baseline, correction)
    if not correction then return baseline end
    local _, corrected = LocalToWorld(ZERO_VECTOR, correction.localDelta, ZERO_VECTOR, baseline)
    return corrected
end

local function compute_manip_angle_from_model_axes(ent, bone, degrees, baseline, armCorrection)
    baseline = baseline or bone_baseline_angle(ent, bone)
    -- Desired comes from the (possibly T-pose-corrected) baseline; the manip
    -- delta is against the model's REAL baseline so the engine lands exactly
    -- on desired.
    local desired = rotate_angle_around_sequential_model_axes(
        arm_corrected_baseline(baseline, armCorrection), ent:GetAngles(), degrees)
    local _, localManip = WorldToLocal(ZERO_VECTOR, desired, ZERO_VECTOR, baseline)
    return clean_angle(localManip)
end

local function world_vector_to_entity_local(ent, vec)
    if not IsValid(ent) then return copy_vector(vec) end

    local origin = ent:GetPos()
    local localOrigin = ent:WorldToLocal(origin)
    local localTarget = ent:WorldToLocal(origin + vec)
    return localTarget - localOrigin
end

local function send_debug_pose(ent, packed, flexPacked)
    if not IsValid(ent) then return end
    flexPacked = flexPacked or {}

    net.Start("mmdvmd_debug_apply")
        net.WriteEntity(ent)
        net.WriteUInt(math.min(#packed, 4096), 16)
        for i = 1, math.min(#packed, 4096) do
            net.WriteUInt(packed[i].bone, 16)
            net.WriteAngle(packed[i].ang)
            net.WriteFloat(packed[i].pos.x)
            net.WriteFloat(packed[i].pos.y)
            net.WriteFloat(packed[i].pos.z)
        end
        net.WriteUInt(math.min(#flexPacked, 4096), 16)
        for i = 1, math.min(#flexPacked, 4096) do
            net.WriteInt(flexPacked[i].flexID, 16)
            net.WriteFloat(flexPacked[i].weight)
        end
    net.SendToServer()
end

local function packet_to_frame_data(frameNumber, packed, flexPacked)
    local frame = {
        frame = math.max(0, math.floor(tonumber(frameNumber) or 0)),
        bones = {},
        flexes = {},
    }

    for _, row in ipairs(packed or {}) do
        local ang = row.ang or ZERO_ANGLE
        local pos = row.pos or ZERO_VECTOR
        frame.bones[#frame.bones + 1] = {
            row.bone,
            ang.p or 0,
            ang.y or 0,
            ang.r or 0,
            pos.x or 0,
            pos.y or 0,
            pos.z or 0,
        }
    end

    for _, row in ipairs(flexPacked or {}) do
        frame.flexes[#frame.flexes + 1] = {
            row.flexID,
            math.Clamp(tonumber(row.weight) or 0, 0, 1),
        }
    end

    return frame
end

local function sorted_client_metadata(map)
    local out = {}
    for _, meta in pairs(map or {}) do
        out[#out + 1] = meta
    end
    table.sort(out, function(a, b) return (a.id or 0) < (b.id or 0) end)
    return out
end

local function optional_client_convar(name)
    if not GetConVar then return nil end
    return GetConVar(name)
end

local function begin_client_cvar_suppression(names)
    local token = {}
    for _, name in ipairs(names or {}) do
        local cvar = optional_client_convar(name)
        if cvar then
            local state = MMDVMDNPC.ClientCVarSuppressions[name]
            if not state then
                state = {
                    original = cvar:GetString(),
                    count = 0,
                }
                MMDVMDNPC.ClientCVarSuppressions[name] = state
                RunConsoleCommand(name, "0")
            end
            state.count = (state.count or 0) + 1
            token[#token + 1] = name
        end
    end
    return #token > 0 and token or nil
end

local function end_client_cvar_suppression(token)
    for _, name in ipairs(token or {}) do
        local state = MMDVMDNPC.ClientCVarSuppressions[name]
        if state then
            state.count = math.max(0, (state.count or 1) - 1)
            if state.count <= 0 then
                MMDVMDNPC.ClientCVarSuppressions[name] = nil
                if optional_client_convar(name) then
                    RunConsoleCommand(name, tostring(state.original or "0"))
                end
            end
        end
    end
end

local function begin_build_dummy_cvar_suppression()
    if MMDVMDNPC.BuildDummyCVarSuppression then return end
    MMDVMDNPC.BuildDummyCVarSuppression = begin_client_cvar_suppression(BUILD_DUMMY_SUPPRESSED_CVARS)
end

local function end_build_dummy_cvar_suppression()
    if not MMDVMDNPC.BuildDummyCVarSuppression then return end
    end_client_cvar_suppression(MMDVMDNPC.BuildDummyCVarSuppression)
    MMDVMDNPC.BuildDummyCVarSuppression = nil
end

local function destroy_build_dummy()
    local dummy = MMDVMDNPC.BuildDummy
    MMDVMDNPC.BuildDummy = nil
    if IsValid(dummy) then dummy:Remove() end
    end_build_dummy_cvar_suppression()
end

-- Build a hidden dummy for the given model. The optional target only supplies a
-- world angle; retargeting produces bone-local manipulation angles that are
-- invariant to the dummy's overall yaw, so a NULL/never-networked target (e.g.
-- an NPC outside the builder's PVS) still yields a correct build from the model
-- string alone. Returns nil only when the model itself cannot be instantiated.
local function build_dummy_for_model(model, target)
    model = tostring(model or "")
    if IsValid(target) and model == "" then model = target:GetModel() or "" end
    if model == "" then return nil end

    local dummy = MMDVMDNPC.BuildDummy
    if not IsValid(dummy) or dummy:GetModel() ~= model then
        destroy_build_dummy()
        begin_build_dummy_cvar_suppression()
        dummy = ClientsideModel(model, RENDERGROUP_OTHER)
        MMDVMDNPC.BuildDummy = dummy
    end
    if not IsValid(dummy) then return nil end

    dummy:SetPos(vector_origin or Vector(0, 0, 0))
    dummy:SetAngles(IsValid(target) and target:GetAngles() or ZERO_ANGLE)
    dummy:SetNoDraw(true)
    if dummy.DrawShadow then dummy:DrawShadow(false) end
    if dummy.SetRenderMode then dummy:SetRenderMode(RENDERMODE_TRANSALPHA) end
    if dummy.SetColor then dummy:SetColor(Color(255, 255, 255, 0)) end
    setup_bones_now(dummy)
    return dummy
end

local function clear_local_playback_pose(ent, built)
    if not IsValid(ent) or not built then return end

    for _, meta in ipairs(built.bones or {}) do
        local bone = tonumber(meta.id) or -1
        if bone >= 0 then
            if ent.ManipulateBoneAngles then ent:ManipulateBoneAngles(bone, ZERO_ANGLE, false) end
            if ent.ManipulateBonePosition then ent:ManipulateBonePosition(bone, ZERO_VECTOR) end
        end
    end

    -- Flexes are deliberately NOT touched here: the SERVER owns flex weights
    -- (it clears them on stop and networks that); a clientside zeroing would
    -- fight the networked values — the post-debug "expression flicker" bug.
    setup_bones_now(ent)
end

-- Mirror of the server's root-motion split (sv_commands apply_built_sample). The
-- server carries the pelvis horizontal on the entity origin via SetPos (which
-- networks and interpolates to us) and keeps only the vertical in the pelvis bone
-- manipulation. This client-side interpolated poser overrides the pelvis manip
-- locally every frame, so if it kept the full horizontal it would stack on top of
-- the networked origin and render the model at DOUBLE the travel. Read the mode
-- from the replicated server convar and zero the horizontal to match; we must NOT
-- SetPos here (the origin is server-owned; a client SetPos is overwritten by the
-- next snapshot's interpolation and only causes jitter).
local function root_motion_origin_active()
    local cv = GetConVar("mmd_vmd_npc_root_motion_origin")
    if cv == nil then return true end -- default-on; fail toward "no double offset"
    return cv:GetBool()
end

local function apply_local_built_sample(ent, frameA, frameB, fraction, pelvisZOffset)
    frameA = frameA or {}
    frameB = frameB or frameA
    fraction = math.Clamp(tonumber(fraction) or 0, 0, 1)
    pelvisZOffset = tonumber(pelvisZOffset) or 0
    local pelvisBone = ent.LookupBone and ent:LookupBone(SOURCE_PELVIS) or nil
    local rootMotion = root_motion_origin_active()
    -- Runs every frame per dancing entity: look the methods up once and pass
    -- the reused scratch objects (the engine copies them).
    local manipulateAngles = ent.ManipulateBoneAngles
    local manipulatePosition = ent.ManipulateBonePosition
    local bonesB = frameB.bones or {}

    for index, boneA in ipairs(frameA.bones or {}) do
        local boneB = bonesB[index] or boneA
        local bone = tonumber(boneA[1]) or -1
        if bone >= 0 then
            if manipulateAngles then
                manipulateAngles(ent, bone, scratch_angle(
                    lerp_angle_value(boneA[2], boneB[2], fraction),
                    lerp_angle_value(boneA[3], boneB[3], fraction),
                    lerp_angle_value(boneA[4], boneB[4], fraction)
                ), false)
            end
            if manipulatePosition then
                local x = lerp_value(boneA[5], boneB[5], fraction)
                local y = lerp_value(boneA[6], boneB[6], fraction)
                local z = lerp_value(boneA[7], boneB[7], fraction)
                if pelvisBone and bone == pelvisBone then
                    z = z + pelvisZOffset
                    if rootMotion then
                        x = 0
                        y = 0
                    end
                end
                manipulatePosition(ent, bone, scratch_vector(x, y, z))
            end
        end
    end

    -- Flexes are deliberately NOT written by this local poser (mirror of the
    -- pelvis split above, but total): a clientside SetFlexWeight overrides the
    -- networked server value on this client only, so any divergence between
    -- the client's built replica and the server's (e.g. after a flex-mapping
    -- edit rebuilt one side) rendered as the face flickering between the
    -- correct expression and neutral. The server samples flexes every playback
    -- tick and those weights network fine; bones are the only thing that needs
    -- local smoothing.

    setup_bones_now(ent)
end

local function resolve_local_eye_bones(ent)
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

    return leftBone, rightBone
end

function MMDVMDNPC.ClientEyeBoneSummary(ent)
    if not IsValid(ent) then return L("mmd_vmd_npc.ui.eye_status_none") end

    local leftBone, rightBone = resolve_local_eye_bones(ent)
    local leftName = leftBone ~= nil and ent.GetBoneName and ent:GetBoneName(leftBone) or nil
    local rightName = rightBone ~= nil and ent.GetBoneName and ent:GetBoneName(rightBone) or nil

    return LF(
        "mmd_vmd_npc.ui.eye_status_fmt",
        leftName and LF("mmd_vmd_npc.ui.eye_bone_fmt", leftName, leftBone) or L("mmd_vmd_npc.ui.not_found"),
        rightName and LF("mmd_vmd_npc.ui.eye_bone_fmt", rightName, rightBone) or L("mmd_vmd_npc.ui.not_found")
    )
end

local function get_local_eye_attachment(ent)
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

-- Single source of truth for "where the local player is currently viewing the
-- scene from", with a stable priority: the imported camera animation when
-- active, else the third-person orbit camera, else the eyes. Both the local
-- (self-proxy) eye tracking and the server bridge read THIS, so the two systems
-- never chase divergent targets and fight over the same eyes frame to frame
-- (the flicker seen when a player dance and an NPC dance overlap). The globals
-- are only trusted while their owning mode is active, so a stale value left
-- behind by a just-deactivated mode is ignored.
function MMDVMDNPC.CurrentViewOrigin()
    -- A camera debug preview renders through CameraAnimViewOrigin without
    -- setting CameraAnimActive, and it suppresses the orbit camera (freezing
    -- EyeTrackCameraOrigin). Recognise it first so eyes track the debug camera
    -- the player is actually looking through, not a frozen orbit point.
    if MMDVMDNPC.CameraDebugPreviewRenderable and MMDVMDNPC.CameraDebugPreviewRenderable()
        and isvector(MMDVMDNPC.CameraAnimViewOrigin) then
        return MMDVMDNPC.CameraAnimViewOrigin
    end
    if MMDVMDNPC.CameraAnimActive and isvector(MMDVMDNPC.CameraAnimViewOrigin) then
        return MMDVMDNPC.CameraAnimViewOrigin
    end
    if MMDVMDNPC.SelfThirdPersonActive and isvector(MMDVMDNPC.EyeTrackCameraOrigin) then
        return MMDVMDNPC.EyeTrackCameraOrigin
    end
    return EyePos()
end

local function local_eye_tracking_target()
    return MMDVMDNPC.CurrentViewOrigin()
end

local function compute_local_look_controls(ent, targetWorld)
    if not IsValid(ent) or not isvector(targetWorld) then return 0, 0, 0 end

    local att = get_local_eye_attachment(ent)
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

local function reset_local_eye_tracking(ent, eyeState)
    if not IsValid(ent) or not eyeState then return end

    if eyeState.eyeBoneL ~= nil and ent.ManipulateBonePosition then
        ent:ManipulateBonePosition(eyeState.eyeBoneL, ZERO_VECTOR)
    end
    if eyeState.eyeBoneR ~= nil and ent.ManipulateBonePosition then
        ent:ManipulateBonePosition(eyeState.eyeBoneR, ZERO_VECTOR)
    end
    if ent.SetEyeTarget then
        pcall(ent.SetEyeTarget, ent, ZERO_VECTOR)
    end
    setup_bones_now(ent)
end

local function apply_local_eye_tracking(ent, state, now)
    if not IsValid(ent) or not ent.ManipulateBonePosition or not state then return end

    if not eye_tracking_enabled() then
        reset_local_eye_tracking(ent, state.eyeTrack)
        state.eyeTrack = nil
        return
    end

    local targetWorld = local_eye_tracking_target()
    if not isvector(targetWorld) then return end

    local eyeState = state.eyeTrack
    if not eyeState then
        eyeState = {}
        state.eyeTrack = eyeState
    end
    if not eyeState.eyeBonesResolved then
        eyeState.eyeBoneL, eyeState.eyeBoneR = resolve_local_eye_bones(ent)
        eyeState.eyeBonesResolved = true
    end

    local lookLeftRight, lookUpDown, lookBack = compute_local_look_controls(ent, targetWorld)
    local dt = math.max(0.001, now - (eyeState.lastApply or now))
    eyeState.lastApply = now
    local smooth = GetConVar("mmd_vmd_npc_eye_track_smooth")
    local moveback = GetConVar("mmd_vmd_npc_eye_track_moveback")
    local posUD = GetConVar("mmd_vmd_npc_eye_track_pos_ud")
    local posLR = GetConVar("mmd_vmd_npc_eye_track_pos_lr")
    local alpha = 1 - math.exp(-dt * math.max(0.1, smooth and smooth:GetFloat() or EYE_TRACK_SMOOTH))

    eyeState.curL = (eyeState.curL or 0) + (lookLeftRight - (eyeState.curL or 0)) * alpha
    eyeState.curU = (eyeState.curU or 0) + (lookUpDown - (eyeState.curU or 0)) * alpha
    eyeState.curB = (eyeState.curB or 0) + (lookBack - (eyeState.curB or 0)) * alpha

    if eyeState.eyeBoneL ~= nil or eyeState.eyeBoneR ~= nil then
        local eyeVec = eyeState.eyeVec or Vector(0, 0, 0)
        eyeState.eyeVec = eyeVec
        eyeVec.x = math.Clamp(eyeState.curU or 0, -1, 1) * (posUD and posUD:GetFloat() or EYE_TRACK_BONE_POS_UD)
        eyeVec.y = math.Clamp(eyeState.curB or 0, 0, 1) * (moveback and moveback:GetFloat() or EYE_TRACK_BONE_MOVE_BACK)
        eyeVec.z = -math.Clamp(eyeState.curL or 0, -1, 1) * (posLR and posLR:GetFloat() or EYE_TRACK_BONE_POS_LR)

        if eyeState.eyeBoneL ~= nil then ent:ManipulateBonePosition(eyeState.eyeBoneL, eyeVec) end
        if eyeState.eyeBoneR ~= nil then ent:ManipulateBonePosition(eyeState.eyeBoneR, eyeVec) end
        setup_bones_now(ent)
    end
end

local function default_self_camera_distance()
    local convarDistance = GetConVar("mmd_vmd_npc_thirdperson_distance")
    return convarDistance and convarDistance:GetFloat() or MMDVMDNPC.DefaultThirdPersonDistance or 120
end

local function entity_camera_center(ent)
    if not IsValid(ent) then return vector_origin or Vector(0, 0, 0) end

    local center = ent:GetPos()
    if ent.LocalToWorld and ent.OBBCenter then
        center = ent:LocalToWorld(ent:OBBCenter())
    end
    return center
end
-- NO NEED IN THIS FORK
-- local function clamp_self_camera_offset(offset)
--     offset = offset or Vector(0, 0, 0)
--     local maxRadius = 1000
--     if offset:LengthSqr() > maxRadius * maxRadius then
--         offset:Normalize()
--         offset = offset * maxRadius
--     end
--     return offset
-- end

local function is_local_self_playback_proxy(ent)
    if not IsValid(ent) or not ent.GetNWBool then return false end
    if ent:GetNWBool("MMDVMDNPCSelfProxy", false) ~= true then return false end
    if ent.GetNWEntity then
        local owner = ent:GetNWEntity("MMDVMDNPCSelfProxyOwner")
        if IsValid(owner) and owner ~= LocalPlayer() then return false end
    end
    return true
end

 
MMDVMDNPC.CameraTrackMode = MMDVMDNPC.CameraTrackMode or true
MMDVMDNPC.StaticCameraCenter = nil 

local function activate_self_proxy_camera(ent)
    if not IsValid(ent) then return end

    local eye = LocalPlayer():EyeAngles()
    MMDVMDNPC.SelfThirdPersonActive = true
    MMDVMDNPC.SelfPlaybackCameraEnt = ent  
    
    MMDVMDNPC.SelfCameraDistance = MMDVMDNPC.SelfCameraDistance or default_self_camera_distance()
    MMDVMDNPC.SelfCameraYaw = MMDVMDNPC.SelfCameraYaw or (ent:GetAngles().y + 180)
    MMDVMDNPC.SelfCameraPitch = MMDVMDNPC.SelfCameraPitch or 10
    
     
     
    local mins, maxs = ent:GetModelBounds()
    local centerOffset = (maxs.z + mins.z) * 0.5
    MMDVMDNPC.StaticCameraCenter = ent:GetPos() + Vector(0, 0, centerOffset)
    
    MMDVMDNPC.CameraInitialized = true
end

-- Local playbacks whose entity has not been networked to this client yet
-- (net messages outrun entity snapshots — the same race the camera system
-- retries on). Keyed by entity INDEX from the wire; resolved from the local
-- playback Think hook until the entity appears or the attempt expires. The
-- old code fell back to posing TargetStatus.ent here, which misfiled the
-- state under an unrelated valid entity that no stop message could ever
-- address — an orphaned second pose writer that flickered every later dance
-- on that entity until the game restarted.
MMDVMDNPC.PendingLocalPlaybacks = MMDVMDNPC.PendingLocalPlaybacks or {}

-- serverStarted is the server ticker's own CurTime epoch for this playback.
-- Both writers computing the frame from the SAME epoch (and the same clock)
-- is what keeps the networked pose and the local interpolated pose on the
-- same dance timestamp; seeding from message-receipt time instead let any
-- delivery skew become a permanent per-frame flicker between two poses.
local function start_local_playback(path, playbackEnt, serverStarted)
    local built = MMDVMDNPC.ClientBuiltCache[path or ""]
    if not built or not IsValid(playbackEnt) then return end
    local ent = playbackEnt
    -- Entity-index reuse guard: a pending start resolved after its original
    -- entity died could land on an unrelated entity. A built cache is per
    -- model, so a model mismatch proves the wrong entity — skip; the server's
    -- networked pose owns whatever is actually dancing.
    local builtModel = string.lower(string.Replace(tostring(built.model or ""), "\\", "/"))
    local entModel = string.lower(string.Replace(tostring(ent.GetModel and ent:GetModel() or ""), "\\", "/"))
    if builtModel ~= "" and entModel ~= "" and builtModel ~= entModel then return end
    if is_local_self_playback_proxy(ent) then
        activate_self_proxy_camera(ent)
    end

    MMDVMDNPC.LocalPlaybacks = MMDVMDNPC.LocalPlaybacks or {}
    local settings = selected_playback_settings()
    local started = tonumber(serverStarted) or 0
    MMDVMDNPC.LocalPlaybacks[ent] = {
        path = path,
        built = built,
        ent = ent,
        started = started > 0 and started or CurTime(),
        nextTick = 0,
        loopPlayback = settings and settings.loopPlayback == true,
        -- The SAME pelvis value the server captured from this settings
        -- snapshot: the local poser reading the live convar while the server
        -- kept the snapshot made the two writers disagree on the pelvis (and
        -- thus the whole body height) for the entire dance.
        pelvisZOffset = tonumber(settings and settings.pelvisZOffset) or 0,
        -- Server-confirmation clock for the orphan reaper (CurTime, so a
        -- paused game does not age states the server also is not ticking).
        lastServerSync = CurTime(),
    }
end

local function queue_pending_local_playback(entIndex, path, serverStarted)
    entIndex = tonumber(entIndex) or 0
    if entIndex <= 0 then return end
    MMDVMDNPC.PendingLocalPlaybacks[entIndex] = {
        path = path,
        started = serverStarted,
        -- CurTime like everything else here: a paused game must not expire a
        -- pending whose entity simply has not been simulated in yet.
        expires = CurTime() + 5,
    }
end

local function resolve_pending_local_playbacks()
    local pendings = MMDVMDNPC.PendingLocalPlaybacks
    if not pendings or next(pendings) == nil then return end
    local now = CurTime()
    for entIndex, pending in pairs(pendings) do
        local ent = Entity(entIndex)
        if IsValid(ent) then
            pendings[entIndex] = nil
            start_local_playback(pending.path, ent, pending.started)
        elseif (pending.expires or 0) < now then
            pendings[entIndex] = nil
        end
    end
end

local function pause_local_playback(ent)
    local playbacks = MMDVMDNPC.LocalPlaybacks or {}
    if IsValid(ent) then
        local state = playbacks[ent]
        if not state then return end
        -- The server repeats "paused" every second; it doubles as the alive
        -- signal that keeps the orphan reaper away while no body syncs flow.
        state.lastServerSync = CurTime()
        if state.paused then return end
        state.paused = true
        state.pauseStarted = CurTime()
        return
    end
    for _, state in pairs(playbacks) do
        if state then
            state.lastServerSync = CurTime()
            if not state.paused then
                state.paused = true
                state.pauseStarted = CurTime()
            end
        end
    end
end

-- serverStarted (when provided) is the server's post-resume epoch and is
-- taken verbatim — even for a state the client never saw get paused. A
-- missed or misaddressed pause message used to leave the local epoch behind
-- the server's by exactly the pause duration, a permanent offset the two
-- pose writers then flickered across on every frame.
local function resume_one_local_playback(state, serverStarted)
    if not state then return end
    state.lastServerSync = CurTime()
    local authoritative = tonumber(serverStarted) or 0
    if not state.paused and authoritative <= 0 then return end
    local now = CurTime()
    if authoritative > 0 then
        state.started = authoritative
    elseif state.paused then
        local pausedFor = math.max(0, now - (tonumber(state.pauseStarted) or now))
        state.started = (tonumber(state.started) or now) + pausedFor
    end
    state.paused = false
    state.pauseStarted = nil
    state.nextTick = 0
end

local function resume_local_playback(ent, serverStarted)
    local playbacks = MMDVMDNPC.LocalPlaybacks or {}
    if IsValid(ent) then
        resume_one_local_playback(playbacks[ent], serverStarted)
        return
    end
    for _, state in pairs(playbacks) do
        resume_one_local_playback(state, serverStarted)
    end
end

local function deactivate_self_proxy_camera()
    MMDVMDNPC.SelfThirdPersonActive = false
    MMDVMDNPC.SelfPlaybackCameraEnt = nil
    MMDVMDNPC.SelfCameraYaw = nil
    MMDVMDNPC.SelfCameraPitch = nil
    MMDVMDNPC.SelfCameraBaseCenter = nil

    MMDVMDNPC.SelfCameraCenterOffset = Vector(0, 0, 0)
    MMDVMDNPC.CameraInitialized = false
    MMDVMDNPC.SelfCameraHeightOffset = 0
end

local function stop_one_local_playback(ent, clearPose)
    local playbacks = MMDVMDNPC.LocalPlaybacks or {}
    local state = playbacks[ent]
    playbacks[ent] = nil
    if not state then return end
    reset_local_eye_tracking(state.ent, state.eyeTrack)
    if MMDVMDNPC.SelfPlaybackCameraEnt == state.ent then
        deactivate_self_proxy_camera()
    end
    if clearPose ~= false then
        clear_local_playback_pose(state.ent, state.built)
    end
end

-- For receivers defined earlier in this file (built-cache invalidation).
MMDVMDNPC.StopLocalPlaybackFor = stop_one_local_playback

local function stop_local_playback(clearPose, ent)
    if IsValid(ent) then
        stop_one_local_playback(ent, clearPose)
        return
    end
    for playbackEnt in pairs(MMDVMDNPC.LocalPlaybacks or {}) do
        stop_one_local_playback(playbackEnt, clearPose)
    end
end

force_self_view_cleanup = function()
    local cameraEnt = MMDVMDNPC.SelfPlaybackCameraEnt
    if IsValid(cameraEnt) then
        stop_one_local_playback(cameraEnt, true)
        if MMDVMDNPC.ActivePlaybackEnts then
            MMDVMDNPC.ActivePlaybackEnts[cameraEnt] = nil
        end
    end

    deactivate_self_proxy_camera()
    MMDVMDNPC.EyeTrackCameraBridgeActive = false
    MMDVMDNPC.EyeTrackCameraOrigin = nil

    local playStatus = MMDVMDNPC.PlayStatus or {}
    if not IsValid(playStatus.ent) or playStatus.ent == cameraEnt then
        MMDVMDNPC.PlayStatus = {
            status = "self_reset",
            message = L("mmd_vmd_npc.status.self_playback_force_reset", "self playback reset; normal view restored"),
            ent = NULL,
        }
        hook.Run("MMDVMDNPCPlayStatusUpdated", MMDVMDNPC.PlayStatus)
    end
end

hook.Add("Think", "MMDVMDNPCLocalInterpolatedPlayback", function()
    resolve_pending_local_playbacks()
    local playbacks = MMDVMDNPC.LocalPlaybacks or {}
    if next(playbacks) == nil then return end

    local now = CurTime()
    for ent, state in pairs(playbacks) do
        local built = state.built or {}
        local frames = built.frames or {}
        if not IsValid(ent) or #frames <= 0 then
            stop_one_local_playback(ent, false)
        elseif now - (tonumber(state.lastServerSync) or now) > 8 then
            -- The server confirms every live playback at least every ~2s
            -- (body sync while playing, repeated status while paused). A
            -- state it has stopped confirming is an orphan — a leaked second
            -- pose writer that would otherwise fight every later dance on
            -- this entity until the game restarts. Clear its pose and drop it.
            stop_one_local_playback(ent, true)
        elseif state.paused then
            apply_local_eye_tracking(ent, state, now)
        elseif now >= (state.nextTick or 0) then
            state.nextTick = now + (1 / local_playback_hz())

            local startFrame = math.floor(tonumber(built.frame_start) or 0)
            local endFrame = math.floor(tonumber(built.frame_end) or startFrame)
            local fps = math.max(1, tonumber(built.fps) or MMDVMDNPC.VMDFPS or 30)
            local sourceFrame = startFrame + (now - (state.started or now)) * fps
            local finished = sourceFrame >= endFrame
            if finished and state.loopPlayback == true then
                local duration = math.max(0, (endFrame - startFrame) / fps)
                if duration > 0 then
                    local elapsed = math.max(0, now - (tonumber(state.started) or now))
                    local loops = math.max(1, math.floor(elapsed / duration))
                    state.started = (tonumber(state.started) or now) + loops * duration
                    sourceFrame = startFrame + (now - (state.started or now)) * fps
                    finished = false
                end
            end
            sourceFrame = math.Clamp(sourceFrame, startFrame, endFrame)

            local lowerFrame = math.floor(sourceFrame)
            local upperFrame = math.min(endFrame, lowerFrame + 1)
            local fraction = sourceFrame - lowerFrame
            local lowerIndex = math.Clamp(lowerFrame - startFrame + 1, 1, #frames)
            local upperIndex = math.Clamp(upperFrame - startFrame + 1, 1, #frames)

            apply_local_built_sample(ent, frames[lowerIndex], frames[upperIndex], fraction, state.pelvisZOffset or 0)
            apply_local_eye_tracking(ent, state, now)

            if finished then
                stop_one_local_playback(ent, false)
            end
        end
    end
end)

local function stop_audio_channel(token)
    token = tonumber(token) or 0
    local state = MMDVMDNPC.AudioChannels[token]
    if not state then return end

    if state.timerName then timer.Remove(state.timerName) end
    if state.channel and state.channel.Stop then state.channel:Stop() end
    MMDVMDNPC.AudioChannels[token] = nil
end

local function stop_all_audio_channels()
    for token in pairs(MMDVMDNPC.AudioChannels or {}) do
        stop_audio_channel(token)
    end
end

local function stop_audio_preview()
    local preview = MMDVMDNPC.AudioPreview
    MMDVMDNPC.AudioPreview = nil
    if preview and preview.channel and preview.channel.Stop then
        preview.channel:Stop()
    end
end

local function audio_file_candidates(soundPath)
    soundPath = tostring(soundPath or "")
    soundPath = string.Replace(soundPath, "\\", "/")
    soundPath = string.gsub(soundPath, "^/+", "")
    if soundPath == "" then return {} end

    local out = {}
    local seen = {}
    local function add(path)
        path = tostring(path or "")
        if path ~= "" and not seen[path] then
            seen[path] = true
            out[#out + 1] = path
        end
    end

    if string.StartWith(soundPath, "sound/") then
        add(soundPath)
        add(string.sub(soundPath, 7))
    else
        add("sound/" .. soundPath)
        add(soundPath)
    end

    return out
end

local function play_audio_file_candidates(soundPath, flags, callback)
    local candidates = audio_file_candidates(soundPath)
    local index = 1

    local function try_next(lastErrID, lastErrName, lastFilename)
        local filename = candidates[index]
        index = index + 1
        if not filename then
            callback(nil, lastErrID, lastErrName, lastFilename or tostring(soundPath or ""))
            return
        end

        sound.PlayFile(filename, flags, function(channel, errID, errName)
            if IsValid(channel) then
                callback(channel, nil, nil, filename)
                return
            end
            try_next(errID, errName, filename)
        end)
    end

    try_next()
end

local function play_audio_preview(soundPath, offset, volume)
    stop_audio_preview()
    if tostring(soundPath or "") == "" then
        print("[MMD VMD] " .. L("mmd_vmd_npc.error.no_imported_music"))
        return
    end

    local seek = math.max(0, -(tonumber(offset) or 0))
    volume = math.Clamp(tonumber(volume) or MMDVMDNPC.DefaultMusicVolume or 1, 0, 2)
    play_audio_file_candidates(soundPath, "noplay", function(channel, errID, errName)
        if not IsValid(channel) then
            print("[MMD VMD] " .. LF("mmd_vmd_npc.console.failed_preview_music_fmt", tostring(errName or errID or L("mmd_vmd_npc.ui.unknown", "unknown"))))
            return
        end
        MMDVMDNPC.AudioPreview = { channel = channel }
        if seek > 0 and channel.SetTime then channel:SetTime(seek) end
        if channel.SetVolume then channel:SetVolume(volume) end
        channel:Play()
    end)
end

-- Music spatialization. In the default omnidirectional mode the channel is 2D
-- (equal in both ears — the engine's audio listener follows the animated
-- camera, and a swooping camera makes true 3D audio swirl around the head) and
-- the volume is driven manually from the PLAYER's distance to the dancer:
-- full volume inside mmd_vmd_npc_music_range, then a sharp quadratic fade to
-- silence across mmd_vmd_npc_music_fade. Unchecking the option restores true
-- 3D positional audio using the same range/fade values.
local function music_omni_enabled()
    local cvar = GetConVar("mmd_vmd_npc_music_omni")
    if not cvar then return true end
    return cvar:GetBool()
end

local function music_range_settings()
    local rangeCvar = GetConVar("mmd_vmd_npc_music_range")
    local fadeCvar = GetConVar("mmd_vmd_npc_music_fade")
    local range = math.max(0, rangeCvar and rangeCvar:GetFloat() or 1500)
    local fade = math.max(10, fadeCvar and fadeCvar:GetFloat() or 300)
    return range, fade
end

-- The dancer arrives as an entity index (not an entity handle): a client can
-- receive the start message before the entity is networked to it (PAS is wider
-- than PVS), and a handle read then would stay NULL forever. Re-resolving the
-- index lets the source become valid as soon as the entity appears.
local function audio_source_entity(state)
    local index = tonumber(state.sourceEntIndex) or 0
    if index <= 0 then return nil end
    local ent = Entity(index)
    if IsValid(ent) then return ent end
    return nil
end

local function omni_volume_factor(state)
    local ply = LocalPlayer()
    if not IsValid(ply) then return 1 end
    local src = audio_source_entity(state)
    -- Unresolvable dancer (not networked to us / removed): gate closed. Full
    -- volume here would play the song map-wide for players who were merely in
    -- the potentially-audible set when it started.
    if not src then return 0 end
    local range, fade = music_range_settings()
    local dist = ply:GetPos():Distance(src:GetPos())
    if dist <= range then return 1 end
    local t = 1 - math.Clamp((dist - range) / fade, 0, 1)
    return t * t
end

local function play_synced_audio(token, soundPath, sourceEntIndex, offset, startTime, volume)
    token = tonumber(token) or 0
    if token <= 0 or tostring(soundPath or "") == "" then return end

    stop_audio_channel(token)
    offset = tonumber(offset) or 0
    startTime = tonumber(startTime) or CurTime()
    volume = math.Clamp(tonumber(volume) or MMDVMDNPC.DefaultMusicVolume or 1, 0, 2)

    local audibleStart = startTime + math.max(0, offset)
    local wait = math.max(0, audibleStart - CurTime())
    local timerName = "MMDVMDNPCAudioStart_" .. tostring(token)
    local state = {
        token = token,
        soundPath = soundPath,
        sourceEntIndex = tonumber(sourceEntIndex) or 0,
        timerName = timerName,
        baseVolume = volume,
    }
    MMDVMDNPC.AudioChannels[token] = state

    timer.Create(timerName, wait, 1, function()
        if MMDVMDNPC.AudioChannels[token] ~= state then return end
        local omni = music_omni_enabled()
        state.omni = omni
        play_audio_file_candidates(soundPath, omni and "noplay" or "3d noplay", function(channel, errID, errName, filename)
            if not IsValid(channel) then
                print("[MMD VMD] " .. LF("mmd_vmd_npc.console.failed_play_music_fmt", filename, tostring(errName or errID or L("mmd_vmd_npc.ui.unknown", "unknown"))))
                return
            end
            -- A stop that raced the async file load already removed this state;
            -- do not let the finished channel play forever as an orphan.
            if MMDVMDNPC.AudioChannels[token] ~= state then
                if channel.Stop then channel:Stop() end
                return
            end
            state.channel = channel
            local src = audio_source_entity(state)
            if omni then
                if channel.SetVolume then channel:SetVolume(volume * omni_volume_factor(state)) end
            else
                local range, fade = music_range_settings()
                if channel.Set3DFadeDistance then channel:Set3DFadeDistance(range, range + fade) end
                if channel.SetPos and src then channel:SetPos(src:GetPos()) end
                if channel.SetVolume then channel:SetVolume(volume) end
            end
            local seek = math.max(0, -offset) + math.max(0, CurTime() - audibleStart)
            if seek > 0 and channel.SetTime then channel:SetTime(seek) end
            if not state.paused then
                channel:Play()
                state.playedOnce = true
            end
        end)
    end)
end

net.Receive("mmdvmd_audio_start", function()
    play_synced_audio(
        net.ReadUInt(32),
        net.ReadString(),
        net.ReadUInt(16),
        net.ReadFloat(),
        net.ReadFloat(),
        net.ReadFloat()
    )
end)

net.Receive("mmdvmd_audio_stop", function()
    stop_audio_channel(net.ReadUInt(32))
end)

net.Receive("mmdvmd_audio_pause", function()
    local token = net.ReadUInt(32)
    local paused = net.ReadBool()
    local state = MMDVMDNPC.AudioChannels[tonumber(token) or 0]
    if not state then return end

    state.paused = paused == true
    local channel = state.channel
    if not IsValid(channel) then return end

    if state.paused then
        if channel.Pause then channel:Pause() end
    else
        if channel.Play then
            channel:Play()
            state.playedOnce = true
        end
    end
end)

hook.Add("Think", "MMDVMDNPCAudioFollow", function()
    for token, state in pairs(MMDVMDNPC.AudioChannels or {}) do
        local channel = state.channel
        if channel and channel.GetState and channel:GetState() == GMOD_CHANNEL_STOPPED then
            -- A "noplay" channel reports STOPPED until its first Play(); a
            -- channel deliberately held back because the playback was paused
            -- before the file finished loading must not be reaped, or the
            -- later resume finds nothing and the music never plays.
            if state.playedOnce and not state.paused then
                stop_audio_channel(token)
            end
        elseif channel then
            if state.omni then
                -- Volume tracks the player-to-dancer distance every frame so
                -- range/fade convar tweaks apply live to running music.
                if channel.SetVolume then
                    channel:SetVolume((state.baseVolume or 1) * omni_volume_factor(state))
                end
            else
                local src = audio_source_entity(state)
                if channel.SetPos and src then
                    channel:SetPos(src:GetPos())
                end
            end
        end
    end
end)

hook.Add("CalcView", "MMDVMDNPCSelfThirdPerson", function(ply, pos, angles, fov)
    -- The imported camera animation view (cl_camera.lua) takes precedence.
    if MMDVMDNPC.CameraAnimActive then return end
    if MMDVMDNPC.CameraDebugPreviewRenderable and MMDVMDNPC.CameraDebugPreviewRenderable() then return end
    if not MMDVMDNPC.SelfThirdPersonActive then return end
    
    local target = MMDVMDNPC.SelfPlaybackCameraEnt
    if not IsValid(target) then 
        MMDVMDNPC.SelfThirdPersonActive = false
        return 
    end

    local heightSlider = GetConVar("mmd_vmd_npc_thirdperson_height"):GetFloat() or 0
    local distance = tonumber(MMDVMDNPC.SelfCameraDistance) or 120
    local dynamicHeight = MMDVMDNPC.SelfCameraHeightOffset or 0

    local center
    if MMDVMDNPC.CameraTrackMode then
        local pelvisBone = target:LookupBone("ValveBiped.Bip01_Pelvis") or target:LookupBone("Pelvis") or 0
        local bonePos, _ = target:GetBonePosition(pelvisBone)
        center = bonePos or target:WorldSpaceCenter()
    else
        center = MMDVMDNPC.StaticCameraCenter or target:WorldSpaceCenter()
    end
    
    center = center + Vector(0, 0, heightSlider + dynamicHeight)

    local yaw = tonumber(MMDVMDNPC.SelfCameraYaw) or 0
    local pitch = tonumber(MMDVMDNPC.SelfCameraPitch) or 10
    local orbit = Angle(pitch, yaw, 0)
    local desiredPos = center - orbit:Forward() * distance

    local tr = util.TraceHull({
        start = center,
        endpos = desiredPos,
        mins = Vector(-4, -4, -4),
        maxs = Vector(4, 4, 4),
        filter = { ply, target },
    })

    MMDVMDNPC.EyeTrackCameraOrigin = tr.HitPos

    local viewAngles = (center - tr.HitPos):Angle()
    -- Expose the resolved 3rd-person view so the camera-following flashlight
    -- (cl_flashlight.lua) can track it without recomputing the orbit.
    MMDVMDNPC.SelfThirdPersonViewOrigin = tr.HitPos
    MMDVMDNPC.SelfThirdPersonViewAngles = viewAngles

    return {
        origin = tr.HitPos,
        angles = viewAngles,
        fov = fov,
        drawviewer = false,
    }
end)

hook.Add("InputMouseApply", "MMDVMDNPCSelfProxyCameraOrbit", function(cmd, x, y, ang)
    if MMDVMDNPC.CameraAnimActive then return end
    if not MMDVMDNPC.SelfThirdPersonActive then return end

    local scale = 0.005
    local sensitivity = GetConVar("sensitivity")
    if sensitivity then scale = scale * math.Clamp(sensitivity:GetFloat(), 0.1, 12) end

    MMDVMDNPC.SelfCameraYaw = (tonumber(MMDVMDNPC.SelfCameraYaw) or (ang and ang.y or 0)) - (tonumber(x) or 0) * scale
    MMDVMDNPC.SelfCameraPitch = math.Clamp((tonumber(MMDVMDNPC.SelfCameraPitch) or 10) + (tonumber(y) or 0) * scale, -65, 80)
    return true
end)

hook.Add("CreateMove", "MMDVMDNPCSelfProxyCameraPan", function(cmd)
    if not MMDVMDNPC.SelfThirdPersonActive or not cmd then return end

    local speed = 60 
    local frameTime = RealFrameTime()
    
    MMDVMDNPC.SelfCameraHeightOffset = MMDVMDNPC.SelfCameraHeightOffset or 0

    if cmd:KeyDown(IN_FORWARD) then 
        MMDVMDNPC.SelfCameraHeightOffset = MMDVMDNPC.SelfCameraHeightOffset + speed * frameTime
    end
    if cmd:KeyDown(IN_BACK) then 
        MMDVMDNPC.SelfCameraHeightOffset = MMDVMDNPC.SelfCameraHeightOffset - speed * frameTime
    end

    MMDVMDNPC.SelfCameraHeightOffset = math.Clamp(MMDVMDNPC.SelfCameraHeightOffset, -50, 100)

    return true 
end)

hook.Add("PlayerBindPress", "MMDVMDNPCSelfProxyCameraWheel", function(ply, bind, pressed)
    if ply ~= LocalPlayer() or not pressed or not MMDVMDNPC.SelfThirdPersonActive then return end

    bind = string.lower(tostring(bind or ""))
    local distance = tonumber(MMDVMDNPC.SelfCameraDistance) or 120

    if string.find(bind, "invprev", 1, true) then  
        MMDVMDNPC.SelfCameraDistance = math.Clamp(distance - 10, 20, 500)
        return true
    elseif string.find(bind, "invnext", 1, true) then  
        MMDVMDNPC.SelfCameraDistance = math.Clamp(distance + 10, 20, 500)
        return true
    end
end)

hook.Add("PreDrawViewModel", "MMDVMDNPCHideSelfProxyViewModel", function()
    if MMDVMDNPC.SelfThirdPersonActive then return true end
end)

-- Client half of the self-playback action lock: the server strips these
-- buttons in StartCommand; stripping them here too keeps prediction in sync so
-- no muzzle flash / fire sound plays locally while the dance proxy performs.
-- The exemptions mirror the server exactly: the addon's own toolgun keeps its
-- documented right-click pause and E+R stop, and +use stays available inside
-- vehicles so the player can dismount.
local SELF_PLAYBACK_LOCKED_BUTTONS = bit.bor(
    IN_ATTACK, IN_ATTACK2, IN_USE, IN_RELOAD, IN_JUMP, IN_DUCK, IN_ZOOM
)
local SELF_PLAYBACK_TOOL_ALLOWED = bit.bor(IN_ATTACK2, IN_USE, IN_RELOAD)

hook.Add("StartCommand", "MMDVMDNPCSelfPlaybackActionLock", function(ply, cmd)
    if ply ~= LocalPlayer() then return end
    if not ply.GetNWBool or not ply:GetNWBool("MMDVMDNPCSelfPlaybackLock", false) then return end

    local mask = SELF_PLAYBACK_LOCKED_BUTTONS
    local weapon = ply.GetActiveWeapon and ply:GetActiveWeapon() or nil
    local toolMode = GetConVar("gmod_toolmode")
    if IsValid(weapon) and weapon:GetClass() == "gmod_tool"
        and toolMode and toolMode:GetString() == "mmd_vmd_npc" then
        mask = bit.band(mask, bit.bnot(SELF_PLAYBACK_TOOL_ALLOWED))
    end
    if ply.InVehicle and ply:InVehicle() then
        mask = bit.band(mask, bit.bnot(IN_USE))
    end
    cmd:SetButtons(bit.band(cmd:GetButtons(), bit.bnot(mask)))
end)

local function selected_eye_track_mode()
    return eye_tracking_enabled() and "camera" or "off"
end

local function has_eye_trackable_local_playback()
    for ent, state in pairs(MMDVMDNPC.LocalPlaybacks or {}) do
        if IsValid(ent) and state then return true end
    end
    return false
end

local function should_send_eye_track_camera_target()
    if selected_eye_track_mode() == "off" then return false end
    if has_eye_trackable_local_playback() then return true end

    local status = MMDVMDNPC.PlayStatus and MMDVMDNPC.PlayStatus.status or ""
    return status == "countdown"
        or status == "playing"
        or status == "paused"
        or status == "group_resumed"
end

local function send_eye_track_camera(active, pos)
    net.Start("mmdvmd_eye_track_camera")
        net.WriteBool(active == true)
        if active == true then
            local smooth = GetConVar("mmd_vmd_npc_eye_track_smooth")
            local moveback = GetConVar("mmd_vmd_npc_eye_track_moveback")
            local posUD = GetConVar("mmd_vmd_npc_eye_track_pos_ud")
            local posLR = GetConVar("mmd_vmd_npc_eye_track_pos_lr")
            net.WriteVector(pos or EyePos())
            net.WriteFloat(smooth and smooth:GetFloat() or MMDVMDNPC.DefaultEyeTrackSmooth or 20)
            net.WriteFloat(moveback and moveback:GetFloat() or MMDVMDNPC.DefaultEyeTrackBoneMoveBack or 0.10)
            net.WriteFloat(posUD and posUD:GetFloat() or MMDVMDNPC.DefaultEyeTrackBonePosUD or 0.5)
            net.WriteFloat(posLR and posLR:GetFloat() or MMDVMDNPC.DefaultEyeTrackBonePosLR or 0.5)
        end
    net.SendToServer()
end

hook.Add("Think", "MMDVMDNPCEyeTrackCameraBridge", function()
    local now = CurTime()
    local shouldSend = should_send_eye_track_camera_target()
    if shouldSend then
        -- Keep the bridge alive for a short grace period after the trigger
        -- momentarily drops (e.g. one dance ends a frame before another's play
        -- status updates). Tearing the target down and rebuilding it snaps the
        -- eyes; lingering lets the smoothing carry through the handover.
        MMDVMDNPC.EyeTrackCameraBridgeUntil = now + 0.4
    end

    if now >= (MMDVMDNPC.EyeTrackCameraBridgeUntil or 0) then
        if MMDVMDNPC.EyeTrackCameraBridgeActive then
            MMDVMDNPC.EyeTrackCameraBridgeActive = false
            send_eye_track_camera(false)
        end
        return
    end

    if now < (MMDVMDNPC.EyeTrackCameraNextSend or 0) then return end
    MMDVMDNPC.EyeTrackCameraNextSend = now + 0.05
    MMDVMDNPC.EyeTrackCameraBridgeActive = true
    -- Same authoritative view origin the local self-proxy eye tracking uses, so
    -- server NPC eyes and local proxy eyes always target the same point.
    send_eye_track_camera(true, MMDVMDNPC.CurrentViewOrigin())
end)

local function convar_float(name, fallback)
    local cvar = GetConVar(name)
    if not cvar then return fallback end
    local value = cvar:GetFloat()
    if value ~= value then return fallback end
    return value
end

local function flex_row_text(row)
    return string.lower(table.concat({
        tostring(row and row.mmd or ""),
        tostring(row and row.source or ""),
        tostring(row and row.resolvedName or ""),
    }, " "))
end

local function text_has_any(text, patterns)
    for _, pattern in ipairs(patterns) do
        if string.find(text, pattern, 1, true) then return true end
    end
    return false
end

local FLEX_EYE_PATTERNS = {
    "eye", "eyes", "blink", "wink", "look", "pupil", "iris",
}

local FLEX_BROW_PATTERNS = {
    "brow", "eyebrow", "brows",
}

local FLEX_MOUTH_PATTERNS = {
    "mouth", "lip", "lips", "jaw", "tongue", "teeth",
}

-- One read of the flex scale convars. A build job snapshots this once so every
-- frame of the build uses the same scales.
local function current_flex_scales()
    return {
        all = convar_float("mmd_vmd_npc_flex_scale_all", 1),
        mouth = convar_float("mmd_vmd_npc_flex_scale_mouth", 1),
        brow = convar_float("mmd_vmd_npc_flex_scale_brow", 1),
        eye = convar_float("mmd_vmd_npc_flex_scale_eye", 1),
        other = 1,
    }
end

local function flex_category_scale(row, scales)
    local text = flex_row_text(row)
    local category = "other"
    if text_has_any(text, FLEX_MOUTH_PATTERNS) then
        category = "mouth"
    elseif text_has_any(text, FLEX_BROW_PATTERNS) then
        category = "brow"
    elseif text_has_any(text, FLEX_EYE_PATTERNS) then
        category = "eye"
    end
    if category == "other" then return 1, category end
    if scales then return scales[category] or 1, category end
    return convar_float("mmd_vmd_npc_flex_scale_" .. category, 1), category
end

local function flex_scale_for_row(row, scales)
    local allScale = scales and scales.all or convar_float("mmd_vmd_npc_flex_scale_all", 1)
    local categoryScale, category = flex_category_scale(row, scales)
    return allScale * categoryScale, category
end

local function scaled_flex_weight(row, scales)
    local scale, category = flex_scale_for_row(row, scales)
    local raw = tonumber(row and row.weight) or 0
    if row then
        row.flexScale = scale
        row.flexCategory = category
        row.scaledWeight = math.Clamp(raw * scale, 0, 1)
    end
    return math.Clamp(raw * scale, 0, 1)
end

-- Model flexes a motion flex row drives (several when a split or manual
-- mapping assigns more than one).
local function flex_row_ids(row)
    if row.flexIDs then return row.flexIDs end
    return { tonumber(row.flexID) or -1 }
end

-- Fast build path -----------------------------------------------------------
-- The legacy build path (rebuild_debug_preview) re-poses the hidden dummy and
-- calls SetupBones once per bone per frame to read each baseline back from the
-- engine. Those baselines are deterministic: a bone's oriented baseline is its
-- reference-pose orientation re-parented through the nearest already-applied
-- ancestor. The fast path captures the reference skeleton once per build job
-- and computes every baseline in closed form, so a frame needs one SetupBones
-- (for the spine correction readback and self-verification) instead of one per
-- bone. Every frame is verified against the engine result; on any mismatch the
-- job permanently falls back to the legacy path, so output is always
-- equivalent to the legacy build within FAST_BUILD_VERIFY_EPSILON degrees.
--
-- Everything that is constant for a job (bone lookups, traversal order, rest
-- orientations, option checks, flex scales) is compiled once, and a frame is
-- solved on plain numbers. Each engine Vector/Angle/VMatrix and every
-- LocalToWorld/WorldToLocal is a C call plus a userdata allocation; the solver
-- used to make thousands of them per frame. The scalar helpers reproduce
-- mathlib's AngleMatrix / MatrixAngles / VectorAngles, including the Angle
-- round trips the object version took between steps, so results match it.
local FAST_BUILD_VERIFY_EPSILON = 0.5

local function fast_build_enabled()
    return convar_bool("mmd_vmd_npc_fast_build", true)
end

-- (Helpers are scoped in do-blocks: this file's main chunk is near Lua's
-- 200-local limit.)
local fast_compile_solver, fast_solve_frame
do
    local DEG_TO_RAD = math.pi / 180
    local RAD_TO_DEG = 180 / math.pi
    local m_sin, m_cos, m_atan2, m_sqrt, m_acos = math.sin, math.cos, math.atan2, math.sqrt, math.acos

    -- Row-major 3x3 rotation; columns are forward, left, up (mathlib AngleMatrix).
    local function set_angle_matrix(m, p, y, r)
        p, y, r = p * DEG_TO_RAD, y * DEG_TO_RAD, r * DEG_TO_RAD
        local sp, cp = m_sin(p), m_cos(p)
        local sy, cy = m_sin(y), m_cos(y)
        local sr, cr = m_sin(r), m_cos(r)
        m[1] = cp * cy
        m[2] = sr * sp * cy - cr * sy
        m[3] = cr * sp * cy + sr * sy
        m[4] = cp * sy
        m[5] = sr * sp * sy + cr * cy
        m[6] = cr * sp * sy - sr * cy
        m[7] = -sp
        m[8] = sr * cp
        m[9] = cr * cp
        return m
    end

    -- mathlib MatrixAngles from the forward column (m1, m4, m7), the left column
    -- (m2, m5, m8) and up.z (m9).
    local function matrix_angles(m1, m2, m4, m5, m7, m8, m9)
        local xy = m_sqrt(m1 * m1 + m4 * m4)
        if xy > 0.001 then
            return m_atan2(-m7, xy) * RAD_TO_DEG, m_atan2(m4, m1) * RAD_TO_DEG, m_atan2(m8, m9) * RAD_TO_DEG
        end
        return m_atan2(-m7, xy) * RAD_TO_DEG, m_atan2(-m2, m5) * RAD_TO_DEG, 0
    end

    -- One component of clean_angle.
    local function clean_degrees(value)
        value = (value + 180) % 360 - 180
        if value < 0.00001 and value > -0.00001 then return 0 end
        return value
    end

    local function angle_object_matrix(ang)
        return set_angle_matrix({}, ang.p or 0, ang.y or 0, ang.r or 0)
    end

    local VMATRIX_META = FindMetaTable and FindMetaTable("VMatrix") or nil
    local vmatrix_unpack = VMATRIX_META and VMATRIX_META.Unpack or nil

    -- VMatrix:Unpack returns the 16 entries row by row: forward column 1/5/9, left
    -- 2/6/10, up 3/7/11, translation 4/8/12. Checked once against the per-axis
    -- getters so a different layout can only cost speed, never correctness.
    local vmatrixUnpackOK = nil

    local function calibrate_vmatrix_unpack(matrix)
        vmatrixUnpackOK = false
        if not vmatrix_unpack or not matrix.GetForward or not matrix.GetUp or not matrix.GetTranslation then return end
        local e11, _, e13, e14, e21, _, e23, e24, e31, _, e33, e34 = vmatrix_unpack(matrix)
        local f, u, t = matrix:GetForward(), matrix:GetUp(), matrix:GetTranslation()
        local function near(a, b) return type(a) == "number" and math.abs(a - b) <= 0.0001 end
        vmatrixUnpackOK = near(e11, f.x) and near(e21, f.y) and near(e31, f.z)
            and near(e13, u.x) and near(e23, u.y) and near(e33, u.z)
            and near(e14, t.x) and near(e24, t.y) and near(e34, t.z)
    end

    -- Returns the forward column, left column, up.z and translation of a bone's
    -- world matrix, or nil when the engine has no matrix for it.
    local function read_bone_matrix(ent, bone)
        local matrix = ent:GetBoneMatrix(bone)
        if not matrix then return nil end
        if vmatrixUnpackOK == nil then calibrate_vmatrix_unpack(matrix) end
        if vmatrixUnpackOK then
            local e11, e12, _, e14, e21, e22, _, e24, e31, e32, e33, e34 = vmatrix_unpack(matrix)
            return e11, e12, e21, e22, e31, e32, e33, e14, e24, e34
        end
        local f, u, t = matrix:GetForward(), matrix:GetUp(), matrix:GetTranslation()
        local fx, fy, fz, ux, uy, uz = f.x, f.y, f.z, u.x, u.y, u.z
        -- left = up x forward (orthonormal basis), so no reliance on GetRight's sign.
        return fx, uy * fz - uz * fy, fy, uz * fx - ux * fz, fz, ux * fy - uy * fx, uz, t.x, t.y, t.z
    end

    local function bone_translation(ent, bone)
        local matrix = ent.GetBoneMatrix and ent:GetBoneMatrix(bone) or nil
        if matrix then
            local t = matrix:GetTranslation()
            return t.x, t.y, t.z
        end
        if ent.GetBonePosition then
            local pos = ent:GetBonePosition(bone)
            if pos then return pos.x, pos.y, pos.z end
        end
        return 0, 0, 0
    end

    local function fast_solver_unsafe(job)
        job.fastUnsafe = true
        job.fastSolver = nil
        return nil
    end

    -- Captures the dummy's reference skeleton and compiles everything a frame
    -- needs. Returns nil (and marks the job for the legacy path) when the closed
    -- form cannot represent this skeleton.
    fast_compile_solver = function(job, dummy)
        local model = dummy:GetModel() or ""
        local refOk, referenceInfo = force_reference_pose(dummy)
        referenceInfo = referenceInfo or lookup_reference_sequence_info(dummy)
        clear_all_bone_manipulations(dummy)
        dummy.MMDVMDNPCManipOwner = nil

        -- Only measure a skeleton that is provably AT its reference pose; a
        -- failed reference pose would measure some mid-animation pose and could
        -- false-trigger on an A-pose model.
        local armCorrections = refOk and arm_reference_corrections(dummy) or nil
        if armCorrections then
            for _, correction in pairs(armCorrections) do
                print(string.format("[MMD VMD] Non-standard reference arm pose on %s: re-inclining %s by %.1f° to the standard A-pose.",
                    model, correction.boneName or "upper arm", correction.degrees))
            end
        end

        local restLocal = {}
        local captureAng = dummy:GetAngles()
        local boneCount = dummy.GetBoneCount and dummy:GetBoneCount() or 0
        for bone = 0, boneCount - 1 do
            local matrix = dummy.GetBoneMatrix and dummy:GetBoneMatrix(bone) or nil
            if matrix then
                local _, localAng = WorldToLocal(ZERO_VECTOR, matrix:GetAngles(), ZERO_VECTOR, captureAng)
                restLocal[bone] = localAng
            end
        end

        local solver = {
            ent = dummy,
            model = model,
            idlenoise = reference_basis_is_idlenoise(referenceInfo),
            rows = {},
            verifyBones = {},
            flexRows = {},
            cur = {},
            seen = {},
            stamp = 0,
            base = {},
            corrected = {},
            check = {},
            entMatrix = {},
            appliedAng = {},
            appliedPos = {},
            bonesByID = {},
            flexesByID = {},
        }

        local pelvisBone = dummy.LookupBone and dummy:LookupBone(SOURCE_PELVIS) or nil
        local spineBone = dummy.LookupBone and dummy:LookupBone(SOURCE_SPINE) or nil
        if pelvisBone and spineBone then
            local sx, sy, sz = bone_translation(dummy, spineBone)
            local px, py, pz = bone_translation(dummy, pelvisBone)
            solver.refSpineX, solver.refSpineY, solver.refSpineZ = sx - px, sy - py, sz - pz
            solver.spineCorrection = spine_pelvis_correction_enabled(job.options) and dummy.ManipulateBonePosition ~= nil
        end
        solver.pelvisBone, solver.spineBone = pelvisBone, spineBone

        local bySource = {}
        local rows = {}
        for index, track in ipairs(job.boneTracks or {}) do
            local source = track.source or ""
            local info = bySource[source]
            if info == nil then
                local bone = dummy.LookupBone and dummy:LookupBone(source) or nil
                info = {
                    bone = bone or false,
                    depth = bone and bone_depth(dummy, bone) or 999999,
                }
                bySource[source] = info
            end
            rows[index] = {
                index = index,
                offset = (index - 1) * 6,
                source = source,
                mmd = track.mmd or "",
                role = track.role or "",
                bone = info.bone or nil,
                depth = info.depth,
                resolved = info.bone ~= false and info.bone ~= nil,
            }
        end

        -- Parents before children: the same traversal order the legacy path uses.
        table.sort(rows, function(a, b)
            if a.resolved ~= b.resolved then return a.resolved end
            if a.depth ~= b.depth then return a.depth < b.depth end
            if (a.bone or 999999) ~= (b.bone or 999999) then return (a.bone or 999999) < (b.bone or 999999) end
            return (a.index or 0) < (b.index or 0)
        end)

        local tracked = {}
        for _, row in ipairs(rows) do
            if row.resolved then tracked[row.bone] = true end
        end

        for _, row in ipairs(rows) do
            if row.resolved then
                local bone = row.bone
                local rest = restLocal[bone]
                if not rest then return fast_solver_unsafe(job) end

                local parent = dummy.GetBoneParent and dummy:GetBoneParent(bone) or -1
                local guard = 0
                while parent and parent >= 0 and guard < 512 do
                    if tracked[parent] then break end
                    parent = dummy:GetBoneParent(parent)
                    guard = guard + 1
                end
                if parent and parent >= 0 and tracked[parent] then
                    if not restLocal[parent] then return fast_solver_unsafe(job) end
                    local _, rel = WorldToLocal(ZERO_VECTOR, rest, ZERO_VECTOR, restLocal[parent])
                    row.anc = parent
                    row.rel = angle_object_matrix(rel)
                end
                row.rest = angle_object_matrix(rest)

                row.disabled = transforms_disabled_for_source(row.source, job.options)
                row.runtimeSpine = spine_pelvis_correction_enabled(job.options) and row_uses_runtime_spine_position(row)
                local correction = armCorrections and armCorrections[bone] or nil
                if correction then row.arm = angle_object_matrix(correction.localDelta) end

                if not solver.cur[bone] then
                    solver.cur[bone] = {}
                    solver.verifyBones[#solver.verifyBones + 1] = bone
                end
                solver.rows[#solver.rows + 1] = row
                solver.bonesByID[bone] = {
                    id = bone,
                    name = row.source,
                    source = row.source,
                    mmd = row.mmd,
                    role = row.role,
                }
            end
        end

        -- Same packets as merged_flex_packets: every model flex gets one slot
        -- (first-use order) that sums the tracks driving it.
        local flexBase = #(job.boneTracks or {}) * 6
        local slotByFlex = {}
        solver.flexTargets, solver.flexSums = {}, {}
        for index, track in ipairs(job.flexTracks or {}) do
            if track.resolved then
                local scale = flex_scale_for_row({
                    mmd = track.mmd,
                    source = track.source,
                    resolvedName = track.resolvedName,
                }, job.flexScales)
                local slots = {}
                for t, flexID in ipairs(flex_row_ids(track)) do
                    if flexID and flexID >= 0 then
                        local slot = slotByFlex[flexID]
                        if not slot then
                            slot = #solver.flexTargets + 1
                            slotByFlex[flexID] = slot
                            solver.flexTargets[slot] = flexID
                        end
                        slots[#slots + 1] = slot
                        local name = track.flexNames and track.flexNames[t] or track.resolvedName or ""
                        solver.flexesByID[flexID] = {
                            id = flexID,
                            name = name,
                            source = track.source or "",
                            mmd = track.mmd or "",
                            resolved = name,
                        }
                    end
                end
                if #slots > 0 then
                    solver.flexRows[#solver.flexRows + 1] = {
                        offset = flexBase + index,
                        scale = scale,
                        slots = slots,
                    }
                end
            end
        end

        -- jigglebones are leaf chains (hair, cloth) that never feed a tracked bone,
        -- but SetupBones simulates every one of them on every call. Playback
        -- force-disables jiggle anyway (sv_commands disable_all_bone_jiggle).
        if dummy.ManipulateBoneJiggle then
            for bone = 0, boneCount - 1 do
                dummy:ManipulateBoneJiggle(bone, 2)
            end
        end

        job.fastSolver = solver
        return solver
    end

    -- Skips the engine call when the bone already holds this manipulation.
    local function fast_apply_manipulation(solver, dummy, bone, p, y, r, x, yy, z)
        local pos = solver.appliedPos[bone]
        if not pos or pos[1] ~= x or pos[2] ~= yy or pos[3] ~= z then
            dummy:ManipulateBonePosition(bone, scratch_vector(x, yy, z))
            if pos then
                pos[1], pos[2], pos[3] = x, yy, z
            else
                solver.appliedPos[bone] = { x, yy, z }
            end
        end
        local ang = solver.appliedAng[bone]
        if not ang or ang[1] ~= p or ang[2] ~= y or ang[3] ~= r then
            dummy:ManipulateBoneAngles(bone, scratch_angle(p, y, r), false)
            if ang then
                ang[1], ang[2], ang[3] = p, y, r
            else
                solver.appliedAng[bone] = { p, y, r }
            end
        end
    end

    -- values: one frame's sampled tracks (6 per bone track: x, y, z, px, py, pz,
    -- then one weight per flex track). Returns the frame in built-cache form, or
    -- nil when the engine disagrees with the closed form.
    fast_solve_frame = function(job, solver, dummy, values, frameNumber)
        if dummy.MMDVMDNPCManipOwner ~= solver then
            -- Something else posed the dummy since this solver last ran; forget
            -- what we think it holds so every manipulation is re-sent.
            solver.appliedAng, solver.appliedPos = {}, {}
            dummy.MMDVMDNPCManipOwner = solver
        end

        local entAng = dummy:GetAngles()
        local E = set_angle_matrix(solver.entMatrix, entAng.p or 0, entAng.y or 0, entAng.r or 0)
        local e1, e2, e3, e4, e5, e6, e7, e8, e9 = E[1], E[2], E[3], E[4], E[5], E[6], E[7], E[8], E[9]
        -- Model axes: X = Forward (column 1), Y = Right (minus column 2), Z = Up.
        local xx, xy, xz = e1, e4, e7
        local yx, yy, yz = -e2, -e5, -e8
        local zx, zy, zz = e3, e6, e9

        local idlenoise = solver.idlenoise
        local cur, seen = solver.cur, solver.seen
        local base, corrected = solver.base, solver.corrected
        local stamp = solver.stamp + 1
        solver.stamp = stamp

        local pelvisBone = solver.pelvisBone
        local pelvisPacket, pelvisMp, pelvisMy, pelvisMr
        local bones, packetByBone = {}, {}
        local rows = solver.rows

        for i = 1, #rows do
            local row = rows[i]
            local bone = row.bone

            -- Baseline: rest orientation re-parented through the nearest tracked
            -- ancestor solved this frame (else through the entity).
            local P, R
            local anc = row.anc
            if anc ~= nil and seen[anc] == stamp then
                P, R = cur[anc], row.rel
            else
                P, R = E, row.rest
            end
            local p1, p2, p3, p4, p5, p6, p7, p8, p9 = P[1], P[2], P[3], P[4], P[5], P[6], P[7], P[8], P[9]
            local r1, r2, r3, r4, r5, r6, r7, r8, r9 = R[1], R[2], R[3], R[4], R[5], R[6], R[7], R[8], R[9]
            local bp, byw, br = matrix_angles(
                p1 * r1 + p2 * r4 + p3 * r7, p1 * r2 + p2 * r5 + p3 * r8,
                p4 * r1 + p5 * r4 + p6 * r7, p4 * r2 + p5 * r5 + p6 * r8,
                p7 * r1 + p8 * r4 + p9 * r7, p7 * r2 + p8 * r5 + p9 * r8,
                p7 * r3 + p8 * r6 + p9 * r9)
            set_angle_matrix(base, bp, byw, br)

            local D = cur[bone]
            seen[bone] = stamp
            if row.disabled then
                for k = 1, 9 do D[k] = base[k] end
            else
                local o = row.offset
                local dx, dy, dz = -values[o + 2], -values[o + 1], values[o + 3]
                local px, py, pz = values[o + 4], values[o + 5], values[o + 6]
                if idlenoise then
                    dx, dy = -dy, dx
                    px, py = -py, px
                end
                if row.runtimeSpine then px, py, pz = 0, 0, 0 end

                -- Desired composes on the (possibly T-pose-corrected) baseline;
                -- the manip stays a delta against the REAL baseline, so the
                -- engine lands exactly on desired and self-verification holds.
                local B = base
                local L = row.arm
                if L then
                    local cp, cy, cr = matrix_angles(
                        base[1] * L[1] + base[2] * L[4] + base[3] * L[7], base[1] * L[2] + base[2] * L[5] + base[3] * L[8],
                        base[4] * L[1] + base[5] * L[4] + base[6] * L[7], base[4] * L[2] + base[5] * L[5] + base[6] * L[8],
                        base[7] * L[1] + base[8] * L[4] + base[9] * L[7], base[7] * L[2] + base[8] * L[5] + base[9] * L[8],
                        base[7] * L[3] + base[8] * L[6] + base[9] * L[9])
                    B = set_angle_matrix(corrected, cp, cy, cr)
                end

                -- rotate_angle_around_sequential_model_axes: forward and up
                -- rotated about the model Y, then X, then Z axis (Rodrigues).
                local fx, fy, fz = B[1], B[4], B[7]
                local ux, uy, uz = B[3], B[6], B[9]
                if dy >= 0.00001 or dy <= -0.00001 then
                    local c, s = m_cos(dy * DEG_TO_RAD), m_sin(dy * DEG_TO_RAD)
                    local t = 1 - c
                    local d = (yx * fx + yy * fy + yz * fz) * t
                    fx, fy, fz = fx * c + (yy * fz - yz * fy) * s + yx * d, fy * c + (yz * fx - yx * fz) * s + yy * d, fz * c + (yx * fy - yy * fx) * s + yz * d
                    d = (yx * ux + yy * uy + yz * uz) * t
                    ux, uy, uz = ux * c + (yy * uz - yz * uy) * s + yx * d, uy * c + (yz * ux - yx * uz) * s + yy * d, uz * c + (yx * uy - yy * ux) * s + yz * d
                end
                if dx >= 0.00001 or dx <= -0.00001 then
                    local c, s = m_cos(dx * DEG_TO_RAD), m_sin(dx * DEG_TO_RAD)
                    local t = 1 - c
                    local d = (xx * fx + xy * fy + xz * fz) * t
                    fx, fy, fz = fx * c + (xy * fz - xz * fy) * s + xx * d, fy * c + (xz * fx - xx * fz) * s + xy * d, fz * c + (xx * fy - xy * fx) * s + xz * d
                    d = (xx * ux + xy * uy + xz * uz) * t
                    ux, uy, uz = ux * c + (xy * uz - xz * uy) * s + xx * d, uy * c + (xz * ux - xx * uz) * s + xy * d, uz * c + (xx * uy - xy * ux) * s + xz * d
                end
                if dz >= 0.00001 or dz <= -0.00001 then
                    local c, s = m_cos(dz * DEG_TO_RAD), m_sin(dz * DEG_TO_RAD)
                    local t = 1 - c
                    local d = (zx * fx + zy * fy + zz * fz) * t
                    fx, fy, fz = fx * c + (zy * fz - zz * fy) * s + zx * d, fy * c + (zz * fx - zx * fz) * s + zy * d, fz * c + (zx * fy - zy * fx) * s + zz * d
                    d = (zx * ux + zy * uy + zz * uz) * t
                    ux, uy, uz = ux * c + (zy * uz - zz * uy) * s + zx * d, uy * c + (zz * ux - zx * uz) * s + zy * d, uz * c + (zx * uy - zy * ux) * s + zz * d
                end
                local len = m_sqrt(fx * fx + fy * fy + fz * fz)
                if len > 0 then fx, fy, fz = fx / len, fy / len, fz / len end
                len = m_sqrt(ux * ux + uy * uy + uz * uz)
                if len > 0 then ux, uy, uz = ux / len, uy / len, uz / len end

                -- forward:AngleEx(up) (mathlib VectorAngles with a pseudo-up).
                local lx, ly, lz = uy * fz - uz * fy, uz * fx - ux * fz, ux * fy - uy * fx
                len = m_sqrt(lx * lx + ly * ly + lz * lz)
                if len > 0 then lx, ly, lz = lx / len, ly / len, lz / len end
                local xyDist = m_sqrt(fx * fx + fy * fy)
                local dp, dyw, dr
                if xyDist > 0.001 then
                    dp = m_atan2(-fz, xyDist) * RAD_TO_DEG
                    dyw = m_atan2(fy, fx) * RAD_TO_DEG
                    dr = m_atan2(lz, ly * fx - lx * fy) * RAD_TO_DEG
                else
                    dp = m_atan2(-fz, xyDist) * RAD_TO_DEG
                    dyw = m_atan2(-lx, ly) * RAD_TO_DEG
                    dr = 0
                end
                set_angle_matrix(D, clean_degrees(dp), clean_degrees(dyw), clean_degrees(dr))

                -- Manipulation = baseline^-1 * desired (WorldToLocal).
                local mp, my, mr = matrix_angles(
                    base[1] * D[1] + base[4] * D[4] + base[7] * D[7], base[1] * D[2] + base[4] * D[5] + base[7] * D[8],
                    base[2] * D[1] + base[5] * D[4] + base[8] * D[7], base[2] * D[2] + base[5] * D[5] + base[8] * D[8],
                    base[3] * D[1] + base[6] * D[4] + base[9] * D[7], base[3] * D[2] + base[6] * D[5] + base[9] * D[8],
                    base[3] * D[3] + base[6] * D[6] + base[9] * D[9])
                mp, my, mr = clean_degrees(mp), clean_degrees(my), clean_degrees(mr)

                local packet = packetByBone[bone]
                if not packet then
                    packet = { bone, 0, 0, 0, 0, 0, 0 }
                    packetByBone[bone] = packet
                    bones[#bones + 1] = packet
                end
                packet[2], packet[3], packet[4] = clean_degrees(mp), clean_degrees(my), clean_degrees(mr)
                packet[5], packet[6], packet[7] = px, py, pz
                if bone == pelvisBone then
                    pelvisPacket, pelvisMp, pelvisMy, pelvisMr = packet, mp, my, mr
                end
                row.mp, row.my, row.mr, row.px, row.py, row.pz = mp, my, mr, px, py, pz
            end
        end

        -- Engine calls only after the closed-form pass: C functions abort LuaJIT
        -- traces, so keeping them out of the loop above lets it compile. The solve
        -- never reads engine state, so deferring the manipulations changes nothing.
        for i = 1, #rows do
            local row = rows[i]
            if row.disabled then
                fast_apply_manipulation(solver, dummy, row.bone, 0, 0, 0, 0, 0, 0)
            else
                fast_apply_manipulation(solver, dummy, row.bone, row.mp, row.my, row.mr, row.px, row.py, row.pz)
            end
        end

        setup_bones_now(dummy)

        -- Self-verification: each solved bone's engine orientation (through the
        -- same GetAngles() round trip as before) against the closed form.
        local check = solver.check
        local spineBone = solver.spineBone
        local minDot = 2
        local spineX, spineY, spineZ, pelvisX, pelvisY, pelvisZ
        local verifyBones = solver.verifyBones
        for i = 1, #verifyBones do
            local bone = verifyBones[i]
            local m1, m2, m4, m5, m7, m8, m9, tx, ty, tz = read_bone_matrix(dummy, bone)
            if m1 then
                local ap, ay, ar = matrix_angles(m1, m2, m4, m5, m7, m8, m9)
                set_angle_matrix(check, ap, ay, ar)
                local D = cur[bone]
                local fdot = check[1] * D[1] + check[4] * D[4] + check[7] * D[7]
                local udot = check[3] * D[3] + check[6] * D[6] + check[9] * D[9]
                local dot = fdot < udot and fdot or udot
                if dot < minDot then minDot = dot end
                if bone == spineBone then spineX, spineY, spineZ = tx, ty, tz end
                if bone == pelvisBone then pelvisX, pelvisY, pelvisZ = tx, ty, tz end
            end
        end
        local maxError = 0
        if minDot < 1 then
            maxError = m_acos(minDot < -1 and -1 or minDot) * RAD_TO_DEG
        end
        if maxError > FAST_BUILD_VERIFY_EPSILON then
            job.fastUnsafe = true
            print(string.format(
                "[MMD VMD] fast build verification failed on %s (%.3f deg deviation); falling back to the legacy build path for this job",
                solver.model, maxError
            ))
            return nil
        end

        if solver.spineCorrection then
            if spineX == nil then spineX, spineY, spineZ = bone_translation(dummy, spineBone) end
            if pelvisX == nil then pelvisX, pelvisY, pelvisZ = bone_translation(dummy, pelvisBone) end
            local cwx = ((spineX - pelvisX) - solver.refSpineX) * -0.5
            local cwy = ((spineY - pelvisY) - solver.refSpineY) * -0.5
            local cwz = ((spineZ - pelvisZ) - solver.refSpineZ) * -0.5
            if cwx * cwx + cwy * cwy + cwz * cwz > 0.0000001 then
                -- World vector into the entity's frame (world_vector_to_entity_local).
                local nx = e1 * cwx + e4 * cwy + e7 * cwz
                local ny = e2 * cwx + e5 * cwy + e8 * cwz
                local nz = e3 * cwx + e6 * cwy + e9 * cwz
                local ap, ay, ar = 0, 0, 0
                if pelvisPacket then
                    nx, ny, nz = pelvisPacket[5] + nx, pelvisPacket[6] + ny, pelvisPacket[7] + nz
                    ap, ay, ar = pelvisMp, pelvisMy, pelvisMr
                else
                    pelvisPacket = { pelvisBone, 0, 0, 0, 0, 0, 0 }
                    packetByBone[pelvisBone] = pelvisPacket
                    bones[#bones + 1] = pelvisPacket
                end
                pelvisPacket[2], pelvisPacket[3], pelvisPacket[4] = clean_degrees(ap), clean_degrees(ay), clean_degrees(ar)
                pelvisPacket[5], pelvisPacket[6], pelvisPacket[7] = nx, ny, nz

                local pos = solver.appliedPos[pelvisBone]
                if not pos or pos[1] ~= nx or pos[2] ~= ny or pos[3] ~= nz then
                    dummy:ManipulateBonePosition(pelvisBone, scratch_vector(nx, ny, nz))
                    solver.appliedPos[pelvisBone] = { nx, ny, nz }
                end
            end
        end

        local flexTargets, sums = solver.flexTargets, solver.flexSums
        for i = 1, #flexTargets do sums[i] = nil end
        local flexRows = solver.flexRows
        for i = 1, #flexRows do
            local flex = flexRows[i]
            local weight = (values[flex.offset] or 0) * flex.scale
            if weight < 0 then weight = 0 elseif weight > 1 then weight = 1 end
            local slots = flex.slots
            for k = 1, #slots do
                local slot = slots[k]
                local sum = sums[slot]
                sums[slot] = sum and (sum + weight) or weight
            end
        end
        local flexes = {}
        for i = 1, #flexTargets do
            flexes[i] = { flexTargets[i], math.min(sums[i], 1) }
        end

        return {
            frame = math.max(0, math.floor(tonumber(frameNumber) or 0)),
            bones = bones,
            flexes = flexes,
        }
    end
end

-- One frame's flex packets: each resolved row's scaled weight goes to every
-- model flex it drives. Rows that drive the same flex add up (MMD morphs are
-- additive) and are clamped to the flex range, in first-use order. Before, a
-- second row on the same flex simply overwrote the first — a wink's zero
-- erased a smile on the shared eyelid.
local function merged_flex_packets(flexRows, flexScales)
    local order, sums = {}, {}
    for _, row in ipairs(flexRows or {}) do
        local weight = scaled_flex_weight(row, flexScales)
        if row.resolved then
            for _, flexID in ipairs(flex_row_ids(row)) do
                if flexID and flexID >= 0 then
                    if sums[flexID] == nil then
                        order[#order + 1] = flexID
                        sums[flexID] = weight
                    else
                        sums[flexID] = sums[flexID] + weight
                    end
                end
            end
        end
    end

    local packed = {}
    for i, flexID in ipairs(order) do
        packed[i] = {
            flexID = flexID,
            weight = math.min(sums[flexID], 1),
        }
    end
    return packed
end

-- buildOptions/flexScales: a build job's snapshots (legacy build fallback);
-- nil uses the live convars (debug preview).
local function rebuild_debug_preview(rows, flexRows, targetEntIndex, sendToServer, targetOverride, buildOptions, flexScales)
    local target = targetOverride or (targetEntIndex and targetEntIndex > 0 and Entity(targetEntIndex) or nil)
    if not IsValid(target) or not target.GetBoneCount then
        for _, row in ipairs(rows) do
            row.p = 0
            row.localYaw = 0
            row.r = 0
            row.resolved = false
        end
        return {}, {}
    end

    local refOk, referenceInfo = force_reference_pose(target)
    referenceInfo = referenceInfo or lookup_reference_sequence_info(target)
    clear_all_bone_manipulations(target)
    -- Reference pose must have taken (see fast_skeleton_for_dummy).
    local armCorrections = refOk and arm_reference_corrections(target) or nil

    local pelvisBone = target.LookupBone and target:LookupBone(SOURCE_PELVIS) or nil
    local spineBone = target.LookupBone and target:LookupBone(SOURCE_SPINE) or nil
    local referenceSpineVector = nil
    if pelvisBone and spineBone then
        referenceSpineVector = bone_world_position(target, spineBone) - bone_world_position(target, pelvisBone)
    end

    for index, row in ipairs(rows) do
        local bone = target.LookupBone and target:LookupBone(row.source or "") or nil
        row.index = index
        row.bone = bone
        row.depth = bone and bone_depth(target, bone) or 999999
        row.resolved = bone ~= nil
        row.p = 0
        row.localYaw = 0
        row.r = 0
    end

    table.sort(rows, function(a, b)
        if a.resolved ~= b.resolved then return a.resolved end
        if a.depth ~= b.depth then return a.depth < b.depth end
        if (a.bone or 999999) ~= (b.bone or 999999) then return (a.bone or 999999) < (b.bone or 999999) end
        return (a.index or 0) < (b.index or 0)
    end)

    -- This must run clientside: the conversion needs bone matrices after each
    -- already-applied parent manipulation, matching mmd_axis_bone_rotator.
    local packed = {}
    local packedByBone = {}
    local appliedAngles = {}
    local appliedPositions = {}
    local function remember_packet(bone, ang, pos)
        local packet = packedByBone[bone]
        if not packet then
            packet = { bone = bone, ang = ZERO_ANGLE, pos = ZERO_VECTOR }
            packedByBone[bone] = packet
            packed[#packed + 1] = packet
        end
        packet.ang = clean_angle(ang or ZERO_ANGLE)
        packet.pos = copy_vector(pos or ZERO_VECTOR)
    end

    for _, row in ipairs(rows) do
        if row.resolved then
            row.disabled = transforms_disabled_for_source(row.source, buildOptions)
            if row.disabled then
                row.p = 0
                row.localYaw = 0
                row.r = 0
            else
                local degrees = raw_axis_to_model_axis_degrees(row.x, row.y, row.z, referenceInfo)
                local position = transform_reference_vector_to_sequence_basis(Vector(row.px or 0, row.py or 0, row.pz or 0), referenceInfo)
                if spine_pelvis_correction_enabled(buildOptions) and row_uses_runtime_spine_position(row) then
                    position = Vector(0, 0, 0)
                    row.runtimePosition = true
                end
                local baseline = bone_baseline_angle(target, row.bone)
                local correction = armCorrections and armCorrections[row.bone] or nil
                local manip = compute_manip_angle_from_model_axes(target, row.bone, degrees, baseline, correction)

                row.p = manip.p or 0
                row.localYaw = manip.y or 0
                row.r = manip.r or 0
                appliedAngles[row.bone] = manip
                appliedPositions[row.bone] = position
                remember_packet(row.bone, manip, position)

                if not is_zero_vector(position) and target.ManipulateBonePosition then
                    target:ManipulateBonePosition(row.bone, position)
                end
                -- A T-pose-corrected bone needs its manip applied even for a
                -- zero-delta row: the correction itself is the rotation.
                if (not is_zero_degrees(degrees) or correction ~= nil) and target.ManipulateBoneAngles then
                    target:ManipulateBoneAngles(row.bone, manip, false)
                end
                if not is_zero_degrees(degrees) or correction ~= nil or not is_zero_vector(position) then
                    setup_bones_now(target)
                end
            end
        end
    end

    if spine_pelvis_correction_enabled(buildOptions) and pelvisBone and spineBone and referenceSpineVector and target.ManipulateBonePosition then
        setup_bones_now(target)

        local frameSpineVector = bone_world_position(target, spineBone) - bone_world_position(target, pelvisBone)
        local correctionWorld = (frameSpineVector - referenceSpineVector) * -0.5
        if not is_zero_vector(correctionWorld) then
            local correctionLocal = world_vector_to_entity_local(target, correctionWorld)
            local pelvisPosition = copy_vector(appliedPositions[pelvisBone]) + correctionLocal
            local pelvisAngle = appliedAngles[pelvisBone] or ZERO_ANGLE

            target:ManipulateBonePosition(pelvisBone, pelvisPosition)
            if target.ManipulateBoneAngles then
                target:ManipulateBoneAngles(pelvisBone, pelvisAngle, false)
            end
            setup_bones_now(target)

            remember_packet(pelvisBone, pelvisAngle, pelvisPosition)
        end
    end

    local flexPacked = merged_flex_packets(flexRows, flexScales)

    if sendToServer ~= false then
        send_debug_pose(target, packed, flexPacked)
    end
    return packed, flexPacked
end

local compute_build_frame
do
    -- Sampled build values back into the row tables the legacy path consumes.
    local function legacy_build_rows(job, values)
        local boneTracks = job.boneTracks or {}
        local rows = {}
        for index, track in ipairs(boneTracks) do
            local o = (index - 1) * 6
            rows[index] = {
                mmd = track.mmd,
                source = track.source,
                role = track.role,
                x = values[o + 1],
                y = values[o + 2],
                z = values[o + 3],
                px = values[o + 4],
                py = values[o + 5],
                pz = values[o + 6],
                resolved = track.resolved,
                bone = track.bone,
            }
        end

        local flexBase = #boneTracks * 6
        local flexRows = {}
        for index, track in ipairs(job.flexTracks or {}) do
            flexRows[index] = {
                mmd = track.mmd,
                source = track.source,
                resolvedName = track.resolvedName,
                weight = values[flexBase + index],
                flexID = track.flexID,
                flexIDs = track.flexIDs,
                flexNames = track.flexNames,
                resolved = track.resolved,
            }
        end
        return rows, flexRows
    end

    -- One build frame in built-cache form ({frame, bones, flexes}).
    compute_build_frame = function(job, dummy, values, frameNumber, targetEntIndex)
        if not job.fastUnsafe and fast_build_enabled() then
            local solver = job.fastSolver
            if not solver or solver.ent ~= dummy or solver.model ~= (dummy:GetModel() or "") then
                solver = fast_compile_solver(job, dummy)
            end
            local frame = solver and fast_solve_frame(job, solver, dummy, values, frameNumber)
            if frame then
                if job.metadataSolver ~= solver then
                    job.metadataSolver = solver
                    for id, meta in pairs(solver.bonesByID) do job.bonesByID[id] = meta end
                    for id, meta in pairs(solver.flexesByID) do job.flexesByID[id] = meta end
                end
                return frame
            end
        end

        local rows, flexRows = legacy_build_rows(job, values)
        local packed, flexPacked = rebuild_debug_preview(rows, flexRows, targetEntIndex, false, dummy, job.options, job.flexScales)
        dummy.MMDVMDNPCManipOwner = nil
        for _, row in ipairs(rows) do
            if row.resolved and row.bone then
                job.bonesByID[row.bone] = {
                    id = row.bone,
                    name = row.source or "",
                    source = row.source or "",
                    mmd = row.mmd or "",
                    role = row.role or "",
                }
            end
        end
        for _, row in ipairs(flexRows) do
            if row.resolved then
                for t, flexID in ipairs(flex_row_ids(row)) do
                    if flexID and flexID >= 0 then
                        local name = row.flexNames and row.flexNames[t] or row.resolvedName or ""
                        job.flexesByID[flexID] = {
                            id = flexID,
                            name = name,
                            source = row.source or "",
                            mmd = row.mmd or "",
                            resolved = name,
                        }
                    end
                end
            end
        end
        return packet_to_frame_data(frameNumber, packed, flexPacked)
    end
end

local function debug_flex_choice_label(row, index)
    local mmd = tostring(row and row.mmd or "")
    local source = tostring(row and row.source or "")
    local label = mmd ~= "" and mmd or source
    if mmd ~= "" and source ~= "" and mmd ~= source then
        label = mmd .. " -> " .. source
    end
    return string.format("%03d  %s", tonumber(index) or 0, label ~= "" and label or "?")
end

local function selected_debug_flex_row(frame)
    if not IsValid(frame) or not IsValid(frame.UnresolvedMorphCombo) then return nil end
    local key = frame.UnresolvedMorphCombo:GetValue()
    return frame.UnresolvedFlexChoices and frame.UnresolvedFlexChoices[key] or nil
end

-- "name #id" for every model flex a motion flex row drives.
local function flex_targets_text(row)
    if not row or not row.resolved then return "" end
    local parts = {}
    for t, flexID in ipairs(flex_row_ids(row)) do
        local name = row.flexNames and row.flexNames[t] or row.resolvedName or ""
        parts[#parts + 1] = tostring(name) .. " #" .. tostring(flexID)
    end
    return table.concat(parts, " + ")
end

local function update_flex_targets_label(frame)
    if not IsValid(frame) or not IsValid(frame.FlexTargetsLabel) then return end
    local row = selected_debug_flex_row(frame)
    local text = row and row.targetsText or ""
    frame.FlexTargetsLabel:SetText(text ~= "" and LF("mmd_vmd_npc.debug.flex_targets_fmt", text) or L("mmd_vmd_npc.debug.flex_targets_none"))
end

local function selected_debug_model_flex(frame)
    if not IsValid(frame) or not IsValid(frame.ModelFlexCombo) then return nil end
    local key = frame.ModelFlexCombo:GetValue()
    return frame.ModelFlexChoices and frame.ModelFlexChoices[key] or nil
end

local function refresh_flex_override_controls(frame, flexRows, targetEntIndex)
    if not IsValid(frame) or not IsValid(frame.UnresolvedMorphCombo) or not IsValid(frame.ModelFlexCombo) then return end

    -- Every debug response rebuilds these combos; without carrying the user's
    -- picks over, both reset to the FIRST choice — so after each mapping click
    -- the next Assign/Unassign/Clear silently acted on morph #001 / flex #0
    -- instead of the row the user chose ("the buttons do nothing").
    local prevMorph = frame.UnresolvedMorphCombo:GetValue()
    local prevFlex = frame.ModelFlexCombo:GetValue()

    frame.TargetEntIndex = targetEntIndex or 0
    frame.UnresolvedFlexChoices = {}
    frame.ModelFlexChoices = {}
    frame.UnresolvedMorphCombo:Clear()
    frame.ModelFlexCombo:Clear()

    local firstMotionFlex
    for index, row in ipairs(flexRows or {}) do
        local label = debug_flex_choice_label(row, index)
        frame.UnresolvedMorphCombo:AddChoice(label)
        frame.UnresolvedFlexChoices[label] = {
            mmd = tostring(row.mmd or ""),
            source = tostring(row.source or ""),
            resolved = row.resolved == true,
            resolvedName = tostring(row.resolvedName or ""),
            flexID = tonumber(row.flexID) or -1,
            targetsText = flex_targets_text(row),
        }
        firstMotionFlex = firstMotionFlex or label
    end

    if firstMotionFlex then
        local keepMorph = prevMorph ~= "" and frame.UnresolvedFlexChoices[prevMorph] ~= nil
        frame.UnresolvedMorphCombo:SetValue(keepMorph and prevMorph or firstMotionFlex)
        frame.UnresolvedMorphCombo:SetEnabled(true)
    else
        frame.UnresolvedMorphCombo:SetValue(L("mmd_vmd_npc.debug.no_motion_flex"))
        frame.UnresolvedMorphCombo:SetEnabled(false)
    end

    local ent = targetEntIndex and targetEntIndex > 0 and Entity(targetEntIndex) or nil
    local firstFlex
    if IsValid(ent) and ent.GetFlexNum and ent.GetFlexName then
        for flexID = 0, (ent:GetFlexNum() or 0) - 1 do
            local flexName = tostring(ent:GetFlexName(flexID) or "")
            if flexName ~= "" then
                local label = string.format("%s #%d", flexName, flexID)
                frame.ModelFlexCombo:AddChoice(label)
                frame.ModelFlexChoices[label] = flexName
                firstFlex = firstFlex or label
            end
        end
    end

    if firstFlex then
        local keepFlex = prevFlex ~= "" and frame.ModelFlexChoices[prevFlex] ~= nil
        frame.ModelFlexCombo:SetValue(keepFlex and prevFlex or firstFlex)
        frame.ModelFlexCombo:SetEnabled(true)
    else
        frame.ModelFlexCombo:SetValue(L("mmd_vmd_npc.debug.no_model_flex"))
        frame.ModelFlexCombo:SetEnabled(false)
    end

    local canAssign = firstMotionFlex ~= nil and firstFlex ~= nil and targetEntIndex and targetEntIndex > 0
    if IsValid(frame.AssignFlexOverride) then frame.AssignFlexOverride:SetEnabled(canAssign) end
    if IsValid(frame.AddFlexOverride) then frame.AddFlexOverride:SetEnabled(canAssign) end
    if IsValid(frame.RemoveFlexOverride) then frame.RemoveFlexOverride:SetEnabled(canAssign) end
    local canChangeMapping = firstMotionFlex ~= nil and targetEntIndex and targetEntIndex > 0
    if IsValid(frame.UnassignFlexOverride) then frame.UnassignFlexOverride:SetEnabled(canChangeMapping) end
    if IsValid(frame.ClearFlexOverride) then frame.ClearFlexOverride:SetEnabled(canChangeMapping) end
    update_flex_targets_label(frame)
end

local function request_flex_override(frame, mode)
    if not IsValid(frame) then return end

    local row = selected_debug_flex_row(frame)
    if not row then return end

    local ent = frame.TargetEntIndex and Entity(frame.TargetEntIndex) or nil
    if not IsValid(ent) then return end

    -- save = drive only the selected flex; add/remove edit the set of flexes
    -- the morph drives.
    local editsFlexList = mode == "save" or mode == "add" or mode == "remove"
    local flexName = editsFlexList and selected_debug_model_flex(frame) or ""
    if editsFlexList and (not flexName or flexName == "") then return end

    local message = "mmdvmd_flex_override_save"
    if mode == "clear" then
        message = "mmdvmd_flex_override_clear"
    elseif mode == "unassign" then
        message = "mmdvmd_flex_override_unassign"
    end

    net.Start(message)
        net.WriteEntity(ent)
        net.WriteString(tostring(frame.MotionID or ""))
        net.WriteString(tostring(row.mmd or ""))
        net.WriteString(tostring(row.source or ""))
        if editsFlexList then
            net.WriteString(tostring(flexName or ""))
            net.WriteString(mode == "save" and "set" or mode)
        end
    net.SendToServer()

    timer.Simple(0.2, function()
        if IsValid(frame) then
            MMDVMDNPC.OpenDebugMenu(frame.MotionID, frame.ActiveFrame or frame.RequestedFrame or 0)
        end
    end)
end

local function update_debug_preview_play_buttons(frame)
    if not IsValid(frame) then return end

    local playing = frame.DebugPreviewPlaying == true
    if IsValid(frame.PlayPreview) then
        frame.PlayPreview:SetEnabled(not playing)
    end
    if IsValid(frame.PausePreview) then
        frame.PausePreview:SetEnabled(playing)
    end
end

local function set_debug_preview_playing(frame, playing)
    if not IsValid(frame) then return end

    frame.DebugPreviewPlaying = playing == true
    if not frame.DebugPreviewPlaying then
        timer.Remove(DEBUG_PREVIEW_TIMER)
    end
    update_debug_preview_play_buttons(frame)
end

local function schedule_debug_preview_next(frame, fps)
    if not IsValid(frame) or frame.DebugPreviewPlaying ~= true then return end

    local delay = 1 / math.max(1, tonumber(fps) or MMDVMDNPC.VMDFPS or 30)
    timer.Remove(DEBUG_PREVIEW_TIMER)
    timer.Create(DEBUG_PREVIEW_TIMER, delay, 1, function()
        local activeFrame = MMDVMDNPC.DebugFrame
        if not IsValid(activeFrame) or activeFrame.DebugPreviewPlaying ~= true then return end

        local endFrame = tonumber(activeFrame.EndFrame) or 0
        local nextFrame = tonumber(activeFrame.NextFrame) or ((tonumber(activeFrame.ActiveFrame) or 0) + 1)
        if nextFrame > endFrame then
            set_debug_preview_playing(activeFrame, false)
            return
        end

        MMDVMDNPC.OpenDebugMenu(activeFrame.MotionID, nextFrame)
    end)
end

local function start_debug_preview_playback(frame)
    if not IsValid(frame) then return end

    set_debug_preview_playing(frame, true)
    local startFrame = tonumber(frame.StartFrame) or 0
    local endFrame = tonumber(frame.EndFrame) or startFrame
    local activeFrame = tonumber(frame.ActiveFrame) or DEBUG_REFERENCE_FRAME
    local nextFrame

    if activeFrame < startFrame or activeFrame >= endFrame then
        nextFrame = startFrame
    else
        nextFrame = tonumber(frame.NextFrame) or (activeFrame + 1)
    end

    MMDVMDNPC.OpenDebugMenu(frame.MotionID, math.Clamp(math.floor(nextFrame), startFrame, endFrame))
end

-- Camera animation debug panel -------------------------------------------------
-- Shows the imported camera's entity-local position/rotation/fov at the debug
-- window's current frame, previews it through CalcView (anchored on the debug
-- target), and exposes the global camera transform tuning convars.

-- The default Derma frame body is a light grey; several debug labels use the
-- skin's default (also light) text colour and become nearly invisible on it.
-- Paint a known dark body under the content and force light text so the debug
-- readouts are legible regardless of the active Derma skin.
-- Light body + black text: a dark body left every UNstyled child widget
-- (checkbox labels, combo boxes, list headers) rendering the skin's dark default
-- text on a dark background, i.e. invisible. A light body makes every widget —
-- styled or not — readable, and styled labels below use near-black text.
local DEBUG_TEXT_COLOR = Color(20, 20, 20)

local function paint_dark_frame_body(self, w, h)
    derma.SkinHook("Paint", "Frame", self, w, h)
    surface.SetDrawColor(236, 238, 242, 255)
    surface.DrawRect(4, 24, w - 8, h - 28)
end

local function style_debug_label(panel, color, bold)
    if not IsValid(panel) then return end
    local font = bold and "MMDVMDNPCDebugBold" or "MMDVMDNPCDebugText"
    if panel.SetTextColor then panel:SetTextColor(color or DEBUG_TEXT_COLOR) end
    if panel.SetFont then panel:SetFont(font) end
    if panel.Label then
        if panel.Label.SetTextColor then panel.Label:SetTextColor(color or DEBUG_TEXT_COLOR) end
        if panel.Label.SetFont then panel.Label:SetFont(font) end
    end
end

-- Scale a debug DListView: row height + bold column headers track the menu scale.
local function style_debug_list(list)
    if not IsValid(list) then return end
    if list.SetDataHeight then list:SetDataHeight(math.floor(18 * MMDVMDNPC.MenuScale())) end
    if list.Columns then
        for _, col in ipairs(list.Columns) do
            if IsValid(col) then
                if col.SetFont then col:SetFont("MMDVMDNPCDebugBold") end
                if col.Header and IsValid(col.Header) and col.Header.SetFont then col.Header:SetFont("MMDVMDNPCDebugBold") end
            end
        end
    end
end

-- Apply the scaled debug font to a freshly added DListView row's cells.
local function style_debug_list_line(line)
    if IsValid(line) and line.Columns then
        for _, cell in ipairs(line.Columns) do
            if IsValid(cell) and cell.SetFont then cell:SetFont("MMDVMDNPCDebugText") end
        end
    end
    return line
end

function MMDVMDNPC.CloseCameraDebugPanel()
    MMDVMDNPC.CameraDebugPreview = nil
    local panel = MMDVMDNPC.CameraDebugPanel
    MMDVMDNPC.CameraDebugPanel = nil
    if IsValid(panel) then panel:Remove() end
end

function MMDVMDNPC.OpenCameraDebugPanel(debugFrame)
    if not IsValid(debugFrame) then return end
    MMDVMDNPC.CloseCameraDebugPanel()

    local motionID = tostring(debugFrame.MotionID or "")
    if motionID == "" then return end

    -- Fetch the camera keys for this motion (no playback attached).
    local function request_camera_track()
        net.Start("mmdvmd_camera_debug_request")
            net.WriteString(motionID)
        net.SendToServer()
    end
    request_camera_track()

    MMDVMDNPC.CameraDebugPreview = { motionID = motionID }

    local panel = vgui.Create("DFrame")
    MMDVMDNPC.CameraDebugPanel = panel
    -- Distinguish "no reply yet" from "the motion has no camera": the server
    -- answers camera-less motions with an empty begin, which fires this hook
    -- with a nil track. Retry a few times in case the request hit the server's
    -- rate-limit cooldown.
    panel.ReplyReceived = false
    panel.RequestsSent = 1
    panel.NextRequestAt = SysTime() + 2
    local hookID = "MMDVMDNPCCameraDebugReply" .. tostring(panel)
    hook.Add("MMDVMDNPCCameraDebugTrackUpdated", hookID, function(replyMotionID)
        if tostring(replyMotionID or "") == motionID and IsValid(panel) then
            panel.ReplyReceived = true
        end
    end)
    panel.OnRemove = function()
        hook.Remove("MMDVMDNPCCameraDebugTrackUpdated", hookID)
    end
    panel:SetTitle(LF("mmd_vmd_npc.camera.debug_title_fmt", motionID))
    panel.Paint = paint_dark_frame_body
    local cameraMenuScale = MMDVMDNPC.MenuScale()
    panel:SetSize(math.min(math.floor(420 * cameraMenuScale), ScrW() - 40), math.min(math.floor(430 * cameraMenuScale), ScrH() - 40))
    panel:SetPos(24, math.floor(ScrH() * 0.2))
    panel:SetSizable(true)
    panel:SetDeleteOnClose(true)
    panel.OnClose = function()
        MMDVMDNPC.CameraDebugPreview = nil
        MMDVMDNPC.CameraDebugPanel = nil
        if IsValid(debugFrame) and IsValid(debugFrame.CameraPreview) then
            debugFrame.CameraPreview:SetValue(0)
        end
    end

    local values = vgui.Create("DLabel", panel)
    values:Dock(TOP)
    values:DockMargin(8, 4, 8, 4)
    values:SetTall(84)
    values:SetWrap(true)
    values:SetAutoStretchVertical(false)
    values:SetText(L("mmd_vmd_npc.camera.debug_waiting"))
    style_debug_label(values)

    local help = vgui.Create("DLabel", panel)
    help:Dock(TOP)
    help:DockMargin(8, 0, 8, 4)
    help:SetTall(48)
    help:SetWrap(true)
    help:SetText(L("mmd_vmd_npc.camera.debug_help"))
    style_debug_label(help, Color(70, 70, 70))

    local scroll = vgui.Create("DScrollPanel", panel)
    scroll:Dock(FILL)

    local function add_slider(labelKey, cvarName, minValue, maxValue, decimals)
        local slider = vgui.Create("DNumSlider", scroll)
        slider:Dock(TOP)
        slider:DockMargin(8, 0, 8, 2)
        slider:SetTall(30)
        slider:SetText(L(labelKey))
        slider:SetMin(minValue)
        slider:SetMax(maxValue)
        slider:SetDecimals(decimals)
        slider:SetConVar(cvarName)
        style_debug_label(slider)
        return slider
    end

    add_slider("mmd_vmd_npc.camera.scale_x", "mmd_vmd_npc_cam_scale_x", 0.25, 4, 2)
    add_slider("mmd_vmd_npc.camera.scale_y", "mmd_vmd_npc_cam_scale_y", 0.25, 4, 2)
    add_slider("mmd_vmd_npc.camera.scale_z", "mmd_vmd_npc_cam_scale_z", 0.25, 4, 2)
    add_slider("mmd_vmd_npc.camera.offset_x", "mmd_vmd_npc_cam_offset_x", -200, 200, 1)
    add_slider("mmd_vmd_npc.camera.offset_y", "mmd_vmd_npc_cam_offset_y", -200, 200, 1)
    add_slider("mmd_vmd_npc.camera.offset_z", "mmd_vmd_npc_cam_offset_z", -200, 200, 1)
    add_slider("mmd_vmd_npc.camera.yaw", "mmd_vmd_npc_cam_yaw", -180, 180, 1)
    add_slider("mmd_vmd_npc.camera.pitch", "mmd_vmd_npc_cam_pitch", -89, 89, 1)
    add_slider("mmd_vmd_npc.camera.fov_offset", "mmd_vmd_npc_cam_fov", -30, 30, 1)
    add_slider("mmd_vmd_npc.camera.max_distance", "mmd_vmd_npc_cam_max_distance", 0, 3000, 0)

    local collision = vgui.Create("DCheckBoxLabel", scroll)
    collision:Dock(TOP)
    collision:DockMargin(8, 4, 8, 2)
    collision:SetText(L("mmd_vmd_npc.camera.collision"))
    collision:SetConVar("mmd_vmd_npc_cam_collision")
    style_debug_label(collision)

    local reset = vgui.Create("DButton", scroll)
    reset:Dock(TOP)
    reset:DockMargin(8, 4, 8, 8)
    reset:SetTall(26)
    reset:SetText(L("mmd_vmd_npc.camera.reset_transform"))
    reset.DoClick = function()
        RunConsoleCommand("mmd_vmd_npc_cam_scale", "1")
        RunConsoleCommand("mmd_vmd_npc_cam_scale_x", "1")
        RunConsoleCommand("mmd_vmd_npc_cam_scale_y", "1")
        RunConsoleCommand("mmd_vmd_npc_cam_scale_z", "1")
        RunConsoleCommand("mmd_vmd_npc_cam_offset_x", "0")
        RunConsoleCommand("mmd_vmd_npc_cam_offset_y", "0")
        RunConsoleCommand("mmd_vmd_npc_cam_offset_z", "0")
        RunConsoleCommand("mmd_vmd_npc_cam_yaw", "0")
        RunConsoleCommand("mmd_vmd_npc_cam_pitch", "0")
        RunConsoleCommand("mmd_vmd_npc_cam_fov", "0")
    end

    panel.Think = function(self)
        -- Follow the debug window's lifetime; it is a singleton that can be
        -- retargeted to another motion, in which case this panel is stale.
        if not IsValid(debugFrame) or tostring(debugFrame.MotionID or "") ~= motionID then
            self:Close()
            return
        end
        if not IsValid(values) then return end

        local now = SysTime()
        if (self.NextValueUpdate or 0) > now then return end
        self.NextValueUpdate = now + 0.1

        local track = MMDVMDNPC.CameraDebugTrackFor and MMDVMDNPC.CameraDebugTrackFor(motionID) or nil
        if not track then
            if self.ReplyReceived then
                values:SetText(L("mmd_vmd_npc.camera.debug_none"))
            else
                values:SetText(L("mmd_vmd_npc.camera.debug_waiting"))
                -- The request may have been eaten by the server-side cooldown;
                -- retry a few times before giving up.
                if now >= (self.NextRequestAt or 0) and (self.RequestsSent or 0) < 5 then
                    self.RequestsSent = (self.RequestsSent or 0) + 1
                    self.NextRequestAt = now + 2
                    request_camera_track()
                end
            end
            return
        end

        local frame = math.max(0, tonumber(debugFrame.ActiveFrame) or 0)
        local sample = MMDVMDNPC.CameraDebugSample(motionID, frame)
        if not sample then
            values:SetText(L("mmd_vmd_npc.camera.debug_none"))
            return
        end

        local anchor = MMDVMDNPC.CameraDebugAnchor and MMDVMDNPC.CameraDebugAnchor() or nil
        values:SetText(LF(
            "mmd_vmd_npc.camera.debug_values_fmt",
            frame,
            sample.x, sample.y, sample.z,
            sample.p, sample.yw, sample.r,
            sample.fov,
            IsValid(anchor) and tostring(anchor) or L("mmd_vmd_npc.ui.none")
        ))
    end
end

function MMDVMDNPC.OpenDebugMenu(motionID, vmdFrame)
    motionID = tostring(motionID or "")
    if motionID == "" then return end

    MMDVMDNPC.DebugMenuWanted = true
    vmdFrame = math.max(DEBUG_REFERENCE_FRAME, math.floor(tonumber(vmdFrame) or DEBUG_REFERENCE_FRAME))

    local frame = MMDVMDNPC.DebugFrame
    if not IsValid(frame) then
        frame = vgui.Create("DFrame")
        MMDVMDNPC.DebugFrame = frame
        local screenW = ScrW and ScrW() or 1280
        local screenH = ScrH and ScrH() or 720
        local menuScale = MMDVMDNPC.MenuScale()
        frame:SetSize(math.min(screenW - 40, math.floor(1360 * menuScale)), math.min(screenH - 40, math.floor(800 * menuScale)))
        frame:Center()
        frame:MakePopup()
        frame.Paint = paint_dark_frame_body
        frame.OnClose = function()
            set_debug_preview_playing(frame, false)
            -- No more debug frames wanted: an in-flight response arriving
            -- after this must not silently reopen the window.
            MMDVMDNPC.DebugMenuWanted = false
            -- Tell the server so it drops the held flex pose and restores the
            -- target's clean reference state (unless a dance is playing).
            net.Start("mmdvmd_debug_close")
            net.SendToServer()
        end

        frame.TargetModelLabel = vgui.Create("DLabel", frame)
        frame.TargetModelLabel:Dock(TOP)
        frame.TargetModelLabel:DockMargin(8, 6, 8, 0)
        frame.TargetModelLabel:SetTall(math.floor(22 * MMDVMDNPC.MenuScale()))
        frame.TargetModelLabel:SetTextColor(Color(30, 90, 170))
        frame.TargetModelLabel:SetFont("MMDVMDNPCDebugBold")
        frame.TargetModelLabel:SetText(L("mmd_vmd_npc.debug.selected_model_none"))

        frame.Summary = vgui.Create("DLabel", frame)
        frame.Summary:Dock(TOP)
        frame.Summary:DockMargin(8, 2, 8, 4)
        frame.Summary:SetTall(38)
        frame.Summary:SetWrap(true)

        frame.Rows = vgui.Create("DListView", frame)
        frame.Rows:Dock(FILL)
        -- Dock last (highest ZPos) so the bone list fills the space left after
        -- the five BOTTOM strips reserve theirs, instead of underlapping them.
        frame.Rows:SetZPos(100)
        frame.Rows:AddColumn(L("mmd_vmd_npc.debug.column_mmd_bone"))
        frame.Rows:AddColumn(L("mmd_vmd_npc.debug.column_source_bone"))
        frame.Rows:AddColumn(L("mmd_vmd_npc.debug.column_role"))
        frame.Rows:AddColumn(L("mmd_vmd_npc.debug.column_raw_x"))
        frame.Rows:AddColumn(L("mmd_vmd_npc.debug.column_raw_y"))
        frame.Rows:AddColumn(L("mmd_vmd_npc.debug.column_raw_z"))
        frame.Rows:AddColumn(L("mmd_vmd_npc.debug.column_bone_position"))
        frame.Rows:AddColumn(L("mmd_vmd_npc.debug.column_manip_angles"))

        frame.FlexRows = vgui.Create("DListView", frame)
        frame.FlexRows:Dock(BOTTOM)
        frame.FlexRows:SetTall(150)
        frame.FlexRows:AddColumn(L("mmd_vmd_npc.debug.column_mmd_morph"))
        frame.FlexRows:AddColumn(L("mmd_vmd_npc.debug.column_source_flex"))
        frame.FlexRows:AddColumn(L("mmd_vmd_npc.debug.column_weight"))
        frame.FlexRows:AddColumn(L("mmd_vmd_npc.debug.column_scaled_weight"))
        frame.FlexRows:AddColumn(L("mmd_vmd_npc.debug.column_target"))
        style_debug_list(frame.Rows)
        style_debug_list(frame.FlexRows)
        frame.FlexRows.OnRowSelected = function(_, _, line)
            if not IsValid(frame.UnresolvedMorphCombo) or not line then return end
            local mmd = line:GetColumnText(1)
            local source = line:GetColumnText(2)
            for label, row in pairs(frame.UnresolvedFlexChoices or {}) do
                if row.mmd == mmd and row.source == source then
                    frame.UnresolvedMorphCombo:SetValue(label)
                    update_flex_targets_label(frame)
                    return
                end
            end
        end

        local flexOverride = vgui.Create("DPanel", frame)
        flexOverride:Dock(BOTTOM)
        flexOverride:SetTall(84)

        frame.FlexOverrideTitle = vgui.Create("DLabel", flexOverride)
        frame.FlexOverrideTitle:Dock(TOP)
        frame.FlexOverrideTitle:SetTall(20)
        frame.FlexOverrideTitle:SetText(L("mmd_vmd_npc.debug.flex_mapping"))

        -- Morph picker on a fixed left slot, model flex picker filling the
        -- rest; the action buttons get their own row so five of them still fit
        -- a narrow (800px) debug window.
        local flexOverrideRow = vgui.Create("DPanel", flexOverride)
        flexOverrideRow:Dock(TOP)
        flexOverrideRow:SetTall(26)

        frame.UnresolvedMorphCombo = vgui.Create("DComboBox", flexOverrideRow)
        frame.UnresolvedMorphCombo:Dock(LEFT)
        frame.UnresolvedMorphCombo:SetZPos(1)
        frame.UnresolvedMorphCombo:SetWide(260)
        frame.UnresolvedMorphCombo:SetTooltip(L("mmd_vmd_npc.debug.motion_flex"))
        frame.UnresolvedMorphCombo.OnSelect = function()
            update_flex_targets_label(frame)
        end

        frame.ModelFlexCombo = vgui.Create("DComboBox", flexOverrideRow)
        frame.ModelFlexCombo:Dock(FILL)
        frame.ModelFlexCombo:SetZPos(100)
        frame.ModelFlexCombo:DockMargin(6, 0, 0, 0)
        frame.ModelFlexCombo:SetTooltip(L("mmd_vmd_npc.debug.model_flex"))

        local flexOverrideButtons = vgui.Create("DPanel", flexOverride)
        flexOverrideButtons:Dock(FILL)
        flexOverrideButtons:DockMargin(0, 4, 0, 0)

        local function add_mapping_button(labelKey, tooltipKey, mode)
            local button = vgui.Create("DButton", flexOverrideButtons)
            button:Dock(LEFT)
            button:DockMargin(0, 0, 6, 0)
            button:SetText(L(labelKey))
            button:SizeToContentsX(20)
            button:SetWide(math.max(90, button:GetWide()))
            if tooltipKey then button:SetTooltip(L(tooltipKey)) end
            button.DoClick = function()
                request_flex_override(frame, mode)
            end
            return button
        end

        frame.AssignFlexOverride = add_mapping_button("mmd_vmd_npc.debug.assign_flex", "mmd_vmd_npc.debug.assign_flex_tip", "save")
        frame.AddFlexOverride = add_mapping_button("mmd_vmd_npc.debug.add_flex", "mmd_vmd_npc.debug.add_flex_tip", "add")
        frame.RemoveFlexOverride = add_mapping_button("mmd_vmd_npc.debug.remove_flex", "mmd_vmd_npc.debug.remove_flex_tip", "remove")
        frame.UnassignFlexOverride = add_mapping_button("mmd_vmd_npc.debug.unassign_flex", nil, "unassign")
        frame.ClearFlexOverride = add_mapping_button("mmd_vmd_npc.debug.clear_flex_mapping", nil, "clear")

        -- Every model flex the selected morph currently drives.
        frame.FlexTargetsLabel = vgui.Create("DLabel", flexOverrideButtons)
        frame.FlexTargetsLabel:Dock(FILL)
        frame.FlexTargetsLabel:DockMargin(4, 0, 0, 0)
        frame.FlexTargetsLabel:SetText(L("mmd_vmd_npc.debug.flex_targets_none"))

        local flexScalePanel = vgui.Create("DPanel", frame)
        flexScalePanel:Dock(BOTTOM)
        flexScalePanel:SetTall(64)

        local function refresh_after_flex_scale_change()
            timer.Create("MMDVMDNPCDebugFlexScaleRefresh", 0.15, 1, function()
                if IsValid(frame) then
                    MMDVMDNPC.OpenDebugMenu(frame.MotionID, frame.ActiveFrame or frame.RequestedFrame or 0)
                end
            end)
        end

        local function add_flex_scale_slider(parent, label, cvarName)
            local slider = vgui.Create("DNumSlider", parent)
            slider:Dock(LEFT)
            slider:SetWide(320)
            slider:SetText(label)
            slider:SetConVar(cvarName)
            slider:SetMinMax(0, 3)
            slider:SetDecimals(2)
            slider:SetValue(convar_float(cvarName, 1))
            slider.OnValueChanged = refresh_after_flex_scale_change
            return slider
        end

        local flexScaleRow1 = vgui.Create("DPanel", flexScalePanel)
        flexScaleRow1:Dock(TOP)
        flexScaleRow1:SetTall(32)
        local flexScaleRow2 = vgui.Create("DPanel", flexScalePanel)
        flexScaleRow2:Dock(FILL)

        frame.FlexScaleAll = add_flex_scale_slider(flexScaleRow1, L("mmd_vmd_npc.debug.flex_scale_all"), "mmd_vmd_npc_flex_scale_all")
        frame.FlexScaleEye = add_flex_scale_slider(flexScaleRow1, L("mmd_vmd_npc.debug.flex_scale_eye"), "mmd_vmd_npc_flex_scale_eye")
        frame.FlexScaleBrow = add_flex_scale_slider(flexScaleRow2, L("mmd_vmd_npc.debug.flex_scale_brow"), "mmd_vmd_npc_flex_scale_brow")
        frame.FlexScaleMouth = add_flex_scale_slider(flexScaleRow2, L("mmd_vmd_npc.debug.flex_scale_mouth"), "mmd_vmd_npc_flex_scale_mouth")

        local options = vgui.Create("DPanel", frame)
        options:Dock(BOTTOM)
        options:SetTall(28)

        frame.DisableArmTwist = vgui.Create("DCheckBoxLabel", options)
        frame.DisableArmTwist:Dock(LEFT)
        frame.DisableArmTwist:SetWide(260)
        frame.DisableArmTwist:SetText(L("mmd_vmd_npc.ui.disable_armtwist"))
        frame.DisableArmTwist:SetConVar("mmd_vmd_npc_disable_armtwist")
        frame.DisableArmTwist:SetValue(convar_bool("mmd_vmd_npc_disable_armtwist", false) and 1 or 0)
        frame.DisableArmTwist:SizeToContents()
        frame.DisableArmTwist.OnChange = function()
            MMDVMDNPC.OpenDebugMenu(frame.MotionID, frame.ActiveFrame or frame.RequestedFrame or 0)
        end

        frame.DisableHandTwist = vgui.Create("DCheckBoxLabel", options)
        frame.DisableHandTwist:Dock(LEFT)
        frame.DisableHandTwist:SetWide(260)
        frame.DisableHandTwist:SetText(L("mmd_vmd_npc.ui.disable_handtwist"))
        frame.DisableHandTwist:SetConVar("mmd_vmd_npc_disable_handtwist")
        frame.DisableHandTwist:SetValue(convar_bool("mmd_vmd_npc_disable_handtwist", false) and 1 or 0)
        frame.DisableHandTwist:SizeToContents()
        frame.DisableHandTwist.OnChange = function()
            MMDVMDNPC.OpenDebugMenu(frame.MotionID, frame.ActiveFrame or frame.RequestedFrame or 0)
        end

        frame.DisableEyes = vgui.Create("DCheckBoxLabel", options)
        frame.DisableEyes:Dock(LEFT)
        frame.DisableEyes:SetWide(220)
        frame.DisableEyes:SetText(L("mmd_vmd_npc.ui.disable_eyes"))
        frame.DisableEyes:SetConVar("mmd_vmd_npc_disable_eyes")
        frame.DisableEyes:SetValue(convar_bool("mmd_vmd_npc_disable_eyes", false) and 1 or 0)
        frame.DisableEyes:SizeToContents()
        frame.DisableEyes.OnChange = function()
            MMDVMDNPC.OpenDebugMenu(frame.MotionID, frame.ActiveFrame or frame.RequestedFrame or 0)
        end

        frame.DisableSpinePelvis = vgui.Create("DCheckBoxLabel", options)
        frame.DisableSpinePelvis:Dock(LEFT)
        frame.DisableSpinePelvis:SetWide(310)
        frame.DisableSpinePelvis:SetText(L("mmd_vmd_npc.ui.disable_spine_pelvis"))
        frame.DisableSpinePelvis:SetConVar("mmd_vmd_npc_disable_spine_pelvis_correction")
        frame.DisableSpinePelvis:SetValue(convar_bool("mmd_vmd_npc_disable_spine_pelvis_correction", false) and 1 or 0)
        frame.DisableSpinePelvis:SizeToContents()
        frame.DisableSpinePelvis.OnChange = function()
            MMDVMDNPC.OpenDebugMenu(frame.MotionID, frame.ActiveFrame or frame.RequestedFrame or 0)
        end

        frame.CameraPreview = vgui.Create("DCheckBoxLabel", options)
        frame.CameraPreview:Dock(LEFT)
        frame.CameraPreview:DockMargin(8, 0, 0, 0)
        frame.CameraPreview:SetWide(240)
        frame.CameraPreview:SetText(L("mmd_vmd_npc.camera.debug_preview"))
        frame.CameraPreview:SetValue(0)
        frame.CameraPreview:SizeToContents()
        frame.CameraPreview.OnChange = function(_, checked)
            if checked then
                MMDVMDNPC.OpenCameraDebugPanel(frame)
            else
                MMDVMDNPC.CloseCameraDebugPanel()
            end
        end

        local controls = vgui.Create("DPanel", frame)
        controls:Dock(BOTTOM)
        controls:SetTall(36)

        frame.Prev = vgui.Create("DButton", controls)
        frame.Prev:Dock(LEFT)
        frame.Prev:SetWide(100)
        frame.Prev:SetText(L("mmd_vmd_npc.debug.previous"))
        frame.Prev.DoClick = function()
            MMDVMDNPC.OpenDebugMenu(frame.MotionID, frame.PrevFrame or frame.ActiveFrame or 0)
        end

        frame.JumpButton = vgui.Create("DButton", controls)
        frame.JumpButton:Dock(LEFT)
        frame.JumpButton:SetWide(90)
        frame.JumpButton:SetText(L("mmd_vmd_npc.debug.jump"))
        frame.JumpButton.DoClick = function()
            local target = IsValid(frame.FrameEntry) and tonumber(frame.FrameEntry:GetValue()) or nil
            if target then
                MMDVMDNPC.OpenDebugMenu(frame.MotionID, math.max(DEBUG_REFERENCE_FRAME, math.floor(target)))
            end
        end

        frame.FrameEntry = vgui.Create("DTextEntry", controls)
        frame.FrameEntry:Dock(LEFT)
        frame.FrameEntry:SetWide(110)
        frame.FrameEntry:SetNumeric(false)
        frame.FrameEntry:SetPlaceholderText(L("mmd_vmd_npc.debug.vmd_frame"))
        frame.FrameEntry.OnEnter = function(entry)
            local target = tonumber(entry:GetValue())
            if target then
                MMDVMDNPC.OpenDebugMenu(frame.MotionID, math.max(DEBUG_REFERENCE_FRAME, math.floor(target)))
            end
        end

        frame.PlayPreview = vgui.Create("DButton", controls)
        frame.PlayPreview:Dock(LEFT)
        frame.PlayPreview:DockMargin(6, 0, 0, 0)
        frame.PlayPreview:SetWide(90)
        frame.PlayPreview:SetText(L("mmd_vmd_npc.debug.play_preview"))
        frame.PlayPreview.DoClick = function()
            start_debug_preview_playback(frame)
        end

        frame.PausePreview = vgui.Create("DButton", controls)
        frame.PausePreview:Dock(LEFT)
        frame.PausePreview:DockMargin(6, 0, 0, 0)
        frame.PausePreview:SetWide(90)
        frame.PausePreview:SetText(L("mmd_vmd_npc.debug.pause_preview"))
        frame.PausePreview:SetEnabled(false)
        frame.PausePreview.DoClick = function()
            set_debug_preview_playing(frame, false)
        end

        frame.Next = vgui.Create("DButton", controls)
        frame.Next:Dock(RIGHT)
        frame.Next:SetWide(100)
        frame.Next:SetText(L("mmd_vmd_npc.debug.next"))
        frame.Next.DoClick = function()
            MMDVMDNPC.OpenDebugMenu(frame.MotionID, frame.NextFrame or frame.ActiveFrame or 0)
        end

        frame.Refresh = vgui.Create("DButton", controls)
        frame.Refresh:Dock(FILL)
        frame.Refresh:SetText(L("mmd_vmd_npc.debug.refresh"))
        frame.Refresh.DoClick = function()
            MMDVMDNPC.OpenDebugMenu(frame.MotionID, frame.ActiveFrame or 0)
        end

        -- Light text on the dark body painted above (Derma's default label
        -- colour is near-invisible on it).
        style_debug_label(frame.Summary)
        style_debug_label(frame.FlexOverrideTitle)
        style_debug_label(frame.FlexTargetsLabel)
        style_debug_label(frame.DisableArmTwist)
        style_debug_label(frame.DisableHandTwist)
        style_debug_label(frame.DisableEyes)
        style_debug_label(frame.DisableSpinePelvis)
        style_debug_label(frame.CameraPreview)
        style_debug_label(frame.FlexScaleAll)
        style_debug_label(frame.FlexScaleEye)
        style_debug_label(frame.FlexScaleBrow)
        style_debug_label(frame.FlexScaleMouth)
    end

    frame.MotionID = motionID
    frame.RequestedFrame = vmdFrame
    frame:SetTitle(LF("mmd_vmd_npc.debug.title_fmt", motionID))
    request_debug(motionID, vmdFrame)
end

local function read_frame_payload()
    local startFrame = net.ReadInt(32)
    local endFrame = net.ReadInt(32)
    local activeFrame = net.ReadInt(32)
    local prevFrame = net.ReadInt(32)
    local nextFrame = net.ReadInt(32)
    local fps = net.ReadUInt(16)
    local duration = net.ReadFloat()
    local targetEntIndex = net.ReadUInt(16)
    local referenceSeq = net.ReadInt(16)
    local referenceName = net.ReadString()
    local referenceBasis = net.ReadString()
    local referenceAxisText = net.ReadString()
    local count = net.ReadUInt(16)
    local rows = {}

    for i = 1, count do
        rows[i] = {
            mmd = net.ReadString(),
            source = net.ReadString(),
            role = net.ReadString(),
            x = net.ReadFloat(),
            y = net.ReadFloat(),
            z = net.ReadFloat(),
            px = net.ReadFloat(),
            py = net.ReadFloat(),
            pz = net.ReadFloat(),
            p = net.ReadFloat(),
            localYaw = net.ReadFloat(),
            r = net.ReadFloat(),
            resolved = net.ReadBool(),
        }
    end
    local flexCount = net.ReadUInt(16)
    local flexRows = {}

    for i = 1, flexCount do
        local row = {
            mmd = net.ReadString(),
            source = net.ReadString(),
            resolvedName = net.ReadString(),
            weight = net.ReadFloat(),
            flexID = net.ReadInt(16),
            resolved = net.ReadBool(),
        }
        row.flexIDs, row.flexNames = {}, {}
        for t = 1, net.ReadUInt(8) do
            row.flexIDs[t] = net.ReadInt(16)
            row.flexNames[t] = net.ReadString()
        end
        flexRows[i] = row
    end

    local referenceInfo = {
        seq = referenceSeq,
        name = referenceName,
        basis = referenceBasis,
        axisText = referenceAxisText,
    }

    return startFrame, endFrame, activeFrame, prevFrame, nextFrame, fps, duration, targetEntIndex, referenceInfo, rows, flexRows
end

net.Receive("mmdvmd_debug_response", function()
    local ok = net.ReadBool()
    local motionID = net.ReadString()
    local err = net.ReadString()
    if not ok then
        print("[MMD VMD] " .. LF("mmd_vmd_npc.console.debug_failed_fmt", motionID, err))
        return
    end

    local startFrame, endFrame, activeFrame, prevFrame, nextFrame, fps, duration, targetEntIndex, referenceInfo, rows, flexRows = read_frame_payload()

    local frame = MMDVMDNPC.DebugFrame
    if not IsValid(frame) or frame.MotionID ~= motionID then
        -- Only (re)open for a wanted session: a response still in flight when
        -- the user closed the window must be dropped, not resurrect the menu
        -- (its rebuild_debug_preview would stomp a running dance's pose).
        if MMDVMDNPC.DebugMenuWanted then
            MMDVMDNPC.OpenDebugMenu(motionID, activeFrame)
        end
        return
    end

    frame.ActiveFrame = activeFrame
    frame.StartFrame = startFrame
    frame.EndFrame = endFrame
    frame.DebugFPS = fps
    frame.PrevFrame = prevFrame
    frame.NextFrame = nextFrame

    if IsValid(frame.TargetModelLabel) then
        local target = targetEntIndex and targetEntIndex > 0 and Entity(targetEntIndex) or nil
        local model = IsValid(target) and target.GetModel and target:GetModel() or ""
        if model ~= "" then
            frame.TargetModelLabel:SetText(LF("mmd_vmd_npc.debug.selected_model_fmt", model))
        else
            frame.TargetModelLabel:SetText(L("mmd_vmd_npc.debug.selected_model_none"))
        end
    end

    if IsValid(frame.FrameEntry) then
        frame.FrameEntry:SetValue(tostring(activeFrame))
    end

    rebuild_debug_preview(rows, flexRows, targetEntIndex, true)

    local referenceText = ""
    if referenceInfo and tostring(referenceInfo.name or "") ~= "" then
        local referenceLabel = string.format(
            "%s (#%s, %s)",
            tostring(referenceInfo.name or ""),
            tostring(referenceInfo.seq or "?"),
            tostring(referenceInfo.axisText or referenceInfo.basis or "")
        )
        referenceText = LF("mmd_vmd_npc.debug.reference_fmt", referenceLabel)
    end

    local activeSeconds = activeFrame == DEBUG_REFERENCE_FRAME and 0 or (activeFrame / math.max(1, fps))
    frame.Summary:SetText(LF(
        "mmd_vmd_npc.debug.summary_fmt",
        motionID,
        activeFrame,
        endFrame,
        activeSeconds,
        duration,
        #rows,
        #flexRows,
        (targetEntIndex > 0 and LF("mmd_vmd_npc.debug.preview_entity_fmt", tostring(targetEntIndex)) or "") .. referenceText
    ))

    frame.Rows:Clear()
    for _, row in ipairs(rows) do
        style_debug_list_line(frame.Rows:AddLine(
            row.mmd,
            row.source,
            row.role,
            fmt_num(row.x),
            fmt_num(row.y),
            fmt_num(row.z),
            fmt_vec(row.px, row.py, row.pz),
            row.disabled and "disabled"
                or (row.resolved and fmt_angle(row.p, row.localYaw, row.r) or "unresolved")
        ))
    end

    if IsValid(frame.FlexRows) then
        -- Preserve the scroll position across the rebuild: Clear() snaps the
        -- list back to the top, so the row a mapping click just changed (often
        -- deep in the 37-row list) scrolled out of view — making the change
        -- invisible and the buttons look dead.
        local flexScrollBar = frame.FlexRows.VBar
        local flexScroll = IsValid(flexScrollBar) and flexScrollBar:GetScroll() or 0
        frame.FlexRows:Clear()
        for _, row in ipairs(flexRows) do
            style_debug_list_line(frame.FlexRows:AddLine(
                row.mmd,
                row.source,
                fmt_num(row.weight),
                fmt_num(row.scaledWeight ~= nil and row.scaledWeight or scaled_flex_weight(row)),
                row.resolved and flex_targets_text(row) or "unresolved"
            ))
        end
        if IsValid(flexScrollBar) and flexScroll > 0 then
            timer.Simple(0, function()
                if IsValid(frame) and IsValid(flexScrollBar) then
                    flexScrollBar:SetScroll(flexScroll)
                end
            end)
        end
    end
    refresh_flex_override_controls(frame, flexRows, targetEntIndex)

    frame.Prev:SetEnabled(activeFrame > DEBUG_REFERENCE_FRAME)
    frame.Next:SetEnabled(activeFrame < endFrame)
    update_debug_preview_play_buttons(frame)
    if frame.DebugPreviewPlaying == true then
        if activeFrame >= endFrame then
            set_debug_preview_playing(frame, false)
        else
            schedule_debug_preview_next(frame, fps)
        end
    end
end)

net.Receive("mmdvmd_build_progress", function()
    update_build_status({
        status = net.ReadString(),
        message = net.ReadString(),
        buildID = net.ReadUInt(32),
        motionID = net.ReadString(),
        model = net.ReadString(),
        currentFrame = net.ReadUInt(32),
        startFrame = net.ReadUInt(32),
        endFrame = net.ReadUInt(32),
        queued = net.ReadUInt(16),
    })
end)

net.Receive("mmdvmd_build_plan", function()
    local buildID = net.ReadUInt(32)
    local motionID = net.ReadString()
    local target = net.ReadEntity()
    local model = net.ReadString()
    local fps = net.ReadUInt(16)
    local startFrame = net.ReadUInt(32)
    local endFrame = net.ReadUInt(32)
    local startDelay = net.ReadFloat()
    local boneCount = net.ReadUInt(16)
    local boneTracks = {}

    show_build_lag_warning(buildID, motionID, startFrame, endFrame)

    -- Tracks whose rotation or position never changes are sent once here
    -- instead of in every frame of every batch.
    for i = 1, boneCount do
        local track = {
            mmd = net.ReadString(),
            source = net.ReadString(),
            role = net.ReadString(),
            resolved = net.ReadBool(),
            bone = net.ReadUInt(16),
        }
        track.animRot = net.ReadBool()
        if not track.animRot then
            track.cx = net.ReadFloat()
            track.cy = net.ReadFloat()
            track.cz = net.ReadFloat()
        end
        track.animPos = net.ReadBool()
        if not track.animPos then
            track.cpx = net.ReadFloat()
            track.cpy = net.ReadFloat()
            track.cpz = net.ReadFloat()
        end
        boneTracks[i] = track
    end

    local flexCount = net.ReadUInt(16)
    local flexTracks = {}
    for i = 1, flexCount do
        local track = {
            mmd = net.ReadString(),
            source = net.ReadString(),
            resolvedName = net.ReadString(),
            resolved = net.ReadBool(),
            flexID = net.ReadInt(16),
        }
        track.animated = net.ReadBool()
        if not track.animated then track.cw = net.ReadFloat() end
        track.flexIDs, track.flexNames = {}, {}
        for t = 1, net.ReadUInt(8) do
            track.flexIDs[t] = net.ReadInt(16)
            track.flexNames[t] = net.ReadString()
        end
        flexTracks[i] = track
    end

    -- The options the server builds (and names the cache file) with.
    local options = {}
    options.disableArmTwist = net.ReadBool()
    options.disableHandTwist = net.ReadBool()
    options.disableEyes = net.ReadBool()
    options.disableSpinePelvisCorrection = net.ReadBool()

    MMDVMDNPC.ClientBuildJobs[buildID] = {
        motionID = motionID,
        model = model,
        target = target,
        fps = fps,
        frame_start = startFrame,
        frame_end = endFrame,
        start_delay = startDelay,
        -- Indexed by frame - frame_start + 1, so a re-requested batch
        -- overwrites instead of duplicating frames.
        frames = {},
        bonesByID = {},
        flexesByID = {},
        boneTracks = boneTracks,
        flexTracks = flexTracks,
        options = options,
        flexScales = current_flex_scales(),
    }
end)

do
    -- Received batches wait here and the worker below solves one per frame. The
    -- server keeps several batches in flight, so while this client solves one the
    -- next is already on the way: network round trips overlap the solving
    -- instead of adding to it, and batches arriving together are still solved
    -- in separate frames.
    MMDVMDNPC.ClientBuildBatches = MMDVMDNPC.ClientBuildBatches or {}

    net.Receive("mmdvmd_build_compact_request", function()
        local buildID = net.ReadUInt(32)
        local firstFrame = net.ReadUInt(32)
        local batchCount = net.ReadUInt(8)
        local job = MMDVMDNPC.ClientBuildJobs[buildID]
        if not job then return end

        local boneTracks = job.boneTracks or {}
        local flexTracks = job.flexTracks or {}
        local boneCount, flexCount = #boneTracks, #flexTracks
        local flexBase = boneCount * 6
        local read_float = net.ReadFloat
        local values = {}
        for frame = 1, batchCount do
            local v = {}
            for i = 1, boneCount do
                local track = boneTracks[i]
                local o = (i - 1) * 6
                if track.animRot then
                    v[o + 1] = read_float()
                    v[o + 2] = read_float()
                    v[o + 3] = read_float()
                else
                    v[o + 1], v[o + 2], v[o + 3] = track.cx, track.cy, track.cz
                end
                if track.animPos then
                    v[o + 4] = read_float()
                    v[o + 5] = read_float()
                    v[o + 6] = read_float()
                else
                    v[o + 4], v[o + 5], v[o + 6] = track.cpx, track.cpy, track.cpz
                end
            end
            for i = 1, flexCount do
                local track = flexTracks[i]
                if track.animated then
                    v[flexBase + i] = read_float()
                else
                    v[flexBase + i] = track.cw
                end
            end
            values[frame] = v
        end

        local queue = MMDVMDNPC.ClientBuildBatches
        queue[#queue + 1] = {
            job = job,
            buildID = buildID,
            firstFrame = firstFrame,
            count = batchCount,
            values = values,
        }
    end)

    local function frame_matches_layout(frame, layout)
        local bones, layoutBones = frame.bones, layout.bones
        if #bones ~= #layoutBones then return false end
        for i = 1, #bones do
            if bones[i][1] ~= layoutBones[i][1] then return false end
        end
        local flexes, layoutFlexes = frame.flexes, layout.flexes
        if #flexes ~= #layoutFlexes then return false end
        for i = 1, #flexes do
            if flexes[i][1] ~= layoutFlexes[i][1] then return false end
        end
        return true
    end

    local BUILD_RESULT_BUDGET_BITS = 60000 * 8
    local NET_ANGLE_MAX_BITS = 66

    -- Results go back as one bone/flex layout per message followed by bare values,
    -- and positions only for bones that moved in this batch (every other bone's
    -- offset is exactly zero). A frame whose packet list differs from the layout
    -- is sent explicitly. Messages split before the 64KB net limit.
    local function send_build_results(buildID, firstFrame, frames)
        local count = #frames
        if count <= 0 then return end

        local layout = frames[1]
        local layoutBones, layoutFlexes = layout.bones, layout.flexes
        local boneCount, flexCount = #layoutBones, #layoutFlexes
        local matches, hasPos = {}, {}
        for i = 1, count do
            local frame = frames[i]
            local match = frame_matches_layout(frame, layout)
            matches[i] = match
            if match then
                local bones = frame.bones
                for j = 1, boneCount do
                    if not hasPos[j] then
                        local b = bones[j]
                        if b[5] ~= 0 or b[6] ~= 0 or b[7] ~= 0 then hasPos[j] = true end
                    end
                end
            end
        end
        local posCount = 0
        for j = 1, boneCount do
            if hasPos[j] then posCount = posCount + 1 end
        end
        local headerBits = 32 + 32 + 8 + 16 + boneCount * 17 + 16 + flexCount * 16
        local layoutFrameBits = 1 + boneCount * NET_ANGLE_MAX_BITS + posCount * 96 + flexCount * 32

        local index = 1
        while index <= count do
            local bits = headerBits
            local last = index - 1
            while last < count do
                local frame = frames[last + 1]
                local frameBits = matches[last + 1] and layoutFrameBits
                    or (1 + 16 + #frame.bones * (16 + NET_ANGLE_MAX_BITS + 96) + 16 + #frame.flexes * 48)
                if last >= index and bits + frameBits > BUILD_RESULT_BUDGET_BITS then break end
                bits = bits + frameBits
                last = last + 1
            end

            net.Start("mmdvmd_build_frame_result")
                net.WriteUInt(buildID, 32)
                net.WriteUInt(firstFrame + index - 1, 32)
                net.WriteUInt(last - index + 1, 8)
                net.WriteUInt(boneCount, 16)
                for j = 1, boneCount do
                    net.WriteUInt(layoutBones[j][1], 16)
                    net.WriteBool(hasPos[j] == true)
                end
                net.WriteUInt(flexCount, 16)
                for j = 1, flexCount do
                    net.WriteInt(layoutFlexes[j][1], 16)
                end
                for i = index, last do
                    local frame = frames[i]
                    local bones, flexes = frame.bones, frame.flexes
                    net.WriteBool(matches[i])
                    if matches[i] then
                        for j = 1, boneCount do
                            local b = bones[j]
                            net.WriteAngle(scratch_angle(b[2], b[3], b[4]))
                            if hasPos[j] then
                                net.WriteFloat(b[5])
                                net.WriteFloat(b[6])
                                net.WriteFloat(b[7])
                            end
                        end
                        for j = 1, flexCount do
                            net.WriteFloat(flexes[j][2])
                        end
                    else
                        local n = math.min(#bones, 4096)
                        net.WriteUInt(n, 16)
                        for j = 1, n do
                            local b = bones[j]
                            net.WriteUInt(b[1], 16)
                            net.WriteAngle(scratch_angle(b[2], b[3], b[4]))
                            net.WriteFloat(b[5])
                            net.WriteFloat(b[6])
                            net.WriteFloat(b[7])
                        end
                        local m = math.min(#flexes, 4096)
                        net.WriteUInt(m, 16)
                        for j = 1, m do
                            net.WriteInt(flexes[j][1], 16)
                            net.WriteFloat(flexes[j][2])
                        end
                    end
                end
            net.SendToServer()
            index = last + 1
        end
    end

    local function process_build_batch(batch)
        local job, buildID = batch.job, batch.buildID
        local visibleTarget = job.target
        -- Build from the plan's model string so a NULL/never-networked target does
        -- not yield an empty (all-bones-dropped) build that the server would cache.
        local dummy = build_dummy_for_model(job.model, visibleTarget)
        if not IsValid(dummy) then
            MMDVMDNPC.ClientBuildJobs[buildID] = nil
            destroy_build_dummy()
            net.Start("mmdvmd_build_cancel_request")
            net.SendToServer()
            print("[MMD VMD] " .. LF("mmd_vmd_npc.console.build_failed_fmt", "could not create a hidden model for '" .. tostring(job.model or "") .. "'"))
            return
        end

        local targetEntIndex = IsValid(visibleTarget) and visibleTarget:EntIndex() or 0
        local frameStart = job.frame_start or 0
        local frames = {}
        local lastFrame = batch.firstFrame
        for i = 1, batch.count do
            local frameNumber = batch.firstFrame + i - 1
            local frame = compute_build_frame(job, dummy, batch.values[i], frameNumber, targetEntIndex)
            frames[i] = frame
            local slot = frameNumber - frameStart + 1
            if slot >= 1 then job.frames[slot] = frame end
            lastFrame = frameNumber
        end

        update_build_status({
            status = "building",
            message = string.format("%s frame %d", job.motionID or "", lastFrame),
            buildID = buildID,
            motionID = job.motionID,
            model = job.model or "",
            currentFrame = lastFrame + 1,
            startFrame = frameStart,
            endFrame = job.frame_end or lastFrame,
            queued = MMDVMDNPC.BuildStatus and MMDVMDNPC.BuildStatus.queued or 0,
        })

        send_build_results(buildID, batch.firstFrame, frames)
    end

    hook.Add("Think", "MMDVMDNPCClientBuildWorker", function()
        local queue = MMDVMDNPC.ClientBuildBatches
        while queue[1] do
            local batch = table.remove(queue, 1)
            -- Batches of a finished or cancelled job are dropped unsolved.
            if MMDVMDNPC.ClientBuildJobs[batch.buildID] == batch.job then
                process_build_batch(batch)
                return
            end
        end
    end)
end

net.Receive("mmdvmd_target_status", function()
    local valid = net.ReadBool()
    local ent = net.ReadEntity()
    local model = net.ReadString()
    local targetType = net.ReadString()
    local message = net.ReadString()

    MMDVMDNPC.TargetStatus = {
        valid = valid,
        ent = ent,
        model = model,
        targetType = targetType,
        message = message,
    }
    hook.Run("MMDVMDNPCTargetStatusUpdated", MMDVMDNPC.TargetStatus)
    request_motion_details()
end)

net.Receive("mmdvmd_assignment_status", function()
    local count = net.ReadUInt(16)
    local order = {}
    local byEnt = {}

    for _ = 1, count do
        local ent = net.ReadEntity()
        local index = net.ReadUInt(16)
        local first = net.ReadBool()
        local motionID = net.ReadString()
        local model = net.ReadString()
        local status = net.ReadString()
        local row = {
            ent = ent,
            index = index,
            first = first,
            motionID = motionID,
            model = model,
            status = status,
        }
        if IsValid(ent) then
            order[#order + 1] = ent
            byEnt[ent] = row
        end
    end

    table.sort(order, function(a, b)
        local aa = byEnt[a] and byEnt[a].index or 0
        local bb = byEnt[b] and byEnt[b].index or 0
        return aa < bb
    end)

    MMDVMDNPC.AssignedActors = {
        order = order,
        byEnt = byEnt,
    }
    hook.Run("MMDVMDNPCAssignmentStatusUpdated", MMDVMDNPC.AssignedActors)
    request_motion_details()
end)

net.Receive("mmdvmd_build_done", function()
    local ok = net.ReadBool()
    local path = net.ReadString()
    local message = net.ReadString()
    local buildID = net.ReadUInt(32)

    -- buildID == 0 (or an id we do not track) is a notification unrelated to any
    -- in-flight streaming build (cache already exists, invalid request, queue
    -- message). It must NOT tear down a running build or the streaming job stalls
    -- and its partial frames get miscached under the wrong path.
    local job = buildID ~= 0 and MMDVMDNPC.ClientBuildJobs and MMDVMDNPC.ClientBuildJobs[buildID] or nil
    if job then
        if ok then
            -- The local replica is only usable when every frame is present
            -- (playback indexes frames by number); otherwise the server's
            -- networked pose plays alone.
            local frames = job.frames
            local complete = true
            for i = 1, math.max(0, (job.frame_end or 0) - (job.frame_start or 0) + 1) do
                if frames[i] == nil then
                    complete = false
                    break
                end
            end
            if complete then
                MMDVMDNPC.ClientBuiltCache[path] = {
                    format = MMDVMDNPC.BuiltFormat,
                    motion_id = job.motionID,
                    model = job.model or "",
                    fps = job.fps or MMDVMDNPC.VMDFPS or 30,
                    frame_start = job.frame_start or 0,
                    frame_end = job.frame_end or 0,
                    bones = sorted_client_metadata(job.bonesByID),
                    flexes = sorted_client_metadata(job.flexesByID),
                    frames = frames,
                }
            end
        end
        MMDVMDNPC.ClientBuildJobs[buildID] = nil
    end

    -- Only drop the hidden dummy once no client build jobs remain, so an
    -- unrelated notification during a build does not destroy the working dummy.
    if not next(MMDVMDNPC.ClientBuildJobs or {}) then
        destroy_build_dummy()
    end

    update_build_status({
        ok = ok,
        status = ok and "built" or "error",
        path = path,
        message = message,
        progress = ok and 1 or 0,
    })
    request_motion_details()
    play_ui_cue(ok and "success" or "blocked")
    print("[MMD VMD] " .. (ok and LF("mmd_vmd_npc.console.build_success_fmt", path) or LF("mmd_vmd_npc.console.build_failed_fmt", message)))
end)

net.Receive("mmdvmd_play_status", function()
    local status = net.ReadString()
    local message = net.ReadString()
    local playbackEnt = net.ReadEntity()
    -- net.WriteEntity resolves to NULL when the entity has not been networked
    -- to this client yet (net beats snapshots); the index both re-resolves
    -- that case and addresses the pending-start queue.
    local entIndex = net.ReadUInt(16)
    -- The server ticker's authoritative epoch for "playing"/resume statuses
    -- (0 for everything else) plus the server's CurTime at send. Anchoring by
    -- ELAPSED dance time — localStarted = CurTime() - (serverNow - started) —
    -- keeps the local poser on the server's dance timestamp even when the
    -- client's CurTime estimate carries a residual offset against the server
    -- clock (post-alt-tab clock correction), which used to become a permanent
    -- per-frame flicker between the two pose writers.
    local serverStarted = net.ReadDouble()
    local serverNow = net.ReadDouble()
    local anchoredStart = 0
    if serverStarted > 0 then
        anchoredStart = serverNow > 0 and (CurTime() - (serverNow - serverStarted)) or serverStarted
    end
    if not IsValid(playbackEnt) and entIndex > 0 then
        local resolved = Entity(entIndex)
        if IsValid(resolved) then playbackEnt = resolved end
    end

    MMDVMDNPC.PlayStatus = {
        status = status,
        message = message,
        ent = playbackEnt,
    }
    hook.Run("MMDVMDNPCPlayStatusUpdated", MMDVMDNPC.PlayStatus)
    MMDVMDNPC.ActivePlaybackEnts = MMDVMDNPC.ActivePlaybackEnts or {}
    if status == "playing" and IsValid(playbackEnt) then
        MMDVMDNPC.ActivePlaybackEnts[playbackEnt] = true
    elseif status == "stopped" or status == "finished" or status == "error" then
        if IsValid(playbackEnt) then
            MMDVMDNPC.ActivePlaybackEnts[playbackEnt] = nil
        end
    elseif status == "stopped_all" then
        MMDVMDNPC.ActivePlaybackEnts = {}
    end
    play_status_cue(status, message)

    if status == "playing" then
        if message == "playback resumed" then
            -- The authoritative epoch belongs to ONE dance: only apply it
            -- when the entity resolved. The unresolved-ent broadcast resume
            -- must stay measured-only, or it would stamp this dance's epoch
            -- onto every other local playback.
            resume_local_playback(playbackEnt, IsValid(playbackEnt) and anchoredStart or nil)
        elseif IsValid(playbackEnt) then
            -- A fresh authoritative start supersedes any stale pending for
            -- this index (a silently torn-down earlier dance never sends a
            -- stop, and a stale pending resolving later would overwrite this
            -- state with the OLD dance's clip and epoch).
            if entIndex > 0 then
                MMDVMDNPC.PendingLocalPlaybacks[entIndex] = nil
            end
            start_local_playback(message, playbackEnt, anchoredStart)
        else
            -- Entity not networked yet: retry from Think instead of guessing
            -- at a target (the old TargetStatus fallback orphaned states).
            queue_pending_local_playback(entIndex, message, anchoredStart)
        end
    elseif status == "paused" then
        pause_local_playback(playbackEnt)
    elseif status == "group_resumed" then
        resume_local_playback()
    elseif status == "countdown" then
        if is_local_self_playback_proxy(playbackEnt) then
            activate_self_proxy_camera(playbackEnt)
        end
    elseif status == "stopped" or status == "finished" or status == "error" then
        local clearPose = status == "stopped" or status == "error"
        if entIndex > 0 then
            MMDVMDNPC.PendingLocalPlaybacks[entIndex] = nil
        end
        if IsValid(playbackEnt) then
            stop_local_playback(clearPose, playbackEnt)
        else
            -- Per-entity stop whose entity is already gone: only drop dead local
            -- playbacks, never the player's other concurrent dances.
            for ent in pairs(MMDVMDNPC.LocalPlaybacks or {}) do
                if not IsValid(ent) then stop_one_local_playback(ent, clearPose) end
            end
        end
    elseif status == "stopped_all" then
        MMDVMDNPC.PendingLocalPlaybacks = {}
        stop_local_playback(true)
    elseif status == "self_reset" then
        if force_self_view_cleanup then
            force_self_view_cleanup()
        end
    elseif status == "missing_build" then
        chat.AddText(Color(255, 200, 0), "[MMD VMD] ", Color(255, 255, 255), tostring(message))
    end
end)

-- Periodic body-pose clock sync (every ~2s per playing dance): re-anchors the
-- local poser's epoch by elapsed dance time so a one-off delivery hitch (a
-- status that sat buffered through an alt-tab) or a residual client-clock
-- offset is corrected within seconds instead of flickering for the rest of
-- the dance; also the liveness signal for the orphan reaper.
net.Receive("mmdvmd_playback_sync", function()
    local entIndex = net.ReadUInt(16)
    local serverStarted = net.ReadDouble()
    local serverNow = net.ReadDouble()
    if entIndex <= 0 then return end
    local ent = Entity(entIndex)
    if not IsValid(ent) then return end
    local state = (MMDVMDNPC.LocalPlaybacks or {})[ent]
    if not state then return end
    state.lastServerSync = CurTime()
    if serverStarted > 0 and serverNow > 0 then
        -- Body syncs only flow while the server is PLAYING this entity, and
        -- net messages are ordered — so a sync is proof any local paused
        -- flag is wrong (a misaddressed broadcast pause): heal it instead of
        -- leaving this dance frozen on the networked pose.
        if state.paused then
            state.paused = false
            state.pauseStarted = nil
            state.nextTick = 0
        end
        state.started = CurTime() - (serverNow - serverStarted)
    end
end)

net.Receive("mmdvmd_clear_built_done", function()
    local ok = net.ReadBool()
    local removed = net.ReadUInt(16)
    local message = net.ReadString()
    local pending = MMDVMDNPC.PendingClearBuilt

    if ok and pending then
        for playbackEnt, localPlayback in pairs(MMDVMDNPC.LocalPlaybacks or {}) do
            local built = localPlayback and localPlayback.built or nil
            local motionMatches = built and tostring(built.motion_id or "") == tostring(pending.motionID or "")
            local modelMatches = built and (pending.scope == "all" or tostring(built.model or "") == tostring(pending.model or ""))
            if motionMatches and modelMatches then
                stop_local_playback(true, playbackEnt)
            end
        end

        for path, built in pairs(MMDVMDNPC.ClientBuiltCache or {}) do
            local motionMatches = tostring(built.motion_id or "") == tostring(pending.motionID or "")
            local modelMatches = pending.scope == "all" or tostring(built.model or "") == tostring(pending.model or "")
            if motionMatches and modelMatches then
                MMDVMDNPC.ClientBuiltCache[path] = nil
            end
        end
    end
    MMDVMDNPC.PendingClearBuilt = nil

    MMDVMDNPC.BuildStatus = {
        ok = ok,
        status = ok and "cleared" or "error",
        message = message,
        removed = removed,
    }
    hook.Run("MMDVMDNPCBuildStatusUpdated", MMDVMDNPC.BuildStatus)
    request_motion_details()
    play_ui_cue(ok and "success" or "blocked")
    print("[MMD VMD] " .. message)
end)

local function forget_client_motion(motionID)
    motionID = tostring(motionID or "")
    if motionID == "" then return end

    for i = #(MMDVMDNPC.ClientMotions or {}), 1, -1 do
        if tostring(MMDVMDNPC.ClientMotions[i] or "") == motionID then
            table.remove(MMDVMDNPC.ClientMotions, i)
        end
    end
    if MMDVMDNPC.MotionDetails then
        MMDVMDNPC.MotionDetails[motionID] = nil
    end
    for i = #(MMDVMDNPC.MotionDetailsOrdered or {}), 1, -1 do
        if tostring(MMDVMDNPC.MotionDetailsOrdered[i].id or "") == motionID then
            table.remove(MMDVMDNPC.MotionDetailsOrdered, i)
        end
    end
    if MMDVMDNPC.AudioOffsets then
        MMDVMDNPC.AudioOffsets[motionID] = nil
    end
    for path, built in pairs(MMDVMDNPC.ClientBuiltCache or {}) do
        if built and tostring(built.motion_id or "") == motionID then
            MMDVMDNPC.ClientBuiltCache[path] = nil
        end
    end
    -- Deleting a motion also takes it off the radial wheel: the manager can
    -- only toggle motions still in its list, so a leftover favorite would be
    -- unremovable from the UI. (ToggleFavorite REMOVES here because the id is
    -- present; it also persists and fires MMDVMDNPCWheelFavoritesChanged.)
    if MMDVMDNPC.IsFavorite and MMDVMDNPC.IsFavorite(motionID) and MMDVMDNPC.ToggleFavorite then
        MMDVMDNPC.ToggleFavorite(motionID)
    end

    local current = GetConVar("mmd_vmd_npc_motion")
    if current and current:GetString() == motionID then
        RunConsoleCommand("mmd_vmd_npc_motion", "")
    end
    hook.Run("MMDVMDNPCMotionListUpdated", MMDVMDNPC.ClientMotions or {})
    hook.Run("MMDVMDNPCMotionDetailsUpdated", MMDVMDNPC.MotionDetailsOrdered or {})
end

net.Receive("mmdvmd_delete_motion_done", function()
    local ok = net.ReadBool()
    local motionID = net.ReadString()
    local message = net.ReadString()
    local removedBuilt = net.ReadUInt(16)
    local musicPath = net.ReadString()
    local musicRemoved = net.ReadBool()

    if ok then
        forget_client_motion(motionID)
        request_list()
        request_motion_details()
    end

    play_ui_cue(ok and "success" or "blocked")
    if notification and notification.AddLegacy then
        notification.AddLegacy(message, ok and (NOTIFY_GENERIC or 0) or (NOTIFY_ERROR or 1), 8)
    end
    local suffix = {}
    if removedBuilt > 0 then
        suffix[#suffix + 1] = LF("mmd_vmd_npc.console.built_removed_fmt", tostring(removedBuilt))
    end
    if musicPath ~= "" then
        suffix[#suffix + 1] = musicRemoved
            and LF("mmd_vmd_npc.console.music_removed_fmt", musicPath)
            or LF("mmd_vmd_npc.console.music_checked_fmt", musicPath)
    end
    print(string.format(
        "[MMD VMD] %s%s",
        message,
        #suffix > 0 and (" | " .. table.concat(suffix, " | ")) or ""
    ))
end)

hook.Add("HUDPaint", "MMDVMDNPCBuildProgressHUD", function()
    local status = MMDVMDNPC.BuildStatus or {}
    if status.status ~= "building" and status.status ~= "queued" and status.status ~= "countdown" then return end

    local width = math.min(520, ScrW() - 80)
    local height = 54
    local x = math.floor((ScrW() - width) * 0.5)
    local y = math.floor(ScrH() * 0.78)
    local progress = math.Clamp(tonumber(status.progress) or 0, 0, 1)
    local title = status.status == "queued" and L("mmd_vmd_npc.hud.build_queued")
        or (status.status == "countdown" and L("mmd_vmd_npc.hud.countdown") or L("mmd_vmd_npc.hud.build"))
    local detail = tostring(status.message or "")

    draw.RoundedBox(6, x, y, width, height, Color(20, 20, 20, 220))
    draw.SimpleText(title, "DermaDefaultBold", x + 12, y + 8, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    draw.SimpleText(detail, "DermaDefault", x + 12, y + 24, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    local barX = x + 12
    local barY = y + height - 13
    local barW = width - 24
    draw.RoundedBox(3, barX, barY, barW, 6, Color(70, 70, 70, 230))
    draw.RoundedBox(3, barX, barY, math.floor(barW * progress), 6, Color(80, 170, 255, 245))
end)

hook.Add("PreDrawHalos", "MMDVMDNPCAssignedActorHalos", function()
    if not halo or not halo.Add then return end
    if GetConVar("mmd_vmd_npc_show_halos"):GetInt() == 0 then return end 
    local assignments = MMDVMDNPC.AssignedActors or {}
    local first = {}
    local selected = {}
    local missing = {}

    for _, ent in ipairs(assignments.order or {}) do
        local row = assignments.byEnt and assignments.byEnt[ent] or nil
        if IsValid(ent) and row then
            if row.status == "missing" then
                missing[#missing + 1] = ent
            elseif row.first then
                first[#first + 1] = ent
            else
                selected[#selected + 1] = ent
            end
        end
    end

    if #first > 0 then halo.Add(first, Color(80, 255, 150), 4, 4, 2, true, true) end
    if #selected > 0 then halo.Add(selected, Color(80, 170, 255), 3, 3, 1, true, true) end
    if #missing > 0 then halo.Add(missing, Color(255, 205, 70), 4, 4, 2, true, true) end
end)

local function assigned_label_color(status)
    if status == "built" then return Color(80, 235, 130, 235) end
    if status == "building" or status == "queued" then return Color(90, 180, 255, 235) end
    if status == "missing" then return Color(255, 205, 70, 235) end
    return Color(220, 220, 220, 235)
end

local function should_draw_assigned_actor_label(ent)
    if not IsValid(ent) then return false end
    if (MMDVMDNPC.ActivePlaybackEnts or {})[ent] then return false end
    if (MMDVMDNPC.LocalPlaybacks or {})[ent] then return false end
    return true
end

hook.Add("PostDrawTranslucentRenderables", "MMDVMDNPCAssignedActorLabels", function()
    local assignments = MMDVMDNPC.AssignedActors or {}
    if not assignments.order or #assignments.order <= 0 then return end

    local eyeAng = EyeAngles()
    local ang = Angle(0, eyeAng.y - 90, 90)
    for _, ent in ipairs(assignments.order) do
        local row = assignments.byEnt and assignments.byEnt[ent] or nil
        if row and should_draw_assigned_actor_label(ent) then
            local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
            local pos = ent:LocalToWorld(Vector(0, 0, maxs.z + 14))
            local title = string.format("#%d %s", tonumber(row.index) or 0, motion_display_name(row.motionID))
            local status = tostring(row.status or "")
            local width = math.max(190, math.min(360, 18 + math.max(#title, #status) * 7))

            cam.Start3D2D(pos, ang, 0.06)
                draw.RoundedBox(6, -width * 0.5, -34, width, 48, Color(15, 15, 18, 205))
                draw.SimpleText(title, "DermaDefaultBold", 0, -27, row.first and Color(120, 255, 170) or Color(235, 245, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
                draw.SimpleText(status, "DermaDefault", 0, -10, assigned_label_color(status), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
            cam.End3D2D()
        end
    end
end)

net.Receive("mmdvmd_debug_open", function()
    local motionID = net.ReadString()
    local requestedFrame = net.ReadInt(32)
    MMDVMDNPC.OpenDebugMenu(motionID, requestedFrame)
end)

local function open_motion_browser()
    local frame = vgui.Create("DFrame")
    frame:SetTitle(L("mmd_vmd_npc.manager.title"))
    local menuScale = MMDVMDNPC.MenuScale()
    local frameWidth = math.Clamp(math.floor(1180 * menuScale), 640, ScrW() - 40)
    local frameHeight = math.Clamp(math.floor(760 * menuScale), 460, ScrH() - 40)
    frame:SetSize(frameWidth, frameHeight)
    if frame.SetSizable then frame:SetSizable(true) end
    if frame.SetMinWidth then frame:SetMinWidth(math.min(980, frameWidth)) end
    if frame.SetMinHeight then frame:SetMinHeight(math.min(660, frameHeight)) end
    frame:Center()
    frame:MakePopup()

    -- Category filter state persists across opens (cookie, not convar, to keep
    -- the console namespace clean). "" = all categories.
    local categoryFilter = cookie and cookie.GetString and cookie.GetString("mmdvmd_manager_category", "") or ""
    local schedule_populate   -- coalesced populate; assigned below
    local rebuild_category_combo

    local top = vgui.Create("DPanel", frame)
    top:Dock(TOP)
    top:SetTall(48)

    local refresh = vgui.Create("DButton", top)
    refresh:Dock(RIGHT)
    refresh:SetZPos(1)
    refresh:DockMargin(8, 8, 0, 8)
    style_manager_button(refresh, 150)
    refresh:SetText(L("mmd_vmd_npc.manager.refresh"))
    refresh.DoClick = function()
        request_list()
        request_motion_details()
    end

    local categoryCombo = vgui.Create("DComboBox", top)
    categoryCombo:Dock(LEFT)
    categoryCombo:SetZPos(2)
    categoryCombo:SetWide(math.floor(220 * menuScale))
    categoryCombo:DockMargin(0, 8, 8, 8)
    categoryCombo:SetSortItems(false)
    set_manager_font(categoryCombo, "MMDVMDNPCManagerText")
    categoryCombo.OnSelect = function(_, _, _, value)
        categoryFilter = tostring(value or "")
        if cookie and cookie.Set then cookie.Set("mmdvmd_manager_category", categoryFilter) end
        if schedule_populate then schedule_populate() end
    end

    rebuild_category_combo = function()
        if not IsValid(categoryCombo) then return end
        -- Never rebuild under an open dropdown (Clear() would rip the menu
        -- away mid-pick); the next details update rebuilds it anyway.
        if categoryCombo.IsMenuOpen and categoryCombo:IsMenuOpen() then return end
        categoryCombo:Clear()
        -- Choices are added WITHOUT the select flag: AddChoice(select=true)
        -- fires OnSelect synchronously, which would rewrite the cookie and
        -- re-populate as a side effect of every rebuild. Display via SetValue.
        categoryCombo:AddChoice(L("mmd_vmd_npc.category.all", "All Categories"), "")
        local found = categoryFilter == "" or categoryFilter == "*"
        for _, category in ipairs(MMDVMDNPC.MotionCategories()) do
            found = found or category == categoryFilter
            categoryCombo:AddChoice(MMDVMDNPC.CategoryDisplayName(category), category)
        end
        if found then
            categoryCombo:SetValue(categoryFilter == "" and L("mmd_vmd_npc.category.all", "All Categories")
                or MMDVMDNPC.CategoryDisplayName(categoryFilter))
        elseif #(MMDVMDNPC.MotionDetailsOrdered or {}) == 0 then
            -- Details not streamed yet: KEEP the remembered filter (do not
            -- wipe the cookie); this rebuild runs again when details arrive
            -- and can then genuinely validate it.
            categoryCombo:SetValue(MMDVMDNPC.CategoryDisplayName(categoryFilter))
        else
            -- The remembered category truly no longer exists (addon
            -- unmounted): fall back to All instead of filtering everything out.
            categoryFilter = ""
            if cookie and cookie.Set then cookie.Set("mmdvmd_manager_category", "") end
            categoryCombo:SetValue(L("mmd_vmd_npc.category.all", "All Categories"))
            if schedule_populate then schedule_populate() end
        end
    end

    -- FILL panels must dock after their edge-docked siblings; docking order in
    -- Derma follows ZPos, so the search box and list get a higher ZPos than the
    -- buttons/strips they share space with. Otherwise the FILL area is computed
    -- before the edges reserve space and the panels overlap.
    local search = vgui.Create("DTextEntry", top)
    search:Dock(FILL)
    search:SetZPos(10)
    search:DockMargin(0, 8, 0, 8)
    search:SetPlaceholderText(L("mmd_vmd_npc.manager.search_placeholder"))
    set_manager_font(search, "MMDVMDNPCManagerText")

    local list = vgui.Create("DListView", frame)
    list:Dock(FILL)
    list:SetZPos(100)
    -- Min widths (not fixed) so the columns always share the available width
    -- instead of summing past the frame and clipping the rightmost ones;
    -- DListView has no horizontal scrollbar. Bone/flex counts and the raw
    -- addon flag moved to the details pane — the list keeps what you scan for.
    local columns = {
        { list:AddColumn(L("mmd_vmd_npc.manager.column_motion_id")), 160 },
        { list:AddColumn(L("mmd_vmd_npc.manager.column_english")), 110 },
        { list:AddColumn(L("mmd_vmd_npc.manager.column_category")), 100 },
        { list:AddColumn(L("mmd_vmd_npc.manager.column_duration")), 64 },
        { list:AddColumn(L("mmd_vmd_npc.manager.column_frames")), 64 },
        { list:AddColumn(L("mmd_vmd_npc.manager.column_music")), 52 },
        { list:AddColumn(L("mmd_vmd_npc.manager.column_camera")), 52 },
        { list:AddColumn(L("mmd_vmd_npc.manager.column_built")), 64 },
        { list:AddColumn(L("mmd_vmd_npc.manager.column_wheel")), 56 },
    }
    local WHEEL_COLUMN = 9
    for _, columnInfo in ipairs(columns) do
        local column, width = columnInfo[1], columnInfo[2]
        if IsValid(column) and column.SetMinWidth then column:SetMinWidth(width) end
    end
    if list.SetDataHeight then list:SetDataHeight(math.floor(30 * MMDVMDNPC.MenuScale())) end
    if IsValid(list.Header) and list.Header.SetTall then list.Header:SetTall(32) end
    for _, column in ipairs(list.Columns or {}) do
        if IsValid(column.Header) then
            set_manager_font(column.Header, "MMDVMDNPCManagerTextBold")
            if column.Header.SetTall then column.Header:SetTall(32) end
        end
    end

    local details = vgui.Create("DLabel", frame)
    details:Dock(BOTTOM)
    details:SetTall(96)
    details:SetWrap(true)
    set_manager_font(details, "MMDVMDNPCManagerDetails")
    details:SetText(L("mmd_vmd_npc.manager.select_motion_details"))

    -- One-line descriptive metadata (importer's 7-field table) + source link.
    -- Hidden until a motion with any of those fields is selected.
    local metaPanel = vgui.Create("DPanel", frame)
    metaPanel:Dock(BOTTOM)
    metaPanel:SetTall(28)
    metaPanel:SetPaintBackground(false)
    metaPanel:SetVisible(false)

    local metaLink = vgui.Create("DButton", metaPanel)
    metaLink:Dock(RIGHT)
    style_manager_button(metaLink, 130)
    metaLink:SetText(L("mmd_vmd_npc.manager.open_link", "Open Link"))
    metaLink:SetTooltip(L("mmd_vmd_npc.ui.link_warning"))
    metaLink.MetaURL = ""
    metaLink.DoClick = function(self)
        local url = self.MetaURL
        if url == "" then return end
        -- gui.OpenURL silently ignores scheme-less URLs ("www.youtube.com/...").
        if not string.match(url, "^https?://") then url = "https://" .. url end
        gui.OpenURL(url)
    end

    local metaLabel = vgui.Create("DLabel", metaPanel)
    metaLabel:Dock(FILL)
    set_manager_font(metaLabel, "MMDVMDNPCManagerDetails")
    metaLabel:SetText("")

    local function update_meta_panel(meta)
        if not IsValid(metaPanel) then return end
        meta = meta or {}
        local parts = {}
        local function add(labelKey, fallback, value)
            value = tostring(value or "")
            if value ~= "" then
                parts[#parts + 1] = L(labelKey, fallback) .. ": " .. value
            end
        end
        add("mmd_vmd_npc.meta.category", "Category", meta.category and meta.category ~= "" and MMDVMDNPC.CategoryDisplayName(meta.category) or "")
        add("mmd_vmd_npc.meta.english_name", "English", meta.englishName)
        add("mmd_vmd_npc.meta.artist", "Artist", meta.artist)
        add("mmd_vmd_npc.meta.language", "Language", meta.language)
        add("mmd_vmd_npc.meta.motion_artist", "Motion Artist", meta.motionArtist)
        local link = tostring(meta.link or "")
        metaLink.MetaURL = link
        metaLink:SetVisible(link ~= "")
        metaLabel:SetText(table.concat(parts, "    "))
        metaPanel:SetVisible(#parts > 0 or link ~= "")
    end

    local audioPanel = vgui.Create("DPanel", frame)
    audioPanel:Dock(BOTTOM)
    audioPanel:SetTall(56)

    local audioOptionsPanel = vgui.Create("DPanel", frame)
    audioOptionsPanel:Dock(BOTTOM)
    audioOptionsPanel:SetTall(52)

    local musicToggle = vgui.Create("DCheckBoxLabel", audioOptionsPanel)
    musicToggle:Dock(LEFT)
    musicToggle:SetWide(170)
    musicToggle:SetText(L("mmd_vmd_npc.manager.play_music"))
    musicToggle:SetConVar("mmd_vmd_npc_music_enabled")
    set_manager_font(musicToggle.Label, "MMDVMDNPCManagerText")

    local omniToggle = vgui.Create("DCheckBoxLabel", audioOptionsPanel)
    omniToggle:Dock(LEFT)
    omniToggle:SetWide(330)
    omniToggle:SetText(L("mmd_vmd_npc.ui.music_omni"))
    omniToggle:SetConVar("mmd_vmd_npc_music_omni")
    omniToggle:SetTooltip(L("mmd_vmd_npc.ui.music_omni_help"))
    set_manager_font(omniToggle.Label, "MMDVMDNPCManagerText")

    local volumeSlider = vgui.Create("DNumSlider", audioOptionsPanel)
    volumeSlider:Dock(FILL)
    volumeSlider:SetText(L("mmd_vmd_npc.manager.volume"))
    volumeSlider:SetMin(0)
    volumeSlider:SetMax(2)
    volumeSlider:SetDecimals(2)
    volumeSlider:SetConVar("mmd_vmd_npc_music_volume")
    set_manager_font(volumeSlider.Label, "MMDVMDNPCManagerText")

    -- Camera auto-enter + music distance behavior: applies to any playback the
    -- player starts, whichever UI (wheel, this menu, the tool) started it.
    local playbackOptionsPanel = vgui.Create("DPanel", frame)
    playbackOptionsPanel:Dock(BOTTOM)
    playbackOptionsPanel:SetTall(52)

    local cameraAutoToggle = vgui.Create("DCheckBoxLabel", playbackOptionsPanel)
    cameraAutoToggle:Dock(LEFT)
    cameraAutoToggle:SetWide(350)
    cameraAutoToggle:SetText(L("mmd_vmd_npc.camera.auto_option"))
    cameraAutoToggle:SetConVar("mmd_vmd_npc_camera_auto")
    cameraAutoToggle:SetTooltip(L("mmd_vmd_npc.camera.auto_option_help"))
    set_manager_font(cameraAutoToggle.Label, "MMDVMDNPCManagerText")

    local rangeSlider = vgui.Create("DNumSlider", playbackOptionsPanel)
    rangeSlider:Dock(LEFT)
    rangeSlider:SetWide(300)
    rangeSlider:SetText(L("mmd_vmd_npc.ui.music_range"))
    rangeSlider:SetMin(100)
    rangeSlider:SetMax(5000)
    rangeSlider:SetDecimals(0)
    rangeSlider:SetConVar("mmd_vmd_npc_music_range")
    set_manager_font(rangeSlider.Label, "MMDVMDNPCManagerText")

    local fadeSlider = vgui.Create("DNumSlider", playbackOptionsPanel)
    fadeSlider:Dock(FILL)
    fadeSlider:SetText(L("mmd_vmd_npc.ui.music_fade"))
    fadeSlider:SetMin(10)
    fadeSlider:SetMax(2000)
    fadeSlider:SetDecimals(0)
    fadeSlider:SetConVar("mmd_vmd_npc_music_fade")
    set_manager_font(fadeSlider.Label, "MMDVMDNPCManagerText")

    local offsetEntry = vgui.Create("DNumberWang", audioPanel)
    offsetEntry:Dock(LEFT)
    offsetEntry:SetWide(110)
    set_manager_font(offsetEntry, "MMDVMDNPCManagerText")
    offsetEntry:SetDecimals(2)
    offsetEntry:SetMinMax(-5, 5)
    offsetEntry:SetValue(0)

    local audioLabel = vgui.Create("DLabel", audioPanel)
    audioLabel:Dock(FILL)
    audioLabel:SetWrap(true)
    set_manager_font(audioLabel, "MMDVMDNPCManagerDetails")
    audioLabel:SetText(L("mmd_vmd_npc.manager.audio_offset_help"))

    local audioPreview = vgui.Create("DButton", audioPanel)
    audioPreview:Dock(RIGHT)
    style_manager_button(audioPreview, 160)
    audioPreview:SetText(L("mmd_vmd_npc.manager.preview_music_only"))

    local motionPreview = vgui.Create("DButton", audioPanel)
    motionPreview:Dock(RIGHT)
    style_manager_button(motionPreview, 160)
    motionPreview:SetText(L("mmd_vmd_npc.manager.preview_motion"))

    local audioStop = vgui.Create("DButton", audioPanel)
    audioStop:Dock(RIGHT)
    style_manager_button(audioStop, 120)
    audioStop:SetText(L("mmd_vmd_npc.manager.stop_music"))
    audioStop.DoClick = stop_audio_preview

    local audioSave = vgui.Create("DButton", audioPanel)
    audioSave:Dock(RIGHT)
    style_manager_button(audioSave, 125)
    audioSave:SetText(L("mmd_vmd_npc.manager.save_offset"))

    local selectedMotion = nil
    local selectedMeta = nil
    local update_wheel_button -- assigned after the wheel button is created
    local toggle_wheel_for    -- assigned after the wheel button is created
    local lastPopulateSignature = nil

    local function wheel_cell_text(motionID)
        local inWheel = MMDVMDNPC.IsFavorite and MMDVMDNPC.IsFavorite(motionID) or false
        return inWheel and "★" or "☆", inWheel
    end

    local function populate()
        if not IsValid(list) then return end
        local query = string.lower(search:GetValue() or "")
        local rows = MMDVMDNPC.MotionDetailsOrdered or {}
        if #rows <= 0 then
            -- Details not streamed yet: show bare ids so the menu is usable
            -- immediately (a fresh array — never mutate the shared cache table).
            rows = {}
            for _, id in ipairs(MMDVMDNPC.ClientMotions or {}) do
                rows[#rows + 1] = { id = id }
            end
        end

        -- Filter first and fingerprint the visible result: rebuilding hundreds
        -- of Derma rows on every status hook is the menu's main cost, and most
        -- hook fires change nothing the list shows.
        local visible = {}
        local signature = { categoryFilter, query }
        for _, meta in ipairs(rows) do
            if MMDVMDNPC.MotionMatchesCategory(meta, categoryFilter) then
                local displayName = motion_display_name(meta)
                local haystack = string.lower(table.concat({
                    meta.id or "",
                    displayName,
                    meta.englishName or "",
                    meta.artist or "",
                    meta.motionArtist or "",
                    meta.sourceName or "",
                    meta.musicSound or "",
                }, " "))
                if query == "" or string.find(haystack, query, 1, true) then
                    local wheelText = wheel_cell_text(meta.id)
                    visible[#visible + 1] = { meta = meta, displayName = displayName, wheelText = wheelText }
                    -- Everything a row DISPLAYS (or hands to update_selection
                    -- via line.Meta) must be part of the fingerprint, or a
                    -- re-import with unchanged id would never refresh the row.
                    -- meta.modified (file mtime) covers all content changes.
                    signature[#signature + 1] = table.concat({
                        tostring(meta.id), displayName, tostring(meta.built),
                        wheelText, tostring(meta.category or ""),
                        tostring(meta.englishName or ""),
                        tostring(meta.modified or ""), tostring(meta.duration or ""),
                        tostring(meta.frameCount or ""), tostring(meta.musicSound or ""),
                        tostring(meta.hasCamera),
                    }, "\1")
                end
            end
        end
        local signatureText = table.concat(signature, "\2")
        if signatureText == lastPopulateSignature then return end
        lastPopulateSignature = signatureText

        local previouslySelected = selectedMotion
        list:Clear()
        local reselectLine = nil
        for _, row in ipairs(visible) do
            local meta = row.meta
            local line = list:AddLine(
                row.displayName,
                tostring(meta.englishName or ""),
                -- nil category = details not streamed yet; show blank, not a
                -- confident (and possibly wrong) "User Import".
                meta.category and MMDVMDNPC.CategoryDisplayName(meta.category) or "",
                string.format("%.2fs", tonumber(meta.duration) or 0),
                tostring(meta.frameCount or ((meta.frameEnd or 0) - (meta.frameStart or 0) + 1)),
                (meta.musicSound and meta.musicSound ~= "") and L("mmd_vmd_npc.ui.yes") or L("mmd_vmd_npc.ui.no"),
                meta.hasCamera and L("mmd_vmd_npc.ui.yes") or L("mmd_vmd_npc.ui.no"),
                meta.built and L("mmd_vmd_npc.ui.built") or L("mmd_vmd_npc.ui.missing"),
                row.wheelText
            )
            line.MotionID = meta.id
            line.Meta = meta
            style_manager_list_line(line)
            -- The wheel cell is a one-click toggle: no hunting for the button
            -- below when curating the wheel from a long list.
            local wheelCell = line.Columns and line.Columns[WHEEL_COLUMN]
            if IsValid(wheelCell) then
                wheelCell:SetMouseInputEnabled(true)
                wheelCell:SetCursor("hand")
                wheelCell:SetTooltip(L("mmd_vmd_npc.manager.wheel_toggle_tip", "Click to add or remove this dance on the wheel"))
                wheelCell.OnMousePressed = function(_, code)
                    if code ~= MOUSE_LEFT then return end
                    list:ClearSelection()
                    list:SelectItem(line)
                    if toggle_wheel_for then toggle_wheel_for(meta.id) end
                end
            end
            if previouslySelected and tostring(meta.id) == tostring(previouslySelected) then
                reselectLine = line
            end
        end

        -- Re-select the same motion after a rebuild (the list Clears on every
        -- status hook); if it is gone, drop the stale selection and details.
        if reselectLine then
            list:SelectItem(reselectLine)
        elseif previouslySelected then
            selectedMotion = nil
            selectedMeta = nil
            if IsValid(details) then
                details:SetText(L("mmd_vmd_npc.manager.select_motion_details"))
            end
            update_meta_panel(nil)
            if update_wheel_button then update_wheel_button() end
            if IsValid(offsetEntry) then offsetEntry:SetValue(0) end
        end
    end

    -- Hooks fire in bursts (list + details + status all refresh around a single
    -- action); coalesce to at most one Derma rebuild per frame.
    local populateQueued = false
    schedule_populate = function()
        if populateQueued then return end
        populateQueued = true
        timer.Simple(0, function()
            populateQueued = false
            if IsValid(frame) then populate() end
        end)
    end

    local function update_selection(line)
        if not line then return end
        selectedMotion = line.MotionID
        selectedMeta = line.Meta or (selectedMotion and MMDVMDNPC.MotionDetails[selectedMotion]) or nil
        if selectedMotion then
            RunConsoleCommand("mmd_vmd_npc_motion", selectedMotion)
            request_audio_settings(selectedMotion)
        end
        local meta = selectedMeta or {}
        local selectedDisplayName = selectedMotion and motion_display_name(meta.id and meta or selectedMotion) or L("mmd_vmd_npc.ui.none")
        details:SetText(LF(
            "mmd_vmd_npc.manager.details_fmt",
            tostring(selectedDisplayName),
            tostring(meta.fps or "?"),
            tostring(meta.frameStart or "?"),
            tostring(meta.frameEnd or "?"),
            tonumber(meta.duration) or 0,
            tostring(meta.boneCount or 0),
            tostring(meta.flexCount or 0),
            tostring(meta.musicSound or "") ~= "" and tostring(meta.musicSound) or L("mmd_vmd_npc.ui.none"),
            meta.hasCamera and L("mmd_vmd_npc.ui.yes") or L("mmd_vmd_npc.ui.no"),
            tostring(meta.sourceName or "")
        ))
        offsetEntry:SetValue(tonumber(MMDVMDNPC.AudioOffsets[selectedMotion or ""]) or 0)
        update_meta_panel(meta)
        if update_wheel_button then update_wheel_button() end
    end

    list.OnRowSelected = function(_, _, line)
        update_selection(line)
    end

    list.DoDoubleClick = function(_, _, line)
        update_selection(line)
        if line and line.MotionID then
            MMDVMDNPC.OpenDebugMenu(line.MotionID, DEBUG_REFERENCE_FRAME)
        end
    end

    search.OnChange = function()
        schedule_populate()
    end

    local controls = vgui.Create("DPanel", frame)
    controls:Dock(BOTTOM)
    controls:SetTall(54)

    local open = vgui.Create("DButton", controls)
    open:Dock(LEFT)
    style_manager_button(open, 140)
    open:SetText(L("mmd_vmd_npc.manager.debug"))
    open.DoClick = function()
        local selected = list:GetSelectedLine()
        local line = selected and list:GetLine(selected)
        if line and line.MotionID then
            MMDVMDNPC.OpenDebugMenu(line.MotionID, DEBUG_REFERENCE_FRAME)
        end
    end

    local build = vgui.Create("DButton", controls)
    build:Dock(LEFT)
    style_manager_button(build, 170)
    build:SetText(L("mmd_vmd_npc.manager.build_selected"))
    build.DoClick = function()
        if selectedMotion then
            MMDVMDNPC.RequestBuildSelectedMotion()
        end
    end

    local play = vgui.Create("DButton", controls)
    play:Dock(LEFT)
    style_manager_button(play, 170)
    play:SetText(L("mmd_vmd_npc.manager.play_built"))
    play.DoClick = function()
        if selectedMotion then
            MMDVMDNPC.RequestPlaySelectedMotion()
        end
    end

    local star = vgui.Create("DButton", controls)
    star:Dock(LEFT)
    style_manager_button(star, 190)

    update_wheel_button = function()
        if not IsValid(star) then return end
        local inWheel = selectedMotion and selectedMotion ~= ""
            and MMDVMDNPC.IsFavorite and MMDVMDNPC.IsFavorite(selectedMotion)
        if inWheel then
            star:SetText(L("mmd_vmd_npc.manager.wheel_remove", "★ Remove From Wheel"))
            star:SetTextColor(Color(255, 200, 90))
        else
            star:SetText(L("mmd_vmd_npc.manager.wheel_add", "☆ Add To Wheel"))
            star:SetTextColor(Color(255, 255, 255))
        end
    end
    update_wheel_button()

    -- Shared by the star button and the per-row wheel cells. Updates only the
    -- affected row's cell instead of rebuilding the whole list.
    -- Debounced PER MOTION ID (not per widget): both presses of a double-click
    -- reach here, and the favorites-changed hook rebuilds the list between
    -- them, so any state stored on the cell/button would not survive to block
    -- the second press (it would toggle add+remove).
    local wheelToggleNext = {}
    toggle_wheel_for = function(motionID)
        if not motionID or motionID == "" then return end
        if (wheelToggleNext[motionID] or 0) > RealTime() then return end
        wheelToggleNext[motionID] = RealTime() + 0.35
        local isAdded = MMDVMDNPC.ToggleFavorite(motionID)
        if isAdded then
            surface.PlaySound("garrysmod/content_downloaded.wav")
            notification.AddLegacy(L("mmd_vmd_npc.manager.wheel_added", "Added to wheel!"), NOTIFY_GENERIC, 3)
        else
            surface.PlaySound("buttons/button15.wav")
            notification.AddLegacy(L("mmd_vmd_npc.manager.wheel_removed", "Removed from wheel"), NOTIFY_CLEANUP, 3)
        end
        update_wheel_button()
        if IsValid(list) then
            for _, line in ipairs(list:GetLines() or {}) do
                if line.MotionID == motionID then
                    local cell = line.Columns and line.Columns[WHEEL_COLUMN]
                    if IsValid(cell) then cell:SetText((wheel_cell_text(motionID))) end
                end
            end
        end
        -- The next populate() must not skip this change.
        lastPopulateSignature = nil
    end

    star.DoClick = function()
        if selectedMotion and selectedMotion ~= "" then
            toggle_wheel_for(selectedMotion)
        else
            notification.AddLegacy(L("mmd_vmd_npc.manager.wheel_select_first", "Select a motion from the list first."), NOTIFY_ERROR, 3)
        end
    end

    local rename = vgui.Create("DButton", controls)
    rename:Dock(LEFT)
    style_manager_button(rename, 110)
    rename:SetText(L("mmd_vmd_npc.manager.rename", "Rename"))
    rename.DoClick = function()
        if selectedMotion and selectedMotion ~= "" then
            Derma_StringRequest(
                L("mmd_vmd_npc.manager.rename_title", "Rename"),
                LF("mmd_vmd_npc.manager.rename_prompt_fmt", tostring(selectedMotion)),
                MMDVMDNPC.GetNiceName(selectedMotion),
                function(text)
                    if text and text ~= "" then
                        MMDVMDNPC.CustomNames[selectedMotion] = text
                        MMDVMDNPC.SaveCustomNames()
                        notification.AddLegacy(L("mmd_vmd_npc.manager.rename_saved", "Saved!"), NOTIFY_GENERIC, 3)
                        lastPopulateSignature = nil
                        if IsValid(list) then populate() end
                    end
                end
            )
        end
    end

    local stop = vgui.Create("DButton", controls)
    stop:Dock(LEFT)
    style_manager_button(stop, 120)
    stop:SetText(L("mmd_vmd_npc.manager.stop"))
    stop.DoClick = function()
        MMDVMDNPC.RequestStopSelectedMotion()
        stop_audio_preview()
    end

    local clearModel = vgui.Create("DButton", controls)
    clearModel:Dock(LEFT)
    style_manager_button(clearModel, 190)
    clearModel:SetText(L("mmd_vmd_npc.manager.clear_this_model"))
    clearModel.DoClick = function()
        MMDVMDNPC.RequestClearBuiltSelectedMotion("model")
        request_motion_details()
    end

    local clearAll = vgui.Create("DButton", controls)
    clearAll:Dock(LEFT)
    style_manager_button(clearAll, 235)
    clearAll:SetText(L("mmd_vmd_npc.manager.clear_all_models"))
    clearAll.DoClick = function()
        MMDVMDNPC.RequestClearBuiltSelectedMotion("all")
        request_motion_details()
    end

    local deleteMotion = vgui.Create("DButton", controls)
    deleteMotion:Dock(FILL)
    deleteMotion:SetText(L("mmd_vmd_npc.manager.delete_motion_music"))
    style_manager_button(deleteMotion)
    set_manager_font(deleteMotion, "MMDVMDNPCManagerTextBold")
    deleteMotion:SetTextColor(Color(180, 40, 40))
    deleteMotion.DoClick = function()
        if not selectedMotion or selectedMotion == "" then
            play_ui_cue("blocked")
            print("[MMD VMD] " .. L("mmd_vmd_npc.error.select_motion"))
            return
        end

        local function delete_selected()
            stop_audio_preview()
            MMDVMDNPC.RequestDeleteSelectedMotion(selectedMotion)
        end
        local prompt = LF("mmd_vmd_npc.manager.delete_prompt_fmt", tostring(selectedMotion))
        if Derma_Query then
            Derma_Query(prompt, L("mmd_vmd_npc.manager.delete_title"), L("mmd_vmd_npc.manager.delete_confirm"), delete_selected, L("mmd_vmd_npc.manager.cancel"))
        else
            delete_selected()
        end
    end

    -- Consistent breathing room between the action buttons; the strip itself
    -- stays transparent so the frame reads as one surface.
    controls:SetPaintBackground(false)
    for _, button in ipairs({ open, build, play, star, rename, stop, clearModel, clearAll, deleteMotion }) do
        if IsValid(button) then button:DockMargin(0, 8, 8, 8) end
    end

    audioPreview.DoClick = function()
        local meta = selectedMeta or (selectedMotion and MMDVMDNPC.MotionDetails[selectedMotion]) or {}
        local volume = GetConVar("mmd_vmd_npc_music_volume")
        play_audio_preview(meta.musicSound or "", offsetEntry:GetValue(), volume and volume:GetFloat() or MMDVMDNPC.DefaultMusicVolume or 1)
    end
    motionPreview.DoClick = function()
        if selectedMotion then
            MMDVMDNPC.SaveAudioOffset(selectedMotion, offsetEntry:GetValue())
            MMDVMDNPC.RequestPlaySelectedMotion()
        end
    end
    audioSave.DoClick = function()
        if selectedMotion then
            MMDVMDNPC.SaveAudioOffset(selectedMotion, offsetEntry:GetValue())
        end
    end

    local hookID = "MMDVMDNPCMotionBrowser_" .. tostring(frame)
    hook.Add("MMDVMDNPCMotionListUpdated", hookID, function() schedule_populate() end)
    hook.Add("MMDVMDNPCMotionDetailsUpdated", hookID .. "_Details", function()
        if rebuild_category_combo then rebuild_category_combo() end
        schedule_populate()
    end)
    hook.Add("MMDVMDNPCWheelFavoritesChanged", hookID .. "_Wheel", function()
        if update_wheel_button then update_wheel_button() end
        lastPopulateSignature = nil
        schedule_populate()
    end)
    hook.Add("MMDVMDNPCAudioSettingsUpdated", hookID .. "_Audio", function(motionID, offset)
        if motionID == selectedMotion and IsValid(offsetEntry) then
            offsetEntry:SetValue(offset)
        end
    end)
    frame.OnRemove = function()
        hook.Remove("MMDVMDNPCMotionListUpdated", hookID)
        hook.Remove("MMDVMDNPCMotionDetailsUpdated", hookID .. "_Details")
        hook.Remove("MMDVMDNPCWheelFavoritesChanged", hookID .. "_Wheel")
        hook.Remove("MMDVMDNPCAudioSettingsUpdated", hookID .. "_Audio")
        stop_audio_preview()
    end

    rebuild_category_combo()
    populate()
    request_list()
    request_motion_details()
end

concommand.Add("mmdvmd_menu", open_motion_browser)
MMDVMDNPC.OpenMotionManager = open_motion_browser

concommand.Add("mmdvmd_list", function()
    request_list()
end)

concommand.Add("mmdvmd_debug", function(_, _, args)
    local motionID = args and args[1] or ""
    if motionID == "" then
        print("[MMD VMD] " .. L("mmd_vmd_npc.console.debug_usage"))
        return
    end
    MMDVMDNPC.OpenDebugMenu(motionID, args and args[2] or DEBUG_REFERENCE_FRAME)
end)

hook.Add("PlayerBindPress", "MMD_SpaceToStopAnimation", function(ply, bind, pressed)
    if not pressed then return end

    if string.find(bind, "+jump") then
        if ply:GetNWBool("MMDVMDNPCSelfProxy", false) or MMDVMDNPC.SelfThirdPersonActive then
            
            MMDVMDNPC.RequestForceSelfPlaybackReset()
            
            return true 
        end
    end
end)

-- Create DB
MMDVMDNPC.CustomNames = MMDVMDNPC.CustomNames or {}
local NAMES_FILE = "mmdvmd_custom_names.json"

function MMDVMDNPC.LoadCustomNames()
    local raw = file.Read(NAMES_FILE, "DATA")
    if raw then MMDVMDNPC.CustomNames = util.JSONToTable(raw) or {} end
end

function MMDVMDNPC.SaveCustomNames()
    file.Write(NAMES_FILE, util.TableToJSON(MMDVMDNPC.CustomNames))
end

function MMDVMDNPC.GetNiceName(id)
    id = tostring(id or "")
    if id == "stop_playback" then return "STOP" end
    if id == "toggle_cam_mode" then 
        return MMDVMDNPC.CameraTrackMode and "CAMERA: FOLLOW" or "CAMERA: STATIC"
    end
    if id == "stop_playback" then return "STOP" end
    if MMDVMDNPC.CustomNames[id] then return MMDVMDNPC.CustomNames[id] end
    local meta = MMDVMDNPC.MotionDetails and MMDVMDNPC.MotionDetails[id]
    if meta and meta.displayName and meta.displayName ~= "" then return meta.displayName end
    return id
end

 
function motion_display_name(metaOrID)
    local id = istable(metaOrID) and metaOrID.id or tostring(metaOrID or "")
    return MMDVMDNPC.GetNiceName(id)
end

 
MMDVMDNPC.LoadCustomNames()