terraform {
  required_version = ">= 1.11.0"

  required_providers {
    harness = {
      source  = "harness/harness"
      version = "~> 0.44.5"
    }
  }
}
