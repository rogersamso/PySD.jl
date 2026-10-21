# Current generated ODE code vs the cleaner ODE style on the synthetic 200 x 50 model.
using BenchmarkTools, OrdinaryDiffEq
include(joinpath(@__DIR__, "Proto.jl"))
using .Proto

gen_file = ARGS[1]
module Generated end
Base.include(Generated, gen_file)
clean = include(joinpath(@__DIR__, "models", "scaled", "ode.jl"))

# same results?
sol_g = Generated.run_model()
sol_c = run_model(clean)
total_g = sum(sol_g.u[end])
total_c = sum(sol_c.u[end])
println("final total: generated ", total_g, ", clean ", total_c,
        ", relative difference ", abs(total_g - total_c) / abs(total_c))

# one evaluation of the equations (rhs!)
u_g, du_g = copy(sol_g.prob.u0), similar(sol_g.prob.u0)
p_c = clean.params()
u_c = clean.initial_state(p_c); du_c = similar(u_c)
f_c = Proto.rhs!(clean)
b_rhs_g = @benchmark Generated.rhs!($du_g, $u_g, nothing, 1.0)
b_rhs_c = @benchmark $f_c($du_c, $u_c, $p_c, 1.0)

# whole simulation (400 Euler steps)
b_run_g = @benchmark Generated.run_model()
b_run_c = @benchmark run_model($clean)

fmt(b) = string(round(median(b).time / 1e6; digits = 3), " ms, ", round(median(b).memory / 2^20; digits = 2), " MiB")
println("rhs!   generated: ", fmt(b_rhs_g), " | clean: ", fmt(b_rhs_c))
println("run    generated: ", fmt(b_run_g), " | clean: ", fmt(b_run_c))
