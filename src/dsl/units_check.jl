# check_units: whether each equation's units add up.  It reads the equations,
# not the numbers (no input files, no simulation): the unit of every expression
# from the declared units, with Unitful's algebra.  Plain numbers take the unit
# that fits; the user's own functions can't be checked, and their equations are
# counted as not checked.

struct UnitIssue
    name::Symbol
    source::LineNumberNode
    message::String
end

Base.show(io::IO, i::UnitIssue) = print(io, _where(i.source), "  ", i.name, ": ", i.message)

"""
    check_units(model)

The equations of `model` whose units don't add up, as a vector of issues
(file, line, variable, what differs); empty when they all do.  Same unit for
`+`, `-`, `min`, `max`, comparisons and the branches of `ifelse` (units of
one kind but another size, `EJ` and `TJ`, need a conversion factor);
`*`, `/` and `^` combine units; `exp`, `log` and trigonometric functions take
`NoUnits`; `∂t(x)` has the unit of `x` per unit of time; the delay times of
`smooth`, `delay` and `x(t - τ)` are times.  `run_model(model; check_units =
true)` checks before running (`:warn` to run anyway).
"""
function check_units(m::Model)
    m.units[] === nothing || return m.units[]
    c = UnitCheck(m, UnitIssue[], 0)
    for v in m.vars
        u = _declared_unit(v)
        if v.kind === :stock
            for p in v.rate
                _expect!(c, v, p.source, _ucheck(c, p.rhs, v, p.source), u / m.time_unit, "∂t($(v.decl.name))")
            end
            _expect!(c, v, v.init.source, _ucheck(c, v.init.rhs, v, v.init.source), u, "$(v.decl.name)(t₀)")
        elseif v.kind in (:aux, :constant)
            for p in v.parts
                _expect!(c, v, p.source, _ucheck(c, p.rhs, v, p.source), u, string(v.decl.name))
            end
            v.init === nothing ||
                _expect!(c, v, v.init.source, _ucheck(c, v.init.rhs, v, v.init.source), u, "$(v.decl.name)(t₀)")
        end
    end
    m.units[] = c.issues
    return c.issues
end

mutable struct UnitCheck
    model::Model
    issues::Vector{UnitIssue}
    unchecked::Int
end

# :any — a plain number, which takes the unit that fits; :unknown — can't tell
const _ANY = :any
const _UNKNOWN = :unknown

_declared_unit(v::Var) = (u = unit_value(v.decl.metadata[:unit]); u === NoUnits ? Unitful.NoUnits : u)

_same(a, b) = a === _ANY || b === _ANY || a === _UNKNOWN || b === _UNKNOWN ||
    (Unitful.dimension(a) == Unitful.dimension(b) && Unitful.convfact(a, b) == 1)

_ustr(u) = u === Unitful.NoUnits ? "NoUnits" : string(u)

function _issue!(c::UnitCheck, v, src, msg)
    push!(c.issues, UnitIssue(v.name, src, msg))
    return _UNKNOWN
end

function _expect!(c, v, src, got, expected, what)
    got === _UNKNOWN && (c.unchecked += 1; return)
    _same(got, expected) ||
        _issue!(c, v, src, "$what is in $(_ustr(got)), should be $(_ustr(expected))" *
                           (Unitful.dimension(got) == Unitful.dimension(expected) ? " (needs a conversion factor)" : ""))
end

# all the same unit (+, -, min, max, comparisons, branches): that unit
function _all_same(c, us, v, src, what)
    known = [u for u in us if u !== _ANY && u !== _UNKNOWN]
    isempty(known) && return any(==(_UNKNOWN), us) ? _UNKNOWN : _ANY
    for u in known[2:end]
        _same(known[1], u) || return _issue!(c, v, src, "$what of $(_ustr(known[1])) and $(_ustr(u))" *
            (Unitful.dimension(known[1]) == Unitful.dimension(u) ? " (needs a conversion factor)" : ""))
    end
    return known[1]
end

_mul(a, b) = a === _UNKNOWN || b === _UNKNOWN ? _UNKNOWN : a === _ANY ? b : b === _ANY ? a : a * b
_div(a, b) = a === _UNKNOWN || b === _UNKNOWN ? _UNKNOWN : b === _ANY ? a : a === _ANY ? inv(b) : a / b

function _none!(c, u, v, src, what)
    u in (_ANY, _UNKNOWN) && return
    _same(u, Unitful.NoUnits) || _issue!(c, v, src, "$what of a value in $(_ustr(u)); it takes NoUnits")
end

function _time!(c, u, v, src, what)
    u in (_ANY, _UNKNOWN) && return
    _same(u, c.model.time_unit) || _issue!(c, v, src, "$what is in $(_ustr(u)), not a time ($(_ustr(c.model.time_unit)))")
end

const _NOUNIT_FUNCTIONS = (:exp, :log, :log10, :log2, :sin, :cos, :tan, :asin, :acos, :atan, :sinh, :cosh, :tanh)
const _SAME_FUNCTIONS = (:abs, :floor, :ceil, :round, :trunc, :min, :max, :clamp, :+, :-)
const _COMPARISONS = (:<, :>, :<=, :>=, :≤, :≥, :(==), :!=, :≠)

_fsym(f) = f isa Symbol ? f : f isa QuoteNode ? f.value : f

function _ucheck(c::UnitCheck, x, v, src)
    m = c.model
    x isa Number && return _ANY
    x === :t && return m.time_unit
    x isa VarRef && return _declared_unit(m.byname[x.name])
    x isa OpRef && return _ucheck_op(c, m.operators[x.k], v, src)
    x isa Expr && x.head === :. && x.args[1] === :p && x.args[2] in (QuoteNode(:t0), QuoteNode(:dt)) && return m.time_unit
    x isa Union{EnvRef,InputRef,QuoteNode,Symbol,String} && return _ANY
    x isa Expr || return _ANY
    if x.head === :ref
        return _ucheck(c, x.args[1], v, src)                       # a selection: the array's unit
    elseif x.head in (:&&, :||) || x.head === :comparison
        foreach(a -> _ucheck(c, a, v, src), x.args)
        return _ANY                                                 # a condition: 0 or 1, as a plain number
    elseif x.head !== :call
        return _UNKNOWN
    end
    f = _fsym(x.args[1])
    args = [a for a in x.args[2:end] if !(a isa Expr && a.head === :parameters)]
    if f === _bc                                                    # element by element: as the function
        return _ucheck(c, Expr(:call, args[1], args[2:end]...), v, src)
    end
    us() = [_ucheck(c, a, v, src) for a in args]
    if x.args[1] isa VarRef                                         # a lookup or data series: its unit
        foreach(a -> _ucheck(c, a, v, src), args)
        return _declared_unit(m.byname[x.args[1].name])
    elseif f === :* || f === :/
        u = us()
        return f === :* ? reduce(_mul, u) : _div(u[1], u[2])
    elseif f === :^
        b = _ucheck(c, args[1], v, src)
        b in (_ANY, _UNKNOWN) && return b
        _same(b, Unitful.NoUnits) && return Unitful.NoUnits
        args[2] isa Real || return _issue!(c, v, src, "a power of a value in $(_ustr(b)) with an exponent known only when the model runs")
        return b^args[2]
    elseif f === :sqrt
        b = _ucheck(c, args[1], v, src)
        return b in (_ANY, _UNKNOWN) ? b : b^(1 // 2)
    elseif f in _COMPARISONS
        _all_same(c, us(), v, src, "a comparison")
        return _ANY                                                 # 0 or 1: h * (t ≥ t₀) has h's unit
    elseif f === :ifelse || f === ifelse
        _ucheck(c, args[1], v, src)
        return _all_same(c, us()[2:end], v, src, "the branches of ifelse")
    elseif f in _SAME_FUNCTIONS
        if f in (:floor, :ceil, :round, :trunc) && length(args) == 2 && args[1] isa Symbol
            return _ucheck(c, args[2], v, src)                      # floor(Int, x)
        end
        return _all_same(c, us(), v, src, f in (:+, :-) ? "a sum" : "$f")
    elseif f in _NOUNIT_FUNCTIONS
        for a in args
            _none!(c, _ucheck(c, a, v, src), v, src, string(f))
        end
        return Unitful.NoUnits
    elseif f === pysd_zidz || f === pysd_xidz
        u = us()
        q = _div(u[1], u[2])
        f === pysd_xidz && _all_same(c, [q, u[3]], v, src, "xidz's value and its value for 0")
        return q
    elseif f === sum_over || f === maximum_over || f === minimum_over || f === previous || f === DimensionalData.set
        return _ucheck(c, args[1], v, src)
    elseif f === LinearAlgebra.inv
        return _div(_ANY, _ucheck(c, args[1], v, src))
    elseif f === LinearAlgebra.I
        return _ANY
    elseif f in (constant, lookup, data)
        return _ANY
    end
    foreach(a -> _ucheck(c, a, v, src), args)                       # the user's own function
    return _UNKNOWN
end

function _ucheck_op(c::UnitCheck, o::Operator, v, src)
    a = [_ucheck(c, x, v, src) for x in o.call.args]
    k = o.call.kind
    init = get(o.call.kwargs, :init, nothing)
    ui = init === nothing ? _ANY : _ucheck(c, init, v, src)
    if k in (:smooth, :delay)
        _time!(c, a[2], v, src, "the delay time of $k")
        return _all_same(c, [a[1], ui], v, src, "$k's input and initial value")
    elseif k === :trend
        _time!(c, a[2], v, src, "the averaging time of trend")
        return _div(_ANY, c.model.time_unit)
    elseif k === :fixed_delay
        _time!(c, _ucheck(c, o.call.kwargs[:τ], v, src), v, src, "the delay τ in x(t - τ)")
        return _all_same(c, [a[1], ui], v, src, "the delayed value and its initial value")
    elseif k === :sample_if_true
        return _all_same(c, [a[2], ui], v, src, "sample_if_true's input and initial value")
    end
    return a[1]                                                     # x(t₀)
end
