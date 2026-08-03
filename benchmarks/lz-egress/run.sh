#!/usr/bin/env bash
# Orchestrate one A/B/C LZ egress test iteration end-to-end:
#   1. Deploy the CFN stack with the requested LocalZoneEgress / CreateFsxInLz
#      combination
#   2. Wait for the EC2 test instance to register with SSM
#   3. Run measure.sh on the instance via SSM Run Command
#   4. Save the resulting JSON under ./results/
#   5. Tear the stack down (skipped when KEEP_STACK=1)
#
# Prerequisites:
#   AWS_PROFILE  - a profile with permission to create VPC + EC2 + IAM +
#                  optional FSx in the target region. If not set, the
#                  default credential provider chain is used.
#   AWS_REGION   - target region. Defaults to us-west-2.
#
# Deploy-time overrides (pass to `deploy` if you want to target a different
# LZ than the template default of Phoenix; see test-stack.yaml Parameters):
#   LOCAL_ZONE_ID
#   LOCAL_ZONE_NAME
#   NETWORK_BORDER_GROUP
#   PARENT_AZ
# Any that are unset fall back to the template defaults.
#
# Usage: ./run.sh <A|B|C>

set -euo pipefail

: "${AWS_REGION:=us-west-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"

CONFIG="${1:?usage: $0 <A|B|C>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STACK_SUFFIX=$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')
STACK="${STACK_PREFIX:-hp-lz-egress-test}-${STACK_SUFFIX}"
TEMPLATE="$HERE/test-stack.yaml"
MEASURE="$HERE/measure.sh"

case "$CONFIG" in
  A) BASE_PARAMS="ParameterKey=LocalZoneEgress,ParameterValue=false ParameterKey=CreateFsxInLz,ParameterValue=false" ;;
  B) BASE_PARAMS="ParameterKey=LocalZoneEgress,ParameterValue=true  ParameterKey=CreateFsxInLz,ParameterValue=false" ;;
  C) BASE_PARAMS="ParameterKey=LocalZoneEgress,ParameterValue=true  ParameterKey=CreateFsxInLz,ParameterValue=true" ;;
  *) echo "config must be A, B, or C" >&2; exit 2 ;;
esac

# Optional overrides for targeting a different LZ than the template default.
EXTRA_PARAMS=""
[[ -n "${LOCAL_ZONE_ID:-}" ]]         && EXTRA_PARAMS+=" ParameterKey=LocalZoneId,ParameterValue=$LOCAL_ZONE_ID"
[[ -n "${LOCAL_ZONE_NAME:-}" ]]       && EXTRA_PARAMS+=" ParameterKey=LocalZoneName,ParameterValue=$LOCAL_ZONE_NAME"
[[ -n "${NETWORK_BORDER_GROUP:-}" ]]  && EXTRA_PARAMS+=" ParameterKey=NetworkBorderGroup,ParameterValue=$NETWORK_BORDER_GROUP"
[[ -n "${PARENT_AZ:-}" ]]             && EXTRA_PARAMS+=" ParameterKey=ParentAz,ParameterValue=$PARENT_AZ"

RESULTS_DIR="$HERE/results"
mkdir -p "$RESULTS_DIR"

echo "===> $(date -u +%FT%TZ) Deploying $STACK (Config $CONFIG)"
aws cloudformation deploy \
  --stack-name "$STACK" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides $BASE_PARAMS $EXTRA_PARAMS \
  --tags Project=hp-lz-egress-test Config="$CONFIG" \
  --no-fail-on-empty-changeset

get_out() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}
INSTANCE_ID=$(get_out InstanceId)
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] || {
  echo "no InstanceId in $STACK outputs; check 'aws cloudformation describe-stacks --stack-name $STACK'" >&2
  exit 1
}
LZ_NAT_EIP=$(get_out LzNatEipAddress 2>/dev/null || echo none)
PARENT_NAT_EIP=$(get_out ParentNatEipAddress 2>/dev/null || echo none)
echo "===> Instance: $INSTANCE_ID   ParentNatEip: $PARENT_NAT_EIP   LzNatEip: $LZ_NAT_EIP"

# Wait for SSM to see the instance.
echo "===> Waiting for SSM to register the instance..."
STATE=None
for _ in $(seq 1 60); do
  STATE=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null || echo "None")
  [[ "$STATE" == "Online" ]] && { echo "===> SSM ready"; break; }
  sleep 10
done
[[ "$STATE" == "Online" ]] || { echo "SSM never became Online. Check NAT egress." >&2; exit 1; }

# Extra dwell for user-data (traceroute / bind-utils install).
sleep 20

# For Config C, pass FSx DNS/mount name into the SSM env.
FSX_DNS="" ; FSX_MOUNT=""
if [[ "$CONFIG" == "C" ]]; then
  FSX_DNS=$(get_out FsxDnsName 2>/dev/null || echo "")
  FSX_MOUNT=$(get_out FsxMountName 2>/dev/null || echo "")
  echo "===> FSx: dns=$FSX_DNS mount=$FSX_MOUNT"
fi

# Inline the measurement script over SSM (avoids needing a shared upload step).
SCRIPT_B64=$(base64 -i "$MEASURE" | tr -d '\n')

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "lz-egress-test $CONFIG" \
  --timeout-seconds 1200 \
  --parameters commands="[
    \"set -eu\",
    \"echo '$SCRIPT_B64' | base64 -d > /tmp/measure.sh\",
    \"chmod +x /tmp/measure.sh\",
    \"LZ_CONFIG=$CONFIG FSX_DNS='$FSX_DNS' FSX_MOUNT='$FSX_MOUNT' /tmp/measure.sh\"
  ]" \
  --query "Command.CommandId" --output text)
echo "===> SSM command: $CMD_ID"

# Poll until the command reaches a terminal status.
for _ in $(seq 1 120); do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query "Status" --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Success|Failed|Cancelled|TimedOut) break ;;
  esac
  sleep 10
done
[[ "$STATUS" == "Success" ]] || echo "SSM command finished with $STATUS" >&2

OUT="$RESULTS_DIR/$CONFIG.json"
ERR="$RESULTS_DIR/$CONFIG.err"
aws ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query "StandardOutputContent" --output text > "$OUT"
aws ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query "StandardErrorContent" --output text > "$ERR"

echo "===> Wrote $OUT ($(wc -c < "$OUT") bytes), stderr: $(wc -c < "$ERR") bytes"

if [[ "${KEEP_STACK:-0}" != "1" ]]; then
  echo "===> Deleting stack..."
  aws cloudformation delete-stack --stack-name "$STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK" 2>&1 || \
    echo "stack-delete-complete wait returned nonzero; check for GuardDuty/VPC-endpoint leftovers"
fi

echo "===> $(date -u +%FT%TZ) Done: Config $CONFIG"
