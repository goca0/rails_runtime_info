# Deferred work

## Cgroup resource limits and usage

Deferred at the owner's request for v0.7.0. The existing raw
`process.linux.cgroup` membership text remains unchanged; no cgroup resource
collector is implemented.

Potential future coverage: memory usage/limits/OOM events, CPU quotas and
throttling, and task counts/limits. Correctly resolve both cgroup v1 and v2
membership against the process's mount layout, including mount roots,
cgroup namespaces, inherited limits, unavailable files and old kernels.
Do not assume Docker paths or equate a leaf limit with the effective limit.
Keep file reads bounded, independently guarded, passive and selection-aware;
no service calls, background sampling, writes or configuration changes.

Snapshot deltas/two-snapshot sampling are intentionally out of scope, not
part of the pending cgroup work.
