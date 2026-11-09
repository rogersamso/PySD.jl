# A page that works without the server: the runs and names given, the
# analyses and (if the user may see it) the code, all in one HTML file.

"""
    static_page(ex, ids, names; user = "local", view = nothing) -> String

The explorer's page with the runs `ids` (those `user` may see) and the values
of `names`: one HTML file that opens anywhere, without a server.
"""
function static_page(ex::Explorer, ids, names; user = "local", view = nothing)
    ids = [i for i in ids if haskey(ex.runs, i) && visible(ex, user, ex.runs[i].meta)]
    keep = Set(names)
    info = model_info(ex)
    info["names"] = [n for n in info["names"] if n["name"] in keep]
    code = may_see_code(ex, user)
    me = me_info(ex, user)
    me["code"] = code && !isempty(ex.code)
    data = Dict("model" => info, "me" => me, "runs" => [_public(ex.runs[i]) for i in ids],
                "series" => Dict(n => series(ex, user, n, ids) for n in names),
                "analyses" => [a for a in values(ex.analyses) if visible(ex, user, a)],
                "view" => view,
                "code" => code ? code_info(ex) : [],
                "texts" => code ? Dict(id => code_text(ex, id) for (id, _) in ex.code) : Dict())
    html = read(joinpath(ASSETS, "index.html"), String)
    inline(tag, file) = tag * replace(read(joinpath(ASSETS, file), String), "</script" => "<\\/script") *
                        (startswith(tag, "<style") ? "</style>" : "</script>")
    payload = replace(JSON3.write(data), "</" => "<\\/")
    return replace(html,
        """<link rel="stylesheet" href="app.css">""" => inline("<style>", "app.css"),
        """<script src="vendor/plotly.min.js"></script>""" => inline("<script>", "vendor/plotly.min.js"),
        """<script src="app.js"></script>""" => "<script>window.PYSD_STATIC = $payload;</script>" *
                                               inline("<script>", "app.js"))
end
