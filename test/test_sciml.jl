# Models written with @equations, run with SciML's solvers (ext/PySDSciMLBaseExt.jl).
using OrdinaryDiffEqLowOrderRK: Euler, BS3
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
    # operators that move by whole steps of Δt: other solvers warn
    @test_logs (:warn, r"fixed delays or sample_if_true") run_model(_dsl("sample_if_true"), BS3())
    @test_logs run_model(_dsl("sample_if_true"), Euler())
end
