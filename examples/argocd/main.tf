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

module "efk" {
  depends_on      = [module.argocd]
  source          = "github.com/provectus/sak-efk"
  cluster_name    = module.kubernetes.cluster_name
  argocd          = module.argocd.state
  domains         = local.domain
  elasticReplicas = 2
  kibana_conf = {
    "ingress.annotations.kubernetes\\.io/ingress\\.class"               = "nginx"
    "ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/auth-url"    = "https://auth.example.com/oauth2/auth"
    "ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/auth-signin" = "https://auth.example.com/oauth2/sign_in?rd=https://$host$request_uri"
  }
  filebeat_conf = {
    "setup.kibana" = {
      "host" = "https://kibana.example.com:443"
    },
    "setup.dashboards.enabled" = true,
    "setup.template.enabled"   = true,
    "setup.template.name"      = "filebeat",
    "setup.template.pattern"   = "filebeat-*",
    "setup.template.settings" = {
      "index.number_of_shards" = 1
    },
    "setup.ilm.enabled"      = "auto",
    "setup.ilm.check_exists" = false,
    "setup.ilm.overwrite"    = true,
    "filebeat.modules" = [
      {
        "module" = "system",
        "syslog" = {
          "enabled" = true
        },
        "auth" = {
          "enabled" = true
        }
      }
    ],
    "filebeat.inputs" = [
      {
        "type" = "container",
        "paths" = [
          "/var/log/containers/*.log"
        ],
        "stream" = "all",
        "processors" = [
          {
            "add_kubernetes_metadata" = {
              "host" = "$${NODE_NAME}",
              "matchers" = [
                {
                  "logs_path" = {
                    "logs_path" = "/var/log/containers/"
                  }
                }
              ]
            }
          }
        ]
      }
    ],
    "filebeat.autodiscover" = {
      "providers" = [
        {
          "type"          = "kubernetes",
          "hints.enabled" = true,
          "templates" = [
            {
              "condition.equals" = {
                "kubernetes.labels.logging" = true
              },
              "config" = [
                {
                  "type" = "container",
                  "paths" = [
                    "/var/log/containers/*-test.log"
                  ],
                  "exclude_lines" = [
                    "^\\s+[\\-`('.|_]"
                  ]
                }
              ]
            },
            {
              "condition.equals" = {
                "kubernetes.labels.logtype" = "nginx"
              },
              "config" = [
                {
                  "module" = "nginx",
                  "access" = {
                    "enabled" = true,
                    "var.paths" = [
                      "/var/log/nginx/access.log*"
                    ]
                  },
                  "error" = {
                    "enabled" = true,
                    "var.paths" = [
                      "/var/log/nginx/error.log*"
                    ]
                  }
                }
              ]
            }
          ]
        }
      ]
    },
    "processors" = [
      {
        "add_cloud_metadata" = null
      },
      {
        "decode_json_fields" = {
          "fields" = [
            "message"
          ],
          "process_array"  = false,
          "max_depth"      = 1,
          "target"         = "",
          "overwrite_keys" = true,
          "add_error_key"  = true
        }
      },
      {
        "drop_event" = {
          "when" = {
            "not" = {
              "contains" = {
                "kubernetes.pod.labels.logging" = "true"
              }
            }
          }
        }
      },
      {
        "drop_event" = {
          "when" = {
            "regexp" = {
              "message" = "(?i)kube-probe/1.18+"
            }
          }
        }
      },
      {
        "drop_event" = {
          "when" = {
            "regexp" = {
              "message" = "(?i)ELB-HealthChecker/2.0"
            }
          }
        }
      }
    ]
  }

}
