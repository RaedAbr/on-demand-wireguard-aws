terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # bucket, region (the bucket's, not the VPN's) and key are passed to `tofu init`.
  # key has no default so that each VPN region gets its own state: sharing one
  # would leave the previous server running, and billing, with nothing tracking it.
  backend "s3" {
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region

  # The locked provider version doesn't know every recent region.
  # The allowed regions are the ones listed in the workflow.
  skip_region_validation = true
}

# ==============================================================================
# 1. Ubuntu 26.04 LTS AMI (official Canonical image, latest build)
# ==============================================================================
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ==============================================================================
# Availability zone: the first one in the region offering var.instance_type
# (not every AZ offers every type; Local Zones are excluded)
# ==============================================================================
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ec2_instance_type_offerings" "available" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }

  filter {
    name   = "location"
    values = data.aws_availability_zones.available.names
  }

  lifecycle {
    postcondition {
      condition     = length(self.locations) > 0
      error_message = "Instance type ${var.instance_type} is not offered in any zone of ${var.aws_region}."
    }
  }
}

locals {
  availability_zone = var.availability_zone != "" ? var.availability_zone : sort(data.aws_ec2_instance_type_offerings.available.locations)[0]
}

# ==============================================================================
# 2. Network (VPC, subnet, internet gateway, route table)
# ==============================================================================
resource "aws_vpc" "vpn" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name      = "${var.instance_name}-vpc"
    ManagedBy = "OpenTofu"
  }
}

resource "aws_internet_gateway" "vpn" {
  vpc_id = aws_vpc.vpn.id

  tags = {
    Name      = "${var.instance_name}-igw"
    ManagedBy = "OpenTofu"
  }
}

resource "aws_subnet" "vpn_public" {
  vpc_id                  = aws_vpc.vpn.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name      = "${var.instance_name}-public-subnet"
    ManagedBy = "OpenTofu"
  }
}

resource "aws_route_table" "vpn_public" {
  vpc_id = aws_vpc.vpn.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.vpn.id
  }

  tags = {
    Name      = "${var.instance_name}-public-rt"
    ManagedBy = "OpenTofu"
  }
}

resource "aws_route_table_association" "vpn_public" {
  subnet_id      = aws_subnet.vpn_public.id
  route_table_id = aws_route_table.vpn_public.id
}

# ==============================================================================
# 3. Security group and optional SSH key pair
# ==============================================================================
resource "aws_security_group" "wireguard" {
  name        = "${var.instance_name}-sg"
  description = "Security group for WireGuard VPN Server (SSH + UDP ${var.wg_port})"
  vpc_id      = aws_vpc.vpn.id

  dynamic "ingress" {
    for_each = nonsensitive(length(var.ssh_allowed_cidrs)) > 0 ? [1] : []

    content {
      description = "SSH access"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_allowed_cidrs
    }
  }

  ingress {
    description      = "WireGuard VPN UDP"
    from_port        = var.wg_port
    to_port          = var.wg_port
    protocol         = "udp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    description      = "Allow all outbound traffic"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name      = "${var.instance_name}-sg"
    ManagedBy = "OpenTofu"
  }
}

resource "aws_key_pair" "vpn" {
  count = var.ssh_public_key != "" ? 1 : 0

  key_name   = "${var.instance_name}-key"
  public_key = var.ssh_public_key

  tags = {
    Name      = "${var.instance_name}-key"
    ManagedBy = "OpenTofu"
  }
}

# ==============================================================================
# 4. EC2 instance, configured by cloud-init user_data
# ==============================================================================
resource "aws_instance" "wireguard" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.vpn_public.id
  vpc_security_group_ids      = [aws_security_group.wireguard.id]
  key_name                    = one(aws_key_pair.vpn[*].key_name)
  associate_public_ip_address = true
  user_data_replace_on_change = true

  depends_on = [aws_internet_gateway.vpn]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    # 1. Detect the main network interface (ens5 by default on t3.micro)
    PUB_NIC=$(ip -o -4 route show to default | awk '{print $5}')
    if [ -z "$${PUB_NIC}" ]; then
      PUB_NIC="ens5"
    fi

    # 2. Enable IPv4 and IPv6 forwarding
    cat <<'SYSCTL' > /etc/sysctl.d/wg.conf
    net.ipv4.ip_forward = 1
    net.ipv6.conf.all.forwarding = 1
    SYSCTL
    sysctl --system

    # 3. Install WireGuard and iptables
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y wireguard wireguard-tools iptables curl

    # 4. Write /etc/wireguard/wg0.conf
    install -d -m 0700 /etc/wireguard
    umask 077

    cat <<WGCONF > /etc/wireguard/wg0.conf
    [Interface]
    Address = 10.66.66.1/24,fd42:42:42::1/64
    ListenPort = ${var.wg_port}
    PrivateKey = ${var.wg_server_private_key}
    PostUp = iptables -I INPUT -p udp --dport ${var.wg_port} -j ACCEPT
    PostUp = iptables -I FORWARD -i $${PUB_NIC} -o wg0 -j ACCEPT
    PostUp = iptables -I FORWARD -i wg0 -j ACCEPT
    PostUp = iptables -t nat -A POSTROUTING -o $${PUB_NIC} -j MASQUERADE
    PostUp = ip6tables -I FORWARD -i wg0 -j ACCEPT
    PostUp = ip6tables -t nat -A POSTROUTING -o $${PUB_NIC} -j MASQUERADE
    PostDown = iptables -D INPUT -p udp --dport ${var.wg_port} -j ACCEPT
    PostDown = iptables -D FORWARD -i $${PUB_NIC} -o wg0 -j ACCEPT
    PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
    PostDown = iptables -t nat -D POSTROUTING -o $${PUB_NIC} -j MASQUERADE
    PostDown = ip6tables -D FORWARD -i wg0 -j ACCEPT
    PostDown = ip6tables -t nat -D POSTROUTING -o $${PUB_NIC} -j MASQUERADE

    ### Client
    [Peer]
    PublicKey = ${var.wg_client_public_key}
    PresharedKey = ${var.wg_client_preshared_key}
    AllowedIPs = 10.66.66.2/32,fd42:42:42::2/128
    WGCONF

    chmod 600 /etc/wireguard/wg0.conf

    # 5. Start and enable WireGuard
    systemctl enable --now wg-quick@wg0

    # 6. Update DuckDNS if configured
    if [ -n "${var.duckdns_domain}" ] && [ -n "${var.duckdns_token}" ]; then
      curl -fsSL "https://www.duckdns.org/update?domains=${var.duckdns_domain}&token=${var.duckdns_token}&ip=" || true
    fi
  EOF

  tags = {
    Name      = var.instance_name
    ManagedBy = "OpenTofu"
  }
}
