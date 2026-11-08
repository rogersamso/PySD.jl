using Test, PySD, PySDExplorer, HTTP, JSON3, DimensionalData, Dates
import PySDExplorer as PE

const region = Dim{:region}([:north, :south])
cup = Model(@equations(title = "PHYSICS-Teacup", begin
    @parameters begin
        room_temperature = 70, [unit = u"°F", title = "Room temperature", limits = (32, 100, 1)]
        characteristic_time = 10, [unit = u"minute", description = "How fast it cools."]
        start[region] = [180.0, 160.0], [unit = u"°F"]
        start_year = 2020, [unit = NoUnits]
        nothing_added = 0, [unit = u"°F"]
    end
    @variables begin
        teacup_temperature(t)[region], [unit = u"°F", description = "The tea."]
        heat_loss_to_room(t)[region], [unit = u"°F/minute"]
        mean_temperature(t), [unit = u"°F"]
    end
    ∂t(teacup_temperature) ~ -heat_loss_to_room
    teacup_temperature(t₀) ~ start
    heat_loss_to_room ~ (teacup_temperature - room_temperature - nothing_added) / characteristic_time
    mean_temperature ~ sum_over(teacup_temperature, region) / 2
end); time = 0:0.5:30, saveat = 1, time_unit = u"minute")

# wait for a job to end; its id's result
function finish(ex, job; timeout = 120)
    t = time()
    while job.status in (:queued, :running)
        time() - t > timeout && error("job $(job.id) still $(job.status)")
        sleep(0.05)
    end
    return job
end

@testset "explorer, one user" begin
    dir = mktempdir()
    sens = joinpath(dir, "sens.tsv")
    write(sens, "parameter\tvalue\tteacup_temperature\tnot_a_name\nroom_temperature\t70\t0.3\t1\ncharacteristic_time\t10\tNaN\t2\n")
    ex = PE.explorer(cup; dir, title = "Cup", sensitivity = sens)
    @test length(ex.runs) == 1                                        # the base run, everyone's
    base = only(values(ex.runs))
    @test base.meta["owner"] == "" && base.meta["shared"] === true
    info = PE.model_info(ex)
    room = only(n for n in info["names"] if n["name"] == "room_temperature")
    @test room["title"] == "Room temperature" && room["set"] == "PHYSICS-Teacup" && room["limits"] == [32, 100, 1]
    @test only(n for n in info["names"] if n["name"] == "start")["value"] == [180, 160]
    file = ex.analyses["file"]
    @test file["outputs"] == ["teacup_temperature"] && file["rows"][2]["teacup_temperature"] === nothing

    # a run, queued and run, saved and read back
    job = finish(ex, PE.submit_run!(ex, "local", "Warm room", ["room_temperature" => 90, "start" => [200, 150]], Pair{String,String}[]))
    @test job.status === :done
    r = ex.runs[job.result]
    @test r.meta["owner"] == "local" && r.meta["shared"] === false
    s = PE.series(ex, "local", "teacup_temperature", [base.meta["id"], r.meta["id"]])
    @test s["elements"] == ["north", "south"]
    @test s["runs"][r.meta["id"]][1][1] == 200 && s["runs"][r.meta["id"]][1][end] > s["runs"][base.meta["id"]][1][end]
    again = PE.explorer(cup; dir)
    @test length(again.runs) == 2 && again.runs[r.meta["id"]].data == r.data

    # only the model's parameters, as numbers of the right shape
    @test_throws ArgumentError PE.submit_run!(ex, "local", "", ["teacup_temperature" => 1], Pair{String,String}[])
    @test_throws ArgumentError PE.submit_run!(ex, "local", "", ["start" => [1]], Pair{String,String}[])
    @test_throws ArgumentError PE.submit_run!(ex, "local", "", ["room_temperature" => "hot"], Pair{String,String}[])
    @test PE._flat([1 2 3; 4 5 6]) == [1, 2, 3, 4, 5, 6] && PE._unflat([1, 2, 3, 4, 5, 6], (2, 3)) == [1 2 3; 4 5 6]

    # a sensitivity analysis: elasticities at the end, the array's elements as results
    job = finish(ex, PE.submit_analysis!(ex, "local"; label = "Cup", around = r.meta["id"],
                                         params = ["room_temperature", "characteristic_time", "start", "start_year", "nothing_added"],
                                         outputs = ["mean_temperature", "teacup_temperature"]))
    @test job.status === :done
    a = ex.analyses[job.result]
    @test a["outputs"] == ["mean_temperature", "teacup_temperature[north]", "teacup_temperature[south]"]
    @test [x["parameter"] for x in a["rows"]] == ["room_temperature", "characteristic_time", "start"]
    @test Set(x["why"] for x in a["skipped"]) == Set(["a year", "it is 0"])
    room_e = a["rows"][1]["mean_temperature"]
    @test 0 < room_e < 1                                              # a warmer room: warmer tea, less than 1 %/%
    # the same elasticity by hand, around the run it starts from
    y(p) = PE._simulate(ex, [:start => [200.0, 150.0], p], [])[:mean_temperature][end]
    y0 = y(:room_temperature => 90.0)
    @test room_e ≈ (y(:room_temperature => 90 * 1.01) - y0) / y0 / 0.01
    @test isfile(joinpath(dir, "analyses", a["id"] * ".json"))
    @test_throws ArgumentError PE.submit_analysis!(ex, "local"; params = ["teacup_temperature"], outputs = ["mean_temperature"])
    @test_throws ArgumentError PE.submit_analysis!(ex, "local"; params = ["room_temperature"], outputs = ["room_temperature"])

    # input sheets: those of files named like the model's own, without notes
    xd = mktempdir()
    sheet(f, names...) = PE.XLSX.writetable(joinpath(xd, f), [n => (; x = [1.0]) for n in names]...; overwrite = true)
    sheet("scen.xlsx", "A", "Readme", "B"); sheet("scen_high.xlsx", "A"); sheet("other.xlsx", "A")
    withinput = Model(@equations(begin
        @parameters begin
            k = 1, [unit = NoUnits]
        end
    end); time = 0:1:2, time_unit = u"s", inputs = (; scen = PySD.excel(joinpath(xd, "scen.xlsx"), "A")))
    @test PE._input_choices(withinput, [xd])["scen"] ==
          [(joinpath(xd, "scen.xlsx"), "A"), (joinpath(xd, "scen.xlsx"), "B"), (joinpath(xd, "scen_high.xlsx"), "A")]

    # the model's code: its files, and where each name is written
    @test [c["id"] for c in PE.code_info(ex)] == ["runtests.jl"]
    tea = only(n for n in info["names"] if n["name"] == "teacup_temperature")
    @test length(tea["code"]) == 3 && all(c -> c[1] == "runtests.jl", tea["code"])   # declaration, ∂t, t₀
    @test PE.code_text(ex, "../Project.toml") === nothing

    # a page that opens without the server
    html = static_page(ex, [r.meta["id"]], ["teacup_temperature"])
    @test occursin("window.PYSD_STATIC", html) && occursin("plotly.js v", html) && !occursin("src=\"app.js\"", html)
end

@testset "explorer, several users" begin
    dir = mktempdir()
    ex = PE.explorer(cup; dir, users = :header, admins = ["roger"])
    router = PE.routes(ex)
    call(method, path, user, body = nothing) = begin
        h = user === nothing ? [] : ["X-PySD-User" => user]
        resp = router(HTTP.Request(method, path, h, body === nothing ? UInt8[] : JSON3.write(body)))
        json = HTTP.header(resp, "Content-Type", "") == "application/json"
        (resp.status, json && !isempty(resp.body) ? JSON3.read(resp.body) : nothing)
    end
    wait_job(user, id) = begin
        t = time()
        while true
            (_, j) = call("GET", "/api/jobs/$id", user)
            j.status in ("done", "failed", "cancelled") && return j
            time() - t > 120 && error("job $id didn't end")
            sleep(0.05)
        end
    end

    @test call("GET", "/api/me", nothing)[1] == 403                  # no user from the proxy
    @test call("GET", "/api/me", "../etc")[1] == 403
    @test call("GET", "/", nothing)[1] == 200                          # the page itself, for the login to show it
    (_, me) = call("GET", "/api/me", "ana")
    @test me.user == "ana" && !me.admin && me.limits.max_runs_per_user == 30
    @test call("GET", "/api/me", "roger")[2].admin
    @test call("GET", "/api/admin", "ana")[1] == 403

    # ana's run: hers only, until she shares it
    (st, job) = call("POST", "/api/runs", "ana", Dict("label" => "Ana's", "params" => Dict("room_temperature" => 40)))
    @test st == 200 && job.status in ("queued", "running")
    done = wait_job("ana", job.id)
    @test done.status == "done"
    id = done.result
    @test id in [r.id for r in call("GET", "/api/runs", "ana")[2]]
    @test !(id in [r.id for r in call("GET", "/api/runs", "joan")[2]])
    @test id in [r.id for r in call("GET", "/api/runs", "roger")[2]]   # administrators see all
    @test isempty(call("GET", "/api/series?name=mean_temperature&runs=$id", "joan")[2].runs)
    # its results as CSV: its owner (and administrators), not others
    resp = router(HTTP.Request("GET", "/api/runs/$id/csv", ["X-PySD-User" => "ana"]))
    @test resp.status == 200 && occursin("Ana", HTTP.header(resp, "Content-Disposition"))
    lines = split(String(resp.body), '\n'; keepempty = false)
    @test startswith(lines[1], "# Ana's (") && occursin("room_temperature = 40", lines[1])
    @test startswith(lines[2], "name,unit,0.0,1.0")
    row = split(first(filter(l -> startswith(l, "teacup_temperature[north],"), lines)), ',')
    @test row[2] == "°F" && parse(Float64, row[3]) == 180.0 && length(row) == 2 + 31
    @test length(lines) == 2 + length(ex.runs[id].columns)
    @test router(HTTP.Request("GET", "/api/runs/$id/csv", ["X-PySD-User" => "joan"])).status == 404
    @test router(HTTP.Request("GET", "/api/runs/$id/csv", ["X-PySD-User" => "roger"])).status == 200
    @test call("GET", "/api/jobs/$(job.id)", "joan")[1] == 404         # nor her jobs
    @test call("PATCH", "/api/runs/$id", "joan", Dict("shared" => true))[1] == 404
    @test call("PATCH", "/api/runs/$id", "ana", Dict("shared" => true))[1] == 200
    @test id in [r.id for r in call("GET", "/api/runs", "joan")[2]]
    @test call("DELETE", "/api/runs/$id", "joan")[1] == 403            # shared: seen, not changed
    base = only(r.id for r in call("GET", "/api/runs", "joan")[2] if r.owner == "")
    @test call("DELETE", "/api/runs/$base", "ana")[1] == 403           # the base run is no one's

    # limits, set by administrators
    @test call("PUT", "/api/admin/settings", "ana", Dict("max_runs_per_user" => 99))[1] == 403
    @test call("PUT", "/api/admin/settings", "roger", Dict("max_runs_per_user" => 0))[1] == 400
    @test call("PUT", "/api/admin/settings", "roger", Dict("max_runs_per_user" => 1, "show_code" => false))[1] == 200
    (st, err) = call("POST", "/api/runs", "ana", Dict("params" => Dict()))
    @test st == 400 && occursin("delete some", err.error)
    @test call("GET", "/api/code", "ana")[1] == 403 && call("GET", "/api/code", "roger")[1] == 200
    @test !call("GET", "/api/me", "ana")[2].code
    @test isfile(joinpath(dir, "settings.json")) && PE._load_settings(dir)["max_runs_per_user"] == 1

    # one job at a time per user, max_parallel slots for everyone
    call("PUT", "/api/admin/settings", "roger", Dict("max_runs_per_user" => 30, "max_parallel" => 1))
    jobs = [PE.submit_run!(ex, u, "", Pair{String,Any}[], Pair{String,String}[]) for u in ("joan", "pere", "marta")]
    @test_throws ArgumentError PE.submit_run!(ex, "joan", "", Pair{String,Any}[], Pair{String,String}[])
    @test count(j -> j.status === :running, jobs) <= 1
    (_, j3) = call("GET", "/api/jobs/$(jobs[3].id)", "marta")
    @test j3.status == "done" || j3.position !== nothing || j3.status == "running"
    @test call("DELETE", "/api/jobs/$(jobs[3].id)", "marta")[1] in (200, 400)   # cancelled if it hadn't started
    foreach(j -> finish(ex, j), jobs)
    @test all(j -> j.status in (:done, :cancelled), jobs) && ex.running == 0
    @test length(call("GET", "/api/admin", "roger")[2].jobs) >= 3

    # analyses: private until shared, limited in parameters
    call("PUT", "/api/admin/settings", "roger", Dict("max_params_per_analysis" => 1))
    @test call("POST", "/api/analyses", "ana", Dict("params" => ["room_temperature", "characteristic_time"],
                                                    "outputs" => ["mean_temperature"]))[1] == 400
    (_, job) = call("POST", "/api/analyses", "ana", Dict("params" => ["room_temperature"], "outputs" => ["mean_temperature"],
                                                         "around" => id))
    a = wait_job("ana", job.id)
    @test a.status == "done"
    @test !(a.result in [x.id for x in call("GET", "/api/analyses", "joan")[2]])
    @test call("GET", "/api/analyses/$(a.result)", "joan")[1] == 404
    @test call("PATCH", "/api/analyses/$(a.result)", "ana", Dict("shared" => true))[1] == 200
    @test call("GET", "/api/analyses/$(a.result)", "joan")[2].rows[1].parameter == "room_temperature"

    # each user's views
    call("POST", "/api/views", "ana", Dict("name" => "Mine", "panels" => []))
    @test length(call("GET", "/api/views", "ana")[2]) == 1 && isempty(call("GET", "/api/views", "joan")[2])

    # the explorer trusts the proxy's header only where the proxy is
    @test_throws ArgumentError serve(cup; dir, users = :header, host = "0.0.0.0")
end

@testset "explorer, its own logins" begin
    # PBKDF2-HMAC-SHA256: the test vectors of RFC 7914 (section 11)
    @test bytes2hex(PE._pbkdf2("password", Vector{UInt8}("salt"), 1)) == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
    @test bytes2hex(PE._pbkdf2("password", Vector{UInt8}("salt"), 4096)) == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"
    h = PE.password_hash("correct horse"; iterations = 1000)
    @test startswith(h, "pbkdf2-sha256\$1000\$") && PE.password_matches("correct horse", h) && !PE.password_matches("correct hors", h)
    @test PE.password_hash("same"; iterations = 10) != PE.password_hash("same"; iterations = 10)   # salted
    @test length(PE.new_password()) == 16

    dir = mktempdir()
    @test_throws ArgumentError PE.explorer(cup; dir, users = :password)          # no administrator yet
    @test_throws ArgumentError PE.set_password!(dir, "roger", "short"; admin = true)
    @test_throws ArgumentError PE.set_password!(dir, "local", "long enough pw"; admin = true)
    PE.set_password!(dir, "roger", "roger's password"; admin = true)
    @test (stat(joinpath(dir, "users.json")).mode & 0o077) == 0                   # the owner's only
    ex = PE.explorer(cup; dir, users = :password, secure_cookies = false)
    router = PE.routes(ex)
    req(method, path; body = nothing, cookie = nothing, csrf = true, addr = "10.0.0.1") = begin
        h = Pair{String,String}["X-Forwarded-For" => addr]
        csrf && push!(h, "X-PySD-Request" => "1")
        cookie === nothing || push!(h, "Cookie" => "pysd_session=$cookie")
        router(HTTP.Request(method, path, h, body === nothing ? UInt8[] : JSON3.write(body)))
    end
    json(r) = JSON3.read(r.body)
    login(user, password; kw...) = req("POST", "/api/login"; body = Dict("user" => user, "password" => password), kw...)
    token(r) = match(r"pysd_session=([0-9a-f]+)", HTTP.header(r, "Set-Cookie")).captures[1]

    r = req("GET", "/api/me")
    @test r.status == 401 && json(r).login
    @test req("GET", "/api/me"; cookie = "0123").status == 401
    @test login("roger", "wrong one").status == 403
    @test login("nobody", "whatever pw").status == 403                         # the same answer
    @test login("roger", "roger's password"; csrf = false).status == 403        # no X-PySD-Request
    r = login("roger", "roger's password")
    @test r.status == 200
    cookie = HTTP.header(r, "Set-Cookie")
    @test occursin("HttpOnly", cookie) && occursin("SameSite=Strict", cookie) && !occursin("Secure", cookie)
    roger = token(r)
    me = json(req("GET", "/api/me"; cookie = roger))
    @test me.user == "roger" && me.admin && me.auth == "password"
    @test !any(s -> occursin(roger, JSON3.write(s)), values(ex.sessions))       # only the token's hash is kept
    @test req("POST", "/api/runs"; body = Dict(), cookie = roger, csrf = false).status == 403

    # administrators make users; a password is shown once
    r = req("POST", "/api/admin/users"; body = Dict("name" => "laia"), cookie = roger)
    @test r.status == 200
    laia_pw = json(r).password
    @test length(laia_pw) == 16 && !occursin(laia_pw, read(joinpath(dir, "users.json"), String))
    @test req("POST", "/api/admin/users"; body = Dict("name" => "laia"), cookie = roger).status == 400   # exists
    @test req("POST", "/api/admin/users"; body = Dict("name" => "a b"), cookie = roger).status == 400
    laia = token(login("laia", laia_pw))
    me = json(req("GET", "/api/me"; cookie = laia))
    @test me.user == "laia" && !me.admin
    @test req("GET", "/api/admin/users"; cookie = laia).status == 403
    @test req("POST", "/api/admin/users"; body = Dict("name" => "x"), cookie = laia).status == 403
    @test [u.user for u in json(req("GET", "/api/admin/users"; cookie = roger))] == ["laia", "roger"]

    # her own password: the current one first; then her sessions end
    @test req("POST", "/api/password"; body = Dict("current" => "nope", "new" => "a new password"), cookie = laia).status == 403
    @test req("POST", "/api/password"; body = Dict("current" => laia_pw, "new" => "short"), cookie = laia).status == 400
    @test req("POST", "/api/password"; body = Dict("current" => laia_pw, "new" => "laia's new one"), cookie = laia).status == 200
    @test req("GET", "/api/me"; cookie = laia).status == 401
    @test login("laia", laia_pw).status == 403
    laia = token(login("laia", "laia's new one"))

    # a reset by an administrator ends her sessions; admin or not; removing
    r = req("POST", "/api/admin/users/laia/password"; cookie = roger)
    @test r.status == 200 && req("GET", "/api/me"; cookie = laia).status == 401
    laia = token(login("laia", json(r).password))
    @test req("PATCH", "/api/admin/users/laia"; body = Dict("admin" => true), cookie = roger).status == 200
    @test json(req("GET", "/api/me"; cookie = laia)).admin
    @test req("PATCH", "/api/admin/users/laia"; body = Dict("admin" => false), cookie = roger).status == 200
    @test req("PATCH", "/api/admin/users/roger"; body = Dict("admin" => false), cookie = roger).status == 400   # the last one
    @test req("DELETE", "/api/admin/users/roger"; cookie = roger).status == 400                                # yourself
    @test req("DELETE", "/api/admin/users/laia"; cookie = roger).status == 200
    @test req("GET", "/api/me"; cookie = laia).status == 401

    # logging out ends the session; too many failures block, for the name and for the address
    @test req("POST", "/api/logout"; cookie = roger).status == 200
    @test req("GET", "/api/me"; cookie = roger).status == 401
    PE.set_password!(dir, "pau", "pau's password")       # (as deploy/users.jl does, while it runs)
    for _ in 1:5
        login("pau", "wrong password!"; addr = "10.0.0.9")
    end
    r = login("pau", "pau's password"; addr = "10.0.0.8")
    @test r.status == 403 && occursin("too many", json(r).error)
    @test login("roger", "roger's password"; addr = "10.0.0.8").status == 200       # others aren't
    for i in 1:20
        login("someone$i", "wrong password!"; addr = "10.0.0.7")
    end
    @test login("roger", "roger's password"; addr = "10.0.0.7").status == 403       # that address is
    # an idle session ends
    t = token(login("roger", "roger's password"; addr = "10.0.0.6"))
    @test req("GET", "/api/me"; cookie = t).status == 200
    ex.sessions[PE._token_key(t)]["seen"] = string(now() - Day(15)); PE._save_sessions!(ex)
    @test req("GET", "/api/me"; cookie = t).status == 401
    @test !haskey(ex.sessions, PE._token_key(t))                                    # and is forgotten
end

@testset "explorer, uploaded sheets" begin
    xd = mktempdir()
    sheet(f, pairs...) = (PE.XLSX.writetable(joinpath(xd, f), [n => (; x = [v]) for (n, v) in pairs]...; overwrite = true);
                          joinpath(xd, f))
    own = sheet("scen.xlsx", "NZP" => 2.0, "Readme" => 0.0)
    m = Model(@equations(begin
        @parameters begin
            k = constant(scen, "A2"), [unit = NoUnits]
        end
        @variables begin
            y(t), [unit = NoUnits]
        end
        ∂t(y) ~ k
        y(t₀) ~ 0
    end); time = 0:1:4, time_unit = u"s", inputs = (; scen = PySD.excel(own, "NZP")))
    dir = mktempdir()
    ex = PE.explorer(m; dir, users = :header, admins = ["roger"])
    high = read(sheet("scen_high.xlsx", "NZP" => 5.0, "BAU" => 1.0, "Info input variables" => 0.0))

    # checked: one of the model's files, an .xlsx file, not a bomb, within the limits
    @test_throws ArgumentError PE.upload!(ex, "ana", high; replaces = "energy")
    @test_throws ArgumentError PE.upload!(ex, "ana", rand(UInt8, 1000); replaces = "scen")
    bomb = copy(high)
    for k in findall(i -> bomb[i:i+3] == UInt8[0x50, 0x4b, 0x01, 0x02], 1:length(bomb)-3)
        bomb[k+24:k+27] .= reinterpret(UInt8, [UInt32(900_000_000)])      # "unpacks to 900 MB"
    end
    @test_throws ArgumentError PE.upload!(ex, "ana", bomb; replaces = "scen")
    fake = copy(high); fake[200:end] .= 0x00                               # (an .xlsx that doesn't open)
    @test_throws ArgumentError PE.upload!(ex, "ana", fake; replaces = "scen")
    @test isempty(filter(f -> endswith(f, ".xlsx"), readdir(joinpath(dir, "inputs"))))   # nothing kept from those

    u = PE.upload!(ex, "ana", high; replaces = "scen", label = "High")
    @test u["sheets"] == ["NZP", "BAU", "Info input variables"] && u["owner"] == "ana" && !u["shared"]
    ana = PE.inputs_info(ex, "ana")["scen"]
    @test [c["label"] for c in ana] == ["scen.xlsx › NZP", "High › NZP", "High › BAU"]      # (no notes)
    @test length(PE.inputs_info(ex, "joan")["scen"]) == 1                                   # hers only

    # a run with her sheet: its values
    id = ana[2]["id"]
    job = finish(ex, PE.submit_run!(ex, "ana", "high", Pair{String,Any}[], ["scen" => id]))
    @test job.status === :done
    r = ex.runs[job.result]
    base = only(x for x in values(ex.runs) if x.meta["owner"] == "")
    @test PE.series(ex, "ana", "y", [r.meta["id"]])["runs"][r.meta["id"]][1][end] == 20      # 5 × 4
    @test PE.series(ex, "ana", "y", [base.meta["id"]])["runs"][base.meta["id"]][1][end] == 8
    @test r.meta["inputs"] == Dict("scen" => id)
    @test_throws ArgumentError PE.submit_run!(ex, "joan", "", Pair{String,Any}[], ["scen" => id])   # not hers

    # shared: others choose it too; only she (or an administrator) changes or deletes it
    @test_throws KeyError PE.change_upload!(ex, "joan", u["id"], Dict(:shared => true))     # (not even seen)
    PE.change_upload!(ex, "ana", u["id"], Dict(:shared => true))
    joan = PE.inputs_info(ex, "joan")["scen"]
    @test joan[2]["label"] == "High (by ana) › NZP"
    @test_throws PE.Forbidden PE.delete_upload!(ex, "joan", u["id"])

    # the limits
    PE.update_settings!(ex, Dict("max_uploads_per_user" => 1))
    @test_throws ArgumentError PE.upload!(ex, "ana", high; replaces = "scen")
    PE.update_settings!(ex, Dict("max_uploads_per_user" => 10, "max_upload_mb" => 1))
    @test_throws ArgumentError PE.upload!(ex, "ana", vcat(high, zeros(UInt8, 2^20)); replaces = "scen")

    # kept on disk; deleting removes the file
    @test length(PE.explorer(m; dir, users = :header).uploads) == 1
    @test PE.delete_upload!(ex, "ana", u["id"])
    @test isempty(readdir(joinpath(dir, "inputs")))

    # the routes: the file as the request's body
    router = PE.routes(ex)
    resp = router(HTTP.Request("POST", "/api/uploads?replaces=scen&label=Mine", ["X-PySD-User" => "pere"], high))
    @test resp.status == 200 && JSON3.read(resp.body).label == "Mine"
    @test JSON3.read(router(HTTP.Request("GET", "/api/uploads", ["X-PySD-User" => "pere"])).body).files == ["scen"]
end
