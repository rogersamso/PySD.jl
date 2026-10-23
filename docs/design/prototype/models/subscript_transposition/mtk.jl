# Model test_subscript_transposition — MTK style
module SubscriptTransposition_MTK

using ModelingToolkit
using ModelingToolkit: t_nounits as t

# Subscripts
const sector = ["agriculture", "industry", "transport", "tourism", "comercial"]
const sector1 = sector

@parameters begin
    input[1:5] = [1.0, 10.0, 5.0, 7.0, 9.0]
    io_matrix[1:5, 1:5] = [ 1.0  2.0  3.0  4.0  5.0;
                           10.0 20.0 30.0 40.0 50.0;
                            1.0  2.0  3.0  4.0  5.0;
                            2.0  3.0  4.0  5.0  6.0;
                           -1.0  2.0 -3.0  4.0 -5.0]
end
@variables output(t)[1:5] output2(t)[1:5]

equations = [
    output ~ io_matrix' * input     # SUM(input[sector!] * io matrix[sector!, sector1])
    output2 ~ io_matrix * input     # SUM(input[sector!] * io matrix[sector1, sector!])
]

@mtkcompile sys = System(equations, t)

const tspan = (0.0, 1.0)
const time_step = 1.0

end
