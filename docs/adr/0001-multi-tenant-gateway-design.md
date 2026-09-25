---
status: proposed
date: 2026-09-25
---

# Serve many tenants from one shared agentgateway, from one agentgateway per tenant, or from both

## Context and Problem Statement

The AI gateway must serve many tenants. A tenant is one API key and one tokens-per-minute limit. The
gateway is [agentgateway](https://agentgateway.dev/) v1.5.0 on Kubernetes, in front of one Microsoft
Foundry model deployment that every tenant shares, with one Foundry key. In the experiments below,
each tenant also had its own credential for a mock upstream, so that a response served with another
tenant's credential could be detected as a leak.

Which gateway topology should serve the tenants: one shared agentgateway for every tenant, one
complete agentgateway (controller and proxy) per tenant namespace, or a mix of the two?

This ADR is **proposed** and chooses no option. It lays out the options and the evidence for
reviewers. The evidence comes from a proof of concept in this repository that built both designs on
local Kind clusters and measured them with the same commands. The numbers below are from its final
measurement campaign: [results/report.md](../../results/report.md) has every figure with links to its
run record, and [the comparison guide](../tenancy-comparison.md) explains each experiment.

Two words have fixed meanings here. **Separation** is what namespaces and separate gateways give
tenants that share one cluster. **Isolation** would mean a dedicated cluster per tenant. Neither of
the measured designs isolates tenants.

In scope: the gateway topology inside one Kubernetes cluster, how tenants are added and removed, and
how a failure or a mistake in one tenant's configuration reaches other tenants. Out of scope: the
model deployment itself, its quota, tenant self-service administration, and upgrades of agentgateway
or its CRDs.

## Decision Drivers

* **Fault containment.** How many tenants lose service when a proxy crashes, runs out of memory, or
  its controller stops.
* **Cross-tenant credential safety.** Whether a configuration mistake can serve one tenant's traffic
  with another tenant's provider credential.
* **Configuration change safety.** Whether a mistake or change made for one tenant can affect other
  tenants' limits or routes.
* **Resource cost.** Pods, reserved CPU and memory, used memory, and monitoring series as tenants grow.
* **Tenant capacity.** How many tenants one deployment can hold as built.
* **Onboarding and offboarding speed.** Time until a new tenant can send requests, and time until a
  removed tenant's key stops working.
* **Operational surface.** Objects to create per tenant, cluster-scoped objects, and copies of the
  shared model credential.
* **Request latency** added by the gateway.
* **Noisy neighbours.** Whether one tenant's heavy or slow traffic degrades other tenants.

## Considered Options

* **Shared**: one agentgateway (one controller and one proxy) for every tenant.
* **Dedicated**: one complete agentgateway (its own controller and proxy) per tenant namespace.
* **Tiered**: shared by default, and dedicated for tenants that need fault containment.
* **Cluster per tenant**: a separate Kubernetes cluster for each tenant (isolation).

## Decision Outcome

No option is chosen yet. The measurements show a clear trade-off, but choosing needs facts that the
proof of concept cannot supply, listed below.

How the evidence points, driver by driver:

| Driver | Shared | Dedicated | Evidence |
| --- | --- | --- | --- |
| Fault containment | A proxy crash failed all 3 tenants (0.8 to 1.0 s each); a proxy out-of-memory kill failed all 3 (27.6 to 30.0 s each); a controller outage froze every tenant's configuration changes. | The same faults reached only the tenant that owned the proxy or controller (2.4 s and 32.2 s); the other tenants saw nothing, and tenant-02's limit change applied during tenant-01's controller outage. | proxy-crash, proxy-memory, controller-outage |
| Cross-tenant credential safety | A backend pointing at another tenant's Secret leaked (301 requests in one minute); a routing policy that trusts a client header leaked (307). | The same Secret reference failed closed (HTTP 500), because a reference cannot cross namespaces; there is no shared routing policy to get wrong. | wrong-credential (first half), forged-tenant-header |
| Mistakes that leak in both | A duplicated key hash served tenant-01 with tenant-02's credential (628) and locked tenant-02 out; a wrong Secret value leaked (302). | A duplicated key hash let tenant-01's key into tenant-02's gateway (635) and locked tenant-02 out; a wrong Secret value leaked (296). | duplicate-key, wrong-credential (second half) |
| Configuration change safety | Every onboarding rewrites 2 gateway objects that all tenants depend on (the limit policy and the route). An invalid limit condition failed open: the policy stayed Accepted with reason PartiallyValid and an invalid-expression message, and that tenant's limit disappeared while its traffic continued; other tenants kept their limits. | Onboarding changes no gateway object another tenant uses (the mock upstream's credential list is shared in both designs). The invalid condition failed open the same way for that tenant. | bad-tenant-config, onboarding records |
| Resource cost | Pods and reservations flat: 2 gateway pods and 0.2 CPU and 256 MiB reserved at 1, 5, and 10 tenants. Used memory rose from 59 to 67 MiB and gateway monitoring series from 538 to 1,335. | Linear: 2 pods, 0.2 CPU and 256 MiB reserved, and about 50 MiB used per tenant; 20 pods, 2 CPU and 2,560 MiB reserved, about 510 MiB used, and 3,150 series at 10 tenants. | scale sweep, at 1 request per second per tenant |
| Tenant capacity | At most 16 tenants as built, because one limit policy and one route each hold at most 16 entries. | No such 16-entry ceiling; the scripts name tenants tenant-01 to tenant-99, and the most measured was 10. | structural finding |
| Onboarding and offboarding | Usable after a median 2.4 s; key refused by authentication within an observed upper bound of a median 220 ms (largest 296 ms) after deactivation; cleaned after a median 8.2 s. | Usable after a median 9.7 s, its own Foundry connection ready a median 18.3 s after the start; key refused within a median upper bound of 202 ms (largest 303 ms); cleaned after a median 14.3 s. | 9 onboardings and 9 offboardings per design |
| Operational surface | 3 objects per tenant (key ConfigMap, provider Secret, backend); 1 copy of the Foundry key. | 15 entries per tenant in the onboarding inventory; one entry is a Helm release that adds a controller Deployment, Service, ServiceAccount, Role, RoleBinding, two ClusterRoles, two ClusterRoleBindings, and monitors. Cluster-scoped: the Namespace, a GatewayClass, two ClusterRoles, and two ClusterRoleBindings. 1 Foundry key copy per tenant. | onboarding records, tenant-objects |
| Request latency | Median difference 1 ms at p50, p95, and p99. | Median difference 0 to 1 ms. | latency scenario |
| Noisy neighbours | A 2,000-request-per-second flood from one tenant (about 99 percent refused with 429 by its limit) and about 1,500 concurrent 30-second requests from one tenant caused no failed probe for the others, and no probe slower than five times its baseline p95. | Same result. | flood, slow-upstream, at these rates on this hardware |

Neither design separates tenant credentials at the Kubernetes permission level: every agentgateway
controller, as the v1.5.0 chart grants it, can list and read Secrets in every namespace.

The questions that would decide it:

1. **Tenant count.** Will one cluster hold more than 16 tenants? The shared design as built cannot,
   without splitting its limit policy and route or running several shared gateways.
2. **Blast radius.** Is it acceptable for a proxy crash or overload caused by one tenant to interrupt
   every tenant for seconds to tens of seconds? If not for all tenants, is it acceptable for some?
3. **Cost per tenant.** Is about 0.2 CPU and 256 MiB reserved per tenant, plus one controller and
   one proxy each, affordable at the expected tenant count?
4. **Change control.** Who changes tenant configuration, and how are mistakes caught? In the shared
   design every onboarding rewrites gateway objects every tenant depends on; in both designs an invalid
   limit condition fails open, with only a PartiallyValid status to show it.
5. **Credential handling.** Is one copy of the model credential per tenant acceptable, and is
   controller read access to every namespace's Secrets acceptable in either design?

### Consequences

These follow from each option; which apply depends on the choice.

* Choosing **shared**: good, because gateway pods and reservations stay flat and onboarding is fast; bad, because one proxy
  or controller fault reaches every tenant, reference and routing mistakes can leak across tenants,
  and the design as built stops at 16 tenants.
* Choosing **dedicated**: good, because faults and reference mistakes stay with one tenant; bad,
  because cost, cluster-scoped objects, and model credential copies grow with every tenant, and
  onboarding takes about four times longer.
* Choosing **tiered**: good, because each tenant can get the containment it needs; bad, because it
  runs both designs, adds a branch to onboarding, monitoring, and recovery for each tier, and was not
  measured as one system.
* Any choice still needs guards against duplicated key hashes and wrong Secret values, which leaked
  in both designs, and a check that the gateway fully accepted every limit policy.

### Confirmation

When an option is chosen, confirm it the way this proof of concept measured it, in an environment
closer to production:

* Run the separation scenario and the ten failure modes (`make scenario NAME=separation` and
  `make break FAILURE=...`, or their equivalents) against the chosen topology. They must show the
  containment the decision relies on and no leak that the design claims to prevent.
* Repeat each measurement several times to establish variance; most figures above come from a
  single run.
* Add automated guards for the mistakes that leaked in both designs: reject a key hash stored for
  more than one tenant, verify each tenant's provider Secret by hash, and alert when a limit policy is
  not fully accepted.

## Pros and Cons of the Options

### Shared

One agentgateway controller and one proxy in one namespace. Each tenant is a key ConfigMap, a
provider Secret, and a backend; one limit policy and one route hold an entry per tenant. A policy
sets the tenant from the authenticated key before routing, so a client cannot choose another tenant.

* Good, because gateway pods and reserved resources did not grow with tenants: 2 pods and 0.2 CPU and
  256 MiB reserved at 1, 5, and 10 tenants (used memory rose from 59 to 67 MiB).
* Good, because a tenant is usable a median 2.4 s after onboarding starts, and only 3 objects are
  created per tenant.
* Good, because there is one copy of the model credential.
* Good, because a limit change for every tenant writes one enforcement policy, besides the limit
  record each tenant has in both designs (enforced for all 3 tenants after 2.9 s, against 4.2 s for
  three policies in the dedicated design).
* Neutral, because gateway latency and noisy-neighbour results matched the dedicated design.
* Bad, because a proxy crash or out-of-memory kill interrupts every tenant (all 3 tenants failed in
  both tests).
* Bad, because a controller outage freezes configuration changes for every tenant.
* Bad, because a backend can reference any tenant's Secret in the shared namespace, and that mistake
  leaked (301 requests in one minute).
* Bad, because tenant routing depends on one policy; a mistake that trusts a client header leaked
  (307 requests in one minute).
* Bad, because every onboarding rewrites the limit policy and route that all tenants depend on, and
  an invalid limit condition in that shared policy fails open for the affected tenant.
* Bad, because the design as built holds at most 16 tenants.

### Dedicated

A namespace per tenant with its own Helm release (controller), GatewayClass, proxy, policies, route,
key, provider Secret, backend, and Foundry connection.

* Good, because a proxy crash, an out-of-memory kill, or a controller outage reached only the owning
  tenant.
* Good, because a backend can reference only Secrets in its own namespace; the wrong reference failed
  closed with HTTP 500 instead of leaking.
* Good, because onboarding changes no gateway object another tenant depends on.
* Good, because there is no 16-entry ceiling (the most measured was 10 tenants).
* Neutral, because gateway latency and noisy-neighbour results matched the shared design.
* Neutral, because key revocation was as fast as in the shared design (about 0.2 s).
* Bad, because cost grows with each tenant: about 0.2 CPU and 256 MiB reserved and about 50 MiB used
  per tenant, and more than twice the monitoring series at 10 tenants (3,150 against 1,335).
* Bad, because onboarding takes a median 9.7 s, and 18.3 s until the tenant's own Foundry connection
  is ready, against 2.4 s shared.
* Bad, because each tenant adds its own controller, cluster-scoped objects (the Namespace, a
  GatewayClass, two ClusterRoles, and two ClusterRoleBindings), and another copy of the model
  credential.
* Bad, because the separation is incomplete: each controller can still read every namespace's
  Secrets, and a duplicated key hash still let one tenant's key into another tenant's gateway.

### Tiered

Shared gateways for most tenants, and dedicated gateways for tenants whose contract or risk needs
fault containment.

* Good, because each tenant can get the containment it needs, and cost grows only with the tenants
  that need their own gateway.
* Good, because it can also work around the 16-tenant ceiling by running several shared gateways.
* Neutral, because each tier's behaviour is expected to match the measured design it uses.
* Bad, because the combination was not measured; running both designs side by side may add effects
  that neither design shows alone.
* Bad, because onboarding, monitoring, and recovery need a branch for each tier (the proof of concept
  already drives both designs from the same commands), and a rule for moving a tenant between tiers.

### Cluster per tenant

A separate Kubernetes cluster, with its own gateway, for each tenant.

* Good, because it would also separate the Kubernetes control plane, node resources, and controller
  permissions, which neither measured design does.
* Bad, because it was not measured here, so its cost and onboarding time are unknown; each tenant
  would also need its own cluster control plane and nodes.
* Bad, because it is outside the scope of the proof of concept, so this ADR can offer no evidence for
  or against it.

## More Information

**Evidence.** [results/report.md](../../results/report.md), generated by `make results` at commit
`a5dbab9` from 79 run records (78 usable) that were measured on commit `6587122`; the two commits
differ only in the report generator and documents, which are outside the input fingerprint.
[The comparison guide](../tenancy-comparison.md), the
[implementation plan](../plans/tenancy-comparison-execplan.md) (Outcomes & Retrospective and
Surprises & Discoveries), and [the review findings](../../FINDINGS.md) complete the evidence. The
report links every run to its Grafana time range (building the link for onboarding, offboarding, and
Foundry records, which have none of their own); the links work only while that cluster and its
Prometheus data exist.

**Limits of the evidence.** Read every number above with these in mind:

* Both designs ran on one laptop, each on a single Kind node sharing Docker Desktop's CPU and memory.
  Absolute numbers do not transfer to production hardware; compare the designs with each other.
* Most figures come from one run each; there is no measure of variance.
* Other software on the host competed for the CPUs. Host load averaged between about 4 and 16 on 10 CPUs during failure runs. Every run passed
  its delivery checks, but host load may have biased timings; the report shows it beside every timing.
* The upstream was a mock for every load test; Foundry was used only for smoke checks.
* Every proxy had one replica, and token limits are local to each proxy.
* Probe timing precision is 200 ms, and memory figures are the maximum of 5-second samples.
* Shared provider quota exhaustion was not tested: both designs sit in front of one deployment
  limited to 10,000 tokens per minute, and local limits in separate proxies cannot cap their total.

**Before choosing,** reviewers may want to repeat the campaign several times, on dedicated hardware
without competing load, with more than one proxy replica, and with the expected tenant count.

**Revisit this decision** when the expected tenant count passes 16, when a tenant contract requires
fault containment, when agentgateway adds per-namespace controller permissions or cross-proxy limits,
or when the model deployment's quota becomes the constraint.
