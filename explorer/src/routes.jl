# The routes: the page's files, and the API it calls (api/…), each answered
# for the user asking.

const TYPES = Dict(".html" => "text/html; charset=utf-8", ".js" => "text/javascript; charset=utf-8",
                   ".css" => "text/css; charset=utf-8", ".svg" => "image/svg+xml", ".png" => "image/png")

_json_response(x; status = 200) =
    HTTP.Response(status, ["Content-Type" => "application/json", "Cache-Control" => "no-store"], JSON3.write(x))
_error(msg; status = 400) = _json_response(Dict("error" => msg); status)

function _asset(req)
    path = HTTP.URI(req.target).path
    path = path == "/" ? "index.html" : lstrip(path, '/')
    occursin("..", path) && return HTTP.Response(404)
    f = joinpath(ASSETS, path)
    isfile(f) || return HTTP.Response(404)
    return HTTP.Response(200, ["Content-Type" => get(TYPES, splitext(f)[2], "application/octet-stream")], read(f))
end

_query(req) = HTTP.queryparams(HTTP.URI(req.target))
_body(req) = isempty(req.body) ? JSON3.Object() : JSON3.read(String(req.body))
_param(req, k) = HTTP.unescapeuri(HTTP.getparams(req)[k])

function routes(ex::Explorer)
    r = HTTP.Router(_asset)
    # each handler gets the request and the user; errors become answers
    # with the explorer's own logins, a request that changes something carries
    # X-PySD-Request (the page adds it; another site's page can't)
    checked(req) = ex.auth.mode === :password && req.method != "GET" && isempty(HTTP.header(req, "X-PySD-Request", "")) &&
                   throw(Forbidden("a request without X-PySD-Request"))
    on(method, path, f; anyone = false) = HTTP.register!(r, method, path, req -> try
        checked(req)
        f(req, anyone ? "" : user_of(ex, req))
    catch e
        e isa NotLoggedIn && return _json_response(Dict("error" => "log in", "login" => true); status = 401)
        e isa Forbidden && return _error(e.msg; status = 403)
        e isa KeyError && return _error("not found: $(e.key)"; status = 404)
        e isa ArgumentError && return _error(e.msg)
        e isa JSON3.Error && return _error("not JSON")
        @error "request failed" exception = (e, catch_backtrace())
        return _error(sprint(showerror, e); status = 500)
    end)
    cached(key, f) = HTTP.Response(200, ["Content-Type" => "application/json"], get!(() -> JSON3.write(f()), ex.cache, key))
    admin(user) = is_admin(ex, user) || throw(Forbidden("for administrators"))

    on("GET", "/api/me", (_, u) -> _json_response(me_info(ex, u)))

    # logins (users = :password)
    pw(u) = ex.auth.mode === :password || throw(ArgumentError("this explorer has no logins of its own"))
    on("POST", "/api/login", (req, _) -> begin
        pw("")
        b = _body(req)
        token = login!(ex, String(get(b, :user, "")), String(get(b, :password, "")), _address(req))
        HTTP.Response(200, ["Content-Type" => "application/json", "Set-Cookie" => _session_cookie(ex, token)],
                      JSON3.write(Dict("ok" => true)))
    end; anyone = true)
    on("POST", "/api/logout", (req, _) -> begin
        pw("")
        logout!(ex, req)
        HTTP.Response(200, ["Content-Type" => "application/json", "Set-Cookie" => _session_cookie(ex, ""; maxage = 0)],
                      JSON3.write(Dict("ok" => true)))
    end; anyone = true)
    on("POST", "/api/password", (req, u) -> begin
        pw(u)
        b = _body(req)
        change_password!(ex, u, String(get(b, :current, "")), String(get(b, :new, "")))
        _json_response(Dict("ok" => true))       # the user's sessions ended: log in again
    end)
    on("GET", "/api/model", (_, u) -> cached("model", () -> model_info(ex)))
    on("GET", "/api/inputs", (_, u) -> (refresh_inputs!(ex); _json_response(inputs_info(ex, u))))
    on("GET", "/api/uploads", (_, u) -> _json_response(Dict("uploads" => uploads_info(ex, u), "files" => _model_files(ex))))
    on("POST", "/api/uploads", (req, u) -> begin
        q = _query(req)
        _json_response(upload!(ex, u, req.body; replaces = get(q, "replaces", ""), label = get(q, "label", "")))
    end)
    on("PATCH", "/api/uploads/{id}", (req, u) -> _json_response(change_upload!(ex, u, _param(req, "id"), _body(req))))
    on("DELETE", "/api/uploads/{id}", (req, u) -> (delete_upload!(ex, u, _param(req, "id")); _json_response(Dict("deleted" => true))))

    on("GET", "/api/runs", (_, u) -> _json_response(runs_info(ex, u)))
    on("POST", "/api/runs", (req, u) -> begin
        b = _body(req)
        job = submit_run!(ex, u, String(get(b, :label, "")), pairs(get(b, :params, Dict())), pairs(get(b, :inputs, Dict())))
        _json_response(job_info(ex, job))
    end)
    on("PATCH", "/api/runs/{id}", (req, u) -> _json_response(_public(change_run!(ex, u, _param(req, "id"), _body(req)))))
    on("DELETE", "/api/runs/{id}", (req, u) -> (delete_run!(ex, u, _param(req, "id")); _json_response(Dict("deleted" => true))))
    on("GET", "/api/runs/{id}/csv", (req, u) -> begin
        id = _param(req, "id")
        csv = run_csv(ex, u, id)
        name = replace(get(ex.runs[id].meta, "label", id), r"[^A-Za-z0-9_\- ]" => "_")
        HTTP.Response(200, ["Content-Type" => "text/csv; charset=utf-8", "Cache-Control" => "no-store",
                            "Content-Disposition" => "attachment; filename=\"$(name).csv\""], csv)
    end)
    on("GET", "/api/series", (req, u) -> begin
        q = _query(req)
        _json_response(series(ex, u, q["name"], split(get(q, "runs", ""), ','; keepempty = false)))
    end)

    on("GET", "/api/jobs", (_, u) -> _json_response(jobs_info(ex, u)))
    on("GET", "/api/jobs/{id}", (req, u) -> _json_response(lock(() -> job_info(ex, _job(ex, u, _param(req, "id"))), ex.cond)))
    on("DELETE", "/api/jobs/{id}", (req, u) -> _json_response(lock(() -> job_info(ex, cancel!(ex, u, _param(req, "id"))), ex.cond)))

    on("GET", "/api/analyses", (_, u) -> _json_response(analyses_info(ex, u)))
    on("GET", "/api/analyses/{id}", (req, u) -> _json_response(analysis(ex, u, _param(req, "id"))))
    on("POST", "/api/analyses", (req, u) -> begin
        b = _body(req)
        job = submit_analysis!(ex, u; label = String(get(b, :label, "")), around = String(get(b, :around, "")),
                               params = String.(get(b, :params, String[])), outputs = String.(get(b, :outputs, String[])),
                               step = get(b, :step, 0.01), years = get(b, :years, false) === true)
        _json_response(job_info(ex, job))
    end)
    on("PATCH", "/api/analyses/{id}", (req, u) -> _json_response(_summary(change_analysis!(ex, u, _param(req, "id"), _body(req)))))
    on("DELETE", "/api/analyses/{id}", (req, u) -> (delete_analysis!(ex, u, _param(req, "id")); _json_response(Dict("deleted" => true))))

    on("GET", "/api/code", (_, u) -> (may_see_code(ex, u) || throw(Forbidden("the code isn't shown")); cached("code", () -> code_info(ex))))
    on("GET", "/api/code/{id}", (req, u) -> begin
        may_see_code(ex, u) || throw(Forbidden("the code isn't shown"))
        text = code_text(ex, _param(req, "id"))
        text === nothing ? _error("no such file"; status = 404) : _json_response(Dict("text" => text))
    end)

    on("GET", "/api/views", (_, u) -> _json_response(views_info(ex, u)))
    on("POST", "/api/views", (req, u) -> begin
        b = _body(req)
        name = strip(String(get(b, :name, "")))
        isempty(name) && return _error("a view needs a name")
        write(_view_file(ex, u, name), JSON3.write(b))
        _json_response(views_info(ex, u))
    end)
    on("DELETE", "/api/views/{name}", (req, u) -> (rm(_view_file(ex, u, _param(req, "name")); force = true);
                                                    _json_response(views_info(ex, u))))

    on("POST", "/api/static", (req, u) -> begin
        b = _body(req)
        html = static_page(ex, String.(b.runs), String.(b.names); user = u, view = get(b, :view, nothing))
        HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8",
                            "Content-Disposition" => "attachment; filename=\"$(isempty(ex.title) ? "model" : ex.title)-explorer.html\""], html)
    end)

    on("GET", "/api/admin", (_, u) -> (admin(u); _json_response(admin_info(ex))))
    on("PUT", "/api/admin/settings", (req, u) -> (admin(u); _json_response(update_settings!(ex, _body(req)))))
    on("GET", "/api/admin/users", (_, u) -> (admin(u); pw(u); _json_response(users_info(ex))))
    on("POST", "/api/admin/users", (req, u) -> begin
        admin(u); pw(u)
        b = _body(req)
        name = strip(String(get(b, :name, "")))
        _json_response(Dict("user" => name, "password" => create_user!(ex, name; admin = get(b, :admin, false) === true)))
    end)
    on("POST", "/api/admin/users/{name}/password", (req, u) -> (admin(u); pw(u);
        _json_response(Dict("password" => reset_password!(ex, _param(req, "name"))))))
    on("PATCH", "/api/admin/users/{name}", (req, u) -> begin
        admin(u); pw(u)
        a = get(_body(req), :admin, nothing)
        a isa Bool || throw(ArgumentError("admin is true or false"))
        set_admin!(ex, _param(req, "name"), a)
        _json_response(users_info(ex))
    end)
    on("DELETE", "/api/admin/users/{name}", (req, u) -> begin
        admin(u); pw(u)
        _param(req, "name") == u && throw(ArgumentError("you can't remove yourself"))
        remove_user!(ex, _param(req, "name"))
        _json_response(users_info(ex))
    end)
    return r
end
