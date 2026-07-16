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
      source  = "hetznercloud/hcloud"
      version = "~> 1.48"
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
