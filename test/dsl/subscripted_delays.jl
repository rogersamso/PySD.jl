# SDXorg/test-models tests/subscripted_delays: material delays of arrays.
# (Vensim's `delay` is `delay_time` here: `delay` is the function.)
const apples = Dim{:apples}([:macoun, :red_spy, :grimes_golden, :roxbury_russet])
const citrus = Dim{:citrus}([:lemon, :lime, :orange, :clementine, :grapefruit])

subscripted_delays = @equations begin
    @parameters begin
        delay_time[apples] = [10, 3, 2, 4], [unit = u"month"]
    end
    @variables begin
        inflow_delay1(t)[apples, citrus], [unit = u"month^-1"]
        inflow_delay1i(t)[apples, citrus], [unit = u"month^-1"]
        inflow_delay3(t)[apples, citrus], [unit = u"month^-1"]
        inflow_delay3i(t)[apples, citrus], [unit = u"month^-1"]
        inflow_delayn(t)[apples, citrus], [unit = u"month^-1"]
        outflow_delay1(t)[apples, citrus], [unit = u"month^-1"]
        outflow_delay1i(t)[apples, citrus], [unit = u"month^-1"]
        outflow_delay3(t)[apples, citrus], [unit = u"month^-1"]
        outflow_delay3i(t)[apples, citrus], [unit = u"month^-1"]
        outflow_delayn(t)[apples, citrus], [unit = u"month^-1"]
        stock_delay1(t)[apples, citrus], [unit = NoUnits]
        stock_delay1i(t)[apples, citrus], [unit = NoUnits]
        stock_delay3(t)[apples, citrus], [unit = NoUnits]
        stock_delay3i(t)[apples, citrus], [unit = NoUnits]
        stock_delayn(t)[apples, citrus], [unit = NoUnits]
    end

    inflow_delay1 ~ 5 * (t ≥ 10)
    inflow_delay1i ~ 5 * (t ≥ 10)
    inflow_delay3 ~ 5 * (t ≥ 10)
    inflow_delay3i ~ 5 * (t ≥ 10)
    inflow_delayn ~ 10 * (t ≥ 5)

    outflow_delay1 ~ delay(inflow_delay1, delay_time)
    outflow_delay1i ~ delay(inflow_delay1i, delay_time; init = 2)
    outflow_delay3 ~ delay(inflow_delay3, delay_time; order = 3)
    outflow_delay3i ~ delay(inflow_delay3i, delay_time; order = 3, init = 3)
    outflow_delayn ~ delay(inflow_delayn, delay_time; order = 6, init = 10)

    ∂t(stock_delay1) ~ inflow_delay1 - outflow_delay1
    ∂t(stock_delay1i) ~ inflow_delay1i - outflow_delay1i
    ∂t(stock_delay3) ~ inflow_delay3 - outflow_delay3
    ∂t(stock_delay3i) ~ inflow_delay3i - outflow_delay3i
    ∂t(stock_delayn) ~ inflow_delayn - outflow_delayn
    stock_delay1(t₀) ~ 5
    stock_delay1i(t₀) ~ 5
    stock_delay3(t₀) ~ 5
    stock_delay3i(t₀) ~ 5
    stock_delayn(t₀) ~ 0
end

Model(subscripted_delays; time = 0:0.25:20, time_unit = u"month")
