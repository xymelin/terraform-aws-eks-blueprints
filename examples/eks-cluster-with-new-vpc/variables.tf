# tflint-ignore: terraform_unused_declarations
variable "cluster_name" {
  description = "Name of cluster - used by Terratest for e2e test automation"
  type        = string
  default     = "xenocideCluster"
}

variable "region" {
  description = "Region where cluster will be deployed"
  type = string
  default = "eu-central-1"
}

variable "cluster_base_name" {
  description = "Base named that will be used as base"
  type = string
  default = "terratestXenocide"
}

variable "vpc_cidr" {
  description = "VPC cidr"
  type = string
  default = "10.0.0.0/16"
}

variable "max_nodes" {
  description = "Maximum nodes"
  type = number
  default = 5
}

variable "min_nodes" {
  description = "Minimum nodes"
  type = number
  default = 3
}

variable "desired_nodes" {
  description = "Desired nodes"
  type = number
  default = 3
}

variable "environment" {
  type = string
  default = "POC"
}