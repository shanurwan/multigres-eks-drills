output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}${var.profile == null ? "" : " --profile ${var.profile}"}"
}

output "azs" {
  value = local.azs
}

output "zone_ids" {
  description = "Use these for spec.cells[].zoneId"
  value       = local.zone_ids
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.bucket
}

output "backup_role_arn" {
  description = "Annotate the multigres-backup service account with this"
  value       = module.backup_irsa.iam_role_arn
}

output "node_groups" {
  description = "Scale one to 0 to take its AZ down"
  value       = { for k, v in module.eks.eks_managed_node_groups : k => v.node_group_id }
}
