variable "project" { type = string }
variable "location" { type = string }
variable "server_type" { type = string }
variable "image" { type = string }
variable "network_id" { type = string }
variable "admin_ip" { type = string }

variable "ssh_key_ids" {
  type = list(string)
}

variable "private_ip" {
  description = "Fixed address on the private network. The stores bind here and nowhere else."
  type        = string
}

variable "postgres_password" {
  type      = string
  sensitive = true
}

variable "minio_access_key" {
  type    = string
  default = "argus"
}

variable "minio_secret_key" {
  type      = string
  sensitive = true
}

variable "s3_bucket" {
  type    = string
  default = "argus-tape"
}

variable "tape_dump_url" {
  type      = string
  default   = ""
  sensitive = true
}
