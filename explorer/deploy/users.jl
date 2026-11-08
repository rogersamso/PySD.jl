# The explorer's users (users = :password), from the command line: for the
# first administrator, or when no one can log in.  The password is read from
# the input, never from the command line (where other users could see it).
#
#   julia users.jl DIR set NAME [--admin|--no-admin]   (asks for the password, or reads a line from a pipe)
#   julia users.jl DIR list
#   julia users.jl DIR remove NAME
#
# In the container: docker compose exec explorer julia /app/users.jl /data set roger --admin
using PySDExplorer: load_users, save_users, set_password!

function read_password()
    if isa(stdin, Base.TTY)
        a = String(Base.getpass("Password (at least 10 characters)")); b = String(Base.getpass("Again"))
        a == b || error("the two passwords differ")
        return a
    end
    return strip(readline(stdin))
end

dir, cmd = ARGS[1], get(ARGS, 2, "list")
if cmd == "set"
    name = ARGS[3]
    admin = "--admin" in ARGS ? true : "--no-admin" in ARGS ? false : nothing
    set_password!(dir, name, read_password(); admin)
    println("$name: password set", admin === nothing ? "" : admin ? ", administrator" : ", not an administrator")
elseif cmd == "list"
    for (n, u) in sort!(collect(load_users(dir)); by = first)
        println(rpad(n, 20), u["admin"] === true ? "admin  " : "       ", "last login ", something(u["last_login"], "never"))
    end
elseif cmd == "remove"
    users = load_users(dir)
    haskey(users, ARGS[3]) || error("no user $(ARGS[3])")
    delete!(users, ARGS[3])
    save_users(dir, users)                  # (their sessions end at their next request)
    println("$(ARGS[3]) removed")
else
    error("commands: set NAME [--admin|--no-admin], list, remove NAME")
end
