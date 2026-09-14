variable "name_prefix" {
  type        = string
  description = "Prefix for all named resources. Bucket names are globally unique."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with hyphens, 3-32 characters."
  }
}

variable "tags" {
  type        = map(string)
  description = "Additional tags applied to every resource."
  default     = {}
}

variable "monthly_budget_usd" {
  type        = number
  description = "Monthly spend threshold for the IR environment."
  default     = 200
}

variable "budget_alert_emails" {
  type        = list(string)
  description = "Addresses notified when the budget threshold is approached or breached."

  validation {
    condition     = length(var.budget_alert_emails) > 0
    error_message = "At least one budget alert address is required. Idle cost is the failure mode this guards."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR for the IR VPC."
  default     = "10.90.0.0/16"
}

variable "enable_internet_egress" {
  type        = bool
  description = <<-EOT
    Adds an internet gateway and NAT gateway. Required only when an org-managed connector
    (for example a ZPA App Connector) must dial outbound to a vendor cloud. Default is no
    egress: this environment handles live malware.
  EOT
  default     = false
}

variable "allowed_ingress_cidrs" {
  type        = list(string)
  description = "CIDRs permitted to reach the appliance on 443. For org-managed connectivity."
  default     = []
}

variable "allowed_ingress_security_group_ids" {
  type        = list(string)
  description = "Security groups permitted to reach the appliance on 443."
  default     = []
}
