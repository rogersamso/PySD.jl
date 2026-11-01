# Runs of one model on several threads at once (a sweep, an ensemble): each run
# has its own buffers, histories and clock; the caches they share (the input
# sheets read, the equations compiled) are locked.  With one thread the tasks
# run one after another: CI runs the tests with two.
@testset "DSL: runs on several threads" begin
    Threads.nthreads() > 1 || @info "one thread: runs on several threads not tested at the same time"
    m = _dsl("teacup")
    final(R) = run_model(m; params = (; room_temperature = R))[:teacup_temperature][end]
    temperatures = 60.0:1.0:75.0
    serial = final.(temperatures)
    @test fetch.([Threads.@spawn final(R) for R in temperatures]) == serial
    if HAS_TEST_MODELS
        # input sheets read by several runs at once, while the cache fills
        mod = _module()
        dir = joinpath(TEST_MODELS, "get_xls_cellrange")
        Core.eval(mod, :(const INPUTS = $dir))
        x = Base.include(mod, joinpath(@__DIR__, "dsl", "get_xls_cellrange.jl"))
        base = run_model(x)[:final1]
        sheets() = (; global_sheet = excel(joinpath(dir, "inputs.xlsx"), "Global"),
                      local_sheet = excel(joinpath(dir, "inputs.xlsx"), "Local"))
        lock(() -> (empty!(PySD._SHEET_CACHE); empty!(PySD._XLSX_CACHE)), PySD._CACHE_LOCK)
        runs = fetch.([Threads.@spawn run_model(x; inputs = sheets())[:final1] for _ in 1:8])
        @test all(==(base), runs)
    end
end
