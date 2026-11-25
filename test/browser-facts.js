/**
 * Implements:
 *   - FR-MD-4: Tab accepts and Escape dismisses live suggestions
 *   - FR-MD-5: Evidence and unverified claims appear in the editor
 */
async () => {
  const checks = [];
  const check = (name, pass) => checks.push({name, pass: Boolean(pass)});
  const wait = ms => new Promise(resolve=>setTimeout(resolve,ms));
  const editor = document.querySelector('#source-left');
  editor.focus();
  const auto = document.querySelector('#auto-correct');
  auto.checked = true;
  auto.dispatchEvent(new Event('change',{bubbles:true}));
  const edit = text => {editor.value=text;editor.selectionStart=editor.selectionEnd=text.length;editor.dispatchEvent(new Event('input',{bubbles:true}));};
  edit('서울은 일본의 수도입니다.');
  await wait(1450);
  check('automatic factual suggestion', document.querySelector('#suggestion-title').textContent==='사실 확인' && !document.querySelector('#suggestion').hidden);
  check('native evidence shown', document.querySelector('#fact-checks a')?.href==='https://www.seoul.go.kr/');
  check('inline Tab preview', !document.querySelector('#source-ghost').hidden && document.querySelector('#ghost-text').textContent==='서울은 대한민국의 수도입니다.');
  editor.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));
  check('Tab applies factual correction',editor.value==='서울은 대한민국의 수도입니다.');
  check('accept hides suggestion',document.querySelector('#suggestion').hidden);
  edit('확인되지 않은 주장입니다.');
  await wait(1450);
  check('unverified visible',document.querySelector('#fact-checks .unverified')?.textContent==='미확인');
  check('unverified edit cannot apply',document.querySelector('#accept').disabled && document.querySelector('#source-ghost').hidden);
  editor.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));
  check('Tab never applies unsupported fact',editor.value==='확인되지 않은 주장입니다.');
  editor.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
  check('Escape dismisses',document.querySelector('#suggestion').hidden);
  edit('서울은 일본의 수도입니다.\n\n다른 문단입니다.');
  editor.setSelectionRange('서울은 일본의 수도입니다.'.length,'서울은 일본의 수도입니다.'.length);
  document.querySelector('#suggest').click();
  await wait(150);
  editor.setSelectionRange(editor.value.length,editor.value.length);
  editor.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));
  check('moving cursor never applies a remote paragraph suggestion',editor.value.startsWith('서울은 일본의 수도입니다.') && document.querySelector('#suggestion').hidden);
  auto.checked=false;
  auto.dispatchEvent(new Event('change',{bubbles:true}));
  return checks;
}
