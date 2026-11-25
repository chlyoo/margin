import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {resolve} from 'node:path';
import {providerConfig, suggest} from './ai.mjs';

const root = fileURLToPath(new URL('.', import.meta.url));
const files = {
  '/': ['public/index.html', 'text/html'],
  '/app.js': ['public/app.js', 'text/javascript'],
  '/core.js': ['public/core.js', 'text/javascript'],
  '/render.js': ['public/render.js', 'text/javascript'],
  '/style.css': ['public/style.css', 'text/css'],
  '/vendor/marked.js': ['node_modules/marked/lib/marked.esm.js', 'text/javascript'],
  '/vendor/purify.js': ['node_modules/dompurify/dist/purify.es.mjs', 'text/javascript'],
  '/vendor/prism.js': ['node_modules/prismjs/prism.js', 'text/javascript'],
  '/vendor/prism.css': ['node_modules/prismjs/themes/prism.css', 'text/css'],
};

export function createApp({env = process.env, fetcher = fetch} = {}) {
  let inFlight = false;
  return createServer(async (req, res) => {
    const send = (status, data) => {
      res.writeHead(status, {'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store'});
      res.end(JSON.stringify(data));
    };
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src https: http: data: blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
    const port = req.socket.localPort;
    const origins = [`http://127.0.0.1:${port}`, `http://localhost:${port}`];
    if (!origins.includes(`http://${req.headers.host}`) || (req.headers.origin && !origins.includes(req.headers.origin)) || req.headers['sec-fetch-site'] === 'cross-site') return send(403, {error: '로컬 앱에서만 접근할 수 있어요.'});
    const path = new URL(req.url, origins[0]).pathname;
    if (req.method === 'GET' && path === '/api/config') return send(200, providerConfig(env));
    if (req.method === 'POST' && path === '/api/suggest') {
      if (!req.headers['content-type']?.startsWith('application/json')) return send(415, {error: 'JSON 요청이 필요해요.'});
      let size = 0;
      let chunks = [];
      let body;
      try {
        for await (const chunk of req) {
          size += chunk.length;
          if (size > 40000) {send(413, {error: '교정할 문단이 너무 길어요.'}); return;}
          chunks.push(chunk);
        }
        body = JSON.parse(Buffer.concat(chunks).toString());
      } catch {return send(400, {error: '요청 형식이 올바르지 않아요.'});}
      if (!body || typeof body !== 'object') return send(400, {error: '요청 형식이 올바르지 않아요.'});
      if (inFlight) return send(429, {error: '이전 교정 요청이 처리 중이에요.'});
      inFlight = true;
      const controller = new AbortController();
      res.on('close', () => controller.abort());
      try {send(200, await suggest(body, env, fetcher, controller.signal));}
      catch (error) {if (!res.destroyed) send(error.status || 500, {error: error.status ? error.message : '요청을 처리하지 못했어요.'});}
      finally {inFlight = false;}
      return;
    }
    if (req.method !== 'GET' || !files[path]) return send(404, {error: '찾을 수 없어요.'});
    try {
      const [file, type] = files[path];
      const contents = await readFile(resolve(root, file));
      res.writeHead(200, {'Content-Type': `${type}; charset=utf-8`, 'Cache-Control': 'no-cache'});
      res.end(contents);
    } catch {send(500, {error: '앱 파일을 읽지 못했어요. npm ci를 실행해 주세요.'});}
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT || 4317);
  const server = createApp();
  server.on('error', error => {console.error(error.code === 'EADDRINUSE' ? `Port ${port} is in use. Set PORT to another port.` : error.message); process.exitCode = 1;});
  server.listen(port, '127.0.0.1', () => console.log(`Markdown Studio: http://127.0.0.1:${port}`));
}
