/**
 * Implements:
 *   - FR-MD-1: Shared document updates
 *   - FR-MD-3: Exact document edits
 *   - FR-MD-4: Paragraph targeting and stale suggestion rejection
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {paragraphAt, applySuggestion, safeFilename, decodeDocument, encodeDocument, selectionMatches} from '../public/core.js';

test('targets the current paragraph and preserves UTF-16 ranges', () => {
  const text = '# 제목\n\n첫 문장입니다.\n두 번째 줄입니다.\n\n끝입니다.';
  const range = paragraphAt(text, text.indexOf('두 번째'));
  assert.equal(range.text, '첫 문장입니다.\n두 번째 줄입니다.');
  assert.equal(text.slice(range.start, range.end), range.text);
});
test('does not suggest inside fenced code or on empty paragraphs', () => {
  const text = '본문\n\n```js\nhello()\n```\n\n';
  assert.equal(paragraphAt(text, text.indexOf('hello')), null);
  assert.equal(paragraphAt(text, text.length), null);
});
test('applies only the exact unchanged revision and target', () => {
  const text = '앞\n\n수정 전입니다.\n\n뒤';
  const range = paragraphAt(text, text.indexOf('수정'));
  const suggestion = {...range, revision: 3, replacement: '수정 후입니다.'};
  assert.equal(applySuggestion(text, 3, suggestion), '앞\n\n수정 후입니다.\n\n뒤');
  assert.equal(applySuggestion(text, 4, suggestion), null);
  assert.equal(applySuggestion(text.replace('전', '중'), 3, suggestion), null);
});
test('normalizes filenames without changing document content', () => {
  assert.equal(safeFilename('../draft'), 'draft.md');
  assert.equal(safeFilename('한글.md'), '한글.md');
});
test('paragraph boundaries respect whitespace-only blank lines', () => {
  const text = '앞 문단\n  \n현재 문단입니다.\n\t\n뒤 문단';
  assert.equal(paragraphAt(text, text.indexOf('현재')).text, '현재 문단입니다.');
});
test('fenced code with a language-like marker stays excluded', () => {
  const text = '```text\n```js\nsecret code\n```';
  assert.equal(paragraphAt(text, text.indexOf('secret')), null);
  assert.equal(paragraphAt('    indented code', 10), null);
});
test('CRLF and UTF-8 BOM round trip through LF editor offsets', () => {
  const original='\ufeff# 제목\r\n\r\n원래 문장입니다.\r\n';
  const decoded=decodeDocument(new TextEncoder().encode(original));
  assert.equal(decoded.text,'# 제목\n\n원래 문장입니다.\n');
  assert.deepEqual(decoded.format,{eol:'\r\n',bom:true});
  assert.equal(encodeDocument(decoded.text,decoded.format),original);
  const range=paragraphAt(decoded.text,decoded.text.indexOf('원래'));
  const next=applySuggestion(decoded.text,1,{...range,revision:1,replacement:'고친 문장입니다.'});
  assert.equal(encodeDocument(next,decoded.format),'\ufeff# 제목\r\n\r\n고친 문장입니다.\r\n');
});
test('selection must remain within the target paragraph for Tab acceptance', () => {
  assert.equal(selectionMatches({start:5,end:10},6,6),true);
  assert.equal(selectionMatches({start:5,end:10},5,10),true);
  assert.equal(selectionMatches({start:5,end:10},0,0),false);
  assert.equal(selectionMatches({start:5,end:10},11,11),false);
});
