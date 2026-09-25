# Security policy

## Supported versions

This repository is a proof of concept for local Kind clusters. Only the latest commit on the default
branch is maintained. It is not designed or hardened for production use.

## Reporting a vulnerability

Please report a vulnerability privately through GitHub's
[private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
for this repository ("Security" tab, "Report a vulnerability"). Do not open a public issue for a
vulnerability, and do not include real credentials in a report.

A report is most useful when it names the command, the file, what an attacker could do, and how to
reproduce it on the local clusters.

## Scope and known limitations

The project runs everything on your own machine and binds every host listener to `127.0.0.1`. It is
not protection from a malicious local administrator, cluster administrator, or another process
running as your operating-system account.

These limitations are known and accepted for a local proof of concept, and are not treated as
vulnerabilities. The [comparison guide](docs/tenancy-comparison.md#security-limitations-accepted-for-this-proof-of-concept)
explains each one:

- `make dashboard` forwards the proxy admin port, whose unauthenticated debug trace can record request
  headers, including tenant keys and the Foundry key, while the forward runs.
- Make evaluates `$(...)` in command-line values; the Makefile takes every value literally and the
  scripts validate each one.
- curl reads your `~/.curlrc`, so a verbose or trace setting there would print Authorization headers.
- Prometheus accepts unauthenticated remote writes while it is forwarded to localhost.
- The mock upstream's key administration endpoint has no authentication; it is reachable only inside
  the cluster.
- Grafana allows anonymous Viewer access on `127.0.0.1`, and the k6 control API used to stop load is
  unauthenticated inside the cluster.

Every agentgateway controller, as the upstream v1.5.0 chart grants it, can read Secrets in every
namespace. The project records this as a finding rather than changing it.

## Handling credentials

Keys live only in the Git-ignored `.env` and `.env.tenants` files with mode 0600, never in process
arguments or under `results/`. Use non-sensitive test prompts: prompts sent to Microsoft Foundry
leave your machine, and Foundry calls can incur charges.
