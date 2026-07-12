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
