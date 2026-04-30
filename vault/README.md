# Vault on OpenShift — Helm Chart, Values, and Runbook

This directory holds the operational artifacts for **three independent
HashiCorp Vault raft clusters** running on OpenShift, plus the scripts and
runbook used to recover, deploy, inspect, and maintain them.

| Cluster | Helm release | Raft cluster_name | F5 VIP |
|---|---|---|---|
| Prod DC      | `vault`     | `vault-prod-cluster`    | `vault.southernco.com` |
| Non-prod DC  | `vault`     | `vault-dev-dc-cluster`  | (not yet wired) |
| Vault-dev    | `vault-dev` | `vault-dev-cluster`     | (not yet wired) |

## Layout

```
vault/
├── README.md                      this file
├── NOTICE                         attribution for embedded HashiCorp chart
├── .env.example                   template for local OpenShift creds (.env is gitignored)
├── .gitignore                     (in parent repo) ignores all secret/key files
│
├── chart/vault/                   hashicorp/vault@0.28.1 (stock upstream, MPL-2.0)
│
├── values/                        per-cluster values.yaml overrides
│   ├── osxadch506pr-prod-AL-leader.yaml         (prod, node_id: vault-al-506pr)
│   ├── osxgdch506pr-prod-GA-follower.yaml       (prod, node_id: vault-ga-506pr)
│   ├── osxgdch101pr-prod-GA-tiebreaker.yaml     (prod, node_id: vault-ga-101pr)
│   ├── osxadch504np-nonprod-AL.yaml             (non-prod, node_id: vault-al-504np)
│   ├── osxgdch504np-nonprod-GA.yaml             (non-prod, node_id: vault-ga-504np)
│   ├── osxgdch101pr-nonprod-GA-tiebreaker.yaml  (non-prod, node_id: vault-ga-101np)
│   ├── osxadch502np-vault-dev-AL-leader.yaml    (vault-dev, node_id: vault-dev-al-502np)
│   ├── osxgdch502np-vault-dev-GA-follower.yaml  (vault-dev, node_id: vault-dev-ga-502np)
│   └── osxgdch101pr-vault-dev-GA-tiebreaker.yaml(vault-dev, node_id: vault-dev-ga-101pr)
│
├── manifests/
│   └── vault-dev-metallb-template.yaml   LoadBalancer service applied with `oc apply`
│                                         (the helm chart only creates ClusterIPs)
│
├── recover-helm-chart.ps1         decode any helm-3 release secret to disk
└── inspect-vault.ps1              status report for a single deployment
```

Local-only files that exist on disk but are **gitignored** (never committed):

```
NEW-KEYS-DO-NOT-COMMIT.json            prod root token + 5 unseal keys
NEW-KEYS-NONPROD-DO-NOT-COMMIT.json    non-prod root token + 5 unseal keys
NEW-KEYS-VAULT-DEV-DO-NOT-COMMIT.json  vault-dev root token + 5 unseal keys
.env                                   `oc login` credentials for local use
snapshots/                             raft snapshots taken before changes
recovered-*/                           per-cluster chart-recovery dumps
upstream/                              fresh `helm pull hashicorp/vault`
```

## Prerequisites

- `oc` 4.x (tested with 4.21.x)
- `helm` 3.x (tested with 3.18.x)
- `pwsh` or `powershell` 5.1+ (the `.ps1` scripts assume Windows PowerShell 5.1)
- Network reachability between OpenShift clusters via the MetalLB IPs they
  advertise (see [the network blocker section](#-network-blocker-affecting-non-prod-and-vault-dev)
  below for known limits)

## Quickstart

```powershell
# 1. Provide your oc credentials (do NOT commit .env)
Copy-Item .env.example .env
# edit .env with your AD username + password

# 2. Source it in your shell
. .\.env   # in bash/zsh
# OR equivalent in PowerShell:
$env:OC_USER='YOUR-AD-USERNAME'; $env:OC_PASSWORD='YOUR-PASSWORD'

# 3. Inspect any deployment
.\inspect-vault.ps1 `
  -ApiUrl 'https://api.osxadch506pr.southernco.com:6443' `
  -Namespace '47303-vault-xadch506-pr'

# 4. (For ops only) Re-deploy a single cluster
oc login https://api.osxadch506pr.southernco.com:6443 -u $env:OC_USER -p $env:OC_PASSWORD
helm upgrade --install vault .\chart\vault `
  -n 47303-vault-xadch506-pr `
  -f .\chart\vault\values.openshift.yaml `
  -f .\values\osxadch506pr-prod-AL-leader.yaml
```

## Cluster topology — Prod DC Vault

`cluster_name = "vault-prod-cluster"`, helm release name `vault`.
(Renamed from the original `vault-prod-dc-cluster` after the legacy
`osxapch506pr` vault — which used the bare `vault-prod-cluster` name —
was scaled down for decommissioning.)

| Cluster (project) | Node ID | MetalLB IP |
|---|---|---|
| `osxadch506pr` / `47303-vault-xadch506-pr` | `vault-al-506pr` | `10.15.96.120:8200` |
| `osxgdch506pr` / `47303-vault-xgdch506-pr` | `vault-ga-506pr` | `10.19.96.120:8200` |
| `osxgdch101pr` / `47303-vault-xgdch101-pr` | `vault-ga-101pr` | `10.19.96.11:8200`  |

DNS / F5:

```
vault.southernco.com  ->  146.126.157.75 (F5 VIP)
                      ->  pool vault-prod-dc, monitor GET /v1/sys/health expects 200 (active-only)
                      ->  routes to whichever cluster is the active raft leader
```

## Cluster topology — Non-prod DC Vault

`cluster_name = "vault-dev-dc-cluster"`, helm release name `vault`.

| Cluster (project) | Node ID | MetalLB IP | Status |
|---|---|---|---|
| `osxadch504np` / `47303-vault-xadch504-np` | `vault-al-504np` | `10.15.96.60:8200`  | ✅ active leader |
| `osxgdch504np` / `47303-vault-xgdch504-np` | `vault-ga-504np` | `10.19.96.61:8200`  | 🚧 scaled to 0 — see [network blocker](#-network-blocker-affecting-non-prod-and-vault-dev) |
| `osxgdch101pr` / `47303-vault-xgdch101-np` | `vault-ga-101np` | `10.19.96.10:8200`  | ✅ follower (voter) |

## Cluster topology — Vault-dev DC Vault

`cluster_name = "vault-dev-cluster"`, helm release name `vault-dev`
(third independent raft cluster).

| Cluster (project) | Node ID | MetalLB IP | Status |
|---|---|---|---|
| `osxadch502np` / `47303-vault-dev-xadch502-np` | `vault-dev-al-502np` | `10.15.96.30:8200` | ✅ active leader |
| `osxgdch502np` / `47303-vault-dev-xgdch502-np` | `vault-dev-ga-502np` | `10.19.96.30:8200` | 🚧 scaled to 0 — same network blocker |
| `osxgdch101pr` / `47303-vault-dev-xgdch101-pr` | `vault-dev-ga-101pr` | `10.19.96.12:8200` | ✅ follower (voter) |

> The `osxgdch101pr` cluster hosts THREE separate vault instances in
> different namespaces — prod (`47303-vault-xgdch101-pr`), non-prod
> (`47303-vault-xgdch101-np`), and vault-dev (`47303-vault-dev-xgdch101-pr`)
> — each a member of a different raft cluster.

The `vault-dev-metallb` LoadBalancer service is NOT provisioned by the
helm chart; it is defined in `manifests/vault-dev-metallb-template.yaml`
and applied separately. The pre-existing prod and non-prod releases also
have a `vault-metallb` service that was created the same way.

## 🚨 Network blocker affecting non-prod and vault-dev

Two MetalLB pools are unrouted cross-cluster:

| Pool | Announced from | Used by | Routable cross-cluster? |
|---|---|---|---|
| `10.19.96.60-10.19.96.119` | `osxgdch504np` | non-prod GA | ❌ **No** |
| `10.19.96.30-10.19.96.59`  | `osxgdch502np` | vault-dev GA | ❌ **No** |
| `10.19.96.10-10.19.96.29`  | `osxgdch101pr` | non-prod GA tiebreaker, vault-dev GA tiebreaker, prod GA-101 | ✅ Yes |
| `10.15.96.x`                | osxadch* clusters | All AL deployments | ✅ Yes |

Because of this:

- AL leaders cannot push raft AppendEntries to GA-504np / GA-502np
- Workstations cannot probe GA-504np / GA-502np health
- Both non-prod and vault-dev clusters are degraded to 2 voters
  (failure tolerance 0)

GA-504np and GA-502np have been removed from raft and their StatefulSets
scaled to 0; PVCs are retained for fast re-join once routing is fixed.

**Network ticket request (open one with the network team):**

> Please add cross-cluster routing for the following two MetalLB pools
> (matching the existing routing for `10.19.96.10-10.19.96.29` on
> `osxgdch101pr`):
>
> 1. `10.19.96.60-10.19.96.119` announced by `osxgdch504np` cluster nodes
>    — specifically `10.19.96.61:8200` and `:8201` must be reachable from
>    pods in `osxadch504np` and `osxgdch101pr`.
> 2. `10.19.96.30-10.19.96.59` announced by `osxgdch502np` cluster nodes
>    — specifically `10.19.96.30:8200` and `:8201` must be reachable from
>    pods in `osxadch502np` and `osxgdch101pr`.
>
> Until then, both the non-prod and vault-dev Vault clusters are degraded
> to 2 voters and cannot survive a single-node failure.

### Re-join GA-504np (non-prod) once network is fixed

```powershell
$keys  = (Get-Content .\NEW-KEYS-NONPROD-DO-NOT-COMMIT.json | ConvertFrom-Json).unseal_keys_b64
oc login https://api.osxgdch504np.southernco.com:6443
oc scale statefulset -n 47303-vault-xgdch504-np vault --replicas=1
# wait for pod 1/1
oc exec -n 47303-vault-xgdch504-np vault-0 -- /bin/sh -c `
  'VAULT_ADDR=http://127.0.0.1:8200 vault operator raft join http://10.15.96.60:8200'
foreach ($k in $keys[0..2]) {
  oc exec -n 47303-vault-xgdch504-np vault-0 -- /bin/sh -c `
    "VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal $k"
}
```

### Re-join GA-502np (vault-dev) once network is fixed

```powershell
$keys  = (Get-Content .\NEW-KEYS-VAULT-DEV-DO-NOT-COMMIT.json | ConvertFrom-Json).unseal_keys_b64
oc login https://api.osxgdch502np.southernco.com:6443
oc scale statefulset -n 47303-vault-dev-xgdch502-np vault-dev --replicas=1
# wait for pod 1/1
oc exec -n 47303-vault-dev-xgdch502-np vault-dev-0 -- /bin/sh -c `
  'VAULT_ADDR=http://127.0.0.1:8200 vault operator raft join http://10.15.96.30:8200'
foreach ($k in $keys[0..2]) {
  oc exec -n 47303-vault-dev-xgdch502-np vault-dev-0 -- /bin/sh -c `
    "VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal $k"
}
```

## Three configuration bugs that were fixed in the values files

The original installations never formed a working multi-cluster raft
because of three bugs baked into the original values. All three are now
corrected in every file under `values/`:

1. **All pods used `node_id = vault-0`** (the StatefulSet hostname,
   applied by the chart when `server.ha.raft.setNodeId: true`). When a
   follower in another cluster ran `raft join`, raft saw the same
   `node_id` as the leader and **overwrote** the leader's entry instead
   of adding a follower. Fix: `setNodeId: false` plus a unique `node_id`
   per cluster in the raft HCL block.

2. **`server.ha.apiAddr` and `server.ha.clusterAddr` were unset**, so
   the chart defaulted `VAULT_CLUSTER_ADDR` to
   `https://$(HOSTNAME).vault-internal:8201` — pod-internal DNS that
   doesn't resolve cross-cluster. Fix: set `server.ha.apiAddr` and
   `server.ha.clusterAddr` to each cluster's MetalLB IP. The HCL
   `api_addr`/`cluster_addr` settings alone are NOT enough — the env
   vars set by the chart take precedence.

3. **Readiness probe path was `/v1/sys/health?uninitcode=204`** (from
   `chart/vault/values.openshift.yaml`) which returns 429 for healthy
   standbys, marking them as `0/1 Ready`. This drops them from the
   MetalLB Service endpoints and breaks F5 fail-over. Fix: override
   `server.readinessProbe.path: "/v1/sys/health?standbyok=true&uninitcode=204"`
   so standby pods report Ready.

The chart's StatefulSet `updateStrategy: OnDelete` means changes to the
template don't auto-roll pods — after a `helm upgrade` you must
`oc delete pod vault-0` on each node manually (and re-unseal it after
restart).

## Day-2 operations

### Re-unseal a sealed pod

After any pod restart, vault is sealed and must be unsealed with 3 of 5
unseal keys from the matching `NEW-KEYS-*-DO-NOT-COMMIT.json` file:

```powershell
$keys = (Get-Content .\NEW-KEYS-DO-NOT-COMMIT.json | ConvertFrom-Json).unseal_keys_b64
oc login https://api.<cluster>.southernco.com:6443
foreach ($k in $keys[0..2]) {
  oc exec -n <ns> vault-0 -- /bin/sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal $k"
}
```

### Inspect a deployment

```powershell
.\inspect-vault.ps1 `
  -ApiUrl https://api.osxadch506pr.southernco.com:6443 `
  -Namespace 47303-vault-xadch506-pr
```

### Apply a values change (rolling upgrade preserving quorum)

```powershell
helm upgrade vault .\chart\vault -n <ns> `
  -f .\chart\vault\values.openshift.yaml -f .\values\<cluster>.yaml

# updateStrategy: OnDelete -- delete pods one at a time:
oc delete pod -n <ns> vault-0           # roll one node
# wait for pod Running, then unseal it (see above)
# repeat on next cluster
```

Always do followers BEFORE the leader — losing the leader triggers an
election that delays the operation slightly.

### Take a raft snapshot

```powershell
$T = (Get-Content .\NEW-KEYS-DO-NOT-COMMIT.json | ConvertFrom-Json).root_token
oc exec -n 47303-vault-xadch506-pr vault-0 -- /bin/sh -c `
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$T vault operator raft snapshot save /tmp/snap"
oc cp -n 47303-vault-xadch506-pr vault-0:/tmp/snap .\snapshots\<name>.snap
```

### Add a new auth method, secret engine, or policy

```powershell
$T = (Get-Content .\NEW-KEYS-DO-NOT-COMMIT.json | ConvertFrom-Json).root_token
oc exec -n 47303-vault-xadch506-pr vault-0 -it -- /bin/sh
  export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$T
  vault auth enable kubernetes
  vault secrets enable -path=secret kv-v2
  # ...
  exit
```

Changes replicate automatically to followers via raft.

### Force leadership change

```powershell
oc exec -n <leader-ns> vault-0 -- /bin/sh -c `
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$T vault operator step-down"
```

Raft will elect a new leader from the remaining voters.

## Recovering the chart from a deployed cluster

If the chart files are ever lost again, `recover-helm-chart.ps1` will
reconstruct them from any cluster running the helm release:

```powershell
.\recover-helm-chart.ps1 -Namespace <ns> -Release <release> -OutDir .\recovered
```

It extracts the helm release secret (`sh.helm.release.v1.<release>.v<rev>`),
which contains the full chart and user-supplied values as
base64-encoded gzipped JSON, and writes the chart tree + values to disk.

## Security follow-ups

1. **Move keys + tokens off disk.** The `NEW-KEYS-*-DO-NOT-COMMIT.json`
   files contain root tokens and Shamir unseal keys in plaintext. Move
   them to a password manager / secrets manager / HSM, then delete the
   local files.
2. **Configure auto-unseal** so pod restarts don't require manual
   intervention. Options on OpenShift:
   - **transit seal** pointed at one trusted always-on Vault
   - **AWS KMS / Azure Key Vault / GCP KMS** (cloud KMS)
   - **HSM (PKCS#11)** if available
3. **End-to-end TLS to vault pods** — current setup uses
   `tls_disable = 1` and terminates TLS at the F5/route. Consider
   enabling pod-side TLS by setting `global.tlsDisable: false` and
   mounting a cert.
4. **Enable an audit device** — the `audit-vault-0` PVC is mounted but
   no audit device is registered, so nothing is being written:
   ```
   vault audit enable file file_path=/vault/audit/audit.log
   ```
