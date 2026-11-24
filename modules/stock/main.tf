# Type names buildable in the requested location right now. Its own module so
# tests can substitute the answer (tests/security.tftest.hcl): nested computed
# lists cannot be mocked on the data source itself.
data "hcloud_server_types" "all" {}

