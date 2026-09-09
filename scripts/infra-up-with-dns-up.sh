#!/bin/bash
# =============================================================================
# infra-up-with-dns.sh
# Purpose: Brings up full infrastructure including DNS
# Usage:   ./scripts/infra-up-with-dns.sh
# Note:    After running, update BigRock nameservers with the new NS records
#          output by terraform apply — hosted zone gets new NS records each
#          time it is recreated.
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Step 1 — Bring up EKS infrastructure + app + Datadog
"$SCRIPT_DIR/infra-up.sh"

# Step 2 — Apply DNS resources (recreates hosted zone + CNAME)
echo ""
echo "=== Applying DNS resources ==="
cd "$PROJECT_ROOT/infrastructure/terraform/dns"
terraform apply -auto-approve

echo ""
echo "========================================"
echo " Infrastructure + DNS is UP"
echo " IMPORTANT: Check terraform output above"
echo " Update BigRock nameservers if NS records changed"
echo "========================================"