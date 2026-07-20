terraform {
  required_version = ">= 1.9"

  # HCP Terraform holds state and does the locking. Run `terraform login` once,
  # then create the workspace in the UI (Version Control: none / CLI-driven).
  cloud {
    organization = "dragonhound_argus"

    workspaces {
      name = "argus-halo"
    }
  }

  required_providers {
    hcloud = {
      source = "hetznercloud/hcloud"
      # >= 1.61 for per-location availability on hcloud_server_types, which the
      # preflight gate reads (it landed there when the deprecated datacenters
      # data source stopped being the only source). See preflight.tf.
      version = "~> 1.61"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.22"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
