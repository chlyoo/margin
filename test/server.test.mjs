/**
 * Implements:
 *   - FR-MD-4: Provider transport and structured correction validation
 *   - NFR-SEC-1: Local boundary, bounded inputs and secret isolation
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createApp} from '../server.mjs';
import {suggest} from '../ai.mjs';

test('provider adapters use the correct URL, headers and schema', async () => {
  for (const provider of ['gateway', 'claude']) {
    let call;
    const fetcher = async (url, init) => {
      call = {url, ...init, body: JSON.parse(init.body)};
      const text = JSON.stringify({replacement: '고친 문장입니다.', reason: '표현을 다듬었어요.'});
      return Response.json(provider === 'claude' ? {content: [{type: 'text', text}]} : {choices: [{message: {content: text}}]});
    };
    const result = await suggest({provider, model: 'test-model', text: '원래 문장입니다.'}, {AI_GATEWAY_API_KEY: 'test-key', ANTHROPIC_API_KEY: 'test-key'}, fetcher);
    assert.equal(result.replacement, '고친 문장입니다.');
    assert.equal(result.reason, '표현을 다듬었어요.');
    assert.equal(result.searchStatus, 'disabled');
    assert.equal(call.body.model, 'test-model');
    if (provider === 'claude') {
      assert.equal(call.url, 'https://api.anthropic.com/v1/messages');
      assert.equal(call.headers['x-api-key'], 'test-key');
      assert.ok(call.headers['anthropic-version']);
    } else {
      assert.equal(call.url, 'https://ai-gateway.vercel.sh/v1/chat/completions');
      assert.equal(call.headers.Authorization, 'Bearer test-key');
    }
  }
});
test('missing key, malformed output and upstream failures are actionable without leaking secrets', async () => {
  await assert.rejects(suggest({provider: 'gateway', text: 'x', model: 'x'}, {}), /API 키/);
  await assert.rejects(suggest({provider: 'gateway', text: 'x', model: 'x'}, {AI_GATEWAY_API_KEY: 'secret'}, async () => Response.json({choices: [{message: {content: 'not json'}}]})), /형식/);
  await assert.rejects(suggest({provider: 'gateway', text: 'x', model: 'x'}, {AI_GATEWAY_API_KEY: 'secret'}, async () => new Response('secret', {status: 401})), /401/);
});
test('HTTP boundary rejects foreign sites and exposes no keys or arbitrary files', async t => {
  const server = createApp({env: {AI_GATEWAY_API_KEY: 'super-secret'}});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;
  const config = await (await fetch(base + '/api/config')).text();
  assert.ok(config.includes('configured'));
  assert.ok(!config.includes('super-secret'));
  assert.equal((await fetch(base + '/api/suggest', {method: 'POST', headers: {'Content-Type': 'application/json', Origin: 'https://evil.example'}, body: '{}'})).status, 403);
  assert.equal((await fetch(base + '/server.mjs')).status, 404);
  assert.equal((await fetch(base + '/api/suggest', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({provider: 'gateway', model: 'x', text: 'a'.repeat(6001)})})).status, 400);
  assert.equal((await fetch(base + '/api/suggest', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: '{'})).status, 400);
});
