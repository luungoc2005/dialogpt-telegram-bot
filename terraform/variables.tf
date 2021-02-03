variable "cidr_block" {
  default     = "172.31.0.0/16"
  type        = string
  description = "CIDR block for the VPC"
}

# variable "public_subnet_cidr_blocks" {
#   default     = ["172.31.0.0/24", "172.31.2.0/24"]
#   type        = list
#   description = "List of public subnet CIDR blocks"
# }

# variable "private_subnet_cidr_blocks" {
#   default     = ["172.31.1.0/24", "172.31.3.0/24"]
#   type        = list
#   description = "List of private subnet CIDR blocks"
# }

# variable "availability_zones" {
#   default     = ["ap-southeast-1a", "ap-southeast-1b"]
#   type        = list
#   description = "List of availability zones"
# }

variable "public_subnet_cidr_blocks" {
  default     = ["172.31.0.0/24"]
  type        = list
  description = "List of public subnet CIDR blocks"
}

variable "private_subnet_cidr_blocks" {
  default     = ["172.31.1.0/24"]
  type        = list
  description = "List of private subnet CIDR blocks"
}

variable "availability_zones" {
  default     = ["ap-southeast-1a"]
  type        = list
  description = "List of availability zones"
}

variable "environment" {
  default     = "dev"
  type        = string
  description = "prod/dev stage name"
}