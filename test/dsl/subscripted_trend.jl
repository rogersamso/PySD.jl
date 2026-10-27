# SDXorg/test-models tests/subscripted_trend: trend of arrays.
const apples = Dim{:apples}([:macoun, :red_spy, :grimes_golden, :roxbury_russet])
const citrus = Dim{:citrus}([:lemon, :lime, :orange, :clementine, :grapefruit])

subscripted_trend = @equations begin
    @parameters begin
        average_time = 6, [unit = u"s"]
        initial_trend[citrus] = 0, [unit = u"s^-1"]
    end
    @variables begin
        input(t)[apples, citrus], [unit = NoUnits]
        trend_of_input(t)[apples, citrus], [unit = u"s^-1"]
    end

    input ~ 1 + 0.5 * sin(2 * 3.14159 * t / 20)
    trend_of_input ~ trend(input, average_time; init = initial_trend)
end

Model(subscripted_trend; time = 0:1:100, time_unit = u"s")
