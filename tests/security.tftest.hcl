# Plans the whole configuration against mocked providers: no credentials, no
# network, nothing created. Each run pins a property the README claims.

mock_provider "hcloud" {
  # Provider ids are numeric strings; the mock default is random text.
  mock_resource "hcloud_network" {
    defaults = { id = "1001" }
  }
  mock_resource "hcloud_firewall" {
    defaults = { id = "2001" }
  }
  mock_resource "hcloud_ssh_key" {
    defaults = { id = "3001" }
  }
}

override_module {
  target  = module.stock
  outputs = { available_server_types = ["cx23", "cx33"] }
}

mock_provider "cloudflare" {}
mock_provider "random" {}

variables {
  hcloud_token          = "test"
  cloudflare_api_token  = "test"
  cloudflare_account_id = "00000000000000000000000000000000"
  cloudflare_zone_id    = "00000000000000000000000000000000"
  ssh_public_key        = "ssh-ed25519 AAAA test"
  admin_ip              = "203.0.113.9/32"
  domain                = "stack.example.com"
}

run "core_exposes_no_data_ports" {
  command = plan

  assert {
    condition     = toset(module.core.open_ports) == toset(["22", "3000"])
    error_message = "core may open only SSH and Grafana on its public interface."
  }

  assert {
    condition     = alltrue([for cidr in module.core.allowed_sources : cidr == var.admin_ip])
    error_message = "every public port on core must be scoped to admin_ip."
  }
}

run "demo_opens_web_to_the_world_and_ssh_to_admin" {
  command = plan

  assert {
    condition     = toset(module.demo.open_ports) == toset(["22", "80", "443"])
    error_message = "the demo tier may open only SSH, HTTP and HTTPS."
  }

  assert {
    condition     = toset(module.demo.ssh_sources) == toset([var.admin_ip])
    error_message = "SSH on the demo tier must be scoped to admin_ip."
  }
}

run "edge_is_proxied_with_strict_tls" {
  command = plan

  assert {
    condition     = cloudflare_dns_record.demo.proxied && cloudflare_dns_record.demo.ttl == 1
    error_message = "the origin address must stay behind Cloudflare's proxy."
  }

  assert {
    condition     = cloudflare_zone_setting.ssl.value == "strict"
    error_message = "the zone must validate the origin certificate."
  }
}

run "metered_paths_are_rate_limited" {
  command = plan

  assert {
    condition = alltrue([
      for path in ["/api/lens/caption", "/api/curator/scan", "/api/curator/upload"] :
      strcontains(cloudflare_ruleset.demo_ratelimit.rules[0].expression, "\"${path}\"")
    ])
    error_message = "a metered or writable path dropped out of the rate limit."
  }

  assert {
    condition     = cloudflare_ruleset.demo_ratelimit.rules[0].action == "block"
    error_message = "the rate limit must block."
  }
}

run "admin_ip_open_to_the_world_is_rejected" {
  command = plan
  variables { admin_ip = "0.0.0.0/0" }
  expect_failures = [var.admin_ip]
}

run "admin_ip_without_a_prefix_is_rejected" {
  command = plan
  variables { admin_ip = "203.0.113.9" }
  expect_failures = [var.admin_ip]
}

run "unavailable_server_type_fails_the_plan" {
  command = plan
  variables { server_type = "cx11" }
  expect_failures = [data.hcloud_location.target]
}

run "quoted_caption_key_is_rejected" {
  command = plan
  variables { lens_caption_api_key = "it's" }
  expect_failures = [var.lens_caption_api_key]
}

run "project_page_hostname_is_rejected" {
  command = plan
  variables {
    domain = "halo.dragonhound.dev"
  }
  expect_failures = [var.domain]
}
