variable "github_owner" {
  description = "GitHub org login (or your username for a personal account)"
  type        = string
}

variable "repos_csv_path" {
  description = "Absolute path to the CSV file to process"
  type        = string
}

variable "required_contexts" {
  description = "Status checks required before merge (job names)"
  type        = list(string)
  default     = ["build", "snyk"]
}

variable "required_approvals" {
  description = "Number of PR approvals"
  type        = number
  default     = 2
}

variable "require_codeowner_review" {
  description = "Require CODEOWNERS review"
  type        = bool
  default     = true
}

variable "default_branch_fallback" {
  description = "Used if default branch cannot be detected"
  type        = string
  default     = "main"
}

variable "codeowners_content" {
  description = "Content for .github/CODEOWNERS (empty to skip)"
  type        = string
  default     = "* @your-org/your-team\n"
}

