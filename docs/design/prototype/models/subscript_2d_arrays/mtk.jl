# Model test_subscript_2d_arrays — MTK style
module SubscriptArrays2D_MTK

using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D

# Subscripts
const one_dimensional_subscript = ["Entry 1", "Entry 2", "Entry 3"]
const second_dimension_subscript = ["Column 1", "Column 2"]

const initial_values = [1.0 2.0; 3.0 4.0; 5.0 6.0]

@parameters rate_a[1:3, 1:2] = [0.01 0.02; 0.03 0.04; 0.05 0.06]
@variables begin
    stock_a(t)[1:3, 1:2] = initial_values
    inflow_a(t)[1:3, 1:2]
end

equations = [
    inflow_a ~ rate_a
    D(stock_a) ~ inflow_a
]

@mtkcompile sys = System(equations, t)

const tspan = (0.0, 100.0)
const time_step = 1.0

end
