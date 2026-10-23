# Model test_subscript_2d_arrays — ODE style
module SubscriptArrays2D

using ..Proto

# Subscripts
const one_dimensional_subscript = ["Entry 1", "Entry 2", "Entry 3"]
const second_dimension_subscript = ["Column 1", "Column 2"]

const control = Control(initial_time = 0, final_time = 100, time_step = 1)

params() = Params(
    initial_values = [1 2; 3 4; 5 6],
    rate_a = [0.01 0.02; 0.03 0.04; 0.05 0.06],
)

initial_state(p) = State(stock_a = p.initial_values)

function model!(d, s, p, t)
    (; rate_a) = p
    inflow_a = rate_a
    d.stock_a .= inflow_a
    return (; inflow_a)
end

end
