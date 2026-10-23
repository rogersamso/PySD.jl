# Model test_subscript_2d_arrays — DSL style (syntax sketch: no macro yet)
@model subscript_2d_arrays begin
    @time 0:1:100                                  # initial time : time step : final time

    @index i ∈ entries = (entry_1, entry_2, entry_3)
    @index j ∈ columns = (column_1, column_2)

    "Rate A [1/month]"
    rate_a[i, j] = [0.01 0.02; 0.03 0.04; 0.05 0.06]

    initial_values[i, j] = [1 2; 3 4; 5 6]

    "Stock A [units]"
    ∂t(stock_a[i, j]) = inflow_a[i, j]
    stock_a(0) = initial_values

    inflow_a[i, j] = rate_a[i, j]
end

# Vensim-style alternative, also accepted:
#     stock_a[i, j] = INTEG(inflow_a[i, j], initial_values[i, j])
