# A model's names as a table: what each one is, its unit and description, as
# declared.  Nothing is stored twice: the table reads the declarations.

"""
    variables(model; helpers = false)

A table (Tables.jl; `DataFrame(variables(m))`) of the model's names, one row
each, read from their declarations:

- `name`: the name in the model (`:teacup_temperature`; `Symbol("retailer.inventory")` in a component)
- `title`: the name to show: the declaration's `title = "…"` (in a translated
  model, the name as written in the original), or `name`
- `set`: the title of the equation set it is declared in (`@equations title = "…" begin`;
  in a translated model, the view), else the set's name, else `""`
- `kind`: `:stock`, `:aux` (changes with time), `:constant` (computed once) or `:parameter` (set by a run's `params`)
- `unit`: the declared unit as written (`"W/(m*m)"`, `""` for `NoUnits`)
- `description`: the declaration's `description`, or `""`
- `limits`: the declaration's `limits = (min, max)` or `(min, max, step)`, or `nothing`
- `dims`: the names of its dimensions (`(:region, :sector)`), `()` for a scalar
- `elements`: the labels along each dimension

`helpers = true` also lists the names a translator adds (declared with
`helper = true`: a lookup of its own, an initial value by parts…).

Other metadata keys are free: a declaration can carry anything an interface
needs (`[unit = u"m", description = "…", group = "Energy"]`).
"""
function variables(m::Model; helpers::Bool = false)
    vs = [v for v in m.vars if helpers || !_meta(v, :helper, false)]
    return (name = Symbol[v.name for v in vs],
            title = String[string(_meta(v, :title, v.name)) for v in vs],
            set = String[_set_title(m.sets[v.set]) for v in vs],
            kind = Symbol[v.kind for v in vs],
            unit = String[_unit_text(_meta(v, :unit, NoUnits)) for v in vs],
            description = String[string(_meta(v, :description, "")) for v in vs],
            limits = Union{Nothing,Tuple}[_limits(_meta(v, :limits, nothing)) for v in vs],
            dims = Tuple[Tuple(DimensionalData.name.(v.dims)) for v in vs],
            elements = Tuple[Tuple(string.(DimensionalData.lookup(d)) for d in v.dims) for v in vs])
end

_meta(v, key, default) = get(v.decl.metadata, key, default)

_set_title(s::EquationSet) =
    string(get(s.metadata, :title, s.name === nothing ? "" : s.name))

_unit_text(u::DeclaredUnit) = u.text
_unit_text(u) = u === Unitful.NoUnits ? "" : string(u)

_limits(::Nothing) = nothing
_limits(x::Tuple) = (length(x) in (2, 3) && all(y -> y isa Real, x)) ? Tuple(float.(x)) :
    throw(ArgumentError("limits are (min, max) or (min, max, step), not $(repr(x))"))
_limits(x) = throw(ArgumentError("limits are (min, max) or (min, max, step), not $(repr(x))"))
