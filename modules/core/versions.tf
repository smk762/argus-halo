# hcloud is a partner provider, so its source must be declared in every module
# that uses it -- the root mapping doesn't propagate. Version constraints stay
# in the root versions.tf.
terraform {
  required_providers {
    hcloud = {
      source = "hetznercloud/hcloud"
    }
  }
}
