# Development

## Running the tests

The tests use the reference models of [SDXorg/test-models](https://github.com/SDXorg/test-models),
included as a git submodule:

```sh
git submodule update --init test/test-models
julia --project -e 'using Pkg; Pkg.test()'
```

Set `PYSD_TEST_MODELS` to use another checkout of test-models (e.g.
`tests/test-models/tests` in a PySD checkout).  Without test-models the
reference tests are skipped with a warning.

## Building this documentation

```sh
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

writes the site to `docs/build` (open `docs/build/index.html`).  The code
examples run while it builds, so a change that breaks one fails the build.
On GitHub, every push to `main` publishes it as the development version,
and every release tag as that version and `stable`.

## Version compatibility

Generated models embed the PySD.jl version they were translated against.
On load, `check_compat` verifies that the installed PySD.jl is compatible.
A major-version mismatch raises an error; a minor-version mismatch emits a
warning.

## Contributing

See [CONTRIBUTING.md](https://github.com/rogersamso/PySD.jl/blob/main/CONTRIBUTING.md).
