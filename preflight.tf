# Stop a bad server_type at PLAN time, and say what would work instead.
#
# Two failure modes this closes. First, a wrong identifier: Hetzner retires plan
# lines (cx11/cx21/cx31 went unavailable-for-order in 2024; the cost-optimized
# cx23/cx33/cx43/cx53 line replaced them in Oct 2025), so a default that was
# right once silently rots. Second, a right identifier that is out of stock:
# Hetzner rejects the create with `resource_unavailable`, and because the SSH
# key, network, subnet and passwords have no dependency on either server, they
# get created FIRST and are left orphaned when the server create fails.
#
# Both are the same question -- "can I build var.server_type in var.location
# right now?" -- and Terraform already holds an API token, so it can just ask
# instead of guessing. A data-source postcondition fails the plan before any
# resource is created, so the answer arrives as a clean "pick one of these",
# never a half-finished apply to clean up.

data "hcloud_server_types" "all" {}

locals {
  # Type names buildable in the requested location right now. Each server type
  # carries the locations it is offered in; `available` is Hetzner's live "not
  # temporarily sold out here" flag. A type not offered in this location at all
  # is simply absent from its `locations` list, and anytrue([]) is false -- so
  # unknown, retired, and sold-out names all fall out the same way.
  #
  # This reads the availability that lives on hcloud_server_types (provider
  # >= 1.61). The same signal used to live only on hcloud_datacenters, which
  # Hetzner deprecated on 2026-06-02 and removes after 2026-10-01 -- deliberately
  # not used here, so this gate does not need revisiting on that date.
  # https://docs.hetzner.cloud/changelog#2026-06-02-datacenters-deprecated
  available_server_types = sort([
    for t in data.hcloud_server_types.all.server_types : t.name
    if anytrue([for l in t.locations : l.available if l.name == var.location])
  ])
}

# Anchored on the location lookup, which validates var.location as a side effect
# (an unknown name errors here rather than surfacing as a confusing "no types
# available"). The postcondition references only the server_types data source and
# input variables -- never `self` -- so there is no dependency cycle.
data "hcloud_location" "target" {
  name = var.location

  lifecycle {
    postcondition {
      condition = contains(local.available_server_types, var.server_type)
      error_message = format(
        "server_type %q cannot be built in location %q right now -- it is either not a current Hetzner plan identifier, or temporarily out of stock there. Available in %s: %s. Set the server_type workspace variable to one of those, or try another location (fsn1 / nbg1 / hel1).",
        var.server_type,
        var.location,
        var.location,
        length(local.available_server_types) > 0 ? join(", ", local.available_server_types) : "(none -- this location is exhausted; switch location)",
      )
    }
  }
}
