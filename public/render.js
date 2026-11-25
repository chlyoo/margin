import {marked} from '/vendor/marked.js';
import DOMPurify from '/vendor/purify.js';

const renderer = new marked.Renderer();
renderer.code = ({text, lang}) => {
  const name = (lang || '').split(/\s/)[0].replace(/[^\w-]/g, '');
  const grammar = window.Prism?.languages[name];
  const code = grammar ? window.Prism.highlight(text, grammar, name) : text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return `<pre><code class="language-${name || 'text'}">${code}</code></pre>`;
};
marked.use({renderer, gfm: true, breaks: false});

export function renderMarkdown(text, allowImages = false) {
  const fragment = DOMPurify.sanitize(marked.parse(text), {
    RETURN_DOM_FRAGMENT: true,
    USE_PROFILES: {html: true},
    FORBID_TAGS: ['style', 'iframe', 'form', 'video', 'audio', 'source'],
    FORBID_ATTR: ['style', 'srcset', 'id', 'name', 'background', 'poster', 'autofocus', 'contenteditable', 'tabindex'],
  });
  for (const element of fragment.querySelectorAll('[src]:not(img)')) element.removeAttribute('src');
  for (const input of fragment.querySelectorAll('input')) {
    if (input.type !== 'checkbox') input.remove();
    else input.disabled = true;
  }
  for (const anchor of fragment.querySelectorAll('a')) {
    const href = anchor.getAttribute('href') || '';
    if (href.startsWith('#')) {
      anchor.removeAttribute('href');
    } else {
      try {
        const url = new URL(href);
        if (!['https:', 'http:', 'mailto:'].includes(url.protocol)) anchor.removeAttribute('href');
        else {anchor.target = '_blank'; anchor.rel = 'noopener noreferrer';}
      } catch {anchor.removeAttribute('href');}
    }
  }
  for (const image of fragment.querySelectorAll('img')) {
    const src = image.getAttribute('src') || '';
    if (!allowImages || !/^https?:\/\//i.test(src)) {
      const placeholder = document.createElement('span');
      placeholder.className = 'image-placeholder';
      placeholder.textContent = `▧ ${image.alt || '이미지'} · ${allowImages ? '주소를 확인해 주세요' : '이미지 표시 꺼짐'}`;
      image.replaceWith(placeholder);
    } else {image.loading = 'lazy'; image.referrerPolicy = 'no-referrer';}
  }
  return fragment;
}
