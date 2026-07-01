#!/bin/bash
set -e

ALB_DNS="scalable-nginx-alb-1730992489.us-east-1.elb.amazonaws.com"

echo "=================================================="
echo " AWS Nginx Production Verification Script"
echo "=================================================="

echo -e "\n1. Testing Main Landing Page (http://$ALB_DNS/)..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://$ALB_DNS/)
echo "Status Code: $HTTP_STATUS"
if [ "$HTTP_STATUS" -eq 200 ]; then
  echo ">>> [PASS] Webpage is online."
else
  echo ">>> [FAIL] Webpage returned status $HTTP_STATUS"
fi

echo -e "\n2. Testing Health Probe Endpoint (http://$ALB_DNS/healthz)..."
HEALTH_RESP=$(curl -s http://$ALB_DNS/healthz | tr -d '\r\n')
if [ "$HEALTH_RESP" = "OK" ]; then
  echo ">>> [PASS] Health check is active (OK)."
else
  echo ">>> [FAIL] Health check returned: $HEALTH_RESP"
fi

echo -e "\n3. Testing Observability Metrics (http://$ALB_DNS/metrics)..."
METRICS_RESP=$(curl -s http://$ALB_DNS/metrics)
if [[ "$METRICS_RESP" =~ "Active connections" ]]; then
  echo ">>> [PASS] Metrics stub status module is active."
  echo "Metrics Snapshot:"
  echo "$METRICS_RESP" | sed 's/^/  /'
else
  echo ">>> [FAIL] Metrics check failed."
fi

echo -e "\n4. Verifying AWS Infrastructure via AWS CLI..."
if command -v aws &> /dev/null; then
  echo "Querying active instances associated with tag 'scalable-nginx-worker'..."
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=scalable-nginx-worker" "Name=instance-state-name,Values=running" \
    --query "Reservations[*].Instances[*].[InstanceId,State.Name,Placement.AvailabilityZone]" \
    --output table

  echo "Querying Auto Scaling Group Policy config..."
  aws autoscaling describe-policies \
    --query "ScalingPolicies[?TargetTrackingConfiguration.PredefinedMetricSpecification.PredefinedMetricType=='ASGAverageCPUUtilization'].{Name:PolicyName,ASG:AutoScalingGroupName,TargetCPU:TargetTrackingConfiguration.TargetValue}" \
    --output table
else
  echo ">>> [WARN] AWS CLI is not installed on this local system. Skipping infrastructure query."
fi

echo "=================================================="
echo " Verification Complete"
echo "=================================================="
