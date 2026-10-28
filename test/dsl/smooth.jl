# SDXorg/test-models tests/smooth: one `smooth` with options replaces SMOOTH,
# SMOOTHI, SMOOTH3, SMOOTH3I and SMOOTH N.
smooth_example = @equations begin
    @parameters begin
        initial_value = 5, [unit = NoUnits]
    end
    @variables begin
        input(t), [unit = NoUnits, description = "A step of 5 at t = 5"]
        adjustment_time(t), [unit = u"s"]
        variable_order(t), [unit = NoUnits, description = "Read at t₀"]
        smooth_output(t), [unit = NoUnits, description = "First-order exponential smoothing"]
        smoothi_output(t), [unit = NoUnits]
        smooth3_output(t), [unit = NoUnits]
        smooth3i_output(t), [unit = NoUnits]
        smooth_n_output(t), [unit = NoUnits]
        smoothed(t), [unit = NoUnits, description = "smooth_output, written as its ODE"]
    end

    input ~ -1 + 5 * (t ≥ 5)
    adjustment_time ~ 2 + 2 * (t ≥ 10)
    variable_order ~ 2 + (t ≥ 10)

    smooth_output ~ smooth(input, adjustment_time)
    smoothi_output ~ smooth(input, adjustment_time; init = initial_value)
    smooth3_output ~ smooth(input, adjustment_time; order = 3)
    smooth3i_output ~ smooth(input, adjustment_time; order = 3, init = initial_value)
    smooth_n_output ~ smooth(input, adjustment_time; order = variable_order, init = initial_value)

    ∂t(smoothed) ~ (input - smoothed) / adjustment_time
    smoothed(t₀) ~ input
end

Model(smooth_example; time = 0:0.25:20, time_unit = u"s")
