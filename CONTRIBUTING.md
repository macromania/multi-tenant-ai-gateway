# Contributing

Thank you for your interest. This repository is a proof of concept that measures two ways to serve
many tenants with agentgateway. Contributions that improve the measurements, fix bugs, or clarify the
documentation are welcome.

## Before you start

- Read the [development guide](docs/local-development.md), especially "Writing scripts": the
  scripts run under macOS `/bin/bash` 3.2 and GNU Make 3.81, which behave differently from newer
  versions.
- Read the [comparison guide](docs/tenancy-comparison.md) to see how each experiment proves that it
  measured what it claims.
- For a larger change, open an issue first to discuss it.

## Making a change

- Keep changes small and focused, and keep `make help` and command output grouped into named
  sections with plain output under `NO_COLOR=1`.
- Never put a key in a process argument, a log, or anything under `results/`.
- Choose ports only from the reserved blocks in `ports.env`.
- Write documentation in plain English, with complete sentences.

## Verifying a change

There is no offline test suite; every command verifies its own outcome on the local clusters.

- Parse every changed script with the project interpreter: `/bin/bash -n scripts/<name>.sh`.
- Run the commands your change affects against both clusters, for example
  `make check CLUSTER=both`, and include the relevant output in the pull request.
- A change to `Makefile`, `scripts/` (except the report generator), `deploy/`, `versions.env`, or
  `ports.env` changes the input fingerprint, so `make results` marks earlier runs as stale. New
  results must come from a campaign run on committed code.

## Licence

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
