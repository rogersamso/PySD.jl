# The DSL: @equations and Model, checked against Vensim's outputs
# (SDXorg/test-models) and on the mistakes Model must catch.
using DimensionalData: Dim, At, AbstractDimArray
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
