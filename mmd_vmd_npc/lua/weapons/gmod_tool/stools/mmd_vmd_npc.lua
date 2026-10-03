MMDVMDNPC = MMDVMDNPC or {}
if not MMDVMDNPC.L then include("mmd_vmd_npc/sh_core.lua") end

local function L(key, fallback)
    return MMDVMDNPC.L and MMDVMDNPC.L(key, fallback) or (fallback or key)
end

local function LF(key, ...)
    return MMDVMDNPC.LFormat and MMDVMDNPC.LFormat(key, ...) or string.format(L(key, key), ...)
end

local function motion_display_name(metaOrID)
    -- Prefer the shared CustomNames-aware resolver from cl_menu so tool-panel
    -- names match the Motion Manager and the wheel, including user renames.
    local id = istable(metaOrID) and tostring(metaOrID.id or "") or tostring(metaOrID or "")
    if MMDVMDNPC.GetNiceName and id ~= "" then
        return MMDVMDNPC.GetNiceName(id)
    end

    if istable(metaOrID) then
        local display = tostring(metaOrID.displayName or "")
        if display ~= "" then return display end
        return tostring(metaOrID.id or "")
    end

    local meta = MMDVMDNPC.MotionDetails and MMDVMDNPC.MotionDetails[id] or nil
    local display = meta and tostring(meta.displayName or "") or ""
    return display ~= "" and display or id
end

TOOL.Category = L("mmd_vmd_npc.category", "Animation")
TOOL.Name = "#tool.mmd_vmd_npc.name"
TOOL.Command = nil
TOOL.ConfigName = ""

TOOL.Information = {
    { name = "left" },
    { name = "left_use", icon2 = "gui/e.png" },
    { name = "left_speed", icon2 = "mmd_vmd_npc/shift.png" },
    { name = "left_alt", icon2 = "mmd_vmd_npc/alt.png" },
    { name = "reload_alt", icon2 = "mmd_vmd_npc/alt.png" },
    { name = "right" },
    { name = "right_speed", icon2 = "mmd_vmd_npc/shift.png" },
    { name = "reload" },
    { name = "reload_speed", icon2 = "mmd_vmd_npc/shift.png" },
    { name = "reload_use", icon2 = "gui/e.png" },
}

local function client_alt_down()
    if not CLIENT or not input or not input.IsKeyDown then return false end
    return (KEY_LALT ~= nil and input.IsKeyDown(KEY_LALT))
        or (KEY_RALT ~= nil and input.IsKeyDown(KEY_RALT))
end

local function bind_is_primary_attack(bind)
    bind = string.lower(tostring(bind or ""))
    return bind == "+attack" or bind == "attack"
end

local function request_stop_npc_playbacks()
    if not CLIENT then return end
    net.Start("mmdvmd_stop_npc_playbacks_request")
    net.SendToServer()
end

local function request_align_assigned_actors()
    if not CLIENT then return end
    net.Start("mmdvmd_assignment_align_request")
    net.SendToServer()
end

local function local_player_has_mmd_vmd_tool()
    if not CLIENT then return false end
    local ply = LocalPlayer()
    if not IsValid(ply) then return false end

    local weapon = ply:GetActiveWeapon()
    if not IsValid(weapon) or weapon:GetClass() ~= "gmod_tool" then return false end

    if weapon.GetMode then
        return weapon:GetMode() == "mmd_vmd_npc"
    end
    return tostring(weapon.Mode or "") == "mmd_vmd_npc"
end

if CLIENT then
    hook.Add("PlayerBindPress", "MMDVMDNPCToolModifierBinds", function(ply, bind, pressed)
        if ply ~= LocalPlayer() or not pressed then return end
        bind = string.lower(tostring(bind or ""))
        if bind_is_primary_attack(bind) and client_alt_down() and local_player_has_mmd_vmd_tool() then
            request_align_assigned_actors()
            return true
        end

        if not string.find(bind, "reload", 1, true) then return end
        if not client_alt_down() or not local_player_has_mmd_vmd_tool() then return end

        request_stop_npc_playbacks()
        return true
    end)
end

TOOL.ClientConVar = {
    motion = "",
    show_halos = "1",
    disable_armtwist = "0",
    disable_handtwist = "0",
    disable_eyes = "0",
    disable_spine_pelvis_correction = "0",
    disable_jiggle = "0",
    start_delay = "2",
    pelvis_z_offset = "-2.5",
    thirdperson_distance = "120",
    thirdperson_height = "24",
    eye_track = "1",
    eye_track_smooth = "20",
    eye_track_moveback = "0.10",
    eye_track_pos_ud = "0.5",
    eye_track_pos_lr = "0.5",
    music_enabled = "1",
    music_volume = "1",
    music_omni = "1",
    music_range = "1500",
    music_fade = "300",
    loop_playback = "0",
    camera_auto = "1",
    fast_build = "1",
    build_frames_per_batch = "64",
    playback_hz = "240",
}

if CLIENT then
    MMDVMDNPC.RegisterI18N()
end

local function selected_motion(tool)
    return tool:GetClientInfo("motion")
end

local function selected_tool_options(tool)
    return MMDVMDNPC.ToolOptions and MMDVMDNPC.ToolOptions(tool) or nil
end

local function selected_playback_settings(tool)
    return MMDVMDNPC.ToolPlaybackSettings and MMDVMDNPC.ToolPlaybackSettings(tool) or nil
end

local function notify_blocked(ply, message, ent)
    if MMDVMDNPC.NotifyBlocked then
        MMDVMDNPC.NotifyBlocked(ply, message, ent)
    else
        MMDVMDNPC.Chat(ply, message)
    end
end

local function assign_target(tool, trace)
    local owner = tool:GetOwner()
    local ent = trace and trace.Entity or nil
    if not IsValid(ent) or not (ent.IsNPC and ent:IsNPC()) then
        notify_blocked(owner, L("mmd_vmd_npc.error.left_click_valid_npc"))
        return false
    end

    local motionID = selected_motion(tool)
    if motionID == "" then
        notify_blocked(owner, L("mmd_vmd_npc.error.select_motion"), ent)
        return false
    end
    local options = selected_tool_options(tool)
    local playbackSettings = selected_playback_settings(tool)
    local ok, err = MMDVMDNPC.AssignActorForPlayer(owner, ent, motionID, options, playbackSettings)
    if not ok and err then
        notify_blocked(owner, err, ent)
    end
    return ok
end

local function open_selected_motion(tool, trace)
    local owner = tool:GetOwner()
    local ent = trace and trace.Entity or nil
    if not IsValid(ent) or not ((ent.IsNPC and ent:IsNPC()) or (ent.IsPlayer and ent:IsPlayer())) then
        ent = MMDVMDNPC.DebugTargets and MMDVMDNPC.DebugTargets[owner] or nil
    end

    if not IsValid(ent) or not ((ent.IsNPC and ent:IsNPC()) or (ent.IsPlayer and ent:IsPlayer())) then
        notify_blocked(owner, L("mmd_vmd_npc.error.shift_right_click_valid_actor"))
        return false
    end

    local motionID = selected_motion(tool)
    local ok, err = MMDVMDNPC.OpenDebugForPlayer(owner, ent, motionID, -1)
    if not ok and err then
        notify_blocked(owner, err, ent)
    end
    return ok
end

local function align_selected_actors(owner, ent)
    if MMDVMDNPC.AlignAssignedActorsToFirstForPlayer then
        local ok, err = MMDVMDNPC.AlignAssignedActorsToFirstForPlayer(owner)
        if not ok and err then notify_blocked(owner, err, ent) end
        return ok == true
    end
    return false
end

function TOOL:LeftClick(trace)
    if CLIENT then return true end
    local owner = self:GetOwner()
    if IsValid(owner) and owner:KeyDown(IN_SPEED) then
        if MMDVMDNPC.BeginBuildForAssignedActorsForPlayer then
            local ok, err = MMDVMDNPC.BeginBuildForAssignedActorsForPlayer(owner, selected_playback_settings(self))
            if not ok and err then notify_blocked(owner, err, trace and trace.Entity or nil) end
            return ok == true
        end
        return false
    end
    if IsValid(owner) and owner:KeyDown(IN_USE) then
        if MMDVMDNPC.StartAssignedGroupPlaybackForPlayer then
            local ok, err = MMDVMDNPC.StartAssignedGroupPlaybackForPlayer(owner, selected_playback_settings(self))
            if not ok and err then notify_blocked(owner, err, trace and trace.Entity or nil) end
            return ok == true
        end
        return false
    end
    return assign_target(self, trace)
end

function TOOL:RightClick(trace)
    if CLIENT then return true end
    local owner = self:GetOwner()
    if not IsValid(owner) then return false end
    if owner:KeyDown(IN_SPEED) then
        return open_selected_motion(self, trace)
    end
    if MMDVMDNPC.HasAssignedActorsForPlayer and MMDVMDNPC.HasAssignedActorsForPlayer(owner) and MMDVMDNPC.ToggleAssignedPlaybackPauseForPlayer then
        local ok, err = MMDVMDNPC.ToggleAssignedPlaybackPauseForPlayer(owner)
        if ok then return true end
        if err and err ~= "no active selected playback to pause" then
            notify_blocked(owner, err, trace and trace.Entity or nil)
            return false
        end
    end
    if MMDVMDNPC.TogglePlaybackPauseForPlayer then
        local ok, err = MMDVMDNPC.TogglePlaybackPauseForPlayer(owner, trace and trace.Entity or nil)
        if not ok and err then notify_blocked(owner, err, trace and trace.Entity or nil) end
        return ok == true
    end
    return false
end

function TOOL:Reload()
    if CLIENT then
        if client_alt_down() then
            request_stop_npc_playbacks()
        end
        return true
    end
    local owner = self:GetOwner()
    if not IsValid(owner) then return false end

    local ok, err = MMDVMDNPC.SelectTargetForPlayer(owner, owner)
    if not ok and err then
        notify_blocked(owner, err, owner)
        return false
    end

    local motionID = selected_motion(self)
    if motionID == "" then
        notify_blocked(owner, L("mmd_vmd_npc.error.select_motion"), owner)
        return true
    end

    local options = selected_tool_options(self)
    local playbackSettings = selected_playback_settings(self)

    if owner:KeyDown(IN_SPEED) then
        if MMDVMDNPC.BeginBuildForPlayer then
            local ok, err = MMDVMDNPC.BeginBuildForPlayer(owner, motionID, options, playbackSettings)
            if not ok and err then notify_blocked(owner, err, owner) end
            return ok == true
        end
        return false
    end

    if owner:KeyDown(IN_USE) then
        local hasBuilt = MMDVMDNPC.HasBuiltAnimationForPlayer and MMDVMDNPC.HasBuiltAnimationForPlayer(owner, motionID, options)
        if not hasBuilt then
            if MMDVMDNPC.ReportBuiltStatusForPlayer then
                MMDVMDNPC.ReportBuiltStatusForPlayer(owner, motionID, options)
            else
                notify_blocked(owner, L("mmd_vmd_npc.error.build_self_first"), owner)
            end
            return true
        end

        if MMDVMDNPC.IsSelfPlaybackRunningForPlayer and MMDVMDNPC.IsSelfPlaybackRunningForPlayer(owner) then
            MMDVMDNPC.StopSelfPlaybackForPlayer(owner, true)
        elseif MMDVMDNPC.StartPlaybackForPlayer then
            MMDVMDNPC.StartPlaybackForPlayer(owner, motionID, options, playbackSettings)
        end
        return true
    end

    if MMDVMDNPC.ReportBuiltStatusForPlayer then
        MMDVMDNPC.ReportBuiltStatusForPlayer(owner, motionID, options)
    end
    return true
end

function TOOL.BuildCPanel(panel)
    panel:ClearControls()
    panel:Help(L("mmd_vmd_npc.ui.tool_help"))

    -- Camera and RTX-Remix lighting settings live in their own sub-tabs below.

    local screenW = ScrW and ScrW() or 1280
    local screenH = ScrH and ScrH() or 720
    local compactPanel = screenW <= 1366 or screenH <= 760
    local textLimit = compactPanel and 38 or 64
    local pathLimit = compactPanel and 42 or 78

    local function shorten_text(value, limit)
        local text = tostring(value or "")
        limit = math.max(12, tonumber(limit) or textLimit)
        if #text <= limit then return text end

        local head = math.max(4, math.floor((limit - 3) * 0.58))
        local tail = math.max(4, limit - 3 - head)
        return string.sub(text, 1, head) .. "..." .. string.sub(text, -tail)
    end

    local function bounded_label(label, font, color, height)
        label:SetFont(font or "DermaDefault")
        if color then label:SetTextColor(color) end
        label:SetWrap(true)
        label:SetAutoStretchVertical(false)
        label:SetTall(height or (compactPanel and 42 or 52))
        return label
    end

    local container = vgui.Create("DPanel", panel)
    -- Previously a screen-scaled fixed height (screenH * ~1.15) — that made the
    -- whole spawn-menu column taller than the screen on every resolution (absurdly
    -- so on 1440p/4K), forcing one enormous outer scrollbar. Instead pin the sheet
    -- to a viewport that fits the tool column on any resolution and let each tab
    -- scroll its own overflow internally, so the outer scrollbar stays short.
    local viewportTall = math.Clamp(math.floor(screenH * 0.62), 440, 760)
    container:SetTall(viewportTall)
    container.Paint = nil
    panel:AddItem(container)

    local sheet = vgui.Create("DPropertySheet", container)
    sheet:Dock(FILL)

    local function create_subtab(title, icon)
        -- Each tab is a ControlPanel inside a DScrollPanel: the ControlPanel takes
        -- its natural content height (Dock TOP) and the scroll panel shows a
        -- scrollbar only when that content exceeds the fixed viewport above.
        local scroll = vgui.Create("DScrollPanel", sheet)
        scroll:Dock(FILL)
        local tab = vgui.Create("ControlPanel", scroll)
        tab:Dock(TOP)
        sheet:AddSheet(title, scroll, icon or "icon16/wrench.png")
        return tab
    end

    local function add_slider(parent, label, cvar, minv, maxv, decimals)
        return parent:NumSlider(label, cvar, minv, maxv, decimals or 2)
    end

    local function add_checkbox_with_help(parent, label, cvar, helpText)
        local checkbox = parent:CheckBox(label, cvar)
        if helpText and helpText ~= "" then parent:Help(helpText) end
        return checkbox
    end

    local function section(parent, title, color)
        local header = vgui.Create("DLabel")
        header:SetText(title)
        header:SetFont("DermaDefaultBold")
        header:SetTextColor(color or Color(80, 170, 255))
        header:DockMargin(0, 8, 0, 2)
        parent:AddItem(header)
        return header
    end

    local function colored_button(parent, text, color, callback)
        local button = vgui.Create("DButton")
        button:SetText(text)
        button:SetTall(30)
        button.DoClick = callback
        button.Paint = function(self, w, h)
            local c = color or Color(70, 120, 190)
            if self:IsHovered() then
                c = Color(math.min(c.r + 25, 255), math.min(c.g + 25, 255), math.min(c.b + 25, 255), 255)
            end
            draw.RoundedBox(5, 0, 0, w, h, c)
            draw.SimpleText(self:GetText(), "DermaDefaultBold", w * 0.5, h * 0.5, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            return true
        end
        parent:AddItem(button)
        return button
    end

    local function key_binder(parent, labelText, cvarName, color)
        local row = vgui.Create("DPanel")
        row:SetTall(30)
        row.Paint = nil
        local label = vgui.Create("DLabel", row)
        label:Dock(FILL)
        label:SetText(labelText)
        label:SetTextColor(color or Color(255, 200, 90))
        label:SetFont("DermaDefaultBold")
        local binder = vgui.Create("DBinder", row)
        binder:Dock(RIGHT)
        binder:SetWide(130)
        local cvar = GetConVar(cvarName)
        binder:SetValue(cvar and cvar:GetInt() or 0)
        binder.OnChange = function(_, num)
            RunConsoleCommand(cvarName, tostring(math.max(0, math.floor(tonumber(num) or 0))))
        end
        parent:AddItem(row)
        return binder
    end

    local motionTab = create_subtab(L("mmd_vmd_npc.ui.tab.motion"), "icon16/film.png")
    local playbackTab = create_subtab(L("mmd_vmd_npc.ui.tab.build_playback"), "icon16/control_play_blue.png")
    local cameraTab = create_subtab(L("mmd_vmd_npc.ui.tab.camera"), "icon16/camera.png")
    local lightingTab = create_subtab(L("mmd_vmd_npc.ui.tab.lighting"), "icon16/lightbulb.png")
    local performanceTab = create_subtab(L("mmd_vmd_npc.ui.tab.performance"), "icon16/lightning.png")
    local advancedTab = create_subtab(L("mmd_vmd_npc.ui.tab.advanced"), "icon16/wrench.png")

    section(motionTab, L("mmd_vmd_npc.ui.tab.motion"), Color(80, 170, 255))
    colored_button(motionTab, L("mmd_vmd_npc.ui.force_reset_self_view"), Color(220, 95, 55), function()
        if MMDVMDNPC and MMDVMDNPC.RequestForceSelfPlaybackReset then
            MMDVMDNPC.RequestForceSelfPlaybackReset()
        end
    end)

    -- The motion wheel uses a REAL console bind (bind <key> +mmd_wheel), not a
    -- convar — and the engine BLOCKS bind/unbind from Lua ("Command is
    -- blocked!"). So this binder cannot rebind anything itself: picking a key
    -- prints the exact console command in chat + console (and copies it to the
    -- clipboard) for the player to run, then keeps showing the LIVE binding.
    local wheelBindRow = vgui.Create("DPanel")
    wheelBindRow:SetTall(30)
    wheelBindRow.Paint = nil
    local wheelBindLabel = vgui.Create("DLabel", wheelBindRow)
    wheelBindLabel:Dock(FILL)
    wheelBindLabel:SetText(L("mmd_vmd_npc.ui.wheel_bind", "Motion wheel key"))
    wheelBindLabel:SetTextColor(Color(255, 200, 90))
    wheelBindLabel:SetFont("DermaDefaultBold")
    local wheelBinder = vgui.Create("DBinder", wheelBindRow)
    wheelBinder:Dock(RIGHT)
    wheelBinder:SetWide(130)

    local function live_wheel_bind_code()
        local boundKey = input.LookupBinding and input.LookupBinding("+mmd_wheel")
        if not boundKey or boundKey == "" or not input.GetKeyCode then return 0 end
        -- LookupBinding reports lowercase names; be tolerant of a GetKeyCode
        -- that only resolves the canonical (uppercase) spelling of mouse keys.
        local code = input.GetKeyCode(boundKey) or 0
        if code <= 0 then code = input.GetKeyCode(string.upper(boundKey)) or 0 end
        return code > 0 and code or 0
    end

    local suppressBinderChange = false
    local function set_binder_display(code)
        -- SetValue fires OnChange (DBinder routes it through SetSelectedNumber),
        -- so programmatic display updates must not be mistaken for user input.
        suppressBinderChange = true
        wheelBinder:SetValue(code or 0)
        suppressBinderChange = false
    end
    set_binder_display(live_wheel_bind_code())

    wheelBinder.OnChange = function(_, keyCode)
        if suppressBinderChange then return end
        keyCode = tonumber(keyCode) or 0
        local old = input.LookupBinding and input.LookupBinding("+mmd_wheel")
        local command, messageKey
        if keyCode > 0 and input.GetKeyName then
            local name = input.GetKeyName(keyCode)
            -- Left/right click are how a capture gets dismissed (and both
            -- already have jobs inside the wheel), so picking them means
            -- "never mind". Re-picking the already-bound key needs no command
            -- either — and that is also what an ESC-cancel reports (DBinder
            -- re-sets the current value, firing OnChange), so without this
            -- check every cancel would print a no-op instruction.
            local isCancelButton = keyCode == MOUSE_LEFT or keyCode == MOUSE_RIGHT
            local sameKey = old and old ~= "" and name and string.lower(old) == string.lower(name)
            if name and name ~= "" and not isCancelButton and not sameKey then
                if old and old ~= "" then
                    command = string.format('unbind %s; bind %s "+mmd_wheel"', old, name)
                else
                    command = string.format('bind %s "+mmd_wheel"', name)
                end
                messageKey = "mmd_vmd_npc.ui.bind_run_fmt"
            end
        elseif old and old ~= "" then
            command = "unbind " .. old
            messageKey = "mmd_vmd_npc.ui.unbind_run_fmt"
        end
        if command and MMDVMDNPC and MMDVMDNPC.AskPlayerToBind then
            MMDVMDNPC.AskPlayerToBind(command, messageKey)
        end
        -- The real binding did not change (only the player can change it), so
        -- snap the display back to it.
        timer.Simple(0, function()
            if IsValid(wheelBinder) then set_binder_display(live_wheel_bind_code()) end
        end)
    end

    -- Reflect the live binding once the player actually runs the command,
    -- without breaking DBinder's own Think-driven key capture.
    local baseBinderThink = wheelBinder.Think
    wheelBinder.Think = function(selfBinder)
        if baseBinderThink then baseBinderThink(selfBinder) end
        if input.IsKeyTrapping and input.IsKeyTrapping() then return end
        if (selfBinder.NextLiveBindCheck or 0) > SysTime() then return end
        selfBinder.NextLiveBindCheck = SysTime() + 1
        local code = live_wheel_bind_code()
        if code ~= (tonumber(selfBinder:GetValue()) or 0) then
            set_binder_display(code)
        end
    end
    motionTab:AddItem(wheelBindRow)
    motionTab:Help(L("mmd_vmd_npc.ui.wheel_bind_help"))

    local hookID = "MMDVMDNPCToolPanel_" .. tostring(panel)
    local audioOffsetSuppress = false
    local selectedMotionLabel = vgui.Create("DLabel")
    selectedMotionLabel:SetText(L("mmd_vmd_npc.ui.selected_motion_none"))
    bounded_label(
        selectedMotionLabel,
        compactPanel and "DermaDefaultBold" or "DermaLarge",
        Color(105, 205, 255),
        compactPanel and 34 or 54
    )
    motionTab:AddItem(selectedMotionLabel)

    local pauseWarningLabel = vgui.Create("DLabel")
    pauseWarningLabel:SetText("")
    pauseWarningLabel:SetFont("DermaDefaultBold")
    pauseWarningLabel:SetTextColor(Color(255, 80, 80))
    pauseWarningLabel:SetWrap(true)
    pauseWarningLabel:SetAutoStretchVertical(true)
    pauseWarningLabel:SetVisible(false)
    motionTab:AddItem(pauseWarningLabel)

    -- Metadata of the selected motion (the importer's 7-field table), shown
    -- right under the selection. Hidden until a motion with metadata is picked.
    local motionMetaLabel = vgui.Create("DLabel")
    motionMetaLabel:SetText("")
    bounded_label(motionMetaLabel, "DermaDefault", Color(210, 220, 230), compactPanel and 34 or 40)
    motionMetaLabel:SetVisible(false)
    motionTab:AddItem(motionMetaLabel)

    -- Source link: a read-only text entry so the URL can be selected/copied,
    -- plus an Open button. The button opens the ORIGINAL metadata URL (stored
    -- on the row), never edited entry text.
    local linkRow = vgui.Create("DPanel")
    linkRow:SetTall(26)
    linkRow:SetPaintBackground(false)
    linkRow:SetVisible(false)
    linkRow.MetaURL = ""
    local linkOpen = vgui.Create("DButton", linkRow)
    linkOpen:Dock(RIGHT)
    linkOpen:SetWide(100)
    linkOpen:SetText(L("mmd_vmd_npc.manager.open_link", "Open Link"))
    linkOpen:SetTooltip(L("mmd_vmd_npc.ui.link_warning"))
    linkOpen.DoClick = function()
        local url = linkRow.MetaURL
        if url == "" then return end
        -- gui.OpenURL silently ignores scheme-less URLs ("www.youtube.com/...").
        if not string.match(url, "^https?://") then url = "https://" .. url end
        gui.OpenURL(url)
    end
    local linkEntry = vgui.Create("DTextEntry", linkRow)
    linkEntry:Dock(FILL)
    linkEntry:DockMargin(0, 0, 6, 0)
    linkEntry:SetEditable(false)
    motionTab:AddItem(linkRow)

    local linkWarning = vgui.Create("DLabel")
    linkWarning:SetText(L("mmd_vmd_npc.ui.link_warning"))
    bounded_label(linkWarning, "DermaDefaultBold", Color(255, 170, 70), compactPanel and 28 or 34)
    linkWarning:SetVisible(false)
    motionTab:AddItem(linkWarning)

    local function update_selected_meta(meta)
        if not IsValid(motionMetaLabel) or not IsValid(linkRow) or not IsValid(linkWarning) then return end
        meta = istable(meta) and meta or nil
        local parts = {}
        local function add(labelKey, fallback, value)
            value = tostring(value or "")
            if value ~= "" then
                parts[#parts + 1] = L(labelKey, fallback) .. ": " .. value
            end
        end
        if meta then
            add("mmd_vmd_npc.meta.category", "Category",
                (meta.category and meta.category ~= "" and MMDVMDNPC.CategoryDisplayName) and MMDVMDNPC.CategoryDisplayName(meta.category) or "")
            add("mmd_vmd_npc.meta.english_name", "English", meta.englishName)
            add("mmd_vmd_npc.meta.artist", "Artist", meta.artist)
            add("mmd_vmd_npc.meta.language", "Language", meta.language)
            add("mmd_vmd_npc.meta.motion_artist", "Motion Artist", meta.motionArtist)
        end
        motionMetaLabel:SetText(table.concat(parts, "  |  "))
        motionMetaLabel:SetVisible(#parts > 0)
        local link = meta and tostring(meta.link or "") or ""
        linkRow.MetaURL = link
        -- Only rewrite when changed: the details hooks fire in bursts and an
        -- unconditional SetValue would drop an in-progress copy selection.
        if IsValid(linkEntry) and linkEntry:GetValue() ~= link then linkEntry:SetValue(link) end
        linkRow:SetVisible(link ~= "")
        linkWarning:SetVisible(link ~= "")
        motionTab:InvalidateLayout()
    end

    local function convar_number(name)
        local cvar = GetConVar(name)
        if not cvar then return 0 end
        return tonumber(cvar:GetString()) or 0
    end

    local function update_pause_warning()
        if not IsValid(pauseWarningLabel) then return end
        local pauseStatus = MMDVMDNPC.PauseStatus or {}
        local svPause = tonumber(pauseStatus.svPause) or convar_number("sv_pause")
        local svPauseSP = tonumber(pauseStatus.svPauseSP) or convar_number("sv_pause_sp")
        local paused = svPause ~= 0 or svPauseSP ~= 0
        pauseWarningLabel:SetVisible(paused)
        pauseWarningLabel:SetText(paused and LF("mmd_vmd_npc.ui.pause_warning_fmt", tostring(svPause), tostring(svPauseSP)) or "")
    end

    local function request_pause_status()
        if MMDVMDNPC and MMDVMDNPC.RequestPauseStatus then
            MMDVMDNPC.RequestPauseStatus()
        end
        update_pause_warning()
    end

    timer.Create(hookID .. "_PauseWarning", 0.5, 0, request_pause_status)

    -- Category + text filter row above the motion list (same category set as
    -- the Motion Manager: addon categories + "User Import"). The motion table
    -- lives directly under the selected-motion header; the music settings
    -- follow it further down.
    local stoolCategoryFilter = cookie and cookie.GetString and cookie.GetString("mmdvmd_tool_category", "") or ""
    local filterRow = vgui.Create("DPanel")
    filterRow:SetTall(26)
    filterRow:SetPaintBackground(false)
    local categoryCombo = vgui.Create("DComboBox", filterRow)
    categoryCombo:Dock(LEFT)
    categoryCombo:SetWide(150)
    categoryCombo:SetSortItems(false)
    local motionSearch = vgui.Create("DTextEntry", filterRow)
    motionSearch:Dock(FILL)
    motionSearch:DockMargin(6, 0, 0, 0)
    motionSearch:SetPlaceholderText(L("mmd_vmd_npc.manager.search_placeholder"))
    motionTab:AddItem(filterRow)

    local motionList = vgui.Create("DListView")
    motionList:SetTall(compactPanel and 190 or 250)
    motionList:SetMultiSelect(false)
    motionList:AddColumn(L("mmd_vmd_npc.ui.column.motion"))
    local englishColumn = motionList:AddColumn(L("mmd_vmd_npc.manager.column_english"))
    if IsValid(englishColumn) and englishColumn.SetMinWidth then englishColumn:SetMinWidth(85) end
    local categoryColumn = motionList:AddColumn(L("mmd_vmd_npc.manager.column_category"))
    if IsValid(categoryColumn) and categoryColumn.SetMinWidth then categoryColumn:SetMinWidth(90) end
    motionList:AddColumn(L("mmd_vmd_npc.ui.column.duration"))
    motionTab:AddItem(motionList)

    local function stool_category_display(category)
        if (category or "") == "" then return L("mmd_vmd_npc.category.all", "All Categories") end
        return MMDVMDNPC.CategoryDisplayName and MMDVMDNPC.CategoryDisplayName(category) or category
    end

    local function rebuild_stool_category_combo()
        if not IsValid(categoryCombo) then return end
        -- Never rebuild under an open dropdown; and add choices WITHOUT the
        -- select flag (it fires OnSelect synchronously, rewriting the cookie
        -- as a side effect of every rebuild) — display via SetValue instead.
        if categoryCombo.IsMenuOpen and categoryCombo:IsMenuOpen() then return end
        categoryCombo:Clear()
        categoryCombo:AddChoice(L("mmd_vmd_npc.category.all", "All Categories"), "")
        local found = stoolCategoryFilter == ""
        if MMDVMDNPC.MotionCategories then
            for _, category in ipairs(MMDVMDNPC.MotionCategories()) do
                found = found or category == stoolCategoryFilter
                categoryCombo:AddChoice(stool_category_display(category), category)
            end
        end
        if found or #(MMDVMDNPC.MotionDetailsOrdered or {}) == 0 then
            -- Keep the remembered filter while the details have not streamed
            -- yet; a later rebuild (details hook) genuinely validates it.
            categoryCombo:SetValue(stool_category_display(stoolCategoryFilter))
        else
            stoolCategoryFilter = ""
            if cookie and cookie.Set then cookie.Set("mmdvmd_tool_category", "") end
            categoryCombo:SetValue(stool_category_display(""))
        end
    end
    rebuild_stool_category_combo()
    local targetLabel = vgui.Create("DLabel")
    local assignmentLabel = vgui.Create("DLabel")
    local buildLabel = vgui.Create("DLabel")
    local buildProgress = vgui.Create("DProgress")
    local playLabel = vgui.Create("DLabel")
    local motionInfo = vgui.Create("DLabel")
    local eyeStatusLabel = vgui.Create("DLabel")
    local update_motion_details
    local update_eye_status

    local function duration_text(meta)
        if not meta then return L("mmd_vmd_npc.ui.loading") end
        return string.format("%.2fs", tonumber(meta.duration) or 0)
    end

    local suppressRowSelect = false

    local function stool_category_text(meta)
        -- Unknown metadata (details not streamed, or a deleted motion) shows
        -- an empty category rather than confidently claiming "User Import".
        if not istable(meta) or (meta.category or "") == "" then return "" end
        if MMDVMDNPC.CategoryDisplayName then
            return MMDVMDNPC.CategoryDisplayName(meta.category)
        end
        return tostring(meta.category)
    end

    local function stool_row_matches(meta, id, query)
        if MMDVMDNPC.MotionMatchesCategory and not MMDVMDNPC.MotionMatchesCategory(meta, stoolCategoryFilter) then
            return false
        end
        if query == "" then return true end
        local haystack = string.lower(table.concat({
            id,
            motion_display_name(meta or id),
            istable(meta) and meta.englishName or "",
            istable(meta) and meta.artist or "",
            istable(meta) and meta.motionArtist or "",
        }, " "))
        return string.find(haystack, query, 1, true) ~= nil
    end

    local function refresh_motion_list_now()
        if not IsValid(motionList) then return end
        motionList:Clear()
        local current = GetConVar("mmd_vmd_npc_motion")
        local selected = current and current:GetString() or ""
        local selectedLine = nil
        local seen = {}
        local detailsOrdered = MMDVMDNPC.MotionDetailsOrdered or {}
        local detailsByID = MMDVMDNPC.MotionDetails or {}
        local query = string.lower(IsValid(motionSearch) and motionSearch:GetValue() or "")

        local function english_text(meta)
            return istable(meta) and tostring(meta.englishName or "") or ""
        end

        local rows = {}
        local function add_row(id, meta)
            seen[id] = true
            if not stool_row_matches(meta, id, query) then return end
            -- Default order: alphabetical by English name, falling back to
            -- the display name for motions without one, so mixed-language
            -- packs still read as a single sorted list.
            local english = english_text(meta)
            rows[#rows + 1] = {
                id = id,
                meta = meta,
                sortKey = string.lower(english ~= "" and english or motion_display_name(meta or id)),
            }
        end

        if #detailsOrdered > 0 then
            for _, meta in ipairs(detailsOrdered) do
                local id = tostring(meta.id or "")
                if id ~= "" then add_row(id, meta) end
            end
        else
            for _, id in ipairs(MMDVMDNPC.ClientMotions or {}) do
                id = tostring(id or "")
                if id ~= "" then add_row(id, detailsByID[id]) end
            end
        end

        table.sort(rows, function(a, b)
            if a.sortKey ~= b.sortKey then return a.sortKey < b.sortKey end
            return a.id < b.id
        end)
        for _, row in ipairs(rows) do
            local line = motionList:AddLine(motion_display_name(row.meta or row.id), english_text(row.meta), stool_category_text(row.meta), duration_text(row.meta))
            line.MotionID = row.id
            line.Meta = row.meta
            if row.id == selected then selectedLine = line end
        end

        -- Keep the currently selected motion visible even when it is missing
        -- from the list (deleted) or hidden by the active filters.
        if selected ~= "" and not selectedLine then
            local label = seen[selected] and motion_display_name(selected) or selected
            selectedLine = motionList:AddLine(label, english_text(detailsByID[selected]),
                stool_category_text(detailsByID[selected]),
                seen[selected] and duration_text(detailsByID[selected]) or L("mmd_vmd_npc.ui.missing"))
            selectedLine.MotionID = selected
            selectedLine.Meta = detailsByID[selected]
        end

        if selectedLine then
            -- Purely visual re-selection: the motion convar already holds this
            -- id, so suppress OnRowSelected (it would fire a console command +
            -- an audio-settings net request per rebuild — i.e. per keystroke).
            suppressRowSelect = true
            if motionList.SelectItem then
                motionList:SelectItem(selectedLine)
            elseif selectedLine.SetSelected then
                selectedLine:SetSelected(true)
            end
            suppressRowSelect = false
        end
    end

    -- The list/details hooks fire in bursts around every action; coalesce the
    -- full Derma rebuild to once per frame.
    local function refresh_motion_list()
        timer.Create(hookID .. "_MotionRefresh", 0, 1, function()
            refresh_motion_list_now()
        end)
    end

    categoryCombo.OnSelect = function(_, _, _, value)
        stoolCategoryFilter = tostring(value or "")
        if cookie and cookie.Set then cookie.Set("mmdvmd_tool_category", stoolCategoryFilter) end
        refresh_motion_list()
    end
    motionSearch.OnChange = function()
        refresh_motion_list()
    end
    hook.Add("MMDVMDNPCMotionDetailsUpdated", hookID .. "_CategoryCombo", rebuild_stool_category_combo)

    -- One-click wheel curation from the spawn menu: acts on the selected
    -- motion, label follows the selection state.
    local wheelQuickButton
    local function update_wheel_quick_button()
        if not IsValid(wheelQuickButton) then return end
        local current = GetConVar("mmd_vmd_npc_motion")
        local motionID = current and current:GetString() or ""
        if motionID ~= "" and MMDVMDNPC.IsFavorite and MMDVMDNPC.IsFavorite(motionID) then
            wheelQuickButton:SetText(L("mmd_vmd_npc.manager.wheel_remove", "★ Remove From Wheel"))
        else
            wheelQuickButton:SetText(L("mmd_vmd_npc.manager.wheel_add", "☆ Add To Wheel"))
        end
    end
    wheelQuickButton = colored_button(motionTab, L("mmd_vmd_npc.manager.wheel_add", "☆ Add To Wheel"), Color(200, 150, 40), function()
        local current = GetConVar("mmd_vmd_npc_motion")
        local motionID = current and current:GetString() or ""
        if motionID == "" or not MMDVMDNPC.ToggleFavorite then
            notification.AddLegacy(L("mmd_vmd_npc.manager.wheel_select_first", "Select a motion from the list first."), NOTIFY_ERROR, 3)
            return
        end
        local isAdded = MMDVMDNPC.ToggleFavorite(motionID)
        if isAdded then
            surface.PlaySound("garrysmod/content_downloaded.wav")
            notification.AddLegacy(L("mmd_vmd_npc.manager.wheel_added", "Added to wheel!"), NOTIFY_GENERIC, 3)
        else
            surface.PlaySound("buttons/button15.wav")
            notification.AddLegacy(L("mmd_vmd_npc.manager.wheel_removed", "Removed from wheel"), NOTIFY_CLEANUP, 3)
        end
        update_wheel_quick_button()
    end)
    update_wheel_quick_button()
    -- Wheel membership can change from the Motion Manager while this panel is
    -- open; keep the quick button's label truthful. (Registered here, after
    -- update_wheel_quick_button exists, so the closure captures the local.)
    hook.Add("MMDVMDNPCWheelFavoritesChanged", hookID .. "_WheelFav", update_wheel_quick_button)

    motionList.OnRowSelected = function(_, _, line)
        if suppressRowSelect then return end
        if not line or not line.MotionID then return end
        RunConsoleCommand("mmd_vmd_npc_motion", line.MotionID)
        if MMDVMDNPC and MMDVMDNPC.RequestAudioSettings then
            MMDVMDNPC.RequestAudioSettings(line.MotionID)
        end
        -- The convar write above is deferred a tick; refresh the wheel button
        -- from the actually-clicked row.
        timer.Simple(0, update_wheel_quick_button)
        if update_motion_details then
            timer.Simple(0, function()
                if IsValid(motionInfo) then
                    update_motion_details()
                end
            end)
        end
    end

    local audioOffsetSlider = vgui.Create("DNumSlider")
    audioOffsetSlider:SetText(L("mmd_vmd_npc.ui.music_offset"))
    audioOffsetSlider:SetMin(-5)
    audioOffsetSlider:SetMax(5)
    audioOffsetSlider:SetDecimals(2)
    audioOffsetSlider:SetValue(0)
    audioOffsetSlider:SetTall(42)
    motionTab:AddItem(audioOffsetSlider)

    add_checkbox_with_help(motionTab, L("mmd_vmd_npc.ui.play_imported_music"), "mmd_vmd_npc_music_enabled", L("mmd_vmd_npc.ui.play_imported_music_help"))
    add_slider(motionTab, L("mmd_vmd_npc.ui.music_volume"), "mmd_vmd_npc_music_volume", 0, 2, 2)
    add_checkbox_with_help(motionTab, L("mmd_vmd_npc.ui.music_omni"), "mmd_vmd_npc_music_omni", L("mmd_vmd_npc.ui.music_omni_help"))
    add_slider(motionTab, L("mmd_vmd_npc.ui.music_range"), "mmd_vmd_npc_music_range", 100, 5000, 0)
    add_slider(motionTab, L("mmd_vmd_npc.ui.music_fade"), "mmd_vmd_npc_music_fade", 10, 2000, 0)
    motionTab:Help(L("mmd_vmd_npc.ui.music_range_help"))
    add_checkbox_with_help(motionTab, L("mmd_vmd_npc.ui.loop_playback"), "mmd_vmd_npc_loop_playback", L("mmd_vmd_npc.ui.loop_playback_help"))

    audioOffsetSlider.OnValueChanged = function(_, value)
        if audioOffsetSuppress then return end
        local current = GetConVar("mmd_vmd_npc_motion")
        local motionID = current and current:GetString() or ""
        if motionID == "" then return end
        local timerName = hookID .. "_AudioOffsetSave"
        timer.Create(timerName, 0.25, 1, function()
            if MMDVMDNPC and MMDVMDNPC.SaveAudioOffset then
                MMDVMDNPC.SaveAudioOffset(motionID, math.Clamp(tonumber(value) or 0, -5, 5))
            end
        end)
    end

    refresh_motion_list()
    hook.Add("MMDVMDNPCMotionListUpdated", hookID, refresh_motion_list)

    colored_button(motionTab, L("mmd_vmd_npc.ui.open_motion_manager"), Color(60, 130, 210), function()
        RunConsoleCommand("mmdvmd_menu")
    end)
    colored_button(motionTab, L("mmd_vmd_npc.ui.refresh_motion_list"), Color(80, 110, 150), function()
        RunConsoleCommand("mmdvmd_list")
        if MMDVMDNPC and MMDVMDNPC.RequestMotionDetails then
            MMDVMDNPC.RequestMotionDetails()
        end
    end)
    colored_button(motionTab, L("mmd_vmd_npc.ui.stop_stuck_build_tasks"), Color(185, 90, 45), function()
        if MMDVMDNPC and MMDVMDNPC.RequestCancelBuildTasks then
            MMDVMDNPC.RequestCancelBuildTasks()
        end
    end)

    section(motionTab, L("mmd_vmd_npc.ui.radial_wheel"), Color(255, 200, 90))
    motionTab:Help(L("mmd_vmd_npc.ui.radial_wheel_help"))

    motionInfo:SetText(L("mmd_vmd_npc.ui.motion_no_metadata"))
    bounded_label(motionInfo, "DermaDefault", Color(210, 220, 230), compactPanel and 40 or 52)
    motionTab:AddItem(motionInfo)

    section(motionTab, L("mmd_vmd_npc.ui.target"), Color(80, 220, 140))
    targetLabel:SetText(L("mmd_vmd_npc.ui.selected_actor_none"))
    bounded_label(
        targetLabel,
        compactPanel and "DermaDefaultBold" or "DermaLarge",
        Color(100, 235, 150),
        compactPanel and 48 or 64
    )
    motionTab:AddItem(targetLabel)

    assignmentLabel:SetText(L("mmd_vmd_npc.ui.coordinated_npcs_zero"))
    bounded_label(assignmentLabel, "DermaDefaultBold", Color(120, 205, 255), compactPanel and 34 or 44)
    motionTab:AddItem(assignmentLabel)

    colored_button(motionTab, L("mmd_vmd_npc.ui.play_selected_group"), Color(80, 155, 230), function()
        if MMDVMDNPC and MMDVMDNPC.RequestPlayAssignedGroup then
            MMDVMDNPC.RequestPlayAssignedGroup()
        end
    end)

    colored_button(motionTab, L("mmd_vmd_npc.ui.stop_animation"), Color(190, 70, 70), function()
        if MMDVMDNPC and MMDVMDNPC.RequestStopSelectedMotion then
            MMDVMDNPC.RequestStopSelectedMotion()
        end
    end)

    colored_button(motionTab, L("mmd_vmd_npc.ui.clear_selection"), Color(150, 95, 95), function()
        if MMDVMDNPC and MMDVMDNPC.RequestClearAssignedActors then
            MMDVMDNPC.RequestClearAssignedActors("all")
        end
    end)

    colored_button(motionTab, L("mmd_vmd_npc.ui.clear_missing_invalid"), Color(165, 125, 70), function()
        if MMDVMDNPC and MMDVMDNPC.RequestClearAssignedActors then
            MMDVMDNPC.RequestClearAssignedActors("missing")
        end
    end)

    colored_button(motionTab, L("mmd_vmd_npc.ui.select_yourself"), Color(70, 150, 90), function()
        if MMDVMDNPC and MMDVMDNPC.RequestSelectSelf then
            MMDVMDNPC.RequestSelectSelf()
        else
            print("[MMD VMD] " .. L("mmd_vmd_npc.hint.self_keys"))
        end
    end)
    motionTab:Help(L("mmd_vmd_npc.ui.self_help"))

    section(playbackTab, L("mmd_vmd_npc.ui.build"), Color(255, 190, 80))
    buildLabel:SetText(L("mmd_vmd_npc.ui.build_idle"))
    buildLabel:SetWrap(true)
    buildLabel:SetAutoStretchVertical(true)
    playbackTab:AddItem(buildLabel)

    buildProgress:SetFraction(0)
    playbackTab:AddItem(buildProgress)

    colored_button(playbackTab, L("mmd_vmd_npc.ui.build_selected_motion"), Color(210, 145, 45), function()
        if MMDVMDNPC and MMDVMDNPC.RequestBuildSelectedMotion then
            MMDVMDNPC.RequestBuildSelectedMotion()
        end
    end)

    colored_button(playbackTab, L("mmd_vmd_npc.ui.stop_build_tasks"), Color(185, 90, 45), function()
        if MMDVMDNPC and MMDVMDNPC.RequestCancelBuildTasks then
            MMDVMDNPC.RequestCancelBuildTasks()
        end
    end)

    section(playbackTab, L("mmd_vmd_npc.ui.playback"), Color(100, 190, 255))
    playLabel:SetText(L("mmd_vmd_npc.ui.playback_idle"))
    playLabel:SetWrap(true)
    playLabel:SetAutoStretchVertical(true)
    playbackTab:AddItem(playLabel)

    colored_button(playbackTab, L("mmd_vmd_npc.ui.play_built_animation"), Color(70, 165, 220), function()
        if MMDVMDNPC and MMDVMDNPC.RequestPlaySelectedMotion then
            MMDVMDNPC.RequestPlaySelectedMotion()
        end
    end)

    colored_button(playbackTab, L("mmd_vmd_npc.ui.stop_animation"), Color(190, 70, 70), function()
        if MMDVMDNPC and MMDVMDNPC.RequestStopSelectedMotion then
            MMDVMDNPC.RequestStopSelectedMotion()
        end
    end)

    add_slider(playbackTab, L("mmd_vmd_npc.ui.start_delay"), "mmd_vmd_npc_start_delay", 2, 20, 1)
    add_slider(playbackTab, L("mmd_vmd_npc.ui.pelvis_z_offset"), "mmd_vmd_npc_pelvis_z_offset", -16, 16, 1)
    add_slider(playbackTab, L("mmd_vmd_npc.ui.thirdperson_distance"), "mmd_vmd_npc_thirdperson_distance", 40, 260, 0)
    add_slider(playbackTab, L("mmd_vmd_npc.ui.thirdperson_height"), "mmd_vmd_npc_thirdperson_height", -20, 90, 0)

    section(motionTab, L("mmd_vmd_npc.ui.display_playback"), Color(150, 210, 255))
    add_checkbox_with_help(motionTab, L("mmd_vmd_npc.ui.hide_hud"), "mmd_vmd_npc_hide_hud", L("mmd_vmd_npc.ui.hide_hud_help"))
    key_binder(motionTab, L("mmd_vmd_npc.ui.hide_hud_key"), "mmd_vmd_npc_hide_hud_key", Color(150, 210, 255))
    add_checkbox_with_help(motionTab, L("mmd_vmd_npc.ui.disable_jiggle"), "mmd_vmd_npc_disable_jiggle", L("mmd_vmd_npc.ui.disable_jiggle_help"))

    section(motionTab, L("mmd_vmd_npc.ui.eye_tracking"), Color(120, 210, 255))
    add_checkbox_with_help(motionTab, L("mmd_vmd_npc.ui.enable_eye_tracking"), "mmd_vmd_npc_eye_track", L("mmd_vmd_npc.ui.enable_eye_tracking_help"))
    add_slider(motionTab, L("mmd_vmd_npc.ui.eye_smoothing"), "mmd_vmd_npc_eye_track_smooth", 0.1, 30, 2)
    add_slider(motionTab, L("mmd_vmd_npc.ui.eye_moveback"), "mmd_vmd_npc_eye_track_moveback", -0.25, 1, 2)
    add_slider(motionTab, L("mmd_vmd_npc.ui.eye_pos_ud"), "mmd_vmd_npc_eye_track_pos_ud", 0, 2, 2)
    add_slider(motionTab, L("mmd_vmd_npc.ui.eye_pos_lr"), "mmd_vmd_npc_eye_track_pos_lr", 0, 2, 2)
    eyeStatusLabel:SetText(L("mmd_vmd_npc.ui.eye_no_target"))
    eyeStatusLabel:SetWrap(true)
    eyeStatusLabel:SetAutoStretchVertical(true)
    motionTab:AddItem(eyeStatusLabel)

    section(playbackTab, L("mmd_vmd_npc.ui.audio_sync"), Color(180, 130, 255))
    playbackTab:Help(L("mmd_vmd_npc.ui.audio_sync_help"))

    section(playbackTab, L("mmd_vmd_npc.ui.manage_built_cache"), Color(255, 110, 110))
    colored_button(playbackTab, L("mmd_vmd_npc.ui.clear_built_model"), Color(170, 80, 80), function()
        if MMDVMDNPC and MMDVMDNPC.RequestClearBuiltSelectedMotion then
            MMDVMDNPC.RequestClearBuiltSelectedMotion("model")
        end
    end)

    colored_button(playbackTab, L("mmd_vmd_npc.ui.clear_built_all"), Color(145, 65, 65), function()
        if MMDVMDNPC and MMDVMDNPC.RequestClearBuiltSelectedMotion then
            MMDVMDNPC.RequestClearBuiltSelectedMotion("all")
        end
    end)

    section(performanceTab, L("mmd_vmd_npc.ui.build_performance"), Color(255, 190, 80))
    performanceTab:Help(L("mmd_vmd_npc.ui.build_performance_help"))
    add_checkbox_with_help(performanceTab, L("mmd_vmd_npc.ui.fast_build"), "mmd_vmd_npc_fast_build", L("mmd_vmd_npc.ui.fast_build_help"))
    -- Cap the slider at the value every consumer actually clamps to
    -- (clamp_build_frames_per_batch); a higher slider range silently lies.
    add_slider(performanceTab, L("mmd_vmd_npc.ui.build_frames_per_batch"), "mmd_vmd_npc_build_frames_per_batch", MMDVMDNPC.MinBuildFramesPerBatch or 1, MMDVMDNPC.MaxBuildFramesPerBatch or 128, 0)

    section(performanceTab, L("mmd_vmd_npc.ui.playback_performance"), Color(100, 190, 255))
    performanceTab:Help(L("mmd_vmd_npc.ui.playback_performance_help"))
    -- Cap the slider at the value every consumer actually clamps to, so the UI
    add_slider(performanceTab, L("mmd_vmd_npc.ui.playback_updates_per_second"), "mmd_vmd_npc_playback_hz", MMDVMDNPC.MinPlaybackHz or 10, MMDVMDNPC.MaxPlaybackHz or 480, 0)

    section(advancedTab, L("mmd_vmd_npc.ui.tab.advanced"), Color(180, 180, 180))

    add_slider(advancedTab, L("mmd_vmd_npc.ui.menu_scale"), "mmd_vmd_npc_menu_scale", 0.6, 2.0, 2)
    advancedTab:Help(L("mmd_vmd_npc.ui.menu_scale_help"))

    advancedTab:CheckBox("Q: Show halos", "mmd_vmd_npc_show_halos") -- ADDED

    advancedTab:CheckBox(L("mmd_vmd_npc.ui.disable_armtwist"), "mmd_vmd_npc_disable_armtwist")
    advancedTab:CheckBox(L("mmd_vmd_npc.ui.disable_handtwist"), "mmd_vmd_npc_disable_handtwist")
    advancedTab:CheckBox(L("mmd_vmd_npc.ui.disable_eyes"), "mmd_vmd_npc_disable_eyes")
    advancedTab:CheckBox(L("mmd_vmd_npc.ui.disable_spine_pelvis"), "mmd_vmd_npc_disable_spine_pelvis_correction")

    colored_button(advancedTab, L("mmd_vmd_npc.ui.debug_selected_motion"), Color(95, 95, 110), function()
        local current = GetConVar("mmd_vmd_npc_motion")
        local motionID = current and current:GetString() or ""
        if motionID ~= "" and MMDVMDNPC and MMDVMDNPC.OpenDebugMenu then
            MMDVMDNPC.OpenDebugMenu(motionID, -1)
        else
            print("[MMD VMD] " .. L("mmd_vmd_npc.error.select_motion"))
        end
    end)

    -- Camera tab -----------------------------------------------------------------
    section(cameraTab, L("mmd_vmd_npc.ui.tab.camera"), Color(120, 200, 255))
    cameraTab:Help(L("mmd_vmd_npc.camera.tab_help"))
    key_binder(cameraTab, L("mmd_vmd_npc.camera.hotkey_label"), "mmd_vmd_npc_camera_key", Color(120, 200, 255))
    cameraTab:Help(L("mmd_vmd_npc.camera.hotkey_help"))
    add_checkbox_with_help(cameraTab, L("mmd_vmd_npc.camera.auto_option"), "mmd_vmd_npc_camera_auto", L("mmd_vmd_npc.camera.auto_option_help"))
    add_checkbox_with_help(cameraTab, L("mmd_vmd_npc.camera.follow"), "mmd_vmd_npc_cam_follow", L("mmd_vmd_npc.camera.follow_help"))
    add_slider(cameraTab, L("mmd_vmd_npc.camera.follow_margin"), "mmd_vmd_npc_cam_follow_margin", 0, 0.9, 2)
    add_slider(cameraTab, L("mmd_vmd_npc.camera.follow_speed"), "mmd_vmd_npc_cam_follow_speed", 1, 30, 0)
    add_checkbox_with_help(cameraTab, L("mmd_vmd_npc.camera.collision"), "mmd_vmd_npc_cam_collision", L("mmd_vmd_npc.camera.collision_help"))
    add_slider(cameraTab, L("mmd_vmd_npc.camera.max_distance"), "mmd_vmd_npc_cam_max_distance", 0, 6000, 0)

    section(cameraTab, L("mmd_vmd_npc.camera.transform"), Color(120, 200, 255))
    cameraTab:Help(L("mmd_vmd_npc.camera.transform_help"))
    add_slider(cameraTab, L("mmd_vmd_npc.camera.scale_x"), "mmd_vmd_npc_cam_scale_x", 0.1, 3, 2)
    add_slider(cameraTab, L("mmd_vmd_npc.camera.scale_y"), "mmd_vmd_npc_cam_scale_y", 0.1, 3, 2)
    add_slider(cameraTab, L("mmd_vmd_npc.camera.scale_z"), "mmd_vmd_npc_cam_scale_z", 0.1, 3, 2)
    add_slider(cameraTab, L("mmd_vmd_npc.camera.offset_x"), "mmd_vmd_npc_cam_offset_x", -128, 128, 0)
    add_slider(cameraTab, L("mmd_vmd_npc.camera.offset_y"), "mmd_vmd_npc_cam_offset_y", -128, 128, 0)
    add_slider(cameraTab, L("mmd_vmd_npc.camera.offset_z"), "mmd_vmd_npc_cam_offset_z", -128, 128, 0)
    add_slider(cameraTab, L("mmd_vmd_npc.camera.yaw"), "mmd_vmd_npc_cam_yaw", -180, 180, 0)
    add_slider(cameraTab, L("mmd_vmd_npc.camera.pitch"), "mmd_vmd_npc_cam_pitch", -90, 90, 0)
    add_slider(cameraTab, L("mmd_vmd_npc.camera.fov_offset"), "mmd_vmd_npc_cam_fov", -80, 80, 0)

    -- RTX-Remix lighting tab -----------------------------------------------------
    section(lightingTab, L("mmd_vmd_npc.ui.tab.lighting"), Color(255, 220, 120))
    lightingTab:Help(L("mmd_vmd_npc.lighting.tab_help"))
    add_checkbox_with_help(lightingTab, L("mmd_vmd_npc.lighting.enable"), "mmd_vmd_npc_flashlight_enabled", L("mmd_vmd_npc.lighting.enable_help"))
    key_binder(lightingTab, L("mmd_vmd_npc.lighting.hotkey_label"), "mmd_vmd_npc_flashlight_key", Color(255, 220, 120))
    lightingTab:Help(L("mmd_vmd_npc.lighting.hotkey_help"))
    add_checkbox_with_help(lightingTab, L("mmd_vmd_npc.lighting.follow_eye"), "mmd_vmd_npc_flashlight_follow_eye", L("mmd_vmd_npc.lighting.follow_eye_help"))
    add_checkbox_with_help(lightingTab, L("mmd_vmd_npc.lighting.shadows"), "mmd_vmd_npc_flashlight_shadows", L("mmd_vmd_npc.lighting.shadows_help"))

    section(lightingTab, L("mmd_vmd_npc.lighting.beam"), Color(255, 220, 120))
    add_slider(lightingTab, L("mmd_vmd_npc.lighting.brightness"), "mmd_vmd_npc_flashlight_brightness", 0, 100, 2)
    add_slider(lightingTab, L("mmd_vmd_npc.lighting.fov"), "mmd_vmd_npc_flashlight_fov", 5, 170, 0)
    add_slider(lightingTab, L("mmd_vmd_npc.lighting.distance"), "mmd_vmd_npc_flashlight_distance", 128, 8192, 0)
    add_slider(lightingTab, L("mmd_vmd_npc.lighting.nearz"), "mmd_vmd_npc_flashlight_nearz", 1, 64, 0)

    section(lightingTab, L("mmd_vmd_npc.lighting.rtx_shaping"), Color(255, 220, 120))
    lightingTab:Help(L("mmd_vmd_npc.lighting.rtx_shaping_help"))
    add_slider(lightingTab, L("mmd_vmd_npc.lighting.rtx_radius"), "mmd_vmd_npc_flashlight_rtx_radius", 1, 200, 0)
    add_slider(lightingTab, L("mmd_vmd_npc.lighting.rtx_softness"), "mmd_vmd_npc_flashlight_rtx_softness", 0, 1, 2)
    add_slider(lightingTab, L("mmd_vmd_npc.lighting.rtx_volumetric"), "mmd_vmd_npc_flashlight_rtx_volumetric", 0, 5, 1)

    section(lightingTab, L("mmd_vmd_npc.lighting.color"), Color(255, 220, 120))
    add_slider(lightingTab, L("mmd_vmd_npc.lighting.color_r"), "mmd_vmd_npc_flashlight_color_r", 0, 255, 0)
    add_slider(lightingTab, L("mmd_vmd_npc.lighting.color_g"), "mmd_vmd_npc_flashlight_color_g", 0, 255, 0)
    add_slider(lightingTab, L("mmd_vmd_npc.lighting.color_b"), "mmd_vmd_npc_flashlight_color_b", 0, 255, 0)

    section(lightingTab, L("mmd_vmd_npc.lighting.offset"), Color(255, 220, 120))
    add_slider(lightingTab, L("mmd_vmd_npc.lighting.offset_forward"), "mmd_vmd_npc_flashlight_offset_forward", -64, 64, 0)
    add_slider(lightingTab, L("mmd_vmd_npc.lighting.offset_right"), "mmd_vmd_npc_flashlight_offset_right", -64, 64, 0)
    add_slider(lightingTab, L("mmd_vmd_npc.lighting.offset_up"), "mmd_vmd_npc_flashlight_offset_up", -64, 64, 0)

    update_eye_status = function()
        if not IsValid(eyeStatusLabel) then return end
        local playStatus = MMDVMDNPC.PlayStatus or {}
        local targetStatus = MMDVMDNPC.TargetStatus or {}
        local ent = IsValid(playStatus.ent) and playStatus.ent or (IsValid(targetStatus.ent) and targetStatus.ent or nil)
        if MMDVMDNPC and MMDVMDNPC.ClientEyeBoneSummary then
            eyeStatusLabel:SetText(MMDVMDNPC.ClientEyeBoneSummary(ent))
        else
            eyeStatusLabel:SetText(L("mmd_vmd_npc.ui.eye_status_unavailable"))
        end
    end

    local function update_target(status)
        if not IsValid(targetLabel) then return end
        status = status or MMDVMDNPC.TargetStatus or {}
        if status.valid and IsValid(status.ent) then
            targetLabel:SetText(LF(
                "mmd_vmd_npc.ui.selected_actor_fmt",
                shorten_text(status.targetType or "actor", 18),
                shorten_text(status.ent, compactPanel and 22 or 34),
                shorten_text(status.model or "", pathLimit)
            ))
        else
            targetLabel:SetText(L("mmd_vmd_npc.ui.selected_actor_none"))
        end
        if update_eye_status then update_eye_status() end
    end

    local function update_build(status)
        if not IsValid(buildLabel) then return end
        status = status or MMDVMDNPC.BuildStatus or {}
        buildLabel:SetText(LF("mmd_vmd_npc.ui.build_status_fmt", tostring(status.message or status.status or "idle")))
        if IsValid(buildProgress) then
            buildProgress:SetFraction(math.Clamp(tonumber(status.progress) or 0, 0, 1))
        end
    end

    local function update_play(status)
        if not IsValid(playLabel) then return end
        status = status or MMDVMDNPC.PlayStatus or {}
        playLabel:SetText(LF("mmd_vmd_npc.ui.playback_status_fmt", tostring(status.message or status.status or "idle")))
        if update_eye_status then update_eye_status() end
    end

    local function update_assignments(assignments)
        if not IsValid(assignmentLabel) then return end
        assignments = assignments or MMDVMDNPC.AssignedActors or {}
        local order = assignments.order or {}
        local count = #order
        if count <= 0 then
            assignmentLabel:SetText(L("mmd_vmd_npc.ui.coordinated_npcs_zero"))
            return
        end

        local firstEnt = order[1]
        local first = assignments.byEnt and assignments.byEnt[firstEnt] or nil
        assignmentLabel:SetText(LF(
            "mmd_vmd_npc.ui.coordinated_npcs_fmt",
            count,
            IsValid(firstEnt) and shorten_text(firstEnt, compactPanel and 18 or 28) or "none",
            shorten_text(first and first.motionID or "", compactPanel and 20 or 34),
            shorten_text(first and first.status or "", compactPanel and 18 or 28)
        ))
    end

    update_motion_details = function()
        if not IsValid(motionInfo) then return end
        local current = GetConVar("mmd_vmd_npc_motion")
        local motionID = current and current:GetString() or ""
        local meta = MMDVMDNPC.MotionDetails and MMDVMDNPC.MotionDetails[motionID] or nil
        if IsValid(selectedMotionLabel) then
            selectedMotionLabel:SetText(motionID ~= "" and LF("mmd_vmd_npc.ui.selected_motion_fmt", shorten_text(motion_display_name(meta or motionID), textLimit)) or L("mmd_vmd_npc.ui.selected_motion_none"))
        end
        update_selected_meta(meta)
        if IsValid(audioOffsetSlider) then
            audioOffsetSuppress = true
            audioOffsetSlider:SetValue(math.Clamp(tonumber(MMDVMDNPC.AudioOffsets and MMDVMDNPC.AudioOffsets[motionID] or 0) or 0, -5, 5))
            audioOffsetSuppress = false
        end
        if meta then
            motionInfo:SetText(LF(
                "mmd_vmd_npc.ui.motion_info_fmt",
                shorten_text(motion_display_name(meta), textLimit),
                tonumber(meta.duration) or 0,
                tonumber(meta.frameCount) or 0,
                tonumber(meta.boneCount) or 0,
                tonumber(meta.flexCount) or 0,
                tostring(meta.musicSound or "") ~= "" and L("mmd_vmd_npc.ui.yes") or L("mmd_vmd_npc.ui.no"),
                meta.built and L("mmd_vmd_npc.ui.yes") or L("mmd_vmd_npc.ui.no")
            ))
        else
            motionInfo:SetText(motionID ~= "" and LF("mmd_vmd_npc.ui.motion_metadata_missing_fmt", shorten_text(motionID, textLimit)) or L("mmd_vmd_npc.ui.motion_none"))
        end
    end

    hook.Add("MMDVMDNPCTargetStatusUpdated", hookID .. "_Target", update_target)
    hook.Add("MMDVMDNPCAssignmentStatusUpdated", hookID .. "_Assignments", update_assignments)
    hook.Add("MMDVMDNPCBuildStatusUpdated", hookID .. "_Build", update_build)
    hook.Add("MMDVMDNPCPlayStatusUpdated", hookID .. "_Play", update_play)
    hook.Add("MMDVMDNPCMotionDetailsUpdated", hookID .. "_Details", function()
        refresh_motion_list()
        update_motion_details()
    end)
    hook.Add("MMDVMDNPCAudioSettingsUpdated", hookID .. "_Audio", function(motionID, offset)
        local current = GetConVar("mmd_vmd_npc_motion")
        local selected = current and current:GetString() or ""
        if motionID ~= selected or not IsValid(audioOffsetSlider) then return end
        audioOffsetSuppress = true
        audioOffsetSlider:SetValue(math.Clamp(tonumber(offset) or 0, -5, 5))
        audioOffsetSuppress = false
    end)
    hook.Add("MMDVMDNPCPauseStatusUpdated", hookID .. "_Pause", update_pause_warning)
    local oldOnRemove = panel.OnRemove
    panel.OnRemove = function()
        if oldOnRemove then oldOnRemove(panel) end
        timer.Remove(hookID .. "_AudioOffsetSave")
        timer.Remove(hookID .. "_PauseWarning")
        timer.Remove(hookID .. "_MotionRefresh")
        hook.Remove("MMDVMDNPCMotionListUpdated", hookID)
        hook.Remove("MMDVMDNPCMotionDetailsUpdated", hookID .. "_CategoryCombo")
        hook.Remove("MMDVMDNPCWheelFavoritesChanged", hookID .. "_WheelFav")
        hook.Remove("MMDVMDNPCTargetStatusUpdated", hookID .. "_Target")
        hook.Remove("MMDVMDNPCAssignmentStatusUpdated", hookID .. "_Assignments")
        hook.Remove("MMDVMDNPCBuildStatusUpdated", hookID .. "_Build")
        hook.Remove("MMDVMDNPCPlayStatusUpdated", hookID .. "_Play")
        hook.Remove("MMDVMDNPCMotionDetailsUpdated", hookID .. "_Details")
        hook.Remove("MMDVMDNPCAudioSettingsUpdated", hookID .. "_Audio")
        hook.Remove("MMDVMDNPCPauseStatusUpdated", hookID .. "_Pause")
    end
    update_target()
    update_assignments()
    update_build()
    update_play()
    update_motion_details()
    update_eye_status()
    request_pause_status()

    if MMDVMDNPC and MMDVMDNPC.RequestMotionList then
        MMDVMDNPC.RequestMotionList()
    end
    if MMDVMDNPC and MMDVMDNPC.RequestMotionDetails then
        MMDVMDNPC.RequestMotionDetails()
    end
    do
        local current = GetConVar("mmd_vmd_npc_motion")
        local motionID = current and current:GetString() or ""
        if motionID ~= "" and MMDVMDNPC and MMDVMDNPC.RequestAudioSettings then
            MMDVMDNPC.RequestAudioSettings(motionID)
        end
    end
end
