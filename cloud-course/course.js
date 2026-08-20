const lessonTitles = [
  '과제 분석과 전체 아키텍처 이해',
  'VPC·Subnet·Security Group',
  'RDS MySQL과 데이터 적재',
  '애플리케이션 단독 실행',
  'Docker 컨테이너화',
  'ECR 이미지 저장소',
  'EKS 클러스터와 Worker Node',
  'Deployment·Service·Probe',
  'USER·PRODUCT·STRESS 전체 배포',
  'ALB·Ingress 단일 Endpoint',
  'S3 상품 이미지 서비스',
  '403·404 처리',
  'CloudWatch·로그·장애 분석',
  '성능·처리율 측정',
  'Pod·Node 성능 튜닝',
  '비용 최적화',
  '장애 대응 종합훈련',
  '3시간 실전 모의대회'
];

const flowSteps = [
  'VPC', 'RDS', 'Application Test', 'Docker', 'ECR', 'EKS',
  'Deployment/Service', 'ALB/Ingress', 'S3', '403/404',
  'Monitoring', 'Performance', 'Cost', 'Mock Contest'
];

const lessonHeading = document.querySelector('h2');
const heroActions = document.querySelector('.hero .actions');
if (heroActions && !heroActions.querySelector('[href="grader.html"]')) {
  const graderLink = document.createElement('a');
  graderLink.className = 'btn alt';
  graderLink.href = 'grader.html';
  graderLink.textContent = '모의 채점실';
  heroActions.appendChild(graderLink);
}
if (heroActions && !heroActions.querySelector('[href="challenge2-practice.html"]')) {
  const challengeLink = document.createElement('a');
  challengeLink.className = 'btn alt';
  challengeLink.href = 'challenge2-practice.html';
  challengeLink.textContent = '제2과제 최종 모의대회';
  heroActions.appendChild(challengeLink);
}
const flowSection = document.createElement('section');
flowSection.className = 'learning-flow';
flowSection.innerHTML = `
  <h2>학습 흐름</h2>
  <div class="flow-list" aria-label="전체 학습 흐름">
    ${flowSteps.map((step, index) => `
      <span class="flow-step">${step}</span>${index < flowSteps.length - 1 ? '<span class="flow-arrow" aria-hidden="true">→</span>' : ''}
    `).join('')}
  </div>`;
lessonHeading.before(flowSection);

const cards = document.querySelectorAll('.card');
cards.forEach((card, index) => {
  const lesson = String(index + 1).padStart(2, '0');
  const title = card.querySelector('h3');
  if (title) title.textContent = lessonTitles[index];
  card.setAttribute('role', 'link');
  card.setAttribute('tabindex', '0');
  card.setAttribute('aria-label', `${lesson}차시 ${lessonTitles[index]} 수업 내용 열기`);
  const openLesson = () => location.href = `lesson.html?lesson=${lesson}`;
  card.addEventListener('click', openLesson);
  card.addEventListener('keydown', event => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      openLesson();
    }
  });
});

const style = document.createElement('style');
style.textContent = `
.learning-flow{margin-top:38px}
.learning-flow h2{margin-bottom:14px}
.flow-list{display:flex;align-items:center;flex-wrap:wrap;gap:9px;padding:18px;background:var(--panel);border:1px solid var(--line);border-radius:18px}
.flow-step{padding:7px 11px;border-radius:10px;background:#1c2844;color:var(--text);font-size:13px;font-weight:700}
.flow-arrow{color:var(--accent);font-weight:800}
@media(max-width:600px){.flow-list{align-items:stretch}.flow-step{flex:1 1 42%;text-align:center}.flow-arrow{display:none}}
`;
document.head.appendChild(style);
