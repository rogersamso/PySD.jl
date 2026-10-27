# The helpers keep the number type they are given (ForwardDiff's Dual for
# Jacobians and gradients, Float32, Measurements), are type-stable, and the
# ones called at every step don't allocate.
using ForwardDiff: Dual, derivative, value
using Measurements: ±, uncertainty

# specialized on the arguments (Julia 1.10 otherwise allocates the tuple of them)
_allocs(f::F, args::Vararg{Any,N}) where {F,N} = (f(args...); @allocated f(args...))

@testset "type-stable for Float64, Float32 and Dual" begin
    for x in (2.0, 2.0f0, Dual(2.0, 1.0))
        @inferred pysd_zidz(one(x), x)
        @inferred pysd_xidz(one(x), x, zero(x))
        @inferred pysd_power(x, 2.5)
        @inferred pysd_exp(x)
        @inferred pysd_ln(x)
        @inferred pysd_step(2.0, x, 1.0)
        @inferred pysd_pulse(x, 1.0, 2.0)
        @inferred pysd_ramp(x, 1.0, 0.0)
        @inferred pysd_ifelse(true, x, zero(x))
        @inferred pysd_sum(fill(x, 20))
        @inferred pysd_sum_seq(fill(x, 3))
    end
end

@testset "no allocations in the helpers called at every step" begin
    v = rand(100)
    @test _allocs(pysd_sum, v) == 0
    @test _allocs(pysd_sum, rand(10, 10)) == 0
    @test _allocs(pysd_sum, rand(1000)) == 0
    @test _allocs(pysd_sum_seq, v) == 0
    @test _allocs(pysd_sum, [Dual(x, 1.0) for x in v]) == 0
    @test _allocs(pysd_zidz, 1.0, 2.0) == 0
    @test _allocs(pysd_exp, 2.0) == 0
    @test _allocs(pysd_power, 2.0, 2.5) == 0
end

@testset "derivatives (ForwardDiff) and uncertainties (Measurements)" begin
    @test derivative(x -> pysd_zidz(1.0, x), 2.0) ≈ -0.25
    @test derivative(x -> pysd_zidz(1.0, x), 0.0) == 0.0
    @test derivative(pysd_exp, 1.0) ≈ exp(1.0)
    @test derivative(pysd_ln, 2.0) ≈ 0.5
    @test derivative(x -> pysd_power(x, 2.5), 4.0) ≈ 2.5 * 4.0^1.5
    @test isnan(value(pysd_power(Dual(-4.0, 1.0), 2.5)))   # NaN as numpy, not an error
    @test derivative(x -> pysd_sum([x, 2x, 3x]), 1.0) == 6.0
    @test derivative(x -> pysd_sum(fill(x, 200)), 1.0) == 200.0
    @test derivative(x -> pysd_sum_seq([x, 2x]), 1.0) == 3.0
    @test uncertainty(pysd_ln(2.0 ± 0.1)) ≈ 0.05
    @test uncertainty(pysd_sum([1.0 ± 0.3, 2.0 ± 0.4])) ≈ 0.5
end

@testset "Float32 stays Float32" begin
    @test pysd_zidz(1.0f0, 2.0f0) isa Float32
    @test pysd_zidz(1.0f0, 0.0f0) === 0.0f0
    @test pysd_sum(fill(1.0f0, 20)) === 20.0f0
    @test pysd_sum_seq(fill(1.0f0, 3)) === 3.0f0
end
