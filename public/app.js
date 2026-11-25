import {paragraphAt, applySuggestion, safeFilename, decodeDocument, encodeDocument, selectionMatches} from './core.js';
import {renderMarkdown} from './render.js';

const $ = selector => document.querySelector(selector);
const $$ = selector => [...document.querySelectorAll(selector)];
const DRAFT_KEY = 'markdown-studio:draft';
const SETTINGS_KEY = 'markdown-studio:settings';
const example = `# 생각을 쓰고, 흐름을 다듬어요

좋은 문서는 작은 문장에서 시작해요. 이곳에 Markdown을 작성하고, 오른쪽에서 완성된 모습을 확인해 보세요.

> 쓸 때는 생각에 집중하고, 읽을 때는 문장에 집중해요.

## 오늘의 노트

- **소스**에서 문서를 자유롭게 편집해요.
- **미리보기**에서 읽는 흐름을 확인해요.
- **분할**에서 두 화면을 함께 사용해요.

### 작은 시작

- [x] 새로운 문서 열기
- [x] 생각의 뼈대 잡기
- [ ] 첫 번째 문장 다듬기

## 문서 안의 구조

| 요소 | 쓰임 |
| :--- | :--- |
| 제목 | 생각의 계층을 만들어요 |
| 인용 | 기억할 문장을 남겨요 |
| 코드 | 정확한 내용을 공유해요 |

\`\`\`javascript
const draft = {
  title: "A little room to think",
  ready: true,
};
\`\`\`

---

한 문장씩, 더 나은 글로 이어가세요.
`;

function stored(key, fallback) {
  try {return JSON.parse(localStorage.getItem(key)) || fallback;} catch {return fallback;}
}
let preferences = stored(SETTINGS_KEY, {});
let draft = stored(DRAFT_KEY, {});
let text = typeof draft.text === 'string' ? draft.text : example;
let documentFormat = draft.format || {eol:'\n',bom:false};
let sourceInsertion = false;
let revision = 0;
let activeEditor = $('#source-left');
let currentSuggestion = null;
let request = null;
let requestId = 0;
let autoTimer;
let draftTimer;
let renderFrame;
let toastTimer;
let composing = false;
let fileHandle = null;
let diskText = null;
let config = {gateway: {configured: false, model: 'anthropic/claude-sonnet-5.5'}, claude: {configured: false, model: 'claude-sonnet-5-5'}};
const paneKinds = {left: 'source', right: 'preview'};

$('#filename').value = safeFilename(draft.name || 'Untitled.md');
$('#provider').value = ['gateway', 'claude'].includes(preferences.provider) ? preferences.provider : 'gateway';
$('#remote-images').checked = preferences.remoteImages === true;
$('#fact-check').checked = preferences.factCheck !== false;
document.body.classList.toggle('dark', preferences.theme === 'dark');

function toast(message) {
  $('#toast').textContent = message;
  $('#toast').hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {$('#toast').hidden = true;}, 5000);
}

function persistPreferences() {
  preferences = {...preferences, provider: $('#provider').value, models: {...preferences.models, [$('#provider').value]: $('#model').value}, remoteImages: $('#remote-images').checked, factCheck: $('#fact-check').checked, autoReview: $('#auto-correct').checked, theme: document.body.classList.contains('dark') ? 'dark' : 'light'};
  try {localStorage.setItem(SETTINGS_KEY, JSON.stringify(preferences));} catch {toast('설정 저장 공간을 사용할 수 없어요.');}
}

function persistDraft() {
  clearTimeout(draftTimer);
  try {
    localStorage.setItem(DRAFT_KEY, JSON.stringify({text, name: safeFilename($('#filename').value), format:documentFormat}));
    $('#save-state').textContent = diskText === text ? '파일 저장됨' : '초안 저장됨';
  } catch {$('#save-state').textContent = '초안 저장 실패'; toast('브라우저 초안을 저장하지 못했어요. 파일로 저장해 주세요.');}
}

function stats() {
  if (currentSuggestion && !selectionMatches(currentSuggestion,activeEditor.selectionStart,activeEditor.selectionEnd)) invalidateSuggestion();
  $('#char-count').textContent = `${text.length.toLocaleString()}자`;
  $('#word-count').textContent = `${text.trim() ? text.trim().split(/\s+/).length.toLocaleString() : 0}단어`;
  const before = activeEditor.value.slice(0, activeEditor.selectionStart);
  $('#cursor-position').textContent = `줄 ${before.split('\n').length}, 열 ${before.length - before.lastIndexOf('\n')}`;
  positionGhost();
}

function positionGhost() {
  const ghost = $('#source-ghost');
  if (!currentSuggestion?.canApply || !activeEditor.offsetParent) {ghost.hidden = true; return;}
  const wrap = activeEditor.parentElement;
  wrap.append(ghost);
  const line = text.slice(0, activeEditor.selectionStart).split('\n').length;
  const padding = parseFloat(getComputedStyle(activeEditor).paddingTop);
  const top = padding + line * 26 - activeEditor.scrollTop;
  ghost.style.top = `${Math.max(8, Math.min(top, wrap.clientHeight - 42))}px`;
  ghost.hidden = false;
}

function showFactChecks(items = [], searchStatus) {
  const container = $('#fact-checks');
  container.replaceChildren();
  container.hidden = !items.length && searchStatus !== 'failed';
  if (searchStatus === 'failed') {
    const note = document.createElement('p');
    note.textContent = '검색을 완료하지 못했어요. 사실 확인 결과는 미확인으로 표시해요.';
    container.append(note);
  }
  const labels = {supported:'근거 확인',contradicted:'사실 수정',unverified:'미확인'};
  for (const item of items) {
    const row = document.createElement('div');
    row.className = 'fact-row';
    const badge = document.createElement('span');
    badge.className = `fact-verdict ${['supported','contradicted'].includes(item.verdict) ? item.verdict : 'unverified'}`;
    badge.textContent = labels[item.verdict] || labels.unverified;
    const claim = document.createElement('strong');
    claim.textContent = item.claim;
    const explanation = document.createElement('p');
    explanation.textContent = item.explanation;
    row.append(badge, claim, explanation);
    for (const source of item.sources || []) {
      try {
        const url = new URL(source.url);
        if (!['https:','http:'].includes(url.protocol)) continue;
        const anchor = document.createElement('a');
        anchor.href = url.href; anchor.target = '_blank'; anchor.rel = 'noopener noreferrer';
        anchor.textContent = source.title || url.hostname;
        row.append(anchor);
      } catch {}
    }
    container.append(row);
  }
}

function invalidateSuggestion() {
  clearTimeout(autoTimer);
  requestId++;
  request?.abort();
  request = null;
  currentSuggestion = null;
  $('#suggestion').hidden = true;
  $('#source-ghost').hidden = true;
  $('#suggest').disabled = false;
  $('#suggest').innerHTML = '<span class="spark">✦</span> 문단 검토';
}

function render() {
  cancelAnimationFrame(renderFrame);
  renderFrame = requestAnimationFrame(() => {
    const fragment = renderMarkdown(text, $('#remote-images').checked);
    for (const side of ['left', 'right']) {
      const scroller = $(`#scroll-${side}`);
      const scroll = scroller.scrollTop;
      $(`#preview-${side}`).replaceChildren(fragment.cloneNode(true));
      scroller.scrollTop = scroll;
    }
  });
}

function syncSources(origin) {
  const lineCount = text.split('\n').length;
  const lines = Array.from({length: Math.min(lineCount, 30000)}, (_, index) => index + 1).join('\n');
  for (const side of ['left', 'right']) {
    const editor = $(`#source-${side}`);
    if (editor !== origin && editor.value !== text) {
      const start = editor.selectionStart;
      const top = editor.scrollTop;
      editor.value = text;
      editor.selectionStart = editor.selectionEnd = Math.min(start, text.length);
      editor.scrollTop = top;
    }
    $(`#lines-${side}`).textContent = lines;
    $(`#lines-${side}`).scrollTop = editor.scrollTop;
  }
}

function updateText(next, origin, auto = true) {
  if (next === text) return;
  text = next;
  revision++;
  invalidateSuggestion();
  syncSources(origin);
  render();
  stats();
  $('#save-state').textContent = '편집 중';
  clearTimeout(draftTimer);
  draftTimer = setTimeout(persistDraft, 250);
  if (auto && $('#auto-correct').checked && !composing) scheduleCorrection();
}

function scheduleCorrection() {
  clearTimeout(autoTimer);
  if (!$('#auto-correct').checked || composing) return;
  autoTimer = setTimeout(() => askCorrection(true), 1200);
}

function setPane(side, kind) {
  paneKinds[side] = kind;
  $(`#wrap-${side}`).hidden = kind !== 'source';
  $(`#scroll-${side}`).hidden = kind !== 'preview';
  $$(`[data-pane="${side}"]`).forEach(button => button.setAttribute('aria-pressed', String(button.dataset.kind === kind)));
  $(`#caption-${side}`).textContent = kind === 'source' ? 'MARKDOWN' : 'LIVE PREVIEW';
  positionGhost();
}

function setMode(mode) {
  $('#workspace').dataset.mode = mode;
  if (mode === 'source') setPane('left', 'source');
  if (mode === 'preview') setPane('right', 'preview');
  $$('[data-mode]').filter(button => button.tagName === 'BUTTON').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.mode === mode)));
  $('#separator').setAttribute('aria-orientation', innerWidth <= 620 ? 'horizontal' : 'vertical');
}

async function askCorrection(automatic = false) {
  if (composing) return;
  const range = paragraphAt(text, activeEditor.selectionStart);
  if (!range) {if (!automatic) toast('소스에서 교정할 문단에 커서를 놓아 주세요. 코드 블록은 제외돼요.'); return;}
  invalidateSuggestion();
  const id = requestId;
  const requestedRevision = revision;
  const controller = new AbortController();
  request = controller;
  $('#suggest').disabled = true;
  $('#suggest').textContent = '✦ 교정 중…';
  try {
    const response = await fetch('/api/suggest', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({provider: $('#provider').value, model: $('#model').value, text: range.text, factCheck: $('#fact-check').checked}), signal: controller.signal,
    });
    const result = await response.json();
    if (id !== requestId || revision !== requestedRevision || controller.signal.aborted || !selectionMatches(range,activeEditor.selectionStart,activeEditor.selectionEnd)) return;
    if (!response.ok) throw Object.assign(new Error(result.error || '교정을 요청하지 못했어요.'),{status:response.status});
    if (typeof result.replacement !== 'string' || typeof result.reason !== 'string') throw new Error('AI 응답 형식이 올바르지 않아요.');
    if (result.replacement === range.text && !result.factChecks?.length && result.searchStatus !== 'failed') {if (!automatic) toast('이 문단은 수정할 부분이 없어요.'); return;}
    currentSuggestion = {...range, ...result, revision: requestedRevision, canApply: result.replacement !== range.text};
    $('#original').textContent = range.text;
    $('#replacement').textContent = result.replacement;
    $('#suggestion-reason').textContent = result.reason;
    $('#suggestion-reason').title = result.reason;
    $('#suggestion-title').textContent = ({grammar:'문법 교정',wording:'문장 다듬기',fact:'사실 확인',none:'검토 결과'})[result.category] || '문장 검토';
    $('#accept').disabled = !currentSuggestion.canApply;
    $('#ghost-text').textContent = result.replacement;
    showFactChecks(result.factChecks, result.searchStatus);
    $('#suggestion').hidden = false;
    positionGhost();
  } catch (error) {
    if (!controller.signal.aborted && id === requestId) {
      toast(error.message);
      if (automatic && error.status === 429) scheduleCorrection();
      else if (automatic && error.status === 503) $('#auto-correct').checked = false;
    }
  } finally {
    if (id === requestId) {
      request = null;
      $('#suggest').disabled = false;
      $('#suggest').innerHTML = '<span class="spark">✦</span> 문단 검토';
    }
  }
}

function acceptSuggestion() {
  if (!currentSuggestion?.canApply) return;
  if (!selectionMatches(currentSuggestion,activeEditor.selectionStart,activeEditor.selectionEnd)) {invalidateSuggestion(); return;}
  const next = applySuggestion(text, revision, currentSuggestion);
  if (next === null) {invalidateSuggestion(); toast('원문이 바뀌어서 제안을 취소했어요.'); return;}
  const start = currentSuggestion.start;
  const end = start + currentSuggestion.replacement.length;
  const editor = activeEditor;
  // Native insertion keeps the accepted correction in the browser's undo history.
  editor.focus();
  editor.setSelectionRange(start, currentSuggestion.end);
  sourceInsertion = true;
  if (!document.execCommand('insertText', false, currentSuggestion.replacement)) updateText(next, null, false);
  sourceInsertion = false;
  if (text !== next) updateText(next, null, false);
  invalidateSuggestion();
  editor.setSelectionRange(start, end);
}

function connectionUI(resetModel = false) {
  const provider = $('#provider').value;
  const entry = config[provider];
  if (resetModel) $('#model').value = preferences.models?.[provider] || entry.model;
  $('#connection-state').textContent = entry.configured ? '● 서버 API 키가 설정돼 있어요.' : '○ 서버 API 키가 아직 없어요.';
  $('#provider-status').classList.toggle('connected', entry.configured);
  $('#provider-label').textContent = provider === 'gateway' ? 'AI Gateway' : 'Claude';
  $('#env-help').textContent = provider === 'gateway' ? 'AI_GATEWAY_API_KEY=your-key\nAI_GATEWAY_MODEL=anthropic/claude-sonnet-5.5' : 'ANTHROPIC_API_KEY=your-key\nANTHROPIC_MODEL=claude-sonnet-5-5';
}

async function openFile(file, handle = null) {
  if (!file || !/\.(md|markdown|txt)$/i.test(file.name)) {toast('Markdown 또는 텍스트 파일을 선택해 주세요.'); return;}
  if (file.size > 2 * 1024 * 1024) {toast('2MB 이하의 파일을 열어 주세요.'); return;}
  try {
    const decoded = decodeDocument(new Uint8Array(await file.arrayBuffer()));
    const contents = decoded.text;
    if (text !== example && text !== diskText && !confirm('저장하지 않은 변경사항이 있어요. 다른 파일을 여시겠어요?')) return;
    // Persist the previous draft before making a document switch.
    persistDraft();
    invalidateSuggestion();
    updateText(contents, null, false);
    documentFormat = decoded.format;
    fileHandle = handle;
    diskText = contents;
    $('#filename').value = safeFilename(file.name);
    activeEditor.selectionStart = activeEditor.selectionEnd = 0;
    persistDraft();
    stats();
    toast(`${file.name} 파일을 열었어요.`);
  } catch {toast('파일을 읽지 못했어요.');}
}

async function chooseFile() {
  try {
    if (window.showOpenFilePicker) {
      const [handle] = await showOpenFilePicker({types: [{description: 'Markdown', accept: {'text/markdown': ['.md', '.markdown', '.txt']}}]});
      await openFile(await handle.getFile(), handle);
    } else $('#file-input').click();
  } catch (error) {if (error.name !== 'AbortError') toast('파일을 열지 못했어요.');}
}

async function saveFile() {
  const source = text;
  const contents = encodeDocument(source,documentFormat);
  const name = safeFilename($('#filename').value);
  $('#filename').value = name;
  try {
    let handle = fileHandle;
    if (!handle && window.showSaveFilePicker) handle = await showSaveFilePicker({suggestedName: name, types: [{description: 'Markdown', accept: {'text/markdown': ['.md']}}]});
    if (handle) {
      const writer = await handle.createWritable();
      await writer.write(contents);
      await writer.close();
      fileHandle = handle;
      $('#filename').value = safeFilename(handle.name);
    } else {
      const url = URL.createObjectURL(new Blob([contents], {type: 'text/markdown;charset=utf-8'}));
      const anchor = document.createElement('a');
      anchor.href = url; anchor.download = name; anchor.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    }
    diskText = source;
    persistDraft();
    toast('Markdown 파일을 저장했어요.');
  } catch (error) {if (error.name !== 'AbortError') toast('파일 저장에 실패했어요. 다시 시도해 주세요.');}
}

for (const side of ['left', 'right']) {
  const editor = $(`#source-${side}`);
  editor.value = text;
  editor.setSelectionRange(0, 0);
  editor.addEventListener('focus', () => {activeEditor = editor; stats();});
  editor.addEventListener('input', () => {activeEditor = editor; updateText(editor.value, editor, !sourceInsertion);});
  editor.addEventListener('compositionstart', () => {composing = true; invalidateSuggestion();});
  editor.addEventListener('compositionend', () => {composing = false; scheduleCorrection();});
  editor.addEventListener('keyup', stats);
  editor.addEventListener('click', stats);
  editor.addEventListener('select', stats);
  editor.addEventListener('scroll', () => {$(`#lines-${side}`).scrollTop = editor.scrollTop; positionGhost();});
  editor.addEventListener('keydown', event => {
    if (event.key === 'Tab' && !event.isComposing) {
      if (currentSuggestion && !selectionMatches(currentSuggestion,editor.selectionStart,editor.selectionEnd)) invalidateSuggestion();
      if (currentSuggestion && !currentSuggestion.canApply) return;
      event.preventDefault();
      if (currentSuggestion?.canApply) acceptSuggestion();
      else document.execCommand('insertText', false, '  ');
    }
    if (event.key === 'Escape') invalidateSuggestion();
  });
}

let scrollLock = false;
for (const side of ['left', 'right']) {
  for (const element of [$(`#source-${side}`), $(`#scroll-${side}`)]) {
    element.addEventListener('scroll', () => {
      if (scrollLock || !$('#sync-scroll').checked || $('#workspace').dataset.mode !== 'split') return;
      const other = side === 'left' ? 'right' : 'left';
      const target = paneKinds[other] === 'source' ? $(`#source-${other}`) : $(`#scroll-${other}`);
      const max = element.scrollHeight - element.clientHeight;
      if (max <= 0) return;
      scrollLock = true;
      target.scrollTop = element.scrollTop / max * (target.scrollHeight - target.clientHeight);
      requestAnimationFrame(() => {scrollLock = false;});
    });
  }
}

$$('button[data-mode]').forEach(button => button.addEventListener('click', () => setMode(button.dataset.mode)));
$$('button[data-pane]').forEach(button => button.addEventListener('click', () => setPane(button.dataset.pane, button.dataset.kind)));
$('#suggest').addEventListener('click', () => askCorrection());
$('#accept').addEventListener('click', acceptSuggestion);
$('#reject').addEventListener('click', invalidateSuggestion);
$('#auto-correct').addEventListener('change', () => {
  invalidateSuggestion();
  if ($('#auto-correct').checked && !config[$('#provider').value].configured) {
    $('#auto-correct').checked = false;
    $('#settings').showModal();
  } else scheduleCorrection();
  persistPreferences();
});
$('#settings-open').addEventListener('click', () => $('#settings').showModal());
$('#provider-status').addEventListener('click', () => $('#settings').showModal());
$('#provider').addEventListener('change', () => {invalidateSuggestion(); $('#auto-correct').checked = false; connectionUI(true); persistPreferences();});
$('#model').addEventListener('input', () => {invalidateSuggestion(); persistPreferences();});
$('#remote-images').addEventListener('change', () => {persistPreferences(); render();});
$('#fact-check').addEventListener('change', () => {invalidateSuggestion(); persistPreferences(); scheduleCorrection();});
$('#settings').addEventListener('close', persistPreferences);
$('#theme').addEventListener('click', () => {document.body.classList.toggle('dark'); persistPreferences();});
$('#open').addEventListener('click', chooseFile);
$('#file-input').addEventListener('change', event => {openFile(event.target.files[0]); event.target.value = '';});
$('#save').addEventListener('click', saveFile);
$('#filename').addEventListener('change', () => {$('#filename').value = safeFilename($('#filename').value); fileHandle = null; persistDraft();});
document.addEventListener('keydown', event => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') {event.preventDefault(); saveFile();}
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'o') {event.preventDefault(); chooseFile();}
  if (event.key === 'Escape' && currentSuggestion) invalidateSuggestion();
});
window.addEventListener('pagehide', persistDraft);
document.addEventListener('visibilitychange', () => {if (document.hidden) persistDraft();});

let dragDepth = 0;
document.addEventListener('dragenter', event => {if (event.dataTransfer.types.includes('Files')) {event.preventDefault(); dragDepth++; $('#drop-overlay').hidden = false;}});
document.addEventListener('dragleave', () => {if (--dragDepth <= 0) {dragDepth = 0; $('#drop-overlay').hidden = true;}});
document.addEventListener('dragover', event => {if (event.dataTransfer.types.includes('Files')) event.preventDefault();});
document.addEventListener('drop', event => {event.preventDefault(); dragDepth = 0; $('#drop-overlay').hidden = true; if (event.dataTransfer.files[0]) openFile(event.dataTransfer.files[0]);});

const separator = $('#separator');
function resizeSplit(value) {
  const split = Math.max(25, Math.min(75, value));
  $('#workspace').style.setProperty('--split', `${split}%`);
  separator.setAttribute('aria-valuenow', Math.round(split));
}
separator.addEventListener('pointerdown', event => {separator.setPointerCapture(event.pointerId);});
separator.addEventListener('pointermove', event => {
  if (!separator.hasPointerCapture(event.pointerId)) return;
  const bounds = $('#workspace').getBoundingClientRect();
  resizeSplit(innerWidth <= 620 ? (event.clientY - bounds.top) / bounds.height * 100 : (event.clientX - bounds.left) / bounds.width * 100);
});
separator.addEventListener('pointerup', event => separator.releasePointerCapture(event.pointerId));
separator.addEventListener('keydown', event => {
  const direction = {ArrowLeft: -5, ArrowRight: 5, ArrowUp: -5, ArrowDown: 5}[event.key];
  if (direction) {event.preventDefault(); resizeSplit(Number(separator.getAttribute('aria-valuenow')) + direction);}
});
window.addEventListener('resize', () => separator.setAttribute('aria-orientation', innerWidth <= 620 ? 'horizontal' : 'vertical'));

$$('[data-format]').forEach(button => button.addEventListener('click', () => {
  if ($('#workspace').dataset.mode === 'preview') setMode('split');
  const side = activeEditor.id.endsWith('left') ? 'left' : 'right';
  setPane(side, 'source');
  const start = activeEditor.selectionStart;
  const end = activeEditor.selectionEnd;
  const selected = text.slice(start, end);
  const wrappers = {heading: ['# ', ''], bold: ['**', '**'], italic: ['*', '*'], link: ['[', '](https://example.com)'], code: ['`', '`'], list: ['- ', ''], quote: ['> ', '']};
  const [before, after] = wrappers[button.dataset.format];
  const insert = before + (selected || '텍스트') + after;
  activeEditor.focus();
  activeEditor.setSelectionRange(start, end);
  document.execCommand('insertText', false, insert);
  activeEditor.setSelectionRange(start + before.length, start + before.length + (selected || '텍스트').length);
}));

syncSources();
setMode('split');
connectionUI(true);
render();
stats();
fetch('/api/config').then(response => response.json()).then(value => {
  if (value.gateway && value.claude) {
    config = value;
    if (!preferences.provider && !config.gateway.configured && config.claude.configured) $('#provider').value = 'claude';
    connectionUI(true);
    $('#auto-correct').checked = config[$('#provider').value].configured && preferences.autoReview !== false;
  }
}).catch(() => toast('AI 연결 설정을 읽지 못했어요.'));
