const f=new URLSearchParams(location.hash.slice(1)),$=i=>document.getElementById(i);
const was=history.state||{},reloaded=(performance.getEntriesByType("navigation")[0]||{}).type==="reload";
const main=f.has("road")?{road:f.get("road"),box:f.get("box")==="1",told:(f.get("notice")||"").split(","),connect:f.get("connect")||"",way:f.get("way")||"",retry:f.get("retry")||""}:{road:was.road,box:was.box,told:reloaded&&was.told||[]},passkey=main.road==="passkey";
if(main.box)$("here").hidden=true;
history.replaceState(main,"",location.pathname);
const notices={company:"This CYFR requires company sign-in. Open its address in a browser to continue. The CYFR app does not support company sign-in yet.",unanswered:"The CYFR at {CYFR} did not answer.",unrouted:"The app could not reach the CYFR at {CYFR} through this computer's tailnet, so it loaded nothing of it.",unforgotten:"The app locked, and could not clear the sign-in it kept on this computer. To clear it, forget this CYFR on this computer from its menu on the left.",unleft:"The CYFR you left did not let go in time, so the app started again and opened nothing. Choose a CYFR on the left to open it."};
let asked=null,picks=0,started=false,epoch=0,run=0,found=false,busy=false;
const steps={files:"Getting CYFR's files",settings:"Writing its settings",images:"Downloading CYFR",start:"Starting CYFR"};
function say(t){$("notice").textContent=t||""}
function folder(a){if(a.folder){$("folder").textContent=a.folder;picks=a.picks||0;found=!!a.found;offer()}}
function offer(){$("go").hidden=busy||started||!found}
function checked(a){const d=a.docker||{},fix=d.commands||[];$("docker").textContent=!a.docker?a.error:d.ready?"Docker answers on this computer.":d.sentence+".";
$("commands").textContent=fix.map(c=>"sudo "+c).join("\n");$("run").hidden=$("commands").hidden=!fix.length;if(d.page)$("page").href=d.page;$("install").hidden=!d.page;$("check").hidden=!!d.ready;$("start").hidden=!d.ready}
function check(){$("docker").textContent="Checking whether Docker answers\u2026";$("run").hidden=$("commands").hidden=$("install").hidden=$("check").hidden=$("start").hidden=true;post("/bootstrap/docker",{}).then(checked)}
function progress(p){run=p.run||0;const running=!p.done&&!p.error;busy=running;if(p.done&&p.folder===$("folder").textContent)found=true;$("choose").hidden=true;$("setup").hidden=false;$("progress").hidden=false;
$("progress").textContent=["Setting up CYFR in "+p.folder].concat(p.steps.map(i=>steps[i]||i)).join("\n")+(running?"\u2026":"");
$("change").hidden=$("back").hidden=running||!!p.done;$("check").hidden=$("start").hidden=true;$("retry").hidden=!p.error;offer();
if(p.error||p.done)say(p.error?p.error+".":"CYFR is set up in "+p.folder+" and started.");
if(running)post("/bootstrap/setup",{seen:p.seq}).then(a=>a.setup?progress(a.setup):say(a.error));else if(p.done&&started){started=false;opening()}}
function begin(){started=true;say("");post("/bootstrap/start",{picks,run}).then(a=>{folder(a);if(a.setup)progress(a.setup);if(a.error)say(a.error)})}
function opening(){$("go").hidden=true;say("Opening CYFR\u2026");post("/bootstrap/open",{picks,run}).then(a=>{if(a.next){if(!passkey)location.replace(a.next);return}say(a.error||"CYFR did not open.");$("go").hidden=false})}
function ask(p,b){return fetch(p,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(Object.assign({epoch},b))})}
function answer(r){return r.ok?r.json():{error:"This page is not the app's own. Quit the app and open it again."}}
function stopped(){return{error:"The app's connection stopped. Quit it and open it again."}}
function post(p,b){return ask(p,b).then(answer,stopped)}
// The page's first request can reach main before main has heard that this
// document is the chooser, and then goes without the run token main adds;
// cyfr refuses it (403) having done nothing. So the first read of the state
// alone is asked again, for under two seconds in all, before the page says
// it is not the app's own.
function state(wait){return ask("/bootstrap/state",{}).then(r=>r.status===403&&wait<2000?new Promise(t=>setTimeout(t,wait)).then(()=>state(wait*2)):answer(r),stopped)}
function show(a,told){say(a.error||told);asked=a.confirm?a:null;const stay=!!(a.next&&(passkey||told));$("confirm").hidden=!asked;$("choose").hidden=!!asked||stay;$("road").hidden=!stay;
if(asked){$("named").textContent=a.cyfr;$("service").textContent=a.confirm}
if(stay){$("open").textContent=a.cyfr;$("passkey").hidden=$("either").hidden=!passkey;$("again").hidden=!passkey||!main.told.some(n=>n==="unanswered"||n==="unrouted");$("passkey").onclick=()=>onward(a.cyfr,"/bootstrap/signin");$("again").onclick=()=>onward(a.cyfr,"/bootstrap/again");$("words").onclick=()=>location.assign(a.next)}
else if(a.next)location.replace(a.next)}
function connected(a){if(!(passkey&&a.next))show(a)}
function onward(at,to){say("Connecting\u2026");post("/bootstrap/connect",{address:at}).then(a=>a.next?location.assign(to):say(a.error))}
function reopen(at){$("address").value=at;$("reopen").hidden=true;say("Connecting\u2026");post("/bootstrap/connect",{address:at,kept:true}).then(a=>{if(a.error){$("reopen").hidden=false;$("reopen").onclick=()=>reopen(at)}connected(a)})}
function box(){$("reopen").hidden=true;say("Opening This box\u2026");post("/bootstrap/box",{}).then(a=>{if(a.error){$("reopen").hidden=false;$("reopen").onclick=box}connected(a)})}
function connect(address,kept){$("reopen").hidden=true;say("Connecting\u2026");post("/bootstrap/connect",kept?{address,kept}:{address}).then(connected)}
state(125).then(a=>{epoch=a.epoch||0;if(a.cyfr)$("address").value=a.cyfr;folder(a);const told=main.told.map(n=>notices[n]).filter(Boolean).join(" ").replace("{CYFR}",main.retry||a.cyfr||"");show(a,told);if(a.setup)progress(a.setup);else if(main.connect){$("address").value=main.connect;connect(main.connect,true)}else if(main.way==="setup"&&!main.box)here();else if(main.way==="box"&&main.box)box();else if(main.retry){$("address").value=main.retry;$("reopen").hidden=false;$("reopen").onclick=()=>reopen(main.retry)}else if(a.resume&&!told)reopen(a.resume);else if(a.resume_box&&main.box&&!told)box()});
$("connect").addEventListener("submit",e=>{e.preventDefault();connect($("address").value)});
function here(){say("");$("choose").hidden=true;$("setup").hidden=false;check()}
$("here").addEventListener("click",here);
$("check").addEventListener("click",check);
$("start").addEventListener("click",begin);
$("retry").addEventListener("click",begin);
$("go").addEventListener("click",opening);
$("back").addEventListener("click",()=>{$("setup").hidden=true;$("choose").hidden=false});
$("change").addEventListener("click",()=>{post("/bootstrap/folder",{picks}).then(a=>a.error?say(a.error):folder(a));location.assign("/bootstrap/pick?epoch="+epoch+"&pick="+picks)});
$("approve").addEventListener("click",()=>{say("Connecting\u2026");post("/bootstrap/approve",{cyfr:asked.cyfr,directory:asked.confirm}).then(connected)});
$("decline").addEventListener("click",()=>{show({});say("Nothing was sent to that account service.")});
