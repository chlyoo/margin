/**
 * Implements:
 *   - FR-MD-1: Selectable split panes
 *   - FR-MD-2: GFM rendering and sanitization
 *   - FR-MD-3: Editing and draft recovery
 *   - FR-MD-4: Correction request, accept/reject and stale response protection
 */
async () => {
  const results = [];
  const check = (name, condition) => {results.push({name, pass: Boolean(condition)});};
  const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
  const editor = document.querySelector('#source-left');
  check('editor available', editor);
  if (!editor) return results;
  const edit = text => {editor.value = text; editor.selectionStart = editor.selectionEnd = text.length; editor.dispatchEvent(new Event('input', {bubbles: true}));};
  edit('# 검증\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n- [x] 완료\n\n```js\nconst n = 1;\n```\n\n<script>window.__xss = true</script>\n<img src=x onerror="window.__xss=true">\n<input type=image src="/beacon.png">\n<table background="/beacon.png"><tr><td background="/beacon.png">x</td></tr></table>\n[bad](javascript:alert(1))');
  await delay(250);
  const preview = document.querySelector('#preview-right');
  check('headings', preview.querySelector('h1')?.textContent === '검증');
  check('tables', preview.querySelector('table').querySelectorAll('td').length === 2);
  check('tasks', preview.querySelector('input[type=checkbox]')?.checked);
  check('highlighted code', preview.querySelector('.token.keyword'));
  check('script sanitized', !preview.querySelector('script') && !window.__xss);
  check('unsafe URL sanitized', !preview.querySelector('a[href^="javascript:"]'));
  check('external images blocked', !preview.querySelector('img[src]'));
  check('non-img remote resource vectors blocked', !preview.querySelector('input[src], [background], [poster]'));
  document.querySelector('[data-mode="preview"]').click();
  check('preview mode', document.querySelector('#workspace').dataset.mode === 'preview');
  document.querySelector('[data-mode="source"]').click();
  check('source mode', document.querySelector('#workspace').dataset.mode === 'source');
  document.querySelector('[data-mode="split"]').click();
  document.querySelector('[data-pane="left"][data-kind="preview"]').click();
  check('left preview selection', !document.querySelector('#preview-left').hidden && editor.closest('.source-wrap').hidden);
  document.querySelector('[data-pane="left"][data-kind="source"]').click();
  const separator = document.querySelector('#separator');
  const beforeResize = Number(separator.getAttribute('aria-valuenow'));
  separator.dispatchEvent(new KeyboardEvent('keydown', {key: 'ArrowRight', bubbles: true}));
  check('keyboard resize', Number(separator.getAttribute('aria-valuenow')) === Math.min(75,beforeResize+5));
  edit('원래 문장입니다.');
  await delay(400);
  check('draft persisted', JSON.parse(localStorage.getItem('markdown-studio:draft')).text === '원래 문장입니다.');
  const realFetch = window.fetch;
  let requestBody;
  window.fetch = async (url, options) => {
    if (url === '/api/suggest') {requestBody = JSON.parse(options.body); return Response.json({replacement: '고친 문장입니다.', reason: '표현을 수정했어요.'});}
    return realFetch(url, options);
  };
  document.querySelector('#suggest').click();
  await delay(100);
  check('manual paragraph request', requestBody?.text === '원래 문장입니다.');
  check('suggestion shown', !document.querySelector('#suggestion').hidden);
  document.querySelector('#accept').click();
  check('accept applies', editor.value === '고친 문장입니다.');
  document.querySelector('#suggest').click();
  await delay(100);
  document.querySelector('#reject').click();
  check('reject preserves source', editor.value === '고친 문장입니다.');
  let resolveResponse;
  window.fetch = async (url, options) => url === '/api/suggest' ? new Promise(resolve => {resolveResponse = resolve;}) : realFetch(url, options);
  edit('대기 중인 문장입니다.');
  document.querySelector('#suggest').click();
  await delay(20);
  edit('새로 입력한 문장입니다.');
  resolveResponse(Response.json({replacement: '오래된 수정입니다.', reason: '오래된 제안'}));
  await delay(100);
  check('stale response discarded', document.querySelector('#suggestion').hidden && editor.value === '새로 입력한 문장입니다.');
  window.fetch = realFetch;
  check('no viewport overflow', document.documentElement.scrollWidth <= innerWidth);
  return results;
}
