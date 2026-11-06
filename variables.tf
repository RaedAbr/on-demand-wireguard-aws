variable "aws_region" {
  description = "AWS region to deploy to (selected in the GitHub Actions workflow)"
  type        = string
  default     = "eu-central-2"
}

variable "availability_zone" {
  description = "Availability zone (empty = first zone in the region offering instance_type)"
  type        = string
  default     = ""
}

variable "instance_name" {
  description = "EC2 instance name and resource name prefix"
  type        = string
  default     = "WireGuard-VPN-Server"
}

variable "instance_type" {
  description = "EC2 instance type (must be amd64)"
  type        = string
  default     = "t3.micro"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.10.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR block"
  type        = string
  default     = "10.10.1.0/24"
}

variable "ssh_public_key" {
  description = "(Optional) SSH public key for the server. Empty = no key pair is created."
  type        = string
  default     = ""
}

variable "ssh_allowed_cidrs" {
  description = "(Optional) CIDRs allowed to reach SSH on port 22. Empty = SSH is closed. Sensitive so that plans in public logs don't show it."
  type        = list(string)
  default     = []
  sensitive   = true
}

variable "wg_port" {
  description = "WireGuard UDP listen port"
  type        = number
  default     = 60573
}

variable "wg_server_private_key" {
  description = "WireGuard server private key"
  type        = string
  sensitive   = true
}

variable "wg_client_public_key" {
  description = "WireGuard client public key"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9+/]{43}=$", var.wg_client_public_key))
    error_message = "wg_client_public_key must be a WireGuard public key (the output of `wg pubkey`)."
  }
}

variable "wg_client_preshared_key" {
  description = "WireGuard client preshared key"
  type        = string
  sensitive   = true
}

variable "duckdns_domain" {
  description = "(Optional) DuckDNS subdomain, without .duckdns.org, updated at boot"
  type        = string
  default     = ""
}

variable "duckdns_token" {
  description = "(Optional) DuckDNS token"
  type        = string
  default     = ""
  sensitive   = true
}
