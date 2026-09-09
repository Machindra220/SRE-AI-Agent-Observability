# Root domain registered at Bigrock
variable "domain_name" {
  description = "Root domain name"
  type = string
  default = "machindra.online"
}

# subdomain for sre app
variable "subdomain" {
  description = "Subdomain for EKS app"
  type = string
  default = "sre"
}


# EKS cluster name — used by Kubernetes provider to fetch LoadBalancer
variable "eks_cluster_name" {
  description = "EKS Cluster name - must match infra cluster name"
  type = string
  default = "sre-ai-agent-dev-eks-cluster"
}

# kubernetes service details - must match your K8s service manifest
variable "k8s_service_name" {
  description = "Kubernetes service name for the app"
  type = string
  default = "sre-ai-agent"
}

variable "k8s_namespace" {
  description = "Kubernetes namespace where the service runs"
  type = string
  default = "sre-ai-agent"
}

# EKS LB hostname - update this after running/each infra-up.sh 
# variable "elb_hostname" {
#   description = "EKS LoadBalancer hostname from kubectl get svc"
#   type = string
#   default = "a088aea33803f4c038ce5781a63dbbab-2089612467.us-east-1.elb.amazonaws.com"
# }