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
  task07first: {
    title: "07_1과제 Release Candidate 상세 풀이",
    description: "Unicorn Tickets 과제를 30점 채점기준과 실제 mark.sh 순서에 맞춰 구성한 실전 풀이입니다.",
    file: "07_1과제_Release_Candidate_상세풀이.md",
  },  task02first: {
    title: "02_1과제_1등 상세 풀이",
    description: "select/1과제/02_1과제_1등 문제를 채점 스크립트 기준으로 더 자세히 풀어쓴 절차형 문서입니다.",
    file: "02_1과제_1등_상세풀이.md",
  },
  task02tomorrow: {
    title: "내일 변경과제 30% 대응센터",
    description: "최종 과제 공개 직후 변경점을 찾고 4시간 안에 재구성하기 위한 비교표와 Module별 체크리스트입니다.",
    file: "02_2과제_내일변경_대응센터.md",
  },
  task02second: {
    title: "제2과제 실제 출제본 30점 만점 풀이",
    description: "실제 시험지 5개 모듈과 채점표 27개 세부항목·30점을 반영한 콘솔 및 CLI 만점 풀이입니다.",
    file: "task02-actual-exam.md",
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
    if (["task02first", "task02second", "task02m1", "task02m2", "task02m3", "task02m4"].includes(docKey)) {
      mountScoreSubmissionForm(docKey);
    }
  })
  .catch((error) => {
    document.getElementById("content").innerHTML = `<p class="error">${escapeHtml(error.message)}</p>`;
  });

function mountScoreSubmissionForm(activeTaskKey) {
  const baseConfig = window.SCORE_SUBMISSION_CONFIG || {};
  const taskNames = {
    task02first: "02_1과제_1등",
    task02second: "02_2과제_실제출제본",
    task02m1: "02_2과제_Module1_Workflow",
    task02m2: "02_2과제_Module2_Analytics",
    task02m3: "02_2과제_Module3_EventHandling",
    task02m4: "02_2과제_Module4_MSK",
  };
  const config = {
    ...baseConfig,
    taskKey: activeTaskKey,
    taskName: taskNames[activeTaskKey],
  };
  const endpoint = String(config.endpoint || "").trim();
  const configured = /^https:\/\/script\.google\.com\/macros\/s\/[\w-]+\/exec$/.test(endpoint);
  const section = document.createElement("section");
  section.className = "score-submit";
  section.id = "score-submit";
  section.innerHTML = `
    <div class="score-submit__heading">
      <p class="eyebrow">Submit result</p>
      <h2>채점 결과 제출</h2>
      <p>채점 스크립트를 실행한 뒤 전체 출력을 붙여넣으면 Google Sheets로 전송됩니다.</p>
    </div>
    <div class="score-submit__download" role="group" aria-label="채점 스크립트 다운로드">
      <strong>채점 스크립트 준비</strong>
      <p><a class="score-submit__secondary" href="downloads/mark.sh" download="mark.sh">mark.sh 다운로드</a></p>
      <p>CloudShell에서 바로 받으려면 아래 명령을 실행하세요.</p>
      <pre><code>curl -fL "https://rani0380.github.io/2026_nationalskills/downloads/mark.sh" -o ~/mark.sh &amp;&amp; chmod +x ~/mark.sh
bash ~/mark.sh</code></pre>
    </div>
    <div class="score-submit__notice" role="note">
      <strong>보안 확인</strong>
      <p>AWS Access Key, Secret Access Key, Session Token, 비밀번호는 제출하지 마세요. 채점 스크립트 출력만 붙여넣으세요.</p>
    </div>
    ${configured ? "" : `<p class="score-submit__setup">Google Sheets 수신 주소가 아직 설정되지 않았습니다. 관리자가 <code>assets/submission-config.js</code>에 Apps Script <code>/exec</code> 주소를 등록하면 전송 버튼이 활성화됩니다.</p>`}
    <form class="score-submit__form" method="post" target="score-submit-frame" novalidate>
      <input type="hidden" name="taskKey" value="${escapeHtml(String(config.taskKey || "task02first"))}">
      <input type="hidden" name="taskName" value="${escapeHtml(String(config.taskName || "02_1과제_1등"))}">
      <input type="hidden" name="submittedAt" value="">
      <input type="hidden" name="pageUrl" value="">
      <div class="score-submit__grid">
        <label>비번호 <input name="studentNo" autocomplete="off" maxlength="30" required></label>
        <label>이름 <input name="studentName" autocomplete="name" maxlength="50" required></label>
        <label class="score-submit__wide">학교/소속 <input name="school" autocomplete="organization" maxlength="100"></label>
      </div>
      <label class="score-submit__wide">채점 결과
        <textarea name="scoreOutput" rows="18" maxlength="45000" placeholder="채점 스크립트 실행 후 출력 전체를 붙여넣으세요." required></textarea>
      </label>
      <label class="score-submit__trap" aria-hidden="true">Website <input name="website" tabindex="-1" autocomplete="off"></label>
      <label class="score-submit__confirm">
        <input type="checkbox" name="safeConfirmed" value="yes" required>
        비밀키·세션 토큰·비밀번호가 포함되지 않았음을 확인했습니다.
      </label>
      <div class="score-submit__actions">
        <button class="score-submit__button" type="submit" ${configured ? "" : "disabled"}>Google Sheets로 제출</button>
        <button class="score-submit__secondary" type="button" data-download-result>결과 파일 저장</button>
      </div>
      <p class="score-submit__status" role="status" aria-live="polite"></p>
    </form>
    <iframe class="score-submit__frame" name="score-submit-frame" title="채점 결과 제출 응답"></iframe>
  `;

  document.getElementById("content").appendChild(section);
  if (activeTaskKey !== "task02first") {
    section.querySelector(".score-submit__download")?.remove();
  }
  const moduleDownloads = {
    task02second: ["day2_release_files_actual.zip"],
    task02m1: ["module1.zip"],
    task02m2: ["module2.zip"],
    task02m3: ["module3.zip"],
    task02m4: ["module4.zip"],
  };
  const moduleFiles = moduleDownloads[activeTaskKey] || [];
  if (moduleFiles.length) {
    const downloadPanel = document.createElement("div");
    downloadPanel.className = "score-submit__download";
    downloadPanel.setAttribute("role", "group");
    downloadPanel.setAttribute("aria-label", "2과제 모듈 지급파일 다운로드");
    const title = document.createElement("strong");
    title.textContent = "2과제 모듈 지급파일";
    const actions = document.createElement("div");
    actions.className = "score-submit__actions";
    for (const filename of moduleFiles) {
      const link = document.createElement("a");
      link.className = "score-submit__secondary";
      link.href = "downloads/task02-modules/" + filename;
      link.download = filename;
      link.textContent = filename + " 다운로드";
      actions.appendChild(link);
    }
    downloadPanel.append(title, actions);
    section.querySelector(".score-submit__notice").before(downloadPanel);
  }
  const form = section.querySelector("form");
  const status = section.querySelector(".score-submit__status");
  const frame = section.querySelector("iframe");
  let submitted = false;

  if (configured) {
    form.action = endpoint;
  }

  form.addEventListener("submit", (event) => {
    status.className = "score-submit__status";
    if (!configured) {
      event.preventDefault();
      status.textContent = "Google Sheets 수신 주소가 설정되지 않았습니다.";
      status.classList.add("is-error");
      return;
    }
    if (!form.reportValidity()) {
      event.preventDefault();
      return;
    }
    const output = form.elements.scoreOutput.value;
    if (containsPossibleSecret(output)) {
      event.preventDefault();
      status.textContent = "Access Key 또는 Secret/Session Token으로 보이는 내용이 있습니다. 민감정보를 제거한 뒤 제출하세요.";
      status.classList.add("is-error");
      return;
    }
    form.elements.submittedAt.value = new Date().toISOString();
    form.elements.pageUrl.value = window.location.href;
    submitted = true;
    status.textContent = "Google Sheets로 전송 중입니다…";
    form.querySelector("button[type=submit]").disabled = true;
  });

  frame.addEventListener("load", () => {
    if (!submitted) return;
    submitted = false;
    status.textContent = "제출 요청을 전송했습니다. 시트에서 새 행을 확인하세요.";
    status.classList.add("is-success");
    form.querySelector("button[type=submit]").disabled = false;
  });

  section.querySelector("[data-download-result]").addEventListener("click", () => {
    const studentNo = form.elements.studentNo.value.trim() || "unknown";
    const studentName = form.elements.studentName.value.trim() || "unknown";
    const output = form.elements.scoreOutput.value;
    if (!output.trim()) {
      status.textContent = "저장할 채점 결과를 먼저 붙여넣으세요.";
      status.className = "score-submit__status is-error";
      return;
    }
    const header = [
      `과제: ${config.taskName || "02_1과제_1등"}`,
      `비번호: ${studentNo}`,
      `이름: ${studentName}`,
      `저장시각: ${new Date().toLocaleString("ko-KR")}`,
      "",
    ].join("\n");
    const blob = new Blob([header, output], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `mark-result-${safeFilename(studentNo)}-${safeFilename(studentName)}.txt`;
    link.click();
    URL.revokeObjectURL(url);
  });
}

function containsPossibleSecret(value) {
  return /AKIA[0-9A-Z]{16}/.test(value)
    || /(aws_secret_access_key|aws_session_token)\s*[=:]/i.test(value)
    || /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(value);
}

function safeFilename(value) {
  return value.replace(/[^0-9A-Za-z가-힣_-]+/g, "-").replace(/^-+|-+$/g, "") || "unknown";
}

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
