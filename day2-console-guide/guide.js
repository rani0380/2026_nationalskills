
(() => {
  const key = 'nationalskills-day2-console-v1';
  const boxes = [...document.querySelectorAll('[data-step]')];
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem(key) || '{}'); } catch (_) {}
  if (!saved || typeof saved !== 'object') saved = {};
  function update() {
    let count = 0;
    boxes.forEach(box => {
      box.closest('.step').classList.toggle('completed', box.checked);
      if (box.checked) count++;
    });
    document.querySelector('#progress').max = boxes.length;
    document.querySelector('#progress').value = count;
    document.querySelector('#progress-label').textContent = `${count} / ${boxes.length}개 단락 완료`;
  }
  boxes.forEach(box => {
    box.checked = !!saved[box.dataset.step];
    box.addEventListener('change', () => {
      saved[box.dataset.step] = box.checked;
      try { localStorage.setItem(key, JSON.stringify(saved)); } catch (_) {}
      update();
    });
  });
  update();
  document.querySelector('#reset-progress').addEventListener('click', () => {
    if (!confirm('이 해설서의 완료 표시를 초기화할까요?')) return;
    saved = {}; boxes.forEach(box => box.checked = false);
    try { localStorage.removeItem(key); } catch (_) {} update();
  });
  const search = document.querySelector('#search');
  function filter() {
    const q = search.value.trim().toLocaleLowerCase(); let count = 0;
    document.querySelectorAll('.step').forEach(step => {
      step.hidden = !!q && !step.textContent.toLocaleLowerCase().includes(q);
      if (!step.hidden) count++;
    });
    document.querySelectorAll('.chapter').forEach(chapter => {
      chapter.hidden = !!q && ![...chapter.querySelectorAll('.step')].some(step => !step.hidden);
    });
    document.querySelector('#search-result').textContent = q ? `${count}개 단락 검색됨` : '';
  }
  search.addEventListener('input', filter);
  document.querySelectorAll('.sidebar nav a').forEach(link => link.addEventListener('click', () => {
    search.value = ''; filter();
    document.querySelectorAll('.sidebar nav a').forEach(item => item.classList.remove('active'));
    link.classList.add('active');
  }));
  document.querySelectorAll('.copy').forEach(button => button.addEventListener('click', async () => {
    const code = button.closest('.code-wrap').querySelector('pre code');
    try {
      await navigator.clipboard.writeText(code.textContent);
      button.textContent = '복사 완료';
    } catch (_) {
      const selection = window.getSelection(); const range = document.createRange();
      range.selectNodeContents(code); selection.removeAllRanges(); selection.addRange(range);
      button.textContent = '선택됨 · Ctrl+C';
    }
    setTimeout(() => button.textContent = '복사', 2400);
  }));
  document.querySelector('#toc-toggle').addEventListener('click', event => {
    const button = event.currentTarget;
    const expanded = button.getAttribute('aria-expanded') === 'true';
    button.setAttribute('aria-expanded', String(!expanded));
    document.querySelector('#toc-panel').hidden = expanded;
  });
})();
