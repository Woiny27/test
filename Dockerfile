# ==============================================================
# Dockerfile — Etalon Task Environment
# Project: tobymao/sqlglot @ v30.17.0
# ==============================================================
# Design notes:
#   * Everything is installed into the image's own interpreter, not a
#     virtualenv. mini-swe-agent runs every command through `bash -lc`; a
#     login shell sources /etc/profile and resets PATH, which silently drops
#     a venv and lands the agent on a different interpreter.
#   * sqlglot has no runtime dependencies. The packages below are only what
#     its own test suite imports: pytest, plus duckdb/pandas/numpy for the
#     executor and optimizer round-trip tests and pytz/dateutil for the
#     temporal tests.
#   * `pip install -e /app` is the repository's normal install path. It needs
#     setuptools_scm, which reads git tags; the image fetches a single commit
#     with no tags, so the version is supplied through
#     SETUPTOOLS_SCM_PRETEND_VERSION. The two artifacts the install writes
#     into the checkout (sqlglot/_version.py and sqlglot.egg-info/) are both
#     already listed in the repository's own .gitignore, so /app stays a
#     clean git worktree.
#   * PYTHONDONTWRITEBYTECODE keeps __pycache__ out of the working tree.
#   * The repository declares one submodule, sqlglot-integration-tests, over an
#     SSH remote that is not publicly reachable. Its loader
#     (tests/test_integration_loader.py) skips cleanly when the directory is
#     absent, so the submodule step is kept but allowed to fail.
# ==============================================================

FROM python:3.13.7-slim-bookworm

ARG REPO_URL="https://github.com/tobymao/sqlglot.git"
ARG BASE_COMMIT="9a8129b6f2667673f24713f4b49162ebae1f699d"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Fetch the selected repository commit inside the image.
# The delivery build context intentionally contains only Dockerfile/.dockerignore,
# so this Dockerfile must not rely on local source files from your machine.
RUN git init -q . && \
    git remote add origin "$REPO_URL" && \
    git fetch --depth 1 origin "$BASE_COMMIT" && \
    git checkout --detach "$BASE_COMMIT" && \
    (git submodule update --init --recursive || true) && \
    git config --global --add safe.directory /app && \
    printf '\n# Etalon worker outputs\ntrajectories/\npatches/\n*.log\n' >> .git/info/exclude && \
    git rev-parse HEAD > /etc/etalon_base_commit

ENV ETALON_REPO_URL="$REPO_URL"
ENV ETALON_BASE_COMMIT="$BASE_COMMIT"

# ------------------------------------------------------------------
# Test toolchain, fully pinned and installed with --no-deps so nothing is
# resolved at build time.
#
#   pytest 9.1.1 (+ pluggy, iniconfig, packaging, pygments)
#   duckdb 1.5.5              tests/test_optimizer.py, tests/test_executor.py
#   pandas 3.0.5 + numpy      tests/test_executor.py DataFrame comparisons
#   python-dateutil, pytz     tests/test_expressions.py temporal tests
# ------------------------------------------------------------------
RUN python -m pip install --no-deps --no-cache-dir \
    "iniconfig==2.3.0" \
    "packaging==26.3" \
    "pluggy==1.6.0" \
    "pygments==2.21.0" \
    "pytest==9.1.1" \
    "duckdb==1.5.5" \
    "numpy==2.5.2" \
    "pandas==3.0.5" \
    "python-dateutil==2.9.0.post0" \
    "pytz==2026.3.post1" \
    "six==1.17.0" \
    "tzdata==2026.3"

# Register the checkout as an editable install so `import sqlglot` resolves to
# /app/sqlglot and the agent's edits take effect with no reinstall.
RUN python -m pip install --no-deps --no-cache-dir \
    "setuptools==80.9.0" "setuptools_scm==9.2.0" && \
    SETUPTOOLS_SCM_PRETEND_VERSION=30.17.0 \
    python -m pip install --no-deps --no-cache-dir --no-build-isolation -e /app

# Sanity: the pinned toolchain must resolve identically from a login shell,
# `python` must be on PATH for tests that shell out to it, and the checkout
# must still be clean after installing.
RUN bash -lc 'python -c "import sqlglot, pytest, duckdb, pandas; print(sqlglot.__version__, sqlglot.__file__, pytest.__version__)"' && \
    sh -lc 'python -c "import sqlglot; print(sqlglot.__file__)"' && \
    bash -lc 'command -v python' && \
    test -z "$(git -C /app status --porcelain --untracked-files=all)" || \
    (git -C /app status --porcelain --untracked-files=all; false)

CMD ["/bin/bash"]
