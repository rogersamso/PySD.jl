# SDXorg/test-models tests/subscripted_smooth: smooth of arrays.
const apples = Dim{:apples}([:macoun, :red_spy, :grimes_golden, :roxbury_russet])
const citrus = Dim{:citrus}([:lemon, :lime, :orange, :clementine, :grapefruit])

subscripted_smooth = @equations begin
    @parameters begin
        initial_value_subscript[citrus] = [4, 5, 6, 3, 7], [unit = NoUnits]
        initial_value = 5, [unit = NoUnits]
    end
    @variables begin
        input_sm(t)[apples, citrus], [unit = NoUnits]
        adjustment_time(t), [unit = u"s"]
        variable_order(t), [unit = NoUnits]
        smooth_output(t)[apples, citrus], [unit = NoUnits]
        smoothi_output(t)[apples, citrus], [unit = NoUnits]
        smooth3_output(t)[apples, citrus], [unit = NoUnits]
        smooth3i_output(t)[apples, citrus], [unit = NoUnits]
        smooth_n_output(t)[apples, citrus], [unit = NoUnits]
    end

    input_sm ~ -1 + 3 * (t ≥ 3)
    adjustment_time ~ 2 + 2 * (t ≥ 1)
    variable_order ~ 2 + (t ≥ 1)
    smooth_output ~ smooth(input_sm, adjustment_time)
    smoothi_output ~ smooth(input_sm, adjustment_time; init = initial_value_subscript)
    smooth3_output ~ smooth(input_sm, adjustment_time; order = 3)
    smooth3i_output ~ smooth(input_sm, adjustment_time; order = 3, init = initial_value)
    smooth_n_output ~ smooth(input_sm, adjustment_time; order = variable_order, init = initial_value)
end

Model(subscripted_smooth; time = 0:0.25:20, time_unit = u"s")
