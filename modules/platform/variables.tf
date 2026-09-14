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
