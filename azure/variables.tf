variable "location" {
  description = "Azure Region"
  type        = string
  default     = "germanywestcentral"
}

variable "prefix" {
  description = "Namenspräfix für Ressourcen"
  type        = string
  default     = "web"
}

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
}

variable "client_id" {
  description = "Client ID des Service Principals"
  type        = string
}

variable "client_certificate_base64" {
  description = "Base64 des Zertifikats (PEM oder PFX)"
  type        = string
  sensitive   = true
}

variable "client_certificate_password" {
  description = "Password für PFX (bei PEM leer)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "client_certificate_is_pfx" {
  description = "True, wenn Base64 ein PFX ist"
  type        = bool
  default     = true
}