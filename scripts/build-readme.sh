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

SECTIONS=(contributions pullrequests releases repositories stats)

ASSET_DIR="${PROFILE_ASSETS:-assets}"

# Octicon paths, matching the icons the previous statistics card used.
ICON_STAR='<path fill-rule="evenodd" d="M8 .25a.75.75 0 01.673.418l1.882 3.815 4.21.612a.75.75 0 01.416 1.279l-3.046 2.97.719 4.192a.75.75 0 01-1.088.791L8 12.347l-3.766 1.98a.75.75 0 01-1.088-.79l.72-4.194L.818 6.374a.75.75 0 01.416-1.28l4.21-.611L7.327.668A.75.75 0 018 .25zm0 2.445L6.615 5.5a.75.75 0 01-.564.41l-3.097.45 2.24 2.184a.75.75 0 01.216.664l-.528 3.084 2.769-1.456a.75.75 0 01.698 0l2.77 1.456-.53-3.084a.75.75 0 01.216-.664l2.24-2.183-3.096-.45a.75.75 0 01-.564-.41L8 2.694v.001z"/>'
ICON_COMMITS='<path fill-rule="evenodd" d="M1.643 3.143L.427 1.927A.25.25 0 000 2.104V5.75c0 .138.112.25.25.25h3.646a.25.25 0 00.177-.427L2.715 4.215a6.5 6.5 0 11-1.18 4.458.75.75 0 10-1.493.154 8.001 8.001 0 101.6-5.684zM7.75 4a.75.75 0 01.75.75v2.992l2.028.812a.75.75 0 01-.557 1.392l-2.5-1A.75.75 0 017 8.25v-3.5A.75.75 0 017.75 4z"/>'
ICON_PRS='<path fill-rule="evenodd" d="M7.177 3.073L9.573.677A.25.25 0 0110 .854v4.792a.25.25 0 01-.427.177L7.177 3.427a.25.25 0 010-.354zM3.75 2.5a.75.75 0 100 1.5.75.75 0 000-1.5zm-2.25.75a2.25 2.25 0 113 2.122v5.256a2.251 2.251 0 11-1.5 0V5.372A2.25 2.25 0 011.5 3.25zM11 2.5h-1V4h1a1 1 0 011 1v5.628a2.251 2.251 0 101.5 0V5A2.5 2.5 0 0011 2.5zm1 10.25a.75.75 0 111.5 0 .75.75 0 01-1.5 0zM3.75 12a.75.75 0 100 1.5.75.75 0 000-1.5z"/>'
ICON_ISSUES='<path fill-rule="evenodd" d="M8 1.5a6.5 6.5 0 100 13 6.5 6.5 0 000-13zM0 8a8 8 0 1116 0A8 8 0 010 8zm9 3a1 1 0 11-2 0 1 1 0 012 0zm-.25-6.25a.75.75 0 00-1.5 0v3.5a.75.75 0 001.5 0v-3.5z"/>'
ICON_CONTRIBS='<path fill-rule="evenodd" d="M2 2.5A2.5 2.5 0 014.5 0h8.75a.75.75 0 01.75.75v12.5a.75.75 0 01-.75.75h-2.5a.75.75 0 110-1.5h1.75v-2h-8a1 1 0 00-.714 1.7.75.75 0 01-1.072 1.05A2.495 2.495 0 012 11.5v-9zm10.5-1V9h-8c-.356 0-.694.074-1 .208V2.5a1 1 0 011-1h8zM5 12.25v3.25a.25.25 0 00.4.2l1.45-1.087a.25.25 0 01.3 0L8.6 15.7a.25.25 0 00.4-.2v-3.25a.25.25 0 00-.25-.25h-3.5a.25.25 0 00-.25.25z"/>'

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

# Relative timestamps in short form ("now", "5m ago", "18h ago", "3d ago", ...).
read -r -d '' HELPERS <<'JQ' || true
def humanize:
    (now - fromdateiso8601) as $d
    | if   $d < 1        then "now"
      elif $d < 60       then "\($d | floor)s ago"
      elif $d < 3600     then "\(($d / 60) | floor)m ago"
      elif $d < 86400    then "\(($d / 3600) | floor)h ago"
      elif $d < 604800   then "\(($d / 86400) | floor)d ago"
      elif $d < 2592000  then "\(($d / 604800) | floor)w ago"
      elif $d < 31536000 then "\(($d / 2592000) | floor)mo ago"
      else                    "\(($d / 31536000) | floor)y ago"
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

# Latest projects
#
# Over-fetch by one so the list still reaches 5 after the meta repository is
# dropped.
gh api graphql -f login="${USERNAME}" -f query='
    query($login: String!) {
        user(login: $login) {
            repositories(
                first: 6
                privacy: PUBLIC
                isFork: false
                ownerAffiliations: OWNER
                orderBy: {field: CREATED_AT, direction: DESC}
            ) {
                nodes { nameWithOwner url description }
            }
        }
    }' \
    | jq -r --arg meta "${META_REPO}" "${HELPERS}"'
        [
            .data.user.repositories.nodes[]
            | select(.nameWithOwner != $meta)
        ]
        | .[0:5]
        | map("- [\(.nameWithOwner)](\(.url))" + (.description | suffix))
        | .[]
    ' > "${BUILD_DIR}/repositories.md"

# GitHub statistics card
#
# Every figure gets its own request. The API applies a cost budget per request,
# not per field, so asking for several at once answers RESOURCE_LIMITS_EXCEEDED
# and which field gets blamed depends on what else happens to be in the query.
scalar() {
    gh api graphql -f login="${USERNAME}" \
        -f query="query(\$login: String!) { user(login: \$login) { $1 } }" \
        --jq "$2"
}

# Thousands separators, e.g. 5680 -> 5,680.
commafy() {
    jq -rn --argjson number "$1" '
        $number
        | tostring
        | (explode | map([.] | implode))
        | reverse
        | to_entries
        | map(if (.key > 0 and (.key % 3) == 0) then (.value + ",") else .value end)
        | reverse
        | join("")
    '
}

commits_public=$(scalar \
    'contributionsCollection { totalCommitContributions }' \
    '.data.user.contributionsCollection.totalCommitContributions')
commits_private=$(scalar \
    'contributionsCollection { restrictedContributionsCount }' \
    '.data.user.contributionsCollection.restrictedContributionsCount')
total_prs=$(scalar \
    'pullRequests(first: 1) { totalCount }' \
    '.data.user.pullRequests.totalCount')
total_issues=$(scalar \
    'issues(first: 1) { totalCount }' \
    '.data.user.issues.totalCount')
contributed_to=$(scalar \
    'repositoriesContributedTo(first: 1, contributionTypes: [COMMIT, ISSUE, PULL_REQUEST, REPOSITORY]) { totalCount }' \
    '.data.user.repositoriesContributedTo.totalCount')

total_commits=$((commits_public + commits_private))

total_stars=0
after="null"
pages=0

while :; do
    response=$(gh api graphql -f login="${USERNAME}" -F after="${after}" -f query='
        query($login: String!, $after: String) {
            user(login: $login) {
                repositories(first: 50, after: $after, ownerAffiliations: OWNER, isFork: false) {
                    pageInfo { hasNextPage endCursor }
                    nodes { stargazers { totalCount } }
                }
            }
        }')

    total_stars=$((
        total_stars + $(jq '[.data.user.repositories.nodes[].stargazers.totalCount] | add // 0' <<<"${response}")
    ))

    pages=$((pages + 1))
    if [[ "$(jq -r '.data.user.repositories.pageInfo.hasNextPage' <<<"${response}")" != "true" ]]; then
        break
    fi
    if [[ "${pages}" -ge 20 ]]; then
        echo "warning: stopped paginating stars after ${pages} pages" >&2
        break
    fi
    after=$(jq -r '.data.user.repositories.pageInfo.endCursor' <<<"${response}")
done

ROWS=(
    "ICON_STAR|Total Stars Earned|$(commafy "${total_stars}")"
    "ICON_COMMITS|Total Commits ($(date +%Y))|$(commafy "${total_commits}")"
    "ICON_PRS|Total PRs|$(commafy "${total_prs}")"
    "ICON_ISSUES|Total Issues|$(commafy "${total_issues}")"
    "ICON_CONTRIBS|Contributed to (last year)|$(commafy "${contributed_to}")"
)

# The card is served through GitHub's image proxy, which strips scripts and
# refuses external references, so everything here is inline shapes and text.
render_stats_card() {
    local target="$1" label_color="$2" value_color="$3" icon_color="$4"
    local index=0 icon label value

    {
        printf '<svg xmlns="http://www.w3.org/2000/svg" width="460" height="132" viewBox="0 0 460 132" role="img" aria-label="GitHub statistics">\n'
        printf '  <title>GitHub statistics</title>\n'
        printf '  <g font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Ubuntu, Sans-Serif" font-size="14">\n'

        for row in "${ROWS[@]}"; do
            IFS='|' read -r icon label value <<<"${row}"
            printf '    <g transform="translate(0, %s)">\n' "$((index * 26))"
            printf '      <svg x="0" y="0" width="16" height="16" viewBox="0 0 16 16" fill="%s">%s</svg>\n' \
                "${icon_color}" "${!icon}"
            printf '      <text x="26" y="12.5" fill="%s">%s</text>\n' "${label_color}" "${label}"
            printf '      <text x="460" y="12.5" fill="%s" font-weight="600" text-anchor="end">%s</text>\n' \
                "${value_color}" "${value}"
            printf '    </g>\n'
            index=$((index + 1))
        done

        printf '  </g>\n'
        printf '</svg>\n'
    } > "${target}"
}

render_stats_card "${BUILD_DIR}/stats-light.svg" "#59636e" "#1f2328" "#59636e"
render_stats_card "${BUILD_DIR}/stats-dark.svg"  "#9198a1" "#e6edf3" "#9198a1"

mkdir -p "${ASSET_DIR}"
mv "${BUILD_DIR}/stats-light.svg" "${ASSET_DIR}/stats-light.svg"
mv "${BUILD_DIR}/stats-dark.svg" "${ASSET_DIR}/stats-dark.svg"

# GitHub's image proxy caches by URL, so stamp the contents into a query string
# to make sure a regenerated card actually reaches the page.
version=$(cat "${ASSET_DIR}/stats-light.svg" "${ASSET_DIR}/stats-dark.svg" | sha1sum | cut -c1-8)

cat > "${BUILD_DIR}/stats.md" <<HTML
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./${ASSET_DIR}/stats-dark.svg?v=${version}">
  <img alt="My GitHub Statistics" src="./${ASSET_DIR}/stats-light.svg?v=${version}">
</picture>
HTML

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
