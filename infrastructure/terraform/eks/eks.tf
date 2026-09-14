module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.0"

  cluster_name    = "${var.project_name}-${var.environment}-eks-cluster"
  cluster_version = var.eks_cluster_version

  cluster_endpoint_public_access = true

  # Disable KMS encryption — demo environment
  cluster_encryption_config = {}

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  eks_managed_node_groups = {

    # ── App node group ────────────────────────────────────────
    # Runs: FastAPI app, Datadog agent
    # Instance: t3.small (2 vCPU, 2GB RAM)
    app_nodes = {
      instance_types = [var.eks_node_instance_type]
      min_size       = var.eks_node_min
      max_size       = var.eks_node_max
      desired_size   = var.eks_node_desired

      labels = {
        Environment = var.environment
        Project     = var.project_name
        workload    = "app"
      }
    }

    # ── AI Agent node group ───────────────────────────────────
    # Runs: LangGraph SRE Agent, fastembed model, pgvector client
    # Instance: t3.medium (2 vCPU, 4GB RAM) — more RAM for embeddings
    # Taint: only agent pods scheduled here (no_schedule for others)
    agent_nodes = {
      instance_types = ["t3.small"]
      min_size       = 1
      max_size       = 1
      desired_size   = 1

      labels = {
        Environment = var.environment
        Project     = var.project_name
        workload    = "ai-agent"
      }

      taints = [
        {
          key    = "workload"
          value  = "ai-agent"
          effect = "NO_SCHEDULE"
        }
      ]
    }
  }

  # Grants cluster creator admin access
  enable_cluster_creator_admin_permissions = true

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}