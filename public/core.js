export function paragraphAt(text, cursor) {
  cursor = Math.max(0, Math.min(cursor, text.length));
  const lines = text.split('\n');
  const offsets = [];
  let position = 0;
  let fence = null;
  let target = null;
  for (const [index, line] of lines.entries()) {
    offsets.push(position);
    const match = line.match(/^\s{0,3}(`{3,}|~{3,})/);
    const inside = fence !== null;
    if (match) {
      if (!fence) fence = match[1];
      else if (match[1][0] === fence[0] && match[1].length >= fence.length && /^\s*[`~]+\s*$/.test(line)) fence = null;
    }
    if (cursor >= position && cursor <= position + line.length) {
      if (inside || match || !line.trim() || /^( {4}|\t)/.test(line)) return null;
      target = index;
      break;
    }
    position += line.length + 1;
  }
  if (target === null) return null;
  let first = target;
  let last = target;
  while (first > 0 && lines[first - 1].trim()) first--;
  while (last < lines.length - 1 && lines[last + 1].trim()) last++;
  const start = offsets[first];
  const end = offsets[target] + lines.slice(target, last + 1).join('\n').length;
  const paragraph = text.slice(start, end);
  if (!paragraph.trim() || paragraph.length > 6000 || /(^|\n)\s*(`{3,}|~{3,})/.test(paragraph)) return null;
  return {start, end, text: paragraph};
}

export function applySuggestion(text, revision, suggestion) {
  if (!suggestion || revision !== suggestion.revision || text.slice(suggestion.start, suggestion.end) !== suggestion.text) return null;
  return text.slice(0, suggestion.start) + suggestion.replacement + text.slice(suggestion.end);
}

export function safeFilename(name) {
  const base = String(name || 'Untitled.md').split(/[\\/]/).pop().replace(/[\u0000-\u001f<>:"|?*]/g, '').trim() || 'Untitled.md';
  return /\.(md|markdown|txt)$/i.test(base) ? base : base + '.md';
}

export function selectionMatches(range, start, end) {
  return Boolean(range && start >= range.start && end <= range.end);
}

export function decodeDocument(bytes) {
  const bom = bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
  const raw = new TextDecoder('utf-8', {fatal: true}).decode(bom ? bytes.slice(3) : bytes);
  const eol = raw.match(/\r\n|\r|\n/)?.[0] || '\n';
  return {text: raw.replace(/\r\n?/g, '\n'), format: {eol, bom}};
}

export function encodeDocument(text, format = {}) {
  const eol = ['\n','\r\n','\r'].includes(format.eol) ? format.eol : '\n';
  return (format.bom ? '\ufeff' : '') + text.replace(/\r\n?/g, '\n').replace(/\n/g, eol);
}
