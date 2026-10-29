module PySD

using DataInterpolations
import Libdl
import LinearAlgebra
import NaNMath
using FunctionWrappers: FunctionWrapper
using NCDatasets
using Random
using Symbolics
using XLSX
using LibXLS
using DelimitedFiles: readdlm
using DimensionalData
using DimensionalData: AbstractDimArray, DimArray, broadcast_dims
using RuntimeGeneratedFunctions
import PrecompileTools
import Tables
import Unitful
using Unitful: @u_str, NoUnits

RuntimeGeneratedFunctions.init(@__MODULE__)

const PYSD_JL_VERSION = let
    proj = joinpath(@__DIR__, "..", "Project.toml")
    m = match(r"version\s*=\s*\"([^\"]+)\"", read(proj, String))
    VersionNumber(m[1])
end

"""
    check_compat(built_with::VersionNumber)

Verify that the installed PySD.jl is compatible with the version the model
was translated against.  Raises an error when the major version differs.
"""
function check_compat(built_with::VersionNumber)
    if PYSD_JL_VERSION.major != built_with.major
        error(
            "This model was translated with PySD.jl v", built_with,
            " but the installed version is v", PYSD_JL_VERSION,
            ". Major-version mismatch — please update PySD.jl or re-translate the model."
        )
    end
    if PYSD_JL_VERSION < built_with
        @warn(
            "This model was translated with PySD.jl v$built_with " *
            "but the installed version is v$PYSD_JL_VERSION (older). " *
            "Some features may be missing."
        )
    end
end

export pysd_trunc, pysd_log_base, pysd_ln, pysd_sqrt, pysd_asin, pysd_acos,
       pysd_exp, pysd_sin, pysd_cos, pysd_tan, pysd_atan, pysd_sinh, pysd_cosh,
       pysd_xidz, pysd_zidz,
       pysd_pulse, pysd_pulse_train, pysd_ramp, pysd_step,
       pysd_active_initial, pysd_ifelse,
       pysd_inv_mat2d_elem, pysd_inv_mat3d_elem,
       pysd_invert_matrix, pysd_elmcount, pysd_sum, pysd_sum_seq,
       pysd_power, pysd_quantum, pysd_pi,
       pysd_xpulse, pysd_xpulse_train, pysd_xramp,
       pysd_random_0_1, pysd_random_uniform,
       pysd_random_normal, pysd_random_exponential,
       pysd_vector_select, pysd_vector_sort_order,
       pysd_vector_reorder, pysd_vector_rank,
       pysd_get_time_value,
       pysd_logical_and, pysd_logical_or, pysd_logical_not,
       pysd_safe, SafeArray,
       pysd_xlsx_read_constant, pysd_xlsx_read_series,
       pysd_xlsx_build_lookup_dispatch,
       pysd_allocate_by_priority, pysd_allocate_available,
       pysd_tab_read_series, pysd_build_tab_itp,
       pysd_export_latex,
       pysd_input, pysd_lookup, pysd_check_inputs, pysd_check_fixed, pysd_file, PySDFunction,
       save_results,
       check_compat, PYSD_JL_VERSION

# the DSL (src/dsl).  The functions for equations (smooth, sum_over, …) are
# found by @equations without being exported; new stateful operators extend
# PySD.nstates, PySD.initial_states, PySD.rates! and PySD.output.
export @equations, EquationSet, Model, run_model, Results, StatefulOperator, excel, check_units,
       series_file, @precompile_model, @u_str, NoUnits, PySDUnits

include("libm.jl")
include("helpers.jl")
include("xlsx.jl")
include("latex.jl")
include("save_results.jl")
include("params.jl")
include("dsl/units.jl")
include("dsl/syntax.jl")
include("dsl/operators.jl")
include("dsl/history.jl")
include("dsl/inputs.jl")
include("dsl/resolve.jl")
include("dsl/build.jl")
include("dsl/lower.jl")
include("dsl/numerics.jl")
include("dsl/codegen.jl")
include("dsl/run.jl")
include("dsl/tables.jl")
include("dsl/units_check.jl")
include("dsl/latex.jl")

__init__() = _load_libm()

end
