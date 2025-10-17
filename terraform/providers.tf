terraform {
  required_version = ">= 1.5.0"
}

# No GitHub provider needed because we call the gh CLI via local-exec.
# (If you later move to managing repos as Terraform resources, add the
# integrations/github provider here.)
