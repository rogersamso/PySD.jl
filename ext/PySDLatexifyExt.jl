# LaTeX of models written with @equations, as they are written: Latexify.jl
# writes the expressions, PySD.jl's own forms are written here first (∂t(x),
# x(t₀), sum_over, ifelse, selections).
module PySDLatexifyExt

using PySD
using PySD: Model, EquationSet, Declaration, DeclaredUnit
using Latexify: Latexify, latexraw, LaTeXString

function PySD._latex_model(m::Model, filename::Union{Nothing,AbstractString})
    io = IOBuffer()
    for s in m.sets
        (isempty(s.equations) && isempty(s.declarations)) && continue
        println(io, "\\section*{", _text(_title(s)), "}")
        if !isempty(s.equations)
            println(io, "\\begin{align*}")
            for (i, e) in enumerate(s.equations)
                print(io, _lhs(e.lhs), " &= ", _tex(e.rhs))
                println(io, i < length(s.equations) ? " \\\\" : "")
            end
            println(io, "\\end{align*}")
        end
        if !isempty(s.declarations)
            println(io, "\\begin{longtable}{p{0.3\\linewidth}p{0.2\\linewidth}p{0.4\\linewidth}}")
            println(io, "Name & Unit & Description \\\\ \\hline")
            for d in s.declarations
                println(io, "\$", _name(d.name), "\$ & ", _unit(get(d.metadata, :unit, nothing)), " & ",
                        _text(get(d.metadata, :description, "")), " \\\\")
            end
            println(io, "\\end{longtable}")
        end
    end
    body = String(take!(io))
    filename === nothing || write(filename, """
        \\documentclass{article}
        \\usepackage{amsmath}
        \\usepackage{longtable}
        \\usepackage[margin=2cm]{geometry}
        \\allowdisplaybreaks
        \\begin{document}
        $body
        \\end{document}
        """)
    return body
end

# a component's name, or the file its equations are in (a view of a translated model)
function _title(s::EquationSet)
    s.name === nothing || return string(s.name)
    for d in s.declarations
        f = d.source.file
        f === nothing || return first(splitext(basename(string(f))))
    end
    return "Equations"
end

_text(s) = replace(string(s), r"([\\&%$#_{}])" => s"\\\1", "~" => "\\textasciitilde{}", "^" => "\\^{}")
_name(x) = "\\mathit{" * replace(string(x), "_" => "\\_") * "}"
_unit(::Nothing) = ""
_unit(u::DeclaredUnit) = "\$\\mathrm{" * replace(u.text, "_" => "\\_", "*" => "\\cdot ") * "}\$"
_unit(u) = u === PySD.NoUnits ? "1" : "\$\\mathrm{" * replace(string(u), "_" => "\\_") * "}\$"

# the left of ~: dx/dt, x(t₀), x[part], x
function _lhs(x)
    if x isa Expr && x.head === :call && x.args[1] === :∂t
        return "\\frac{d\\," * _lhs(x.args[2]) * "}{dt}"
    elseif x isa Expr && x.head === :call && length(x.args) == 2 && x.args[2] === :t₀
        return _lhs(x.args[1]) * "(t_0)"
    end
    return _tex(x)
end

_tex(x) = String(latexraw(_forms(x)))

const _REDUCE = Dict(:sum_over => "\\sum", :prod_over => "\\prod",
                     :maximum_over => "\\max", :minimum_over => "\\min")

# PySD.jl's forms as LaTeX, the rest as Julia expressions for Latexify
function _forms(x)
    x === :t && return LaTeXString("t")
    x === :t₀ && return LaTeXString("t_0")
    x === :Δt && return LaTeXString("\\Delta t")
    x isa Symbol && return LaTeXString(_name(x))
    x isa QuoteNode && return LaTeXString(_name(x.value))
    x isa Expr || return x
    if x.head === :ref                                       # x[d = At(:a), …]
        return LaTeXString(_tex(x.args[1]) * "[" * join(_selector.(x.args[2:end]), ", ") * "]")
    elseif x.head === :. && length(x.args) == 2 && x.args[2] isa Expr && x.args[2].head === :tuple
        return _forms(Expr(:call, x.args[1], x.args[2].args...))      # f.(…): f(…)
    elseif x.head === :call
        f = x.args[1]
        args = [a for a in x.args[2:end] if !(a isa Expr && a.head in (:parameters, :kw))]
        f isa Symbol && startswith(string(f), ".") && length(string(f)) > 1 &&
            return _forms(Expr(:call, Symbol(string(f)[2:end]), args...))   # .* as *
        if haskey(_REDUCE, f)
            ds = args[2] isa Expr && args[2].head === :tuple ? args[2].args : [args[2]]
            return LaTeXString(_REDUCE[f] * "_{" * join(_name.(ds), ", ") * "} \\left(" * _tex(args[1]) * "\\right)")
        elseif f === :ifelse && length(args) == 3
            return LaTeXString("\\begin{cases} " * _tex(args[2]) * " & \\text{if } " * _tex(args[1]) *
                               " \\\\ " * _tex(args[3]) * " & \\text{otherwise} \\end{cases}")
        elseif f === :set                                    # dimensions renamed: the same values
            return _forms(args[1])
        end
        f in _MATH && return Expr(:call, f, map(_forms, args)...)     # Latexify's: exp, log, √, …
        # a lookup, a data series, a delayed value, an operator: name(arguments)
        return LaTeXString(_tex(f) * "\\left(" * join(_tex.(args), ", ") * "\\right)")
    elseif x.head === :. && length(x.args) == 2 && x.args[2] isa QuoteNode
        return LaTeXString(_name(string(x.args[1], ".", x.args[2].value)))     # a component's name
    end
    return Expr(x.head, map(_forms, x.args)...)
end

const _MATH = Set([:+, :-, :*, :/, :^, :exp, :log, :log10, :sqrt, :abs, :sin, :cos, :tan,
                   :asin, :acos, :atan, :sinh, :cosh, :tanh, :min, :max, :<, :>, :≤, :≥,
                   :<=, :>=, :(==), :!=, :&, :|, :!])

function _selector(a)
    a isa Expr && a.head === :kw || return _tex(a)
    d, sel = a.args
    _at(s) = s isa Expr && s.head === :call && s.args[1] === :At
    _not(s) = s isa Expr && s.head === :call && s.args[1] === :Not
    _labels(s) = (v = s.args[2]; v isa Expr && v.head === :vect ? "\\{" * join(_tex.(v.args), ", ") * "\\}" : _tex(v))
    _at(sel) && return _labels(sel)
    _not(sel) && _at(sel.args[2]) && return _name(d) * " \\neq " * _labels(sel.args[2])
    return _name(d) * " = " * _tex(sel)
end

end
