output "role_arn" {
  description = "IRSA role ARN assumed by the cluster-autoscaler service account"
  value       = module.irsa.role_arn
}
