module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.0"

  cluster_name    = "${var.project_name}-${var.environment}-eks-cluster"
  cluster_version = var.eks_cluster_version

  cluster_endpoint_public_access = true

  # Disable KMS encryption as this is demo, in prod need to handle with different approcah
  cluster_encryption_config = {}

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  eks_managed_node_groups = {
    default = {
      instance_types = [var.eks_node_instance_type]
      min_size       = var.eks_node_min
      max_size       = var.eks_node_max
      desired_size   = var.eks_node_desired

      labels = {
        Environment = var.environment
        Project     = var.project_name
      }
    }
  }

  # Grants cluster creator admin access
  enable_cluster_creator_admin_permissions = true

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}