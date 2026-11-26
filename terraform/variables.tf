variable "region" {
  type        = string
  description = "AWS region with at least 3 AZs, e.g. ap-southeast-1"
}

variable "profile" {
  type        = string
  description = "AWS CLI profile to use"
  default     = null
}

variable "name" {
  type    = string
  default = "multigres-lab"
}

variable "owner" {
  type        = string
  description = "Owner tag value"
}

variable "kubernetes_version" {
  type        = string
  description = "Must be in EKS standard support (extended support costs about 6x per hour). Check: aws eks describe-cluster-versions"
  default     = "1.35"
}

variable "instance_type" {
  type        = string
  description = "One node per AZ. m7i-flex.large = 2 vCPU / 8 GiB, and is allowed on AWS free-plan accounts (m6i.large is not)"
  default     = "m7i-flex.large"
}

variable "admin_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the EKS API, e.g. your public IP /32"
}

variable "budget_usd" {
  type    = number
  default = 40
}

variable "alert_email" {
  type = string
}
