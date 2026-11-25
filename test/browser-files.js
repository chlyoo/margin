/**
 * Implements:
 *   - FR-MD-3: Browser file import/export and document protection
 */
async () => {
  const checks = [];
  const check = (name, pass) => checks.push({name, pass: Boolean(pass)});
  const wait = () => new Promise(resolve => setTimeout(resolve, 150));
  const editor = document.querySelector('#source-left');
  const input = document.querySelector('#file-input');
  const realConfirm = window.confirm;
  const originalPicker = window.showSaveFilePicker;
  let shouldConfirm = false;
  window.confirm = () => {shouldConfirm = true; return false;};
  editor.value = '저장 전 중요한 문장입니다.';
  editor.dispatchEvent(new Event('input', {bubbles:true}));
  const upload = () => {
    const data = new DataTransfer();
    data.items.add(new File(['# 가져온 문서\n\n내용입니다.\n'], 'import.md', {type:'text/markdown'}));
    input.files = data.files;
    input.dispatchEvent(new Event('change', {bubbles:true}));
  };
  upload();
  await wait();
  check('unsaved changes require confirmation', shouldConfirm && editor.value === '저장 전 중요한 문장입니다.');
  window.confirm = () => true;
  upload();
  await wait();
  check('Markdown import exact', editor.value === '# 가져온 문서\n\n내용입니다.\n' && document.querySelector('#filename').value === 'import.md');
  let saved;
  let closed = false;
  window.showSaveFilePicker = async () => ({name:'saved.md',createWritable:async () => ({write:async text => {saved=text;},close:async () => {closed=true;}})});
  document.querySelector('#save').click();
  await wait();
  check('file writer exact content', saved === editor.value && closed);
  check('saved file name', document.querySelector('#filename').value === 'saved.md');
  const crlf='\ufeff# CRLF\r\n\r\n원래 문장입니다.\r\n';
  const data = new DataTransfer();
  data.items.add(new File([crlf],'crlf.md',{type:'text/markdown'}));
  input.files=data.files;
  input.dispatchEvent(new Event('change',{bubbles:true}));
  await wait();
  check('CRLF source uses consistent LF offsets',editor.value==='# CRLF\n\n원래 문장입니다.\n');
  document.querySelector('#save').click();
  await wait();
  check('CRLF and BOM preserved by file writer',saved===crlf);
  window.confirm = realConfirm;
  window.showSaveFilePicker = originalPicker;
  return checks;
}
