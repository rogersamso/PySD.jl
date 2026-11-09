# Jobs: runs and analyses wait for one of the `max_parallel` simulation slots,
# first come first served; a user has at most `max_jobs_per_user` waiting or
# running.

struct Cancelled <: Exception end

"""
    submit!(work, ex, user, kind, label) -> Job

Queue `work(job)`.  It runs on a thread of its own when its turn comes.
"""
function submit!(work, ex::Explorer, user, kind, label)
    job = Job(_new_id(), user, kind, label, :queued, 0.0, "", nothing, now(), nothing, nothing,
              Threads.Atomic{Bool}(false), work)
    lock(ex.cond) do
        if !is_admin(ex, user)
            mine = count(j -> j.user == user && j.status in (:queued, :running), ex.jobs)
            limit = ex.settings["max_jobs_per_user"]
            mine >= limit && throw(ArgumentError(
                "you have $mine job$(mine == 1 ? "" : "s") waiting or running (at most $limit): wait for it, or cancel it"))
        end
        _forget_old_jobs!(ex)
        push!(ex.jobs, job)
    end
    errormonitor(Threads.@spawn _execute(ex, job))     # (an error in it is printed, not lost)
    return job
end

# a job's turn: a slot free, and no job queued before it
_turn(ex, job) = ex.running < ex.settings["max_parallel"] &&
                 findfirst(j -> j.status === :queued, ex.jobs) == findfirst(j -> j === job, ex.jobs)

function _execute(ex::Explorer, job::Job)
    started = lock(ex.cond) do
        while job.status === :queued && !_turn(ex, job)
            wait(ex.cond)
        end
        job.status === :queued || return false        # cancelled while it waited
        job.status = :running
        job.started = now()
        ex.running += 1
        notify(ex.cond)                                # the next one may have a slot too
        return true
    end
    started || return
    try
        job.result = job.work(job)
        job.progress = 1.0
        job.status = :done
    catch e
        if e isa Cancelled
            job.status, job.message = :cancelled, "cancelled"
        else
            job.status = :failed
            job.message = e isa ArgumentError ? e.msg : sprint(showerror, e)
            @error "job $(job.id) ($(job.kind) of $(job.user)) failed" exception = (e, catch_backtrace())
        end
    finally
        job.finished = now()
        lock(ex.cond) do
            ex.running -= 1
            notify(ex.cond)
        end
    end
end

"""
    cancel!(ex, user, id)

A job waiting: it won't start.  An analysis running: it stops before its next
run.  A run running can't be stopped (it takes seconds).
"""
function cancel!(ex::Explorer, user, id)
    lock(ex.cond) do
        job = _job(ex, user, id)
        if job.status === :queued
            job.status, job.message, job.finished = :cancelled, "cancelled", now()
            notify(ex.cond)
        elseif job.status === :running
            job.kind == "run" && throw(ArgumentError("a run can't be stopped once it has started: it takes seconds"))
            job.cancel[] = true
        end
        return job
    end
end

function _job(ex::Explorer, user, id)
    i = findfirst(j -> j.id == id, ex.jobs)
    (i === nothing || !(ex.jobs[i].user == user || is_admin(ex, user))) && throw(KeyError(id))
    return ex.jobs[i]
end

# finished jobs are kept an hour, for the page to see how they ended
_forget_old_jobs!(ex) =
    filter!(j -> j.finished === nothing || now() - j.finished < Hour(1), ex.jobs)

function job_info(ex::Explorer, job::Job)
    queued = filter(j -> j.status === :queued, ex.jobs)
    pos = findfirst(j -> j === job, queued)
    stamp(t) = t === nothing ? nothing : Dates.format(t, "HH:MM:SS")
    return Dict("id" => job.id, "user" => job.user, "kind" => job.kind, "label" => job.label,
                "status" => String(job.status), "progress" => round(job.progress; digits = 3),
                "message" => job.message, "result" => job.result, "position" => pos,
                "created" => stamp(job.created), "started" => stamp(job.started), "finished" => stamp(job.finished))
end

jobs_info(ex::Explorer, user, all = is_admin(ex, user)) =
    lock(ex.cond) do
        [job_info(ex, j) for j in ex.jobs if all || j.user == user]
    end
