# Platform Certificate Rotation Rollout Plan

Status date: 2026-10-10

This document separates certificate issuance, certificate renewal, consumer
reload, deployment rollout, and trust-anchor rotation. A certificate is not
considered operationally automated until all five concerns that apply to it
have an owner and a verified path.

No repository push or Argo sync is authorized by this plan. The operator must
choose when each local commit is pushed and when each application is synced.

## Current repository state

| Repository | Local commit | Remote state | Purpose |
| --- | --- | --- | --- |
| `tf-k8s-cluster-infra` | `b50bf95` plus preceding `fe2b39e` | Already pushed to `prod` before the hold instruction | Future-build certificate renewal configuration for VPA, Vault, CloudNativePG, and Linkerd |
| `k8s-teleport` | `6ad749a` | Local only; `prod` is one commit ahead of `origin/prod` | Replace one-shot etcd PKI generation with cert-manager resources and consumer update behavior |

Both repositories have clean working trees at the time of this writing.

## Desired operating standard

1. Leaf certificates should normally have a 90-day lifetime and begin renewal
   at 50% remaining lifetime, unless the owning controller has a documented
   and tested built-in policy.
2. Routine CA certificate renewal should keep the CA private key stable. A CA
   key rotation is a different operation and requires overlapping trust,
   staged consumer updates, and a rollback plan.
3. Workloads that hot-reload certificates should do so without a rollout.
   Workloads that do not hot-reload must be connected to a controlled rolling
   restart mechanism such as Stakater Reloader.
4. Stateful single-replica workloads must not be restarted automatically until
   the expected interruption is accepted or redundancy is added.
5. Every rollout must verify the certificate actually served by the endpoint,
   not only the contents of the Kubernetes Secret.

## Certificate inventory and required behavior

### Already configured and live

| Certificate or group | Renewal owner | Consumer update behavior | Deployment needed now |
| --- | --- | --- | --- |
| CloudNativePG operator webhook | CloudNativePG 1.22.5; 90-day duration and 30-day threshold | Operator certificate watcher reloads the serving certificate | None; renewed and verified live through 2027-01-08 |
| OpenObserve PostgreSQL CA, server, and replication certificates | CloudNativePG 1.22.5; 90-day duration and 30-day threshold | CloudNativePG and PostgreSQL reload managed certificate files | None; renewed and live server certificate verified through 2027-01-08 |
| VPA admission webhook | cert-manager `Certificate/vpa-webhook-tls`; 90 days; renew at 50% | VPA runs with `--reload-cert` and reloads projected Secret updates | None; next renewal time is 2026-10-14 11:33:55 EDT |
| Vault agent injector webhook | cert-manager `Certificate/vault-agent-injector-tls`; 90 days; renew at 50% | Stakater Reloader annotation rolls `Deployment/vault-agent-injector` | No manual rollout; observe the scheduled 2026-10-14 11:45:50 EDT renewal and automatic rollout |
| Rancher ingress certificate | cert-manager `Certificate/tls-rancher-ingress` | Ingress controller dynamically reloads its referenced TLS Secret | None; retain cert-manager readiness and ingress smoke checks |

### Controller-managed certificates to monitor, not replace blindly

The live cluster also contains TLS Secrets managed by Rancher/dynamiclistener,
RKE2, Cluster API, Kyverno, Longhorn, and CloudNativePG. Their owning
controllers should remain the source of truth. Replacing those Secrets with
independent cert-manager objects can break controller reconciliation or CA
bundle injection.

| Group | Current owner | Required verification |
| --- | --- | --- |
| Rancher internal and webhook TLS | Rancher/dynamiclistener | Confirm each controller reports its renewal policy, then observe a renewal and verify the served certificate and webhook CA bundle |
| `rke2-serving` | RKE2 | Confirm RKE2 automatic rotation policy and validate API serving certificates after the next scheduled rotation |
| CAPI webhook | Cluster API controller | Confirm controller certificate reconciliation and webhook CA injection after renewal |
| Kyverno webhook CA and leaf pairs | Kyverno (`cert.kyverno.io/managed-by=kyverno`) | Confirm Kyverno certificate manager renews both pairs and updates webhook bundles |
| Longhorn webhook CA and leaf | Longhorn | Confirm Longhorn manager certificate rotation and webhook availability after renewal |

These checks are observational unless a controller is proven not to renew or
reload its own certificates.

### Linkerd changes in the platform-build repository

The future-build manifest declares cert-manager resources for:

- Linkerd identity issuer certificate;
- policy-validator webhook certificate;
- proxy-injector webhook certificate;
- service-profile-validator webhook certificate;
- Linkerd Viz tap certificate; and
- Linkerd Viz tap-injector webhook certificate.

The identity trust anchor has a long lifetime and a stable private key across
routine certificate renewal. The identity issuer and webhook leaf certificates
use 90-day lifetimes with renewal at 50%. Reloader annotations roll the Linkerd
control-plane or Viz deployment when its Secret changes.

#### Existing-cluster Linkerd rollout

Do not apply this as an unobserved bulk change. Use the following sequence:

1. Record the current Linkerd trust-anchor fingerprint, identity issuer
   fingerprint, webhook certificate fingerprints, control-plane versions, and
   `linkerd check` result.
2. Back up the current Linkerd TLS Secrets and webhook CA bundles to an
   access-controlled operational location.
3. Apply only the Linkerd cert-manager Issuers and Certificates.
4. Wait for every Certificate to report `Ready=True`; validate SANs, EKUs,
   issuer chain, and expiry before changing a consumer.
5. Upgrade the Linkerd control plane with the external identity issuer flags.
   Roll one control-plane deployment at a time: identity, destination/policy,
   then proxy injector.
6. After each rollout, require ready replicas, healthy webhook endpoints, and a
   successful `linkerd check`.
7. Roll the service-profile validator only after the core control plane is
   healthy.
8. Apply the Linkerd Viz certificates, then roll tap and tap-injector one at a
   time. Require `linkerd viz check` after both are healthy.
9. Verify a newly injected workload obtains a valid identity and can establish
   mTLS to an existing meshed workload. Also verify an existing proxy renews its
   workload identity without a pod restart.
10. Observe one cert-manager leaf renewal and its Reloader-triggered rollout
    before declaring the mechanism proven.

Routine trust-anchor certificate renewal retains the same CA key. A trust-anchor
key rotation is intentionally not automatic: it requires a dual-trust bundle,
rolling all meshed proxies, switching the issuer, and removing the old anchor
only after no proxy depends on it.

### Teleport etcd changes in `k8s-teleport`

Local commit `6ad749a` replaces the one-shot OpenSSL bootstrap Job and combined
`etcd-tls` Secret with:

- a self-signed bootstrap Issuer;
- a cert-manager-managed etcd CA Certificate;
- a CA Issuer;
- a 90-day etcd server/peer Certificate;
- a 90-day Teleport client Certificate;
- projected Secret volumes; and
- rolling consumer update configuration.

Leaf certificates renew at 50% remaining lifetime. The CA certificate renews
with the same private key so routine CA certificate renewal does not invalidate
still-valid leaves. A CA key change remains a separate overlapping-trust
migration.

#### Existing-cluster Teleport rollout

This is the highest-risk certificate change because etcd currently has one
replica. Treat it as a maintenance-window migration.

1. Confirm the Argo application target revision and disable automated sync or
   use a controlled manual sync window.
2. Take and verify an etcd snapshot. Record the current member list, database
   size, endpoint health, alarm list, and current TLS certificate fingerprints.
3. Capture Teleport readiness, `tctl status`, cluster name, auth/proxy health,
   and a working login/API path as the pre-change baseline.
4. Push `6ad749a` only after the maintenance window is approved.
5. Sync only the new Issuer and Certificate resources first. Do not change the
   StatefulSets yet.
6. Wait for `etcd-ca`, `etcd-server-tls`, and `etcd-client-tls` to become
   `Ready=True`. Validate the server SANs, server/client EKUs, chain, and key
   permissions.
7. Change the etcd StatefulSet to the new projected server Secret. Because it
   is a single-member etcd cluster, its first restart creates a brief Teleport
   control-plane outage. Wait for etcd endpoint and member health before
   proceeding.
8. Change the two-replica Teleport StatefulSet to the new client Secret. Roll
   one pod at a time and require the replacement pod to become ready before the
   second is updated.
9. Verify `tctl status`, auth/proxy readiness, Kubernetes access, application
   access, Argo access through Teleport, and absence of TLS or quorum errors.
10. Keep the old `etcd-tls` Secret for a defined rollback interval. Remove it
    only in a later change after the new chain has survived a normal renewal.
11. Observe the first 45-day leaf renewal. Confirm the new certificate is
    served by etcd and used by Teleport. If a consumer rollout is required,
    verify it remains ordered and healthy.

Before enabling unattended etcd restarts, decide between these operating
models:

- expand etcd to three members so a rolling restart remains available; or
- prove that the deployed etcd version reloads the projected certificate and
  CA files safely, then remove automatic restart of the single-member etcd
  StatefulSet while retaining the Teleport client rollout.

The first model offers the clearest availability guarantee. Until one model is
chosen and tested, keep the Teleport commit local.

## Recommended rollout order

1. Observe and verify the VPA and Vault renewals on October 14. This validates
   cert-manager issuance, hot reload, and Reloader behavior with low risk.
2. Perform a supported CloudNativePG minor-version upgrade as a separate
   database-operator maintenance item. The current 1.22.5 patch fixes the
   immediate renewal behavior but the 1.22 release line is end-of-life.
3. Stage the Linkerd certificate migration in a controlled maintenance window.
   Complete core control-plane verification before Linkerd Viz.
4. Decide the etcd availability model and rehearse snapshot restoration.
5. Push and manually sync the Teleport commit in waves during an approved
   maintenance window.
6. Observe at least one automatic renewal for each management pattern before
   calling the platform-wide objective complete.

## Required proof after every renewal or rollout

- Certificate resource is `Ready=True` and has a future `renewalTime` where
  cert-manager owns it.
- Secret resource version and public certificate fingerprint changed.
- Served endpoint presents the new certificate and complete expected chain.
- Webhook `caBundle` matches the active CA where applicable.
- Deployment or StatefulSet rollout completed only when required.
- All pods and endpoints are ready with no certificate, trust, or leader/quorum
  errors.
- Product-level smoke test passes: admission request, database connection,
  Linkerd mTLS, Rancher/API access, or Teleport login as appropriate.
- Argo reports the intended revision as Synced/Healthy only after functional
  checks pass; Argo health alone is not completion proof.

## Rollback principles

- Preserve the old CA and leaf Secrets until the new chain is functionally
  verified and the rollback interval has elapsed.
- Roll back consumers before removing newly issued certificates.
- Never delete an expiring Secret to force renewal on a stateful service.
- For CA key rotation, distribute overlapping trust first, then change issuers,
  then rotate consumers, and remove old trust last.
- Restore etcd from the verified snapshot only if ordinary manifest rollback
  and pod recovery cannot restore service.

