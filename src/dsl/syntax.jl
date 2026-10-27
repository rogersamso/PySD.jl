# The @equations macro: it only captures.  A block becomes an EquationSet
# holding the declarations, the equations as expressions, and the Julia values
# the block uses (functions, dimensions, settings such as `rule`).  Julia `for`
# loops in the block run when the set is built, and write one equation per
# value.  `Model` does the rest (build.jl).

"A declared name: a parameter (a given value) or a variable (one equation)."
struct Declaration
    name::Symbol
    kind::Symbol                 # :parameter or :variable
    timevarying::Bool            # x(t)
    dims::Vector{Any}            # Dim values
    default::Any                 # expression: a parameter's value, an input's default
    metadata::Dict{Symbol,Any}   # unit, description, nonnegative, input, output
    source::LineNumberNode
end

"An equation `lhs ~ rhs`, after the loops around it have run."
struct Equation
    lhs::Any
    rhs::Any
    source::LineNumberNode
end

"""
    EquationSet

What `@equations` returns: declarations, equations and the Julia values they
use.  A set with a name is a component; its names get the name as a prefix
(`retailer.inventory`).
"""
struct EquationSet
    name::Union{Nothing,Symbol}
    declarations::Vector{Declaration}
    equations::Vector{Equation}
    env::Dict{Symbol,Any}
end

Base.show(io::IO, s::EquationSet) =
    print(io, "EquationSet(", s.name === nothing ? "" : repr(s.name) * ", ",
          length(s.declarations), " names, ", length(s.equations), " equations)")

# A component's variable, `retailer.incoming_orders`, used in an equation.
Base.getproperty(s::EquationSet, name::Symbol) =
    name in fieldnames(EquationSet) ? getfield(s, name) : ComponentRef(s, name)

struct ComponentRef
    set::EquationSet
    name::Symbol
end

"""
    @equations [name] begin
        @parameters begin
            τ = 10, [unit = u"minute", description = "Characteristic time"]
        end
        @variables begin
            temperature(t), [unit = u"°F"]
        end
        ∂t(temperature) ~ -(temperature - room_temperature) / τ
        temperature(t₀) ~ 180
    end

A set of equations with the declarations of their names.  `@parameters` are
given values, `@variables` have an equation (`x(t)` when they change with
time); each declaration carries `[unit = …]` and optionally `description`,
`nonnegative`, `input`, `output`.  Equations use `~`.  With a `name`, the set
is a component.  `Model` builds a model from one or more sets.
"""
macro equations(args...)
    length(args) in (1, 2) || throw(ArgumentError("use @equations [name] begin … end"))
    name = length(args) == 2 ? args[1] : nothing
    block = args[end]
    (block isa Expr && block.head === :block) ||
        throw(ArgumentError("@equations needs a begin … end block"))
    return esc(_equations_code(name, block, __source__))
end

const _RESERVED = (:t, :t₀, :Δt, :∂t, :end, :begin, :nothing, :true, :false)

function _equations_code(name, block, source)
    decls, eqs, env = gensym(:declarations), gensym(:equations), gensym(:env)
    body = Any[]
    declared = Symbol[]
    used = Set{Symbol}()
    _statements!(body, block, decls, eqs, Symbol[], declared, used, source)
    captures = [:(@isdefined($s) && ($env[$(QuoteNode(s))] = $s))
                for s in sort!(collect(setdiff(used, declared, _RESERVED))) if Base.isidentifier(s)]
    return quote
        let $decls = $Declaration[], $eqs = $Equation[], $env = Dict{Symbol,Any}()
            $(body...)
            $(captures...)
            $EquationSet($(name === nothing ? nothing : name), $decls, $eqs, $env)
        end
    end
end

function _statements!(body, block, decls, eqs, loopvars, declared, used, source)
    for s in block.args
        if s isa LineNumberNode
            source = s
        elseif s isa Expr && s.head === :macrocall && s.args[1] in (Symbol("@parameters"), Symbol("@variables"))
            kind = s.args[1] === Symbol("@parameters") ? :parameter : :variable
            for d in _declaration_lines(s)
                d isa LineNumberNode && (source = d; continue)
                push!(body, _declaration_code(d, kind, decls, loopvars, declared, used, source))
            end
        elseif s isa Expr && s.head === :call && s.args[1] === :~ && length(s.args) == 3
            _symbols!(used, s.args[2], loopvars)
            _symbols!(used, s.args[3], loopvars)
            push!(body, :(push!($eqs, $Equation($(_quoted(s.args[2], loopvars)),
                                                $(_quoted(s.args[3], loopvars)),
                                                $(QuoteNode(source))))))
        elseif s isa Expr && s.head === :for
            iters = s.args[1].head === :block ? s.args[1].args : [s.args[1]]
            vars = copy(loopvars)
            for it in iters
                it isa LineNumberNode && continue
                _symbols!(used, it.args[2], loopvars)
                _loopvars!(vars, it.args[1])
            end
            inner = Any[]
            _statements!(inner, s.args[2], decls, eqs, vars, declared, used, source)
            push!(body, Expr(:for, s.args[1], Expr(:block, inner...)))
        else
            error("$(source.file):$(source.line): @equations takes declarations " *
                  "(@parameters, @variables), equations (a ~ b) and for loops, not `$s`")
        end
    end
end

_declaration_lines(s) = filter(a -> a isa Expr || a isa LineNumberNode, s.args[3:end]) |> lines ->
    (length(lines) == 1 && lines[1] isa Expr && lines[1].head === :block) ? lines[1].args : lines

_loopvars!(vars, s::Symbol) = push!(vars, s)
_loopvars!(vars, s::Expr) = foreach(a -> _loopvars!(vars, a), s.args)

# One declaration line:  name, [meta]  |  name(t), [meta]  |  name[dims], [meta]
# |  name(t)[dims], [meta]  |  name = default, [meta]  (parameters, inputs)
function _declaration_code(d, kind, decls, loopvars, declared, used, source)
    default = nothing
    if d isa Expr && d.head === :(=)
        lhs, rest = d.args[1], _unblock(d.args[2])
        if rest isa Expr && rest.head === :tuple && length(rest.args) == 2
            default, meta = rest.args
            d = Expr(:tuple, lhs, meta)
        else
            default = rest
            d = lhs
        end
    end
    target, meta = (d isa Expr && d.head === :tuple && length(d.args) == 2) ? (d.args[1], d.args[2]) :
                   (d, nothing)
    meta === nothing && error("$(source.file):$(source.line): `$target` has no metadata: " *
                              "every name is declared with [unit = …]")
    (meta isa Expr && meta.head === :vect) ||
        error("$(source.file):$(source.line): metadata of `$target` must be [key = value, …]")
    dims = Any[]
    if target isa Expr && target.head === :ref
        append!(dims, target.args[2:end])
        target = target.args[1]
    end
    timevarying = false
    if target isa Expr && target.head === :call && target.args[2:end] == [:t]
        timevarying = true
        target = target.args[1]
    end
    target isa Symbol || error("$(source.file):$(source.line): can't read the declaration `$d`")
    push!(declared, target)
    foreach(x -> _symbols!(used, x, loopvars), dims)
    default === nothing || _symbols!(used, default, loopvars)
    pairs = map(meta.args) do m
        (m isa Expr && m.head in (:(=), :kw) && m.args[1] isa Symbol) ||
            error("$(source.file):$(source.line): metadata must be key = value, not `$m`")
        val = m.args[2]
        if m.args[1] === :unit && val isa Expr && val.head === :macrocall && val.args[1] === Symbol("@u_str")
            val = :($_unit($(val.args[end])))                # read here: °C and °F without their offset
        end
        :($(QuoteNode(m.args[1])) => $val)
    end
    return :(push!($decls, $Declaration($(QuoteNode(target)), $(QuoteNode(kind)), $timevarying,
                                        Any[$(dims...)], $(_quoted(default, loopvars)),
                                        Dict{Symbol,Any}($(pairs...)), $(QuoteNode(source)))))
end

_unblock(x) = (x isa Expr && x.head === :block) ?
    only(filter(a -> !(a isa LineNumberNode), x.args)) : x

# An expression to keep, with the loop variables' values put in when the loop runs.
_quoted(x, loopvars) = isempty(loopvars) ? QuoteNode(x) : Expr(:quote, _interpolate(x, loopvars))
_interpolate(x::Symbol, loopvars) = x in loopvars ? Expr(:$, :($_literal($x))) : x
_interpolate(x::Expr, loopvars) = Expr(x.head, (_interpolate(a, loopvars) for a in x.args)...)
_interpolate(x, loopvars) = x

# a value written into an expression: symbols as labels (:layer1), not names
_literal(x::Symbol) = QuoteNode(x)
_literal(x) = x

# The names an expression uses: not keyword names, field names after `.`,
# names bound by comprehensions and generators, or quoted symbols.
_symbols!(used, x::Symbol, bound) = (x in bound || push!(used, x); used)
_symbols!(used, x, bound) = used
function _symbols!(used, x::Expr, bound)
    if x.head === :quote || x.head === :inert
        return used
    elseif x.head === :. && length(x.args) == 2 && x.args[2] isa QuoteNode
        return _symbols!(used, x.args[1], bound)
    elseif x.head in (:kw, :(=)) && x.args[1] isa Symbol
        return _symbols!(used, x.args[2], bound)       # keyword arguments, selectors
    elseif x.head === :generator || x.head === :flatten
        inner = copy(bound)
        for it in x.args[2:end]
            its = it isa Expr && it.head === :filter ? it.args[2:end] : [it]
            for i in its
                i isa Expr && i.head === :(=) || continue
                _symbols!(used, i.args[2], inner)
                _loopvars!(inner, i.args[1])
            end
        end
        return _symbols!(used, x.args[1], inner)
    elseif x.head === :call && x.args[1] === :~
        return used
    end
    for a in x.args
        _symbols!(used, a, bound)
    end
    return used
end

# A unit as Unitful reads it, except that units with an offset (°C, °F) are
# used without it: a model never converts between units, so a temperature and
# a temperature change have the same unit.
_unit(s::AbstractString) = _unit_value(Meta.parse(s))
_unit_value(x::Number) = x
function _unit_value(x::Symbol)
    u = Unitful.uparse(string(x); unit_context = unique!([Unitful; Unitful.unitmodules]))
    return u isa Unitful.AffineUnits ? Unitful.absoluteunit(u) : u
end
function _unit_value(x::Expr)
    x.head === :call || error("can't read the unit `$x`")
    f = x.args[1]
    f in (:*, :/, :^, :inv, :sqrt) || error("can't read the unit `$x`")
    return getfield(Base, f)(map(_unit_value, x.args[2:end])...)
end
