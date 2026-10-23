# Model test_subscript_transposition — DSL style (syntax sketch: no macro yet)
@model subscript_transposition begin
    @time 0:1:1

    @index s ∈ sectors = (agriculture, industry, transport, tourism, comercial)
    @index r ∈ sectors                             # a second index over the same set

    input[s] = [1, 10, 5, 7, 9]
    io_matrix[s, r] = [ 1  2  3 4  5;
                       10 20 30 40 50;
                        1  2  3 4  5;
                        2  3  4 5  6;
                       -1  2 -3 4 -5]

    output[r] = ∑(input[s] * io_matrix[s, r] for s ∈ sectors)   # Vensim: SUM(input[sector!] * io matrix[sector!, sector1])
    output2[r] = ∑(input[s] * io_matrix[r, s] for s ∈ sectors)

    # or, as linear algebra:
    #   output = io_matrix' * input
    #   output2 = io_matrix * input
end
