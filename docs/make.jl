# Builds the documentation: julia --project=docs docs/make.jl
# (CI deploys it to GitHub Pages: the latest from main as "dev", each release
# tag as its version and "stable".)
using Documenter, PySD
using OrdinaryDiffEqLowOrderRK, SciMLBase       # loads PySD's SciML extension, for its docstrings

# NEWS.md is the changelog page, as it is in the repository
cp(joinpath(@__DIR__, "..", "NEWS.md"), joinpath(@__DIR__, "src", "news.md"); force = true)

makedocs(;
    sitename = "PySD.jl",
    authors = "PySD.jl contributors",
    modules = [PySD, Base.get_extension(PySD, :PySDSciMLBaseExt)],
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://rogersamso.github.io/PySD.jl",
        edit_link = "main",
        size_threshold_ignore = ["functions.md", "api.md"],
    ),
    pages = [
        "Home" => "index.md",
        "Guide" => [
            "Translating a Vensim model" => "translating.md",
            "Writing models" => "writing.md",
            "Running a model" => "running.md",
            "Solvers and the model's ticks" => "solvers.md",
            "Sensitivity and derivatives" => "sensitivity.md",
            "Models as packages" => "packages.md",
        ],
        "Vensim functions" => "functions.md",
        "Reference" => "api.md",
        "Development" => "development.md",
        "News" => "news.md",
    ],
    checkdocs = :exports,
    # the helpers that translated ODE and MTK models call are not all documented yet
    warnonly = [:missing_docs],
)

deploydocs(; repo = "github.com/rogersamso/PySD.jl", devbranch = "main", push_preview = false)
