variable "project_id" {
  description = "GCP project ID"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID."
  }
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-west1"
}

variable "zone" {
  description = "GCP zone for the test VM"
  type        = string
  default     = "us-west1-b"
}

variable "hub_subnet" {
  description = "GCP hub subnet CIDR"
  type        = string
  default     = "10.8.10.0/24"

  validation {
    condition     = can(cidrnetmask(var.hub_subnet))
    error_message = "hub_subnet must be a valid IPv4 CIDR."
  }
}

variable "home_lan" {
  description = "Lab LAN behind OPNsense"
  type        = string
  default     = "10.2.10.0/24"
}

variable "vyos_lan" {
  description = "Lab LAN behind VyOS"
  type        = string
  default     = "10.2.20.0/24"
}

variable "gcp_asn" {
  description = "Cloud Router ASN (private range)"
  type        = number
  default     = 65001

  validation {
    condition     = var.gcp_asn >= 64512 && var.gcp_asn <= 65534
    error_message = "Use a private ASN between 64512 and 65534."
  }
}

variable "alert_email" {
  description = "Email for alert notifications. Kept in terraform.tfvars, never committed."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must look like an email address."
  }
}

variable "vm_service_account" {
  description = "Service account for the test VM. Must match what GCP holds if importing."
  type = object({
    email  = string
    scopes = list(string)
  })
}

variable "tunnels" {
  description = "One entry per on-prem router. Names must match what exists in GCP if importing."
  type = map(object({
    peer_gateway_name = string
    redundancy_type   = string
    description       = string
    tunnel_name       = string
    router_if_name    = string
    bgp_peer_name     = string
    gateway_interface = number
    peer_ip           = string
    peer_asn          = number
    bgp_cloud_ip      = string
    bgp_peer_ip       = string
    psk_secret_id     = string
  }))

  validation {
    condition     = alltrue([for t in values(var.tunnels) : contains([0, 1], t.gateway_interface)])
    error_message = "gateway_interface must be 0 or 1 (HA VPN has two interfaces)."
  }

  validation {
    condition     = alltrue([for t in values(var.tunnels) : can(regex("^169\\.254\\.", t.bgp_cloud_ip)) && can(regex("^169\\.254\\.", t.bgp_peer_ip))])
    error_message = "Cloud Router BGP addresses must be in 169.254.0.0/16."
  }

  validation {
    condition     = alltrue([for t in values(var.tunnels) : t.peer_asn >= 64512 && t.peer_asn <= 65534])
    error_message = "peer_asn must be a private ASN between 64512 and 65534."
  }
}

variable "enabled_tunnels" {
  description = "Which tunnels to build. An empty list removes every billable tunnel resource."
  type        = list(string)
  default     = []
}

variable "advertise_dns_forwarding_range" {
  description = "Advertise 35.199.192.0/19 so Cloud DNS outbound forwarding to an on-prem resolver works"
  type        = bool
  default     = false
}
