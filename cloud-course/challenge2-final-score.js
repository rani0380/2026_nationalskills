(() => {
  const footer = document.querySelector('footer');
  const fileInput = document.getElementById('resultFile');
  if (!footer || !fileInput) return;

  const names = {
    1: 'DynamoDB 주문 애플리케이션',
    2: 'VPC Lattice 서비스 연결',
    3: 'IAM 변경 이벤트 자동 복구',
    4: 'SQS 기반 ECS Auto Scaling',
  };

  const section = document.createElement('section');
  section.className = 'panel final-score-panel';
  section.innerHTML = `
    <style>
      .final-score-panel{margin-top:18px}.final-score-head{display:flex;justify-content:space-between;gap:16px;align-items:end}.final-score-total{text-align:right}.final-score-total strong{display:block;color:var(--green);font-size:34px;line-height:1.1}.final-score-table{width:100%;border-collapse:collapse;margin-top:16px}.final-score-table th,.final-score-table td{padding:12px 10px;border-bottom:1px solid var(--line);text-align:left}.final-score-table th{color:var(--blue)}.score-number{font-size:18px;font-weight:900;white-space:nowrap}.score-track{height:10px;min-width:140px;background:#071220;border-radius:99px;overflow:hidden}.score-fill{height:100%;background:linear-gradient(90deg,var(--blue),var(--green));border-radius:99px}.final-feedback{margin-top:16px;padding:14px 16px;border:1px solid var(--line);border-radius:12px;background:#0b1729}.final-empty{padding:24px;text-align:center;border:2px dashed var(--line);border-radius:14px;color:var(--muted)}@media(max-width:650px){.final-score-head{display:block}.final-score-total{text-align:left;margin-top:10px}.final-score-table th:nth-child(2),.final-score-table td:nth-child(2){display:none}}
    </style>
    <div class="final-score-head"><div><h2>내 모듈별 최종 점수</h2><p class="muted">채점표의 마지막에서 각 모듈 취득점수와 보완 우선순위를 확인합니다.</p></div><div class="final-score-total"><span>총점</span><strong id="finalTotal">— / 30.0</strong><span id="finalRate" class="muted">달성률 —</span></div></div>
    <div id="finalScoreBody" class="final-empty">위의 CloudShell 자동 채점 영역에서 <code>challenge2-grade-result.json</code>을 불러오면 모듈별 점수가 표시됩니다.</div>`;
  footer.before(section);

  function render(result) {
    if (!result || result.schema !== 'challenge2-practice-v1' || !Array.isArray(result.modules)) return;
    const modules = result.modules.slice().sort((a, b) => a.module - b.module);
    const total = Number(result.score) || 0;
    const max = Number(result.maxScore) || 30;
    const rate = max ? Math.round(total / max * 100) : 0;
    document.getElementById('finalTotal').textContent = `${total.toFixed(1)} / ${max.toFixed(1)}`;
    document.getElementById('finalRate').textContent = `달성률 ${rate}%`;

    const minimum = Math.min(...modules.map(m => Number(m.score) || 0));
    const weakest = modules.filter(m => Number(m.score) === minimum).map(m => `모듈 ${m.module}`).join(', ');
    const rows = modules.map(m => {
      const score = Number(m.score) || 0;
      const moduleMax = Number(m.max) || 7.5;
      const percent = moduleMax ? Math.max(0, Math.min(100, score / moduleMax * 100)) : 0;
      const passed = Array.isArray(m.checks) ? m.checks.filter(c => c.status === 'pass').length : 0;
      const count = Array.isArray(m.checks) ? m.checks.length : 0;
      return `<tr><td><strong>모듈 ${m.module}</strong><br><span class="muted">${names[m.module] || ''}</span></td><td><div class="score-track" aria-label="모듈 ${m.module} 달성률 ${Math.round(percent)}%"><div class="score-fill" style="width:${percent}%"></div></div></td><td class="score-number">${score.toFixed(1)} / ${moduleMax.toFixed(1)}</td><td>${passed} / ${count} 항목</td></tr>`;
    }).join('');

    let message;
    if (rate >= 90) message = '실전 제출 전 실제 자동 복구와 Scale-out 동작만 한 번 더 검증하세요.';
    else if (rate >= 70) message = `${weakest}의 실패 항목부터 다시 확인하면 점수를 빠르게 높일 수 있습니다.`;
    else message = `${weakest}를 우선 재구축하고, 실패 항목의 리전·이름·연결 상태를 채점 명령과 대조하세요.`;

    document.getElementById('finalScoreBody').className = '';
    document.getElementById('finalScoreBody').innerHTML = `<div style="overflow:auto"><table class="final-score-table"><thead><tr><th>모듈</th><th>달성도</th><th>취득점수</th><th>통과 항목</th></tr></thead><tbody>${rows}</tbody></table></div><div class="final-feedback"><strong>학습 피드백</strong><br>${message}</div>`;
    section.scrollIntoView({behavior: 'smooth', block: 'start'});
  }

  fileInput.addEventListener('change', async event => {
    try {
      const file = event.target.files && event.target.files[0];
      if (!file) return;
      render(JSON.parse(await file.text()));
    } catch (_) {
      document.getElementById('finalScoreBody').className = 'final-empty';
      document.getElementById('finalScoreBody').textContent = '모듈별 점수를 표시할 수 없습니다. 올바른 자동 채점 JSON을 선택하세요.';
    }
  });
})();
