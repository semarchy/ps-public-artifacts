#!/usr/bin/env bash
#
# mirror-semarchy-chart.sh
# -----------------------------------------------------------------------------
# Mirror the Semarchy Data Platform Helm chart AND every container image it
# references from the Semarchy source registry into a local Artifactory (or any
# OCI-compliant) target registry.
#
# Validated against chart versions: 1.3.0, 1.4.2
#
# What it does:
#   1. `helm pull` the parent chart from the source OCI registry. The parent
#      chart bundles all sub-charts inside its .tgz, so a single push mirrors
#      the whole chart tree.
#   2. `helm template` the pulled chart (all components enabled) and extract
#      every `image:` reference. This is the authoritative image list -- values.yaml
#      alone does NOT expose image tags nor the third-party/sub-chart images.
#   3. `skopeo copy` each image from the source registry to the target registry,
#      preserving its repository path (registry host is swapped for the target).
#   4. `helm push` the chart .tgz to the target OCI registry.
#   5. Self-check: re-render the chart pointed at the target registry and fail
#      if any image still references the source registry (e.g. a newly
#      hard-coded image) or was not mirrored.
#
# Prerequisites (assumed done before running, per pipeline design):
#   * `helm registry login <source>`  (registry.na.semarchy.net)
#   * `helm registry login <target>`  (your Artifactory)
#   Both logins are stored in the Helm registry config, which this script hands
#   to skopeo via --authfile so images authenticate with the same credentials.
#
# Required tooling on the runner: helm (>=3.8, OCI support), skopeo.
#
# -----------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C   # stable sort order for comm

# ------------------------------------------------------------------ defaults --
SOURCE_REGISTRY="registry.na.semarchy.net"
SOURCE_CHART_REPO=""                 # OCI repo (dir) holding the chart; default derived below
CHART_NAME="semarchy-data-platform"
CHART_VERSION=""                     # REQUIRED (-v)
TARGET_REPO=""                       # REQUIRED (-t) e.g. artifactory.corp.com/semarchy
CHART_TARGET_REPO=""                 # OCI repo to push the chart into; default derived from TARGET_REPO
VALUES_FILES=()                      # optional -f values overlays for the render
EXTRA_SETS=()                        # optional --set passthroughs for the render
AUTHFILE="${HELM_REGISTRY_CONFIG:-$HOME/.config/helm/registry/config.json}"
WORK_DIR=""                          # default: mktemp
IMAGES_OUT=""                        # optional: copy the discovered image list here
DRY_RUN="false"
KEEP_WORKDIR="false"
SKIP_EXISTING="false"
SKIP_VERIFY="false"

# Components that are optional/disabled by default. Enabling them makes the
# render a SUPERSET so we mirror every image that could ever be deployed.
# Override by passing your real deployment values with -f.
DEFAULT_SETS=(
  "well-known-service.enabled=true"
  "xdg.enabled=true"
  "global.caCert.enabled=true"          # pulls in the CA truststore builder image (1.4.x: mirror/ubi9/openjdk-21-runtime)
  "global.smartReload.reloader.install=true"
  "global.domain=mirror.example.com"        # harmless value so required() templates render
  "global.license.body=mirror-render-only"  # non-placeholder so the license template renders
)

# Image overrides that the chart cannot derive from global.image.registry.
# Used by the self-check (step 5) to simulate a customer values overlay.
# As of chart 1.4.2 only Reloader is hard-coded. dm.secretManager was fixed in
# 1.4.1 and must NOT be overridden with a full path any more.
hardcoded_override_sets() {
  printf '%s\n' "reloader.image.repository=${TARGET_REPO}/semarchy-release/mirror/stakater/reloader"
}

# --------------------------------------------------------------------- utils --
c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_blu=$'\033[36m'
log()  { printf '%s[mirror]%s %s\n' "$c_blu" "$c_reset" "$*"; }
ok()   { printf '%s[ ok  ]%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s[warn ]%s %s\n' "$c_yel" "$c_reset" "$*" >&2; }
err()  { printf '%s[error]%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<EOF
Mirror the Semarchy Data Platform Helm chart and all its images to a target registry.

Usage:
  $(basename "$0") -t <target-repo> -v <chart-version> [options]

Required:
  -t, --target-repo <repo>     Target registry base for images, e.g.
                               artifactory.corp.com/semarchy
                               (images land under <repo>/<original-path>)
  -v, --chart-version <ver>    Chart version to mirror, e.g. 1.4.2

Options:
  -s, --source-registry <host> Source image registry (default: $SOURCE_REGISTRY)
      --source-chart-repo <oci> OCI repo holding the chart
                               (default: oci://<source-registry>/semarchy)
      --chart-name <name>      Chart name (default: $CHART_NAME)
      --chart-target-repo <oci> OCI repo to push the chart into
                               (default: oci://<target-repo>)
  -f, --values <file>          Extra values file for the render (repeatable).
                               Pass your real deployment values for an exact match.
      --set <k=v>              Extra --set for the render (repeatable)
      --authfile <path>        Docker/Helm auth file for skopeo
                               (default: $AUTHFILE)
      --work-dir <dir>         Working directory (default: a mktemp dir)
      --images-out <file>      Write the discovered image list to <file>
                               (useful as an audit trail / for change review)
      --skip-existing          Skip images already present in the target
                               (checked with 'skopeo inspect'); faster re-runs
      --no-verify              Skip the post-mirror self-check (step 5)
      --keep                   Keep the working directory on exit
      --dry-run                Print actions without copying/pushing
                               (the chart is still pulled to discover images)
  -h, --help                   Show this help

Prerequisites: run \`helm registry login\` for BOTH the source and target
registries before invoking this script. Requires: helm, skopeo.
EOF
}

# ------------------------------------------------------------------ arg parse --
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target-repo)       TARGET_REPO="$2"; shift 2;;
    -v|--chart-version)     CHART_VERSION="$2"; shift 2;;
    -s|--source-registry)   SOURCE_REGISTRY="$2"; shift 2;;
    --source-chart-repo)    SOURCE_CHART_REPO="$2"; shift 2;;
    --chart-name)           CHART_NAME="$2"; shift 2;;
    --chart-target-repo)    CHART_TARGET_REPO="$2"; shift 2;;
    -f|--values)            VALUES_FILES+=("$2"); shift 2;;
    --set)                  EXTRA_SETS+=("$2"); shift 2;;
    --authfile)             AUTHFILE="$2"; shift 2;;
    --work-dir)             WORK_DIR="$2"; shift 2;;
    --images-out)           IMAGES_OUT="$2"; shift 2;;
    --skip-existing)        SKIP_EXISTING="true"; shift;;
    --no-verify)            SKIP_VERIFY="true"; shift;;
    --keep)                 KEEP_WORKDIR="true"; shift;;
    --dry-run)              DRY_RUN="true"; shift;;
    -h|--help)              usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)";;
  esac
done

[[ -n "$TARGET_REPO"   ]] || { usage; die "Missing required --target-repo"; }
[[ -n "$CHART_VERSION" ]] || { usage; die "Missing required --chart-version"; }

# normalize first, then derive defaults that depend on other args
TARGET_REPO="${TARGET_REPO%/}"
SOURCE_CHART_REPO="${SOURCE_CHART_REPO:-oci://${SOURCE_REGISTRY}/semarchy}"
CHART_TARGET_REPO="${CHART_TARGET_REPO:-oci://${TARGET_REPO}}"

# ------------------------------------------------------------- dependency chk --
for bin in helm skopeo; do
  command -v "$bin" >/dev/null 2>&1 || die "Required tool not found on PATH: $bin"
done

AUTH_ARGS=()
if [[ -f "$AUTHFILE" ]]; then
  AUTH_ARGS=(--authfile "$AUTHFILE")
  log "Using auth file for skopeo: $AUTHFILE"
else
  warn "Auth file not found at '$AUTHFILE'. skopeo will fall back to its default"
  warn "credential locations. Ensure the runner is logged in, or pass --authfile."
fi

# ------------------------------------------------------------------- workdir ---
CLEANUP_WORKDIR="false"
if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mirror-semarchy.XXXXXX")"
  CLEANUP_WORKDIR="true"
else
  mkdir -p "$WORK_DIR"
fi
cleanup() {
  if [[ "$CLEANUP_WORKDIR" == "true" && "$KEEP_WORKDIR" != "true" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

log "Chart      : ${CHART_NAME} ${CHART_VERSION}"
log "Source     : ${SOURCE_CHART_REPO}/${CHART_NAME}  (images from ${SOURCE_REGISTRY})"
log "Target repo: ${TARGET_REPO}   (chart -> ${CHART_TARGET_REPO})"
log "Work dir   : ${WORK_DIR}"
[[ "$DRY_RUN" == "true" ]] && warn "DRY-RUN: no image will be copied and the chart will not be pushed."

# Extract every image reference from a rendered manifest on stdin.
# Handles name:tag and name@sha256:digest, strips quotes, ignores unrendered templates.
extract_images() {
  grep -E '^[[:space:]]*-?[[:space:]]*image:[[:space:]]' \
    | sed -E 's/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*//; s/^["'\'']//; s/["'\''][[:space:]]*$//; s/[[:space:]]+$//' \
    | grep -vE '(\{\{|^$)' \
    | sort -u || true
}

# ================================================================ 1. pull =====
CHART_TGZ="${WORK_DIR}/${CHART_NAME}-${CHART_VERSION}.tgz"
log "Pulling chart from ${SOURCE_CHART_REPO}/${CHART_NAME} ..."
if [[ "$DRY_RUN" == "true" ]]; then
  echo "  helm pull ${SOURCE_CHART_REPO}/${CHART_NAME} --version ${CHART_VERSION} -d ${WORK_DIR}"
  # For dry-run image discovery we still need a chart; pulling is read-only.
  helm pull "${SOURCE_CHART_REPO}/${CHART_NAME}" --version "${CHART_VERSION}" -d "${WORK_DIR}" \
    || warn "Dry-run: could not pull chart; image discovery will be skipped."
else
  helm pull "${SOURCE_CHART_REPO}/${CHART_NAME}" --version "${CHART_VERSION}" -d "${WORK_DIR}"
  ok "Pulled $(basename "$CHART_TGZ")"
fi

# ================================================= 2. render & discover images =
IMAGES_FILE="${WORK_DIR}/images.txt"
: > "$IMAGES_FILE"

render_args=()
if [[ -f "$CHART_TGZ" ]]; then
  log "Rendering chart to discover images (helm template) ..."
  render_args=("$CHART_TGZ")
  for s in "${DEFAULT_SETS[@]}"; do render_args+=(--set "$s"); done
  for s in "${EXTRA_SETS[@]+"${EXTRA_SETS[@]}"}"; do render_args+=(--set "$s"); done
  for f in "${VALUES_FILES[@]+"${VALUES_FILES[@]}"}"; do render_args+=(-f "$f"); done

  helm template "${render_args[@]}" 2>"${WORK_DIR}/helm-template.err" \
    | extract_images > "$IMAGES_FILE"

  if [[ ! -s "$IMAGES_FILE" ]]; then
    err "helm template produced no images. Render stderr:"
    cat "${WORK_DIR}/helm-template.err" >&2 || true
    die "Aborting: nothing to mirror."
  fi
  ok "Discovered $(wc -l < "$IMAGES_FILE") unique image(s)."
  sed 's/^/    /' "$IMAGES_FILE"

  # Flag images that do not come from the source registry (would need a
  # different set of credentials, and are usually a sign of a values override).
  if grep -v "^${SOURCE_REGISTRY}/" "$IMAGES_FILE" > "${WORK_DIR}/foreign.txt"; then
    warn "These images are NOT served by ${SOURCE_REGISTRY}:"
    sed 's/^/    /' "${WORK_DIR}/foreign.txt" >&2
  fi

  if [[ -n "$IMAGES_OUT" ]]; then
    cp "$IMAGES_FILE" "$IMAGES_OUT"
    ok "Image list written to ${IMAGES_OUT}"
  fi
else
  warn "No chart tarball available; skipping image discovery."
fi

# =============================================== rehome helper (host swap) =====
# Map a source image ref to its target ref: drop the registry host and re-prefix
# with TARGET_REPO, preserving the rest of the repository path and the tag/digest.
rehome() {
  local img="$1" first path
  first="${img%%/*}"
  if [[ "$first" == *.* || "$first" == *:* || "$first" == "localhost" ]]; then
    path="${img#*/}"        # first segment is a registry host -> drop it
  else
    path="$img"             # docker-hub style (e.g. adorsys/keycloak-config-cli) -> keep
  fi
  printf '%s/%s' "$TARGET_REPO" "$path"
}

# ================================================== 3. copy images to target ==
declare -a FAILED_IMAGES=()
COPIED=0
SKIPPED=0
if [[ -s "$IMAGES_FILE" ]]; then
  log "Mirroring images to ${TARGET_REPO} ..."
  while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    dst="$(rehome "$img")"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  skopeo copy --all docker://${img} docker://${dst}"
      COPIED=$((COPIED+1))
      continue
    fi
    if [[ "$SKIP_EXISTING" == "true" ]] \
       && skopeo inspect --raw "${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}" "docker://${dst}" >/dev/null 2>&1; then
      ok "already present, skipped: ${dst}"
      SKIPPED=$((SKIPPED+1))
      continue
    fi
    log "copy: ${img}"
    log "  -> ${dst}"
    if skopeo copy --all "${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}" "docker://${img}" "docker://${dst}"; then
      ok "mirrored ${dst}"
      COPIED=$((COPIED+1))
    else
      err "FAILED to copy ${img}"
      FAILED_IMAGES+=("$img")
    fi
  done < "$IMAGES_FILE"
fi

# ==================================================== 4. push chart to target =
if [[ -f "$CHART_TGZ" ]]; then
  log "Pushing chart to ${CHART_TARGET_REPO} ..."
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  helm push ${CHART_TGZ} ${CHART_TARGET_REPO}"
  else
    if helm push "$CHART_TGZ" "$CHART_TARGET_REPO"; then
      ok "Chart pushed: ${CHART_TARGET_REPO}/${CHART_NAME}:${CHART_VERSION}"
    else
      die "Chart push failed."
    fi
  fi
fi

# ================================================= 5. self-check (offline) =====
# Re-render the same chart as a customer would deploy it from the mirror
# (global.image.registry + known hard-coded overrides) and check that:
#   a) no image still points at the source registry, and
#   b) every rendered image is one we mirrored.
VERIFY_STATUS="skipped"
if [[ "$SKIP_VERIFY" != "true" && -f "$CHART_TGZ" && -s "$IMAGES_FILE" ]]; then
  log "Self-check: rendering chart against ${TARGET_REPO} ..."
  verify_args=("${render_args[@]}" --set "global.image.registry=${TARGET_REPO}")
  while IFS= read -r s; do verify_args+=(--set "$s"); done < <(hardcoded_override_sets)

  helm template "${verify_args[@]}" 2>"${WORK_DIR}/helm-verify.err" \
    | extract_images > "${WORK_DIR}/images-target.txt"

  while IFS= read -r img; do rehome "$img"; echo; done < "$IMAGES_FILE" \
    | sort -u > "${WORK_DIR}/images-expected.txt"

  VERIFY_STATUS="passed"
  if grep -F "${SOURCE_REGISTRY}/" "${WORK_DIR}/images-target.txt" > "${WORK_DIR}/leftover.txt"; then
    err "Images still pointing at ${SOURCE_REGISTRY} with only global.image.registry set:"
    sed 's/^/    /' "${WORK_DIR}/leftover.txt" >&2
    err "-> a per-component image.repository override is needed in your values overlay."
    VERIFY_STATUS="failed"
  fi
  if comm -23 "${WORK_DIR}/images-target.txt" "${WORK_DIR}/images-expected.txt" \
       | grep -vF "${SOURCE_REGISTRY}/" > "${WORK_DIR}/unmirrored.txt"; then
    err "Rendered images that were NOT mirrored (check for double prefixes or path changes):"
    sed 's/^/    /' "${WORK_DIR}/unmirrored.txt" >&2
    VERIFY_STATUS="failed"
  fi
  [[ "$VERIFY_STATUS" == "passed" ]] && ok "Self-check passed: every rendered image resolves to the mirror."
fi

# ------------------------------------------------------------------- summary ---
echo
log "==================== SUMMARY ===================="
log "Chart mirrored : ${CHART_TARGET_REPO}/${CHART_NAME}:${CHART_VERSION}"
log "Images copied  : ${COPIED}"
[[ "$SKIP_EXISTING" == "true" ]] && log "Images skipped : ${SKIPPED} (already in target)"
log "Self-check     : ${VERIFY_STATUS}"
if [[ ${#FAILED_IMAGES[@]} -gt 0 ]]; then
  err "Images failed  : ${#FAILED_IMAGES[@]}"
  for i in "${FAILED_IMAGES[@]}"; do err "  - $i"; done
  die "Completed with image copy failures."
fi
[[ "$VERIFY_STATUS" == "failed" ]] && die "Completed, but the self-check failed (see above)."
ok "All done."
