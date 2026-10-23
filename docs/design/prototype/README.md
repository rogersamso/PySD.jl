# Prototype: output styles

Hand-written versions of three test models in the proposed styles, used for
[`../output-styles.md`](../output-styles.md):

| Folder | Model (SDXorg/test-models) |
|---|---|
| `models/subscript_2d_arrays` | 2D stock with constants |
| `models/subscript_transposition` | sums over a dimension, transposed |
| `models/smooth` | SMOOTH, SMOOTHI, SMOOTH3, SMOOTH3I, SMOOTH N |
| `models/scaled` | synthetic 200 × 50 model, for timing |

Each folder has `ode.jl` (cleaner ODE style), `mtk.jl` (hand-written
ModelingToolkit) and `dsl.jl` (DSL syntax sketch: valid Julia syntax, no macro yet).
`Proto.jl` holds the draft helpers of the ODE style.

## Running

```sh
cd docs/design/prototype
julia --project=. -e 'using Pkg; Pkg.develop(path="../../.."); Pkg.add(["OrdinaryDiffEq", "ComponentArrays", "ModelingToolkit", "DynamicalSystemsBase", "BenchmarkTools"])'
git submodule update --init ../../../test/test-models    # reference outputs

julia --project=. check.jl subscript_2d_arrays           # ODE style vs reference
julia --project=. check_mtk.jl subscript_2d_arrays       # MTK style vs reference
julia --project=. ds_demo.jl                             # DynamicalSystems: step!, set_parameter!

python make_scaled.py generated/scaled                   # needs PySD (Python): current builder output
julia --project=. bench_scaled.jl generated/scaled/scaled.jl
```
