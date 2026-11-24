# hcloud is a partner provider, so its source must be declared in every module
# that uses it -- the root mapping doesn't propagate. The root versions.tf
# narrows the floor given here.
terraform {
  required_version = ">= 1.9"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.61"
    }
  }
}
