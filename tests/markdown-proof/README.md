# The markdown proof

`run.sh` proves, on the browser harness's Playwright image
(`tests/browser/`), what the console's markdown hook
(`apps/cyfr/assets/js/hooks/markdown_content.js`) puts in the page: the
markup marked makes of a message, after DOMPurify has sanitized it with the
hook's policy. DOMPurify sanitizes against a browser's own DOM, and Node
has none, so the JavaScript suite pins the hook's parse step alone
(`apps/cyfr/assets/test/markdown/`) and the sanitized result is proved here,
in Chromium.

No release and no server run. `markdown.mjs` opens a page of its own,
`http://markdown.test/`, whose requests it answers itself: the page, and
the hook and the vendored modules it imports, read from the console's
assets, which `playwright_run` mounts read-only at `/assets`. Each case sets
the element's `data-raw-content` and runs the hook's `mounted` callback,
then `updated` for every later case, as LiveView does, and compares the
element's `innerHTML` with the expected markup exactly:

- lists, nested lists, paragraphs with their line breaks, and trailing
  blank lines;
- task items, tight, loose and nested, whose checkbox inputs the sanitizer
  removes;
- a link, which opens apart (`target="_blank"`, `rel="noopener noreferrer"`);
- a script element, an event handler attribute, a `javascript:` link, a
  form with its controls and an iframe, each removed, a removed element's
  text kept.

The image the handler case offers is answered 404, so it fails and a
handler left on it would run; the proof waits for that image's error before
it reads whether anything ran. A render the hook catches and logs, and any
other console error, fails the run.

Usage: `tests/markdown-proof/run.sh`. It writes `markdown.json`, each case
with its expected and actual markup, into `MARKDOWN_OUT` (default: a
scratch directory removed when the run ends).
