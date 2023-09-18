# This is needed not just for us to have the permission to get the
# openid configuration but also so that external services can look it
# up as well.
resource "kubernetes_cluster_role_binding_v1" "anonymous_openid" {
  metadata {
    name = "allow-anonymous-openid-${random_pet.terraform_runner.id}"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:service-account-issuer-discovery"
  }
  subject {
    kind = "Group"
    name = "system:unauthenticated"
  }
}

locals {
  local_kubeconfig   = yamldecode(file(var.config_path))
  k8s_cluster_object = one([for cluster in local.kubeconfig["clusters"] : cluster if cluster["name"] == one([for context in local.kubeconfig["contexts"] : context if context["name"] == local.kubeconfig["current-context"]])["context"]["cluster"]])["cluster"]
}

data "http" "openid_configuration" {
  depends_on  = [kubernetes_cluster_role_binding_v1.anonymous_openid]
  count       = var.config_path == null ? 0 : 1
  url         = "${local.k8s_cluster_object["server"]}/.well-known/openid-configuration"
  ca_cert_pem = try(base64decode(local.k8s_cluster_object["certificate-authority-data"]), null)
}

locals {
  cluster_issuer    = var.config_path == null ? try(jsondecode(base64decode(split(".", file("/var/run/secrets/kubernetes.io/serviceaccount/token"))[1]))["iss"], "") : jsondecode(data.http.openid_configuration[0].response_body)["issuer"]
  cluster_issuer_ca = var.config_path == null ? try(file("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"), "") : try(base64decode(local.k8s_cluster_object["certificate-authority-data"]), "")
}
