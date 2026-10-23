-- Imported MMD camera animation playback (client).
--
-- The importer exports camera keys in the dancing CHARACTER's local frame:
-- eye position in source units and view angles in degrees, both relative to an
-- upright character at the origin facing +X. At render time each sample is
-- transformed by the anchor entity's position and yaw, so the path is correct
-- wherever the character stands and whichever way it faces.

MMDVMDNPC = MMDVMDNPC or {}
MMDVMDNPC.CameraTracks = MMDVMDNPC.CameraTracks or {}          -- [anchorEntIndex] = track
MMDVMDNPC.CameraDebugTracks = MMDVMDNPC.CameraDebugTracks or {} -- [motionID] = track
MMDVMDNPC.CameraPendingTransfers = MMDVMDNPC.CameraPendingTransfers or {}
MMDVMDNPC.CameraAnimActive = MMDVMDNPC.CameraAnimActive or false
MMDVMDNPC.CameraAnimEntIndex = MMDVMDNPC.CameraAnimEntIndex or nil
MMDVMDNPC.CameraAnimViewOrigin = MMDVMDNPC.CameraAnimViewOrigin or nil
MMDVMDNPC.CameraDebugPreview = MMDVMDNPC.CameraDebugPreview or nil

CreateClientConVar("mmd_vmd_npc_camera_key", "0", true, false, "Key code that toggles the imported camera animation view")
CreateClientConVar("mmd_vmd_npc_camera_auto", "1", true, false, "Automatically enter the imported camera animation when a dance you start has one")
CreateClientConVar("mmd_vmd_npc_cam_scale", "1", true, false, "Camera animation: legacy uniform position scale (migrated into the per-axis scales)")
CreateClientConVar("mmd_vmd_npc_cam_scale_x", "1", true, false, "Camera animation: position scale forward")
CreateClientConVar("mmd_vmd_npc_cam_scale_y", "1", true, false, "Camera animation: position scale left")
CreateClientConVar("mmd_vmd_npc_cam_scale_z", "1", true, false, "Camera animation: position scale up")
CreateClientConVar("mmd_vmd_npc_cam_offset_x", "0", true, false, "Camera animation: global offset forward")
CreateClientConVar("mmd_vmd_npc_cam_offset_y", "0", true, false, "Camera animation: global offset left")
CreateClientConVar("mmd_vmd_npc_cam_offset_z", "0", true, false, "Camera animation: global offset up")
CreateClientConVar("mmd_vmd_npc_cam_yaw", "0", true, false, "Camera animation: global yaw offset (degrees)")
CreateClientConVar("mmd_vmd_npc_cam_pitch", "0", true, false, "Camera animation: global pitch offset (degrees)")
CreateClientConVar("mmd_vmd_npc_cam_fov", "0", true, false, "Camera animation: fov offset (degrees)")
CreateClientConVar("mmd_vmd_npc_cam_collision", "1", true, false, "Camera animation: pull the camera in front of walls it would otherwise clip through")
CreateClientConVar("mmd_vmd_npc_cam_max_distance", "2500", true, false, "Camera animation: cap the camera's distance to the subject (0 = unlimited)")
CreateClientConVar("mmd_vmd_npc_cam_follow", "0", true, false, "Camera animation: rotate the view to keep the character in frame (experimental, play-time only)")
CreateClientConVar("mmd_vmd_npc_cam_follow_margin", "0.33", true, false, "Camera follow: fraction of the half-frame the character may drift from center before the camera turns (0 = always centered)")
CreateClientConVar("mmd_vmd_npc_cam_follow_speed", "8", true, false, "Camera follow: correction turn speed (per second)")

-- Wall collision defaults on. New clients already get "1"; this one-time
-- migration also turns it on for existing clients that saved it off during
-- earlier testing (before it actually worked), then respects any later choice.
CreateClientConVar("mmd_vmd_npc_cam_collision_migrated", "0", true, false)
hook.Add("InitPostEntity", "MMDVMDNPCCamCollisionDefaultOn", function()
    local marker = GetConVar("mmd_vmd_npc_cam_collision_migrated")
    if marker and marker:GetBool() then return end
    RunConsoleCommand("mmd_vmd_npc_cam_collision_migrated", "1")
    RunConsoleCommand("mmd_vmd_npc_cam_collision", "1")
end)

-- The uniform position scale was split per axis. Carry a tuned legacy value
-- into any axis still at its default, then neutralize the legacy convar. The
-- marker makes this strictly one-time: the legacy convar stays live as a
-- uniform multiplier afterwards, and a deliberate post-split legacy value must
-- never be folded into (and corrupt) tuned per-axis values on a later session.
CreateClientConVar("mmd_vmd_npc_cam_scale_split_migrated", "0", true, false)
hook.Add("InitPostEntity", "MMDVMDNPCCamScaleSplitMigrate", function()
    local marker = GetConVar("mmd_vmd_npc_cam_scale_split_migrated")
    if marker and marker:GetBool() then return end
    RunConsoleCommand("mmd_vmd_npc_cam_scale_split_migrated", "1")
    local legacy = GetConVar("mmd_vmd_npc_cam_scale")
    if not legacy then return end
    local value = legacy:GetFloat()
    if value ~= value or math.abs(value - 1) < 0.001 then return end
    for _, axis in ipairs({ "x", "y", "z" }) do
        local cvar = GetConVar("mmd_vmd_npc_cam_scale_" .. axis)
        if cvar and math.abs(cvar:GetFloat() - 1) < 0.001 then
            RunConsoleCommand("mmd_vmd_npc_cam_scale_" .. axis, tostring(value))
        end
    end
    RunConsoleCommand("mmd_vmd_npc_cam_scale", "1")
end)

local function L(key, fallback)
    return MMDVMDNPC.L and MMDVMDNPC.L(key, fallback) or (fallback or key)
end

local function convar_number(name, fallback)
    local cvar = GetConVar(name)
    if not cvar then return fallback end
    local value = cvar:GetFloat()
    if value ~= value then return fallback end
    return value
end

local function camera_auto_enabled()
    local cvar = GetConVar("mmd_vmd_npc_camera_auto")
    if not cvar then return true end
    return cvar:GetBool()
end

-- Track sampling --------------------------------------------------------------

-- A hard camera cut is exported as two keys on adjacent frames with a large
-- delta; hold the earlier key instead of smearing across the cut.
local CUT_POSITION_DELTA = 30
local CUT_ANGLE_DELTA = 25

local function normalize_angle(value)
    return math.NormalizeAngle and math.NormalizeAngle(value) or (((value + 180) % 360) - 180)
end

local function lerp_number(a, b, t)
    return a + (b - a) * t
end

local function lerp_angle(a, b, t)
    return a + normalize_angle(b - a) * t
end

local function camera_key_span(keys, frame)
    local lo, hi = 1, #keys
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if keys[mid].frame <= frame then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return lo
end

function MMDVMDNPC.SampleCameraTrack(track, frame)
    local keys = track and track.keys or nil
    if not istable(keys) or #keys <= 0 then return nil end

    local first, last = keys[1], keys[#keys]
    if frame <= first.frame then
        return first.x, first.y, first.z, first.p, first.yw, first.r, first.fov
    end
    if frame >= last.frame then
        return last.x, last.y, last.z, last.p, last.yw, last.r, last.fov
    end

    local index = camera_key_span(keys, frame)
    local a = keys[index]
    local b = keys[index + 1] or a
    local span = math.max(1e-6, b.frame - a.frame)
    local t = math.Clamp((frame - a.frame) / span, 0, 1)

    if (b.frame - a.frame) <= 1 then
        local posDelta = math.max(math.abs(b.x - a.x), math.abs(b.y - a.y), math.abs(b.z - a.z))
        local angDelta = math.max(
            math.abs(normalize_angle(b.p - a.p)),
            math.abs(normalize_angle(b.yw - a.yw)),
            math.abs(normalize_angle(b.r - a.r))
        )
        if posDelta > CUT_POSITION_DELTA or angDelta > CUT_ANGLE_DELTA then
            return a.x, a.y, a.z, a.p, a.yw, a.r, a.fov
        end
    end

    return lerp_number(a.x, b.x, t),
        lerp_number(a.y, b.y, t),
        lerp_number(a.z, b.z, t),
        lerp_angle(a.p, b.p, t),
        lerp_angle(a.yw, b.yw, t),
        lerp_angle(a.r, b.r, t),
        lerp_number(a.fov, b.fov, t)
end

local function track_frame_now(track, now)
    local fps = math.max(1, track.fps or 30)
    if track.paused then
        return track.heldFrame or track.frameStart or 0
    end
    local elapsedSeconds = math.max(0, now - (track.startAt or 0))
    -- Looping follows the BODY motion's period (loopSeconds from the server),
    -- not the camera's own frame range: the camera may be shorter than the
    -- dance and must hold its last key until the dance wraps.
    if track.loop and (track.loopSeconds or 0) > 0 then
        elapsedSeconds = elapsedSeconds % track.loopSeconds
    end
    local frame = (track.frameStart or 0) + elapsedSeconds * fps
    return math.min(frame, track.frameEnd or frame)
end

-- Global user transform (tuned from the camera debug panel) -------------------

local function apply_global_transform(x, y, z, p, yw, r, fov)
    -- Per-axis scales in the character's local frame (x forward, y left, z up),
    -- applied before the yaw offset so they follow the authored composition.
    -- The legacy uniform scale still multiplies in (it is 1 after migration)
    -- so setting it from the console is never silently dead.
    local legacyScale = math.Clamp(convar_number("mmd_vmd_npc_cam_scale", 1), 0.05, 20)
    local scaleX = math.Clamp(legacyScale * convar_number("mmd_vmd_npc_cam_scale_x", 1), 0.05, 20)
    local scaleY = math.Clamp(legacyScale * convar_number("mmd_vmd_npc_cam_scale_y", 1), 0.05, 20)
    local scaleZ = math.Clamp(legacyScale * convar_number("mmd_vmd_npc_cam_scale_z", 1), 0.05, 20)
    local yawOff = convar_number("mmd_vmd_npc_cam_yaw", 0)
    local pitchOff = convar_number("mmd_vmd_npc_cam_pitch", 0)
    local fovOff = convar_number("mmd_vmd_npc_cam_fov", 0)

    x, y, z = x * scaleX, y * scaleY, z * scaleZ
    if math.abs(yawOff) > 0.001 then
        local rad = math.rad(yawOff)
        local c, s = math.cos(rad), math.sin(rad)
        x, y = x * c - y * s, x * s + y * c
    end
    x = x + convar_number("mmd_vmd_npc_cam_offset_x", 0)
    y = y + convar_number("mmd_vmd_npc_cam_offset_y", 0)
    z = z + convar_number("mmd_vmd_npc_cam_offset_z", 0)

    p = math.Clamp(p + pitchOff, -89.9, 89.9)
    yw = yw + yawOff
    fov = math.Clamp(fov + fovOff, 1, 170)
    return x, y, z, p, yw, r, fov
end

-- MMD fov is vertical; Source expects the 4:3 horizontal fov and derives the
-- vertical from it independent of the actual window aspect.
local function vertical_to_source_fov(vfov)
    local half = math.rad(math.Clamp(vfov, 1, 170)) * 0.5
    return math.deg(2 * math.atan(math.tan(half) * (4 / 3)))
end

local function anchor_transform(ent, track)
    -- Non-debug tracks anchor to the dance-start snapshot sent in camera_begin:
    -- root-motion playback moves the entity origin during the dance, and the
    -- camera VMD already contains the character's travel, so re-anchoring to
    -- the live entity would double-count it. Debug previews (no dance running)
    -- keep following the live entity so the orbit tracks wherever it stands.
    if track and track.debug ~= true and isvector(track.anchorPos) then
        return track.anchorPos, Angle(0, tonumber(track.anchorYaw) or 0, 0)
    end
    local ang = ent:GetAngles()
    return ent:GetPos(), Angle(0, ang.y or 0, 0)
end

-- Wall collision + distance cap. The animated camera can be authored to swing
-- far from the character or, once the character is at an arbitrary world
-- position, end up on the far side of a wall so the player only sees geometry.
-- Both cases are corrected by pulling the camera along the subject->camera line
-- until it is in front of the obstruction (and no farther than a cap), then
-- widening the vertical FOV so the subject keeps its intended apparent size
-- (tan(fov/2) scales with the distance ratio).
local CAMERA_WALL_MARGIN = 8
-- Degenerate floor: never divide by ~zero and never pull nearer than this even
-- if a wall is right against the subject. Applied uniformly at every distance
-- (no separate "close-up" cutoff), so the camera never snaps on/off as an
-- animated close pass crosses a threshold.
local CAMERA_MIN_PULL = 4
local CAMERA_MAX_ADJUSTED_FOV = 130
local CAMERA_HULL_MIN = Vector(-4, -4, -4)
local CAMERA_HULL_MAX = Vector(4, 4, 4)

local function camera_pivot(anchorEnt)
    -- Follow the dancing CHARACTER (pelvis bone), not the entity center: with
    -- root motion the character walks away from where the dance started, and
    -- collision must trace from where the body actually is. Bone id is memoized
    -- per entity (false = model has no pelvis, skip further lookups).
    local pelvis = anchorEnt.MMDVMDNPCPelvisBone
    if pelvis == nil and anchorEnt.LookupBone then
        pelvis = anchorEnt:LookupBone("ValveBiped.Bip01_Pelvis") or anchorEnt:LookupBone("Pelvis") or false
        anchorEnt.MMDVMDNPCPelvisBone = pelvis
    end
    if pelvis and anchorEnt.GetBonePosition then
        local pos = anchorEnt:GetBonePosition(pelvis)
        if isvector(pos) then return pos end
    end
    if anchorEnt.WorldSpaceCenter then
        local center = anchorEnt:WorldSpaceCenter()
        if isvector(center) then return center end
    end
    return anchorEnt:GetPos() + Vector(0, 0, 40)
end

-- Occlusion trace from the subject to the desired camera spot. Uses the DEFAULT
-- solid mask (world brushes AND props/func_detail/displacements — the same mask
-- the working orbit camera uses; MASK_SOLID_BRUSHWORLD missed prop and detail
-- walls). A ±4 hull keeps the lens clear of the surface. If the hull merely
-- grazes nearby geometry at the start it reports StartSolid even though the
-- subject is in the open, so fall back to a line trace to tell a genuine
-- overshoot (subject truly inside a brush) from a false positive.
local function trace_camera_wall(pivot, target, anchorEnt)
    local filter = { anchorEnt }
    local ply = LocalPlayer()
    if IsValid(ply) then filter[#filter + 1] = ply end

    local hull = util.TraceHull({
        start = pivot,
        endpos = target,
        mins = CAMERA_HULL_MIN,
        maxs = CAMERA_HULL_MAX,
        filter = filter,
    })
    if not hull.StartSolid then return hull end

    return util.TraceLine({
        start = pivot,
        endpos = target,
        filter = filter,
    })
end

local function apply_camera_collision(anchorEnt, pivot, camPos, vfov)
    local toCam = camPos - pivot
    local dist = toCam:Length()
    if dist <= CAMERA_MIN_PULL then return camPos, vfov end
    local dir = toCam / dist

    local capped = dist
    local maxDist = convar_number("mmd_vmd_npc_cam_max_distance", 2500)
    if maxDist > 0 then capped = math.min(capped, maxDist) end

    local collide = GetConVar("mmd_vmd_npc_cam_collision")
    if not collide or collide:GetBool() then
        local tr = trace_camera_wall(pivot, pivot + dir * capped, anchorEnt)
        -- StartSolid here means the subject itself is inside a brush (a real
        -- animation overshoot through a wall); leave the camera where the
        -- animation put it rather than yanking it onto a surface behind the
        -- character.
        if tr.Hit and not tr.StartSolid then
            capped = math.min(capped, (tr.HitPos - pivot):Length() - CAMERA_WALL_MARGIN)
        end
    end

    capped = math.max(CAMERA_MIN_PULL, capped)
    if capped >= dist - 0.5 then return camPos, vfov end

    -- Widen to preserve apparent size, but never below the authored FOV (the
    -- ceiling only trims extreme fisheye — a base FOV already wider than the
    -- ceiling must not be narrowed by the collision path).
    local half = math.rad(math.Clamp(vfov, 1, 179)) * 0.5
    local widened = math.deg(2 * math.atan(math.tan(half) * (dist / capped)))
    return pivot + dir * capped, math.Clamp(widened, vfov, math.max(vfov, CAMERA_MAX_ADJUSTED_FOV))
end

-- Experimental "follow character" (mmd_vmd_npc_cam_follow): rotate the animated
-- view just enough to keep the dancing character near the center of frame —
-- inside the central third by default (margin 0.33 of the half-frame). Pure
-- render-time correction on the sampled view: builds, the imported keys and the
-- debug preview (which must show the authored path verbatim) are untouched.
local function camera_follow_enabled()
    local cvar = GetConVar("mmd_vmd_npc_cam_follow")
    return cvar ~= nil and cvar:GetBool()
end

-- Screen position maps to angle by tan, so the margin converts through
-- atan(margin * tan(halfFov)) rather than a linear fraction of the fov.
local function follow_max_offset(marginFrac, halfFovDeg)
    return math.deg(math.atan(marginFrac * math.tan(math.rad(halfFovDeg))))
end

-- Cut / loop-wrap detection for the follow smoothing, on the RAW sampled keys
-- (pre scale/anchor, so the user transform and world placement cannot skew the
-- thresholds). The per-render-frame delta is widened by how many track frames
-- this render frame advanced, so fast-but-smooth authored motion at low client
-- fps is not mistaken for a cut; a backward frame jump (loop wrap) keeps the
-- base thresholds.
local function camera_follow_cut(track, frame, x, y, z, p, yw)
    local cut = false
    if track.followPrevFrame ~= nil then
        local adv = frame - track.followPrevFrame
        local widen = adv >= 0 and math.Clamp(adv, 1, 4) or 1
        local posDelta = math.max(
            math.abs(x - track.followPrevX),
            math.abs(y - track.followPrevY),
            math.abs(z - track.followPrevZ))
        local angDelta = math.max(
            math.abs(normalize_angle(p - track.followPrevP)),
            math.abs(normalize_angle(yw - track.followPrevYw)))
        cut = posDelta > CUT_POSITION_DELTA * widen or angDelta > CUT_ANGLE_DELTA * widen
    end
    track.followPrevFrame = frame
    track.followPrevX, track.followPrevY, track.followPrevZ = x, y, z
    track.followPrevP, track.followPrevYw = p, yw
    return cut
end

-- Positive local yaw offset = subject left of view center; +rotation around
-- the view's own up axis turns the camera left. Positive local pitch offset =
-- subject below center (Source pitch-down positive); +rotation around the
-- view's right axis pitches the camera up, hence the negation. The pitch turn
-- uses the post-yaw right axis so the pair exactly inverts the yaw-then-pitch
-- (atan2) decomposition of the subject offset: a full correction centers the
-- subject precisely, whatever the authored roll.
local function follow_corrected_angles(camAng, pitchCorr, yawCorr)
    if math.abs(pitchCorr) < 0.001 and math.abs(yawCorr) < 0.001 then return camAng end
    local corrected = Angle(camAng.p, camAng.y, camAng.r)
    corrected:RotateAroundAxis(camAng:Up(), yawCorr)
    corrected:RotateAroundAxis(corrected:Right(), -pitchCorr)
    return corrected
end

local function apply_camera_follow(track, pivot, camPos, camAng, vfov, cutSnap)
    local toSubject = pivot - camPos
    if toSubject:LengthSqr() < 1 then
        -- Degenerate close pass: no meaningful direction to retarget on; keep
        -- holding the current correction so the view does not blip for a frame.
        return follow_corrected_angles(camAng, track.followPitch or 0, track.followYaw or 0)
    end

    -- Subject offset decomposed in the VIEW's own (rolled) frame, so the
    -- margin box is screen-aligned even on dutch angles, and a steep world
    -- pitch cannot fake a huge yaw offset for a subject sitting near screen
    -- center (the old desired.y - camAng.y decomposition blew up near the
    -- poles). atan2 keeps it continuous when the subject is behind the camera:
    -- that resolves to the shortest turn that brings it back into frame.
    local dir = toSubject:GetNormalized()
    local fwd = dir:Dot(camAng:Forward())
    local left = -dir:Dot(camAng:Right())
    local up = dir:Dot(camAng:Up())
    local offYaw = math.deg(math.atan2(left, fwd))
    local offPitch = math.deg(math.atan2(-up, math.sqrt(fwd * fwd + left * left)))

    -- Frame half-angles: MMD fov is vertical and aspect-independent, the
    -- horizontal half-angle follows from the real window aspect.
    local halfV = math.Clamp(vfov, 1, 170) * 0.5
    local halfH = math.deg(math.atan(math.tan(math.rad(halfV)) * (ScrW() / math.max(1, ScrH()))))

    -- Turn only by the excess beyond the allowed drift, so the authored
    -- composition survives wherever it already keeps the character framed.
    local margin = math.Clamp(convar_number("mmd_vmd_npc_cam_follow_margin", 0.33), 0, 0.95)
    local maxPitch = follow_max_offset(margin, halfV)
    local maxYaw = follow_max_offset(margin, halfH)
    local targetPitch = offPitch - math.Clamp(offPitch, -maxPitch, maxPitch)
    local targetYaw = offYaw - math.Clamp(offYaw, -maxYaw, maxYaw)

    -- Smooth toward the target correction; snap across authored camera cuts
    -- and loop wraps so the correction does not visibly swing after the
    -- picture itself already jumped.
    local blend = math.Clamp(FrameTime() * math.Clamp(convar_number("mmd_vmd_npc_cam_follow_speed", 8), 0.5, 60), 0, 1)
    if cutSnap then blend = 1 end
    track.followPitch = lerp_angle(track.followPitch or 0, targetPitch, blend)
    track.followYaw = lerp_angle(track.followYaw or 0, targetYaw, blend)

    return follow_corrected_angles(camAng, track.followPitch, track.followYaw)
end

-- Where the stage-placement and movement options moved the dancer, from the
-- server's mmdvmd_camera_shift (MMDVMDNPC.BuiltTravelShiftKeys): the camera
-- adds it so it keeps framing the dancer instead of the authored spot. Keyed
-- by anchor entity; a shift applies only to the camera transfer it was sent with.
MMDVMDNPC.CameraShifts = MMDVMDNPC.CameraShifts or {}

local function camera_shift_at(track, frame)
    local shift = MMDVMDNPC.CameraShifts[track.entIndex]
    if not shift or shift.transferID ~= track.transferID then return nil end
    local keys = shift.keys
    if #keys <= 0 then return nil end
    if frame <= keys[1].frame then return keys[1].x, keys[1].y end
    if frame >= keys[#keys].frame then return keys[#keys].x, keys[#keys].y end
    local lo, hi = 1, #keys
    while hi - lo > 1 do
        local mid = math.floor((lo + hi) * 0.5)
        if keys[mid].frame <= frame then lo = mid else hi = mid end
    end
    local a, b = keys[lo], keys[hi]
    -- Keys one frame apart around a jump are a scene cut: hold until its frame, as the body does.
    if b.frame - a.frame <= 1 and math.abs(b.x - a.x) + math.abs(b.y - a.y) > 2 then return a.x, a.y end
    local t = (frame - a.frame) / math.max(1, b.frame - a.frame)
    return a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t
end

local function camera_view_for(track, anchorEnt, frame)
    local x, y, z, p, yw, r, fov = MMDVMDNPC.SampleCameraTrack(track, frame)
    if x == nil then return nil end

    -- Follow bookkeeping runs on the raw sample, before the global transform.
    local followActive = false
    local followSnap = false
    if track.debug ~= true and camera_follow_enabled() then
        followActive = true
        followSnap = camera_follow_cut(track, frame, x, y, z, p, yw)
    else
        track.followPitch, track.followYaw = nil, nil
        track.followPrevFrame = nil
    end

    x, y, z, p, yw, r, fov = apply_global_transform(x, y, z, p, yw, r, fov)

    local anchorPos, anchorAng = anchor_transform(anchorEnt, track)
    local worldPos, worldAng = LocalToWorld(Vector(x, y, z), Angle(p, yw, r), anchorPos, anchorAng)
    local shiftX, shiftY = camera_shift_at(track, frame)
    if shiftX then
        local shift = Vector(shiftX, shiftY, 0)
        shift:Rotate(anchorAng)
        worldPos = worldPos + shift
    end
    local pivot = camera_pivot(anchorEnt)
    worldPos, fov = apply_camera_collision(anchorEnt, pivot, worldPos, fov)
    if followActive then
        worldAng = apply_camera_follow(track, pivot, worldPos, worldAng, fov, followSnap)
    end
    return {
        origin = worldPos,
        angles = worldAng,
        fov = vertical_to_source_fov(fov),
        drawviewer = true,
        localValues = { x = x, y = y, z = z, p = p, yw = yw, r = r, fov = fov },
    }
end

-- The camera debug preview orbits the "entity of interest": the first assigned
-- group actor, else the selected debug target, else the local player (so a
-- debug session with nothing selected previews on the player's own model).
function MMDVMDNPC.CameraDebugAnchor()
    local assigned = MMDVMDNPC.AssignedActors
    if istable(assigned) and istable(assigned.order) then
        for _, ent in ipairs(assigned.order) do
            if IsValid(ent) then return ent end
        end
    end
    local target = MMDVMDNPC.TargetStatus and MMDVMDNPC.TargetStatus.ent or nil
    if IsValid(target) then return target end
    local ply = LocalPlayer()
    if IsValid(ply) then return ply end
    return nil
end

-- Public helpers for the debug panel ------------------------------------------

function MMDVMDNPC.CameraDebugTrackFor(motionID)
    return MMDVMDNPC.CameraDebugTracks[tostring(motionID or "")]
end

-- True when the debug camera preview will actually render a view this frame.
-- Pure predicate (no CalcView side effects) so hook order cannot deadlock the
-- orbit camera against the camera hook.
function MMDVMDNPC.CameraDebugPreviewRenderable()
    local debugPreview = MMDVMDNPC.CameraDebugPreview
    if not istable(debugPreview) then return false end
    local track = MMDVMDNPC.CameraDebugTracks[tostring(debugPreview.motionID or "")]
    if not track then return false end
    local anchor = MMDVMDNPC.CameraDebugAnchor()
    if not IsValid(anchor) then return false end
    local frameWindow = MMDVMDNPC.DebugFrame
    local frame = IsValid(frameWindow) and tonumber(frameWindow.ActiveFrame) or nil
    return frame ~= nil and frame >= 0
end

function MMDVMDNPC.CameraDebugSample(motionID, frame)
    local track = MMDVMDNPC.CameraDebugTrackFor(motionID)
    if not track then return nil end
    local x, y, z, p, yw, r, fov = MMDVMDNPC.SampleCameraTrack(track, frame)
    if x == nil then return nil end
    x, y, z, p, yw, r, fov = apply_global_transform(x, y, z, p, yw, r, fov)
    return { x = x, y = y, z = z, p = p, yw = yw, r = r, fov = fov }
end

-- Activation -------------------------------------------------------------------

local function playable_camera_entries()
    local out = {}
    for entIndex, track in pairs(MMDVMDNPC.CameraTracks) do
        local ent = Entity(entIndex)
        if IsValid(ent) and istable(track.keys) and #track.keys > 0 then
            out[#out + 1] = { entIndex = entIndex, track = track }
        end
    end
    return out
end

function MMDVMDNPC.CameraAnimAvailable()
    return #playable_camera_entries() > 0
end

function MMDVMDNPC.ActivateCameraAnim(entIndex)
    local track = MMDVMDNPC.CameraTracks[entIndex]
    if not track or not IsValid(Entity(entIndex)) then return false end
    MMDVMDNPC.CameraAnimActive = true
    MMDVMDNPC.CameraAnimEntIndex = entIndex
    return true
end

function MMDVMDNPC.DeactivateCameraAnim()
    MMDVMDNPC.CameraAnimActive = false
    MMDVMDNPC.CameraAnimEntIndex = nil
    MMDVMDNPC.CameraAnimViewOrigin = nil
end

function MMDVMDNPC.ToggleCameraAnim()
    if MMDVMDNPC.CameraAnimActive then
        MMDVMDNPC.DeactivateCameraAnim()
        return
    end

    -- Of all dances currently playing with a camera path, enter the one that
    -- started most recently.
    local entries = playable_camera_entries()
    if #entries <= 0 then
        if notification and notification.AddLegacy then
            notification.AddLegacy(L("mmd_vmd_npc.camera.none_available", "No camera animation is playing"), NOTIFY_HINT, 3)
        end
        return
    end
    table.sort(entries, function(a, b)
        return (a.track.receivedAt or 0) > (b.track.receivedAt or 0)
    end)
    MMDVMDNPC.ActivateCameraAnim(entries[1].entIndex)
end

concommand.Add("mmdvmd_camera_toggle", function()
    MMDVMDNPC.ToggleCameraAnim()
end)

-- Net receivers ----------------------------------------------------------------

local function prune_stale_transfers()
    local cutoff = SysTime() - 30
    for id, pending in pairs(MMDVMDNPC.CameraPendingTransfers) do
        if (pending.receivedAt or 0) < cutoff then
            MMDVMDNPC.CameraPendingTransfers[id] = nil
        end
    end
end

-- The server's paced key chunks are sent from timers that outlive a stop or a
-- restart of the playback, so an in-flight transfer must be invalidated when
-- its anchor is stopped or superseded — otherwise the late chunks complete it,
-- re-install a dead track and auto-enter the camera of a playback that no
-- longer exists.
local function cancel_pending_transfers_for(entIndex)
    for id, pending in pairs(MMDVMDNPC.CameraPendingTransfers) do
        if pending.debug ~= true and pending.entIndex == entIndex then
            MMDVMDNPC.CameraPendingTransfers[id] = nil
        end
    end
end

local function pending_transfer_for(entIndex)
    for _, pending in pairs(MMDVMDNPC.CameraPendingTransfers) do
        if pending.debug ~= true and pending.entIndex == entIndex then
            return pending
        end
    end
    return nil
end

net.Receive("mmdvmd_camera_begin", function()
    prune_stale_transfers()
    local transferID = net.ReadUInt(32)
    local entIndex = net.ReadUInt(16)
    local motionID = net.ReadString()
    local anchorPos = net.ReadVector()
    local anchorYaw = net.ReadFloat()
    local fps = net.ReadUInt(16)
    local frameStart = net.ReadUInt(32)
    local frameEnd = net.ReadUInt(32)
    local startAt = net.ReadFloat()
    local loop = net.ReadBool()
    local loopSeconds = net.ReadFloat()
    local autoEnter = net.ReadBool()
    local debug = net.ReadBool()
    local keyCount = net.ReadUInt(16)

    local track = {
        transferID = transferID,
        entIndex = entIndex,
        motionID = motionID,
        anchorPos = anchorPos,
        anchorYaw = anchorYaw,
        fps = fps,
        frameStart = frameStart,
        frameEnd = frameEnd,
        startAt = startAt,
        loop = loop,
        loopSeconds = loopSeconds,
        autoEnter = autoEnter,
        debug = debug,
        expected = keyCount,
        received = 0,
        keys = {},
        receivedAt = SysTime(),
    }

    if keyCount <= 0 then
        -- Camera-less motion answering a debug request.
        if debug then
            MMDVMDNPC.CameraDebugTracks[motionID] = nil
            hook.Run("MMDVMDNPCCameraDebugTrackUpdated", motionID, nil)
        end
        return
    end

    -- A newer begin for the same anchor supersedes any older in-flight
    -- transfer (the playback was restarted while the previous camera track
    -- was still streaming).
    if not debug then
        cancel_pending_transfers_for(entIndex)
    end
    MMDVMDNPC.CameraPendingTransfers[transferID] = track
end)

net.Receive("mmdvmd_camera_keys", function()
    local transferID = net.ReadUInt(32)
    local startIndex = net.ReadUInt(16)
    local count = net.ReadUInt(16)
    local track = MMDVMDNPC.CameraPendingTransfers[transferID]

    for i = 0, count - 1 do
        local key = {
            frame = net.ReadUInt(32),
            x = net.ReadFloat(),
            y = net.ReadFloat(),
            z = net.ReadFloat(),
            p = net.ReadFloat(),
            yw = net.ReadFloat(),
            r = net.ReadFloat(),
            fov = net.ReadFloat(),
        }
        if track then
            track.keys[startIndex + i] = key
            track.received = track.received + 1
        end
    end

    if not track or track.received < track.expected then return end
    MMDVMDNPC.CameraPendingTransfers[transferID] = nil

    if track.debug then
        MMDVMDNPC.CameraDebugTracks[track.motionID] = track
        hook.Run("MMDVMDNPCCameraDebugTrackUpdated", track.motionID, track)
        return
    end

    MMDVMDNPC.CameraTracks[track.entIndex] = track

    -- Any playback this player started (wheel, self via menu, NPC or group):
    -- enter the imported camera automatically when the camera-auto option is
    -- enabled. The freshly spawned self-proxy entity may not have been
    -- networked yet (net messages outrun entity snapshots), so a failed
    -- activation is retried from the Think hook until the entity appears or
    -- the attempt expires.
    if track.autoEnter and camera_auto_enabled() then
        if not MMDVMDNPC.ActivateCameraAnim(track.entIndex) then
            track.pendingActivate = true
            track.pendingActivateUntil = SysTime() + 5
        end
    end
end)

net.Receive("mmdvmd_camera_shift", function()
    local entIndex = net.ReadUInt(16)
    local transferID = net.ReadUInt(32)
    local count = net.ReadUInt(16)
    local keys = {}
    for i = 1, count do
        keys[i] = { frame = net.ReadUInt(32), x = net.ReadFloat(), y = net.ReadFloat() }
    end
    MMDVMDNPC.CameraShifts[entIndex] = { transferID = transferID, keys = keys }
end)

net.Receive("mmdvmd_camera_stop", function()
    local entIndex = net.ReadUInt(16)
    MMDVMDNPC.CameraTracks[entIndex] = nil
    MMDVMDNPC.CameraShifts[entIndex] = nil
    cancel_pending_transfers_for(entIndex)
    if MMDVMDNPC.CameraAnimActive and MMDVMDNPC.CameraAnimEntIndex == entIndex then
        MMDVMDNPC.DeactivateCameraAnim()
    end
end)

net.Receive("mmdvmd_camera_sync", function()
    local entIndex = net.ReadUInt(16)
    local paused = net.ReadBool()
    local startAt = net.ReadFloat()
    -- The keys may still be streaming; apply the sync to the in-flight
    -- transfer so a pause issued in that window is not lost when the track
    -- installs moments later.
    local track = MMDVMDNPC.CameraTracks[entIndex] or pending_transfer_for(entIndex)
    if not track then return end

    if paused and not track.paused then
        track.heldFrame = track_frame_now(track, CurTime())
    end
    track.paused = paused
    track.startAt = startAt
    if not paused then track.heldFrame = nil end
end)

hook.Add("MMDVMDNPCPlayStatusUpdated", "MMDVMDNPCCameraStatusWatch", function(status)
    -- "stopped_all" only stops NPC dances; the server sends explicit
    -- mmdvmd_camera_stop per playback, so just prune tracks whose anchor is
    -- gone rather than wiping a still-running self-playback camera.
    if istable(status) and status.status == "stopped_all" then
        for entIndex, track in pairs(MMDVMDNPC.CameraTracks) do
            -- A freshly started self playback's proxy can lawfully be invalid
            -- for a few seconds (net beats entity snapshots). The pending
            -- activation window covers the auto-enter case; the receivedAt
            -- grace covers tracks installed with the camera-auto option off.
            local awaitingEntity = (track.pendingActivate
                    and (track.pendingActivateUntil or 0) >= SysTime())
                or (track.receivedAt or 0) >= SysTime() - 5
            if not IsValid(Entity(entIndex)) and not awaitingEntity then
                MMDVMDNPC.CameraTracks[entIndex] = nil
                if MMDVMDNPC.CameraAnimActive and MMDVMDNPC.CameraAnimEntIndex == entIndex then
                    MMDVMDNPC.DeactivateCameraAnim()
                end
            end
        end
    end
end)

-- Rendering --------------------------------------------------------------------

hook.Add("CalcView", "MMDVMDNPCCameraAnim", function(ply, pos, angles, fov)
    -- Camera debug preview from the raw-animation debug window takes priority.
    if MMDVMDNPC.CameraDebugPreviewRenderable() then
        local debugPreview = MMDVMDNPC.CameraDebugPreview
        local track = MMDVMDNPC.CameraDebugTracks[tostring(debugPreview.motionID or "")]
        local anchor = MMDVMDNPC.CameraDebugAnchor()
        local frameWindow = MMDVMDNPC.DebugFrame
        local frame = IsValid(frameWindow) and tonumber(frameWindow.ActiveFrame) or 0
        local view = camera_view_for(track, anchor, math.max(0, frame))
        if view then
            MMDVMDNPC.CameraAnimViewOrigin = view.origin
            MMDVMDNPC.CameraAnimViewAngles = view.angles
            return view
        end
    end

    if not MMDVMDNPC.CameraAnimActive then return end

    local entIndex = MMDVMDNPC.CameraAnimEntIndex
    local track = entIndex and MMDVMDNPC.CameraTracks[entIndex] or nil
    local anchor = entIndex and Entity(entIndex) or nil
    if not track or not IsValid(anchor) then
        MMDVMDNPC.DeactivateCameraAnim()
        return
    end

    local view = camera_view_for(track, anchor, track_frame_now(track, CurTime()))
    if not view then
        MMDVMDNPC.DeactivateCameraAnim()
        return
    end

    MMDVMDNPC.CameraAnimViewOrigin = view.origin
    MMDVMDNPC.CameraAnimViewAngles = view.angles
    return view
end)

hook.Add("PreDrawViewModel", "MMDVMDNPCCameraAnimViewModel", function()
    if MMDVMDNPC.CameraAnimActive or MMDVMDNPC.CameraDebugPreviewRenderable() then return true end
end)

-- Hotkey + deferred activation ---------------------------------------------------

local function retry_pending_activations()
    for entIndex, track in pairs(MMDVMDNPC.CameraTracks) do
        if track.pendingActivate then
            if (track.pendingActivateUntil or 0) < SysTime() then
                track.pendingActivate = nil
            elseif MMDVMDNPC.ActivateCameraAnim(entIndex) then
                track.pendingActivate = nil
            end
        end
    end
end

-- input.WasKeyPressed/WasMousePressed only work inside Move hooks, so from
-- Think the hotkey must edge-detect the held state manually.
local hotkeyWasDown = false

hook.Add("Think", "MMDVMDNPCCameraHotkey", function()
    retry_pending_activations()

    local key = math.floor(convar_number("mmd_vmd_npc_camera_key", 0))
    if key <= 0 then
        hotkeyWasDown = false
        return
    end

    -- DBinder can hand out mouse button codes as well as keyboard KEY_ codes.
    local down
    if MOUSE_FIRST and key >= MOUSE_FIRST then
        down = input.IsMouseDown and input.IsMouseDown(key) or false
    else
        down = input.IsKeyDown and input.IsKeyDown(key) or false
    end

    -- Do not toggle while UI could be consuming the key: main menu, any
    -- cursor-visible panel (spawn menu, addon menu, wheel — this also covers
    -- pressing the key inside the DBinder while binding it), chat, or a
    -- focused text field. The held state still updates below so closing the
    -- UI with the key held does not fire a spurious toggle.
    local suppressed = gui.IsGameUIVisible()
        or (vgui and vgui.CursorVisible and vgui.CursorVisible())
        or (vgui and vgui.GetKeyboardFocus and IsValid(vgui.GetKeyboardFocus()))
    if not suppressed then
        local ply = LocalPlayer()
        suppressed = IsValid(ply) and ply.IsTyping and ply:IsTyping() or false
    end

    if down and not hotkeyWasDown and not suppressed then
        MMDVMDNPC.ToggleCameraAnim()
    end
    hotkeyWasDown = down
end)

-- Hide HUD during camera motion --------------------------------------------------

local function camera_motion_active()
    return MMDVMDNPC.CameraAnimActive == true
        or (MMDVMDNPC.CameraDebugPreviewRenderable and MMDVMDNPC.CameraDebugPreviewRenderable() == true)
end

-- While an imported camera animation drives the view, hide every standard HUD
-- element (health, ammo, crosshair, ...) so the shot is clean. Gated by the
-- default-on `mmd_vmd_npc_hide_hud` option; returning nil leaves the HUD alone.
hook.Add("HUDShouldDraw", "MMDVMDNPCHideHUD", function(name)
    local cv = GetConVar("mmd_vmd_npc_hide_hud")
    if cv and not cv:GetBool() then return end
    if camera_motion_active() then return false end
end)

local hideHudKeyWasDown = false

hook.Add("Think", "MMDVMDNPCHideHudHotkey", function()
    local key = math.floor(convar_number("mmd_vmd_npc_hide_hud_key", 0))
    if key <= 0 then
        hideHudKeyWasDown = false
        return
    end

    local down
    if MOUSE_FIRST and key >= MOUSE_FIRST then
        down = input.IsMouseDown and input.IsMouseDown(key) or false
    else
        down = input.IsKeyDown and input.IsKeyDown(key) or false
    end

    local suppressed = gui.IsGameUIVisible()
        or (vgui and vgui.CursorVisible and vgui.CursorVisible())
        or (vgui and vgui.GetKeyboardFocus and IsValid(vgui.GetKeyboardFocus()))
    if not suppressed then
        local ply = LocalPlayer()
        suppressed = IsValid(ply) and ply.IsTyping and ply:IsTyping() or false
    end

    if down and not hideHudKeyWasDown and not suppressed then
        local cv = GetConVar("mmd_vmd_npc_hide_hud")
        RunConsoleCommand("mmd_vmd_npc_hide_hud", (cv and cv:GetBool()) and "0" or "1")
    end
    hideHudKeyWasDown = down
end)
