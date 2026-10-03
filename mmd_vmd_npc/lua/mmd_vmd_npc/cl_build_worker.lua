-- Cooperative build work. A checkpoint yields only from the active worker,
-- so the same retargeting functions remain synchronous in the debug preview.
-- The budget is a soft limit: individual engine calls cannot be interrupted.
local worker = { tasks = {} }

function worker:Start(key, run, complete, failed)
    self:Cancel(key)
    self.tasks[key] = {
        thread = coroutine.create(run),
        complete = complete,
        failed = failed,
    }
end

function worker:Cancel(key)
    self.tasks[key] = nil
end

function worker:Checkpoint()
    if self.active and self.active == coroutine.running() and SysTime() >= self.deadline then
        coroutine.yield()
    end
end

function worker:Step(seconds)
    self.deadline = SysTime() + seconds
    for key, task in pairs(self.tasks) do
        self.active = task.thread
        self.settings = task.settings
        local ok, result = coroutine.resume(task.thread)
        self.active = nil
        self.settings = nil
        if not ok or coroutine.status(task.thread) == "dead" then
            self.tasks[key] = nil
            if ok then
                if task.complete then task.complete(result) end
            elseif task.failed then
                task.failed(tostring(result))
            end
        end
        if SysTime() >= self.deadline then break end
    end
end

return worker
