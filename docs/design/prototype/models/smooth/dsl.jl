# Model test_smooth — DSL style (syntax sketch: no macro yet)
@model smooth begin
    @time 0:0.25:20

    initial_value = 5
    input = -1 + STEP(5, 5)                        # time is implicit, as in Vensim
    adjustment_time = 2 + STEP(2, 10)
    variable_order = 2 + STEP(1, 10)

    # one SMOOTH with options instead of SMOOTH / SMOOTHI / SMOOTH3 / SMOOTH3I / SMOOTH N;
    # the macro creates the hidden stage stocks
    smooth_output = SMOOTH(input, adjustment_time)
    smoothi_output = SMOOTH(input, adjustment_time; init = initial_value)
    smooth3_output = SMOOTH(input, adjustment_time; order = 3)
    smooth3i_output = SMOOTH(input, adjustment_time; order = 3, init = initial_value)
    smooth_n_output = SMOOTH(input, adjustment_time; order = variable_order, init = initial_value)
end
