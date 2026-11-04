# Helpers that only called a Julia function, which translated models now call
# themselves (PySD.jl 0.8.0).  Kept, with a warning, so that models translated
# before still run; they go in 1.0.
Base.@deprecate pysd_pi() π
Base.@deprecate pysd_log_base(x, base) pysd_ln(x) / pysd_ln(base)
Base.@deprecate pysd_elmcount(n) Float64(n)
