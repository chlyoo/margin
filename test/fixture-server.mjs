import {createApp} from '../server.mjs';

const server = createApp({
  env: {AI_GATEWAY_API_KEY: 'fixture-not-a-real-key', ANTHROPIC_API_KEY: 'fixture-not-a-real-key'},
  fetcher: async (_url, options) => {
    const input = JSON.parse(options.body);
    const text = input.messages.at(-1).content;
    const facts = text.includes('서울은 일본');
    const unknown = text.includes('확인되지 않은');
    const value = facts || unknown ? {
      replacement:facts ? '서울은 대한민국의 수도입니다.' : '근거 없는 수정입니다.',
      reason:'사실 관계를 검토했어요.',category:'fact',
      factChecks:[{claim:text,verdict:'contradicted',explanation:facts ? '서울은 대한민국의 수도예요.' : '이 주장은 확인이 필요해요.',sourceUrls:['https://www.seoul.go.kr/']}],
    } : {replacement: text.replace('문장', '표현'), reason: '테스트 교정 결과예요.',category:'grammar',factChecks:[]};
    const result = JSON.stringify(value);
    return Response.json({choices: [{message: {content: result}}], content: [
      ...(facts ? [{type:'web_search_tool_result',content:[{type:'web_search_result',url:'https://www.seoul.go.kr/',title:'서울특별시'}]}] : []),
      {type: 'text', text: result},
    ]});
  },
});
server.listen(4318, '127.0.0.1', () => console.log('Markdown Studio test fixture: http://127.0.0.1:4318 (no external calls)'));
