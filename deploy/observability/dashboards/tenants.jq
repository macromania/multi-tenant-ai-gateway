# Renders the mtag-tenants Grafana dashboard. Run with: jq -n --arg cluster <shared|dedicated> -f tenants.jq
# cAdvisor updates container CPU every 10 to 20 seconds, so rates over container metrics use 2-minute
# windows even though the kubelet is scraped every 5 seconds.
# Gateway pods are the controllers and proxies in agentgateway-system and the tenant namespaces.

def gw: "namespace=~\"agentgateway-system|tenant-[0-9]+\", container!=\"\", container!=\"POD\"";
def ds: {type: "prometheus", uid: "prometheus"};
def panel($title; $unit; $targets; $x; $y; $w):
  {type: "timeseries", title: $title, datasource: ds,
   gridPos: {x: $x, y: $y, w: $w, h: 8},
   fieldConfig: {defaults: {unit: $unit, custom: {lineWidth: 1, fillOpacity: 5}}, overrides: []},
   options: {legend: {displayMode: "table", placement: "bottom", calcs: ["mean", "max"]},
             tooltip: {mode: "multi", sort: "desc"}},
   targets: [$targets | to_entries[] | {refId: ([65 + .key] | implode), datasource: ds,
                                        expr: .value[0], legendFormat: .value[1]}]};
# An instant table: k6 publishes a verdict series only when that verdict first occurs, so a single
# leak has no earlier zero sample for rate() or increase(); totals over the time range show it.
def table($title; $expr; $x; $y; $w):
  {type: "table", title: $title, datasource: ds, gridPos: {x: $x, y: $y, w: $w, h: 8},
   targets: [{refId: "A", datasource: ds, expr: $expr, instant: true, format: "table"}],
   transformations: [{id: "organize", options: {excludeByName: {Time: true}}}]};
def row($title; $y): {type: "row", title: $title, collapsed: false, gridPos: {x: 0, y: $y, w: 24, h: 1}, panels: []};

{
  uid: "mtag-tenants",
  title: ("Tenancy comparison (" + $cluster + ")"),
  tags: ["mtag", $cluster],
  timezone: "utc",
  schemaVersion: 39,
  refresh: "10s",
  time: {from: "now-30m", to: "now"},
  templating: {list: [
    {name: "tenant", label: "Tenant", type: "query", datasource: ds, refresh: 2,
     query: {query: "label_values(agentgateway_requests_total{tenant!=\"unknown\"}, tenant)", refId: "tenant"},
     includeAll: true, multi: true, allValue: ".*", current: {text: "All", value: "$__all"}}
  ]},
  panels: [
    row("Tenants: what the gateway saw"; 0),
    panel("Gateway requests per second by tenant and status"; "reqps";
      [["sum by (tenant, status) (rate(agentgateway_requests_total{tenant=~\"$tenant\"}[30s]))", "{{tenant}} {{status}}"]]; 0; 1; 12),
    panel("Rate-limited (429) responses per second by tenant"; "reqps";
      [["sum by (tenant) (rate(agentgateway_requests_total{tenant=~\"$tenant\", status=\"429\"}[30s]))", "{{tenant}}"]]; 12; 1; 12),
    panel("Tokens per minute by tenant"; "short";
      [["sum by (tenant, gen_ai_token_type) (rate(agentgateway_gen_ai_client_token_usage_sum{tenant=~\"$tenant\"}[1m])) * 60", "{{tenant}} {{gen_ai_token_type}}"]]; 0; 9; 12),
    panel("Gateway request latency by tenant (p50, p95, p99)"; "s";
      [["histogram_quantile(0.5, sum by (le, tenant) (rate(agentgateway_request_duration_seconds_bucket{tenant=~\"$tenant\"}[1m])))", "{{tenant}} p50"],
       ["histogram_quantile(0.95, sum by (le, tenant) (rate(agentgateway_request_duration_seconds_bucket{tenant=~\"$tenant\"}[1m])))", "{{tenant}} p95"],
       ["histogram_quantile(0.99, sum by (le, tenant) (rate(agentgateway_request_duration_seconds_bucket{tenant=~\"$tenant\"}[1m])))", "{{tenant}} p99"]]; 12; 9; 12),
    row("Tenants: what the clients saw (k6)"; 17),
    panel("Client latency by tenant (p50, p95, p99)"; "s";
      [["histogram_quantile(0.5, sum by (tenant) (rate(k6_http_req_duration_seconds{tenant=~\"$tenant\"}[30s])))", "{{tenant}} p50"],
       ["histogram_quantile(0.95, sum by (tenant) (rate(k6_http_req_duration_seconds{tenant=~\"$tenant\"}[30s])))", "{{tenant}} p95"],
       ["histogram_quantile(0.99, sum by (tenant) (rate(k6_http_req_duration_seconds{tenant=~\"$tenant\"}[30s])))", "{{tenant}} p99"]]; 0; 18; 12),
    panel("Client verdicts per second by tenant"; "reqps";
      [["sum by (tenant, verdict) (rate(k6_mtag_verdicts_total{tenant=~\"$tenant\"}[30s]))", "{{tenant}} {{verdict}}"]]; 12; 18; 12),
    table("Leaks and unverifiable responses in the selected time range (totals per run and stream)";
      "sum by (tenant, run_id, stream, verdict) (max_over_time(k6_mtag_verdicts_total{tenant=~\"$tenant\", verdict=~\"leak|unverifiable\"}[$__range]))"; 0; 26; 12),
    panel("Mock upstream requests per second by key owner and status"; "reqps";
      [["sum by (owner, code) (rate(mock_requests_total{owner=~\"$tenant|none\"}[30s]))", "{{owner}} {{code}}"],
       ["sum(mock_in_flight)", "in flight"]]; 12; 26; 12),
    row("Gateway pods (controllers and proxies)"; 34),
    panel("CPU by pod"; "cores";
      [["sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{" + gw + "}[2m]))", "{{namespace}}/{{pod}}"]]; 0; 35; 12),
    panel("CPU throttling by pod"; "percentunit";
      [["sum by (namespace, pod) (rate(container_cpu_cfs_throttled_periods_total{" + gw + "}[2m])) / sum by (namespace, pod) (rate(container_cpu_cfs_periods_total{" + gw + "}[2m]))", "{{namespace}}/{{pod}}"]]; 12; 35; 12),
    panel("Working-set memory by pod"; "bytes";
      [["sum by (namespace, pod) (container_memory_working_set_bytes{" + gw + "})", "{{namespace}}/{{pod}}"]]; 0; 43; 12),
    panel("Gateway pods, restarts, and OOM kills"; "short";
      [["count(kube_pod_status_phase{namespace=~\"agentgateway-system|tenant-[0-9]+\", phase=\"Running\"} == 1)", "running pods"],
       ["sum(increase(kube_pod_container_status_restarts_total{namespace=~\"agentgateway-system|tenant-[0-9]+\"}[5m]))", "restarts (5m)"],
       ["sum(kube_pod_container_status_last_terminated_reason{namespace=~\"agentgateway-system|tenant-[0-9]+\", reason=\"OOMKilled\"})", "last terminated by OOM"]]; 12; 43; 12),
    row("Measurement apparatus"; 51),
    panel("Mock upstream CPU and throttling"; "short";
      [["sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=\"mock-upstream\", container=\"mock\"}[2m]))", "{{pod}} cores"],
       ["sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace=\"mock-upstream\", container=\"mock\"}[2m])) / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace=\"mock-upstream\", container=\"mock\"}[2m]))", "{{pod}} throttled"]]; 0; 52; 12),
    panel("Prometheus head series"; "short";
      [["prometheus_tsdb_head_series", "head series"]]; 12; 52; 12)
  ]
}
