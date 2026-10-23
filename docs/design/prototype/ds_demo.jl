# DynamicalSystems.jl with a model in the cleaner ODE style, parameters in `p`.
using ComponentArrays, OrdinaryDiffEq, DynamicalSystemsBase

# --- the model (parameters as a named block, unpacked at the top of model!) ---
const params = ComponentArray(growth = 0.001, weight = collect(1.0:50.0))

function model!(d, s, p, t)
    (; growth, weight) = p
    stock = s.stock
    inflow = growth .* stock .* weight' ./ sum(weight)
    d.stock .= inflow
    return (; inflow, total = sum(stock))
end

u0 = ComponentArray(stock = ones(200, 50))
# CoupledODEs stores the state as a plain array: view it with the named layout again (no copy)
const AXES = getaxes(u0)
rule!(d, s, p, t) = (model!(ComponentArray(d, AXES), ComponentArray(s, AXES), p, t); nothing)

# --- as a DynamicalSystem: same solver as Vensim (Euler, fixed step) ---
ds = CoupledODEs(rule!, u0, copy(params); diffeq = (alg = Euler(), dt = 0.25, adaptive = false))

step!(ds, 50.0, true)                                  # run to t = 50
println("t = ", current_time(ds), ", total = ", round(sum(current_state(ds)); digits = 3))

set_parameter!(ds, :growth, 0.01)                      # change a parameter mid-run (a scenario switch)
step!(ds, 50.0, true)                                  # continue to t = 100
println("t = ", current_time(ds), ", total = ", round(sum(current_state(ds)); digits = 3),
        " (growth 0.01 from t = 50)")

saved = copy(current_state(ds))                        # export / import of the state
reinit!(ds, saved; t0 = 100.0)
println("restarted at t = ", current_time(ds), " from the saved state, total = ",
        round(sum(current_state(ds)); digits = 3))

# reference without the switch, for comparison
reinit!(ds, u0; t0 = 0.0); set_parameter!(ds, :growth, 0.001); step!(ds, 100.0, true)
println("no switch: t = ", current_time(ds), ", total = ", round(sum(current_state(ds)); digits = 3))
