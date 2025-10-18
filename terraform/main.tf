locals {
  csv_path = var.repos_csv_path

  # Parse CSV and normalize headers/values (case/space-insensitive)
  rows = [
    for r in csvdecode(file(local.csv_path)) : {
      for k, v in r :
      lower(trimspace(k)) => trimspace(v)
    }
  ]

  repos = {
    for r in local.rows :
    lower(r["name"]) => {
      name        = r["name"]
      description = try(r["description"], "")
      visibility  = lower(try(r["visibility"], "private"))  # private|public|internal
    }
    if contains(keys(r), "name") && length(trimspace(try(r["name"], ""))) > 0
  }
}

# Create-only via gh CLI (no GitHub resources tracked in TF state)
resource "null_resource" "create_repo" {
  for_each = local.repos

  triggers = {
    name        = each.value.name
    description = each.value.description
    visibility  = each.value.visibility
  }

  # Step 1: Create the repo if missing
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      NAME    = each.value.name
      OWNER   = var.github_owner
      RAW_VIS = each.value.visibility
      DESC    = each.value.description
    }
    command = <<EOT
set -euo pipefail

# Normalize visibility (fix common typo: "pubic" -> "public")
VIS="$(echo "$RAW_VIS" | tr '[:upper:]' '[:lower:]' | sed -e 's/^pubic$/public/')"
case "$VIS" in
  private|public|internal) ;;
  *) echo "Invalid visibility '$RAW_VIS' (normalized: '$VIS'). Use private|public|internal"; exit 1 ;;
esac

# Guard: OWNER must be a real org/user
if [ -z "$OWNER" ] || [ "$OWNER" = "your-org-login" ]; then
  echo "ERROR: set github_owner (OWNER) to your real org/user. Current: '$OWNER'"
  exit 1
fi

# Ensure gh is authenticated
if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI not authenticated. Set GH_TOKEN/GITHUB_TOKEN (classic PAT with repo+admin:org)."
  exit 1
fi

# Create repo if missing
if gh repo view "$OWNER/$NAME" >/dev/null 2>&1; then
  echo "Repo $OWNER/$NAME already exists; skipping creation."
else
  gh repo create "$OWNER/$NAME" --"$VIS" --description "$DESC" -y
  echo "Created repo $OWNER/$NAME"
fi
EOT
  }

  # Step 2: Init default branch if needed, apply protection, inject files
  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-c"]
    environment = {
      NAME                    = each.value.name
      OWNER                   = var.github_owner
      DEFAULT_BRANCH_FALLBACK = var.default_branch_fallback
      REQUIRED_APPROVALS      = tostring(var.required_approvals)
      REQUIRE_CODEOWNERS      = tostring(var.require_codeowner_review)
      REQUIRED_CONTEXTS       = join(",", var.required_contexts) # comma-delimited for POSIX loop
      CODEOWNERS_CONTENT      = var.codeowners_content
    }
    command = <<EOT
set -euo pipefail

# Determine default branch; initialize if empty repo
DEF="$(gh repo view "$OWNER/$NAME" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || true)"
if [ -z "$DEF" ] || [ "$DEF" = "null" ]; then
  DEF="$DEFAULT_BRANCH_FALLBACK"
  echo "No default branch detected. Initializing '$DEF' with README.md…"
  B64=$(printf "%s\n" "# $NAME" | base64 -w0 2>/dev/null || printf "%s\n" "# $NAME" | base64)
  gh api -X PUT "repos/$OWNER/$NAME/contents/README.md" \
    -F message="chore: init repo with README" \
    -F content="$B64" \
    -F branch="$DEF"
  gh api -X PATCH "repos/$OWNER/$NAME" -F default_branch="$DEF"
else
  echo "Default branch for $OWNER/$NAME is '$DEF'"
fi

# Build -F args for required status checks (POSIX-friendly; no arrays)
CTX_ARGS=""
OLDIFS="$IFS"; IFS=','
for c in $REQUIRED_CONTEXTS; do
  c="$(echo "$c" | xargs)"   # trim spaces
  [ -n "$c" ] && CTX_ARGS="$CTX_ARGS -F required_status_checks.contexts[]=$c"
done
IFS="$OLDIFS"

# Convert inputs to proper JSON literals ( POSIX-safe)
RCO=false
[ "$REQUIRE_CODEOWNERS" = "true" ] && RCO=true

APPROVALS="$REQUIRED_APPROVALS"
if [ -z "$APPROVALS" ]; then
  APPROVALS=2
fi
case "$APPROVALS" in ''|*[!0-9]*) APPROVALS=2 ;; esac

# Apply branch protection (use := for booleans/ints/null so JSON types are correct)
# shellcheck disable=SC2086
gh api -X PUT "repos/$OWNER/$NAME/branches/$DEF/protection" \
  -F required_status_checks.strict:=true \
  $CTX_ARGS \
  -F enforce_admins:=true \
  -F required_pull_request_reviews.dismiss_stale_reviews:=true \
  -F required_pull_request_reviews.require_code_owner_reviews:=$RCO \
  -F required_pull_request_reviews.required_approving_review_count:=$APPROVALS \
  -F restrictions:=null

echo "Branch protection applied on $OWNER/$NAME:$DEF"

ts="$(date +%s)"

# Inject CODEOWNERS if content provided
if [ -n "$CODEOWNERS_CONTENT" ]; then
  B64=$(printf "%s" "$CODEOWNERS_CONTENT" | base64 -w0 2>/dev/null || printf "%s" "$CODEOWNERS_CONTENT" | base64)
  gh api -X PUT "repos/$OWNER/$NAME/contents/.github/CODEOWNERS" \
    -F message="chore: add CODEOWNERS ($ts)" \
    -F content="$B64" || echo "CODEOWNERS already present or write-protected; skipping."
fi

# Inject Snyk workflow (optional)
if [ "$INJECT_SNYK" = "true" ]; then
  WF_B64=$(printf "%s" "$SNYK_WORKFLOW_YAML" | base64 -w0 2>/dev/null || printf "%s" "$SNYK_WORKFLOW_YAML" | base64)
  gh api -X PUT "repos/$OWNER/$NAME/contents/.github/workflows/snyk.yml" \
    -F message="ci: add Snyk workflow ($ts)" \
    -F content="$WF_B64" || echo "snyk.yml already present or write-protected; skipping."
fi

echo "Post-create steps completed for $OWNER/$NAME"
EOT
  }
}

# Helpful outputs
output "csv_used" {
  value = local.csv_path
}

output "processed_repositories" {
  value = [for r in null_resource.create_repo : r.triggers.name]
}
