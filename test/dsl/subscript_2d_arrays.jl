# SDXorg/test-models tests/subscript_2d_arrays.
const one_dimensional_subscript = Dim{:one_dimensional_subscript}([:entry_1, :entry_2, :entry_3])
const second_dimension_subscript = Dim{:second_dimension_subscript}([:column_1, :column_2])

subscript_2d_arrays = @equations begin
    @parameters begin
        rate_a[one_dimensional_subscript, second_dimension_subscript] =
            [0.01 0.02; 0.03 0.04; 0.05 0.06], [unit = u"month^-1"]
        initial_values[one_dimensional_subscript, second_dimension_subscript] =
            [1 2; 3 4; 5 6], [unit = NoUnits]
    end
    @variables begin
        stock_a(t)[one_dimensional_subscript, second_dimension_subscript],
            [unit = NoUnits, description = "Each element grows linearly"]
        inflow_a(t)[one_dimensional_subscript, second_dimension_subscript], [unit = u"month^-1"]
    end

    ∂t(stock_a) ~ inflow_a
    stock_a(t₀) ~ initial_values
    inflow_a ~ rate_a
end

Model(subscript_2d_arrays; time = 0:1:100, time_unit = u"month")
