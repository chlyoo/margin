// Script failures are reported to the app instead of leaving a silent blank preview.
window.addEventListener('error', event => window.webkit?.messageHandlers?.margin?.postMessage({error:`${event.message} (${(event.filename || '').split('/').pop()}:${event.lineno})`}));
const renderer = new marked.Renderer();
renderer.code = ({text,lang}) => {
  const name = (lang || '').split(/\s/)[0].replace(/[^\w-]/g,'');
  const code = Prism.languages[name] ? Prism.highlight(text,Prism.languages[name],name) : text.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
  return `<pre><code class="language-${name}">${code}</code></pre>`;
};
// A single newline is a visible line break (as in Obsidian); a blank line starts a new paragraph.
marked.use({renderer,gfm:true,breaks:true});
// Obsidian-style tags: `#name` after whitespace or at the start of a line renders as a chip. The source stays `#name`.
marked.use({extensions:[{
  name:'tag', level:'inline',
  start(src) { const found = src.match(/(?:^|\s)#(?=[\p{L}\p{N}_\/-])/u); return found ? found.index + found[0].length - 1 : undefined; },
  tokenizer(src, tokens) {
    const found = /^#([\p{L}\p{N}_\/-]+)/u.exec(src);
    if (!found || /^\d+$/.test(found[1])) return;
    const last = tokens[tokens.length - 1];
    if (last && last.type !== 'br' && !(last.type === 'text' && /\s$/.test(last.raw))) return;
    return {type:'tag', raw:found[0], text:found[0]};
  },
  renderer(token) { return `<span class="tag">${token.text.replace(/&/g,'&amp;').replace(/</g,'&lt;')}</span>`; }
}]});
const article = () => document.querySelector('#document');
const clean = html => {
  const fragment = DOMPurify.sanitize(html, {RETURN_DOM_FRAGMENT:true, USE_PROFILES:{html:true}, FORBID_TAGS:['style','iframe','form','video','audio','source','button','textarea','select'], FORBID_ATTR:['style','src','srcset','background','poster','autofocus','contenteditable','tabindex','id','name']});
  for (const node of fragment.querySelectorAll('[data-md]')) node.removeAttribute('data-md');
  for (const input of fragment.querySelectorAll('input')) {if(input.type==='checkbox')input.disabled=true;else input.remove();}
  for (const image of fragment.querySelectorAll('img')) {const span=document.createElement('span');span.className='image-placeholder';span.textContent='▧ '+(image.alt||'이미지');image.replaceWith(span);}
  for (const anchor of fragment.querySelectorAll('a')) {try {const url=new URL(anchor.getAttribute('href'));if(!['http:','https:'].includes(url.protocol))anchor.removeAttribute('href');}catch{anchor.removeAttribute('href');}}
  return fragment;
};
let source = '', editable = false, seq = 0, painting = false, painted = false, mapped = false, touched = false, linkSignature = '';
let dirty = new Set();
const info = new WeakMap(), cache = new Map();

// ---- rendered DOM -> Markdown. Only blocks the user changed are serialized; the rest keep their exact source.
const isBlock = node => node.nodeType === 1 && /^(P|DIV|H[1-6]|UL|OL|PRE|BLOCKQUOTE|TABLE|HR|SECTION)$/.test(node.tagName);
const escapeText = text => text.replace(/\u00a0/g, ' ').replace(/\\/g, '\\\\').replace(/([*`\[\]])/g, '\\$1')
  .replace(/_/g, (match, index, all) => /[A-Za-z0-9]/.test(all[index - 1] || '') && /[A-Za-z0-9]/.test(all[index + 1] || '') ? '_' : '\\_')
  .replace(/~~/g, '\\~~').replace(/<(?=[a-zA-Z\/!?])/g, '\\<').replace(/&(?=#?\w+;)/g, '\\&');
const guardLines = text => text.replace(/^(\d+)([.)])(?=\s|$)/gm, '$1\\$2').replace(/^(#{1,6})(?=\s|$)/gm, '\\$1').replace(/^>/gm, '\\>').replace(/^([-+])(?=\s|$)/gm, '\\$1').replace(/^(=+|-{3,})\s*$/gm, '\\$1');
const tidy = text => text.replace(/[ \t]*\n[ \t]*/g, '\n').replace(/(\\\n)+$/, '').trim();
const wrap = (mark, inner) => { const parts = inner.match(/^(\s*)([\s\S]*?)(\s*)$/); return parts[2] ? parts[1] + mark + parts[2] + mark + parts[3] : inner; };
const inlineOf = node => [...node.childNodes].map(inlineNode).join('');
const inlineNode = node => {
  if (node.nodeType === 3) return escapeText(node.nodeValue);
  if (node.nodeType !== 1) return '';
  const tag = node.tagName;
  if (tag === 'BR') return '\n';
  if (tag === 'STRONG' || tag === 'B') return wrap('**', inlineOf(node));
  if (tag === 'EM' || tag === 'I') return wrap('*', inlineOf(node));
  if (tag === 'DEL' || tag === 'S' || tag === 'STRIKE') return wrap('~~', inlineOf(node));
  if (tag === 'CODE') {
    const text = node.textContent.replace(/\u00a0/g, ' '); if (!text) return '';
    let fence = '`'; while (text.includes(fence)) fence += '`';
    const pad = /^`|`$/.test(text) || (/^ .* $/.test(text) && text.trim()) ? ' ' : '';
    return fence + pad + text + pad + fence;
  }
  if (tag === 'A') {
    const inner = inlineOf(node), href = node.getAttribute('href'), label = node.textContent;
    if (!href) return inner;
    if (label === href || 'mailto:' + label === href || 'http://' + label === href) return label;
    const title = node.getAttribute('title');
    return `[${inner}](${/[\s()]/.test(href) ? '<' + href + '>' : href}${title ? ` "${title.replace(/"/g, '\\"')}"` : ''})`;
  }
  if (tag === 'INPUT') return '';
  if (node.classList.contains('tag')) return node.textContent.replace(/\u00a0/g, ' ');
  if (tag === 'IMG') { const address = node.getAttribute('src') || ''; return /^https?:\/\//i.test(address) ? `![${escapeText(node.getAttribute('alt') || '')}](${address})` : ''; }
  if (node.classList.contains('image-placeholder')) return node.dataset.md || '';
  return inlineOf(node);
};
const plain = node => node.nodeType === 3 ? node.nodeValue : node.nodeType !== 1 ? '' : node.tagName === 'BR' ? '\n' : (node.tagName === 'DIV' && node.previousSibling ? '\n' : '') + [...node.childNodes].map(plain).join('');
const blocksOf = (node, separator = '\n\n') => {
  const parts = []; let run = [];
  const flush = () => { if (!run.length) return; const text = guardLines(tidy(run.map(inlineNode).join(''))); if (text) parts.push(text); run = []; };
  for (const child of node.childNodes) {
    if (isBlock(child)) { flush(); const text = blockNode(child); if (text) parts.push(text); } else run.push(child);
  }
  flush(); return parts.join(separator);
};
const listOf = node => {
  const ordered = node.tagName === 'OL'; let number = +(node.getAttribute('start') || 1);
  const items = [], extras = new Map();
  for (const child of node.children) {
    if (child.tagName === 'LI') items.push(child);
    else if ((child.tagName === 'UL' || child.tagName === 'OL') && items.length) extras.set(items[items.length - 1], [...(extras.get(items[items.length - 1]) || []), child]);
  }
  const loose = items.some(item => [...item.children].some(child => child.tagName === 'P'));
  return items.map(item => {
    const marker = ordered ? `${number++}. ` : '- ', pad = ' '.repeat(marker.length);
    const box = item.querySelector(':scope > input[type=checkbox], :scope > p:first-child > input[type=checkbox]');
    const body = (box ? (box.checked ? '[x] ' : '[ ] ') : '') + [blocksOf(item, loose ? '\n\n' : '\n'), ...(extras.get(item) || []).map(listOf)].filter(Boolean).join('\n');
    return (marker + body.split('\n').map((line, index) => index && line ? pad + line : line).join('\n')).trimEnd();
  }).join(loose ? '\n\n' : '\n');
};
const tableOf = node => {
  const rows = [...node.rows]; if (!rows.length) return '';
  const cells = row => '| ' + [...row.cells].map(cell => tidy(inlineOf(cell)).replace(/\s*\n\s*/g, '<br>').replace(/\|/g, '\\|')).join(' | ') + ' |';
  const align = '| ' + [...rows[0].cells].map(cell => ({left:':---', center:':---:', right:'---:'}[cell.getAttribute('align')] || '---')).join(' | ') + ' |';
  return [cells(rows[0]), align, ...rows.slice(1).map(cells)].join('\n');
};
const blockNode = node => {
  if (node.nodeType === 3) return guardLines(tidy(escapeText(node.nodeValue)));
  if (node.nodeType !== 1) return '';
  const tag = node.tagName;
  if (/^H[1-6]$/.test(tag)) { const text = tidy(inlineOf(node)).replace(/\\?\s*\n\s*/g, ' '); return text ? '#'.repeat(+tag[1]) + ' ' + text : ''; }
  if (tag === 'HR') return '---';
  if (tag === 'PRE') {
    const code = node.querySelector('code'), language = ((code?.className || '').match(/language-([\w-]+)/) || [])[1] || '';
    const text = plain(code || node).replace(/\u00a0/g, ' ').replace(/\n$/, '');
    let fence = '```'; while (text.includes(fence)) fence += '`';
    return fence + language + '\n' + text + '\n' + fence;
  }
  if (tag === 'BLOCKQUOTE') { const text = blocksOf(node); return text ? text.split('\n').map(line => line ? '> ' + line : '>').join('\n') : ''; }
  if (tag === 'UL' || tag === 'OL') return listOf(node);
  if (tag === 'TABLE') return tableOf(node);
  if (tag === 'SECTION' || (tag === 'DIV' && [...node.childNodes].some(isBlock))) return blocksOf(node);
  if (tag === 'P' || tag === 'DIV') return guardLines(tidy(inlineOf(node)));
  return guardLines(tidy(inlineNode(node)));
};

// ---- pasted rich text (Google Docs, Word, web pages) -> Markdown. The pasted HTML itself never enters the page.
const convertHTML = (html, plainText, fenceCode) => {
  const body = new DOMParser().parseFromString(html, 'text/html').body, doc = body.ownerDocument;
  for (const node of body.querySelectorAll('script,style,meta,link,title')) node.remove();
  const styleOf = node => node.getAttribute('style') || '';
  const monoFont = node => /font-family[^;]*(mono|courier|consolas|menlo)/i.test(styleOf(node));
  const codeLike = node => monoFont(node) || /white-space\s*:\s*pre/i.test(styleOf(node)) || ['PRE', 'CODE', 'TT', 'KBD', 'SAMP'].includes(node.tagName);
  let total = 0, code = 0;
  const walker = doc.createTreeWalker(body, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    if (!walker.currentNode.nodeValue.trim()) continue;
    total++;
    for (let parent = walker.currentNode.parentElement; parent && parent !== body; parent = parent.parentElement) if (codeLike(parent)) { code++; break; }
  }
  if (!total) return null;
  // Everything is code (copied from an editor or terminal): keep the plain text exactly.
  if (code === total) { const text = (plainText || body.textContent).replace(/\n+$/, ''); return fenceCode && text.includes('\n') ? '```\n' + text + '\n```' : null; }
  for (const node of [...body.querySelectorAll('[style]')]) {
    if (!node.isConnected) continue;
    const style = styleOf(node), tag = node.tagName;
    if ((tag === 'B' || tag === 'STRONG') && /font-weight\s*:\s*(normal|[1-4]00)/i.test(style)) { node.replaceWith(...node.childNodes); continue; }
    if (tag !== 'SPAN' && tag !== 'FONT') continue;
    const marks = [];
    if (/font-weight\s*:\s*(bold|[6-9]00)/i.test(style)) marks.push('strong');
    if (/font-style\s*:\s*italic/i.test(style)) marks.push('em');
    if (/text-decoration[^;]*line-through/i.test(style)) marks.push('del');
    if (monoFont(node)) marks.push('code');
    let inner = node;
    for (const mark of marks) { const wrapper = doc.createElement(mark); wrapper.append(...inner.childNodes); inner.append(wrapper); inner = wrapper; }
  }
  const blockSelector = 'p,div,h1,h2,h3,h4,h5,h6,ul,ol,table,pre,blockquote,hr';
  for (const node of [...body.querySelectorAll('span,b,strong,i,em,font,u,a')]) if (node.isConnected && node.querySelector(blockSelector)) node.replaceWith(...node.childNodes);
  for (const item of body.querySelectorAll('li')) { const first = item.firstElementChild; if (first && first.tagName === 'P' && [...item.children].filter(child => child.tagName === 'P').length === 1) first.replaceWith(...first.childNodes); }
  for (const heading of body.querySelectorAll('h1,h2,h3,h4,h5,h6')) for (const node of [...heading.querySelectorAll('strong,b')]) node.replaceWith(...node.childNodes);
  for (const node of [...body.querySelectorAll('strong,b,em,i,del')]) {
    if (!node.isConnected) continue;
    while (node.nextSibling && node.nextSibling.nodeType === 1 && node.nextSibling.tagName === node.tagName) { node.append(...node.nextSibling.childNodes); node.nextSibling.remove(); }
  }
  const markdown = blocksOf(body), strip = text => text.replace(/\s+/g, '');
  if (!markdown || strip(markdown.replace(/\\(.)/g, '$1')) === strip(plainText || body.textContent)) return null;
  return markdown;
};
window.marginConvertHTML = (html, plainText) => convertHTML(html, plainText, false);

// ---- block model
const holder = fragment => { const box = document.createElement('div'); box.append(fragment); return box; };
// Whitespace next to a line break or a block edge is invisible, so it does not count as a rendering difference.
const normalize = html => html.replace(/\s+/g, ' ').replace(/ ?(<br>|<\/?(?:p|li|ul|ol|h[1-6]|td|th|tr|table|thead|tbody|blockquote|pre)(?: [^>]*)?>) ?/g, '$1').replace(/> </g, '><').trim();
const imageSources = token => {
  const found = [];
  const walk = item => {
    if (!item || typeof item !== 'object') return;
    if (Array.isArray(item)) { item.forEach(walk); return; }
    if (item.type === 'image') found.push(item.raw);
    for (const key of ['tokens', 'items', 'header', 'rows']) if (item[key]) walk(item[key]);
  };
  walk(token); return found;
};
const tagImages = (root, sources) => {
  const spots = root.querySelectorAll('.image-placeholder');
  if (spots.length !== sources.length) return false;
  spots.forEach((spot, index) => { spot.dataset.md = sources[index]; spot.contentEditable = 'false'; });
  return true;
};
const describe = (token, links) => {
  let hit = cache.get(token.raw); if (hit) return hit;
  const list = [token]; list.links = links;
  const box = holder(clean(marked.parser(list))), html = box.innerHTML, sources = imageSources(token);
  const empty = !box.textContent.trim() && !box.querySelector('hr,input,table,.image-placeholder');
  let locked = empty || token.type === 'html' || token.type === 'def' || !tagImages(box, sources);
  // A block is editable in place only when serializing its rendering reproduces the same rendering.
  if (!locked) locked = normalize(holder(clean(marked.parse(blocksOf(box)))).innerHTML) !== normalize(html);
  hit = {html:box.innerHTML, empty, locked};
  if (cache.size > 4000) cache.clear();
  cache.set(token.raw, hit); return hit;
};
const paint = () => {
  painting = true; dirty = new Set(); touched = false; painted = true;
  const root = article(), tokens = marked.lexer(source), parts = [];
  const signature = JSON.stringify(tokens.links || {});
  if (signature !== linkSignature) { cache.clear(); linkSignature = signature; }
  let offset = 0, exact = true, lead = '';
  for (const token of tokens) {
    if (!source.startsWith(token.raw, offset)) { exact = false; break; }
    if (token.type === 'space') { if (parts.length) parts[parts.length - 1].gap += token.raw; else lead += token.raw; }
    else { const body = token.raw.replace(/\n+$/, ''); parts.push({token, body, gap:token.raw.slice(body.length)}); }
    offset += token.raw.length;
  }
  if (!exact || offset !== source.length) {
    mapped = false; root.contentEditable = 'false'; root.classList.remove('editable');
    root.replaceChildren(clean(marked.parse(source)));
  } else {
    const fragment = document.createDocumentFragment();
    parts.forEach((part, index) => {
      const detail = describe(part.token, tokens.links), section = document.createElement('section');
      section.className = 'block';
      if (detail.empty) { const raw = document.createElement('div'); raw.className = 'raw'; raw.textContent = part.body; section.append(raw); }
      else section.innerHTML = detail.html;
      if (detail.locked) { section.contentEditable = 'false'; section.classList.add('locked'); }
      else if (editable) for (const box of section.querySelectorAll('input[type=checkbox]')) box.disabled = false;
      info.set(section, {index, body:part.body, gap:part.gap, locked:detail.locked, last:index === parts.length - 1, lead:index === 0 ? lead : ''});
      fragment.append(section);
    });
    mapped = true; root.replaceChildren(fragment);
    root.contentEditable = editable ? 'true' : 'false'; root.classList.toggle('editable', editable);
  }
  observer.takeRecords(); painting = false;
};
const compose = () => {
  const items = [];
  for (const node of article().childNodes) {
    const meta = info.get(node), changed = !meta || (dirty.has(node) && !meta.locked);
    const body = meta ? (changed ? blocksOf(node) : meta.body) : blockNode(node);
    if (body) items.push({meta, body, changed});
  }
  let text = '';
  items.forEach((item, index) => {
    const meta = item.meta, next = items[index + 1];
    if (index === 0 && meta && meta.index === 0) text += meta.lead;
    let gap = !next ? (meta && meta.last ? meta.gap : '\n') : (meta && next.meta && next.meta.index === meta.index + 1 ? meta.gap : '\n\n');
    if (next && (item.changed || next.changed) && !/\n\s*\n/.test(gap)) gap = '\n\n';
    text += item.body + gap;
  });
  return text;
};
const note = records => {
  if (painting) return;
  for (const record of records) {
    touched = true;
    let node = record.target;
    while (node && node.parentNode !== article()) node = node.parentNode;
    if (node && info.has(node)) dirty.add(node);
  }
};
const observer = new MutationObserver(note);
observer.observe(article(), {subtree:true, childList:true, characterData:true});
const sync = () => {
  note(observer.takeRecords());
  if (!touched || !mapped || !editable) return;
  const next = compose(); if (next === source) return;
  const limit = Math.min(source.length, next.length);
  let start = 0; while (start < limit && source[start] === next[start]) start++;
  let tail = 0; while (tail < limit - start && source[source.length - 1 - tail] === next[next.length - 1 - tail]) tail++;
  // Never split a surrogate pair across the edit boundary.
  if (start > 0 && (source.charCodeAt(start - 1) & 0xfc00) === 0xd800) start--;
  if (tail > 0 && (source.charCodeAt(source.length - tail) & 0xfc00) === 0xdc00) tail--;
  window.webkit?.messageHandlers?.margin?.postMessage({seq:++seq, start, end:source.length - tail, before:source.slice(start, source.length - tail), text:next.slice(start, next.length - tail)});
  source = next;
};
const finish = () => { if (holding) return; hideBubble(); sync(); if (touched) paint(); };
let holding = false, savedRange = null;
const root = article();
const post = message => window.webkit?.messageHandlers?.margin?.postMessage(message);
// Typing `#name` and a space turns the name into a chip right away.
const autoTag = () => {
  const selection = inRoot(); if (!selection || !selection.isCollapsed) return;
  const node = selection.anchorNode;
  if (node.nodeType !== 3 || node.parentElement.closest('code,pre,a,.tag,section.locked')) return;
  const found = /(^|\s)(#[\p{L}\p{N}_\/-]+)[ \u00a0]$/u.exec(node.nodeValue.slice(0, selection.anchorOffset));
  if (!found || /^#\d+$/.test(found[2])) return;
  if (!found[1] && node.previousSibling && node.previousSibling.nodeName !== 'BR') return;
  const start = found.index + found[1].length, range = document.createRange(), chip = document.createElement('span');
  range.setStart(node, start); range.setEnd(node, start + found[2].length);
  chip.className = 'tag'; range.surroundContents(chip);
  const rest = chip.nextSibling;
  if (rest && rest.nodeType === 3) selection.collapse(rest, Math.min(1, rest.nodeValue.length));
};
// Typing a URL and a space links it right away.
const autoLink = () => {
  const selection = inRoot(); if (!selection || !selection.isCollapsed) return;
  const node = selection.anchorNode;
  if (node.nodeType !== 3 || node.parentElement.closest('code,pre,a,.tag,section.locked')) return;
  const found = /(^|\s)(https?:\/\/[^\s<]+?)[.,;:!?)]*[ \u00a0]$/i.exec(node.nodeValue.slice(0, selection.anchorOffset));
  if (!found) return;
  const start = found.index + found[1].length, range = document.createRange(), anchor = document.createElement('a');
  range.setStart(node, start); range.setEnd(node, start + found[2].length);
  anchor.setAttribute('href', found[2]); range.surroundContents(anchor);
  const rest = anchor.nextSibling;
  if (rest && rest.nodeType === 3) selection.collapse(rest, rest.nodeValue.length);
};
root.addEventListener('input', event => {
  if (event.isComposing) return;
  if (editable && event.inputType === 'insertText' && (event.data === ' ' || event.data === '\u00a0')) { autoTag(); autoLink(); }
  sync();
});
root.addEventListener('compositionend', sync);
root.addEventListener('change', event => {
  let node = event.target; while (node && node.parentNode !== root) node = node.parentNode;
  if (node && info.has(node)) { dirty.add(node); touched = true; sync(); }
});
root.addEventListener('paste', event => {
  event.preventDefault();
  const html = event.clipboardData.getData('text/html'), text = event.clipboardData.getData('text/plain');
  const markdown = html ? convertHTML(html, text, true) : null;
  const address = /^https?:\/\/[^\s<]+$/i.test(text.trim()) ? text.trim() : null, selection = inRoot();
  if (markdown === null && address && selection && !anchorElement(selection).closest('code,pre')) {
    // A pasted URL links the selected words, or becomes a link itself.
    if (selection.isCollapsed) document.execCommand('insertHTML', false, `<a href="${quote(address)}">${quote(address)}</a>`);
    else document.execCommand('createLink', false, address);
    return;
  }
  if (markdown === null) { document.execCommand('insertText', false, text); return; }
  const tokens = marked.lexer(markdown), box = holder(clean(marked.parser(tokens)));
  tagImages(box, imageSources(tokens));
  const inline = box.children.length === 1 && box.firstElementChild.tagName === 'P';
  document.execCommand('insertHTML', false, inline ? box.firstElementChild.innerHTML : box.innerHTML);
});
root.addEventListener('drop', event => event.preventDefault());
root.addEventListener('keydown', event => {
  if (event.key === 'Escape') root.blur();
  else if (event.metaKey && !event.shiftKey && !event.altKey && event.key.toLowerCase() === 'k') { event.preventDefault(); window.marginFormat('link'); }
});
root.addEventListener('focusout', finish);
window.addEventListener('blur', finish);
root.addEventListener('click', event => {
  const anchor = event.target.closest?.('a[href]');
  if (!anchor || !editable) return;
  event.preventDefault();
  if (event.metaKey) window.webkit?.messageHandlers?.margin?.postMessage({open:anchor.getAttribute('href')});
});
// ---- formatting commands driven by the native toolbar. Only what Markdown can express.
const inRoot = () => { const selection = getSelection(); return selection.rangeCount && root.contains(selection.anchorNode) ? selection : null; };
const anchorElement = selection => selection.anchorNode.nodeType === 1 ? selection.anchorNode : selection.anchorNode.parentElement;
const quote = text => text.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
const reportState = () => {
  const selection = editable && inRoot(); if (!selection) return;
  const element = anchorElement(selection), block = element.closest('h1,h2,h3,h4,h5,h6,pre,blockquote,li,p');
  post({state:{bold:!!element.closest('b,strong'), italic:!!element.closest('i,em'), strike:!!element.closest('s,strike,del'), code:!!element.closest('code') && !element.closest('pre'), block:block ? block.tagName.toLowerCase() : 'p'}});
};
// Caret inside a link shows its address with open / edit / remove, the way document editors do.
const linkBubble = document.createElement('div'), bubbleAddress = document.createElement('span');
let bubbleAnchor = null;
const bubbleButton = (label, action) => {
  const button = document.createElement('button'); button.type = 'button'; button.textContent = label;
  button.addEventListener('mousedown', event => event.preventDefault());
  button.addEventListener('click', event => { event.preventDefault(); action(); });
  return button;
};
const selectAnchor = anchor => {
  if (!anchor || !anchor.isConnected) return false;
  const range = document.createRange(), selection = getSelection();
  range.selectNodeContents(anchor); selection.removeAllRanges(); selection.addRange(range); return true;
};
const hideBubble = () => { linkBubble.hidden = true; bubbleAnchor = null; };
const showBubble = () => {
  const selection = editable && !holding && inRoot(), anchor = selection ? anchorElement(selection).closest('a[href]') : null;
  if (!anchor || anchor.closest('section.locked')) { hideBubble(); return; }
  bubbleAnchor = anchor; bubbleAddress.textContent = anchor.getAttribute('href'); linkBubble.hidden = false;
  const box = anchor.getBoundingClientRect();
  linkBubble.style.top = Math.min(box.bottom + 6, innerHeight - linkBubble.offsetHeight - 8) + 'px';
  linkBubble.style.left = Math.max(8, Math.min(box.left, innerWidth - linkBubble.offsetWidth - 8)) + 'px';
};
linkBubble.className = 'linkbubble'; linkBubble.hidden = true; bubbleAddress.className = 'address';
linkBubble.append(bubbleAddress,
  bubbleButton('열기', () => { if (bubbleAnchor) post({open:bubbleAnchor.getAttribute('href')}); }),
  bubbleButton('편집', () => { if (selectAnchor(bubbleAnchor)) window.marginFormat('link'); }),
  bubbleButton('링크 제거', () => { if (selectAnchor(bubbleAnchor)) { document.execCommand('unlink'); hideBubble(); sync(); } }));
document.body.append(linkBubble);
window.addEventListener('scroll', showBubble, {passive:true});
document.addEventListener('selectionchange', () => { reportState(); showBubble(); });
const linkBar = document.createElement('div'), linkInput = document.createElement('input');
linkBar.className = 'linkbar'; linkBar.hidden = true;
linkInput.type = 'text'; linkInput.spellcheck = false; linkInput.placeholder = 'https://…  Enter로 적용 · 비우면 링크 제거 · Esc로 취소';
linkBar.append(linkInput); document.body.append(linkBar);
const closeLink = apply => {
  if (!holding) return;
  holding = false;
  const value = linkInput.value.trim(), range = savedRange; savedRange = null;
  linkBar.hidden = true; root.focus();
  const selection = getSelection(); selection.removeAllRanges(); if (range) selection.addRange(range);
  if (!apply || !range) return;
  const address = value && !/^https?:\/\//i.test(value) ? 'https://' + value : value;
  if (!address) document.execCommand('unlink');
  else if (range.collapsed) document.execCommand('insertHTML', false, `<a href="${quote(address)}">${quote(address)}</a>`);
  else document.execCommand('createLink', false, address);
  sync(); reportState();
};
linkInput.addEventListener('keydown', event => {
  if (event.key === 'Enter') { event.preventDefault(); closeLink(true); }
  else if (event.key === 'Escape') { event.preventDefault(); closeLink(false); }
});
linkInput.addEventListener('blur', () => closeLink(false));
window.marginFormat = command => {
  const selection = editable && mapped && inRoot(); if (!selection) return false;
  const element = anchorElement(selection);
  if (element.closest('section.locked')) return false;
  const run = (name, value) => document.execCommand(name, false, value);
  if (command === 'bold') run('bold');
  else if (command === 'italic') run('italic');
  else if (command === 'strike') run('strikeThrough');
  else if (command === 'code') {
    const code = element.closest('code');
    if (code && !code.closest('pre')) code.replaceWith(...code.childNodes);
    else if (!selection.isCollapsed) run('insertHTML', `<code>${quote(selection.toString())}</code>`);
  }
  else if (['p', 'h1', 'h2', 'h3'].includes(command)) run('formatBlock', `<${command}>`);
  else if (command === 'bullet') run('insertUnorderedList');
  else if (command === 'number') run('insertOrderedList');
  else if (command === 'task') {
    let item = element.closest('li');
    if (!item) { run('insertUnorderedList'); const again = inRoot(); item = again ? anchorElement(again).closest('li') : null; }
    if (item) {
      const box = item.querySelector(':scope > input[type=checkbox]');
      if (box) box.remove(); else { const made = document.createElement('input'); made.type = 'checkbox'; item.prepend(made, document.createTextNode(' ')); }
    }
  }
  else if (command === 'quote') { if (element.closest('blockquote')) run('outdent'); else run('formatBlock', '<blockquote>'); }
  else if (command === 'codeblock') run('formatBlock', element.closest('pre') ? '<p>' : '<pre>');
  else if (command === 'rule') run('insertHorizontalRule');
  else if (command === 'tag') {
    const chip = element.closest('.tag');
    if (chip) chip.replaceWith(document.createTextNode(chip.textContent.replace(/^#/, '')));
    else {
      if (selection.isCollapsed) { selection.modify('move', 'backward', 'word'); selection.modify('extend', 'forward', 'word'); }
      const name = selection.toString().trim().replace(/\s+/g, '-').replace(/[^\p{L}\p{N}_\/-]/gu, '');
      if (!name || /^\d+$/.test(name)) return false;
      const range = selection.getRangeAt(0), before = range.startContainer.nodeType === 3 ? range.startContainer.nodeValue.slice(0, range.startOffset) : '';
      run('insertHTML', (before && !/\s$/.test(before) ? ' ' : '') + `<span class="tag">#${quote(name)}</span>`);
    }
  }
  else if (command === 'link') {
    const anchor = element.closest('a[href]');
    if (anchor) selectAnchor(anchor);
    savedRange = getSelection().getRangeAt(0).cloneRange();
    linkInput.value = anchor ? anchor.getAttribute('href') : ''; hideBubble();
    holding = true; linkBar.hidden = false; linkInput.focus(); linkInput.select();
    return true;
  }
  else return false;
  sync(); reportState(); return true;
};
let plainShown = false;
window.marginRender = (text, canEdit, ack, force, plain) => {
  if (plain) {
    // Not Markdown: show the file's own text as it is, read-only.
    editable = false; source = text; plainShown = true; painted = false; mapped = false;
    const root = article(), pre = document.createElement('pre'), code = document.createElement('code');
    pre.className = 'plain'; code.textContent = text; pre.append(code);
    root.contentEditable = 'false'; root.classList.remove('editable'); root.replaceChildren(pre);
    observer.takeRecords(); return;
  }
  const was = editable; editable = !!canEdit;
  // A render older than the latest posted edit would clobber what is being typed.
  if (!force && !plainShown && ((ack || 0) < seq || (painted && text === source && was === editable))) return;
  plainShown = false; source = text; paint();
};
window.marginRoundTrip = text => {
  const tokens = marked.lexer(text), blocks = tokens.filter(token => token.type !== 'space');
  return {blocks:blocks.length, locked:blocks.filter(token => describe(token, tokens.links).locked).map(token => token.raw.slice(0, 40))};
};
