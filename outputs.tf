output "instance_id" {
  description = "WireGuard EC2 instance ID"
  value       = aws_instance.wireguard.id
}

output "vpc_id" {
  description = "ID of the dedicated VPC"
  value       = aws_vpc.vpn.id
}

output "public_ip" {
  description = "Public IPv4 address of the VPN server"
  value       = aws_instance.wireguard.public_ip
}

output "wireguard_endpoint" {
  description = "Endpoint for the WireGuard client (<IP>:<port>)"
  value       = "${aws_instance.wireguard.public_ip}:${var.wg_port}"
}

output "ssh_command" {
  description = "SSH command for the server (needs ssh_public_key and ssh_allowed_cidrs)"
  value       = "ssh -i <path-to-your-private-key> ubuntu@${aws_instance.wireguard.public_ip}"
}
