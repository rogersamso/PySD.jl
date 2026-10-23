# The platform's C maths library, which Python PySD calls (numpy and Python's
# own floats use it): Julia's own exp, log, sin, ... and ^ differ from it in
# the last digit in 1 to 10% of the cases.  With the same digits, values that
# are equal up to rounding take the same branch of an IF THEN ELSE as in
# Python.  Where the library cannot be loaded, Julia's functions are used
# (NaN out of the domain, as numpy).

const _LIBM_NAMES = Sys.islinux() ? ("libm.so.6",) :
                    Sys.isapple() ? ("libSystem.B.dylib",) : ("ucrtbase", "msvcrt")

const _LIBM_UNARY = (:exp, :log, :sin, :cos, :tan, :atan, :asin, :acos, :sinh, :cosh)

for f in (_LIBM_UNARY..., :pow)
    @eval const $(Symbol(:_libm_, f)) = Ref{Ptr{Cvoid}}(C_NULL)
end

function _load_libm()
    for name in _LIBM_NAMES
        handle = Libdl.dlopen_e(name)
        handle == C_NULL && continue
        for f in (_LIBM_UNARY..., :pow)
            getfield(@__MODULE__, Symbol(:_libm_, f))[] = Libdl.dlsym_e(handle, f)
        end
        return true
    end
    return false
end

for f in _LIBM_UNARY
    ptr = Symbol(:_libm_, f)
    fallback = isdefined(NaNMath, f) ? :(NaNMath.$f) : :(Base.$f)
    @eval function $(Symbol(:_c_, f))(x::Float64)
        p = $ptr[]
        return p == C_NULL ? $fallback(x) : ccall(p, Float64, (Float64,), x)
    end
end

function _c_pow(x::Float64, y::Float64)
    p = _libm_pow[]
    p == C_NULL && return x < 0 && !isinteger(y) ? NaN : x^y
    return ccall(p, Float64, (Float64, Float64), x, y)
end
