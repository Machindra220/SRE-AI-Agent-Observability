# ─────────────────────────────────────────────────────────────
# providers.tf
# Configures Terraform version, required providers (Datadog + AWS),
# and wires Datadog API/APP keys from AWS Secrets Manager.
# State is stored locally (terraform.tfstate in this directory).
# ─────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Datadog provider — manages monitors, dashboards, SLOs
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.39"
    }
    # AWS provider — used only to read secrets from Secrets Manager
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Local state — terraform.tfstate stored in this directory
}

# AWS provider — region must match where secrets are stored
provider "aws" {
  region = "us-east-1"
}

# ── Fetch Datadog keys from AWS Secrets Manager ───────────────
# Secret: sre-ai-agent/datadog
# Secret: sre-demo/datadog2
# Keys  : DD_API_KEY, DD_APP_KEY
data "aws_secretsmanager_secret" "datadog" {
  name = "sre-demo/datadog2"
}

data "aws_secretsmanager_secret_version" "datadog" {
  secret_id = data.aws_secretsmanager_secret.datadog.id
}

# Parse the JSON secret and extract individual keys
locals {
  datadog_secrets = jsondecode(data.aws_secretsmanager_secret_version.datadog.secret_string)
}

# ── Datadog provider — keys sourced from Secrets Manager ─────
provider "datadog" {
  api_key = local.datadog_secrets["DD_API_KEY"]
  app_key = local.datadog_secrets["DD_APP_KEY"]
  api_url = "https://api.datadoghq.com/"
}

