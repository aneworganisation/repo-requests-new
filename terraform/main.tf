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

resource "null_resource" "create_repo" {
  for_each = local.repos

  triggers = {
    name        = each.value.name
    description = each.value.description
    visibility  = each.value.visibility
  }

  # STEP 1 — Create the repository (idempotent)
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

# Normalize visibility (fix common typo)
VIS="$(echo "$RAW_VIS" | tr '[:upper:]' '[:lower:]' | sed -e 's/^pubic$/public/')"
case "$VIS" in private|public|internal) ;; *) echo "Invalid visibility '$RAW_VIS'"; exit 1;; esac

# Sanity checks
if [ -z "$OWNER" ] || [ "$OWNER" = "your-org-login" ]; then
  echo "ERROR: set github_owner to your real org/user. Current: '$OWNER'"; exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI not authenticated. Set GH_TOKEN (classic PAT with repo + admin:org if org)."; exit 1
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

  # STEP 2 — Default branch + branch protection + optional CODEOWNERS (with early-exit)
  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-c"]
    environment = {
      NAME                    = each.value.name
      OWNER                   = var.github_owner
      DEFAULT_BRANCH_FALLBACK = var.default_branch_fallback
      REQUIRED_APPROVALS      = tostring(var.required_approvals)
      REQUIRE_CODEOWNER       = tostring(var.require_codeowner_review)
      REQUIRED_CONTEXTS_CSV   = join(",", var.required_contexts)   # comma-delimited
      CODEOWNERS_CONTENT      = var.codeowners_content
    }
    command = <<EOT
set -euo pipefail

# Resolve default branch (may be null for empty repos)
DEF="$(gh repo view "$OWNER/$NAME" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || true)"

# EARLY EXIT: if default branch exists AND protection is already present, skip this whole block
if [ -n "$DEF" ] && [ "$DEF" != "null" ]; then
  if gh api -X GET "repos/$OWNER/$NAME/branches/$DEF/protection" >/dev/null 2>&1; then
    echo "Branch protection already present on $OWNER/$NAME:$DEF — skipping post-create actions."
    exit 0
  fi
fi

# If no default branch yet, initialize it with README and set as default
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
  echo "Default branch for $OWNER/$NAME is '$DEF' (no protection yet)."
fi

# Build JSON array of required contexts WITHOUT jq (allow empty -> [])
CTX_LIST=""
if [ -n "$REQUIRED_CONTEXTS_CSV" ]; then
  CTX_LIST=$(printf "%s" "$REQUIRED_CONTEXTS_CSV" | awk -F',' '{
    n=0; for(i=1;i<=NF;i++){ gsub(/^[ \t]+|[ \t]+$/, "", $i); if($i!=""){ if(n++) printf(","); printf("\"%s\"",$i) } }
  }')
fi
[ -z "$CTX_LIST" ] && CTX_LIST=""

# Booleans/ints (POSIX-safe)
RCO=false
[ "$REQUIRE_CODEOWNER" = "true" ] && RCO=true
APPROVALS="$REQUIRED_APPROVALS"; if [ -z "$APPROVALS" ]; then APPROVALS=2; fi
case "$APPROVALS" in ''|*[!0-9]*) APPROVALS=2 ;; esac

# Build full JSON payload (escape $ for Terraform so bash expands at runtime)
PAYLOAD=$(cat <<JSON
{
  "required_status_checks": {
    "strict": true,
    "contexts": [$${CTX_LIST}]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": $${RCO},
    "required_approving_review_count": $${APPROVALS}
  },
  "restrictions": null
}
JSON
)

echo "Applying branch protection on $OWNER/$NAME:$DEF with payload:"
echo "$PAYLOAD"

gh api -X PUT "repos/$OWNER/$NAME/branches/$DEF/protection" \
  -H "Accept: application/vnd.github+json" \
  --input - <<< "$PAYLOAD"

echo "Branch protection applied."

# Optional: inject CODEOWNERS if content provided
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

output "csv_used"               { value = local.csv_path }
output "processed_repositories" { value = [for r in null_resource.create_repo : r.triggers.name] }
