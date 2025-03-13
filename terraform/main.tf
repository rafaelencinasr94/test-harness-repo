terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }
  required_version = ">= 1.2.0"
}


locals {
  key_name = "harness_terraform"
}

provider "aws" {
  region = "us-west-1"
}

resource "aws_vpc" "main_vpc" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "main_vpc"
  }
}

resource "aws_subnet" "subnet-1" {
  vpc_id = aws_vpc.main_vpc.id
  cidr_block = cidrsubnet(aws_vpc.main_vpc.cidr_block, 8, 1)
  map_public_ip_on_launch = true
  availability_zone = "us-west-1b"
    tags = {
      Name = "subnet-1b"
    }
}

output "ecs_subnet_id" {
  value = aws_subnet.subnet-1.id
}

resource "aws_subnet" "subnet-2" {
  vpc_id = aws_vpc.main_vpc.id
  cidr_block = cidrsubnet(aws_vpc.main_vpc.cidr_block, 8, 2)
  map_public_ip_on_launch = true
  availability_zone = "us-west-1c"
    tags = {
      Name = "subnet-1c"
    }
}

resource "aws_internet_gateway" "harness-igw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "harness-igw"
  }
}

resource "aws_route_table" "harness-public-rt" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.harness-igw.id
  }

  tags = {
    Name = "harness-public-rt"
  }
}

resource "aws_route_table_association" "subnet-1-route" {
  subnet_id      = aws_subnet.subnet-1.id
  route_table_id = aws_route_table.harness-public-rt.id
}

resource "aws_route_table_association" "subnet-2-route" {
  subnet_id      = aws_subnet.subnet-2.id
  route_table_id = aws_route_table.harness-public-rt.id
}

resource "aws_security_group" "harness-subnet-sg" {
  name        = "harness-public-subnet-sg"
  description = "Allow SSH inboud traffic and all outbound traffic"
  vpc_id      = aws_vpc.main_vpc.id

         ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    self        = "false"
    cidr_blocks = ["0.0.0.0/0"]
    description = "any"
    }



     ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    self        = "false"
    cidr_blocks = ["0.0.0.0/0"]
    description = "any"
    }


    egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    }

  tags = {
    Name = "harness-subnet-sg"
  }
}

output "ecs_sg_id" {
  value = aws_security_group.harness-subnet-sg.id
}

resource "aws_launch_template" "ecs_lt" {
  name_prefix   = "ecs-template"
  image_id           = "ami-08d4f6bbae664bd41"
  key_name = local.key_name
  instance_type = "t2.micro"
  vpc_security_group_ids = [aws_security_group.harness-subnet-sg.id]

  iam_instance_profile {
      name = "ecsInstanceRole"
  }
  block_device_mappings {
      device_name = "/dev/xvda"
      ebs {
          volume_size = 30
          volume_type = "gp2"
      }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "ecs-instance"
    }
  }
}

resource "aws_autoscaling_group" "ecs_asg" {
  vpc_zone_identifier = [aws_subnet.subnet-1.id, aws_subnet.subnet-2.id]
  desired_capacity = 1
  max_size = 2
  min_size = 1

  launch_template {
    id = aws_launch_template.ecs_lt.id
    version = "$Latest"
  }

  tag {
    key = "AmazonECSManaged"
    value = true
    propagate_at_launch = true
  }
}

resource "aws_lb" "ecs_alb" {
  name = "ecs-alb"
  internal = false
  load_balancer_type = "application"
  security_groups = [aws_security_group.harness-subnet-sg.id]
  subnets = [ aws_subnet.subnet-1.id, aws_subnet.subnet-2.id ]

  tags = {
    Name = "ecs-alb"
  }
}

resource "aws_lb_target_group" "ecs_tg" {
  name = "ecs-target-group"
  port = 8080
  protocol = "HTTP"
  target_type = "ip"
  vpc_id = aws_vpc.main_vpc.id

  health_check {
    path = "/"
  }
}

resource "aws_lb_listener" "ecs_alb_listener" {
  load_balancer_arn = aws_lb.ecs_alb.arn
  port = 8080
  protocol = "HTTP"

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.ecs_tg.id
  }
}

resource "aws_ecs_cluster" "ecs_cluster" {
  name = "my-ecs-cluster"
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.ecs_cluster.name
}


resource "aws_ecs_capacity_provider" "ecs_capacity_provider" {
  name = "test1"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.ecs_asg.arn
    managed_scaling {
        maximum_scaling_step_size = 1000
        minimum_scaling_step_size = 1
        status = "ENABLED"
        target_capacity = 3
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "example" {
  cluster_name = aws_ecs_cluster.ecs_cluster.name

  capacity_providers = [aws_ecs_capacity_provider.ecs_capacity_provider.name]

  default_capacity_provider_strategy {
    base = 1
    weight = 100
    capacity_provider = aws_ecs_capacity_provider.ecs_capacity_provider.name
  }
}