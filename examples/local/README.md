# Local example

Applies circuit-otelcol to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman.

The example's config takes OTLP over HTTP on `127.0.0.1:4318` and writes what arrives to `/tmp/otelcol-out.json`, tagged with `DEPLOY_ENV` from the write-only environment file. It also serves the host's metrics for Prometheus on `127.0.0.1:8889`.

Rootful Podman is simplest. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To send the collector a log and see it come out the other side:

```sh
ssh="ssh -p 2303 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1"
$ssh "curl -s -X POST -H 'Content-Type: application/json' http://127.0.0.1:4318/v1/logs \
  -d '{\"resourceLogs\":[{\"scopeLogs\":[{\"logRecords\":[{\"body\":{\"stringValue\":\"hello\"}}]}]}]}'"
$ssh cat /tmp/otelcol-out.json
$ssh "curl -s http://127.0.0.1:8889/metrics | grep ^system_cpu_"
```

`up.sh` listens on `127.0.0.1:2303`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
