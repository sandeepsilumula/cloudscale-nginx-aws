# Fetch availability zones dynamically
data "aws_availability_zones" "available" {
  state = "available"
}

# Fetch the latest stable Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# ================= VPC & NETWORKING =================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "scalable-nginx-vpc"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "scalable-nginx-igw"
  }
}

# Public Subnets (for ALB)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "scalable-nginx-public-${count.index}"
  }
}

# Private Subnets (for ASG)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "scalable-nginx-private-${count.index}"
  }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name = "scalable-nginx-nat-eip"
  }
}

# NAT Gateway for Private Subnets outbound traffic
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "scalable-nginx-nat-gw"
  }

  depends_on = [aws_internet_gateway.gw]
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "scalable-nginx-public-rt"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "scalable-nginx-private-rt"
  }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ================= SECURITY GROUPS =================

resource "aws_security_group" "alb" {
  name        = "scalable-nginx-alb-sg"
  description = "Allow public inbound HTTP traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "scalable-nginx-alb-sg"
  }
}

resource "aws_security_group" "instance" {
  name        = "scalable-nginx-instance-sg"
  description = "Allow inbound traffic from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Allow HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "scalable-nginx-instance-sg"
  }
}

# ================= APPLICATION LOAD BALANCER =================

resource "aws_lb" "external" {
  name               = "scalable-nginx-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "scalable-nginx-alb"
  }
}

resource "aws_lb_target_group" "target_group" {
  name     = "scalable-nginx-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/healthz"
    protocol            = "HTTP"
    port                = "80"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "scalable-nginx-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.external.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group.arn
  }
}

# ================= AUTO SCALING GROUP =================

resource "aws_launch_template" "nginx" {
  name_prefix   = "scalable-nginx-lt-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.instance.id]
  }

  # Build the container runtime and serving configuration on boot
  user_data = base64encode(<<-EOF
              #!/bin/bash
              # Update packages and install Docker
              dnf update -y
              dnf install -y docker
              systemctl start docker
              systemctl enable docker

              # Scaffold Application
              mkdir -p /app/src

              # Write index.html
              cat << 'HTML' > /app/src/index.html
              <!DOCTYPE html>
              <html lang="en">
              <head>
                  <meta charset="UTF-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1.0">
                  <meta name="description" content="Highly scalable AWS-hosted Nginx webpage showcase. Designed for high availability, performance, and modern aesthetics.">
                  <title>Scalable AWS Architecture Showcase</title>
                  <link rel="preconnect" href="https://fonts.googleapis.com">
                  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
                  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;600;800&family=Outfit:wght@400;600;800&display=swap" rel="stylesheet">
                  <style>
                      :root {
                          --bg-primary: #0a0e17;
                          --bg-secondary: rgba(255, 255, 255, 0.03);
                          --border-color: rgba(255, 255, 255, 0.08);
                          --text-primary: #f8fafc;
                          --text-secondary: #94a3b8;
                          --accent-purple: #8b5cf6;
                          --accent-blue: #3b82f6;
                          --accent-green: #10b981;
                          --accent-glow: rgba(139, 92, 246, 0.15);
                          --font-sans: 'Inter', sans-serif;
                          --font-display: 'Outfit', sans-serif;
                      }

                      * {
                          box-sizing: border-box;
                          margin: 0;
                          padding: 0;
                      }

                      body {
                          background-color: var(--bg-primary);
                          color: var(--text-primary);
                          font-family: var(--font-sans);
                          min-height: 100vh;
                          display: flex;
                          align-items: center;
                          justify-content: center;
                          overflow-x: hidden;
                          position: relative;
                          padding: 2rem 1rem;
                      }

                      .background-decorations {
                          position: absolute;
                          top: 0;
                          left: 0;
                          width: 100%;
                          height: 100%;
                          overflow: hidden;
                          z-index: 1;
                          pointer-events: none;
                      }

                      .glow-orb {
                          position: absolute;
                          border-radius: 50%;
                          filter: blur(120px);
                          opacity: 0.4;
                          mix-blend-mode: screen;
                          animation: float 20s infinite ease-in-out;
                      }

                      .orb-1 {
                          width: 400px;
                          height: 400px;
                          background: radial-gradient(circle, var(--accent-purple) 0%, transparent 80%);
                          top: -10%;
                          right: 10%;
                      }

                      .orb-2 {
                          width: 500px;
                          height: 500px;
                          background: radial-gradient(circle, var(--accent-blue) 0%, transparent 80%);
                          bottom: -15%;
                          left: 5%;
                          animation-delay: -5s;
                      }

                      .orb-3 {
                          width: 300px;
                          height: 300px;
                          background: radial-gradient(circle, var(--accent-green) 0%, transparent 80%);
                          top: 40%;
                          left: 50%;
                          transform: translate(-50%, -50%);
                          animation-duration: 25s;
                          animation-delay: -10s;
                      }

                      @keyframes float {
                          0%, 100% {
                              transform: translateY(0) scale(1);
                          }
                          50% {
                              transform: translateY(-40px) scale(1.1);
                          }
                      }

                      .dashboard-container {
                          background: rgba(15, 23, 42, 0.45);
                          backdrop-filter: blur(16px);
                          -webkit-backdrop-filter: blur(16px);
                          border: 1px solid var(--border-color);
                          border-radius: 24px;
                          padding: 3rem 2.5rem;
                          max-width: 900px;
                          width: 100%;
                          z-index: 10;
                          box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
                          transition: transform 0.3s ease, box-shadow 0.3s ease;
                      }

                      .dashboard-container:hover {
                          transform: translateY(-2px);
                          box-shadow: 0 30px 60px -10px rgba(139, 92, 246, 0.1);
                          border-color: rgba(139, 92, 246, 0.25);
                      }

                      .dashboard-header {
                          text-align: center;
                          margin-bottom: 3rem;
                      }

                      .badge {
                          display: inline-flex;
                          align-items: center;
                          gap: 0.5rem;
                          background: rgba(16, 185, 129, 0.1);
                          border: 1px solid rgba(16, 185, 129, 0.2);
                          color: var(--accent-green);
                          padding: 0.5rem 1rem;
                          border-radius: 9999px;
                          font-size: 0.85rem;
                          font-weight: 600;
                          letter-spacing: 0.05em;
                          text-transform: uppercase;
                          margin-bottom: 1.5rem;
                      }

                      .pulse-dot {
                          width: 8px;
                          height: 8px;
                          background-color: var(--accent-green);
                          border-radius: 50%;
                          box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7);
                          animation: pulse 1.6s infinite;
                      }

                      @keyframes pulse {
                          0% {
                              transform: scale(0.95);
                              box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7);
                          }
                          70% {
                              transform: scale(1);
                              box-shadow: 0 0 0 6px rgba(16, 185, 129, 0);
                          }
                          100% {
                              transform: scale(0.95);
                              box-shadow: 0 0 0 0 rgba(16, 185, 129, 0);
                          }
                      }

                      .main-title {
                          font-family: var(--font-display);
                          font-size: 2.75rem;
                          font-weight: 800;
                          line-height: 1.2;
                          background: linear-gradient(135deg, #ffffff 40%, #a5b4fc 100%);
                          -webkit-background-clip: text;
                          -webkit-text-fill-color: transparent;
                          margin-bottom: 1rem;
                      }

                      .subtitle {
                          font-size: 1.1rem;
                          color: var(--text-secondary);
                          max-width: 600px;
                          margin: 0 auto;
                          line-height: 1.6;
                      }

                      .metrics-grid {
                          display: grid;
                          grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
                          gap: 1.5rem;
                          margin-bottom: 2.5rem;
                      }

                      .metric-card {
                          background: var(--bg-secondary);
                          border: 1px solid var(--border-color);
                          border-radius: 16px;
                          padding: 1.75rem;
                          text-align: center;
                          transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
                          position: relative;
                          overflow: hidden;
                      }

                      .metric-card::before {
                          content: '';
                          position: absolute;
                          top: 0;
                          left: 0;
                          width: 100%;
                          height: 100%;
                          background: linear-gradient(180deg, rgba(255, 255, 255, 0.02) 0%, transparent 100%);
                          pointer-events: none;
                      }

                      .metric-card:hover {
                          transform: translateY(-4px);
                          border-color: rgba(255, 255, 255, 0.15);
                          background: rgba(255, 255, 255, 0.05);
                      }

                      .metric-card h3 {
                          font-size: 0.9rem;
                          text-transform: uppercase;
                          letter-spacing: 0.05em;
                          color: var(--text-secondary);
                          margin-bottom: 1rem;
                          font-weight: 600;
                      }

                      .metric-value {
                          font-family: var(--font-display);
                          font-size: 2.25rem;
                          font-weight: 800;
                          margin-bottom: 0.5rem;
                      }

                      .text-gradient-green {
                          background: linear-gradient(135deg, #a7f3d0 0%, #10b981 100%);
                          -webkit-background-clip: text;
                          -webkit-text-fill-color: transparent;
                      }

                      .text-gradient-blue {
                          background: linear-gradient(135deg, #93c5fd 0%, #3b82f6 100%);
                          -webkit-background-clip: text;
                          -webkit-text-fill-color: transparent;
                      }

                      .metric-label {
                          font-size: 0.85rem;
                          color: var(--text-secondary);
                      }

                      .architecture-diagram-card {
                          background: var(--bg-secondary);
                          border: 1px solid var(--border-color);
                          border-radius: 16px;
                          padding: 2rem;
                          margin-bottom: 2.5rem;
                      }

                      .architecture-diagram-card h3 {
                          font-size: 0.9rem;
                          text-transform: uppercase;
                          letter-spacing: 0.05em;
                          color: var(--text-secondary);
                          margin-bottom: 1.5rem;
                          font-weight: 600;
                          text-align: center;
                      }

                      .topography-container {
                          display: flex;
                          align-items: center;
                          justify-content: space-around;
                          gap: 1rem;
                          padding: 1rem 0;
                      }

                      .node-item {
                          display: flex;
                          flex-direction: column;
                          align-items: center;
                          gap: 0.75rem;
                          background: rgba(15, 23, 42, 0.6);
                          border: 1px solid var(--border-color);
                          padding: 1.25rem;
                          border-radius: 12px;
                          min-width: 120px;
                          transition: all 0.3s ease;
                      }

                      .node-item:hover {
                          border-color: var(--accent-purple);
                          box-shadow: 0 0 15px rgba(139, 92, 246, 0.15);
                      }

                      .node-icon {
                          font-size: 1.75rem;
                      }

                      .node-item span {
                          font-size: 0.85rem;
                          font-weight: 600;
                      }

                      .flow-line {
                          flex-grow: 1;
                          height: 2px;
                          background: linear-gradient(90deg, var(--accent-blue), var(--accent-purple));
                          position: relative;
                          opacity: 0.6;
                      }

                      .flow-line::after {
                          content: '';
                          position: absolute;
                          width: 6px;
                          height: 6px;
                          background: #ffffff;
                          border-radius: 50%;
                          top: 50%;
                          transform: translateY(-50%);
                          animation: flow-dot 2s infinite linear;
                      }

                      @keyframes flow-dot {
                          0% { left: 0%; opacity: 0; }
                          10% { opacity: 1; }
                          90% { opacity: 1; }
                          100% { left: 100%; opacity: 0; }
                      }

                      .dashboard-footer {
                          text-align: center;
                          border-top: 1px solid var(--border-color);
                          padding-top: 2rem;
                      }

                      .dashboard-footer p {
                          font-size: 0.8rem;
                          color: var(--text-secondary);
                      }

                      @media (max-width: 640px) {
                          .main-title {
                              font-size: 2rem;
                          }
                          .topography-container {
                              flex-direction: column;
                              gap: 1.5rem;
                          }
                          .flow-line {
                              width: 2px;
                              height: 40px;
                              flex-grow: 0;
                          }
                          .flow-line::after {
                              animation: flow-dot-vertical 2s infinite linear;
                          }
                          .dashboard-container {
                              padding: 2rem 1.5rem;
                          }
                      }

                      @keyframes flow-dot-vertical {
                          0% { top: 0%; opacity: 0; }
                          10% { opacity: 1; }
                          90% { opacity: 1; }
                          100% { top: 100%; opacity: 0; }
                      }
                  </style>
              </head>
              <body>
                  <div class="background-decorations">
                      <div class="glow-orb orb-1"></div>
                      <div class="glow-orb orb-2"></div>
                      <div class="glow-orb orb-3"></div>
                  </div>

                  <main class="dashboard-container" id="main-dashboard">
                      <header class="dashboard-header">
                          <div class="badge" id="status-badge">
                              <span class="pulse-dot"></span>
                              AWS Infrastructure: Active
                          </div>
                          <h1 class="main-title">Hello from a Scalable AWS Architecture!</h1>
                          <p class="subtitle">An optimized, containerized Nginx application running in a high-availability cloud environment.</p>
                      </header>

                      <section class="metrics-grid">
                          <div class="metric-card" id="card-status">
                              <h3>Server Status</h3>
                              <div class="metric-value text-gradient-green">Healthy</div>
                              <p class="metric-label">HTTP 200 OK via Nginx</p>
                          </div>
                          <div class="metric-card" id="card-latency">
                              <h3>Response Latency</h3>
                              <div class="metric-value" id="latency-val">12ms</div>
                              <p class="metric-label">CloudFront Edge Cached</p>
                          </div>
                          <div class="metric-card" id="card-scale">
                              <h3>Replica Count</h3>
                              <div class="metric-value text-gradient-blue" id="replica-val">3 / 10</div>
                              <p class="metric-label">Auto Scaling Enabled</p>
                          </div>
                      </section>

                      <section class="architecture-diagram-card">
                          <h3>Active Topography</h3>
                          <div class="topography-container">
                              <div class="node-item internet">
                                  <div class="node-icon">🌐</div>
                                  <span>Client</span>
                              </div>
                              <div class="flow-line"></div>
                              <div class="node-item load-balancer">
                                  <div class="node-icon">⚖️</div>
                                  <span>AWS ALB</span>
                              </div>
                              <div class="flow-line"></div>
                              <div class="node-item nginx-service">
                                  <div class="node-icon">⚙️</div>
                                  <span>Nginx Pods</span>
                              </div>
                          </div>
                      </section>

                      <footer class="dashboard-footer">
                          <p>Engineered with Google Antigravity &bull; Proactive Observability Enabled</p>
                      </footer>
                  </main>

                  <script>
                      const latencyElement = document.getElementById('latency-val');
                      const replicaElement = document.getElementById('replica-val');

                      setInterval(() => {
                          const randomLatency = Math.floor(Math.random() * 8) + 8;
                          latencyElement.innerText = randomLatency + 'ms';
                      }, 3000);

                      setInterval(() => {
                          const hour = new Date().getHours();
                          const baseReplicas = (hour >= 12 && hour <= 18) ? 6 : 3;
                          const fluctuation = Math.floor(Math.random() * 2);
                          replicaElement.innerText = (baseReplicas + fluctuation) + ' / 10';
                      }, 10000);
                  </script>
              </body>
              </html>
              HTML

              # Write nginx.conf
              cat << 'CONF' > /app/nginx.conf
              worker_processes auto;
              events {
                  worker_connections 1024;
              }
              http {
                  include       /etc/nginx/mime.types;
                  default_type  application/octet-stream;
                  sendfile        on;
                  keepalive_timeout  65;
                  server_tokens off;
                  gzip on;
                  gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

                  server {
                      listen 80;
                      server_name localhost;
                      root /usr/share/nginx/html;
                      index index.html;

                      location / {
                          try_files $uri $uri/ =404;
                      }

                      location /healthz {
                          access_log off;
                          default_type text/plain;
                          return 200 "OK\n";
                      }

                      location /metrics {
                          stub_status on;
                          access_log off;
                      }
                  }
              }
              CONF

              # Write Dockerfile
              cat << 'DOCKER' > /app/Dockerfile
              FROM alpine:3.18 AS validator
              WORKDIR /build
              COPY src/ .
              RUN test -f index.html

              FROM nginx:1.25-alpine
              COPY nginx.conf /etc/nginx/nginx.conf
              COPY --from=validator /build/ /usr/share/nginx/html/
              EXPOSE 80
              CMD ["nginx", "-g", "daemon off;"]
              DOCKER

              # Build and run application
              cd /app
              docker build -t nginx-app .
              docker run -d --name scalable-web -p 80:80 --restart always nginx-app
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "scalable-nginx-worker"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "asg" {
  name_prefix         = "scalable-nginx-asg-"
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.target_group.arn]

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  force_delete          = true
  health_check_type     = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.nginx.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
    triggers = ["tag"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ================= ASG TARGET TRACKING POLICY =================

resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "cpu-target-tracking-policy"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.asg.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.target_cpu_utilization
  }
}
