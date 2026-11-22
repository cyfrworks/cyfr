// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"crypto/sha256"
	"encoding/base64"
)

// The chooser's one style and one script, each allowed by its hash alone.
// The script keeps the run token from the first address's fragment in
// sessionStorage, private to this origin, and puts it back with each
// answer, since main may clear that storage while a Connect waits; it
// takes everything off the address, and sends the token with each
// request; it writes answers as text, never markup.
// What main says, the road and the notices, is read from an address that
// carries a run token alone, which main's own loads do and no page's can
// (a wrong one is refused above anything it says). It is kept in this
// entry of the history, where no page of another origin writes: a reload
// of main's load still shows it, and coming back to the entry by history,
// as a page can make the window do, shows the road and no notice.
// On the passkey road the script
// connects the CYFR remembered by itself as the app starts, leaves a CYFR
// just connected to main, which opens it at its root, and asks main by
// addresses main alone answers to connect to another and, where main says
// the CYFR's page did not load, to open that CYFR again.
// With a CYFR open it goes on to the device's pages by itself only when
// it has nothing to tell (a notice main put in the address, or one
// cyfr's answer names): with a notice it stays, as it does on the
// passkey road, until the person takes a way on.
const (
	bootstrapStyle = `body{background:#0b1418;color:#e8f1f2;font:1.25rem system-ui,sans-serif;margin:0;display:grid;place-items:center;min-height:90vh}
main{max-width:34rem;padding:1rem}label{display:block;margin:1rem 0}input{display:block;width:100%;font:inherit;padding:.5rem;margin-top:.25rem;box-sizing:border-box}
button{font:inherit;padding:.5rem 1rem;margin:.5rem .5rem 0 0}.quiet{background:none;color:inherit;border:1px solid #567}.code{font-family:monospace;word-break:break-all}`
	bootstrapScript = `const s=sessionStorage,f=new URLSearchParams(location.hash.slice(1)),$=i=>document.getElementById(i);
const token=f.get("token")||s.getItem("token")||"",was=history.state||{},reloaded=(performance.getEntriesByType("navigation")[0]||{}).type==="reload";
const main=f.get("token")?{road:f.get("road"),told:(f.get("notice")||"").split(",")}:{road:was.road,told:reloaded&&was.told||[]},passkey=main.road==="passkey";
s.setItem("token",token);history.replaceState(main,"",location.pathname);
const notices={company:"This CYFR requires company sign-in. Open its address in a browser to continue. The CYFR app does not support company sign-in yet.",unanswered:"The CYFR at {CYFR} did not answer.",uncleared:"The app could not clear the sign-in it kept on this computer, so it opened no other CYFR: try again."};
let asked=null;
function say(t){$("notice").textContent=t||""}
function post(p,b){return fetch(p,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(Object.assign({token},b))}).then(r=>{s.setItem("token",token);return r.ok?r.json():{error:"This page is not the app's own. Quit the app and open it again."}},()=>({error:"The app's connection stopped. Quit it and open it again."}))}
function show(a,told){say(a.error||told);asked=a.confirm?a:null;const stay=!!(a.next&&(passkey||told));$("confirm").hidden=!asked;$("choose").hidden=!!asked||stay;$("road").hidden=!stay;
if(asked){$("home").textContent=a.home;$("service").textContent=a.confirm}
if(stay){$("open").textContent=a.home;$("passkey").hidden=$("either").hidden=$("another").hidden=!passkey;$("again").hidden=!passkey||!main.told.includes("unanswered");$("passkey").onclick=()=>location.assign(a.home+"/login");$("words").onclick=()=>location.assign(a.next)}
else if(a.next)location.replace(a.next)}
function connected(a){if(!(passkey&&a.next))show(a,notices[a.notice])}
function connect(address){say("Connecting\u2026");post("/bootstrap/connect",{address}).then(connected)}
post("/bootstrap/state",{}).then(a=>{if(a.home)$("address").value=a.home;const told=main.told.map(n=>notices[n]).filter(Boolean).join(" ").replace("{CYFR}",a.home||"");show(a,told);if(passkey&&a.resume&&!told)connect(a.resume)});
$("connect").addEventListener("submit",e=>{e.preventDefault();connect($("address").value)});
$("another").addEventListener("click",()=>location.assign("/bootstrap/another"));
$("again").addEventListener("click",()=>location.assign("/bootstrap/again"));
$("approve").addEventListener("click",()=>{say("Connecting\u2026");post("/bootstrap/approve",{home:asked.home,directory:asked.confirm}).then(connected)});
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
<button id="again" hidden>Try again</button>
<button id="passkey">Sign in with your passkey</button>
<p id="either">No passkey on this computer, or you would rather not use one? Use this computer's own key, opened with its PIN or six-word passphrase.</p>
<button id="words" class="quiet">Use this computer's key</button>
<button id="another" class="quiet" hidden>Connect to another CYFR</button>
</section>
<section id="confirm" hidden>
<h1>Check the account service</h1>
<p>The CYFR at <b class="code" id="home"></b> signs you in at the account service</p>
<p class="code" id="service"></p>
<p>That is not cyfr.run. Go on only if you expected this address.</p>
<button id="approve">Go on</button><button id="decline" class="quiet">Cancel</button>
</section>
<p id="notice" role="status"></p>
</main><script>` + bootstrapScript + `</script></html>`
