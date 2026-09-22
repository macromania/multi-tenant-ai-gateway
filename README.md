# Multi-tenant AI gateway development environment

A Make-driven local Kind cluster running [agentgateway](https://agentgateway.dev/),
with guided Microsoft Foundry model deployment and OpenAI-compatible curl requests.
There is no local application backend or model server.

This first increment is a **single-user development environment**, not tenant
isolation or a production deployment.

## Start locally

Start Docker Desktop, then:

```bash
make help
make doctor
make up
make check
```

The project uses its own kubeconfig and Kind cluster. It does not change your
current Kubernetes context, Docker context, or Azure subscription. Local startup
does not call Azure or deploy a model.

With K9s installed, browse the project cluster using its local kubeconfig:

```bash
make k9s
```

## Connect a model

Azure CLI 2.80 or later and an active `az login` are required.

```bash
make foundry-register
make foundry-regions
make foundry-up
```

Registration requires confirmation unless the service is already registered.
Setup guides region and model selection, checks quota and platform capacity,
then asks you to confirm the actual deployment before creating resources.
It creates a dedicated Foundry account, default project, and chat model
deployment, saves protected configuration in `.env`, and configures agentgateway.

**Foundry model calls can incur charges.** The confirmation shows the subscription,
region, model, SKU, capacity, and network/authentication choices. No model request
is sent automatically. Capacity limits are not spending limits.

## Send a prompt

```bash
make prompt PROMPT="Explain what an agent gateway does in one sentence."
make prompt PROMPT_FILE=prompt.txt FORMAT=json
make endpoints
```

The prompt command invokes curl against agentgateway's `/v1/chat/completions`
route. It manages and cleans up its own temporary localhost connection. It does
not call Azure directly or expose the Azure key to the client.

For another client or SDK, keep `make gateway-forward` running and use
`http://127.0.0.1:38470/v1` with the separate local gateway API key from `.env`.
Stop forwarding with Ctrl-C. Never source `.env` as shell code or commit it.

## Stop or remove resources

```bash
make down CONFIRM=1
```

This removes only the local cluster. Azure resources and `.env` remain.

```bash
make foundry-down CONFIRM=1
```

This separately deletes only the recorded, project-owned cloud resources and
removes their local gateway configuration and credentials.

See [the development guide](docs/local-development.md) for prerequisites,
command sections, configuration, safety boundaries, troubleshooting, and tests.