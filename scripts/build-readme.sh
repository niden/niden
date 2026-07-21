#!/usr/bin/env bash
#
# Renders templates/README.md.tpl into README.md by replacing the section
# markers with data pulled from the GitHub GraphQL API.
#
# Requires: gh, jq, and a token in GH_TOKEN with read access to the profile.
#
set -euo pipefail

USERNAME="${PROFILE_USER:-niden}"
TEMPLATE="${PROFILE_TEMPLATE:-templates/README.md.tpl}"
OUTPUT="${PROFILE_OUTPUT:-README.md}"
META_REPO="${USERNAME}/${USERNAME}"

SECTIONS=(contributions pullrequests releases)

BUILD_DIR=".readme-build"
trap 'rm -rf "${BUILD_DIR}"' EXIT
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh is not authenticated - set GH_TOKEN or run 'gh auth login'" >&2
    exit 1
fi

if [[ ! -f "${TEMPLATE}" ]]; then
    echo "error: template not found: ${TEMPLATE}" >&2
    exit 1
fi

# Relative timestamps, matching the wording the previous renderer produced
# ("now", "5 minutes ago", "1 day ago", "3 weeks ago", ...).
read -r -d '' HELPERS <<'JQ' || true
def humanize:
    (now - fromdateiso8601) as $d
    | if   $d < 1        then "now"
      elif $d < 2        then "1 second ago"
      elif $d < 60       then "\($d | floor) seconds ago"
      elif $d < 120      then "1 minute ago"
      elif $d < 3600     then "\(($d / 60) | floor) minutes ago"
      elif $d < 7200     then "1 hour ago"
      elif $d < 86400    then "\(($d / 3600) | floor) hours ago"
      elif $d < 172800   then "1 day ago"
      elif $d < 604800   then "\(($d / 86400) | floor) days ago"
      elif $d < 1209600  then "1 week ago"
      elif $d < 2592000  then "\(($d / 604800) | floor) weeks ago"
      elif $d < 5184000  then "1 month ago"
      elif $d < 31536000 then "\(($d / 2592000) | floor) months ago"
      elif $d < 46656000 then "1 year ago"
      elif $d < 63072000 then "2 years ago"
      else                    "\(($d / 31536000) | floor) years ago"
      end;

def suffix:
    if ((. // "") | length) == 0 then "" else " - \(.)" end;
JQ

# Work in Progress
#
# commitContributionsByRepository is capped by the API's query cost limit -
# large values come back as RESOURCE_LIMITS_EXCEEDED, so fetch 20 and trim to
# 10 once the meta and private repositories are dropped.
gh api graphql -f login="${USERNAME}" -f query='
    query($login: String!) {
        user(login: $login) {
            contributionsCollection {
                commitContributionsByRepository(maxRepositories: 20) {
                    contributions(first: 1) {
                        nodes { occurredAt }
                    }
                    repository { nameWithOwner url description isPrivate }
                }
            }
        }
    }' \
    | jq -r --arg meta "${META_REPO}" "${HELPERS}"'
        [
            .data.user.contributionsCollection.commitContributionsByRepository[]
            | select(.repository.isPrivate | not)
            | select(.repository.nameWithOwner != $meta)
            | select(.contributions.nodes | length > 0)
        ]
        | sort_by(.contributions.nodes[0].occurredAt)
        | reverse
        | .[0:10]
        | map(
            "- [\(.repository.nameWithOwner)](\(.repository.url))"
            + (.repository.description | suffix)
            + " (\(.contributions.nodes[0].occurredAt | humanize))"
        )
        | .[]
    ' > "${BUILD_DIR}/contributions.md"

# Latest Pull Requests
#
# Over-fetch slightly so the list still reaches 10 after the meta and private
# repositories are dropped.
gh api graphql -f login="${USERNAME}" -f query='
    query($login: String!) {
        user(login: $login) {
            pullRequests(first: 15, orderBy: {field: CREATED_AT, direction: DESC}) {
                nodes {
                    title
                    url
                    createdAt
                    repository { nameWithOwner url isPrivate }
                }
            }
        }
    }' \
    | jq -r --arg meta "${META_REPO}" "${HELPERS}"'
        [
            .data.user.pullRequests.nodes[]
            | select(.repository.isPrivate | not)
            | select(.repository.nameWithOwner != $meta)
        ]
        | .[0:10]
        | map(
            "- [\(.title)](\(.url))"
            + " on [\(.repository.nameWithOwner)](\(.repository.url))"
            + " (\(.createdAt | humanize))"
        )
        | .[]
    ' > "${BUILD_DIR}/pullrequests.md"

# Latest releases contributed to
#
# repositoriesContributedTo has a hard cost ceiling somewhere between 10 and 15
# repositories per request - above that the API answers RESOURCE_LIMITS_EXCEEDED
# regardless of how few fields are nested - so walk it a page at a time and
# collect the nodes before formatting.
after="null"
pages=0
: > "${BUILD_DIR}/releases.json"

while :; do
    response=$(gh api graphql -f login="${USERNAME}" -F after="${after}" -f query='
        query($login: String!, $after: String) {
            user(login: $login) {
                repositoriesContributedTo(
                    first: 10
                    after: $after
                    includeUserRepositories: true
                    contributionTypes: COMMIT
                    privacy: PUBLIC
                ) {
                    pageInfo { hasNextPage endCursor }
                    nodes {
                        nameWithOwner
                        url
                        description
                        releases(first: 10, orderBy: {field: CREATED_AT, direction: DESC}) {
                            nodes { tagName url publishedAt isPrerelease isDraft }
                        }
                    }
                }
            }
        }')

    jq -c '.data.user.repositoriesContributedTo.nodes[]' <<<"${response}" >> "${BUILD_DIR}/releases.json"

    pages=$((pages + 1))
    if [[ "$(jq -r '.data.user.repositoriesContributedTo.pageInfo.hasNextPage' <<<"${response}")" != "true" ]]; then
        break
    fi
    if [[ "${pages}" -ge 20 ]]; then
        echo "warning: stopped paginating releases after ${pages} pages" >&2
        break
    fi
    after=$(jq -r '.data.user.repositoriesContributedTo.pageInfo.endCursor' <<<"${response}")
done

jq -r -s --arg meta "${META_REPO}" "${HELPERS}"'
    [
        .[]
        | select(.nameWithOwner != $meta)
        | . as $repo
        | (
            [
                .releases.nodes[]
                | select((.isDraft | not) and (.isPrerelease | not))
                | select(.publishedAt != null and .tagName != "")
            ]
            | first
          ) as $release
        | select($release != null)
        | {repo: $repo, release: $release}
    ]
    | sort_by(.release.publishedAt)
    | reverse
    | .[0:5]
    | map(
        "- [\(.repo.nameWithOwner)](\(.repo.url))"
        + " ([\(.release.tagName)](\(.release.url)), \(.release.publishedAt | humanize))"
        + (.repo.description | suffix)
    )
    | .[]
' "${BUILD_DIR}/releases.json" > "${BUILD_DIR}/releases.md"

for section in "${SECTIONS[@]}"; do
    if [[ ! -s "${BUILD_DIR}/${section}.md" ]]; then
        echo "error: section '${section}' came back empty, refusing to write ${OUTPUT}" >&2
        exit 1
    fi
done

# Substitute each marker with the block rendered for it.
cp "${TEMPLATE}" "${BUILD_DIR}/render.md"
for section in "${SECTIONS[@]}"; do
    marker="<!--$(echo "${section}" | tr '[:lower:]' '[:upper:]')-->"
    awk -v marker="${marker}" -v file="${BUILD_DIR}/${section}.md" '
        $0 == marker {
            while ((getline line < file) > 0) {
                print line
            }
            close(file)
            next
        }
        { print }
    ' "${BUILD_DIR}/render.md" > "${BUILD_DIR}/render.next"
    mv "${BUILD_DIR}/render.next" "${BUILD_DIR}/render.md"
done

mv "${BUILD_DIR}/render.md" "${OUTPUT}"
echo "wrote ${OUTPUT}"
