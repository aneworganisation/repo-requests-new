variable "github_owner" {
  description = "GitHub org login (or your username for a personal account)"
  type        = string
}

variable "repos_csv_path" {
  description = "Absolute path to the CSV file to process"
  type        = string
}

# No required contexts by default (merges won't be blocked by status checks).
# If you later add CI jobs (e.g., 'build', 'test'), set this to ["build","test"].
variable "required_contexts" {
  description = "Status checks required before merge (job names). Use [] to require none."
  type        = list(string)
  default     = []
}

# Default PR approvals required
variable "required_approvals" {
  description = "Number of PR approvals required by branch protection"
  type        = number
  default     = 2
}

# Require CODEOWNERS review toggle
# Note: This only has effect if a CODEOWNERS file exists. Since codeowners_content=""
# by default, this requirement won't block unless you add a CODEOWNERS file later.
variable "require_codeowner_review" {
  description = "Require CODEOWNERS review for PRs"
  type        = bool
  default     = true
}

# Default branch to use when initializing empty repositories
variable "default_branch_fallback" {
  description = "Branch name to initialize when a repo has no default branch"
  type        = string
  default     = "main"
}

# No CODEOWNERS injected by default. To enable, provide file content here (e.g., '* @your-org/your-team').
variable "codeowners_content" {
  description = "Content for .github/CODEOWNERS. Empty string means do not create the file."
  type        = string
  default     = ""
}
