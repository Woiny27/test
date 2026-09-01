# Golden Tests

This directory is hidden from the agent during task runs.

Required entrypoints:

- `run_tests_f2p.sh` — runs all Fail-to-Pass checks. It must fail before the
  correct solution is applied and pass after the solution is applied.
- `run_tests_p2p.sh` — runs all Pass-to-Pass/regression checks. It must pass
  before and after the solution is applied.

The scripts may call any language or framework internally. The tooling only
checks their shell exit codes.
