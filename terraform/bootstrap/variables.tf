variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "hello-world"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "github_org" {
  type        = string
  description = "GitHub organisation or username (e.g. my-org)"
}

variable "github_repo" {
  type        = string
  description = "Repository name without the org prefix (e.g. lucidity)"
}

