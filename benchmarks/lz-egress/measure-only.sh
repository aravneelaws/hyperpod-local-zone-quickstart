#!/usr/bin/env bash
# Run measure.sh against an already-deployed stack (skips deploy/teardown).
# Useful for re-running measurements without paying the ~2-minute NAT
# create/delete cycle.
#
# Usage: ./measure-only.sh <A|B|C>
# The stack name is derived the same way as run.sh:
#   ${STACK_PREFIX:-hp-lz-egress-test}-<lowercase config>

set -euo pipefail

: "${AWS_REGION:=us-west-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"

CONFIG="${1:?usage: $0 <A|B|C>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STACK_SUFFIX=$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')
STACK="${STACK_PREFIX:-hp-lz-egress-test}-${STACK_SUFFIX}"
MEASURE="$HERE/measure.sh"
RESULTS_DIR="$HERE/results"
mkdir -p "$RESULTS_DIR"

get_out() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --region "$AWS_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text 2>/dev/null
}
INSTANCE_ID=$(get_out InstanceId)
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] || {
  echo "no InstanceId in $STACK - has it been deployed?" >&2
  exit 1
}

echo "===> Instance: $INSTANCE_ID"
echo "===> Waiting for SSM..."
STATE=None
for i in $(seq 1 60); do
  STATE=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null || echo "None")
  [[ "$STATE" == "Online" ]] && { echo "===> SSM ready ($i)"; break; }
  sleep 10
done
[[ "$STATE" == "Online" ]] || { echo "SSM never became Online. Check NAT egress." >&2; exit 1; }

sleep 20  # let user-data settle

FSX_DNS="" ; FSX_MOUNT=""
if [[ "$CONFIG" == "C" ]]; then
  FSX_DNS=$(get_out FsxDnsName || echo "")
  FSX_MOUNT=$(get_out FsxMountName || echo "")
  echo "===> FSx: dns=$FSX_DNS mount=$FSX_MOUNT"
fi

SCRIPT_B64=$(base64 -i "$MEASURE" | tr -d '\n')

# Build the SSM parameters JSON via python to avoid shell-quoting pitfalls with
# a long base64 payload.
PARAM_JSON=$(mktemp)
python3 - <<PY > "$PARAM_JSON"
import json
cmds = [
    "set -eu",
    "echo '${SCRIPT_B64}' | base64 -d > /tmp/measure.sh".replace("\${SCRIPT_B64}", "$SCRIPT_B64"),
    "chmod +x /tmp/measure.sh",
    "LZ_CONFIG=$CONFIG FSX_DNS='$FSX_DNS' FSX_MOUNT='$FSX_MOUNT' /tmp/measure.sh",
]
print(json.dumps({"commands": cmds}))
PY

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "lz-egress-test $CONFIG" \
  --timeout-seconds 1200 \
  --parameters "file://$PARAM_JSON" \
  --query "Command.CommandId" --output text)
echo "===> SSM command: $CMD_ID"
rm -f "$PARAM_JSON"

for _ in $(seq 1 120); do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query "Status" --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Success) echo "===> Success"; break ;;
    Failed|Cancelled|TimedOut) echo "===> Status: $STATUS"; break ;;
  esac
  sleep 10
done

OUT="$RESULTS_DIR/$CONFIG.json"
ERR="$RESULTS_DIR/$CONFIG.err"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query "StandardOutputContent" --output text > "$OUT"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query "StandardErrorContent" --output text > "$ERR"

echo "===> Wrote $OUT ($(wc -c < "$OUT") bytes)"
echo "===> stderr: $(wc -c < "$ERR") bytes"
