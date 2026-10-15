# Platform Certificate Auto-Rotation Plan

Status date: 2026-10-15

This document is the implementation and rollout plan for ensuring that every
platform certificate has an automatic renewal owner and that every consumer
either hot-reloads the renewed certificate or is rolled in a safe, automated
order.

This plan does not itself authorize a repository push, Argo sync, cluster
mutation, or workload restart. Completed sections record separately approved
work. Each remaining implementation stage must be reviewed and approved before
it is pushed or applied.

## Definition of done

A certificate is not considered auto-rotating merely because a controller can
write a new Secret. Each certificate family must have all of the following:

1. A single, documented issuer and renewal owner.
2. A renewal policy appropriate to the component. Platform leaf certificates
   should normally be valid for 90 days and renew at approximately 50% of
   their lifetime unless their vendor has a supported built-in policy.
3. A stable trust model. Routine renewal should retain the CA private key.
   Trust-anchor key rotation is a separate, staged operation with overlapping
   trust; it must not run unattended.
4. A verified consumer-update mechanism: native hot reload, dynamic reload, or
   an ordered rollout connected to Secret changes.
5. Monitoring for the stored certificate, the certificate actually served,
   the consumer's trust bundle, and the health of the owning controller.
6. A functional test and a rollback path.

## Current state

### Completed and proven live

| Certificate family | Renewal owner | Consumer update path | Current result |
| --- | --- | --- | --- |
| Teleport etcd CA, server/peer, and client certificates | cert-manager | etcd reloads certificate files on new connections; Teleport has an ordered two-replica rollout | Migration completed, verified, and returned to automatic Argo management. The temporary dual-trust migration logic was removed from `k8s-teleport`. |
| CloudNativePG operator webhook | CloudNativePG | Operator certificate watcher | Renewed and verified through 2027-01-08. |
| OpenObserve PostgreSQL CA, server, and replication certificates | CloudNativePG | CloudNativePG/PostgreSQL managed reload | Renewed and verified through 2027-01-08. |
| VPA webhook | cert-manager | VPA `--reload-cert` | `Ready=True`; current certificate expires 2027-01-12 and has a 2026-11-28 renewal time. |
| Vault agent injector | cert-manager | Stakater Reloader rolls the injector | `Ready=True`; current certificate expires 2027-01-12 and has a 2026-11-28 renewal time. |
| Rancher public ingress | cert-manager | ingress controller dynamic Secret reload | `Ready=True`; current certificate expires 2027-05-02. |
| OpenObserve Dex ingress | cert-manager | ingress controller dynamic Secret reload | Revision 2 is `Ready=True`, has a standards-compliant Subject/Issuer DN, and is stored and served internally with the same fingerprint. Current certificate expires 2027-01-13 and renews on 2026-11-29. |

Completed work is not a substitute for observing the next natural renewal.
The first normal renewal of each management pattern must remain part of the
acceptance evidence.

### Remaining work at a glance

| Priority | Certificate family | Main gap | Proposed owner/update mechanism |
| --- | --- | --- | --- |
| Urgent observation | Rancher imperative API | Vendor leaf expires 2026-10-29; it is not a cert-manager object | Keep Rancher as owner, monitor the built-in rotator and served/bundled certificate, and define a supported repair gate. |
| High | Linkerd identity and webhooks | Live certificates remain static through 2027-05-02; corrected future-build resources are prepared locally but not applied | cert-manager with stable CAs, CA injection, corrected rollouts, and a separate overlapping-trust identity migration. |
| High | ingress-nginx admission webhooks | Two controllers claim the same class; both use long-lived one-shot certificates | Consolidate to one controller, then use cert-manager, CA injection, and Reloader. |
| High | NiFi server and client TLS | Long-lived self-signed PKCS12 material has no expiry-driven renewal | cert-manager/Vault PKI leaves, automated PKCS12 conversion, NiFi native reload, and dual-trust migration. |
| High | RKE2 node certificates | Renewal occurs only when RKE2 starts; CA rotation is manual | Host expiry inventory, alerts, and a controlled node-by-node restart/rotation procedure. |
| Medium | Gravitee Kubernetes Operator webhook | Operator is the current certificate writer; external-certificate support is not yet proven | Preserve one writer, test the current chart's supported integration, then add cert-manager only if ownership can be transferred. |
| Medium | Teleport iDRAC bridge | Pod-start OpenSSL certificate is valid for ten years | cert-manager 90-day leaf plus safe pod rollout. |
| Medium | Other vendor-managed webhooks | Renewal/reload behavior has not been observed end to end | Preserve vendor ownership; monitor and test natural renewal before changing implementation. |
| External | pfSense/HAProxy wildcard | Public certificate is outside Kubernetes and not represented in Git | Verify ACME DNS-01 and HAProxy reload, monitor publicly, and document non-secret configuration. |
| Platform-wide | Expiry monitoring | No complete inventory or platform certificate alerting exists | Least-privilege audit job, cert-manager metrics, served-certificate probes, and OpenObserve alerts. |

## Plan 1: Rancher imperative API certificate

### Evidence and risk

`Secret/cattle-system/imperative-api-sni-provider-cert-ca` currently contains a
leaf certificate valid from 2026-07-31 through 2026-10-29. The Secret predates
that leaf, which demonstrates that Rancher has rotated it in place before. All
Rancher pods logged `starting imperative api cert rotator` on 2026-10-14. The
APIService `v1.ext.cattle.io` is currently available, and its `caBundle`
matches the stored and served certificate chain.

This certificate is Rancher-owned. Creating a competing cert-manager
`Certificate` for the same Secret would create two writers and is not the safe
remediation. The near-term risk is a failure of Rancher's internal rotator that
is not detected before 2026-10-29.

### Implementation plan

1. Add this exact Secret, the imperative API endpoint on port 6666, and
   `APIService/v1.ext.cattle.io` to certificate monitoring.
2. Record the Secret fingerprint, served fingerprint, expiration, `caBundle`
   fingerprint, APIService availability, and rotator log health daily until a
   renewal occurs.
3. Alert at 21, 14, and 7 days remaining and immediately on a stored/served or
   CA-bundle mismatch.
4. If the leaf has not renewed by 2026-10-22, open a maintenance gate. First
   collect Rancher rotator logs and version-specific vendor guidance. The
   preferred recovery is a supported Rancher repair or a one-pod-at-a-time
   Rancher restart that reinitializes the rotator.
5. Do not delete or recreate the Secret unless the precise Rancher recovery
   procedure for this version requires it and a working old Secret has been
   backed up.

### Acceptance and rollback

- The new leaf fingerprint and expiry are visible in the Secret and from the
  live port.
- The APIService bundle matches, `Available=True`, and Rancher UI/API access
  succeeds after each pod action.
- The old Secret is retained only while its chain remains valid and only for a
  short rollback window.

## Plan 2: Linkerd identity and webhook certificates

### Evidence and risks

The live cluster is running Linkerd edge-26.5.1 and currently passes both
`linkerd check` and `linkerd viz check`. Its identity issuer, three core
webhook certificates, and two Viz certificates are CLI-created Secrets rather
than cert-manager resources. They expire on 2027-05-02.

Identity trust-anchor key rotation also cannot be handled as an ordinary leaf
renewal. Every meshed proxy trusts that anchor.

Teleport's namespace has Linkerd injection disabled and the two Teleport server
pods are not meshed. A Linkerd identity transition should therefore not remove
Teleport access to Kubernetes. Keep the `sudo -E kubectl` console path on
`srvr-node` available throughout the migration anyway.

### Prepared future-build implementation

The future-build template now implements the supported steady state but has
not been applied to the existing Linkerd installation:

1. A stable identity trust anchor uses `rotationPolicy: Never`; its 90-day
   identity issuer uses `rotationPolicy: Always` and renews at 50 percent.
2. Core Linkerd webhooks use a dedicated stable CA and 90-day ECDSA leaves.
   Linkerd Viz uses a second dedicated stable CA and 90-day ECDSA leaves.
   Neither webhook family shares the workload-identity trust root.
3. cert-manager CA injection owns all three core webhook bundles, the tap
   APIService bundle, and the tap-injector webhook bundle.
4. Linkerd's native certificate watchers update the identity issuer, proxy
   injector, service-profile validator, tap, and tap-injector without a pod
   restart. The policy validator's `kubert` TLS server rereads its key and
   certificate for every new connection. Reloader is intentionally not attached
   to these Secrets; an explicit rollout is only a recovery action if the served
   certificate does not change within the verification timeout.
5. Initial Linkerd installation still supplies the correct stable CA files so
   there is no bootstrap interval with an empty or incorrect bundle.
6. The rebuild CLI is pinned to the currently deployed and audited
   `edge-26.5.1` release instead of the older `edge-25.8.1` source value.

### Rollout progress: 2026-10-15

- Phase 0 completed without changing live Linkerd resources. A mode-0600
  rollback archive was created outside the repository, all five webhook/tap
  stored, served, and bundled fingerprints matched, admission dry-run injected
  a proxy, the tap APIService was Available, and the matching `edge-26.5.1`
  CLI reported a passing Linkerd check.
- Phase 1A created `Issuer/linkerd-webhook-selfsigned`,
  `Certificate/linkerd-webhook-ca`, and `Issuer/linkerd-webhook-ca`. All three
  are Ready. The stable ECDSA CA expires on 2036-10-12, renews on 2035-10-13,
  and has SHA-256 fingerprint
  `68:EF:C2:EC:E4:6D:36:F9:55:07:4C:A8:80:33:F9:22:81:DC:43:1A:91:29:33:87:68:15:22:0D:92:D5:3C:37`.
- Phase 1A did not change an existing Secret, webhook `caBundle`, CA-injection
  annotation, or Linkerd pod identity/restart count. Admission and the complete
  Linkerd check remained healthy.
- The next approval gate is migration of the policy-validator leaf using an
  in-cluster rollback Secret and an old-plus-new temporary CA bundle.

### Existing-cluster migration

Do not apply the future-build block wholesale to the current cluster. Perform
webhook TLS and identity trust migration as separately approved changes.

#### Phase 0: preflight and rollback capture

1. Confirm all Linkerd control-plane and Viz deployments are ready and run
   `linkerd check` plus `linkerd viz check`.
2. Record the Secret, served-certificate, webhook, and APIService bundle
   fingerprints for every Linkerd certificate consumer.
3. Export the existing Linkerd Secrets, webhook configurations, tap APIService,
   trust-root ConfigMap, and Linkerd-generated install manifests to an encrypted
   or mode-0600 backup on `srvr-node`. Do not commit private keys.
4. Inventory all meshed workloads. Record their current proxy versions and
   identity trust anchors so every rollout can be accounted for.
5. Stop if any APIService is unavailable, any admission webhook is failing, or
   any Linkerd check is not green before the migration begins.

#### Phase 1: core webhook certificates

1. Create the dedicated core webhook self-signed Issuer, stable CA Certificate,
   and CA Issuer. Wait for the CA Certificate and Issuer to become ready.
2. For one consumer at a time, temporarily set its webhook `caBundle` to the
   old CA plus the new CA. This dual bundle prevents an API-server trust gap.
3. Create the cert-manager leaf Certificate using the existing canonical Secret
   name, then wait for its actual consumer to reload the mounted files:
   - policy validator: `linkerd-policy-validator-k8s-tls` and
     `Deployment/linkerd-destination`;
   - proxy injector: `linkerd-proxy-injector-k8s-tls` and
     `Deployment/linkerd-proxy-injector`;
   - service-profile validator: `linkerd-sp-validator-k8s-tls` and
     `Deployment/linkerd-destination`.
4. After each consumer, prove the stored and served leaf match, the new CA
   validates the leaf, admission succeeds, and `linkerd check` remains green.
   If the served leaf does not change within the verification timeout, stop and
   inspect the certificate-watcher logs before approving a rollout of only the
   owning deployment.
5. Annotate that webhook configuration for cert-manager CA injection. Wait for
   cainjector to replace the temporary dual bundle with the stable new CA, then
   repeat the functional check.

**Gate:** do not start the next webhook until the current webhook has passed
stored/served/bundle comparison and admission testing.

#### Phase 2: Linkerd Viz certificates

1. Create the dedicated Viz self-signed Issuer, stable CA Certificate, and CA
   Issuer. Wait for them to become ready.
2. Migrate `tap-k8s-tls` using a temporary old-plus-new CA bundle on
   `APIService/v1alpha1.tap.linkerd.io`, verify the Tap server's native reload,
   then enable cert-manager CA injection.
3. Migrate `tap-injector-k8s-tls` using a temporary old-plus-new CA bundle on
   `MutatingWebhookConfiguration/linkerd-tap-injector-webhook-config`, verify
   the injector's native reload, then enable cert-manager CA injection.
4. After each wave, compare stored, served, and bundled fingerprints and run
   `linkerd viz check`. Confirm the tap APIService remains Available.

**Gate:** do not proceed to workload identity until both webhook phases have
been stable through an observation window and a controlled test leaf renewal.

#### Phase 3: identity issuer and trust anchor

1. Create the new cert-manager identity root and CA Issuer without changing the
   existing `linkerd-identity-issuer` Secret.
2. Publish an old-plus-new identity trust bundle through a reviewed Linkerd
   upgrade while the old issuer remains active.
3. Roll every one of the approximately 70 currently meshed pods in controlled
   workload groups. After each group, prove the proxy is ready and trusts both
   roots. Keep unmeshed Teleport server pods unchanged.
4. Only after every proxy trusts both roots, create the cert-manager
   `linkerd-identity-issuer` Certificate against the canonical Secret and prove
   that `Deployment/linkerd-identity` natively reloads it. Roll the deployment
   only as a recovery action if the issuer does not reload within the
   verification timeout.
5. Prove newly issued workload identities chain to the new root while old
   identities continue to communicate. Run identity, policy, tap, application,
   and complete Linkerd checks.
6. Wait longer than the maximum workload identity lifetime and verify no active
   proxy still presents an identity issued by the old root.
7. Remove the old root from the trust bundle in a later, separately approved
   rollout, then roll and verify every meshed workload again.

#### Rollback boundaries

- Before a webhook's old CA is removed, restore its saved Secret and old bundle,
  then verify native reload. Roll only that webhook's owning deployment if the
  served certificate does not revert within the verification timeout.
- During the dual-root identity period, restore the old issuer Secret and verify
  that `linkerd-identity` reloads it; both roots remain trusted, so a targeted
  deployment rollout remains a safe fallback.
- Never remove an old webhook CA or identity root in the same approval step that
  introduces its replacement.
- Stop immediately on APIService unavailability, admission timeouts, identity
  errors, proxy readiness loss, or a failed Linkerd check.

Routine identity leaf renewal becomes automatic. Root key replacement remains
an intentionally gated security ceremony.

## Plan 3: OpenObserve Dex ingress

### Implemented minimal configuration

The public TLS connection terminates at pfSense and presents its managed Let's
Encrypt wildcard certificate. pfSense then forwards the request to the NGINX
Ingress that references `dex-openobserve-tls`; that internal backend
certificate is not presented to users.

The platform template now creates a namespaced self-signed cert-manager
`Issuer/openobserve-dex-selfsigned` and
`Certificate/openobserve-dex-tls`. The Certificate owns the existing
`dex-openobserve-tls` Secret, has a 90-day lifetime, renews at 50 percent of its
lifetime, rotates its private key, and contains the public Dex hostname as a
SAN. Its non-empty organization and organizational-unit Subject also gives the
self-signed certificate a standards-compliant Issuer DN. Both NGINX controllers
watch the Secret and hot-reload it, so routine renewal does not require a Dex or
ingress-controller rollout.

### 2026-10-15 rollout evidence

- The Issuer and Certificate became Ready and cert-manager scheduled the first
  renewal for 2026-11-29.
- The custom NGINX load balancer and all five RKE2 ingress nodes served the same
  newly issued certificate without restarting Dex or either ingress controller.
- Missing-Secret errors stopped after issuance.
- Public Dex discovery and the direct NGINX discovery endpoint both returned
  HTTP 200 with the expected issuer, and the unauthenticated authorization flow
  redirected through the GitHub connector to `github.com`.
- The public endpoint continued to present the pfSense Let's Encrypt
  certificate; no user-facing trust or routing configuration changed.
- A follow-up Subject correction issued revision 2 at 2026-10-15T17:00:05Z.
  The stored and internally served fingerprints matched, `/dex` and Dex
  discovery returned HTTP 200, and the retained empty-Issuer warning applied
  only to deleted revision 1.

Observe one natural renewal as ongoing lifecycle evidence. No additional Dex
certificate cleanup is required for this configuration.

## Plan 4: NiFi server and external-client TLS

### Evidence and risk

The main NiFi workload is a directly managed single-replica StatefulSet, not a
NiFiKop cluster. Its startup script creates self-signed PKCS12 material valid
for 3,650 days only when the file is absent, unreadable, or missing a SAN; it
does not renew based on expiration. The external client Secret is also a
long-lived Vault-sourced certificate. Enabling NiFiKop cert-manager support
would not fix the direct StatefulSet's server certificate.

NiFi 2.7.1 supports native keystore and truststore auto reload. That permits
automatic leaf renewal without restarting the single NiFi replica, provided
the generated PKCS12 files are replaced atomically.

### Implementation plan

1. Select one stable internal CA. Prefer the existing Vault PKI through a
   cert-manager Issuer if it is available and operationally owned; otherwise
   use a scoped cert-manager CA with a stable private key.
2. Issue a 90-day NiFi server certificate in `kafka` with all StatefulSet,
   Service, and client-used SANs.
3. Issue a 90-day client certificate in `dataflow` with a stable subject
   identity. Do not copy a CA private key across namespaces.
4. Mount PEM material from the cert-manager Secrets. Add a narrow conversion
   process that validates the new chain, builds PKCS12 into temporary files,
   and atomically replaces the fixed keystore/truststore paths.
5. Enable `nifi.security.autoreload.enabled=true` and an explicit reload check
   interval. Confirm NiFi reports that it loaded the new certificate.
6. Replace the AVP/Vault long-lived external-client Secret with the managed
   Certificate Secret in `dataflow-apps`.
7. Determine whether NiFiKop rereads its client Secret. If it does not, add a
   targeted Reloader annotation only to the NiFiKop operator deployment.

### One-time migration order

1. Add old-plus-new CA trust to both sides.
2. Deploy the managed client leaf while the server trusts both CAs.
3. Deploy and hot-reload the managed server leaf.
4. Confirm external cluster operations and the main NiFi UI/API.
5. Remove the old CA only after all clients have changed and the rollback
   interval has elapsed.

The affected repositories are `k8s-kafka` for server TLS and reload support,
and `dataflow-apps` plus the individual dataflow application repositories for
client Secret consumption and reload verification.

## Plan 5: RKE2 node and CA certificates

### Evidence and risk

The cluster runs RKE2 v1.35.3+rke2r3 on three control-plane/etcd nodes and two
workers. RKE2 leaf certificates are valid for 365 days and are automatically
renewed when RKE2 starts within its renewal window; the current release uses a
120-day threshold. RKE2 CAs are valid for ten years and are not automatically
renewed. No current `CertificateExpirationWarning` event was found.

Automatic renewal at process start is not the same as guaranteed rotation on
a continuously running node. It needs a controlled restart owner.

### Implementation plan

1. From each node, capture `sudo rke2 certificate check --output table` and
   store only certificate metadata in the operational inventory.
2. Install a read-only host timer that reports RKE2 certificate expiration and
   emits structured journald output. Alert on the RKE2 warning event and on any
   leaf inside 120 days.
3. Add a controlled renewal workflow using system-upgrade-controller or an
   approved operations runner:
   - preflight etcd health and snapshot status;
   - restart one control-plane node at a time and require it to rejoin before
     moving on;
   - drain/restart/uncordon one worker at a time;
   - verify Kubernetes API, node readiness, and newly served fingerprints.
4. Use an ordinary RKE2 restart for normal within-window renewal. Reserve
   `rke2 certificate rotate` for an intentional new-key operation.
5. Audit CA residual lifetime at least annually and begin a separate CA
   rotation project no later than two years before expiry. CA rotation must
   never be unattended.

## Plan 6: ingress-nginx consolidation and webhook TLS

### Evidence and risk

Two active ingress-nginx controllers currently claim the same
`controller-class=k8s.io/ingress-nginx` and `ingress-class=nginx`:

- the RKE2-managed hardened DaemonSet; and
- an older Argo-managed custom Deployment.

Both also register the standard ingress-nginx validation path and use
long-lived, one-shot admission certificates. This creates ambiguous Ingress
ownership before certificate rotation is considered.

### Preferred implementation plan

1. Retain the newer RKE2-managed hardened controller.
2. Add a persistent RKE2 `HelmChartConfig` that enables the chart's
   cert-manager admission-certificate mode and disables one-shot patch jobs.
3. Declare a stable admission CA, a 90-day leaf, cert-manager CA injection, and
   a DaemonSet-aware restart/hot-reload path.
4. Provide the stable LoadBalancer/VIP behavior currently supplied by the
   custom controller and repoint pfSense/HAProxy if required.
5. Prove Rancher and the Dex route decision against the RKE2 controller.
6. Disable and remove the custom controller, its webhook, and its certificate
   only after all `nginx` Ingress traffic is proven on the retained controller.

If the custom controller must remain, take the inverse path: disable the RKE2
controller, upgrade the custom chart to a supported version, and implement the
same cert-manager, CA injection, and reload pattern. The final state must have
one owner for the `nginx` IngressClass and one validation webhook.

### Acceptance

- Exactly one controller reconciles the `nginx` class.
- Its 90-day Certificate is `Ready=True`, its webhook bundle matches the CA,
  and a test Ingress admission succeeds.
- Rancher UI/API and every retained NGINX-hosted route work through the intended
  VIP after a renewal.

## Plan 7: Gravitee Kubernetes Operator webhook

### Evidence and risk

The Gravitee Kubernetes Operator (GKO) creates and updates
`Secret/gko-webhook-cert`, mounts it into the operator, and manages the webhook
bundles. The current certificate is long-lived. The installed chart does not
yet provide a proven switch for externally managed certificate ownership.

Creating a cert-manager Certificate for that Secret now would create two
writers.

### Implementation plan

1. Render and test the latest supported GKO chart in staging to determine
   whether it can consume an externally managed Secret and CA bundle.
2. If supported, disable GKO's internal issuer, create a stable CA and 90-day
   webhook leaf, use cert-manager CA injection, and prove GKO reloads the
   mounted certificate or add a targeted rollout.
3. If not supported, open an upstream feature request or maintain a minimal,
   version-pinned patch that disables internal issuance while retaining the
   operator's certificate watcher.
4. Until a single-writer migration is proven, keep the current GKO ownership
   and explicitly monitor the Secret, served endpoint, and webhook bundle as a
   documented exception.

Acceptance requires a single writer and a successful Gravitee custom-resource
admission and reconciliation after renewal.

## Plan 8: other controller-owned and internal certificates

These certificates should not be converted to cert-manager without first
proving that their vendor ownership can be disabled.

| Component | Current interpretation | Plan |
| --- | --- | --- |
| Kyverno webhooks | Marked `cert.kyverno.io/managed-by=kyverno`; Kyverno periodically checks and renews its webhook pair | Retain ownership; alert on leaf and bundle; observe one natural renewal and an admission test. |
| Cluster API webhook | Controller-owned Service certificate | Retain ownership; capture Secret/served/bundle fingerprints before and after a release or natural renewal. |
| Longhorn webhook | Dynamiclistener-managed CA and leaf | Retain ownership; monitor manager logs, served certificate, bundle, and volume operations after renewal. |
| Rancher dynamiclistener endpoints | Rancher-owned | Retain ownership; monitor stored/served equivalence and functional Rancher checks. |
| External Secrets and MetalLB webhooks | Long-lived controller/bootstrap certificates | Verify current upstream renewal behavior. If no routine renewal exists, either adopt the component's supported cert-manager integration or record and alert on a time-bounded exception. |
| cert-manager webhook | cert-manager internal CA and leaf | Retain internal management and monitor readiness/metrics; do not create a second Certificate. |
| Legacy `teleport/etcd-tls` | No longer an active consumer after the Teleport migration | Retain only for the approved rollback interval, then remove in a separate reviewed change. |

### Teleport iDRAC bridge

The iDRAC bridge currently creates a ten-year self-signed certificate with
OpenSSL at pod start. Replace it with a cert-manager 90-day server Certificate,
mount the Secret read-only, and attach a targeted rollout to Secret changes.
Validate the KVM launch path, browser trust behavior, and rollback before
removing the generated certificate logic.

## Plan 9: public pfSense/HAProxy wildcard certificate

### Evidence and risk

The public endpoints for `teleport.app.suncoast.systems` and the Dex hostname
present the same Let's Encrypt certificate for the relevant Suncoast wildcard
names. It is valid from 2026-09-26 through 2026-12-25. That certificate is not
stored in Kubernetes; it terminates on pfSense/HAProxy. No current repository
declares its ACME lifecycle.

### Implementation plan

1. Export a redacted pfSense configuration backup and record which ACME
   account, DNS-01 provider, renewal schedule, certificate object, and HAProxy
   frontends own the wildcard.
2. Verify that the Cloudflare DNS credential is scoped to the minimum required
   zone permissions and remains in pfSense's secret store, never Git.
3. Verify the after-renew action reloads or rebinds HAProxy without leaving the
   old certificate served.
4. Run a staging or forced test renewal in a maintenance window, then verify
   the public fingerprint from an external probe and complete Teleport plus
   Dex/OAuth smoke tests.
5. Add external expiry probes and alerts at 30 and 14 days.
6. Document the non-secret pfSense/HAProxy/ACME configuration in
   `proxmox-infra-ops` or a dedicated network-edge repository so the next
   platform build includes an explicit external-certificate step.

Retain the previously valid certificate for the short HAProxy rollback window,
but never commit its private key.

## Plan 10: platform certificate inventory and monitoring

### Implementation plan

1. Add a GitOps certificate inventory with fields for namespace, Secret,
   issuer/owner, lifetime, renewal threshold, CA-key policy, consumer, served
   endpoint, bundle object, reload mechanism, functional check, and source
   repository.
2. Deploy a read-only certificate audit CronJob. Use namespace-scoped Roles and
   `resourceNames` for known Secrets rather than granting cluster-wide Secret
   list access. Emit only public X.509 metadata, never private keys or Secret
   payloads.
3. Collect cert-manager expiration, renewal, and readiness metrics.
4. Probe stored-versus-served fingerprints for internal TLS endpoints and
   validate webhook/APIService CA bundles.
5. Ingest RKE2 host reports and `CertificateExpirationWarning` events.
6. Probe public TLS endpoints externally, including the pfSense/HAProxy
   wildcard.
7. Route structured results through Alloy to OpenObserve and alert at 30, 14,
   and 7 days, on `Ready=False`, on an overdue renewal, and on any
   stored/served/bundle mismatch.
8. Create a harmless short-lived synthetic Certificate and endpoint so alert
   delivery and consumer update behavior can be tested without waiting months
   for a production renewal.

The base inventory, RBAC, and audit workload belong in
`tf-k8s-cluster-infra`. Alloy routing, OpenObserve dashboards, and alert rules
belong in `grafana-alloy-monitoring`.

## Repository change map

| Repository | Planned changes |
| --- | --- |
| `tf-k8s-cluster-infra` | Correct Linkerd resources/targets, implement the Dex decision, add RKE2 HelmChartConfig if RKE2 ingress is retained, add inventory/RBAC/audit workload, and preserve all future-build configuration. |
| `grafana-alloy-monitoring` | Certificate audit ingestion, dashboards, and 30/14/7-day plus mismatch alerts. |
| `k8s-kafka` | NiFi stable CA/server leaf, PEM-to-PKCS12 conversion, native reload settings, and migration manifests. |
| `dataflow-apps` | Managed external-client Certificate and operator Secret/reload integration. |
| `dataflow-example-app`, `dataflow-notification-app`, `dataflow-platform-deploy-app`, `dataflow-cms-translation-app` | Verify and, where needed, update NiFi client trust/identity consumption. |
| `k8s-api-gateway` | GKO chart upgrade/integration after single-writer support is proven. |
| `k8s-teleport` | iDRAC bridge Certificate and rollout; later removal of legacy etcd rollback material. |
| `argocd-post-install` | Argo application ordering/sync waves only where needed for new certificate dependencies. |
| `proxmox-infra-ops` or dedicated edge repo | Non-secret pfSense ACME/HAProxy ownership and recovery documentation. |

Do not make a speculative change in every repository. Each repository should
change only after its consumer and Secret ownership have been verified.

## Recommended rollout order

1. Immediately monitor the Rancher imperative API certificate and verify the
   pfSense ACME renewal configuration. These are the nearest unproven expiry
   paths.
2. Capture the five-node RKE2 certificate inventory.
3. Implement inventory, monitoring, alerts, and the synthetic renewal test.
4. Make source-only Linkerd corrections and the reviewed Dex ingress decision
   so future platform builds are correct.
5. Consolidate ingress-nginx and establish renewable admission TLS.
6. Migrate Linkerd webhook TLS, then perform the separate identity
   overlapping-trust migration.
7. Migrate NiFi using the dual-trust order and prove hot reload.
8. Migrate GKO if a single-writer integration is supported, then the iDRAC
   bridge and remaining internal exceptions.
9. Observe one natural renewal for cert-manager hot reload, Reloader rollout,
   vendor rotator, RKE2 restart renewal, and external ACME renewal.
10. Remove old trust, legacy Secrets, and temporary compatibility logic only in
    later reviewed changes.

## Required evidence for every stage

- Source diff and rendered manifests are reviewed before commit.
- The exact local commit is recorded separately from whether it was pushed.
- Argo target revision, sync, and health are recorded separately from
  functional proof.
- Issuer/Certificate readiness and expected `renewalTime` are captured.
- Secret resource version and public certificate fingerprint changed.
- The endpoint actually serves the new certificate and expected complete
  chain.
- Webhook or APIService `caBundle` matches the active CA.
- Only the required workload rolled, and every replacement became ready before
  the next one changed.
- Product-level behavior succeeds: admission, database connection, Linkerd
  mTLS, NiFi client operation, Rancher/API access, RKE2 API, Teleport login, or
  Dex/OAuth login as applicable.
- Logs contain no certificate, trust, webhook, leader, or quorum errors.
- The first natural renewal is observed before the mechanism is declared
  operationally proven.

## Authoritative implementation references

- [Linkerd: Automatically Rotating Control Plane TLS Credentials](https://linkerd.io/2-edge/tasks/automatically-rotating-control-plane-tls-credentials/)
- [Linkerd: Automatically Rotating Webhook TLS Credentials](https://linkerd.io/docs/tasks/automatically-rotating-webhook-tls-credentials/)
- [cert-manager CA Injector](https://cert-manager.io/docs/concepts/ca-injector/)
- [cert-manager Prometheus Metrics](https://cert-manager.io/docs/devops-tips/prometheus-metrics/)
- [trust-manager](https://cert-manager.io/docs/trust/trust-manager/)
- [RKE2 Certificate Management](https://docs.rke2.io/security/certificates)
- [RKE2 Helm Integration and HelmChartConfig](https://docs.rke2.io/add-ons/helm)
- [Apache NiFi Administration Guide](https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html)
- [Kyverno certificate renewal behavior](https://kyverno.io/docs/installation/customization/)
- [Gravitee Kubernetes Operator](https://github.com/gravitee-io/gravitee-kubernetes-operator)
- [Rancher imperative API certificate rotator tracking issue](https://github.com/rancher/rancher/issues/49200)

## Rollback principles

- Preserve old CA trust and still-valid leaf material until the new chain is
  functionally verified and the rollback interval has elapsed.
- Roll consumers back before removing newly issued material.
- Never delete an expiring Secret to force renewal on a stateful or
  controller-owned service.
- Never allow two controllers to write the same TLS Secret or CA bundle.
- For CA key rotation, publish overlapping trust first, change issuers second,
  rotate consumers third, and remove old trust last.
- Restore stateful data from a verified backup only if manifest rollback and
  ordinary workload recovery cannot restore service.
