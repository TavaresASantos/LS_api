# 1. CONFIGURAÇÃO DO PROVIDER E REPOSITÓRIO ECR
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1" # Região padrão do seu projeto
}

# NOVO: Criação automática do repositório ECR na conta nova
resource "aws_ecr_repository" "lacrei_repo" {
  name                 = "lacrei-api-repo"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true # Escaneia a imagem contra vulnerabilidades (DevSecOps)
  }
}

# 2. REDE (VPC E SUBRETS MULTI-AZ)
resource "aws_vpc" "lacrei_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "lacrei-vpc" }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.lacrei_vpc.id
  tags   = { Name = "lacrei-igw" }
}

resource "aws_subnet" "pub_1" {
  vpc_id                  = aws_vpc.lacrei_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "lacrei-pub-1" }
}

resource "aws_subnet" "pub_2" {
  vpc_id                  = aws_vpc.lacrei_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags                    = { Name = "lacrei-pub-2" }
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.lacrei_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.pub_1.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.pub_2.id
  route_table_id = aws_route_table.rt.id
}

# 3. SECURITY GROUPS (ISOLAMENTO DE REDE)
resource "aws_security_group" "alb_sg" {
  name   = "lacrei-alb-sg"
  vpc_id = aws_vpc.lacrei_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Produção
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Staging
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_sg" {
  name   = "lacrei-ecs-sg"
  vpc_id = aws_vpc.lacrei_vpc.id

  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # SÓ ACEITA TRAFEGO DO ALB
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 4. LOAD BALANCER (ALB) E TARGET GROUPS
resource "aws_lb" "lacrei_alb" {
  name               = "lacrei-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.pub_1.id, aws_subnet.pub_2.id]
}

resource "aws_lb_target_group" "prod_tg" {
  name        = "tg-lacrei-api-prod"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.lacrei_vpc.id
  target_type = "ip"

  health_check {
    path                = "/status"
    port                = "3000"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }
}

resource "aws_lb_target_group" "staging_tg" {
  name        = "tg-lacrei-api-staging"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.lacrei_vpc.id
  target_type = "ip"

  health_check {
    path                = "/status"
    port                = "3000"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }
}

# LISTENERS (PORTA 80 -> PROD, PORTA 8080 -> STAGING)
resource "aws_lb_listener" "prod_listener" {
  load_balancer_arn = aws_lb.lacrei_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.prod_tg.arn
  }
}

resource "aws_lb_listener" "staging_listener" {
  load_balancer_arn = aws_lb.lacrei_alb.arn
  port              = "8080"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.staging_tg.arn
  }
}

# 5. IAM ROLES (PERMISSÕES DO ECS)
resource "aws_iam_role" "ecs_execution_role" {
  name = "lacrei_ecs_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# CLOUDWATCH LOG GROUP FOR ECS
resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/lacrei-api-task"
  retention_in_days = 7
}

# 6. ECS CLUSTER E TASK DEFINITIONS
resource "aws_ecs_cluster" "lacrei_cluster" {
  name = "lacrei-ecs-cluster"
}

# TASK DE PRODUÇÃO (REFERENCIANDO O ECR DINAMICAMENTE)
resource "aws_ecs_task_definition" "prod_task" {
  family                   = "lacrei-api-task-service-production"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn

  container_definitions = jsonencode([{
    name      = "lacrei-container-prod"
    image     = "${aws_ecr_repository.lacrei_repo.repository_url}:latest" # DINÂMICO
    essential = true
    portMappings = [{
      containerPort = 3000
      hostPort      = 3000
    }]
    healthCheck = {
      command  = ["CMD-SHELL", "curl -f http://localhost:3000/status || exit 1"]
      interval = 30
      timeout  = 5
      retries  = 3
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs_logs.name
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "prod"
      }
    }
  }])
}

# TASK DE STAGING (REFERENCIANDO O ECR DINAMICAMENTE)
resource "aws_ecs_task_definition" "staging_task" {
  family                   = "lacrei-api-task-service-staging"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn

  container_definitions = jsonencode([{
    name      = "lacrei-container-staging"
    image     = "${aws_ecr_repository.lacrei_repo.repository_url}:latest" # DINÂMICO
    essential = true
    portMappings = [{
      containerPort = 3000
      hostPort      = 3000
    }]
    healthCheck = {
      command  = ["CMD-SHELL", "curl -f http://localhost:3000/status || exit 1"]
      interval = 30
      timeout  = 5
      retries  = 3
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs_logs.name
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "staging"
      }
    }
  }])
}

# 7. SERVICES COM CIRCUIT BREAKER (ROLLBACK AUTOMÁTICO)
resource "aws_ecs_service" "prod_service" {
  name                              = "lacrei-api-service-prod"
  cluster                           = aws_ecs_cluster.lacrei_cluster.id
  task_definition                   = aws_ecs_task_definition.prod_task.arn
  desired_count                     = 2
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 300

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = [aws_subnet.pub_1.id, aws_subnet.pub_2.id]
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.prod_tg.arn
    container_name   = "lacrei-container-prod"
    container_port   = 3000
  }
}

resource "aws_ecs_service" "staging_service" {
  name                              = "lacrei-api-service-staging"
  cluster                           = aws_ecs_cluster.lacrei_cluster.id
  task_definition                   = aws_ecs_task_definition.staging_task.arn
  desired_count                     = 2
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 300

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = [aws_subnet.pub_1.id, aws_subnet.pub_2.id]
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.staging_tg.arn
    container_name   = "lacrei-container-staging"
    container_port   = 3000
  }
}


# ==============================================================================
# VERSÃO 2: ARQUITETURA TLS/HTTPS PARA CENÁRIO REAL COM DOMÍNIO PROPRIO
#
# ==============================================================================

# 1. SOLICITAÇÃO DO CERTIFICADO SSL/TLS NO AWS ACM
# resource "aws_acm_certificate" "lacrei_cert" {
#   domain_name       = "api.lacrei.com.br" # Domínio oficial da plataforma
#   validation_method = "DNS"
#   tags              = { Environment = "production" }
# }

# 2. LISTENER SECURE HTTPS (PORTA 443)
# resource "aws_lb_listener" "https_listener" {
#   load_balancer_arn = aws_lb.lacrei_alb.arn
#   port              = "443"
#   protocol          = "HTTPS"
#   ssl_policy        = "ELBSecurityPolicy-2016-08"
#   certificate_arn   = aws_acm_certificate.lacrei_cert.arn
# 
#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.prod_tg.arn
#   }
# }

# 3. IMPLEMENTAÇÃO DE REDIRECT 301 NO LISTENER HTTP (PORTA 80)
# Se fôssemos ativar o HTTPS, o bloco "prod_listener" da seção 4 seria substituído por este:
# default_action {
#   type = "redirect"
#   redirect {
#     port        = "443"
#     protocol    = "HTTPS"
#     status_code = "HTTP_301"
#   }
# }