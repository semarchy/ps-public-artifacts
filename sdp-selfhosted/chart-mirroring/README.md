# Semarchy Data Platform — Air-Gapped / Local Registry Mirroring

This guide explains how to mirror the **Semarchy Data Platform** Helm chart and
all of its container images from the Semarchy registry
(`registry.na.semarchy.net`) into your **own local registry** (Artifactory, ACR,
Harbor, Nexus, …), and how to deploy the platform so that every pull comes from
your local registry only.

It covers two deliverables:

| File | Purpose |
|------|---------|
| [`mirror-semarchy-chart.sh`](mirror-semarchy-chart.sh) | Mirrors the chart **and** all images to your registry |
| [`values.customer-mirrored-images.yaml`](values.customer-mirrored-images.yaml) | Deployment values that repoint every image to your registry |

---

## Why this is needed

The Semarchy chart pulls ~20 container images at deploy time — Semarchy
application images **and** third-party images (Keycloak, Envoy, Fluent Bit,
Reloader, etc.). In a restricted or air-gapped environment your cluster cannot
reach `registry.na.semarchy.net`, so both the chart and every image must first
be copied into a registry your cluster *can* reach.

Two steps make that work:

1. **Mirror** — copy the chart + images into your registry (`mirror-semarchy-chart.sh`).
2. **Repoint** — tell the chart to pull from your registry (`values.customer-mirrored-images.yaml`).

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

The script assumes you are already logged in to **both** registries before it
runs. Both logins are written to the Helm registry config, which the script
then hands to `skopeo`.

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
  --chart-version 1.3.0
```

`--target-repo` is the **base** path in your registry under which everything is
stored. Images keep their original path underneath it, e.g.:

```
registry.na.semarchy.net/semarchy-release/docker-dm:1.12.1
  ->  artifactory.company.com/semarchy/semarchy-release/docker-dm:1.12.1
```

### What the script does

1. `helm pull` the chart (the parent `.tgz` **bundles all sub-charts**, so one
   push mirrors the whole chart tree).
2. `helm template` the chart with all components enabled and extract every
   `image:` reference — this is the authoritative image list. 
3. `skopeo copy --all` each image (all architectures) to your registry.
4. `helm push` the chart `.tgz` to your registry.

### Common options

| Flag | Default | Description |
|------|---------|-------------|
| `-t, --target-repo` | *(required)* | Target registry base, e.g. `artifactory.company.com/semarchy` |
| `-v, --chart-version` | *(required)* | Chart version to mirror, e.g. `1.3.0` |
| `-s, --source-registry` | `registry.na.semarchy.net` | Source image registry |
| `--source-chart-repo` | `oci://<source>/semarchy` | OCI repo holding the chart |
| `--chart-target-repo` | `oci://<target-repo>` | Where to push the chart |
| `-f, --values` | — | Extra values file for the render (repeatable). Pass your real deployment values for an exact match |
| `--authfile` | Helm registry config | Auth file handed to skopeo |
| `--dry-run` | off | Print all actions without pulling/copying/pushing |

> **Tip:** run once with `--dry-run` to review the full plan (chart pull, every
> image copy, chart push) before mirroring for real.

---

## Step 3 — Configure the deployment values

Open [`values.customer-mirrored-images.yaml`](values.customer-mirrored-images.yaml)
and replace the placeholders. The mirroring is driven by **three** settings:

```yaml
global:
  image:
    registry: '<YOUR_LOCAL_REGISTRY>'   # <-- same value as --target-repo above
    repository: 'semarchy-release'      # keep as-is (the mirror preserves this path)

dm:
  secretManager:
    image:
      repository: '<YOUR_LOCAL_REGISTRY>/semarchy-release/docker-secret-manager'

reloader:
  image:
    repository: '<YOUR_LOCAL_REGISTRY>/semarchy-release/mirror/stakater/reloader'
```

- `global.image.registry` repoints **18 of the 20** images by itself.
- `dm.secretManager` and `reloader` **hard-code** the source registry in the
  chart and do not honor `global.image.registry`, so they are overridden
  explicitly. These two are the only per-component image overrides required.

Set `global.image.registry` to the **same base** you passed as `--target-repo`
in Step 2 so the paths line up.

Also replace the remaining starter placeholders: `<YOUR_GLOBAL_DOMAIN>`,
`<YOUR_LICENSE_KEY_HERE>`, `<YOUR_INGRESS_CLASS_NAME>`, the TLS secret names, the
admin user fields, and `<YOUR_LOCAL_REGISTRY_PULL_SECRET>`.

---

## Step 4 — Create the image pull secret

Pods now pull from your registry, so create a pull secret in the release
namespace and reference it (the values file already wires it via
`global.imagePullSecrets`):

```bash
kubectl create secret docker-registry local-registry \
  --docker-server=artifactory.company.com \
  --docker-username="$LOCAL_USER" \
  --docker-password="$LOCAL_KEY" \
  --namespace=semarchy
```

Use `--docker-server=<host only>` (no path). The secret **name** (`local-registry`
here) must match `global.imagePullSecrets[0].name` in the values file.

---

## Step 5 — Install the platform

```bash
helm upgrade --install sdp \
  oci://artifactory.company.com/semarchy/semarchy-data-platform \
  --version 1.3.0 \
  --namespace semarchy \
  -f values.customer-mirrored-images.yaml
```

### Verify no image points at the source registry

```bash
helm template sdp \
  oci://artifactory.company.com/semarchy/semarchy-data-platform \
  --version 1.3.0 -f values.customer-mirrored-images.yaml \
  | grep -E '^\s*-?\s*image:' | sort -u
```

Every line should reference your local registry. No occurrence of
`registry.na.semarchy.net` should remain.

---

## Reference — the mirrored images

These 20 images are copied by the script for chart **1.3.0** (tags change per
chart version). All are stored under `<YOUR_LOCAL_REGISTRY>/…`:

| # | Image path (under the mirror base) | Repointed by |
|---|-------------------------------------|--------------|
| 1 | `semarchy-release/alpine-tools` | `global.image.registry` |
| 2 | `semarchy-release/docker-billing-service` | `global.image.registry` |
| 3 | `semarchy-release/docker-dm` | `global.image.registry` |
| 4 | `semarchy-release/docker-dm-passive` | `global.image.registry` |
| 5 | `semarchy-release/docker-log-explorer` | `global.image.registry` |
| 6 | `semarchy-release/docker-log-explorer-service` | `global.image.registry` |
| 7 | `semarchy-release/docker-secret-manager` | **`dm.secretManager.image`** |
| 8 | `semarchy-release/docker-site-admin` | `global.image.registry` |
| 9 | `semarchy-release/docker-user-profile` | `global.image.registry` |
| 10 | `semarchy-release/docker-welcome` | `global.image.registry` |
| 11 | `semarchy-release/docker-well-known-service` | `global.image.registry` |
| 12 | `semarchy-release/iam_kc_extensions` | `global.image.registry` |
| 13 | `semarchy-release/iam_kc_themes` | `global.image.registry` |
| 14 | `semarchy-release/sdp-infra-tools` | `global.image.registry` |
| 15 | `semarchy-release/mirror/adorsys/keycloak-config-cli` | `global.image.registry` |
| 16 | `semarchy-release/mirror/eclipse-temurin` | `global.image.registry` |
| 17 | `semarchy-release/mirror/envoyproxy/envoy` | `global.image.registry` |
| 18 | `semarchy-release/mirror/fluent/fluent-bit` | `global.image.registry` |
| 19 | `semarchy-release/mirror/keycloak/keycloak` | `global.image.registry` |
| 20 | `semarchy-release/mirror/stakater/reloader` | **`reloader.image`** |

---

## Upgrading to a new chart version

Image tags are tied to the chart version, so for every new version:

1. Re-run **Step 2** with the new `--chart-version` to mirror the new chart and
   any new/updated images.
2. Confirm the image set with the script's `--dry-run` output — if Semarchy adds
   or renames an image, it appears here.
3. Update `--version` in **Step 5**. The values file usually needs no change
   (only registry/path are overridden, never tags).

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `unauthorized` during pull | Not logged in to the source registry — redo **Step 1**. |
| `skopeo` auth failures | The auth file passed to skopeo doesn't hold both logins. Ensure both `helm registry login` calls ran, or pass `--authfile <path>` explicitly. |
| Pods stuck `ImagePullBackOff` | Pull secret missing/misnamed, or `global.image.registry` doesn't match `--target-repo`. Check **Step 3** and **Step 4**. |
| An image still points at `registry.na.semarchy.net` | A newly added hard-coded image. Re-run the verify command in **Step 5**, then add a matching per-component `image.repository` override. |
| `license.body must be set` on render | Provide a real (or any non-placeholder) license value. |

---

## Automating with CI (optional)

An Azure DevOps pipeline that performs the login + mirror is provided in
[`azure-pipelines.yml`](azure-pipelines.yml). It runs manually, takes the chart
version and target repo as run-time parameters, and pulls registry credentials
from a secret variable group. See the comments at the top of that file for
setup.
