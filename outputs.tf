output "service" {
  description = "Name of the collector's systemd service on each host."
  value       = var.distribution
}

output "config_file" {
  description = "Path of the collector config the circuit writes on each host."
  value       = local.config_file
}
