local limits = require("scripts.spellforge.shared.limits")

local orchestrator = {}

local queue = {}
local jobs = {}
local next_job_index = 1
local current_tick = 0

local function cloneJob(job)
    if type(job) ~= "table" then
        return nil
    end
    local out = {}
    for k, v in pairs(job) do
        out[k] = v
    end
    return out
end

local function appendError(errors, path, message)
    errors[#errors + 1] = {
        path = path,
        message = message,
    }
end

local function validateDepth(depth)
    local d = tonumber(depth) or 0
    if d > limits.MAX_RECURSION_DEPTH then
        return false, string.format("depth exceeds MAX_RECURSION_DEPTH (%d)", limits.MAX_RECURSION_DEPTH)
    end
    if d < 0 then
        return false, "depth must be >= 0"
    end
    return true, nil
end

local function isExpired(job)
    return job.expires_at_tick ~= nil and current_tick >= job.expires_at_tick
end

local function enqueueInternal(job)
    local job_id = string.format("job_%d", next_job_index)
    next_job_index = next_job_index + 1

    local depth = tonumber(job.depth) or 0
    local ttl_ticks = tonumber(job.ttl_ticks)

    local normalized = {
        job_id = job_id,
        kind = job.kind,
        status = "queued",
        recipe_id = job.recipe_id,
        slot_id = job.slot_id,
        helper_engine_id = job.helper_engine_id,
        parent_job_id = job.parent_job_id,
        source_job_id = job.source_job_id,
        depth = depth,
        created_tick = current_tick,
        expires_at_tick = job.expires_at_tick,
        ttl_ticks = ttl_ticks,
        payload = job.payload,
        not_before_tick = job.not_before_tick,
        error = nil,
        trace = {},
    }

    if ttl_ticks ~= nil then
        normalized.expires_at_tick = current_tick + ttl_ticks
    end

    jobs[job_id] = normalized
    queue[#queue + 1] = job_id

    return normalized
end

function orchestrator.enqueue(job, opts)
    local _ = opts
    if type(job) ~= "table" then
        return { ok = false, error = "job must be a table" }
    end

    local kind = job.kind
    if type(kind) ~= "string" or kind == "" then
        return { ok = false, error = "job.kind must be a non-empty string" }
    end

    local depth_ok, depth_err = validateDepth(job.depth)
    if not depth_ok then
        return { ok = false, error = depth_err }
    end

    local normalized = enqueueInternal(job)
    return {
        ok = true,
        job_id = normalized.job_id,
        status = normalized.status,
    }
end

function orchestrator.cancel(job_id)
    local job = jobs[job_id]
    if not job then
        return { ok = false, error = "job not found" }
    end
    if job.status ~= "queued" then
        return { ok = false, error = string.format("cannot cancel job in status=%s", tostring(job.status)) }
    end
    job.status = "canceled"
    return { ok = true }
end

local function runHandler(job)
    if job.kind == "noop" or job.kind == "mark_complete" then
        return true, nil, nil
    elseif job.kind == "fail" then
        return false, tostring(job.payload and job.payload.error or "dummy fail"), nil
    elseif job.kind == "enqueue_child_dummy" then
        local child_depth = (job.depth or 0) + 1
        local depth_ok, depth_err = validateDepth(child_depth)
        if not depth_ok then
            return false, depth_err, nil
        end
        local child_kind = job.payload and job.payload.child_kind or "noop"
        local child = enqueueInternal({
            kind = child_kind,
            recipe_id = job.recipe_id,
            slot_id = job.slot_id,
            helper_engine_id = job.helper_engine_id,
            parent_job_id = job.job_id,
            source_job_id = job.job_id,
            depth = child_depth,
            payload = job.payload and job.payload.child_payload or nil,
            not_before_tick = current_tick + 1,
        })
        return true, nil, child.job_id
    end

    return false, string.format("unsupported job kind: %s", tostring(job.kind)), nil
end

function orchestrator.tick(opts)
    local options = opts or {}
    current_tick = current_tick + 1

    local max_jobs = options.max_jobs_per_tick or limits.MAX_JOBS_PER_TICK
    local processed_count = 0
    local completed_count = 0
    local failed_count = 0
    local expired_count = 0
    local canceled_count = 0
    local processed_order = {}

    local iterations = 0
    local initial_len = #queue

    while processed_count < max_jobs and #queue > 0 and iterations < initial_len do
        iterations = iterations + 1
        local job_id = table.remove(queue, 1)
        local job = jobs[job_id]

        if job and job.status == "queued" then
            if job.not_before_tick ~= nil and current_tick < job.not_before_tick then
                queue[#queue + 1] = job_id
            elseif isExpired(job) then
                job.status = "expired"
                processed_count = processed_count + 1
                expired_count = expired_count + 1
                processed_order[#processed_order + 1] = job_id
            else
                job.status = "running"
                local ok, err, child_job_id = runHandler(job)
                processed_count = processed_count + 1
                processed_order[#processed_order + 1] = job_id

                if ok then
                    job.status = "complete"
                    if child_job_id then
                        job.child_job_id = child_job_id
                    end
                    completed_count = completed_count + 1
                else
                    job.status = "failed"
                    job.error = tostring(err)
                    failed_count = failed_count + 1
                end
            end
        elseif job and job.status == "canceled" then
            canceled_count = canceled_count + 1
        end
    end

    return {
        tick = current_tick,
        processed_count = processed_count,
        completed_count = completed_count,
        failed_count = failed_count,
        expired_count = expired_count,
        canceled_count = canceled_count,
        remaining_count = #queue,
        processed_order = processed_order,
    }
end

function orchestrator.getJob(job_id)
    return cloneJob(jobs[job_id])
end

function orchestrator.clearForTests()
    queue = {}
    jobs = {}
    next_job_index = 1
    current_tick = 0
end

return orchestrator
