variable "github_owner" {
  description = "GitHub org login (or your username for a personal account)"
  type        = string
}

variable "repos_csv_path" {
  description = "Absolute path to the CSV file to process"
  type        = string
}


variable "required_approvals" {
  description = "Number of PR approvals required"
  type        = number
  default     = 2
}

variable "require_codeowner_review" {
  description = "Require CODEOWNERS review"
  type        = bool
  default     = true
}

variable "default_branch_fallback" {
  description = "If default branch cannot be detected, use this"
  type        = string
  default     = "main"
}


