output "public_ip" {
  value       = azurerm_public_ip.pip.ip_address
  description = "Public IP der Web-VM"
}

output "ssh_private_key" {
  value       = tls_private_key.ssh.private_key_pem
  description = "Private SSH Key"
  sensitive   = true
}

output "ssh_command" {
  value       = "ssh -i private_key.pem azureuser@${azurerm_public_ip.pip.ip_address}"
  description = "SSH Connect Command"
}