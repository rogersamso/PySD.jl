# Run a prototype model (ODE style) and compare every reference column with it.
# usage: julia --project check.jl <model folder> [<file>]
using PySD: pysd_tab_read_series

include(joinpath(@__DIR__, "Proto.jl"))
using .Proto

folder = ARGS[1]
file = length(ARGS) > 1 ? ARGS[2] : "ode.jl"
m = include(joinpath(@__DIR__, "models", folder, file))

# reference outputs from SDXorg/test-models (PySD.jl submodule test/test-models)
test_models = get(ENV, "PYSD_TEST_MODELS", joinpath(@__DIR__, "..", "..", "..", "test", "test-models", "tests"))
ref_file = first(filter(isfile, joinpath.(test_models, folder, ["output.csv", "output.tab"])))
sep = endswith(ref_file, ".tab") ? '\t' : ','
# many Vensim outputs use old Mac line endings (\r only): normalise to \n
ref = joinpath(mktempdir(), basename(ref_file))
write(ref, replace(read(ref_file, String), r"\r\n?" => "\n"))
raw_header = strip.(split(readline(ref), sep))
header = strip.(raw_header, '"')

# subscript labels -> position, from the model's label lists
labels = Dict{String,Int}()
for name in names(m; all = true)
    v = getfield(m, name)
    v isa Vector{String} && for (i, l) in enumerate(v)
        labels[lowercase(l)] = i
    end
end
julia_name(s) = Symbol(replace(lowercase(strip(s)), r"[^a-z0-9]+" => "_"))
const CONTROL = Set(["time", "initial time", "final time", "time step", "saveper"])

sol = run_model(m)
res = results(m, sol)
worst, missing, compared = 0.0, String[], 0
for (raw, col) in zip(raw_header[2:end], header[2:end])
    lowercase(col) in CONTROL && continue
    parts = split(col, "["; limit = 2)
    base, sub = parts[1], length(parts) > 1 ? parts[2] : ""
    key = julia_name(base)
    idx = isempty(sub) ? () : Tuple(labels[lowercase(strip(l))] for l in split(rstrip(sub, ']'), ","))
    haskey(res[1], key) || (push!(missing, col); continue)
    times, vals = pysd_tab_read_series(ref, raw)
    for (t, v) in zip(times, vals)
        isnan(v) && continue
        i = findfirst(x -> isapprox(x, t; atol = 1e-9), sol.t)
        i === nothing && continue
        got = res[i][key]
        got = isempty(idx) ? got[] : got[idx...]
        global worst = max(worst, abs(got - v) / max(abs(v), 1e-4))
        global compared += 1
    end
end
println(rpad(folder, 26), " ", file, ": compared $compared values, worst relative error ",
        round(worst; sigdigits = 3), isempty(missing) ? "" : "; MISSING: $(join(missing, ", "))")
