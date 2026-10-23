# Vensim built-in function implementations for ModelingToolkit.
#
# All conditions use `ifelse` + `&`/`|` instead of `?:` / `&&` / `||` so
# they remain valid when called with symbolic (Num) arguments inside MTK
# equations.

# Base.trunc is not available as a symbolic primitive in MTK.
# Register a thin wrapper so INTEGER(x) / INT(x) works inside equations.
pysd_trunc(x::Real) = Base.trunc(x)
@register_symbolic pysd_trunc(x::Real)

pysd_log_base(x, base) = log(base, x)

# What Vensim considers zero.  Times accumulated by fixed Euler steps carry
# rounding errors, so pulses start up to SMALL_VENSIM early (as in Python PySD).
const SMALL_VENSIM = 1e-6

# XIDZ and ZIDZ treat denominators smaller than SMALL_VENSIM as zero, as
# Python PySD.  The comparison stays symbolic for MTK variables (iszero of
# a symbolic variable is always false).
pysd_xidz(x, y, z) = ifelse(abs(y) < SMALL_VENSIM, z, x / y)

pysd_zidz(x, y) = ifelse(abs(y) < SMALL_VENSIM, 0.0, x / y)

pysd_pulse(t_now, start, width) =
    ifelse((t_now >= start - SMALL_VENSIM) & (t_now < start + width), 1.0, 0.0)

# NOTE: the Vensim parser reorders PULSE TRAIN(start, width, interval, end)
# to CallStructure arguments (start, interval, width, end).  The end time is
# excluded, as in Vensim and Python PySD.
pysd_pulse_train(t_now, start, interval, width, end_time) =
    ifelse((t_now >= start) & (t_now < end_time) &
           (mod(t_now - start + SMALL_VENSIM, interval) < width), 1.0, 0.0)

pysd_ramp(t_now, slope, start_time, end_time=Inf) =
    slope * max(0.0, min(t_now - start_time, end_time - start_time))

pysd_step(t_now, height, step_time) =
    ifelse(t_now >= step_time, float(height), 0.0)

# Vensim logical operators — values are always 0.0 (false) or 1.0 (true).
# Return Symbolic{Bool} via comparisons so the result can be used as the
# condition of a symbolic `ifelse` in MTK equations.
pysd_logical_and(a, b) = (a > 0.5) & (b > 0.5)
pysd_logical_or(a, b)  = (a > 0.5) | (b > 0.5)
pysd_logical_not(a)    = !(a > 0.5)

# ACTIVE INITIAL(expr, initial) — in ODE mode expr is always live;
# we just return expr (the first argument).
pysd_active_initial(expr, initial) = expr

# Symbolics' `ifelse` has type issues with `SymReal` conditions, so PySD
# emits `pysd_ifelse` instead.  A concrete Bool dispatches to the ternary;
# a symbolic / numeric condition compares against 0.5 then defers to `ifelse`.
pysd_ifelse(cond::Bool, a, b) = cond ? a : b
pysd_ifelse(cond, a, b) = ifelse(cond > 0.5, a, b)

# INVERT_MATRIX helpers — registered as symbolic black boxes so Symbolics
# does not attempt symbolic matrix algebra (which hangs for large matrices).
# At solve time the concrete array is passed and inv is computed numerically.
function pysd_inv_mat2d_elem(mat::AbstractMatrix, i::Int, j::Int)
    return inv(mat)[i, j]
end
@register_symbolic pysd_inv_mat2d_elem(mat::AbstractMatrix, i::Int, j::Int)

function pysd_inv_mat3d_elem(mat::AbstractArray, b::Int, i::Int, j::Int)
    return inv(mat[b, :, :])[i, j]
end
@register_symbolic pysd_inv_mat3d_elem(mat::AbstractArray, b::Int, i::Int, j::Int)

pysd_invert_matrix(m::AbstractArray, n) = vec(inv(reshape(m, Int(n), Int(n))))
pysd_invert_matrix(m, n) = m

pysd_elmcount(n) = Float64(n)

# Vensim POWER, also used for `^`: x^y.  A negative base with a non-integer
# exponent gives NaN (as numpy.power) instead of throwing a DomainError.
pysd_power(x, y) = x < 0 && !isinteger(y) ? NaN : float(x)^y
@register_symbolic pysd_power(x::Real, y::Real)

struct SafeArray{T,N,A<:AbstractArray{T,N}} <: AbstractArray{T,N}
    data::A
end
Base.size(s::SafeArray) = size(s.data)
Base.getindex(s::SafeArray{T,1}, i::Integer) where T =
    checkbounds(Bool, s.data, i) ? s.data[i] : zero(T)
Base.getindex(s::SafeArray{T,2}, i::Integer, j::Integer) where T =
    checkbounds(Bool, s.data, i, j) ? s.data[i, j] : zero(T)
Base.getindex(s::SafeArray{T}, idx::Integer...) where T =
    checkbounds(Bool, s.data, idx...) ? s.data[idx...] : zero(T)
function Base.setindex!(s::SafeArray, v, idx...)
    checkbounds(Bool, s.data, idx...) && (s.data[idx...] = v)
    return v
end
pysd_safe(x::AbstractArray) = SafeArray(x)
pysd_safe(x) = x

pysd_quantum(a, b) = ifelse(b < 1e-6, float(a), b * pysd_trunc(a / b))
@register_symbolic pysd_quantum(a::Real, b::Real)

pysd_pi() = Base.MathConstants.pi

# XMILE variants: Xpulse has (start, magnitude), Xramp has (slope, start)
# XMILE PULSE(magnitude, start[, interval]): `magnitude / time_step` during one
# time step at `start` (and every `interval` after it), as in Python PySD.
pysd_xpulse(t_now, start, magnitude, time_step) =
    ifelse((t_now >= start - SMALL_VENSIM) & (t_now < start + time_step / 2),
           magnitude / time_step, 0.0)

pysd_xpulse_train(t_now, start, interval, magnitude, time_step) =
    ifelse((t_now >= start) &
           (mod(t_now - start + SMALL_VENSIM, interval) < time_step / 2),
           magnitude / time_step, 0.0)

# Without time_step: models translated by PySD before PySD.jl 0.2.1.  Kept so
# they still run, with their previous (non-Vensim) behaviour.
function pysd_xpulse(t_now, start, magnitude)
    @warn "XMILE PULSE called without the time step (model translated by an older PySD): " *
          "results differ from Vensim; re-translate the model." maxlog = 1
    ifelse((t_now >= start) & (t_now < start + magnitude), magnitude, 0.0)
end

function pysd_xpulse_train(t_now, start, interval, magnitude)
    @warn "XMILE PULSE called without the time step (model translated by an older PySD): " *
          "results differ from Vensim; re-translate the model." maxlog = 1
    ifelse((t_now >= start) & (mod(t_now - start, interval) < magnitude), magnitude, 0.0)
end

pysd_xramp(t_now, slope, start_time) =
    slope * max(0.0, t_now - start_time)

# Random functions — opaque wrappers so MTK calls them at every timestep
pysd_random_0_1() = Base.rand()
@register_symbolic pysd_random_0_1()

pysd_random_uniform(lo, hi, _seed) = lo + (hi - lo) * Base.rand()
@register_symbolic pysd_random_uniform(lo::Real, hi::Real, _seed::Real)

function pysd_random_normal(lo, hi, mean, std, _seed)
    x = mean + std * Base.randn()
    return clamp(x, lo, hi)
end
@register_symbolic pysd_random_normal(lo::Real, hi::Real, mean::Real, std::Real, _seed::Real)

function pysd_random_exponential(lo, hi, mean, _seed)
    x = lo + mean * Random.randexp()
    return clamp(x, lo, hi)
end
@register_symbolic pysd_random_exponential(lo::Real, hi::Real, mean::Real, _seed::Real)

# Vector operations
function pysd_vector_select(sel_vec, expr_vec, miss_val, action)
    selected = [expr_vec[i] for i in eachindex(sel_vec) if sel_vec[i] != 0]
    isempty(selected) && return miss_val
    action == 0 && return selected[1]
    action == 1 && return sum(selected)
    action == 2 && return maximum(selected)
    action == 3 && return minimum(selected)
    action == 4 && return sum(selected) / length(selected)
    return miss_val
end

# VECTOR SORT ORDER returns 0-based positions (as Vensim and Python PySD);
# VECTOR REORDER takes them.
"""
    pysd_vector_select(sel, expr, missing_vals, numerical_action, error_action)

Vensim's VECTOR SELECT, as Python PySD: the elements of `expr` where `sel` is
non-zero are combined by `numerical_action` (0 sum of sel*expr, 1 product of
sel*expr, 2 min of sel*expr, 3 max of sel*expr, 4 mean of sel*expr,
5 product of expr^sel, 6 sum, 7 product, 8 min, 9 max, 10 mean of expr).
`missing_vals` is returned when `sel` is all zeros.  `error_action` 1 (or 3)
raises when `sel` is all zeros, 2 (or 3) when it has more than one non-zero.
`sel` and `expr` are broadcast together (e.g. a matrix and a vector).
"""
function pysd_vector_select(sel, expr, missing_vals, numerical_action, error_action)
    S = sel .+ zero.(expr)
    E = expr .+ zero.(sel)
    nz = S .!= 0
    if !any(nz)
        error_action in (1, 3) &&
            throw(DomainError(sel, "VECTOR SELECT: all the values of the selection array are 0"))
        return Float64(missing_vals)
    end
    count(nz) > 1 && error_action in (2, 3) &&
        throw(DomainError(sel, "VECTOR SELECT: more than one non-zero value in the selection array"))
    action = Int(numerical_action)
    vals = if action in 0:4
        (S .* E)[nz]
    elseif action == 5
        (E .^ S)[nz]         # as Vensim (its help says sel ^ expr)
    elseif action in 6:10
        E[nz]
    else
        throw(ArgumentError("VECTOR SELECT: numerical_action must be 0 to 10, got $numerical_action"))
    end
    action in (0, 6) && return Float64(sum(vals))
    action in (1, 5, 7) && return Float64(prod(vals))
    action in (2, 8) && return Float64(minimum(vals))
    action in (3, 9) && return Float64(maximum(vals))
    return Float64(sum(vals) / length(vals))
end

pysd_vector_sort_order(vec, dir) =
    Float64.(ifelse(dir > 0, sortperm(vec), sortperm(vec, rev=true)) .- 1)

pysd_vector_reorder(vec, order) = vec[Int.(order) .+ 1]

pysd_vector_rank(vec, dir) =
    Float64.(invperm(ifelse(dir > 0, sortperm(vec), sortperm(vec, rev=true))))

pysd_get_time_value(t_now, lookup_fn, lo, hi) =
    lookup_fn(clamp(t_now, lo, hi))

# ---------------------------------------------------------------------------
# ALLOCATE BY PRIORITY
# Implements Vensim's ALLOCATE BY PRIORITY algorithm exactly:
# supply is distributed from highest to lowest priority with a linear
# transition zone of width `width` before the next-lower target activates.
# ---------------------------------------------------------------------------
function pysd_allocate_by_priority(
        request ::AbstractVector{<:Real},
        priority::AbstractVector{<:Real},
        width   ::Real,
        supply  ::Real)

    n = length(request)
    supply = Float64(supply)
    total_req = sum(request)

    total_req <= 0.0 && return zeros(n)
    supply >= total_req && return Float64.(collect(request))
    supply <= 0.0      && return zeros(n)
    width  <= 0.0      && error("pysd_allocate_by_priority: width must be positive")

    # Remove zero-request targets; sort remaining by priority descending
    nz    = findall(!=(0), request)
    req   = Float64.(request[nz])
    pri   = Float64.(priority[nz])
    m     = length(req)
    perm  = sortperm(pri, rev=true)
    req   = req[perm];  pri = pri[perm]

    out    = zeros(m)
    # distances[i] = supply consumed by target i before target i+1 activates
    dist   = fill(Inf, m)
    for i in 1:m-1
        dist[i] = min(1.0, (pri[i] - pri[i+1]) / width) * req[i]
    end

    active = falses(m);  active[1] = true
    c_i    = 1
    rem    = supply

    while rem > 1e-14
        act = req .* active
        s   = sum(act)
        s <= 0.0 && break
        slopes = act ./ s

        # supply until any active target saturates
        dx_top = Inf
        for i in 1:m
            active[i] || continue
            v = (req[i] - out[i]) / slopes[i]
            v < dx_top && (dx_top = v)
        end

        # supply until c_i reaches its distance → next target starts
        dx_start = Inf
        if c_i <= m && slopes[c_i] > 0.0
            dx_start = (dist[c_i] - out[c_i]) / slopes[c_i]
        end

        dx = min(dx_top, dx_start, rem)
        dx = max(dx, 0.0)
        out .+= slopes .* dx

        # activate next target if its distance was reached
        if dx >= dx_start - 1e-14 && c_i < m
            c_i += 1
            active[c_i] = true
        end
        # deactivate saturated targets
        for i in 1:m
            if active[i] && out[i] >= req[i] - 1e-14
                out[i] = req[i]
                active[i] = false
            end
        end
        rem -= dx
        rem < 0.0 && break
    end

    # Map back to full output array in original order
    result = zeros(n)
    result[nz] = out[invperm(perm)]
    return result
end

# ---------------------------------------------------------------------------
# ALLOCATE AVAILABLE
# Implements Vensim's ALLOCATE AVAILABLE algorithm.
# `pp` is an (n×4) matrix: columns are [pprofile, ppriority, pwidth, pextra]
# Supported profiles: 1=rectangular, 2=triangular, 3=normal, 4=exponential.
# The equilibrium "price" x* where sum(demand_i(x*)) = avail is found by
# bisection over the monotone total-demand function.
# ---------------------------------------------------------------------------
function _pysd_demand_at_price(q0, pprofile, ppriority, pwidth, x)
    prof = round(Int, pprofile)
    q0   = Float64(q0)
    if q0 <= 0.0
        return 0.0
    end
    if prof == 1  # rectangular
        lo = ppriority - pwidth / 2
        hi = ppriority + pwidth / 2
        x <= lo && return q0
        x >= hi && return 0.0
        return q0 * (1.0 - (x - lo) / pwidth)
    elseif prof == 2  # triangular
        lo = ppriority - pwidth / 2
        hi = ppriority + pwidth / 2
        x <= lo && return q0
        x >= hi && return 0.0
        if x < ppriority
            return q0 * (1.0 - 2.0 * (x - lo)^2 / pwidth^2)
        else
            return 2.0 * q0 * (hi - x)^2 / pwidth^2
        end
    elseif prof == 3  # normal (uses erfc from SpecialFunctions via Symbolics)
        # erfc(x) ≈ 2*Φ(-x*sqrt(2)) where Φ is the standard normal CDF
        # We approximate using a rational fit (max error < 1e-7)
        t = (x - ppriority) / (pwidth * sqrt(2.0))
        return q0 * 0.5 * _pysd_erfc(t)
    elseif prof == 4  # exponential
        if x < ppriority
            return q0 * (1.0 - 0.5 * exp((x - ppriority) / pwidth))
        else
            return q0 * 0.5 * exp((ppriority - x) / pwidth)
        end
    else
        return 0.0  # unsupported profile
    end
end

"""
    pysd_tab_read_series(filepath, colname) -> (times, vals)

Read a tab- or comma-separated Vensim output file and return the time series
for the column named `colname`.  Matching is case-insensitive and
leading/trailing whitespace is ignored.

Accepts Unix, Windows and old Mac (CR only) line endings.  Uses only Julia
Base functions — no extra packages required.
"""
function pysd_tab_read_series(filepath::AbstractString, colname::AbstractString)
    sep = endswith(lowercase(filepath), ".tab") ? '\t' : ','
    content = read(filepath, String)
    isempty(strip(content)) && error("Empty file: $filepath")
    # split on any line ending: Vensim writes Unix, Windows and old Mac (CR only) files
    raw = split(content, r"\r\n|\r|\n")

    header = strip.(split(raw[1], sep))
    target = strip(colname)
    col_idx = findfirst(h -> lowercase(h) == lowercase(target), header)
    col_idx === nothing &&
        error("Column '$(colname)' not found in '$(filepath)'.\nAvailable: " * join(header, ", "))

    times = Float64[]
    vals  = Float64[]
    for line in raw[2:end]
        stripped = rstrip(line, ['\r', '\n'])  # keep empty trailing cells
        isempty(strip(stripped)) && continue
        fields = split(stripped, sep)
        t_str = strip(fields[1])
        v_str = col_idx <= length(fields) ? strip(fields[col_idx]) : ""
        isempty(t_str) && continue
        push!(times, parse(Float64, t_str))
        push!(vals,  isempty(v_str) ? NaN : parse(Float64, v_str))
    end
    return times, vals
end

"""
DATA with the :RAW: keyword, as Python PySD: the value at the data times only,
NaN at any other time.
"""
struct _RawSeries
    times::Vector{Float64}
    vals::Vector{Float64}
end

function (r::_RawSeries)(t)
    i = findfirst(x -> isapprox(x, t; atol=1e-10), r.times)
    return i === nothing ? NaN : r.vals[i]
end

"""
    pysd_build_tab_itp(vals, times, method)

Build a DataInterpolations interpolation object from `(times, vals)` using
the Vensim interpolation `method` symbol:
- `:interpolate`            → `LinearInterpolation`
- `:raw`                    → the value at the data times, NaN in between
- `:hold_backward`           → `ConstantInterpolation` (hold previous value)
- `:look_forward`            → `ConstantInterpolation(dir=:right)` (next value)
"""
function pysd_build_tab_itp(vals::AbstractVector, times::AbstractVector, method::Symbol)
    times, vals = _one_point_constant(times, vals)
    if method === :hold_backward
        return ConstantInterpolation(vals, times;
            extrapolation_left=ExtrapolationType.Constant,
            extrapolation_right=ExtrapolationType.Constant)
    elseif method === :look_forward
        return ConstantInterpolation(vals, times;
            dir=:right,
            extrapolation_left=ExtrapolationType.Constant,
            extrapolation_right=ExtrapolationType.Constant)
    elseif method === :raw
        return _RawSeries(Float64.(times), Float64.(vals))
    else  # :interpolate
        return LinearInterpolation(vals, times;
            extrapolation_left=ExtrapolationType.Constant,
            extrapolation_right=ExtrapolationType.Constant)
    end
end

# Abramowitz & Stegun approximation for erfc (max error < 1.5e-7)
function _pysd_erfc(x)
    t = 1.0 / (1.0 + 0.3275911 * abs(x))
    poly = t * (0.254829592 +
           t * (-0.284496736 +
           t * (1.421413741 +
           t * (-1.453152027 +
           t * 1.061405429))))
    y = poly * exp(-x * x)
    return x >= 0.0 ? y : 2.0 - y
end

function pysd_allocate_available(
        request::AbstractVector{<:Real},
        pp     ::AbstractMatrix{<:Real},
        avail  ::Real)

    n         = length(request)
    avail     = Float64(avail)
    total_req = sum(request)

    total_req <= 0.0 && return zeros(n)
    avail >= total_req && return Float64.(collect(request))
    avail <= 0.0       && return zeros(n)

    # Determine bisection bounds: xlo → all demand on, xhi → all demand off
    xlo = minimum(pp[:, 2] .- abs.(pp[:, 3]) ./ 2) - 1e3
    xhi = maximum(pp[:, 2] .+ abs.(pp[:, 3]) ./ 2) + 1e3
    # Extend for normal profile (tails extend far)
    for i in 1:n
        round(Int, pp[i, 1]) == 3 || continue
        xlo = min(xlo, pp[i, 2] - 8.3 * pp[i, 3])
        xhi = max(xhi, pp[i, 2] + 8.3 * pp[i, 3])
    end

    total_demand(x) = sum(_pysd_demand_at_price(
        request[i], pp[i,1], pp[i,2], pp[i,3], x) for i in 1:n)

    # Bisection: total_demand is decreasing in x
    for _ in 1:80
        xmid = (xlo + xhi) / 2.0
        total_demand(xmid) > avail ? (xlo = xmid) : (xhi = xmid)
        abs(xhi - xlo) < 1e-12 * (abs(xlo) + abs(xhi) + 1e-14) && break
    end

    x_star = (xlo + xhi) / 2.0
    return [_pysd_demand_at_price(request[i], pp[i,1], pp[i,2], pp[i,3], x_star)
            for i in 1:n]
end
