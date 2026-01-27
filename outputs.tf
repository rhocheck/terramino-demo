output "web_instance_url" {
  description = "The public DNS URL of the EC2 web server"
  value       = "http://${aws_instance.web[0].public_dns}"
}