locals {
  csv_path = var.repos_csv_path

  # Parse CSV and normalize headers/values (case/space-insensitive)
  rows = [
    for r in csvdecode(file(local.csv_path)) : {
      for k, v in r :
      lower(trimspace(k)) => trimspace(v)
    }
  ]

  # Map of repo requests keyed by normalized name
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

# Create-only via GitHub CLI (no github_* resources, so no TF state tracking of repos)
resource "null_resource" "create_repo" {
  for_each = local.repos

  # Re-run when row values change
  triggers = {
    name        = each.value.name
    description = each.value.description
    visibility  = each.value.visibility
  }

  ############################
  # Step 1: Create repository
  ############################
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

# Ensure gh is authenticated (GH_TOKEN/GITHUB_TOKEN should be set in the job)
if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI not authenticated. Set GH_TOKEN (classic PAT with repo + admin:org if creating in org)."
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

  ##########################################################################
  # Step 2: Ensure default branch; apply branch protection; (optional) CODEOWNERS
  ##########################################################################
  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-c"]
    environment = {
      NAME                    = each.value.name
      OWNER                   = var.github_owner
      DEFAULT_BRANCH_FALLBACK = var.default_branch_fallback
      REQUIRED_APPROVALS      = tostring(var.required_approvals)
      REQUIRE_CODEOWNER       = tostring(var.require_codeowner_review)
      REQUIRED_CONTEXTS_CSV   = join(",", var.required_contexts)  # comma-delimited for POSIX loop
      CODEOWNERS_CONTENT      = var.codeowners_content
    }
    command = <<EOT
set -euo pipefail

# 2.1 Determine default branch; initialize if repo is empty
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

# 2.2 Build required status checks array from comma list (allow empty -> [])
CTX_JSON=$(printf "%s" "$REQUIRED_CONTEXTS_CSV" | jq -R '
  split(",")
  | map(gsub("^\\s+|\\s+$";""))
  | map(select(length>0))
')

# 2.3 Convert inputs to proper JSON types (POSIX-safe defaults)
RCO=false
[ "$REQUIRE_CODEOWNER" = "true" ] && RCO=true

APPROVALS="$REQUIRED_APPROVALS"
if [ -z "$APPROVALS" ]; then APPPROVALS=2; fi
case "$APPROVALS" in ''|*[!0-9]*) APPROVALS=2 ;; esac

# 2.4 Construct full JSON payload for branch protection
PAYLOAD=$(jq -n \
  --argjson contexts "$CTX_JSON" \
  --argjson strict true \
  --argjson admins true \
  --argjson dismiss true \
  --argjson codeowners "$RCO" \
  --argjson approvals "$APPROVALS" \
  '{
     required_status_checks: {
       strict: $strict,
       contexts: $contexts
     },
     enforce_admins: $admins,
     required_pull_request_reviews: {
       dismiss_stale_reviews: $dismiss,
       require_code_owner_reviews: $codeowners,
       required_approving_review_count: $approvals
     },
     restrictions: null
   }')

echo "Applying branch protection on $OWNER/$NAME:$DEF with payload:"
echo "$PAYLOAD" | jq .

gh api -X PUT "repos/$OWNER/$NAME/branches/$DEF/protection" \
  -H "Accept: application/vnd.github+json" \
  --input - <<< "$PAYLOAD"

echo "Branch protection applied."

# 2.5 (Optional) Inject CODEOWNERS if content provided
if [ -n "$CODEOWNERS_CONTENT" ]; then
  ts="$(date +%s)"
  B64=$(printf "%s" "$CODEOWNERS_CONTENT" | base64 -w0 2>/dev/null || printf "%s" "$CODEOWNERS_CONTENT" | base64)
  gh api -X PUT "repos/$OWNER/$NAME/contents/.github/CODEOWNERS" \
    -F message="chore: add CODEOWNERS ($ts)" \
    -F content="$B64" || echo "CODEOWNERS already present or write-protected; skipping."
fi

echo "Post-create steps completed for $OWNER/$NAME"
EOT
  }
}

# Useful outputs
output "csv_used"               { value = local.csv_path }
output "processed_repositories" { value = [for r in null_resource.create_repo : r.triggers.name] }
