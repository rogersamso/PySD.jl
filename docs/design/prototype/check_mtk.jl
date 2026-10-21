# Run a prototype model (MTK style) and compare every reference column with it.
# usage: julia --project check_mtk.jl <model folder>
using PySD: pysd_tab_read_series
using ModelingToolkit, OrdinaryDiffEq

folder = ARGS[1]
t0 = time()
m = include(joinpath(@__DIR__, "models", folder, "mtk.jl"))
t_build = time() - t0

# reference outputs from SDXorg/test-models (PySD.jl submodule test/test-models)
test_models = get(ENV, "PYSD_TEST_MODELS", joinpath(@__DIR__, "..", "..", "..", "test", "test-models", "tests"))
ref_file = first(filter(isfile, joinpath.(test_models, folder, ["output.csv", "output.tab"])))
sep = endswith(ref_file, ".tab") ? '\t' : ','
ref = joinpath(mktempdir(), basename(ref_file))
write(ref, replace(read(ref_file, String), r"\r\n?" => "\n"))
raw_header = strip.(split(readline(ref), sep))
header = strip.(raw_header, '"')

labels = Dict{String,Int}()
for name in names(m; all = true)
    v = getfield(m, name)
    v isa Vector{String} && for (i, l) in enumerate(v)
        labels[lowercase(l)] = i
    end
end
julia_name(s) = Symbol(replace(lowercase(strip(s)), r"[^a-z0-9]+" => "_"))
const CONTROL = Set(["time", "initial time", "final time", "time step", "saveper"])

t0 = time()
prob = ODEProblem(m.sys, [], m.tspan)
sol = solve(prob, Euler(); dt = m.time_step, adaptive = false,
            saveat = m.tspan[1]:m.time_step:m.tspan[2])
t_run = time() - t0

"""Time series of a symbolic variable or parameter (element)."""
function series(sym)
    try
        return sol[sym]
    catch
        return fill(sol.ps[sym], length(sol.t))
    end
end

worst, missing, compared = 0.0, String[], 0
for (raw, col) in zip(raw_header[2:end], header[2:end])
    lowercase(col) in CONTROL && continue
    parts = split(col, "["; limit = 2)
    base, sub = parts[1], length(parts) > 1 ? parts[2] : ""
    key = julia_name(base)
    idx = isempty(sub) ? () : Tuple(labels[lowercase(strip(l))] for l in split(rstrip(sub, ']'), ","))
    isdefined(m, key) || (push!(missing, col); continue)
    v = getfield(m, key)
    # plain numbers are constants (symbolic Num is also <: Real, so test for floats)
    vals_julia = v isa AbstractArray{<:AbstractFloat} || v isa AbstractFloat ? fill(isempty(idx) ? v : v[idx...], length(sol.t)) :
                 series(isempty(idx) ? v : v[idx...])
    times, vals = pysd_tab_read_series(ref, raw)
    for (t, x) in zip(times, vals)
        isnan(x) && continue
        i = findfirst(y -> isapprox(y, t; atol = 1e-9), sol.t)
        i === nothing && continue
        global worst = max(worst, abs(vals_julia[i] - x) / max(abs(x), 1e-4))
        global compared += 1
    end
end
println(rpad(folder, 26), " mtk.jl: compared $compared values, worst relative error ",
        round(worst; sigdigits = 3), "; build ", round(t_build; digits = 1), " s, run ",
        round(t_run; digits = 1), " s", isempty(missing) ? "" : "; MISSING: $(join(missing, ", "))")
