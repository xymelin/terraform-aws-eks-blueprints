provider "aws" {
  region = var.region
}

provider "kubernetes" {
  host                   = module.eks_blueprints.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks_blueprints.eks_cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks_blueprints.eks_cluster_id
}

#Choosing Only Availability Zones (no Local Zones):
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = var.cluster_base_name
  # var.cluster_name is for Terratest
  cluster_name = var.cluster_name
  region       = var.region

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    PartOf    = var.cluster_name
    ManagedBy = "terraform-blueprints"
  }
}


# SSH key gitlab
#resource "aws_secretsmanager_secret" "gitlab_key" {
#  name = "github-ssh-key"
#  secret_string = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCZy3KsDW6ugYPFCR/TelQfKH2W5AmTT6Ly6Ej7t1Y1co0kajXw3e/bEwbT39KAY8vtNHXBomwJI2v/cHDLOIkgZI/NhtXq3JQmM4ru2/XBlAMyZZpM/0Y3l2+czQacyowjW6Pio/cTwxL3pwuK0zZNN4d5PjX4sUBGcHt0TB5KxvYBPffcNQqZyUmfRQoJT5SQOHUWxghuG4tHvT0EDm3CD9kSVQSufKRmdTZMybxZ1L7MRPTfAwbI3RzgTuNHvCOlZU7Bfm2sJlWt8LdH56E+Tb3QlaZlbhFLSBF5dE78qigo3oATk3ZuCsX56qAPk3ZKQkBg3DYcgxcI0w0FWIlH imported-openssh-key"
#}
#
resource "aws_secretsmanager_secret" "github-ssh" {
  name = "github-ssh"
  tags = {
    OwnedBy = "argocd"
    Purpouse = "gitlab"
  }
}

resource "aws_secretsmanager_secret_version" "github-ssh" {
  secret_id     = aws_secretsmanager_secret.github-ssh.id
  secret_string = "${file("secret.txt")}"
}



#---------------------------------------------------------------
# EKS Blueprints
#---------------------------------------------------------------

module "eks_blueprints" {
  source = "../.."

  cluster_name    = local.cluster_name
  cluster_version = "1.24"

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets

  managed_node_groups = {
    mg_5 = {
      node_group_name = "on_demand"
      instance_types  = ["m5.large"]
      min_size        = var.min_nodes
      max_size        = var.max_nodes
      desired_size    = var.desired_nodes
      subnet_ids      = module.vpc.private_subnets
      update_config = [{
        max_unavailable_percentage = 30
      }]
      k8s_labels = {
        Environment = var.environment
        WorkerType  = "on_demand"
      }
    }
  }

  tags = local.tags
}

module "eks_blueprints_kubernetes_addons" {
  source = "../../modules/kubernetes-addons"

  eks_cluster_id       = module.eks_blueprints.eks_cluster_id
  eks_cluster_endpoint = module.eks_blueprints.eks_cluster_endpoint
  eks_oidc_provider    = module.eks_blueprints.oidc_provider
  eks_cluster_version  = module.eks_blueprints.eks_cluster_version

  # EKS Managed Add-ons
  enable_amazon_eks_vpc_cni            = true
  enable_amazon_eks_coredns            = true
  enable_amazon_eks_kube_proxy         = true
  enable_amazon_eks_aws_ebs_csi_driver = true

  # Add-ons
  enable_aws_load_balancer_controller = true
  enable_metrics_server               = true
  #enable_aws_cloudwatch_metrics       = true
  enable_prometheus                   = true
  enable_kube_state_metrics           = true
  enable_ingress_nginx                = true
  enable_argocd                       = true

  argocd_helm_config = {
    name             = "argo-cd"
    chart            = "argo-cd"
    repository       = "https://argoproj.github.io/argo-helm"
    version          = "3.29.5"
    namespace        = "argocd"
    timeout          = "1200"
    create_namespace = true
    #    values           = [templatefile("${path.module}/argocd-values.yaml", {})]
  }


  argocd_applications     = {
    workloads = {
      path                = "charts/docker-registry"
      repo_url            = "git@github.com:xymelin/helm-charts.git"
      project             = "test"
      ssh_key_secret_name = "github-ssh"  # Needed for private repos
      insecure            = true # Set to true to disable the server's certificate verification
    }
  }
  enable_grafana              = true
  enable_promtail             = true

  enable_cluster_autoscaler = true
  cluster_autoscaler_helm_config = {
    set = [
      {
        name  = "podLabels.prometheus\\.io/scrape",
        value = "true",
        type  = "string",
      }
    ]
  }

  enable_cert_manager = true
  cert_manager_helm_config = {
    set_values = [
      {
        name  = "extraArgs[0]"
        value = "--enable-certificate-owner-ref=false"
      },
    ]
  }
  # TODO - requires dependency on `cert-manager` for namespace
  # enable_cert_manager_csi_driver = true

  tags = local.tags
  depends_on = [
    aws_secretsmanager_secret.github-ssh
  ]
}


#---------------------------------------------------------------
# Supporting Resources
#---------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 10)]
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 20)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Manage so we can name
  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${local.name}-default" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${local.name}-default" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.name}-default" }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }

  tags = local.tags
}
