# circuit-otelcol

A Conn3x circuit that installs the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) on your hosts, as an agent for each host or as a gateway for others, and keeps it running. It installs the official `.deb` or `.rpm` from a pinned [release](https://github.com/open-telemetry/opentelemetry-collector-releases/releases), checks its SHA-256 first, and only puts a config live after the collector's own `validate` has passed it.

Out of the box, each host sends its CPU, memory, disk, filesystem, network and paging metrics, its systemd journal, and anything local applications send over OTLP, on to an OTLP endpoint you name. Give it a config of your own and it runs that instead.

## Usage

```hcl
variable "otlp_token" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "otelcol" {
  source = "github.com/conn3xorg/circuit-otelcol?ref=v0.1.0"

  hosts = {
    web1 = "203.0.113.10"
    web2 = "203.0.113.11"
  }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  otlp_endpoint = "https://otlp.example.com"
  otlp_headers  = { Authorization = "Bearer $${env:OTLP_TOKEN}" }
  environment   = { OTLP_TOKEN = var.otlp_token }
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

`$${env:OTLP_TOKEN}` is the collector's own syntax for an environment variable; the extra `$` stops OpenTofu reading it as interpolation. The token itself goes in `environment`, which is ephemeral: it's written to a file on the host and never reaches the plan or the state. Pass it from an ephemeral variable, as here, or from an ephemeral resource that reads your secrets store, such as one run by circuit-openbao.

Leave out `otlp_endpoint` and the default config prints a line per batch to the collector's journal through the `debug` exporter instead, which is a quick way to see that data flows:

```sh
journalctl -u otelcol-contrib -f
```

To try it on a throwaway container first, see [examples/local](examples/local).

### Your own config

`config` takes the whole collector config as an HCL object and writes it as YAML. This one takes OTLP on every address, so the host can act as a gateway for others, and sends on to Honeycomb:

```hcl
module "otelcol" {
  source = "github.com/conn3xorg/circuit-otelcol?ref=v0.1.0"

  hosts       = { gw1 = "10.0.0.5" }
  environment = { HONEYCOMB_API_KEY = var.honeycomb_api_key }

  config = {
    receivers = {
      otlp = { protocols = { grpc = { endpoint = "0.0.0.0:4317" }, http = { endpoint = "0.0.0.0:4318" } } }
    }
    processors = {
      memory_limiter = { check_interval = "1s", limit_percentage = 80, spike_limit_percentage = 20 }
      batch          = {}
    }
    exporters = {
      otlp_http = {
        endpoint = "https://api.honeycomb.io"
        headers  = { "x-honeycomb-team" = "$${env:HONEYCOMB_API_KEY}" }
      }
    }
    service = {
      pipelines = {
        traces  = { receivers = ["otlp"], processors = ["memory_limiter", "batch"], exporters = ["otlp_http"] }
        metrics = { receivers = ["otlp"], processors = ["memory_limiter", "batch"], exporters = ["otlp_http"] }
        logs    = { receivers = ["otlp"], processors = ["memory_limiter", "batch"], exporters = ["otlp_http"] }
      }
    }
  }
}
```

If you'd rather keep the config as YAML, pass it as a string with `config_yaml = file("${path.module}/otelcol.yaml")`. In a file read with `file()`, `${env:NAME}` needs no extra `$`.

The circuit doesn't open a firewall port. For a gateway, open 4317 and 4318 to your other hosts with a `firewalld` or `ufw` step of your own.

### Into Prometheus

There are two ways to get the collector's metrics into [circuit-prometheus](https://github.com/conn3xorg/circuit-prometheus).

Prometheus can scrape them. Add a `prometheus` exporter to the config and the metrics pipeline, such as `prometheus = { endpoint = "0.0.0.0:8889" }`, and list each host in circuit-prometheus's `scrape_targets`, such as `{ otelcol = ["10.0.0.5:8889"] }`. Metric names come out the way Prometheus expects, such as `system_cpu_time_seconds_total`.

Or the collector can push them. Start Prometheus with `extra_args = ["--web.enable-remote-write-receiver"]` and an address the collector can reach, and use the `prometheus_remote_write` exporter with `endpoint = "http://PROMETHEUS:9090/api/v1/write"`.

If you only want host metrics in Prometheus, [circuit-node-exporter](https://github.com/conn3xorg/circuit-node-exporter) is the smaller tool.

## What it does

On each host, in order:

1. Stops and disables the other distribution's service, if it's there from an earlier apply, so the two don't fight over ports. Its package stays installed.
2. Installs `curl` if it's missing.
3. Downloads `DISTRIBUTION_VERSION_linux_ARCH.deb` or `.rpm` from the GitHub release into `/var/cache/conn3x-otelcol`. If the checksum doesn't match `checksums`, the apply fails and nothing is installed.
4. Installs it with `apt-get` or `dnf`, unless that version is already installed. The package creates its own system user, enables the service, and starts it with upstream's example config, which the steps below replace.
5. Writes `environment` to `/etc/DISTRIBUTION/conn3x.env`, mode 0600, owned by root. Only an HMAC of the content is kept in state.
6. Writes a systemd drop-in that reads that file and adds the collector to the `systemd-journal` group, so the journald receiver can read the whole journal, and reloads systemd when the drop-in changes.
7. Writes the rendered config to `/etc/DISTRIBUTION/config.yaml.conn3x`.
8. Runs `DISTRIBUTION validate` on it with the same environment the service gets. Only when that passes does it copy the file over `/etc/DISTRIBUTION/config.yaml`, the file the service runs with. A config that fails stops the apply there, with the collector's own error, and the running collector keeps its old config. A hand edit to the live file is put back on the next apply.
9. Starts the collector now and at boot, and restarts it when the package, the environment, the drop-in or the config changed.

Before the circuit runs, the `conn3x_host` data source reads each host's distribution and architecture over SSH. Debian and Ubuntu get the `.deb`, the Red Hat family the `.rpm`, and `x86_64` and `aarch64` the `amd64` and `arm64` builds. For a host created in the same plan, give its `os` and `arch` in a host object, such as `{ address = "203.0.113.10", os = "ubuntu", arch = "x86_64" }`.

### The default config

Without `config` or `config_yaml`, the collector gets:

- An `otlp` receiver on `127.0.0.1:4317` (gRPC) and `127.0.0.1:4318` (HTTP), for applications on the same host.
- A `host_metrics` receiver with the cpu, load, memory, disk, filesystem, network and paging scrapers, every `collection_interval`.
- With otelcol-contrib, a `journald` receiver. The core `otelcol` build has no journald receiver, so it sends metrics and OTLP only.
- The `resource_detection` processor, which adds the host name, and `batch`. With journald, a `filter` processor drops the collector's own journal lines, which would otherwise come round again.
- An `otlp_http` exporter, or `otlp_grpc` with `otlp_protocol = "grpc"`, to `otlp_endpoint`, and the `debug` exporter when `otlp_endpoint` is null or `debug_exporter` is true.

### Distributions

`otelcol-contrib`, the default, has the most receivers, processors and exporters, journald and the vendor exporters among them. `otelcol` is the smaller core build. Both come from the same release with the same version number, and `checksums` has an entry for each. Switching from one to the other stops the old service and starts the new one.

### Upgrading

Set `otelcol_version` and `checksums` together. Each package has a `.sha256` file beside it on the release:

```sh
v=0.164.0
for f in otelcol-contrib_${v}_linux_{amd64,arm64}.{deb,rpm} otelcol_${v}_linux_{amd64,arm64}.{deb,rpm}; do
  echo "$f $(curl -sL https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$v/$f.sha256)"
done
```

The new package installs over the old one, keeps the circuit's config, and the collector restarts. The config is validated again by the new version before the apply finishes. Collector releases sometimes rename or drop components, so read the release notes first. The old package file stays in `/var/cache/conn3x-otelcol` until you remove it.

The default config uses component names from 0.164.0, such as `host_metrics` and `otlp_http`. To run an older release, pass a config of your own with the older names.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts`, `os` and `arch`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `distribution` | string | `"otelcol-contrib"` | `"otelcol-contrib"` or `"otelcol"`. |
| `otelcol_version` | string | `"0.164.0"` | Collector release to install, without the leading `v`. |
| `checksums` | map(string) | The 0.164.0 checksums | SHA-256 of each package, keyed `DISTRIBUTION_ARCH.EXT`, such as `otelcol-contrib_amd64.deb`. |
| `config` | any | `null` | The whole collector config as an HCL object, written as YAML. Replaces the default config. |
| `config_yaml` | string | `null` | The whole collector config as a YAML string. Set this or `config`, not both. |
| `otlp_endpoint` | string | `null` | Where the default config sends everything over OTLP. When null, it uses the debug exporter. |
| `otlp_protocol` | string | `"http"` | `"http"` or `"grpc"`, for `otlp_endpoint`. |
| `otlp_headers` | map(string) | `{}` | Headers for `otlp_endpoint`. They're in the plan, so refer to secrets with `$${env:NAME}`. |
| `debug_exporter` | bool | `false` | Also send everything in the default config to the debug exporter. |
| `collection_interval` | string | `"60s"` | How often the default config reads host metrics. |
| `environment` | map(string) | `null` | Ephemeral and sensitive. Environment variables for the collector, such as API keys, for the config to read as `${env:NAME}`. Never in the plan or state. |

## Outputs

| Name | Description |
| --- | --- |
| `service` | Name of the collector's systemd service, such as `otelcol-contrib`. |
| `config_file` | Path of the live config on each host, such as `/etc/otelcol-contrib/config.yaml`. |

## Requirements

Requires Conn3x v0.6.9 or later, systemd on each host, and outbound HTTPS to github.com. Hosts must be x86_64 or arm64.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, checks that the second plan has no changes, posts a log over OTLP to `127.0.0.1:4318` and finds it in the file exporter's output with a value from `environment`, and reads `system_cpu_` metrics from the Prometheus exporter on `127.0.0.1:8889`.

By hand, on arm64 Rocky Linux 10 and Fedora 45 containers, the default config ran with each `otlp_protocol` and with the core `otelcol` build, switching builds stopped the other one, a config that fails `validate` stopped the apply and left the live config alone, and a secret in `environment` stayed out of the state file.

It was also applied to an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet with SELinux enforcing. Both started on 0.163.2 and were upgraded to 0.164.0, which kept the circuit's config. Journal lines reached the file exporter, `system_cpu_time_seconds_total` was on the Prometheus exporter, and the CI check passed. After a reboot the collector came back, the check passed again, the plan had no changes and there were no SELinux denials.

## License

MPL-2.0. See [LICENSE](LICENSE). The OpenTelemetry Collector itself is Apache-2.0.
