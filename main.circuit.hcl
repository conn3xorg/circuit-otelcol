# Facts give each host's distribution and architecture, which pick the
# .deb or .rpm and its build.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
  }
}

locals {
  name  = var.distribution
  other = var.distribution == "otelcol" ? "otelcol-contrib" : "otelcol"
  dir   = "/etc/${local.name}"

  # A host object's os and arch stand in for the facts of a host created
  # in the same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  ext    = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "deb" : "rpm" }
  goarch = { x86_64 = "amd64", aarch64 = "arm64", amd64 = "amd64", arm64 = "arm64" }
  arch   = { for name, h in var.hosts : name => local.goarch[try(h.arch, data.conn3x_host.facts[name].arch)] }
  pkg    = { for name, h in var.hosts : name => "${local.name}_${var.otelcol_version}_linux_${local.arch[name]}.${local.ext[name]}" }

  # The package's unit reads its flags from its own EnvironmentFile, which
  # dpkg and rpm treat as a config file. Exporter secrets go in a second
  # file, added by a drop-in, so upgrades never touch them.
  env_file = "${local.dir}/conn3x.env"
  dropin   = "/etc/systemd/system/${local.name}.service.d/conn3x.conf"

  # systemd-journal lets the journald receiver read the whole journal.
  dropin_content = "# Written by Conn3x. Changes here are overwritten on the next apply.\n[Service]\nEnvironmentFile=${local.env_file}\nSupplementaryGroups=systemd-journal\n"

  # The package's unit starts the collector with this file.
  config_file = "${local.dir}/config.yaml"
  candidate   = "${local.dir}/config.yaml.conn3x"

  otlp_exporter = var.otlp_protocol == "grpc" ? "otlp_grpc" : "otlp_http"
  debug         = var.debug_exporter || var.otlp_endpoint == null
  exporters = merge(
    var.otlp_endpoint == null ? {} : { (local.otlp_exporter) = merge({ endpoint = var.otlp_endpoint }, length(var.otlp_headers) == 0 ? {} : { headers = var.otlp_headers }) },
    local.debug ? { debug = { verbosity = "basic" } } : {},
  )

  # Host metrics, the journal (otelcol-contrib only, since core has no
  # journald receiver) and OTLP from local applications, out through
  # OTLP or the debug exporter. The receivers listen on loopback only.
  journald = local.name == "otelcol-contrib"
  default_config = {
    receivers = merge(
      {
        otlp = { protocols = { grpc = { endpoint = "127.0.0.1:4317" }, http = { endpoint = "127.0.0.1:4318" } } }
        host_metrics = {
          collection_interval = var.collection_interval
          scrapers            = { cpu = {}, load = {}, memory = {}, disk = {}, filesystem = {}, network = {}, paging = {} }
        }
      },
      local.journald ? { journald = {} } : {},
    )
    # The collector's own journal lines are dropped, or the debug exporter
    # and export errors would feed back into the journal it reads.
    processors = merge(
      {
        resource_detection = { detectors = ["system"] }
        batch              = {}
      },
      local.journald ? { "filter/self" = { log_conditions = ["log.body[\"_SYSTEMD_UNIT\"] == \"${local.name}.service\""] } } : {},
    )
    exporters = local.exporters
    service = {
      pipelines = {
        metrics = { receivers = ["otlp", "host_metrics"], processors = ["resource_detection", "batch"], exporters = keys(local.exporters) }
        logs    = { receivers = concat(["otlp"], local.journald ? ["journald"] : []), processors = concat(local.journald ? ["filter/self"] : [], ["resource_detection", "batch"]), exporters = keys(local.exporters) }
        traces  = { receivers = ["otlp"], processors = ["resource_detection", "batch"], exporters = keys(local.exporters) }
      }
    }
  }

  config = join("", [
    "# Written by Conn3x. Changes here are overwritten on the next apply.\n",
    var.config_yaml != null ? var.config_yaml : var.config != null ? yamlencode(var.config) : yamlencode(local.default_config),
  ])
}

circuit "otelcol" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # After a switch of distribution, the other build would still hold the
  # same ports. Its package stays installed.
  step "other_stopped" {
    command {
      command = "systemctl disable --now ${local.other}.service"
      unless  = "! systemctl is-enabled -q ${local.other}.service 2>/dev/null && ! systemctl is-active -q ${local.other}.service"
    }
  }

  # The download needs it, and minimal images can lack it.
  step "curl" {
    package {
      name = "curl"
    }
  }

  step "download" {
    download {
      url    = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${var.otelcol_version}/${local.pkg[each.key]}"
      sha256 = var.checksums["${local.name}_${local.arch[each.key]}.${local.ext[each.key]}"]
      dest   = "/var/cache/conn3x-otelcol/${local.pkg[each.key]}"
    }
  }

  # Installs or upgrades from the checked file. confold keeps the config
  # this circuit wrote when an upgrade ships a new example config.yaml.
  step "package" {
    command {
      command = local.ext[each.key] == "deb" ? "DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold /var/cache/conn3x-otelcol/${local.pkg[each.key]}" : "dnf -y install /var/cache/conn3x-otelcol/${local.pkg[each.key]}"
      unless  = local.ext[each.key] == "deb" ? "[ \"$(dpkg-query -W -f='$${Version}' ${local.name} 2>/dev/null)\" = ${var.otelcol_version} ]" : "[ \"$(rpm -q --qf '%%{VERSION}' ${local.name} 2>/dev/null)\" = ${var.otelcol_version} ]"
    }
    notify = [handler.restart]
  }

  # Write-only: the plan and state record only an HMAC of the content.
  # systemd reads it as root before it starts the collector.
  step "environment" {
    file {
      path       = local.env_file
      content_wo = join("", [for k, v in coalesce(var.environment, {}) : "${k}=\"${replace(v, "/([\"\\\\$`])/", "\\$1")}\"\n"])
      owner      = "root"
      group      = "root"
      mode       = "0600"
    }
    notify = [handler.restart]
  }

  step "dropin" {
    file {
      path    = local.dropin
      content = local.dropin_content
    }
    notify = [handler.restart]
  }

  # systemd doesn't always notice a new drop-in for a unit it has loaded,
  # and the restart would then run without the environment.
  step "daemon_reload" {
    command {
      command  = "systemctl daemon-reload"
      triggers = { dropin = sha256(local.dropin_content) }
    }
  }

  # The rendered config lands beside the live one first.
  step "candidate" {
    file {
      path    = local.candidate
      content = local.config
    }
  }

  # Copies the candidate over the live config only once the collector's
  # own validate accepts it, with the same environment the service gets,
  # so a bad config never reaches the running collector. Also puts it back
  # after a hand edit to the live file, or after a package install wrote
  # upstream's example over it.
  step "config" {
    command {
      command  = "set -a && . ${local.env_file} && set +a && /usr/bin/${local.name} validate --config=${local.candidate} && cp ${local.candidate} ${local.config_file}"
      unless   = "[ \"$(sha256sum < ${local.candidate})\" = \"$(sha256sum < ${local.config_file})\" ]"
      triggers = { config = sha256(local.config), version = var.otelcol_version }
    }
    notify = [handler.restart]
  }

  step "running" {
    service {
      name    = local.name
      state   = "started"
      enabled = true
    }
  }

  handler "restart" {
    service {
      name = local.name
    }
  }
}
