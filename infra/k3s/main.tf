terraform {
  required_version = ">= 1.5.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.5.0"
    }
  }
}

variable "kubeconfig_path" {
  type        = string
  description = "Path to the dedicated kubeconfig for the lab cluster."
}

variable "kube_context" {
  type        = string
  description = "Explicit Kubernetes context for the lab cluster."
}

provider "kubernetes" {
  config_path    = pathexpand(var.kubeconfig_path)
  config_context = var.kube_context
}

locals {
  demo_objects = [
    for document in split("\n---\n", replace(file("${path.module}/../../k8s/demo.yaml"), "\r\n", "\n")) :
    yamldecode(document)
  ]
}

resource "kubernetes_manifest" "namespace" {
  manifest = yamldecode(file("${path.module}/../../k8s/00-namespace.yaml"))
}

resource "kubernetes_manifest" "demo" {
  for_each = { for object in local.demo_objects : object.kind => object }
  manifest = each.value

  depends_on = [kubernetes_manifest.namespace]
}
