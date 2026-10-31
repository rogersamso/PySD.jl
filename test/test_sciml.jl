# Models written with @equations, run with SciML's solvers (ext/PySDSciMLBaseExt.jl).
using OrdinaryDiffEqLowOrderRK: Euler, BS3, RK4
using SciMLBase: ODEProblem, solve

_close(a::Number, b::Number) = isapprox(a, b; rtol = 1e-10, atol = 1e-12)
_close(a::AbstractArray, b::AbstractArray) = size(a) == size(b) && all(_close(x, y) for (x, y) in zip(a, b))

@testset "DSL: SciML solvers" begin
    # Euler's steps of Δt are Vensim's: the same values as run_model's
    for name in ("teacup", "arrays", "subscripted_delays", "sample_if_true")
        m = _dsl(name)
        own, sciml = run_model(m), run_model(m, Euler())
        @test sciml.time ≈ own.time
        @test all(k -> _close(own[k], sciml[k]), keys(own))
    end
    # an adaptive solver solves the ODE itself: the teacup's exponential cooling
    m = _dsl("teacup")
    r = run_model(m, BS3(); abstol = 1e-10, reltol = 1e-10)
    @test r[:teacup_temperature] ≈ 70 .+ 110 .* exp.(-r.time ./ 10) rtol = 1e-7
    # parameters and inputs as run_model's; derivatives through the solver
    final(R) = run_model(m, Euler(); params = (; room_temperature = R))[:teacup_temperature][end]
    @test final(60.0) ≈ run_model(m; params = (; room_temperature = 60.0))[:teacup_temperature][end]
    @test derivative(final, 70.0) ≈ 1 - (1 - 0.125 / 10)^240 rtol = 1e-10
    # the problem itself, for what run_model doesn't do (callbacks, ensembles, …)
    prob = ODEProblem(m; params = (; characteristic_time = 5))
    sol = solve(prob, Euler(); dt = 0.125)
    res = Results(m, sol)
    @test res[:teacup_temperature][end] ≈ run_model(m; params = (; characteristic_time = 5))[:teacup_temperature][end]
    @test res[:characteristic_time] == 5
    @test_logs run_model(_dsl("sample_if_true"), Euler())
end

@testset "DSL: fixed delays and samples with SciML solvers" begin
    # Euler's steps of Δt: the same values as run_model's, to the last digit
    m = _dsl("delay_fixed")
    own = run_model(m)
    sciml = @test_logs run_model(m, Euler())
    @test all(k -> own[k] == sciml[k], keys(own))
    s = _dsl("sample_if_true")
    own = run_model(s)
    sciml = run_model(s, Euler())
    @test all(k -> own[k] == sciml[k], keys(own))
    # they move at the model's ticks, whatever the solver: inputs of time
    # alone give exactly run_model's values under any solver, at any step
    for (alg, kw) in ((BS3(), (;)), (RK4(), (;)), (Euler(), (; dt = m.dt / 2)))
        for model in (m, s)
            own, other = run_model(model), run_model(model, alg; kw...)
            @test other.time == own.time
            @test all(k -> other[k] == own[k], keys(own))
        end
    end
    # a solution read afterwards: at the ticks, run_model's values; between, the last tick's
    sol = solve(ODEProblem(m), BS3(); saveat = [3.0, 3.5, 4.0])
    @test Results(m, sol)[:df1] == [4.0, 4.0, 9.0]                # time_squared(t - 1)
end

@testset "DSL: stocks around fixed delays and samples, with any solver" begin
    # Δt = 0.5: a stock fed by a fixed delay, a capital that a sample spends from
    c = _dsl("clock")
    own = run_model(c)
    @test all(k -> run_model(c, Euler())[k] == own[k], keys(own))
    # finer or better steps converge on one answer (the model with ticks every Δt)
    exact = run_model(c, BS3(); reltol = 1e-11, abstol = 1e-13)
    @test exact[:arrivals] == own[:arrivals]                 # the delay: still whole ticks
    @test run_model(c, RK4(); reltol = 1e-11, abstol = 1e-13)[:capital] ≈ exact[:capital] rtol = 1e-8
    err(r) = maximum(abs, r[:stock] .- exact[:stock]) + maximum(abs, r[:capital] .- exact[:capital])
    errs = [err(run_model(c, Euler(); dt = c.dt / k)) for k in (1, 2, 4, 8)]
    @test issorted(errs; rev = true) && errs[end] < errs[1] / 4
    @test err(run_model(c, RK4(); adaptive = false)) < errs[end]
    # the stock at 3.5, a step after the delayed orders arrive
    @test exact[:stock][findfirst(==(3.5), exact.time)] ≈ 0.4424 atol = 1e-4
end
