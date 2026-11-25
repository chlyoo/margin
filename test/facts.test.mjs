/**
 * Implements:
 *   - FR-MD-5: Search-backed factual review with source provenance
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {suggest} from '../ai.mjs';

const input = {provider:'gateway', model:'anthropic/claude-sonnet-5.5', text:'서울은 일본의 수도입니다.', factCheck:true};
const result = {replacement:'서울은 대한민국의 수도입니다.', reason:'수도 정보를 수정했어요.', category:'fact', factChecks:[{claim:'서울은 일본의 수도입니다.',verdict:'contradicted',explanation:'서울은 대한민국의 수도예요.',sourceUrls:['https://www.seoul.go.kr/']} ]};
const response = (value, sources=[]) => Response.json({content:[
  ...(sources.length ? [{type:'web_search_tool_result',content:sources.map(url=>({type:'web_search_result',url,title:'서울시'}))}] : []),
  {type:'text',text:JSON.stringify(value)},
]});

test('Gateway facts use Messages with bounded native web search', async () => {
  let call;
  const value = await suggest(input, {AI_GATEWAY_API_KEY:'fake'}, async (url, init) => {call={url,...init,body:JSON.parse(init.body)}; return response(result,['https://www.seoul.go.kr/']);});
  assert.equal(call.url,'https://ai-gateway.vercel.sh/v1/messages');
  assert.equal(call.body.tools[0].type,'web_search_20250305');
  assert.equal(call.body.tools[0].max_uses,2);
  assert.equal(value.factChecks[0].verdict,'contradicted');
  assert.equal(value.factChecks[0].sources[0].url,'https://www.seoul.go.kr/');
  assert.equal(value.replacement,result.replacement);
});
test('invented sources cannot authorize a factual edit', async () => {
  const value = await suggest(input,{AI_GATEWAY_API_KEY:'fake'},async()=>response(result));
  assert.equal(value.replacement,input.text);
  assert.equal(value.factChecks[0].verdict,'unverified');
  assert.deepEqual(value.factChecks[0].sources,[]);
});
test('search errors remain unverified instead of reporting successful verification',async()=>{
  const value = await suggest(input,{AI_GATEWAY_API_KEY:'fake'},async()=>Response.json({content:[{type:'web_search_tool_result',content:{type:'web_search_tool_result_error',error_code:'unavailable'}},{type:'text',text:JSON.stringify(result)}]}));
  assert.equal(value.searchStatus,'failed');
  assert.equal(value.factChecks[0].verdict,'unverified');
  assert.equal(value.replacement,input.text);
});
test('direct Claude facts retain native citation sources and reject unsafe URLs',async()=>{
  const value = await suggest({...input,provider:'claude',model:'claude-sonnet-5-5'},{ANTHROPIC_API_KEY:'fake'},async()=>Response.json({content:[{type:'text',text:JSON.stringify({...result,factChecks:[{...result.factChecks[0],sourceUrls:['https://www.seoul.go.kr/','javascript:alert(1)']}]}),citations:[{type:'web_search_result_location',url:'https://www.seoul.go.kr/',title:'서울시'}]}]}));
  assert.equal(value.factChecks[0].sources.length,1);
});
test('factual review rejects missing category instead of treating facts as grammar',async()=>{
  const missing = {...result};
  delete missing.category;
  await assert.rejects(suggest(input,{AI_GATEWAY_API_KEY:'fake'},async()=>response(missing)),/형식/);
});
test('a numeric fact change mislabeled grammar still requires evidence',async()=>{
  const original={...input,text:'이 제품은 2020년에 출시됐습니다.'};
  const value=await suggest(original,{AI_GATEWAY_API_KEY:'fake'},async()=>response({replacement:'이 제품은 2025년에 출시됐습니다.',reason:'문법',category:'grammar',factChecks:[]}));
  assert.equal(value.replacement,original.text);
});
