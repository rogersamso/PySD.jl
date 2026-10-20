# Save ODE simulation results to a NetCDF file.

using NCDatasets

"""
    save_results(sol, state_map, dim_labels, path)

ODE-backend variant.  `state_map` is a vector of `(name, index, dim_names)`
and `dim_labels` maps each subscript range name to its element labels.
Scalar state variables are saved with dimension `(time,)`.  Subscripted
state variables get one NetCDF dimension per subscript range, named after
the range and holding its element labels, in the file order
`(time, dim_1, ..., dim_n)`.
"""
function save_results(
    sol,
    state_map::AbstractVector,
    dim_labels::Dict,
    path::AbstractString,
)
    ts = sol.t
    NCDatasets.Dataset(path, "c") do ds
        ds.attrib["Conventions"] = "CF-1.8"
        NCDatasets.defDim(ds, "time", length(ts))
        vt = NCDatasets.defVar(ds, "time", Float64, ("time",))
        vt[:] = ts
        vt.attrib["units"] = "1"

        for (name, idx, subs) in state_map
            if isempty(subs)
                v = NCDatasets.defVar(ds, name, Float64, ("time",))
                v[:] = sol[idx, :]
            else
                shape = Tuple(length(dim_labels[d]) for d in subs)
                n = prod(shape)
                for d in subs
                    if !haskey(ds.dim, d)
                        NCDatasets.defDim(ds, d, length(dim_labels[d]))
                        coord = NCDatasets.defVar(ds, d, String, (d,))
                        coord[:] = dim_labels[d]
                    end
                end
                # The state vector holds the stock column-major (as reshaped in
                # rhs!).  NCDatasets lists dimensions fastest-varying first, so
                # (dim_n, ..., dim_1, time) is (time, dim_1, ..., dim_n) in the file.
                nd = length(shape)
                data = Array{Float64}(undef, reverse(shape)..., length(ts))
                for (i, u) in enumerate(sol.u)
                    block = reshape(u[idx:idx + n - 1], shape)
                    selectdim(data, nd + 1, i) .= permutedims(block, nd:-1:1)
                end
                v = NCDatasets.defVar(ds, name, Float64, (reverse(subs)..., "time"))
                v[:] = data
            end
        end
    end
    return path
end
