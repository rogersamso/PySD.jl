using DataInterpolations: ConstantInterpolation

@testset "params: pysd_input" begin
    given = Dict{Symbol,Any}(:a => 2, :v => [1, 2, 3], :w => 5, :m => [1.0 2.0; 3.0 4.0])
    @test pysd_input(given, :a, 1.0) === 2.0
    @test pysd_input(given, :b, 1.0) === 1.0                  # not given: default
    v = pysd_input(given, :v, pysd_safe(zeros(3)))
    @test v isa SafeArray && collect(v) == [1.0, 2.0, 3.0]
    @test isnan(v[5])                                         # out of range reads NaN, as the model's arrays
    @test collect(pysd_input(given, :w, zeros(2, 2))) == fill(5.0, 2, 2)  # a number fills the array
    @test collect(pysd_input(given, :m, zeros(2, 2))) == [1.0 2.0; 3.0 4.0]
    @test_throws DimensionMismatch pysd_input(given, :v, zeros(4))
    @test_throws ArgumentError pysd_input(given, :v, 0.0)     # an array for a number
    @test_throws ArgumentError pysd_input(Dict{Symbol,Any}(:a => "x"), :a, 0.0)
end

@testset "params: pysd_lookup" begin
    f = pysd_lookup(([0.0, 10.0], [0.0, 100.0]))
    @test f(5.0) ≈ 50.0
    @test f(-1.0) == 0.0 && f(20.0) == 100.0                  # held outside the x range
    @test f(2, 5.0) ≈ 50.0                                    # same series for every element
    g = pysd_lookup(([0.0, 1.0], [0.0 10.0; 1.0 20.0]))       # one column per element
    @test g(1, 0.5) ≈ 0.5 && g(2, 0.5) ≈ 15.0
    @test pysd_lookup(3)(1, 2, 7.0) == 3.0
    h = x -> 2x
    @test pysd_lookup(h) === h
    itp = ConstantInterpolation([1.0, 2.0], [0.0, 1.0])
    @test pysd_lookup(itp)(0.5) == itp(0.5)
    @test pysd_input(Dict{Symbol,Any}(:l => ([0, 1], [0, 2])), :l, x -> 0.0)(0.5) ≈ 1.0
    @test_throws ArgumentError pysd_lookup("x")
end

@testset "params: pysd_check_inputs and pysd_file" begin
    @test pysd_check_inputs(Dict{Symbol,Any}(:a => 1), (a = 1.0, b = 2.0)) === nothing
    err = try
        pysd_check_inputs(Dict{Symbol,Any}(:a => 1, :zz => 2, :c => 3), (a = 1.0, b = 2.0)); ""
    catch e
        sprint(showerror, e)
    end
    @test occursin("c, zz", err)
    files = Dict("../data/in.xlsx" => "other.xlsx", "b.xlsx" => "/abs/b2.xlsx")
    @test pysd_file("/m", "../data/in.xlsx", files) == "/m/other.xlsx"
    @test pysd_file("/m", "../x/b.xlsx", files) == "/abs/b2.xlsx"   # by base name
    @test pysd_file("/m", "c.xlsx", files) == "/m/c.xlsx"
end

@testset "params: pysd_check_fixed" begin
    fixed = (delay_time = "the number of stages of DELAY FIXED in x",)
    @test pysd_check_fixed(Dict{Symbol,Any}(:a => 1), fixed) === nothing
    err = try
        pysd_check_fixed(Dict{Symbol,Any}(:delay_time => 3), fixed); ""
    catch e
        sprint(showerror, e)
    end
    @test occursin("delay_time sets the number of stages of DELAY FIXED in x", err)
    @test occursin("translate the model again", err)
end

@testset "params: lookups keep one type" begin
    a = pysd_input(Dict{Symbol,Any}(), :l, x -> 2x)
    b = pysd_input(Dict{Symbol,Any}(:l => ([0, 1], [0, 1])), :l, x -> 2x)
    c = pysd_input(Dict{Symbol,Any}(:l => x -> 3), :l, x -> 2x)
    @test a isa PySDFunction{1} && typeof(a) == typeof(b) == typeof(c)
    @test a(1.5) === 3.0 && b(0.5) === 0.5 && c(0.0) === 3.0    # an Int result as Float64
    @test a(1) === 2.0                                         # other argument types: f directly
    d = pysd_input(Dict{Symbol,Any}(:l => ([0, 1], [0 10; 1 20])), :l, (i, x) -> 0.0)
    e = pysd_input(Dict{Symbol,Any}(), :l, (i, x) -> i * x)
    @test d isa PySDFunction{2} && typeof(d) == typeof(e)
    @test d(2, 0.5) === 15.0 && e(2, 1.5) === 3.0
    @test Base.return_types(a, (Float64,)) == [Float64]
    @test Base.return_types(e, (Int, Float64)) == [Float64]
    # a dual-number-like argument keeps its type
    @test a(big"1.5") == 3 && a(big"1.5") isa BigFloat
end

@testset "series of one point" begin
    xs, ys = PySD._clean_series([5.0], [2.0])
    @test xs == [5.0, 6.0] && ys == [2.0, 2.0]
    xs, ys = PySD._clean_series([5.0], reshape([2.0, 3.0], 2, 1))
    @test ys == [2.0 2.0; 3.0 3.0]
    itp = pysd_build_tab_itp([2.0], [5.0], :interpolate)
    @test itp(0.0) == 2.0 && itp(5.0) == 2.0 && itp(100.0) == 2.0
    @test pysd_build_tab_itp([2.0], [5.0], :hold_backward)(7.0) == 2.0
end
