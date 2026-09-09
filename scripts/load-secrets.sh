#!/bin/bash
# =============================================================================
# load-secrets.sh
# Purpose: Loads all project secrets from AWS Secrets Manager
# Usage:   source ./scripts/load-secrets.sh
# IMPORTANT: Must be sourced not executed - use: source scripts/load-secrets.sh
# =============================================================================

echo "=== Loading secrets from AWS Secrets Manager ==="

# Retrieves Datadog secrets
DD_SECRETS=$(aws secretsmanager get-secret-value \
  --secret-id "sre-demo/datadog2" \
  --region us-east-1 \
  --query 'SecretString' \
  --output text)

export DD_API_KEY=$(echo $DD_SECRETS | python3 -c "import sys,json; print(json.load(sys.stdin)['DD_API_KEY'])")
export DD_APP_KEY=$(echo $DD_SECRETS | python3 -c "import sys,json; print(json.load(sys.stdin)['DD_APP_KEY'])")

echo "✅ DD_API_KEY loaded (${DD_API_KEY:0:8}...)"
echo "✅ DD_APP_KEY loaded (${DD_APP_KEY:0:8}...)"

# Retrieves AWS IAM keys
AWS_SECRETS=$(aws secretsmanager get-secret-value \
  --secret-id "sre-demo/aws-iam" \
  --region us-east-1 \
  --query 'SecretString' \
  --output text)

export AWS_ACCESS_KEY_ID=$(echo $AWS_SECRETS | python3 -c "import sys,json; print(json.load(sys.stdin)['AWS_ACCESS_KEY_ID'])")
export AWS_SECRET_ACCESS_KEY=$(echo $AWS_SECRETS | python3 -c "import sys,json; print(json.load(sys.stdin)['AWS_SECRET_ACCESS_KEY'])")

echo "✅ AWS_ACCESS_KEY_ID loaded (${AWS_ACCESS_KEY_ID:0:8}...)"
echo "✅ AWS_SECRET_ACCESS_KEY loaded"

echo "=== All secrets loaded ==="
