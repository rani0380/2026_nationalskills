# 네트워크 구성 이름표

모든 문자열은 Name 태그에 정확히 입력합니다. 모듈 2만 도쿄 리전이며 나머지는 서울 리전입니다.

## 모듈 1

- VPC: `practice-orders-vpc` (`10.81.0.0/16`)
- Public Subnet: `practice-orders-public-a` (`10.81.1.0/24`)
- Internet Gateway: `practice-orders-igw`
- Public Route Table: `practice-orders-public-rt`
- Client Security Group: `practice-orders-client-sg`
- Client EC2: `practice-orders-client`

## 모듈 2

- Client VPC: `practice-lattice-client-vpc` (`10.82.0.0/16`)
- Client Public Subnet: `practice-lattice-client-public-a` (`10.82.1.0/24`)
- Client IGW/RT: `practice-lattice-client-igw`, `practice-lattice-client-public-rt`
- Client SG/EC2: `practice-lattice-client-sg`, `practice-lattice-client`
- Service VPC: `practice-lattice-service-vpc` (`10.83.0.0/16`)
- Service Private Subnet: `practice-lattice-service-private-a` (`10.83.1.0/24`)
- Service SG/EC2: `practice-lattice-inventory-sg`, `practice-lattice-inventory`
- Association SG: `practice-lattice-assoc-sg`
- Service Network: `practice-lattice-sn`
- Service: `practice-lattice-inventory-service`
- Target Group: `practice-lattice-inventory-tg`
- Listener: `practice-lattice-http-listener`

## 모듈 3

모듈 3에는 VPC, Subnet, Route Table, IGW, Security Group 또는 EC2가 필요하지 않습니다.

## 모듈 4

- VPC: `practice-ecs-vpc` (`10.84.0.0/16`)
- Private Subnet A/C: `practice-ecs-private-a` (`10.84.1.0/24`), `practice-ecs-private-c` (`10.84.2.0/24`)
- Private Route Table A/C: `practice-ecs-private-rt-a`, `practice-ecs-private-rt-c`
- Worker Security Group: `practice-ecs-worker-sg`
- NAT 방식 Public Subnet A/C: `practice-ecs-public-a` (`10.84.11.0/24`), `practice-ecs-public-c` (`10.84.12.0/24`)
- NAT 방식 IGW/Public RT: `practice-ecs-igw`, `practice-ecs-public-rt`
- NAT Gateway A/C: `practice-ecs-nat-a`, `practice-ecs-nat-c`
- Endpoint 방식 SG: `practice-ecs-endpoint-sg`
- Endpoint Name 태그: `practice-ecs-vpce-ecr-api`, `practice-ecs-vpce-ecr-dkr`, `practice-ecs-vpce-logs`, `practice-ecs-vpce-sqs`, `practice-ecs-vpce-sts`, `practice-ecs-vpce-s3`
