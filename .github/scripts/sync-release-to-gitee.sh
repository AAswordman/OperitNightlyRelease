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
SYNC_DOWNLOAD_STALL_SECONDS="${SYNC_DOWNLOAD_STALL_SECONDS:-5}"
SYNC_DOWNLOAD_CONNECT_TIMEOUT="${SYNC_DOWNLOAD_CONNECT_TIMEOUT:-8}"
SYNC_DOWNLOAD_PROBE_TIMEOUT="${SYNC_DOWNLOAD_PROBE_TIMEOUT:-8}"
SYNC_DOWNLOAD_PROBE_BYTES="${SYNC_DOWNLOAD_PROBE_BYTES:-262144}"
SYNC_DOWNLOAD_MAX_ROUNDS="${SYNC_DOWNLOAD_MAX_ROUNDS:-12}"
SYNC_PROBE_CONCURRENCY="${SYNC_PROBE_CONCURRENCY:-8}"

if ! [[ "${SYNC_ASSET_CONCURRENCY}" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYNC_ASSET_CONCURRENCY must be a positive integer." >&2
  exit 1
fi
if ! [[ "${SYNC_DOWNLOAD_STALL_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYNC_DOWNLOAD_STALL_SECONDS must be a positive integer." >&2
  exit 1
fi
if ! [[ "${SYNC_DOWNLOAD_CONNECT_TIMEOUT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYNC_DOWNLOAD_CONNECT_TIMEOUT must be a positive integer." >&2
  exit 1
fi
if ! [[ "${SYNC_DOWNLOAD_PROBE_TIMEOUT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYNC_DOWNLOAD_PROBE_TIMEOUT must be a positive integer." >&2
  exit 1
fi
if ! [[ "${SYNC_DOWNLOAD_PROBE_BYTES}" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYNC_DOWNLOAD_PROBE_BYTES must be a positive integer." >&2
  exit 1
fi
if ! [[ "${SYNC_DOWNLOAD_MAX_ROUNDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYNC_DOWNLOAD_MAX_ROUNDS must be a positive integer." >&2
  exit 1
fi
if ! [[ "${SYNC_PROBE_CONCURRENCY}" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYNC_PROBE_CONCURRENCY must be a positive integer." >&2
  exit 1
fi

if [[ -n "${GH_RELEASE_MIRROR_PREFIXES_RAW}" ]]; then
  IFS=',;' read -r -a GH_RELEASE_MIRROR_PREFIX_LIST <<<"${GH_RELEASE_MIRROR_PREFIXES_RAW}"
else
  GH_RELEASE_MIRROR_PREFIX_LIST=(
    "https://gh-proxy.com/"
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
echo "Download stall seconds: ${SYNC_DOWNLOAD_STALL_SECONDS}"
echo "Download connect timeout: ${SYNC_DOWNLOAD_CONNECT_TIMEOUT}"
echo "Download probe timeout: ${SYNC_DOWNLOAD_PROBE_TIMEOUT}"
echo "Download probe bytes: ${SYNC_DOWNLOAD_PROBE_BYTES}"
echo "Download max rounds: ${SYNC_DOWNLOAD_MAX_ROUNDS}"
echo "Probe concurrency: ${SYNC_PROBE_CONCURRENCY}"

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

is_github_direct_url() {
  local url="$1"
  [[ "${url}" == https://github.com/* || "${url}" == https://api.github.com/* || "${url}" == https://objects.githubusercontent.com/* || "${url}" == https://*.githubusercontent.com/* ]]
}

file_size_bytes() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    wc -c < "${path}" | tr -d '[:space:]'
  else
    echo "0"
  fi
}

probe_download_speed() {
  local url="$1"
  local probe_end raw code speed speed_int
  probe_end=$((SYNC_DOWNLOAD_PROBE_BYTES - 1))

  if [[ -n "${GITHUB_TOKEN:-}" ]] && is_github_direct_url "${url}"; then
    raw="$(
      curl -L -sS -o /dev/null \
        --connect-timeout "${SYNC_DOWNLOAD_PROBE_TIMEOUT}" \
        --max-time "${SYNC_DOWNLOAD_PROBE_TIMEOUT}" \
        --range "0-${probe_end}" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/octet-stream" \
        -w "%{http_code} %{speed_download}" \
        "${url}" 2>/dev/null || true
    )"
  else
    raw="$(
      curl -L -sS -o /dev/null \
        --connect-timeout "${SYNC_DOWNLOAD_PROBE_TIMEOUT}" \
        --max-time "${SYNC_DOWNLOAD_PROBE_TIMEOUT}" \
        --range "0-${probe_end}" \
        -H "Accept: application/octet-stream" \
        -w "%{http_code} %{speed_download}" \
        "${url}" 2>/dev/null || true
    )"
  fi

  code="${raw%% *}"
  speed="${raw#* }"
  if [[ "${code}" =~ ^2[0-9][0-9]$ ]]; then
    speed_int="${speed%.*}"
    if [[ -z "${speed_int}" || ! "${speed_int}" =~ ^[0-9]+$ ]]; then
      speed_int=0
    fi
    echo "${speed_int}"
  else
    echo "0"
  fi
}

gh_download_asset_once() {
  local url="$1"
  local out="$2"

  if [[ -n "${GITHUB_TOKEN:-}" ]] && is_github_direct_url "${url}"; then
    curl -fsSL \
      --connect-timeout "${SYNC_DOWNLOAD_CONNECT_TIMEOUT}" \
      --speed-time "${SYNC_DOWNLOAD_STALL_SECONDS}" \
      --speed-limit 1 \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/octet-stream" \
      -C - \
      -o "${out}" \
      -L "${url}" \
      >/dev/null
  else
    curl -fsSL \
      --connect-timeout "${SYNC_DOWNLOAD_CONNECT_TIMEOUT}" \
      --speed-time "${SYNC_DOWNLOAD_STALL_SECONDS}" \
      --speed-limit 1 \
      -H "Accept: application/octet-stream" \
      -C - \
      -o "${out}" \
      -L "${url}" \
      >/dev/null
  fi
}

gh_download_asset() {
  local url="$1"
  local out="$2"
  local expected_size="${3:-0}"
  local round best_url best_speed speed candidate resume_from actual_size line
  local -a candidates
  local -a probe_results

  touch "${out}"
  for ((round = 1; round <= SYNC_DOWNLOAD_MAX_ROUNDS; round++)); do
    mapfile -t candidates < <(build_asset_download_candidates "${url}")
    if [[ "${#candidates[@]}" -eq 0 ]]; then
      echo "No download candidates found: ${url}" >&2
      return 1
    fi

    best_url=""
    best_speed=-1
    echo "Probe round ${round}: selecting fastest source"
    mapfile -t probe_results < <(probe_download_candidates_parallel "${candidates[@]}")
    for line in "${probe_results[@]}"; do
      speed="${line%%$'\t'*}"
      candidate="${line#*$'\t'}"
      echo "Probe result: speed=${speed}B/s url=${candidate}"
      if [[ "${speed}" =~ ^[0-9]+$ ]] && (( speed > best_speed )); then
        best_speed="${speed}"
        best_url="${candidate}"
      fi
    done

    if [[ -z "${best_url}" ]]; then
      echo "Probe round ${round}: all candidates unavailable." >&2
      continue
    fi

    resume_from="$(file_size_bytes "${out}")"
    echo "Download round ${round}: ${best_url} (resume_from=${resume_from})"
    if gh_download_asset_once "${best_url}" "${out}"; then
      if [[ "${expected_size}" =~ ^[0-9]+$ ]] && (( expected_size > 0 )); then
        actual_size="$(file_size_bytes "${out}")"
        if (( actual_size < expected_size )); then
          echo "Partial file after round ${round}: ${actual_size}/${expected_size}, continue with resume."
          continue
        fi
      fi
      return 0
    fi

    echo "Download round ${round} failed, re-probing and resuming."
  done

  echo "All download rounds failed: ${url}" >&2
  return 1
}

build_asset_download_candidates() {
  local original_url="$1"
  local prefix

  if [[ "${original_url}" == https://github.com/*/releases/download/* ]]; then
    {
      for prefix in "${GH_RELEASE_MIRROR_PREFIX_LIST[@]}"; do
        prefix="${prefix//$'\r'/}"
        prefix="${prefix//$'\n'/}"
        prefix="$(echo "${prefix}" | awk '{$1=$1;print}')"
        [[ -z "${prefix}" ]] && continue
        build_mirror_candidate_url "${prefix}" "${original_url}"
      done
      printf '%s\n' "${original_url}"
    } | awk 'NF && !seen[$0]++'
    return 0
  fi

  printf '%s\n' "${original_url}"
}

build_mirror_candidate_url() {
  local mirror_entry="$1"
  local original_url="$2"
  local candidate path_after_github

  if [[ "${mirror_entry}" == *"{url}"* ]]; then
    candidate="${mirror_entry//\{url\}/${original_url}}"
  elif [[ "${mirror_entry}" == *"https://github.com"* ]]; then
    candidate="${mirror_entry/https:\/\/github.com/${original_url}}"
  elif [[ "${mirror_entry}" == *"github.com"* ]]; then
    path_after_github="${original_url#https://github.com}"
    candidate="${mirror_entry/github.com/github.com${path_after_github}}"
  else
    if [[ "${mirror_entry}" != */ && "${mirror_entry}" != *\?* ]]; then
      mirror_entry="${mirror_entry}/"
    fi
    candidate="${mirror_entry}${original_url}"
  fi

  printf '%s\n' "${candidate}"
}

probe_download_candidates_parallel() {
  local tmp_dir supports_wait_n running_jobs idx candidate speed
  local -a pids

  supports_wait_n=0
  running_jobs=0
  idx=0
  pids=()
  tmp_dir="$(mktemp -d)"

  if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
    supports_wait_n=1
  fi

  for candidate in "$@"; do
    [[ -z "${candidate}" ]] && continue
    idx=$((idx + 1))
    {
      speed="$(probe_download_speed "${candidate}")"
      printf '%s\t%s\n' "${speed}" "${candidate}" > "${tmp_dir}/${idx}.txt"
    } &
    pids+=("$!")
    running_jobs=$((running_jobs + 1))

    if (( running_jobs >= SYNC_PROBE_CONCURRENCY )); then
      if (( supports_wait_n == 1 )); then
        wait -n || true
      else
        wait "${pids[0]}" || true
        pids=("${pids[@]:1}")
      fi
      running_jobs=$((running_jobs - 1))
    fi
  done

  if (( supports_wait_n == 1 )); then
    while (( running_jobs > 0 )); do
      wait -n || true
      running_jobs=$((running_jobs - 1))
    done
  else
    local pid
    for pid in "${pids[@]}"; do
      wait "${pid}" || true
    done
  fi

  if compgen -G "${tmp_dir}/*.txt" > /dev/null; then
    sort -t $'\t' -k1,1nr "${tmp_dir}"/*.txt
  fi
  rm -rf "${tmp_dir}"
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
  local asset_size="${4:-0}"
  local tmp_file

  tmp_file="$(mktemp)"
  echo "Downloading GitHub asset: ${asset_name} (size=${asset_size})"
  if ! gh_download_asset "${asset_url}" "${tmp_file}" "${asset_size}"; then
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
    local asset_name asset_url asset_size
    asset_name="$(jq -r '.name // empty' <<<"${asset}")"
    asset_url="$(jq -r '.browser_download_url // empty' <<<"${asset}")"
    asset_size="$(jq -r '.size // 0' <<<"${asset}")"

    if [[ -z "${asset_name}" || -z "${asset_url}" ]]; then
      continue
    fi

    if jq -e --arg n "${asset_name}" 'if type=="array" then any(.[]; .name == $n) else false end' "${tmp_assets}" >/dev/null; then
      echo "Asset already exists on Gitee, skip: ${asset_name}"
      continue
    fi

    sync_one_asset "${release_id}" "${asset_name}" "${asset_url}" "${asset_size}" &
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
