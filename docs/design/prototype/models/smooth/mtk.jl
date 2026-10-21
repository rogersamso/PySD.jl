# Model test_smooth — MTK style
module Smooth_MTK

using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D
import PySD: pysd_step
@register_symbolic pysd_step(t, height, step_time)

"""Equations of an N-stage SMOOTH whose stage levels are `s` (output: s[end])."""
smooth_equations(s, input, delay_time) = Equation[
    D(s[1]) ~ (input - s[1]) * length(s) / delay_time;
    [D(s[k]) ~ (s[k-1] - s[k]) * length(s) / delay_time for k in 2:length(s)]
]

const initial_value = 5.0
@variables begin
    input(t)
    adjustment_time(t)
    variable_order(t)
    smooth(t)[1:1] = fill(-1.0, 1)
    smoothi(t)[1:1] = fill(initial_value, 1)
    smooth3(t)[1:3] = fill(-1.0, 3)
    smooth3i(t)[1:3] = fill(initial_value, 3)
    smooth_n(t)[1:2] = fill(initial_value, 2)   # SMOOTH N keeps its initial order (2)
    smooth_output(t)
    smoothi_output(t)
    smooth3_output(t)
    smooth3i_output(t)
    smooth_n_output(t)
end

equations = Equation[
    input ~ -1 + pysd_step(t, 5, 5)
    adjustment_time ~ 2 + pysd_step(t, 2, 10)
    variable_order ~ 2 + pysd_step(t, 1, 10)
    smooth_equations(smooth, input, adjustment_time)
    smooth_equations(smoothi, input, adjustment_time)
    smooth_equations(smooth3, input, adjustment_time)
    smooth_equations(smooth3i, input, adjustment_time)
    smooth_equations(smooth_n, input, adjustment_time)
    smooth_output ~ smooth[end]
    smoothi_output ~ smoothi[end]
    smooth3_output ~ smooth3[end]
    smooth3i_output ~ smooth3i[end]
    smooth_n_output ~ smooth_n[end]
]

@mtkcompile sys = System(equations, t)

const tspan = (0.0, 20.0)
const time_step = 0.25

end
