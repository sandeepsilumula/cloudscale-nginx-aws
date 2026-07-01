output "alb_dns_name" {
  description = "The public DNS name of the Application Load Balancer"
  value       = aws_lb.external.dns_name
}

output "vpc_id" {
  description = "The ID of the created VPC"
  value       = aws_vpc.main.id
}
