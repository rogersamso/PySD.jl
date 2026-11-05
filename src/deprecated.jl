# Helpers that only called a Julia function, which translated models now call
# themselves (PySD.jl 0.8.0).  Kept, with a warning, so that models translated
# before still run; they go in 1.0.
Base.@deprecate pysd_pi() π
Base.@deprecate pysd_elmcount(n) Float64(n)

# The maths functions with Python PySD's digits, now in PythonMath with
# Julia's names (PySD.jl 0.10.0).  INTEGER is Julia's trunc; ModelingToolkit
# has no symbolic trunc, so this one keeps working in equations.
Base.@deprecate pysd_trunc(x) _trunc(x)
for f in (:exp, :sqrt, :sin, :cos, :tan, :asin, :acos, :atan, :sinh, :cosh)
    @eval Base.@deprecate $(Symbol(:pysd_, f))(x) PythonMath.$f(x)
end
Base.@deprecate pysd_ln(x) PythonMath.log(x)
Base.@deprecate pysd_log_base(x, base) PythonMath.log(x) / PythonMath.log(base)
