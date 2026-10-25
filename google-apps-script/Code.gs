const SHEET_NAME = '채점결과';
// 2027 지방 모의고사 제출은 아래 스프레드시트의 별도 탭에 기록합니다.
const MOCK_SPREADSHEET_ID = '1kZURRJDtN9FKv1jQdMTBE6U70AtjC0dyctEa_fp7vZM';
const MOCK_SHEET_NAME = '2027지방모의고사';
const MOCK_HEADERS = [
  '수신시각',
  '학생 제출시각',
  '과제',
  '비번호',
  '이름',
  '학교/소속',
  '점수',
  '만점',
  'AWS 계정',
  '채점 결과',
  '페이지 URL',
];
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

    const taskKey = clean(params.taskKey, 50);
    if (/^mock\d+t\d+$/.test(taskKey)) {
      appendMockRow([
        new Date(),
        safeCell(submittedAt),
        safeCell(taskName),
        safeCell(studentNo),
        safeCell(studentName),
        safeCell(school),
      ], scoreOutput, pageUrl);
      return jsonResponse({ ok: true });
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

function appendMockRow(head, scoreOutput, pageUrl) {
  const score = scoreOutput.match(/TOTAL SCORE:\s*([\d.]+)\s*\/\s*([\d.]+)/);
  const account = scoreOutput.match(/계정:\s*(\d{12})/);
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    const spreadsheet = SpreadsheetApp.openById(MOCK_SPREADSHEET_ID);
    let sheet = spreadsheet.getSheetByName(MOCK_SHEET_NAME);
    if (!sheet) {
      sheet = spreadsheet.insertSheet(MOCK_SHEET_NAME);
    }
    if (sheet.getLastRow() === 0) {
      sheet.appendRow(MOCK_HEADERS);
      sheet.setFrozenRows(1);
    }
    sheet.appendRow(head.concat([
      score ? Number(score[1]) : '',
      score ? Number(score[2]) : '',
      account ? "'" + account[1] : '',
      safeCell(scoreOutput),
      safeCell(pageUrl),
    ]));
  } finally {
    lock.releaseLock();
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
