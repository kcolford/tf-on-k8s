variable "runner_prefix" {
  description = "Prefix to add to every named runner resource."
  type        = string
  nullable    = false
  default     = "terraform-runner"
}

variable "refresh_schedule" {
  description = "A cron schedule on which to refresh this resource."
  type        = string
  nullable    = false
  default     = "*/5 * * * *"
}

variable "secret_suffix" {
  description = "This should be set to the secret suffix used by the k8s backend. Use commandline.auto.tfvars as a single source of truth for both the backend and this variable."
  type        = string
  nullable    = false
}

locals {
  passthrough_variables = {
    runner_prefix    = var.runner_prefix
    refresh_schedule = var.refresh_schedule
    secret_suffix    = var.secret_suffix
  }
}

terraform {
  backend "kubernetes" {}
  required_providers {
    kubernetes = {}
    random     = {}
  }
}

variable "config_path" {
  description = "This is the path to the kubeconfig file. Use commandline.auto.tfvars to inject it in both the backend and the provider."
  type        = string
  default     = null
}

provider "kubernetes" {
  config_path = var.config_path
}

resource "random_pet" "terraform_runner" {}

locals {
  runner_name = "${var.runner_prefix}-${random_pet.terraform_runner.id}"
  secret_name = "tfstate-${terraform.workspace}-${var.secret_suffix}"
}

locals {
  yaml_blobs = flatten([for filename in fileset(path.module, "*.yaml") : split("---", file("${path.module}/${filename}"))])
  yaml_data  = [for blob in local.yaml_blobs : yamldecode(blob) if trimspace(blob) != ""]
}

resource "kubernetes_manifest" "terraform_runner" {
  for_each = { for doc in local.yaml_data : "${doc.kind}/${try(reverse(split("/", doc.apiVersion))[1], "")}/${try(doc.metadata.namespace, "")}/${doc.metadata.name}" => doc }
  manifest = each.value
}

resource "kubernetes_config_map_v1" "terraform_runner" {
  metadata {
    name = local.runner_name
  }
  data = { for filename in setsubtract(fileset(path.module, "*.{tf,yaml,auto.tfvars}"), ["commandline.auto.tfvars"]) : filename => file("${path.module}/${filename}") }
}

resource "kubernetes_service_account_v1" "terraform_runner" {
  metadata {
    name = local.runner_name
  }
}

locals {
  resource_verbs = ["get", "create", "update", "patch", "delete"]
}

resource "kubernetes_role_v1" "terraform_runner" {
  metadata {
    name = local.runner_name
  }

  # access to change the state file
  rule {
    verbs      = ["list"]
    api_groups = ["", "coordination.k8s.io"]
    resources  = ["secrets", "leases"]
  }
  rule {
    verbs          = local.resource_verbs
    api_groups     = ["coordination.k8s.io"]
    resources      = ["leases"]
    resource_names = ["lock-${local.secret_name}"]
  }
  rule {
    verbs          = local.resource_verbs
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = [local.secret_name]
  }

  # access to configure itself
  rule {
    verbs          = local.resource_verbs
    api_groups     = ["", "rbac.authorization.k8s.io", "batch"]
    resources      = ["configmaps", "cronjobs", "serviceaccounts", "roles", "rolebindings"]
    resource_names = [local.runner_name]
  }
}

resource "kubernetes_role_binding_v1" "terraform_runner" {
  metadata {
    name = local.runner_name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.terraform_runner.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.terraform_runner.metadata[0].name
    namespace = kubernetes_service_account_v1.terraform_runner.metadata[0].namespace
  }
}

resource "kubernetes_cron_job_v1" "terraform_runner" {
  metadata {
    name = local.runner_name
  }
  spec {
    concurrency_policy = "Forbid"
    schedule           = var.refresh_schedule

    job_template {
      metadata {}

      spec {
        template {
          metadata {
            annotations = {
              "vault.hashicorp.com/role" = "app"
            }
          }

          spec {
            volume {
              name = "dot-terraform"
              empty_dir {}
            }

            volume {
              name = "terraform-config"

              config_map {
                name = kubernetes_config_map_v1.terraform_runner.metadata[0].name
              }
            }

            init_container {
              name  = "copy-tf-files"
              image = "busybox"
              args  = ["cp", "-a", "/module/.", "/data/"]

              volume_mount {
                name       = "terraform-config"
                read_only  = true
                mount_path = "/module"
              }
              volume_mount {
                name       = "dot-terraform"
                mount_path = "/data"
              }
            }

            init_container {
              name        = "terraform-init"
              image       = "hashicorp/terraform"
              args        = ["init", "-backend-config=in_cluster_config=true", "-backend-config=secret_suffix=${var.secret_suffix}"]
              working_dir = "/data"

              env {
                name  = "TF_WORKSPACE"
                value = terraform.workspace
              }

              env {
                name  = "TF_INPUT"
                value = "false"
              }

              env {
                name  = "TF_IN_AUTOMATION"
                value = "true"
              }

              volume_mount {
                name       = "dot-terraform"
                mount_path = "/data"
              }
            }

            container {
              name        = "terraform-apply"
              image       = "hashicorp/terraform"
              args        = ["apply", "-auto-approve"]
              working_dir = "/data"

              env {
                name  = "TF_WORKSPACE"
                value = terraform.workspace
              }

              env {
                name  = "TF_INPUT"
                value = "false"
              }

              env {
                name  = "TF_IN_AUTOMATION"
                value = "true"
              }

              dynamic "env" {
                for_each = local.passthrough_variables
                content {
                  name  = "TF_VAR_${env.key}"
                  value = env.value
                }
              }

              volume_mount {
                name       = "dot-terraform"
                mount_path = "/data"
              }
            }

            restart_policy       = "Never"
            service_account_name = kubernetes_service_account_v1.terraform_runner.metadata[0].name
          }
        }
      }
    }
  }
}
