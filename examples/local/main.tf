variable "port" {
  type    = number
  default = 2303
}

module "otelcol" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  # The config reads DEPLOY_ENV from here. A real exporter's API key goes
  # the same way, from a secret store rather than a literal.
  environment = { DEPLOY_ENV = "local" }

  # OTLP in on loopback, everything out to a file, and host metrics out to
  # a Prometheus endpoint as well.
  config = {
    receivers = {
      otlp = { protocols = { http = { endpoint = "127.0.0.1:4318" } } }
      host_metrics = {
        collection_interval = "10s"
        scrapers            = { cpu = {}, memory = {}, load = {} }
      }
    }
    processors = {
      resource = { attributes = [{ key = "deployment.environment", value = "$${env:DEPLOY_ENV}", action = "upsert" }] }
      batch    = {}
    }
    exporters = {
      file       = { path = "/tmp/otelcol-out.json" }
      prometheus = { endpoint = "127.0.0.1:8889" }
    }
    service = {
      pipelines = {
        logs    = { receivers = ["otlp"], processors = ["resource", "batch"], exporters = ["file"] }
        traces  = { receivers = ["otlp"], processors = ["resource", "batch"], exporters = ["file"] }
        metrics = { receivers = ["host_metrics"], processors = ["batch"], exporters = ["prometheus"] }
      }
    }
  }
}

output "config_file" {
  value = module.otelcol.config_file
}
