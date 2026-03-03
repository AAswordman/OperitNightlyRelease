#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-single}"

required_env=(
  GITEE_OWNER
  GITEE_REPO
  GITEE_TOKEN
  GITHUB_TOKEN
  GITHUB_REPOSITORY
)

for key in "${required_env[@]}"; do
  if [[ -z "${!key:-}" ]]; then
    echo "Missing required environment variable: ${key}" >&2
    exit 1
  fi
done

API_BASE="https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}"
GH_API_BASE="https://api.github.com/repos/${GITHUB_REPOSITORY}"

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
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

delete_gitee_release_by_tag() {
  local tag="$1"
  local rid
  if rid="$(gitee_release_id_by_tag "${tag}")"; then
    echo "Deleting Gitee release tag=${tag} id=${rid}"
    curl -sS -X DELETE "${API_BASE}/releases/${rid}?access_token=${GITEE_TOKEN}" >/dev/null
  else
    echo "Gitee release tag=${tag} does not exist; skip delete"
  fi
}

sync_release_assets() {
  local release_id="$1"
  local release_json="$2"
  local tmp_assets
  tmp_assets="$(mktemp)"
  curl -sS "${API_BASE}/releases/${release_id}/attach_files?access_token=${GITEE_TOKEN}" > "${tmp_assets}"

  while IFS= read -r aid; do
    [[ -z "${aid}" ]] && continue
    curl -sS -X DELETE "${API_BASE}/releases/${release_id}/attach_files/${aid}?access_token=${GITEE_TOKEN}" >/dev/null
  done < <(jq -r 'if type=="array" then .[].id else empty end' "${tmp_assets}")

  rm -f "${tmp_assets}"

  while IFS= read -r asset; do
    [[ -z "${asset}" ]] && continue
    local asset_name asset_url tmp_file
    asset_name="$(jq -r '.name' <<<"${asset}")"
    asset_url="$(jq -r '.browser_download_url' <<<"${asset}")"
    tmp_file="$(mktemp)"

    echo "Downloading GitHub asset: ${asset_name}"
    curl -fsSL \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/octet-stream" \
      -L "${asset_url}" \
      -o "${tmp_file}"

    echo "Uploading asset to Gitee: ${asset_name}"
    curl -sS -X POST "${API_BASE}/releases/${release_id}/attach_files" \
      --form "access_token=${GITEE_TOKEN}" \
      --form "file=@${tmp_file};filename=${asset_name}" >/dev/null

    rm -f "${tmp_file}"
  done < <(jq -c '.assets[]?' <<<"${release_json}")
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

sync_single_release_event() {
  local event_path action release_json tag
  event_path="${GITHUB_EVENT_PATH:-}"
  if [[ -z "${event_path}" || ! -f "${event_path}" ]]; then
    echo "GITHUB_EVENT_PATH is missing or invalid" >&2
    exit 1
  fi

  action="$(jq -r '.action // empty' "${event_path}")"
  release_json="$(jq -c '.release // {}' "${event_path}")"
  tag="$(jq -r '.release.tag_name // empty' "${event_path}")"

  if [[ -z "${tag}" ]]; then
    echo "No release tag in event payload; skip"
    return 0
  fi

  case "${action}" in
    deleted|unpublished)
      delete_gitee_release_by_tag "${tag}"
      ;;
    *)
      upsert_gitee_release_from_json "${release_json}"
      ;;
  esac
}

sync_all_releases() {
  local page response count
  page=1
  while true; do
    response="$(curl -fsSL \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${GH_API_BASE}/releases?per_page=100&page=${page}")"
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
  single)
    sync_single_release_event
    ;;
  all)
    sync_all_releases
    ;;
  *)
    echo "Unsupported mode: ${MODE}. Use 'single' or 'all'." >&2
    exit 1
    ;;
esac
