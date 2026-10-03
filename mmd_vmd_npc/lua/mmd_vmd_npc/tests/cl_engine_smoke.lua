-- Only loaded by sv_engine_smoke.lua in an isolated developer instance.
if SERVER then return end
local report = { comparisons = {}, failures = {}, cancelledAfterSlices = 0, cancellations = {} }
local original = {}
for _, name in ipairs({ "mmd_vmd_npc_fast_build", "mmd_vmd_npc_build_budget_ms" }) do
    local cv = GetConVar(name)
    original[name] = cv and cv:GetString()
end
RunConsoleCommand("mmd_vmd_npc_fast_build", "1")
RunConsoleCommand("mmd_vmd_npc_build_budget_ms", "0.5")
local function notify(stage)
    net.Start("mmdvmd_test_stage")
    net.WriteString(stage)
    net.SendToServer()
end
local function save()
    file.CreateDir("mmd_vmd_npc")
    file.Write("mmd_vmd_npc/performance_smoke_client.json", util.TableToJSON(report, true))
end
include("mmd_vmd_npc/tests/cl_build_regression.lua")
local comparisonStage = 0
hook.Add("MMDVMDNPCBuildRegressionComplete", "MMDVMDNPC.EngineSmoke", function(result)
    report.comparisons[#report.comparisons + 1] = result
    if result.failed > 0 then report.failures[#report.failures + 1] = result.source .. " comparisons failed" end
    save()
    if comparisonStage == 0 then
        comparisonStage = 1
        timer.Simple(0.1, function()
            RunConsoleCommand("mmd_vmd_npc_test_build_motion", MMDVMDNPCPerformanceTestModel, "motion_8f38d4be83_98de5fe977")
        end)
    elseif comparisonStage == 1 then
        comparisonStage = 2
        timer.Simple(0.1, function()
            RunConsoleCommand("mmd_vmd_npc_test_build", "models/player/kleiner.mdl")
        end)
    else
        hook.Remove("MMDVMDNPCBuildRegressionComplete", "MMDVMDNPC.EngineSmoke")
        notify("comparisons_done")
    end
end)
local cancelArmed, slices, cancelMode = false, 0, "fast"
net.Receive("mmdvmd_test_control", function()
    local action = net.ReadString()
    if action == "arm_cancel" then cancelArmed, slices, cancelMode = true, 0, "fast" end
    if action == "arm_legacy_cancel" then
        RunConsoleCommand("mmd_vmd_npc_fast_build", "0")
        cancelArmed, slices, cancelMode = true, 0, "legacy"
        timer.Simple(0.1, function()
            report.legacyModeVerified = not GetConVar("mmd_vmd_npc_fast_build"):GetBool()
            if not report.legacyModeVerified then report.failures[#report.failures + 1] = "could not enable legacy worker test" end
            save()
            notify("legacy_ready")
        end)
    end
    if action == "finish" then
        for name, value in pairs(original) do if value ~= nil then RunConsoleCommand(name, value) end end
        hook.Remove("Think", "MMDVMDNPC.EngineSmokeCancel")
        report.buildJobsRemaining = table.Count(MMDVMDNPC.ClientBuildJobs or {})
        report.workerTasksRemaining = table.Count(MMDVMDNPC.BuildWorker.tasks)
        save()
        notify("client_finished")
    end
end)
hook.Add("Think", "MMDVMDNPC.EngineSmokeCancel", function()
    if cancelArmed and next(MMDVMDNPC.BuildWorker.tasks) then
        slices = slices + 1
        if slices >= 3 then
            cancelArmed = false
            report.cancelledAfterSlices = slices
            MMDVMDNPC.RequestCancelBuildTasks()
            report.cancelClearedWorker = next(MMDVMDNPC.BuildWorker.tasks) == nil
            report.cancellations[#report.cancellations + 1] = {
                mode = cancelMode, slices = slices, workerCleared = report.cancelClearedWorker,
            }
            save()
            notify("client_cancelled")
        end
    end
end)
timer.Simple(0.5, function()
    RunConsoleCommand("mmd_vmd_npc_test_build", MMDVMDNPCPerformanceTestModel)
end)
