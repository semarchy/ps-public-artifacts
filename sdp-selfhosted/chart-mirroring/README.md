# Semarchy Data Platform — Air-Gapped / Local Registry Mirroring

This guide explains how to mirror the **Semarchy Data Platform** Helm chart and
all of its container images from the Semarchy registry
(`registry.na.semarchy.net`) into your **own local registry** (Artifactory, ACR,
Harbor, Nexus, …), and how to deploy the platform so that every pull comes from
your local registry only.

**Validated chart versions:** 1.3.0, 1.4.2

| File | Purpose |
|------|---------|
| [`mirror-semarchy-chart.sh`](mirror-semarchy-chart.sh) | Mirrors the chart **and** all images to your registry, then self-checks the result |
| [`values.customer-mirrored-images.yaml`](values.customer-mirrored-images.yaml) | Deployment values that repoint every image to your registry |
| [`azure-pipelines.yml`](azure-pipelines.yml) *(optional)* | Azure DevOps pipeline that runs the login and mirror steps on demand |

---

## What changed in chart 1.4.x

| Topic | Chart ≤ 1.4.0 | Chart 1.4.1 / 1.4.2 |
|---|---|---|
| `dm.secretManager` image | Hard-coded full path → explicit override required | Built from `global.image.registry` — **remove the override** (it would double the registry prefix) |
| Hard-coded images left | `dm.secretManager`, `reloader` | `reloader` only |
| CA truststore builder (`global.caCert.enabled=true`) | `mirror/eclipse-temurin` | `mirror/ubi9/openjdk-21-runtime:1.23` |
| Infra-tools tag | — | Set by `global.image-tools.image.tag` (1.9.0 in 1.4.2) |
| Reloader | — | Installed by default (`global.smartReload.reloader.install: true`) |
| Script | No post-mirror check | Built-in self-check (step 5), `--images-out`, `--skip-existing` |

---

## Prerequisites

On the machine (or CI runner) that runs the mirror:

- [`helm`](https://helm.sh/) **3.8+** (OCI support)
- [`skopeo`](https://github.com/containers/skopeo)
- Network access to **both** `registry.na.semarchy.net` and your local registry
- Credentials for both registries

On the target Kubernetes cluster:

- A namespace for the platform
- An image pull secret for your local registry (see [Step 4](#step-4--create-the-image-pull-secret))

---

## Step 1 — Log in to both registries

```bash
# Source (Semarchy) — credentials provided by Semarchy
helm registry login registry.na.semarchy.net \
  --username "$SEMARCHY_USER" --password "$SEMARCHY_KEY"

# Target (your local registry)
helm registry login artifactory.company.com \
  --username "$LOCAL_USER" --password "$LOCAL_KEY"
```

---

## Step 2 — Mirror the chart and images

```bash
./mirror-semarchy-chart.sh \
  --target-repo   artifactory.company.com/semarchy \
  --chart-version 1.4.2 \
  --images-out    images-1.4.2.txt
```

`--target-repo` is the **base** path in your registry. Images keep their
original path underneath it:

```
registry.na.semarchy.net/semarchy-release/docker-dm:1.17.1
  ->  artifactory.company.com/semarchy/semarchy-release/docker-dm:1.17.1
```

### What the script does

1. `helm pull` the chart (the parent `.tgz` **bundles all sub-charts**, so one
   push mirrors the whole chart tree).
2. `helm template` the chart with all optional components enabled and extract
   every `image:` reference — the authoritative image list.
3. `skopeo copy --all` each image (all architectures) to your registry.
4. `helm push` the chart `.tgz` to your registry.
5. **Self-check** — re-render the chart with `global.image.registry` set to your
   target (plus the known Reloader override) and fail if any image still points
   at `registry.na.semarchy.net` or was not mirrored.

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `-t, --target-repo` | *(required)* | Target registry base, e.g. `artifactory.company.com/semarchy` |
| `-v, --chart-version` | *(required)* | Chart version to mirror, e.g. `1.4.2` |
| `-s, --source-registry` | `registry.na.semarchy.net` | Source image registry |
| `--source-chart-repo` | `oci://<source>/semarchy` | OCI repo holding the chart |
| `--chart-target-repo` | `oci://<target-repo>` | Where to push the chart |
| `-f, --values` | — | Extra values file for the render (repeatable). Pass your real deployment values for an exact match |
| `--set` | — | Extra `--set` for the render (repeatable) |
| `--authfile` | Helm registry config | Auth file handed to skopeo |
| `--images-out` | — | Save the discovered image list (audit trail, diff between versions) |
| `--skip-existing` | off | Skip images already present in the target — faster re-runs |
| `--no-verify` | off | Skip the step-5 self-check |
| `--keep` | off | Keep the working directory |
| `--dry-run` | off | Print every copy/push without doing it (the chart is still pulled to discover images) |

> **Tip:** run once with `--dry-run` to review the full plan before mirroring for real.

---

## Step 3 — Configure the deployment values

Open [`values.customer-mirrored-images.yaml`](values.customer-mirrored-images.yaml)
and replace the placeholders. For chart **1.4.1 and later**, mirroring is driven
by **two** settings:

```yaml
global:
  image:
    registry: '<YOUR_LOCAL_REGISTRY>'   # same value as --target-repo
    repository: 'semarchy-release'      # keep as-is

reloader:
  image:
    repository: '<YOUR_LOCAL_REGISTRY>/semarchy-release/mirror/stakater/reloader'
```

- `global.image.registry` repoints **19 of the 20** images.
- `reloader` is an upstream sub-chart whose image is hard-coded to the source
  registry, so it is overridden explicitly.
- **Keep `repository: semarchy-release`.** Many image paths in the chart
  hard-code that segment; only `sdp-infra-tools` and `docker-well-known-service`
  honour `global.image.repository`, so changing it splits the paths.
- **Do not override `dm.secretManager.image.repository`** on 1.4.1+. The chart
  now prepends `global.image.registry` to it, so a full path renders as
  `<REG>/<REG>/semarchy-release/docker-secret-manager` → `ImagePullBackOff`.
  The override is only needed for chart ≤ 1.4.0 (commented out in the file).

Also replace `<YOUR_GLOBAL_DOMAIN>`, `<YOUR_LICENSE_KEY_HERE>`,
`<YOUR_INGRESS_CLASS_NAME>`, the TLS secret names, the admin user fields, and
`<YOUR_LOCAL_REGISTRY_PULL_SECRET>`.

---

## Step 4 — Create the image pull secret

The chart default pull secret is `semarchy-harbor`; the values file replaces it
with your own.

```bash
kubectl create secret docker-registry local-registry \
  --docker-server=artifactory.company.com \
  --docker-username="$LOCAL_USER" \
  --docker-password="$LOCAL_KEY" \
  --namespace=semarchy
```

Use `--docker-server=<host only>` (no path). The secret **name** must match
`global.imagePullSecrets[0].name` in the values file.

---

## Step 5 — Verify, then install

Render with **your** values (add any other `-f` files you deploy with, and
`--set global.caCert.enabled=true` if you use a private CA):

```bash
helm template sdp \
  oci://artifactory.company.com/semarchy/semarchy-data-platform \
  --version 1.4.2 -f values.customer-mirrored-images.yaml \
  | grep -E '^\s*-?\s*image:' | sort -u

# Must print 0
helm template sdp \
  oci://artifactory.company.com/semarchy/semarchy-data-platform \
  --version 1.4.2 -f values.customer-mirrored-images.yaml \
  | grep -c 'registry.na.semarchy.net'
```

Every image must reference your local registry **exactly once** (watch for a
doubled prefix). Then install:

```bash
helm upgrade --install sdp \
  oci://artifactory.company.com/semarchy/semarchy-data-platform \
  --version 1.4.2 \
  --namespace semarchy \
  -f values.customer-mirrored-images.yaml
```

---

## Reference — the mirrored images (chart 1.4.2)

All are stored under `<YOUR_LOCAL_REGISTRY>/…`. Tags change with every chart version.

| # | Image path (under the mirror base) | Tag (1.4.2) | Repointed by |
|---|-------------------------------------|-------------|--------------|
| 1 | `semarchy-release/alpine-tools` | 3.22.1 | `global.image.registry` |
| 2 | `semarchy-release/docker-billing-service` | 1.15.2 | `global.image.registry` |
| 3 | `semarchy-release/docker-dm` | 1.17.1 | `global.image.registry` |
| 4 | `semarchy-release/docker-dm-passive` | 1.17.1 | `global.image.registry` |
| 5 | `semarchy-release/docker-log-explorer` | 1.4.3-b | `global.image.registry` |
| 6 | `semarchy-release/docker-log-explorer-service` | 2.9.2 | `global.image.registry` |
| 7 | `semarchy-release/docker-secret-manager` | 1.2.0 | `global.image.registry` (≤ 1.4.0: `dm.secretManager.image`) |
| 8 | `semarchy-release/docker-site-admin` | 1.6.1-b | `global.image.registry` |
| 9 | `semarchy-release/docker-user-profile` | 1.4.3-b | `global.image.registry` |
| 10 | `semarchy-release/docker-welcome` | 1.4.12-b | `global.image.registry` |
| 11 | `semarchy-release/docker-well-known-service` | 1.6.1 | `global.image.registry` + `global.image.repository` |
| 12 | `semarchy-release/iam_kc_extensions` | 3.10.1 | `global.image.registry` |
| 13 | `semarchy-release/iam_kc_themes` | 3.10.1 | `global.image.registry` |
| 14 | `semarchy-release/sdp-infra-tools` | 1.9.0 | `global.image.registry` + `global.image.repository` |
| 15 | `semarchy-release/mirror/adorsys/keycloak-config-cli` | 6.5.0-26 | `global.image.registry` |
| 16 | `semarchy-release/mirror/ubi9/openjdk-21-runtime` *(only with `global.caCert.enabled`)* | 1.23 | `global.image.registry` |
| 17 | `semarchy-release/mirror/envoyproxy/envoy` | distroless-v1.37.0 | `global.image.registry` |
| 18 | `semarchy-release/mirror/fluent/fluent-bit` | 3.2.10 | `global.image.registry` |
| 19 | `semarchy-release/mirror/keycloak/keycloak` | 26.7.5 | `global.image.registry` |
| 20 | `semarchy-release/mirror/stakater/reloader` | v1.4.8 | **`reloader.image.repository`** |

Chart 1.3.0 used `semarchy-release/mirror/eclipse-temurin` in place of #16.

---

## Upgrading to a new chart version

1. Re-run **Step 2** with the new `--chart-version` (add `--skip-existing` to
   avoid re-copying unchanged images).
2. Diff the new `--images-out` file against the previous one to see added,
   removed or renamed images.
3. If the script's self-check fails, a new image is hard-coded to the source
   registry (add an override) or an override is no longer needed (remove it).
   Also check the release notes.
4. Update `--version` in **Step 5** and re-run the verification.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `unauthorized` during pull | Not logged in to the source registry — redo **Step 1**. |
| `skopeo` auth failures | The auth file passed to skopeo doesn't hold both logins. Ensure both `helm registry login` calls ran, or pass `--authfile <path>` explicitly. |
| Pods stuck `ImagePullBackOff` | Pull secret missing/misnamed, or `global.image.registry` doesn't match `--target-repo`. Check **Step 3** and **Step 4**. |
| Image path contains the registry twice | A full-path override on a value the chart already prefixes (typically `dm.secretManager.image.repository` on 1.4.1+). Remove the override. |
| An image still points at `registry.na.semarchy.net` | A newly hard-coded image. The script's self-check names it; add a matching per-component `image.repository` override. |
| `make-truststore` init container fails to pull | `global.caCert.enabled=true` but `mirror/ubi9/openjdk-21-runtime` was not mirrored (e.g. script run with a values file disabling caCert). |
| `license.body must be set` on render | Provide a real (or any non-placeholder) license value. |

---

## Automating with CI (optional)

[`azure-pipelines.yml`](azure-pipelines.yml) performs the login and mirror on
demand, takes the chart version and target repo as run-time parameters, pulls
registry credentials from a secret variable group, and publishes the image list
as a pipeline artifact. See the comments at the top of the file for setup.
