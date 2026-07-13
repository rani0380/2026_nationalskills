const docs = {
  solution: {
    title: "1과제 풀이해설서",
    description: "구축 순서, 설정 예시, 검증 명령, 실수 방지 체크리스트를 정리한 문서입니다.",
    file: "풀이해설서.md",
  },
  theory: {
    title: "1과제 이론설명서",
    description: "AWS 서비스와 Kubernetes 운영 개념을 시험 요구사항 중심으로 설명한 문서입니다.",
    file: "이론설명서.md",
  },
  detailed: {
    title: "1과제·2과제 상세 풀이집",
    description: "선별 과제의 채점 스크립트 기준 구성 순서, 핵심 명령, 검증 포인트를 정리한 문서입니다.",
    file: "상세풀이집.md",
  },
  task02first: {
    title: "02_1과제_1등 상세 풀이",
    description: "select/1과제/02_1과제_1등 문제를 채점 스크립트 기준으로 더 자세히 풀어쓴 절차형 문서입니다.",
    file: "02_1과제_1등_상세풀이.md",
  },
  task02second: {
    title: "2과제 풀이해설서",
    description: "select/2과제/02_2과제_1등의 Workflow, Analytics, Event Handling, MSK 모듈 풀이와 이론을 정리한 문서입니다.",
    file: "02_2과제_1등_상세풀이.md",
  },
  task02m1: {
    title: "02_2 Module 1 Workflow 설명서",
    description: "S3, Lambda, DynamoDB, Step Functions로 학생 성적 처리 워크플로우를 구성하는 모듈별 설명서입니다.",
    file: "02_2과제_Module1_Workflow_설명서.md",
  },
  task02m2: {
    title: "02_2 Module 2 Analytics 설명서",
    description: "EC2, ALB, Kinesis Data Stream, Managed Flink로 실시간 주문 분석을 구성하는 모듈별 설명서입니다.",
    file: "02_2과제_Module2_Analytics_설명서.md",
  },
  task02m3: {
    title: "02_2 Module 3 Event Handling 설명서",
    description: "EventBridge, AWS Config, Lambda, SNS로 보안 이벤트 자동 복구를 구성하는 모듈별 설명서입니다.",
    file: "02_2과제_Module3_EventHandling_설명서.md",
  },
  task02m4: {
    title: "02_2 Module 4 MSK 설명서",
    description: "Amazon MSK, Kafka topic, Producer EC2, Lambda consumer로 스트리밍 파이프라인을 구성하는 모듈별 설명서입니다.",
    file: "02_2과제_Module4_MSK_설명서.md",
  },
  consoleCli: {
    title: "AWS 콘솔 + CLI 보강 풀이",
    description: "콘솔 화면 예시 이미지와 중간에 필요한 CLI 명령을 함께 정리한 실전 보강 풀이입니다.",
    file: "AWS콘솔_CLI_보강풀이.md",
  },
};

const params = new URLSearchParams(window.location.search);
const docKey = docs[params.get("doc")] ? params.get("doc") : "solution";
const selected = docs[docKey];

document.title = `${selected.title} | 2026 전국기능경기대회 클라우드컴퓨팅`;
document.getElementById("doc-title").textContent = selected.title;
document.getElementById("doc-description").textContent = selected.description;

for (const link of document.querySelectorAll("[data-doc-link]")) {
  if (link.dataset.docLink === docKey) {
    link.setAttribute("aria-current", "page");
  }
}

fetch(encodeURI(selected.file))
  .then((response) => {
    if (!response.ok) {
      throw new Error(`문서를 불러오지 못했습니다. (${response.status})`);
    }
    return response.text();
  })
  .then((markdown) => {
    document.getElementById("content").innerHTML = renderMarkdown(markdown);
  })
  .catch((error) => {
    document.getElementById("content").innerHTML = `<p class="error">${escapeHtml(error.message)}</p>`;
  });

function renderMarkdown(markdown) {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const html = [];
  let index = 0;
  let inList = false;
  let inOrderedList = false;
  let inCode = false;
  let codeLang = "";
  let codeLines = [];

  while (index < lines.length) {
    const line = lines[index];

    if (line.startsWith("```")) {
      if (inCode) {
        html.push(`<pre><code class="language-${escapeHtml(codeLang)}">${escapeHtml(codeLines.join("\n"))}</code></pre>`);
        inCode = false;
        codeLang = "";
        codeLines = [];
      } else {
        closeLists();
        inCode = true;
        codeLang = line.slice(3).trim();
      }
      index += 1;
      continue;
    }

    if (inCode) {
      codeLines.push(line);
      index += 1;
      continue;
    }

    if (!line.trim()) {
      closeLists();
      index += 1;
      continue;
    }

    if (isTableStart(lines, index)) {
      closeLists();
      const tableRows = [];
      tableRows.push(lines[index]);
      index += 2;
      while (index < lines.length && lines[index].trim().startsWith("|")) {
        tableRows.push(lines[index]);
        index += 1;
      }
      html.push(renderTable(tableRows));
      continue;
    }

    const image = line.match(/^!\[([^\]]*)\]\(([^)]+)\)$/);
    if (image) {
      closeLists();
      html.push(`<figure><img src="${escapeHtml(image[2])}" alt="${escapeHtml(image[1])}"><figcaption>${escapeHtml(image[1])}</figcaption></figure>`);
      index += 1;
      continue;
    }

    const heading = line.match(/^(#{1,6})\s+(.+)$/);
    if (heading) {
      closeLists();
      const level = heading[1].length;
      html.push(`<h${level}>${inlineMarkdown(heading[2])}</h${level}>`);
      index += 1;
      continue;
    }

    const unordered = line.match(/^\s*[-*]\s+(.+)$/);
    if (unordered) {
      if (inOrderedList) closeLists();
      if (!inList) {
        html.push("<ul>");
        inList = true;
      }
      html.push(`<li>${inlineMarkdown(unordered[1])}</li>`);
      index += 1;
      continue;
    }

    const ordered = line.match(/^\s*\d+\.\s+(.+)$/);
    if (ordered) {
      if (inList) closeLists();
      if (!inOrderedList) {
        html.push("<ol>");
        inOrderedList = true;
      }
      html.push(`<li>${inlineMarkdown(ordered[1])}</li>`);
      index += 1;
      continue;
    }

    closeLists();
    const paragraph = [line.trim()];
    index += 1;
    while (index < lines.length && lines[index].trim() && !isBlockStart(lines, index)) {
      paragraph.push(lines[index].trim());
      index += 1;
    }
    html.push(`<p>${inlineMarkdown(paragraph.join(" "))}</p>`);
  }

  closeLists();
  return html.join("\n");

  function closeLists() {
    if (inList) {
      html.push("</ul>");
      inList = false;
    }
    if (inOrderedList) {
      html.push("</ol>");
      inOrderedList = false;
    }
  }
}

function isBlockStart(lines, index) {
  const line = lines[index];
  return line.startsWith("```")
    || /^(#{1,6})\s+/.test(line)
    || /^\s*[-*]\s+/.test(line)
    || /^\s*\d+\.\s+/.test(line)
    || /^!\[[^\]]*\]\([^)]+\)$/.test(line)
    || isTableStart(lines, index);
}

function isTableStart(lines, index) {
  return index + 1 < lines.length
    && lines[index].trim().startsWith("|")
    && /^\s*\|?[\s:-]+\|[\s|:-]*$/.test(lines[index + 1]);
}

function renderTable(rows) {
  const cells = rows.map((row) => row.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((cell) => cell.trim()));
  const head = cells[0];
  const body = cells.slice(1);
  return `<div class="table-wrap"><table><thead><tr>${head.map((cell) => `<th>${inlineMarkdown(cell)}</th>`).join("")}</tr></thead><tbody>${body.map((row) => `<tr>${row.map((cell) => `<td>${inlineMarkdown(cell)}</td>`).join("")}</tr>`).join("")}</tbody></table></div>`;
}

function inlineMarkdown(text) {
  return escapeHtml(text)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
}

function escapeHtml(value) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}
