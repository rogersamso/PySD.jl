# The DSL: @equations and Model, checked against Vensim's outputs
# (SDXorg/test-models) and on the mistakes Model must catch.
using DimensionalData: Dim, At, AbstractDimArray, DimArray, broadcast_dims
using LinearAlgebra: I
include(joinpath(@__DIR__, "dsl", "check.jl"))

function _module()
    mod = Module()
    Core.eval(mod, :(using PySD, DimensionalData))
    return mod
end
_dsl(name) = Base.include(_module(), joinpath(@__DIR__, "dsl", name * ".jl"))

@testset "DSL: Vensim's results" begin
    for (model, ref, tol) in [("teacup", "samples/teacup/output.csv", 1e-5),
                              ("subscript_2d_arrays", "tests/subscript_2d_arrays/output.tab", 1e-5),
                              ("subscript_transposition", "tests/subscript_transposition/output.tab", 1e-12),
                              ("smooth", "tests/smooth/output.tab", 1e-5)]
        m = _dsl(model)
        res = run_model(m)
        if HAS_TEST_MODELS
            r = compare_reference(res, joinpath(TEST_MODELS, "..", ref))
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
end

@testset "DSL: arrays on plain arrays" begin
    mod = _module()
    m = Base.include(mod, joinpath(@__DIR__, "dsl", "arrays.jl"))
    r = run_model(m)
    a, a1, b, years = mod.a, mod.a1, mod.b, mod.years
    M = DimArray([0.1 0.2 0.0; 0.0 0.1 0.3; 0.2 0.0 0.1], (a, a1))
    v = DimArray([1.0, 2.0, 3.0], a)
    w = DimArray([1.0, 2.0], b)
    flow = broadcast_dims(*, w, v) ./ 10                       # (b, a)
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
    p = PySD._runparams(m2, m2.params(m2.inputs, (;), m2.env, m2.t0, m2.dt), m2.inputs)
    u = m2.init(p); du = similar(u)
    allocs(f::F, du, u, p) where {F} = (f(du, u, p, 0.0); @allocated f(du, u, p, 0.0))
    @test allocs(m2.rhs!, du, u, p) == 0
end
