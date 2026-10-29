variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts, os or arch."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }

  validation {
    condition     = alltrue([for h in var.hosts : contains(["x86_64", "aarch64", "amd64", "arm64"], try(h.arch, "x86_64"))])
    error_message = "A host object's arch must be x86_64, aarch64, amd64 or arm64."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "distribution" {
  type        = string
  default     = "otelcol-contrib"
  description = "Collector build to install: \"otelcol-contrib\", with the most receivers and exporters, or \"otelcol\", the smaller core build without journald."

  validation {
    condition     = contains(["otelcol-contrib", "otelcol"], var.distribution)
    error_message = "distribution must be \"otelcol-contrib\" or \"otelcol\"."
  }
}

variable "otelcol_version" {
  type        = string
  default     = "0.164.0"
  description = "Collector release to install, without the leading v. Raising it upgrades the collector in place."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.otelcol_version))
    error_message = "otelcol_version must be a full release, such as \"0.164.0\"."
  }
}

variable "checksums" {
  type        = map(string)
  nullable    = false
  description = "SHA-256 of each package, keyed DISTRIBUTION_ARCH.EXT, from the .sha256 file beside it on the release. Change these with otelcol_version."
  default = {
    "otelcol-contrib_amd64.deb" = "1995260c54cf5d74964a85e5e7d27834bb9a252c87a2582a4fb6a6c34565a90d"
    "otelcol-contrib_amd64.rpm" = "c79d8f9faea63c43265ea027f3c7c6e72f42d1a54e90be6b8d1fe531b1ad8fdc"
    "otelcol-contrib_arm64.deb" = "34dca7290ff50d8be123c587dff51d93711a59e2cff41895e8801b145749dd0e"
    "otelcol-contrib_arm64.rpm" = "28e4add3efb675de699d5a8073245cb5cc450d4d969f4488483453b52c3a38d8"
    "otelcol_amd64.deb"         = "73312676234dd202ab0b8685eed87ffda26e5da09affebb78df663532d400cb2"
    "otelcol_amd64.rpm"         = "c0e848d23af5a653bc6d3adea011b0a538908e71923efdc1982c4dc8991e0b4d"
    "otelcol_arm64.deb"         = "5a88956e45a647822beac12a589dc48e785f976a1f7c4f6954c5edb7d981a483"
    "otelcol_arm64.rpm"         = "f018a579af888b8daaddb8d202a7a4f813a2176361bb5f6adea3efbc65b88637"
  }

  validation {
    condition     = alltrue([for v in values(var.checksums) : can(regex("^[0-9a-f]{64}$", v))])
    error_message = "Each checksum must be a SHA-256 in lowercase hex."
  }
}

variable "config" {
  type        = any
  default     = null
  description = "The whole collector config as an HCL object, written as YAML, such as { receivers = {...}, exporters = {...}, service = {...} }. Write $${env:NAME} for a value from environment. Replaces the default config. Set this or config_yaml, not both."
}

variable "config_yaml" {
  type        = string
  default     = null
  description = "The whole collector config as a YAML string, written as it is. Replaces the default config. Set this or config, not both."

  validation {
    condition     = var.config_yaml == null || var.config == null
    error_message = "Set config or config_yaml, not both."
  }
}

variable "otlp_endpoint" {
  type        = string
  default     = null
  description = "Where the default config sends everything over OTLP, such as \"https://otlp.example.com\" for http or \"otel-gateway.internal:4317\" for grpc. When null, the default config prints to the debug exporter instead. Not used with config or config_yaml."
}

variable "otlp_protocol" {
  type        = string
  default     = "http"
  description = "OTLP protocol for otlp_endpoint: \"http\" (the otlp_http exporter) or \"grpc\" (the otlp_grpc exporter)."

  validation {
    condition     = contains(["http", "grpc"], var.otlp_protocol)
    error_message = "otlp_protocol must be \"http\" or \"grpc\"."
  }
}

variable "otlp_headers" {
  type        = map(string)
  default     = {}
  description = "Headers the default config sends to otlp_endpoint, such as { Authorization = \"Bearer $${env:OTLP_TOKEN}\" }. They're in the plan and the config, so put secrets in environment and refer to them."
}

variable "debug_exporter" {
  type        = bool
  default     = false
  description = "Also send everything in the default config to the debug exporter, which writes a line per batch to the collector's journal. Always on when otlp_endpoint is null."
}

variable "collection_interval" {
  type        = string
  default     = "60s"
  description = "How often the default config's hostmetrics receiver reads the host, as a duration such as \"30s\"."

  validation {
    condition     = can(regex("^[0-9]+(ms|s|m|h)$", var.collection_interval))
    error_message = "collection_interval must be a duration such as \"30s\" or \"1m\"."
  }
}

variable "environment" {
  type        = map(string)
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "Environment variables for the collector, such as { OTLP_TOKEN = \"...\" }, for the config to read as $${env:OTLP_TOKEN}. Written to /etc/DISTRIBUTION/conn3x.env, mode 0600; it never reaches state or the plan."

  validation {
    condition     = var.environment == null || try(alltrue([for k, v in var.environment : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k)) && !strcontains(v, "\n")]), false)
    error_message = "environment maps variable names, such as OTLP_TOKEN, to values on one line."
  }
}
