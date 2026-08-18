const SHEET_NAME = '채점결과';
const HEADERS = [
  '수신시각',
  '학생 제출시각',
  '과제',
  '비번호',
  '이름',
  '학교/소속',
  '채점 결과',
  '페이지 URL',
];

function doPost(e) {
  try {
    const params = e && e.parameter ? e.parameter : {};
    if (String(params.website || '').trim()) {
      return jsonResponse({ ok: true });
    }

    const studentNo = clean(params.studentNo, 30);
    const studentName = clean(params.studentName, 50);
    const school = clean(params.school, 100);
    const scoreOutput = clean(params.scoreOutput, 45000);
    const taskName = clean(params.taskName || params.taskKey, 100);
    const submittedAt = clean(params.submittedAt, 50);
    const pageUrl = clean(params.pageUrl, 500);

    if (!studentNo || !studentName || !scoreOutput) {
      return jsonResponse({ ok: false, error: 'required fields are missing' });
    }
    if (containsSecret(scoreOutput)) {
      return jsonResponse({ ok: false, error: 'possible credential detected' });
    }

    const lock = LockService.getScriptLock();
    lock.waitLock(10000);
    try {
      const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
      let sheet = spreadsheet.getSheetByName(SHEET_NAME);
      if (!sheet) {
        sheet = spreadsheet.insertSheet(SHEET_NAME);
      }
      if (sheet.getLastRow() === 0) {
        sheet.appendRow(HEADERS);
        sheet.setFrozenRows(1);
      }
      sheet.appendRow([
        new Date(),
        safeCell(submittedAt),
        safeCell(taskName),
        safeCell(studentNo),
        safeCell(studentName),
        safeCell(school),
        safeCell(scoreOutput),
        safeCell(pageUrl),
      ]);
    } finally {
      lock.releaseLock();
    }
    return jsonResponse({ ok: true });
  } catch (error) {
    console.error(error);
    return jsonResponse({ ok: false, error: String(error) });
  }
}

function clean(value, maxLength) {
  return String(value == null ? '' : value).trim().slice(0, maxLength);
}

function safeCell(value) {
  return /^[=+\-@]/.test(value) ? "'" + value : value;
}

function containsSecret(value) {
  return /AKIA[0-9A-Z]{16}/.test(value)
    || /(aws_secret_access_key|aws_session_token)\s*[=:]/i.test(value)
    || /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(value);
}

function jsonResponse(payload) {
  return ContentService.createTextOutput(JSON.stringify(payload))
    .setMimeType(ContentService.MimeType.JSON);
}
