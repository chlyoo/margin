/**
 * Implements:
 *   - FR-MD-4: Opt-in debounced and IME-safe automatic corrections
 */
async () => {
  const checks = [];
  const check = (name, pass) => checks.push({name, pass: Boolean(pass)});
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const editor = document.querySelector('#source-left');
  const auto = document.querySelector('#auto-correct');
  check('live review enabled when configured', auto.checked);
  auto.checked = false;
  auto.dispatchEvent(new Event('change', {bubbles:true}));
  const realFetch = window.fetch;
  let calls = 0;
  window.fetch = async (url, init) => {if (url === '/api/suggest') calls++; return realFetch(url, init);};
  const edit = value => {editor.value = value; editor.selectionStart = editor.selectionEnd = value.length; editor.dispatchEvent(new Event('input', {bubbles:true}));};
  edit('자동 교정할 문장입니다.');
  await wait(1300);
  check('automatic review can be disabled', calls === 0 && !auto.checked);
  auto.checked = true;
  auto.dispatchEvent(new Event('change', {bubbles:true}));
  await wait(600);
  edit('마지막으로 입력한 문장입니다.');
  await wait(800);
  check('debounce restarts on edits', calls === 0);
  await wait(550);
  check('one automatic paragraph correction', calls === 1 && !document.querySelector('#suggestion').hidden && document.querySelector('#replacement').textContent === '마지막으로 입력한 표현입니다.');
  document.querySelector('#reject').click();
  editor.dispatchEvent(new CompositionEvent('compositionstart', {bubbles:true}));
  edit('한글 조합 중인 문장입니다.');
  await wait(1300);
  check('IME composition sends no requests', calls === 1);
  editor.dispatchEvent(new CompositionEvent('compositionend', {bubbles:true}));
  await wait(1350);
  check('IME completion schedules correction', calls === 2 && !document.querySelector('#suggestion').hidden);
  const provider = document.querySelector('#provider');
  provider.value = 'claude';
  provider.dispatchEvent(new Event('change', {bubbles:true}));
  check('provider switch invalidates suggestion', document.querySelector('#suggestion').hidden && !auto.checked);
  document.querySelector('#suggest').click();
  await wait(150);
  check('Claude adapter round trip through server', !document.querySelector('#suggestion').hidden);
  document.querySelector('#reject').click();
  document.querySelector('[data-pane="right"][data-kind="source"]').click();
  const right = document.querySelector('#source-right');
  right.value = '오른쪽에서 수정한 문장입니다.';
  right.dispatchEvent(new Event('input', {bubbles:true}));
  check('both source panes share one document', editor.value === right.value);
  auto.checked = false;
  auto.dispatchEvent(new Event('change', {bubbles:true}));
  window.fetch = realFetch;
  return checks;
}
