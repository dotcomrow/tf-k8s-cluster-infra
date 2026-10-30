# Platform log retention policy

Operational logs must retain no more than seven days unless a documented subsystem requirement explicitly overrides the platform default.

## Controls

| Data | Control | Limit |
| --- | --- | --- |
| Centralized OpenObserve logs, metrics, and traces | `ZO_COMPACT_DATA_RETENTION_DAYS` | 7 days |
| Node systemd journal | `MaxRetentionSec` plus disk ceilings | 3 days |
| Node rsyslog files | daily logrotate, `rotate 7`, `maxage 7` | 7 days; 50 MiB per file before rotation |
| Node nginx files | daily logrotate, `rotate 7`, `maxage 7` | 7 days; 100 MiB per file before rotation |
| Node cloud-init files | daily logrotate, `rotate 7`, `maxage 7` | 7 days; 25 MiB per file before rotation |
| Kubernetes container logs | kubelet rotation | 10 MiB per file, 3 files per container |

Kubernetes does not provide a kubelet maximum-age setting for CRI container log files. The local `10 MiB × 3` policy is therefore a bounded diagnostic cache, not the authoritative history store. OpenObserve supplies the time-bounded seven-day history. Do not increase the node-local cap to approximate seven days: log rates vary by orders of magnitude, so a larger byte limit would consume node disk without enforcing age.

On the 2026-10-29 production audit, 454 container logs used approximately 2.24 GB total and averaged 4.9 MB each. The configured ceiling is roughly 30 MiB per container under normal kubelet rotation, or about 13.6 GiB if every observed container simultaneously reached its ceiling. This is proportionate for the five-node cluster and leaves centralized retention responsible for history.

Kafka record retention is managed separately in `k8s-kafka`. Kafka transport records are not a replacement for application databases or OpenObserve logs.
