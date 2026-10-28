# The equations of a model written with @equations, as LaTeX (the rendering is
# in ext/PySDLatexifyExt.jl, loaded with Latexify.jl).

"""
    pysd_export_latex(m::Model; filename = nothing)

The equations of a model written with `@equations`, as LaTeX, the way they are
written: a section per set of equations (a view of a translated model), with
its equations (`∂t(x)` as dx/dt, `sum_over` as Σ, `ifelse` as cases, selections
as `x[a]`) and a table of its names, units and descriptions.  Needs Latexify.jl
(`using Latexify`).  With `filename`, it also writes a document that compiles
on its own.

```julia
using PySD, Latexify
m = include("model_dsl/model.jl")
pysd_export_latex(m; filename = "model.tex")
```
"""
pysd_export_latex(m::Model; filename::Union{Nothing,AbstractString} = nothing) = _latex_model(m, filename)

_latex_model(m, filename) =
    error("LaTeX export needs Latexify.jl: `using Latexify` (installed with `using Pkg; Pkg.add(\"Latexify\")`)")
