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

variable "data_volume_gb" {
  type        = number
  description = "Size of the persistent OpenSearch and PostgreSQL data volume."
  default     = 500
}

variable "private_zone_name" {
  type        = string
  description = "Private hosted zone name. Connector app segments reference names, not IPs."
  default     = "ir.internal"
}

# --- Phase 2: evidence store (spec 5) ---

variable "retention_years" {
  type        = number
  description = <<-EOT
    Years an artifact is retained after its case closes (D10). The clock starts at case
    close, not at upload -- see spec 5.2. Phase 2 records this on the case; phase 4's case
    close is what applies it.
  EOT
  default     = 3

  validation {
    condition     = var.retention_years >= 1 && var.retention_years <= 100
    error_message = "retention_years must be between 1 and 100."
  }
}

variable "object_lock_mode" {
  type        = string
  description = "GOVERNANCE (reversible by a break-glass role) or COMPLIANCE (irreversible)."
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.object_lock_mode)
    error_message = "object_lock_mode must be \"GOVERNANCE\" or \"COMPLIANCE\"."
  }
}

variable "acknowledge_compliance_mode_is_irreversible" {
  type        = bool
  description = <<-EOT
    Required to be true when object_lock_mode is COMPLIANCE. Compliance-locked objects cannot
    be deleted before expiry by anyone, including the account root -- AWS documents the sole
    escape as deleting the AWS account -- and the bucket cannot be destroyed while they exist,
    so `tofu destroy` fails against one. Never set this in a development or sandbox account.
  EOT
  default     = false
}

variable "intake_expiry_days" {
  type        = number
  description = <<-EOT
    Days before an object left in the intake bucket expires. Intake is a quarantine boundary,
    not storage: the recorder deletes objects it has filed, so anything still here after this
    window failed to record and should be investigated rather than kept.
  EOT
  default     = 7

  validation {
    condition     = var.intake_expiry_days >= 1
    error_message = "intake_expiry_days must be at least 1."
  }
}

variable "manifest_deletion_protection" {
  type        = bool
  description = <<-EOT
    Blocks deletion of the case and artifact tables. The manifest is the only thing in this
    design that cannot be reconstructed -- evidence can be re-hashed, a chain of custody
    cannot be re-derived. Set false only to tear down a development deployment (spec 5.2.2).
  EOT
  default     = true
}

variable "break_glass_principal_arns" {
  type        = list(string)
  description = <<-EOT
    Principals permitted to assume the break-glass role, which holds
    s3:BypassGovernanceRetention for genuine operator error -- ingesting the wrong client's
    data, for example (spec 5.2). Empty means no role is created.
  EOT
  default     = []
}
