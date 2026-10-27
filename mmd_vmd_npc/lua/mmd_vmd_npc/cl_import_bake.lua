-- In-game motion import, the conversion half: a Lua port of
-- tools/vmd_baker.py (pose bake, ground unification, scene cuts, export) and
-- of the steps tools/import_vmd.py runs around it (VMD parsing, flex merge,
-- camera track, motion JSON), so an import made in game writes the same
-- motion file as the desktop importer. The bundled model's skeleton comes
-- precomputed from cl_import_data.lua (tools/build_ingame_import_data.py).
--
-- Long loops call opts.checkpoint(); cl_importer.lua runs every step in a
-- coroutine that yields there, so the game keeps drawing during a bake.
-- Only the standard Lua 5.1 library is used, plus util.SHA1 through
-- Bake.SHA1, so tests/test_ingame_importer.py can run this file under LuaJIT
-- and compare its output with the Python importer's. Keep the two in step.
MMDVMDNPC = MMDVMDNPC or {}
local Bake = {}
MMDVMDNPC.ImportBake = Bake

local byte, sub, find, format, gsub, lower = string.byte, string.sub, string.find, string.format, string.gsub, string.lower
local floor, ceil, sqrt, abs = math.floor, math.ceil, math.sqrt, math.abs
local sin, cos, acos, asin, atan2, exp = math.sin, math.cos, math.acos, math.asin, math.atan2, math.exp
local ldexp, fmod, huge, pi = math.ldexp, math.fmod, math.huge, math.pi
local concat, sort = table.concat, table.sort

Bake.OutputFormat = "mmd_vmd_npc_parent_corrected_axis_v1"
Bake.VMDFPS = 30
-- About 2.3 hours at 30 fps: a larger range is a corrupt frame number.
Bake.MaxBakeFrames = 250000

-- mmd_tools imports at 0.08 Blender units per MMD unit; the export writes
-- 41.78 Source units per Blender unit.
local POSITION_SCALE = 0.08 * 41.78
local CAMERA_POSITION_SCALE = 41.78 * 0.08
-- ROTATION_EPSILON_DEGREES and POSITION_EPSILON_SOURCE_UNITS (both 0.0005).
local EPSILON = 0.0005
local RAD2DEG = 180 / pi
local CHUNK_FRAMES = 2048
local GROUND_AIRBORNE_FRAMES = 15
local GROUND_CUT_STEP = 2.0
local GROUND_SMOOTH_SIGMA = 2.0
local CAMERA_TRACK_FORMAT = 1
local CAMERA_POS_EPS = 0.1
local CAMERA_ANG_EPS = 0.05
local CAMERA_FOV_EPS = 0.02
local CAMERA_MAX_KEYS = 20000

local function noop() end

Bake.SHA1 = Bake.SHA1 or (util and util.SHA1)

-- ---------------------------------------------------------------------------
-- Numbers: numpy and Python rounding, JSON text.
-- ---------------------------------------------------------------------------
local function clip(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- numpy's rint: to the nearest integer, ties to even.
local function rint(v)
    local f = floor(v + 0.5)
    if f - v == 0.5 and f % 2 ~= 0 then f = f - 1 end
    return f
end

-- np.round(v, 6), which multiplies, rints and divides.
local function round6(v)
    return rint(v * 1e6) / 1e6
end

-- Python's round(v, digits): the nearest decimal, read back.
local ROUND_FORMATS = { [3] = "%.3f", [4] = "%.4f", [5] = "%.5f", [6] = "%.6f" }
local function py_round(v, digits)
    return tonumber(format(ROUND_FORMATS[digits], v))
end

-- Python's float %, as numpy's mod: the result takes the divisor's sign.
local function py_mod(a, b)
    local m = fmod(a, b)
    if m ~= 0 then
        if (b < 0) ~= (m < 0) then m = m + b end
    else
        m = b < 0 and -0.0 or 0.0
    end
    return m
end

-- max(0.0, min(1.0, w)) with Python's comparisons (NaN becomes 1).
local function clamp01(w)
    local m = 1.0
    if w < 1.0 then m = w end
    if m > 0.0 then return m end
    return 0.0
end

local function finite_or_zero(v)
    if v ~= v or v == huge or v == -huge then return 0 end
    return v
end

-- Shortest text for a value that is already rounded to at most 6 decimals,
-- as Python's json.dumps prints it (without its ".0" on whole floats).
local function trim_number(s)
    local n = #s
    if find(s, ".", 1, true) then
        while byte(s, n) == 48 do n = n - 1 end
        if byte(s, n) == 46 then n = n - 1 end
        s = sub(s, 1, n)
    end
    if s == "-0" then return "0" end
    return s
end

local function num(v)
    if v == 0 then return "0" end
    if v == floor(v) and v > -1e15 and v < 1e15 then return format("%d", v) end
    return trim_number(format("%.6f", v))
end
Bake.FormatNumber = num

local function fixed3(v)
    return trim_number(format("%.3f", v))
end

local JSON_ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function json_escape(char)
    return JSON_ESCAPES[char] or format("\\u%04x", byte(char))
end

local function json_string(s)
    return '"' .. gsub(s, '[%z\1-\31"\\]', json_escape) .. '"'
end
Bake.JSONString = json_string

-- Objects keep their key order; RAW wraps text that is already JSON.
local KEYS, RAW = {}, {}

function Bake.Object()
    return { [KEYS] = {} }
end

function Bake.Put(object, key, value)
    if value == nil then return object end
    if object[key] == nil then
        local keys = object[KEYS]
        keys[#keys + 1] = key
    end
    object[key] = value
    return object
end

function Bake.Get(object, key)
    return object[key]
end

function Bake.Remove(object, key)
    if object[key] == nil then return end
    object[key] = nil
    local keys = object[KEYS]
    for i = #keys, 1, -1 do
        if keys[i] == key then table.remove(keys, i) end
    end
end

function Bake.Raw(text)
    return { [RAW] = text }
end

local function encode(value, out)
    local kind = type(value)
    if kind == "string" then
        out[#out + 1] = json_string(value)
    elseif kind == "number" then
        out[#out + 1] = num(value)
    elseif kind == "boolean" then
        out[#out + 1] = value and "true" or "false"
    elseif kind == "table" then
        if value[RAW] then
            out[#out + 1] = value[RAW]
        elseif value[KEYS] then
            out[#out + 1] = "{"
            for i, key in ipairs(value[KEYS]) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = json_string(key)
                out[#out + 1] = ":"
                encode(value[key], out)
            end
            out[#out + 1] = "}"
        else
            out[#out + 1] = "["
            for i, item in ipairs(value) do
                if i > 1 then out[#out + 1] = "," end
                encode(item, out)
            end
            out[#out + 1] = "]"
        end
    else
        out[#out + 1] = "null"
    end
end

function Bake.EncodeJSON(value)
    local out = {}
    encode(value, out)
    return concat(out)
end

-- Log text for a raw cp932 name: its ASCII part.
local function printable(raw)
    return (gsub(raw, "[\128-\255]+", "?"))
end

local function preview(list, limit, toText)
    local parts = {}
    for i = 1, math.min(#list, limit) do parts[i] = toText and toText(list[i]) or tostring(list[i]) end
    return concat(parts, ", ") .. (#list > limit and " ..." or "")
end

-- ---------------------------------------------------------------------------
-- VMD files.
-- ---------------------------------------------------------------------------
local function u32(s, p)
    local a, b, c, d = byte(s, p, p + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function f32(s, p)
    local a, b, c, d = byte(s, p, p + 3)
    local exponent = (d % 128) * 2 + floor(c / 128)
    local mantissa = (c % 128) * 65536 + b * 256 + a
    local value
    if exponent == 0 then
        value = ldexp(mantissa, -149)
    elseif exponent == 255 then
        value = mantissa == 0 and huge or (0 / 0)
    else
        value = ldexp(mantissa + 8388608, exponent - 150)
    end
    if d >= 128 then return -value end
    return value
end

-- Fixed-width cp932 name field, up to its first NUL. Names stay raw bytes:
-- cl_import_data.lua keys the model's names the same way.
local function raw_name(s, p, size)
    local raw = sub(s, p, p + size - 1)
    local zero = find(raw, "\0", 1, true)
    if zero then return sub(raw, 1, zero - 1) end
    return raw
end

-- Bone records keep their offset into `data` (decoded only for bones the
-- bake uses); opts.bones = false and opts.morphs = false skip those sections.
function Bake.ParseVMD(data, opts)
    opts = opts or {}
    local checkpoint = opts.checkpoint or noop
    local size = #data
    local pos = 1

    local function need(count)
        if pos + count - 1 > size then error("unexpected end of VMD", 0) end
    end

    local function count_or_zero()
        if pos + 3 > size then
            pos = size + 1
            return 0
        end
        local count = u32(data, pos)
        pos = pos + 4
        return count
    end

    need(30)
    local nameSize
    if sub(data, 1, 25) == "Vocaloid Motion Data 0002" then
        nameSize = 20
    elseif sub(data, 1, 25) == "Vocaloid Motion Data file" then
        -- Legacy v1 files store a 10-byte model name.
        nameSize = 10
    elseif sub(data, 1, 20) == "Vocaloid Motion Data" then
        nameSize = 20
    else
        error("not a VMD file", 0)
    end
    pos = 31
    need(nameSize)
    local parsed = {
        data = data,
        modelName = raw_name(data, pos, nameSize),
        boneOrder = {},
        bones = {},
        morphOrder = {},
        morphs = {},
        camera = {},
        properties = {},
    }
    pos = pos + nameSize
    local maxFrame = 0

    need(4)
    local count = u32(data, pos)
    pos = pos + 4
    need(count * 111)
    if opts.bones ~= false then
        local bones, order = parsed.bones, parsed.boneOrder
        local p = pos
        for i = 1, count do
            local frame = u32(data, p + 15)
            if frame > maxFrame then maxFrame = frame end
            local name = raw_name(data, p, 15)
            local track = bones[name]
            if not track then
                track = { frames = {}, offsets = {}, count = 0 }
                bones[name] = track
                order[#order + 1] = name
            end
            local n = track.count + 1
            track.count = n
            track.frames[n] = frame
            track.offsets[n] = p
            p = p + 111
            if i % 2048 == 0 then checkpoint() end
        end
    end
    pos = pos + count * 111

    count = count_or_zero()
    need(count * 23)
    if opts.morphs ~= false then
        -- Parallel arrays: face VMDs hold hundreds of thousands of keys.
        local morphs, order = parsed.morphs, parsed.morphOrder
        local p = pos
        for i = 1, count do
            local name = raw_name(data, p, 15)
            local frame = u32(data, p + 15)
            if frame > maxFrame then maxFrame = frame end
            local keys = morphs[name]
            if not keys then
                keys = { frames = {}, weights = {}, count = 0 }
                morphs[name] = keys
                order[#order + 1] = name
            end
            local n = keys.count + 1
            keys.count = n
            keys.frames[n] = frame
            keys.weights[n] = f32(data, p + 19)
            p = p + 23
            if i % 4096 == 0 then checkpoint() end
        end
    end
    pos = pos + count * 23

    -- Camera records: frame, distance, target, rotation (radians), 24
    -- interpolation bytes, fov (degrees), perspective-off flag. They never
    -- extend maxFrame, which drives the body bake length.
    count = count_or_zero()
    need(count * 61)
    if opts.camera ~= false then
        local camera = parsed.camera
        for i = 1, count do
            local p = pos + (i - 1) * 61
            local interp = { byte(data, p + 32, p + 55) }
            camera[i] = {
                frame = u32(data, p),
                distance = f32(data, p + 4),
                x = f32(data, p + 8), y = f32(data, p + 12), z = f32(data, p + 16),
                rx = f32(data, p + 20), ry = f32(data, p + 24), rz = f32(data, p + 28),
                interp = interp,
                fov = u32(data, p + 56),
            }
        end
    end
    pos = pos + count * 61

    -- Light and self-shadow records, skipped to reach the property frames.
    count = count_or_zero()
    need(count * 28)
    pos = pos + count * 28
    count = count_or_zero()
    need(count * 9)
    pos = pos + count * 9

    count = count_or_zero()
    local properties = parsed.properties
    for _ = 1, count do
        need(9)
        local frame = u32(data, pos)
        local states = u32(data, pos + 5)
        pos = pos + 9
        need(states * 21)
        local ik = {}
        for k = 1, states do
            ik[k] = { raw_name(data, pos, 20), byte(data, pos + 20) ~= 0 }
            pos = pos + 21
        end
        properties[#properties + 1] = { frame = frame, ik = ik }
        if frame > maxFrame then maxFrame = frame end
    end

    parsed.maxFrame = maxFrame
    parsed.boneTrackCount = #parsed.boneOrder
    return parsed
end

-- Stable sort of { frame, ... } records (Python's sorted keeps file order).
local function sorted_by_frame(list, frameOf)
    frameOf = frameOf or function(item) return item.frame end
    local inOrder = true
    for i = 2, #list do
        if frameOf(list[i]) < frameOf(list[i - 1]) then
            inOrder = false
            break
        end
    end
    if inOrder then return list end
    local decorated = {}
    for i, item in ipairs(list) do decorated[i] = { item, i } end
    sort(decorated, function(a, b)
        local fa, fb = frameOf(a[1]), frameOf(b[1])
        if fa ~= fb then return fa < fb end
        return a[2] < b[2]
    end)
    local out = {}
    for i, entry in ipairs(decorated) do out[i] = entry[1] end
    return out
end

-- ---------------------------------------------------------------------------
-- Quaternions (x, y, z, w) and vectors, as multiple return values.
-- ---------------------------------------------------------------------------
local function qmul(ax, ay, az, aw, bx, by, bz, bw)
    return aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz
end

local function qnormalize(x, y, z, w)
    local length = sqrt(x * x + y * y + z * z + w * w)
    if length > 1e-12 then return x / length, y / length, z / length, w / length end
    return 0, 0, 0, 1
end

local function qrotate(qx, qy, qz, qw, vx, vy, vz)
    local tx = 2 * (qy * vz - qz * vy)
    local ty = 2 * (qz * vx - qx * vz)
    local tz = 2 * (qx * vy - qy * vx)
    return vx + qw * tx + (qy * tz - qz * ty),
        vy + qw * ty + (qz * tx - qx * tz),
        vz + qw * tz + (qx * ty - qy * tx)
end

local function axis_angle(ax, ay, az, angle)
    local half = 0.5 * angle
    local s = sin(half)
    return ax * s, ay * s, az * s, cos(half)
end

-- Shortest-path spherical interpolation (MMD/D3DX semantics).
local function qslerp(ax, ay, az, aw, bx, by, bz, bw, t)
    local dot = ax * bx + ay * by + az * bz + aw * bw
    if dot < 0 then bx, by, bz, bw = -bx, -by, -bz, -bw end
    dot = abs(dot)
    if dot > 1 then dot = 1 end
    local theta = acos(dot)
    local sinTheta = sin(theta)
    local s0, s1
    if sinTheta < 1e-10 then
        s0, s1 = 1 - t, t
    else
        s0, s1 = sin((1 - t) * theta) / sinTheta, sin(t * theta) / sinTheta
    end
    return qnormalize(ax * s0 + bx * s1, ay * s0 + by * s1, az * s0 + bz * s1, aw * s0 + bw * s1)
end

-- slerp(identity, q, weight); negative weights invert ("cancel" bones).
local function qpower(x, y, z, w, weight)
    if w < 0 then x, y, z, w = -x, -y, -z, -w end
    local length = sqrt(x * x + y * y + z * z)
    if length <= 1e-12 then return 0, 0, 0, 1 end
    local angle = 2 * atan2(length, w)
    return axis_angle(x / length, y / length, z / length, angle * weight)
end

local function vnormalize(x, y, z)
    local length = sqrt(x * x + y * y + z * z)
    local d = length > 1e-12 and length or 1
    return x / d, y / d, z / d, length
end

local function cross(ax, ay, az, bx, by, bz)
    return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

local function component(x, y, z, axis)
    if axis == 1 then return x end
    if axis == 2 then return y end
    return z
end

local function unit_axis(axis)
    return axis == 1 and 1 or 0, axis == 2 and 1 or 0, axis == 3 and 1 or 0
end

-- Angles (x, y, z) with m = Rx(x) Ry(y) Rz(z) nearest `before`, which keeps
-- the clamping of multi-axis IK links continuous.
local function diff_angle(a, b)
    return py_mod(a - b + pi, 2 * pi) - pi
end

local CANDIDATE_SHIFTS = {
    { pi, pi, pi }, { pi, pi, -pi }, { pi, -pi, pi }, { pi, -pi, -pi },
    { -pi, pi, pi }, { -pi, pi, -pi }, { -pi, -pi, pi }, { -pi, -pi, -pi },
}

local function decompose_xyz(x, y, z, w, bx, by, bz)
    local xx, yy, zz = x * x, y * y, z * z
    local xy, xz, yz = x * y, x * z, y * z
    local wx, wy, wz = w * x, w * y, w * z
    local m00 = 1 - 2 * (yy + zz)
    local m01 = 2 * (xy - wz)
    local m02 = 2 * (xz + wy)
    local m10 = 2 * (xy + wz)
    local m11 = 1 - 2 * (xx + zz)
    local m12 = 2 * (yz - wx)
    local m22 = 1 - 2 * (xx + yy)
    local sy = clip(m02, -1, 1)
    local ay = asin(sy)
    local ax = atan2(-m12, m22)
    local az = atan2(-m01, m00)
    if abs(sy) > 1 - 1e-6 then
        -- Gimbal: keep the previous X, put the remaining roll into Z.
        ax = bx
        az = atan2(m10, m11) - (sy > 0 and 1 or -1) * ax
    end
    local bestX, bestY, bestZ = ax, ay, az
    local bestErr = abs(diff_angle(ax, bx)) + abs(diff_angle(ay, by)) + abs(diff_angle(az, bz))
    for _, shift in ipairs(CANDIDATE_SHIFTS) do
        local cx, cy, cz = ax + shift[1], shift[2] - ay, az + shift[3]
        local err = abs(diff_angle(cx, bx)) + abs(diff_angle(cy, by)) + abs(diff_angle(cz, bz))
        if err < bestErr then
            bestX, bestY, bestZ, bestErr = cx, cy, cz, err
        end
    end
    return bestX, bestY, bestZ
end

local function quat_from_xyz(ax, ay, az)
    local x, y, z, w = axis_angle(1, 0, 0, ax)
    x, y, z, w = qmul(x, y, z, w, axis_angle(0, 1, 0, ay))
    return qmul(x, y, z, w, axis_angle(0, 0, 1, az))
end

-- ---------------------------------------------------------------------------
-- Bezier curves.
-- ---------------------------------------------------------------------------
local function bezier(s, p1, p2)
    local inv = 1 - s
    return 3 * inv * inv * s * p1 + 3 * inv * s * s * p2 + s * s * s
end

-- Progress at x of the unit bezier (0,0)-(x1,y1)-(x2,y2)-(1,1); bisection,
-- exact to ~1e-10 and never diverging.
local function bezier_progress(x, x1, y1, x2, y2)
    if x1 == y1 and x2 == y2 then return x end
    local lo, hi = 0, 1
    for _ = 1, 34 do
        local mid = 0.5 * (lo + hi)
        if bezier(mid, x1, x2) < x then lo = mid else hi = mid end
    end
    return bezier(0.5 * (lo + hi), y1, y2)
end

local function bezier_point(t, p0, p1, p2, p3)
    local inv = 1 - t
    return inv * inv * inv * p0 + 3 * inv * inv * t * p1 + 3 * inv * t * t * p2 + t * t * t * p3
end

-- Camera channels store (x1, x2, y1, y2), unlike bone curves.
local function camera_weight(t, interp, channel)
    if t <= 0 then return 0 end
    if t >= 1 then return 1 end
    local base = channel * 4
    local x1, x2 = interp[base + 1] / 127, interp[base + 2] / 127
    local y1, y2 = interp[base + 3] / 127, interp[base + 4] / 127
    if abs(x1 - y1) < 1e-6 and abs(x2 - y2) < 1e-6 then return t end
    local lo, hi = 0, 1
    for _ = 1, 32 do
        local mid = (lo + hi) * 0.5
        if bezier_point(mid, 0, x1, x2, 1) < t then lo = mid else hi = mid end
    end
    return bezier_point((lo + hi) * 0.5, 0, y1, y2, 1)
end

-- ---------------------------------------------------------------------------
-- Tracks of the body VMD on the bundled skeleton.
-- ---------------------------------------------------------------------------
local function resolve_name(D, name, truncated)
    local index = D.exactNames[name]
    if index ~= nil then return index, true end
    index = truncated[name]
    if index ~= nil then return index, false end
    return nil, false
end

local function build_track(data, keys)
    local frames, offsets, n = keys.frames, keys.offsets, keys.count
    local order = {}
    local inOrder = true
    for i = 1, n do
        order[i] = i
        if i > 1 and frames[i] < frames[i - 1] then inOrder = false end
    end
    if not inOrder then
        sort(order, function(a, b)
            local fa, fb = frames[a], frames[b]
            if fa ~= fb then return fa < fb end
            return a < b
        end)
    end
    local track = { kf = {}, lx = {}, ly = {}, lz = {}, qx = {}, qy = {}, qz = {}, qw = {}, ip = {}, data = data, index = 0, curveKey = 0 }
    local count = 0
    for _, i in ipairs(order) do
        local frame = frames[i]
        -- The last key of a duplicated frame wins.
        if count == 0 or track.kf[count] ~= frame then count = count + 1 end
        local p = offsets[i]
        track.kf[count] = frame
        track.lx[count] = finite_or_zero(f32(data, p + 19))
        track.ly[count] = finite_or_zero(f32(data, p + 23))
        track.lz[count] = finite_or_zero(f32(data, p + 27))
        local x, y, z, w = f32(data, p + 31), f32(data, p + 35), f32(data, p + 39), f32(data, p + 43)
        if x == 0 and y == 0 and z == 0 and w == 0 then x, y, z, w = 0, 0, 0, 1 end
        x, y, z, w = qnormalize(finite_or_zero(x), finite_or_zero(y), finite_or_zero(z), finite_or_zero(w))
        track.qx[count], track.qy[count], track.qz[count], track.qw[count] = x, y, z, w
        track.ip[count] = p + 47
    end
    track.count = count
    track.curve = {}
    return track
end

-- Location and rotation at `frame`; frames must be asked for in increasing
-- order (each track keeps its position).
local function sample_track(track, frame)
    local count = track.count
    if count == 1 then
        return track.lx[1], track.ly[1], track.lz[1], track.qx[1], track.qy[1], track.qz[1], track.qw[1]
    end
    local kf = track.kf
    local index = track.index
    while index < count and kf[index + 1] <= frame do index = index + 1 end
    track.index = index
    local i0 = index < 1 and 1 or index
    local i1 = index + 1
    if i1 > count then i1 = count end
    local wx, wy, wz, wr = 0, 0, 0, 0
    if index >= 1 and index < count then
        local t = (frame - kf[i0]) / (kf[i1] - kf[i0])
        if t > 0 then
            local c = track.curve
            if track.curveKey ~= i1 then
                -- Each channel reads its own 16-byte row: (x1, y1, x2, y2) at
                -- offsets 0, 4, 8, 12 (newer MMD writes a physics flag over
                -- bytes 2 and 3 of the first row).
                local data, p = track.data, track.ip[i1]
                for channel = 0, 3 do
                    local base = p + channel * 16
                    c[channel * 4 + 1] = byte(data, base) / 127
                    c[channel * 4 + 2] = byte(data, base + 4) / 127
                    c[channel * 4 + 3] = byte(data, base + 8) / 127
                    c[channel * 4 + 4] = byte(data, base + 12) / 127
                end
                track.curveKey = i1
            end
            wx = bezier_progress(t, c[1], c[2], c[3], c[4])
            wy = bezier_progress(t, c[5], c[6], c[7], c[8])
            wz = bezier_progress(t, c[9], c[10], c[11], c[12])
            wr = bezier_progress(t, c[13], c[14], c[15], c[16])
        end
    end
    local lx, ly, lz = track.lx, track.ly, track.lz
    local qx, qy, qz, qw = track.qx, track.qy, track.qz, track.qw
    local x, y, z, w = qslerp(qx[i0], qy[i0], qz[i0], qw[i0], qx[i1], qy[i1], qz[i1], qw[i1], wr)
    return lx[i0] + (lx[i1] - lx[i0]) * wx,
        ly[i0] + (ly[i1] - ly[i0]) * wy,
        lz[i0] + (lz[i1] - lz[i0]) * wz,
        x, y, z, w
end

-- ---------------------------------------------------------------------------
-- Ground unification and scene cuts (see vmd_baker.py).
-- ---------------------------------------------------------------------------

-- Row indices i (1-based) where the position jumps from row i - 1: a step
-- above CutMinStep Source units and CutRatio times the median step of the
-- CutNeighbours rows on either side (rows past either end count as still).
-- Same rule as MMDVMDNPC.BuiltPoseCuts in sh_core.lua.
local function detect_pose_cuts(xs, ys, zs)
    local n = #xs
    local cuts = {}
    if n < 2 then return cuts end
    local minStep = MMDVMDNPC.CutMinStep or 8
    local ratio = MMDVMDNPC.CutRatio or 4
    local span = MMDVMDNPC.CutNeighbours or 3
    local steps = { 0 }
    for i = 2, n do
        local dx, dy, dz = xs[i] - xs[i - 1], ys[i] - ys[i - 1], zs[i] - zs[i - 1]
        steps[i] = sqrt(dx * dx + dy * dy + dz * dz)
    end
    local around = {}
    for i = 2, n do
        local step = steps[i]
        if step > minStep then
            for k = 1, span do
                around[k] = steps[i - k] or 0
                around[span + k] = steps[i + k] or 0
            end
            sort(around)
            local median = (around[span] + around[span + 1]) * 0.5
            if step > ratio * median then cuts[#cuts + 1] = i end
        end
    end
    return cuts
end

local function sliding(values, half, pick)
    local n, out = #values, {}
    for i = 1, n do
        local best
        for k = i - half, i + half do
            local v = values[k < 1 and 1 or (k > n and n or k)]
            if best == nil or pick(v, best) then best = v end
        end
        out[i] = best
    end
    return out
end

local function is_less(a, b) return a < b end
local function is_greater(a, b) return a > b end

-- numpy's pairwise sum, for the 13 kernel taps.
local function pairwise_sum(values)
    local n = #values
    if n < 8 then
        local total = 0
        for i = 1, n do total = total + values[i] end
        return total
    end
    local r = {}
    for j = 1, 8 do r[j] = values[j] end
    local i = 9
    local whole = n - n % 8
    while i <= whole do
        for j = 0, 7 do r[j + 1] = r[j + 1] + values[i + j] end
        i = i + 8
    end
    local total = ((r[1] + r[2]) + (r[3] + r[4])) + ((r[5] + r[6]) + (r[7] + r[8]))
    while i <= n do
        total = total + values[i]
        i = i + 1
    end
    return total
end

local function gaussian_smooth(values, sigma)
    local n = #values
    local radius = ceil(3 * sigma)
    local out = {}
    if sigma <= 0 or radius < 1 or n < 2 then
        for i = 1, n do out[i] = values[i] end
        return out
    end
    local kernel = {}
    for k = -radius, radius do
        local t = k / sigma
        kernel[#kernel + 1] = exp(-0.5 * (t * t))
    end
    local total = pairwise_sum(kernel)
    for k = 1, #kernel do kernel[k] = kernel[k] / total end
    for i = 1, n do
        local sum = 0
        for k = 1, #kernel do
            local at = i + k - 1 - radius
            sum = sum + values[at < 1 and 1 or (at > n and n or at)] * kernel[k]
        end
        out[i] = sum
    end
    return out
end

-- Per-frame height (MMD units) to subtract from the whole character so its
-- ground contact stays on the rest-pose floor: the morphological opening of
-- the lowest contact (jumps keep their height, steps and slopes are
-- followed), smoothed except across platform changes and scene cuts.
local function ground_offsets(lowest, restHeight, poseCuts)
    local n = #lowest
    if n == 0 then return {} end
    local half = GROUND_AIRBORNE_FRAMES
    local floorHeights = sliding(sliding(lowest, half, is_less), half, is_greater)
    local starts = {}
    for i = 2, n do
        if abs(floorHeights[i] - floorHeights[i - 1]) > GROUND_CUT_STEP then starts[i] = true end
    end
    for _, i in ipairs(poseCuts or {}) do starts[i] = true end
    local offsets = {}
    local first = 1
    for i = 2, n + 1 do
        if i > n or starts[i] then
            local run = {}
            for k = first, i - 1 do run[#run + 1] = floorHeights[k] end
            local smoothed = gaussian_smooth(run, GROUND_SMOOTH_SIGMA)
            for k = 1, #smoothed do offsets[first + k - 1] = smoothed[k] - restHeight end
            first = i
        end
    end
    return offsets
end

-- ---------------------------------------------------------------------------
-- Export: the parent-corrected rotation document.
-- ---------------------------------------------------------------------------
local function finish_degrees(v)
    if abs(v) < 1e-9 then v = 0 end
    v = round6(v)
    if abs(v) < EPSILON then return 0 end
    return v
end

-- Fixed-axis XYZ of R = Rz(z) Ry(y) Rx(x), in degrees, rounded like the
-- Blender exporter.
local function extrinsic_degrees(x, y, z, w)
    x, y, z, w = qnormalize(x, y, z, w)
    local xx, yy, zz = x * x, y * y, z * z
    local xy, xz, yz = x * y, x * z, y * z
    local wx, wy, wz = w * x, w * y, w * z
    local m00 = 1 - 2 * (yy + zz)
    local m01 = 2 * (xy - wz)
    local m10 = 2 * (xy + wz)
    local m11 = 1 - 2 * (xx + zz)
    local m20 = 2 * (xz - wy)
    local m21 = 2 * (yz + wx)
    local m22 = 1 - 2 * (xx + yy)
    local sy = clip(-m20, -1, 1)
    local ry = asin(sy)
    local rx, rz
    if abs(cos(ry)) > 1e-8 then
        rx = atan2(m21, m22)
        rz = atan2(m10, m00)
    else
        rx = sy > 0 and atan2(m01, m11) or atan2(-m01, m11)
        rz = 0
    end
    return finish_degrees(rx * RAD2DEG), finish_degrees(ry * RAD2DEG), finish_degrees(rz * RAD2DEG)
end

local function finish_position(v)
    if abs(v) < EPSILON then v = 0 end
    v = round6(v)
    if abs(v) < EPSILON then return 0 end
    return v
end

-- MMD offset -> the exporter's GMod position columns (MMD z, x, y) * scale.
local function source_position(dx, dy, dz, flipForward)
    local a = finish_position(dz * POSITION_SCALE)
    local b = finish_position(dx * POSITION_SCALE)
    local c = finish_position(dy * POSITION_SCALE)
    if flipForward and a ~= 0 then a = -a end
    return a, b, c
end

-- Keyframe compaction: drop held samples but keep the last frame of every
-- hold, so linear playback between kept keys reproduces each baked frame.
-- Rows are written as JSON text as they are kept.
local function compactor()
    return { rows = {}, count = 0, started = false }
end

local function compact_row(c, frame, v1, v2, v3, v4, v5, v6)
    c.count = c.count + 1
    c.rows[c.count] = format("[%d,%s,%s,%s,%s,%s,%s]", frame, num(v1), num(v2), num(v3), num(v4), num(v5), num(v6))
    c.lastKey = frame
end

local function differs(c, v1, v2, v3, v4, v5, v6)
    return abs(v1 - c.l1) > EPSILON or abs(v2 - c.l2) > EPSILON or abs(v3 - c.l3) > EPSILON
        or abs(v4 - c.l4) > EPSILON or abs(v5 - c.l5) > EPSILON or abs(v6 - c.l6) > EPSILON
end

local function compact_push(c, frame, v1, v2, v3, v4, v5, v6)
    if not c.started then
        c.started = true
        compact_row(c, frame, v1, v2, v3, v4, v5, v6)
        c.l1, c.l2, c.l3, c.l4, c.l5, c.l6 = v1, v2, v3, v4, v5, v6
    elseif differs(c, v1, v2, v3, v4, v5, v6) then
        if c.pf ~= nil and c.lastKey ~= c.pf and not differs(c, c.p1, c.p2, c.p3, c.p4, c.p5, c.p6) then
            compact_row(c, c.pf, c.p1, c.p2, c.p3, c.p4, c.p5, c.p6)
        end
        compact_row(c, frame, v1, v2, v3, v4, v5, v6)
        c.l1, c.l2, c.l3, c.l4, c.l5, c.l6 = v1, v2, v3, v4, v5, v6
    end
    c.pf = frame
    c.p1, c.p2, c.p3, c.p4, c.p5, c.p6 = v1, v2, v3, v4, v5, v6
end

local function compact_finish(c)
    if c.started and c.lastKey ~= c.pf then
        compact_row(c, c.pf, c.p1, c.p2, c.p3, c.p4, c.p5, c.p6)
    end
end

local function is_zero_transform(v1, v2, v3, v4, v5, v6)
    return abs(v1) <= EPSILON and abs(v2) <= EPSILON and abs(v3) <= EPSILON
        and abs(v4) <= EPSILON and abs(v5) <= EPSILON and abs(v6) <= EPSILON
end

-- ---------------------------------------------------------------------------
-- The bake: Python's bake_motion on one frame at a time.
-- ---------------------------------------------------------------------------

-- body: a ParseVMD result. opts: disableIK, unifyGround, inputName,
-- emit(text), progress(fraction), checkpoint().
-- Returns the document (Bake.Object) and, when unifyGround found the contact
-- bones, the ground offsets for the camera (MMD units per frame, rounded to
-- 5 decimals like the Python document's _ground_offsets_mmd).
function Bake.BakeMotion(body, opts)
    local D = MMDVMDNPC.ImportData
    if not D then error("the importer's skeleton data (cl_import_data.lua) is missing", 0) end
    opts = opts or {}
    local emit = opts.emit or noop
    local progress = opts.progress or noop
    local checkpoint = opts.checkpoint or noop

    local frameStart, frameEnd = 0, body.maxFrame or 0
    if frameEnd - frameStart > Bake.MaxBakeFrames then
        error(format("VMD frame range %d..%d exceeds the %d-frame limit; the file may be corrupted", frameStart, frameEnd, Bake.MaxBakeFrames), 0)
    end

    -- Skeleton tables.
    local N = #D.bones
    local parent, restX, restY, restZ, offX, offY, offZ = {}, {}, {}, {}, {}, {}, {}
    for b, bone in ipairs(D.bones) do
        local p = bone[2]
        parent[b] = p
        restX[b], restY[b], restZ[b] = bone[3], bone[4], bone[5]
        if p > 0 then
            offX[b], offY[b], offZ[b] = bone[3] - D.bones[p][3], bone[4] - D.bones[p][4], bone[5] - D.bones[p][5]
        else
            offX[b], offY[b], offZ[b] = bone[3], bone[4], bone[5]
        end
    end
    local appends, chains, transformOrder = D.appends, D.chains, D.transformOrder

    -- Tracks: an exact VMD name wins over a truncated-prefix match.
    local tracks, exactMatch, unmatched = {}, {}, {}
    local animated = 0
    for _, name in ipairs(body.boneOrder) do
        local keys = body.bones[name]
        if keys.count > 0 then
            local index, exact = resolve_name(D, name, D.truncatedNames15)
            if index == nil then
                unmatched[#unmatched + 1] = name
            elseif tracks[index] ~= nil and (exactMatch[index] or not exact) then
                unmatched[#unmatched + 1] = name
            else
                if tracks[index] == nil then animated = animated + 1 end
                exactMatch[index] = exact
                -- Bones the importer does not keep (index < 0) count but are not sampled.
                tracks[index] = index > 0 and build_track(body.data, keys) or false
                checkpoint()
            end
        end
    end
    local trackList = {}
    for index, track in pairs(tracks) do
        if index > 0 and track then trackList[#trackList + 1] = { index, track } end
    end
    sort(trackList, function(a, b) return a[1] < b[1] end)
    if #unmatched > 0 then
        emit(format("%d VMD bone track(s) have no matching model bone: %s", #unmatched, preview(unmatched, 8, printable)))
    end
    local appendCount, chainCount = 0, 0
    for _ in pairs(appends) do appendCount = appendCount + 1 end
    for _ in pairs(chains) do chainCount = chainCount + 1 end
    emit(format("Loaded motion: %d animated bone(s), %d IK chain(s), %d append bone(s)", animated, chainCount, appendCount))

    -- IK on/off: a step function of the VMD property keys, on before the first.
    local ikEvents = {}
    if not opts.disableIK then
        for _, prop in ipairs(sorted_by_frame(body.properties)) do
            for _, state in ipairs(prop.ik) do
                local index = resolve_name(D, state[1], D.truncatedNames20)
                if index and chains[index] then
                    local events = ikEvents[index] or {}
                    ikEvents[index] = events
                    events[#events + 1] = { prop.frame, state[2] }
                end
            end
        end
    else
        emit("Foot IK disabled for this bake (motion authored without IK).")
    end
    local ikCursor = {}

    local function ik_enabled(index, frame)
        if opts.disableIK then return false end
        local events = ikEvents[index]
        if not events then return true end
        local cursor = ikCursor[index] or 0
        while cursor < #events and events[cursor + 1][1] <= frame do cursor = cursor + 1 end
        ikCursor[index] = cursor
        if cursor < 1 then return true end
        return events[cursor][2]
    end

    -- Pose state, one frame at a time.
    local atx, aty, atz = {}, {}, {}
    local aqx, aqy, aqz, aqw = {}, {}, {}, {}
    local iqx, iqy, iqz, iqw = {}, {}, {}, {}
    local pqx, pqy, pqz, pqw = {}, {}, {}, {}
    local ptx, pty, ptz = {}, {}, {}
    local hasIK, hasApp = {}, {}
    local lqx, lqy, lqz, lqw, ltx, lty, ltz = {}, {}, {}, {}, {}, {}, {}
    local gqx, gqy, gqz, gqw, gpx, gpy, gpz = {}, {}, {}, {}, {}, {}, {}

    local function refresh_local(b)
        local x, y, z, w = aqx[b], aqy[b], aqz[b], aqw[b]
        if hasIK[b] then x, y, z, w = qmul(iqx[b], iqy[b], iqz[b], iqw[b], x, y, z, w) end
        if hasApp[b] then x, y, z, w = qmul(x, y, z, w, pqx[b], pqy[b], pqz[b], pqw[b]) end
        lqx[b], lqy[b], lqz[b], lqw[b] = x, y, z, w
        ltx[b] = offX[b] + atx[b] + ptx[b]
        lty[b] = offY[b] + aty[b] + pty[b]
        ltz[b] = offZ[b] + atz[b] + ptz[b]
    end

    local function refresh_one(b)
        local p = parent[b]
        if p == 0 then
            gqx[b], gqy[b], gqz[b], gqw[b] = lqx[b], lqy[b], lqz[b], lqw[b]
            gpx[b], gpy[b], gpz[b] = ltx[b], lty[b], ltz[b]
        else
            local px, py, pz, pw = gqx[p], gqy[p], gqz[p], gqw[p]
            gqx[b], gqy[b], gqz[b], gqw[b] = qmul(px, py, pz, pw, lqx[b], lqy[b], lqz[b], lqw[b])
            local rx, ry, rz = qrotate(px, py, pz, pw, ltx[b], lty[b], ltz[b])
            gpx[b], gpy[b], gpz[b] = gpx[p] + rx, gpy[p] + ry, gpz[p] + rz
        end
    end

    local function refresh_list(list)
        for i = 1, #list do refresh_one(list[i]) end
    end

    local function set_link_rotation(b, x, y, z, w)
        iqx[b], iqy[b], iqz[b], iqw[b] = qmul(x, y, z, w, -aqx[b], -aqy[b], -aqz[b], aqw[b])
    end

    local function apply_append(b, spec)
        local src, ratio = spec.source, spec.ratio
        if spec.rotate then
            local x, y, z, w
            if spec.localAppend then
                x, y, z, w = aqx[src], aqy[src], aqz[src], aqw[src]
                if hasIK[src] then x, y, z, w = qmul(iqx[src], iqy[src], iqz[src], iqw[src], x, y, z, w) end
            else
                -- The source's user value x IK x its own append ("multiple append").
                x, y, z, w = lqx[src], lqy[src], lqz[src], lqw[src]
            end
            pqx[b], pqy[b], pqz[b], pqw[b] = qpower(x, y, z, w, ratio)
            hasApp[b] = true
        end
        if spec.translate then
            if spec.localAppend then
                ptx[b], pty[b], ptz[b] = atx[src] * ratio, aty[src] * ratio, atz[src] * ratio
            else
                ptx[b], pty[b], ptz[b] = (atx[src] + ptx[src]) * ratio, (aty[src] + pty[src]) * ratio, (atz[src] + ptz[src]) * ratio
            end
        end
        refresh_local(b)
        refresh_list(spec.descendants)
    end

    -- Closed-form solve of a standard leg [hinge knee, free thigh]: the exact
    -- knee angle for the hip-to-target distance, then the minimal thigh aim.
    -- False for degenerate geometry, which falls back to CCD.
    local function solve_two_bone(ik, chain)
        local hinge, free = chain.links[1], chain.links[2]
        local knee, thigh, effector = hinge.bone, free.bone, chain.effector
        local axis = hinge.plane
        local i, j = axis % 3 + 1, (axis + 1) % 3 + 1
        local kx, ky, kz = ltx[knee], lty[knee], ltz[knee]
        local fx, fy, fz = ltx[effector], lty[effector], ltz[effector]
        local tx, ty, tz = gpx[ik], gpy[ik], gpz[ik]
        local hx, hy, hz = gpx[thigh], gpy[thigh], gpz[thigh]
        local dx, dy, dz = tx - hx, ty - hy, tz - hz
        local spanSq = dx * dx + dy * dy + dz * dz
        local ki, kj, ka = component(kx, ky, kz, i), component(kx, ky, kz, j), component(kx, ky, kz, axis)
        local fi, fj, fa = component(fx, fy, fz, i), component(fx, fy, fz, j), component(fx, fy, fz, axis)
        -- |knee + R(theta) foot|^2 = base + 2 (A cos theta + B sin theta)
        local aTerm = ki * fi + kj * fj
        local bTerm = kj * fi - ki * fj
        local base = (kx * kx + ky * ky + kz * kz) + (fx * fx + fy * fy + fz * fz) + 2 * ka * fa
        local radius = sqrt(aTerm * aTerm + bTerm * bTerm)
        if not (radius > 1e-9) then return false end
        local phase = atan2(bTerm, aTerm)
        local spread = acos(clip((spanSq - base) / (2 * radius), -1, 1))
        local lowerLimit, upperLimit = hinge.lower[axis], hinge.upper[axis]
        local middle = 0.5 * (lowerLimit + upperLimit)
        local function fit(theta)
            theta = theta + 2 * pi * rint((middle - theta) / (2 * pi))
            return clip(theta, lowerLimit, upperLimit)
        end
        local reach = sqrt(spanSq)
        local function reach_error(theta)
            local reachSq = base + 2 * (aTerm * cos(theta) + bTerm * sin(theta))
            if reachSq < 0 then reachSq = 0 end
            return abs(sqrt(reachSq) - reach)
        end
        local first, second = fit(phase + spread), fit(phase - spread)
        local errFirst, errSecond = reach_error(first), reach_error(second)
        local pickFirst
        if abs(errFirst - errSecond) <= 1e-9 then
            pickFirst = abs(first - middle) <= abs(second - middle)
        else
            pickFirst = errFirst < errSecond
        end
        local theta = pickFirst and first or second
        local ax, ay, az = unit_axis(axis)
        local rx, ry, rz, rw = axis_angle(ax, ay, az, theta)
        set_link_rotation(knee, rx, ry, rz, rw)

        -- Aim the thigh: minimal rotation taking the re-bent foot direction
        -- onto the target direction, in the thigh's own frame.
        local qx, qy, qz, qw = gqx[thigh], gqy[thigh], gqz[thigh], gqw[thigh]
        local bx, by, bz = qrotate(rx, ry, rz, rw, fx, fy, fz)
        local flx, fly, flz = vnormalize(kx + bx, ky + by, kz + bz)
        local tlx, tly, tlz, targetLen = vnormalize(qrotate(-qx, -qy, -qz, qw, dx, dy, dz))
        local dot = clip(flx * tlx + fly * tly + flz * tlz, -1, 1)
        local cx, cy, cz, crossLen = vnormalize(cross(flx, fly, flz, tlx, tly, tlz))
        local mx, my, mz, mw = 0, 0, 0, 1
        if crossLen > 1e-12 and targetLen > 1e-9 then
            mx, my, mz, mw = axis_angle(cx, cy, cz, acos(dot))
        elseif crossLen <= 1e-12 and dot < 0 and targetLen > 1e-9 then
            -- Exactly opposite: a half turn about an axis perpendicular to the foot.
            local hx2, hy2, hz2 = 0, 1, 0
            if abs(flx) < 0.9 then hx2, hy2 = 1, 0 end
            local px, py, pz = vnormalize(cross(flx, fly, flz, hx2, hy2, hz2))
            mx, my, mz, mw = axis_angle(px, py, pz, pi)
        end
        set_link_rotation(thigh, qmul(aqx[thigh], aqy[thigh], aqz[thigh], aqw[thigh], mx, my, mz, mw))
        refresh_local(knee)
        refresh_local(thigh)
        refresh_list(chain.affected)
        return true
    end

    -- One CCD step on one link (MMD-style, with hinge handling).
    local function solve_link(chain, position, link, iteration, ikx, iky, ikz, planeAngle, prevAngles)
        local b = link.bone
        local cx, cy, cz, cw = -gqx[b], -gqy[b], -gqz[b], gqw[b]
        local ox, oy, oz = gpx[b], gpy[b], gpz[b]
        local effector = chain.effector
        local ex, ey, ez, effectorLen = vnormalize(qrotate(cx, cy, cz, cw, gpx[effector] - ox, gpy[effector] - oy, gpz[effector] - oz))
        local tx, ty, tz, targetLen = vnormalize(qrotate(cx, cy, cz, cw, ikx - ox, iky - oy, ikz - oz))
        local valid = effectorLen > 1e-9 and targetLen > 1e-9
        local dot = clip(ex * tx + ey * ty + ez * tz, -1, 1)
        local angle = acos(dot)
        if angle > chain.unitAngle then angle = chain.unitAngle end

        local x, y, z, w
        if link.plane > 0 then
            local axis = link.plane
            local ax, ay, az = unit_axis(axis)
            local px, py, pz, pw = axis_angle(ax, ay, az, angle)
            px, py, pz = qrotate(px, py, pz, pw, ex, ey, ez)
            local nx, ny, nz, nw = axis_angle(ax, ay, az, -angle)
            nx, ny, nz = qrotate(nx, ny, nz, nw, ex, ey, ez)
            local dotPos = px * tx + py * ty + pz * tz
            local dotNeg = nx * tx + ny * ty + nz * tz
            local newAngle = planeAngle[position] + (dotPos > dotNeg and angle or -angle)
            local lowerLimit, upperLimit = link.lower[axis], link.upper[axis]
            if iteration == 0 then
                local outside = newAngle < lowerLimit or newAngle > upperLimit
                local mirrorOK = -newAngle > lowerLimit and -newAngle < upperLimit
                local half = 0.5 * (lowerLimit + upperLimit)
                if outside and (mirrorOK or abs(half - newAngle) > abs(half + newAngle)) then
                    newAngle = -newAngle
                end
            end
            newAngle = clip(newAngle, lowerLimit, upperLimit)
            if not valid then return end
            planeAngle[position] = newAngle
            x, y, z, w = axis_angle(ax, ay, az, newAngle)
        else
            if not (valid and angle * RAD2DEG >= 1e-3) then return end
            local sx, sy, sz, crossLen = vnormalize(cross(ex, ey, ez, tx, ty, tz))
            if not (crossLen > 1e-12) then return end
            x, y, z, w = aqx[b], aqy[b], aqz[b], aqw[b]
            if hasIK[b] then x, y, z, w = qmul(iqx[b], iqy[b], iqz[b], iqw[b], x, y, z, w) end
            x, y, z, w = qmul(x, y, z, w, axis_angle(sx, sy, sz, angle))
            if link.lower then
                local before = prevAngles[position]
                local a1, a2, a3 = decompose_xyz(x, y, z, w, before[1], before[2], before[3])
                local lo, hi, unit = link.lower, link.upper, chain.unitAngle
                a1 = clip(clip(a1, lo[1], hi[1]) - before[1], -unit, unit) + before[1]
                a2 = clip(clip(a2, lo[2], hi[2]) - before[2], -unit, unit) + before[2]
                a3 = clip(clip(a3, lo[3], hi[3]) - before[3], -unit, unit) + before[3]
                before[1], before[2], before[3] = a1, a2, a3
                x, y, z, w = quat_from_xyz(a1, a2, a3)
            end
        end
        set_link_rotation(b, x, y, z, w)
        refresh_local(b)
        refresh_list(link.path)
    end

    local ccdScratch = {}
    local function solve_ik(ik, chain)
        local links = chain.links
        for k = 1, #links do
            local b = links[k].bone
            hasIK[b] = true
            iqx[b], iqy[b], iqz[b], iqw[b] = 0, 0, 0, 1
            refresh_local(b)
        end
        refresh_list(chain.affected)
        if chain.twoBone and solve_two_bone(ik, chain) then return end

        -- Per-chain scratch, reused every frame.
        local scratch = ccdScratch[ik]
        if not scratch then
            scratch = { planeAngle = {}, prevAngles = {}, saved = {} }
            for k = 1, #links do
                scratch.prevAngles[k] = { 0, 0, 0 }
                scratch.saved[k] = { 0, 0, 0, 1 }
            end
            ccdScratch[ik] = scratch
        end
        local planeAngle, prevAngles, saved = scratch.planeAngle, scratch.prevAngles, scratch.saved
        for k = 1, #links do
            local b, before, s = links[k].bone, prevAngles[k], saved[k]
            planeAngle[k] = 0
            before[1], before[2], before[3] = 0, 0, 0
            s[1], s[2], s[3], s[4] = iqx[b], iqy[b], iqz[b], iqw[b]
        end
        local best = huge
        local ikx, iky, ikz = gpx[ik], gpy[ik], gpz[ik]
        local effector = chain.effector
        for iteration = 0, chain.loops - 1 do
            for position = 1, #links do
                solve_link(chain, position, links[position], iteration, ikx, iky, ikz, planeAngle, prevAngles)
            end
            local dx, dy, dz = gpx[effector] - ikx, gpy[effector] - iky, gpz[effector] - ikz
            local distance = sqrt(dx * dx + dy * dy + dz * dz)
            if distance < best then
                best = distance
                for k = 1, #links do
                    local b, s = links[k].bone, saved[k]
                    s[1], s[2], s[3], s[4] = iqx[b], iqy[b], iqz[b], iqw[b]
                end
            else
                -- No longer improving: restore the best pose and stop.
                for k = 1, #links do
                    local b, s = links[k].bone, saved[k]
                    iqx[b], iqy[b], iqz[b], iqw[b] = s[1], s[2], s[3], s[4]
                    refresh_local(b)
                end
                refresh_list(chain.affected)
                break
            end
        end
        refresh_list(chain.affected)
    end

    -- MMD bone update for one frame: local transforms, global transforms,
    -- append and IK in transform order, then a final global pass (no physics).
    local function evaluate(frame)
        for b = 1, N do
            atx[b], aty[b], atz[b] = 0, 0, 0
            aqx[b], aqy[b], aqz[b], aqw[b] = 0, 0, 0, 1
            iqx[b], iqy[b], iqz[b], iqw[b] = 0, 0, 0, 1
            pqx[b], pqy[b], pqz[b], pqw[b] = 0, 0, 0, 1
            ptx[b], pty[b], ptz[b] = 0, 0, 0
            hasIK[b], hasApp[b] = false, false
            lqx[b], lqy[b], lqz[b], lqw[b] = 0, 0, 0, 1
            ltx[b], lty[b], ltz[b] = offX[b], offY[b], offZ[b]
        end
        for k = 1, #trackList do
            local b, track = trackList[k][1], trackList[k][2]
            local x, y, z, qx, qy, qz, qw = sample_track(track, frame)
            atx[b], aty[b], atz[b] = x, y, z
            aqx[b], aqy[b], aqz[b], aqw[b] = qx, qy, qz, qw
            lqx[b], lqy[b], lqz[b], lqw[b] = qx, qy, qz, qw
            ltx[b], lty[b], ltz[b] = offX[b] + x, offY[b] + y, offZ[b] + z
        end
        for b = 1, N do refresh_one(b) end
        for k = 1, #transformOrder do
            local b = transformOrder[k]
            local spec = appends[b]
            if spec then apply_append(b, spec) end
            local chain = chains[b]
            if chain and ik_enabled(b, frame) then solve_ik(b, chain) end
        end
        for b = 1, N do refresh_one(b) end
    end

    -- Exported tracks.
    local plans = {}
    local pelvis
    for k, row in ipairs(D.plans) do
        local plan = { order = k, bone = row[1], name = row[2], target = row[3], role = row[4], mode = row[5], reference = row[6], score = 0, moving = false }
        if plan.mode == "pelvis" then
            plan.samples = { {}, {}, {}, {}, {}, {} }
            pelvis = pelvis or plan
        else
            plan.keys = compactor()
        end
        plans[k] = plan
    end

    local function plan_values(plan)
        local b, mode, ref = plan.bone, plan.mode, plan.reference
        local x, y, z, w = gqx[b], gqy[b], gqz[b], gqw[b]
        local p1, p2, p3 = 0, 0, 0
        if mode == "pelvis" then
            p1, p2, p3 = source_position(gpx[b] - restX[b], gpy[b] - restY[b], gpz[b] - restZ[b], true)
        elseif ref > 0 then
            x, y, z, w = qmul(x, y, z, w, -gqx[ref], -gqy[ref], -gqz[ref], gqw[ref])
            if mode == "override" then
                -- Move the Source child back onto the baked MMD child origin.
                local rx, ry, rz = qrotate(gqx[ref], gqy[ref], gqz[ref], gqw[ref], restX[b] - restX[ref], restY[b] - restY[ref], restZ[b] - restZ[ref])
                p1, p2, p3 = source_position(gpx[b] - (gpx[ref] + rx), gpy[b] - (gpy[ref] + ry), gpz[b] - (gpz[ref] + rz), false)
            end
        end
        -- MMD -> Blender armature space: (x, y, z) -> (x, z, y), a mirror.
        local r1, r2, r3 = extrinsic_degrees(-x, -z, -y, w)
        return r1, r2, r3, p1, p2, p3
    end

    local contacts = opts.unifyGround and D.contacts or {}
    if opts.unifyGround and #contacts == 0 then
        emit("Warning: ground unification skipped: the model has none of the standard foot/leg bones.")
    end
    local lowest = {}
    local placementX, placementY, placementZ = {}, {}, {}
    local placement = D.placement

    local total = frameEnd - frameStart + 1
    emit(format("Baking pose frames %d..%d (%d frames).", frameStart, frameEnd, total))
    local chunkStart = 1
    for k = 1, total do
        local frame = frameStart + k - 1
        evaluate(frame)
        for _, plan in ipairs(plans) do
            local v1, v2, v3, v4, v5, v6 = plan_values(plan)
            plan.score = plan.score + abs(v1) + abs(v2) + abs(v3)
            if plan.samples then
                local s = plan.samples
                s[1][k], s[2][k], s[3][k], s[4][k], s[5][k], s[6][k] = v1, v2, v3, v4, v5, v6
            else
                if not plan.moving and not is_zero_transform(v1, v2, v3, v4, v5, v6) then plan.moving = true end
                compact_push(plan.keys, frame, v1, v2, v3, v4, v5, v6)
            end
        end
        if #contacts > 0 then
            local low = huge
            for c = 1, #contacts do
                local y = gpy[contacts[c]]
                if y < low then low = y end
            end
            lowest[k] = low
            placementX[k], placementY[k], placementZ[k] = gpx[placement] * POSITION_SCALE, gpy[placement] * POSITION_SCALE, gpz[placement] * POSITION_SCALE
        end
        if k - chunkStart + 1 >= CHUNK_FRAMES or k == total then
            emit(format("Baked frames %d..%d of %d", frameStart + chunkStart - 1, frame, frameEnd))
            chunkStart = k + 1
        end
        progress(k / total)
        checkpoint()
    end

    local ground
    if #contacts > 0 then
        local cuts = detect_pose_cuts(placementX, placementY, placementZ)
        ground = ground_offsets(lowest, D.restHeight, cuts)
        if pelvis then
            -- Only the pelvis track carries a world position: lowering its
            -- height column moves the whole body.
            local heights = pelvis.samples[6]
            for k = 1, #heights do
                local h = heights[k] - ground[k] * POSITION_SCALE
                if abs(h) < EPSILON then h = 0 else h = round6(h) end
                if abs(h) < EPSILON then h = 0 end
                heights[k] = h
            end
        end
        local lifted = 0
        for k = 1, #ground do
            if abs(ground[k]) > lifted then lifted = abs(ground[k]) end
        end
        emit(format("Unified ground height: shifted the character by up to %.2f MMD units (%.2f m) to keep it on one floor level.", lifted, lifted * 0.08))
    end

    -- Scene cuts of the exported pelvis track, after ground unification.
    local cutFrames = {}
    if pelvis then
        local s = pelvis.samples
        for _, index in ipairs(detect_pose_cuts(s[4], s[5], s[6])) do
            cutFrames[#cutFrames + 1] = frameStart + index - 1
        end
        if #cutFrames > 0 then
            emit(format("Scene cuts (the character jumps to another spot in one frame): %d at frame(s) %s", #cutFrames, preview(cutFrames, 12)))
        end
    end

    emit("Exporting parent-corrected bone rotations.")
    local groups, targets = {}, {}
    local identityTracks = 0
    for _, plan in ipairs(plans) do
        if plan.samples then
            local s = plan.samples
            plan.keys = compactor()
            for k = 1, total do
                local v1, v2, v3, v4, v5, v6 = s[1][k], s[2][k], s[3][k], s[4][k], s[5][k], s[6][k]
                if not plan.moving and not is_zero_transform(v1, v2, v3, v4, v5, v6) then plan.moving = true end
                compact_push(plan.keys, frameStart + k - 1, v1, v2, v3, v4, v5, v6)
                if k % 1024 == 0 then checkpoint() end
            end
            plan.samples = nil
        end
        compact_finish(plan.keys)
        if not plan.moving then identityTracks = identityTracks + 1 end
        if plan.keys.count > 0 then
            if not groups[plan.target] then
                groups[plan.target] = {}
                targets[#targets + 1] = plan.target
            end
            local list = groups[plan.target]
            list[#list + 1] = plan
        end
        checkpoint()
    end

    -- One track per GMod bone: the one that moves most, then the longest.
    sort(targets)
    local bonesOut = {}
    local duplicateTargets = 0
    for _, target in ipairs(targets) do
        local candidates = groups[target]
        duplicateTargets = duplicateTargets + #candidates - 1
        sort(candidates, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            if a.keys.count ~= b.keys.count then return a.keys.count > b.keys.count end
            return a.name > b.name
        end)
        local plan = candidates[1]
        local entry = Bake.Object()
        Bake.Put(entry, "m", plan.name)
        Bake.Put(entry, "g", plan.target)
        Bake.Put(entry, "k", Bake.Raw("[" .. concat(plan.keys.rows, ",") .. "]"))
        if plan.role ~= "" then Bake.Put(entry, "role", plan.role) end
        bonesOut[#bonesOut + 1] = entry
        checkpoint()
    end

    local overrides = Bake.Object()
    for _, pair in ipairs(D.hierarchyOverrides) do Bake.Put(overrides, pair[1], pair[2]) end

    local cameraOffsets
    if ground then
        cameraOffsets = {}
        for k = 1, #ground do cameraOffsets[k] = py_round(ground[k], 5) end
    end

    local doc = Bake.Object()
    Bake.Put(doc, "format", Bake.OutputFormat)
    Bake.Put(doc, "armature", D.armature)
    Bake.Put(doc, "input_vmd", tostring(opts.inputName or "motion.vmd"))
    Bake.Put(doc, "mmd_model", D.modelFile)
    Bake.Put(doc, "space", "ARMATURE_OBJECT")
    Bake.Put(doc, "axis", { "+X model left", "+Y model front", "+Z model top" })
    Bake.Put(doc, "order", "fixed_xyz_extrinsic")
    Bake.Put(doc, "matrix_order", "Rz @ Ry @ Rx")
    Bake.Put(doc, "units", "degrees")
    Bake.Put(doc, "position_units", "source_units")
    Bake.Put(doc, "columns", { "frame", "x_deg", "y_deg", "z_deg", "pos_x", "pos_y", "pos_z" })
    Bake.Put(doc, "pelvis_track", "global_lower_body_includes_mmd_root_center_groove_waist")
    Bake.Put(doc, "hierarchy_overrides", overrides)
    Bake.Put(doc, "frame_start", frameStart)
    Bake.Put(doc, "frame_end", frameEnd)
    Bake.Put(doc, "frame_count", frameEnd - frameStart + 1)
    Bake.Put(doc, "fps", Bake.VMDFPS)
    Bake.Put(doc, "cuts", cutFrames)
    Bake.Put(doc, "source_bone_map_count", D.boneMapCount)
    Bake.Put(doc, "mapped_track_count", #plans)
    Bake.Put(doc, "identity_track_count", identityTracks)
    Bake.Put(doc, "duplicate_target_count", duplicateTargets)
    Bake.Put(doc, "bone_count", #bonesOut)
    Bake.Put(doc, "bones", bonesOut)
    Bake.Put(doc, "baker", "native")
    if ground then
        local lowestOffset, highestOffset = huge, -huge
        for k = 1, #ground do
            if ground[k] < lowestOffset then lowestOffset = ground[k] end
            if ground[k] > highestOffset then highestOffset = ground[k] end
        end
        if #ground == 0 then lowestOffset, highestOffset = 0, 0 end
        Bake.Put(doc, "ground_unified", true)
        Bake.Put(doc, "ground_offset_range_mmd", { py_round(lowestOffset, 4), py_round(highestOffset, 4) })
    end
    emit(format("Exported parent-corrected bone rotations: %d bone track(s).", #bonesOut))
    return doc, cameraOffsets
end

-- ---------------------------------------------------------------------------
-- Flex tracks (import_vmd.merge_motion_json_flex_tracks).
-- ---------------------------------------------------------------------------

-- Linear playback: a key may only be dropped when it is inside a constant run.
-- frames, weights: parallel arrays of `count` keys in file order.
local function compact_morph_keyframes(frames, weights, count)
    local order = {}
    local inOrder = true
    for i = 1, count do
        order[i] = i
        if i > 1 and frames[i] < frames[i - 1] then inOrder = false end
    end
    if not inOrder then
        sort(order, function(a, b)
            if frames[a] ~= frames[b] then return frames[a] < frames[b] end
            return a < b
        end)
    end
    local keys = {}
    for index = 1, count do
        local weight = clamp01(weights[order[index]])
        local keep = true
        if index > 1 and index < count then
            local previous = keys[#keys][2]
            local nextWeight = clamp01(weights[order[index + 1]])
            if abs(weight - previous) <= 0.000001 and abs(nextWeight - weight) <= 0.000001 then keep = false end
        end
        if keep then keys[#keys + 1] = { frames[order[index]], py_round(weight, 6) } end
    end
    return keys
end

local function compact_key_list(list)
    local frames, weights = {}, {}
    for i, key in ipairs(list) do frames[i], weights[i] = key[1], key[2] end
    return compact_morph_keyframes(frames, weights, #list)
end

local function track_is_meaningful(keys)
    for _, key in ipairs(keys) do
        if abs(key[2]) > 0.000001 then return true end
    end
    return false
end

-- import_vmd.find_segment + sample_morph on sorted { frame, weight } keys.
local function sample_morph(keys, frame)
    local n = #keys
    if n == 0 then return 0 end
    if frame <= keys[1][1] then return keys[1][2] end
    if frame >= keys[n][1] then return keys[n][2] end
    local lo, hi = 1, n
    while lo + 1 < hi do
        local mid = floor((lo + hi) / 2)
        if keys[mid][1] <= frame then lo = mid else hi = mid end
    end
    local a, b = keys[lo], keys[hi]
    local span = b[1] - a[1]
    if span < 1 then span = 1 end
    return a[2] + (b[2] - a[2]) * ((frame - a[1]) / span)
end

local function combine_additive(sets)
    local active = {}
    for _, keys in ipairs(sets) do
        if #keys > 0 then active[#active + 1] = keys end
    end
    if #active == 0 then return {} end
    local seen, frames = {}, {}
    for _, keys in ipairs(active) do
        for _, key in ipairs(keys) do
            if not seen[key[1]] then
                seen[key[1]] = true
                frames[#frames + 1] = key[1]
            end
        end
    end
    sort(frames)
    local weights = {}
    for i, frame in ipairs(frames) do
        local total = 0
        for _, keys in ipairs(active) do total = total + sample_morph(keys, frame) end
        weights[i] = clamp01(total)
    end
    local combined = {}
    local count = #frames
    for i = 1, count do
        local keep = true
        if i > 1 and i < count then
            if abs(weights[i] - combined[#combined][2]) <= 0.000001 and abs(weights[i + 1] - weights[i]) <= 0.000001 then keep = false end
        end
        if keep then combined[#combined + 1] = { frames[i], weights[i] } end
    end
    return combined
end

local function merge_additive(existing, incoming)
    local name
    if incoming.m ~= "" and incoming.m ~= existing.m then
        name = existing.m ~= "" and (existing.m .. "+" .. incoming.m) or incoming.m
    else
        name = existing.m ~= "" and existing.m or incoming.m
    end
    return { m = name, g = existing.g ~= "" and existing.g or incoming.g, k = compact_key_list(combine_additive({ existing.k, incoming.k })) }
end

-- Mapped flex tracks of one parsed VMD, sorted by morph name.
local function flex_tracks_of(parsed, D, checkpoint)
    local entries = {}
    for _, raw in ipairs(parsed.morphOrder) do
        local mapped = D.flexMap[raw]
        if mapped then entries[#entries + 1] = { mapped[1], mapped[2], parsed.morphs[raw] } end
    end
    sort(entries, function(a, b) return a[1] < b[1] end)
    local tracks = {}
    for _, entry in ipairs(entries) do
        local morph = entry[3]
        local keys = compact_morph_keyframes(morph.frames, morph.weights, morph.count)
        if #keys > 0 then tracks[#tracks + 1] = { m = entry[1], g = entry[2], k = keys } end
        checkpoint()
    end
    return tracks
end

-- sources: { { parsed = ParseVMD result, label = "main VMD", path = text }, ... }
-- in merge order (the body VMD first); a source with `missing` set could not
-- be read and is skipped with a warning. Returns the JSON flex list and warnings.
function Bake.MergeFlexTracks(sources, emit, checkpoint)
    local D = MMDVMDNPC.ImportData
    emit = emit or noop
    checkpoint = checkpoint or noop
    local flexes, warnings, seen = {}, {}, {}
    for _, source in ipairs(sources) do
        local tracks = {}
        if source.missing then
            warnings[#warnings + 1] = format("Skipped missing %s flex VMD: %s", source.label, source.path)
        else
            tracks = flex_tracks_of(source.parsed, D, checkpoint)
            emit(format("Parsed %d mapped flex track(s) from %s: %s", #tracks, source.label, source.path))
        end
        for _, track in ipairs(tracks) do
            checkpoint()
            local target = track.g
            local existing = seen[target]
            if existing then
                local meaningful = track_is_meaningful(track.k)
                if meaningful and not existing.meaningful then
                    flexes[existing.index] = track
                    warnings[#warnings + 1] = format("Replaced zero placeholder flex %s from %s with %s: %s", target, existing.origin, source.label, source.path)
                    existing.meaningful, existing.origin = true, source.label
                elseif meaningful and existing.meaningful then
                    flexes[existing.index] = merge_additive(flexes[existing.index], track)
                    warnings[#warnings + 1] = format("Added duplicate flex %s from %s additively: %s", target, source.label, source.path)
                else
                    warnings[#warnings + 1] = format("Skipped duplicate flex %s from %s: %s", target, source.main and "main VMD" or source.label, source.path)
                end
            else
                seen[target] = { index = #flexes + 1, meaningful = track_is_meaningful(track.k), origin = source.label }
                flexes[#flexes + 1] = track
            end
        end
    end
    local out = {}
    for i, track in ipairs(flexes) do
        local rows = {}
        for k, key in ipairs(track.k) do rows[k] = format("[%d,%s]", key[1], num(key[2])) end
        local entry = Bake.Object()
        Bake.Put(entry, "m", track.m)
        Bake.Put(entry, "g", track.g)
        Bake.Put(entry, "k", Bake.Raw("[" .. concat(rows, ",") .. "]"))
        out[i] = entry
    end
    return out, warnings
end

-- ---------------------------------------------------------------------------
-- Camera track (import_vmd.build_camera_track).
-- ---------------------------------------------------------------------------
local function normalize_angle(value)
    return py_mod(value + 180, 360) - 180
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function lerp_angle(a, b, t)
    return a + normalize_angle(b - a) * t
end

-- Source VectorAngles(forward, pseudo-up) -> pitch, yaw, roll in degrees.
local function source_angles(fx, fy, fz, ux, uy, uz)
    local lx = uy * fz - uz * fy
    local ly = uz * fx - ux * fz
    local lz = ux * fy - uy * fx
    local length = sqrt(lx * lx + ly * ly + lz * lz)
    if length > 1e-9 then lx, ly, lz = lx / length, ly / length, lz / length end
    local xyDist = sqrt(fx * fx + fy * fy)
    local pitch, yaw, roll
    if xyDist > 0.001 then
        yaw = atan2(fy, fx)
        pitch = atan2(-fz, xyDist)
        roll = atan2(lz, ly * fx - lx * fy)
    else
        yaw = atan2(-lx, ly)
        pitch = atan2(-fz, xyDist)
        roll = 0
    end
    return pitch * RAD2DEG, yaw * RAD2DEG, roll * RAD2DEG
end

-- Entity-local GMod camera sample { px, py, pz, pitch, yaw, roll, vfov }.
local function camera_sample(frames, cursor, frame, verticalOffset)
    local n = #frames
    local tx, ty, tz, rx, ry, rz, distance, fov
    if frame <= frames[1].frame or frame >= frames[n].frame then
        local key = frame <= frames[1].frame and frames[1] or frames[n]
        tx, ty, tz, rx, ry, rz, distance, fov = key.x, key.y, key.z, key.rx, key.ry, key.rz, key.distance, key.fov
    else
        local lo = cursor.index
        while lo < n and frames[lo + 1].frame <= frame do lo = lo + 1 end
        cursor.index = lo
        local a, b = frames[lo], frames[lo + 1]
        local span = b.frame - a.frame
        if span < 1e-9 then span = 1e-9 end
        local t = (frame - a.frame) / span
        local interp = b.interp
        local wr = camera_weight(t, interp, 3)
        tx = lerp(a.x, b.x, camera_weight(t, interp, 0))
        ty = lerp(a.y, b.y, camera_weight(t, interp, 1))
        tz = lerp(a.z, b.z, camera_weight(t, interp, 2))
        -- Cumulative euler values (can exceed +-pi), interpolated per component.
        rx, ry, rz = lerp(a.rx, b.rx, wr), lerp(a.ry, b.ry, wr), lerp(a.rz, b.rz, wr)
        distance = lerp(a.distance, b.distance, camera_weight(t, interp, 4))
        fov = lerp(a.fov, b.fov, camera_weight(t, interp, 5))
    end
    -- R = RotY(-ry) RotX(-rx) RotZ(-rz); eye = target + R (0, 0, distance).
    local cx, sx = cos(-rx), sin(-rx)
    local cy, sy = cos(-ry), sin(-ry)
    local cz, sz = cos(-rz), sin(-rz)
    local m01 = -cy * sz + sy * sx * cz
    local m02 = sy * cx
    local m11 = cx * cz
    local m12 = -sx
    local m21 = sy * sz + cy * sx * cz
    local m22 = cy * cx
    local ex, ey, ez = tx + m02 * distance, ty + m12 * distance, tz + m22 * distance
    if verticalOffset ~= 0 then ey = ey - verticalOffset end
    -- MMD (x, y, z) -> GMod entity-local (-z, x, y).
    local pitch, yaw, roll = source_angles(-m22, m02, m12, -m21, m01, m11)
    return { -ez * CAMERA_POSITION_SCALE, ex * CAMERA_POSITION_SCALE, ey * CAMERA_POSITION_SCALE, pitch, yaw, roll, fov }
end

local function samples_close(a, b)
    for i = 1, 3 do
        if abs(a[i] - b[i]) > CAMERA_POS_EPS then return false end
    end
    for i = 4, 6 do
        if abs(normalize_angle(a[i] - b[i])) > CAMERA_ANG_EPS then return false end
    end
    return abs(a[7] - b[7]) <= CAMERA_FOV_EPS
end

-- parsed: ParseVMD result of the camera VMD; groundOffsets: per body frame
-- from 0 (MMD units), the heights a ground-unified bake removed. Returns the
-- camera track object, or nil when the file holds no camera frames.
function Bake.CameraTrack(parsed, sourceName, groundOffsets, opts)
    opts = opts or {}
    local emit = opts.emit or noop
    local checkpoint = opts.checkpoint or noop
    local frames = sorted_by_frame(parsed.camera)
    if #frames == 0 then
        emit("No camera frames found in " .. sourceName)
        return nil
    end
    local frameStart, frameEnd = 0, frames[#frames].frame
    if frameEnd - frameStart > Bake.MaxBakeFrames then
        error(format("camera VMD frame range 0..%d exceeds the %d-frame limit; the file may be corrupted: %s", frameEnd, Bake.MaxBakeFrames, sourceName), 0)
    end
    local offsets = groundOffsets or {}
    local samples = {}
    local cursor = { index = 1 }
    for f = frameStart, frameEnd do
        local offset = 0
        if #offsets > 0 then offset = offsets[clip(f, 0, #offsets - 1) + 1] end
        local s = camera_sample(frames, cursor, f, offset)
        s[4], s[5], s[6] = normalize_angle(s[4]), normalize_angle(s[5]), normalize_angle(s[6])
        samples[#samples + 1] = s
        if f % 512 == 0 then checkpoint() end
    end
    if #offsets > 0 then emit("Camera lowered with the unified ground height to keep framing the character") end

    -- Greedy decimation: keep a sample only when linear interpolation from
    -- the previous kept one fails to reproduce an intermediate frame.
    local total = #samples
    local kept = { 1 }
    local last, index = 1, 2
    local approx = {}
    while index < total do
        local candidate = index + 1
        local span = candidate - last
        local ok = true
        local a, b = samples[last], samples[candidate]
        for mid = last + 1, candidate - 1 do
            local t = (mid - last) / span
            approx[1], approx[2], approx[3] = lerp(a[1], b[1], t), lerp(a[2], b[2], t), lerp(a[3], b[3], t)
            approx[4], approx[5], approx[6] = lerp_angle(a[4], b[4], t), lerp_angle(a[5], b[5], t), lerp_angle(a[6], b[6], t)
            approx[7] = lerp(a[7], b[7], t)
            if not samples_close(approx, samples[mid]) then
                ok = false
                break
            end
        end
        if not ok then
            kept[#kept + 1] = index
            last = index
        end
        index = index + 1
        checkpoint()
    end
    if total > 1 then kept[#kept + 1] = total end

    -- The addon loads at most 20000 camera keys; thin uniformly instead.
    if #kept > CAMERA_MAX_KEYS then
        local stride = (#kept - 1) / (CAMERA_MAX_KEYS - 1)
        local thinned = {}
        for i = 0, CAMERA_MAX_KEYS - 1 do thinned[i + 1] = kept[rint(i * stride) + 1] end
        thinned[CAMERA_MAX_KEYS] = kept[#kept]
        kept = thinned
        emit(format("Camera track thinned to %d keys to fit the addon limit", CAMERA_MAX_KEYS))
    end

    local rows = {}
    for i, sampleIndex in ipairs(kept) do
        local s = samples[sampleIndex]
        rows[i] = format("[%d,%s,%s,%s,%s,%s,%s,%s]", frameStart + sampleIndex - 1,
            fixed3(s[1]), fixed3(s[2]), fixed3(s[3]), fixed3(s[4]), fixed3(s[5]), fixed3(s[6]), fixed3(s[7]))
    end
    emit(format("Camera track: %d VMD key(s) over frames %d-%d, exported %d sampled key(s)", #frames, frameStart, frameEnd, #rows))
    local track = Bake.Object()
    Bake.Put(track, "format", CAMERA_TRACK_FORMAT)
    Bake.Put(track, "fps", Bake.VMDFPS)
    Bake.Put(track, "frame_start", frameStart)
    Bake.Put(track, "frame_end", frameEnd)
    Bake.Put(track, "position_scale", py_round(CAMERA_POSITION_SCALE, 6))
    Bake.Put(track, "key_count", #rows)
    Bake.Put(track, "source", sourceName)
    Bake.Put(track, "keys", Bake.Raw("[" .. concat(rows, ",") .. "]"))
    if #offsets > 0 then Bake.Put(track, "ground_unified", true) end
    return track
end

-- ---------------------------------------------------------------------------
-- Names and the motion file (import_vmd.write_motion_json).
-- ---------------------------------------------------------------------------
local MEDIA_SUFFIXES = {
    [".vmd"] = true, [".json"] = true, [".mp3"] = true, [".wav"] = true, [".ogg"] = true,
    [".flac"] = true, [".m4a"] = true, [".aac"] = true, [".wma"] = true, [".mp4"] = true,
    [".mkv"] = true, [".mov"] = true, [".avi"] = true, [".webm"] = true,
}

local function trim(text)
    return (gsub(tostring(text or ""), "^%s*(.-)%s*$", "%1"))
end
Bake.Trim = trim

-- A typed name stays as it is; a path or file name gives its stem (isPath:
-- the value is a file name, as when no display name was typed).
function Bake.MotionSourceStem(value, isPath)
    value = trim(value)
    if value == "" then return "motion" end
    local base = value:match("([^/\\]*)$") or value
    local dot = base:match("^.*()%.")
    local suffix = ""
    if dot and dot > 1 and dot < #base then suffix = lower(sub(base, dot)) end
    if isPath or find(value, "[/\\]") or MEDIA_SUFFIXES[suffix] then
        local stem = suffix ~= "" and sub(base, 1, dot - 1) or base
        stem = trim(stem)
        return stem ~= "" and stem or value
    end
    return value
end

function Bake.Slugify(value, isPath)
    local rawStem = Bake.MotionSourceStem(value, isPath)
    local slug = gsub(lower(rawStem), "[^a-z0-9_%.%-]+", "_")
    slug = slug:match("^[%._%-]*(.-)[%._%-]*$")
    if slug ~= "" then return slug end
    return "motion_" .. sub(Bake.SHA1(rawStem), 1, 10)
end

-- The motion id: the name's slug and the body VMD's content hash, so two
-- motions imported from same-named files never overwrite each other.
function Bake.MotionID(nameSource, isPath, vmdHash)
    local slug = Bake.Slugify(nameSource, isPath)
    if not vmdHash or vmdHash == "" then return slug end
    return slug .. "_" .. sub(vmdHash, 1, 10)
end

Bake.MetaFields = { "category", "display_name", "english_name", "artist", "language", "link", "motion_artist" }

-- doc: BakeMotion's document. info: flexes, flexWarnings, music (object),
-- camera (object), audioOffset, motionID, nameSource, nameIsPath, meta.
-- Returns the motion JSON text and its display name.
function Bake.MotionJSON(doc, info)
    Bake.Put(doc, "flexes", info.flexes or {})
    Bake.Put(doc, "flex_count", #(info.flexes or {}))
    if info.flexWarnings and #info.flexWarnings > 0 then Bake.Put(doc, "flex_warnings", info.flexWarnings) end
    local offset = py_round(clip(tonumber(info.audioOffset) or 0, -5, 5), 3)
    if info.music then
        Bake.Put(info.music, "offset", offset)
        Bake.Put(info.music, "default_offset", offset)
        Bake.Put(doc, "music", info.music)
    end
    if info.camera then Bake.Put(doc, "camera", info.camera) end
    Bake.Put(doc, "audio_offset", offset)

    local fallback = trim(Bake.MotionSourceStem(info.nameSource, info.nameIsPath))
    if fallback == "" then fallback = "motion" end
    local meta = Bake.Object()
    for _, field in ipairs(Bake.MetaFields) do
        Bake.Put(meta, field, trim(info.meta and info.meta[field] or ""))
    end
    if meta.display_name == "" then meta.display_name = fallback end
    Bake.Put(doc, "motion_id", info.motionID)
    Bake.Put(doc, "motion_name", meta.display_name)
    Bake.Put(doc, "display_name", meta.display_name)
    Bake.Put(doc, "meta", meta)
    return Bake.EncodeJSON(doc), meta.display_name
end
