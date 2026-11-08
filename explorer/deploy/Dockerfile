# PySD Explorer: any model translated to PySD.jl's DSL, mounted at /model.
# Build from the root of the PySD.jl repository:
#   docker build -f explorer/deploy/Dockerfile -t pysd-explorer .
FROM julia:1.12

ENV JULIA_DEPOT_PATH=/opt/julia \
    JULIA_PROJECT=/app
# not root; its depot stays writable (Julia compiles again for another CPU if it must)
RUN useradd --create-home --uid 1000 explorer \
    && mkdir -p /app /opt/julia /data /src && chown explorer /app /opt/julia /data /src
USER explorer
WORKDIR /app

# PySD.jl and the explorer, and what translated models use
COPY --chown=explorer Project.toml /src/PySD.jl/Project.toml
COPY --chown=explorer src /src/PySD.jl/src
COPY --chown=explorer ext /src/PySD.jl/ext
COPY --chown=explorer explorer /src/PySD.jl/explorer
RUN julia -e 'using Pkg; \
        Pkg.develop([PackageSpec(path = "/src/PySD.jl"), PackageSpec(path = "/src/PySD.jl/explorer")]); \
        Pkg.add(["DimensionalData", "Unitful"]); \
        Pkg.precompile()'

COPY --chown=explorer explorer/deploy/serve.jl /app/serve.jl

VOLUME ["/data"]
EXPOSE 8080
CMD ["julia", "--threads=auto", "/app/serve.jl"]
