data "aws_eks_cluster" "cluster" {
  name = module.kubernetes.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.kubernetes.cluster_name
}

locals {
  environment  = var.environment
  project      = var.project
  cluster_name = var.cluster_name
  domain       = ["${local.cluster_name}.${var.domain_name}"]
}

module "network" {
  source = "github.com/provectus/sak-vpc"

  availability_zones = var.availability_zones
  environment        = local.environment
  project            = local.project
  cluster_name       = local.cluster_name
  network            = 10
}

module "kubernetes" {
  depends_on = [module.network]
  source     = "github.com/provectus/sak-kubernetes"

  environment        = local.environment
  project            = local.project
  availability_zones = var.availability_zones
  cluster_name       = local.cluster_name
  domains            = local.domain
  vpc_id             = module.network.vpc_id
  subnets            = module.network.private_subnets

  on_demand_gpu_instance_type = "g4dn.xlarge"
}

module "argocd" {
  depends_on = [module.network.vpc_id, module.kubernetes.cluster_name, data.aws_eks_cluster.cluster]
  source     = "github.com/provectus/sak-argocd"

  branch       = var.argocd.branch
  owner        = var.argocd.owner
  repository   = var.argocd.repository
  cluster_name = module.kubernetes.cluster_name
  path_prefix  = "examples/argocd/"

  domains = local.domain
  ingress_annotations = {
    "nginx.ingress.kubernetes.io/ssl-redirect" = "false"
    "kubernetes.io/ingress.class"              = "nginx"
  }
  conf = {
    "server.service.type"     = "ClusterIP"
    "server.ingress.paths[0]" = "/"
  }
}

module "alb-ingress" {
  depends_on   = [module.argocd]
  source       = "github.com/provectus/sak-alb-controller"
  cluster_name = module.kubernetes.cluster_name
  vpc_id       = module.network.vpc_id
  argocd       = module.argocd.state
}



#module external_dns {
#  source       = "github.com/provectus/sak-external-dns?ref=add_several_features_from_latest_release"
#  source = "/Users/dmiroshnik/work/provectus/sak-external-dns"
#  cluster_name = module.kubernetes.cluster_name
#  argocd       = module.argocd.state
#  mainzoneid = "Z020452411YL6ISW5A1GW"
#  hostedzones = []
#}

module "prometheus" {
  depends_on      = [module.argocd]
#  source          = "github.com/provectus/sak-prometheus?ref=feature//update-module"
  source = "/Users/dmiroshnik/work/provectus/sak-prometheus"
  cluster_name    = module.kubernetes.cluster_name
  argocd          = module.argocd.state
  domains         = local.domain
  tags            = {}
}
