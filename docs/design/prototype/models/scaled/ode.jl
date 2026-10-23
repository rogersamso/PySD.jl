# Synthetic 200 x 50 model — ODE style
module Scaled

using ..Proto

const A = ["a$i" for i in 1:200]
const B = ["b$i" for i in 1:50]

const control = Control(initial_time = 0, final_time = 100, time_step = 0.25, saveper = 1)

params() = Params(growth = 0.001, weight = 1:50)

initial_state(p) = State(stock = ones(length(A), length(B)))

function model!(d, s, p, t)
    (; growth, weight) = p
    stock = s.stock
    inflow = growth .* stock .* weight' ./ sum(weight)    # inflow[A, B] = growth * stock[A, B] * weight[B] / SUM(weight[B!])
    d.stock .= inflow
    return (; inflow, total = sum(stock))
end

end
