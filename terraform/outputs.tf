output "ha_vpn_interface_0" {
  description = "Remote peer address for the router on interface 0"
  value       = google_compute_ha_vpn_gateway.ha_vpn_hub.vpn_interfaces[0].ip_address
}

output "ha_vpn_interface_1" {
  description = "Remote peer address for the router on interface 1"
  value       = google_compute_ha_vpn_gateway.ha_vpn_hub.vpn_interfaces[1].ip_address
}

output "vm_internal_ip" {
  description = "Ping target on the GCP side"
  value       = google_compute_instance.vm_hub_test.network_interface[0].network_ip
}

output "active_tunnels" {
  description = "Tunnels currently built and billing"
  value       = keys(local.active)
}

output "hourly_cost_estimate" {
  description = "Rough tunnel cost while these are up"
  value       = format("~USD %.2f/hr", length(local.active) * 0.05)
}

output "bgp_peers" {
  description = "ASN and BGP addressing per active tunnel"
  value = {
    for k, v in local.active : k => {
      peer_asn = v.peer_asn
      cloud_ip = v.bgp_cloud_ip
      peer_ip  = v.bgp_peer_ip
    }
  }
}
