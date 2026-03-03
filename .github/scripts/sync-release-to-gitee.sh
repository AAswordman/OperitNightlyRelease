#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-latest}"
TARGET_TAG="${2:-${SYNC_TAG:-}}"

# Gitee variable naming has restrictions; support alias variables in CI.
if [[ -z "${GITEE_TOKEN:-}" ]]; then
  if [[ -n "${REL_SYNC_TOKEN:-}" ]]; then
    GITEE_TOKEN="${REL_SYNC_TOKEN}"
  elif [[ -n "${SYNC_GITEE_TOKEN:-}" ]]; then
    GITEE_TOKEN="${SYNC_GITEE_TOKEN}"
  elif [[ -n "${SYSTEM_FILE_PARAMETER_CACHE:-}" && -f "${SYSTEM_FILE_PARAMETER_CACHE}" ]] && command -v jq >/dev/null 2>&1; then
    GITEE_TOKEN="$(
      jq -r '.. | objects | (.GITEE_TOKEN? // .REL_SYNC_TOKEN? // empty) | if type=="string" then . elif type=="array" then (.[0] // empty) else empty end' "${SYSTEM_FILE_PARAMETER_CACHE}" \
      | awk 'NF { print; exit }'
    )"
  fi
fi
export GITEE_TOKEN

required_env=(
  GITEE_OWNER
  GITEE_REPO
  GITEE_TOKEN
)

for key in "${required_env[@]}"; do
  if [[ -z "${!key:-}" ]]; then
    echo "Missing required environment variable: ${key}" >&2
    exit 1
  fi
done

SOURCE_GITHUB_REPOSITORY="${SOURCE_GITHUB_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
if [[ -z "${SOURCE_GITHUB_REPOSITORY}" ]]; then
  echo "Missing SOURCE_GITHUB_REPOSITORY (or GITHUB_REPOSITORY)." >&2
  echo "Expected format: owner/repo" >&2
  exit 1
fi

API_BASE="https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}"
GH_API_BASE="https://api.github.com/repos/${SOURCE_GITHUB_REPOSITORY}"
GH_RELEASE_MIRROR_PREFIXES_RAW="${GH_RELEASE_MIRROR_PREFIXES:-}"
SYNC_ASSET_CONCURRENCY="${SYNC_ASSET_CONCURRENCY:-4}"

if ! [[ "${SYNC_ASSET_CONCURRENCY}" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYNC_ASSET_CONCURRENCY must be a positive integer." >&2
  exit 1
fi

if [[ -n "${GH_RELEASE_MIRROR_PREFIXES_RAW}" ]]; then
  IFS=',;' read -r -a GH_RELEASE_MIRROR_PREFIX_LIST <<<"${GH_RELEASE_MIRROR_PREFIXES_RAW}"
else
  GH_RELEASE_MIRROR_PREFIX_LIST=(
    "https://ghfast.top/"
    "https://flash.aaswordsman.org/"
  )
fi

echo "Source GitHub repository: ${SOURCE_GITHUB_REPOSITORY}"
echo "Target Gitee repository: ${GITEE_OWNER}/${GITEE_REPO}"
if [[ "${#GH_RELEASE_MIRROR_PREFIX_LIST[@]}" -gt 0 ]]; then
  echo "GitHub asset mirrors: ${GH_RELEASE_MIRROR_PREFIX_LIST[*]}"
fi
echo "Asset sync concurrency: ${SYNC_ASSET_CONCURRENCY}"

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

gh_api_get_code() {
  local url="$1"
  local out="$2"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -sS -L -o "${out}" -w "%{http_code}" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${url}"
  else
    curl -sS -L -o "${out}" -w "%{http_code}" \
      -H "Accept: application/vnd.github+json" \
      "${url}"
  fi
}

gh_api_get_json() {
  local url="$1"
  local tmp code

  tmp="$(mktemp)"
  code="$(gh_api_get_code "${url}" "${tmp}")"
  if [[ "${code}" != "200" ]]; then
    echo "GitHub API request failed: ${url} (HTTP ${code})" >&2
    cat "${tmp}" >&2
    rm -f "${tmp}"
    exit 1
  fi
  cat "${tmp}"
  rm -f "${tmp}"
}

gh_download_asset() {
  local url="$1"
  local out="$2"
  local attempt=0
  local download_url

  while IFS= read -r download_url; do
    [[ -z "${download_url}" ]] && continue
    attempt=$((attempt + 1))
    echo "Download attempt ${attempt}: ${download_url}"

    if gh_download_asset_once "${download_url}" "${out}"; then
      return 0
    fi

    echo "Download attempt ${attempt} failed"
  done < <(build_asset_download_candidates "${url}")

  echo "All download attempts failed: ${url}" >&2
  return 1
}

gh_download_asset_once() {
  local url="$1"
  local out="$2"

  if [[ -n "${GITHUB_TOKEN:-}" ]] && [[ "${url}" == https://github.com/* || "${url}" == https://api.github.com/* || "${url}" == https://objects.githubusercontent.com/* || "${url}" == https://*.githubusercontent.com/* ]]; then
    curl -fsSL --retry 4 --retry-all-errors --retry-delay 2 \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/octet-stream" \
      -L "${url}" \
      -o "${out}"
  else
    curl -fsSL --retry 4 --retry-all-errors --retry-delay 2 \
      -H "Accept: application/octet-stream" \
      -L "${url}" \
      -o "${out}"
  fi
}

build_asset_download_candidates() {
  local original_url="$1"
  local prefix
  local mirror_url

  if [[ "${original_url}" == https://github.com/*/releases/download/* ]]; then
    for prefix in "${GH_RELEASE_MIRROR_PREFIX_LIST[@]}"; do
      prefix="${prefix//[[:space:]]/}"
      [[ -z "${prefix}" ]] && continue
      if [[ "${prefix}" != */ ]]; then
        prefix="${prefix}/"
      fi
      mirror_url="${prefix}${original_url}"
      printf '%s\n' "${mirror_url}"
    done
  fi

  printf '%s\n' "${original_url}"
}

gitee_release_id_by_tag() {
  local tag="$1"
  local tag_q tmp code rid
  tag_q="$(urlencode "${tag}")"
  tmp="$(mktemp)"
  code="$(curl -sS -o "${tmp}" -w "%{http_code}" "${API_BASE}/releases/tags/${tag_q}?access_token=${GITEE_TOKEN}")"
  if [[ "${code}" == "200" ]]; then
    rid="$(jq -r '.id // empty' "${tmp}")"
    if [[ -n "${rid}" && "${rid}" != "null" ]]; then
      echo "${rid}"
      rm -f "${tmp}"
      return 0
    fi
  fi
  rm -f "${tmp}"
  return 1
}

sync_one_asset() {
  local release_id="$1"
  local asset_name="$2"
  local asset_url="$3"
  local tmp_file

  tmp_file="$(mktemp)"
  echo "Downloading GitHub asset: ${asset_name}"
  if ! gh_download_asset "${asset_url}" "${tmp_file}"; then
    rm -f "${tmp_file}"
    echo "Failed to download asset: ${asset_name}" >&2
    return 1
  fi

  echo "Uploading asset to Gitee: ${asset_name}"
  if ! curl -fsS -X POST "${API_BASE}/releases/${release_id}/attach_files" \
    --form "access_token=${GITEE_TOKEN}" \
    --form "file=@${tmp_file};filename=${asset_name}" >/dev/null; then
    rm -f "${tmp_file}"
    echo "Failed to upload asset: ${asset_name}" >&2
    return 1
  fi

  rm -f "${tmp_file}"
  return 0
}

sync_release_assets() {
  local release_id="$1"
  local release_json="$2"
  local tmp_assets supports_wait_n running_jobs failed
  local -a pids

  supports_wait_n=0
  running_jobs=0
  failed=0
  pids=()
  if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
    supports_wait_n=1
  fi

  tmp_assets="$(mktemp)"
  curl -sS "${API_BASE}/releases/${release_id}/attach_files?access_token=${GITEE_TOKEN}" > "${tmp_assets}"

  while IFS= read -r asset; do
    [[ -z "${asset}" ]] && continue
    local asset_name asset_url
    asset_name="$(jq -r '.name // empty' <<<"${asset}")"
    asset_url="$(jq -r '.browser_download_url // empty' <<<"${asset}")"

    if [[ -z "${asset_name}" || -z "${asset_url}" ]]; then
      continue
    fi

    if jq -e --arg n "${asset_name}" 'if type=="array" then any(.[]; .name == $n) else false end' "${tmp_assets}" >/dev/null; then
      echo "Asset already exists on Gitee, skip: ${asset_name}"
      continue
    fi

    sync_one_asset "${release_id}" "${asset_name}" "${asset_url}" &
    pids+=("$!")
    running_jobs=$((running_jobs + 1))

    if (( running_jobs >= SYNC_ASSET_CONCURRENCY )); then
      if (( supports_wait_n == 1 )); then
        if ! wait -n; then
          failed=1
        fi
      else
        local first_pid
        first_pid="${pids[0]}"
        pids=("${pids[@]:1}")
        if ! wait "${first_pid}"; then
          failed=1
        fi
      fi
      running_jobs=$((running_jobs - 1))
    fi
  done < <(jq -c '.assets[]?' <<<"${release_json}")

  if (( supports_wait_n == 1 )); then
    while (( running_jobs > 0 )); do
      if ! wait -n; then
        failed=1
      fi
      running_jobs=$((running_jobs - 1))
    done
  else
    local pid
    for pid in "${pids[@]}"; do
      if ! wait "${pid}"; then
        failed=1
      fi
    done
  fi

  rm -f "${tmp_assets}"
  if (( failed != 0 )); then
    echo "One or more asset sync jobs failed." >&2
    exit 1
  fi
}

upsert_gitee_release_from_json() {
  local release_json="$1"
  local tag name body prerelease target rid tmp_upsert

  tag="$(jq -r '.tag_name // empty' <<<"${release_json}")"
  if [[ -z "${tag}" || "${tag}" == "null" ]]; then
    echo "Skip release without tag_name"
    return 0
  fi

  name="$(jq -r '.name // empty' <<<"${release_json}")"
  if [[ -z "${name}" || "${name}" == "null" ]]; then
    name="${tag}"
  fi
  body="$(jq -r '.body // ""' <<<"${release_json}")"
  prerelease="$(jq -r '.prerelease // false' <<<"${release_json}")"
  target="$(jq -r '.target_commitish // "main"' <<<"${release_json}")"

  tmp_upsert="$(mktemp)"
  if rid="$(gitee_release_id_by_tag "${tag}")"; then
    echo "Updating Gitee release tag=${tag} id=${rid}"
    curl -sS -X PATCH "${API_BASE}/releases/${rid}" \
      --form "access_token=${GITEE_TOKEN}" \
      --form "tag_name=${tag}" \
      --form "name=${name}" \
      --form-string "body=${body}" \
      --form "prerelease=${prerelease}" \
      --form "target_commitish=${target}" > "${tmp_upsert}"
  else
    echo "Creating Gitee release tag=${tag}"
    curl -sS -X POST "${API_BASE}/releases" \
      --form "access_token=${GITEE_TOKEN}" \
      --form "tag_name=${tag}" \
      --form "name=${name}" \
      --form-string "body=${body}" \
      --form "prerelease=${prerelease}" \
      --form "target_commitish=${target}" > "${tmp_upsert}"
  fi

  rid="$(jq -r '.id // empty' "${tmp_upsert}")"
  if [[ -z "${rid}" || "${rid}" == "null" ]]; then
    echo "Failed to upsert Gitee release for tag=${tag}" >&2
    cat "${tmp_upsert}" >&2
    rm -f "${tmp_upsert}"
    exit 1
  fi
  rm -f "${tmp_upsert}"

  sync_release_assets "${rid}" "${release_json}"
}

sync_release_by_tag() {
  local tag="$1"
  local tag_q tmp code release_json

  tag_q="$(urlencode "${tag}")"
  tmp="$(mktemp)"
  code="$(gh_api_get_code "${GH_API_BASE}/releases/tags/${tag_q}" "${tmp}")"
  if [[ "${code}" == "404" ]]; then
    echo "GitHub release not found for tag=${tag}, skip"
    rm -f "${tmp}"
    return 0
  fi
  if [[ "${code}" != "200" ]]; then
    echo "Failed to query GitHub release by tag=${tag} (HTTP ${code})" >&2
    cat "${tmp}" >&2
    rm -f "${tmp}"
    exit 1
  fi
  release_json="$(cat "${tmp}")"
  rm -f "${tmp}"
  upsert_gitee_release_from_json "${release_json}"
}

sync_latest_release() {
  local tmp code release_json

  tmp="$(mktemp)"
  code="$(gh_api_get_code "${GH_API_BASE}/releases/latest" "${tmp}")"
  if [[ "${code}" == "404" ]]; then
    echo "No GitHub release found, skip"
    rm -f "${tmp}"
    return 0
  fi
  if [[ "${code}" != "200" ]]; then
    echo "Failed to query latest GitHub release (HTTP ${code})" >&2
    cat "${tmp}" >&2
    rm -f "${tmp}"
    exit 1
  fi
  release_json="$(cat "${tmp}")"
  rm -f "${tmp}"
  upsert_gitee_release_from_json "${release_json}"
}

sync_all_releases() {
  local page response count
  page=1
  while true; do
    response="$(gh_api_get_json "${GH_API_BASE}/releases?per_page=100&page=${page}")"
    count="$(jq 'length' <<<"${response}")"
    if [[ "${count}" -eq 0 ]]; then
      break
    fi

    while IFS= read -r release_json; do
      [[ -z "${release_json}" ]] && continue
      upsert_gitee_release_from_json "${release_json}"
    done < <(jq -c '.[] | select(.draft == false)' <<<"${response}")

    page=$((page + 1))
  done
}

case "${MODE}" in
  latest)
    sync_latest_release
    ;;
  tag)
    if [[ -z "${TARGET_TAG}" ]]; then
      echo "Missing tag. Usage: sync-release-to-gitee.sh tag <tag>" >&2
      exit 1
    fi
    sync_release_by_tag "${TARGET_TAG}"
    ;;
  all)
    sync_all_releases
    ;;
  *)
    echo "Unsupported mode: ${MODE}. Use 'latest', 'tag', or 'all'." >&2
    exit 1
    ;;
esac
