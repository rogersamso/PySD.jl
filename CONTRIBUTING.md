# Contributing to PySD.jl

Bug reports, fixes and new features are welcome.  This page says where to
report what, how to run the tests, and what a pull request needs to be
merged.

## Where to report what

PySD.jl is half of a pair: [PySD](https://github.com/SDXorg/pysd)'s Julia
builder translates Vensim and XMILE models to Julia, and PySD.jl runs them.

- **Here**: a function that gives a different result than Vensim, an error
  or a slow run in a model written with `@equations`, the Excel and data
  readers, `run_model`, the LaTeX export.
- **In [SDXorg/pysd](https://github.com/SDXorg/pysd/issues)**: a model that
  fails to translate, or Julia code written by `translate_to_julia` that is
  wrong before it runs.

If you aren't sure which, open the issue here.  A good report has the
smallest model that shows the problem, what you expected (Vensim's or Python
PySD's result, if you have it), what you got, and your Julia and PySD.jl
versions.

For a large change, such as a new operator or a change to how models are
built, open an issue first so we can agree on the approach before you write
it.

## Setting up

Fork the repository, then:

```sh
git clone --recurse-submodules https://github.com/<you>/PySD.jl
cd PySD.jl
julia --project -e 'using Pkg; Pkg.instantiate()'
```

`--recurse-submodules` fetches [SDXorg/test-models](https://github.com/SDXorg/test-models)
into `test/test-models`: the Vensim models and outputs the tests compare
against.  In a clone without it, run `git submodule update --init
test/test-models`.

## Running the tests

```sh
julia --project -e 'using Pkg; Pkg.test()'
```

Without test-models, the comparisons with Vensim's outputs are skipped with
a warning; run them before opening a pull request.

The tests include [Aqua](https://github.com/JuliaTesting/Aqua.jl)'s checks:
no type piracy, no method ambiguities, and a compat bound for every
dependency.

## What a change needs

- **Tests.** A fix comes with a test that fails without it.  The tests of
  the runtime functions are in `test/runtests.jl` and the files it includes;
  the tests of the DSL are in `test/test_dsl.jl`, with their models in
  `test/dsl/`.  When a test-models model covers the case, compare against
  its Vensim output rather than against numbers written by hand.
- **Fast functions stay fast.** Functions called at every step of a run must
  not allocate and must return the number type they are given (`Float32`,
  ForwardDiff's `Dual`, …).  `test/test_number_types.jl` checks both: add
  new functions of this kind to it.
- **Julia 1.10.** CI runs the tests on Julia 1.10, the oldest version
  PySD.jl supports, on the latest Julia 1, and with the oldest version of
  every dependency that the compat bounds allow.  A new dependency needs a
  `[compat]` entry in `Project.toml` whose lower bound really works.
- **Test data.** The Excel files in `test/data/` are written by the Python
  scripts next to them.  To change one, change its script and run it from
  the repository root, and commit both.
- **Documentation.** The README is the documentation.  A change that users
  will notice updates it.
- **Code style.** There's no formatter.  Follow the code around your change:
  4 spaces, a docstring for a new exported function, and comments that say
  why rather than what.

Don't change the version in `Project.toml`: it's set when a release is made.
Models translated by PySD check the PySD.jl version they were written for
(`check_compat`), so say in the pull request if your change renames or
removes an exported function, or changes what one returns.

## Pull requests

- One change per pull request.  Small ones are reviewed faster.
- Title it as the history does, with the part it changes first:
  `DSL: …`, `Tests: …`, `CI: …`, or a plain sentence for the runtime
  functions.
- In the description, say what changes and why, and how you tested it.
- CI must pass before a pull request is merged.  On your first pull request,
  GitHub waits for a maintainer to approve the CI run before it starts.
- Pull requests are merged into `main` by a maintainer once they're
  reviewed.

Contributions to PySD.jl are released under its [MIT License](LICENSE).
