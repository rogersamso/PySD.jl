# SDXorg/test-models tests/sample_if_true: sample_if_true of numbers and arrays,
# the condition, the input and the initial value each with its own dimensions.
const dim1 = Dim{:dim1}([:a, :b, :c])
const dim2 = Dim{:dim2}([:d, :e])

sample_example = @equations begin
    @parameters begin
        var_initial[dim1] = [100, -10, 50], [unit = u"s"]
    end
    @variables begin
        time_in_seconds(t), [unit = u"s"]
        oscilating_var(t), [unit = NoUnits]
        oscilating_var_dim(t)[dim1], [unit = NoUnits]
        var(t)[dim2], [unit = u"s"]
        sample_simple(t), [unit = u"s"]
        sample_var(t), [unit = u"s"]
        sample_001(t)[dim1], [unit = u"s"]
        sample_010(t)[dim2], [unit = u"s"]
        sample_011(t)[dim1, dim2], [unit = u"s"]
        sample_100(t)[dim1], [unit = u"s"]
        sample_110(t)[dim1, dim2], [unit = u"s"]
        sample_111(t)[dim1, dim2], [unit = u"s"]
    end

    time_in_seconds ~ t * 60
    oscilating_var ~ sin(exp(0.5 * t))
    oscilating_var_dim[dim1 = At(:a)] ~ oscilating_var + t * 0.1
    oscilating_var_dim[dim1 = At(:b)] ~ -oscilating_var
    oscilating_var_dim[dim1 = At(:c)] ~ oscilating_var * 2 - 1
    var[dim2 = At(:d)] ~ time_in_seconds * 10
    var[dim2 = At(:e)] ~ -time_in_seconds

    sample_simple ~ sample_if_true(oscilating_var < 0, time_in_seconds; init = 100)
    sample_var ~ sample_if_true(oscilating_var > 0, time_in_seconds; init = time_in_seconds)
    sample_001 ~ sample_if_true(oscilating_var > 0, time_in_seconds; init = var_initial)
    sample_010 ~ sample_if_true(oscilating_var > 0, var; init = -90)
    sample_011 ~ sample_if_true(oscilating_var > 0, var; init = var_initial)
    sample_100 ~ sample_if_true(oscilating_var_dim .< 0, time_in_seconds; init = 100)
    sample_110 ~ sample_if_true(oscilating_var_dim .< 0, var; init = -30)
    sample_111 ~ sample_if_true(oscilating_var_dim .< 0, var; init = var_initial)
end

Model(sample_example; time = 0:1:20, time_unit = u"s")
