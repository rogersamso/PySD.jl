using Test, PySD, PySDExplorer, HTTP, JSON3, DimensionalData
import PySDExplorer as PE

const region = Dim{:region}([:north, :south])
cup = Model(@equations(title = "PHYSICS-Teacup", begin
    @parameters begin
        room_temperature = 70, [unit = u"°F", title = "Room temperature", limits = (32, 100, 1)]
        characteristic_time = 10, [unit = u"minute", description = "How fast it cools."]
        start[region] = [180.0, 160.0], [unit = u"°F"]
    end
    @variables begin
        teacup_temperature(t)[region], [unit = u"°F", description = "The tea."]
        heat_loss_to_room(t)[region], [unit = u"°F/minute"]
    end
    ∂t(teacup_temperature) ~ -heat_loss_to_room
    teacup_temperature(t₀) ~ start
    heat_loss_to_room ~ (teacup_temperature - room_temperature) / characteristic_time
end); time = 0:0.5:30, saveat = 1, time_unit = u"minute")

@testset "explorer" begin
    dir = mktempdir()
    sens = joinpath(dir, "sens.tsv")
    write(sens, "parameter\tvalue\tteacup_temperature\tnot_a_name\nroom_temperature\t70\t0.3\t1\ncharacteristic_time\t10\tNaN\t2\n")
    ex = PE.explorer(cup; dir, title = "Cup", sensitivity = sens)
    @test length(ex.runs) == 1                                        # the base run
    base = only(values(ex.runs))
    info = PE.model_info(ex)
    room = only(n for n in info["names"] if n["name"] == "room_temperature")
    @test room["title"] == "Room temperature" && room["set"] == "PHYSICS-Teacup" && room["limits"] == [32, 100, 1]
    @test room["value"] == 70
    @test only(n for n in info["names"] if n["name"] == "start")["value"] == [180, 160]
    @test ex.sensitivity["outputs"] == ["teacup_temperature"]
    @test ex.sensitivity["rows"][2]["teacup_temperature"] === nothing    # NaN: no value

    # a run with other values, saved and read back
    r = PE.run!(ex, "Warm room", ["room_temperature" => 90, "start" => [200, 150]], Pair{String,String}[])
    s = PE.series(ex, "teacup_temperature", [base.meta["id"], r.meta["id"]])
    @test s["elements"] == ["north", "south"]
    @test s["runs"][r.meta["id"]][1][1] == 200 && s["runs"][r.meta["id"]][2][1] == 150
    @test s["runs"][r.meta["id"]][1][end] > s["runs"][base.meta["id"]][1][end]
    again = PE.explorer(cup; dir)
    @test length(again.runs) == 2
    @test again.runs[r.meta["id"]].data == r.data && again.runs[r.meta["id"]].meta["params"]["room_temperature"] == 90

    # only the model's parameters, as numbers of the right shape
    @test_throws ArgumentError PE.run!(ex, "", ["teacup_temperature" => 1], Pair{String,String}[])
    @test_throws ArgumentError PE.run!(ex, "", ["start" => [1]], Pair{String,String}[])
    @test_throws ArgumentError PE.run!(ex, "", ["room_temperature" => "hot"], Pair{String,String}[])

    # a page that opens without the server
    html = static_page(ex, [r.meta["id"]], ["teacup_temperature"])
    @test occursin("window.PYSD_STATIC", html) && occursin("plotly.js v", html) && !occursin("src=\"app.js\"", html)

    # arrays of more than one dimension: their values flat, the first dimension slowest
    @test PE._flat([1 2 3; 4 5 6]) == [1, 2, 3, 4, 5, 6] && PE._unflat([1, 2, 3, 4, 5, 6], (2, 3)) == [1 2 3; 4 5 6]

    # input sheets: those of files named like the model's own, without notes
    xd = mktempdir()
    sheet(f, names...) = PE.XLSX.writetable(joinpath(xd, f), [n => (; x = [1.0]) for n in names]...; overwrite = true)
    sheet("scen.xlsx", "A", "Readme", "B"); sheet("scen_high.xlsx", "A"); sheet("other.xlsx", "A")
    withinput = Model(@equations(begin
        @parameters begin
            k = 1, [unit = NoUnits]
        end
    end); time = 0:1:2, time_unit = u"s", inputs = (; scen = PySD.excel(joinpath(xd, "scen.xlsx"), "A")))
    ch = PE._input_choices(withinput, [xd])["scen"]
    @test ch == [(joinpath(xd, "scen.xlsx"), "A"), (joinpath(xd, "scen.xlsx"), "B"), (joinpath(xd, "scen_high.xlsx"), "A")]

    # the model's code: its files, and where each name is written
    @test [c["id"] for c in PE.code_info(ex)] == ["runtests.jl"]
    tea = only(n for n in info["names"] if n["name"] == "teacup_temperature")
    @test length(tea["code"]) == 3 && all(c -> c[1] == "runtests.jl", tea["code"])   # declaration, ∂t, t₀
    @test occursin("teacup_temperature(t₀) ~ start", PE.code_text(ex, "runtests.jl"))
    @test PE.code_text(ex, "../Project.toml") === nothing

    # the routes
    router = PE.routes(ex)
    get(path) = router(HTTP.Request("GET", path))
    @test get("/api/code/runtests.jl").status == 200 && get("/api/code/nothing.jl").status == 404
    @test get("/").status == 200 && get("/app.js").status == 200 && get("/../Project.toml").status == 404
    @test length(JSON3.read(get("/api/runs").body)) == 2
    post = router(HTTP.Request("POST", "/api/runs", ["Content-Type" => "application/json"],
                               JSON3.write(Dict("label" => "Cold", "params" => Dict("room_temperature" => 40)))))
    @test post.status == 200 && JSON3.read(post.body).label == "Cold"
    bad = router(HTTP.Request("POST", "/api/runs", [], JSON3.write(Dict("params" => Dict("x" => 1)))))
    @test bad.status == 400
    id = JSON3.read(post.body).id
    @test router(HTTP.Request("DELETE", "/api/runs/$id")).status == 200 && !haskey(ex.runs, id)
    v = router(HTTP.Request("POST", "/api/views", [], JSON3.write(Dict("name" => "My view", "panels" => []))))
    @test JSON3.read(v.body)[1].name == "My view"
end
