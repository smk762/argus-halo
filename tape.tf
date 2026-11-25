# A presigned URL carries its own clock, so staleness needs no request. Core reads
# the URL on every first boot: an expired one brings up empty stores. A warning,
# not an error, because most plans never rebuild core.
locals {
  tape_signed_at  = try(formatdate("YYYY-MM-DD'T'hh:mm:ssZ", join("", [for p in [regex("X-Amz-Date=(\\d{4})(\\d{2})(\\d{2})T(\\d{2})(\\d{2})(\\d{2})Z", var.tape_dump_url)] : "${p[0]}-${p[1]}-${p[2]}T${p[3]}:${p[4]}:${p[5]}Z"])), null)
  tape_lifetime_s = try(tonumber(regex("X-Amz-Expires=(\\d+)", var.tape_dump_url)[0]), null)

  # True for an empty URL and for one that is not presigned (a stable address).
  tape_url_fresh = nonsensitive(
    local.tape_signed_at == null || local.tape_lifetime_s == null ? true :
    timecmp(plantimestamp(), timeadd(local.tape_signed_at, "${local.tape_lifetime_s}s")) < 0
  )
}

check "tape_url_fresh" {
  assert {
    condition     = local.tape_url_fresh
    error_message = "tape_dump_url has expired: a core rebuilt now would boot with empty stores. Run make tape and update the workspace variable."
  }
}
