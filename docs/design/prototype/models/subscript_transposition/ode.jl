# Model test_subscript_transposition — ODE style
module SubscriptTransposition

using ..Proto

# Subscripts
const sector = ["agriculture", "industry", "transport", "tourism", "comercial"]
const sector1 = sector

const control = Control(initial_time = 0, final_time = 1, time_step = 1)

params() = Params(
    input = [1, 10, 5, 7, 9],
    io_matrix = [ 1  2  3  4  5;
                 10 20 30 40 50;
                  1  2  3  4  5;
                  2  3  4  5  6;
                 -1  2 -3  4 -5],
)

initial_state(p) = State()

function model!(d, s, p, t)
    (; input, io_matrix) = p
    # output[sector1]  = SUM(input[sector!] * io matrix[sector!, sector1])
    output = [sum(input[i] * io_matrix[i, j] for i in eachindex(sector)) for j in eachindex(sector1)]
    # output2[sector1] = SUM(input[sector!] * io matrix[sector1, sector!])
    output2 = [sum(input[i] * io_matrix[j, i] for i in eachindex(sector)) for j in eachindex(sector1)]
    return (; output, output2)
end

end
