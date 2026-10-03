MMDVMDNPC = MMDVMDNPC or {}
-- Parsed-motion cache. Cleared unconditionally when this file (re)loads: the
-- cache validity key is mtime+path+realm only, so an autorefresh that changes
-- read_motion_file itself (new fields, new parsing) would otherwise keep
-- serving objects in the OLD shape — and MotionMetadata would then persist
-- that stale shape into _meta_index.dat under the new schema stamp.
MMDVMDNPC.Cache = {}
MMDVMDNPC.FlexAliases = MMDVMDNPC.FlexAliases or nil
MMDVMDNPC.FlexOverrides = MMDVMDNPC.FlexOverrides or nil
MMDVMDNPC.FlexOverrideUnassigned = MMDVMDNPC.FlexOverrideUnassigned or "__mmd_vmd_npc_unassigned__"

local EXPECTED_FORMAT = "mmd_vmd_npc_parent_corrected_axis_v1"
local FLEX_MAPPING_DATA_PATH = "mmd_vmd_npc/flex_mapping_table.json"
local FLEX_MAPPING_STATIC_PATH = "data_static/mmd_vmd_npc/flex_mapping_table.json"
local STATIC_MOTION_ROOT = "data_static/" .. MMDVMDNPC.MotionRoot
local FLEX_OVERRIDE_UNASSIGNED = MMDVMDNPC.FlexOverrideUnassigned

local function number_or(value, fallback)
    local out = tonumber(value)
    if out == nil then return fallback end
    return out
end

local function validate_key(raw, trackName)
    if not istable(raw) then
        return nil, "bad keyframe in " .. trackName
    end

    return {
        frame = number_or(raw[1], 0),
        x = number_or(raw[2], 0),
        y = number_or(raw[3], 0),
        z = number_or(raw[4], 0),
        px = number_or(raw[5], 0),
        py = number_or(raw[6], 0),
        pz = number_or(raw[7], 0),
    }
end

local function normalize_track(raw, index)
    if not istable(raw) then return nil, "bad bone track" end

    local source = tostring(raw.g or raw.target or raw.source or "")
    local mmd = tostring(raw.m or raw.mmd or "")
    if source == "" then
        return nil, "bone track has no target GMod bone: " .. mmd
    end

    local keys = {}
    for _, rawKey in ipairs(raw.k or raw.keys or {}) do
        local key, err = validate_key(rawKey, mmd ~= "" and mmd or source)
        if not key then return nil, err end
        keys[#keys + 1] = key
    end

    table.sort(keys, function(a, b) return a.frame < b.frame end)
    if #keys <= 0 then
        return nil, "bone track has no keyframes: " .. source
    end

    return {
        index = index,
        source = source,
        mmd = mmd,
        role = tostring(raw.role or ""),
        keys = keys,
    }
end

local function validate_flex_key(raw, trackName)
    if not istable(raw) then
        return nil, "bad flex keyframe in " .. trackName
    end

    return {
        frame = number_or(raw[1], 0),
        weight = math.Clamp(number_or(raw[2], 0), 0, 1),
    }
end

local function normalize_flex_track(raw, index)
    if not istable(raw) then return nil, "bad flex track" end

    local source = tostring(raw.g or raw.target or raw.source or raw.flex or "")
    local mmd = tostring(raw.m or raw.mmd or "")
    if source == "" then
        return nil, "flex track has no target Source flex: " .. mmd
    end

    local keys = {}
    for _, rawKey in ipairs(raw.k or raw.keys or {}) do
        local key, err = validate_flex_key(rawKey, mmd ~= "" and mmd or source)
        if not key then return nil, err end
        keys[#keys + 1] = key
    end

    table.sort(keys, function(a, b) return a.frame < b.frame end)
    if #keys <= 0 then
        return nil, "flex track has no keyframes: " .. source
    end

    return {
        index = index,
        source = source,
        mmd = mmd,
        keys = keys,
    }
end

local function normalize_flex_name(name)
    name = string.lower(tostring(name or ""))
    name = string.gsub(name, "[%s_%-]+", "")
    return name
end

local function exact_flex_on_entity(ent, flexName)
    if not IsValid(ent) or not ent.GetFlexNum or not ent.GetFlexName then return nil, nil end

    flexName = tostring(flexName or "")
    if flexName == "" then return nil, nil end

    local maxFlex = ent:GetFlexNum() or 0
    for flexID = 0, maxFlex - 1 do
        local current = tostring(ent:GetFlexName(flexID) or "")
        if current == flexName then
            return flexID, current
        end
    end

    local wantedLower = string.lower(flexName)
    for flexID = 0, maxFlex - 1 do
        local current = tostring(ent:GetFlexName(flexID) or "")
        if string.lower(current) == wantedLower then
            return flexID, current
        end
    end

    return nil, nil
end

function MMDVMDNPC.FindExactFlexOnEntity(ent, flexName)
    return exact_flex_on_entity(ent, flexName)
end

local function flex_override_model_key(modelPath)
    modelPath = string.lower(tostring(modelPath or ""))
    modelPath = string.gsub(modelPath, "\\", "/")
    return modelPath
end

function MMDVMDNPC.FlexOverrideModelKey(modelPath)
    return flex_override_model_key(modelPath)
end

function MMDVMDNPC.LoadFlexOverrides()
    if MMDVMDNPC.FlexOverrides then return MMDVMDNPC.FlexOverrides end

    local raw = file.Read(MMDVMDNPC.FlexOverridePath or (MMDVMDNPC.SettingsRoot .. "/flex_overrides.json"), "DATA")
    local parsed = raw and util.JSONToTable(raw) or nil
    MMDVMDNPC.FlexOverrides = istable(parsed) and parsed or {}
    return MMDVMDNPC.FlexOverrides
end

function MMDVMDNPC.SaveFlexOverrides()
    file.CreateDir(MMDVMDNPC.DataRoot)
    file.CreateDir(MMDVMDNPC.SettingsRoot)
    file.Write(
        MMDVMDNPC.FlexOverridePath or (MMDVMDNPC.SettingsRoot .. "/flex_overrides.json"),
        util.TableToJSON(MMDVMDNPC.LoadFlexOverrides(), false)
    )
end

function MMDVMDNPC.FlexOverrideForModel(modelPath, sourceName, mmdName)
    local modelKey = flex_override_model_key(modelPath)
    if modelKey == "" then return nil end

    local modelOverrides = MMDVMDNPC.LoadFlexOverrides()[modelKey]
    if not istable(modelOverrides) then return nil end

    sourceName = tostring(sourceName or "")
    mmdName = tostring(mmdName or "")

    local function lookup(map, key)
        if not istable(map) or key == "" then return nil end
        local value = map[key]
        if value ~= nil and tostring(value) ~= "" then return tostring(value) end
        return nil
    end

    return lookup(modelOverrides.by_mmd, mmdName)
        or lookup(modelOverrides.by_source, sourceName)
        or lookup(modelOverrides.by_mmd_norm, normalize_flex_name(mmdName))
        or lookup(modelOverrides.by_source_norm, normalize_flex_name(sourceName))
end

function MMDVMDNPC.SetFlexOverrideForModel(modelPath, mmdName, sourceName, flexName)
    local modelKey = flex_override_model_key(modelPath)
    flexName = tostring(flexName or "")
    mmdName = tostring(mmdName or "")
    sourceName = tostring(sourceName or "")

    if modelKey == "" or flexName == "" then return false end

    local overrides = MMDVMDNPC.LoadFlexOverrides()
    local modelOverrides = overrides[modelKey] or {}
    modelOverrides.by_mmd = istable(modelOverrides.by_mmd) and modelOverrides.by_mmd or {}
    modelOverrides.by_source = istable(modelOverrides.by_source) and modelOverrides.by_source or {}
    modelOverrides.by_mmd_norm = istable(modelOverrides.by_mmd_norm) and modelOverrides.by_mmd_norm or {}
    modelOverrides.by_source_norm = istable(modelOverrides.by_source_norm) and modelOverrides.by_source_norm or {}

    if mmdName ~= "" then
        modelOverrides.by_mmd[mmdName] = flexName
        modelOverrides.by_mmd_norm[normalize_flex_name(mmdName)] = flexName
    end
    if sourceName ~= "" then
        modelOverrides.by_source[sourceName] = flexName
        modelOverrides.by_source_norm[normalize_flex_name(sourceName)] = flexName
    end

    overrides[modelKey] = modelOverrides
    MMDVMDNPC.SaveFlexOverrides()
    return true
end

function MMDVMDNPC.SetFlexUnassignedForModel(modelPath, mmdName, sourceName)
    return MMDVMDNPC.SetFlexOverrideForModel(modelPath, mmdName, sourceName, FLEX_OVERRIDE_UNASSIGNED)
end

function MMDVMDNPC.ClearFlexOverrideForModel(modelPath, mmdName, sourceName)
    local modelKey = flex_override_model_key(modelPath)
    if modelKey == "" then return false end

    local overrides = MMDVMDNPC.LoadFlexOverrides()
    local modelOverrides = overrides[modelKey]
    if not istable(modelOverrides) then return false end

    mmdName = tostring(mmdName or "")
    sourceName = tostring(sourceName or "")

    -- Track whether anything actually existed: returning true for a no-op made
    -- "Clear Mapping" report success on morphs that had no saved mapping.
    local removedAny = false
    local function drop(map, key)
        if istable(map) and key ~= "" and map[key] ~= nil then
            map[key] = nil
            removedAny = true
        end
    end
    drop(modelOverrides.by_mmd, mmdName)
    drop(modelOverrides.by_source, sourceName)
    drop(modelOverrides.by_mmd_norm, mmdName ~= "" and normalize_flex_name(mmdName) or "")
    drop(modelOverrides.by_source_norm, sourceName ~= "" and normalize_flex_name(sourceName) or "")

    if not removedAny then return false end
    MMDVMDNPC.SaveFlexOverrides()
    return true
end

function MMDVMDNPC.LoadFlexAliases()
    if MMDVMDNPC.FlexAliases then return MMDVMDNPC.FlexAliases end

    local aliases = {}
    local raw = file.Read(FLEX_MAPPING_DATA_PATH, "DATA")
    if not raw then
        raw = file.Read(FLEX_MAPPING_STATIC_PATH, "GAME")
    end

    local parsed = raw and util.JSONToTable(raw) or nil
    local rows = istable(parsed) and (istable(parsed.aliases) and parsed.aliases or parsed) or {}

    local function ingest_alias_row(values)
        if not istable(values) then return end
        if #values > 0 then
            local canonical = values[1]
            local row = aliases[canonical] or {}
            local seen = {}
            for _, value in ipairs(row) do
                seen[normalize_flex_name(value)] = true
            end
            for _, value in ipairs(values) do
                local key = normalize_flex_name(value)
                if key ~= "" and not seen[key] then
                    row[#row + 1] = value
                    seen[key] = true
                end
            end
            for _, value in ipairs(row) do
                aliases[value] = row
            end
            aliases[canonical] = row
        end
    end

    for _, values in ipairs(rows) do
        ingest_alias_row(values)
    end

    MMDVMDNPC.FlexAliases = aliases
    return aliases
end

function MMDVMDNPC.ResolveFlexID(ent, sourceName, mmdName)
    if not IsValid(ent) then return -1, "" end

    local candidates = {}
    local seen = {}
    local function add_candidate(name)
        name = tostring(name or "")
        local key = normalize_flex_name(name)
        if key ~= "" and not seen[key] then
            candidates[#candidates + 1] = name
            seen[key] = true
        end
    end

    if ent.GetModel and MMDVMDNPC.FlexOverrideForModel then
        local override = MMDVMDNPC.FlexOverrideForModel(ent:GetModel() or "", sourceName, mmdName)
        if override == FLEX_OVERRIDE_UNASSIGNED then return -1, "" end
        add_candidate(override)
    end
    add_candidate(sourceName)
    add_candidate(mmdName)
    local aliases = MMDVMDNPC.LoadFlexAliases()[tostring(sourceName or "")] or {}
    for _, alias in ipairs(aliases) do
        add_candidate(alias)
    end
    aliases = MMDVMDNPC.LoadFlexAliases()[tostring(mmdName or "")] or {}
    for _, alias in ipairs(aliases) do
        add_candidate(alias)
    end

    for _, name in ipairs(candidates) do
        local exactID, exactName = exact_flex_on_entity(ent, name)
        if exactID and exactID >= 0 then
            return exactID, exactName or name
        end
    end

    if ent.GetFlexIDByName then
        for _, name in ipairs(candidates) do
            local flexID = ent:GetFlexIDByName(name)
            if flexID and flexID >= 0 then
                local actualName = ent.GetFlexName and ent:GetFlexName(flexID) or nil
                return flexID, actualName or name
            end
        end
    end

    local normalizedCandidates = {}
    for _, name in ipairs(candidates) do
        normalizedCandidates[normalize_flex_name(name)] = true
    end

    if ent.GetFlexNum and ent.GetFlexName then
        for flexID = 0, (ent:GetFlexNum() or 0) - 1 do
            local flexName = ent:GetFlexName(flexID)
            if normalizedCandidates[normalize_flex_name(flexName)] then
                return flexID, flexName or ""
            end
        end
    end

    return -1, ""
end

-- Optional MMD camera track exported by the importer: entity-local eye
-- position (source units), local view angles (degrees) and vertical fov per
-- sampled key. Invalid tracks are dropped silently so old motions keep loading.
local MAX_CAMERA_KEYS = 20000

local function normalize_camera_track(raw)
    if not istable(raw) or not istable(raw.keys) then return nil end

    local keys = {}
    for _, rawKey in ipairs(raw.keys) do
        if istable(rawKey) then
            keys[#keys + 1] = {
                frame = math.max(0, math.floor(number_or(rawKey[1], 0))),
                x = number_or(rawKey[2], 0),
                y = number_or(rawKey[3], 0),
                z = number_or(rawKey[4], 0),
                p = number_or(rawKey[5], 0),
                yw = number_or(rawKey[6], 0),
                r = number_or(rawKey[7], 0),
                fov = math.Clamp(number_or(rawKey[8], 30), 1, 179),
            }
            if #keys >= MAX_CAMERA_KEYS then break end
        end
    end
    if #keys <= 0 then return nil end

    table.sort(keys, function(a, b) return a.frame < b.frame end)
    return {
        fps = math.max(1, math.floor(number_or(raw.fps, MMDVMDNPC.VMDFPS or 30))),
        frameStart = math.floor(number_or(raw.frame_start, keys[1].frame)),
        frameEnd = math.floor(number_or(raw.frame_end, keys[#keys].frame)),
        keyCount = #keys,
        keys = keys,
    }
end

local function motion_file_info(motionID)
    local path, id = MMDVMDNPC.MotionPath(motionID)
    if not path or not id then return nil end

    if file.Exists(path, "DATA") then
        return {
            id = id,
            path = path,
            realm = "DATA",
            isAddon = false,
            modified = file.Time(path, "DATA") or 0,
        }
    end

    local staticPath = STATIC_MOTION_ROOT .. "/" .. id .. MMDVMDNPC.CacheExtension
    if file.Exists(staticPath, "GAME") then
        return {
            id = id,
            path = staticPath,
            realm = "GAME",
            isAddon = true,
            modified = file.Time(staticPath, "GAME") or 0,
        }
    end

    return {
        id = id,
        path = path,
        realm = "DATA",
        isAddon = false,
        modified = 0,
    }
end

function MMDVMDNPC.MotionFileInfo(motionID)
    return motion_file_info(motionID)
end

-- Free-text fields sourced from motion JSON: strip NULs (net.WriteString
-- truncates at them) and bound the length.
local function clamp_meta_string(value, limit)
    value = string.gsub(tostring(value or ""), "%z", "")
    return string.sub(value, 1, limit or 256)
end

local function build_motion_from_parsed(parsed, path, realm, info)
    if parsed.format ~= EXPECTED_FORMAT then
        return nil, "unsupported motion JSON format: " .. tostring(parsed.format or "missing")
    end

    local motion = {
        format = parsed.format,
        fps = math.max(1, math.floor(number_or(parsed.fps, MMDVMDNPC.VMDFPS or 30))),
        frameStart = number_or(parsed.frame_start, 0),
        frameEnd = number_or(parsed.frame_end, 0),
        frameCount = math.max(1, math.floor(number_or(parsed.frame_count, 1))),
        displayName = tostring(parsed.display_name or parsed.motion_name or parsed.name
            or (istable(parsed.meta) and parsed.meta.display_name) or ""),
        sourceName = tostring(parsed.input_vmd or ""),
        sourcePath = tostring(parsed.baked_vmd or parsed.input_vmd or ""),
        modelPath = tostring(parsed.mmd_model or ""),
        isAddon = parsed.is_addon == true or (info and info.isAddon == true),
        -- Descriptive metadata block written by the importer (all optional).
        -- Values are free text from the importer table or third-party addon
        -- JSONs: clamp them here (NUL-stripped, bounded) so they can never
        -- blow up the persisted meta index or the chunked details net stream.
        meta = istable(parsed.meta) and {
            category = clamp_meta_string(parsed.meta.category, 128),
            englishName = clamp_meta_string(parsed.meta.english_name, 256),
            artist = clamp_meta_string(parsed.meta.artist, 256),
            language = clamp_meta_string(parsed.meta.language, 64),
            link = clamp_meta_string(parsed.meta.link, 512),
            motionArtist = clamp_meta_string(parsed.meta.motion_artist, 256),
        } or nil,
        filePath = path,
        fileRealm = realm,
        axis = parsed.axis or {},
        order = tostring(parsed.order or ""),
        columns = parsed.columns or {},
        music = istable(parsed.music) and {
            sound = tostring(parsed.music.sound or ""),
            sampleRate = number_or(parsed.music.sample_rate, 0),
            source = tostring(parsed.music.source or ""),
            offset = number_or(parsed.music.offset or parsed.music.default_offset, number_or(parsed.audio_offset, 0)),
        } or nil,
        defaultAudioOffset = number_or(parsed.audio_offset, istable(parsed.music) and number_or(parsed.music.offset or parsed.music.default_offset, 0) or 0),
        boneTracks = {},
        flexTracks = {},
        camera = normalize_camera_track(parsed.camera),
    }
    motion.duration = math.max(0, (motion.frameEnd - motion.frameStart) / motion.fps)

    local seenTargets = {}
    for index, rawTrack in ipairs(parsed.bones or {}) do
        local track, err = normalize_track(rawTrack, index)
        if not track then return nil, err end
        if seenTargets[track.source] then
            return nil, "motion JSON has duplicate target GMod bone: " .. track.source
        end
        seenTargets[track.source] = true
        motion.boneTracks[#motion.boneTracks + 1] = track
    end

    table.sort(motion.boneTracks, function(a, b)
        return (a.index or 0) < (b.index or 0)
    end)

    for index, rawTrack in ipairs(parsed.flexes or parsed.morphs or {}) do
        local track, err = normalize_flex_track(rawTrack, index)
        if not track then return nil, err end
        motion.flexTracks[#motion.flexTracks + 1] = track
    end

    table.sort(motion.flexTracks, function(a, b)
        return (a.index or 0) < (b.index or 0)
    end)

    return motion
end

local function read_motion_file(info)
    local path = info and info.path or ""
    local realm = info and info.realm or "DATA"
    local raw = file.Read(path, realm)
    if not raw then
        return nil, "motion json not found: " .. path
    end

    local parsed = util.JSONToTable(raw)
    if not istable(parsed) then
        return nil, "motion file is not valid JSON: " .. path
    end
    return build_motion_from_parsed(parsed, path, realm, info)
end

-- Header-only motion read ------------------------------------------------------
-- Motion JSONs are dozens of MB, but everything the meta derive needs lives in
-- the writer's small scalar HEAD (format .. bone_count, before the huge
-- "bones" array) and small TAIL ("flex_count", "music", "camera", the names,
-- "meta", "is_addon"). Splicing those two fragments around stubbed track
-- arrays yields a tiny valid JSON that goes through the exact same
-- normalization — so first-time indexing of a freshly subscribed pack costs
-- milliseconds per file instead of a multi-second util.JSONToTable of the
-- whole file (which froze the game for minutes on the first menu open).
-- Any layout mismatch fails closed: the caller falls back to the full parse.
--
-- The anchors are safe to locate with plain byte search: inside JSON string
-- values every quote is escaped (\"), so the raw sequences '"bones":' and
-- '"flex_count":' can only be real keys — and both are unique, top-level keys
-- in this format. A pathological file that still splices wrong produces
-- invalid JSON and falls back.
local MOTION_HEADER_HEAD_BYTES = 16384
local MOTION_HEADER_TAIL_BYTES = 524288
local MOTION_HEADER_TAIL_MAX = 8388608

local function parse_motion_header(info)
    local path = info and info.path or ""
    local realm = info and info.realm or "DATA"
    local f = file.Open(path, "rb", realm)
    if not f then return nil end
    local size = f:Size() or 0
    -- Small files parse quickly anyway; let them take the exact full path.
    if size <= MOTION_HEADER_TAIL_BYTES then f:Close() return nil end

    local head = f:Read(math.min(MOTION_HEADER_HEAD_BYTES, size)) or ""
    local bonesAt = string.find(head, '"bones":', 1, true)
    if not bonesAt then f:Close() return nil end
    local headPart = string.gsub(string.sub(head, 1, bonesAt - 1), ",%s*$", "")

    -- "flex_count" precedes "music"/"camera"/"meta" in the writer layout, so a
    -- splice anchored there provably contains every tail field; grow the tail
    -- window until the anchor is inside it (the camera block between it and
    -- EOF can be ~1.5MB at the 20000-key cap).
    local tailLen = MOTION_HEADER_TAIL_BYTES
    local anchorAt, tail
    while true do
        tailLen = math.min(tailLen, size)
        f:Seek(size - tailLen)
        tail = f:Read(tailLen) or ""
        anchorAt = string.find(tail, '"flex_count":', 1, true)
        if anchorAt or tailLen >= size or tailLen >= MOTION_HEADER_TAIL_MAX then break end
        tailLen = tailLen * 4
    end
    f:Close()
    if not anchorAt then return nil end

    -- Layout-order gate: in the writer layout "flex_count" immediately follows
    -- the flexes ARRAY (bytes '],'), which is what guarantees the splice keeps
    -- every remaining tail key. A re-serialized file with reordered keys (e.g.
    -- jq -S) can carry keys BETWEEN "bones" and "flex_count" that the splice
    -- would silently drop (a camera block, say — persisting hasCamera=false
    -- until the file changes); such files must take the full parse instead.
    if anchorAt < 3 or string.sub(tail, anchorAt - 2, anchorAt - 1) ~= "]," then return nil end

    local spliced = headPart .. ',"bones":[],"flexes":[],' .. string.sub(tail, anchorAt)
    local parsed = util.JSONToTable(spliced)
    if not istable(parsed) then return nil end
    -- The track arrays were stubbed out, so the meta derive must take its
    -- counts from the writer's scalars; without them this mode cannot match
    -- the full parse and must not be used. NaN is rejected and the use site
    -- clamps: one hand-edited "bone_count":1e999 must not put a value into
    -- _meta_index.dat that util.TableToJSON cannot round-trip (that would
    -- silently wipe the whole persisted index every session).
    local boneCount, flexCount = parsed.bone_count, parsed.flex_count
    if not isnumber(boneCount) or boneCount ~= boneCount then return nil end
    if not isnumber(flexCount) or flexCount ~= flexCount then return nil end
    return parsed
end

-- Lightweight persistent header/metadata indexes -----------------------------
-- Parsing every motion or built-cache JSON in full (each can be several MB of
-- baked frames) just to read a handful of header fields is what made the first
-- menu open, motion deletion and built-cache clearing extremely slow. These
-- indexes remember the small header per file keyed by the file's mtime, persist
-- to a tiny sidecar (a ".dat" so it never matches the "*.json" motion/built
-- globs), and are only rebuilt for files that are new or have changed.

local MOTION_META_INDEX_PATH = MMDVMDNPC.MotionRoot .. "/_meta_index.dat"
local BUILT_HEADER_INDEX_PATH = MMDVMDNPC.BuiltRoot .. "/_headers.dat"

local function load_json_index(filePath)
    local raw = file.Read(filePath, "DATA")
    if not raw then return {} end
    local parsed = util.JSONToTable(raw)
    return istable(parsed) and parsed or {}
end

local function save_json_index(filePath, tbl)
    local dir = string.GetPathFromFilename(filePath)
    if dir and dir ~= "" then file.CreateDir(dir) end
    file.Write(filePath, util.TableToJSON(tbl or {}))
end

local function make_index(path, timerName)
    local cache
    local function get()
        if not cache then cache = load_json_index(path) end
        return cache
    end
    local dirty = false
    local function schedule_save()
        if dirty then return end
        dirty = true
        timer.Create(timerName, 1, 1, function()
            dirty = false
            save_json_index(path, get())
        end)
    end
    return get, schedule_save
end

local motion_meta_index, save_motion_meta_index = make_index(MOTION_META_INDEX_PATH, "MMDVMDNPCMotionMetaSave")
local built_header_index, save_built_header_index = make_index(BUILT_HEADER_INDEX_PATH, "MMDVMDNPCBuiltHeaderSave")

-- Bump when the derived meta gains fields: index entries persisted by an older
-- addon version lack them, and the mtime+size key alone would keep serving the
-- stale shape forever (the motion files themselves did not change).
local MOTION_META_SCHEMA = 2

-- True when MotionMetadata(id) would be served straight from the persisted
-- index — i.e. calling it costs no multi-MB JSON parse. Lets callers budget
-- the expensive derives (send_motion_details time-slices them per tick).
function MMDVMDNPC.HasMotionMetadataCached(motionID)
    local info = motion_file_info(motionID)
    if not info then return false end
    local cached = motion_meta_index()[info.id]
    if not istable(cached) or not istable(cached.meta) then return false end
    if cached.meta.schema ~= MOTION_META_SCHEMA then return false end
    return cached.modified == (info.modified or 0)
        and cached.size == (file.Size(info.path, info.realm) or -1)
end

-- Motion metadata: served from the index whenever the file's mtime is unchanged
-- so a full parse only happens for new/changed motions.
function MMDVMDNPC.MotionMetadata(motionID)
    local info = motion_file_info(motionID)
    if not info then return nil, "invalid motion id" end

    local modified = info.modified or 0
    -- Size is part of the validity key: file.Time is only whole-second, so a
    -- same-second content replacement (backup restore, cp -p, a re-import inside
    -- one second) would otherwise keep serving stale persisted metadata.
    local size = file.Size(info.path, info.realm) or -1
    local idx = motion_meta_index()
    local cached = idx[info.id]
    if istable(cached) and cached.modified == modified and cached.size == size
        and istable(cached.meta) and cached.meta.schema == MOTION_META_SCHEMA then
        return cached.meta
    end

    local hadCachedMotion = MMDVMDNPC.Cache[info.id] ~= nil

    -- Header fast path: splice the small head + tail of the file and run the
    -- same normalization, skipping the multi-MB track arrays entirely. Falls
    -- back to the exact full parse for any file that does not match the
    -- writer's layout. The header-mode motion has stubbed (empty) tracks and
    -- must NEVER enter MMDVMDNPC.Cache — playback would pose nothing. Known
    -- trade-off: track-level validation (duplicate targets, bad keyframes)
    -- is skipped here, so such a broken file gets listed and only errors when
    -- played — LoadMotion still full-parses on every play/build path.
    -- A motion already resident in the Cache skips the header I/O: LoadMotion
    -- serves it from memory when fresh, exactly like the old path.
    local motion, headerCounts
    if not hadCachedMotion then
        local parsedHeader = parse_motion_header(info)
        if parsedHeader then
            local headerMotion = build_motion_from_parsed(parsedHeader, info.path, info.realm, info)
            if headerMotion then
                motion = headerMotion
                headerCounts = {
                    bones = math.Clamp(math.floor(parsedHeader.bone_count), 0, 65535),
                    flexes = math.Clamp(math.floor(parsedHeader.flex_count), 0, 65535),
                }
            end
        end
    end
    if not motion then
        local loaded, err = MMDVMDNPC.LoadMotion(info.id)
        if not loaded then return nil, err end
        motion = loaded
    end

    -- Category rule: motions in the user's DATA folder are ALWAYS "User Import"
    -- (the realm decides, not the JSON — a local import that was also exported
    -- as a GMA carries is_addon=true but is still the user's own import). Only
    -- motions mounted from addons use their authored category, with a fallback
    -- bucket for addon motions that ship without one.
    local motionMeta = motion.meta or {}
    local category
    if info.isAddon == true then
        local authored = tostring(motionMeta.category or "")
        -- "__"-prefixed names are reserved for the sentinels; an authored
        -- category must not be able to impersonate "User Import".
        if string.sub(authored, 1, 2) == "__" then authored = "" end
        category = authored ~= "" and authored or MMDVMDNPC.CategoryAddonOther
    else
        category = MMDVMDNPC.CategoryUserImport
    end

    local meta = {
        schema = MOTION_META_SCHEMA,
        id = info.id,
        fps = motion.fps or MMDVMDNPC.VMDFPS or 30,
        frameStart = motion.frameStart or 0,
        frameEnd = motion.frameEnd or 0,
        frameCount = motion.frameCount or 0,
        duration = motion.duration or 0,
        boneCount = headerCounts and headerCounts.bones or #(motion.boneTracks or {}),
        flexCount = headerCounts and headerCounts.flexes or #(motion.flexTracks or {}),
        -- The name/source/music strings also come straight from the JSON and
        -- are netted per entry: clamp them like the meta block.
        displayName = clamp_meta_string((motion.displayName and motion.displayName ~= "") and motion.displayName or info.id, 256),
        sourceName = clamp_meta_string(motion.sourceName, 256),
        sourcePath = clamp_meta_string(motion.sourcePath, 256),
        modelPath = clamp_meta_string(motion.modelPath, 256),
        modified = modified,
        isAddon = motion.isAddon == true,
        fromAddon = info.isAddon == true,
        category = category,
        englishName = tostring(motionMeta.englishName or ""),
        artist = tostring(motionMeta.artist or ""),
        language = tostring(motionMeta.language or ""),
        link = tostring(motionMeta.link or ""),
        motionArtist = tostring(motionMeta.motionArtist or ""),
        musicSound = clamp_meta_string(motion.music and motion.music.sound, 256),
        musicSource = clamp_meta_string(motion.music and motion.music.source, 256),
        musicSampleRate = motion.music and motion.music.sampleRate or 0,
        musicOffset = motion.defaultAudioOffset or (motion.music and motion.music.offset) or 0,
        hasCamera = motion.camera ~= nil,
    }

    idx[info.id] = { modified = modified, size = size, meta = meta }
    save_motion_meta_index()
    -- The full parsed motion (multi-MB of baked tracks) was only needed to
    -- derive this small header. Keeping every such motion resident would run
    -- the game out of memory the first time a mounted pack brings dozens of
    -- dances (menu open -> details walk -> N full parses all retained).
    -- Playback/build reloads on demand; the persisted index makes this derive
    -- a one-time cost per file.
    if not hadCachedMotion then
        MMDVMDNPC.Cache[info.id] = nil
    end
    return meta
end

function MMDVMDNPC.ForgetMotionMeta(motionID)
    local id = MMDVMDNPC.NormalizeMotionID(motionID) or tostring(motionID or "")
    local idx = motion_meta_index()
    if idx[id] ~= nil then
        idx[id] = nil
        save_motion_meta_index()
    end
end

-- Built-cache header {motion_id, model, format} without parsing the whole file
-- once the index knows it. builtInMem is the in-memory BuiltCache entry, if any.
local function derive_built_header(built, modified)
    return {
        motion_id = tostring(built.motion_id or ""),
        model = tostring(built.model or ""),
        format = tostring(built.format or ""),
        modified = modified,
    }
end

function MMDVMDNPC.BuiltHeader(path, builtInMem)
    if not path or path == "" then return nil end
    local modified = file.Time(path, "DATA") or 0
    if modified == 0 and not file.Exists(path, "DATA") then return nil end

    local idx = built_header_index()
    local entry = idx[path]
    if istable(entry) and entry.modified == modified then
        return entry
    end

    local built = builtInMem
    if not istable(built) then
        local raw = file.Read(path, "DATA")
        built = raw and util.JSONToTable(raw) or nil
    end
    if not istable(built) then return nil end

    entry = derive_built_header(built, modified)
    idx[path] = entry
    save_built_header_index()
    return entry
end

function MMDVMDNPC.NoteBuiltHeader(path, built)
    if not path or path == "" or not istable(built) then return end
    built_header_index()[path] = derive_built_header(built, file.Time(path, "DATA") or 0)
    save_built_header_index()
end

function MMDVMDNPC.ForgetBuiltHeader(path)
    if not path then return end
    local idx = built_header_index()
    if idx[path] ~= nil then
        idx[path] = nil
        save_built_header_index()
    end
end

-- Drop index entries whose files no longer exist. Files removed outside the
-- addon's own delete/clear paths (manual deletion, MRU eviction then deletion)
-- would otherwise linger forever; a stale entry is never served (both lookups
-- re-validate against the live file) but the sidecars would grow unbounded.
-- Runs once, shortly after server start.
function MMDVMDNPC.PruneStaleIndexes()
    local built = built_header_index()
    local builtChanged = false
    for path in pairs(built) do
        if not file.Exists(path, "DATA") then
            built[path] = nil
            builtChanged = true
        end
    end
    if builtChanged then save_built_header_index() end

    local meta = motion_meta_index()
    local metaChanged = false
    for id in pairs(meta) do
        local info = motion_file_info(id)
        if not info or not file.Exists(info.path, info.realm) then
            meta[id] = nil
            metaChanged = true
        end
    end
    if metaChanged then save_motion_meta_index() end
end

timer.Simple(30, function()
    if MMDVMDNPC.PruneStaleIndexes then MMDVMDNPC.PruneStaleIndexes() end
end)

function MMDVMDNPC.ListMotions()
    local files = file.Find(MMDVMDNPC.MotionRoot .. "/*" .. MMDVMDNPC.CacheExtension, "DATA", "nameasc")
    local addonFiles = file.Find(STATIC_MOTION_ROOT .. "/*" .. MMDVMDNPC.CacheExtension, "GAME", "nameasc")
    local list = {}
    local seen = {}

    for _, name in ipairs(files or {}) do
        local id = MMDVMDNPC.NormalizeMotionID(name)
        if id and not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end

    for _, name in ipairs(addonFiles or {}) do
        local id = MMDVMDNPC.NormalizeMotionID(name)
        if id and not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end

    table.sort(list)
    return list
end

function MMDVMDNPC.LoadMotion(motionID)
    local info = motion_file_info(motionID)
    if not info then
        return nil, "invalid motion id"
    end

    local id = info.id
    local modified = info.modified or file.Time(info.path, info.realm) or 0
    local cached = MMDVMDNPC.Cache[id]
    if cached and cached.modified == modified and cached.path == info.path and cached.realm == info.realm then
        return cached.motion
    end

    local motion, err = read_motion_file(info)
    if not motion then return nil, err end

    motion.id = id
    motion.modified = modified
    MMDVMDNPC.Cache[id] = {
        modified = modified,
        path = info.path,
        realm = info.realm,
        motion = motion,
    }

    return motion
end

function MMDVMDNPC.ClearMotionCache()
    MMDVMDNPC.Cache = {}
end
