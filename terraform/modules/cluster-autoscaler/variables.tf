variable "cluster_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  type = string
}

variable "chart_version" {
  type    = string
  default = "9.36.0"
}

variable "tags" {
  type    = map(string)
  default = {}
}
