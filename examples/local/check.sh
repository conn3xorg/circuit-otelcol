# Run on the host. The live config is the one validate passed, with
# DEPLOY_ENV from the write-only environment file. A log posted over OTLP
# reaches the file exporter with that value, and host metrics reach the
# Prometheus exporter. Each run posts its own message, so an earlier run's
# output can't pass it.
set -eu
msg=hello-from-ci-$(date +%s)
for _ in $(seq 30); do systemctl is-active -q otelcol-contrib && break; sleep 1; done
systemctl is-active otelcol-contrib
cmp /etc/otelcol-contrib/config.yaml.conn3x /etc/otelcol-contrib/config.yaml
[ "$(stat -c %a /etc/otelcol-contrib/conn3x.env)" = 600 ]
(set -a; . /etc/otelcol-contrib/conn3x.env; otelcol-contrib validate --config=/etc/otelcol-contrib/config.yaml)
for _ in $(seq 30); do
  curl -sf -X POST -H 'Content-Type: application/json' http://127.0.0.1:4318/v1/logs \
    -d '{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"body":{"stringValue":"'"$msg"'"}}]}]}]}' && break
  sleep 1
done
for _ in $(seq 30); do
  grep -q "$msg" /tmp/otelcol-out.json 2>/dev/null && break
  sleep 1
done
grep "$msg" /tmp/otelcol-out.json | grep -q '"deployment.environment","value":{"stringValue":"local"}'
for _ in $(seq 60); do
  curl -sf http://127.0.0.1:8889/metrics | grep -q '^system_cpu_' && exit 0
  sleep 1
done
exit 1
