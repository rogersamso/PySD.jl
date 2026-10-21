using PySD
using Test
using NCDatasets

const DATA = joinpath(@__DIR__, "data")

# SDXorg/test-models (git submodule test/test-models, or PYSD_TEST_MODELS)
const TEST_MODELS = get(ENV, "PYSD_TEST_MODELS", joinpath(@__DIR__, "test-models", "tests"))
const HAS_TEST_MODELS = isdir(TEST_MODELS)
HAS_TEST_MODELS || @warn "test-models not found at $TEST_MODELS: reference tests skipped " *
                         "(run `git submodule update --init` or set PYSD_TEST_MODELS)"

"""
    vensim_output(folder) -> (t, col, t_ref) -> value

Reader for a test model's Vensim `output.tab`.  Constants are saved in the
first row only, so an empty cell falls back to the first value.
"""
function vensim_output(folder)
    path = joinpath(TEST_MODELS, folder, "output.tab")
    cache = Dict{String,Tuple{Vector{Float64},Vector{Float64}}}()
    return function (col, t)
        times, vals = get!(() -> pysd_tab_read_series(path, col), cache, col)
        v = vals[findfirst(==(t), times)]
        return isnan(v) ? vals[1] : v
    end
end

# Minimal stand-in for an ODE solution: what save_results reads.
struct FakeSol
    t::Vector{Float64}
    u::Vector{Vector{Float64}}
end
Base.getindex(s::FakeSol, i::Int, ::Colon) = [u[i] for u in s.u]

@testset "PySD.jl" begin

@testset "check_compat" begin
    @test PYSD_JL_VERSION isa VersionNumber
    @test check_compat(PYSD_JL_VERSION) === nothing
    @test_throws ErrorException check_compat(VersionNumber(PYSD_JL_VERSION.major + 1, 0, 0))
    @test_logs (:warn,) check_compat(VersionNumber(PYSD_JL_VERSION.major,
                                                   PYSD_JL_VERSION.minor + 1, 0))
end

@testset "arithmetic helpers" begin
    @test pysd_xidz(6.0, 3.0, 5.0) == 2.0
    @test pysd_xidz(6.0, 0.0, 5.0) == 5.0
    @test pysd_zidz(6.0, 3.0) == 2.0
    @test pysd_zidz(6.0, 0.0) == 0.0
    @test pysd_trunc(2.7) == 2.0
    @test pysd_trunc(-2.7) == -2.0
    @test pysd_log_base(8.0, 2.0) ≈ 3.0
    @test pysd_quantum(7.5, 2.0) == 6.0
    @test pysd_quantum(-7.5, 2.0) == -6.0
    @test pysd_quantum(3.0, 0.0) == 3.0          # Vensim: B <= 0 returns A
    @test pysd_elmcount(3) === 3.0
    @test pysd_pi() ≈ π
    @test pysd_power(2.0, 3.0) == 8.0
    @test pysd_power(-2.0, 3.0) == -8.0
    # Vensim POWER / numpy.power (also used for `^`): (-2)^2 = 4
    @test pysd_power(-2.0, 2.0) == 4.0
    @test pysd_power(4, -1) == 0.25
    @test pysd_power(-8.0, 1 / 3) === NaN        # negative base, non-integer exponent (numpy: nan)
end

@testset "time functions" begin
    # PULSE(start=2, width=3): 1 on [2, 5)
    @test [pysd_pulse(t, 2.0, 3.0) for t in (1.0, 2.0, 4.9, 5.0)] == [0.0, 1.0, 1.0, 0.0]
    # PULSE TRAIN(start=1, width=1, interval=4, end=9), argument order (start, interval, width, end)
    @test [pysd_pulse_train(t, 1.0, 4.0, 1.0, 9.0) for t in (0.0, 1.0, 1.5, 2.0, 5.0, 13.0)] ==
          [0.0, 1.0, 1.0, 0.0, 1.0, 0.0]
    # end time is exclusive in Vensim / Python PySD (t < end)
    @test pysd_pulse_train(9.0, 1.0, 4.0, 1.0, 9.0) == 0.0
    # times accumulated by Euler steps are slightly off (0.1 + 0.1 + 0.1 < 0.3 is false, but
    # 0.7 - 0.4 < 0.3): pulses start up to 1e-6 early, as in Python PySD
    @test pysd_pulse(0.3 - 1e-9, 0.3, 1.0) == 1.0
    @test pysd_pulse_train(5.0 - 1e-9 + 4.0, 1.0, 4.0, 1.0, 20.0) == 1.0
    # RAMP(slope=2, start=1, end=4)
    @test [pysd_ramp(t, 2.0, 1.0, 4.0) for t in (0.0, 1.0, 2.0, 4.0, 10.0)] ==
          [0.0, 0.0, 2.0, 6.0, 6.0]
    @test pysd_ramp(10.0, 2.0, 1.0) == 18.0      # no end time
    # STEP(height=5, time=3)
    @test [pysd_step(t, 5, 3.0) for t in (2.9, 3.0, 4.0)] == [0.0, 5.0, 5.0]
    # XMILE RAMP(slope, start)
    @test [pysd_xramp(t, 2.0, 1.0) for t in (0.0, 3.0)] == [0.0, 4.0]
    # XMILE PULSE(magnitude, start[, interval]): magnitude / time_step during one time step
    dt = 0.25
    @test [pysd_xpulse(t, 2.0, 5.0, dt) for t in (1.75, 2.0, 2.25)] == [0.0, 20.0, 0.0]
    @test [pysd_xpulse_train(t, 1.0, 3.0, 5.0, dt) for t in (0.75, 1.0, 1.25, 4.0, 7.0, 7.25)] ==
          [0.0, 20.0, 0.0, 20.0, 20.0, 0.0]
    # models translated by an older PySD call the methods without time_step: still run, with a warning
    @test_logs (:warn,) pysd_xpulse(2.0, 2.0, 5.0)
    @test pysd_get_time_value(15.0, x -> 2x, 0.0, 10.0) == 20.0   # clamped to hi
    @test pysd_get_time_value(5.0, x -> 2x, 0.0, 10.0) == 10.0
end

@testset "logic" begin
    @test pysd_logical_and(1.0, 1.0) === true
    @test pysd_logical_and(1.0, 0.0) === false
    @test pysd_logical_or(0.0, 1.0) === true
    @test pysd_logical_or(0.0, 0.0) === false
    @test pysd_logical_not(0.0) === true
    @test pysd_ifelse(true, 1.0, 2.0) == 1.0
    @test pysd_ifelse(false, 1.0, 2.0) == 2.0
    @test pysd_ifelse(1.0, 1.0, 2.0) == 1.0
    @test pysd_ifelse(0.0, 1.0, 2.0) == 2.0
    @test pysd_active_initial(4.0, 1.0) == 4.0
end

@testset "matrices" begin
    m = [2.0 1.0; 1.0 3.0]
    @test pysd_inv_mat2d_elem(m, 1, 2) ≈ inv(m)[1, 2]
    stack3 = cat(reshape(m, 1, 2, 2), reshape(2m, 1, 2, 2); dims=1)
    @test pysd_inv_mat3d_elem(stack3, 2, 2, 1) ≈ inv(2m)[2, 1]
    @test pysd_invert_matrix(vec(m), 2) ≈ vec(inv(m))
    @test pysd_invert_matrix(5.0, 1) == 5.0
end

@testset "vector functions" begin
    v = [3.0, 1.0, 2.0]
    # VECTOR SELECT actions: 0 first, 1 sum, 2 max, 3 min, 4 mean
    sel = [1.0, 0.0, 1.0]
    @test pysd_vector_select(sel, v, -1.0, 0) == 3.0
    @test pysd_vector_select(sel, v, -1.0, 1) == 5.0
    @test pysd_vector_select(sel, v, -1.0, 2) == 3.0
    @test pysd_vector_select(sel, v, -1.0, 3) == 2.0
    @test pysd_vector_select(sel, v, -1.0, 4) == 2.5
    @test pysd_vector_select(zeros(3), v, -1.0, 1) == -1.0
    # VECTOR REORDER takes 0-based positions, as returned by VECTOR SORT ORDER
    @test pysd_vector_reorder(v, [1.0, 2.0, 0.0]) == [1.0, 2.0, 3.0]
    @test pysd_vector_reorder(v, pysd_vector_sort_order(v, 1)) == sort(v)
    @test pysd_vector_reorder(v, pysd_vector_sort_order(v, -1)) == sort(v; rev = true)
    # VECTOR RANK is 1-based in Vensim and Python PySD
    @test pysd_vector_rank(v, 1) == [3.0, 1.0, 2.0]
    @test pysd_vector_rank(v, -1) == [1.0, 3.0, 2.0]
    # VECTOR SORT ORDER: Vensim / Python PySD return 0-based positions
    @test pysd_vector_sort_order(v, 1) == [1.0, 2.0, 0.0]
    @test pysd_vector_sort_order(v, -1) == [0.0, 2.0, 1.0]
end

@testset "random" begin
    @test 0.0 <= pysd_random_0_1() < 1.0
    @test all(2.0 <= pysd_random_uniform(2.0, 3.0, 0) <= 3.0 for _ in 1:100)
    @test all(-1.0 <= pysd_random_normal(-1.0, 1.0, 0.0, 5.0, 0) <= 1.0 for _ in 1:100)
    @test all(1.0 <= pysd_random_exponential(1.0, 2.0, 3.0, 0) <= 2.0 for _ in 1:100)
end

@testset "SafeArray" begin
    a = pysd_safe(zeros(2, 3))
    @test a isa SafeArray
    @test size(a) == (2, 3)
    a[1, 2] = 4.0
    @test a[1, 2] == 4.0
    @test a[5, 5] == 0.0                 # out of bounds reads give zero
    a[9, 9] = 1.0                        # and writes are ignored
    @test sum(a.data) == 4.0
    b = pysd_safe([1.0, 2.0])
    @test b[2] == 2.0 && b[3] == 0.0
    c = pysd_safe(zeros(2, 2, 2))
    c[2, 2, 2] = 1.0
    @test c[2, 2, 2] == 1.0 && c[3, 1, 1] == 0.0
    @test pysd_safe(3.0) === 3.0
end

@testset "ALLOCATE BY PRIORITY" begin
    @test_throws ErrorException pysd_allocate_by_priority([1.0, 1.0], [1.0, 2.0], 0.0, 1.0)
    @test pysd_allocate_by_priority([1.0, 2.0], [1.0, 2.0], 1.0, 5.0) == [1.0, 2.0]
    @test pysd_allocate_by_priority([1.0, 2.0], [1.0, 2.0], 1.0, 0.0) == [0.0, 0.0]
    @test pysd_allocate_by_priority([0.0, 0.0], [1.0, 2.0], 1.0, 1.0) == [0.0, 0.0]
end

if HAS_TEST_MODELS
# Inputs and expected allocations from test-models/allocate_by_priority (Vensim)
@testset "ALLOCATE BY PRIORITY: Vensim reference" begin
    out = vensim_output("allocate_by_priority")
    dim, dim2 = ["A", "B", "C"], ["A", "B", "C", "D", "E"]
    v(var, labels, t) = [out("$var[$l]", t) for l in labels]
    check(name, got, exp) = isapprox(got, exp; rtol=1e-4, atol=1e-4) || (@info name got exp; false)
    for t in (0.0, 3.0, 7.0, 12.0, 20.0, 30.0)
        supply = out("supply 0D", t)
        for (n, d) in (("1", dim), ("2", dim2))
            got = pysd_allocate_by_priority(v("demands$n", d, t), v("priorities$n", d, t), 3.0, supply)
            @test check("allocation$n t=$t", got, v("allocation$n", d, t))
        end
        for r in dim
            lab = ["$r,$c" for c in dim2]
            got = pysd_allocate_by_priority(v("demands2D", lab, t), v("priorities2D", lab, t),
                                            out("widths[$r]", t), out("supply 1D[$r]", t))
            @test check("allocation2D[$r] t=$t", got, v("allocation2D", lab, t))
        end
    end
end

# Inputs and expected allocations from test-models/allocate_available (Vensim)
@testset "ALLOCATE AVAILABLE: Vensim reference" begin
    out = vensim_output("allocate_available")
    branch = ["Boston", "Dayton", "Fresno"]
    ptype = ["ptype", "ppriority", "pwidth", "pextra"]
    demand(t) = [out("demand1[$b]", t) for b in branch]
    pp(var, t) = [out("$var[$b,$p]", t) for b in branch, p in ptype]
    # rtol as in PySD's Python pathway test: the normal profile differs from
    # Vensim by up to ~3e-4 (Python PySD gives the same values as here)
    check(name, got, exp) = isapprox(got, exp; rtol=2e-2) || (@info name got exp; false)
    for t in (0.0, 4.0, 8.0, 12.0, 20.0, 40.0, 100.0), k in 1:4  # saved every 4
        got = pysd_allocate_available(demand(t), pp("priority$k far", t), out("available", t))
        @test check("allocation$k far t=$t", got, [out("allocation$k far[$b]", t) for b in branch])
    end
    for k in 1:4, p in ["A", "B", "C", "D"]
        got = pysd_allocate_available(demand(0.0), pp("priority$k sep", 0.0),
                                      out("available sep[$p]", 0.0))
        @test check("allocation$k sep[$p]", got, [out("allocation$k sep[$p,$b]", 0.0) for b in branch])
    end
end
end  # HAS_TEST_MODELS

@testset "tab data" begin
    times, vals = pysd_tab_read_series(joinpath(DATA, "sample.tab"), "stock a")
    @test times == [0.0, 1.0, 2.0]
    @test vals == [1.0, 2.0, 4.0]
    _, flow = pysd_tab_read_series(joinpath(DATA, "sample.tab"), "Flow")
    @test flow[1] == 0.5 && isnan(flow[2]) && flow[3] == 0.25
    @test_throws ErrorException pysd_tab_read_series(joinpath(DATA, "sample.tab"), "missing")

    lin = pysd_build_tab_itp([1.0, 2.0, 4.0], [0.0, 1.0, 2.0], :interpolate)
    @test lin(0.5) ≈ 1.5
    @test lin(5.0) == 4.0                 # constant extrapolation
    back = pysd_build_tab_itp([1.0, 2.0, 4.0], [0.0, 1.0, 2.0], :hold_backward)
    @test back(1.5) == 2.0
    fwd = pysd_build_tab_itp([1.0, 2.0, 4.0], [0.0, 1.0, 2.0], :look_forward)
    @test fwd(1.5) == 4.0
end

@testset "XLSX readers" begin
    xl = joinpath(DATA, "sample.xlsx")
    @test pysd_xlsx_read_constant(xl, "Data", "B2") == 3.5
    @test pysd_xlsx_read_constant(xl, "Data", "scalar_param") == 3.5
    @test pysd_xlsx_read_constant(xl, "Data", "local_param") == 7.0
    @test pysd_xlsx_read_constant(xl, "Data", "row_param") == [1.0, 2.0, 3.0]
    @test pysd_xlsx_read_constant(xl, "Data", "col_param") == [10.0, 20.0, 30.0]
    @test pysd_xlsx_read_constant(xl, "Data", "mat_param") == [1.0 2.0 3.0; 4.0 5.0 6.0]
    @test pysd_xlsx_read_constant(xl, "Data", "mat_param"; transpose=true) ==
          [1.0 4.0; 2.0 5.0; 3.0 6.0]
    @test pysd_xlsx_read_constant(xl, "Data", ["row_param", [9.0]]) == [1.0, 2.0, 3.0, 9.0]
    @test pysd_xlsx_read_constant(xl, "Data", ["mat_param"]; dims=(2, 3)) ==
          [1.0 2.0 3.0; 4.0 5.0 6.0]
    @test_throws ErrorException pysd_xlsx_read_constant(xl, "Data", "no_such_name")

    # Row mode: x in row 10, y from B11
    xs, ys = pysd_xlsx_read_series(xl, "Data", "10", "B11")
    @test xs == [0.0, 1.0, 2.0, 3.0, 4.0] && ys == [0.0, 10.0, 20.0, 30.0, 40.0]
    # Column mode: x in column H, y from I2
    xs, ys = pysd_xlsx_read_series(xl, "Data", "H", "I2")
    @test xs == [0.0, 1.0, 2.0, 3.0, 4.0] && ys == [5.0, 4.0, 3.0, 2.0, 1.0]
    # Named ranges
    xs, ys = pysd_xlsx_read_series(xl, "Data", "xs", "ys")
    @test ys == [5.0, 4.0, 3.0, 2.0, 1.0]
    xs, yss = pysd_xlsx_read_series(xl, "Data", "xs", ["ys", "ys"])
    @test length(yss) == 2 && yss[2] == [5.0, 4.0, 3.0, 2.0, 1.0]

    fns = pysd_xlsx_build_lookup_dispatch(xl, "Data", "xs", "ys2")
    @test length(fns) == 2
    @test fns[1](1.5) ≈ 3.5 && fns[2](1.5) ≈ 2.5
    @test fns[1](10.0) == 1.0                           # constant extrapolation
    @test only(pysd_xlsx_build_lookup_dispatch(xl, "Data", "xs", "ys"))(0.5) ≈ 4.5
end

@testset "save_results" begin
    dim_labels = Dict("A" => ["a1", "a2", "a3"], "B" => ["b1", "b2"], "C" => ["c1", "c2"])
    # state vector: scalar, then a 3x2 stock, then a 3x2x2 stock (column-major)
    m2 = [1.0 2.0; 3.0 4.0; 5.0 6.0]
    m3 = reshape(collect(1.0:12.0), 3, 2, 2)
    u(k) = vcat([10.0k], vec(m2 .* k), vec(m3 .* k))
    sol = FakeSol([0.0, 1.0], [u(1), u(2)])
    state_map = [("s", 1, String[]), ("m2", 2, ["A", "B"]), ("m3", 8, ["A", "B", "C"])]
    path = joinpath(mktempdir(), "out.nc")
    @test save_results(sol, state_map, dim_labels, path) == path

    NCDataset(path) do ds
        @test ds["time"][:] == [0.0, 1.0]
        @test ds["s"][:] == [10.0, 20.0]
        @test ds["A"][:] == ["a1", "a2", "a3"]
        @test ds["B"][:] == ["b1", "b2"]
        # file order is (time, dim_1, ..., dim_n); NCDatasets shows it reversed
        @test dimnames(ds["m2"]) == ("B", "A", "time")
        @test dimnames(ds["m3"]) == ("C", "B", "A", "time")
        a2 = Array(ds["m2"])                 # (B, A, time)
        @test a2[:, :, 2] == permutedims(2 .* m2)
        a3 = Array(ds["m3"])                 # (C, B, A, time)
        @test a3[:, :, :, 1] == permutedims(m3, (3, 2, 1))
        @test a3[2, 1, 3, 2] == 2 * m3[3, 1, 2]
    end
end

end
