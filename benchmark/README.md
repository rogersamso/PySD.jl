# Benchmark: a Vensim model in Julia and in Python

These scripts time a Vensim model translated by PySD to PySD.jl's DSL against
the same model in Python PySD, and compare their results value by value.  They
work for any model PySD translates with `backend = "dsl"`, and for models that
take data from other models (regional models fed by a global one).

## Steps

1. **Translate** each model (Python, from a PySD checkout with the Julia
   builder):

   ```sh
   python -c "import pysd; pysd.translate_to_julia('model.mdl', backend='dsl', split_views=True)"
   ```

   This writes `model_dsl/`, with `model.jl` (the model) and `names.tsv`
   (Vensim's name of each variable and its Julia name).

2. **Run the Python reference**, one model after the other (each model's
   results are the next one's parent data):

   ```sh
   python run_python.py global.mdl global.tab
   python run_python.py region.mdl region.tab global.tab
   ```

3. **Run the models in Julia**, in one session and the same order (each gets
   the runs before it as its parents):

   ```sh
   julia --project=path/to/PySD.jl run_julia.jl out/ global_dsl/global.jl region_dsl/region.jl
   ```

   It prints, and writes to `out/julia_times.tsv`, each model's build time,
   first run (mostly compiling), a later run and the memory used, and saves
   its results to `out/<model>_results.tsv`.

4. **Compare** each model:

   ```sh
   python compare.py region.tab out/region_results.tsv region_dsl/names.tsv
   python compare.py region.tab out/region_results.tsv region_dsl/names.tsv first
   ```

   It counts the values that agree within 0, 1e-12, 1e-9, 1e-6 and 1e-3
   (relative), and lists the largest differences; with `first`, the variables
   that differ, the earliest first, which is where to start looking.

## Things to know

- **Run one thing at a time.**  Two runs at once share the processor, and both
  times come out wrong.
- **The first Julia run is mostly compiling**; later runs (other parameters,
  other inputs, `run_model(m; params = …)`) take seconds.  A model saved as a
  package (`@precompile_model`, see the README) loads ready to run.
- **Models are translated with Python's digits** (`numerics = :python`): sums,
  powers, exponentials and inverses round as in Python, so values agree to the
  last digit almost everywhere.  A model that compares values that should be
  exactly equal (`IF x < 0` where x is a difference of two equal sums) can
  still take another branch at a step where the last digit differs.
- **Results files are read exactly**: `run_python.py` reads parents' results
  with pandas' exact float parser (its default one changes the last digit of
  many values, and then Python's own inputs differ from Julia's).
