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
<main{{if .Proof}} data-proof="{{.Proof}}"{{end}}{{if .To}} data-to="{{.To}}"{{end}}>
{{if .Notice}}<p class="notice" role="status">{{.Notice}}</p>{{end}}
{{if .Waiting}}
<h1>CYFR is starting</h1>
<p>This device opens CYFR once it answers. If it does not, run <code>cyfr up</code> in CYFR's directory; Ctrl+Alt+F2 opens a terminal.</p>
{{else if eq .Answer "answered"}}
<h1>Done</h1><p>This window closes by itself.</p><script>{{.Close}}</script>
{{else if eq .Answer "ended"}}
<h1>Add a passkey to your account</h1>
{{else if eq .Page "setup"}}
{{range .Warn}}<p class="warn">{{.}}</p>{{end}}
<h1>Set up CYFR</h1>
{{if .Passphrase}}<p>This device has no chip it can use to keep a short PIN safe, so it uses this passphrase. Write it down now: this device shows it this once.</p>
<p class="code">{{.Passphrase}}</p>
{{else if not .Digits}}{{if .Drawn}}<p>Type the passphrase this device showed you. If you did not write it down, show a new one: the one shown before stops working.</p>
{{else}}<p>This device has no chip it can use to keep a short PIN safe, so it uses a passphrase, which this device shows once. Have something to write it down on.</p>{{end}}
<form method="post" action="/passphrase">{{template "proof"}}<button{{if not .Drawn}} autofocus{{end}}>Show {{if .Drawn}}a new{{else}}the{{end}} passphrase</button></form>
{{end}}
{{if or .Digits .Drawn}}<form method="post" action="/setup">{{template "proof"}}
<label>Your name, yours for life<input name="name" autocomplete="off" autofocus required></label>
{{template "secret" .}}
{{template "terms" .}}
<button>Set up</button>
</form>
<h1>Already have an account?</h1>
<p>Add this device to it instead, then approve it on another device of yours.</p>
<form method="post" action="/make">{{template "proof"}}
{{template "secret" .}}
<button class="quiet">Add this device to my account</button>
</form>{{end}}
{{else if eq .Page "enroll"}}
<h1>Add this device to your account</h1>
<p>On another device of yours, scan this code or open the address below. Approve only if that device shows <b>{{.Code}}</b> at the account service <b>{{.Service}}</b>.</p>
<div class="qr">{{.QR}}</div>
<p class="code">{{.AddURL}}</p>
<form method="post" action="/enroll">{{template "proof"}}<label>Your name: @<input name="name" autocomplete="off" required></label><button>I approved it</button></form>
<h1>No account yet?</h1>
<form method="post" action="/create">{{template "proof"}}
<label>Your name, yours for life<input name="name" autocomplete="off" required></label>
{{template "typed" .}}
{{template "terms" .}}
<button class="quiet">Make my account</button></form>
{{else if eq .Page "recovery"}}
<h1>Your recovery code</h1>
<p>If you ever lose your devices, this code brings your account @{{.Name}} back. Keep it off this device: scan it, or print it.</p>
{{if .RecoveryCode}}<div class="qr">{{.QR}}</div>
<p class="code">{{.RecoveryCode}}</p>
<button id="print" type="button" class="quiet">Print</button><script>{{.Print}}</script>
{{else}}<p>The code shows only on the page the {{if .Digits}}PIN{{else}}passphrase{{end}} was typed on.</p>
{{if .Reveal}}<form id="reveal" method="post" action="/recovery">{{template "proof"}}</form>{{end}}{{end}}
<form method="post" action="/saved">{{template "proof"}}<button autofocus>I saved it</button></form>
{{else if eq .Page "account"}}
<h1>Your account is not finished</h1>
<p>Nothing is lost: try again.</p>
<form method="post" action="/saved">{{template "proof"}}{{if .Accept}}{{template "terms" .}}{{end}}<button autofocus>Try again</button></form>
{{else if eq .Page "resume"}}
<h1>Finish your account</h1>
<p>This device began making the account @{{.Name}}. Type its recovery code to finish it.</p>
<form method="post" action="/resume">{{template "proof"}}<label>Recovery code<input name="code" type="password" autocomplete="off" autofocus required></label><button>Finish</button></form>
{{else if eq .Page "locked"}}
<h1>CYFR is locked</h1>
<form method="post" action="/unlock">{{template "proof"}}
{{template "typed" .}}
<button>Unlock</button></form>
{{range .Warn}}<p class="warn">{{.}}</p>{{end}}
{{else if eq .Page "name"}}
<h1>Your name</h1>
<form method="post" action="/name">{{template "proof"}}<label>A name for life<input name="name" value="{{.Name}}" autocomplete="off" required></label><button>Take it</button></form>
{{else if and (eq .Page "confirm") (not .Confirm)}}
<h1>A confirmation is open</h1>
<p>It is shown in the window that asked for it.</p>
{{else if eq .Page "confirm"}}
<h1>Confirm on this device</h1>
<p>CYFR asks to confirm <b>{{.Confirm.Operation}}</b>:</p>
<dl>{{range .Fields}}<dt>{{index . 0}}</dt><dd>{{index . 1}}</dd>{{end}}</dl>
<form method="post" action="/confirm/decide">{{template "proof"}}
<input type="hidden" name="ref" value="{{.Confirm.Ref}}">
{{template "again" .}}
<button name="decision" value="confirm">Confirm</button>
<button name="decision" value="cancel" class="quiet" formnovalidate>Cancel</button>
</form>
{{else if and (eq .Page "passkey") (not .Passkey)}}
<h1>A passkey request is open</h1>
<p>It is shown in the window that asked for it.</p>
{{else if eq .Page "passkey"}}
<h1>Add a passkey to your account</h1>
<p>A browser asks to add a passkey to your account. Approve it only if that browser shows this same code:</p>
<p class="code">{{.Passkey.Code}}</p>
<form method="post" action="/passkey/decide">{{template "proof"}}
<input type="hidden" name="ref" value="{{.Passkey.Ref}}">
<input type="hidden" name="key" value="{{.Passkey.Digest}}">
{{template "again" .}}
<button name="decision" value="approve">Approve</button>
<button name="decision" value="cancel" class="quiet" formnovalidate>Cancel</button>
</form>
{{else}}
<h1>CYFR is unlocked</h1>
<form method="post" action="/open">{{template "proof"}}<button autofocus>Open CYFR</button></form>
<form method="post" action="/lock">{{template "proof"}}<button class="quiet">Lock</button></form>
{{end}}
</main><script>{{.Keep}}</script></html>
{{define "secret"}}{{if .Digits}}
<label>Choose a six-digit PIN<input name="secret" type="password" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" autocomplete="off" required></label>
<label>The same PIN again<input name="again" type="password" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" autocomplete="off" required></label>
<p>The chip in this device keeps your PIN; it allows eight wrong tries, then one every ten minutes.</p>
{{else}}
<label>The passphrase<input name="secret" type="password" autocomplete="off" required></label>
<label>The passphrase again<input name="again" type="password" autocomplete="off" required></label>
{{end}}{{end}}
{{define "again"}}<label>{{if .Digits}}PIN{{else}}Passphrase{{end}}, again<input name="secret" type="password" {{if .Digits}}inputmode="numeric" maxlength="6"{{end}} autocomplete="off"></label>{{end}}
{{define "proof"}}<input type="hidden" name="proof">{{end}}
{{define "typed"}}<label>{{if .Digits}}PIN{{else}}Passphrase{{end}}<input name="secret" type="password" {{if .Digits}}inputmode="numeric" maxlength="6"{{end}} autocomplete="off" autofocus required></label>{{end}}
{{define "terms"}}{{if .Terms}}<label><input type="checkbox" name="accept" value="yes"> I accept the terms at {{.Terms}}</label>{{end}}{{end}}`))
