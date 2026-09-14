# providers.tf
# AWS provider only — Route 53 is an AWS service.
# Local state — dns resources have their own separate state file
# so they are never affected by infra-down.sh (EKS destroy).
# ─────────────────────────────────────────────────────────────
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
        source = "hashicorp/aws"
        version = "~> 6.0"
    }
    # Kubernetes provider - reads live EKS service LoadBalancer hostname
    kubernetes = {
        source = "hashicorp/kubernetes"
        version = "~> 2.0"
    }
  }

  # Separate local state — independent from AWS infra and Datadog state
  # DNS resources should NEVER be destroyed with app infrastructure
}

provider "aws" {
  region = "us-east-1"
}

# ── Kubernetes provider — authenticates via EKS cluster ──────
# Reads kubeconfig from the current kubectl context automatically.
# Run: aws eks update-kubeconfig --name sre-ai-agent-dev-eks-cluster
# before terraform apply to ensure correct cluster is targeted.
data "aws_eks_cluster" "main" {
  name = var.eks_cluster_name
}

data "aws_eks_cluster_auth" "main" {
  name = var.eks_cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}
