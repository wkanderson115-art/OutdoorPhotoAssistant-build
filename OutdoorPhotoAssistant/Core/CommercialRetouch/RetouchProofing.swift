import Foundation

// A self-contained, offline customer proofing page: one index.html with inline
// CSS and JavaScript, no CDN, no backend, no network. It has to work when the
// customer opens the ZIP on an airplane, so every byte the page needs is inside
// the file, and every filename that reaches the page is escaped first.

enum RetouchProofingError: LocalizedError {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let name):
            return "写入失败：\(name)"
        }
    }
}

/// Builds a self-contained, offline customer proofing page (no network, no backend).
enum RetouchProofingPage {
    struct Item {
        /// Path of the image relative to the page (`../web/xxx.jpg`), already
        /// logical — the builder percent-encodes it for `src` and shows the last
        /// path component as the file name the customer copies.
        var fileName: String
        var title: String
        var width: Int
        var height: Int
    }

    /// Writes `index.html` next to nothing else: everything is inlined.
    static func build(jobName: String, items: [Item], outputURL: URL, watermarkNote: String?) throws {
        let html = page(jobName: jobName, items: items, watermarkNote: watermarkNote)
        guard let data = html.data(using: .utf8) else {
            throw RetouchProofingError.writeFailed(outputURL.lastPathComponent)
        }
        let folder = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw RetouchProofingError.writeFailed(outputURL.lastPathComponent)
        }
        // Same discipline as the image writer: never publish a half-written page.
        let temporary = folder.appendingPathComponent(UUID().uuidString + ".tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.moveItem(at: temporary, to: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw RetouchProofingError.writeFailed(outputURL.lastPathComponent)
        }
    }

    /// Pure string assembly, split out so it can be unit tested without disk.
    static func page(jobName: String, items: [Item], watermarkNote: String?) -> String {
        var cards: [String] = []
        cards.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            let number = offset + 1
            let title = escapeHTML(item.title.isEmpty ? item.fileName : item.title)
            let source = escapeHTML(encodePath(item.fileName))
            let filePart = item.fileName.split(separator: "/").last.map(String.init) ?? item.fileName
            let copyName = escapeHTML(filePart)
            let width = max(1, item.width)
            let height = max(1, item.height)
            cards.append("""
            <li class="card" data-file="\(copyName)" data-title="\(title)">
              <button class="open" type="button" data-full="\(source)" aria-label="点击放大 \(title)">
                <img src="\(source)" width="\(width)" height="\(height)" alt="\(title)" loading="lazy" decoding="async">
              </button>
              <span class="badge" aria-hidden="true">\(number)</span>
              <div class="meta">
                <span class="name" dir="auto">\(title)</span>
                <button class="pick" type="button" aria-pressed="false">选片</button>
              </div>
            </li>
            """)
        }

        let trimmedNote = (watermarkNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let noteBlock = trimmedNote.isEmpty
            ? ""
            : "\n  <p class=\"note\" dir=\"auto\">\(escapeHTML(trimmedNote))</p>"
        let safeJob = escapeHTML(jobName.isEmpty ? "选片" : jobName)
        let total = items.count

        return #"""
<!DOCTYPE html>
<html lang="zh-CN" dir="ltr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="robots" content="noindex, nofollow">
<title>\#(safeJob) · 选片</title>
<style>
:root {
  color-scheme: light dark;
  --bg: #101114;
  --panel: #191b20;
  --line: #2a2d34;
  --text: #f2f3f5;
  --muted: #9aa0aa;
  --accent: #f5c451;
  --picked: #3ddc84;
}
@media (prefers-color-scheme: light) {
  :root {
    --bg: #f6f7f9;
    --panel: #ffffff;
    --line: #e2e5ea;
    --text: #16181d;
    --muted: #666e7a;
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  background: var(--bg);
  color: var(--text);
  font: 15px/1.5 -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
  -webkit-text-size-adjust: 100%;
  padding-block-end: env(safe-area-inset-bottom, 0px);
}
.bar {
  position: sticky;
  inset-block-start: 0;
  z-index: 2;
  display: flex;
  flex-wrap: wrap;
  gap: 8px 12px;
  align-items: center;
  justify-content: space-between;
  padding-block: 12px;
  padding-inline: 16px;
  background: var(--panel);
  border-block-end: 1px solid var(--line);
}
h1 { margin: 0; font-size: 17px; font-weight: 600; }
.hint { margin: 2px 0 0; font-size: 12px; color: var(--muted); }
.actions { display: flex; align-items: center; gap: 10px; }
.count { font-size: 13px; color: var(--muted); white-space: nowrap; }
button { font: inherit; color: inherit; cursor: pointer; border-radius: 999px; }
#copy {
  border: 1px solid var(--line);
  background: var(--accent);
  color: #16181d;
  padding: 8px 14px;
  font-weight: 600;
}
.note {
  margin: 12px 16px 0;
  padding: 8px 12px;
  border: 1px solid var(--line);
  border-radius: 10px;
  font-size: 12px;
  color: var(--muted);
  background: var(--panel);
}
main { padding: 14px 16px 40px; }
.grid {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  gap: 12px;
  grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
}
.card {
  position: relative;
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 12px;
  overflow: hidden;
}
.card.picked { border-color: var(--picked); }
.open { display: block; width: 100%; padding: 0; border: 0; background: none; }
.open img {
  display: block;
  width: 100%;
  height: auto;
  aspect-ratio: 3 / 2;
  object-fit: cover;
  background: #000;
}
.badge {
  position: absolute;
  inset-block-start: 8px;
  inset-inline-start: 8px;
  min-width: 22px;
  padding: 1px 6px;
  border-radius: 999px;
  background: rgba(0, 0, 0, 0.62);
  color: #ffffff;
  font-size: 12px;
  text-align: center;
}
.meta {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  padding: 8px 10px;
}
.name {
  font-size: 12px;
  color: var(--muted);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.pick { border: 1px solid var(--line); background: transparent; padding: 4px 10px; font-size: 12px; }
.card.picked .pick { background: var(--picked); border-color: var(--picked); color: #08150d; font-weight: 600; }
.lightbox {
  position: fixed;
  inset: 0;
  z-index: 10;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.93);
}
.lightbox[hidden] { display: none; }
.lightbox img { max-width: 100vw; max-height: 82vh; object-fit: contain; }
.lightbox-caption {
  position: absolute;
  inset-block-end: 18px;
  inset-inline: 0;
  text-align: center;
  font-size: 12px;
  color: #d8dbe0;
}
.lightbox button {
  position: absolute;
  border: 0;
  background: rgba(255, 255, 255, 0.16);
  color: #ffffff;
  width: 40px;
  height: 40px;
  font-size: 18px;
}
#lightbox-close { inset-block-start: 12px; inset-inline-end: 12px; }
#lightbox-prev { inset-block-start: 46%; inset-inline-start: 10px; }
#lightbox-next { inset-block-start: 46%; inset-inline-end: 10px; }
.clipboard { position: absolute; inline-size: 1px; block-size: 1px; opacity: 0; pointer-events: none; border: 0; padding: 0; }
@media (min-width: 900px) {
  .grid { grid-template-columns: repeat(auto-fill, minmax(210px, 1fr)); }
}
</style>
</head>
<body data-job="\#(safeJob)">
<header class="bar">
  <div class="brand">
    <h1 dir="auto">\#(safeJob)</h1>
    <p class="hint">点击放大 · 勾选后点“复制选片结果”</p>
  </div>
  <div class="actions">
    <span class="count" id="count">已选 0 张</span>
    <button id="copy" type="button">复制选片结果</button>
  </div>
</header>\#(noteBlock)
<main>
  <p class="hint" style="margin-block-end: 10px;">共 \#(total) 张 · 编号即文件名顺序</p>
  <ul class="grid" id="grid">
\#(cards.joined(separator: "\n"))
  </ul>
  <noscript><p class="note">当前浏览器禁用了 JavaScript，仍可逐张查看，但无法记录勾选。</p></noscript>
</main>
<textarea class="clipboard" id="clipboard" readonly aria-hidden="true"></textarea>
<div class="lightbox" id="lightbox" hidden aria-hidden="true" role="dialog" aria-modal="true" aria-label="大图预览">
  <button id="lightbox-close" type="button" aria-label="关闭">×</button>
  <button id="lightbox-prev" type="button" aria-label="上一张">‹</button>
  <img id="lightbox-image" alt="">
  <button id="lightbox-next" type="button" aria-label="下一张">›</button>
  <p class="lightbox-caption" id="lightbox-caption" dir="auto"></p>
</div>
<script>
(function () {
  'use strict';
  var grid = document.getElementById('grid');
  if (!grid) { return; }
  var cards = Array.prototype.slice.call(grid.querySelectorAll('.card'));
  var countLabel = document.getElementById('count');
  var copyButton = document.getElementById('copy');
  var lightbox = document.getElementById('lightbox');
  var lightboxImage = document.getElementById('lightbox-image');
  var lightboxCaption = document.getElementById('lightbox-caption');
  var scratch = document.getElementById('clipboard');
  var job = document.body.getAttribute('data-job') || 'job';
  var storageKey = 'opa-proofing-selection:' + job;
  var selected = Object.create(null);
  var current = -1;

  function isPicked(name) {
    return !!(name && Object.prototype.hasOwnProperty.call(selected, name));
  }

  function store() {
    try { return window.localStorage; } catch (error) { return null; }
  }

  function load() {
    var box = store();
    if (!box) { return; }
    var raw = null;
    try { raw = box.getItem(storageKey); } catch (error) { raw = null; }
    if (!raw) { return; }
    var parsed = null;
    try { parsed = JSON.parse(raw); } catch (error) { parsed = null; }
    if (!parsed || typeof parsed.length !== 'number') { return; }
    for (var i = 0; i < parsed.length; i += 1) {
      selected[String(parsed[i])] = true;
    }
  }

  function names() {
    var list = [];
    for (var i = 0; i < cards.length; i += 1) {
      var name = cards[i].getAttribute('data-file');
      if (isPicked(name)) { list.push(name); }
    }
    return list;
  }

  function save() {
    var box = store();
    if (!box) { return; }
    try { box.setItem(storageKey, JSON.stringify(names())); } catch (error) { /* 隐私模式忽略 */ }
  }

  function refresh() {
    var total = 0;
    for (var i = 0; i < cards.length; i += 1) {
      var card = cards[i];
      var name = card.getAttribute('data-file');
      var on = isPicked(name);
      if (on) { total += 1; card.classList.add('picked'); } else { card.classList.remove('picked'); }
      card.setAttribute('aria-selected', on ? 'true' : 'false');
      var pick = card.querySelector('.pick');
      if (pick) {
        pick.setAttribute('aria-pressed', on ? 'true' : 'false');
        pick.textContent = on ? '已选' : '选片';
      }
    }
    if (countLabel) { countLabel.textContent = '已选 ' + total + ' 张'; }
  }

  function toggle(name) {
    if (!name) { return; }
    if (isPicked(name)) { delete selected[name]; } else { selected[name] = true; }
    refresh();
    save();
  }

  function flash(message) {
    if (!copyButton) { return; }
    if (!copyButton.getAttribute('data-label')) {
      copyButton.setAttribute('data-label', copyButton.textContent || '复制选片结果');
    }
    copyButton.textContent = message;
    window.setTimeout(function () {
      copyButton.textContent = copyButton.getAttribute('data-label') || '复制选片结果';
    }, 1800);
  }

  function fallbackCopy(text, done) {
    if (!scratch) { done(); return; }
    scratch.value = text;
    scratch.focus();
    scratch.select();
    try { scratch.setSelectionRange(0, text.length); } catch (error) { /* 旧版 Safari */ }
    try { document.execCommand('copy'); } catch (error) { /* 忽略 */ }
    done();
  }

  function copyResult() {
    var list = names();
    var text = list.join('\n');
    var done = function () {
      flash(list.length ? ('已复制 ' + list.length + ' 张') : '未选片');
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text, done); });
      return;
    }
    fallbackCopy(text, done);
  }

  function openAt(index) {
    if (!lightbox || !lightboxImage) { return; }
    if (index < 0 || index >= cards.length) { return; }
    var card = cards[index];
    var opener = card.querySelector('.open');
    var source = opener ? opener.getAttribute('data-full') : null;
    if (!source) { return; }
    current = index;
    lightboxImage.setAttribute('src', source);
    lightboxImage.setAttribute('alt', card.getAttribute('data-title') || '');
    if (lightboxCaption) { lightboxCaption.textContent = card.getAttribute('data-title') || ''; }
    lightbox.hidden = false;
    lightbox.setAttribute('aria-hidden', 'false');
  }

  function closeLightbox() {
    if (!lightbox) { return; }
    lightbox.hidden = true;
    lightbox.setAttribute('aria-hidden', 'true');
    if (lightboxImage) { lightboxImage.removeAttribute('src'); }
    current = -1;
  }

  function step(delta) {
    if (current < 0 || cards.length === 0) { return; }
    openAt((current + delta + cards.length) % cards.length);
  }

  for (var i = 0; i < cards.length; i += 1) {
    (function (index) {
      var card = cards[index];
      var opener = card.querySelector('.open');
      if (opener) {
        opener.addEventListener('click', function () { openAt(index); });
      }
      var pick = card.querySelector('.pick');
      if (pick) {
        pick.addEventListener('click', function () { toggle(card.getAttribute('data-file')); });
      }
    })(i);
  }

  var closeButton = document.getElementById('lightbox-close');
  if (closeButton) { closeButton.addEventListener('click', closeLightbox); }
  var prevButton = document.getElementById('lightbox-prev');
  if (prevButton) { prevButton.addEventListener('click', function () { step(-1); }); }
  var nextButton = document.getElementById('lightbox-next');
  if (nextButton) { nextButton.addEventListener('click', function () { step(1); }); }
  if (lightbox) {
    lightbox.addEventListener('click', function (event) {
      if (event.target === lightbox) { closeLightbox(); }
    });
  }
  document.addEventListener('keydown', function (event) {
    if (current < 0) { return; }
    if (event.key === 'Escape') { closeLightbox(); }
    if (event.key === 'ArrowRight') { step(1); }
    if (event.key === 'ArrowLeft') { step(-1); }
  });
  if (copyButton) { copyButton.addEventListener('click', copyResult); }

  load();
  refresh();
})();
</script>
</body>
</html>
"""#
    }

    // MARK: - Escaping

    /// Minimal HTML escaper: a file name or shoot name can never open a tag,
    /// close an attribute or start a script.
    static func escapeHTML(_ value: String) -> String {
        var escaped = String()
        escaped.reserveCapacity(value.count + 16)
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Percent-encodes every path segment but keeps "/" so a relative path such
    /// as `../web/IMG 0001.jpg` becomes a valid `src` without escaping the slash.
    static func encodePath(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed
            .subtracting(CharacterSet(charactersIn: "/?#%"))
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        return segments.map { segment -> String in
            String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
        }.joined(separator: "/")
    }
}
