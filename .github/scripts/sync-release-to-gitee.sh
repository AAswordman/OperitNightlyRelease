#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-latest}"
TARGET_TAG="${2:-${SYNC_TAG:-}}"

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

echo "Source GitHub repository: ${SOURCE_GITHUB_REPOSITORY}"
echo "Target Gitee repository: ${GITEE_OWNER}/${GITEE_REPO}"

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

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
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

sync_release_assets() {
  local release_id="$1"
  local release_json="$2"
  local tmp_assets
  tmp_assets="$(mktemp)"
  curl -sS "${API_BASE}/releases/${release_id}/attach_files?access_token=${GITEE_TOKEN}" > "${tmp_assets}"

  while IFS= read -r asset; do
    [[ -z "${asset}" ]] && continue
    local asset_name asset_url tmp_file
    asset_name="$(jq -r '.name // empty' <<<"${asset}")"
    asset_url="$(jq -r '.browser_download_url // empty' <<<"${asset}")"

    if [[ -z "${asset_name}" || -z "${asset_url}" ]]; then
      continue
    fi

    if jq -e --arg n "${asset_name}" 'if type=="array" then any(.[]; .name == $n) else false end' "${tmp_assets}" >/dev/null; then
      echo "Asset already exists on Gitee, skip: ${asset_name}"
      continue
    fi

    tmp_file="$(mktemp)"
    echo "Downloading GitHub asset: ${asset_name}"
    gh_download_asset "${asset_url}" "${tmp_file}"

    echo "Uploading asset to Gitee: ${asset_name}"
    curl -sS -X POST "${API_BASE}/releases/${release_id}/attach_files" \
      --form "access_token=${GITEE_TOKEN}" \
      --form "file=@${tmp_file};filename=${asset_name}" >/dev/null

    rm -f "${tmp_file}"
  done < <(jq -c '.assets[]?' <<<"${release_json}")

  rm -f "${tmp_assets}"
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
