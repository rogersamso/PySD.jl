# Model test_smooth — ODE style
module Smooth

using ..Proto
using PySD: pysd_step

const control = Control(initial_time = 0, final_time = 20, time_step = 0.25)

params() = Params(initial_value = 5)

# Time-dependent inputs
input(t) = -1 + pysd_step(t, 5, 5)
adjustment_time(t) = 2 + pysd_step(t, 2, 10)
variable_order(t) = 2 + pysd_step(t, 1, 10)

# SMOOTH N keeps the order it has at the initial time
const smooth_n_order = round(Int, variable_order(control.initial_time))

initial_state(p) = State(
    smooth    = smooth_initial(input(0)),
    smoothi   = smooth_initial(p.initial_value),
    smooth3   = smooth_initial(input(0), 3),
    smooth3i  = smooth_initial(p.initial_value, 3),
    smooth_n  = smooth_initial(p.initial_value, smooth_n_order),
)

function model!(d, s, p, t)
    x, τ = input(t), adjustment_time(t)
    smooth!(d.smooth,   s.smooth,   x, τ)
    smooth!(d.smoothi,  s.smoothi,  x, τ)
    smooth!(d.smooth3,  s.smooth3,  x, τ)
    smooth!(d.smooth3i, s.smooth3i, x, τ)
    smooth!(d.smooth_n, s.smooth_n, x, τ)
    return (;
        input = x, adjustment_time = τ, variable_order = variable_order(t),
        smooth_output = s.smooth[end], smoothi_output = s.smoothi[end],
        smooth3_output = s.smooth3[end], smooth3i_output = s.smooth3i[end],
        smooth_n_output = s.smooth_n[end],
    )
end

end
