"""
    PySD.PythonMath

Julia's `exp`, `log`, `sqrt`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`,
`sinh` and `cosh` as Python PySD computes them, for models that must give
its digits:

- for `Float64` and `Int`, the platform's C maths library, which numpy and
  Python call (Julia's own functions differ from it in the last digit in 1 to
  10% of the cases; with the same digits, values equal up to rounding take
  the same branch of an IF THEN ELSE);
- `log`, `sqrt`, `asin` and `acos` give NaN out of their domain, as numpy,
  instead of throwing a `DomainError`: IF THEN ELSE computes both branches,
  and the one not taken may be out of the domain.

Other arguments (symbolic variables, dual numbers, measurements) go to Julia's
functions (NaNMath's for those four), so ModelingToolkit builds equations from
them and ForwardDiff differentiates them.

Translated models call them qualified (`PythonMath.exp(x)`); the DSL's
`numerics = :python` puts them in place of Julia's in the code it generates,
while the model's text keeps the ordinary names.
"""
module PythonMath

import NaNMath
using ..PySD: _c_exp, _c_log, _c_sin, _c_cos, _c_tan, _c_atan, _c_asin, _c_acos,
              _c_sinh, _c_cosh

# functions of their own, not methods of Base's: Julia's keep their meaning
function exp end
function log end
function sqrt end
function sin end
function cos end
function tan end
function asin end
function acos end
function atan end
function sinh end
function cosh end

const _CNum = Union{Float64,Int}

for (f, c, julia) in ((:exp, :_c_exp, :(Base.exp)), (:sin, :_c_sin, :(Base.sin)),
                      (:cos, :_c_cos, :(Base.cos)), (:tan, :_c_tan, :(Base.tan)),
                      (:atan, :_c_atan, :(Base.atan)), (:sinh, :_c_sinh, :(Base.sinh)),
                      (:cosh, :_c_cosh, :(Base.cosh)),
                      (:log, :_c_log, :(NaNMath.log)), (:asin, :_c_asin, :(NaNMath.asin)),
                      (:acos, :_c_acos, :(NaNMath.acos)))
    @eval $f(x) = $julia(x)
    @eval $f(x::_CNum) = $c(Float64(x))
end
# (the C library's square root is correctly rounded, as Julia's)
sqrt(x) = NaNMath.sqrt(x)

end
