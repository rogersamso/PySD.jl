# SDXorg/test-models tests/delay_fixed: x(t - τ; init), with delays that are
# not multiples of the time step, and delays read at the initial time.
delay_fixed = @equations begin
    @variables begin
        time_squared(t), [unit = u"s^2"]
        df05(t), [unit = u"s^2"]
        df1(t), [unit = u"s^2"]
        df12(t), [unit = u"s^2"]
        df15(t), [unit = u"s^2"]
        df2(t), [unit = u"s^2"]
        df37(t), [unit = u"s^2"]
        dst(t), [unit = u"s^2"]
        dt2(t), [unit = u"s^2"]
    end

    time_squared ~ t^2
    df05 ~ time_squared(t - 0.5; init = -10)
    df1 ~ time_squared(t - 1; init = 10)
    df12 ~ time_squared(t - 1.2; init = -4)
    df15 ~ time_squared(t - 1.5; init = 20)
    df2 ~ time_squared(t - 2; init = -3)
    df37 ~ time_squared(t - 3.7; init = 4)
    dst ~ time_squared(t - (2 + 2 * sin(t)); init = 7)
    dt2 ~ time_squared(t - t / 2; init = 4)
end

Model(delay_fixed; time = 0:1:50, time_unit = u"s")
