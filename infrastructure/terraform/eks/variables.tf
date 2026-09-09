variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project Name used for resource naming"
  type        = string
  default     = "sre-ai-agent"
}

variable "environment" {
  description = "Environment Name"
  type        = string
  default     = "dev"
}

variable "eks_cluster_version" {
  description = "Kubernetes Version"
  type        = string
  default     = "1.32"
}

variable "eks_node_instance_type" {
  description = "EC2 Instance type for EKS nodes"
  type        = string
  default     = "t3.small"
}

variable "eks_node_desired" {
  description = "Desired Numbers of EKS Nodes"
  type        = number
  default     = 1
}

variable "eks_node_min" {
  description = "Minimum EKS nodes"
  type        = number
  default     = 1
}

variable "eks_node_max" {
  description = "Max EKS nodes"
  type        = number
  default     = 2
}