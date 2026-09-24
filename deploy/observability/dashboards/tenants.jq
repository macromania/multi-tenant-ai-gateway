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
     query: {query: "label_values(mock_requests_total{owner!=\"none\"}, owner)", refId: "tenant"},
     includeAll: true, multi: true, allValue: ".*", current: {text: "All", value: "$__all"}}
  ]},
  panels: [
    row("Tenants"; 0),
    panel("Mock upstream requests per second by key owner and status"; "reqps";
      [["sum by (owner, code) (rate(mock_requests_total{owner=~\"$tenant|none\"}[30s]))", "{{owner}} {{code}}"]]; 0; 1; 12),
    panel("Mock upstream requests in flight"; "short";
      [["sum(mock_in_flight)", "in flight"]]; 12; 1; 12),
    row("Gateway pods (controllers and proxies)"; 9),
    panel("CPU by pod"; "cores";
      [["sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{" + gw + "}[2m]))", "{{namespace}}/{{pod}}"]]; 0; 10; 12),
    panel("CPU throttling by pod"; "percentunit";
      [["sum by (namespace, pod) (rate(container_cpu_cfs_throttled_periods_total{" + gw + "}[2m])) / sum by (namespace, pod) (rate(container_cpu_cfs_periods_total{" + gw + "}[2m]))", "{{namespace}}/{{pod}}"]]; 12; 10; 12),
    panel("Working-set memory by pod"; "bytes";
      [["sum by (namespace, pod) (container_memory_working_set_bytes{" + gw + "})", "{{namespace}}/{{pod}}"]]; 0; 18; 12),
    panel("Gateway pods, restarts, and OOM kills"; "short";
      [["count(kube_pod_status_phase{namespace=~\"agentgateway-system|tenant-[0-9]+\", phase=\"Running\"} == 1)", "running pods"],
       ["sum(increase(kube_pod_container_status_restarts_total{namespace=~\"agentgateway-system|tenant-[0-9]+\"}[5m]))", "restarts (5m)"],
       ["sum(kube_pod_container_status_last_terminated_reason{namespace=~\"agentgateway-system|tenant-[0-9]+\", reason=\"OOMKilled\"})", "last terminated by OOM"]]; 12; 18; 12),
    row("Measurement apparatus"; 26),
    panel("Mock upstream CPU and throttling"; "short";
      [["sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=\"mock-upstream\", container=\"mock\"}[2m]))", "{{pod}} cores"],
       ["sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace=\"mock-upstream\", container=\"mock\"}[2m])) / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace=\"mock-upstream\", container=\"mock\"}[2m]))", "{{pod}} throttled"]]; 0; 27; 12),
    panel("Prometheus head series"; "short";
      [["prometheus_tsdb_head_series", "head series"]]; 12; 27; 12)
  ]
}
