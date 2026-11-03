// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import "html/template"

// style is the pages' one stylesheet, allowed by its hash: large touch
// targets for a seven-inch screen and its on-screen keyboard.
const style = `body{background:#0b1418;color:#e8f1f2;font:1.25rem system-ui,sans-serif;margin:0;display:grid;place-items:center;min-height:90vh}
main{max-width:34rem;padding:1.5rem}h1{font-size:1.6rem;color:#7fd6d0}
input{font-size:1.5rem;padding:.5rem;width:100%;box-sizing:border-box;margin:.25rem 0 .75rem}
button{font-size:1.3rem;padding:.7rem 1.4rem;margin:.3rem .3rem .3rem 0;border-radius:.4rem;border:0;background:#2a9d8f;color:#fff}
button.quiet{background:#33444a}.notice{background:#3b2a12;padding:.6rem;border-radius:.4rem}
.warn{color:#ffb4a2}.code{font:1.1rem monospace;word-break:break-all;background:#162229;padding:.6rem}
.qr svg{width:16rem;height:16rem}dl{display:grid;grid-template-columns:auto 1fr;gap:.3rem 1rem}dt{color:#9fb3b8}
@media print{body{background:#fff;color:#000}button,form,.notice,.warn{display:none}}`

var pages = template.Must(template.New("page").Parse(`<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
{{if .Waiting}}<meta http-equiv="refresh" content="2">{{end}}
<title>CYFR</title><style>` + style + `</style>
<main>
{{if .Notice}}<p class="notice" role="status">{{.Notice}}</p>{{end}}
{{if .Waiting}}
<h1>CYFR is starting</h1>
<p>This screen opens CYFR once it answers. If it does not, run <code>cyfr up</code> in CYFR's directory; Ctrl+Alt+F2 opens a terminal.</p>
{{else if eq .Answer "answered"}}
<h1>Done</h1><p>This window closes by itself.</p><script>{{.Close}}</script>
{{else if or (eq .Page "setup") (eq .Page "restore")}}
{{range .Warn}}<p class="warn">{{.}}</p>{{end}}
{{if eq .Page "setup"}}<h1>Set up CYFR</h1>
<form method="post" action="/setup">
<label>Your name, yours for life<input name="name" autocomplete="off" autofocus required></label>
{{else}}<h1>Restore onto this box</h1>
<form method="post" action="/restore">
<label>Your recovery code<input name="code" autocomplete="off" autofocus required></label>
{{end}}
{{if .Digits}}
<label>Choose a six-digit PIN<input name="secret" type="password" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" autocomplete="off" required></label>
<label>The same PIN again<input name="again" type="password" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" autocomplete="off" required></label>
<p>The chip in this box keeps your PIN; it allows eight wrong tries, then one every ten minutes.</p>
{{else}}
<p>This box has no chip to keep a short PIN safe, so it uses this passphrase. Write it down:</p>
<p class="code">{{.Passphrase}}</p>
<label>The passphrase<input name="secret" type="password" autocomplete="off" required></label>
<label>The passphrase again<input name="again" type="password" autocomplete="off" required></label>
{{end}}
<button>{{if eq .Page "setup"}}Set up{{else}}Restore{{end}}</button>
</form>
{{else if eq .Page "finish"}}
<h1>Finish setting up</h1>
<p>This screen made its key, but CYFR's answer did not arrive. Enter your {{if .Digits}}PIN{{else}}passphrase{{end}} to finish with the same key.</p>
<form method="post" action="/finish">
<label>Your name, as you gave it<input name="name" autocomplete="off"></label>
<label>{{if .Digits}}PIN{{else}}Passphrase{{end}}<input name="secret" type="password" {{if .Digits}}inputmode="numeric" maxlength="6"{{end}} autocomplete="off" required></label>
<button>Finish</button></form>
{{else if eq .Page "locked"}}
<h1>CYFR is locked</h1>
<form method="post" action="/unlock">
<label>{{if .Digits}}PIN{{else}}Passphrase{{end}}<input name="secret" type="password" {{if .Digits}}inputmode="numeric" maxlength="6"{{end}} autocomplete="off" autofocus required></label>
<button>Unlock</button></form>
{{if .Kit}}
<h1>Restored from a backup?</h1>
<p>A restore of CYFR from a backup suspends this screen. Your recovery code brings it back.</p>
<form method="post" action="/kit">
<label>Your recovery code<input name="code" autocomplete="off" required></label>
<label>{{if .Digits}}PIN{{else}}Passphrase{{end}}<input name="secret" type="password" {{if .Digits}}inputmode="numeric" maxlength="6"{{end}} autocomplete="off" required></label>
<button>Bring this screen back</button></form>
{{end}}
{{range .Warn}}<p class="warn">{{.}}</p>{{end}}
{{else if eq .Page "name"}}
<h1>Your name</h1>
<form method="post" action="/name"><label>A name for life<input name="name" value="{{.Name}}" autocomplete="off" required></label><button>Take it</button></form>
{{else if eq .Page "recovery"}}
<h1>Your recovery code</h1>
<p>If this box is ever lost, this code brings you back. Keep it off this box: scan it, or print it.</p>
<div class="qr">{{.QR}}</div>
<p class="code">{{.Recovery.Code}}</p>
<button id="print" type="button" class="quiet">Print</button><script>{{.Print}}</script>
<form method="post" action="/saved"><button autofocus>I saved it</button></form>
{{else if eq .Page "confirm"}}
<h1>Confirm on this screen</h1>
<p>CYFR asks to confirm <b>{{.Confirm.Operation}}</b>:</p>
<dl>{{range .Fields}}<dt>{{index . 0}}</dt><dd>{{index . 1}}</dd>{{end}}</dl>
<form method="post" action="/confirm/decide">
<input type="hidden" name="ref" value="{{.Confirm.Ref}}">
<label>{{if .Digits}}PIN{{else}}Passphrase{{end}}, again<input name="secret" type="password" {{if .Digits}}inputmode="numeric" maxlength="6"{{end}} autocomplete="off"></label>
<button name="decision" value="confirm">Confirm</button>
<button name="decision" value="cancel" class="quiet" formnovalidate>Cancel</button>
</form>
{{else}}
<h1>CYFR is unlocked</h1>
<form method="post" action="/open"><button autofocus>Open CYFR</button></form>
<form method="post" action="/lock"><button class="quiet">Lock</button></form>
{{end}}
</main></html>`))
