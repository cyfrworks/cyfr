// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"crypto/sha256"
	"encoding/base64"
)

// The chooser's one style and one script, each allowed by its hash alone.
// The script keeps the run token from the first address's fragment in
// sessionStorage, private to this origin, takes it off the address, where
// it leaves the notice alone so that a reload still shows it, and sends
// the token with each request; it writes answers as text, never markup.
// With a CYFR open it goes on to the device's pages by itself only when
// it has nothing to tell: with a notice it stays, as it does on the
// passkey road, until the person takes a way on.
const (
	bootstrapStyle = `body{background:#0b1418;color:#e8f1f2;font:1.25rem system-ui,sans-serif;margin:0;display:grid;place-items:center;min-height:90vh}
main{max-width:34rem;padding:1rem}label{display:block;margin:1rem 0}input{display:block;width:100%;font:inherit;padding:.5rem;margin-top:.25rem;box-sizing:border-box}
button{font:inherit;padding:.5rem 1rem;margin:.5rem .5rem 0 0}.warn{color:#ffb4a2}.quiet{background:none;color:inherit;border:1px solid #567}.code{font-family:monospace;word-break:break-all}`
	bootstrapScript = `const s=sessionStorage,f=new URLSearchParams(location.hash.slice(1)),$=i=>document.getElementById(i);
if(f.get("token"))s.setItem("token",f.get("token"));history.replaceState(null,"",location.pathname+(f.get("notice")?"#notice="+f.get("notice"):""));
const notices={company:"This CYFR requires company sign-in. Open its address in a browser to continue. The CYFR app does not support company sign-in yet.",
unconfirmed:"CYFR locked, but the CYFR did not confirm that it signed this computer out. That sign-in ends when it expires, or when you sign it out under Settings, Keys on your account."};
let asked=null;
function say(t){$("notice").textContent=t||""}
function post(p,b){return fetch(p,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(Object.assign({token:s.getItem("token")||""},b))}).then(r=>r.ok?r.json():{error:"This page is not the app's own. Quit the app and open it again."},()=>({error:"The app's connection stopped. Quit it and open it again."}))}
function show(a,told){say(a.error||told);asked=a.confirm?a:null;const stay=!!(a.passkey||a.next&&told);$("confirm").hidden=!asked;$("choose").hidden=!!asked||stay;$("road").hidden=!stay;
if(asked){$("home").textContent=a.home;$("service").textContent=a.confirm}
if(stay){$("open").textContent=a.home;$("passkey").hidden=$("either").hidden=!a.passkey;$("passkey").onclick=()=>location.assign(a.passkey);$("words").onclick=()=>location.assign(a.next)}
else if(a.next)location.replace(a.next)}
post("/bootstrap/state",{}).then(a=>{if(a.home)$("address").value=a.home;$("warning").textContent=a.warning||"";show(a,(f.get("notice")||"").split(",").map(n=>notices[n]).filter(Boolean).join(" "))});
$("connect").addEventListener("submit",e=>{e.preventDefault();say("Connecting\u2026");post("/bootstrap/connect",{address:$("address").value}).then(show)});
$("approve").addEventListener("click",()=>{say("Connecting\u2026");post("/bootstrap/approve",{home:asked.home,directory:asked.confirm}).then(show)});
$("decline").addEventListener("click",()=>{show({});say("Nothing was sent to that account service.")});`
)

var bootstrapPolicy = "default-src 'none'; script-src " + hash(bootstrapScript) + "; style-src " + hash(bootstrapStyle) +
	"; connect-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'"

func hash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return "'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) + "'"
}

const bootstrapPage = `<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>CYFR</title><style>` + bootstrapStyle + `</style>
<main>
<section id="choose">
<h1>Connect to a CYFR</h1>
<form id="connect"><label>Its address<input id="address" autocomplete="url" placeholder="https://cyfr.example.com" autofocus required></label>
<button>Connect</button></form>
<p>Setting up CYFR on this computer comes in the next version of this app.</p>
</section>
<section id="road" hidden>
<h1>Sign in to the CYFR at <span class="code" id="open"></span></h1>
<button id="passkey">Sign in with your passkey</button>
<p id="either">No passkey on this computer, or you would rather not use one? Use this computer's own key, opened with its PIN or six-word passphrase.</p>
<button id="words" class="quiet">Use this computer's key</button>
</section>
<section id="confirm" hidden>
<h1>Check the account service</h1>
<p>The CYFR at <b class="code" id="home"></b> signs you in at the account service</p>
<p class="code" id="service"></p>
<p>That is not cyfr.run. Go on only if you expected this address.</p>
<button id="approve">Go on</button><button id="decline" class="quiet">Cancel</button>
</section>
<p id="notice" role="status"></p>
<p id="warning" class="warn" role="status"></p>
</main><script>` + bootstrapScript + `</script></html>`
