# Times models written in the DSL (as PySD translates them, backend = "dsl"), in
# one Julia session, in the order given, and saves their results.  A model that
# takes data from other models (`parents` in its inputs) gets the runs of the
# models before it.
#
# usage: julia --project=<PySD.jl> run_julia.jl <out dir> <model.jl> [<model.jl> …]
#
# For each model: the time to build it (include its file), its first run (mostly
# compiling), a later run, and its results in <out dir>/<name>_results.tsv (a row
# per variable or element, a column per saved time); the times also go to
# <out dir>/julia_times.tsv.
using PySD, DimensionalData

function save(path, m, r)
    open(path, "w") do io
        println(io, "name\t", join(r.time, "\t"))
        n = length(r.time)
        for v in m.vars
            x = try r[v.name] catch; continue end                 # lookups: not values
            vals = v.kind in (:stock, :aux) ? x : fill(x, n)
            (vals[1] isa Number || vals[1] isa DimensionalData.AbstractDimArray{<:Number}) || continue
            if isempty(v.dims)
                println(io, v.name, "\t", join(vals, "\t"))
            else
                for I in CartesianIndices(size(vals[1]))
                    labels = join((string(DimensionalData.lookup(vals[1], k)[I[k]]) for k in 1:ndims(vals[1])), ",")
                    println(io, v.name, "[", labels, "]\t", join((x[I] for x in vals), "\t"))
                end
            end
        end
    end
end

gb() = round(Sys.maxrss() / 2^30; digits = 1)

function main(out, files)
    mkpath(out)
    runs = Any[]
    times = ["model\tbuild_s\tfirst_run_s\tlater_run_s\tmax_memory_gb"]
    for file in files
        name = first(splitext(basename(file)))
        mod = Module()
        Core.eval(mod, :(using PySD, DimensionalData))
        Core.eval(mod, :(include(p) = Base.include($mod, p)))
        t_build = @elapsed m = Base.include(mod, abspath(file))
        inputs = haskey(m.inputs, :parents) ? (; parents = Tuple(runs)) : (;)
        t_first = @elapsed r = run_model(m; inputs)
        t_later = @elapsed r = run_model(m; inputs)
        save(joinpath(out, name * "_results.tsv"), m, r)
        line = "$name\t$(round(t_build; digits = 1))\t$(round(t_first; digits = 1))\t$(round(t_later; digits = 2))\t$(gb())"
        println(replace(line, "\t" => "  ")); flush(stdout)
        push!(times, line)
        push!(runs, r)
    end
    write(joinpath(out, "julia_times.tsv"), join(times, "\n") * "\n")
end

main(ARGS[1], ARGS[2:end])
