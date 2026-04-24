local orchestrator = require("scripts.spellforge.global.orchestrator")
local plan_cache = require("scripts.spellforge.global.plan_cache")
local helper_records = require("scripts.spellforge.global.helper_records")
local log = require("scripts.spellforge.shared.log").new("tests.smoke_orchestrator")

local state = {
    ran = false,
}

local function assertLine(ok, label, detail)
    if ok then
        log.info("PASS " .. label)
    else
        log.error("FAIL " .. label .. (detail and (" :: " .. detail) or ""))
    end
end

local function run()
    orchestrator.clearForTests()

    local one = orchestrator.enqueue({ kind = "noop" })
    assertLine(one.ok == true and one.job_id ~= nil, "1 enqueue one noop")
    local j1 = orchestrator.getJob(one.job_id)
    assertLine(j1 and j1.status == "queued", "1 queued status before tick")
    local t1 = orchestrator.tick()
    local j1_after = orchestrator.getJob(one.job_id)
    assertLine(t1.processed_count == 1, "1 tick processed_count=1")
    assertLine(j1_after and j1_after.status == "complete", "1 noop completes")

    orchestrator.clearForTests()
    local a = orchestrator.enqueue({ kind = "mark_complete", payload = { name = "A" } })
    local b = orchestrator.enqueue({ kind = "mark_complete", payload = { name = "B" } })
    local c = orchestrator.enqueue({ kind = "mark_complete", payload = { name = "C" } })
    local fifo = orchestrator.tick()
    local order_ok = fifo.processed_order[1] == a.job_id and fifo.processed_order[2] == b.job_id and fifo.processed_order[3] == c.job_id
    assertLine(order_ok, "2 FIFO processing order")

    orchestrator.clearForTests()
    for _ = 1, 19 do
        orchestrator.enqueue({ kind = "noop" })
    end
    local bound1 = orchestrator.tick()
    local bound2 = orchestrator.tick()
    assertLine(bound1.processed_count == 16 and bound1.remaining_count == 3, "3 first tick bounded by MAX_JOBS_PER_TICK")
    assertLine(bound2.processed_count == 3 and bound2.remaining_count == 0, "3 second tick processes remainder")

    orchestrator.clearForTests()
    orchestrator.enqueue({ kind = "mark_complete" })
    local fail_job = orchestrator.enqueue({ kind = "fail", payload = { error = "expected failure" } })
    orchestrator.enqueue({ kind = "mark_complete" })
    local fail_tick = orchestrator.tick()
    local fail_state = orchestrator.getJob(fail_job.job_id)
    assertLine(fail_tick.failed_count == 1, "4 failing job increments failed_count")
    assertLine(fail_state and fail_state.status == "failed" and fail_state.error ~= nil, "4 failing job has readable error")
    assertLine(fail_tick.completed_count == 2, "4 later jobs still complete")

    orchestrator.clearForTests()
    local exp = orchestrator.enqueue({ kind = "mark_complete", ttl_ticks = 0 })
    local exp_tick = orchestrator.tick()
    local exp_state = orchestrator.getJob(exp.job_id)
    assertLine(exp_tick.expired_count == 1, "5 expired job counted")
    assertLine(exp_state and exp_state.status == "expired", "5 expired job does not run")

    orchestrator.clearForTests()
    local cancel = orchestrator.enqueue({ kind = "mark_complete" })
    local canceled = orchestrator.cancel(cancel.job_id)
    local cancel_tick = orchestrator.tick()
    local cancel_state = orchestrator.getJob(cancel.job_id)
    assertLine(canceled.ok == true, "6 cancel returns ok")
    assertLine(cancel_state and cancel_state.status == "canceled", "6 canceled status retained")
    assertLine(cancel_tick.completed_count == 0, "6 canceled job not completed")

    orchestrator.clearForTests()
    local depth_bad = orchestrator.enqueue({ kind = "noop", depth = 99 })
    assertLine(depth_bad.ok == false, "7 depth cap reject")

    orchestrator.clearForTests()
    local parent = orchestrator.enqueue({ kind = "enqueue_child_dummy", depth = 0, payload = { child_kind = "noop" } })
    local child_tick_1 = orchestrator.tick()
    local parent_state = orchestrator.getJob(parent.job_id)
    local child_tick_2 = orchestrator.tick()
    local child_id = parent_state and parent_state.child_job_id
    local child_state = child_id and orchestrator.getJob(child_id) or nil
    assertLine(child_tick_1.completed_count == 1 and child_tick_1.remaining_count == 1, "8 parent completes and child queued")
    assertLine(child_tick_2.completed_count == 1 and child_state and child_state.status == "complete", "8 child runs on later tick")

    orchestrator.enqueue({ kind = "noop" })
    orchestrator.clearForTests()
    local reset = orchestrator.enqueue({ kind = "noop" })
    assertLine(reset.ok == true and reset.job_id == "job_1", "9 clearForTests resets deterministic job IDs")

    orchestrator.clearForTests()
    plan_cache.clearForTests()
    helper_records.clearForTests()
    local compiled = plan_cache.compileOrGet({
        { id = "firedamage", range = 2, magnitudeMin = 10, magnitudeMax = 10, area = 0, duration = 1 },
    })
    local materialized = plan_cache.attachHelperRecords(compiled.recipe_id)
    local first_mapping = materialized.plan and materialized.plan.helper_records and materialized.plan.helper_records[1]
    local staged = orchestrator.enqueue({
        kind = "mark_complete",
        recipe_id = first_mapping and first_mapping.recipe_id,
        slot_id = first_mapping and first_mapping.slot_id,
        helper_engine_id = first_mapping and first_mapping.engine_id,
    })
    local staged_tick = orchestrator.tick()
    local staged_state = staged.ok and orchestrator.getJob(staged.job_id) or nil
    assertLine(staged.ok == true, "10 staged metadata job enqueue")
    assertLine(staged_state and staged_state.helper_engine_id ~= nil and staged_state.status == "complete", "10 staged metadata preserved and completed")
    assertLine(staged_tick.completed_count == 1, "10 no SFP launch path used by orchestrator dummy job")

    log.info("smoke orchestrator run complete")
end

return {
    engineHandlers = {
        onUpdate = function()
            if state.ran then
                return
            end
            state.ran = true
            run()
        end,
    },
}
