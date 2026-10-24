# =====================================================================
# Network
# =====================================================================

resource "google_compute_network" "vpc_hub" {
  name                    = "vpc-hub"
  auto_create_subnetworks = false    # custom mode; auto mode would claim 10.128.0.0/9 in every region
  routing_mode            = "GLOBAL" # Cloud Router advertises every subnet in the VPC
  description             = "Hybrid lab hub network"
}

resource "google_compute_subnetwork" "sn_hub_usw1" {
  name                     = "sn-hub-usw1"
  network                  = google_compute_network.vpc_hub.id
  region                   = var.region
  ip_cidr_range            = var.hub_subnet
  private_ip_google_access = true
  # Flow logs are off to avoid Cloud Logging charges. Turn on with a
  # log_config block only while investigating, then remove it.
}

# =====================================================================
# Firewall (GCP is default-deny for ingress)
# =====================================================================

resource "google_compute_firewall" "iap_ssh" {
  name        = "hub-allow-iap-ssh"
  network     = google_compute_network.vpc_hub.name
  direction   = "INGRESS"
  priority    = 1000
  description = "SSH via Identity-Aware Proxy"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Google's published IAP TCP forwarding range. Not the internet.
  source_ranges = ["35.235.240.0/20"]
}

resource "google_compute_firewall" "from_home" {
  name        = "hub-allow-from-home"
  network     = google_compute_network.vpc_hub.name
  direction   = "INGRESS"
  priority    = 1000
  description = "Allow lab LAN over the VPN"

  allow { protocol = "icmp" }

  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443", "53", "5201", "8080"]
  }

  allow {
    protocol = "udp"
    ports    = ["53"]
  }

  source_ranges = [var.home_lan]
}

resource "google_compute_firewall" "from_vyos" {
  name        = "hub-allow-from-vyos"
  network     = google_compute_network.vpc_hub.name
  direction   = "INGRESS"
  priority    = 1000
  description = "Allow VyOS lab LAN over the VPN"

  allow { protocol = "icmp" }

  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443", "53", "5201"]
  }

  allow {
    protocol = "udp"
    ports    = ["53"]
  }

  source_ranges = [var.vyos_lan]
}

# =====================================================================
# Test VM (free tier: e2-micro + 30 GB pd-standard in us-west1)
# =====================================================================

resource "google_compute_instance" "vm_hub_test" {
  name         = "vm-hub-test"
  machine_type = "e2-micro"
  zone         = var.zone
  description  = "Hybrid lab target"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 30
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.sn_hub_usw1.id
    # No access_config block = no external IP. The VM has no internet.
  }

  # Declared explicitly. If omitted after an import, Terraform plans to
  # REMOVE the service account GCP attached at creation.
  service_account {
    email  = var.vm_service_account.email
    scopes = var.vm_service_account.scopes
  }
}

# =====================================================================
# VPN scaffolding (free, always present)
# =====================================================================

resource "google_compute_router" "rt_hub_vpn" {
  name        = "rt-hub-vpn"
  network     = google_compute_network.vpc_hub.id
  region      = var.region
  description = "BGP peer to home lab"

  bgp {
    asn = var.gcp_asn
  }
}

# Deleting this changes both external IPs. Keep it during teardown.
resource "google_compute_ha_vpn_gateway" "ha_vpn_hub" {
  name    = "ha-vpn-hub"
  network = google_compute_network.vpc_hub.id
  region  = var.region
}

# description and redundancy_type both FORCE REPLACEMENT on this resource,
# so both come from the map and must match what GCP holds exactly.
resource "google_compute_external_vpn_gateway" "peer" {
  for_each = var.tunnels

  name            = each.value.peer_gateway_name
  redundancy_type = each.value.redundancy_type
  description     = each.value.description

  interface {
    id         = 0
    ip_address = each.value.peer_ip
  }
}

# =====================================================================
# Pre-shared keys: read from Secret Manager, never stored in code
# =====================================================================

data "google_secret_manager_secret_version" "psk" {
  for_each = var.tunnels
  secret   = each.value.psk_secret_id
  # version omitted = "latest"
}

# GCP returns only sharedSecretHash, never the plaintext, so Terraform
# cannot compare shared_secret. Without ignore_changes, every plan after an
# import proposes destroying the tunnels.
#
# Rotation stays deliberate and automatic: add a NEW version of the secret,
# set the same value on the router, then apply. The version number changes,
# which replaces exactly that one tunnel.
resource "terraform_data" "psk_version" {
  for_each = var.tunnels
  # name ends in /versions/N, so it changes whenever a new version is added
  input = data.google_secret_manager_secret_version.psk[each.key].name
}

# =====================================================================
# Billable tunnel resources (~USD 0.05 per tunnel-hour)
# =====================================================================

locals {
  active = {
    for k, v in var.tunnels : k => v
    if contains(var.enabled_tunnels, k)
  }
}

resource "google_compute_vpn_tunnel" "tun" {
  for_each = local.active

  name                            = each.value.tunnel_name
  region                          = var.region
  vpn_gateway                     = google_compute_ha_vpn_gateway.ha_vpn_hub.self_link
  vpn_gateway_interface           = each.value.gateway_interface
  peer_external_gateway           = google_compute_external_vpn_gateway.peer[each.key].self_link
  peer_external_gateway_interface = 0
  shared_secret                   = data.google_secret_manager_secret_version.psk[each.key].secret_data
  ike_version                     = 2
  router                          = google_compute_router.rt_hub_vpn.self_link

  lifecycle {
    ignore_changes       = [shared_secret]
    replace_triggered_by = [terraform_data.psk_version[each.key]]
  }
}

resource "google_compute_router_interface" "if_tun" {
  for_each = local.active

  name       = each.value.router_if_name
  router     = google_compute_router.rt_hub_vpn.name
  region     = var.region
  ip_range   = "${each.value.bgp_cloud_ip}/30"
  vpn_tunnel = google_compute_vpn_tunnel.tun[each.key].name
}

resource "google_compute_router_peer" "bgp" {
  for_each = local.active

  name                      = each.value.bgp_peer_name
  router                    = google_compute_router.rt_hub_vpn.name
  region                    = var.region
  peer_ip_address           = each.value.bgp_peer_ip
  peer_asn                  = each.value.peer_asn
  interface                 = google_compute_router_interface.if_tun[each.key].name
  advertised_route_priority = 100

  # DEFAULT advertises every VPC subnet. CUSTOM is only needed if Cloud DNS
  # forwards queries to an on-prem resolver: those queries come from
  # 35.199.192.0/19, and on-prem needs a route back to that range.
  advertise_mode    = var.advertise_dns_forwarding_range ? "CUSTOM" : "DEFAULT"
  advertised_groups = var.advertise_dns_forwarding_range ? ["ALL_SUBNETS"] : null

  dynamic "advertised_ip_ranges" {
    for_each = var.advertise_dns_forwarding_range ? ["35.199.192.0/19"] : []
    content {
      range       = advertised_ip_ranges.value
      description = "Cloud DNS forwarding source range"
    }
  }
}
