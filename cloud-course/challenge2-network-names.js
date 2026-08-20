(() => {
  const modules = document.querySelector('.modules');
  if (!modules) return;
  const section = document.createElement('section');
  section.className = 'panel network-names';
  section.innerHTML = `
    <style>.network-names{grid-column:1/-1}.network-names details{margin:12px 0;border:1px solid var(--line);border-radius:14px;background:#0b1729}.network-names summary{cursor:pointer;padding:15px 17px;font-weight:900;color:var(--blue)}.network-names .table-box{overflow:auto;padding:0 16px 16px}.network-names table{width:100%;border-collapse:collapse;min-width:760px}.network-names th,.network-names td{padding:9px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}.network-names th{color:#ddecff}.network-names td:nth-child(2) code{color:var(--yellow)}.required{color:var(--green);font-weight:800}.optional{color:var(--muted);font-weight:800}</style>
    <h2>네트워크 구성 이름표</h2>
    <p class="muted">아래 문자열을 <strong>Name 태그</strong>로 정확히 입력합니다. VPC Lattice Service처럼 Name 필드가 있는 리소스는 리소스 이름 자체도 같은 문자열을 사용합니다. 임의 축약이나 대소문자 변경은 하지 않습니다.</p>
    <details open><summary>모듈 1 · DynamoDB Client Network</summary><div class="table-box"><table><thead><tr><th>구분</th><th>정확한 이름/Name 태그</th><th>CIDR·설정</th><th>연결 대상</th><th>필수</th></tr></thead><tbody>
      <tr><td>VPC</td><td><code>practice-orders-vpc</code></td><td>10.81.0.0/16, DNS support/hostnames Enabled</td><td>서울 ap-northeast-2</td><td class="required">필수</td></tr>
      <tr><td>Public Subnet</td><td><code>practice-orders-public-a</code></td><td>10.81.1.0/24, Public IPv4 auto-assign Enabled</td><td>AZ-a</td><td class="required">필수</td></tr>
      <tr><td>Internet Gateway</td><td><code>practice-orders-igw</code></td><td>—</td><td>practice-orders-vpc</td><td class="required">필수</td></tr>
      <tr><td>Public Route Table</td><td><code>practice-orders-public-rt</code></td><td>0.0.0.0/0 → practice-orders-igw</td><td>practice-orders-public-a</td><td class="required">필수</td></tr>
      <tr><td>Client Security Group</td><td><code>practice-orders-client-sg</code></td><td>Inbound TCP/8080 from 0.0.0.0/0</td><td>practice-orders-client</td><td class="required">필수</td></tr>
      <tr><td>Client EC2</td><td><code>practice-orders-client</code></td><td>t3.micro, Public IP</td><td>practice-orders-public-a</td><td class="required">필수</td></tr>
    </tbody></table></div></details>
    <details open><summary>모듈 2 · VPC Lattice Client/Service Network</summary><div class="table-box"><table><thead><tr><th>구분</th><th>정확한 이름/Name 태그</th><th>CIDR·설정</th><th>연결 대상</th><th>필수</th></tr></thead><tbody>
      <tr><td>Client VPC</td><td><code>practice-lattice-client-vpc</code></td><td>10.82.0.0/16, DNS Enabled</td><td>도쿄 ap-northeast-1</td><td class="required">필수</td></tr>
      <tr><td>Client Public Subnet</td><td><code>practice-lattice-client-public-a</code></td><td>10.82.1.0/24</td><td>Client VPC, AZ-a</td><td class="required">필수</td></tr>
      <tr><td>Client IGW</td><td><code>practice-lattice-client-igw</code></td><td>—</td><td>Client VPC</td><td class="required">필수</td></tr>
      <tr><td>Client Public RT</td><td><code>practice-lattice-client-public-rt</code></td><td>0.0.0.0/0 → Client IGW</td><td>Client Public Subnet</td><td class="required">필수</td></tr>
      <tr><td>Client EC2 SG</td><td><code>practice-lattice-client-sg</code></td><td>Inbound TCP/80 from 0.0.0.0/0</td><td>practice-lattice-client</td><td class="required">필수</td></tr>
      <tr><td>Client EC2</td><td><code>practice-lattice-client</code></td><td>t3.micro, Public IP</td><td>Client Public Subnet</td><td class="required">필수</td></tr>
      <tr><td>Service VPC</td><td><code>practice-lattice-service-vpc</code></td><td>10.83.0.0/16, DNS Enabled</td><td>도쿄 ap-northeast-1</td><td class="required">필수</td></tr>
      <tr><td>Service Private Subnet</td><td><code>practice-lattice-service-private-a</code></td><td>10.83.1.0/24, Public IPv4 auto-assign Disabled</td><td>Service VPC, AZ-a</td><td class="required">필수</td></tr>
      <tr><td>Service EC2 SG</td><td><code>practice-lattice-inventory-sg</code></td><td>Inbound TCP/8080 from VPC Lattice Managed Prefix List</td><td>practice-lattice-inventory</td><td class="required">필수</td></tr>
      <tr><td>Service EC2</td><td><code>practice-lattice-inventory</code></td><td>t3.micro, Public IP 없음</td><td>Service Private Subnet</td><td class="required">필수</td></tr>
      <tr><td>Association SG</td><td><code>practice-lattice-assoc-sg</code></td><td>Inbound TCP/80 from 10.82.0.0/16</td><td>Service Network ↔ Client VPC Association</td><td class="required">필수</td></tr>
      <tr><td>Service Network</td><td><code>practice-lattice-sn</code></td><td>Auth type None</td><td>Client VPC Association</td><td class="required">필수</td></tr>
      <tr><td>Lattice Service</td><td><code>practice-lattice-inventory-service</code></td><td>HTTP/80 Listener</td><td>practice-lattice-sn</td><td class="required">필수</td></tr>
      <tr><td>Target Group</td><td><code>practice-lattice-inventory-tg</code></td><td>Instance, HTTP/8080, /health</td><td>Service EC2</td><td class="required">필수</td></tr>
      <tr><td>Listener</td><td><code>practice-lattice-http-listener</code></td><td>HTTP/80, Forward to inventory-tg</td><td>Lattice Service</td><td class="required">필수</td></tr>
      <tr><td>Service Public Subnet</td><td><code>practice-lattice-service-public-a</code></td><td>10.83.254.0/24</td><td>NAT 배치용</td><td class="optional">NAT 사용 시</td></tr>
      <tr><td>Service IGW / NAT / RT</td><td><code>practice-lattice-service-igw</code><br><code>practice-lattice-service-nat-a</code><br><code>practice-lattice-service-private-rt</code></td><td>Private RT: 0.0.0.0/0 → NAT</td><td>Service 앱 설치용 Outbound</td><td class="optional">NAT 사용 시</td></tr>
    </tbody></table><p class="warn"><strong>금지:</strong> Client VPC와 Service VPC 사이에 VPC Peering, Transit Gateway, VPN 또는 PrivateLink Endpoint Service를 만들지 않습니다.</p></div></details>
    <details><summary>모듈 3 · IAM Event Handling</summary><div class="table-box"><p class="success"><strong>모듈 3에는 VPC, Subnet, Route Table, Internet Gateway, Security Group 또는 EC2가 필요하지 않습니다.</strong> IAM과 S3는 Global 서비스이고 Lambda·SNS·EventBridge·CloudWatch Logs는 서울 리전에 구성합니다. 불필요한 네트워크 리소스를 추가하지 않습니다.</p></div></details>
    <details open><summary>모듈 4 · SQS/ECS Fargate Network</summary><div class="table-box"><table><thead><tr><th>구분</th><th>정확한 이름/Name 태그</th><th>CIDR·설정</th><th>연결 대상</th><th>필수</th></tr></thead><tbody>
      <tr><td>VPC</td><td><code>practice-ecs-vpc</code></td><td>10.84.0.0/16, DNS Enabled</td><td>서울 ap-northeast-2</td><td class="required">필수</td></tr>
      <tr><td>Private Subnet A</td><td><code>practice-ecs-private-a</code></td><td>10.84.1.0/24, Public IPv4 Disabled</td><td>AZ-a, ECS Service</td><td class="required">필수</td></tr>
      <tr><td>Private Subnet C</td><td><code>practice-ecs-private-c</code></td><td>10.84.2.0/24, Public IPv4 Disabled</td><td>AZ-c, ECS Service</td><td class="required">필수</td></tr>
      <tr><td>Fargate Task SG</td><td><code>practice-ecs-worker-sg</code></td><td>Inbound 없음, Outbound HTTPS/443 허용</td><td>practice-ecs-worker-service</td><td class="required">필수</td></tr>
      <tr><td>Private RT A</td><td><code>practice-ecs-private-rt-a</code></td><td>NAT 또는 VPC Endpoint 경로</td><td>practice-ecs-private-a</td><td class="required">필수</td></tr>
      <tr><td>Private RT C</td><td><code>practice-ecs-private-rt-c</code></td><td>NAT 또는 VPC Endpoint 경로</td><td>practice-ecs-private-c</td><td class="required">필수</td></tr>
      <tr><td>Public Subnet A</td><td><code>practice-ecs-public-a</code></td><td>10.84.11.0/24</td><td>AZ-a, NAT A</td><td class="optional">NAT 방식</td></tr>
      <tr><td>Public Subnet C</td><td><code>practice-ecs-public-c</code></td><td>10.84.12.0/24</td><td>AZ-c, NAT C</td><td class="optional">NAT 방식</td></tr>
      <tr><td>IGW</td><td><code>practice-ecs-igw</code></td><td>—</td><td>practice-ecs-vpc</td><td class="optional">NAT 방식</td></tr>
      <tr><td>Public RT</td><td><code>practice-ecs-public-rt</code></td><td>0.0.0.0/0 → practice-ecs-igw</td><td>Public Subnet A/C</td><td class="optional">NAT 방식</td></tr>
      <tr><td>NAT Gateway A/C</td><td><code>practice-ecs-nat-a</code><br><code>practice-ecs-nat-c</code></td><td>각 AZ Public Subnet</td><td>각 Private RT 기본 경로</td><td class="optional">NAT 방식</td></tr>
      <tr><td>Endpoint SG</td><td><code>practice-ecs-endpoint-sg</code></td><td>Inbound TCP/443 from practice-ecs-worker-sg</td><td>Interface VPC Endpoints</td><td class="optional">Endpoint 방식</td></tr>
      <tr><td>VPC Endpoints</td><td><code>practice-ecs-vpce-ecr-api</code><br><code>practice-ecs-vpce-ecr-dkr</code><br><code>practice-ecs-vpce-logs</code><br><code>practice-ecs-vpce-sqs</code><br><code>practice-ecs-vpce-sts</code><br><code>practice-ecs-vpce-s3</code></td><td>Private DNS Enabled; S3는 Gateway 타입</td><td>Private Subnet A/C 및 Private RT</td><td class="optional">Endpoint 방식</td></tr>
    </tbody></table><p class="muted">NAT 방식과 Endpoint 방식을 동시에 만들 필요는 없습니다. 연습에서는 둘 중 하나만 선택하되, ECR Image Pull·SQS·STS·CloudWatch Logs가 모두 통신되어야 합니다.</p></div></details>`;
  modules.before(section);
})();
