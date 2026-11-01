# Fixed delays and samples of models translated with PySD's ODE backend: values
# recorded at the model's ticks (src/ticks.jl), with any solver.
using OrdinaryDiffEqLowOrderRK: Euler, BS3, RK4
using SciMLBase: ODEProblem, solve

@testset "Ticks: records" begin
    T = PySDTicks(0.0, 0.5)
    # before a run: the initial values
    @test pysd_fixed_delay(T, 1, 2, 7.0, 3.0) == 7.0
    @test pysd_sampled(T, 2, true, 1.0, 7.0, 3.0) == 7.0
    for (k, t) in enumerate(0:0.5:2)
        pysd_begin_tick!(T, t)
        # at a tick: the sample's rule, from the tick before
        @test pysd_sampled(T, 2, isodd(k), 10.0 * k, 0.0, t) == (isodd(k) ? 10.0 * k : 10.0 * (k - 1))
        pysd_record!(T, 1, [t, -t])
        pysd_record!(T, 2, isodd(k) ? 10.0 * k : 10.0 * (k - 1))
        pysd_end_tick!(T)
    end
    pysd_free_ticks!(T)
    # afterwards, by time: the last tick at or before it
    @test pysd_fixed_delay(T, 1, 2, [9.0, 9.0], 1.7) == [0.5, -0.5]     # tick 3, input of tick 1
    @test pysd_fixed_delay(T, 1, 2, 9.0, 1.7, 2) == -0.5                 # an element
    @test pysd_fixed_delay(T, 1, 2, 9.0, 0.9, 2) == 9.0                  # tick 1: before the first two
    @test pysd_sampled(T, 2, false, 0.0, 0.0, 1.2) == 30.0               # held from tick 2
    @test pysd_sampled(T, 2, false, 0.0, 0.0, 1.0) == 30.0
    pysd_reset_ticks!(T)
    @test isempty(T.records) && isempty(T.times)
    # an initial value that changes (the input itself): its value at the first tick
    pysd_begin_tick!(T, 0.0)
    @test pysd_fixed_delay(T, 3, 2, 5.0, 0.0) == 5.0
    pysd_record!(T, 3, 5.0)
    pysd_end_tick!(T)
    pysd_begin_tick!(T, 0.5)
    @test pysd_fixed_delay(T, 3, 2, 6.0, 0.5) == 5.0
    pysd_record!(T, 3, 6.0)
    pysd_end_tick!(T)
    pysd_free_ticks!(T)
    @test pysd_fixed_delay(T, 3, 2, 7.0, 0.5) == 5.0
end

@testset "Ticks: a translated ODE model, with any solver" begin
    # what PySD's ODE backend writes, by hand: Δt = 0.5; orders arrive 2 later;
    # a capital spends a fifth of itself every 2 years
    T = PySDTicks(0.0, 0.5)
    function model(u, t)
        orders = t >= 1 ? 1.0 : 0.0
        arrivals = pysd_fixed_delay(T, 1, 4, 0.0, t)
        spending = pysd_sampled(T, 2, isapprox(rem(t, 2), 0; atol = 1e-9), 0.2 * u[2], 0.0, t)
        return (; orders, arrivals, spending)
    end
    function rhs!(du, u, p, t)
        v = model(u, t)
        du[1] = v.arrivals - u[1] / 2
        du[2] = 0.25 * u[2] - v.spending
    end
    record!(u, t) = (v = model(u, t); pysd_record!(T, 1, v.orders); pysd_record!(T, 2, v.spending))
    run(alg; kw...) = (sol = solve(ODEProblem(rhs!, [0.0, 1.0], (0.0, 10.0)), alg;
                                   callback = pysd_ticks_callback(T, record!; t_final = 10.0), kw...);
                       pysd_free_ticks!(T); sol)
    # Euler steps of Δt, written out as Vensim does them
    function vensim()
        u, out = [0.0, 1.0], Vector{Float64}[]
        Tv = PySDTicks(0.0, 0.5)
        for k in 0:20
            t = 0.5k
            orders = t >= 1 ? 1.0 : 0.0
            arrivals = k >= 4 ? (0.5(k - 4) >= 1 ? 1.0 : 0.0) : 0.0
            spending = rem(t, 2) == 0 ? 0.2 * u[2] : (isempty(out) ? 0.0 : out[end][3])
            push!(out, [u[1], u[2], spending, arrivals])
            u = u .+ 0.5 .* [arrivals - u[1] / 2, 0.25 * u[2] - spending]
        end
        return out
    end
    ref = vensim()
    sol = run(Euler(); dt = 0.5)
    @test sol.t ≈ 0:0.5:10
    @test [u[1] for u in sol.u] ≈ [r[1] for r in ref] rtol = 1e-12
    @test [u[2] for u in sol.u] ≈ [r[2] for r in ref] rtol = 1e-12
    @test [model(u, t).spending for (u, t) in zip(sol.u, sol.t)] ≈ [r[3] for r in ref] rtol = 1e-12
    # other solvers: the arrivals are still whole ticks, and the stocks converge
    arrivals_of(sol) = [model(u, t).arrivals for (u, t) in zip(sol.u, sol.t) if isinteger(2t)]
    exact = run(BS3(); reltol = 1e-11, abstol = 1e-13, saveat = 0:0.5:10)
    @test arrivals_of(exact) == [r[4] for r in ref]
    err(sol) = maximum(abs, [u[1] for u in sol.u] .- [u[1] for u in exact.u]) +
               maximum(abs, [u[2] for u in sol.u] .- [u[2] for u in exact.u])
    errs = [err(run(Euler(); dt = 0.5 / k, saveat = 0:0.5:10)) for k in (1, 2, 4)]
    @test issorted(errs; rev = true) && errs[3] < errs[1] / 3
    @test err(run(RK4(); dt = 0.5, adaptive = false)) < errs[3]
    # the stock at 3.5, a step after the orders arrive (as the DSL's clock example)
    @test exact.u[8][1] ≈ 0.4424 atol = 1e-4
end
