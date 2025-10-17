locals {
  csv_path = var.repos_csv_path

  # Normalize CSV headers/values (case/space-insensitive)
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
      visibility  = lower(try(r["visibility"], "private"))  # private|public|internal (internal = Enterprise Cloud)
    }
    if contains(keys(r), "name") && length(trimspace(try(r["name"], ""))) > 0
  }
}

# Create-only: use gh CLI, not github_repository (no TF state tracking of repos)
resource "null_resource" "create_repo" {
  for_each = local.repos

  triggers = {
    name        = each.value.name
    description = each.value.description
    visibility  = each.value.visibility
  }

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

VIS="$(echo "$RAW_VIS" | tr '[:upper:]' '[:lower:]' | sed -e 's/^public$/public/')"
[[ "$VIS" =~ ^(private|public|internal)$ ]] || { echo "Invalid visibility '$RAW_VIS'"; exit 1; }
[[ -n "$OWNER" && "$OWNER" != "your-org-login" ]] || { echo "ERROR: set github_owner to your real org/user"; exit 1; }

gh auth status >/dev/null 2>&1 || { echo "gh not authenticated (set GH_TOKEN/GITHUB_TOKEN)"; exit 1; }

# Create repo if missing
if gh repo view "$OWNER/$NAME" >/dev/null 2>&1; then
  echo "Repo $OWNER/$NAME already exists; skipping creation."
else
  gh repo create "$OWNER/$NAME" --"$VIS" --description "$DESC" -y
  echo "Created repo $OWNER/$NAME"
fi
EOT
  }

  # --- Post-create: set branch protection + required checks + CODEOWNERS + Snyk workflow ---
  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-c"]
    environment = {
      NAME                    = each.value.name
      OWNER                   = var.github_owner
      DEFAULT_BRANCH_FALLBACK = var.default_branch_fallback
      REQUIRED_APPROVALS      = tostring(var.required_approvals)
      REQUIRE_CODEOWNERS      = tostring(var.require_codeowner_review)
    }
    command = <<EOT
set -euo pipefail

# Detect default branch
DEF=$(gh repo view "$OWNER/$NAME" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || true)
if [ -z "$DEF" ] || [ "$DEF" = "null" ]; then
  DEF="$DEFAULT_BRANCH_FALLBACK"
fi
echo "Default branch for $OWNER/$NAME is '$DEF'"


# Enforce branch protection (2 approvals, CODEOWNERS, strict checks)
gh api -X PUT "repos/$OWNER/$NAME/branches/$DEF/protection" \
  -f required_status_checks.strict=true \
  -f enforce_admins=true \
  -f required_pull_request_reviews.dismiss_stale_reviews=true \
  -f required_pull_request_reviews.required_approving_review_count="$REQUIRED_APPROVALS" \
  -f required_pull_request_reviews.require_code_owner_reviews="$REQUIRE_CODEOWNERS" \
  -f restrictions=null

echo "Branch protection applied on $OWNER/$NAME:$DEF"

# Ensure .github directory exists (create via API)
timestamp=$(date +%s)

# Inject CODEOWNERS (optional; skip if empty)
if [ -n "$CODEOWNERS_CONTENT" ]; then
  B64=$(printf "%s" "$CODEOWNERS_CONTENT" | base64 -w0 || base64)
  gh api -X PUT "repos/$OWNER/$NAME/contents/.github/CODEOWNERS" \
    -f message="chore: add CODEOWNERS ($timestamp)" \
    -f content="$B64" || echo "CODEOWNERS already present or write-protected; skipping."
fi
echo "Post-create hardening complete for $OWNER/$NAME"
EOT
  }
}

output "csv_used" {
  value = local.csv_path
}

output "processed_repositories" {
  value = [for r in null_resource.create_repo : r.triggers.name]
}
