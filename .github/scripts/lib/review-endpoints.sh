# review-endpoints.sh — the one CI endpoint fetch and merge-base
# resolution for review pre-steps, shared by stellar-prep.sh (ADR-0271)
# and opencode-review-prep.sh (the per-kind lanes). Sourced, never
# executed: it defines the two helpers every review pre-step needs on
# the actions/checkout depth-1 checkout, where credentials are not
# persisted (persist-credentials: false) so every fetch authenticates
# inline and nothing token-bearing survives into a model step.
#
# Requires git and coreutils base64 on PATH; no repository state beyond
# the object store is touched.

# review_auth TOKEN → the Authorization header value for GitHub's git
# http transport (the x-access-token user carries the workflow's token).
review_auth() {
	printf 'AUTHORIZATION: basic %s' "$(printf 'x-access-token:%s' "$1" | base64 -w0)"
}

# fetch_review_base AUTH BASE_SHA HEAD_SHA → the merge-base SHA, or empty
# when none resolves even at depth 256. Fetches both endpoints at
# --depth=1 first (the checkout holds only the merge ref), then deepens
# in powers of two until the merge-base exists: the PR's real diff is
# merge-base...head, and resolving it needs just enough history to
# connect the endpoints — never the whole base branch.
fetch_review_base() { # $1 = AUTH header value, $2 = base SHA, $3 = head SHA
	local auth=$1 base=$2 head=$3 mb depth
	git -c http.https://github.com/.extraheader="$auth" \
		fetch --depth=1 origin "$base" "$head"
	mb=$(git merge-base "$base" "$head" 2>/dev/null || true)
	depth=2
	while [ -z "$mb" ] && [ "$depth" -le 256 ]; do
		git -c http.https://github.com/.extraheader="$auth" \
			fetch --deepen="$depth" origin "$base" "$head"
		mb=$(git merge-base "$base" "$head" 2>/dev/null || true)
		depth=$((depth * 2))
	done
	printf '%s' "$mb"
}
