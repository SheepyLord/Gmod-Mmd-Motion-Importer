-- The fake clock advances only where a work item actually consumes CPU time.
-- This makes scheduling assertions deterministic and independent of host load.
local now, passed, failures = 0, 0, {}
SysTime = function() return now end
local function new_worker()
    now = 0
    return assert(loadstring(worker_source, "cl_build_worker.lua"))()
end
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failures[#failures + 1] = name .. ": " .. tostring(err)
        print("FAIL " .. failures[#failures])
    end
end
local function empty(worker) return next(worker.tasks) == nil end

test("checkpoints are harmless in synchronous debug preview", function()
    local w = new_worker()
    w:Checkpoint()
    w:Step(0.002)
    now = 10
    w:Checkpoint()
    local unrelated = coroutine.create(function() w:Checkpoint(); return true end)
    local ok, result = coroutine.resume(unrelated)
    assert(ok and result == true and coroutine.status(unrelated) == "dead")
end)

test("Start defers computation until the next Step", function()
    local w = new_worker()
    local ran, result = false, nil
    w:Start("build", function() ran = true; return 42 end, function(value) result = value end)
    assert(not ran and result == nil)
    w:Step(0.002)
    assert(ran and result == 42 and empty(w))
end)

test("long builds cross frames without losing or duplicating output", function()
    local w = new_worker()
    local frames, complete, maxSlice = {}, 0, 0
    w:Start("build", function()
        for i = 1, 25 do
            now = now + 0.0007
            frames[#frames + 1] = i
            w:Checkpoint()
        end
        return frames
    end, function(value) assert(value == frames); complete = complete + 1 end)
    local steps = 0
    while not empty(w) do
        local before = now
        w:Step(0.002)
        maxSlice = math.max(maxSlice, now - before)
        steps = steps + 1
        assert(steps < 30, "build did not finish")
    end
    assert(steps > 1, "entire build blocked one frame")
    assert(maxSlice <= 0.0027 + 1e-9, "budget exceeded by more than one work unit")
    assert(complete == 1 and #frames == 25)
    for i, value in ipairs(frames) do assert(i == value, "frame ordering changed") end
end)

test("cancellation before execution does no work or completion", function()
    local w = new_worker()
    w:Start("cancelled", function() error("cancelled task executed") end, function() error("cancelled completion") end)
    w:Cancel("cancelled")
    w:Cancel("cancelled")
    w:Step(0.002)
    assert(empty(w))
end)

test("cancellation discards a suspended build and its result", function()
    local w = new_worker()
    local count, completed, failed = 0, 0, 0
    w:Start("cancelled", function()
        for i = 1, 10 do
            count = count + 1
            now = now + 0.001
            w:Checkpoint()
        end
    end, function() completed = completed + 1 end, function() failed = failed + 1 end)
    w:Step(0.002)
    assert(count > 0 and count < 10)
    local stoppedAt = count
    w:Cancel("cancelled")
    w:Step(0.002)
    assert(count == stoppedAt and completed == 0 and failed == 0 and empty(w))
end)

test("replacement does not deliver stale completion", function()
    local w = new_worker()
    local oldCount, oldDone, newDone = 0, false, false
    w:Start(17, function()
        oldCount = oldCount + 1
        now = now + 0.003
        w:Checkpoint()
        error("replaced coroutine resumed")
    end, function() oldDone = true end)
    w:Step(0.002)
    w:Start(17, function() return "new" end, function(value) assert(value == "new"); newDone = true end)
    w:Step(0.002)
    assert(oldCount == 1 and not oldDone and newDone and empty(w))
end)

test("failure is reported once and other builds continue", function()
    local w = new_worker()
    local failuresSeen, completed = 0, 0
    w:Start("broken", function() error("synthetic skeleton failure") end, function() error("bad completion") end,
        function(err) assert(string.find(err, "synthetic skeleton failure", 1, true)); failuresSeen = failuresSeen + 1 end)
    w:Start("good", function() return true end, function(value) assert(value); completed = completed + 1 end)
    for i = 1, 3 do w:Step(0.002) end
    assert(failuresSeen == 1 and completed == 1 and empty(w))
    now = 100
    w:Checkpoint()
end)

test("completion may safely queue the next batch under the same key", function()
    local w = new_worker()
    local completed = {}
    w:Start("batch", function() return 1 end, function(value)
        completed[#completed + 1] = value
        w:Start("batch", function() return 2 end, function(nextValue) completed[#completed + 1] = nextValue end)
    end)
    for i = 1, 3 do w:Step(0.002) end
    assert(#completed == 2 and completed[1] == 1 and completed[2] == 2 and empty(w))
end)

test("all queued builds share one frame budget", function()
    local w = new_worker()
    local completed = 0
    for task = 1, 3 do
        w:Start(task, function()
            for unit = 1, 4 do
                now = now + 0.0006
                w:Checkpoint()
            end
        end, function() completed = completed + 1 end)
    end
    local steps = 0
    while not empty(w) do
        local before = now
        w:Step(0.002)
        assert(now - before <= 0.0026 + 1e-9, "separate per-task budgets blocked one frame")
        steps = steps + 1
        assert(steps < 20)
    end
    assert(completed == 3 and steps > 1)
end)

test("build settings exist only while their own task is active", function()
    local w = new_worker()
    local expected = { transform = 17 }
    local completed = false
    w:Start("snapshot", function()
        assert(w.settings == expected)
        now = now + 0.003
        w:Checkpoint()
        assert(w.settings == expected)
        return true
    end, function(value) assert(value and w.settings == nil); completed = true end)
    w.tasks.snapshot.settings = expected
    w:Step(0.002)
    assert(w.settings == nil and not completed)
    w:Step(0.002)
    assert(w.settings == nil and completed and empty(w))
end)

print(string.format("Worker regressions: %d passed, %d failed", passed, #failures))
assert(#failures == 0, table.concat(failures, "\n"))
