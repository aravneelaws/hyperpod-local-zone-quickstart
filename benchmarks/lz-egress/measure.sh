#!/bin/bash
# LZ egress measurement script. Executed on the test EC2 instance via SSM
# Send-Command. Emits a single JSON document to stdout that the outer runner
# captures. Any tool installs are best-effort and idempotent.
#
# Environment inputs:
#   LZ_CONFIG   - free-form label written into the result JSON (e.g. "A", "B", "C").
#   FSX_DNS     - optional. FSx Lustre DNS name from the stack outputs.
#   FSX_MOUNT   - optional. Lustre mount name (paired with FSX_DNS).
#                 When both are set, runs a small metadata smoke test.

set -u
LC_ALL=C

CONFIG="${LZ_CONFIG:-unknown}"
LOG="/tmp/lz-egress-${CONFIG}.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== LZ egress test start: config=$CONFIG at $(date -u +%FT%TZ) ==="

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

# Metadata: IMDSv2
IMDS_TOK=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || echo "")
imds() {
  curl -sS -H "X-aws-ec2-metadata-token: $IMDS_TOK" \
    "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null
}
INSTANCE_ID=$(imds instance-id)
AZ_NAME=$(imds placement/availability-zone)
AZ_ID=$(imds placement/availability-zone-id)
LOCAL_IPV4=$(imds local-ipv4)
# Private-only instances return HTML 404 for public-ipv4; filter to plain IPs.
PUBLIC_IPV4=$(imds public-ipv4 2>/dev/null | grep -v '<' | grep -E '^[0-9.]+$' || echo "none")

# Install measurement tools (idempotent; safe to re-run on every invocation).
sudo dnf install -y --quiet traceroute bind-utils >/dev/null 2>&1 || dnf install -y --quiet traceroute bind-utils >/dev/null 2>&1 || true

# ============================================================================
# 1. curl timings against 5 public endpoints (3 trials per endpoint).
#    Fresh TCP connect on each trial, so the DNS/connect/TLS phases are
#    measured directly rather than reusing a connection.
# ============================================================================
CURL_FORMAT='{"dns":%{time_namelookup},"connect":%{time_connect},"appconn":%{time_appconnect},"pretxfer":%{time_pretransfer},"ttfb":%{time_starttransfer},"total":%{time_total},"http":%{http_code},"size":%{size_download},"speed":%{speed_download}}'
targets=(
  "https://pypi.org/simple/"
  "https://github.com/robots.txt"
  "https://huggingface.co/robots.txt"
  "http://archive.ubuntu.com/ubuntu/dists/noble/InRelease"
  "https://speed.cloudflare.com/__down?bytes=25000000"
)
CURL_RESULTS="["
first=1
for url in "${targets[@]}"; do
  for trial in 1 2 3; do
    row=$(curl -sS -o /dev/null -w "$CURL_FORMAT" --connect-timeout 20 --max-time 60 "$url" 2>/dev/null || echo '{}')
    row=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '{}'); d['url']='$url'; d['trial']=$trial; print(json.dumps(d))" <<< "$row")
    [[ $first -eq 1 ]] && first=0 || CURL_RESULTS+=","
    CURL_RESULTS+="$row"
  done
done
CURL_RESULTS+="]"

# ============================================================================
# 2. Traceroute to a public host. Hop 1 latency reveals whether the LZ
#    subnet's first-hop NAT is LZ-local (sub-millisecond) or parent-AZ
#    (LZ<->region RTT, distance-dependent).
# ============================================================================
TRACEROUTE=$(traceroute -n -w 2 -q 1 -m 20 1.1.1.1 2>&1 | json_escape)

# ============================================================================
# 3. Path MTU probes. ping -M do sets the DF bit; if the path can't carry
#    that payload without fragmentation, packets are dropped.
#    8973 = 9001 payload minus 28 (IP+ICMP hdr).
#    1472 = 1500 - 28. 1272 = 1300 - 28.
#    Note: the 9001 MTU documented for LZ<->LZ traffic does NOT apply to
#    public internet egress; both configs cap at 1500 to the internet.
#    Kept in the script because it's cheap and disambiguates internal vs
#    external MTU behavior.
# ============================================================================
MTU_9001=$(ping -M do -s 8973 -c 3 -W 2 1.1.1.1 2>&1 | tail -3 | json_escape)
MTU_1472=$(ping -M do -s 1472 -c 3 -W 2 1.1.1.1 2>&1 | tail -3 | json_escape)
MTU_1272=$(ping -M do -s 1272 -c 3 -W 2 1.1.1.1 2>&1 | tail -3 | json_escape)

# ============================================================================
# 4. DNS timing via the VPC resolver (169.254.169.253). Not a substitute for
#    CoreDNS-in-cluster timing, but useful as a resolver-path RTT baseline.
# ============================================================================
DNS_RESULTS="["
dfirst=1
for host in pypi.org github.com huggingface.co archive.ubuntu.com speed.cloudflare.com; do
  for trial in 1 2 3; do
    d=$(dig +tries=1 +time=3 +stats "$host" @169.254.169.253 2>/dev/null | awk '/Query time:/ {print $4}' | head -1)
    d="${d:-null}"
    [[ $dfirst -eq 1 ]] && dfirst=0 || DNS_RESULTS+=","
    DNS_RESULTS+="{\"host\":\"$host\",\"trial\":$trial,\"ms\":$d}"
  done
done
DNS_RESULTS+="]"

# ============================================================================
# 5. Optional FSx-in-LZ metadata smoke test. Runs only when FSX_DNS and
#    FSX_MOUNT are set (Config C). Times 50 small file creates/stats/
#    listings/deletes to compare against node-local /tmp.
# ============================================================================
FSX_RESULTS='"skipped"'
if [[ -n "${FSX_DNS:-}" && -n "${FSX_MOUNT:-}" ]]; then
  if ! command -v mount.lustre >/dev/null 2>&1; then
    dnf install -y --quiet https://fsx-lustre-client-repo.s3.amazonaws.com/al/2023/fsx-lustre-client-repo-1-8.el9.noarch.rpm 2>&1 >>"$LOG" || true
    dnf install -y --quiet kmod-lustre-client lustre-client 2>&1 >>"$LOG" || true
  fi
  mkdir -p /mnt/fsx
  if mount -t lustre "${FSX_DNS}@tcp:/${FSX_MOUNT}" /mnt/fsx 2>>"$LOG"; then
    TESTDIR="/mnt/fsx/lz-test-$(date +%s)-$$"
    mkdir -p "$TESTDIR"
    T_CREATE=$( { time -p bash -c 'for i in $(seq 1 50); do echo x > '"$TESTDIR"'/f_$i; done'; } 2>&1 | awk '/real/{print $2}')
    T_STAT=$( { time -p bash -c 'for i in $(seq 1 50); do stat '"$TESTDIR"'/f_$i >/dev/null; done'; } 2>&1 | awk '/real/{print $2}')
    T_LIST=$( { time -p bash -c 'ls '"$TESTDIR"' >/dev/null'; } 2>&1 | awk '/real/{print $2}')
    T_DELETE=$( { time -p bash -c 'rm '"$TESTDIR"'/f_*'; } 2>&1 | awk '/real/{print $2}')
    rmdir "$TESTDIR" 2>/dev/null || true
    umount /mnt/fsx 2>/dev/null || true
    FSX_RESULTS="{\"create_50\":\"$T_CREATE\",\"stat_50\":\"$T_STAT\",\"list\":\"$T_LIST\",\"delete_50\":\"$T_DELETE\",\"dns\":\"$FSX_DNS\",\"mount\":\"$FSX_MOUNT\"}"
  else
    FSX_RESULTS="{\"mount_error\":\"see log\"}"
  fi
fi

# ============================================================================
# Assemble the result JSON and print it. The outer runner captures stdout.
# ============================================================================
cat <<EOF
{
  "meta": {
    "config": "$CONFIG",
    "timestamp": "$(date -u +%FT%TZ)",
    "instance_id": "$INSTANCE_ID",
    "az_name": "$AZ_NAME",
    "az_id": "$AZ_ID",
    "local_ipv4": "$LOCAL_IPV4",
    "public_ipv4": "$PUBLIC_IPV4"
  },
  "curl": $CURL_RESULTS,
  "traceroute": $TRACEROUTE,
  "mtu": {
    "size_8973_9001mtu": $MTU_9001,
    "size_1472_1500mtu": $MTU_1472,
    "size_1272_1300mtu": $MTU_1272
  },
  "dns_ms": $DNS_RESULTS,
  "fsx": $FSX_RESULTS
}
EOF
echo "=== LZ egress test end at $(date -u +%FT%TZ) ==="
