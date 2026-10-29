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

@testset "DSL: fixed delays and samples with SciML solvers" begin
    # Euler's steps of Δt: the same values as run_model's, to the last digit
    m = _dsl("delay_fixed")
    own = run_model(m)
    sciml = @test_logs run_model(m, Euler())
    @test all(k -> own[k] == sciml[k], keys(own))
    # other solvers: continuous time; a delay of t² is (t - τ)², and its initial value before τ
    r = @test_logs (:warn, r"continuous time") run_model(m, BS3(); dtmax = 0.01)
    @test r[:df12][3:end] ≈ (r.time[3:end] .- 1.2) .^ 2 atol = 1e-4
    @test r[:df12][1:2] == [-4, -4]
    @test r[:df37][end] ≈ (50 - 3.7)^2 atol = 1e-4

    # samples at an instant, and up to one: Vensim's steps never see t == 2.3
    # (the last step before it, 2.0, for t < 2.3); other solvers stop at 2.3,
    # and at the year of each run's parameters
    s = Base.include_string(_module(), """
        Model(@equations(begin
            @parameters begin
                year = 2.3, [unit = u"s"]
            end
            @variables begin
                x(t), [unit = u"s^2"]
                at_year(t), [unit = u"s^2"]
                before_year(t), [unit = u"s^2"]
            end
            x ~ t^2
            at_year ~ sample_if_true(t == year, x; init = 0)
            before_year ~ sample_if_true(t < year, x; init = 0)
        end); time = 0:0.5:5, time_unit = u"s")
        """)
    r = run_model(s)
    @test r[:at_year][end] == 0 && r[:before_year][end] == 4
    @test run_model(s, Euler())[:before_year] == r[:before_year]
    r = @test_logs (:warn, r"continuous time") run_model(s, BS3())
    @test r[:at_year][end] ≈ 2.3^2 && r[:before_year][end] ≈ 2.3^2
    r = @test_logs (:warn,) run_model(s, BS3(); params = (; year = 4.1))
    @test r[:at_year][end] ≈ 4.1^2 && r[:before_year][end] ≈ 4.1^2

    # Euler at smaller steps tends to the continuous-time solution
    c = Base.include_string(_module(), """
        Model(@equations(begin
            @variables begin
                x(t), [unit = NoUnits]
                late(t), [unit = NoUnits]
                held(t), [unit = NoUnits]
                total(t), [unit = u"s"]
            end
            x ~ sin(t)
            late ~ x(t - 1.5; init = 0)
            held ~ sample_if_true(t < 3.3, x; init = 0)
            ∂t(total) ~ late + held
            total(t₀) ~ 0
        end); time = 0:0.5:10, time_unit = u"s")
        """)
    exact = (@test_logs (:warn,) run_model(c, BS3(); reltol = 1e-10, abstol = 1e-10, dtmax = 0.01))[:total]
    errs = [maximum(abs.((@test_logs (:warn,) run_model(c, Euler(); dt = 0.5 / 2^k))[:total] .- exact)) for k in 1:4]
    @test all(errs[2:end] .< 0.6 .* errs[1:end-1])
    @test errs[end] < 0.05 * maximum(abs, exact)
end
