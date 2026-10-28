# The DSL: @equations and Model, checked against Vensim's outputs
# (SDXorg/test-models) and on the mistakes Model must catch.
using DimensionalData: Dim, At, AbstractDimArray, DimArray, broadcast_dims
using PySD: pysd_exp, pysd_ln, pysd_power, pysd_sin, pysd_sum, pysd_sum_seq
using LinearAlgebra: I
include(joinpath(@__DIR__, "dsl", "check.jl"))

function _module()
    mod = Module()
    Core.eval(mod, :(using PySD, DimensionalData))
    return mod
end
_dsl(name) = Base.include(_module(), joinpath(@__DIR__, "dsl", name * ".jl"))

@testset "DSL: Vensim's results" begin
    # floor: relative errors at least to it, where Vensim's single-precision
    # arithmetic leaves about -4e-6 in a stock that should be zero
    for (model, ref, tol, floor) in [("teacup", "samples/teacup/output.csv", 1e-5, 1e-6),
                                     ("subscript_2d_arrays", "tests/subscript_2d_arrays/output.tab", 1e-5, 1e-6),
                                     ("subscript_transposition", "tests/subscript_transposition/output.tab", 1e-12, 1e-6),
                                     ("smooth", "tests/smooth/output.tab", 1e-5, 1e-6),
                                     ("subscripted_smooth", "tests/subscripted_smooth/output.tab", 1e-5, 1e-6),
                                     ("subscripted_trend", "tests/subscripted_trend/output.tab", 1e-4, 1e-6),
                                     ("subscripted_delays", "tests/subscripted_delays/output.tab", 1e-5, 1.0),
                                     ("delay_fixed", "tests/delay_fixed/output.tab", 1e-12, 1e-6),
                                     ("sample_if_true", "tests/sample_if_true/output.tab", 1e-5, 1e-6)]
        m = _dsl(model)
        res = run_model(m)
        if HAS_TEST_MODELS
            r = compare_reference(res, joinpath(TEST_MODELS, "..", ref); floor,
                                  renames = Dict(:delay => :delay_time))      # `delay` is the function
            @test r.compared > 0
            @test isempty(r.missing)
            @test r.worst < tol
        end
    end
end

@testset "DSL: Excel inputs, Vensim's results" begin
    # 1 + sin(11) and the like cancel to about 1e-5 in Vensim's arithmetic: relative
    # errors at least to 1e-3 there (absolute differences of 1e-8)
    for (model, folder, floor, tol) in [("get_xls_cellrange", "get_xls_cellrange", 1e-6, 1e-12),
                                        ("get_lookups_subscripted_args", "get_lookups_subscripted_args", 1e-3, 1e-4)]
        HAS_TEST_MODELS || continue
        mod = _module()
        dir = joinpath(TEST_MODELS, folder)
        Core.eval(mod, :(const INPUTS = $dir))
        m = Base.include(mod, joinpath(@__DIR__, "dsl", model * ".jl"))
        ref = first(f for f in readdir(dir; join = true) if endswith(f, ".tab"))
        r = compare_reference(run_model(m), ref; floor)
        @test r.compared > 100
        @test isempty(r.missing)
        @test r.worst < tol
    end
    if HAS_TEST_MODELS
        # anything callable replaces a lookup between runs; a constant is a number
        mod = _module()
        Core.eval(mod, :(const INPUTS = $(joinpath(TEST_MODELS, "get_xls_cellrange"))))
        m = Base.include(mod, joinpath(@__DIR__, "dsl", "get_xls_cellrange.jl"))
        base = run_model(m)
        changed = run_model(m; params = (; lookup1 = x -> 0.0, data1 = t -> 1.0))
        @test changed[:final1][end] == base[:value1] .+ 10
        @test changed[:final2] == base[:final2]
    end
end

@testset "DSL: components, connections, dispatch" begin
    mod = _module()
    Base.include(mod, joinpath(@__DIR__, "dsl", "beer_game.jl"))
    anchoring = run_model(mod.beer_game())
    up_to = run_model(mod.beer_game(; rule = mod.OrderUpTo()))
    orders(r) = maximum(r[Symbol("factory.orders_placed")])
    @test orders(up_to) > orders(anchoring) > 8          # the bullwhip effect, stronger ordering the whole gap
    @test minimum(anchoring[Symbol("retailer.inventory")]) >= 0
    alone = run_model(Model(mod.stage(; name = :alone); time = 0:1:52, time_unit = u"wk"))
    @test all(==(12), alone[Symbol("alone.inventory")])  # inputs not connected: their defaults
end

# the model in `body`, built, or the message of the error it gives
function _build(body)
    mod = Module()
    Core.eval(mod, :(using PySD))
    Core.eval(mod, :(const d = $(Dim{:d}([:a, :b, :c]))))
    try
        Core.eval(mod, Meta.parse("Model(@equations begin\n$body\nend; time = 0:1:10, time_unit = u\"s\")"))
    catch e
        e isa LoadError && (e = e.error)
        return sprint(showerror, e)
    end
end

@testset "DSL: mistakes Model catches" begin
    stock(eqs) = """@variables begin
                        x(t), [unit = u"m"]
                        y(t), [unit = u"m/s"]
                    end
                    $eqs"""
    @test _build(stock("∂t(x) ~ y\nx(t₀) ~ 1\ny ~ 2")) isa Model
    @test occursin("has no unit", _build("""@variables begin
                                               x(t), [description = "no unit"]
                                           end
                                           x ~ 1"""))
    @test occursin("has no metadata", _build("""@variables begin
                                                  x(t)
                                              end
                                              x ~ 1"""))
    @test occursin("`z` is not declared", _build(stock("∂t(x) ~ y\nx(t₀) ~ 1\ny ~ z")))
    @test occursin("no initial value", _build(stock("∂t(x) ~ y\ny ~ 2")))
    @test occursin("has no equation", _build(stock("∂t(x) ~ y\nx(t₀) ~ 1")))
    @test occursin("algebraic loop: ", _build("""@variables begin
                                                   a(t), [unit = NoUnits]
                                                   b(t), [unit = NoUnits]
                                               end
                                               a ~ b + 1
                                               b ~ 2a"""))
    @test occursin("is a parameter", _build("""@parameters begin
                                                 k = 1, [unit = NoUnits]
                                             end
                                             k ~ 2"""))
    @test occursin("depends on time", _build("""@variables begin
                                                    c, [unit = NoUnits]
                                                end
                                                c ~ t"""))
    parts(eqs) = """@variables begin
                        x[d], [unit = NoUnits]
                    end
                    $eqs"""
    @test _build(parts("x[d = At(:a)] ~ 1\nx[d = Not(At(:a))] ~ 2")) isa Model
    @test occursin("overlap", _build(parts("x[d = At(:a)] ~ 1\nx ~ 2")))
    @test occursin("don't cover", _build(parts("x[d = At(:a)] ~ 1")))
    # a fixed delay's steps are counted when the model is built: its delay time,
    # or what it depends on, can't change between runs; other parameters can
    m = _build("""@parameters begin
                      k = 2, [unit = u"s"]
                      g = 1, [unit = NoUnits]
                  end
                  @variables begin
                      τ, [unit = u"s"]
                      x(t), [unit = u"s"]
                      y(t), [unit = u"s"]
                  end
                  τ ~ 2k
                  x ~ g * t
                  y ~ x(t - τ; init = 0)""")
    @test m isa Model
    @test occursin("`k` can't change between runs", try run_model(m; params = (; k = 3)); "" catch e; sprint(showerror, e) end)
    @test run_model(m; params = (; g = 2))[:x][end] == 20
end

@testset "DSL: arrays on plain arrays" begin
    mod = _module()
    m = Base.include(mod, joinpath(@__DIR__, "dsl", "arrays.jl"))
    r = run_model(m)
    a, a1, b, years = mod.a, mod.a1, mod.b, mod.years
    M = DimArray([0.1 0.2 0.0; 0.0 0.1 0.3; 0.2 0.0 0.1], (a, a1))
    v = DimArray([1.0, 2.0, 3.0], a)
    w = DimArray([1.0, 2.0], b)
    flow = broadcast_dims(*, w, v) .* 0.1                      # (b, a)
    @test r[:flow][end] == flow
    # the stock grows by the flow, laid out in its own order (a, b)
    @test r[:s][end] ≈ 1 .+ 2 .* permutedims(flow, (a, b))
    @test parent(r[:leontief]) ≈ inv(I - parent(M))
    @test parent(r[:ia][1]) ≈ I - parent(M)
    @test parent(r[:inverse][1]) ≈ inv(I - parent(M))
    @test parent(r[:product][1]) ≈ inv(I - parent(M)) * parent(v)
    @test parent(r[:shifted][1]) == [0.0, 1.0, 2.0]
    @test r[:pick] == [3.0, 3.0, 6.0, 6.0, 9.0]              # the year changes at t = 1 and t = 2
    @test parent(r[:part][1]) == [1.0, 4.0, 6.0]
    @test parent(r[:notx][1]) == [6.0, 0.0, 0.0]
    @test r[:total][end] ≈ sum(r[:s][end])
    @test parent(r[:swapped][1]) == parent(M)                 # renamed, not transposed
    # nothing allocated at each step, but by inv (LAPACK needs a copy and a factorization)
    src = read(joinpath(@__DIR__, "dsl", "arrays.jl"), String)
    src = replace(src, r"\n    inverse ~ [^\n]*" => "", r"\n        inverse\(t\)[^\n]*" => "")
    m2 = Base.include_string(_module(), src)
    p = PySD._runparams(m2)
    u = m2.init(p); du = similar(u)
    # (the step function itself, from the newest world: Julia's, after the model was built)
    allocs(f::F, du, u, p) where {F} = (f(du, u, p, 0.0); @allocated f(du, u, p, 0.0))
    @test Base.invokelatest(allocs, m2.rhs!.f, du, u, p) == 0
    # operators of arrays: their hidden stocks element by element, nothing allocated either
    for name in ("subscripted_smooth", "subscripted_delays", "sample_if_true")
        m3 = _dsl(name)
        p = PySD._runparams(m3)
        u = m3.init(p); du = similar(u)
        @test Base.invokelatest(allocs, m3.rhs!.f, du, u, p) == 0
    end
end

@testset "DSL: Python's digits or Julia's" begin
    mod = _module()
    Base.include(mod, joinpath(@__DIR__, "dsl", "numerics.jl"))
    py = run_model(Model(mod.numerics_example; time = 0:0.5:1, time_unit = u"s", numerics = :python))
    jl = run_model(Model(mod.numerics_example; time = 0:0.5:1, time_unit = u"s"))
    x0 = collect(range(0.1, 3.0; length = 200))
    x = x0 .+ 1.0                                                  # x .+ t at t = 1
    @test parent(py[:e][end]) == pysd_exp.(x)                      # the C maths library
    @test parent(jl[:e][end]) == exp.(x)                           # Julia's
    @test parent(py[:e][end]) != parent(jl[:e][end])               # they differ in the last digit, sometimes
    @test parent(py[:l][end]) == pysd_ln.(x)
    @test parent(py[:p][end]) == pysd_power.(x, 1.7)
    @test parent(py[:s][end]) == pysd_sin.(x0 .* 3 .+ 1)
    # numpy's order of additions: pairwise along the last dimension, one after the other along others
    M = [pysd_sin(a * b) for a in 1:3, b in 1:200] .* 2
    @test parent(py[:sum_last][end]) == [pysd_sum(M[i, :]) for i in 1:3]
    @test parent(py[:sum_first][end]) == [pysd_sum_seq(M[:, c]) for c in 1:200]
    @test py[:total][end] == pysd_sum(x0 .* 2)
    @test parent(py[:inverse_once]) == PySD._numpy_inv([2.0 0.3 0.1; 0.2 3.0 0.4; 0.1 0.5 4.0])
end

@testset "DSL: check_units" begin
    m = _dsl("units")
    issues = check_units(m)
    wrong = sort(unique(i.name for i in issues))
    @test wrong == [:wrong_choice, :wrong_energy, :wrong_growth, :wrong_smoothed, :wrong_total]
    msg(name) = only(i.message for i in issues if i.name === name)
    @test occursin("needs a conversion factor", msg(:wrong_total))
    @test occursin("∂t(wrong_energy) is in EJ", msg(:wrong_energy))
    @test occursin("exp of a value in yr", msg(:wrong_growth))
    @test occursin("not a time", msg(:wrong_smoothed))
    @test occursin("branches of ifelse", msg(:wrong_choice))
    @test check_units(m) === issues                                  # kept per built model
    @test_throws ErrorException run_model(m; check_units = true)
    @test (@test_logs (:warn,) match_mode = :any run_model(m; check_units = :warn)) isa Results
    # the test models: units that add up
    @test isempty(check_units(_dsl("teacup")))
    @test isempty(check_units(_dsl("arrays")))
    mod = _module()
    Base.include(mod, joinpath(@__DIR__, "dsl", "beer_game.jl"))
    @test isempty(check_units(mod.beer_game()))
    # a unit written as 1 over another: a unit, not the number 1/s
    growth = _build("""@parameters begin
                           k = 0.1, [unit = u"1/s"]
                       end
                       @variables begin
                           x(t), [unit = u"kg"]
                       end
                       ∂t(x) ~ k * x
                       x(t₀) ~ 1""")
    @test isempty(check_units(growth))
end

@testset "DSL: a model precompiled in a package" begin
    # a package that builds the teacup model when it's precompiled; a second
    # Julia session loads it built and compiled: no Model call in that session
    dir = mktempdir()
    pkg = joinpath(dir, "Cup")
    mkpath(joinpath(pkg, "src"))
    cp(joinpath(@__DIR__, "dsl", "teacup.jl"), joinpath(pkg, "teacup.jl"))
    write(joinpath(pkg, "Project.toml"), """
        name = "Cup"
        uuid = "8c0c3e3a-6a64-4e0e-9a51-3f2c1b0d9e7f"
        [deps]
        PySD = "$(Base.PkgId(PySD).uuid)"
        """)
    write(joinpath(pkg, "src", "Cup.jl"), """
        module Cup
        using PySD
        @precompile_model model = include("../teacup.jl")
        end
        """)
    env = joinpath(dir, "env")
    # (Julia sessions of their own, with Julia's usual load path, not the tests')
    function julia(code)
        cmd = addenv(`$(Base.julia_cmd()) --startup-file=no --project=$env -e $code`,
                     "JULIA_LOAD_PATH" => "@:@stdlib", "JULIA_PROJECT" => nothing)
        out = IOBuffer()
        ok = success(pipeline(cmd; stdout = out, stderr = out))
        text = String(take!(out))
        ok || error("julia -e $code failed:\n$text")
        return last(split(chomp(text), '\n'))
    end
    julia("using Pkg; Pkg.develop([PackageSpec(path = $(repr(pkgdir(PySD)))), PackageSpec(path = $(repr(pkg)))])")
    check = "using Cup, PySD; print(PySD._MODELS[], \" \", run_model(Cup.model)[:teacup_temperature][end])"
    built = julia(check)                  # precompiles Cup: builds the model there
    loaded = julia(check)                 # loads it
    expected = run_model(_dsl("teacup"))[:teacup_temperature][end]
    @test loaded == "0 $expected"
    @test endswith(built, " $expected")
end
