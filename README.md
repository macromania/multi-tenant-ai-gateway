# Multi-tenant AI gateway: shared versus dedicated

A Make-driven proof of concept that compares two ways to serve many tenants with
[agentgateway](https://agentgateway.dev/) on local Kind clusters:

- **mtag-shared**: one agentgateway (one controller, one proxy) serves every tenant. The tenant's
  API key tells the gateway who is calling.
- **mtag-dedicated**: every tenant gets its own complete agentgateway (its own controller and proxy)
  in its own Kubernetes namespace.

Both clusters are built by the same commands, run the same in-cluster mock of the OpenAI chat
completions API for load tests, and have their own Prometheus and Grafana. A real Microsoft Foundry
deployment is used only for small smoke and separation checks. The results are input to a later
architecture decision; this repository does not choose a design.

"Separation" here means what namespaces and separate gateways give tenants that share a cluster.
"Isolation" means a dedicated cluster per tenant, which is out of scope.

## Start locally

Start Docker Desktop, then:

```bash
make help
make doctor
make up CLUSTER=shared
make up CLUSTER=dedicated
make status CLUSTER=both
```

Every command that touches a cluster needs `CLUSTER=shared` or `CLUSTER=dedicated`; no cluster is
ever chosen for you. Each cluster has its own kubeconfig under `.local/<cluster>/` and never changes
your current Kubernetes context, Docker context, or Azure subscription.

## Observe

```bash
make grafana CLUSTER=shared        # http://127.0.0.1:38484/d/mtag-tenants
make grafana CLUSTER=dedicated     # http://127.0.0.1:38494/d/mtag-tenants
make prometheus CLUSTER=shared     # http://127.0.0.1:38485
```

Grafana viewing needs no login. Each command keeps running until Ctrl-C.

## Connect the Foundry model

Azure CLI 2.80 or later and an active `az login` are required.

```bash
make foundry-register
make foundry-up
make gateway-configure CLUSTER=both
```

`foundry-up` deploys one model deployment (`gateway-chat`) that every tenant in both clusters shares.
It does not change any cluster. `gateway-configure` adds the Foundry route behind tenant
authentication. **Foundry model calls can incur charges.**

## Stop or remove resources

```bash
make down CLUSTER=shared CONFIRM=1
make down CLUSTER=dedicated CONFIRM=1
make foundry-down CONFIRM=1
```

`down` removes one local cluster. Azure resources, `.env`, and `.env.tenants` remain.

## More

- [Development guide](docs/local-development.md): prerequisites, ports, state, safety boundaries.
- [Implementation plan](docs/plans/tenancy-comparison-execplan.md): the living plan and its decisions.
- [Review findings](FINDINGS.md): what each review found and what was done about it.
