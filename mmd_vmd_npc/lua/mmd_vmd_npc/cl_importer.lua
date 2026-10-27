-- In-game motion import, the game half. Model Hotloader's binary module lets
-- client addons read files the player chooses (mmdhl.FileAccess; its
-- docs/FILE_ACCESS.md). With it, the tool panel offers an importer window
-- with the desktop importer's inputs; this file reads the chosen files,
-- runs the conversion of cl_import_bake.lua in a coroutine a slice per frame
-- and writes the motion JSON (and its music) into data/mmd_vmd_npc/, where
-- the addon lists it with the motions the desktop importer writes. Without
-- file access the tool panel shows why, with a Resolve button.
MMDVMDNPC = MMDVMDNPC or {}
local Importer = MMDVMDNPC.Importer or {}
MMDVMDNPC.Importer = Importer

local function L(key, fallback)
    return MMDVMDNPC.L and MMDVMDNPC.L(key, fallback) or (fallback or key)
end

local function LF(key, ...)
    return MMDVMDNPC.LFormat and MMDVMDNPC.LFormat(key, ...) or string.format(L(key, key), ...)
end

-- The name Model Hotloader's Windows dialogs show, and the key it remembers
-- "always allow" folders by: keep it stable (not translated).
local ADDON_NAME = "Advanced MMD Animation Player"
Importer.WorkshopURL = "https://steamcommunity.com/sharedfiles/filedetails/?id=3810025467"
Importer.GitHubURL = "https://github.com/SheepyLord/Gmod-Model-Hotloader-with-Vulkan"
-- File access reads at most 16 MiB per call.
local READ_CHUNK = 16 * 1024 * 1024
-- Seconds of import work per game frame.
local FRAME_BUDGET = 0.012
local MUSIC_ROOT = MMDVMDNPC.DataRoot .. "/music"
local AUDIO_EXTENSIONS = { "mp3", "ogg", "wav" }
local CANCELLED = setmetatable({}, { __tostring = function() return "Import cancelled" end })
local META_FIELDS = { "category", "display_name", "english_name", "artist", "language", "link", "motion_artist" }

local TEXT_FONT = "MMDVMDNPCManagerText"
local BOLD_FONT = "MMDVMDNPCManagerTextBold"
local SMALL_FONT = "MMDVMDNPCManagerDetails"
local TEXT_COLOR = Color(235, 238, 242)
local MUTED_COLOR = Color(150, 158, 168)
local WARNING_COLOR = Color(255, 190, 90)

-- ---------------------------------------------------------------------------
-- Availability
-- ---------------------------------------------------------------------------
local function file_access()
    local FA = istable(mmdhl) and mmdhl.FileAccess or nil
    if istable(FA) and isfunction(FA.IsAvailable) and isfunction(FA.Pick) and isfunction(FA.Read) then return FA end
    return nil
end

-- true, or false with the reason to show and a code: "not_installed", or
-- Model Hotloader's own (needs_update, unavailable_remote, disabled, ...).
function MMDVMDNPC.ImporterAvailability()
    local FA = file_access()
    if not FA then return false, L("mmd_vmd_npc.import.not_installed"), "not_installed" end
    local ok, available, reason, code = pcall(FA.IsAvailable)
    if not ok then return false, tostring(available), "error" end
    if available then return true end
    return false, tostring(reason or ""), tostring(code or "unavailable")
end

local function availability_changed()
    hook.Run("MMDVMDNPCImportAvailabilityChanged")
end
hook.Add("MMDHL.FileAccessReady", "MMDVMDNPCImporter", function() availability_changed() end)
hook.Add("MMDHL.FileAccessChanged", "MMDVMDNPCImporter", function() availability_changed() end)
hook.Add("MMDHL.InstallationChanged", "MMDVMDNPCImporter", function() availability_changed() end)

-- ---------------------------------------------------------------------------
-- Shared bits of the windows
-- ---------------------------------------------------------------------------
local function scaled(value)
    local scale = MMDVMDNPC.MenuScale and MMDVMDNPC.MenuScale() or 1
    return math.floor(value * scale + 0.5)
end

local function add_label(parent, text, font, color, wrap)
    local label = vgui.Create("DLabel", parent)
    label:SetFont(font or TEXT_FONT)
    label:SetText(text or "")
    label:SetTextColor(color or TEXT_COLOR)
    if wrap then
        label:SetWrap(true)
        label:SetAutoStretchVertical(true)
    end
    return label
end

local function add_button(parent, text, onClick)
    local button = vgui.Create("DButton", parent)
    button:SetText(text)
    button:SetFont(TEXT_FONT)
    button.DoClick = onClick
    return button
end

local function accent_button(parent, text, color, onClick)
    local button = add_button(parent, text, onClick)
    button.Paint = function(self, w, h)
        local c = color
        if not self:IsEnabled() then
            c = Color(85, 90, 98)
        elseif self:IsHovered() then
            c = Color(math.min(c.r + 25, 255), math.min(c.g + 25, 255), math.min(c.b + 25, 255))
        end
        draw.RoundedBox(5, 0, 0, w, h, c)
        draw.SimpleText(self:GetText(), BOLD_FONT, w * 0.5, h * 0.5, self:IsEnabled() and color_white or Color(175, 180, 186), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        return true
    end
    return button
end

local function open_url(url)
    -- gui.OpenURL silently ignores scheme-less URLs.
    if not string.match(url, "^https?://") then url = "https://" .. url end
    gui.OpenURL(url)
end

-- ---------------------------------------------------------------------------
-- The Resolve window: why hot import is unavailable and where to get it.
-- ---------------------------------------------------------------------------
function MMDVMDNPC.OpenImporterResolve()
    if IsValid(Importer.ResolveFrame) then Importer.ResolveFrame:Remove() end
    local frame = vgui.Create("DFrame")
    Importer.ResolveFrame = frame
    frame:SetTitle(L("mmd_vmd_npc.import.resolve_title"))
    frame:SetSize(math.min(scaled(660), ScrW() - 40), math.min(scaled(440), ScrH() - 40))
    frame:Center()
    frame:MakePopup()
    frame:DockPadding(scaled(14), scaled(34), scaled(14), scaled(12))

    local buttons = vgui.Create("DPanel", frame)
    buttons:Dock(BOTTOM)
    buttons:SetTall(scaled(34))
    buttons:SetPaintBackground(false)
    local close = add_button(buttons, L("mmd_vmd_npc.import.close"), function() frame:Close() end)
    close:Dock(RIGHT)
    close:SetWide(scaled(120))
    local action = add_button(buttons, "", nil)
    action:Dock(LEFT)
    action:SetWide(scaled(230))

    local scroll = vgui.Create("DScrollPanel", frame)
    scroll:Dock(FILL)
    local body = add_label(scroll, "", TEXT_FONT, TEXT_COLOR, true)
    body:Dock(TOP)
    local reasonLabel = add_label(scroll, "", SMALL_FONT, WARNING_COLOR, true)
    reasonLabel:Dock(TOP)
    reasonLabel:DockMargin(0, scaled(8), 0, 0)

    local function link_row(title, url)
        local caption = add_label(scroll, title, BOLD_FONT, TEXT_COLOR)
        caption:Dock(TOP)
        caption:DockMargin(0, scaled(12), 0, scaled(2))
        caption:SetTall(scaled(22))
        local row = vgui.Create("DPanel", scroll)
        row:Dock(TOP)
        row:SetTall(scaled(28))
        row:SetPaintBackground(false)
        local open = add_button(row, L("mmd_vmd_npc.import.open_link"), function() open_url(url) end)
        open:Dock(RIGHT)
        open:SetWide(scaled(110))
        open:DockMargin(scaled(6), 0, 0, 0)
        local entry = vgui.Create("DTextEntry", row)
        entry:Dock(FILL)
        entry:SetFont(TEXT_FONT)
        entry:SetEditable(false)
        entry:SetValue(url)
    end
    link_row(L("mmd_vmd_npc.import.link_workshop"), Importer.WorkshopURL)
    link_row(L("mmd_vmd_npc.import.link_github"), Importer.GitHubURL)
    local desktop = add_label(scroll, L("mmd_vmd_npc.import.resolve_desktop"), SMALL_FONT, MUTED_COLOR, true)
    desktop:Dock(TOP)
    desktop:DockMargin(0, scaled(14), 0, 0)

    local function refresh()
        if not IsValid(frame) then return end
        local available, reason, code = MMDVMDNPC.ImporterAvailability()
        if available then
            body:SetText(L("mmd_vmd_npc.import.resolve_ready"))
        elseif code == "not_installed" then
            body:SetText(L("mmd_vmd_npc.import.resolve_not_installed"))
        else
            body:SetText(L("mmd_vmd_npc.import.resolve_unavailable"))
        end
        local showReason = not available and code ~= "not_installed" and reason ~= ""
        reasonLabel:SetText(showReason and LF("mmd_vmd_npc.import.resolve_reason_fmt", reason) or "")
        reasonLabel:SetVisible(showReason)
        local FA = file_access()
        if available then
            action:SetText(L("mmd_vmd_npc.import.open_importer"))
            action.DoClick = function() frame:Close() MMDVMDNPC.OpenMotionImporter() end
            action:SetVisible(true)
        elseif code == "disabled" and FA and isfunction(FA.OpenManager) then
            action:SetText(L("mmd_vmd_npc.import.file_access_settings"))
            action.DoClick = function() FA.OpenManager() end
            action:SetVisible(true)
        else
            action:SetVisible(false)
        end
        scroll:InvalidateLayout()
    end
    refresh()
    hook.Add("MMDVMDNPCImportAvailabilityChanged", frame, function() refresh() end)
    return frame
end

-- ---------------------------------------------------------------------------
-- Inputs, kept until the map changes (file access items end with the map).
-- ---------------------------------------------------------------------------
local State = Importer.State or { flexes = {}, meta = {}, audioOffset = 0, nameAutofill = "" }
Importer.State = State

local function item_name(item)
    return istable(item) and tostring(item.name or "") or ""
end

local function item_text(item)
    if not istable(item) then return "" end
    local text = tostring(item.displayPath or "")
    return text ~= "" and text or item_name(item)
end

local function release(item)
    local FA = file_access()
    if FA and istable(item) and isfunction(FA.Release) then pcall(FA.Release, item) end
end

local function stem_of(name)
    return MMDVMDNPC.ImportBake and MMDVMDNPC.ImportBake.MotionSourceStem(name, true) or tostring(name or "")
end

function Importer.Notice(text, isError)
    text = tostring(text or "")
    if text == "" then return end
    notification.AddLegacy(text, isError and NOTIFY_ERROR or NOTIFY_HINT, 6)
    if isError then surface.PlaySound("buttons/button10.wav") end
end

-- kind: body, music, camera or flex; done(items) gets the chosen items.
local PICKER_TITLES = { body = "picker_body", music = "picker_music", camera = "picker_camera", flex = "picker_flex" }

local function pick(kind, done)
    local FA = file_access()
    if not FA then
        MMDVMDNPC.OpenImporterResolve()
        return
    end
    local filters
    if kind == "music" then
        filters = { { L("mmd_vmd_npc.import.filter_audio"), "*.mp3;*.ogg;*.wav" } }
    else
        filters = { { L("mmd_vmd_npc.import.filter_vmd"), "*.vmd" } }
    end
    FA.Pick({
        addon = ADDON_NAME,
        title = L("mmd_vmd_npc.import." .. PICKER_TITLES[kind]),
        purpose = L("mmd_vmd_npc.import.purpose"),
        filters = filters,
        multiple = kind == "flex",
    }, function(ok, items, extra)
        if not ok then
            -- items is Model Hotloader's localized reason, extra its code;
            -- closing the picker ("denied") needs no message.
            if extra ~= "denied" then Importer.Notice(items, true) end
            return
        end
        for _, refused in ipairs(istable(extra) and extra or {}) do
            local name = istable(refused) and (refused.name or refused[1]) or refused
            Importer.Notice(LF("mmd_vmd_npc.import.refused_fmt", tostring(name or "?")), true)
        end
        if istable(items) and #items > 0 then done(items) end
    end)
end

-- A new body motion: its old music, camera and flex files no longer apply,
-- and an auto-filled name follows the new file (as in the desktop importer).
local function set_body(item)
    if State.body and State.body ~= item then release(State.body) end
    State.body = item
    local name = tostring(State.meta.display_name or "")
    if name == "" or name == State.nameAutofill then
        State.nameAutofill = stem_of(item_name(item))
        State.meta.display_name = State.nameAutofill
    end
    release(State.music)
    release(State.camera)
    for _, flex in ipairs(State.flexes) do release(flex) end
    State.music, State.camera, State.flexes = nil, nil, {}
end

-- ---------------------------------------------------------------------------
-- The import job
-- ---------------------------------------------------------------------------
local function job_log(job, text)
    job.log[#job.log + 1] = tostring(text)
    job.logVersion = job.logVersion + 1
    job.dirty = true
end

local function job_stage(job, stage, fraction)
    job.stage = stage
    if fraction and fraction > job.progress then job.progress = fraction end
    job.dirty = true
end

local function format_elapsed(seconds)
    seconds = math.max(0, math.floor(seconds + 0.5))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

function Importer.StatusText(job)
    job = job or Importer.Job
    if not job then return L("mmd_vmd_npc.import.progress_idle") end
    local stage = L("mmd_vmd_npc.import.stage." .. tostring(job.stage or "reading"))
    local elapsed = (job.finishedAt or SysTime()) - job.started
    return LF("mmd_vmd_npc.import.status_fmt", stage, math.floor(job.progress * 100 + 0.5), format_elapsed(elapsed))
end

local function remove_stale_music(motionID, keepExtension)
    for _, extension in ipairs(AUDIO_EXTENSIONS) do
        local path = MUSIC_ROOT .. "/" .. motionID .. "." .. extension
        if extension ~= keepExtension and file.Exists(path, "DATA") then file.Delete(path) end
    end
end

-- The audio type from the file's first bytes: GMod plays MP3, OGG and WAV
-- as they are; anything else needs the desktop importer's conversion.
local function audio_extension(head)
    if string.sub(head, 1, 3) == "ID3" then return "mp3" end
    if string.sub(head, 1, 4) == "OggS" then return "ogg" end
    if string.sub(head, 1, 4) == "RIFF" and string.sub(head, 9, 12) == "WAVE" then return "wav" end
    local a, b = string.byte(head, 1, 2)
    -- An MPEG audio frame starts with 11 set sync bits.
    if a == 255 and b and b >= 224 then return "mp3" end
    return nil
end

local function run_job(job)
    local inputs = job.inputs
    local Bake, D = MMDVMDNPC.ImportBake, MMDVMDNPC.ImportData

    local function checkpoint()
        if job.cancelRequested then error(CANCELLED, 0) end
        if SysTime() > job.deadline then coroutine.yield() end
    end

    local function emit(text)
        job_log(job, text)
    end

    -- onChunk(data) for each part of the file, in order; reads wait for
    -- Model Hotloader's answer without blocking the game.
    local function read_chunks(item, onChunk)
        local offset = 0
        while true do
            local reply
            job.waiting = true
            item:Read({ mode = "binary", offset = offset, maxBytes = READ_CHUNK }, function(ok, data, info)
                reply = { ok = ok, data = data, info = info }
                job.waiting = false
            end)
            while job.waiting do coroutine.yield() end
            if job.cancelRequested then error(CANCELLED, 0) end
            if not reply.ok then
                error(LF("mmd_vmd_npc.import.read_failed_fmt", item_name(item), tostring(reply.data or "?")), 0)
            end
            local data = isstring(reply.data) and reply.data or ""
            local info = istable(reply.info) and reply.info or {}
            if info.limited then error(LF("mmd_vmd_npc.import.too_large_fmt", item_name(item)), 0) end
            onChunk(data)
            offset = offset + #data
            local size = tonumber(info.size)
            local more
            if info.eof ~= nil then more = info.eof == false else more = size ~= nil and offset < size end
            if #data == 0 or not more then break end
            checkpoint()
        end
    end

    local function read_all(item)
        local parts = {}
        read_chunks(item, function(data) parts[#parts + 1] = data end)
        return table.concat(parts)
    end

    job_stage(job, "reading", 0.01)
    local bodyText = item_text(inputs.body)
    emit("Reading body motion VMD: " .. bodyText)
    local bodyData = read_all(inputs.body)
    job_stage(job, "parsing", 0.05)
    emit("Importing VMD motion: " .. bodyText)
    local body = Bake.ParseVMD(bodyData, { checkpoint = checkpoint })
    emit(string.format("Imported VMD motion: %d bone track(s), max frame %d", body.boneTrackCount, body.maxFrame))
    local vmdHash = util.SHA1(bodyData)
    bodyData = nil

    -- The camera first, so a missing or corrupt camera VMD fails before the bake.
    local cameraParsed
    if inputs.camera then
        emit("Reading camera VMD: " .. item_text(inputs.camera))
        cameraParsed = Bake.ParseVMD(read_all(inputs.camera), { bones = false, morphs = false, checkpoint = checkpoint })
    end

    job_stage(job, "baking", 0.10)
    emit("Starting native motion bake...")
    emit(string.format("Using the bundled MMD model: %s (%d bones)", D.modelFile, D.pmxBoneCount))
    local started = SysTime()
    local doc, groundOffsets = Bake.BakeMotion(body, {
        disableIK = inputs.disableIK,
        unifyGround = inputs.unifyGround,
        inputName = item_name(inputs.body),
        emit = emit,
        checkpoint = checkpoint,
        progress = function(fraction)
            job.progress = 0.10 + 0.75 * fraction
            job.dirty = true
        end,
    })
    emit(string.format("Native bake finished in %.1fs", SysTime() - started))

    job_stage(job, "flex", 0.86)
    local sources = { { parsed = body, label = "main VMD", path = bodyText, main = true } }
    for index, item in ipairs(inputs.flexes) do
        local label = "extra flex VMD #" .. index
        local ok, data = pcall(read_all, item)
        if ok then
            sources[#sources + 1] = { parsed = Bake.ParseVMD(data, { bones = false, camera = false, checkpoint = checkpoint }), label = label, path = item_text(item) }
        elseif data == CANCELLED then
            error(CANCELLED, 0)
        else
            -- As the desktop importer skips a flex VMD that went missing.
            sources[#sources + 1] = { missing = tostring(data), label = label, path = item_text(item) }
        end
    end
    local flexes, flexWarnings = Bake.MergeFlexTracks(sources, emit, checkpoint)
    for _, warning in ipairs(flexWarnings) do emit("Warning: " .. warning) end
    body, sources = nil, nil

    local cameraTrack
    if cameraParsed then
        job_stage(job, "camera", 0.90)
        cameraTrack = Bake.CameraTrack(cameraParsed, item_name(inputs.camera), groundOffsets, { emit = emit, checkpoint = checkpoint })
    end

    local typedName = Bake.Trim(inputs.meta.display_name)
    local nameSource, nameIsPath = typedName, false
    if typedName == "" then nameSource, nameIsPath = item_name(inputs.body), true end
    local motionID = Bake.MotionID(nameSource, nameIsPath, vmdHash)
    if not MMDVMDNPC.NormalizeMotionID(motionID) then
        error("cannot make a motion id from the name " .. nameSource, 0)
    end

    local music, musicPath, musicExtension
    if inputs.music then
        job_stage(job, "music", 0.93)
        emit("Copying music: " .. item_text(inputs.music))
        local path, written = nil, 0
        read_chunks(inputs.music, function(data)
            if not path then
                musicExtension = audio_extension(data)
                if not musicExtension then error(L("mmd_vmd_npc.import.unsupported_audio"), 0) end
                file.CreateDir(MMDVMDNPC.DataRoot)
                file.CreateDir(MUSIC_ROOT)
                path = MUSIC_ROOT .. "/" .. motionID .. "." .. musicExtension
                file.Write(path, data)
            else
                file.Append(path, data)
            end
            written = written + #data
        end)
        if not path then error(L("mmd_vmd_npc.import.unsupported_audio"), 0) end
        if (file.Size(path, "DATA") or -1) ~= written then error(LF("mmd_vmd_npc.import.write_failed_fmt", "data/" .. path), 0) end
        musicPath = "data/" .. path
        emit("Wrote GMod sound: " .. musicPath)
        music = Bake.Object()
        Bake.Put(music, "sound", musicPath)
        Bake.Put(music, "source", item_name(inputs.music))
    end

    job_stage(job, "writing", 0.97)
    local text, displayName = Bake.MotionJSON(doc, {
        flexes = flexes,
        flexWarnings = flexWarnings,
        music = music,
        camera = cameraTrack,
        audioOffset = inputs.audioOffset,
        motionID = motionID,
        nameSource = nameSource,
        nameIsPath = nameIsPath,
        meta = inputs.meta,
    })
    file.CreateDir(MMDVMDNPC.DataRoot)
    file.CreateDir(MMDVMDNPC.MotionRoot)
    local path = MMDVMDNPC.MotionRoot .. "/" .. motionID .. MMDVMDNPC.CacheExtension
    local previous = file.Read(path, "DATA")
    file.Write(path, text)
    if (file.Size(path, "DATA") or -1) ~= #text then error(LF("mmd_vmd_npc.import.write_failed_fmt", "data/" .. path), 0) end
    emit("Wrote motion JSON: data/" .. path)
    -- Music of an earlier import of this motion in another format, or none now.
    remove_stale_music(motionID, musicExtension)
    return {
        id = motionID,
        name = displayName,
        path = "data/" .. path,
        music = musicPath or "",
        replaced = previous ~= nil and previous ~= text,
    }
end

local function finish(job, ok, result)
    hook.Remove("Think", "MMDVMDNPCImporterJob")
    if job.finished then return end
    job.finished = true
    job.finishedAt = SysTime()
    job.waiting = false
    -- A coroutine that died with an error keeps its stack, and with it the
    -- VMD data the job read; let it go.
    job.co = nil
    if ok then
        job.result = result
        job.progress = 1
        job.stage = "complete"
        if MMDVMDNPC.RequestMotionList then MMDVMDNPC.RequestMotionList() end
        if MMDVMDNPC.RequestMotionDetails then MMDVMDNPC.RequestMotionDetails() end
        -- A re-import changed an existing motion: its built animations are stale.
        if result.replaced and MMDVMDNPC.RequestClearBuiltSelectedMotion then
            MMDVMDNPC.RequestClearBuiltSelectedMotion("all", result.id)
        end
        RunConsoleCommand("mmd_vmd_npc_motion", result.id)
        if MMDVMDNPC.RequestAudioSettings then MMDVMDNPC.RequestAudioSettings(result.id) end
        notification.AddLegacy(LF("mmd_vmd_npc.import.complete_fmt", result.name), NOTIFY_GENERIC, 8)
        surface.PlaySound("garrysmod/content_downloaded.wav")
    elseif result == CANCELLED then
        job.stage = "cancelled"
        job_log(job, "Import cancelled")
        notification.AddLegacy(L("mmd_vmd_npc.import.stage.cancelled"), NOTIFY_CLEANUP, 4)
    else
        job.stage = "failed"
        local message = istable(result) and tostring(result.message) or tostring(result)
        job.error = message
        job_log(job, "Error: " .. message)
        if istable(result) and result.trace then job_log(job, result.trace) end
        notification.AddLegacy(LF("mmd_vmd_npc.import.failed_fmt", message), NOTIFY_ERROR, 8)
        surface.PlaySound("buttons/button10.wav")
    end
    job.dirty = false
    hook.Run("MMDVMDNPCImporterUpdated", job)
end

local function drive()
    local job = Importer.Job
    if not job or job.finished then
        hook.Remove("Think", "MMDVMDNPCImporterJob")
        return
    end
    if job.cancelRequested and job.waiting then
        finish(job, false, CANCELLED)
        return
    end
    if not job.waiting then
        job.deadline = SysTime() + FRAME_BUDGET
        local ok, result = coroutine.resume(job.co)
        if not ok then
            finish(job, false, result)
            return
        end
        if coroutine.status(job.co) == "dead" then
            finish(job, true, result)
            return
        end
    end
    if job.dirty and (job.nextUpdate or 0) <= SysTime() then
        job.dirty = false
        job.nextUpdate = SysTime() + 0.1
        hook.Run("MMDVMDNPCImporterUpdated", job)
    end
end

function Importer.Running()
    return Importer.Job ~= nil and not Importer.Job.finished
end

function Importer.Start()
    if Importer.Running() then
        Importer.Notice(L("mmd_vmd_npc.import.busy"), true)
        return false
    end
    if not State.body then
        Importer.Notice(L("mmd_vmd_npc.import.select_body"), true)
        return false
    end
    local available, reason = MMDVMDNPC.ImporterAvailability()
    if not available then
        Importer.Notice(reason, true)
        MMDVMDNPC.OpenImporterResolve()
        return false
    end
    local meta = {}
    for _, field in ipairs(META_FIELDS) do meta[field] = tostring(State.meta[field] or "") end
    local flexes = {}
    for i, item in ipairs(State.flexes) do flexes[i] = item end
    local job = {
        inputs = {
            body = State.body,
            music = State.music,
            camera = State.camera,
            flexes = flexes,
            meta = meta,
            audioOffset = math.Clamp(tonumber(State.audioOffset) or 0, -5, 5),
            disableIK = State.disableIK == true,
            unifyGround = State.unifyGround == true,
        },
        log = {},
        logVersion = 0,
        progress = 0,
        stage = "reading",
        started = SysTime(),
        deadline = SysTime(),
    }
    job.co = coroutine.create(function()
        local ok, result = xpcall(run_job, function(err)
            if err == CANCELLED then return err end
            return { message = tostring(err), trace = debug.traceback(tostring(err), 2) }
        end, job)
        if not ok then error(result, 0) end
        return result
    end)
    Importer.Job = job
    hook.Add("Think", "MMDVMDNPCImporterJob", drive)
    hook.Run("MMDVMDNPCImporterUpdated", job)
    return true
end

function Importer.Cancel()
    local job = Importer.Job
    if not job or job.finished or job.cancelRequested then return end
    job.cancelRequested = true
    job_log(job, "Cancel requested.")
end

-- ---------------------------------------------------------------------------
-- The importer window: the desktop importer's inputs, without the ones that
-- only make sense outside the game (the GMod folder, the preview and the
-- .gma export: Lua can write only into data/).
-- ---------------------------------------------------------------------------
function MMDVMDNPC.OpenMotionImporter()
    if not MMDVMDNPC.ImporterAvailability() then
        MMDVMDNPC.OpenImporterResolve()
        return
    end
    if IsValid(Importer.Frame) then
        Importer.Frame:MakePopup()
        Importer.Frame:MoveToFront()
        return Importer.Frame
    end
    if State.disableIK == nil then State.disableIK = cookie.GetNumber("mmdvmd_import_disable_ik", 0) == 1 end
    if State.unifyGround == nil then State.unifyGround = cookie.GetNumber("mmdvmd_import_unify_ground", 0) == 1 end

    local frame = vgui.Create("DFrame")
    Importer.Frame = frame
    frame:SetTitle(L("mmd_vmd_npc.import.title"))
    local width = math.min(scaled(1000), ScrW() - 40)
    local height = math.min(scaled(820), ScrH() - 40)
    frame:SetSize(width, height)
    frame:SetSizable(true)
    frame:SetMinWidth(math.min(scaled(640), width))
    frame:SetMinHeight(math.min(scaled(480), height))
    frame:Center()
    frame:MakePopup()

    -- Bottom bar: progress and the two actions stay in view.
    local bottom = vgui.Create("DPanel", frame)
    bottom:Dock(BOTTOM)
    bottom:SetTall(scaled(92))
    bottom:SetPaintBackground(false)
    bottom:DockPadding(scaled(6), scaled(6), scaled(6), 0)
    local actions = vgui.Create("DPanel", bottom)
    actions:Dock(BOTTOM)
    actions:SetTall(scaled(40))
    actions:SetPaintBackground(false)
    local cancel = add_button(actions, L("mmd_vmd_npc.import.cancel"), function() Importer.Cancel() end)
    cancel:Dock(RIGHT)
    cancel:SetWide(scaled(170))
    cancel:DockMargin(scaled(8), 0, 0, 0)
    local bake = accent_button(actions, L("mmd_vmd_npc.import.bake"), Color(40, 140, 70), function() Importer.Start() end)
    bake:Dock(FILL)
    local progress = vgui.Create("DProgress", bottom)
    progress:Dock(TOP)
    progress:SetTall(scaled(16))
    local status = add_label(bottom, L("mmd_vmd_npc.import.progress_idle"), SMALL_FONT, MUTED_COLOR)
    status:Dock(TOP)
    status:SetTall(scaled(22))

    local scroll = vgui.Create("DScrollPanel", frame)
    scroll:Dock(FILL)
    scroll:GetCanvas():DockPadding(scaled(6), 0, scaled(10), scaled(6))

    local function top(panel, gap)
        panel:Dock(TOP)
        panel:DockMargin(0, gap or 0, 0, 0)
        return panel
    end

    top(add_label(scroll, L("mmd_vmd_npc.import.help"), SMALL_FONT, MUTED_COLOR, true))
    -- Buttons that change the chosen files; a running import still reads them.
    local fileButtons = {}

    -- A field title with its Required/Optional badge, and its hint below.
    local function field_header(text, required, hint)
        local row = top(vgui.Create("DPanel", scroll), scaled(12))
        row:SetTall(scaled(24))
        row:SetPaintBackground(false)
        local title = add_label(row, text, BOLD_FONT, TEXT_COLOR)
        title:Dock(LEFT)
        title:SizeToContentsX(scaled(4))
        if required ~= nil then
            local badgeText = required and L("mmd_vmd_npc.import.required") or L("mmd_vmd_npc.import.optional")
            surface.SetFont(SMALL_FONT)
            local textWidth = surface.GetTextSize(badgeText)
            local badge = vgui.Create("DPanel", row)
            badge:Dock(LEFT)
            badge:DockMargin(scaled(8), scaled(3), 0, scaled(3))
            badge:SetWide(textWidth + scaled(16))
            badge.Paint = function(_, w, h)
                draw.RoundedBox(4, 0, 0, w, h, required and Color(31, 111, 235) or Color(70, 72, 76))
                draw.SimpleText(badgeText, SMALL_FONT, w * 0.5, h * 0.5, required and color_white or Color(215, 215, 215), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
        end
        if hint and hint ~= "" then
            top(add_label(scroll, hint, SMALL_FONT, MUTED_COLOR, true), scaled(2))
        end
    end

    -- Chosen file (read-only) with Browse and, for optional files, Clear.
    local function file_line(onBrowse, onClear)
        local row = top(vgui.Create("DPanel", scroll), scaled(4))
        row:SetTall(scaled(30))
        row:SetPaintBackground(false)
        if onClear then
            local clear = add_button(row, L("mmd_vmd_npc.import.clear"), onClear)
            clear:Dock(RIGHT)
            clear:SetWide(scaled(90))
            clear:DockMargin(scaled(6), 0, 0, 0)
            fileButtons[#fileButtons + 1] = clear
        end
        local browse = add_button(row, L("mmd_vmd_npc.import.browse"), onBrowse)
        browse:Dock(RIGHT)
        browse:SetWide(scaled(110))
        browse:DockMargin(scaled(6), 0, 0, 0)
        fileButtons[#fileButtons + 1] = browse
        local entry = vgui.Create("DTextEntry", row)
        entry:Dock(FILL)
        entry:SetFont(TEXT_FONT)
        entry:SetEditable(false)
        entry:SetPlaceholderText(L("mmd_vmd_npc.import.none_selected"))
        return entry
    end

    local refresh_inputs

    field_header(L("mmd_vmd_npc.import.body_vmd"), true, L("mmd_vmd_npc.import.body_vmd_hint"))
    local bodyEntry = file_line(function()
        pick("body", function(items)
            set_body(items[1])
            for i = 2, #items do release(items[i]) end
            refresh_inputs()
        end)
    end)

    field_header(L("mmd_vmd_npc.import.music"), false, L("mmd_vmd_npc.import.music_hint"))
    local musicEntry = file_line(function()
        pick("music", function(items)
            if State.music ~= items[1] then release(State.music) end
            State.music = items[1]
            refresh_inputs()
        end)
    end, function()
        release(State.music)
        State.music = nil
        refresh_inputs()
    end)

    field_header(L("mmd_vmd_npc.import.camera_vmd"), false, L("mmd_vmd_npc.import.camera_vmd_hint"))
    local cameraEntry = file_line(function()
        pick("camera", function(items)
            if State.camera ~= items[1] then release(State.camera) end
            State.camera = items[1]
            refresh_inputs()
        end)
    end, function()
        release(State.camera)
        State.camera = nil
        refresh_inputs()
    end)

    field_header(L("mmd_vmd_npc.import.audio_offset"), false, L("mmd_vmd_npc.import.audio_offset_hint"))
    local offsetSlider = top(vgui.Create("DNumSlider", scroll), scaled(2))
    offsetSlider:SetTall(scaled(30))
    offsetSlider:SetText(L("mmd_vmd_npc.import.audio_offset"))
    offsetSlider:SetMin(-5)
    offsetSlider:SetMax(5)
    offsetSlider:SetDecimals(2)
    offsetSlider:SetValue(tonumber(State.audioOffset) or 0)
    if IsValid(offsetSlider.Label) then
        offsetSlider.Label:SetFont(TEXT_FONT)
        offsetSlider.Label:SetTextColor(TEXT_COLOR)
    end
    offsetSlider.OnValueChanged = function(_, value)
        State.audioOffset = math.Clamp(tonumber(value) or 0, -5, 5)
    end

    -- Motion metadata: the desktop importer's 7-field table, as a grid.
    field_header(L("mmd_vmd_npc.import.motion_meta"), false, L("mmd_vmd_npc.import.motion_meta_hint"))
    local grid = top(vgui.Create("DPanel", scroll), scaled(4))
    grid:SetPaintBackground(false)
    grid:SetTall(scaled(110))
    local metaEntries, cells = {}, {}
    for _, field in ipairs(META_FIELDS) do
        local cell = vgui.Create("DPanel", grid)
        cell:SetPaintBackground(false)
        local caption = add_label(cell, L("mmd_vmd_npc.import.meta." .. field), SMALL_FONT, TEXT_COLOR)
        caption:Dock(TOP)
        caption:SetTall(scaled(20))
        local entry = vgui.Create("DTextEntry", cell)
        entry:Dock(FILL)
        entry:SetFont(TEXT_FONT)
        entry:SetUpdateOnType(true)
        entry:SetTooltip(L("mmd_vmd_npc.import.meta." .. field .. "_tip"))
        caption:SetTooltip(L("mmd_vmd_npc.import.meta." .. field .. "_tip"))
        entry.OnValueChange = function(_, value)
            State.meta[field] = tostring(value or "")
        end
        metaEntries[field] = entry
        cells[#cells + 1] = cell
    end
    grid.PerformLayout = function(self, w)
        local gap = scaled(8)
        local columns = math.Clamp(math.floor((w + gap) / scaled(230)), 1, 4)
        local cellWidth = math.floor((w - gap * (columns - 1)) / columns)
        local cellHeight = scaled(50)
        for index, cell in ipairs(cells) do
            local column = (index - 1) % columns
            local row = math.floor((index - 1) / columns)
            cell:SetPos(column * (cellWidth + gap), row * (cellHeight + gap))
            cell:SetSize(cellWidth, cellHeight)
        end
        local rows = math.ceil(#cells / columns)
        local tall = rows * cellHeight + (rows - 1) * gap
        if self:GetTall() ~= tall then self:SetTall(tall) end
    end

    field_header(L("mmd_vmd_npc.import.flex_group"), false)
    local flexList = top(vgui.Create("DListView", scroll), scaled(4))
    flexList:SetTall(scaled(96))
    flexList:SetMultiSelect(true)
    flexList:AddColumn(L("mmd_vmd_npc.import.flex_column"))
    local flexButtons = top(vgui.Create("DPanel", scroll), scaled(4))
    flexButtons:SetTall(scaled(30))
    flexButtons:SetPaintBackground(false)
    local addFlex = add_button(flexButtons, L("mmd_vmd_npc.import.flex_add"), function()
        pick("flex", function(items)
            for _, item in ipairs(items) do State.flexes[#State.flexes + 1] = item end
            refresh_inputs()
        end)
    end)
    addFlex:Dock(LEFT)
    addFlex:SetWide(scaled(240))
    local removeFlex = add_button(flexButtons, L("mmd_vmd_npc.import.flex_remove"), function()
        local drop = {}
        for _, line in ipairs(flexList:GetSelected() or {}) do
            if line.FlexItem then drop[line.FlexItem] = true end
        end
        local kept = {}
        for _, item in ipairs(State.flexes) do
            if drop[item] then release(item) else kept[#kept + 1] = item end
        end
        State.flexes = kept
        refresh_inputs()
    end)
    removeFlex:Dock(LEFT)
    removeFlex:SetWide(scaled(240))
    removeFlex:DockMargin(scaled(8), 0, 0, 0)
    fileButtons[#fileButtons + 1] = addFlex
    fileButtons[#fileButtons + 1] = removeFlex

    field_header(L("mmd_vmd_npc.import.bake_options"), nil)
    local function option(text, tip, value, cookieName, onChange)
        local check = top(vgui.Create("DCheckBoxLabel", scroll), scaled(6))
        check:SetTall(scaled(22))
        check:SetText(text)
        check:SetFont(TEXT_FONT)
        check:SetTextColor(TEXT_COLOR)
        check:SetValue(value and 1 or 0)
        check:SetTooltip(tip)
        check.OnChange = function(_, checked)
            onChange(checked == true)
            cookie.Set(cookieName, checked and "1" or "0")
        end
        return check
    end
    option(L("mmd_vmd_npc.import.disable_foot_ik"), L("mmd_vmd_npc.import.disable_foot_ik_tip"), State.disableIK, "mmdvmd_import_disable_ik", function(value) State.disableIK = value end)
    option(L("mmd_vmd_npc.import.unify_ground"), L("mmd_vmd_npc.import.unify_ground_tip"), State.unifyGround, "mmdvmd_import_unify_ground", function(value) State.unifyGround = value end)

    field_header(L("mmd_vmd_npc.import.log_title"), nil)
    local function output_line(caption)
        local row = top(vgui.Create("DPanel", scroll), scaled(4))
        row:SetTall(scaled(26))
        row:SetPaintBackground(false)
        local label = add_label(row, caption, SMALL_FONT, TEXT_COLOR)
        label:Dock(LEFT)
        label:SetWide(scaled(140))
        local entry = vgui.Create("DTextEntry", row)
        entry:Dock(FILL)
        entry:SetFont(SMALL_FONT)
        entry:SetEditable(false)
        return entry
    end
    local motionOutput = output_line(L("mmd_vmd_npc.import.output_motion"))
    local musicOutput = output_line(L("mmd_vmd_npc.import.output_music"))
    local logEntry = top(vgui.Create("DTextEntry", scroll), scaled(6))
    logEntry:SetTall(scaled(180))
    logEntry:SetMultiline(true)
    logEntry:SetEditable(false)
    logEntry:SetVerticalScrollbarEnabled(true)
    logEntry:SetFont("DermaDefault")
    local copyRow = top(vgui.Create("DPanel", scroll), scaled(4))
    copyRow:SetTall(scaled(30))
    copyRow:SetPaintBackground(false)
    local copyLog = add_button(copyRow, L("mmd_vmd_npc.import.copy_log"), function()
        local job = Importer.Job
        SetClipboardText(job and table.concat(job.log, "\n") or "")
    end)
    copyLog:Dock(RIGHT)
    copyLog:SetWide(scaled(140))

    refresh_inputs = function()
        if not IsValid(frame) then return end
        bodyEntry:SetValue(item_text(State.body))
        musicEntry:SetValue(item_text(State.music))
        cameraEntry:SetValue(item_text(State.camera))
        for field, entry in pairs(metaEntries) do
            local value = tostring(State.meta[field] or "")
            if entry:GetValue() ~= value then entry:SetText(value) end
        end
        flexList:Clear()
        for _, item in ipairs(State.flexes) do
            local line = flexList:AddLine(item_text(item))
            line.FlexItem = item
        end
    end

    local shownLog = -1
    local function refresh_job()
        if not IsValid(frame) then return end
        local job = Importer.Job
        local running = Importer.Running()
        bake:SetEnabled(not running)
        cancel:SetEnabled(running and not job.cancelRequested)
        for _, button in ipairs(fileButtons) do button:SetEnabled(not running) end
        progress:SetFraction(job and job.progress or 0)
        if job then
            status:SetText(Importer.StatusText(job) .. (job.error and ("  " .. job.error) or ""))
            status:SetTextColor(job.stage == "failed" and Color(255, 110, 100) or (job.stage == "complete" and Color(110, 220, 130) or MUTED_COLOR))
        else
            status:SetText(L("mmd_vmd_npc.import.progress_idle"))
            status:SetTextColor(MUTED_COLOR)
        end
        local result = job and job.result
        motionOutput:SetValue(result and result.path or "")
        musicOutput:SetValue(result and result.music or "")
        local version = job and job.logVersion or 0
        if version ~= shownLog then
            shownLog = version
            logEntry:SetValue(job and table.concat(job.log, "\n") or "")
            if logEntry.GotoTextEnd then logEntry:GotoTextEnd() end
        end
    end

    hook.Add("MMDVMDNPCImporterUpdated", frame, function() refresh_job() end)
    -- The elapsed time keeps counting between updates.
    local baseThink = frame.Think
    frame.Think = function(self)
        if baseThink then baseThink(self) end
        if Importer.Running() and (self.NextStatus or 0) <= SysTime() then
            self.NextStatus = SysTime() + 0.5
            status:SetText(Importer.StatusText())
        end
    end
    hook.Add("MMDVMDNPCImportAvailabilityChanged", frame, function()
        if MMDVMDNPC.ImporterAvailability() then return end
        -- File access went away (turned off, worker check failed): explain.
        if not Importer.Running() then
            frame:Close()
            MMDVMDNPC.OpenImporterResolve()
        end
    end)
    refresh_inputs()
    refresh_job()
    return frame
end

concommand.Add("mmdvmd_import", function()
    MMDVMDNPC.OpenMotionImporter()
end)
