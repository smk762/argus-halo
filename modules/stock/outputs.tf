# Each server type carries the locations it is offered in; `available` is
# Hetzner's live "not sold out here" flag. A type not offered in this location
# is absent from its `locations`, and anytrue([]) is false, so unknown, retired
# and sold-out names all fall out the same way.
#
# Read from hcloud_server_types (provider >= 1.61) because the datacenters
# source that used to carry this was deprecated on 2026-06-02.
# https://docs.hetzner.cloud/changelog#2026-06-02-datacenters-deprecated
output "available_server_types" {
  description = "Server type names that can be created in var.location now."
  value = sort([
    for t in data.hcloud_server_types.all.server_types : t.name
    if anytrue([for l in t.locations : l.available if l.name == var.location])
  ])
}
