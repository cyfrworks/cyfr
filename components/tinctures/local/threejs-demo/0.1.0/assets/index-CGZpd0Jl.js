(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const l of document.querySelectorAll('link[rel="modulepreload"]'))r(l);new MutationObserver(l=>{for(const c of l)if(c.type==="childList")for(const h of c.addedNodes)h.tagName==="LINK"&&h.rel==="modulepreload"&&r(h)}).observe(document,{childList:!0,subtree:!0});function i(l){const c={};return l.integrity&&(c.integrity=l.integrity),l.referrerPolicy&&(c.referrerPolicy=l.referrerPolicy),l.crossOrigin==="use-credentials"?c.credentials="include":l.crossOrigin==="anonymous"?c.credentials="omit":c.credentials="same-origin",c}function r(l){if(l.ep)return;l.ep=!0;const c=i(l);fetch(l.href,c)}})();var Pf={exports:{}},vo={};/**
 * @license React
 * react-jsx-runtime.production.js
 *
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */var o_;function ix(){if(o_)return vo;o_=1;var o=Symbol.for("react.transitional.element"),e=Symbol.for("react.fragment");function i(r,l,c){var h=null;if(c!==void 0&&(h=""+c),l.key!==void 0&&(h=""+l.key),"key"in l){c={};for(var d in l)d!=="key"&&(c[d]=l[d])}else c=l;return l=c.ref,{$$typeof:o,type:r,key:h,ref:l!==void 0?l:null,props:c}}return vo.Fragment=e,vo.jsx=i,vo.jsxs=i,vo}var l_;function ax(){return l_||(l_=1,Pf.exports=ix()),Pf.exports}var aa=ax(),Bf={exports:{}},ie={};/**
 * @license React
 * react.production.js
 *
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */var u_;function rx(){if(u_)return ie;u_=1;var o=Symbol.for("react.transitional.element"),e=Symbol.for("react.portal"),i=Symbol.for("react.fragment"),r=Symbol.for("react.strict_mode"),l=Symbol.for("react.profiler"),c=Symbol.for("react.consumer"),h=Symbol.for("react.context"),d=Symbol.for("react.forward_ref"),m=Symbol.for("react.suspense"),p=Symbol.for("react.memo"),S=Symbol.for("react.lazy"),v=Symbol.for("react.activity"),x=Symbol.iterator;function y(z){return z===null||typeof z!="object"?null:(z=x&&z[x]||z["@@iterator"],typeof z=="function"?z:null)}var R={isMounted:function(){return!1},enqueueForceUpdate:function(){},enqueueReplaceState:function(){},enqueueSetState:function(){}},w=Object.assign,M={};function _(z,nt,xt){this.props=z,this.context=nt,this.refs=M,this.updater=xt||R}_.prototype.isReactComponent={},_.prototype.setState=function(z,nt){if(typeof z!="object"&&typeof z!="function"&&z!=null)throw Error("takes an object of state variables to update or a function which returns an object of state variables.");this.updater.enqueueSetState(this,z,nt,"setState")},_.prototype.forceUpdate=function(z){this.updater.enqueueForceUpdate(this,z,"forceUpdate")};function L(){}L.prototype=_.prototype;function U(z,nt,xt){this.props=z,this.context=nt,this.refs=M,this.updater=xt||R}var C=U.prototype=new L;C.constructor=U,w(C,_.prototype),C.isPureReactComponent=!0;var G=Array.isArray;function I(){}var O={H:null,A:null,T:null,S:null},V=Object.prototype.hasOwnProperty;function D(z,nt,xt){var K=xt.ref;return{$$typeof:o,type:z,key:nt,ref:K!==void 0?K:null,props:xt}}function b(z,nt){return D(z.type,nt,z.props)}function B(z){return typeof z=="object"&&z!==null&&z.$$typeof===o}function rt(z){var nt={"=":"=0",":":"=2"};return"$"+z.replace(/[=:]/g,function(xt){return nt[xt]})}var st=/\/+/g;function dt(z,nt){return typeof z=="object"&&z!==null&&z.key!=null?rt(""+z.key):nt.toString(36)}function pt(z){switch(z.status){case"fulfilled":return z.value;case"rejected":throw z.reason;default:switch(typeof z.status=="string"?z.then(I,I):(z.status="pending",z.then(function(nt){z.status==="pending"&&(z.status="fulfilled",z.value=nt)},function(nt){z.status==="pending"&&(z.status="rejected",z.reason=nt)})),z.status){case"fulfilled":return z.value;case"rejected":throw z.reason}}throw z}function P(z,nt,xt,K,ft){var yt=typeof z;(yt==="undefined"||yt==="boolean")&&(z=null);var St=!1;if(z===null)St=!0;else switch(yt){case"bigint":case"string":case"number":St=!0;break;case"object":switch(z.$$typeof){case o:case e:St=!0;break;case S:return St=z._init,P(St(z._payload),nt,xt,K,ft)}}if(St)return ft=ft(z),St=K===""?"."+dt(z,0):K,G(ft)?(xt="",St!=null&&(xt=St.replace(st,"$&/")+"/"),P(ft,nt,xt,"",function(jt){return jt})):ft!=null&&(B(ft)&&(ft=b(ft,xt+(ft.key==null||z&&z.key===ft.key?"":(""+ft.key).replace(st,"$&/")+"/")+St)),nt.push(ft)),1;St=0;var zt=K===""?".":K+":";if(G(z))for(var qt=0;qt<z.length;qt++)K=z[qt],yt=zt+dt(K,qt),St+=P(K,nt,xt,yt,ft);else if(qt=y(z),typeof qt=="function")for(z=qt.call(z),qt=0;!(K=z.next()).done;)K=K.value,yt=zt+dt(K,qt++),St+=P(K,nt,xt,yt,ft);else if(yt==="object"){if(typeof z.then=="function")return P(pt(z),nt,xt,K,ft);throw nt=String(z),Error("Objects are not valid as a React child (found: "+(nt==="[object Object]"?"object with keys {"+Object.keys(z).join(", ")+"}":nt)+"). If you meant to render a collection of children, use an array instead.")}return St}function Y(z,nt,xt){if(z==null)return z;var K=[],ft=0;return P(z,K,"","",function(yt){return nt.call(xt,yt,ft++)}),K}function j(z){if(z._status===-1){var nt=z._result;nt=nt(),nt.then(function(xt){(z._status===0||z._status===-1)&&(z._status=1,z._result=xt)},function(xt){(z._status===0||z._status===-1)&&(z._status=2,z._result=xt)}),z._status===-1&&(z._status=0,z._result=nt)}if(z._status===1)return z._result.default;throw z._result}var vt=typeof reportError=="function"?reportError:function(z){if(typeof window=="object"&&typeof window.ErrorEvent=="function"){var nt=new window.ErrorEvent("error",{bubbles:!0,cancelable:!0,message:typeof z=="object"&&z!==null&&typeof z.message=="string"?String(z.message):String(z),error:z});if(!window.dispatchEvent(nt))return}else if(typeof process=="object"&&typeof process.emit=="function"){process.emit("uncaughtException",z);return}console.error(z)},Tt={map:Y,forEach:function(z,nt,xt){Y(z,function(){nt.apply(this,arguments)},xt)},count:function(z){var nt=0;return Y(z,function(){nt++}),nt},toArray:function(z){return Y(z,function(nt){return nt})||[]},only:function(z){if(!B(z))throw Error("React.Children.only expected to receive a single React element child.");return z}};return ie.Activity=v,ie.Children=Tt,ie.Component=_,ie.Fragment=i,ie.Profiler=l,ie.PureComponent=U,ie.StrictMode=r,ie.Suspense=m,ie.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE=O,ie.__COMPILER_RUNTIME={__proto__:null,c:function(z){return O.H.useMemoCache(z)}},ie.cache=function(z){return function(){return z.apply(null,arguments)}},ie.cacheSignal=function(){return null},ie.cloneElement=function(z,nt,xt){if(z==null)throw Error("The argument must be a React element, but you passed "+z+".");var K=w({},z.props),ft=z.key;if(nt!=null)for(yt in nt.key!==void 0&&(ft=""+nt.key),nt)!V.call(nt,yt)||yt==="key"||yt==="__self"||yt==="__source"||yt==="ref"&&nt.ref===void 0||(K[yt]=nt[yt]);var yt=arguments.length-2;if(yt===1)K.children=xt;else if(1<yt){for(var St=Array(yt),zt=0;zt<yt;zt++)St[zt]=arguments[zt+2];K.children=St}return D(z.type,ft,K)},ie.createContext=function(z){return z={$$typeof:h,_currentValue:z,_currentValue2:z,_threadCount:0,Provider:null,Consumer:null},z.Provider=z,z.Consumer={$$typeof:c,_context:z},z},ie.createElement=function(z,nt,xt){var K,ft={},yt=null;if(nt!=null)for(K in nt.key!==void 0&&(yt=""+nt.key),nt)V.call(nt,K)&&K!=="key"&&K!=="__self"&&K!=="__source"&&(ft[K]=nt[K]);var St=arguments.length-2;if(St===1)ft.children=xt;else if(1<St){for(var zt=Array(St),qt=0;qt<St;qt++)zt[qt]=arguments[qt+2];ft.children=zt}if(z&&z.defaultProps)for(K in St=z.defaultProps,St)ft[K]===void 0&&(ft[K]=St[K]);return D(z,yt,ft)},ie.createRef=function(){return{current:null}},ie.forwardRef=function(z){return{$$typeof:d,render:z}},ie.isValidElement=B,ie.lazy=function(z){return{$$typeof:S,_payload:{_status:-1,_result:z},_init:j}},ie.memo=function(z,nt){return{$$typeof:p,type:z,compare:nt===void 0?null:nt}},ie.startTransition=function(z){var nt=O.T,xt={};O.T=xt;try{var K=z(),ft=O.S;ft!==null&&ft(xt,K),typeof K=="object"&&K!==null&&typeof K.then=="function"&&K.then(I,vt)}catch(yt){vt(yt)}finally{nt!==null&&xt.types!==null&&(nt.types=xt.types),O.T=nt}},ie.unstable_useCacheRefresh=function(){return O.H.useCacheRefresh()},ie.use=function(z){return O.H.use(z)},ie.useActionState=function(z,nt,xt){return O.H.useActionState(z,nt,xt)},ie.useCallback=function(z,nt){return O.H.useCallback(z,nt)},ie.useContext=function(z){return O.H.useContext(z)},ie.useDebugValue=function(){},ie.useDeferredValue=function(z,nt){return O.H.useDeferredValue(z,nt)},ie.useEffect=function(z,nt){return O.H.useEffect(z,nt)},ie.useEffectEvent=function(z){return O.H.useEffectEvent(z)},ie.useId=function(){return O.H.useId()},ie.useImperativeHandle=function(z,nt,xt){return O.H.useImperativeHandle(z,nt,xt)},ie.useInsertionEffect=function(z,nt){return O.H.useInsertionEffect(z,nt)},ie.useLayoutEffect=function(z,nt){return O.H.useLayoutEffect(z,nt)},ie.useMemo=function(z,nt){return O.H.useMemo(z,nt)},ie.useOptimistic=function(z,nt){return O.H.useOptimistic(z,nt)},ie.useReducer=function(z,nt,xt){return O.H.useReducer(z,nt,xt)},ie.useRef=function(z){return O.H.useRef(z)},ie.useState=function(z){return O.H.useState(z)},ie.useSyncExternalStore=function(z,nt,xt){return O.H.useSyncExternalStore(z,nt,xt)},ie.useTransition=function(){return O.H.useTransition()},ie.version="19.2.4",ie}var c_;function ld(){return c_||(c_=1,Bf.exports=rx()),Bf.exports}var mu=ld(),If={exports:{}},So={},Ff={exports:{}},Hf={};/**
 * @license React
 * scheduler.production.js
 *
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */var f_;function sx(){return f_||(f_=1,(function(o){function e(P,Y){var j=P.length;P.push(Y);t:for(;0<j;){var vt=j-1>>>1,Tt=P[vt];if(0<l(Tt,Y))P[vt]=Y,P[j]=Tt,j=vt;else break t}}function i(P){return P.length===0?null:P[0]}function r(P){if(P.length===0)return null;var Y=P[0],j=P.pop();if(j!==Y){P[0]=j;t:for(var vt=0,Tt=P.length,z=Tt>>>1;vt<z;){var nt=2*(vt+1)-1,xt=P[nt],K=nt+1,ft=P[K];if(0>l(xt,j))K<Tt&&0>l(ft,xt)?(P[vt]=ft,P[K]=j,vt=K):(P[vt]=xt,P[nt]=j,vt=nt);else if(K<Tt&&0>l(ft,j))P[vt]=ft,P[K]=j,vt=K;else break t}}return Y}function l(P,Y){var j=P.sortIndex-Y.sortIndex;return j!==0?j:P.id-Y.id}if(o.unstable_now=void 0,typeof performance=="object"&&typeof performance.now=="function"){var c=performance;o.unstable_now=function(){return c.now()}}else{var h=Date,d=h.now();o.unstable_now=function(){return h.now()-d}}var m=[],p=[],S=1,v=null,x=3,y=!1,R=!1,w=!1,M=!1,_=typeof setTimeout=="function"?setTimeout:null,L=typeof clearTimeout=="function"?clearTimeout:null,U=typeof setImmediate<"u"?setImmediate:null;function C(P){for(var Y=i(p);Y!==null;){if(Y.callback===null)r(p);else if(Y.startTime<=P)r(p),Y.sortIndex=Y.expirationTime,e(m,Y);else break;Y=i(p)}}function G(P){if(w=!1,C(P),!R)if(i(m)!==null)R=!0,I||(I=!0,rt());else{var Y=i(p);Y!==null&&pt(G,Y.startTime-P)}}var I=!1,O=-1,V=5,D=-1;function b(){return M?!0:!(o.unstable_now()-D<V)}function B(){if(M=!1,I){var P=o.unstable_now();D=P;var Y=!0;try{t:{R=!1,w&&(w=!1,L(O),O=-1),y=!0;var j=x;try{e:{for(C(P),v=i(m);v!==null&&!(v.expirationTime>P&&b());){var vt=v.callback;if(typeof vt=="function"){v.callback=null,x=v.priorityLevel;var Tt=vt(v.expirationTime<=P);if(P=o.unstable_now(),typeof Tt=="function"){v.callback=Tt,C(P),Y=!0;break e}v===i(m)&&r(m),C(P)}else r(m);v=i(m)}if(v!==null)Y=!0;else{var z=i(p);z!==null&&pt(G,z.startTime-P),Y=!1}}break t}finally{v=null,x=j,y=!1}Y=void 0}}finally{Y?rt():I=!1}}}var rt;if(typeof U=="function")rt=function(){U(B)};else if(typeof MessageChannel<"u"){var st=new MessageChannel,dt=st.port2;st.port1.onmessage=B,rt=function(){dt.postMessage(null)}}else rt=function(){_(B,0)};function pt(P,Y){O=_(function(){P(o.unstable_now())},Y)}o.unstable_IdlePriority=5,o.unstable_ImmediatePriority=1,o.unstable_LowPriority=4,o.unstable_NormalPriority=3,o.unstable_Profiling=null,o.unstable_UserBlockingPriority=2,o.unstable_cancelCallback=function(P){P.callback=null},o.unstable_forceFrameRate=function(P){0>P||125<P?console.error("forceFrameRate takes a positive int between 0 and 125, forcing frame rates higher than 125 fps is not supported"):V=0<P?Math.floor(1e3/P):5},o.unstable_getCurrentPriorityLevel=function(){return x},o.unstable_next=function(P){switch(x){case 1:case 2:case 3:var Y=3;break;default:Y=x}var j=x;x=Y;try{return P()}finally{x=j}},o.unstable_requestPaint=function(){M=!0},o.unstable_runWithPriority=function(P,Y){switch(P){case 1:case 2:case 3:case 4:case 5:break;default:P=3}var j=x;x=P;try{return Y()}finally{x=j}},o.unstable_scheduleCallback=function(P,Y,j){var vt=o.unstable_now();switch(typeof j=="object"&&j!==null?(j=j.delay,j=typeof j=="number"&&0<j?vt+j:vt):j=vt,P){case 1:var Tt=-1;break;case 2:Tt=250;break;case 5:Tt=1073741823;break;case 4:Tt=1e4;break;default:Tt=5e3}return Tt=j+Tt,P={id:S++,callback:Y,priorityLevel:P,startTime:j,expirationTime:Tt,sortIndex:-1},j>vt?(P.sortIndex=j,e(p,P),i(m)===null&&P===i(p)&&(w?(L(O),O=-1):w=!0,pt(G,j-vt))):(P.sortIndex=Tt,e(m,P),R||y||(R=!0,I||(I=!0,rt()))),P},o.unstable_shouldYield=b,o.unstable_wrapCallback=function(P){var Y=x;return function(){var j=x;x=Y;try{return P.apply(this,arguments)}finally{x=j}}}})(Hf)),Hf}var h_;function ox(){return h_||(h_=1,Ff.exports=sx()),Ff.exports}var Gf={exports:{}},En={};/**
 * @license React
 * react-dom.production.js
 *
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */var d_;function lx(){if(d_)return En;d_=1;var o=ld();function e(m){var p="https://react.dev/errors/"+m;if(1<arguments.length){p+="?args[]="+encodeURIComponent(arguments[1]);for(var S=2;S<arguments.length;S++)p+="&args[]="+encodeURIComponent(arguments[S])}return"Minified React error #"+m+"; visit "+p+" for the full message or use the non-minified dev environment for full errors and additional helpful warnings."}function i(){}var r={d:{f:i,r:function(){throw Error(e(522))},D:i,C:i,L:i,m:i,X:i,S:i,M:i},p:0,findDOMNode:null},l=Symbol.for("react.portal");function c(m,p,S){var v=3<arguments.length&&arguments[3]!==void 0?arguments[3]:null;return{$$typeof:l,key:v==null?null:""+v,children:m,containerInfo:p,implementation:S}}var h=o.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;function d(m,p){if(m==="font")return"";if(typeof p=="string")return p==="use-credentials"?p:""}return En.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE=r,En.createPortal=function(m,p){var S=2<arguments.length&&arguments[2]!==void 0?arguments[2]:null;if(!p||p.nodeType!==1&&p.nodeType!==9&&p.nodeType!==11)throw Error(e(299));return c(m,p,null,S)},En.flushSync=function(m){var p=h.T,S=r.p;try{if(h.T=null,r.p=2,m)return m()}finally{h.T=p,r.p=S,r.d.f()}},En.preconnect=function(m,p){typeof m=="string"&&(p?(p=p.crossOrigin,p=typeof p=="string"?p==="use-credentials"?p:"":void 0):p=null,r.d.C(m,p))},En.prefetchDNS=function(m){typeof m=="string"&&r.d.D(m)},En.preinit=function(m,p){if(typeof m=="string"&&p&&typeof p.as=="string"){var S=p.as,v=d(S,p.crossOrigin),x=typeof p.integrity=="string"?p.integrity:void 0,y=typeof p.fetchPriority=="string"?p.fetchPriority:void 0;S==="style"?r.d.S(m,typeof p.precedence=="string"?p.precedence:void 0,{crossOrigin:v,integrity:x,fetchPriority:y}):S==="script"&&r.d.X(m,{crossOrigin:v,integrity:x,fetchPriority:y,nonce:typeof p.nonce=="string"?p.nonce:void 0})}},En.preinitModule=function(m,p){if(typeof m=="string")if(typeof p=="object"&&p!==null){if(p.as==null||p.as==="script"){var S=d(p.as,p.crossOrigin);r.d.M(m,{crossOrigin:S,integrity:typeof p.integrity=="string"?p.integrity:void 0,nonce:typeof p.nonce=="string"?p.nonce:void 0})}}else p==null&&r.d.M(m)},En.preload=function(m,p){if(typeof m=="string"&&typeof p=="object"&&p!==null&&typeof p.as=="string"){var S=p.as,v=d(S,p.crossOrigin);r.d.L(m,S,{crossOrigin:v,integrity:typeof p.integrity=="string"?p.integrity:void 0,nonce:typeof p.nonce=="string"?p.nonce:void 0,type:typeof p.type=="string"?p.type:void 0,fetchPriority:typeof p.fetchPriority=="string"?p.fetchPriority:void 0,referrerPolicy:typeof p.referrerPolicy=="string"?p.referrerPolicy:void 0,imageSrcSet:typeof p.imageSrcSet=="string"?p.imageSrcSet:void 0,imageSizes:typeof p.imageSizes=="string"?p.imageSizes:void 0,media:typeof p.media=="string"?p.media:void 0})}},En.preloadModule=function(m,p){if(typeof m=="string")if(p){var S=d(p.as,p.crossOrigin);r.d.m(m,{as:typeof p.as=="string"&&p.as!=="script"?p.as:void 0,crossOrigin:S,integrity:typeof p.integrity=="string"?p.integrity:void 0})}else r.d.m(m)},En.requestFormReset=function(m){r.d.r(m)},En.unstable_batchedUpdates=function(m,p){return m(p)},En.useFormState=function(m,p,S){return h.H.useFormState(m,p,S)},En.useFormStatus=function(){return h.H.useHostTransitionStatus()},En.version="19.2.4",En}var p_;function ux(){if(p_)return Gf.exports;p_=1;function o(){if(!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__>"u"||typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE!="function"))try{__REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(o)}catch(e){console.error(e)}}return o(),Gf.exports=lx(),Gf.exports}/**
 * @license React
 * react-dom-client.production.js
 *
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */var m_;function cx(){if(m_)return So;m_=1;var o=ox(),e=ld(),i=ux();function r(t){var n="https://react.dev/errors/"+t;if(1<arguments.length){n+="?args[]="+encodeURIComponent(arguments[1]);for(var a=2;a<arguments.length;a++)n+="&args[]="+encodeURIComponent(arguments[a])}return"Minified React error #"+t+"; visit "+n+" for the full message or use the non-minified dev environment for full errors and additional helpful warnings."}function l(t){return!(!t||t.nodeType!==1&&t.nodeType!==9&&t.nodeType!==11)}function c(t){var n=t,a=t;if(t.alternate)for(;n.return;)n=n.return;else{t=n;do n=t,(n.flags&4098)!==0&&(a=n.return),t=n.return;while(t)}return n.tag===3?a:null}function h(t){if(t.tag===13){var n=t.memoizedState;if(n===null&&(t=t.alternate,t!==null&&(n=t.memoizedState)),n!==null)return n.dehydrated}return null}function d(t){if(t.tag===31){var n=t.memoizedState;if(n===null&&(t=t.alternate,t!==null&&(n=t.memoizedState)),n!==null)return n.dehydrated}return null}function m(t){if(c(t)!==t)throw Error(r(188))}function p(t){var n=t.alternate;if(!n){if(n=c(t),n===null)throw Error(r(188));return n!==t?null:t}for(var a=t,s=n;;){var u=a.return;if(u===null)break;var f=u.alternate;if(f===null){if(s=u.return,s!==null){a=s;continue}break}if(u.child===f.child){for(f=u.child;f;){if(f===a)return m(u),t;if(f===s)return m(u),n;f=f.sibling}throw Error(r(188))}if(a.return!==s.return)a=u,s=f;else{for(var g=!1,E=u.child;E;){if(E===a){g=!0,a=u,s=f;break}if(E===s){g=!0,s=u,a=f;break}E=E.sibling}if(!g){for(E=f.child;E;){if(E===a){g=!0,a=f,s=u;break}if(E===s){g=!0,s=f,a=u;break}E=E.sibling}if(!g)throw Error(r(189))}}if(a.alternate!==s)throw Error(r(190))}if(a.tag!==3)throw Error(r(188));return a.stateNode.current===a?t:n}function S(t){var n=t.tag;if(n===5||n===26||n===27||n===6)return t;for(t=t.child;t!==null;){if(n=S(t),n!==null)return n;t=t.sibling}return null}var v=Object.assign,x=Symbol.for("react.element"),y=Symbol.for("react.transitional.element"),R=Symbol.for("react.portal"),w=Symbol.for("react.fragment"),M=Symbol.for("react.strict_mode"),_=Symbol.for("react.profiler"),L=Symbol.for("react.consumer"),U=Symbol.for("react.context"),C=Symbol.for("react.forward_ref"),G=Symbol.for("react.suspense"),I=Symbol.for("react.suspense_list"),O=Symbol.for("react.memo"),V=Symbol.for("react.lazy"),D=Symbol.for("react.activity"),b=Symbol.for("react.memo_cache_sentinel"),B=Symbol.iterator;function rt(t){return t===null||typeof t!="object"?null:(t=B&&t[B]||t["@@iterator"],typeof t=="function"?t:null)}var st=Symbol.for("react.client.reference");function dt(t){if(t==null)return null;if(typeof t=="function")return t.$$typeof===st?null:t.displayName||t.name||null;if(typeof t=="string")return t;switch(t){case w:return"Fragment";case _:return"Profiler";case M:return"StrictMode";case G:return"Suspense";case I:return"SuspenseList";case D:return"Activity"}if(typeof t=="object")switch(t.$$typeof){case R:return"Portal";case U:return t.displayName||"Context";case L:return(t._context.displayName||"Context")+".Consumer";case C:var n=t.render;return t=t.displayName,t||(t=n.displayName||n.name||"",t=t!==""?"ForwardRef("+t+")":"ForwardRef"),t;case O:return n=t.displayName||null,n!==null?n:dt(t.type)||"Memo";case V:n=t._payload,t=t._init;try{return dt(t(n))}catch{}}return null}var pt=Array.isArray,P=e.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE,Y=i.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE,j={pending:!1,data:null,method:null,action:null},vt=[],Tt=-1;function z(t){return{current:t}}function nt(t){0>Tt||(t.current=vt[Tt],vt[Tt]=null,Tt--)}function xt(t,n){Tt++,vt[Tt]=t.current,t.current=n}var K=z(null),ft=z(null),yt=z(null),St=z(null);function zt(t,n){switch(xt(yt,n),xt(ft,t),xt(K,null),n.nodeType){case 9:case 11:t=(t=n.documentElement)&&(t=t.namespaceURI)?Dg(t):0;break;default:if(t=n.tagName,n=n.namespaceURI)n=Dg(n),t=Ug(n,t);else switch(t){case"svg":t=1;break;case"math":t=2;break;default:t=0}}nt(K),xt(K,t)}function qt(){nt(K),nt(ft),nt(yt)}function jt(t){t.memoizedState!==null&&xt(St,t);var n=K.current,a=Ug(n,t.type);n!==a&&(xt(ft,t),xt(K,a))}function Ge(t){ft.current===t&&(nt(K),nt(ft)),St.current===t&&(nt(St),po._currentValue=j)}var Fe,ue;function H(t){if(Fe===void 0)try{throw Error()}catch(a){var n=a.stack.trim().match(/\n( *(at )?)/);Fe=n&&n[1]||"",ue=-1<a.stack.indexOf(`
    at`)?" (<anonymous>)":-1<a.stack.indexOf("@")?"@unknown:0:0":""}return`
`+Fe+t+ue}var Mn=!1;function ce(t,n){if(!t||Mn)return"";Mn=!0;var a=Error.prepareStackTrace;Error.prepareStackTrace=void 0;try{var s={DetermineComponentFrameRoot:function(){try{if(n){var gt=function(){throw Error()};if(Object.defineProperty(gt.prototype,"props",{set:function(){throw Error()}}),typeof Reflect=="object"&&Reflect.construct){try{Reflect.construct(gt,[])}catch(ot){var tt=ot}Reflect.construct(t,[],gt)}else{try{gt.call()}catch(ot){tt=ot}t.call(gt.prototype)}}else{try{throw Error()}catch(ot){tt=ot}(gt=t())&&typeof gt.catch=="function"&&gt.catch(function(){})}}catch(ot){if(ot&&tt&&typeof ot.stack=="string")return[ot.stack,tt.stack]}return[null,null]}};s.DetermineComponentFrameRoot.displayName="DetermineComponentFrameRoot";var u=Object.getOwnPropertyDescriptor(s.DetermineComponentFrameRoot,"name");u&&u.configurable&&Object.defineProperty(s.DetermineComponentFrameRoot,"name",{value:"DetermineComponentFrameRoot"});var f=s.DetermineComponentFrameRoot(),g=f[0],E=f[1];if(g&&E){var F=g.split(`
`),$=E.split(`
`);for(u=s=0;s<F.length&&!F[s].includes("DetermineComponentFrameRoot");)s++;for(;u<$.length&&!$[u].includes("DetermineComponentFrameRoot");)u++;if(s===F.length||u===$.length)for(s=F.length-1,u=$.length-1;1<=s&&0<=u&&F[s]!==$[u];)u--;for(;1<=s&&0<=u;s--,u--)if(F[s]!==$[u]){if(s!==1||u!==1)do if(s--,u--,0>u||F[s]!==$[u]){var ut=`
`+F[s].replace(" at new "," at ");return t.displayName&&ut.includes("<anonymous>")&&(ut=ut.replace("<anonymous>",t.displayName)),ut}while(1<=s&&0<=u);break}}}finally{Mn=!1,Error.prepareStackTrace=a}return(a=t?t.displayName||t.name:"")?H(a):""}function de(t,n){switch(t.tag){case 26:case 27:case 5:return H(t.type);case 16:return H("Lazy");case 13:return t.child!==n&&n!==null?H("Suspense Fallback"):H("Suspense");case 19:return H("SuspenseList");case 0:case 15:return ce(t.type,!1);case 11:return ce(t.type.render,!1);case 1:return ce(t.type,!0);case 31:return H("Activity");default:return""}}function Vt(t){try{var n="",a=null;do n+=de(t,a),a=t,t=t.return;while(t);return n}catch(s){return`
Error generating stack: `+s.message+`
`+s.stack}}var we=Object.prototype.hasOwnProperty,Gt=o.unstable_scheduleCallback,N=o.unstable_cancelCallback,T=o.unstable_shouldYield,et=o.unstable_requestPaint,ct=o.unstable_now,Mt=o.unstable_getCurrentPriorityLevel,mt=o.unstable_ImmediatePriority,Ft=o.unstable_UserBlockingPriority,Rt=o.unstable_NormalPriority,Zt=o.unstable_LowPriority,Qt=o.unstable_IdlePriority,bt=o.log,Pt=o.unstable_setDisableYieldValue,Yt=null,Ht=null;function Nt(t){if(typeof bt=="function"&&Pt(t),Ht&&typeof Ht.setStrictMode=="function")try{Ht.setStrictMode(Yt,t)}catch{}}var $t=Math.clz32?Math.clz32:W,ae=Math.log,Le=Math.LN2;function W(t){return t>>>=0,t===0?32:31-(ae(t)/Le|0)|0}var Ct=256,lt=262144,_t=4194304;function At(t){var n=t&42;if(n!==0)return n;switch(t&-t){case 1:return 1;case 2:return 2;case 4:return 4;case 8:return 8;case 16:return 16;case 32:return 32;case 64:return 64;case 128:return 128;case 256:case 512:case 1024:case 2048:case 4096:case 8192:case 16384:case 32768:case 65536:case 131072:return t&261888;case 262144:case 524288:case 1048576:case 2097152:return t&3932160;case 4194304:case 8388608:case 16777216:case 33554432:return t&62914560;case 67108864:return 67108864;case 134217728:return 134217728;case 268435456:return 268435456;case 536870912:return 536870912;case 1073741824:return 0;default:return t}}function wt(t,n,a){var s=t.pendingLanes;if(s===0)return 0;var u=0,f=t.suspendedLanes,g=t.pingedLanes;t=t.warmLanes;var E=s&134217727;return E!==0?(s=E&~f,s!==0?u=At(s):(g&=E,g!==0?u=At(g):a||(a=E&~t,a!==0&&(u=At(a))))):(E=s&~f,E!==0?u=At(E):g!==0?u=At(g):a||(a=s&~t,a!==0&&(u=At(a)))),u===0?0:n!==0&&n!==u&&(n&f)===0&&(f=u&-u,a=n&-n,f>=a||f===32&&(a&4194048)!==0)?n:u}function te(t,n){return(t.pendingLanes&~(t.suspendedLanes&~t.pingedLanes)&n)===0}function We(t,n){switch(t){case 1:case 2:case 4:case 8:case 64:return n+250;case 16:case 32:case 128:case 256:case 512:case 1024:case 2048:case 4096:case 8192:case 16384:case 32768:case 65536:case 131072:case 262144:case 524288:case 1048576:case 2097152:return n+5e3;case 4194304:case 8388608:case 16777216:case 33554432:return-1;case 67108864:case 134217728:case 268435456:case 536870912:case 1073741824:return-1;default:return-1}}function sn(){var t=_t;return _t<<=1,(_t&62914560)===0&&(_t=4194304),t}function Ee(t){for(var n=[],a=0;31>a;a++)n.push(t);return n}function pn(t,n){t.pendingLanes|=n,n!==268435456&&(t.suspendedLanes=0,t.pingedLanes=0,t.warmLanes=0)}function ci(t,n,a,s,u,f){var g=t.pendingLanes;t.pendingLanes=a,t.suspendedLanes=0,t.pingedLanes=0,t.warmLanes=0,t.expiredLanes&=a,t.entangledLanes&=a,t.errorRecoveryDisabledLanes&=a,t.shellSuspendCounter=0;var E=t.entanglements,F=t.expirationTimes,$=t.hiddenUpdates;for(a=g&~a;0<a;){var ut=31-$t(a),gt=1<<ut;E[ut]=0,F[ut]=-1;var tt=$[ut];if(tt!==null)for($[ut]=null,ut=0;ut<tt.length;ut++){var ot=tt[ut];ot!==null&&(ot.lane&=-536870913)}a&=~gt}s!==0&&bs(t,s,0),f!==0&&u===0&&t.tag!==0&&(t.suspendedLanes|=f&~(g&~n))}function bs(t,n,a){t.pendingLanes|=n,t.suspendedLanes&=~n;var s=31-$t(n);t.entangledLanes|=n,t.entanglements[s]=t.entanglements[s]|1073741824|a&261930}function As(t,n){var a=t.entangledLanes|=n;for(t=t.entanglements;a;){var s=31-$t(a),u=1<<s;u&n|t[s]&n&&(t[s]|=n),a&=~u}}function Ei(t,n){var a=n&-n;return a=(a&42)!==0?1:Xa(a),(a&(t.suspendedLanes|n))!==0?0:a}function Xa(t){switch(t){case 2:t=1;break;case 8:t=4;break;case 32:t=16;break;case 256:case 512:case 1024:case 2048:case 4096:case 8192:case 16384:case 32768:case 65536:case 131072:case 262144:case 524288:case 1048576:case 2097152:case 4194304:case 8388608:case 16777216:case 33554432:t=128;break;case 268435456:t=134217728;break;default:t=0}return t}function yr(t){return t&=-t,2<t?8<t?(t&134217727)!==0?32:268435456:8:2}function Rs(){var t=Y.p;return t!==0?t:(t=window.event,t===void 0?32:t_(t.type))}function ka(t,n){var a=Y.p;try{return Y.p=t,n()}finally{Y.p=a}}var fi=Math.random().toString(36).slice(2),je="__reactFiber$"+fi,mn="__reactProps$"+fi,Oi="__reactContainer$"+fi,Cs="__reactEvents$"+fi,wu="__reactListeners$"+fi,Du="__reactHandles$"+fi,Bo="__reactResources$"+fi,Wa="__reactMarker$"+fi;function ws(t){delete t[je],delete t[mn],delete t[Cs],delete t[wu],delete t[Du]}function A(t){var n=t[je];if(n)return n;for(var a=t.parentNode;a;){if(n=a[Oi]||a[je]){if(a=n.alternate,n.child!==null||a!==null&&a.child!==null)for(t=Ig(t);t!==null;){if(a=t[je])return a;t=Ig(t)}return n}t=a,a=t.parentNode}return null}function q(t){if(t=t[je]||t[Oi]){var n=t.tag;if(n===5||n===6||n===13||n===31||n===26||n===27||n===3)return t}return null}function it(t){var n=t.tag;if(n===5||n===26||n===27||n===6)return t.stateNode;throw Error(r(33))}function at(t){var n=t[Bo];return n||(n=t[Bo]={hoistableStyles:new Map,hoistableScripts:new Map}),n}function k(t){t[Wa]=!0}var Et=new Set,Dt={};function Lt(t,n){Ot(t,n),Ot(t+"Capture",n)}function Ot(t,n){for(Dt[t]=n,t=0;t<n.length;t++)Et.add(n[t])}var ee=RegExp("^[:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD][:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\-.0-9\\u00B7\\u0300-\\u036F\\u203F-\\u2040]*$"),Jt={},Xt={};function ge(t){return we.call(Xt,t)?!0:we.call(Jt,t)?!1:ee.test(t)?Xt[t]=!0:(Jt[t]=!0,!1)}function _e(t,n,a){if(ge(n))if(a===null)t.removeAttribute(n);else{switch(typeof a){case"undefined":case"function":case"symbol":t.removeAttribute(n);return;case"boolean":var s=n.toLowerCase().slice(0,5);if(s!=="data-"&&s!=="aria-"){t.removeAttribute(n);return}}t.setAttribute(n,""+a)}}function Ve(t,n,a){if(a===null)t.removeAttribute(n);else{switch(typeof a){case"undefined":case"function":case"symbol":case"boolean":t.removeAttribute(n);return}t.setAttribute(n,""+a)}}function Te(t,n,a,s){if(s===null)t.removeAttribute(a);else{switch(typeof s){case"undefined":case"function":case"symbol":case"boolean":t.removeAttribute(a);return}t.setAttributeNS(n,a,""+s)}}function ne(t){switch(typeof t){case"bigint":case"boolean":case"number":case"string":case"undefined":return t;case"object":return t;default:return""}}function Wt(t){var n=t.type;return(t=t.nodeName)&&t.toLowerCase()==="input"&&(n==="checkbox"||n==="radio")}function on(t,n,a){var s=Object.getOwnPropertyDescriptor(t.constructor.prototype,n);if(!t.hasOwnProperty(n)&&typeof s<"u"&&typeof s.get=="function"&&typeof s.set=="function"){var u=s.get,f=s.set;return Object.defineProperty(t,n,{configurable:!0,get:function(){return u.call(this)},set:function(g){a=""+g,f.call(this,g)}}),Object.defineProperty(t,n,{enumerable:s.enumerable}),{getValue:function(){return a},setValue:function(g){a=""+g},stopTracking:function(){t._valueTracker=null,delete t[n]}}}}function xe(t){if(!t._valueTracker){var n=Wt(t)?"checked":"value";t._valueTracker=on(t,n,""+t[n])}}function Ln(t){if(!t)return!1;var n=t._valueTracker;if(!n)return!0;var a=n.getValue(),s="";return t&&(s=Wt(t)?t.checked?"true":"false":t.value),t=s,t!==a?(n.setValue(t),!0):!1}function hi(t){if(t=t||(typeof document<"u"?document:void 0),typeof t>"u")return null;try{return t.activeElement||t.body}catch{return t.body}}var Cn=/[\n"\\]/g;function fn(t){return t.replace(Cn,function(n){return"\\"+n.charCodeAt(0).toString(16)+" "})}function Ne(t,n,a,s,u,f,g,E){t.name="",g!=null&&typeof g!="function"&&typeof g!="symbol"&&typeof g!="boolean"?t.type=g:t.removeAttribute("type"),n!=null?g==="number"?(n===0&&t.value===""||t.value!=n)&&(t.value=""+ne(n)):t.value!==""+ne(n)&&(t.value=""+ne(n)):g!=="submit"&&g!=="reset"||t.removeAttribute("value"),n!=null?yn(t,g,ne(n)):a!=null?yn(t,g,ne(a)):s!=null&&t.removeAttribute("value"),u==null&&f!=null&&(t.defaultChecked=!!f),u!=null&&(t.checked=u&&typeof u!="function"&&typeof u!="symbol"),E!=null&&typeof E!="function"&&typeof E!="symbol"&&typeof E!="boolean"?t.name=""+ne(E):t.removeAttribute("name")}function wn(t,n,a,s,u,f,g,E){if(f!=null&&typeof f!="function"&&typeof f!="symbol"&&typeof f!="boolean"&&(t.type=f),n!=null||a!=null){if(!(f!=="submit"&&f!=="reset"||n!=null)){xe(t);return}a=a!=null?""+ne(a):"",n=n!=null?""+ne(n):a,E||n===t.value||(t.value=n),t.defaultValue=n}s=s??u,s=typeof s!="function"&&typeof s!="symbol"&&!!s,t.checked=E?t.checked:!!s,t.defaultChecked=!!s,g!=null&&typeof g!="function"&&typeof g!="symbol"&&typeof g!="boolean"&&(t.name=g),xe(t)}function yn(t,n,a){n==="number"&&hi(t.ownerDocument)===t||t.defaultValue===""+a||(t.defaultValue=""+a)}function Ze(t,n,a,s){if(t=t.options,n){n={};for(var u=0;u<a.length;u++)n["$"+a[u]]=!0;for(a=0;a<t.length;a++)u=n.hasOwnProperty("$"+t[a].value),t[a].selected!==u&&(t[a].selected=u),u&&s&&(t[a].defaultSelected=!0)}else{for(a=""+ne(a),n=null,u=0;u<t.length;u++){if(t[u].value===a){t[u].selected=!0,s&&(t[u].defaultSelected=!0);return}n!==null||t[u].disabled||(n=t[u])}n!==null&&(n.selected=!0)}}function gn(t,n,a){if(n!=null&&(n=""+ne(n),n!==t.value&&(t.value=n),a==null)){t.defaultValue!==n&&(t.defaultValue=n);return}t.defaultValue=a!=null?""+ne(a):""}function Er(t,n,a,s){if(n==null){if(s!=null){if(a!=null)throw Error(r(92));if(pt(s)){if(1<s.length)throw Error(r(93));s=s[0]}a=s}a==null&&(a=""),n=a}a=ne(n),t.defaultValue=a,s=t.textContent,s===a&&s!==""&&s!==null&&(t.value=s),xe(t)}function Nn(t,n){if(n){var a=t.firstChild;if(a&&a===t.lastChild&&a.nodeType===3){a.nodeValue=n;return}}t.textContent=n}var J0=new Set("animationIterationCount aspectRatio borderImageOutset borderImageSlice borderImageWidth boxFlex boxFlexGroup boxOrdinalGroup columnCount columns flex flexGrow flexPositive flexShrink flexNegative flexOrder gridArea gridRow gridRowEnd gridRowSpan gridRowStart gridColumn gridColumnEnd gridColumnSpan gridColumnStart fontWeight lineClamp lineHeight opacity order orphans scale tabSize widows zIndex zoom fillOpacity floodOpacity stopOpacity strokeDasharray strokeDashoffset strokeMiterlimit strokeOpacity strokeWidth MozAnimationIterationCount MozBoxFlex MozBoxFlexGroup MozLineClamp msAnimationIterationCount msFlex msZoom msFlexGrow msFlexNegative msFlexOrder msFlexPositive msFlexShrink msGridColumn msGridColumnSpan msGridRow msGridRowSpan WebkitAnimationIterationCount WebkitBoxFlex WebKitBoxFlexGroup WebkitBoxOrdinalGroup WebkitColumnCount WebkitColumns WebkitFlex WebkitFlexGrow WebkitFlexPositive WebkitFlexShrink WebkitLineClamp".split(" "));function Rd(t,n,a){var s=n.indexOf("--")===0;a==null||typeof a=="boolean"||a===""?s?t.setProperty(n,""):n==="float"?t.cssFloat="":t[n]="":s?t.setProperty(n,a):typeof a!="number"||a===0||J0.has(n)?n==="float"?t.cssFloat=a:t[n]=(""+a).trim():t[n]=a+"px"}function Cd(t,n,a){if(n!=null&&typeof n!="object")throw Error(r(62));if(t=t.style,a!=null){for(var s in a)!a.hasOwnProperty(s)||n!=null&&n.hasOwnProperty(s)||(s.indexOf("--")===0?t.setProperty(s,""):s==="float"?t.cssFloat="":t[s]="");for(var u in n)s=n[u],n.hasOwnProperty(u)&&a[u]!==s&&Rd(t,u,s)}else for(var f in n)n.hasOwnProperty(f)&&Rd(t,f,n[f])}function Uu(t){if(t.indexOf("-")===-1)return!1;switch(t){case"annotation-xml":case"color-profile":case"font-face":case"font-face-src":case"font-face-uri":case"font-face-format":case"font-face-name":case"missing-glyph":return!1;default:return!0}}var $0=new Map([["acceptCharset","accept-charset"],["htmlFor","for"],["httpEquiv","http-equiv"],["crossOrigin","crossorigin"],["accentHeight","accent-height"],["alignmentBaseline","alignment-baseline"],["arabicForm","arabic-form"],["baselineShift","baseline-shift"],["capHeight","cap-height"],["clipPath","clip-path"],["clipRule","clip-rule"],["colorInterpolation","color-interpolation"],["colorInterpolationFilters","color-interpolation-filters"],["colorProfile","color-profile"],["colorRendering","color-rendering"],["dominantBaseline","dominant-baseline"],["enableBackground","enable-background"],["fillOpacity","fill-opacity"],["fillRule","fill-rule"],["floodColor","flood-color"],["floodOpacity","flood-opacity"],["fontFamily","font-family"],["fontSize","font-size"],["fontSizeAdjust","font-size-adjust"],["fontStretch","font-stretch"],["fontStyle","font-style"],["fontVariant","font-variant"],["fontWeight","font-weight"],["glyphName","glyph-name"],["glyphOrientationHorizontal","glyph-orientation-horizontal"],["glyphOrientationVertical","glyph-orientation-vertical"],["horizAdvX","horiz-adv-x"],["horizOriginX","horiz-origin-x"],["imageRendering","image-rendering"],["letterSpacing","letter-spacing"],["lightingColor","lighting-color"],["markerEnd","marker-end"],["markerMid","marker-mid"],["markerStart","marker-start"],["overlinePosition","overline-position"],["overlineThickness","overline-thickness"],["paintOrder","paint-order"],["panose-1","panose-1"],["pointerEvents","pointer-events"],["renderingIntent","rendering-intent"],["shapeRendering","shape-rendering"],["stopColor","stop-color"],["stopOpacity","stop-opacity"],["strikethroughPosition","strikethrough-position"],["strikethroughThickness","strikethrough-thickness"],["strokeDasharray","stroke-dasharray"],["strokeDashoffset","stroke-dashoffset"],["strokeLinecap","stroke-linecap"],["strokeLinejoin","stroke-linejoin"],["strokeMiterlimit","stroke-miterlimit"],["strokeOpacity","stroke-opacity"],["strokeWidth","stroke-width"],["textAnchor","text-anchor"],["textDecoration","text-decoration"],["textRendering","text-rendering"],["transformOrigin","transform-origin"],["underlinePosition","underline-position"],["underlineThickness","underline-thickness"],["unicodeBidi","unicode-bidi"],["unicodeRange","unicode-range"],["unitsPerEm","units-per-em"],["vAlphabetic","v-alphabetic"],["vHanging","v-hanging"],["vIdeographic","v-ideographic"],["vMathematical","v-mathematical"],["vectorEffect","vector-effect"],["vertAdvY","vert-adv-y"],["vertOriginX","vert-origin-x"],["vertOriginY","vert-origin-y"],["wordSpacing","word-spacing"],["writingMode","writing-mode"],["xmlnsXlink","xmlns:xlink"],["xHeight","x-height"]]),tv=/^[\u0000-\u001F ]*j[\r\n\t]*a[\r\n\t]*v[\r\n\t]*a[\r\n\t]*s[\r\n\t]*c[\r\n\t]*r[\r\n\t]*i[\r\n\t]*p[\r\n\t]*t[\r\n\t]*:/i;function Io(t){return tv.test(""+t)?"javascript:throw new Error('React has blocked a javascript: URL as a security precaution.')":t}function zi(){}var Lu=null;function Nu(t){return t=t.target||t.srcElement||window,t.correspondingUseElement&&(t=t.correspondingUseElement),t.nodeType===3?t.parentNode:t}var Tr=null,br=null;function wd(t){var n=q(t);if(n&&(t=n.stateNode)){var a=t[mn]||null;t:switch(t=n.stateNode,n.type){case"input":if(Ne(t,a.value,a.defaultValue,a.defaultValue,a.checked,a.defaultChecked,a.type,a.name),n=a.name,a.type==="radio"&&n!=null){for(a=t;a.parentNode;)a=a.parentNode;for(a=a.querySelectorAll('input[name="'+fn(""+n)+'"][type="radio"]'),n=0;n<a.length;n++){var s=a[n];if(s!==t&&s.form===t.form){var u=s[mn]||null;if(!u)throw Error(r(90));Ne(s,u.value,u.defaultValue,u.defaultValue,u.checked,u.defaultChecked,u.type,u.name)}}for(n=0;n<a.length;n++)s=a[n],s.form===t.form&&Ln(s)}break t;case"textarea":gn(t,a.value,a.defaultValue);break t;case"select":n=a.value,n!=null&&Ze(t,!!a.multiple,n,!1)}}}var Ou=!1;function Dd(t,n,a){if(Ou)return t(n,a);Ou=!0;try{var s=t(n);return s}finally{if(Ou=!1,(Tr!==null||br!==null)&&(bl(),Tr&&(n=Tr,t=br,br=Tr=null,wd(n),t)))for(n=0;n<t.length;n++)wd(t[n])}}function Ds(t,n){var a=t.stateNode;if(a===null)return null;var s=a[mn]||null;if(s===null)return null;a=s[n];t:switch(n){case"onClick":case"onClickCapture":case"onDoubleClick":case"onDoubleClickCapture":case"onMouseDown":case"onMouseDownCapture":case"onMouseMove":case"onMouseMoveCapture":case"onMouseUp":case"onMouseUpCapture":case"onMouseEnter":(s=!s.disabled)||(t=t.type,s=!(t==="button"||t==="input"||t==="select"||t==="textarea")),t=!s;break t;default:t=!1}if(t)return null;if(a&&typeof a!="function")throw Error(r(231,n,typeof a));return a}var Pi=!(typeof window>"u"||typeof window.document>"u"||typeof window.document.createElement>"u"),zu=!1;if(Pi)try{var Us={};Object.defineProperty(Us,"passive",{get:function(){zu=!0}}),window.addEventListener("test",Us,Us),window.removeEventListener("test",Us,Us)}catch{zu=!1}var ua=null,Pu=null,Fo=null;function Ud(){if(Fo)return Fo;var t,n=Pu,a=n.length,s,u="value"in ua?ua.value:ua.textContent,f=u.length;for(t=0;t<a&&n[t]===u[t];t++);var g=a-t;for(s=1;s<=g&&n[a-s]===u[f-s];s++);return Fo=u.slice(t,1<s?1-s:void 0)}function Ho(t){var n=t.keyCode;return"charCode"in t?(t=t.charCode,t===0&&n===13&&(t=13)):t=n,t===10&&(t=13),32<=t||t===13?t:0}function Go(){return!0}function Ld(){return!1}function On(t){function n(a,s,u,f,g){this._reactName=a,this._targetInst=u,this.type=s,this.nativeEvent=f,this.target=g,this.currentTarget=null;for(var E in t)t.hasOwnProperty(E)&&(a=t[E],this[E]=a?a(f):f[E]);return this.isDefaultPrevented=(f.defaultPrevented!=null?f.defaultPrevented:f.returnValue===!1)?Go:Ld,this.isPropagationStopped=Ld,this}return v(n.prototype,{preventDefault:function(){this.defaultPrevented=!0;var a=this.nativeEvent;a&&(a.preventDefault?a.preventDefault():typeof a.returnValue!="unknown"&&(a.returnValue=!1),this.isDefaultPrevented=Go)},stopPropagation:function(){var a=this.nativeEvent;a&&(a.stopPropagation?a.stopPropagation():typeof a.cancelBubble!="unknown"&&(a.cancelBubble=!0),this.isPropagationStopped=Go)},persist:function(){},isPersistent:Go}),n}var qa={eventPhase:0,bubbles:0,cancelable:0,timeStamp:function(t){return t.timeStamp||Date.now()},defaultPrevented:0,isTrusted:0},Vo=On(qa),Ls=v({},qa,{view:0,detail:0}),ev=On(Ls),Bu,Iu,Ns,Xo=v({},Ls,{screenX:0,screenY:0,clientX:0,clientY:0,pageX:0,pageY:0,ctrlKey:0,shiftKey:0,altKey:0,metaKey:0,getModifierState:Hu,button:0,buttons:0,relatedTarget:function(t){return t.relatedTarget===void 0?t.fromElement===t.srcElement?t.toElement:t.fromElement:t.relatedTarget},movementX:function(t){return"movementX"in t?t.movementX:(t!==Ns&&(Ns&&t.type==="mousemove"?(Bu=t.screenX-Ns.screenX,Iu=t.screenY-Ns.screenY):Iu=Bu=0,Ns=t),Bu)},movementY:function(t){return"movementY"in t?t.movementY:Iu}}),Nd=On(Xo),nv=v({},Xo,{dataTransfer:0}),iv=On(nv),av=v({},Ls,{relatedTarget:0}),Fu=On(av),rv=v({},qa,{animationName:0,elapsedTime:0,pseudoElement:0}),sv=On(rv),ov=v({},qa,{clipboardData:function(t){return"clipboardData"in t?t.clipboardData:window.clipboardData}}),lv=On(ov),uv=v({},qa,{data:0}),Od=On(uv),cv={Esc:"Escape",Spacebar:" ",Left:"ArrowLeft",Up:"ArrowUp",Right:"ArrowRight",Down:"ArrowDown",Del:"Delete",Win:"OS",Menu:"ContextMenu",Apps:"ContextMenu",Scroll:"ScrollLock",MozPrintableKey:"Unidentified"},fv={8:"Backspace",9:"Tab",12:"Clear",13:"Enter",16:"Shift",17:"Control",18:"Alt",19:"Pause",20:"CapsLock",27:"Escape",32:" ",33:"PageUp",34:"PageDown",35:"End",36:"Home",37:"ArrowLeft",38:"ArrowUp",39:"ArrowRight",40:"ArrowDown",45:"Insert",46:"Delete",112:"F1",113:"F2",114:"F3",115:"F4",116:"F5",117:"F6",118:"F7",119:"F8",120:"F9",121:"F10",122:"F11",123:"F12",144:"NumLock",145:"ScrollLock",224:"Meta"},hv={Alt:"altKey",Control:"ctrlKey",Meta:"metaKey",Shift:"shiftKey"};function dv(t){var n=this.nativeEvent;return n.getModifierState?n.getModifierState(t):(t=hv[t])?!!n[t]:!1}function Hu(){return dv}var pv=v({},Ls,{key:function(t){if(t.key){var n=cv[t.key]||t.key;if(n!=="Unidentified")return n}return t.type==="keypress"?(t=Ho(t),t===13?"Enter":String.fromCharCode(t)):t.type==="keydown"||t.type==="keyup"?fv[t.keyCode]||"Unidentified":""},code:0,location:0,ctrlKey:0,shiftKey:0,altKey:0,metaKey:0,repeat:0,locale:0,getModifierState:Hu,charCode:function(t){return t.type==="keypress"?Ho(t):0},keyCode:function(t){return t.type==="keydown"||t.type==="keyup"?t.keyCode:0},which:function(t){return t.type==="keypress"?Ho(t):t.type==="keydown"||t.type==="keyup"?t.keyCode:0}}),mv=On(pv),gv=v({},Xo,{pointerId:0,width:0,height:0,pressure:0,tangentialPressure:0,tiltX:0,tiltY:0,twist:0,pointerType:0,isPrimary:0}),zd=On(gv),_v=v({},Ls,{touches:0,targetTouches:0,changedTouches:0,altKey:0,metaKey:0,ctrlKey:0,shiftKey:0,getModifierState:Hu}),vv=On(_v),Sv=v({},qa,{propertyName:0,elapsedTime:0,pseudoElement:0}),xv=On(Sv),Mv=v({},Xo,{deltaX:function(t){return"deltaX"in t?t.deltaX:"wheelDeltaX"in t?-t.wheelDeltaX:0},deltaY:function(t){return"deltaY"in t?t.deltaY:"wheelDeltaY"in t?-t.wheelDeltaY:"wheelDelta"in t?-t.wheelDelta:0},deltaZ:0,deltaMode:0}),yv=On(Mv),Ev=v({},qa,{newState:0,oldState:0}),Tv=On(Ev),bv=[9,13,27,32],Gu=Pi&&"CompositionEvent"in window,Os=null;Pi&&"documentMode"in document&&(Os=document.documentMode);var Av=Pi&&"TextEvent"in window&&!Os,Pd=Pi&&(!Gu||Os&&8<Os&&11>=Os),Bd=" ",Id=!1;function Fd(t,n){switch(t){case"keyup":return bv.indexOf(n.keyCode)!==-1;case"keydown":return n.keyCode!==229;case"keypress":case"mousedown":case"focusout":return!0;default:return!1}}function Hd(t){return t=t.detail,typeof t=="object"&&"data"in t?t.data:null}var Ar=!1;function Rv(t,n){switch(t){case"compositionend":return Hd(n);case"keypress":return n.which!==32?null:(Id=!0,Bd);case"textInput":return t=n.data,t===Bd&&Id?null:t;default:return null}}function Cv(t,n){if(Ar)return t==="compositionend"||!Gu&&Fd(t,n)?(t=Ud(),Fo=Pu=ua=null,Ar=!1,t):null;switch(t){case"paste":return null;case"keypress":if(!(n.ctrlKey||n.altKey||n.metaKey)||n.ctrlKey&&n.altKey){if(n.char&&1<n.char.length)return n.char;if(n.which)return String.fromCharCode(n.which)}return null;case"compositionend":return Pd&&n.locale!=="ko"?null:n.data;default:return null}}var wv={color:!0,date:!0,datetime:!0,"datetime-local":!0,email:!0,month:!0,number:!0,password:!0,range:!0,search:!0,tel:!0,text:!0,time:!0,url:!0,week:!0};function Gd(t){var n=t&&t.nodeName&&t.nodeName.toLowerCase();return n==="input"?!!wv[t.type]:n==="textarea"}function Vd(t,n,a,s){Tr?br?br.push(s):br=[s]:Tr=s,n=Ll(n,"onChange"),0<n.length&&(a=new Vo("onChange","change",null,a,s),t.push({event:a,listeners:n}))}var zs=null,Ps=null;function Dv(t){Tg(t,0)}function ko(t){var n=it(t);if(Ln(n))return t}function Xd(t,n){if(t==="change")return n}var kd=!1;if(Pi){var Vu;if(Pi){var Xu="oninput"in document;if(!Xu){var Wd=document.createElement("div");Wd.setAttribute("oninput","return;"),Xu=typeof Wd.oninput=="function"}Vu=Xu}else Vu=!1;kd=Vu&&(!document.documentMode||9<document.documentMode)}function qd(){zs&&(zs.detachEvent("onpropertychange",Yd),Ps=zs=null)}function Yd(t){if(t.propertyName==="value"&&ko(Ps)){var n=[];Vd(n,Ps,t,Nu(t)),Dd(Dv,n)}}function Uv(t,n,a){t==="focusin"?(qd(),zs=n,Ps=a,zs.attachEvent("onpropertychange",Yd)):t==="focusout"&&qd()}function Lv(t){if(t==="selectionchange"||t==="keyup"||t==="keydown")return ko(Ps)}function Nv(t,n){if(t==="click")return ko(n)}function Ov(t,n){if(t==="input"||t==="change")return ko(n)}function zv(t,n){return t===n&&(t!==0||1/t===1/n)||t!==t&&n!==n}var Xn=typeof Object.is=="function"?Object.is:zv;function Bs(t,n){if(Xn(t,n))return!0;if(typeof t!="object"||t===null||typeof n!="object"||n===null)return!1;var a=Object.keys(t),s=Object.keys(n);if(a.length!==s.length)return!1;for(s=0;s<a.length;s++){var u=a[s];if(!we.call(n,u)||!Xn(t[u],n[u]))return!1}return!0}function jd(t){for(;t&&t.firstChild;)t=t.firstChild;return t}function Zd(t,n){var a=jd(t);t=0;for(var s;a;){if(a.nodeType===3){if(s=t+a.textContent.length,t<=n&&s>=n)return{node:a,offset:n-t};t=s}t:{for(;a;){if(a.nextSibling){a=a.nextSibling;break t}a=a.parentNode}a=void 0}a=jd(a)}}function Kd(t,n){return t&&n?t===n?!0:t&&t.nodeType===3?!1:n&&n.nodeType===3?Kd(t,n.parentNode):"contains"in t?t.contains(n):t.compareDocumentPosition?!!(t.compareDocumentPosition(n)&16):!1:!1}function Qd(t){t=t!=null&&t.ownerDocument!=null&&t.ownerDocument.defaultView!=null?t.ownerDocument.defaultView:window;for(var n=hi(t.document);n instanceof t.HTMLIFrameElement;){try{var a=typeof n.contentWindow.location.href=="string"}catch{a=!1}if(a)t=n.contentWindow;else break;n=hi(t.document)}return n}function ku(t){var n=t&&t.nodeName&&t.nodeName.toLowerCase();return n&&(n==="input"&&(t.type==="text"||t.type==="search"||t.type==="tel"||t.type==="url"||t.type==="password")||n==="textarea"||t.contentEditable==="true")}var Pv=Pi&&"documentMode"in document&&11>=document.documentMode,Rr=null,Wu=null,Is=null,qu=!1;function Jd(t,n,a){var s=a.window===a?a.document:a.nodeType===9?a:a.ownerDocument;qu||Rr==null||Rr!==hi(s)||(s=Rr,"selectionStart"in s&&ku(s)?s={start:s.selectionStart,end:s.selectionEnd}:(s=(s.ownerDocument&&s.ownerDocument.defaultView||window).getSelection(),s={anchorNode:s.anchorNode,anchorOffset:s.anchorOffset,focusNode:s.focusNode,focusOffset:s.focusOffset}),Is&&Bs(Is,s)||(Is=s,s=Ll(Wu,"onSelect"),0<s.length&&(n=new Vo("onSelect","select",null,n,a),t.push({event:n,listeners:s}),n.target=Rr)))}function Ya(t,n){var a={};return a[t.toLowerCase()]=n.toLowerCase(),a["Webkit"+t]="webkit"+n,a["Moz"+t]="moz"+n,a}var Cr={animationend:Ya("Animation","AnimationEnd"),animationiteration:Ya("Animation","AnimationIteration"),animationstart:Ya("Animation","AnimationStart"),transitionrun:Ya("Transition","TransitionRun"),transitionstart:Ya("Transition","TransitionStart"),transitioncancel:Ya("Transition","TransitionCancel"),transitionend:Ya("Transition","TransitionEnd")},Yu={},$d={};Pi&&($d=document.createElement("div").style,"AnimationEvent"in window||(delete Cr.animationend.animation,delete Cr.animationiteration.animation,delete Cr.animationstart.animation),"TransitionEvent"in window||delete Cr.transitionend.transition);function ja(t){if(Yu[t])return Yu[t];if(!Cr[t])return t;var n=Cr[t],a;for(a in n)if(n.hasOwnProperty(a)&&a in $d)return Yu[t]=n[a];return t}var tp=ja("animationend"),ep=ja("animationiteration"),np=ja("animationstart"),Bv=ja("transitionrun"),Iv=ja("transitionstart"),Fv=ja("transitioncancel"),ip=ja("transitionend"),ap=new Map,ju="abort auxClick beforeToggle cancel canPlay canPlayThrough click close contextMenu copy cut drag dragEnd dragEnter dragExit dragLeave dragOver dragStart drop durationChange emptied encrypted ended error gotPointerCapture input invalid keyDown keyPress keyUp load loadedData loadedMetadata loadStart lostPointerCapture mouseDown mouseMove mouseOut mouseOver mouseUp paste pause play playing pointerCancel pointerDown pointerMove pointerOut pointerOver pointerUp progress rateChange reset resize seeked seeking stalled submit suspend timeUpdate touchCancel touchEnd touchStart volumeChange scroll toggle touchMove waiting wheel".split(" ");ju.push("scrollEnd");function di(t,n){ap.set(t,n),Lt(n,[t])}var Wo=typeof reportError=="function"?reportError:function(t){if(typeof window=="object"&&typeof window.ErrorEvent=="function"){var n=new window.ErrorEvent("error",{bubbles:!0,cancelable:!0,message:typeof t=="object"&&t!==null&&typeof t.message=="string"?String(t.message):String(t),error:t});if(!window.dispatchEvent(n))return}else if(typeof process=="object"&&typeof process.emit=="function"){process.emit("uncaughtException",t);return}console.error(t)},$n=[],wr=0,Zu=0;function qo(){for(var t=wr,n=Zu=wr=0;n<t;){var a=$n[n];$n[n++]=null;var s=$n[n];$n[n++]=null;var u=$n[n];$n[n++]=null;var f=$n[n];if($n[n++]=null,s!==null&&u!==null){var g=s.pending;g===null?u.next=u:(u.next=g.next,g.next=u),s.pending=u}f!==0&&rp(a,u,f)}}function Yo(t,n,a,s){$n[wr++]=t,$n[wr++]=n,$n[wr++]=a,$n[wr++]=s,Zu|=s,t.lanes|=s,t=t.alternate,t!==null&&(t.lanes|=s)}function Ku(t,n,a,s){return Yo(t,n,a,s),jo(t)}function Za(t,n){return Yo(t,null,null,n),jo(t)}function rp(t,n,a){t.lanes|=a;var s=t.alternate;s!==null&&(s.lanes|=a);for(var u=!1,f=t.return;f!==null;)f.childLanes|=a,s=f.alternate,s!==null&&(s.childLanes|=a),f.tag===22&&(t=f.stateNode,t===null||t._visibility&1||(u=!0)),t=f,f=f.return;return t.tag===3?(f=t.stateNode,u&&n!==null&&(u=31-$t(a),t=f.hiddenUpdates,s=t[u],s===null?t[u]=[n]:s.push(n),n.lane=a|536870912),f):null}function jo(t){if(50<so)throw so=0,sf=null,Error(r(185));for(var n=t.return;n!==null;)t=n,n=t.return;return t.tag===3?t.stateNode:null}var Dr={};function Hv(t,n,a,s){this.tag=t,this.key=a,this.sibling=this.child=this.return=this.stateNode=this.type=this.elementType=null,this.index=0,this.refCleanup=this.ref=null,this.pendingProps=n,this.dependencies=this.memoizedState=this.updateQueue=this.memoizedProps=null,this.mode=s,this.subtreeFlags=this.flags=0,this.deletions=null,this.childLanes=this.lanes=0,this.alternate=null}function kn(t,n,a,s){return new Hv(t,n,a,s)}function Qu(t){return t=t.prototype,!(!t||!t.isReactComponent)}function Bi(t,n){var a=t.alternate;return a===null?(a=kn(t.tag,n,t.key,t.mode),a.elementType=t.elementType,a.type=t.type,a.stateNode=t.stateNode,a.alternate=t,t.alternate=a):(a.pendingProps=n,a.type=t.type,a.flags=0,a.subtreeFlags=0,a.deletions=null),a.flags=t.flags&65011712,a.childLanes=t.childLanes,a.lanes=t.lanes,a.child=t.child,a.memoizedProps=t.memoizedProps,a.memoizedState=t.memoizedState,a.updateQueue=t.updateQueue,n=t.dependencies,a.dependencies=n===null?null:{lanes:n.lanes,firstContext:n.firstContext},a.sibling=t.sibling,a.index=t.index,a.ref=t.ref,a.refCleanup=t.refCleanup,a}function sp(t,n){t.flags&=65011714;var a=t.alternate;return a===null?(t.childLanes=0,t.lanes=n,t.child=null,t.subtreeFlags=0,t.memoizedProps=null,t.memoizedState=null,t.updateQueue=null,t.dependencies=null,t.stateNode=null):(t.childLanes=a.childLanes,t.lanes=a.lanes,t.child=a.child,t.subtreeFlags=0,t.deletions=null,t.memoizedProps=a.memoizedProps,t.memoizedState=a.memoizedState,t.updateQueue=a.updateQueue,t.type=a.type,n=a.dependencies,t.dependencies=n===null?null:{lanes:n.lanes,firstContext:n.firstContext}),t}function Zo(t,n,a,s,u,f){var g=0;if(s=t,typeof t=="function")Qu(t)&&(g=1);else if(typeof t=="string")g=WS(t,a,K.current)?26:t==="html"||t==="head"||t==="body"?27:5;else t:switch(t){case D:return t=kn(31,a,n,u),t.elementType=D,t.lanes=f,t;case w:return Ka(a.children,u,f,n);case M:g=8,u|=24;break;case _:return t=kn(12,a,n,u|2),t.elementType=_,t.lanes=f,t;case G:return t=kn(13,a,n,u),t.elementType=G,t.lanes=f,t;case I:return t=kn(19,a,n,u),t.elementType=I,t.lanes=f,t;default:if(typeof t=="object"&&t!==null)switch(t.$$typeof){case U:g=10;break t;case L:g=9;break t;case C:g=11;break t;case O:g=14;break t;case V:g=16,s=null;break t}g=29,a=Error(r(130,t===null?"null":typeof t,"")),s=null}return n=kn(g,a,n,u),n.elementType=t,n.type=s,n.lanes=f,n}function Ka(t,n,a,s){return t=kn(7,t,s,n),t.lanes=a,t}function Ju(t,n,a){return t=kn(6,t,null,n),t.lanes=a,t}function op(t){var n=kn(18,null,null,0);return n.stateNode=t,n}function $u(t,n,a){return n=kn(4,t.children!==null?t.children:[],t.key,n),n.lanes=a,n.stateNode={containerInfo:t.containerInfo,pendingChildren:null,implementation:t.implementation},n}var lp=new WeakMap;function ti(t,n){if(typeof t=="object"&&t!==null){var a=lp.get(t);return a!==void 0?a:(n={value:t,source:n,stack:Vt(n)},lp.set(t,n),n)}return{value:t,source:n,stack:Vt(n)}}var Ur=[],Lr=0,Ko=null,Fs=0,ei=[],ni=0,ca=null,Ti=1,bi="";function Ii(t,n){Ur[Lr++]=Fs,Ur[Lr++]=Ko,Ko=t,Fs=n}function up(t,n,a){ei[ni++]=Ti,ei[ni++]=bi,ei[ni++]=ca,ca=t;var s=Ti;t=bi;var u=32-$t(s)-1;s&=~(1<<u),a+=1;var f=32-$t(n)+u;if(30<f){var g=u-u%5;f=(s&(1<<g)-1).toString(32),s>>=g,u-=g,Ti=1<<32-$t(n)+u|a<<u|s,bi=f+t}else Ti=1<<f|a<<u|s,bi=t}function tc(t){t.return!==null&&(Ii(t,1),up(t,1,0))}function ec(t){for(;t===Ko;)Ko=Ur[--Lr],Ur[Lr]=null,Fs=Ur[--Lr],Ur[Lr]=null;for(;t===ca;)ca=ei[--ni],ei[ni]=null,bi=ei[--ni],ei[ni]=null,Ti=ei[--ni],ei[ni]=null}function cp(t,n){ei[ni++]=Ti,ei[ni++]=bi,ei[ni++]=ca,Ti=n.id,bi=n.overflow,ca=t}var _n=null,Xe=null,ve=!1,fa=null,ii=!1,nc=Error(r(519));function ha(t){var n=Error(r(418,1<arguments.length&&arguments[1]!==void 0&&arguments[1]?"text":"HTML",""));throw Hs(ti(n,t)),nc}function fp(t){var n=t.stateNode,a=t.type,s=t.memoizedProps;switch(n[je]=t,n[mn]=s,a){case"dialog":he("cancel",n),he("close",n);break;case"iframe":case"object":case"embed":he("load",n);break;case"video":case"audio":for(a=0;a<lo.length;a++)he(lo[a],n);break;case"source":he("error",n);break;case"img":case"image":case"link":he("error",n),he("load",n);break;case"details":he("toggle",n);break;case"input":he("invalid",n),wn(n,s.value,s.defaultValue,s.checked,s.defaultChecked,s.type,s.name,!0);break;case"select":he("invalid",n);break;case"textarea":he("invalid",n),Er(n,s.value,s.defaultValue,s.children)}a=s.children,typeof a!="string"&&typeof a!="number"&&typeof a!="bigint"||n.textContent===""+a||s.suppressHydrationWarning===!0||Cg(n.textContent,a)?(s.popover!=null&&(he("beforetoggle",n),he("toggle",n)),s.onScroll!=null&&he("scroll",n),s.onScrollEnd!=null&&he("scrollend",n),s.onClick!=null&&(n.onclick=zi),n=!0):n=!1,n||ha(t,!0)}function hp(t){for(_n=t.return;_n;)switch(_n.tag){case 5:case 31:case 13:ii=!1;return;case 27:case 3:ii=!0;return;default:_n=_n.return}}function Nr(t){if(t!==_n)return!1;if(!ve)return hp(t),ve=!0,!1;var n=t.tag,a;if((a=n!==3&&n!==27)&&((a=n===5)&&(a=t.type,a=!(a!=="form"&&a!=="button")||Mf(t.type,t.memoizedProps)),a=!a),a&&Xe&&ha(t),hp(t),n===13){if(t=t.memoizedState,t=t!==null?t.dehydrated:null,!t)throw Error(r(317));Xe=Bg(t)}else if(n===31){if(t=t.memoizedState,t=t!==null?t.dehydrated:null,!t)throw Error(r(317));Xe=Bg(t)}else n===27?(n=Xe,Aa(t.type)?(t=Af,Af=null,Xe=t):Xe=n):Xe=_n?ri(t.stateNode.nextSibling):null;return!0}function Qa(){Xe=_n=null,ve=!1}function ic(){var t=fa;return t!==null&&(In===null?In=t:In.push.apply(In,t),fa=null),t}function Hs(t){fa===null?fa=[t]:fa.push(t)}var ac=z(null),Ja=null,Fi=null;function da(t,n,a){xt(ac,n._currentValue),n._currentValue=a}function Hi(t){t._currentValue=ac.current,nt(ac)}function rc(t,n,a){for(;t!==null;){var s=t.alternate;if((t.childLanes&n)!==n?(t.childLanes|=n,s!==null&&(s.childLanes|=n)):s!==null&&(s.childLanes&n)!==n&&(s.childLanes|=n),t===a)break;t=t.return}}function sc(t,n,a,s){var u=t.child;for(u!==null&&(u.return=t);u!==null;){var f=u.dependencies;if(f!==null){var g=u.child;f=f.firstContext;t:for(;f!==null;){var E=f;f=u;for(var F=0;F<n.length;F++)if(E.context===n[F]){f.lanes|=a,E=f.alternate,E!==null&&(E.lanes|=a),rc(f.return,a,t),s||(g=null);break t}f=E.next}}else if(u.tag===18){if(g=u.return,g===null)throw Error(r(341));g.lanes|=a,f=g.alternate,f!==null&&(f.lanes|=a),rc(g,a,t),g=null}else g=u.child;if(g!==null)g.return=u;else for(g=u;g!==null;){if(g===t){g=null;break}if(u=g.sibling,u!==null){u.return=g.return,g=u;break}g=g.return}u=g}}function Or(t,n,a,s){t=null;for(var u=n,f=!1;u!==null;){if(!f){if((u.flags&524288)!==0)f=!0;else if((u.flags&262144)!==0)break}if(u.tag===10){var g=u.alternate;if(g===null)throw Error(r(387));if(g=g.memoizedProps,g!==null){var E=u.type;Xn(u.pendingProps.value,g.value)||(t!==null?t.push(E):t=[E])}}else if(u===St.current){if(g=u.alternate,g===null)throw Error(r(387));g.memoizedState.memoizedState!==u.memoizedState.memoizedState&&(t!==null?t.push(po):t=[po])}u=u.return}t!==null&&sc(n,t,a,s),n.flags|=262144}function Qo(t){for(t=t.firstContext;t!==null;){if(!Xn(t.context._currentValue,t.memoizedValue))return!0;t=t.next}return!1}function $a(t){Ja=t,Fi=null,t=t.dependencies,t!==null&&(t.firstContext=null)}function vn(t){return dp(Ja,t)}function Jo(t,n){return Ja===null&&$a(t),dp(t,n)}function dp(t,n){var a=n._currentValue;if(n={context:n,memoizedValue:a,next:null},Fi===null){if(t===null)throw Error(r(308));Fi=n,t.dependencies={lanes:0,firstContext:n},t.flags|=524288}else Fi=Fi.next=n;return a}var Gv=typeof AbortController<"u"?AbortController:function(){var t=[],n=this.signal={aborted:!1,addEventListener:function(a,s){t.push(s)}};this.abort=function(){n.aborted=!0,t.forEach(function(a){return a()})}},Vv=o.unstable_scheduleCallback,Xv=o.unstable_NormalPriority,tn={$$typeof:U,Consumer:null,Provider:null,_currentValue:null,_currentValue2:null,_threadCount:0};function oc(){return{controller:new Gv,data:new Map,refCount:0}}function Gs(t){t.refCount--,t.refCount===0&&Vv(Xv,function(){t.controller.abort()})}var Vs=null,lc=0,zr=0,Pr=null;function kv(t,n){if(Vs===null){var a=Vs=[];lc=0,zr=hf(),Pr={status:"pending",value:void 0,then:function(s){a.push(s)}}}return lc++,n.then(pp,pp),n}function pp(){if(--lc===0&&Vs!==null){Pr!==null&&(Pr.status="fulfilled");var t=Vs;Vs=null,zr=0,Pr=null;for(var n=0;n<t.length;n++)(0,t[n])()}}function Wv(t,n){var a=[],s={status:"pending",value:null,reason:null,then:function(u){a.push(u)}};return t.then(function(){s.status="fulfilled",s.value=n;for(var u=0;u<a.length;u++)(0,a[u])(n)},function(u){for(s.status="rejected",s.reason=u,u=0;u<a.length;u++)(0,a[u])(void 0)}),s}var mp=P.S;P.S=function(t,n){Jm=ct(),typeof n=="object"&&n!==null&&typeof n.then=="function"&&kv(t,n),mp!==null&&mp(t,n)};var tr=z(null);function uc(){var t=tr.current;return t!==null?t:He.pooledCache}function $o(t,n){n===null?xt(tr,tr.current):xt(tr,n.pool)}function gp(){var t=uc();return t===null?null:{parent:tn._currentValue,pool:t}}var Br=Error(r(460)),cc=Error(r(474)),tl=Error(r(542)),el={then:function(){}};function _p(t){return t=t.status,t==="fulfilled"||t==="rejected"}function vp(t,n,a){switch(a=t[a],a===void 0?t.push(n):a!==n&&(n.then(zi,zi),n=a),n.status){case"fulfilled":return n.value;case"rejected":throw t=n.reason,xp(t),t;default:if(typeof n.status=="string")n.then(zi,zi);else{if(t=He,t!==null&&100<t.shellSuspendCounter)throw Error(r(482));t=n,t.status="pending",t.then(function(s){if(n.status==="pending"){var u=n;u.status="fulfilled",u.value=s}},function(s){if(n.status==="pending"){var u=n;u.status="rejected",u.reason=s}})}switch(n.status){case"fulfilled":return n.value;case"rejected":throw t=n.reason,xp(t),t}throw nr=n,Br}}function er(t){try{var n=t._init;return n(t._payload)}catch(a){throw a!==null&&typeof a=="object"&&typeof a.then=="function"?(nr=a,Br):a}}var nr=null;function Sp(){if(nr===null)throw Error(r(459));var t=nr;return nr=null,t}function xp(t){if(t===Br||t===tl)throw Error(r(483))}var Ir=null,Xs=0;function nl(t){var n=Xs;return Xs+=1,Ir===null&&(Ir=[]),vp(Ir,t,n)}function ks(t,n){n=n.props.ref,t.ref=n!==void 0?n:null}function il(t,n){throw n.$$typeof===x?Error(r(525)):(t=Object.prototype.toString.call(n),Error(r(31,t==="[object Object]"?"object with keys {"+Object.keys(n).join(", ")+"}":t)))}function Mp(t){function n(Z,X){if(t){var J=Z.deletions;J===null?(Z.deletions=[X],Z.flags|=16):J.push(X)}}function a(Z,X){if(!t)return null;for(;X!==null;)n(Z,X),X=X.sibling;return null}function s(Z){for(var X=new Map;Z!==null;)Z.key!==null?X.set(Z.key,Z):X.set(Z.index,Z),Z=Z.sibling;return X}function u(Z,X){return Z=Bi(Z,X),Z.index=0,Z.sibling=null,Z}function f(Z,X,J){return Z.index=J,t?(J=Z.alternate,J!==null?(J=J.index,J<X?(Z.flags|=67108866,X):J):(Z.flags|=67108866,X)):(Z.flags|=1048576,X)}function g(Z){return t&&Z.alternate===null&&(Z.flags|=67108866),Z}function E(Z,X,J,ht){return X===null||X.tag!==6?(X=Ju(J,Z.mode,ht),X.return=Z,X):(X=u(X,J),X.return=Z,X)}function F(Z,X,J,ht){var kt=J.type;return kt===w?ut(Z,X,J.props.children,ht,J.key):X!==null&&(X.elementType===kt||typeof kt=="object"&&kt!==null&&kt.$$typeof===V&&er(kt)===X.type)?(X=u(X,J.props),ks(X,J),X.return=Z,X):(X=Zo(J.type,J.key,J.props,null,Z.mode,ht),ks(X,J),X.return=Z,X)}function $(Z,X,J,ht){return X===null||X.tag!==4||X.stateNode.containerInfo!==J.containerInfo||X.stateNode.implementation!==J.implementation?(X=$u(J,Z.mode,ht),X.return=Z,X):(X=u(X,J.children||[]),X.return=Z,X)}function ut(Z,X,J,ht,kt){return X===null||X.tag!==7?(X=Ka(J,Z.mode,ht,kt),X.return=Z,X):(X=u(X,J),X.return=Z,X)}function gt(Z,X,J){if(typeof X=="string"&&X!==""||typeof X=="number"||typeof X=="bigint")return X=Ju(""+X,Z.mode,J),X.return=Z,X;if(typeof X=="object"&&X!==null){switch(X.$$typeof){case y:return J=Zo(X.type,X.key,X.props,null,Z.mode,J),ks(J,X),J.return=Z,J;case R:return X=$u(X,Z.mode,J),X.return=Z,X;case V:return X=er(X),gt(Z,X,J)}if(pt(X)||rt(X))return X=Ka(X,Z.mode,J,null),X.return=Z,X;if(typeof X.then=="function")return gt(Z,nl(X),J);if(X.$$typeof===U)return gt(Z,Jo(Z,X),J);il(Z,X)}return null}function tt(Z,X,J,ht){var kt=X!==null?X.key:null;if(typeof J=="string"&&J!==""||typeof J=="number"||typeof J=="bigint")return kt!==null?null:E(Z,X,""+J,ht);if(typeof J=="object"&&J!==null){switch(J.$$typeof){case y:return J.key===kt?F(Z,X,J,ht):null;case R:return J.key===kt?$(Z,X,J,ht):null;case V:return J=er(J),tt(Z,X,J,ht)}if(pt(J)||rt(J))return kt!==null?null:ut(Z,X,J,ht,null);if(typeof J.then=="function")return tt(Z,X,nl(J),ht);if(J.$$typeof===U)return tt(Z,X,Jo(Z,J),ht);il(Z,J)}return null}function ot(Z,X,J,ht,kt){if(typeof ht=="string"&&ht!==""||typeof ht=="number"||typeof ht=="bigint")return Z=Z.get(J)||null,E(X,Z,""+ht,kt);if(typeof ht=="object"&&ht!==null){switch(ht.$$typeof){case y:return Z=Z.get(ht.key===null?J:ht.key)||null,F(X,Z,ht,kt);case R:return Z=Z.get(ht.key===null?J:ht.key)||null,$(X,Z,ht,kt);case V:return ht=er(ht),ot(Z,X,J,ht,kt)}if(pt(ht)||rt(ht))return Z=Z.get(J)||null,ut(X,Z,ht,kt,null);if(typeof ht.then=="function")return ot(Z,X,J,nl(ht),kt);if(ht.$$typeof===U)return ot(Z,X,J,Jo(X,ht),kt);il(X,ht)}return null}function Bt(Z,X,J,ht){for(var kt=null,be=null,It=X,se=X=0,me=null;It!==null&&se<J.length;se++){It.index>se?(me=It,It=null):me=It.sibling;var Ae=tt(Z,It,J[se],ht);if(Ae===null){It===null&&(It=me);break}t&&It&&Ae.alternate===null&&n(Z,It),X=f(Ae,X,se),be===null?kt=Ae:be.sibling=Ae,be=Ae,It=me}if(se===J.length)return a(Z,It),ve&&Ii(Z,se),kt;if(It===null){for(;se<J.length;se++)It=gt(Z,J[se],ht),It!==null&&(X=f(It,X,se),be===null?kt=It:be.sibling=It,be=It);return ve&&Ii(Z,se),kt}for(It=s(It);se<J.length;se++)me=ot(It,Z,se,J[se],ht),me!==null&&(t&&me.alternate!==null&&It.delete(me.key===null?se:me.key),X=f(me,X,se),be===null?kt=me:be.sibling=me,be=me);return t&&It.forEach(function(Ua){return n(Z,Ua)}),ve&&Ii(Z,se),kt}function Kt(Z,X,J,ht){if(J==null)throw Error(r(151));for(var kt=null,be=null,It=X,se=X=0,me=null,Ae=J.next();It!==null&&!Ae.done;se++,Ae=J.next()){It.index>se?(me=It,It=null):me=It.sibling;var Ua=tt(Z,It,Ae.value,ht);if(Ua===null){It===null&&(It=me);break}t&&It&&Ua.alternate===null&&n(Z,It),X=f(Ua,X,se),be===null?kt=Ua:be.sibling=Ua,be=Ua,It=me}if(Ae.done)return a(Z,It),ve&&Ii(Z,se),kt;if(It===null){for(;!Ae.done;se++,Ae=J.next())Ae=gt(Z,Ae.value,ht),Ae!==null&&(X=f(Ae,X,se),be===null?kt=Ae:be.sibling=Ae,be=Ae);return ve&&Ii(Z,se),kt}for(It=s(It);!Ae.done;se++,Ae=J.next())Ae=ot(It,Z,se,Ae.value,ht),Ae!==null&&(t&&Ae.alternate!==null&&It.delete(Ae.key===null?se:Ae.key),X=f(Ae,X,se),be===null?kt=Ae:be.sibling=Ae,be=Ae);return t&&It.forEach(function(nx){return n(Z,nx)}),ve&&Ii(Z,se),kt}function Pe(Z,X,J,ht){if(typeof J=="object"&&J!==null&&J.type===w&&J.key===null&&(J=J.props.children),typeof J=="object"&&J!==null){switch(J.$$typeof){case y:t:{for(var kt=J.key;X!==null;){if(X.key===kt){if(kt=J.type,kt===w){if(X.tag===7){a(Z,X.sibling),ht=u(X,J.props.children),ht.return=Z,Z=ht;break t}}else if(X.elementType===kt||typeof kt=="object"&&kt!==null&&kt.$$typeof===V&&er(kt)===X.type){a(Z,X.sibling),ht=u(X,J.props),ks(ht,J),ht.return=Z,Z=ht;break t}a(Z,X);break}else n(Z,X);X=X.sibling}J.type===w?(ht=Ka(J.props.children,Z.mode,ht,J.key),ht.return=Z,Z=ht):(ht=Zo(J.type,J.key,J.props,null,Z.mode,ht),ks(ht,J),ht.return=Z,Z=ht)}return g(Z);case R:t:{for(kt=J.key;X!==null;){if(X.key===kt)if(X.tag===4&&X.stateNode.containerInfo===J.containerInfo&&X.stateNode.implementation===J.implementation){a(Z,X.sibling),ht=u(X,J.children||[]),ht.return=Z,Z=ht;break t}else{a(Z,X);break}else n(Z,X);X=X.sibling}ht=$u(J,Z.mode,ht),ht.return=Z,Z=ht}return g(Z);case V:return J=er(J),Pe(Z,X,J,ht)}if(pt(J))return Bt(Z,X,J,ht);if(rt(J)){if(kt=rt(J),typeof kt!="function")throw Error(r(150));return J=kt.call(J),Kt(Z,X,J,ht)}if(typeof J.then=="function")return Pe(Z,X,nl(J),ht);if(J.$$typeof===U)return Pe(Z,X,Jo(Z,J),ht);il(Z,J)}return typeof J=="string"&&J!==""||typeof J=="number"||typeof J=="bigint"?(J=""+J,X!==null&&X.tag===6?(a(Z,X.sibling),ht=u(X,J),ht.return=Z,Z=ht):(a(Z,X),ht=Ju(J,Z.mode,ht),ht.return=Z,Z=ht),g(Z)):a(Z,X)}return function(Z,X,J,ht){try{Xs=0;var kt=Pe(Z,X,J,ht);return Ir=null,kt}catch(It){if(It===Br||It===tl)throw It;var be=kn(29,It,null,Z.mode);return be.lanes=ht,be.return=Z,be}finally{}}}var ir=Mp(!0),yp=Mp(!1),pa=!1;function fc(t){t.updateQueue={baseState:t.memoizedState,firstBaseUpdate:null,lastBaseUpdate:null,shared:{pending:null,lanes:0,hiddenCallbacks:null},callbacks:null}}function hc(t,n){t=t.updateQueue,n.updateQueue===t&&(n.updateQueue={baseState:t.baseState,firstBaseUpdate:t.firstBaseUpdate,lastBaseUpdate:t.lastBaseUpdate,shared:t.shared,callbacks:null})}function ma(t){return{lane:t,tag:0,payload:null,callback:null,next:null}}function ga(t,n,a){var s=t.updateQueue;if(s===null)return null;if(s=s.shared,(Ce&2)!==0){var u=s.pending;return u===null?n.next=n:(n.next=u.next,u.next=n),s.pending=n,n=jo(t),rp(t,null,a),n}return Yo(t,s,n,a),jo(t)}function Ws(t,n,a){if(n=n.updateQueue,n!==null&&(n=n.shared,(a&4194048)!==0)){var s=n.lanes;s&=t.pendingLanes,a|=s,n.lanes=a,As(t,a)}}function dc(t,n){var a=t.updateQueue,s=t.alternate;if(s!==null&&(s=s.updateQueue,a===s)){var u=null,f=null;if(a=a.firstBaseUpdate,a!==null){do{var g={lane:a.lane,tag:a.tag,payload:a.payload,callback:null,next:null};f===null?u=f=g:f=f.next=g,a=a.next}while(a!==null);f===null?u=f=n:f=f.next=n}else u=f=n;a={baseState:s.baseState,firstBaseUpdate:u,lastBaseUpdate:f,shared:s.shared,callbacks:s.callbacks},t.updateQueue=a;return}t=a.lastBaseUpdate,t===null?a.firstBaseUpdate=n:t.next=n,a.lastBaseUpdate=n}var pc=!1;function qs(){if(pc){var t=Pr;if(t!==null)throw t}}function Ys(t,n,a,s){pc=!1;var u=t.updateQueue;pa=!1;var f=u.firstBaseUpdate,g=u.lastBaseUpdate,E=u.shared.pending;if(E!==null){u.shared.pending=null;var F=E,$=F.next;F.next=null,g===null?f=$:g.next=$,g=F;var ut=t.alternate;ut!==null&&(ut=ut.updateQueue,E=ut.lastBaseUpdate,E!==g&&(E===null?ut.firstBaseUpdate=$:E.next=$,ut.lastBaseUpdate=F))}if(f!==null){var gt=u.baseState;g=0,ut=$=F=null,E=f;do{var tt=E.lane&-536870913,ot=tt!==E.lane;if(ot?(pe&tt)===tt:(s&tt)===tt){tt!==0&&tt===zr&&(pc=!0),ut!==null&&(ut=ut.next={lane:0,tag:E.tag,payload:E.payload,callback:null,next:null});t:{var Bt=t,Kt=E;tt=n;var Pe=a;switch(Kt.tag){case 1:if(Bt=Kt.payload,typeof Bt=="function"){gt=Bt.call(Pe,gt,tt);break t}gt=Bt;break t;case 3:Bt.flags=Bt.flags&-65537|128;case 0:if(Bt=Kt.payload,tt=typeof Bt=="function"?Bt.call(Pe,gt,tt):Bt,tt==null)break t;gt=v({},gt,tt);break t;case 2:pa=!0}}tt=E.callback,tt!==null&&(t.flags|=64,ot&&(t.flags|=8192),ot=u.callbacks,ot===null?u.callbacks=[tt]:ot.push(tt))}else ot={lane:tt,tag:E.tag,payload:E.payload,callback:E.callback,next:null},ut===null?($=ut=ot,F=gt):ut=ut.next=ot,g|=tt;if(E=E.next,E===null){if(E=u.shared.pending,E===null)break;ot=E,E=ot.next,ot.next=null,u.lastBaseUpdate=ot,u.shared.pending=null}}while(!0);ut===null&&(F=gt),u.baseState=F,u.firstBaseUpdate=$,u.lastBaseUpdate=ut,f===null&&(u.shared.lanes=0),Ma|=g,t.lanes=g,t.memoizedState=gt}}function Ep(t,n){if(typeof t!="function")throw Error(r(191,t));t.call(n)}function Tp(t,n){var a=t.callbacks;if(a!==null)for(t.callbacks=null,t=0;t<a.length;t++)Ep(a[t],n)}var Fr=z(null),al=z(0);function bp(t,n){t=Zi,xt(al,t),xt(Fr,n),Zi=t|n.baseLanes}function mc(){xt(al,Zi),xt(Fr,Fr.current)}function gc(){Zi=al.current,nt(Fr),nt(al)}var Wn=z(null),ai=null;function _a(t){var n=t.alternate;xt(Je,Je.current&1),xt(Wn,t),ai===null&&(n===null||Fr.current!==null||n.memoizedState!==null)&&(ai=t)}function _c(t){xt(Je,Je.current),xt(Wn,t),ai===null&&(ai=t)}function Ap(t){t.tag===22?(xt(Je,Je.current),xt(Wn,t),ai===null&&(ai=t)):va()}function va(){xt(Je,Je.current),xt(Wn,Wn.current)}function qn(t){nt(Wn),ai===t&&(ai=null),nt(Je)}var Je=z(0);function rl(t){for(var n=t;n!==null;){if(n.tag===13){var a=n.memoizedState;if(a!==null&&(a=a.dehydrated,a===null||Tf(a)||bf(a)))return n}else if(n.tag===19&&(n.memoizedProps.revealOrder==="forwards"||n.memoizedProps.revealOrder==="backwards"||n.memoizedProps.revealOrder==="unstable_legacy-backwards"||n.memoizedProps.revealOrder==="together")){if((n.flags&128)!==0)return n}else if(n.child!==null){n.child.return=n,n=n.child;continue}if(n===t)break;for(;n.sibling===null;){if(n.return===null||n.return===t)return null;n=n.return}n.sibling.return=n.return,n=n.sibling}return null}var Gi=0,re=null,Oe=null,en=null,sl=!1,Hr=!1,ar=!1,ol=0,js=0,Gr=null,qv=0;function Ke(){throw Error(r(321))}function vc(t,n){if(n===null)return!1;for(var a=0;a<n.length&&a<t.length;a++)if(!Xn(t[a],n[a]))return!1;return!0}function Sc(t,n,a,s,u,f){return Gi=f,re=n,n.memoizedState=null,n.updateQueue=null,n.lanes=0,P.H=t===null||t.memoizedState===null?um:Oc,ar=!1,f=a(s,u),ar=!1,Hr&&(f=Cp(n,a,s,u)),Rp(t),f}function Rp(t){P.H=Qs;var n=Oe!==null&&Oe.next!==null;if(Gi=0,en=Oe=re=null,sl=!1,js=0,Gr=null,n)throw Error(r(300));t===null||nn||(t=t.dependencies,t!==null&&Qo(t)&&(nn=!0))}function Cp(t,n,a,s){re=t;var u=0;do{if(Hr&&(Gr=null),js=0,Hr=!1,25<=u)throw Error(r(301));if(u+=1,en=Oe=null,t.updateQueue!=null){var f=t.updateQueue;f.lastEffect=null,f.events=null,f.stores=null,f.memoCache!=null&&(f.memoCache.index=0)}P.H=cm,f=n(a,s)}while(Hr);return f}function Yv(){var t=P.H,n=t.useState()[0];return n=typeof n.then=="function"?Zs(n):n,t=t.useState()[0],(Oe!==null?Oe.memoizedState:null)!==t&&(re.flags|=1024),n}function xc(){var t=ol!==0;return ol=0,t}function Mc(t,n,a){n.updateQueue=t.updateQueue,n.flags&=-2053,t.lanes&=~a}function yc(t){if(sl){for(t=t.memoizedState;t!==null;){var n=t.queue;n!==null&&(n.pending=null),t=t.next}sl=!1}Gi=0,en=Oe=re=null,Hr=!1,js=ol=0,Gr=null}function Dn(){var t={memoizedState:null,baseState:null,baseQueue:null,queue:null,next:null};return en===null?re.memoizedState=en=t:en=en.next=t,en}function $e(){if(Oe===null){var t=re.alternate;t=t!==null?t.memoizedState:null}else t=Oe.next;var n=en===null?re.memoizedState:en.next;if(n!==null)en=n,Oe=t;else{if(t===null)throw re.alternate===null?Error(r(467)):Error(r(310));Oe=t,t={memoizedState:Oe.memoizedState,baseState:Oe.baseState,baseQueue:Oe.baseQueue,queue:Oe.queue,next:null},en===null?re.memoizedState=en=t:en=en.next=t}return en}function ll(){return{lastEffect:null,events:null,stores:null,memoCache:null}}function Zs(t){var n=js;return js+=1,Gr===null&&(Gr=[]),t=vp(Gr,t,n),n=re,(en===null?n.memoizedState:en.next)===null&&(n=n.alternate,P.H=n===null||n.memoizedState===null?um:Oc),t}function ul(t){if(t!==null&&typeof t=="object"){if(typeof t.then=="function")return Zs(t);if(t.$$typeof===U)return vn(t)}throw Error(r(438,String(t)))}function Ec(t){var n=null,a=re.updateQueue;if(a!==null&&(n=a.memoCache),n==null){var s=re.alternate;s!==null&&(s=s.updateQueue,s!==null&&(s=s.memoCache,s!=null&&(n={data:s.data.map(function(u){return u.slice()}),index:0})))}if(n==null&&(n={data:[],index:0}),a===null&&(a=ll(),re.updateQueue=a),a.memoCache=n,a=n.data[n.index],a===void 0)for(a=n.data[n.index]=Array(t),s=0;s<t;s++)a[s]=b;return n.index++,a}function Vi(t,n){return typeof n=="function"?n(t):n}function cl(t){var n=$e();return Tc(n,Oe,t)}function Tc(t,n,a){var s=t.queue;if(s===null)throw Error(r(311));s.lastRenderedReducer=a;var u=t.baseQueue,f=s.pending;if(f!==null){if(u!==null){var g=u.next;u.next=f.next,f.next=g}n.baseQueue=u=f,s.pending=null}if(f=t.baseState,u===null)t.memoizedState=f;else{n=u.next;var E=g=null,F=null,$=n,ut=!1;do{var gt=$.lane&-536870913;if(gt!==$.lane?(pe&gt)===gt:(Gi&gt)===gt){var tt=$.revertLane;if(tt===0)F!==null&&(F=F.next={lane:0,revertLane:0,gesture:null,action:$.action,hasEagerState:$.hasEagerState,eagerState:$.eagerState,next:null}),gt===zr&&(ut=!0);else if((Gi&tt)===tt){$=$.next,tt===zr&&(ut=!0);continue}else gt={lane:0,revertLane:$.revertLane,gesture:null,action:$.action,hasEagerState:$.hasEagerState,eagerState:$.eagerState,next:null},F===null?(E=F=gt,g=f):F=F.next=gt,re.lanes|=tt,Ma|=tt;gt=$.action,ar&&a(f,gt),f=$.hasEagerState?$.eagerState:a(f,gt)}else tt={lane:gt,revertLane:$.revertLane,gesture:$.gesture,action:$.action,hasEagerState:$.hasEagerState,eagerState:$.eagerState,next:null},F===null?(E=F=tt,g=f):F=F.next=tt,re.lanes|=gt,Ma|=gt;$=$.next}while($!==null&&$!==n);if(F===null?g=f:F.next=E,!Xn(f,t.memoizedState)&&(nn=!0,ut&&(a=Pr,a!==null)))throw a;t.memoizedState=f,t.baseState=g,t.baseQueue=F,s.lastRenderedState=f}return u===null&&(s.lanes=0),[t.memoizedState,s.dispatch]}function bc(t){var n=$e(),a=n.queue;if(a===null)throw Error(r(311));a.lastRenderedReducer=t;var s=a.dispatch,u=a.pending,f=n.memoizedState;if(u!==null){a.pending=null;var g=u=u.next;do f=t(f,g.action),g=g.next;while(g!==u);Xn(f,n.memoizedState)||(nn=!0),n.memoizedState=f,n.baseQueue===null&&(n.baseState=f),a.lastRenderedState=f}return[f,s]}function wp(t,n,a){var s=re,u=$e(),f=ve;if(f){if(a===void 0)throw Error(r(407));a=a()}else a=n();var g=!Xn((Oe||u).memoizedState,a);if(g&&(u.memoizedState=a,nn=!0),u=u.queue,Cc(Lp.bind(null,s,u,t),[t]),u.getSnapshot!==n||g||en!==null&&en.memoizedState.tag&1){if(s.flags|=2048,Vr(9,{destroy:void 0},Up.bind(null,s,u,a,n),null),He===null)throw Error(r(349));f||(Gi&127)!==0||Dp(s,n,a)}return a}function Dp(t,n,a){t.flags|=16384,t={getSnapshot:n,value:a},n=re.updateQueue,n===null?(n=ll(),re.updateQueue=n,n.stores=[t]):(a=n.stores,a===null?n.stores=[t]:a.push(t))}function Up(t,n,a,s){n.value=a,n.getSnapshot=s,Np(n)&&Op(t)}function Lp(t,n,a){return a(function(){Np(n)&&Op(t)})}function Np(t){var n=t.getSnapshot;t=t.value;try{var a=n();return!Xn(t,a)}catch{return!0}}function Op(t){var n=Za(t,2);n!==null&&Fn(n,t,2)}function Ac(t){var n=Dn();if(typeof t=="function"){var a=t;if(t=a(),ar){Nt(!0);try{a()}finally{Nt(!1)}}}return n.memoizedState=n.baseState=t,n.queue={pending:null,lanes:0,dispatch:null,lastRenderedReducer:Vi,lastRenderedState:t},n}function zp(t,n,a,s){return t.baseState=a,Tc(t,Oe,typeof s=="function"?s:Vi)}function jv(t,n,a,s,u){if(dl(t))throw Error(r(485));if(t=n.action,t!==null){var f={payload:u,action:t,next:null,isTransition:!0,status:"pending",value:null,reason:null,listeners:[],then:function(g){f.listeners.push(g)}};P.T!==null?a(!0):f.isTransition=!1,s(f),a=n.pending,a===null?(f.next=n.pending=f,Pp(n,f)):(f.next=a.next,n.pending=a.next=f)}}function Pp(t,n){var a=n.action,s=n.payload,u=t.state;if(n.isTransition){var f=P.T,g={};P.T=g;try{var E=a(u,s),F=P.S;F!==null&&F(g,E),Bp(t,n,E)}catch($){Rc(t,n,$)}finally{f!==null&&g.types!==null&&(f.types=g.types),P.T=f}}else try{f=a(u,s),Bp(t,n,f)}catch($){Rc(t,n,$)}}function Bp(t,n,a){a!==null&&typeof a=="object"&&typeof a.then=="function"?a.then(function(s){Ip(t,n,s)},function(s){return Rc(t,n,s)}):Ip(t,n,a)}function Ip(t,n,a){n.status="fulfilled",n.value=a,Fp(n),t.state=a,n=t.pending,n!==null&&(a=n.next,a===n?t.pending=null:(a=a.next,n.next=a,Pp(t,a)))}function Rc(t,n,a){var s=t.pending;if(t.pending=null,s!==null){s=s.next;do n.status="rejected",n.reason=a,Fp(n),n=n.next;while(n!==s)}t.action=null}function Fp(t){t=t.listeners;for(var n=0;n<t.length;n++)(0,t[n])()}function Hp(t,n){return n}function Gp(t,n){if(ve){var a=He.formState;if(a!==null){t:{var s=re;if(ve){if(Xe){e:{for(var u=Xe,f=ii;u.nodeType!==8;){if(!f){u=null;break e}if(u=ri(u.nextSibling),u===null){u=null;break e}}f=u.data,u=f==="F!"||f==="F"?u:null}if(u){Xe=ri(u.nextSibling),s=u.data==="F!";break t}}ha(s)}s=!1}s&&(n=a[0])}}return a=Dn(),a.memoizedState=a.baseState=n,s={pending:null,lanes:0,dispatch:null,lastRenderedReducer:Hp,lastRenderedState:n},a.queue=s,a=sm.bind(null,re,s),s.dispatch=a,s=Ac(!1),f=Nc.bind(null,re,!1,s.queue),s=Dn(),u={state:n,dispatch:null,action:t,pending:null},s.queue=u,a=jv.bind(null,re,u,f,a),u.dispatch=a,s.memoizedState=t,[n,a,!1]}function Vp(t){var n=$e();return Xp(n,Oe,t)}function Xp(t,n,a){if(n=Tc(t,n,Hp)[0],t=cl(Vi)[0],typeof n=="object"&&n!==null&&typeof n.then=="function")try{var s=Zs(n)}catch(g){throw g===Br?tl:g}else s=n;n=$e();var u=n.queue,f=u.dispatch;return a!==n.memoizedState&&(re.flags|=2048,Vr(9,{destroy:void 0},Zv.bind(null,u,a),null)),[s,f,t]}function Zv(t,n){t.action=n}function kp(t){var n=$e(),a=Oe;if(a!==null)return Xp(n,a,t);$e(),n=n.memoizedState,a=$e();var s=a.queue.dispatch;return a.memoizedState=t,[n,s,!1]}function Vr(t,n,a,s){return t={tag:t,create:a,deps:s,inst:n,next:null},n=re.updateQueue,n===null&&(n=ll(),re.updateQueue=n),a=n.lastEffect,a===null?n.lastEffect=t.next=t:(s=a.next,a.next=t,t.next=s,n.lastEffect=t),t}function Wp(){return $e().memoizedState}function fl(t,n,a,s){var u=Dn();re.flags|=t,u.memoizedState=Vr(1|n,{destroy:void 0},a,s===void 0?null:s)}function hl(t,n,a,s){var u=$e();s=s===void 0?null:s;var f=u.memoizedState.inst;Oe!==null&&s!==null&&vc(s,Oe.memoizedState.deps)?u.memoizedState=Vr(n,f,a,s):(re.flags|=t,u.memoizedState=Vr(1|n,f,a,s))}function qp(t,n){fl(8390656,8,t,n)}function Cc(t,n){hl(2048,8,t,n)}function Kv(t){re.flags|=4;var n=re.updateQueue;if(n===null)n=ll(),re.updateQueue=n,n.events=[t];else{var a=n.events;a===null?n.events=[t]:a.push(t)}}function Yp(t){var n=$e().memoizedState;return Kv({ref:n,nextImpl:t}),function(){if((Ce&2)!==0)throw Error(r(440));return n.impl.apply(void 0,arguments)}}function jp(t,n){return hl(4,2,t,n)}function Zp(t,n){return hl(4,4,t,n)}function Kp(t,n){if(typeof n=="function"){t=t();var a=n(t);return function(){typeof a=="function"?a():n(null)}}if(n!=null)return t=t(),n.current=t,function(){n.current=null}}function Qp(t,n,a){a=a!=null?a.concat([t]):null,hl(4,4,Kp.bind(null,n,t),a)}function wc(){}function Jp(t,n){var a=$e();n=n===void 0?null:n;var s=a.memoizedState;return n!==null&&vc(n,s[1])?s[0]:(a.memoizedState=[t,n],t)}function $p(t,n){var a=$e();n=n===void 0?null:n;var s=a.memoizedState;if(n!==null&&vc(n,s[1]))return s[0];if(s=t(),ar){Nt(!0);try{t()}finally{Nt(!1)}}return a.memoizedState=[s,n],s}function Dc(t,n,a){return a===void 0||(Gi&1073741824)!==0&&(pe&261930)===0?t.memoizedState=n:(t.memoizedState=a,t=tg(),re.lanes|=t,Ma|=t,a)}function tm(t,n,a,s){return Xn(a,n)?a:Fr.current!==null?(t=Dc(t,a,s),Xn(t,n)||(nn=!0),t):(Gi&42)===0||(Gi&1073741824)!==0&&(pe&261930)===0?(nn=!0,t.memoizedState=a):(t=tg(),re.lanes|=t,Ma|=t,n)}function em(t,n,a,s,u){var f=Y.p;Y.p=f!==0&&8>f?f:8;var g=P.T,E={};P.T=E,Nc(t,!1,n,a);try{var F=u(),$=P.S;if($!==null&&$(E,F),F!==null&&typeof F=="object"&&typeof F.then=="function"){var ut=Wv(F,s);Ks(t,n,ut,Zn(t))}else Ks(t,n,s,Zn(t))}catch(gt){Ks(t,n,{then:function(){},status:"rejected",reason:gt},Zn())}finally{Y.p=f,g!==null&&E.types!==null&&(g.types=E.types),P.T=g}}function Qv(){}function Uc(t,n,a,s){if(t.tag!==5)throw Error(r(476));var u=nm(t).queue;em(t,u,n,j,a===null?Qv:function(){return im(t),a(s)})}function nm(t){var n=t.memoizedState;if(n!==null)return n;n={memoizedState:j,baseState:j,baseQueue:null,queue:{pending:null,lanes:0,dispatch:null,lastRenderedReducer:Vi,lastRenderedState:j},next:null};var a={};return n.next={memoizedState:a,baseState:a,baseQueue:null,queue:{pending:null,lanes:0,dispatch:null,lastRenderedReducer:Vi,lastRenderedState:a},next:null},t.memoizedState=n,t=t.alternate,t!==null&&(t.memoizedState=n),n}function im(t){var n=nm(t);n.next===null&&(n=t.alternate.memoizedState),Ks(t,n.next.queue,{},Zn())}function Lc(){return vn(po)}function am(){return $e().memoizedState}function rm(){return $e().memoizedState}function Jv(t){for(var n=t.return;n!==null;){switch(n.tag){case 24:case 3:var a=Zn();t=ma(a);var s=ga(n,t,a);s!==null&&(Fn(s,n,a),Ws(s,n,a)),n={cache:oc()},t.payload=n;return}n=n.return}}function $v(t,n,a){var s=Zn();a={lane:s,revertLane:0,gesture:null,action:a,hasEagerState:!1,eagerState:null,next:null},dl(t)?om(n,a):(a=Ku(t,n,a,s),a!==null&&(Fn(a,t,s),lm(a,n,s)))}function sm(t,n,a){var s=Zn();Ks(t,n,a,s)}function Ks(t,n,a,s){var u={lane:s,revertLane:0,gesture:null,action:a,hasEagerState:!1,eagerState:null,next:null};if(dl(t))om(n,u);else{var f=t.alternate;if(t.lanes===0&&(f===null||f.lanes===0)&&(f=n.lastRenderedReducer,f!==null))try{var g=n.lastRenderedState,E=f(g,a);if(u.hasEagerState=!0,u.eagerState=E,Xn(E,g))return Yo(t,n,u,0),He===null&&qo(),!1}catch{}finally{}if(a=Ku(t,n,u,s),a!==null)return Fn(a,t,s),lm(a,n,s),!0}return!1}function Nc(t,n,a,s){if(s={lane:2,revertLane:hf(),gesture:null,action:s,hasEagerState:!1,eagerState:null,next:null},dl(t)){if(n)throw Error(r(479))}else n=Ku(t,a,s,2),n!==null&&Fn(n,t,2)}function dl(t){var n=t.alternate;return t===re||n!==null&&n===re}function om(t,n){Hr=sl=!0;var a=t.pending;a===null?n.next=n:(n.next=a.next,a.next=n),t.pending=n}function lm(t,n,a){if((a&4194048)!==0){var s=n.lanes;s&=t.pendingLanes,a|=s,n.lanes=a,As(t,a)}}var Qs={readContext:vn,use:ul,useCallback:Ke,useContext:Ke,useEffect:Ke,useImperativeHandle:Ke,useLayoutEffect:Ke,useInsertionEffect:Ke,useMemo:Ke,useReducer:Ke,useRef:Ke,useState:Ke,useDebugValue:Ke,useDeferredValue:Ke,useTransition:Ke,useSyncExternalStore:Ke,useId:Ke,useHostTransitionStatus:Ke,useFormState:Ke,useActionState:Ke,useOptimistic:Ke,useMemoCache:Ke,useCacheRefresh:Ke};Qs.useEffectEvent=Ke;var um={readContext:vn,use:ul,useCallback:function(t,n){return Dn().memoizedState=[t,n===void 0?null:n],t},useContext:vn,useEffect:qp,useImperativeHandle:function(t,n,a){a=a!=null?a.concat([t]):null,fl(4194308,4,Kp.bind(null,n,t),a)},useLayoutEffect:function(t,n){return fl(4194308,4,t,n)},useInsertionEffect:function(t,n){fl(4,2,t,n)},useMemo:function(t,n){var a=Dn();n=n===void 0?null:n;var s=t();if(ar){Nt(!0);try{t()}finally{Nt(!1)}}return a.memoizedState=[s,n],s},useReducer:function(t,n,a){var s=Dn();if(a!==void 0){var u=a(n);if(ar){Nt(!0);try{a(n)}finally{Nt(!1)}}}else u=n;return s.memoizedState=s.baseState=u,t={pending:null,lanes:0,dispatch:null,lastRenderedReducer:t,lastRenderedState:u},s.queue=t,t=t.dispatch=$v.bind(null,re,t),[s.memoizedState,t]},useRef:function(t){var n=Dn();return t={current:t},n.memoizedState=t},useState:function(t){t=Ac(t);var n=t.queue,a=sm.bind(null,re,n);return n.dispatch=a,[t.memoizedState,a]},useDebugValue:wc,useDeferredValue:function(t,n){var a=Dn();return Dc(a,t,n)},useTransition:function(){var t=Ac(!1);return t=em.bind(null,re,t.queue,!0,!1),Dn().memoizedState=t,[!1,t]},useSyncExternalStore:function(t,n,a){var s=re,u=Dn();if(ve){if(a===void 0)throw Error(r(407));a=a()}else{if(a=n(),He===null)throw Error(r(349));(pe&127)!==0||Dp(s,n,a)}u.memoizedState=a;var f={value:a,getSnapshot:n};return u.queue=f,qp(Lp.bind(null,s,f,t),[t]),s.flags|=2048,Vr(9,{destroy:void 0},Up.bind(null,s,f,a,n),null),a},useId:function(){var t=Dn(),n=He.identifierPrefix;if(ve){var a=bi,s=Ti;a=(s&~(1<<32-$t(s)-1)).toString(32)+a,n="_"+n+"R_"+a,a=ol++,0<a&&(n+="H"+a.toString(32)),n+="_"}else a=qv++,n="_"+n+"r_"+a.toString(32)+"_";return t.memoizedState=n},useHostTransitionStatus:Lc,useFormState:Gp,useActionState:Gp,useOptimistic:function(t){var n=Dn();n.memoizedState=n.baseState=t;var a={pending:null,lanes:0,dispatch:null,lastRenderedReducer:null,lastRenderedState:null};return n.queue=a,n=Nc.bind(null,re,!0,a),a.dispatch=n,[t,n]},useMemoCache:Ec,useCacheRefresh:function(){return Dn().memoizedState=Jv.bind(null,re)},useEffectEvent:function(t){var n=Dn(),a={impl:t};return n.memoizedState=a,function(){if((Ce&2)!==0)throw Error(r(440));return a.impl.apply(void 0,arguments)}}},Oc={readContext:vn,use:ul,useCallback:Jp,useContext:vn,useEffect:Cc,useImperativeHandle:Qp,useInsertionEffect:jp,useLayoutEffect:Zp,useMemo:$p,useReducer:cl,useRef:Wp,useState:function(){return cl(Vi)},useDebugValue:wc,useDeferredValue:function(t,n){var a=$e();return tm(a,Oe.memoizedState,t,n)},useTransition:function(){var t=cl(Vi)[0],n=$e().memoizedState;return[typeof t=="boolean"?t:Zs(t),n]},useSyncExternalStore:wp,useId:am,useHostTransitionStatus:Lc,useFormState:Vp,useActionState:Vp,useOptimistic:function(t,n){var a=$e();return zp(a,Oe,t,n)},useMemoCache:Ec,useCacheRefresh:rm};Oc.useEffectEvent=Yp;var cm={readContext:vn,use:ul,useCallback:Jp,useContext:vn,useEffect:Cc,useImperativeHandle:Qp,useInsertionEffect:jp,useLayoutEffect:Zp,useMemo:$p,useReducer:bc,useRef:Wp,useState:function(){return bc(Vi)},useDebugValue:wc,useDeferredValue:function(t,n){var a=$e();return Oe===null?Dc(a,t,n):tm(a,Oe.memoizedState,t,n)},useTransition:function(){var t=bc(Vi)[0],n=$e().memoizedState;return[typeof t=="boolean"?t:Zs(t),n]},useSyncExternalStore:wp,useId:am,useHostTransitionStatus:Lc,useFormState:kp,useActionState:kp,useOptimistic:function(t,n){var a=$e();return Oe!==null?zp(a,Oe,t,n):(a.baseState=t,[t,a.queue.dispatch])},useMemoCache:Ec,useCacheRefresh:rm};cm.useEffectEvent=Yp;function zc(t,n,a,s){n=t.memoizedState,a=a(s,n),a=a==null?n:v({},n,a),t.memoizedState=a,t.lanes===0&&(t.updateQueue.baseState=a)}var Pc={enqueueSetState:function(t,n,a){t=t._reactInternals;var s=Zn(),u=ma(s);u.payload=n,a!=null&&(u.callback=a),n=ga(t,u,s),n!==null&&(Fn(n,t,s),Ws(n,t,s))},enqueueReplaceState:function(t,n,a){t=t._reactInternals;var s=Zn(),u=ma(s);u.tag=1,u.payload=n,a!=null&&(u.callback=a),n=ga(t,u,s),n!==null&&(Fn(n,t,s),Ws(n,t,s))},enqueueForceUpdate:function(t,n){t=t._reactInternals;var a=Zn(),s=ma(a);s.tag=2,n!=null&&(s.callback=n),n=ga(t,s,a),n!==null&&(Fn(n,t,a),Ws(n,t,a))}};function fm(t,n,a,s,u,f,g){return t=t.stateNode,typeof t.shouldComponentUpdate=="function"?t.shouldComponentUpdate(s,f,g):n.prototype&&n.prototype.isPureReactComponent?!Bs(a,s)||!Bs(u,f):!0}function hm(t,n,a,s){t=n.state,typeof n.componentWillReceiveProps=="function"&&n.componentWillReceiveProps(a,s),typeof n.UNSAFE_componentWillReceiveProps=="function"&&n.UNSAFE_componentWillReceiveProps(a,s),n.state!==t&&Pc.enqueueReplaceState(n,n.state,null)}function rr(t,n){var a=n;if("ref"in n){a={};for(var s in n)s!=="ref"&&(a[s]=n[s])}if(t=t.defaultProps){a===n&&(a=v({},a));for(var u in t)a[u]===void 0&&(a[u]=t[u])}return a}function dm(t){Wo(t)}function pm(t){console.error(t)}function mm(t){Wo(t)}function pl(t,n){try{var a=t.onUncaughtError;a(n.value,{componentStack:n.stack})}catch(s){setTimeout(function(){throw s})}}function gm(t,n,a){try{var s=t.onCaughtError;s(a.value,{componentStack:a.stack,errorBoundary:n.tag===1?n.stateNode:null})}catch(u){setTimeout(function(){throw u})}}function Bc(t,n,a){return a=ma(a),a.tag=3,a.payload={element:null},a.callback=function(){pl(t,n)},a}function _m(t){return t=ma(t),t.tag=3,t}function vm(t,n,a,s){var u=a.type.getDerivedStateFromError;if(typeof u=="function"){var f=s.value;t.payload=function(){return u(f)},t.callback=function(){gm(n,a,s)}}var g=a.stateNode;g!==null&&typeof g.componentDidCatch=="function"&&(t.callback=function(){gm(n,a,s),typeof u!="function"&&(ya===null?ya=new Set([this]):ya.add(this));var E=s.stack;this.componentDidCatch(s.value,{componentStack:E!==null?E:""})})}function tS(t,n,a,s,u){if(a.flags|=32768,s!==null&&typeof s=="object"&&typeof s.then=="function"){if(n=a.alternate,n!==null&&Or(n,a,u,!0),a=Wn.current,a!==null){switch(a.tag){case 31:case 13:return ai===null?Al():a.alternate===null&&Qe===0&&(Qe=3),a.flags&=-257,a.flags|=65536,a.lanes=u,s===el?a.flags|=16384:(n=a.updateQueue,n===null?a.updateQueue=new Set([s]):n.add(s),uf(t,s,u)),!1;case 22:return a.flags|=65536,s===el?a.flags|=16384:(n=a.updateQueue,n===null?(n={transitions:null,markerInstances:null,retryQueue:new Set([s])},a.updateQueue=n):(a=n.retryQueue,a===null?n.retryQueue=new Set([s]):a.add(s)),uf(t,s,u)),!1}throw Error(r(435,a.tag))}return uf(t,s,u),Al(),!1}if(ve)return n=Wn.current,n!==null?((n.flags&65536)===0&&(n.flags|=256),n.flags|=65536,n.lanes=u,s!==nc&&(t=Error(r(422),{cause:s}),Hs(ti(t,a)))):(s!==nc&&(n=Error(r(423),{cause:s}),Hs(ti(n,a))),t=t.current.alternate,t.flags|=65536,u&=-u,t.lanes|=u,s=ti(s,a),u=Bc(t.stateNode,s,u),dc(t,u),Qe!==4&&(Qe=2)),!1;var f=Error(r(520),{cause:s});if(f=ti(f,a),ro===null?ro=[f]:ro.push(f),Qe!==4&&(Qe=2),n===null)return!0;s=ti(s,a),a=n;do{switch(a.tag){case 3:return a.flags|=65536,t=u&-u,a.lanes|=t,t=Bc(a.stateNode,s,t),dc(a,t),!1;case 1:if(n=a.type,f=a.stateNode,(a.flags&128)===0&&(typeof n.getDerivedStateFromError=="function"||f!==null&&typeof f.componentDidCatch=="function"&&(ya===null||!ya.has(f))))return a.flags|=65536,u&=-u,a.lanes|=u,u=_m(u),vm(u,t,a,s),dc(a,u),!1}a=a.return}while(a!==null);return!1}var Ic=Error(r(461)),nn=!1;function Sn(t,n,a,s){n.child=t===null?yp(n,null,a,s):ir(n,t.child,a,s)}function Sm(t,n,a,s,u){a=a.render;var f=n.ref;if("ref"in s){var g={};for(var E in s)E!=="ref"&&(g[E]=s[E])}else g=s;return $a(n),s=Sc(t,n,a,g,f,u),E=xc(),t!==null&&!nn?(Mc(t,n,u),Xi(t,n,u)):(ve&&E&&tc(n),n.flags|=1,Sn(t,n,s,u),n.child)}function xm(t,n,a,s,u){if(t===null){var f=a.type;return typeof f=="function"&&!Qu(f)&&f.defaultProps===void 0&&a.compare===null?(n.tag=15,n.type=f,Mm(t,n,f,s,u)):(t=Zo(a.type,null,s,n,n.mode,u),t.ref=n.ref,t.return=n,n.child=t)}if(f=t.child,!qc(t,u)){var g=f.memoizedProps;if(a=a.compare,a=a!==null?a:Bs,a(g,s)&&t.ref===n.ref)return Xi(t,n,u)}return n.flags|=1,t=Bi(f,s),t.ref=n.ref,t.return=n,n.child=t}function Mm(t,n,a,s,u){if(t!==null){var f=t.memoizedProps;if(Bs(f,s)&&t.ref===n.ref)if(nn=!1,n.pendingProps=s=f,qc(t,u))(t.flags&131072)!==0&&(nn=!0);else return n.lanes=t.lanes,Xi(t,n,u)}return Fc(t,n,a,s,u)}function ym(t,n,a,s){var u=s.children,f=t!==null?t.memoizedState:null;if(t===null&&n.stateNode===null&&(n.stateNode={_visibility:1,_pendingMarkers:null,_retryCache:null,_transitions:null}),s.mode==="hidden"){if((n.flags&128)!==0){if(f=f!==null?f.baseLanes|a:a,t!==null){for(s=n.child=t.child,u=0;s!==null;)u=u|s.lanes|s.childLanes,s=s.sibling;s=u&~f}else s=0,n.child=null;return Em(t,n,f,a,s)}if((a&536870912)!==0)n.memoizedState={baseLanes:0,cachePool:null},t!==null&&$o(n,f!==null?f.cachePool:null),f!==null?bp(n,f):mc(),Ap(n);else return s=n.lanes=536870912,Em(t,n,f!==null?f.baseLanes|a:a,a,s)}else f!==null?($o(n,f.cachePool),bp(n,f),va(),n.memoizedState=null):(t!==null&&$o(n,null),mc(),va());return Sn(t,n,u,a),n.child}function Js(t,n){return t!==null&&t.tag===22||n.stateNode!==null||(n.stateNode={_visibility:1,_pendingMarkers:null,_retryCache:null,_transitions:null}),n.sibling}function Em(t,n,a,s,u){var f=uc();return f=f===null?null:{parent:tn._currentValue,pool:f},n.memoizedState={baseLanes:a,cachePool:f},t!==null&&$o(n,null),mc(),Ap(n),t!==null&&Or(t,n,s,!0),n.childLanes=u,null}function ml(t,n){return n=_l({mode:n.mode,children:n.children},t.mode),n.ref=t.ref,t.child=n,n.return=t,n}function Tm(t,n,a){return ir(n,t.child,null,a),t=ml(n,n.pendingProps),t.flags|=2,qn(n),n.memoizedState=null,t}function eS(t,n,a){var s=n.pendingProps,u=(n.flags&128)!==0;if(n.flags&=-129,t===null){if(ve){if(s.mode==="hidden")return t=ml(n,s),n.lanes=536870912,Js(null,t);if(_c(n),(t=Xe)?(t=Pg(t,ii),t=t!==null&&t.data==="&"?t:null,t!==null&&(n.memoizedState={dehydrated:t,treeContext:ca!==null?{id:Ti,overflow:bi}:null,retryLane:536870912,hydrationErrors:null},a=op(t),a.return=n,n.child=a,_n=n,Xe=null)):t=null,t===null)throw ha(n);return n.lanes=536870912,null}return ml(n,s)}var f=t.memoizedState;if(f!==null){var g=f.dehydrated;if(_c(n),u)if(n.flags&256)n.flags&=-257,n=Tm(t,n,a);else if(n.memoizedState!==null)n.child=t.child,n.flags|=128,n=null;else throw Error(r(558));else if(nn||Or(t,n,a,!1),u=(a&t.childLanes)!==0,nn||u){if(s=He,s!==null&&(g=Ei(s,a),g!==0&&g!==f.retryLane))throw f.retryLane=g,Za(t,g),Fn(s,t,g),Ic;Al(),n=Tm(t,n,a)}else t=f.treeContext,Xe=ri(g.nextSibling),_n=n,ve=!0,fa=null,ii=!1,t!==null&&cp(n,t),n=ml(n,s),n.flags|=4096;return n}return t=Bi(t.child,{mode:s.mode,children:s.children}),t.ref=n.ref,n.child=t,t.return=n,t}function gl(t,n){var a=n.ref;if(a===null)t!==null&&t.ref!==null&&(n.flags|=4194816);else{if(typeof a!="function"&&typeof a!="object")throw Error(r(284));(t===null||t.ref!==a)&&(n.flags|=4194816)}}function Fc(t,n,a,s,u){return $a(n),a=Sc(t,n,a,s,void 0,u),s=xc(),t!==null&&!nn?(Mc(t,n,u),Xi(t,n,u)):(ve&&s&&tc(n),n.flags|=1,Sn(t,n,a,u),n.child)}function bm(t,n,a,s,u,f){return $a(n),n.updateQueue=null,a=Cp(n,s,a,u),Rp(t),s=xc(),t!==null&&!nn?(Mc(t,n,f),Xi(t,n,f)):(ve&&s&&tc(n),n.flags|=1,Sn(t,n,a,f),n.child)}function Am(t,n,a,s,u){if($a(n),n.stateNode===null){var f=Dr,g=a.contextType;typeof g=="object"&&g!==null&&(f=vn(g)),f=new a(s,f),n.memoizedState=f.state!==null&&f.state!==void 0?f.state:null,f.updater=Pc,n.stateNode=f,f._reactInternals=n,f=n.stateNode,f.props=s,f.state=n.memoizedState,f.refs={},fc(n),g=a.contextType,f.context=typeof g=="object"&&g!==null?vn(g):Dr,f.state=n.memoizedState,g=a.getDerivedStateFromProps,typeof g=="function"&&(zc(n,a,g,s),f.state=n.memoizedState),typeof a.getDerivedStateFromProps=="function"||typeof f.getSnapshotBeforeUpdate=="function"||typeof f.UNSAFE_componentWillMount!="function"&&typeof f.componentWillMount!="function"||(g=f.state,typeof f.componentWillMount=="function"&&f.componentWillMount(),typeof f.UNSAFE_componentWillMount=="function"&&f.UNSAFE_componentWillMount(),g!==f.state&&Pc.enqueueReplaceState(f,f.state,null),Ys(n,s,f,u),qs(),f.state=n.memoizedState),typeof f.componentDidMount=="function"&&(n.flags|=4194308),s=!0}else if(t===null){f=n.stateNode;var E=n.memoizedProps,F=rr(a,E);f.props=F;var $=f.context,ut=a.contextType;g=Dr,typeof ut=="object"&&ut!==null&&(g=vn(ut));var gt=a.getDerivedStateFromProps;ut=typeof gt=="function"||typeof f.getSnapshotBeforeUpdate=="function",E=n.pendingProps!==E,ut||typeof f.UNSAFE_componentWillReceiveProps!="function"&&typeof f.componentWillReceiveProps!="function"||(E||$!==g)&&hm(n,f,s,g),pa=!1;var tt=n.memoizedState;f.state=tt,Ys(n,s,f,u),qs(),$=n.memoizedState,E||tt!==$||pa?(typeof gt=="function"&&(zc(n,a,gt,s),$=n.memoizedState),(F=pa||fm(n,a,F,s,tt,$,g))?(ut||typeof f.UNSAFE_componentWillMount!="function"&&typeof f.componentWillMount!="function"||(typeof f.componentWillMount=="function"&&f.componentWillMount(),typeof f.UNSAFE_componentWillMount=="function"&&f.UNSAFE_componentWillMount()),typeof f.componentDidMount=="function"&&(n.flags|=4194308)):(typeof f.componentDidMount=="function"&&(n.flags|=4194308),n.memoizedProps=s,n.memoizedState=$),f.props=s,f.state=$,f.context=g,s=F):(typeof f.componentDidMount=="function"&&(n.flags|=4194308),s=!1)}else{f=n.stateNode,hc(t,n),g=n.memoizedProps,ut=rr(a,g),f.props=ut,gt=n.pendingProps,tt=f.context,$=a.contextType,F=Dr,typeof $=="object"&&$!==null&&(F=vn($)),E=a.getDerivedStateFromProps,($=typeof E=="function"||typeof f.getSnapshotBeforeUpdate=="function")||typeof f.UNSAFE_componentWillReceiveProps!="function"&&typeof f.componentWillReceiveProps!="function"||(g!==gt||tt!==F)&&hm(n,f,s,F),pa=!1,tt=n.memoizedState,f.state=tt,Ys(n,s,f,u),qs();var ot=n.memoizedState;g!==gt||tt!==ot||pa||t!==null&&t.dependencies!==null&&Qo(t.dependencies)?(typeof E=="function"&&(zc(n,a,E,s),ot=n.memoizedState),(ut=pa||fm(n,a,ut,s,tt,ot,F)||t!==null&&t.dependencies!==null&&Qo(t.dependencies))?($||typeof f.UNSAFE_componentWillUpdate!="function"&&typeof f.componentWillUpdate!="function"||(typeof f.componentWillUpdate=="function"&&f.componentWillUpdate(s,ot,F),typeof f.UNSAFE_componentWillUpdate=="function"&&f.UNSAFE_componentWillUpdate(s,ot,F)),typeof f.componentDidUpdate=="function"&&(n.flags|=4),typeof f.getSnapshotBeforeUpdate=="function"&&(n.flags|=1024)):(typeof f.componentDidUpdate!="function"||g===t.memoizedProps&&tt===t.memoizedState||(n.flags|=4),typeof f.getSnapshotBeforeUpdate!="function"||g===t.memoizedProps&&tt===t.memoizedState||(n.flags|=1024),n.memoizedProps=s,n.memoizedState=ot),f.props=s,f.state=ot,f.context=F,s=ut):(typeof f.componentDidUpdate!="function"||g===t.memoizedProps&&tt===t.memoizedState||(n.flags|=4),typeof f.getSnapshotBeforeUpdate!="function"||g===t.memoizedProps&&tt===t.memoizedState||(n.flags|=1024),s=!1)}return f=s,gl(t,n),s=(n.flags&128)!==0,f||s?(f=n.stateNode,a=s&&typeof a.getDerivedStateFromError!="function"?null:f.render(),n.flags|=1,t!==null&&s?(n.child=ir(n,t.child,null,u),n.child=ir(n,null,a,u)):Sn(t,n,a,u),n.memoizedState=f.state,t=n.child):t=Xi(t,n,u),t}function Rm(t,n,a,s){return Qa(),n.flags|=256,Sn(t,n,a,s),n.child}var Hc={dehydrated:null,treeContext:null,retryLane:0,hydrationErrors:null};function Gc(t){return{baseLanes:t,cachePool:gp()}}function Vc(t,n,a){return t=t!==null?t.childLanes&~a:0,n&&(t|=jn),t}function Cm(t,n,a){var s=n.pendingProps,u=!1,f=(n.flags&128)!==0,g;if((g=f)||(g=t!==null&&t.memoizedState===null?!1:(Je.current&2)!==0),g&&(u=!0,n.flags&=-129),g=(n.flags&32)!==0,n.flags&=-33,t===null){if(ve){if(u?_a(n):va(),(t=Xe)?(t=Pg(t,ii),t=t!==null&&t.data!=="&"?t:null,t!==null&&(n.memoizedState={dehydrated:t,treeContext:ca!==null?{id:Ti,overflow:bi}:null,retryLane:536870912,hydrationErrors:null},a=op(t),a.return=n,n.child=a,_n=n,Xe=null)):t=null,t===null)throw ha(n);return bf(t)?n.lanes=32:n.lanes=536870912,null}var E=s.children;return s=s.fallback,u?(va(),u=n.mode,E=_l({mode:"hidden",children:E},u),s=Ka(s,u,a,null),E.return=n,s.return=n,E.sibling=s,n.child=E,s=n.child,s.memoizedState=Gc(a),s.childLanes=Vc(t,g,a),n.memoizedState=Hc,Js(null,s)):(_a(n),Xc(n,E))}var F=t.memoizedState;if(F!==null&&(E=F.dehydrated,E!==null)){if(f)n.flags&256?(_a(n),n.flags&=-257,n=kc(t,n,a)):n.memoizedState!==null?(va(),n.child=t.child,n.flags|=128,n=null):(va(),E=s.fallback,u=n.mode,s=_l({mode:"visible",children:s.children},u),E=Ka(E,u,a,null),E.flags|=2,s.return=n,E.return=n,s.sibling=E,n.child=s,ir(n,t.child,null,a),s=n.child,s.memoizedState=Gc(a),s.childLanes=Vc(t,g,a),n.memoizedState=Hc,n=Js(null,s));else if(_a(n),bf(E)){if(g=E.nextSibling&&E.nextSibling.dataset,g)var $=g.dgst;g=$,s=Error(r(419)),s.stack="",s.digest=g,Hs({value:s,source:null,stack:null}),n=kc(t,n,a)}else if(nn||Or(t,n,a,!1),g=(a&t.childLanes)!==0,nn||g){if(g=He,g!==null&&(s=Ei(g,a),s!==0&&s!==F.retryLane))throw F.retryLane=s,Za(t,s),Fn(g,t,s),Ic;Tf(E)||Al(),n=kc(t,n,a)}else Tf(E)?(n.flags|=192,n.child=t.child,n=null):(t=F.treeContext,Xe=ri(E.nextSibling),_n=n,ve=!0,fa=null,ii=!1,t!==null&&cp(n,t),n=Xc(n,s.children),n.flags|=4096);return n}return u?(va(),E=s.fallback,u=n.mode,F=t.child,$=F.sibling,s=Bi(F,{mode:"hidden",children:s.children}),s.subtreeFlags=F.subtreeFlags&65011712,$!==null?E=Bi($,E):(E=Ka(E,u,a,null),E.flags|=2),E.return=n,s.return=n,s.sibling=E,n.child=s,Js(null,s),s=n.child,E=t.child.memoizedState,E===null?E=Gc(a):(u=E.cachePool,u!==null?(F=tn._currentValue,u=u.parent!==F?{parent:F,pool:F}:u):u=gp(),E={baseLanes:E.baseLanes|a,cachePool:u}),s.memoizedState=E,s.childLanes=Vc(t,g,a),n.memoizedState=Hc,Js(t.child,s)):(_a(n),a=t.child,t=a.sibling,a=Bi(a,{mode:"visible",children:s.children}),a.return=n,a.sibling=null,t!==null&&(g=n.deletions,g===null?(n.deletions=[t],n.flags|=16):g.push(t)),n.child=a,n.memoizedState=null,a)}function Xc(t,n){return n=_l({mode:"visible",children:n},t.mode),n.return=t,t.child=n}function _l(t,n){return t=kn(22,t,null,n),t.lanes=0,t}function kc(t,n,a){return ir(n,t.child,null,a),t=Xc(n,n.pendingProps.children),t.flags|=2,n.memoizedState=null,t}function wm(t,n,a){t.lanes|=n;var s=t.alternate;s!==null&&(s.lanes|=n),rc(t.return,n,a)}function Wc(t,n,a,s,u,f){var g=t.memoizedState;g===null?t.memoizedState={isBackwards:n,rendering:null,renderingStartTime:0,last:s,tail:a,tailMode:u,treeForkCount:f}:(g.isBackwards=n,g.rendering=null,g.renderingStartTime=0,g.last=s,g.tail=a,g.tailMode=u,g.treeForkCount=f)}function Dm(t,n,a){var s=n.pendingProps,u=s.revealOrder,f=s.tail;s=s.children;var g=Je.current,E=(g&2)!==0;if(E?(g=g&1|2,n.flags|=128):g&=1,xt(Je,g),Sn(t,n,s,a),s=ve?Fs:0,!E&&t!==null&&(t.flags&128)!==0)t:for(t=n.child;t!==null;){if(t.tag===13)t.memoizedState!==null&&wm(t,a,n);else if(t.tag===19)wm(t,a,n);else if(t.child!==null){t.child.return=t,t=t.child;continue}if(t===n)break t;for(;t.sibling===null;){if(t.return===null||t.return===n)break t;t=t.return}t.sibling.return=t.return,t=t.sibling}switch(u){case"forwards":for(a=n.child,u=null;a!==null;)t=a.alternate,t!==null&&rl(t)===null&&(u=a),a=a.sibling;a=u,a===null?(u=n.child,n.child=null):(u=a.sibling,a.sibling=null),Wc(n,!1,u,a,f,s);break;case"backwards":case"unstable_legacy-backwards":for(a=null,u=n.child,n.child=null;u!==null;){if(t=u.alternate,t!==null&&rl(t)===null){n.child=u;break}t=u.sibling,u.sibling=a,a=u,u=t}Wc(n,!0,a,null,f,s);break;case"together":Wc(n,!1,null,null,void 0,s);break;default:n.memoizedState=null}return n.child}function Xi(t,n,a){if(t!==null&&(n.dependencies=t.dependencies),Ma|=n.lanes,(a&n.childLanes)===0)if(t!==null){if(Or(t,n,a,!1),(a&n.childLanes)===0)return null}else return null;if(t!==null&&n.child!==t.child)throw Error(r(153));if(n.child!==null){for(t=n.child,a=Bi(t,t.pendingProps),n.child=a,a.return=n;t.sibling!==null;)t=t.sibling,a=a.sibling=Bi(t,t.pendingProps),a.return=n;a.sibling=null}return n.child}function qc(t,n){return(t.lanes&n)!==0?!0:(t=t.dependencies,!!(t!==null&&Qo(t)))}function nS(t,n,a){switch(n.tag){case 3:zt(n,n.stateNode.containerInfo),da(n,tn,t.memoizedState.cache),Qa();break;case 27:case 5:jt(n);break;case 4:zt(n,n.stateNode.containerInfo);break;case 10:da(n,n.type,n.memoizedProps.value);break;case 31:if(n.memoizedState!==null)return n.flags|=128,_c(n),null;break;case 13:var s=n.memoizedState;if(s!==null)return s.dehydrated!==null?(_a(n),n.flags|=128,null):(a&n.child.childLanes)!==0?Cm(t,n,a):(_a(n),t=Xi(t,n,a),t!==null?t.sibling:null);_a(n);break;case 19:var u=(t.flags&128)!==0;if(s=(a&n.childLanes)!==0,s||(Or(t,n,a,!1),s=(a&n.childLanes)!==0),u){if(s)return Dm(t,n,a);n.flags|=128}if(u=n.memoizedState,u!==null&&(u.rendering=null,u.tail=null,u.lastEffect=null),xt(Je,Je.current),s)break;return null;case 22:return n.lanes=0,ym(t,n,a,n.pendingProps);case 24:da(n,tn,t.memoizedState.cache)}return Xi(t,n,a)}function Um(t,n,a){if(t!==null)if(t.memoizedProps!==n.pendingProps)nn=!0;else{if(!qc(t,a)&&(n.flags&128)===0)return nn=!1,nS(t,n,a);nn=(t.flags&131072)!==0}else nn=!1,ve&&(n.flags&1048576)!==0&&up(n,Fs,n.index);switch(n.lanes=0,n.tag){case 16:t:{var s=n.pendingProps;if(t=er(n.elementType),n.type=t,typeof t=="function")Qu(t)?(s=rr(t,s),n.tag=1,n=Am(null,n,t,s,a)):(n.tag=0,n=Fc(null,n,t,s,a));else{if(t!=null){var u=t.$$typeof;if(u===C){n.tag=11,n=Sm(null,n,t,s,a);break t}else if(u===O){n.tag=14,n=xm(null,n,t,s,a);break t}}throw n=dt(t)||t,Error(r(306,n,""))}}return n;case 0:return Fc(t,n,n.type,n.pendingProps,a);case 1:return s=n.type,u=rr(s,n.pendingProps),Am(t,n,s,u,a);case 3:t:{if(zt(n,n.stateNode.containerInfo),t===null)throw Error(r(387));s=n.pendingProps;var f=n.memoizedState;u=f.element,hc(t,n),Ys(n,s,null,a);var g=n.memoizedState;if(s=g.cache,da(n,tn,s),s!==f.cache&&sc(n,[tn],a,!0),qs(),s=g.element,f.isDehydrated)if(f={element:s,isDehydrated:!1,cache:g.cache},n.updateQueue.baseState=f,n.memoizedState=f,n.flags&256){n=Rm(t,n,s,a);break t}else if(s!==u){u=ti(Error(r(424)),n),Hs(u),n=Rm(t,n,s,a);break t}else{switch(t=n.stateNode.containerInfo,t.nodeType){case 9:t=t.body;break;default:t=t.nodeName==="HTML"?t.ownerDocument.body:t}for(Xe=ri(t.firstChild),_n=n,ve=!0,fa=null,ii=!0,a=yp(n,null,s,a),n.child=a;a;)a.flags=a.flags&-3|4096,a=a.sibling}else{if(Qa(),s===u){n=Xi(t,n,a);break t}Sn(t,n,s,a)}n=n.child}return n;case 26:return gl(t,n),t===null?(a=Vg(n.type,null,n.pendingProps,null))?n.memoizedState=a:ve||(a=n.type,t=n.pendingProps,s=Nl(yt.current).createElement(a),s[je]=n,s[mn]=t,xn(s,a,t),k(s),n.stateNode=s):n.memoizedState=Vg(n.type,t.memoizedProps,n.pendingProps,t.memoizedState),null;case 27:return jt(n),t===null&&ve&&(s=n.stateNode=Fg(n.type,n.pendingProps,yt.current),_n=n,ii=!0,u=Xe,Aa(n.type)?(Af=u,Xe=ri(s.firstChild)):Xe=u),Sn(t,n,n.pendingProps.children,a),gl(t,n),t===null&&(n.flags|=4194304),n.child;case 5:return t===null&&ve&&((u=s=Xe)&&(s=LS(s,n.type,n.pendingProps,ii),s!==null?(n.stateNode=s,_n=n,Xe=ri(s.firstChild),ii=!1,u=!0):u=!1),u||ha(n)),jt(n),u=n.type,f=n.pendingProps,g=t!==null?t.memoizedProps:null,s=f.children,Mf(u,f)?s=null:g!==null&&Mf(u,g)&&(n.flags|=32),n.memoizedState!==null&&(u=Sc(t,n,Yv,null,null,a),po._currentValue=u),gl(t,n),Sn(t,n,s,a),n.child;case 6:return t===null&&ve&&((t=a=Xe)&&(a=NS(a,n.pendingProps,ii),a!==null?(n.stateNode=a,_n=n,Xe=null,t=!0):t=!1),t||ha(n)),null;case 13:return Cm(t,n,a);case 4:return zt(n,n.stateNode.containerInfo),s=n.pendingProps,t===null?n.child=ir(n,null,s,a):Sn(t,n,s,a),n.child;case 11:return Sm(t,n,n.type,n.pendingProps,a);case 7:return Sn(t,n,n.pendingProps,a),n.child;case 8:return Sn(t,n,n.pendingProps.children,a),n.child;case 12:return Sn(t,n,n.pendingProps.children,a),n.child;case 10:return s=n.pendingProps,da(n,n.type,s.value),Sn(t,n,s.children,a),n.child;case 9:return u=n.type._context,s=n.pendingProps.children,$a(n),u=vn(u),s=s(u),n.flags|=1,Sn(t,n,s,a),n.child;case 14:return xm(t,n,n.type,n.pendingProps,a);case 15:return Mm(t,n,n.type,n.pendingProps,a);case 19:return Dm(t,n,a);case 31:return eS(t,n,a);case 22:return ym(t,n,a,n.pendingProps);case 24:return $a(n),s=vn(tn),t===null?(u=uc(),u===null&&(u=He,f=oc(),u.pooledCache=f,f.refCount++,f!==null&&(u.pooledCacheLanes|=a),u=f),n.memoizedState={parent:s,cache:u},fc(n),da(n,tn,u)):((t.lanes&a)!==0&&(hc(t,n),Ys(n,null,null,a),qs()),u=t.memoizedState,f=n.memoizedState,u.parent!==s?(u={parent:s,cache:s},n.memoizedState=u,n.lanes===0&&(n.memoizedState=n.updateQueue.baseState=u),da(n,tn,s)):(s=f.cache,da(n,tn,s),s!==u.cache&&sc(n,[tn],a,!0))),Sn(t,n,n.pendingProps.children,a),n.child;case 29:throw n.pendingProps}throw Error(r(156,n.tag))}function ki(t){t.flags|=4}function Yc(t,n,a,s,u){if((n=(t.mode&32)!==0)&&(n=!1),n){if(t.flags|=16777216,(u&335544128)===u)if(t.stateNode.complete)t.flags|=8192;else if(ag())t.flags|=8192;else throw nr=el,cc}else t.flags&=-16777217}function Lm(t,n){if(n.type!=="stylesheet"||(n.state.loading&4)!==0)t.flags&=-16777217;else if(t.flags|=16777216,!Yg(n))if(ag())t.flags|=8192;else throw nr=el,cc}function vl(t,n){n!==null&&(t.flags|=4),t.flags&16384&&(n=t.tag!==22?sn():536870912,t.lanes|=n,qr|=n)}function $s(t,n){if(!ve)switch(t.tailMode){case"hidden":n=t.tail;for(var a=null;n!==null;)n.alternate!==null&&(a=n),n=n.sibling;a===null?t.tail=null:a.sibling=null;break;case"collapsed":a=t.tail;for(var s=null;a!==null;)a.alternate!==null&&(s=a),a=a.sibling;s===null?n||t.tail===null?t.tail=null:t.tail.sibling=null:s.sibling=null}}function ke(t){var n=t.alternate!==null&&t.alternate.child===t.child,a=0,s=0;if(n)for(var u=t.child;u!==null;)a|=u.lanes|u.childLanes,s|=u.subtreeFlags&65011712,s|=u.flags&65011712,u.return=t,u=u.sibling;else for(u=t.child;u!==null;)a|=u.lanes|u.childLanes,s|=u.subtreeFlags,s|=u.flags,u.return=t,u=u.sibling;return t.subtreeFlags|=s,t.childLanes=a,n}function iS(t,n,a){var s=n.pendingProps;switch(ec(n),n.tag){case 16:case 15:case 0:case 11:case 7:case 8:case 12:case 9:case 14:return ke(n),null;case 1:return ke(n),null;case 3:return a=n.stateNode,s=null,t!==null&&(s=t.memoizedState.cache),n.memoizedState.cache!==s&&(n.flags|=2048),Hi(tn),qt(),a.pendingContext&&(a.context=a.pendingContext,a.pendingContext=null),(t===null||t.child===null)&&(Nr(n)?ki(n):t===null||t.memoizedState.isDehydrated&&(n.flags&256)===0||(n.flags|=1024,ic())),ke(n),null;case 26:var u=n.type,f=n.memoizedState;return t===null?(ki(n),f!==null?(ke(n),Lm(n,f)):(ke(n),Yc(n,u,null,s,a))):f?f!==t.memoizedState?(ki(n),ke(n),Lm(n,f)):(ke(n),n.flags&=-16777217):(t=t.memoizedProps,t!==s&&ki(n),ke(n),Yc(n,u,t,s,a)),null;case 27:if(Ge(n),a=yt.current,u=n.type,t!==null&&n.stateNode!=null)t.memoizedProps!==s&&ki(n);else{if(!s){if(n.stateNode===null)throw Error(r(166));return ke(n),null}t=K.current,Nr(n)?fp(n):(t=Fg(u,s,a),n.stateNode=t,ki(n))}return ke(n),null;case 5:if(Ge(n),u=n.type,t!==null&&n.stateNode!=null)t.memoizedProps!==s&&ki(n);else{if(!s){if(n.stateNode===null)throw Error(r(166));return ke(n),null}if(f=K.current,Nr(n))fp(n);else{var g=Nl(yt.current);switch(f){case 1:f=g.createElementNS("http://www.w3.org/2000/svg",u);break;case 2:f=g.createElementNS("http://www.w3.org/1998/Math/MathML",u);break;default:switch(u){case"svg":f=g.createElementNS("http://www.w3.org/2000/svg",u);break;case"math":f=g.createElementNS("http://www.w3.org/1998/Math/MathML",u);break;case"script":f=g.createElement("div"),f.innerHTML="<script><\/script>",f=f.removeChild(f.firstChild);break;case"select":f=typeof s.is=="string"?g.createElement("select",{is:s.is}):g.createElement("select"),s.multiple?f.multiple=!0:s.size&&(f.size=s.size);break;default:f=typeof s.is=="string"?g.createElement(u,{is:s.is}):g.createElement(u)}}f[je]=n,f[mn]=s;t:for(g=n.child;g!==null;){if(g.tag===5||g.tag===6)f.appendChild(g.stateNode);else if(g.tag!==4&&g.tag!==27&&g.child!==null){g.child.return=g,g=g.child;continue}if(g===n)break t;for(;g.sibling===null;){if(g.return===null||g.return===n)break t;g=g.return}g.sibling.return=g.return,g=g.sibling}n.stateNode=f;t:switch(xn(f,u,s),u){case"button":case"input":case"select":case"textarea":s=!!s.autoFocus;break t;case"img":s=!0;break t;default:s=!1}s&&ki(n)}}return ke(n),Yc(n,n.type,t===null?null:t.memoizedProps,n.pendingProps,a),null;case 6:if(t&&n.stateNode!=null)t.memoizedProps!==s&&ki(n);else{if(typeof s!="string"&&n.stateNode===null)throw Error(r(166));if(t=yt.current,Nr(n)){if(t=n.stateNode,a=n.memoizedProps,s=null,u=_n,u!==null)switch(u.tag){case 27:case 5:s=u.memoizedProps}t[je]=n,t=!!(t.nodeValue===a||s!==null&&s.suppressHydrationWarning===!0||Cg(t.nodeValue,a)),t||ha(n,!0)}else t=Nl(t).createTextNode(s),t[je]=n,n.stateNode=t}return ke(n),null;case 31:if(a=n.memoizedState,t===null||t.memoizedState!==null){if(s=Nr(n),a!==null){if(t===null){if(!s)throw Error(r(318));if(t=n.memoizedState,t=t!==null?t.dehydrated:null,!t)throw Error(r(557));t[je]=n}else Qa(),(n.flags&128)===0&&(n.memoizedState=null),n.flags|=4;ke(n),t=!1}else a=ic(),t!==null&&t.memoizedState!==null&&(t.memoizedState.hydrationErrors=a),t=!0;if(!t)return n.flags&256?(qn(n),n):(qn(n),null);if((n.flags&128)!==0)throw Error(r(558))}return ke(n),null;case 13:if(s=n.memoizedState,t===null||t.memoizedState!==null&&t.memoizedState.dehydrated!==null){if(u=Nr(n),s!==null&&s.dehydrated!==null){if(t===null){if(!u)throw Error(r(318));if(u=n.memoizedState,u=u!==null?u.dehydrated:null,!u)throw Error(r(317));u[je]=n}else Qa(),(n.flags&128)===0&&(n.memoizedState=null),n.flags|=4;ke(n),u=!1}else u=ic(),t!==null&&t.memoizedState!==null&&(t.memoizedState.hydrationErrors=u),u=!0;if(!u)return n.flags&256?(qn(n),n):(qn(n),null)}return qn(n),(n.flags&128)!==0?(n.lanes=a,n):(a=s!==null,t=t!==null&&t.memoizedState!==null,a&&(s=n.child,u=null,s.alternate!==null&&s.alternate.memoizedState!==null&&s.alternate.memoizedState.cachePool!==null&&(u=s.alternate.memoizedState.cachePool.pool),f=null,s.memoizedState!==null&&s.memoizedState.cachePool!==null&&(f=s.memoizedState.cachePool.pool),f!==u&&(s.flags|=2048)),a!==t&&a&&(n.child.flags|=8192),vl(n,n.updateQueue),ke(n),null);case 4:return qt(),t===null&&gf(n.stateNode.containerInfo),ke(n),null;case 10:return Hi(n.type),ke(n),null;case 19:if(nt(Je),s=n.memoizedState,s===null)return ke(n),null;if(u=(n.flags&128)!==0,f=s.rendering,f===null)if(u)$s(s,!1);else{if(Qe!==0||t!==null&&(t.flags&128)!==0)for(t=n.child;t!==null;){if(f=rl(t),f!==null){for(n.flags|=128,$s(s,!1),t=f.updateQueue,n.updateQueue=t,vl(n,t),n.subtreeFlags=0,t=a,a=n.child;a!==null;)sp(a,t),a=a.sibling;return xt(Je,Je.current&1|2),ve&&Ii(n,s.treeForkCount),n.child}t=t.sibling}s.tail!==null&&ct()>El&&(n.flags|=128,u=!0,$s(s,!1),n.lanes=4194304)}else{if(!u)if(t=rl(f),t!==null){if(n.flags|=128,u=!0,t=t.updateQueue,n.updateQueue=t,vl(n,t),$s(s,!0),s.tail===null&&s.tailMode==="hidden"&&!f.alternate&&!ve)return ke(n),null}else 2*ct()-s.renderingStartTime>El&&a!==536870912&&(n.flags|=128,u=!0,$s(s,!1),n.lanes=4194304);s.isBackwards?(f.sibling=n.child,n.child=f):(t=s.last,t!==null?t.sibling=f:n.child=f,s.last=f)}return s.tail!==null?(t=s.tail,s.rendering=t,s.tail=t.sibling,s.renderingStartTime=ct(),t.sibling=null,a=Je.current,xt(Je,u?a&1|2:a&1),ve&&Ii(n,s.treeForkCount),t):(ke(n),null);case 22:case 23:return qn(n),gc(),s=n.memoizedState!==null,t!==null?t.memoizedState!==null!==s&&(n.flags|=8192):s&&(n.flags|=8192),s?(a&536870912)!==0&&(n.flags&128)===0&&(ke(n),n.subtreeFlags&6&&(n.flags|=8192)):ke(n),a=n.updateQueue,a!==null&&vl(n,a.retryQueue),a=null,t!==null&&t.memoizedState!==null&&t.memoizedState.cachePool!==null&&(a=t.memoizedState.cachePool.pool),s=null,n.memoizedState!==null&&n.memoizedState.cachePool!==null&&(s=n.memoizedState.cachePool.pool),s!==a&&(n.flags|=2048),t!==null&&nt(tr),null;case 24:return a=null,t!==null&&(a=t.memoizedState.cache),n.memoizedState.cache!==a&&(n.flags|=2048),Hi(tn),ke(n),null;case 25:return null;case 30:return null}throw Error(r(156,n.tag))}function aS(t,n){switch(ec(n),n.tag){case 1:return t=n.flags,t&65536?(n.flags=t&-65537|128,n):null;case 3:return Hi(tn),qt(),t=n.flags,(t&65536)!==0&&(t&128)===0?(n.flags=t&-65537|128,n):null;case 26:case 27:case 5:return Ge(n),null;case 31:if(n.memoizedState!==null){if(qn(n),n.alternate===null)throw Error(r(340));Qa()}return t=n.flags,t&65536?(n.flags=t&-65537|128,n):null;case 13:if(qn(n),t=n.memoizedState,t!==null&&t.dehydrated!==null){if(n.alternate===null)throw Error(r(340));Qa()}return t=n.flags,t&65536?(n.flags=t&-65537|128,n):null;case 19:return nt(Je),null;case 4:return qt(),null;case 10:return Hi(n.type),null;case 22:case 23:return qn(n),gc(),t!==null&&nt(tr),t=n.flags,t&65536?(n.flags=t&-65537|128,n):null;case 24:return Hi(tn),null;case 25:return null;default:return null}}function Nm(t,n){switch(ec(n),n.tag){case 3:Hi(tn),qt();break;case 26:case 27:case 5:Ge(n);break;case 4:qt();break;case 31:n.memoizedState!==null&&qn(n);break;case 13:qn(n);break;case 19:nt(Je);break;case 10:Hi(n.type);break;case 22:case 23:qn(n),gc(),t!==null&&nt(tr);break;case 24:Hi(tn)}}function to(t,n){try{var a=n.updateQueue,s=a!==null?a.lastEffect:null;if(s!==null){var u=s.next;a=u;do{if((a.tag&t)===t){s=void 0;var f=a.create,g=a.inst;s=f(),g.destroy=s}a=a.next}while(a!==u)}}catch(E){Ue(n,n.return,E)}}function Sa(t,n,a){try{var s=n.updateQueue,u=s!==null?s.lastEffect:null;if(u!==null){var f=u.next;s=f;do{if((s.tag&t)===t){var g=s.inst,E=g.destroy;if(E!==void 0){g.destroy=void 0,u=n;var F=a,$=E;try{$()}catch(ut){Ue(u,F,ut)}}}s=s.next}while(s!==f)}}catch(ut){Ue(n,n.return,ut)}}function Om(t){var n=t.updateQueue;if(n!==null){var a=t.stateNode;try{Tp(n,a)}catch(s){Ue(t,t.return,s)}}}function zm(t,n,a){a.props=rr(t.type,t.memoizedProps),a.state=t.memoizedState;try{a.componentWillUnmount()}catch(s){Ue(t,n,s)}}function eo(t,n){try{var a=t.ref;if(a!==null){switch(t.tag){case 26:case 27:case 5:var s=t.stateNode;break;case 30:s=t.stateNode;break;default:s=t.stateNode}typeof a=="function"?t.refCleanup=a(s):a.current=s}}catch(u){Ue(t,n,u)}}function Ai(t,n){var a=t.ref,s=t.refCleanup;if(a!==null)if(typeof s=="function")try{s()}catch(u){Ue(t,n,u)}finally{t.refCleanup=null,t=t.alternate,t!=null&&(t.refCleanup=null)}else if(typeof a=="function")try{a(null)}catch(u){Ue(t,n,u)}else a.current=null}function Pm(t){var n=t.type,a=t.memoizedProps,s=t.stateNode;try{t:switch(n){case"button":case"input":case"select":case"textarea":a.autoFocus&&s.focus();break t;case"img":a.src?s.src=a.src:a.srcSet&&(s.srcset=a.srcSet)}}catch(u){Ue(t,t.return,u)}}function jc(t,n,a){try{var s=t.stateNode;AS(s,t.type,a,n),s[mn]=n}catch(u){Ue(t,t.return,u)}}function Bm(t){return t.tag===5||t.tag===3||t.tag===26||t.tag===27&&Aa(t.type)||t.tag===4}function Zc(t){t:for(;;){for(;t.sibling===null;){if(t.return===null||Bm(t.return))return null;t=t.return}for(t.sibling.return=t.return,t=t.sibling;t.tag!==5&&t.tag!==6&&t.tag!==18;){if(t.tag===27&&Aa(t.type)||t.flags&2||t.child===null||t.tag===4)continue t;t.child.return=t,t=t.child}if(!(t.flags&2))return t.stateNode}}function Kc(t,n,a){var s=t.tag;if(s===5||s===6)t=t.stateNode,n?(a.nodeType===9?a.body:a.nodeName==="HTML"?a.ownerDocument.body:a).insertBefore(t,n):(n=a.nodeType===9?a.body:a.nodeName==="HTML"?a.ownerDocument.body:a,n.appendChild(t),a=a._reactRootContainer,a!=null||n.onclick!==null||(n.onclick=zi));else if(s!==4&&(s===27&&Aa(t.type)&&(a=t.stateNode,n=null),t=t.child,t!==null))for(Kc(t,n,a),t=t.sibling;t!==null;)Kc(t,n,a),t=t.sibling}function Sl(t,n,a){var s=t.tag;if(s===5||s===6)t=t.stateNode,n?a.insertBefore(t,n):a.appendChild(t);else if(s!==4&&(s===27&&Aa(t.type)&&(a=t.stateNode),t=t.child,t!==null))for(Sl(t,n,a),t=t.sibling;t!==null;)Sl(t,n,a),t=t.sibling}function Im(t){var n=t.stateNode,a=t.memoizedProps;try{for(var s=t.type,u=n.attributes;u.length;)n.removeAttributeNode(u[0]);xn(n,s,a),n[je]=t,n[mn]=a}catch(f){Ue(t,t.return,f)}}var Wi=!1,an=!1,Qc=!1,Fm=typeof WeakSet=="function"?WeakSet:Set,hn=null;function rS(t,n){if(t=t.containerInfo,Sf=Hl,t=Qd(t),ku(t)){if("selectionStart"in t)var a={start:t.selectionStart,end:t.selectionEnd};else t:{a=(a=t.ownerDocument)&&a.defaultView||window;var s=a.getSelection&&a.getSelection();if(s&&s.rangeCount!==0){a=s.anchorNode;var u=s.anchorOffset,f=s.focusNode;s=s.focusOffset;try{a.nodeType,f.nodeType}catch{a=null;break t}var g=0,E=-1,F=-1,$=0,ut=0,gt=t,tt=null;e:for(;;){for(var ot;gt!==a||u!==0&&gt.nodeType!==3||(E=g+u),gt!==f||s!==0&&gt.nodeType!==3||(F=g+s),gt.nodeType===3&&(g+=gt.nodeValue.length),(ot=gt.firstChild)!==null;)tt=gt,gt=ot;for(;;){if(gt===t)break e;if(tt===a&&++$===u&&(E=g),tt===f&&++ut===s&&(F=g),(ot=gt.nextSibling)!==null)break;gt=tt,tt=gt.parentNode}gt=ot}a=E===-1||F===-1?null:{start:E,end:F}}else a=null}a=a||{start:0,end:0}}else a=null;for(xf={focusedElem:t,selectionRange:a},Hl=!1,hn=n;hn!==null;)if(n=hn,t=n.child,(n.subtreeFlags&1028)!==0&&t!==null)t.return=n,hn=t;else for(;hn!==null;){switch(n=hn,f=n.alternate,t=n.flags,n.tag){case 0:if((t&4)!==0&&(t=n.updateQueue,t=t!==null?t.events:null,t!==null))for(a=0;a<t.length;a++)u=t[a],u.ref.impl=u.nextImpl;break;case 11:case 15:break;case 1:if((t&1024)!==0&&f!==null){t=void 0,a=n,u=f.memoizedProps,f=f.memoizedState,s=a.stateNode;try{var Bt=rr(a.type,u);t=s.getSnapshotBeforeUpdate(Bt,f),s.__reactInternalSnapshotBeforeUpdate=t}catch(Kt){Ue(a,a.return,Kt)}}break;case 3:if((t&1024)!==0){if(t=n.stateNode.containerInfo,a=t.nodeType,a===9)Ef(t);else if(a===1)switch(t.nodeName){case"HEAD":case"HTML":case"BODY":Ef(t);break;default:t.textContent=""}}break;case 5:case 26:case 27:case 6:case 4:case 17:break;default:if((t&1024)!==0)throw Error(r(163))}if(t=n.sibling,t!==null){t.return=n.return,hn=t;break}hn=n.return}}function Hm(t,n,a){var s=a.flags;switch(a.tag){case 0:case 11:case 15:Yi(t,a),s&4&&to(5,a);break;case 1:if(Yi(t,a),s&4)if(t=a.stateNode,n===null)try{t.componentDidMount()}catch(g){Ue(a,a.return,g)}else{var u=rr(a.type,n.memoizedProps);n=n.memoizedState;try{t.componentDidUpdate(u,n,t.__reactInternalSnapshotBeforeUpdate)}catch(g){Ue(a,a.return,g)}}s&64&&Om(a),s&512&&eo(a,a.return);break;case 3:if(Yi(t,a),s&64&&(t=a.updateQueue,t!==null)){if(n=null,a.child!==null)switch(a.child.tag){case 27:case 5:n=a.child.stateNode;break;case 1:n=a.child.stateNode}try{Tp(t,n)}catch(g){Ue(a,a.return,g)}}break;case 27:n===null&&s&4&&Im(a);case 26:case 5:Yi(t,a),n===null&&s&4&&Pm(a),s&512&&eo(a,a.return);break;case 12:Yi(t,a);break;case 31:Yi(t,a),s&4&&Xm(t,a);break;case 13:Yi(t,a),s&4&&km(t,a),s&64&&(t=a.memoizedState,t!==null&&(t=t.dehydrated,t!==null&&(a=pS.bind(null,a),OS(t,a))));break;case 22:if(s=a.memoizedState!==null||Wi,!s){n=n!==null&&n.memoizedState!==null||an,u=Wi;var f=an;Wi=s,(an=n)&&!f?ji(t,a,(a.subtreeFlags&8772)!==0):Yi(t,a),Wi=u,an=f}break;case 30:break;default:Yi(t,a)}}function Gm(t){var n=t.alternate;n!==null&&(t.alternate=null,Gm(n)),t.child=null,t.deletions=null,t.sibling=null,t.tag===5&&(n=t.stateNode,n!==null&&ws(n)),t.stateNode=null,t.return=null,t.dependencies=null,t.memoizedProps=null,t.memoizedState=null,t.pendingProps=null,t.stateNode=null,t.updateQueue=null}var qe=null,zn=!1;function qi(t,n,a){for(a=a.child;a!==null;)Vm(t,n,a),a=a.sibling}function Vm(t,n,a){if(Ht&&typeof Ht.onCommitFiberUnmount=="function")try{Ht.onCommitFiberUnmount(Yt,a)}catch{}switch(a.tag){case 26:an||Ai(a,n),qi(t,n,a),a.memoizedState?a.memoizedState.count--:a.stateNode&&(a=a.stateNode,a.parentNode.removeChild(a));break;case 27:an||Ai(a,n);var s=qe,u=zn;Aa(a.type)&&(qe=a.stateNode,zn=!1),qi(t,n,a),co(a.stateNode),qe=s,zn=u;break;case 5:an||Ai(a,n);case 6:if(s=qe,u=zn,qe=null,qi(t,n,a),qe=s,zn=u,qe!==null)if(zn)try{(qe.nodeType===9?qe.body:qe.nodeName==="HTML"?qe.ownerDocument.body:qe).removeChild(a.stateNode)}catch(f){Ue(a,n,f)}else try{qe.removeChild(a.stateNode)}catch(f){Ue(a,n,f)}break;case 18:qe!==null&&(zn?(t=qe,Og(t.nodeType===9?t.body:t.nodeName==="HTML"?t.ownerDocument.body:t,a.stateNode),ts(t)):Og(qe,a.stateNode));break;case 4:s=qe,u=zn,qe=a.stateNode.containerInfo,zn=!0,qi(t,n,a),qe=s,zn=u;break;case 0:case 11:case 14:case 15:Sa(2,a,n),an||Sa(4,a,n),qi(t,n,a);break;case 1:an||(Ai(a,n),s=a.stateNode,typeof s.componentWillUnmount=="function"&&zm(a,n,s)),qi(t,n,a);break;case 21:qi(t,n,a);break;case 22:an=(s=an)||a.memoizedState!==null,qi(t,n,a),an=s;break;default:qi(t,n,a)}}function Xm(t,n){if(n.memoizedState===null&&(t=n.alternate,t!==null&&(t=t.memoizedState,t!==null))){t=t.dehydrated;try{ts(t)}catch(a){Ue(n,n.return,a)}}}function km(t,n){if(n.memoizedState===null&&(t=n.alternate,t!==null&&(t=t.memoizedState,t!==null&&(t=t.dehydrated,t!==null))))try{ts(t)}catch(a){Ue(n,n.return,a)}}function sS(t){switch(t.tag){case 31:case 13:case 19:var n=t.stateNode;return n===null&&(n=t.stateNode=new Fm),n;case 22:return t=t.stateNode,n=t._retryCache,n===null&&(n=t._retryCache=new Fm),n;default:throw Error(r(435,t.tag))}}function xl(t,n){var a=sS(t);n.forEach(function(s){if(!a.has(s)){a.add(s);var u=mS.bind(null,t,s);s.then(u,u)}})}function Pn(t,n){var a=n.deletions;if(a!==null)for(var s=0;s<a.length;s++){var u=a[s],f=t,g=n,E=g;t:for(;E!==null;){switch(E.tag){case 27:if(Aa(E.type)){qe=E.stateNode,zn=!1;break t}break;case 5:qe=E.stateNode,zn=!1;break t;case 3:case 4:qe=E.stateNode.containerInfo,zn=!0;break t}E=E.return}if(qe===null)throw Error(r(160));Vm(f,g,u),qe=null,zn=!1,f=u.alternate,f!==null&&(f.return=null),u.return=null}if(n.subtreeFlags&13886)for(n=n.child;n!==null;)Wm(n,t),n=n.sibling}var pi=null;function Wm(t,n){var a=t.alternate,s=t.flags;switch(t.tag){case 0:case 11:case 14:case 15:Pn(n,t),Bn(t),s&4&&(Sa(3,t,t.return),to(3,t),Sa(5,t,t.return));break;case 1:Pn(n,t),Bn(t),s&512&&(an||a===null||Ai(a,a.return)),s&64&&Wi&&(t=t.updateQueue,t!==null&&(s=t.callbacks,s!==null&&(a=t.shared.hiddenCallbacks,t.shared.hiddenCallbacks=a===null?s:a.concat(s))));break;case 26:var u=pi;if(Pn(n,t),Bn(t),s&512&&(an||a===null||Ai(a,a.return)),s&4){var f=a!==null?a.memoizedState:null;if(s=t.memoizedState,a===null)if(s===null)if(t.stateNode===null){t:{s=t.type,a=t.memoizedProps,u=u.ownerDocument||u;e:switch(s){case"title":f=u.getElementsByTagName("title")[0],(!f||f[Wa]||f[je]||f.namespaceURI==="http://www.w3.org/2000/svg"||f.hasAttribute("itemprop"))&&(f=u.createElement(s),u.head.insertBefore(f,u.querySelector("head > title"))),xn(f,s,a),f[je]=t,k(f),s=f;break t;case"link":var g=Wg("link","href",u).get(s+(a.href||""));if(g){for(var E=0;E<g.length;E++)if(f=g[E],f.getAttribute("href")===(a.href==null||a.href===""?null:a.href)&&f.getAttribute("rel")===(a.rel==null?null:a.rel)&&f.getAttribute("title")===(a.title==null?null:a.title)&&f.getAttribute("crossorigin")===(a.crossOrigin==null?null:a.crossOrigin)){g.splice(E,1);break e}}f=u.createElement(s),xn(f,s,a),u.head.appendChild(f);break;case"meta":if(g=Wg("meta","content",u).get(s+(a.content||""))){for(E=0;E<g.length;E++)if(f=g[E],f.getAttribute("content")===(a.content==null?null:""+a.content)&&f.getAttribute("name")===(a.name==null?null:a.name)&&f.getAttribute("property")===(a.property==null?null:a.property)&&f.getAttribute("http-equiv")===(a.httpEquiv==null?null:a.httpEquiv)&&f.getAttribute("charset")===(a.charSet==null?null:a.charSet)){g.splice(E,1);break e}}f=u.createElement(s),xn(f,s,a),u.head.appendChild(f);break;default:throw Error(r(468,s))}f[je]=t,k(f),s=f}t.stateNode=s}else qg(u,t.type,t.stateNode);else t.stateNode=kg(u,s,t.memoizedProps);else f!==s?(f===null?a.stateNode!==null&&(a=a.stateNode,a.parentNode.removeChild(a)):f.count--,s===null?qg(u,t.type,t.stateNode):kg(u,s,t.memoizedProps)):s===null&&t.stateNode!==null&&jc(t,t.memoizedProps,a.memoizedProps)}break;case 27:Pn(n,t),Bn(t),s&512&&(an||a===null||Ai(a,a.return)),a!==null&&s&4&&jc(t,t.memoizedProps,a.memoizedProps);break;case 5:if(Pn(n,t),Bn(t),s&512&&(an||a===null||Ai(a,a.return)),t.flags&32){u=t.stateNode;try{Nn(u,"")}catch(Bt){Ue(t,t.return,Bt)}}s&4&&t.stateNode!=null&&(u=t.memoizedProps,jc(t,u,a!==null?a.memoizedProps:u)),s&1024&&(Qc=!0);break;case 6:if(Pn(n,t),Bn(t),s&4){if(t.stateNode===null)throw Error(r(162));s=t.memoizedProps,a=t.stateNode;try{a.nodeValue=s}catch(Bt){Ue(t,t.return,Bt)}}break;case 3:if(Pl=null,u=pi,pi=Ol(n.containerInfo),Pn(n,t),pi=u,Bn(t),s&4&&a!==null&&a.memoizedState.isDehydrated)try{ts(n.containerInfo)}catch(Bt){Ue(t,t.return,Bt)}Qc&&(Qc=!1,qm(t));break;case 4:s=pi,pi=Ol(t.stateNode.containerInfo),Pn(n,t),Bn(t),pi=s;break;case 12:Pn(n,t),Bn(t);break;case 31:Pn(n,t),Bn(t),s&4&&(s=t.updateQueue,s!==null&&(t.updateQueue=null,xl(t,s)));break;case 13:Pn(n,t),Bn(t),t.child.flags&8192&&t.memoizedState!==null!=(a!==null&&a.memoizedState!==null)&&(yl=ct()),s&4&&(s=t.updateQueue,s!==null&&(t.updateQueue=null,xl(t,s)));break;case 22:u=t.memoizedState!==null;var F=a!==null&&a.memoizedState!==null,$=Wi,ut=an;if(Wi=$||u,an=ut||F,Pn(n,t),an=ut,Wi=$,Bn(t),s&8192)t:for(n=t.stateNode,n._visibility=u?n._visibility&-2:n._visibility|1,u&&(a===null||F||Wi||an||sr(t)),a=null,n=t;;){if(n.tag===5||n.tag===26){if(a===null){F=a=n;try{if(f=F.stateNode,u)g=f.style,typeof g.setProperty=="function"?g.setProperty("display","none","important"):g.display="none";else{E=F.stateNode;var gt=F.memoizedProps.style,tt=gt!=null&&gt.hasOwnProperty("display")?gt.display:null;E.style.display=tt==null||typeof tt=="boolean"?"":(""+tt).trim()}}catch(Bt){Ue(F,F.return,Bt)}}}else if(n.tag===6){if(a===null){F=n;try{F.stateNode.nodeValue=u?"":F.memoizedProps}catch(Bt){Ue(F,F.return,Bt)}}}else if(n.tag===18){if(a===null){F=n;try{var ot=F.stateNode;u?zg(ot,!0):zg(F.stateNode,!1)}catch(Bt){Ue(F,F.return,Bt)}}}else if((n.tag!==22&&n.tag!==23||n.memoizedState===null||n===t)&&n.child!==null){n.child.return=n,n=n.child;continue}if(n===t)break t;for(;n.sibling===null;){if(n.return===null||n.return===t)break t;a===n&&(a=null),n=n.return}a===n&&(a=null),n.sibling.return=n.return,n=n.sibling}s&4&&(s=t.updateQueue,s!==null&&(a=s.retryQueue,a!==null&&(s.retryQueue=null,xl(t,a))));break;case 19:Pn(n,t),Bn(t),s&4&&(s=t.updateQueue,s!==null&&(t.updateQueue=null,xl(t,s)));break;case 30:break;case 21:break;default:Pn(n,t),Bn(t)}}function Bn(t){var n=t.flags;if(n&2){try{for(var a,s=t.return;s!==null;){if(Bm(s)){a=s;break}s=s.return}if(a==null)throw Error(r(160));switch(a.tag){case 27:var u=a.stateNode,f=Zc(t);Sl(t,f,u);break;case 5:var g=a.stateNode;a.flags&32&&(Nn(g,""),a.flags&=-33);var E=Zc(t);Sl(t,E,g);break;case 3:case 4:var F=a.stateNode.containerInfo,$=Zc(t);Kc(t,$,F);break;default:throw Error(r(161))}}catch(ut){Ue(t,t.return,ut)}t.flags&=-3}n&4096&&(t.flags&=-4097)}function qm(t){if(t.subtreeFlags&1024)for(t=t.child;t!==null;){var n=t;qm(n),n.tag===5&&n.flags&1024&&n.stateNode.reset(),t=t.sibling}}function Yi(t,n){if(n.subtreeFlags&8772)for(n=n.child;n!==null;)Hm(t,n.alternate,n),n=n.sibling}function sr(t){for(t=t.child;t!==null;){var n=t;switch(n.tag){case 0:case 11:case 14:case 15:Sa(4,n,n.return),sr(n);break;case 1:Ai(n,n.return);var a=n.stateNode;typeof a.componentWillUnmount=="function"&&zm(n,n.return,a),sr(n);break;case 27:co(n.stateNode);case 26:case 5:Ai(n,n.return),sr(n);break;case 22:n.memoizedState===null&&sr(n);break;case 30:sr(n);break;default:sr(n)}t=t.sibling}}function ji(t,n,a){for(a=a&&(n.subtreeFlags&8772)!==0,n=n.child;n!==null;){var s=n.alternate,u=t,f=n,g=f.flags;switch(f.tag){case 0:case 11:case 15:ji(u,f,a),to(4,f);break;case 1:if(ji(u,f,a),s=f,u=s.stateNode,typeof u.componentDidMount=="function")try{u.componentDidMount()}catch($){Ue(s,s.return,$)}if(s=f,u=s.updateQueue,u!==null){var E=s.stateNode;try{var F=u.shared.hiddenCallbacks;if(F!==null)for(u.shared.hiddenCallbacks=null,u=0;u<F.length;u++)Ep(F[u],E)}catch($){Ue(s,s.return,$)}}a&&g&64&&Om(f),eo(f,f.return);break;case 27:Im(f);case 26:case 5:ji(u,f,a),a&&s===null&&g&4&&Pm(f),eo(f,f.return);break;case 12:ji(u,f,a);break;case 31:ji(u,f,a),a&&g&4&&Xm(u,f);break;case 13:ji(u,f,a),a&&g&4&&km(u,f);break;case 22:f.memoizedState===null&&ji(u,f,a),eo(f,f.return);break;case 30:break;default:ji(u,f,a)}n=n.sibling}}function Jc(t,n){var a=null;t!==null&&t.memoizedState!==null&&t.memoizedState.cachePool!==null&&(a=t.memoizedState.cachePool.pool),t=null,n.memoizedState!==null&&n.memoizedState.cachePool!==null&&(t=n.memoizedState.cachePool.pool),t!==a&&(t!=null&&t.refCount++,a!=null&&Gs(a))}function $c(t,n){t=null,n.alternate!==null&&(t=n.alternate.memoizedState.cache),n=n.memoizedState.cache,n!==t&&(n.refCount++,t!=null&&Gs(t))}function mi(t,n,a,s){if(n.subtreeFlags&10256)for(n=n.child;n!==null;)Ym(t,n,a,s),n=n.sibling}function Ym(t,n,a,s){var u=n.flags;switch(n.tag){case 0:case 11:case 15:mi(t,n,a,s),u&2048&&to(9,n);break;case 1:mi(t,n,a,s);break;case 3:mi(t,n,a,s),u&2048&&(t=null,n.alternate!==null&&(t=n.alternate.memoizedState.cache),n=n.memoizedState.cache,n!==t&&(n.refCount++,t!=null&&Gs(t)));break;case 12:if(u&2048){mi(t,n,a,s),t=n.stateNode;try{var f=n.memoizedProps,g=f.id,E=f.onPostCommit;typeof E=="function"&&E(g,n.alternate===null?"mount":"update",t.passiveEffectDuration,-0)}catch(F){Ue(n,n.return,F)}}else mi(t,n,a,s);break;case 31:mi(t,n,a,s);break;case 13:mi(t,n,a,s);break;case 23:break;case 22:f=n.stateNode,g=n.alternate,n.memoizedState!==null?f._visibility&2?mi(t,n,a,s):no(t,n):f._visibility&2?mi(t,n,a,s):(f._visibility|=2,Xr(t,n,a,s,(n.subtreeFlags&10256)!==0||!1)),u&2048&&Jc(g,n);break;case 24:mi(t,n,a,s),u&2048&&$c(n.alternate,n);break;default:mi(t,n,a,s)}}function Xr(t,n,a,s,u){for(u=u&&((n.subtreeFlags&10256)!==0||!1),n=n.child;n!==null;){var f=t,g=n,E=a,F=s,$=g.flags;switch(g.tag){case 0:case 11:case 15:Xr(f,g,E,F,u),to(8,g);break;case 23:break;case 22:var ut=g.stateNode;g.memoizedState!==null?ut._visibility&2?Xr(f,g,E,F,u):no(f,g):(ut._visibility|=2,Xr(f,g,E,F,u)),u&&$&2048&&Jc(g.alternate,g);break;case 24:Xr(f,g,E,F,u),u&&$&2048&&$c(g.alternate,g);break;default:Xr(f,g,E,F,u)}n=n.sibling}}function no(t,n){if(n.subtreeFlags&10256)for(n=n.child;n!==null;){var a=t,s=n,u=s.flags;switch(s.tag){case 22:no(a,s),u&2048&&Jc(s.alternate,s);break;case 24:no(a,s),u&2048&&$c(s.alternate,s);break;default:no(a,s)}n=n.sibling}}var io=8192;function kr(t,n,a){if(t.subtreeFlags&io)for(t=t.child;t!==null;)jm(t,n,a),t=t.sibling}function jm(t,n,a){switch(t.tag){case 26:kr(t,n,a),t.flags&io&&t.memoizedState!==null&&qS(a,pi,t.memoizedState,t.memoizedProps);break;case 5:kr(t,n,a);break;case 3:case 4:var s=pi;pi=Ol(t.stateNode.containerInfo),kr(t,n,a),pi=s;break;case 22:t.memoizedState===null&&(s=t.alternate,s!==null&&s.memoizedState!==null?(s=io,io=16777216,kr(t,n,a),io=s):kr(t,n,a));break;default:kr(t,n,a)}}function Zm(t){var n=t.alternate;if(n!==null&&(t=n.child,t!==null)){n.child=null;do n=t.sibling,t.sibling=null,t=n;while(t!==null)}}function ao(t){var n=t.deletions;if((t.flags&16)!==0){if(n!==null)for(var a=0;a<n.length;a++){var s=n[a];hn=s,Qm(s,t)}Zm(t)}if(t.subtreeFlags&10256)for(t=t.child;t!==null;)Km(t),t=t.sibling}function Km(t){switch(t.tag){case 0:case 11:case 15:ao(t),t.flags&2048&&Sa(9,t,t.return);break;case 3:ao(t);break;case 12:ao(t);break;case 22:var n=t.stateNode;t.memoizedState!==null&&n._visibility&2&&(t.return===null||t.return.tag!==13)?(n._visibility&=-3,Ml(t)):ao(t);break;default:ao(t)}}function Ml(t){var n=t.deletions;if((t.flags&16)!==0){if(n!==null)for(var a=0;a<n.length;a++){var s=n[a];hn=s,Qm(s,t)}Zm(t)}for(t=t.child;t!==null;){switch(n=t,n.tag){case 0:case 11:case 15:Sa(8,n,n.return),Ml(n);break;case 22:a=n.stateNode,a._visibility&2&&(a._visibility&=-3,Ml(n));break;default:Ml(n)}t=t.sibling}}function Qm(t,n){for(;hn!==null;){var a=hn;switch(a.tag){case 0:case 11:case 15:Sa(8,a,n);break;case 23:case 22:if(a.memoizedState!==null&&a.memoizedState.cachePool!==null){var s=a.memoizedState.cachePool.pool;s!=null&&s.refCount++}break;case 24:Gs(a.memoizedState.cache)}if(s=a.child,s!==null)s.return=a,hn=s;else t:for(a=t;hn!==null;){s=hn;var u=s.sibling,f=s.return;if(Gm(s),s===a){hn=null;break t}if(u!==null){u.return=f,hn=u;break t}hn=f}}}var oS={getCacheForType:function(t){var n=vn(tn),a=n.data.get(t);return a===void 0&&(a=t(),n.data.set(t,a)),a},cacheSignal:function(){return vn(tn).controller.signal}},lS=typeof WeakMap=="function"?WeakMap:Map,Ce=0,He=null,fe=null,pe=0,De=0,Yn=null,xa=!1,Wr=!1,tf=!1,Zi=0,Qe=0,Ma=0,or=0,ef=0,jn=0,qr=0,ro=null,In=null,nf=!1,yl=0,Jm=0,El=1/0,Tl=null,ya=null,ln=0,Ea=null,Yr=null,Ki=0,af=0,rf=null,$m=null,so=0,sf=null;function Zn(){return(Ce&2)!==0&&pe!==0?pe&-pe:P.T!==null?hf():Rs()}function tg(){if(jn===0)if((pe&536870912)===0||ve){var t=lt;lt<<=1,(lt&3932160)===0&&(lt=262144),jn=t}else jn=536870912;return t=Wn.current,t!==null&&(t.flags|=32),jn}function Fn(t,n,a){(t===He&&(De===2||De===9)||t.cancelPendingCommit!==null)&&(jr(t,0),Ta(t,pe,jn,!1)),pn(t,a),((Ce&2)===0||t!==He)&&(t===He&&((Ce&2)===0&&(or|=a),Qe===4&&Ta(t,pe,jn,!1)),Ri(t))}function eg(t,n,a){if((Ce&6)!==0)throw Error(r(327));var s=!a&&(n&127)===0&&(n&t.expiredLanes)===0||te(t,n),u=s?fS(t,n):lf(t,n,!0),f=s;do{if(u===0){Wr&&!s&&Ta(t,n,0,!1);break}else{if(a=t.current.alternate,f&&!uS(a)){u=lf(t,n,!1),f=!1;continue}if(u===2){if(f=n,t.errorRecoveryDisabledLanes&f)var g=0;else g=t.pendingLanes&-536870913,g=g!==0?g:g&536870912?536870912:0;if(g!==0){n=g;t:{var E=t;u=ro;var F=E.current.memoizedState.isDehydrated;if(F&&(jr(E,g).flags|=256),g=lf(E,g,!1),g!==2){if(tf&&!F){E.errorRecoveryDisabledLanes|=f,or|=f,u=4;break t}f=In,In=u,f!==null&&(In===null?In=f:In.push.apply(In,f))}u=g}if(f=!1,u!==2)continue}}if(u===1){jr(t,0),Ta(t,n,0,!0);break}t:{switch(s=t,f=u,f){case 0:case 1:throw Error(r(345));case 4:if((n&4194048)!==n)break;case 6:Ta(s,n,jn,!xa);break t;case 2:In=null;break;case 3:case 5:break;default:throw Error(r(329))}if((n&62914560)===n&&(u=yl+300-ct(),10<u)){if(Ta(s,n,jn,!xa),wt(s,0,!0)!==0)break t;Ki=n,s.timeoutHandle=Lg(ng.bind(null,s,a,In,Tl,nf,n,jn,or,qr,xa,f,"Throttled",-0,0),u);break t}ng(s,a,In,Tl,nf,n,jn,or,qr,xa,f,null,-0,0)}}break}while(!0);Ri(t)}function ng(t,n,a,s,u,f,g,E,F,$,ut,gt,tt,ot){if(t.timeoutHandle=-1,gt=n.subtreeFlags,gt&8192||(gt&16785408)===16785408){gt={stylesheets:null,count:0,imgCount:0,imgBytes:0,suspenseyImages:[],waitingForImages:!0,waitingForViewTransition:!1,unsuspend:zi},jm(n,f,gt);var Bt=(f&62914560)===f?yl-ct():(f&4194048)===f?Jm-ct():0;if(Bt=YS(gt,Bt),Bt!==null){Ki=f,t.cancelPendingCommit=Bt(cg.bind(null,t,n,f,a,s,u,g,E,F,ut,gt,null,tt,ot)),Ta(t,f,g,!$);return}}cg(t,n,f,a,s,u,g,E,F)}function uS(t){for(var n=t;;){var a=n.tag;if((a===0||a===11||a===15)&&n.flags&16384&&(a=n.updateQueue,a!==null&&(a=a.stores,a!==null)))for(var s=0;s<a.length;s++){var u=a[s],f=u.getSnapshot;u=u.value;try{if(!Xn(f(),u))return!1}catch{return!1}}if(a=n.child,n.subtreeFlags&16384&&a!==null)a.return=n,n=a;else{if(n===t)break;for(;n.sibling===null;){if(n.return===null||n.return===t)return!0;n=n.return}n.sibling.return=n.return,n=n.sibling}}return!0}function Ta(t,n,a,s){n&=~ef,n&=~or,t.suspendedLanes|=n,t.pingedLanes&=~n,s&&(t.warmLanes|=n),s=t.expirationTimes;for(var u=n;0<u;){var f=31-$t(u),g=1<<f;s[f]=-1,u&=~g}a!==0&&bs(t,a,n)}function bl(){return(Ce&6)===0?(oo(0),!1):!0}function of(){if(fe!==null){if(De===0)var t=fe.return;else t=fe,Fi=Ja=null,yc(t),Ir=null,Xs=0,t=fe;for(;t!==null;)Nm(t.alternate,t),t=t.return;fe=null}}function jr(t,n){var a=t.timeoutHandle;a!==-1&&(t.timeoutHandle=-1,wS(a)),a=t.cancelPendingCommit,a!==null&&(t.cancelPendingCommit=null,a()),Ki=0,of(),He=t,fe=a=Bi(t.current,null),pe=n,De=0,Yn=null,xa=!1,Wr=te(t,n),tf=!1,qr=jn=ef=or=Ma=Qe=0,In=ro=null,nf=!1,(n&8)!==0&&(n|=n&32);var s=t.entangledLanes;if(s!==0)for(t=t.entanglements,s&=n;0<s;){var u=31-$t(s),f=1<<u;n|=t[u],s&=~f}return Zi=n,qo(),a}function ig(t,n){re=null,P.H=Qs,n===Br||n===tl?(n=Sp(),De=3):n===cc?(n=Sp(),De=4):De=n===Ic?8:n!==null&&typeof n=="object"&&typeof n.then=="function"?6:1,Yn=n,fe===null&&(Qe=1,pl(t,ti(n,t.current)))}function ag(){var t=Wn.current;return t===null?!0:(pe&4194048)===pe?ai===null:(pe&62914560)===pe||(pe&536870912)!==0?t===ai:!1}function rg(){var t=P.H;return P.H=Qs,t===null?Qs:t}function sg(){var t=P.A;return P.A=oS,t}function Al(){Qe=4,xa||(pe&4194048)!==pe&&Wn.current!==null||(Wr=!0),(Ma&134217727)===0&&(or&134217727)===0||He===null||Ta(He,pe,jn,!1)}function lf(t,n,a){var s=Ce;Ce|=2;var u=rg(),f=sg();(He!==t||pe!==n)&&(Tl=null,jr(t,n)),n=!1;var g=Qe;t:do try{if(De!==0&&fe!==null){var E=fe,F=Yn;switch(De){case 8:of(),g=6;break t;case 3:case 2:case 9:case 6:Wn.current===null&&(n=!0);var $=De;if(De=0,Yn=null,Zr(t,E,F,$),a&&Wr){g=0;break t}break;default:$=De,De=0,Yn=null,Zr(t,E,F,$)}}cS(),g=Qe;break}catch(ut){ig(t,ut)}while(!0);return n&&t.shellSuspendCounter++,Fi=Ja=null,Ce=s,P.H=u,P.A=f,fe===null&&(He=null,pe=0,qo()),g}function cS(){for(;fe!==null;)og(fe)}function fS(t,n){var a=Ce;Ce|=2;var s=rg(),u=sg();He!==t||pe!==n?(Tl=null,El=ct()+500,jr(t,n)):Wr=te(t,n);t:do try{if(De!==0&&fe!==null){n=fe;var f=Yn;e:switch(De){case 1:De=0,Yn=null,Zr(t,n,f,1);break;case 2:case 9:if(_p(f)){De=0,Yn=null,lg(n);break}n=function(){De!==2&&De!==9||He!==t||(De=7),Ri(t)},f.then(n,n);break t;case 3:De=7;break t;case 4:De=5;break t;case 7:_p(f)?(De=0,Yn=null,lg(n)):(De=0,Yn=null,Zr(t,n,f,7));break;case 5:var g=null;switch(fe.tag){case 26:g=fe.memoizedState;case 5:case 27:var E=fe;if(g?Yg(g):E.stateNode.complete){De=0,Yn=null;var F=E.sibling;if(F!==null)fe=F;else{var $=E.return;$!==null?(fe=$,Rl($)):fe=null}break e}}De=0,Yn=null,Zr(t,n,f,5);break;case 6:De=0,Yn=null,Zr(t,n,f,6);break;case 8:of(),Qe=6;break t;default:throw Error(r(462))}}hS();break}catch(ut){ig(t,ut)}while(!0);return Fi=Ja=null,P.H=s,P.A=u,Ce=a,fe!==null?0:(He=null,pe=0,qo(),Qe)}function hS(){for(;fe!==null&&!T();)og(fe)}function og(t){var n=Um(t.alternate,t,Zi);t.memoizedProps=t.pendingProps,n===null?Rl(t):fe=n}function lg(t){var n=t,a=n.alternate;switch(n.tag){case 15:case 0:n=bm(a,n,n.pendingProps,n.type,void 0,pe);break;case 11:n=bm(a,n,n.pendingProps,n.type.render,n.ref,pe);break;case 5:yc(n);default:Nm(a,n),n=fe=sp(n,Zi),n=Um(a,n,Zi)}t.memoizedProps=t.pendingProps,n===null?Rl(t):fe=n}function Zr(t,n,a,s){Fi=Ja=null,yc(n),Ir=null,Xs=0;var u=n.return;try{if(tS(t,u,n,a,pe)){Qe=1,pl(t,ti(a,t.current)),fe=null;return}}catch(f){if(u!==null)throw fe=u,f;Qe=1,pl(t,ti(a,t.current)),fe=null;return}n.flags&32768?(ve||s===1?t=!0:Wr||(pe&536870912)!==0?t=!1:(xa=t=!0,(s===2||s===9||s===3||s===6)&&(s=Wn.current,s!==null&&s.tag===13&&(s.flags|=16384))),ug(n,t)):Rl(n)}function Rl(t){var n=t;do{if((n.flags&32768)!==0){ug(n,xa);return}t=n.return;var a=iS(n.alternate,n,Zi);if(a!==null){fe=a;return}if(n=n.sibling,n!==null){fe=n;return}fe=n=t}while(n!==null);Qe===0&&(Qe=5)}function ug(t,n){do{var a=aS(t.alternate,t);if(a!==null){a.flags&=32767,fe=a;return}if(a=t.return,a!==null&&(a.flags|=32768,a.subtreeFlags=0,a.deletions=null),!n&&(t=t.sibling,t!==null)){fe=t;return}fe=t=a}while(t!==null);Qe=6,fe=null}function cg(t,n,a,s,u,f,g,E,F){t.cancelPendingCommit=null;do Cl();while(ln!==0);if((Ce&6)!==0)throw Error(r(327));if(n!==null){if(n===t.current)throw Error(r(177));if(f=n.lanes|n.childLanes,f|=Zu,ci(t,a,f,g,E,F),t===He&&(fe=He=null,pe=0),Yr=n,Ea=t,Ki=a,af=f,rf=u,$m=s,(n.subtreeFlags&10256)!==0||(n.flags&10256)!==0?(t.callbackNode=null,t.callbackPriority=0,gS(Rt,function(){return mg(),null})):(t.callbackNode=null,t.callbackPriority=0),s=(n.flags&13878)!==0,(n.subtreeFlags&13878)!==0||s){s=P.T,P.T=null,u=Y.p,Y.p=2,g=Ce,Ce|=4;try{rS(t,n,a)}finally{Ce=g,Y.p=u,P.T=s}}ln=1,fg(),hg(),dg()}}function fg(){if(ln===1){ln=0;var t=Ea,n=Yr,a=(n.flags&13878)!==0;if((n.subtreeFlags&13878)!==0||a){a=P.T,P.T=null;var s=Y.p;Y.p=2;var u=Ce;Ce|=4;try{Wm(n,t);var f=xf,g=Qd(t.containerInfo),E=f.focusedElem,F=f.selectionRange;if(g!==E&&E&&E.ownerDocument&&Kd(E.ownerDocument.documentElement,E)){if(F!==null&&ku(E)){var $=F.start,ut=F.end;if(ut===void 0&&(ut=$),"selectionStart"in E)E.selectionStart=$,E.selectionEnd=Math.min(ut,E.value.length);else{var gt=E.ownerDocument||document,tt=gt&&gt.defaultView||window;if(tt.getSelection){var ot=tt.getSelection(),Bt=E.textContent.length,Kt=Math.min(F.start,Bt),Pe=F.end===void 0?Kt:Math.min(F.end,Bt);!ot.extend&&Kt>Pe&&(g=Pe,Pe=Kt,Kt=g);var Z=Zd(E,Kt),X=Zd(E,Pe);if(Z&&X&&(ot.rangeCount!==1||ot.anchorNode!==Z.node||ot.anchorOffset!==Z.offset||ot.focusNode!==X.node||ot.focusOffset!==X.offset)){var J=gt.createRange();J.setStart(Z.node,Z.offset),ot.removeAllRanges(),Kt>Pe?(ot.addRange(J),ot.extend(X.node,X.offset)):(J.setEnd(X.node,X.offset),ot.addRange(J))}}}}for(gt=[],ot=E;ot=ot.parentNode;)ot.nodeType===1&&gt.push({element:ot,left:ot.scrollLeft,top:ot.scrollTop});for(typeof E.focus=="function"&&E.focus(),E=0;E<gt.length;E++){var ht=gt[E];ht.element.scrollLeft=ht.left,ht.element.scrollTop=ht.top}}Hl=!!Sf,xf=Sf=null}finally{Ce=u,Y.p=s,P.T=a}}t.current=n,ln=2}}function hg(){if(ln===2){ln=0;var t=Ea,n=Yr,a=(n.flags&8772)!==0;if((n.subtreeFlags&8772)!==0||a){a=P.T,P.T=null;var s=Y.p;Y.p=2;var u=Ce;Ce|=4;try{Hm(t,n.alternate,n)}finally{Ce=u,Y.p=s,P.T=a}}ln=3}}function dg(){if(ln===4||ln===3){ln=0,et();var t=Ea,n=Yr,a=Ki,s=$m;(n.subtreeFlags&10256)!==0||(n.flags&10256)!==0?ln=5:(ln=0,Yr=Ea=null,pg(t,t.pendingLanes));var u=t.pendingLanes;if(u===0&&(ya=null),yr(a),n=n.stateNode,Ht&&typeof Ht.onCommitFiberRoot=="function")try{Ht.onCommitFiberRoot(Yt,n,void 0,(n.current.flags&128)===128)}catch{}if(s!==null){n=P.T,u=Y.p,Y.p=2,P.T=null;try{for(var f=t.onRecoverableError,g=0;g<s.length;g++){var E=s[g];f(E.value,{componentStack:E.stack})}}finally{P.T=n,Y.p=u}}(Ki&3)!==0&&Cl(),Ri(t),u=t.pendingLanes,(a&261930)!==0&&(u&42)!==0?t===sf?so++:(so=0,sf=t):so=0,oo(0)}}function pg(t,n){(t.pooledCacheLanes&=n)===0&&(n=t.pooledCache,n!=null&&(t.pooledCache=null,Gs(n)))}function Cl(){return fg(),hg(),dg(),mg()}function mg(){if(ln!==5)return!1;var t=Ea,n=af;af=0;var a=yr(Ki),s=P.T,u=Y.p;try{Y.p=32>a?32:a,P.T=null,a=rf,rf=null;var f=Ea,g=Ki;if(ln=0,Yr=Ea=null,Ki=0,(Ce&6)!==0)throw Error(r(331));var E=Ce;if(Ce|=4,Km(f.current),Ym(f,f.current,g,a),Ce=E,oo(0,!1),Ht&&typeof Ht.onPostCommitFiberRoot=="function")try{Ht.onPostCommitFiberRoot(Yt,f)}catch{}return!0}finally{Y.p=u,P.T=s,pg(t,n)}}function gg(t,n,a){n=ti(a,n),n=Bc(t.stateNode,n,2),t=ga(t,n,2),t!==null&&(pn(t,2),Ri(t))}function Ue(t,n,a){if(t.tag===3)gg(t,t,a);else for(;n!==null;){if(n.tag===3){gg(n,t,a);break}else if(n.tag===1){var s=n.stateNode;if(typeof n.type.getDerivedStateFromError=="function"||typeof s.componentDidCatch=="function"&&(ya===null||!ya.has(s))){t=ti(a,t),a=_m(2),s=ga(n,a,2),s!==null&&(vm(a,s,n,t),pn(s,2),Ri(s));break}}n=n.return}}function uf(t,n,a){var s=t.pingCache;if(s===null){s=t.pingCache=new lS;var u=new Set;s.set(n,u)}else u=s.get(n),u===void 0&&(u=new Set,s.set(n,u));u.has(a)||(tf=!0,u.add(a),t=dS.bind(null,t,n,a),n.then(t,t))}function dS(t,n,a){var s=t.pingCache;s!==null&&s.delete(n),t.pingedLanes|=t.suspendedLanes&a,t.warmLanes&=~a,He===t&&(pe&a)===a&&(Qe===4||Qe===3&&(pe&62914560)===pe&&300>ct()-yl?(Ce&2)===0&&jr(t,0):ef|=a,qr===pe&&(qr=0)),Ri(t)}function _g(t,n){n===0&&(n=sn()),t=Za(t,n),t!==null&&(pn(t,n),Ri(t))}function pS(t){var n=t.memoizedState,a=0;n!==null&&(a=n.retryLane),_g(t,a)}function mS(t,n){var a=0;switch(t.tag){case 31:case 13:var s=t.stateNode,u=t.memoizedState;u!==null&&(a=u.retryLane);break;case 19:s=t.stateNode;break;case 22:s=t.stateNode._retryCache;break;default:throw Error(r(314))}s!==null&&s.delete(n),_g(t,a)}function gS(t,n){return Gt(t,n)}var wl=null,Kr=null,cf=!1,Dl=!1,ff=!1,ba=0;function Ri(t){t!==Kr&&t.next===null&&(Kr===null?wl=Kr=t:Kr=Kr.next=t),Dl=!0,cf||(cf=!0,vS())}function oo(t,n){if(!ff&&Dl){ff=!0;do for(var a=!1,s=wl;s!==null;){if(t!==0){var u=s.pendingLanes;if(u===0)var f=0;else{var g=s.suspendedLanes,E=s.pingedLanes;f=(1<<31-$t(42|t)+1)-1,f&=u&~(g&~E),f=f&201326741?f&201326741|1:f?f|2:0}f!==0&&(a=!0,Mg(s,f))}else f=pe,f=wt(s,s===He?f:0,s.cancelPendingCommit!==null||s.timeoutHandle!==-1),(f&3)===0||te(s,f)||(a=!0,Mg(s,f));s=s.next}while(a);ff=!1}}function _S(){vg()}function vg(){Dl=cf=!1;var t=0;ba!==0&&CS()&&(t=ba);for(var n=ct(),a=null,s=wl;s!==null;){var u=s.next,f=Sg(s,n);f===0?(s.next=null,a===null?wl=u:a.next=u,u===null&&(Kr=a)):(a=s,(t!==0||(f&3)!==0)&&(Dl=!0)),s=u}ln!==0&&ln!==5||oo(t),ba!==0&&(ba=0)}function Sg(t,n){for(var a=t.suspendedLanes,s=t.pingedLanes,u=t.expirationTimes,f=t.pendingLanes&-62914561;0<f;){var g=31-$t(f),E=1<<g,F=u[g];F===-1?((E&a)===0||(E&s)!==0)&&(u[g]=We(E,n)):F<=n&&(t.expiredLanes|=E),f&=~E}if(n=He,a=pe,a=wt(t,t===n?a:0,t.cancelPendingCommit!==null||t.timeoutHandle!==-1),s=t.callbackNode,a===0||t===n&&(De===2||De===9)||t.cancelPendingCommit!==null)return s!==null&&s!==null&&N(s),t.callbackNode=null,t.callbackPriority=0;if((a&3)===0||te(t,a)){if(n=a&-a,n===t.callbackPriority)return n;switch(s!==null&&N(s),yr(a)){case 2:case 8:a=Ft;break;case 32:a=Rt;break;case 268435456:a=Qt;break;default:a=Rt}return s=xg.bind(null,t),a=Gt(a,s),t.callbackPriority=n,t.callbackNode=a,n}return s!==null&&s!==null&&N(s),t.callbackPriority=2,t.callbackNode=null,2}function xg(t,n){if(ln!==0&&ln!==5)return t.callbackNode=null,t.callbackPriority=0,null;var a=t.callbackNode;if(Cl()&&t.callbackNode!==a)return null;var s=pe;return s=wt(t,t===He?s:0,t.cancelPendingCommit!==null||t.timeoutHandle!==-1),s===0?null:(eg(t,s,n),Sg(t,ct()),t.callbackNode!=null&&t.callbackNode===a?xg.bind(null,t):null)}function Mg(t,n){if(Cl())return null;eg(t,n,!0)}function vS(){DS(function(){(Ce&6)!==0?Gt(mt,_S):vg()})}function hf(){if(ba===0){var t=zr;t===0&&(t=Ct,Ct<<=1,(Ct&261888)===0&&(Ct=256)),ba=t}return ba}function yg(t){return t==null||typeof t=="symbol"||typeof t=="boolean"?null:typeof t=="function"?t:Io(""+t)}function Eg(t,n){var a=n.ownerDocument.createElement("input");return a.name=n.name,a.value=n.value,t.id&&a.setAttribute("form",t.id),n.parentNode.insertBefore(a,n),t=new FormData(t),a.parentNode.removeChild(a),t}function SS(t,n,a,s,u){if(n==="submit"&&a&&a.stateNode===u){var f=yg((u[mn]||null).action),g=s.submitter;g&&(n=(n=g[mn]||null)?yg(n.formAction):g.getAttribute("formAction"),n!==null&&(f=n,g=null));var E=new Vo("action","action",null,s,u);t.push({event:E,listeners:[{instance:null,listener:function(){if(s.defaultPrevented){if(ba!==0){var F=g?Eg(u,g):new FormData(u);Uc(a,{pending:!0,data:F,method:u.method,action:f},null,F)}}else typeof f=="function"&&(E.preventDefault(),F=g?Eg(u,g):new FormData(u),Uc(a,{pending:!0,data:F,method:u.method,action:f},f,F))},currentTarget:u}]})}}for(var df=0;df<ju.length;df++){var pf=ju[df],xS=pf.toLowerCase(),MS=pf[0].toUpperCase()+pf.slice(1);di(xS,"on"+MS)}di(tp,"onAnimationEnd"),di(ep,"onAnimationIteration"),di(np,"onAnimationStart"),di("dblclick","onDoubleClick"),di("focusin","onFocus"),di("focusout","onBlur"),di(Bv,"onTransitionRun"),di(Iv,"onTransitionStart"),di(Fv,"onTransitionCancel"),di(ip,"onTransitionEnd"),Ot("onMouseEnter",["mouseout","mouseover"]),Ot("onMouseLeave",["mouseout","mouseover"]),Ot("onPointerEnter",["pointerout","pointerover"]),Ot("onPointerLeave",["pointerout","pointerover"]),Lt("onChange","change click focusin focusout input keydown keyup selectionchange".split(" ")),Lt("onSelect","focusout contextmenu dragend focusin keydown keyup mousedown mouseup selectionchange".split(" ")),Lt("onBeforeInput",["compositionend","keypress","textInput","paste"]),Lt("onCompositionEnd","compositionend focusout keydown keypress keyup mousedown".split(" ")),Lt("onCompositionStart","compositionstart focusout keydown keypress keyup mousedown".split(" ")),Lt("onCompositionUpdate","compositionupdate focusout keydown keypress keyup mousedown".split(" "));var lo="abort canplay canplaythrough durationchange emptied encrypted ended error loadeddata loadedmetadata loadstart pause play playing progress ratechange resize seeked seeking stalled suspend timeupdate volumechange waiting".split(" "),yS=new Set("beforetoggle cancel close invalid load scroll scrollend toggle".split(" ").concat(lo));function Tg(t,n){n=(n&4)!==0;for(var a=0;a<t.length;a++){var s=t[a],u=s.event;s=s.listeners;t:{var f=void 0;if(n)for(var g=s.length-1;0<=g;g--){var E=s[g],F=E.instance,$=E.currentTarget;if(E=E.listener,F!==f&&u.isPropagationStopped())break t;f=E,u.currentTarget=$;try{f(u)}catch(ut){Wo(ut)}u.currentTarget=null,f=F}else for(g=0;g<s.length;g++){if(E=s[g],F=E.instance,$=E.currentTarget,E=E.listener,F!==f&&u.isPropagationStopped())break t;f=E,u.currentTarget=$;try{f(u)}catch(ut){Wo(ut)}u.currentTarget=null,f=F}}}}function he(t,n){var a=n[Cs];a===void 0&&(a=n[Cs]=new Set);var s=t+"__bubble";a.has(s)||(bg(n,t,2,!1),a.add(s))}function mf(t,n,a){var s=0;n&&(s|=4),bg(a,t,s,n)}var Ul="_reactListening"+Math.random().toString(36).slice(2);function gf(t){if(!t[Ul]){t[Ul]=!0,Et.forEach(function(a){a!=="selectionchange"&&(yS.has(a)||mf(a,!1,t),mf(a,!0,t))});var n=t.nodeType===9?t:t.ownerDocument;n===null||n[Ul]||(n[Ul]=!0,mf("selectionchange",!1,n))}}function bg(t,n,a,s){switch(t_(n)){case 2:var u=KS;break;case 8:u=QS;break;default:u=Uf}a=u.bind(null,n,a,t),u=void 0,!zu||n!=="touchstart"&&n!=="touchmove"&&n!=="wheel"||(u=!0),s?u!==void 0?t.addEventListener(n,a,{capture:!0,passive:u}):t.addEventListener(n,a,!0):u!==void 0?t.addEventListener(n,a,{passive:u}):t.addEventListener(n,a,!1)}function _f(t,n,a,s,u){var f=s;if((n&1)===0&&(n&2)===0&&s!==null)t:for(;;){if(s===null)return;var g=s.tag;if(g===3||g===4){var E=s.stateNode.containerInfo;if(E===u)break;if(g===4)for(g=s.return;g!==null;){var F=g.tag;if((F===3||F===4)&&g.stateNode.containerInfo===u)return;g=g.return}for(;E!==null;){if(g=A(E),g===null)return;if(F=g.tag,F===5||F===6||F===26||F===27){s=f=g;continue t}E=E.parentNode}}s=s.return}Dd(function(){var $=f,ut=Nu(a),gt=[];t:{var tt=ap.get(t);if(tt!==void 0){var ot=Vo,Bt=t;switch(t){case"keypress":if(Ho(a)===0)break t;case"keydown":case"keyup":ot=mv;break;case"focusin":Bt="focus",ot=Fu;break;case"focusout":Bt="blur",ot=Fu;break;case"beforeblur":case"afterblur":ot=Fu;break;case"click":if(a.button===2)break t;case"auxclick":case"dblclick":case"mousedown":case"mousemove":case"mouseup":case"mouseout":case"mouseover":case"contextmenu":ot=Nd;break;case"drag":case"dragend":case"dragenter":case"dragexit":case"dragleave":case"dragover":case"dragstart":case"drop":ot=iv;break;case"touchcancel":case"touchend":case"touchmove":case"touchstart":ot=vv;break;case tp:case ep:case np:ot=sv;break;case ip:ot=xv;break;case"scroll":case"scrollend":ot=ev;break;case"wheel":ot=yv;break;case"copy":case"cut":case"paste":ot=lv;break;case"gotpointercapture":case"lostpointercapture":case"pointercancel":case"pointerdown":case"pointermove":case"pointerout":case"pointerover":case"pointerup":ot=zd;break;case"toggle":case"beforetoggle":ot=Tv}var Kt=(n&4)!==0,Pe=!Kt&&(t==="scroll"||t==="scrollend"),Z=Kt?tt!==null?tt+"Capture":null:tt;Kt=[];for(var X=$,J;X!==null;){var ht=X;if(J=ht.stateNode,ht=ht.tag,ht!==5&&ht!==26&&ht!==27||J===null||Z===null||(ht=Ds(X,Z),ht!=null&&Kt.push(uo(X,ht,J))),Pe)break;X=X.return}0<Kt.length&&(tt=new ot(tt,Bt,null,a,ut),gt.push({event:tt,listeners:Kt}))}}if((n&7)===0){t:{if(tt=t==="mouseover"||t==="pointerover",ot=t==="mouseout"||t==="pointerout",tt&&a!==Lu&&(Bt=a.relatedTarget||a.fromElement)&&(A(Bt)||Bt[Oi]))break t;if((ot||tt)&&(tt=ut.window===ut?ut:(tt=ut.ownerDocument)?tt.defaultView||tt.parentWindow:window,ot?(Bt=a.relatedTarget||a.toElement,ot=$,Bt=Bt?A(Bt):null,Bt!==null&&(Pe=c(Bt),Kt=Bt.tag,Bt!==Pe||Kt!==5&&Kt!==27&&Kt!==6)&&(Bt=null)):(ot=null,Bt=$),ot!==Bt)){if(Kt=Nd,ht="onMouseLeave",Z="onMouseEnter",X="mouse",(t==="pointerout"||t==="pointerover")&&(Kt=zd,ht="onPointerLeave",Z="onPointerEnter",X="pointer"),Pe=ot==null?tt:it(ot),J=Bt==null?tt:it(Bt),tt=new Kt(ht,X+"leave",ot,a,ut),tt.target=Pe,tt.relatedTarget=J,ht=null,A(ut)===$&&(Kt=new Kt(Z,X+"enter",Bt,a,ut),Kt.target=J,Kt.relatedTarget=Pe,ht=Kt),Pe=ht,ot&&Bt)e:{for(Kt=ES,Z=ot,X=Bt,J=0,ht=Z;ht;ht=Kt(ht))J++;ht=0;for(var kt=X;kt;kt=Kt(kt))ht++;for(;0<J-ht;)Z=Kt(Z),J--;for(;0<ht-J;)X=Kt(X),ht--;for(;J--;){if(Z===X||X!==null&&Z===X.alternate){Kt=Z;break e}Z=Kt(Z),X=Kt(X)}Kt=null}else Kt=null;ot!==null&&Ag(gt,tt,ot,Kt,!1),Bt!==null&&Pe!==null&&Ag(gt,Pe,Bt,Kt,!0)}}t:{if(tt=$?it($):window,ot=tt.nodeName&&tt.nodeName.toLowerCase(),ot==="select"||ot==="input"&&tt.type==="file")var be=Xd;else if(Gd(tt))if(kd)be=Ov;else{be=Lv;var It=Uv}else ot=tt.nodeName,!ot||ot.toLowerCase()!=="input"||tt.type!=="checkbox"&&tt.type!=="radio"?$&&Uu($.elementType)&&(be=Xd):be=Nv;if(be&&(be=be(t,$))){Vd(gt,be,a,ut);break t}It&&It(t,tt,$),t==="focusout"&&$&&tt.type==="number"&&$.memoizedProps.value!=null&&yn(tt,"number",tt.value)}switch(It=$?it($):window,t){case"focusin":(Gd(It)||It.contentEditable==="true")&&(Rr=It,Wu=$,Is=null);break;case"focusout":Is=Wu=Rr=null;break;case"mousedown":qu=!0;break;case"contextmenu":case"mouseup":case"dragend":qu=!1,Jd(gt,a,ut);break;case"selectionchange":if(Pv)break;case"keydown":case"keyup":Jd(gt,a,ut)}var se;if(Gu)t:{switch(t){case"compositionstart":var me="onCompositionStart";break t;case"compositionend":me="onCompositionEnd";break t;case"compositionupdate":me="onCompositionUpdate";break t}me=void 0}else Ar?Fd(t,a)&&(me="onCompositionEnd"):t==="keydown"&&a.keyCode===229&&(me="onCompositionStart");me&&(Pd&&a.locale!=="ko"&&(Ar||me!=="onCompositionStart"?me==="onCompositionEnd"&&Ar&&(se=Ud()):(ua=ut,Pu="value"in ua?ua.value:ua.textContent,Ar=!0)),It=Ll($,me),0<It.length&&(me=new Od(me,t,null,a,ut),gt.push({event:me,listeners:It}),se?me.data=se:(se=Hd(a),se!==null&&(me.data=se)))),(se=Av?Rv(t,a):Cv(t,a))&&(me=Ll($,"onBeforeInput"),0<me.length&&(It=new Od("onBeforeInput","beforeinput",null,a,ut),gt.push({event:It,listeners:me}),It.data=se)),SS(gt,t,$,a,ut)}Tg(gt,n)})}function uo(t,n,a){return{instance:t,listener:n,currentTarget:a}}function Ll(t,n){for(var a=n+"Capture",s=[];t!==null;){var u=t,f=u.stateNode;if(u=u.tag,u!==5&&u!==26&&u!==27||f===null||(u=Ds(t,a),u!=null&&s.unshift(uo(t,u,f)),u=Ds(t,n),u!=null&&s.push(uo(t,u,f))),t.tag===3)return s;t=t.return}return[]}function ES(t){if(t===null)return null;do t=t.return;while(t&&t.tag!==5&&t.tag!==27);return t||null}function Ag(t,n,a,s,u){for(var f=n._reactName,g=[];a!==null&&a!==s;){var E=a,F=E.alternate,$=E.stateNode;if(E=E.tag,F!==null&&F===s)break;E!==5&&E!==26&&E!==27||$===null||(F=$,u?($=Ds(a,f),$!=null&&g.unshift(uo(a,$,F))):u||($=Ds(a,f),$!=null&&g.push(uo(a,$,F)))),a=a.return}g.length!==0&&t.push({event:n,listeners:g})}var TS=/\r\n?/g,bS=/\u0000|\uFFFD/g;function Rg(t){return(typeof t=="string"?t:""+t).replace(TS,`
`).replace(bS,"")}function Cg(t,n){return n=Rg(n),Rg(t)===n}function ze(t,n,a,s,u,f){switch(a){case"children":typeof s=="string"?n==="body"||n==="textarea"&&s===""||Nn(t,s):(typeof s=="number"||typeof s=="bigint")&&n!=="body"&&Nn(t,""+s);break;case"className":Ve(t,"class",s);break;case"tabIndex":Ve(t,"tabindex",s);break;case"dir":case"role":case"viewBox":case"width":case"height":Ve(t,a,s);break;case"style":Cd(t,s,f);break;case"data":if(n!=="object"){Ve(t,"data",s);break}case"src":case"href":if(s===""&&(n!=="a"||a!=="href")){t.removeAttribute(a);break}if(s==null||typeof s=="function"||typeof s=="symbol"||typeof s=="boolean"){t.removeAttribute(a);break}s=Io(""+s),t.setAttribute(a,s);break;case"action":case"formAction":if(typeof s=="function"){t.setAttribute(a,"javascript:throw new Error('A React form was unexpectedly submitted. If you called form.submit() manually, consider using form.requestSubmit() instead. If you\\'re trying to use event.stopPropagation() in a submit event handler, consider also calling event.preventDefault().')");break}else typeof f=="function"&&(a==="formAction"?(n!=="input"&&ze(t,n,"name",u.name,u,null),ze(t,n,"formEncType",u.formEncType,u,null),ze(t,n,"formMethod",u.formMethod,u,null),ze(t,n,"formTarget",u.formTarget,u,null)):(ze(t,n,"encType",u.encType,u,null),ze(t,n,"method",u.method,u,null),ze(t,n,"target",u.target,u,null)));if(s==null||typeof s=="symbol"||typeof s=="boolean"){t.removeAttribute(a);break}s=Io(""+s),t.setAttribute(a,s);break;case"onClick":s!=null&&(t.onclick=zi);break;case"onScroll":s!=null&&he("scroll",t);break;case"onScrollEnd":s!=null&&he("scrollend",t);break;case"dangerouslySetInnerHTML":if(s!=null){if(typeof s!="object"||!("__html"in s))throw Error(r(61));if(a=s.__html,a!=null){if(u.children!=null)throw Error(r(60));t.innerHTML=a}}break;case"multiple":t.multiple=s&&typeof s!="function"&&typeof s!="symbol";break;case"muted":t.muted=s&&typeof s!="function"&&typeof s!="symbol";break;case"suppressContentEditableWarning":case"suppressHydrationWarning":case"defaultValue":case"defaultChecked":case"innerHTML":case"ref":break;case"autoFocus":break;case"xlinkHref":if(s==null||typeof s=="function"||typeof s=="boolean"||typeof s=="symbol"){t.removeAttribute("xlink:href");break}a=Io(""+s),t.setAttributeNS("http://www.w3.org/1999/xlink","xlink:href",a);break;case"contentEditable":case"spellCheck":case"draggable":case"value":case"autoReverse":case"externalResourcesRequired":case"focusable":case"preserveAlpha":s!=null&&typeof s!="function"&&typeof s!="symbol"?t.setAttribute(a,""+s):t.removeAttribute(a);break;case"inert":case"allowFullScreen":case"async":case"autoPlay":case"controls":case"default":case"defer":case"disabled":case"disablePictureInPicture":case"disableRemotePlayback":case"formNoValidate":case"hidden":case"loop":case"noModule":case"noValidate":case"open":case"playsInline":case"readOnly":case"required":case"reversed":case"scoped":case"seamless":case"itemScope":s&&typeof s!="function"&&typeof s!="symbol"?t.setAttribute(a,""):t.removeAttribute(a);break;case"capture":case"download":s===!0?t.setAttribute(a,""):s!==!1&&s!=null&&typeof s!="function"&&typeof s!="symbol"?t.setAttribute(a,s):t.removeAttribute(a);break;case"cols":case"rows":case"size":case"span":s!=null&&typeof s!="function"&&typeof s!="symbol"&&!isNaN(s)&&1<=s?t.setAttribute(a,s):t.removeAttribute(a);break;case"rowSpan":case"start":s==null||typeof s=="function"||typeof s=="symbol"||isNaN(s)?t.removeAttribute(a):t.setAttribute(a,s);break;case"popover":he("beforetoggle",t),he("toggle",t),_e(t,"popover",s);break;case"xlinkActuate":Te(t,"http://www.w3.org/1999/xlink","xlink:actuate",s);break;case"xlinkArcrole":Te(t,"http://www.w3.org/1999/xlink","xlink:arcrole",s);break;case"xlinkRole":Te(t,"http://www.w3.org/1999/xlink","xlink:role",s);break;case"xlinkShow":Te(t,"http://www.w3.org/1999/xlink","xlink:show",s);break;case"xlinkTitle":Te(t,"http://www.w3.org/1999/xlink","xlink:title",s);break;case"xlinkType":Te(t,"http://www.w3.org/1999/xlink","xlink:type",s);break;case"xmlBase":Te(t,"http://www.w3.org/XML/1998/namespace","xml:base",s);break;case"xmlLang":Te(t,"http://www.w3.org/XML/1998/namespace","xml:lang",s);break;case"xmlSpace":Te(t,"http://www.w3.org/XML/1998/namespace","xml:space",s);break;case"is":_e(t,"is",s);break;case"innerText":case"textContent":break;default:(!(2<a.length)||a[0]!=="o"&&a[0]!=="O"||a[1]!=="n"&&a[1]!=="N")&&(a=$0.get(a)||a,_e(t,a,s))}}function vf(t,n,a,s,u,f){switch(a){case"style":Cd(t,s,f);break;case"dangerouslySetInnerHTML":if(s!=null){if(typeof s!="object"||!("__html"in s))throw Error(r(61));if(a=s.__html,a!=null){if(u.children!=null)throw Error(r(60));t.innerHTML=a}}break;case"children":typeof s=="string"?Nn(t,s):(typeof s=="number"||typeof s=="bigint")&&Nn(t,""+s);break;case"onScroll":s!=null&&he("scroll",t);break;case"onScrollEnd":s!=null&&he("scrollend",t);break;case"onClick":s!=null&&(t.onclick=zi);break;case"suppressContentEditableWarning":case"suppressHydrationWarning":case"innerHTML":case"ref":break;case"innerText":case"textContent":break;default:if(!Dt.hasOwnProperty(a))t:{if(a[0]==="o"&&a[1]==="n"&&(u=a.endsWith("Capture"),n=a.slice(2,u?a.length-7:void 0),f=t[mn]||null,f=f!=null?f[a]:null,typeof f=="function"&&t.removeEventListener(n,f,u),typeof s=="function")){typeof f!="function"&&f!==null&&(a in t?t[a]=null:t.hasAttribute(a)&&t.removeAttribute(a)),t.addEventListener(n,s,u);break t}a in t?t[a]=s:s===!0?t.setAttribute(a,""):_e(t,a,s)}}}function xn(t,n,a){switch(n){case"div":case"span":case"svg":case"path":case"a":case"g":case"p":case"li":break;case"img":he("error",t),he("load",t);var s=!1,u=!1,f;for(f in a)if(a.hasOwnProperty(f)){var g=a[f];if(g!=null)switch(f){case"src":s=!0;break;case"srcSet":u=!0;break;case"children":case"dangerouslySetInnerHTML":throw Error(r(137,n));default:ze(t,n,f,g,a,null)}}u&&ze(t,n,"srcSet",a.srcSet,a,null),s&&ze(t,n,"src",a.src,a,null);return;case"input":he("invalid",t);var E=f=g=u=null,F=null,$=null;for(s in a)if(a.hasOwnProperty(s)){var ut=a[s];if(ut!=null)switch(s){case"name":u=ut;break;case"type":g=ut;break;case"checked":F=ut;break;case"defaultChecked":$=ut;break;case"value":f=ut;break;case"defaultValue":E=ut;break;case"children":case"dangerouslySetInnerHTML":if(ut!=null)throw Error(r(137,n));break;default:ze(t,n,s,ut,a,null)}}wn(t,f,E,F,$,g,u,!1);return;case"select":he("invalid",t),s=g=f=null;for(u in a)if(a.hasOwnProperty(u)&&(E=a[u],E!=null))switch(u){case"value":f=E;break;case"defaultValue":g=E;break;case"multiple":s=E;default:ze(t,n,u,E,a,null)}n=f,a=g,t.multiple=!!s,n!=null?Ze(t,!!s,n,!1):a!=null&&Ze(t,!!s,a,!0);return;case"textarea":he("invalid",t),f=u=s=null;for(g in a)if(a.hasOwnProperty(g)&&(E=a[g],E!=null))switch(g){case"value":s=E;break;case"defaultValue":u=E;break;case"children":f=E;break;case"dangerouslySetInnerHTML":if(E!=null)throw Error(r(91));break;default:ze(t,n,g,E,a,null)}Er(t,s,u,f);return;case"option":for(F in a)if(a.hasOwnProperty(F)&&(s=a[F],s!=null))switch(F){case"selected":t.selected=s&&typeof s!="function"&&typeof s!="symbol";break;default:ze(t,n,F,s,a,null)}return;case"dialog":he("beforetoggle",t),he("toggle",t),he("cancel",t),he("close",t);break;case"iframe":case"object":he("load",t);break;case"video":case"audio":for(s=0;s<lo.length;s++)he(lo[s],t);break;case"image":he("error",t),he("load",t);break;case"details":he("toggle",t);break;case"embed":case"source":case"link":he("error",t),he("load",t);case"area":case"base":case"br":case"col":case"hr":case"keygen":case"meta":case"param":case"track":case"wbr":case"menuitem":for($ in a)if(a.hasOwnProperty($)&&(s=a[$],s!=null))switch($){case"children":case"dangerouslySetInnerHTML":throw Error(r(137,n));default:ze(t,n,$,s,a,null)}return;default:if(Uu(n)){for(ut in a)a.hasOwnProperty(ut)&&(s=a[ut],s!==void 0&&vf(t,n,ut,s,a,void 0));return}}for(E in a)a.hasOwnProperty(E)&&(s=a[E],s!=null&&ze(t,n,E,s,a,null))}function AS(t,n,a,s){switch(n){case"div":case"span":case"svg":case"path":case"a":case"g":case"p":case"li":break;case"input":var u=null,f=null,g=null,E=null,F=null,$=null,ut=null;for(ot in a){var gt=a[ot];if(a.hasOwnProperty(ot)&&gt!=null)switch(ot){case"checked":break;case"value":break;case"defaultValue":F=gt;default:s.hasOwnProperty(ot)||ze(t,n,ot,null,s,gt)}}for(var tt in s){var ot=s[tt];if(gt=a[tt],s.hasOwnProperty(tt)&&(ot!=null||gt!=null))switch(tt){case"type":f=ot;break;case"name":u=ot;break;case"checked":$=ot;break;case"defaultChecked":ut=ot;break;case"value":g=ot;break;case"defaultValue":E=ot;break;case"children":case"dangerouslySetInnerHTML":if(ot!=null)throw Error(r(137,n));break;default:ot!==gt&&ze(t,n,tt,ot,s,gt)}}Ne(t,g,E,F,$,ut,f,u);return;case"select":ot=g=E=tt=null;for(f in a)if(F=a[f],a.hasOwnProperty(f)&&F!=null)switch(f){case"value":break;case"multiple":ot=F;default:s.hasOwnProperty(f)||ze(t,n,f,null,s,F)}for(u in s)if(f=s[u],F=a[u],s.hasOwnProperty(u)&&(f!=null||F!=null))switch(u){case"value":tt=f;break;case"defaultValue":E=f;break;case"multiple":g=f;default:f!==F&&ze(t,n,u,f,s,F)}n=E,a=g,s=ot,tt!=null?Ze(t,!!a,tt,!1):!!s!=!!a&&(n!=null?Ze(t,!!a,n,!0):Ze(t,!!a,a?[]:"",!1));return;case"textarea":ot=tt=null;for(E in a)if(u=a[E],a.hasOwnProperty(E)&&u!=null&&!s.hasOwnProperty(E))switch(E){case"value":break;case"children":break;default:ze(t,n,E,null,s,u)}for(g in s)if(u=s[g],f=a[g],s.hasOwnProperty(g)&&(u!=null||f!=null))switch(g){case"value":tt=u;break;case"defaultValue":ot=u;break;case"children":break;case"dangerouslySetInnerHTML":if(u!=null)throw Error(r(91));break;default:u!==f&&ze(t,n,g,u,s,f)}gn(t,tt,ot);return;case"option":for(var Bt in a)if(tt=a[Bt],a.hasOwnProperty(Bt)&&tt!=null&&!s.hasOwnProperty(Bt))switch(Bt){case"selected":t.selected=!1;break;default:ze(t,n,Bt,null,s,tt)}for(F in s)if(tt=s[F],ot=a[F],s.hasOwnProperty(F)&&tt!==ot&&(tt!=null||ot!=null))switch(F){case"selected":t.selected=tt&&typeof tt!="function"&&typeof tt!="symbol";break;default:ze(t,n,F,tt,s,ot)}return;case"img":case"link":case"area":case"base":case"br":case"col":case"embed":case"hr":case"keygen":case"meta":case"param":case"source":case"track":case"wbr":case"menuitem":for(var Kt in a)tt=a[Kt],a.hasOwnProperty(Kt)&&tt!=null&&!s.hasOwnProperty(Kt)&&ze(t,n,Kt,null,s,tt);for($ in s)if(tt=s[$],ot=a[$],s.hasOwnProperty($)&&tt!==ot&&(tt!=null||ot!=null))switch($){case"children":case"dangerouslySetInnerHTML":if(tt!=null)throw Error(r(137,n));break;default:ze(t,n,$,tt,s,ot)}return;default:if(Uu(n)){for(var Pe in a)tt=a[Pe],a.hasOwnProperty(Pe)&&tt!==void 0&&!s.hasOwnProperty(Pe)&&vf(t,n,Pe,void 0,s,tt);for(ut in s)tt=s[ut],ot=a[ut],!s.hasOwnProperty(ut)||tt===ot||tt===void 0&&ot===void 0||vf(t,n,ut,tt,s,ot);return}}for(var Z in a)tt=a[Z],a.hasOwnProperty(Z)&&tt!=null&&!s.hasOwnProperty(Z)&&ze(t,n,Z,null,s,tt);for(gt in s)tt=s[gt],ot=a[gt],!s.hasOwnProperty(gt)||tt===ot||tt==null&&ot==null||ze(t,n,gt,tt,s,ot)}function wg(t){switch(t){case"css":case"script":case"font":case"img":case"image":case"input":case"link":return!0;default:return!1}}function RS(){if(typeof performance.getEntriesByType=="function"){for(var t=0,n=0,a=performance.getEntriesByType("resource"),s=0;s<a.length;s++){var u=a[s],f=u.transferSize,g=u.initiatorType,E=u.duration;if(f&&E&&wg(g)){for(g=0,E=u.responseEnd,s+=1;s<a.length;s++){var F=a[s],$=F.startTime;if($>E)break;var ut=F.transferSize,gt=F.initiatorType;ut&&wg(gt)&&(F=F.responseEnd,g+=ut*(F<E?1:(E-$)/(F-$)))}if(--s,n+=8*(f+g)/(u.duration/1e3),t++,10<t)break}}if(0<t)return n/t/1e6}return navigator.connection&&(t=navigator.connection.downlink,typeof t=="number")?t:5}var Sf=null,xf=null;function Nl(t){return t.nodeType===9?t:t.ownerDocument}function Dg(t){switch(t){case"http://www.w3.org/2000/svg":return 1;case"http://www.w3.org/1998/Math/MathML":return 2;default:return 0}}function Ug(t,n){if(t===0)switch(n){case"svg":return 1;case"math":return 2;default:return 0}return t===1&&n==="foreignObject"?0:t}function Mf(t,n){return t==="textarea"||t==="noscript"||typeof n.children=="string"||typeof n.children=="number"||typeof n.children=="bigint"||typeof n.dangerouslySetInnerHTML=="object"&&n.dangerouslySetInnerHTML!==null&&n.dangerouslySetInnerHTML.__html!=null}var yf=null;function CS(){var t=window.event;return t&&t.type==="popstate"?t===yf?!1:(yf=t,!0):(yf=null,!1)}var Lg=typeof setTimeout=="function"?setTimeout:void 0,wS=typeof clearTimeout=="function"?clearTimeout:void 0,Ng=typeof Promise=="function"?Promise:void 0,DS=typeof queueMicrotask=="function"?queueMicrotask:typeof Ng<"u"?function(t){return Ng.resolve(null).then(t).catch(US)}:Lg;function US(t){setTimeout(function(){throw t})}function Aa(t){return t==="head"}function Og(t,n){var a=n,s=0;do{var u=a.nextSibling;if(t.removeChild(a),u&&u.nodeType===8)if(a=u.data,a==="/$"||a==="/&"){if(s===0){t.removeChild(u),ts(n);return}s--}else if(a==="$"||a==="$?"||a==="$~"||a==="$!"||a==="&")s++;else if(a==="html")co(t.ownerDocument.documentElement);else if(a==="head"){a=t.ownerDocument.head,co(a);for(var f=a.firstChild;f;){var g=f.nextSibling,E=f.nodeName;f[Wa]||E==="SCRIPT"||E==="STYLE"||E==="LINK"&&f.rel.toLowerCase()==="stylesheet"||a.removeChild(f),f=g}}else a==="body"&&co(t.ownerDocument.body);a=u}while(a);ts(n)}function zg(t,n){var a=t;t=0;do{var s=a.nextSibling;if(a.nodeType===1?n?(a._stashedDisplay=a.style.display,a.style.display="none"):(a.style.display=a._stashedDisplay||"",a.getAttribute("style")===""&&a.removeAttribute("style")):a.nodeType===3&&(n?(a._stashedText=a.nodeValue,a.nodeValue=""):a.nodeValue=a._stashedText||""),s&&s.nodeType===8)if(a=s.data,a==="/$"){if(t===0)break;t--}else a!=="$"&&a!=="$?"&&a!=="$~"&&a!=="$!"||t++;a=s}while(a)}function Ef(t){var n=t.firstChild;for(n&&n.nodeType===10&&(n=n.nextSibling);n;){var a=n;switch(n=n.nextSibling,a.nodeName){case"HTML":case"HEAD":case"BODY":Ef(a),ws(a);continue;case"SCRIPT":case"STYLE":continue;case"LINK":if(a.rel.toLowerCase()==="stylesheet")continue}t.removeChild(a)}}function LS(t,n,a,s){for(;t.nodeType===1;){var u=a;if(t.nodeName.toLowerCase()!==n.toLowerCase()){if(!s&&(t.nodeName!=="INPUT"||t.type!=="hidden"))break}else if(s){if(!t[Wa])switch(n){case"meta":if(!t.hasAttribute("itemprop"))break;return t;case"link":if(f=t.getAttribute("rel"),f==="stylesheet"&&t.hasAttribute("data-precedence"))break;if(f!==u.rel||t.getAttribute("href")!==(u.href==null||u.href===""?null:u.href)||t.getAttribute("crossorigin")!==(u.crossOrigin==null?null:u.crossOrigin)||t.getAttribute("title")!==(u.title==null?null:u.title))break;return t;case"style":if(t.hasAttribute("data-precedence"))break;return t;case"script":if(f=t.getAttribute("src"),(f!==(u.src==null?null:u.src)||t.getAttribute("type")!==(u.type==null?null:u.type)||t.getAttribute("crossorigin")!==(u.crossOrigin==null?null:u.crossOrigin))&&f&&t.hasAttribute("async")&&!t.hasAttribute("itemprop"))break;return t;default:return t}}else if(n==="input"&&t.type==="hidden"){var f=u.name==null?null:""+u.name;if(u.type==="hidden"&&t.getAttribute("name")===f)return t}else return t;if(t=ri(t.nextSibling),t===null)break}return null}function NS(t,n,a){if(n==="")return null;for(;t.nodeType!==3;)if((t.nodeType!==1||t.nodeName!=="INPUT"||t.type!=="hidden")&&!a||(t=ri(t.nextSibling),t===null))return null;return t}function Pg(t,n){for(;t.nodeType!==8;)if((t.nodeType!==1||t.nodeName!=="INPUT"||t.type!=="hidden")&&!n||(t=ri(t.nextSibling),t===null))return null;return t}function Tf(t){return t.data==="$?"||t.data==="$~"}function bf(t){return t.data==="$!"||t.data==="$?"&&t.ownerDocument.readyState!=="loading"}function OS(t,n){var a=t.ownerDocument;if(t.data==="$~")t._reactRetry=n;else if(t.data!=="$?"||a.readyState!=="loading")n();else{var s=function(){n(),a.removeEventListener("DOMContentLoaded",s)};a.addEventListener("DOMContentLoaded",s),t._reactRetry=s}}function ri(t){for(;t!=null;t=t.nextSibling){var n=t.nodeType;if(n===1||n===3)break;if(n===8){if(n=t.data,n==="$"||n==="$!"||n==="$?"||n==="$~"||n==="&"||n==="F!"||n==="F")break;if(n==="/$"||n==="/&")return null}}return t}var Af=null;function Bg(t){t=t.nextSibling;for(var n=0;t;){if(t.nodeType===8){var a=t.data;if(a==="/$"||a==="/&"){if(n===0)return ri(t.nextSibling);n--}else a!=="$"&&a!=="$!"&&a!=="$?"&&a!=="$~"&&a!=="&"||n++}t=t.nextSibling}return null}function Ig(t){t=t.previousSibling;for(var n=0;t;){if(t.nodeType===8){var a=t.data;if(a==="$"||a==="$!"||a==="$?"||a==="$~"||a==="&"){if(n===0)return t;n--}else a!=="/$"&&a!=="/&"||n++}t=t.previousSibling}return null}function Fg(t,n,a){switch(n=Nl(a),t){case"html":if(t=n.documentElement,!t)throw Error(r(452));return t;case"head":if(t=n.head,!t)throw Error(r(453));return t;case"body":if(t=n.body,!t)throw Error(r(454));return t;default:throw Error(r(451))}}function co(t){for(var n=t.attributes;n.length;)t.removeAttributeNode(n[0]);ws(t)}var si=new Map,Hg=new Set;function Ol(t){return typeof t.getRootNode=="function"?t.getRootNode():t.nodeType===9?t:t.ownerDocument}var Qi=Y.d;Y.d={f:zS,r:PS,D:BS,C:IS,L:FS,m:HS,X:VS,S:GS,M:XS};function zS(){var t=Qi.f(),n=bl();return t||n}function PS(t){var n=q(t);n!==null&&n.tag===5&&n.type==="form"?im(n):Qi.r(t)}var Qr=typeof document>"u"?null:document;function Gg(t,n,a){var s=Qr;if(s&&typeof n=="string"&&n){var u=fn(n);u='link[rel="'+t+'"][href="'+u+'"]',typeof a=="string"&&(u+='[crossorigin="'+a+'"]'),Hg.has(u)||(Hg.add(u),t={rel:t,crossOrigin:a,href:n},s.querySelector(u)===null&&(n=s.createElement("link"),xn(n,"link",t),k(n),s.head.appendChild(n)))}}function BS(t){Qi.D(t),Gg("dns-prefetch",t,null)}function IS(t,n){Qi.C(t,n),Gg("preconnect",t,n)}function FS(t,n,a){Qi.L(t,n,a);var s=Qr;if(s&&t&&n){var u='link[rel="preload"][as="'+fn(n)+'"]';n==="image"&&a&&a.imageSrcSet?(u+='[imagesrcset="'+fn(a.imageSrcSet)+'"]',typeof a.imageSizes=="string"&&(u+='[imagesizes="'+fn(a.imageSizes)+'"]')):u+='[href="'+fn(t)+'"]';var f=u;switch(n){case"style":f=Jr(t);break;case"script":f=$r(t)}si.has(f)||(t=v({rel:"preload",href:n==="image"&&a&&a.imageSrcSet?void 0:t,as:n},a),si.set(f,t),s.querySelector(u)!==null||n==="style"&&s.querySelector(fo(f))||n==="script"&&s.querySelector(ho(f))||(n=s.createElement("link"),xn(n,"link",t),k(n),s.head.appendChild(n)))}}function HS(t,n){Qi.m(t,n);var a=Qr;if(a&&t){var s=n&&typeof n.as=="string"?n.as:"script",u='link[rel="modulepreload"][as="'+fn(s)+'"][href="'+fn(t)+'"]',f=u;switch(s){case"audioworklet":case"paintworklet":case"serviceworker":case"sharedworker":case"worker":case"script":f=$r(t)}if(!si.has(f)&&(t=v({rel:"modulepreload",href:t},n),si.set(f,t),a.querySelector(u)===null)){switch(s){case"audioworklet":case"paintworklet":case"serviceworker":case"sharedworker":case"worker":case"script":if(a.querySelector(ho(f)))return}s=a.createElement("link"),xn(s,"link",t),k(s),a.head.appendChild(s)}}}function GS(t,n,a){Qi.S(t,n,a);var s=Qr;if(s&&t){var u=at(s).hoistableStyles,f=Jr(t);n=n||"default";var g=u.get(f);if(!g){var E={loading:0,preload:null};if(g=s.querySelector(fo(f)))E.loading=5;else{t=v({rel:"stylesheet",href:t,"data-precedence":n},a),(a=si.get(f))&&Rf(t,a);var F=g=s.createElement("link");k(F),xn(F,"link",t),F._p=new Promise(function($,ut){F.onload=$,F.onerror=ut}),F.addEventListener("load",function(){E.loading|=1}),F.addEventListener("error",function(){E.loading|=2}),E.loading|=4,zl(g,n,s)}g={type:"stylesheet",instance:g,count:1,state:E},u.set(f,g)}}}function VS(t,n){Qi.X(t,n);var a=Qr;if(a&&t){var s=at(a).hoistableScripts,u=$r(t),f=s.get(u);f||(f=a.querySelector(ho(u)),f||(t=v({src:t,async:!0},n),(n=si.get(u))&&Cf(t,n),f=a.createElement("script"),k(f),xn(f,"link",t),a.head.appendChild(f)),f={type:"script",instance:f,count:1,state:null},s.set(u,f))}}function XS(t,n){Qi.M(t,n);var a=Qr;if(a&&t){var s=at(a).hoistableScripts,u=$r(t),f=s.get(u);f||(f=a.querySelector(ho(u)),f||(t=v({src:t,async:!0,type:"module"},n),(n=si.get(u))&&Cf(t,n),f=a.createElement("script"),k(f),xn(f,"link",t),a.head.appendChild(f)),f={type:"script",instance:f,count:1,state:null},s.set(u,f))}}function Vg(t,n,a,s){var u=(u=yt.current)?Ol(u):null;if(!u)throw Error(r(446));switch(t){case"meta":case"title":return null;case"style":return typeof a.precedence=="string"&&typeof a.href=="string"?(n=Jr(a.href),a=at(u).hoistableStyles,s=a.get(n),s||(s={type:"style",instance:null,count:0,state:null},a.set(n,s)),s):{type:"void",instance:null,count:0,state:null};case"link":if(a.rel==="stylesheet"&&typeof a.href=="string"&&typeof a.precedence=="string"){t=Jr(a.href);var f=at(u).hoistableStyles,g=f.get(t);if(g||(u=u.ownerDocument||u,g={type:"stylesheet",instance:null,count:0,state:{loading:0,preload:null}},f.set(t,g),(f=u.querySelector(fo(t)))&&!f._p&&(g.instance=f,g.state.loading=5),si.has(t)||(a={rel:"preload",as:"style",href:a.href,crossOrigin:a.crossOrigin,integrity:a.integrity,media:a.media,hrefLang:a.hrefLang,referrerPolicy:a.referrerPolicy},si.set(t,a),f||kS(u,t,a,g.state))),n&&s===null)throw Error(r(528,""));return g}if(n&&s!==null)throw Error(r(529,""));return null;case"script":return n=a.async,a=a.src,typeof a=="string"&&n&&typeof n!="function"&&typeof n!="symbol"?(n=$r(a),a=at(u).hoistableScripts,s=a.get(n),s||(s={type:"script",instance:null,count:0,state:null},a.set(n,s)),s):{type:"void",instance:null,count:0,state:null};default:throw Error(r(444,t))}}function Jr(t){return'href="'+fn(t)+'"'}function fo(t){return'link[rel="stylesheet"]['+t+"]"}function Xg(t){return v({},t,{"data-precedence":t.precedence,precedence:null})}function kS(t,n,a,s){t.querySelector('link[rel="preload"][as="style"]['+n+"]")?s.loading=1:(n=t.createElement("link"),s.preload=n,n.addEventListener("load",function(){return s.loading|=1}),n.addEventListener("error",function(){return s.loading|=2}),xn(n,"link",a),k(n),t.head.appendChild(n))}function $r(t){return'[src="'+fn(t)+'"]'}function ho(t){return"script[async]"+t}function kg(t,n,a){if(n.count++,n.instance===null)switch(n.type){case"style":var s=t.querySelector('style[data-href~="'+fn(a.href)+'"]');if(s)return n.instance=s,k(s),s;var u=v({},a,{"data-href":a.href,"data-precedence":a.precedence,href:null,precedence:null});return s=(t.ownerDocument||t).createElement("style"),k(s),xn(s,"style",u),zl(s,a.precedence,t),n.instance=s;case"stylesheet":u=Jr(a.href);var f=t.querySelector(fo(u));if(f)return n.state.loading|=4,n.instance=f,k(f),f;s=Xg(a),(u=si.get(u))&&Rf(s,u),f=(t.ownerDocument||t).createElement("link"),k(f);var g=f;return g._p=new Promise(function(E,F){g.onload=E,g.onerror=F}),xn(f,"link",s),n.state.loading|=4,zl(f,a.precedence,t),n.instance=f;case"script":return f=$r(a.src),(u=t.querySelector(ho(f)))?(n.instance=u,k(u),u):(s=a,(u=si.get(f))&&(s=v({},a),Cf(s,u)),t=t.ownerDocument||t,u=t.createElement("script"),k(u),xn(u,"link",s),t.head.appendChild(u),n.instance=u);case"void":return null;default:throw Error(r(443,n.type))}else n.type==="stylesheet"&&(n.state.loading&4)===0&&(s=n.instance,n.state.loading|=4,zl(s,a.precedence,t));return n.instance}function zl(t,n,a){for(var s=a.querySelectorAll('link[rel="stylesheet"][data-precedence],style[data-precedence]'),u=s.length?s[s.length-1]:null,f=u,g=0;g<s.length;g++){var E=s[g];if(E.dataset.precedence===n)f=E;else if(f!==u)break}f?f.parentNode.insertBefore(t,f.nextSibling):(n=a.nodeType===9?a.head:a,n.insertBefore(t,n.firstChild))}function Rf(t,n){t.crossOrigin==null&&(t.crossOrigin=n.crossOrigin),t.referrerPolicy==null&&(t.referrerPolicy=n.referrerPolicy),t.title==null&&(t.title=n.title)}function Cf(t,n){t.crossOrigin==null&&(t.crossOrigin=n.crossOrigin),t.referrerPolicy==null&&(t.referrerPolicy=n.referrerPolicy),t.integrity==null&&(t.integrity=n.integrity)}var Pl=null;function Wg(t,n,a){if(Pl===null){var s=new Map,u=Pl=new Map;u.set(a,s)}else u=Pl,s=u.get(a),s||(s=new Map,u.set(a,s));if(s.has(t))return s;for(s.set(t,null),a=a.getElementsByTagName(t),u=0;u<a.length;u++){var f=a[u];if(!(f[Wa]||f[je]||t==="link"&&f.getAttribute("rel")==="stylesheet")&&f.namespaceURI!=="http://www.w3.org/2000/svg"){var g=f.getAttribute(n)||"";g=t+g;var E=s.get(g);E?E.push(f):s.set(g,[f])}}return s}function qg(t,n,a){t=t.ownerDocument||t,t.head.insertBefore(a,n==="title"?t.querySelector("head > title"):null)}function WS(t,n,a){if(a===1||n.itemProp!=null)return!1;switch(t){case"meta":case"title":return!0;case"style":if(typeof n.precedence!="string"||typeof n.href!="string"||n.href==="")break;return!0;case"link":if(typeof n.rel!="string"||typeof n.href!="string"||n.href===""||n.onLoad||n.onError)break;switch(n.rel){case"stylesheet":return t=n.disabled,typeof n.precedence=="string"&&t==null;default:return!0}case"script":if(n.async&&typeof n.async!="function"&&typeof n.async!="symbol"&&!n.onLoad&&!n.onError&&n.src&&typeof n.src=="string")return!0}return!1}function Yg(t){return!(t.type==="stylesheet"&&(t.state.loading&3)===0)}function qS(t,n,a,s){if(a.type==="stylesheet"&&(typeof s.media!="string"||matchMedia(s.media).matches!==!1)&&(a.state.loading&4)===0){if(a.instance===null){var u=Jr(s.href),f=n.querySelector(fo(u));if(f){n=f._p,n!==null&&typeof n=="object"&&typeof n.then=="function"&&(t.count++,t=Bl.bind(t),n.then(t,t)),a.state.loading|=4,a.instance=f,k(f);return}f=n.ownerDocument||n,s=Xg(s),(u=si.get(u))&&Rf(s,u),f=f.createElement("link"),k(f);var g=f;g._p=new Promise(function(E,F){g.onload=E,g.onerror=F}),xn(f,"link",s),a.instance=f}t.stylesheets===null&&(t.stylesheets=new Map),t.stylesheets.set(a,n),(n=a.state.preload)&&(a.state.loading&3)===0&&(t.count++,a=Bl.bind(t),n.addEventListener("load",a),n.addEventListener("error",a))}}var wf=0;function YS(t,n){return t.stylesheets&&t.count===0&&Fl(t,t.stylesheets),0<t.count||0<t.imgCount?function(a){var s=setTimeout(function(){if(t.stylesheets&&Fl(t,t.stylesheets),t.unsuspend){var f=t.unsuspend;t.unsuspend=null,f()}},6e4+n);0<t.imgBytes&&wf===0&&(wf=62500*RS());var u=setTimeout(function(){if(t.waitingForImages=!1,t.count===0&&(t.stylesheets&&Fl(t,t.stylesheets),t.unsuspend)){var f=t.unsuspend;t.unsuspend=null,f()}},(t.imgBytes>wf?50:800)+n);return t.unsuspend=a,function(){t.unsuspend=null,clearTimeout(s),clearTimeout(u)}}:null}function Bl(){if(this.count--,this.count===0&&(this.imgCount===0||!this.waitingForImages)){if(this.stylesheets)Fl(this,this.stylesheets);else if(this.unsuspend){var t=this.unsuspend;this.unsuspend=null,t()}}}var Il=null;function Fl(t,n){t.stylesheets=null,t.unsuspend!==null&&(t.count++,Il=new Map,n.forEach(jS,t),Il=null,Bl.call(t))}function jS(t,n){if(!(n.state.loading&4)){var a=Il.get(t);if(a)var s=a.get(null);else{a=new Map,Il.set(t,a);for(var u=t.querySelectorAll("link[data-precedence],style[data-precedence]"),f=0;f<u.length;f++){var g=u[f];(g.nodeName==="LINK"||g.getAttribute("media")!=="not all")&&(a.set(g.dataset.precedence,g),s=g)}s&&a.set(null,s)}u=n.instance,g=u.getAttribute("data-precedence"),f=a.get(g)||s,f===s&&a.set(null,u),a.set(g,u),this.count++,s=Bl.bind(this),u.addEventListener("load",s),u.addEventListener("error",s),f?f.parentNode.insertBefore(u,f.nextSibling):(t=t.nodeType===9?t.head:t,t.insertBefore(u,t.firstChild)),n.state.loading|=4}}var po={$$typeof:U,Provider:null,Consumer:null,_currentValue:j,_currentValue2:j,_threadCount:0};function ZS(t,n,a,s,u,f,g,E,F){this.tag=1,this.containerInfo=t,this.pingCache=this.current=this.pendingChildren=null,this.timeoutHandle=-1,this.callbackNode=this.next=this.pendingContext=this.context=this.cancelPendingCommit=null,this.callbackPriority=0,this.expirationTimes=Ee(-1),this.entangledLanes=this.shellSuspendCounter=this.errorRecoveryDisabledLanes=this.expiredLanes=this.warmLanes=this.pingedLanes=this.suspendedLanes=this.pendingLanes=0,this.entanglements=Ee(0),this.hiddenUpdates=Ee(null),this.identifierPrefix=s,this.onUncaughtError=u,this.onCaughtError=f,this.onRecoverableError=g,this.pooledCache=null,this.pooledCacheLanes=0,this.formState=F,this.incompleteTransitions=new Map}function jg(t,n,a,s,u,f,g,E,F,$,ut,gt){return t=new ZS(t,n,a,g,F,$,ut,gt,E),n=1,f===!0&&(n|=24),f=kn(3,null,null,n),t.current=f,f.stateNode=t,n=oc(),n.refCount++,t.pooledCache=n,n.refCount++,f.memoizedState={element:s,isDehydrated:a,cache:n},fc(f),t}function Zg(t){return t?(t=Dr,t):Dr}function Kg(t,n,a,s,u,f){u=Zg(u),s.context===null?s.context=u:s.pendingContext=u,s=ma(n),s.payload={element:a},f=f===void 0?null:f,f!==null&&(s.callback=f),a=ga(t,s,n),a!==null&&(Fn(a,t,n),Ws(a,t,n))}function Qg(t,n){if(t=t.memoizedState,t!==null&&t.dehydrated!==null){var a=t.retryLane;t.retryLane=a!==0&&a<n?a:n}}function Df(t,n){Qg(t,n),(t=t.alternate)&&Qg(t,n)}function Jg(t){if(t.tag===13||t.tag===31){var n=Za(t,67108864);n!==null&&Fn(n,t,67108864),Df(t,67108864)}}function $g(t){if(t.tag===13||t.tag===31){var n=Zn();n=Xa(n);var a=Za(t,n);a!==null&&Fn(a,t,n),Df(t,n)}}var Hl=!0;function KS(t,n,a,s){var u=P.T;P.T=null;var f=Y.p;try{Y.p=2,Uf(t,n,a,s)}finally{Y.p=f,P.T=u}}function QS(t,n,a,s){var u=P.T;P.T=null;var f=Y.p;try{Y.p=8,Uf(t,n,a,s)}finally{Y.p=f,P.T=u}}function Uf(t,n,a,s){if(Hl){var u=Lf(s);if(u===null)_f(t,n,s,Gl,a),e_(t,s);else if($S(u,t,n,a,s))s.stopPropagation();else if(e_(t,s),n&4&&-1<JS.indexOf(t)){for(;u!==null;){var f=q(u);if(f!==null)switch(f.tag){case 3:if(f=f.stateNode,f.current.memoizedState.isDehydrated){var g=At(f.pendingLanes);if(g!==0){var E=f;for(E.pendingLanes|=2,E.entangledLanes|=2;g;){var F=1<<31-$t(g);E.entanglements[1]|=F,g&=~F}Ri(f),(Ce&6)===0&&(El=ct()+500,oo(0))}}break;case 31:case 13:E=Za(f,2),E!==null&&Fn(E,f,2),bl(),Df(f,2)}if(f=Lf(s),f===null&&_f(t,n,s,Gl,a),f===u)break;u=f}u!==null&&s.stopPropagation()}else _f(t,n,s,null,a)}}function Lf(t){return t=Nu(t),Nf(t)}var Gl=null;function Nf(t){if(Gl=null,t=A(t),t!==null){var n=c(t);if(n===null)t=null;else{var a=n.tag;if(a===13){if(t=h(n),t!==null)return t;t=null}else if(a===31){if(t=d(n),t!==null)return t;t=null}else if(a===3){if(n.stateNode.current.memoizedState.isDehydrated)return n.tag===3?n.stateNode.containerInfo:null;t=null}else n!==t&&(t=null)}}return Gl=t,null}function t_(t){switch(t){case"beforetoggle":case"cancel":case"click":case"close":case"contextmenu":case"copy":case"cut":case"auxclick":case"dblclick":case"dragend":case"dragstart":case"drop":case"focusin":case"focusout":case"input":case"invalid":case"keydown":case"keypress":case"keyup":case"mousedown":case"mouseup":case"paste":case"pause":case"play":case"pointercancel":case"pointerdown":case"pointerup":case"ratechange":case"reset":case"resize":case"seeked":case"submit":case"toggle":case"touchcancel":case"touchend":case"touchstart":case"volumechange":case"change":case"selectionchange":case"textInput":case"compositionstart":case"compositionend":case"compositionupdate":case"beforeblur":case"afterblur":case"beforeinput":case"blur":case"fullscreenchange":case"focus":case"hashchange":case"popstate":case"select":case"selectstart":return 2;case"drag":case"dragenter":case"dragexit":case"dragleave":case"dragover":case"mousemove":case"mouseout":case"mouseover":case"pointermove":case"pointerout":case"pointerover":case"scroll":case"touchmove":case"wheel":case"mouseenter":case"mouseleave":case"pointerenter":case"pointerleave":return 8;case"message":switch(Mt()){case mt:return 2;case Ft:return 8;case Rt:case Zt:return 32;case Qt:return 268435456;default:return 32}default:return 32}}var Of=!1,Ra=null,Ca=null,wa=null,mo=new Map,go=new Map,Da=[],JS="mousedown mouseup touchcancel touchend touchstart auxclick dblclick pointercancel pointerdown pointerup dragend dragstart drop compositionend compositionstart keydown keypress keyup input textInput copy cut paste click change contextmenu reset".split(" ");function e_(t,n){switch(t){case"focusin":case"focusout":Ra=null;break;case"dragenter":case"dragleave":Ca=null;break;case"mouseover":case"mouseout":wa=null;break;case"pointerover":case"pointerout":mo.delete(n.pointerId);break;case"gotpointercapture":case"lostpointercapture":go.delete(n.pointerId)}}function _o(t,n,a,s,u,f){return t===null||t.nativeEvent!==f?(t={blockedOn:n,domEventName:a,eventSystemFlags:s,nativeEvent:f,targetContainers:[u]},n!==null&&(n=q(n),n!==null&&Jg(n)),t):(t.eventSystemFlags|=s,n=t.targetContainers,u!==null&&n.indexOf(u)===-1&&n.push(u),t)}function $S(t,n,a,s,u){switch(n){case"focusin":return Ra=_o(Ra,t,n,a,s,u),!0;case"dragenter":return Ca=_o(Ca,t,n,a,s,u),!0;case"mouseover":return wa=_o(wa,t,n,a,s,u),!0;case"pointerover":var f=u.pointerId;return mo.set(f,_o(mo.get(f)||null,t,n,a,s,u)),!0;case"gotpointercapture":return f=u.pointerId,go.set(f,_o(go.get(f)||null,t,n,a,s,u)),!0}return!1}function n_(t){var n=A(t.target);if(n!==null){var a=c(n);if(a!==null){if(n=a.tag,n===13){if(n=h(a),n!==null){t.blockedOn=n,ka(t.priority,function(){$g(a)});return}}else if(n===31){if(n=d(a),n!==null){t.blockedOn=n,ka(t.priority,function(){$g(a)});return}}else if(n===3&&a.stateNode.current.memoizedState.isDehydrated){t.blockedOn=a.tag===3?a.stateNode.containerInfo:null;return}}}t.blockedOn=null}function Vl(t){if(t.blockedOn!==null)return!1;for(var n=t.targetContainers;0<n.length;){var a=Lf(t.nativeEvent);if(a===null){a=t.nativeEvent;var s=new a.constructor(a.type,a);Lu=s,a.target.dispatchEvent(s),Lu=null}else return n=q(a),n!==null&&Jg(n),t.blockedOn=a,!1;n.shift()}return!0}function i_(t,n,a){Vl(t)&&a.delete(n)}function tx(){Of=!1,Ra!==null&&Vl(Ra)&&(Ra=null),Ca!==null&&Vl(Ca)&&(Ca=null),wa!==null&&Vl(wa)&&(wa=null),mo.forEach(i_),go.forEach(i_)}function Xl(t,n){t.blockedOn===n&&(t.blockedOn=null,Of||(Of=!0,o.unstable_scheduleCallback(o.unstable_NormalPriority,tx)))}var kl=null;function a_(t){kl!==t&&(kl=t,o.unstable_scheduleCallback(o.unstable_NormalPriority,function(){kl===t&&(kl=null);for(var n=0;n<t.length;n+=3){var a=t[n],s=t[n+1],u=t[n+2];if(typeof s!="function"){if(Nf(s||a)===null)continue;break}var f=q(a);f!==null&&(t.splice(n,3),n-=3,Uc(f,{pending:!0,data:u,method:a.method,action:s},s,u))}}))}function ts(t){function n(F){return Xl(F,t)}Ra!==null&&Xl(Ra,t),Ca!==null&&Xl(Ca,t),wa!==null&&Xl(wa,t),mo.forEach(n),go.forEach(n);for(var a=0;a<Da.length;a++){var s=Da[a];s.blockedOn===t&&(s.blockedOn=null)}for(;0<Da.length&&(a=Da[0],a.blockedOn===null);)n_(a),a.blockedOn===null&&Da.shift();if(a=(t.ownerDocument||t).$$reactFormReplay,a!=null)for(s=0;s<a.length;s+=3){var u=a[s],f=a[s+1],g=u[mn]||null;if(typeof f=="function")g||a_(a);else if(g){var E=null;if(f&&f.hasAttribute("formAction")){if(u=f,g=f[mn]||null)E=g.formAction;else if(Nf(u)!==null)continue}else E=g.action;typeof E=="function"?a[s+1]=E:(a.splice(s,3),s-=3),a_(a)}}}function r_(){function t(f){f.canIntercept&&f.info==="react-transition"&&f.intercept({handler:function(){return new Promise(function(g){return u=g})},focusReset:"manual",scroll:"manual"})}function n(){u!==null&&(u(),u=null),s||setTimeout(a,20)}function a(){if(!s&&!navigation.transition){var f=navigation.currentEntry;f&&f.url!=null&&navigation.navigate(f.url,{state:f.getState(),info:"react-transition",history:"replace"})}}if(typeof navigation=="object"){var s=!1,u=null;return navigation.addEventListener("navigate",t),navigation.addEventListener("navigatesuccess",n),navigation.addEventListener("navigateerror",n),setTimeout(a,100),function(){s=!0,navigation.removeEventListener("navigate",t),navigation.removeEventListener("navigatesuccess",n),navigation.removeEventListener("navigateerror",n),u!==null&&(u(),u=null)}}}function zf(t){this._internalRoot=t}Wl.prototype.render=zf.prototype.render=function(t){var n=this._internalRoot;if(n===null)throw Error(r(409));var a=n.current,s=Zn();Kg(a,s,t,n,null,null)},Wl.prototype.unmount=zf.prototype.unmount=function(){var t=this._internalRoot;if(t!==null){this._internalRoot=null;var n=t.containerInfo;Kg(t.current,2,null,t,null,null),bl(),n[Oi]=null}};function Wl(t){this._internalRoot=t}Wl.prototype.unstable_scheduleHydration=function(t){if(t){var n=Rs();t={blockedOn:null,target:t,priority:n};for(var a=0;a<Da.length&&n!==0&&n<Da[a].priority;a++);Da.splice(a,0,t),a===0&&n_(t)}};var s_=e.version;if(s_!=="19.2.4")throw Error(r(527,s_,"19.2.4"));Y.findDOMNode=function(t){var n=t._reactInternals;if(n===void 0)throw typeof t.render=="function"?Error(r(188)):(t=Object.keys(t).join(","),Error(r(268,t)));return t=p(n),t=t!==null?S(t):null,t=t===null?null:t.stateNode,t};var ex={bundleType:0,version:"19.2.4",rendererPackageName:"react-dom",currentDispatcherRef:P,reconcilerVersion:"19.2.4"};if(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__<"u"){var ql=__REACT_DEVTOOLS_GLOBAL_HOOK__;if(!ql.isDisabled&&ql.supportsFiber)try{Yt=ql.inject(ex),Ht=ql}catch{}}return So.createRoot=function(t,n){if(!l(t))throw Error(r(299));var a=!1,s="",u=dm,f=pm,g=mm;return n!=null&&(n.unstable_strictMode===!0&&(a=!0),n.identifierPrefix!==void 0&&(s=n.identifierPrefix),n.onUncaughtError!==void 0&&(u=n.onUncaughtError),n.onCaughtError!==void 0&&(f=n.onCaughtError),n.onRecoverableError!==void 0&&(g=n.onRecoverableError)),n=jg(t,1,!1,null,null,a,s,null,u,f,g,r_),t[Oi]=n.current,gf(t),new zf(n)},So.hydrateRoot=function(t,n,a){if(!l(t))throw Error(r(299));var s=!1,u="",f=dm,g=pm,E=mm,F=null;return a!=null&&(a.unstable_strictMode===!0&&(s=!0),a.identifierPrefix!==void 0&&(u=a.identifierPrefix),a.onUncaughtError!==void 0&&(f=a.onUncaughtError),a.onCaughtError!==void 0&&(g=a.onCaughtError),a.onRecoverableError!==void 0&&(E=a.onRecoverableError),a.formState!==void 0&&(F=a.formState)),n=jg(t,1,!0,n,a??null,s,u,F,f,g,E,r_),n.context=Zg(null),a=n.current,s=Zn(),s=Xa(s),u=ma(s),u.callback=null,ga(a,u,s),a=s,n.current.lanes=a,pn(n,a),Ri(n),t[Oi]=n.current,gf(t),new Wl(n)},So.version="19.2.4",So}var g_;function fx(){if(g_)return If.exports;g_=1;function o(){if(!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__>"u"||typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE!="function"))try{__REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(o)}catch(e){console.error(e)}}return o(),If.exports=cx(),If.exports}var hx=fx();/**
 * @license
 * Copyright 2010-2025 Three.js Authors
 * SPDX-License-Identifier: MIT
 */const ud="176",dx=0,__=1,px=2,x0=1,M0=2,ia=3,Ga=0,Gn=1,ra=2,Fa=0,gs=1,v_=2,S_=3,x_=4,mx=5,gr=100,gx=101,_x=102,vx=103,Sx=104,xx=200,Mx=201,yx=202,Ex=203,Mh=204,yh=205,Tx=206,bx=207,Ax=208,Rx=209,Cx=210,wx=211,Dx=212,Ux=213,Lx=214,Eh=0,Th=1,bh=2,vs=3,Ah=4,Rh=5,Ch=6,wh=7,y0=0,Nx=1,Ox=2,Ha=0,zx=1,Px=2,Bx=3,E0=4,Ix=5,Fx=6,Hx=7,T0=300,Ss=301,xs=302,Dh=303,Uh=304,Au=306,Lh=1e3,vr=1001,Nh=1002,yi=1003,Gx=1004,Yl=1005,wi=1006,Vf=1007,Sr=1008,Ui=1009,b0=1010,A0=1011,Ro=1012,cd=1013,xr=1014,sa=1015,Uo=1016,fd=1017,hd=1018,Co=1020,R0=35902,C0=1021,w0=1022,Mi=1023,wo=1026,Do=1027,D0=1028,dd=1029,U0=1030,pd=1031,md=1033,gu=33776,_u=33777,vu=33778,Su=33779,Oh=35840,zh=35841,Ph=35842,Bh=35843,Ih=36196,Fh=37492,Hh=37496,Gh=37808,Vh=37809,Xh=37810,kh=37811,Wh=37812,qh=37813,Yh=37814,jh=37815,Zh=37816,Kh=37817,Qh=37818,Jh=37819,$h=37820,td=37821,xu=36492,ed=36494,nd=36495,L0=36283,id=36284,ad=36285,rd=36286,Vx=3200,Xx=3201,N0=0,kx=1,Ia="",li="srgb",Ms="srgb-linear",Eu="linear",Be="srgb",es=7680,M_=519,Wx=512,qx=513,Yx=514,O0=515,jx=516,Zx=517,Kx=518,Qx=519,y_=35044,E_="300 es",oa=2e3,Tu=2001;class Es{addEventListener(e,i){this._listeners===void 0&&(this._listeners={});const r=this._listeners;r[e]===void 0&&(r[e]=[]),r[e].indexOf(i)===-1&&r[e].push(i)}hasEventListener(e,i){const r=this._listeners;return r===void 0?!1:r[e]!==void 0&&r[e].indexOf(i)!==-1}removeEventListener(e,i){const r=this._listeners;if(r===void 0)return;const l=r[e];if(l!==void 0){const c=l.indexOf(i);c!==-1&&l.splice(c,1)}}dispatchEvent(e){const i=this._listeners;if(i===void 0)return;const r=i[e.type];if(r!==void 0){e.target=this;const l=r.slice(0);for(let c=0,h=l.length;c<h;c++)l[c].call(this,e);e.target=null}}}const Tn=["00","01","02","03","04","05","06","07","08","09","0a","0b","0c","0d","0e","0f","10","11","12","13","14","15","16","17","18","19","1a","1b","1c","1d","1e","1f","20","21","22","23","24","25","26","27","28","29","2a","2b","2c","2d","2e","2f","30","31","32","33","34","35","36","37","38","39","3a","3b","3c","3d","3e","3f","40","41","42","43","44","45","46","47","48","49","4a","4b","4c","4d","4e","4f","50","51","52","53","54","55","56","57","58","59","5a","5b","5c","5d","5e","5f","60","61","62","63","64","65","66","67","68","69","6a","6b","6c","6d","6e","6f","70","71","72","73","74","75","76","77","78","79","7a","7b","7c","7d","7e","7f","80","81","82","83","84","85","86","87","88","89","8a","8b","8c","8d","8e","8f","90","91","92","93","94","95","96","97","98","99","9a","9b","9c","9d","9e","9f","a0","a1","a2","a3","a4","a5","a6","a7","a8","a9","aa","ab","ac","ad","ae","af","b0","b1","b2","b3","b4","b5","b6","b7","b8","b9","ba","bb","bc","bd","be","bf","c0","c1","c2","c3","c4","c5","c6","c7","c8","c9","ca","cb","cc","cd","ce","cf","d0","d1","d2","d3","d4","d5","d6","d7","d8","d9","da","db","dc","dd","de","df","e0","e1","e2","e3","e4","e5","e6","e7","e8","e9","ea","eb","ec","ed","ee","ef","f0","f1","f2","f3","f4","f5","f6","f7","f8","f9","fa","fb","fc","fd","fe","ff"],Xf=Math.PI/180,sd=180/Math.PI;function Lo(){const o=Math.random()*4294967295|0,e=Math.random()*4294967295|0,i=Math.random()*4294967295|0,r=Math.random()*4294967295|0;return(Tn[o&255]+Tn[o>>8&255]+Tn[o>>16&255]+Tn[o>>24&255]+"-"+Tn[e&255]+Tn[e>>8&255]+"-"+Tn[e>>16&15|64]+Tn[e>>24&255]+"-"+Tn[i&63|128]+Tn[i>>8&255]+"-"+Tn[i>>16&255]+Tn[i>>24&255]+Tn[r&255]+Tn[r>>8&255]+Tn[r>>16&255]+Tn[r>>24&255]).toLowerCase()}function Se(o,e,i){return Math.max(e,Math.min(i,o))}function Jx(o,e){return(o%e+e)%e}function kf(o,e,i){return(1-i)*o+i*e}function xo(o,e){switch(e.constructor){case Float32Array:return o;case Uint32Array:return o/4294967295;case Uint16Array:return o/65535;case Uint8Array:return o/255;case Int32Array:return Math.max(o/2147483647,-1);case Int16Array:return Math.max(o/32767,-1);case Int8Array:return Math.max(o/127,-1);default:throw new Error("Invalid component type.")}}function Hn(o,e){switch(e.constructor){case Float32Array:return o;case Uint32Array:return Math.round(o*4294967295);case Uint16Array:return Math.round(o*65535);case Uint8Array:return Math.round(o*255);case Int32Array:return Math.round(o*2147483647);case Int16Array:return Math.round(o*32767);case Int8Array:return Math.round(o*127);default:throw new Error("Invalid component type.")}}class ye{constructor(e=0,i=0){ye.prototype.isVector2=!0,this.x=e,this.y=i}get width(){return this.x}set width(e){this.x=e}get height(){return this.y}set height(e){this.y=e}set(e,i){return this.x=e,this.y=i,this}setScalar(e){return this.x=e,this.y=e,this}setX(e){return this.x=e,this}setY(e){return this.y=e,this}setComponent(e,i){switch(e){case 0:this.x=i;break;case 1:this.y=i;break;default:throw new Error("index is out of range: "+e)}return this}getComponent(e){switch(e){case 0:return this.x;case 1:return this.y;default:throw new Error("index is out of range: "+e)}}clone(){return new this.constructor(this.x,this.y)}copy(e){return this.x=e.x,this.y=e.y,this}add(e){return this.x+=e.x,this.y+=e.y,this}addScalar(e){return this.x+=e,this.y+=e,this}addVectors(e,i){return this.x=e.x+i.x,this.y=e.y+i.y,this}addScaledVector(e,i){return this.x+=e.x*i,this.y+=e.y*i,this}sub(e){return this.x-=e.x,this.y-=e.y,this}subScalar(e){return this.x-=e,this.y-=e,this}subVectors(e,i){return this.x=e.x-i.x,this.y=e.y-i.y,this}multiply(e){return this.x*=e.x,this.y*=e.y,this}multiplyScalar(e){return this.x*=e,this.y*=e,this}divide(e){return this.x/=e.x,this.y/=e.y,this}divideScalar(e){return this.multiplyScalar(1/e)}applyMatrix3(e){const i=this.x,r=this.y,l=e.elements;return this.x=l[0]*i+l[3]*r+l[6],this.y=l[1]*i+l[4]*r+l[7],this}min(e){return this.x=Math.min(this.x,e.x),this.y=Math.min(this.y,e.y),this}max(e){return this.x=Math.max(this.x,e.x),this.y=Math.max(this.y,e.y),this}clamp(e,i){return this.x=Se(this.x,e.x,i.x),this.y=Se(this.y,e.y,i.y),this}clampScalar(e,i){return this.x=Se(this.x,e,i),this.y=Se(this.y,e,i),this}clampLength(e,i){const r=this.length();return this.divideScalar(r||1).multiplyScalar(Se(r,e,i))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this}negate(){return this.x=-this.x,this.y=-this.y,this}dot(e){return this.x*e.x+this.y*e.y}cross(e){return this.x*e.y-this.y*e.x}lengthSq(){return this.x*this.x+this.y*this.y}length(){return Math.sqrt(this.x*this.x+this.y*this.y)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)}normalize(){return this.divideScalar(this.length()||1)}angle(){return Math.atan2(-this.y,-this.x)+Math.PI}angleTo(e){const i=Math.sqrt(this.lengthSq()*e.lengthSq());if(i===0)return Math.PI/2;const r=this.dot(e)/i;return Math.acos(Se(r,-1,1))}distanceTo(e){return Math.sqrt(this.distanceToSquared(e))}distanceToSquared(e){const i=this.x-e.x,r=this.y-e.y;return i*i+r*r}manhattanDistanceTo(e){return Math.abs(this.x-e.x)+Math.abs(this.y-e.y)}setLength(e){return this.normalize().multiplyScalar(e)}lerp(e,i){return this.x+=(e.x-this.x)*i,this.y+=(e.y-this.y)*i,this}lerpVectors(e,i,r){return this.x=e.x+(i.x-e.x)*r,this.y=e.y+(i.y-e.y)*r,this}equals(e){return e.x===this.x&&e.y===this.y}fromArray(e,i=0){return this.x=e[i],this.y=e[i+1],this}toArray(e=[],i=0){return e[i]=this.x,e[i+1]=this.y,e}fromBufferAttribute(e,i){return this.x=e.getX(i),this.y=e.getY(i),this}rotateAround(e,i){const r=Math.cos(i),l=Math.sin(i),c=this.x-e.x,h=this.y-e.y;return this.x=c*r-h*l+e.x,this.y=c*l+h*r+e.y,this}random(){return this.x=Math.random(),this.y=Math.random(),this}*[Symbol.iterator](){yield this.x,yield this.y}}class oe{constructor(e,i,r,l,c,h,d,m,p){oe.prototype.isMatrix3=!0,this.elements=[1,0,0,0,1,0,0,0,1],e!==void 0&&this.set(e,i,r,l,c,h,d,m,p)}set(e,i,r,l,c,h,d,m,p){const S=this.elements;return S[0]=e,S[1]=l,S[2]=d,S[3]=i,S[4]=c,S[5]=m,S[6]=r,S[7]=h,S[8]=p,this}identity(){return this.set(1,0,0,0,1,0,0,0,1),this}copy(e){const i=this.elements,r=e.elements;return i[0]=r[0],i[1]=r[1],i[2]=r[2],i[3]=r[3],i[4]=r[4],i[5]=r[5],i[6]=r[6],i[7]=r[7],i[8]=r[8],this}extractBasis(e,i,r){return e.setFromMatrix3Column(this,0),i.setFromMatrix3Column(this,1),r.setFromMatrix3Column(this,2),this}setFromMatrix4(e){const i=e.elements;return this.set(i[0],i[4],i[8],i[1],i[5],i[9],i[2],i[6],i[10]),this}multiply(e){return this.multiplyMatrices(this,e)}premultiply(e){return this.multiplyMatrices(e,this)}multiplyMatrices(e,i){const r=e.elements,l=i.elements,c=this.elements,h=r[0],d=r[3],m=r[6],p=r[1],S=r[4],v=r[7],x=r[2],y=r[5],R=r[8],w=l[0],M=l[3],_=l[6],L=l[1],U=l[4],C=l[7],G=l[2],I=l[5],O=l[8];return c[0]=h*w+d*L+m*G,c[3]=h*M+d*U+m*I,c[6]=h*_+d*C+m*O,c[1]=p*w+S*L+v*G,c[4]=p*M+S*U+v*I,c[7]=p*_+S*C+v*O,c[2]=x*w+y*L+R*G,c[5]=x*M+y*U+R*I,c[8]=x*_+y*C+R*O,this}multiplyScalar(e){const i=this.elements;return i[0]*=e,i[3]*=e,i[6]*=e,i[1]*=e,i[4]*=e,i[7]*=e,i[2]*=e,i[5]*=e,i[8]*=e,this}determinant(){const e=this.elements,i=e[0],r=e[1],l=e[2],c=e[3],h=e[4],d=e[5],m=e[6],p=e[7],S=e[8];return i*h*S-i*d*p-r*c*S+r*d*m+l*c*p-l*h*m}invert(){const e=this.elements,i=e[0],r=e[1],l=e[2],c=e[3],h=e[4],d=e[5],m=e[6],p=e[7],S=e[8],v=S*h-d*p,x=d*m-S*c,y=p*c-h*m,R=i*v+r*x+l*y;if(R===0)return this.set(0,0,0,0,0,0,0,0,0);const w=1/R;return e[0]=v*w,e[1]=(l*p-S*r)*w,e[2]=(d*r-l*h)*w,e[3]=x*w,e[4]=(S*i-l*m)*w,e[5]=(l*c-d*i)*w,e[6]=y*w,e[7]=(r*m-p*i)*w,e[8]=(h*i-r*c)*w,this}transpose(){let e;const i=this.elements;return e=i[1],i[1]=i[3],i[3]=e,e=i[2],i[2]=i[6],i[6]=e,e=i[5],i[5]=i[7],i[7]=e,this}getNormalMatrix(e){return this.setFromMatrix4(e).invert().transpose()}transposeIntoArray(e){const i=this.elements;return e[0]=i[0],e[1]=i[3],e[2]=i[6],e[3]=i[1],e[4]=i[4],e[5]=i[7],e[6]=i[2],e[7]=i[5],e[8]=i[8],this}setUvTransform(e,i,r,l,c,h,d){const m=Math.cos(c),p=Math.sin(c);return this.set(r*m,r*p,-r*(m*h+p*d)+h+e,-l*p,l*m,-l*(-p*h+m*d)+d+i,0,0,1),this}scale(e,i){return this.premultiply(Wf.makeScale(e,i)),this}rotate(e){return this.premultiply(Wf.makeRotation(-e)),this}translate(e,i){return this.premultiply(Wf.makeTranslation(e,i)),this}makeTranslation(e,i){return e.isVector2?this.set(1,0,e.x,0,1,e.y,0,0,1):this.set(1,0,e,0,1,i,0,0,1),this}makeRotation(e){const i=Math.cos(e),r=Math.sin(e);return this.set(i,-r,0,r,i,0,0,0,1),this}makeScale(e,i){return this.set(e,0,0,0,i,0,0,0,1),this}equals(e){const i=this.elements,r=e.elements;for(let l=0;l<9;l++)if(i[l]!==r[l])return!1;return!0}fromArray(e,i=0){for(let r=0;r<9;r++)this.elements[r]=e[r+i];return this}toArray(e=[],i=0){const r=this.elements;return e[i]=r[0],e[i+1]=r[1],e[i+2]=r[2],e[i+3]=r[3],e[i+4]=r[4],e[i+5]=r[5],e[i+6]=r[6],e[i+7]=r[7],e[i+8]=r[8],e}clone(){return new this.constructor().fromArray(this.elements)}}const Wf=new oe;function z0(o){for(let e=o.length-1;e>=0;--e)if(o[e]>=65535)return!0;return!1}function bu(o){return document.createElementNS("http://www.w3.org/1999/xhtml",o)}function $x(){const o=bu("canvas");return o.style.display="block",o}const T_={};function Mu(o){o in T_||(T_[o]=!0,console.warn(o))}function tM(o,e,i){return new Promise(function(r,l){function c(){switch(o.clientWaitSync(e,o.SYNC_FLUSH_COMMANDS_BIT,0)){case o.WAIT_FAILED:l();break;case o.TIMEOUT_EXPIRED:setTimeout(c,i);break;default:r()}}setTimeout(c,i)})}function eM(o){const e=o.elements;e[2]=.5*e[2]+.5*e[3],e[6]=.5*e[6]+.5*e[7],e[10]=.5*e[10]+.5*e[11],e[14]=.5*e[14]+.5*e[15]}function nM(o){const e=o.elements;e[11]===-1?(e[10]=-e[10]-1,e[14]=-e[14]):(e[10]=-e[10],e[14]=-e[14]+1)}const b_=new oe().set(.4123908,.3575843,.1804808,.212639,.7151687,.0721923,.0193308,.1191948,.9505322),A_=new oe().set(3.2409699,-1.5373832,-.4986108,-.9692436,1.8759675,.0415551,.0556301,-.203977,1.0569715);function iM(){const o={enabled:!0,workingColorSpace:Ms,spaces:{},convert:function(l,c,h){return this.enabled===!1||c===h||!c||!h||(this.spaces[c].transfer===Be&&(l.r=la(l.r),l.g=la(l.g),l.b=la(l.b)),this.spaces[c].primaries!==this.spaces[h].primaries&&(l.applyMatrix3(this.spaces[c].toXYZ),l.applyMatrix3(this.spaces[h].fromXYZ)),this.spaces[h].transfer===Be&&(l.r=_s(l.r),l.g=_s(l.g),l.b=_s(l.b))),l},fromWorkingColorSpace:function(l,c){return this.convert(l,this.workingColorSpace,c)},toWorkingColorSpace:function(l,c){return this.convert(l,c,this.workingColorSpace)},getPrimaries:function(l){return this.spaces[l].primaries},getTransfer:function(l){return l===Ia?Eu:this.spaces[l].transfer},getLuminanceCoefficients:function(l,c=this.workingColorSpace){return l.fromArray(this.spaces[c].luminanceCoefficients)},define:function(l){Object.assign(this.spaces,l)},_getMatrix:function(l,c,h){return l.copy(this.spaces[c].toXYZ).multiply(this.spaces[h].fromXYZ)},_getDrawingBufferColorSpace:function(l){return this.spaces[l].outputColorSpaceConfig.drawingBufferColorSpace},_getUnpackColorSpace:function(l=this.workingColorSpace){return this.spaces[l].workingColorSpaceConfig.unpackColorSpace}},e=[.64,.33,.3,.6,.15,.06],i=[.2126,.7152,.0722],r=[.3127,.329];return o.define({[Ms]:{primaries:e,whitePoint:r,transfer:Eu,toXYZ:b_,fromXYZ:A_,luminanceCoefficients:i,workingColorSpaceConfig:{unpackColorSpace:li},outputColorSpaceConfig:{drawingBufferColorSpace:li}},[li]:{primaries:e,whitePoint:r,transfer:Be,toXYZ:b_,fromXYZ:A_,luminanceCoefficients:i,outputColorSpaceConfig:{drawingBufferColorSpace:li}}}),o}const Re=iM();function la(o){return o<.04045?o*.0773993808:Math.pow(o*.9478672986+.0521327014,2.4)}function _s(o){return o<.0031308?o*12.92:1.055*Math.pow(o,.41666)-.055}let ns;class aM{static getDataURL(e,i="image/png"){if(/^data:/i.test(e.src)||typeof HTMLCanvasElement>"u")return e.src;let r;if(e instanceof HTMLCanvasElement)r=e;else{ns===void 0&&(ns=bu("canvas")),ns.width=e.width,ns.height=e.height;const l=ns.getContext("2d");e instanceof ImageData?l.putImageData(e,0,0):l.drawImage(e,0,0,e.width,e.height),r=ns}return r.toDataURL(i)}static sRGBToLinear(e){if(typeof HTMLImageElement<"u"&&e instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&e instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&e instanceof ImageBitmap){const i=bu("canvas");i.width=e.width,i.height=e.height;const r=i.getContext("2d");r.drawImage(e,0,0,e.width,e.height);const l=r.getImageData(0,0,e.width,e.height),c=l.data;for(let h=0;h<c.length;h++)c[h]=la(c[h]/255)*255;return r.putImageData(l,0,0),i}else if(e.data){const i=e.data.slice(0);for(let r=0;r<i.length;r++)i instanceof Uint8Array||i instanceof Uint8ClampedArray?i[r]=Math.floor(la(i[r]/255)*255):i[r]=la(i[r]);return{data:i,width:e.width,height:e.height}}else return console.warn("THREE.ImageUtils.sRGBToLinear(): Unsupported image type. No color space conversion applied."),e}}let rM=0;class gd{constructor(e=null){this.isSource=!0,Object.defineProperty(this,"id",{value:rM++}),this.uuid=Lo(),this.data=e,this.dataReady=!0,this.version=0}set needsUpdate(e){e===!0&&this.version++}toJSON(e){const i=e===void 0||typeof e=="string";if(!i&&e.images[this.uuid]!==void 0)return e.images[this.uuid];const r={uuid:this.uuid,url:""},l=this.data;if(l!==null){let c;if(Array.isArray(l)){c=[];for(let h=0,d=l.length;h<d;h++)l[h].isDataTexture?c.push(qf(l[h].image)):c.push(qf(l[h]))}else c=qf(l);r.url=c}return i||(e.images[this.uuid]=r),r}}function qf(o){return typeof HTMLImageElement<"u"&&o instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&o instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&o instanceof ImageBitmap?aM.getDataURL(o):o.data?{data:Array.from(o.data),width:o.width,height:o.height,type:o.data.constructor.name}:(console.warn("THREE.Texture: Unable to serialize Texture."),{})}let sM=0;class Vn extends Es{constructor(e=Vn.DEFAULT_IMAGE,i=Vn.DEFAULT_MAPPING,r=vr,l=vr,c=wi,h=Sr,d=Mi,m=Ui,p=Vn.DEFAULT_ANISOTROPY,S=Ia){super(),this.isTexture=!0,Object.defineProperty(this,"id",{value:sM++}),this.uuid=Lo(),this.name="",this.source=new gd(e),this.mipmaps=[],this.mapping=i,this.channel=0,this.wrapS=r,this.wrapT=l,this.magFilter=c,this.minFilter=h,this.anisotropy=p,this.format=d,this.internalFormat=null,this.type=m,this.offset=new ye(0,0),this.repeat=new ye(1,1),this.center=new ye(0,0),this.rotation=0,this.matrixAutoUpdate=!0,this.matrix=new oe,this.generateMipmaps=!0,this.premultiplyAlpha=!1,this.flipY=!0,this.unpackAlignment=4,this.colorSpace=S,this.userData={},this.version=0,this.onUpdate=null,this.renderTarget=null,this.isRenderTargetTexture=!1,this.isTextureArray=!1,this.pmremVersion=0}get image(){return this.source.data}set image(e=null){this.source.data=e}updateMatrix(){this.matrix.setUvTransform(this.offset.x,this.offset.y,this.repeat.x,this.repeat.y,this.rotation,this.center.x,this.center.y)}clone(){return new this.constructor().copy(this)}copy(e){return this.name=e.name,this.source=e.source,this.mipmaps=e.mipmaps.slice(0),this.mapping=e.mapping,this.channel=e.channel,this.wrapS=e.wrapS,this.wrapT=e.wrapT,this.magFilter=e.magFilter,this.minFilter=e.minFilter,this.anisotropy=e.anisotropy,this.format=e.format,this.internalFormat=e.internalFormat,this.type=e.type,this.offset.copy(e.offset),this.repeat.copy(e.repeat),this.center.copy(e.center),this.rotation=e.rotation,this.matrixAutoUpdate=e.matrixAutoUpdate,this.matrix.copy(e.matrix),this.generateMipmaps=e.generateMipmaps,this.premultiplyAlpha=e.premultiplyAlpha,this.flipY=e.flipY,this.unpackAlignment=e.unpackAlignment,this.colorSpace=e.colorSpace,this.renderTarget=e.renderTarget,this.isRenderTargetTexture=e.isRenderTargetTexture,this.isTextureArray=e.isTextureArray,this.userData=JSON.parse(JSON.stringify(e.userData)),this.needsUpdate=!0,this}toJSON(e){const i=e===void 0||typeof e=="string";if(!i&&e.textures[this.uuid]!==void 0)return e.textures[this.uuid];const r={metadata:{version:4.6,type:"Texture",generator:"Texture.toJSON"},uuid:this.uuid,name:this.name,image:this.source.toJSON(e).uuid,mapping:this.mapping,channel:this.channel,repeat:[this.repeat.x,this.repeat.y],offset:[this.offset.x,this.offset.y],center:[this.center.x,this.center.y],rotation:this.rotation,wrap:[this.wrapS,this.wrapT],format:this.format,internalFormat:this.internalFormat,type:this.type,colorSpace:this.colorSpace,minFilter:this.minFilter,magFilter:this.magFilter,anisotropy:this.anisotropy,flipY:this.flipY,generateMipmaps:this.generateMipmaps,premultiplyAlpha:this.premultiplyAlpha,unpackAlignment:this.unpackAlignment};return Object.keys(this.userData).length>0&&(r.userData=this.userData),i||(e.textures[this.uuid]=r),r}dispose(){this.dispatchEvent({type:"dispose"})}transformUv(e){if(this.mapping!==T0)return e;if(e.applyMatrix3(this.matrix),e.x<0||e.x>1)switch(this.wrapS){case Lh:e.x=e.x-Math.floor(e.x);break;case vr:e.x=e.x<0?0:1;break;case Nh:Math.abs(Math.floor(e.x)%2)===1?e.x=Math.ceil(e.x)-e.x:e.x=e.x-Math.floor(e.x);break}if(e.y<0||e.y>1)switch(this.wrapT){case Lh:e.y=e.y-Math.floor(e.y);break;case vr:e.y=e.y<0?0:1;break;case Nh:Math.abs(Math.floor(e.y)%2)===1?e.y=Math.ceil(e.y)-e.y:e.y=e.y-Math.floor(e.y);break}return this.flipY&&(e.y=1-e.y),e}set needsUpdate(e){e===!0&&(this.version++,this.source.needsUpdate=!0)}set needsPMREMUpdate(e){e===!0&&this.pmremVersion++}}Vn.DEFAULT_IMAGE=null;Vn.DEFAULT_MAPPING=T0;Vn.DEFAULT_ANISOTROPY=1;class Ie{constructor(e=0,i=0,r=0,l=1){Ie.prototype.isVector4=!0,this.x=e,this.y=i,this.z=r,this.w=l}get width(){return this.z}set width(e){this.z=e}get height(){return this.w}set height(e){this.w=e}set(e,i,r,l){return this.x=e,this.y=i,this.z=r,this.w=l,this}setScalar(e){return this.x=e,this.y=e,this.z=e,this.w=e,this}setX(e){return this.x=e,this}setY(e){return this.y=e,this}setZ(e){return this.z=e,this}setW(e){return this.w=e,this}setComponent(e,i){switch(e){case 0:this.x=i;break;case 1:this.y=i;break;case 2:this.z=i;break;case 3:this.w=i;break;default:throw new Error("index is out of range: "+e)}return this}getComponent(e){switch(e){case 0:return this.x;case 1:return this.y;case 2:return this.z;case 3:return this.w;default:throw new Error("index is out of range: "+e)}}clone(){return new this.constructor(this.x,this.y,this.z,this.w)}copy(e){return this.x=e.x,this.y=e.y,this.z=e.z,this.w=e.w!==void 0?e.w:1,this}add(e){return this.x+=e.x,this.y+=e.y,this.z+=e.z,this.w+=e.w,this}addScalar(e){return this.x+=e,this.y+=e,this.z+=e,this.w+=e,this}addVectors(e,i){return this.x=e.x+i.x,this.y=e.y+i.y,this.z=e.z+i.z,this.w=e.w+i.w,this}addScaledVector(e,i){return this.x+=e.x*i,this.y+=e.y*i,this.z+=e.z*i,this.w+=e.w*i,this}sub(e){return this.x-=e.x,this.y-=e.y,this.z-=e.z,this.w-=e.w,this}subScalar(e){return this.x-=e,this.y-=e,this.z-=e,this.w-=e,this}subVectors(e,i){return this.x=e.x-i.x,this.y=e.y-i.y,this.z=e.z-i.z,this.w=e.w-i.w,this}multiply(e){return this.x*=e.x,this.y*=e.y,this.z*=e.z,this.w*=e.w,this}multiplyScalar(e){return this.x*=e,this.y*=e,this.z*=e,this.w*=e,this}applyMatrix4(e){const i=this.x,r=this.y,l=this.z,c=this.w,h=e.elements;return this.x=h[0]*i+h[4]*r+h[8]*l+h[12]*c,this.y=h[1]*i+h[5]*r+h[9]*l+h[13]*c,this.z=h[2]*i+h[6]*r+h[10]*l+h[14]*c,this.w=h[3]*i+h[7]*r+h[11]*l+h[15]*c,this}divide(e){return this.x/=e.x,this.y/=e.y,this.z/=e.z,this.w/=e.w,this}divideScalar(e){return this.multiplyScalar(1/e)}setAxisAngleFromQuaternion(e){this.w=2*Math.acos(e.w);const i=Math.sqrt(1-e.w*e.w);return i<1e-4?(this.x=1,this.y=0,this.z=0):(this.x=e.x/i,this.y=e.y/i,this.z=e.z/i),this}setAxisAngleFromRotationMatrix(e){let i,r,l,c;const m=e.elements,p=m[0],S=m[4],v=m[8],x=m[1],y=m[5],R=m[9],w=m[2],M=m[6],_=m[10];if(Math.abs(S-x)<.01&&Math.abs(v-w)<.01&&Math.abs(R-M)<.01){if(Math.abs(S+x)<.1&&Math.abs(v+w)<.1&&Math.abs(R+M)<.1&&Math.abs(p+y+_-3)<.1)return this.set(1,0,0,0),this;i=Math.PI;const U=(p+1)/2,C=(y+1)/2,G=(_+1)/2,I=(S+x)/4,O=(v+w)/4,V=(R+M)/4;return U>C&&U>G?U<.01?(r=0,l=.707106781,c=.707106781):(r=Math.sqrt(U),l=I/r,c=O/r):C>G?C<.01?(r=.707106781,l=0,c=.707106781):(l=Math.sqrt(C),r=I/l,c=V/l):G<.01?(r=.707106781,l=.707106781,c=0):(c=Math.sqrt(G),r=O/c,l=V/c),this.set(r,l,c,i),this}let L=Math.sqrt((M-R)*(M-R)+(v-w)*(v-w)+(x-S)*(x-S));return Math.abs(L)<.001&&(L=1),this.x=(M-R)/L,this.y=(v-w)/L,this.z=(x-S)/L,this.w=Math.acos((p+y+_-1)/2),this}setFromMatrixPosition(e){const i=e.elements;return this.x=i[12],this.y=i[13],this.z=i[14],this.w=i[15],this}min(e){return this.x=Math.min(this.x,e.x),this.y=Math.min(this.y,e.y),this.z=Math.min(this.z,e.z),this.w=Math.min(this.w,e.w),this}max(e){return this.x=Math.max(this.x,e.x),this.y=Math.max(this.y,e.y),this.z=Math.max(this.z,e.z),this.w=Math.max(this.w,e.w),this}clamp(e,i){return this.x=Se(this.x,e.x,i.x),this.y=Se(this.y,e.y,i.y),this.z=Se(this.z,e.z,i.z),this.w=Se(this.w,e.w,i.w),this}clampScalar(e,i){return this.x=Se(this.x,e,i),this.y=Se(this.y,e,i),this.z=Se(this.z,e,i),this.w=Se(this.w,e,i),this}clampLength(e,i){const r=this.length();return this.divideScalar(r||1).multiplyScalar(Se(r,e,i))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this.z=Math.floor(this.z),this.w=Math.floor(this.w),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this.z=Math.ceil(this.z),this.w=Math.ceil(this.w),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this.z=Math.round(this.z),this.w=Math.round(this.w),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this.z=Math.trunc(this.z),this.w=Math.trunc(this.w),this}negate(){return this.x=-this.x,this.y=-this.y,this.z=-this.z,this.w=-this.w,this}dot(e){return this.x*e.x+this.y*e.y+this.z*e.z+this.w*e.w}lengthSq(){return this.x*this.x+this.y*this.y+this.z*this.z+this.w*this.w}length(){return Math.sqrt(this.x*this.x+this.y*this.y+this.z*this.z+this.w*this.w)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)+Math.abs(this.z)+Math.abs(this.w)}normalize(){return this.divideScalar(this.length()||1)}setLength(e){return this.normalize().multiplyScalar(e)}lerp(e,i){return this.x+=(e.x-this.x)*i,this.y+=(e.y-this.y)*i,this.z+=(e.z-this.z)*i,this.w+=(e.w-this.w)*i,this}lerpVectors(e,i,r){return this.x=e.x+(i.x-e.x)*r,this.y=e.y+(i.y-e.y)*r,this.z=e.z+(i.z-e.z)*r,this.w=e.w+(i.w-e.w)*r,this}equals(e){return e.x===this.x&&e.y===this.y&&e.z===this.z&&e.w===this.w}fromArray(e,i=0){return this.x=e[i],this.y=e[i+1],this.z=e[i+2],this.w=e[i+3],this}toArray(e=[],i=0){return e[i]=this.x,e[i+1]=this.y,e[i+2]=this.z,e[i+3]=this.w,e}fromBufferAttribute(e,i){return this.x=e.getX(i),this.y=e.getY(i),this.z=e.getZ(i),this.w=e.getW(i),this}random(){return this.x=Math.random(),this.y=Math.random(),this.z=Math.random(),this.w=Math.random(),this}*[Symbol.iterator](){yield this.x,yield this.y,yield this.z,yield this.w}}class oM extends Es{constructor(e=1,i=1,r={}){super(),this.isRenderTarget=!0,this.width=e,this.height=i,this.depth=r.depth?r.depth:1,this.scissor=new Ie(0,0,e,i),this.scissorTest=!1,this.viewport=new Ie(0,0,e,i);const l={width:e,height:i,depth:this.depth};r=Object.assign({generateMipmaps:!1,internalFormat:null,minFilter:wi,depthBuffer:!0,stencilBuffer:!1,resolveDepthBuffer:!0,resolveStencilBuffer:!0,depthTexture:null,samples:0,count:1,multiview:!1},r);const c=new Vn(l,r.mapping,r.wrapS,r.wrapT,r.magFilter,r.minFilter,r.format,r.type,r.anisotropy,r.colorSpace);c.flipY=!1,c.generateMipmaps=r.generateMipmaps,c.internalFormat=r.internalFormat,this.textures=[];const h=r.count;for(let d=0;d<h;d++)this.textures[d]=c.clone(),this.textures[d].isRenderTargetTexture=!0,this.textures[d].renderTarget=this;this.depthBuffer=r.depthBuffer,this.stencilBuffer=r.stencilBuffer,this.resolveDepthBuffer=r.resolveDepthBuffer,this.resolveStencilBuffer=r.resolveStencilBuffer,this._depthTexture=null,this.depthTexture=r.depthTexture,this.samples=r.samples,this.multiview=r.multiview}get texture(){return this.textures[0]}set texture(e){this.textures[0]=e}set depthTexture(e){this._depthTexture!==null&&(this._depthTexture.renderTarget=null),e!==null&&(e.renderTarget=this),this._depthTexture=e}get depthTexture(){return this._depthTexture}setSize(e,i,r=1){if(this.width!==e||this.height!==i||this.depth!==r){this.width=e,this.height=i,this.depth=r;for(let l=0,c=this.textures.length;l<c;l++)this.textures[l].image.width=e,this.textures[l].image.height=i,this.textures[l].image.depth=r;this.dispose()}this.viewport.set(0,0,e,i),this.scissor.set(0,0,e,i)}clone(){return new this.constructor().copy(this)}copy(e){this.width=e.width,this.height=e.height,this.depth=e.depth,this.scissor.copy(e.scissor),this.scissorTest=e.scissorTest,this.viewport.copy(e.viewport),this.textures.length=0;for(let i=0,r=e.textures.length;i<r;i++){this.textures[i]=e.textures[i].clone(),this.textures[i].isRenderTargetTexture=!0,this.textures[i].renderTarget=this;const l=Object.assign({},e.textures[i].image);this.textures[i].source=new gd(l)}return this.depthBuffer=e.depthBuffer,this.stencilBuffer=e.stencilBuffer,this.resolveDepthBuffer=e.resolveDepthBuffer,this.resolveStencilBuffer=e.resolveStencilBuffer,e.depthTexture!==null&&(this.depthTexture=e.depthTexture.clone()),this.samples=e.samples,this}dispose(){this.dispatchEvent({type:"dispose"})}}class Mr extends oM{constructor(e=1,i=1,r={}){super(e,i,r),this.isWebGLRenderTarget=!0}}class P0 extends Vn{constructor(e=null,i=1,r=1,l=1){super(null),this.isDataArrayTexture=!0,this.image={data:e,width:i,height:r,depth:l},this.magFilter=yi,this.minFilter=yi,this.wrapR=vr,this.generateMipmaps=!1,this.flipY=!1,this.unpackAlignment=1,this.layerUpdates=new Set}addLayerUpdate(e){this.layerUpdates.add(e)}clearLayerUpdates(){this.layerUpdates.clear()}}class lM extends Vn{constructor(e=null,i=1,r=1,l=1){super(null),this.isData3DTexture=!0,this.image={data:e,width:i,height:r,depth:l},this.magFilter=yi,this.minFilter=yi,this.wrapR=vr,this.generateMipmaps=!1,this.flipY=!1,this.unpackAlignment=1}}class No{constructor(e=0,i=0,r=0,l=1){this.isQuaternion=!0,this._x=e,this._y=i,this._z=r,this._w=l}static slerpFlat(e,i,r,l,c,h,d){let m=r[l+0],p=r[l+1],S=r[l+2],v=r[l+3];const x=c[h+0],y=c[h+1],R=c[h+2],w=c[h+3];if(d===0){e[i+0]=m,e[i+1]=p,e[i+2]=S,e[i+3]=v;return}if(d===1){e[i+0]=x,e[i+1]=y,e[i+2]=R,e[i+3]=w;return}if(v!==w||m!==x||p!==y||S!==R){let M=1-d;const _=m*x+p*y+S*R+v*w,L=_>=0?1:-1,U=1-_*_;if(U>Number.EPSILON){const G=Math.sqrt(U),I=Math.atan2(G,_*L);M=Math.sin(M*I)/G,d=Math.sin(d*I)/G}const C=d*L;if(m=m*M+x*C,p=p*M+y*C,S=S*M+R*C,v=v*M+w*C,M===1-d){const G=1/Math.sqrt(m*m+p*p+S*S+v*v);m*=G,p*=G,S*=G,v*=G}}e[i]=m,e[i+1]=p,e[i+2]=S,e[i+3]=v}static multiplyQuaternionsFlat(e,i,r,l,c,h){const d=r[l],m=r[l+1],p=r[l+2],S=r[l+3],v=c[h],x=c[h+1],y=c[h+2],R=c[h+3];return e[i]=d*R+S*v+m*y-p*x,e[i+1]=m*R+S*x+p*v-d*y,e[i+2]=p*R+S*y+d*x-m*v,e[i+3]=S*R-d*v-m*x-p*y,e}get x(){return this._x}set x(e){this._x=e,this._onChangeCallback()}get y(){return this._y}set y(e){this._y=e,this._onChangeCallback()}get z(){return this._z}set z(e){this._z=e,this._onChangeCallback()}get w(){return this._w}set w(e){this._w=e,this._onChangeCallback()}set(e,i,r,l){return this._x=e,this._y=i,this._z=r,this._w=l,this._onChangeCallback(),this}clone(){return new this.constructor(this._x,this._y,this._z,this._w)}copy(e){return this._x=e.x,this._y=e.y,this._z=e.z,this._w=e.w,this._onChangeCallback(),this}setFromEuler(e,i=!0){const r=e._x,l=e._y,c=e._z,h=e._order,d=Math.cos,m=Math.sin,p=d(r/2),S=d(l/2),v=d(c/2),x=m(r/2),y=m(l/2),R=m(c/2);switch(h){case"XYZ":this._x=x*S*v+p*y*R,this._y=p*y*v-x*S*R,this._z=p*S*R+x*y*v,this._w=p*S*v-x*y*R;break;case"YXZ":this._x=x*S*v+p*y*R,this._y=p*y*v-x*S*R,this._z=p*S*R-x*y*v,this._w=p*S*v+x*y*R;break;case"ZXY":this._x=x*S*v-p*y*R,this._y=p*y*v+x*S*R,this._z=p*S*R+x*y*v,this._w=p*S*v-x*y*R;break;case"ZYX":this._x=x*S*v-p*y*R,this._y=p*y*v+x*S*R,this._z=p*S*R-x*y*v,this._w=p*S*v+x*y*R;break;case"YZX":this._x=x*S*v+p*y*R,this._y=p*y*v+x*S*R,this._z=p*S*R-x*y*v,this._w=p*S*v-x*y*R;break;case"XZY":this._x=x*S*v-p*y*R,this._y=p*y*v-x*S*R,this._z=p*S*R+x*y*v,this._w=p*S*v+x*y*R;break;default:console.warn("THREE.Quaternion: .setFromEuler() encountered an unknown order: "+h)}return i===!0&&this._onChangeCallback(),this}setFromAxisAngle(e,i){const r=i/2,l=Math.sin(r);return this._x=e.x*l,this._y=e.y*l,this._z=e.z*l,this._w=Math.cos(r),this._onChangeCallback(),this}setFromRotationMatrix(e){const i=e.elements,r=i[0],l=i[4],c=i[8],h=i[1],d=i[5],m=i[9],p=i[2],S=i[6],v=i[10],x=r+d+v;if(x>0){const y=.5/Math.sqrt(x+1);this._w=.25/y,this._x=(S-m)*y,this._y=(c-p)*y,this._z=(h-l)*y}else if(r>d&&r>v){const y=2*Math.sqrt(1+r-d-v);this._w=(S-m)/y,this._x=.25*y,this._y=(l+h)/y,this._z=(c+p)/y}else if(d>v){const y=2*Math.sqrt(1+d-r-v);this._w=(c-p)/y,this._x=(l+h)/y,this._y=.25*y,this._z=(m+S)/y}else{const y=2*Math.sqrt(1+v-r-d);this._w=(h-l)/y,this._x=(c+p)/y,this._y=(m+S)/y,this._z=.25*y}return this._onChangeCallback(),this}setFromUnitVectors(e,i){let r=e.dot(i)+1;return r<Number.EPSILON?(r=0,Math.abs(e.x)>Math.abs(e.z)?(this._x=-e.y,this._y=e.x,this._z=0,this._w=r):(this._x=0,this._y=-e.z,this._z=e.y,this._w=r)):(this._x=e.y*i.z-e.z*i.y,this._y=e.z*i.x-e.x*i.z,this._z=e.x*i.y-e.y*i.x,this._w=r),this.normalize()}angleTo(e){return 2*Math.acos(Math.abs(Se(this.dot(e),-1,1)))}rotateTowards(e,i){const r=this.angleTo(e);if(r===0)return this;const l=Math.min(1,i/r);return this.slerp(e,l),this}identity(){return this.set(0,0,0,1)}invert(){return this.conjugate()}conjugate(){return this._x*=-1,this._y*=-1,this._z*=-1,this._onChangeCallback(),this}dot(e){return this._x*e._x+this._y*e._y+this._z*e._z+this._w*e._w}lengthSq(){return this._x*this._x+this._y*this._y+this._z*this._z+this._w*this._w}length(){return Math.sqrt(this._x*this._x+this._y*this._y+this._z*this._z+this._w*this._w)}normalize(){let e=this.length();return e===0?(this._x=0,this._y=0,this._z=0,this._w=1):(e=1/e,this._x=this._x*e,this._y=this._y*e,this._z=this._z*e,this._w=this._w*e),this._onChangeCallback(),this}multiply(e){return this.multiplyQuaternions(this,e)}premultiply(e){return this.multiplyQuaternions(e,this)}multiplyQuaternions(e,i){const r=e._x,l=e._y,c=e._z,h=e._w,d=i._x,m=i._y,p=i._z,S=i._w;return this._x=r*S+h*d+l*p-c*m,this._y=l*S+h*m+c*d-r*p,this._z=c*S+h*p+r*m-l*d,this._w=h*S-r*d-l*m-c*p,this._onChangeCallback(),this}slerp(e,i){if(i===0)return this;if(i===1)return this.copy(e);const r=this._x,l=this._y,c=this._z,h=this._w;let d=h*e._w+r*e._x+l*e._y+c*e._z;if(d<0?(this._w=-e._w,this._x=-e._x,this._y=-e._y,this._z=-e._z,d=-d):this.copy(e),d>=1)return this._w=h,this._x=r,this._y=l,this._z=c,this;const m=1-d*d;if(m<=Number.EPSILON){const y=1-i;return this._w=y*h+i*this._w,this._x=y*r+i*this._x,this._y=y*l+i*this._y,this._z=y*c+i*this._z,this.normalize(),this}const p=Math.sqrt(m),S=Math.atan2(p,d),v=Math.sin((1-i)*S)/p,x=Math.sin(i*S)/p;return this._w=h*v+this._w*x,this._x=r*v+this._x*x,this._y=l*v+this._y*x,this._z=c*v+this._z*x,this._onChangeCallback(),this}slerpQuaternions(e,i,r){return this.copy(e).slerp(i,r)}random(){const e=2*Math.PI*Math.random(),i=2*Math.PI*Math.random(),r=Math.random(),l=Math.sqrt(1-r),c=Math.sqrt(r);return this.set(l*Math.sin(e),l*Math.cos(e),c*Math.sin(i),c*Math.cos(i))}equals(e){return e._x===this._x&&e._y===this._y&&e._z===this._z&&e._w===this._w}fromArray(e,i=0){return this._x=e[i],this._y=e[i+1],this._z=e[i+2],this._w=e[i+3],this._onChangeCallback(),this}toArray(e=[],i=0){return e[i]=this._x,e[i+1]=this._y,e[i+2]=this._z,e[i+3]=this._w,e}fromBufferAttribute(e,i){return this._x=e.getX(i),this._y=e.getY(i),this._z=e.getZ(i),this._w=e.getW(i),this._onChangeCallback(),this}toJSON(){return this.toArray()}_onChange(e){return this._onChangeCallback=e,this}_onChangeCallback(){}*[Symbol.iterator](){yield this._x,yield this._y,yield this._z,yield this._w}}class Q{constructor(e=0,i=0,r=0){Q.prototype.isVector3=!0,this.x=e,this.y=i,this.z=r}set(e,i,r){return r===void 0&&(r=this.z),this.x=e,this.y=i,this.z=r,this}setScalar(e){return this.x=e,this.y=e,this.z=e,this}setX(e){return this.x=e,this}setY(e){return this.y=e,this}setZ(e){return this.z=e,this}setComponent(e,i){switch(e){case 0:this.x=i;break;case 1:this.y=i;break;case 2:this.z=i;break;default:throw new Error("index is out of range: "+e)}return this}getComponent(e){switch(e){case 0:return this.x;case 1:return this.y;case 2:return this.z;default:throw new Error("index is out of range: "+e)}}clone(){return new this.constructor(this.x,this.y,this.z)}copy(e){return this.x=e.x,this.y=e.y,this.z=e.z,this}add(e){return this.x+=e.x,this.y+=e.y,this.z+=e.z,this}addScalar(e){return this.x+=e,this.y+=e,this.z+=e,this}addVectors(e,i){return this.x=e.x+i.x,this.y=e.y+i.y,this.z=e.z+i.z,this}addScaledVector(e,i){return this.x+=e.x*i,this.y+=e.y*i,this.z+=e.z*i,this}sub(e){return this.x-=e.x,this.y-=e.y,this.z-=e.z,this}subScalar(e){return this.x-=e,this.y-=e,this.z-=e,this}subVectors(e,i){return this.x=e.x-i.x,this.y=e.y-i.y,this.z=e.z-i.z,this}multiply(e){return this.x*=e.x,this.y*=e.y,this.z*=e.z,this}multiplyScalar(e){return this.x*=e,this.y*=e,this.z*=e,this}multiplyVectors(e,i){return this.x=e.x*i.x,this.y=e.y*i.y,this.z=e.z*i.z,this}applyEuler(e){return this.applyQuaternion(R_.setFromEuler(e))}applyAxisAngle(e,i){return this.applyQuaternion(R_.setFromAxisAngle(e,i))}applyMatrix3(e){const i=this.x,r=this.y,l=this.z,c=e.elements;return this.x=c[0]*i+c[3]*r+c[6]*l,this.y=c[1]*i+c[4]*r+c[7]*l,this.z=c[2]*i+c[5]*r+c[8]*l,this}applyNormalMatrix(e){return this.applyMatrix3(e).normalize()}applyMatrix4(e){const i=this.x,r=this.y,l=this.z,c=e.elements,h=1/(c[3]*i+c[7]*r+c[11]*l+c[15]);return this.x=(c[0]*i+c[4]*r+c[8]*l+c[12])*h,this.y=(c[1]*i+c[5]*r+c[9]*l+c[13])*h,this.z=(c[2]*i+c[6]*r+c[10]*l+c[14])*h,this}applyQuaternion(e){const i=this.x,r=this.y,l=this.z,c=e.x,h=e.y,d=e.z,m=e.w,p=2*(h*l-d*r),S=2*(d*i-c*l),v=2*(c*r-h*i);return this.x=i+m*p+h*v-d*S,this.y=r+m*S+d*p-c*v,this.z=l+m*v+c*S-h*p,this}project(e){return this.applyMatrix4(e.matrixWorldInverse).applyMatrix4(e.projectionMatrix)}unproject(e){return this.applyMatrix4(e.projectionMatrixInverse).applyMatrix4(e.matrixWorld)}transformDirection(e){const i=this.x,r=this.y,l=this.z,c=e.elements;return this.x=c[0]*i+c[4]*r+c[8]*l,this.y=c[1]*i+c[5]*r+c[9]*l,this.z=c[2]*i+c[6]*r+c[10]*l,this.normalize()}divide(e){return this.x/=e.x,this.y/=e.y,this.z/=e.z,this}divideScalar(e){return this.multiplyScalar(1/e)}min(e){return this.x=Math.min(this.x,e.x),this.y=Math.min(this.y,e.y),this.z=Math.min(this.z,e.z),this}max(e){return this.x=Math.max(this.x,e.x),this.y=Math.max(this.y,e.y),this.z=Math.max(this.z,e.z),this}clamp(e,i){return this.x=Se(this.x,e.x,i.x),this.y=Se(this.y,e.y,i.y),this.z=Se(this.z,e.z,i.z),this}clampScalar(e,i){return this.x=Se(this.x,e,i),this.y=Se(this.y,e,i),this.z=Se(this.z,e,i),this}clampLength(e,i){const r=this.length();return this.divideScalar(r||1).multiplyScalar(Se(r,e,i))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this.z=Math.floor(this.z),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this.z=Math.ceil(this.z),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this.z=Math.round(this.z),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this.z=Math.trunc(this.z),this}negate(){return this.x=-this.x,this.y=-this.y,this.z=-this.z,this}dot(e){return this.x*e.x+this.y*e.y+this.z*e.z}lengthSq(){return this.x*this.x+this.y*this.y+this.z*this.z}length(){return Math.sqrt(this.x*this.x+this.y*this.y+this.z*this.z)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)+Math.abs(this.z)}normalize(){return this.divideScalar(this.length()||1)}setLength(e){return this.normalize().multiplyScalar(e)}lerp(e,i){return this.x+=(e.x-this.x)*i,this.y+=(e.y-this.y)*i,this.z+=(e.z-this.z)*i,this}lerpVectors(e,i,r){return this.x=e.x+(i.x-e.x)*r,this.y=e.y+(i.y-e.y)*r,this.z=e.z+(i.z-e.z)*r,this}cross(e){return this.crossVectors(this,e)}crossVectors(e,i){const r=e.x,l=e.y,c=e.z,h=i.x,d=i.y,m=i.z;return this.x=l*m-c*d,this.y=c*h-r*m,this.z=r*d-l*h,this}projectOnVector(e){const i=e.lengthSq();if(i===0)return this.set(0,0,0);const r=e.dot(this)/i;return this.copy(e).multiplyScalar(r)}projectOnPlane(e){return Yf.copy(this).projectOnVector(e),this.sub(Yf)}reflect(e){return this.sub(Yf.copy(e).multiplyScalar(2*this.dot(e)))}angleTo(e){const i=Math.sqrt(this.lengthSq()*e.lengthSq());if(i===0)return Math.PI/2;const r=this.dot(e)/i;return Math.acos(Se(r,-1,1))}distanceTo(e){return Math.sqrt(this.distanceToSquared(e))}distanceToSquared(e){const i=this.x-e.x,r=this.y-e.y,l=this.z-e.z;return i*i+r*r+l*l}manhattanDistanceTo(e){return Math.abs(this.x-e.x)+Math.abs(this.y-e.y)+Math.abs(this.z-e.z)}setFromSpherical(e){return this.setFromSphericalCoords(e.radius,e.phi,e.theta)}setFromSphericalCoords(e,i,r){const l=Math.sin(i)*e;return this.x=l*Math.sin(r),this.y=Math.cos(i)*e,this.z=l*Math.cos(r),this}setFromCylindrical(e){return this.setFromCylindricalCoords(e.radius,e.theta,e.y)}setFromCylindricalCoords(e,i,r){return this.x=e*Math.sin(i),this.y=r,this.z=e*Math.cos(i),this}setFromMatrixPosition(e){const i=e.elements;return this.x=i[12],this.y=i[13],this.z=i[14],this}setFromMatrixScale(e){const i=this.setFromMatrixColumn(e,0).length(),r=this.setFromMatrixColumn(e,1).length(),l=this.setFromMatrixColumn(e,2).length();return this.x=i,this.y=r,this.z=l,this}setFromMatrixColumn(e,i){return this.fromArray(e.elements,i*4)}setFromMatrix3Column(e,i){return this.fromArray(e.elements,i*3)}setFromEuler(e){return this.x=e._x,this.y=e._y,this.z=e._z,this}setFromColor(e){return this.x=e.r,this.y=e.g,this.z=e.b,this}equals(e){return e.x===this.x&&e.y===this.y&&e.z===this.z}fromArray(e,i=0){return this.x=e[i],this.y=e[i+1],this.z=e[i+2],this}toArray(e=[],i=0){return e[i]=this.x,e[i+1]=this.y,e[i+2]=this.z,e}fromBufferAttribute(e,i){return this.x=e.getX(i),this.y=e.getY(i),this.z=e.getZ(i),this}random(){return this.x=Math.random(),this.y=Math.random(),this.z=Math.random(),this}randomDirection(){const e=Math.random()*Math.PI*2,i=Math.random()*2-1,r=Math.sqrt(1-i*i);return this.x=r*Math.cos(e),this.y=i,this.z=r*Math.sin(e),this}*[Symbol.iterator](){yield this.x,yield this.y,yield this.z}}const Yf=new Q,R_=new No;class Oo{constructor(e=new Q(1/0,1/0,1/0),i=new Q(-1/0,-1/0,-1/0)){this.isBox3=!0,this.min=e,this.max=i}set(e,i){return this.min.copy(e),this.max.copy(i),this}setFromArray(e){this.makeEmpty();for(let i=0,r=e.length;i<r;i+=3)this.expandByPoint(gi.fromArray(e,i));return this}setFromBufferAttribute(e){this.makeEmpty();for(let i=0,r=e.count;i<r;i++)this.expandByPoint(gi.fromBufferAttribute(e,i));return this}setFromPoints(e){this.makeEmpty();for(let i=0,r=e.length;i<r;i++)this.expandByPoint(e[i]);return this}setFromCenterAndSize(e,i){const r=gi.copy(i).multiplyScalar(.5);return this.min.copy(e).sub(r),this.max.copy(e).add(r),this}setFromObject(e,i=!1){return this.makeEmpty(),this.expandByObject(e,i)}clone(){return new this.constructor().copy(this)}copy(e){return this.min.copy(e.min),this.max.copy(e.max),this}makeEmpty(){return this.min.x=this.min.y=this.min.z=1/0,this.max.x=this.max.y=this.max.z=-1/0,this}isEmpty(){return this.max.x<this.min.x||this.max.y<this.min.y||this.max.z<this.min.z}getCenter(e){return this.isEmpty()?e.set(0,0,0):e.addVectors(this.min,this.max).multiplyScalar(.5)}getSize(e){return this.isEmpty()?e.set(0,0,0):e.subVectors(this.max,this.min)}expandByPoint(e){return this.min.min(e),this.max.max(e),this}expandByVector(e){return this.min.sub(e),this.max.add(e),this}expandByScalar(e){return this.min.addScalar(-e),this.max.addScalar(e),this}expandByObject(e,i=!1){e.updateWorldMatrix(!1,!1);const r=e.geometry;if(r!==void 0){const c=r.getAttribute("position");if(i===!0&&c!==void 0&&e.isInstancedMesh!==!0)for(let h=0,d=c.count;h<d;h++)e.isMesh===!0?e.getVertexPosition(h,gi):gi.fromBufferAttribute(c,h),gi.applyMatrix4(e.matrixWorld),this.expandByPoint(gi);else e.boundingBox!==void 0?(e.boundingBox===null&&e.computeBoundingBox(),jl.copy(e.boundingBox)):(r.boundingBox===null&&r.computeBoundingBox(),jl.copy(r.boundingBox)),jl.applyMatrix4(e.matrixWorld),this.union(jl)}const l=e.children;for(let c=0,h=l.length;c<h;c++)this.expandByObject(l[c],i);return this}containsPoint(e){return e.x>=this.min.x&&e.x<=this.max.x&&e.y>=this.min.y&&e.y<=this.max.y&&e.z>=this.min.z&&e.z<=this.max.z}containsBox(e){return this.min.x<=e.min.x&&e.max.x<=this.max.x&&this.min.y<=e.min.y&&e.max.y<=this.max.y&&this.min.z<=e.min.z&&e.max.z<=this.max.z}getParameter(e,i){return i.set((e.x-this.min.x)/(this.max.x-this.min.x),(e.y-this.min.y)/(this.max.y-this.min.y),(e.z-this.min.z)/(this.max.z-this.min.z))}intersectsBox(e){return e.max.x>=this.min.x&&e.min.x<=this.max.x&&e.max.y>=this.min.y&&e.min.y<=this.max.y&&e.max.z>=this.min.z&&e.min.z<=this.max.z}intersectsSphere(e){return this.clampPoint(e.center,gi),gi.distanceToSquared(e.center)<=e.radius*e.radius}intersectsPlane(e){let i,r;return e.normal.x>0?(i=e.normal.x*this.min.x,r=e.normal.x*this.max.x):(i=e.normal.x*this.max.x,r=e.normal.x*this.min.x),e.normal.y>0?(i+=e.normal.y*this.min.y,r+=e.normal.y*this.max.y):(i+=e.normal.y*this.max.y,r+=e.normal.y*this.min.y),e.normal.z>0?(i+=e.normal.z*this.min.z,r+=e.normal.z*this.max.z):(i+=e.normal.z*this.max.z,r+=e.normal.z*this.min.z),i<=-e.constant&&r>=-e.constant}intersectsTriangle(e){if(this.isEmpty())return!1;this.getCenter(Mo),Zl.subVectors(this.max,Mo),is.subVectors(e.a,Mo),as.subVectors(e.b,Mo),rs.subVectors(e.c,Mo),La.subVectors(as,is),Na.subVectors(rs,as),lr.subVectors(is,rs);let i=[0,-La.z,La.y,0,-Na.z,Na.y,0,-lr.z,lr.y,La.z,0,-La.x,Na.z,0,-Na.x,lr.z,0,-lr.x,-La.y,La.x,0,-Na.y,Na.x,0,-lr.y,lr.x,0];return!jf(i,is,as,rs,Zl)||(i=[1,0,0,0,1,0,0,0,1],!jf(i,is,as,rs,Zl))?!1:(Kl.crossVectors(La,Na),i=[Kl.x,Kl.y,Kl.z],jf(i,is,as,rs,Zl))}clampPoint(e,i){return i.copy(e).clamp(this.min,this.max)}distanceToPoint(e){return this.clampPoint(e,gi).distanceTo(e)}getBoundingSphere(e){return this.isEmpty()?e.makeEmpty():(this.getCenter(e.center),e.radius=this.getSize(gi).length()*.5),e}intersect(e){return this.min.max(e.min),this.max.min(e.max),this.isEmpty()&&this.makeEmpty(),this}union(e){return this.min.min(e.min),this.max.max(e.max),this}applyMatrix4(e){return this.isEmpty()?this:(Ji[0].set(this.min.x,this.min.y,this.min.z).applyMatrix4(e),Ji[1].set(this.min.x,this.min.y,this.max.z).applyMatrix4(e),Ji[2].set(this.min.x,this.max.y,this.min.z).applyMatrix4(e),Ji[3].set(this.min.x,this.max.y,this.max.z).applyMatrix4(e),Ji[4].set(this.max.x,this.min.y,this.min.z).applyMatrix4(e),Ji[5].set(this.max.x,this.min.y,this.max.z).applyMatrix4(e),Ji[6].set(this.max.x,this.max.y,this.min.z).applyMatrix4(e),Ji[7].set(this.max.x,this.max.y,this.max.z).applyMatrix4(e),this.setFromPoints(Ji),this)}translate(e){return this.min.add(e),this.max.add(e),this}equals(e){return e.min.equals(this.min)&&e.max.equals(this.max)}}const Ji=[new Q,new Q,new Q,new Q,new Q,new Q,new Q,new Q],gi=new Q,jl=new Oo,is=new Q,as=new Q,rs=new Q,La=new Q,Na=new Q,lr=new Q,Mo=new Q,Zl=new Q,Kl=new Q,ur=new Q;function jf(o,e,i,r,l){for(let c=0,h=o.length-3;c<=h;c+=3){ur.fromArray(o,c);const d=l.x*Math.abs(ur.x)+l.y*Math.abs(ur.y)+l.z*Math.abs(ur.z),m=e.dot(ur),p=i.dot(ur),S=r.dot(ur);if(Math.max(-Math.max(m,p,S),Math.min(m,p,S))>d)return!1}return!0}const uM=new Oo,yo=new Q,Zf=new Q;class _d{constructor(e=new Q,i=-1){this.isSphere=!0,this.center=e,this.radius=i}set(e,i){return this.center.copy(e),this.radius=i,this}setFromPoints(e,i){const r=this.center;i!==void 0?r.copy(i):uM.setFromPoints(e).getCenter(r);let l=0;for(let c=0,h=e.length;c<h;c++)l=Math.max(l,r.distanceToSquared(e[c]));return this.radius=Math.sqrt(l),this}copy(e){return this.center.copy(e.center),this.radius=e.radius,this}isEmpty(){return this.radius<0}makeEmpty(){return this.center.set(0,0,0),this.radius=-1,this}containsPoint(e){return e.distanceToSquared(this.center)<=this.radius*this.radius}distanceToPoint(e){return e.distanceTo(this.center)-this.radius}intersectsSphere(e){const i=this.radius+e.radius;return e.center.distanceToSquared(this.center)<=i*i}intersectsBox(e){return e.intersectsSphere(this)}intersectsPlane(e){return Math.abs(e.distanceToPoint(this.center))<=this.radius}clampPoint(e,i){const r=this.center.distanceToSquared(e);return i.copy(e),r>this.radius*this.radius&&(i.sub(this.center).normalize(),i.multiplyScalar(this.radius).add(this.center)),i}getBoundingBox(e){return this.isEmpty()?(e.makeEmpty(),e):(e.set(this.center,this.center),e.expandByScalar(this.radius),e)}applyMatrix4(e){return this.center.applyMatrix4(e),this.radius=this.radius*e.getMaxScaleOnAxis(),this}translate(e){return this.center.add(e),this}expandByPoint(e){if(this.isEmpty())return this.center.copy(e),this.radius=0,this;yo.subVectors(e,this.center);const i=yo.lengthSq();if(i>this.radius*this.radius){const r=Math.sqrt(i),l=(r-this.radius)*.5;this.center.addScaledVector(yo,l/r),this.radius+=l}return this}union(e){return e.isEmpty()?this:this.isEmpty()?(this.copy(e),this):(this.center.equals(e.center)===!0?this.radius=Math.max(this.radius,e.radius):(Zf.subVectors(e.center,this.center).setLength(e.radius),this.expandByPoint(yo.copy(e.center).add(Zf)),this.expandByPoint(yo.copy(e.center).sub(Zf))),this)}equals(e){return e.center.equals(this.center)&&e.radius===this.radius}clone(){return new this.constructor().copy(this)}}const $i=new Q,Kf=new Q,Ql=new Q,Oa=new Q,Qf=new Q,Jl=new Q,Jf=new Q;class cM{constructor(e=new Q,i=new Q(0,0,-1)){this.origin=e,this.direction=i}set(e,i){return this.origin.copy(e),this.direction.copy(i),this}copy(e){return this.origin.copy(e.origin),this.direction.copy(e.direction),this}at(e,i){return i.copy(this.origin).addScaledVector(this.direction,e)}lookAt(e){return this.direction.copy(e).sub(this.origin).normalize(),this}recast(e){return this.origin.copy(this.at(e,$i)),this}closestPointToPoint(e,i){i.subVectors(e,this.origin);const r=i.dot(this.direction);return r<0?i.copy(this.origin):i.copy(this.origin).addScaledVector(this.direction,r)}distanceToPoint(e){return Math.sqrt(this.distanceSqToPoint(e))}distanceSqToPoint(e){const i=$i.subVectors(e,this.origin).dot(this.direction);return i<0?this.origin.distanceToSquared(e):($i.copy(this.origin).addScaledVector(this.direction,i),$i.distanceToSquared(e))}distanceSqToSegment(e,i,r,l){Kf.copy(e).add(i).multiplyScalar(.5),Ql.copy(i).sub(e).normalize(),Oa.copy(this.origin).sub(Kf);const c=e.distanceTo(i)*.5,h=-this.direction.dot(Ql),d=Oa.dot(this.direction),m=-Oa.dot(Ql),p=Oa.lengthSq(),S=Math.abs(1-h*h);let v,x,y,R;if(S>0)if(v=h*m-d,x=h*d-m,R=c*S,v>=0)if(x>=-R)if(x<=R){const w=1/S;v*=w,x*=w,y=v*(v+h*x+2*d)+x*(h*v+x+2*m)+p}else x=c,v=Math.max(0,-(h*x+d)),y=-v*v+x*(x+2*m)+p;else x=-c,v=Math.max(0,-(h*x+d)),y=-v*v+x*(x+2*m)+p;else x<=-R?(v=Math.max(0,-(-h*c+d)),x=v>0?-c:Math.min(Math.max(-c,-m),c),y=-v*v+x*(x+2*m)+p):x<=R?(v=0,x=Math.min(Math.max(-c,-m),c),y=x*(x+2*m)+p):(v=Math.max(0,-(h*c+d)),x=v>0?c:Math.min(Math.max(-c,-m),c),y=-v*v+x*(x+2*m)+p);else x=h>0?-c:c,v=Math.max(0,-(h*x+d)),y=-v*v+x*(x+2*m)+p;return r&&r.copy(this.origin).addScaledVector(this.direction,v),l&&l.copy(Kf).addScaledVector(Ql,x),y}intersectSphere(e,i){$i.subVectors(e.center,this.origin);const r=$i.dot(this.direction),l=$i.dot($i)-r*r,c=e.radius*e.radius;if(l>c)return null;const h=Math.sqrt(c-l),d=r-h,m=r+h;return m<0?null:d<0?this.at(m,i):this.at(d,i)}intersectsSphere(e){return this.distanceSqToPoint(e.center)<=e.radius*e.radius}distanceToPlane(e){const i=e.normal.dot(this.direction);if(i===0)return e.distanceToPoint(this.origin)===0?0:null;const r=-(this.origin.dot(e.normal)+e.constant)/i;return r>=0?r:null}intersectPlane(e,i){const r=this.distanceToPlane(e);return r===null?null:this.at(r,i)}intersectsPlane(e){const i=e.distanceToPoint(this.origin);return i===0||e.normal.dot(this.direction)*i<0}intersectBox(e,i){let r,l,c,h,d,m;const p=1/this.direction.x,S=1/this.direction.y,v=1/this.direction.z,x=this.origin;return p>=0?(r=(e.min.x-x.x)*p,l=(e.max.x-x.x)*p):(r=(e.max.x-x.x)*p,l=(e.min.x-x.x)*p),S>=0?(c=(e.min.y-x.y)*S,h=(e.max.y-x.y)*S):(c=(e.max.y-x.y)*S,h=(e.min.y-x.y)*S),r>h||c>l||((c>r||isNaN(r))&&(r=c),(h<l||isNaN(l))&&(l=h),v>=0?(d=(e.min.z-x.z)*v,m=(e.max.z-x.z)*v):(d=(e.max.z-x.z)*v,m=(e.min.z-x.z)*v),r>m||d>l)||((d>r||r!==r)&&(r=d),(m<l||l!==l)&&(l=m),l<0)?null:this.at(r>=0?r:l,i)}intersectsBox(e){return this.intersectBox(e,$i)!==null}intersectTriangle(e,i,r,l,c){Qf.subVectors(i,e),Jl.subVectors(r,e),Jf.crossVectors(Qf,Jl);let h=this.direction.dot(Jf),d;if(h>0){if(l)return null;d=1}else if(h<0)d=-1,h=-h;else return null;Oa.subVectors(this.origin,e);const m=d*this.direction.dot(Jl.crossVectors(Oa,Jl));if(m<0)return null;const p=d*this.direction.dot(Qf.cross(Oa));if(p<0||m+p>h)return null;const S=-d*Oa.dot(Jf);return S<0?null:this.at(S/h,c)}applyMatrix4(e){return this.origin.applyMatrix4(e),this.direction.transformDirection(e),this}equals(e){return e.origin.equals(this.origin)&&e.direction.equals(this.direction)}clone(){return new this.constructor().copy(this)}}class Ye{constructor(e,i,r,l,c,h,d,m,p,S,v,x,y,R,w,M){Ye.prototype.isMatrix4=!0,this.elements=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],e!==void 0&&this.set(e,i,r,l,c,h,d,m,p,S,v,x,y,R,w,M)}set(e,i,r,l,c,h,d,m,p,S,v,x,y,R,w,M){const _=this.elements;return _[0]=e,_[4]=i,_[8]=r,_[12]=l,_[1]=c,_[5]=h,_[9]=d,_[13]=m,_[2]=p,_[6]=S,_[10]=v,_[14]=x,_[3]=y,_[7]=R,_[11]=w,_[15]=M,this}identity(){return this.set(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1),this}clone(){return new Ye().fromArray(this.elements)}copy(e){const i=this.elements,r=e.elements;return i[0]=r[0],i[1]=r[1],i[2]=r[2],i[3]=r[3],i[4]=r[4],i[5]=r[5],i[6]=r[6],i[7]=r[7],i[8]=r[8],i[9]=r[9],i[10]=r[10],i[11]=r[11],i[12]=r[12],i[13]=r[13],i[14]=r[14],i[15]=r[15],this}copyPosition(e){const i=this.elements,r=e.elements;return i[12]=r[12],i[13]=r[13],i[14]=r[14],this}setFromMatrix3(e){const i=e.elements;return this.set(i[0],i[3],i[6],0,i[1],i[4],i[7],0,i[2],i[5],i[8],0,0,0,0,1),this}extractBasis(e,i,r){return e.setFromMatrixColumn(this,0),i.setFromMatrixColumn(this,1),r.setFromMatrixColumn(this,2),this}makeBasis(e,i,r){return this.set(e.x,i.x,r.x,0,e.y,i.y,r.y,0,e.z,i.z,r.z,0,0,0,0,1),this}extractRotation(e){const i=this.elements,r=e.elements,l=1/ss.setFromMatrixColumn(e,0).length(),c=1/ss.setFromMatrixColumn(e,1).length(),h=1/ss.setFromMatrixColumn(e,2).length();return i[0]=r[0]*l,i[1]=r[1]*l,i[2]=r[2]*l,i[3]=0,i[4]=r[4]*c,i[5]=r[5]*c,i[6]=r[6]*c,i[7]=0,i[8]=r[8]*h,i[9]=r[9]*h,i[10]=r[10]*h,i[11]=0,i[12]=0,i[13]=0,i[14]=0,i[15]=1,this}makeRotationFromEuler(e){const i=this.elements,r=e.x,l=e.y,c=e.z,h=Math.cos(r),d=Math.sin(r),m=Math.cos(l),p=Math.sin(l),S=Math.cos(c),v=Math.sin(c);if(e.order==="XYZ"){const x=h*S,y=h*v,R=d*S,w=d*v;i[0]=m*S,i[4]=-m*v,i[8]=p,i[1]=y+R*p,i[5]=x-w*p,i[9]=-d*m,i[2]=w-x*p,i[6]=R+y*p,i[10]=h*m}else if(e.order==="YXZ"){const x=m*S,y=m*v,R=p*S,w=p*v;i[0]=x+w*d,i[4]=R*d-y,i[8]=h*p,i[1]=h*v,i[5]=h*S,i[9]=-d,i[2]=y*d-R,i[6]=w+x*d,i[10]=h*m}else if(e.order==="ZXY"){const x=m*S,y=m*v,R=p*S,w=p*v;i[0]=x-w*d,i[4]=-h*v,i[8]=R+y*d,i[1]=y+R*d,i[5]=h*S,i[9]=w-x*d,i[2]=-h*p,i[6]=d,i[10]=h*m}else if(e.order==="ZYX"){const x=h*S,y=h*v,R=d*S,w=d*v;i[0]=m*S,i[4]=R*p-y,i[8]=x*p+w,i[1]=m*v,i[5]=w*p+x,i[9]=y*p-R,i[2]=-p,i[6]=d*m,i[10]=h*m}else if(e.order==="YZX"){const x=h*m,y=h*p,R=d*m,w=d*p;i[0]=m*S,i[4]=w-x*v,i[8]=R*v+y,i[1]=v,i[5]=h*S,i[9]=-d*S,i[2]=-p*S,i[6]=y*v+R,i[10]=x-w*v}else if(e.order==="XZY"){const x=h*m,y=h*p,R=d*m,w=d*p;i[0]=m*S,i[4]=-v,i[8]=p*S,i[1]=x*v+w,i[5]=h*S,i[9]=y*v-R,i[2]=R*v-y,i[6]=d*S,i[10]=w*v+x}return i[3]=0,i[7]=0,i[11]=0,i[12]=0,i[13]=0,i[14]=0,i[15]=1,this}makeRotationFromQuaternion(e){return this.compose(fM,e,hM)}lookAt(e,i,r){const l=this.elements;return Kn.subVectors(e,i),Kn.lengthSq()===0&&(Kn.z=1),Kn.normalize(),za.crossVectors(r,Kn),za.lengthSq()===0&&(Math.abs(r.z)===1?Kn.x+=1e-4:Kn.z+=1e-4,Kn.normalize(),za.crossVectors(r,Kn)),za.normalize(),$l.crossVectors(Kn,za),l[0]=za.x,l[4]=$l.x,l[8]=Kn.x,l[1]=za.y,l[5]=$l.y,l[9]=Kn.y,l[2]=za.z,l[6]=$l.z,l[10]=Kn.z,this}multiply(e){return this.multiplyMatrices(this,e)}premultiply(e){return this.multiplyMatrices(e,this)}multiplyMatrices(e,i){const r=e.elements,l=i.elements,c=this.elements,h=r[0],d=r[4],m=r[8],p=r[12],S=r[1],v=r[5],x=r[9],y=r[13],R=r[2],w=r[6],M=r[10],_=r[14],L=r[3],U=r[7],C=r[11],G=r[15],I=l[0],O=l[4],V=l[8],D=l[12],b=l[1],B=l[5],rt=l[9],st=l[13],dt=l[2],pt=l[6],P=l[10],Y=l[14],j=l[3],vt=l[7],Tt=l[11],z=l[15];return c[0]=h*I+d*b+m*dt+p*j,c[4]=h*O+d*B+m*pt+p*vt,c[8]=h*V+d*rt+m*P+p*Tt,c[12]=h*D+d*st+m*Y+p*z,c[1]=S*I+v*b+x*dt+y*j,c[5]=S*O+v*B+x*pt+y*vt,c[9]=S*V+v*rt+x*P+y*Tt,c[13]=S*D+v*st+x*Y+y*z,c[2]=R*I+w*b+M*dt+_*j,c[6]=R*O+w*B+M*pt+_*vt,c[10]=R*V+w*rt+M*P+_*Tt,c[14]=R*D+w*st+M*Y+_*z,c[3]=L*I+U*b+C*dt+G*j,c[7]=L*O+U*B+C*pt+G*vt,c[11]=L*V+U*rt+C*P+G*Tt,c[15]=L*D+U*st+C*Y+G*z,this}multiplyScalar(e){const i=this.elements;return i[0]*=e,i[4]*=e,i[8]*=e,i[12]*=e,i[1]*=e,i[5]*=e,i[9]*=e,i[13]*=e,i[2]*=e,i[6]*=e,i[10]*=e,i[14]*=e,i[3]*=e,i[7]*=e,i[11]*=e,i[15]*=e,this}determinant(){const e=this.elements,i=e[0],r=e[4],l=e[8],c=e[12],h=e[1],d=e[5],m=e[9],p=e[13],S=e[2],v=e[6],x=e[10],y=e[14],R=e[3],w=e[7],M=e[11],_=e[15];return R*(+c*m*v-l*p*v-c*d*x+r*p*x+l*d*y-r*m*y)+w*(+i*m*y-i*p*x+c*h*x-l*h*y+l*p*S-c*m*S)+M*(+i*p*v-i*d*y-c*h*v+r*h*y+c*d*S-r*p*S)+_*(-l*d*S-i*m*v+i*d*x+l*h*v-r*h*x+r*m*S)}transpose(){const e=this.elements;let i;return i=e[1],e[1]=e[4],e[4]=i,i=e[2],e[2]=e[8],e[8]=i,i=e[6],e[6]=e[9],e[9]=i,i=e[3],e[3]=e[12],e[12]=i,i=e[7],e[7]=e[13],e[13]=i,i=e[11],e[11]=e[14],e[14]=i,this}setPosition(e,i,r){const l=this.elements;return e.isVector3?(l[12]=e.x,l[13]=e.y,l[14]=e.z):(l[12]=e,l[13]=i,l[14]=r),this}invert(){const e=this.elements,i=e[0],r=e[1],l=e[2],c=e[3],h=e[4],d=e[5],m=e[6],p=e[7],S=e[8],v=e[9],x=e[10],y=e[11],R=e[12],w=e[13],M=e[14],_=e[15],L=v*M*p-w*x*p+w*m*y-d*M*y-v*m*_+d*x*_,U=R*x*p-S*M*p-R*m*y+h*M*y+S*m*_-h*x*_,C=S*w*p-R*v*p+R*d*y-h*w*y-S*d*_+h*v*_,G=R*v*m-S*w*m-R*d*x+h*w*x+S*d*M-h*v*M,I=i*L+r*U+l*C+c*G;if(I===0)return this.set(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0);const O=1/I;return e[0]=L*O,e[1]=(w*x*c-v*M*c-w*l*y+r*M*y+v*l*_-r*x*_)*O,e[2]=(d*M*c-w*m*c+w*l*p-r*M*p-d*l*_+r*m*_)*O,e[3]=(v*m*c-d*x*c-v*l*p+r*x*p+d*l*y-r*m*y)*O,e[4]=U*O,e[5]=(S*M*c-R*x*c+R*l*y-i*M*y-S*l*_+i*x*_)*O,e[6]=(R*m*c-h*M*c-R*l*p+i*M*p+h*l*_-i*m*_)*O,e[7]=(h*x*c-S*m*c+S*l*p-i*x*p-h*l*y+i*m*y)*O,e[8]=C*O,e[9]=(R*v*c-S*w*c-R*r*y+i*w*y+S*r*_-i*v*_)*O,e[10]=(h*w*c-R*d*c+R*r*p-i*w*p-h*r*_+i*d*_)*O,e[11]=(S*d*c-h*v*c-S*r*p+i*v*p+h*r*y-i*d*y)*O,e[12]=G*O,e[13]=(S*w*l-R*v*l+R*r*x-i*w*x-S*r*M+i*v*M)*O,e[14]=(R*d*l-h*w*l-R*r*m+i*w*m+h*r*M-i*d*M)*O,e[15]=(h*v*l-S*d*l+S*r*m-i*v*m-h*r*x+i*d*x)*O,this}scale(e){const i=this.elements,r=e.x,l=e.y,c=e.z;return i[0]*=r,i[4]*=l,i[8]*=c,i[1]*=r,i[5]*=l,i[9]*=c,i[2]*=r,i[6]*=l,i[10]*=c,i[3]*=r,i[7]*=l,i[11]*=c,this}getMaxScaleOnAxis(){const e=this.elements,i=e[0]*e[0]+e[1]*e[1]+e[2]*e[2],r=e[4]*e[4]+e[5]*e[5]+e[6]*e[6],l=e[8]*e[8]+e[9]*e[9]+e[10]*e[10];return Math.sqrt(Math.max(i,r,l))}makeTranslation(e,i,r){return e.isVector3?this.set(1,0,0,e.x,0,1,0,e.y,0,0,1,e.z,0,0,0,1):this.set(1,0,0,e,0,1,0,i,0,0,1,r,0,0,0,1),this}makeRotationX(e){const i=Math.cos(e),r=Math.sin(e);return this.set(1,0,0,0,0,i,-r,0,0,r,i,0,0,0,0,1),this}makeRotationY(e){const i=Math.cos(e),r=Math.sin(e);return this.set(i,0,r,0,0,1,0,0,-r,0,i,0,0,0,0,1),this}makeRotationZ(e){const i=Math.cos(e),r=Math.sin(e);return this.set(i,-r,0,0,r,i,0,0,0,0,1,0,0,0,0,1),this}makeRotationAxis(e,i){const r=Math.cos(i),l=Math.sin(i),c=1-r,h=e.x,d=e.y,m=e.z,p=c*h,S=c*d;return this.set(p*h+r,p*d-l*m,p*m+l*d,0,p*d+l*m,S*d+r,S*m-l*h,0,p*m-l*d,S*m+l*h,c*m*m+r,0,0,0,0,1),this}makeScale(e,i,r){return this.set(e,0,0,0,0,i,0,0,0,0,r,0,0,0,0,1),this}makeShear(e,i,r,l,c,h){return this.set(1,r,c,0,e,1,h,0,i,l,1,0,0,0,0,1),this}compose(e,i,r){const l=this.elements,c=i._x,h=i._y,d=i._z,m=i._w,p=c+c,S=h+h,v=d+d,x=c*p,y=c*S,R=c*v,w=h*S,M=h*v,_=d*v,L=m*p,U=m*S,C=m*v,G=r.x,I=r.y,O=r.z;return l[0]=(1-(w+_))*G,l[1]=(y+C)*G,l[2]=(R-U)*G,l[3]=0,l[4]=(y-C)*I,l[5]=(1-(x+_))*I,l[6]=(M+L)*I,l[7]=0,l[8]=(R+U)*O,l[9]=(M-L)*O,l[10]=(1-(x+w))*O,l[11]=0,l[12]=e.x,l[13]=e.y,l[14]=e.z,l[15]=1,this}decompose(e,i,r){const l=this.elements;let c=ss.set(l[0],l[1],l[2]).length();const h=ss.set(l[4],l[5],l[6]).length(),d=ss.set(l[8],l[9],l[10]).length();this.determinant()<0&&(c=-c),e.x=l[12],e.y=l[13],e.z=l[14],_i.copy(this);const p=1/c,S=1/h,v=1/d;return _i.elements[0]*=p,_i.elements[1]*=p,_i.elements[2]*=p,_i.elements[4]*=S,_i.elements[5]*=S,_i.elements[6]*=S,_i.elements[8]*=v,_i.elements[9]*=v,_i.elements[10]*=v,i.setFromRotationMatrix(_i),r.x=c,r.y=h,r.z=d,this}makePerspective(e,i,r,l,c,h,d=oa){const m=this.elements,p=2*c/(i-e),S=2*c/(r-l),v=(i+e)/(i-e),x=(r+l)/(r-l);let y,R;if(d===oa)y=-(h+c)/(h-c),R=-2*h*c/(h-c);else if(d===Tu)y=-h/(h-c),R=-h*c/(h-c);else throw new Error("THREE.Matrix4.makePerspective(): Invalid coordinate system: "+d);return m[0]=p,m[4]=0,m[8]=v,m[12]=0,m[1]=0,m[5]=S,m[9]=x,m[13]=0,m[2]=0,m[6]=0,m[10]=y,m[14]=R,m[3]=0,m[7]=0,m[11]=-1,m[15]=0,this}makeOrthographic(e,i,r,l,c,h,d=oa){const m=this.elements,p=1/(i-e),S=1/(r-l),v=1/(h-c),x=(i+e)*p,y=(r+l)*S;let R,w;if(d===oa)R=(h+c)*v,w=-2*v;else if(d===Tu)R=c*v,w=-1*v;else throw new Error("THREE.Matrix4.makeOrthographic(): Invalid coordinate system: "+d);return m[0]=2*p,m[4]=0,m[8]=0,m[12]=-x,m[1]=0,m[5]=2*S,m[9]=0,m[13]=-y,m[2]=0,m[6]=0,m[10]=w,m[14]=-R,m[3]=0,m[7]=0,m[11]=0,m[15]=1,this}equals(e){const i=this.elements,r=e.elements;for(let l=0;l<16;l++)if(i[l]!==r[l])return!1;return!0}fromArray(e,i=0){for(let r=0;r<16;r++)this.elements[r]=e[r+i];return this}toArray(e=[],i=0){const r=this.elements;return e[i]=r[0],e[i+1]=r[1],e[i+2]=r[2],e[i+3]=r[3],e[i+4]=r[4],e[i+5]=r[5],e[i+6]=r[6],e[i+7]=r[7],e[i+8]=r[8],e[i+9]=r[9],e[i+10]=r[10],e[i+11]=r[11],e[i+12]=r[12],e[i+13]=r[13],e[i+14]=r[14],e[i+15]=r[15],e}}const ss=new Q,_i=new Ye,fM=new Q(0,0,0),hM=new Q(1,1,1),za=new Q,$l=new Q,Kn=new Q,C_=new Ye,w_=new No;class Li{constructor(e=0,i=0,r=0,l=Li.DEFAULT_ORDER){this.isEuler=!0,this._x=e,this._y=i,this._z=r,this._order=l}get x(){return this._x}set x(e){this._x=e,this._onChangeCallback()}get y(){return this._y}set y(e){this._y=e,this._onChangeCallback()}get z(){return this._z}set z(e){this._z=e,this._onChangeCallback()}get order(){return this._order}set order(e){this._order=e,this._onChangeCallback()}set(e,i,r,l=this._order){return this._x=e,this._y=i,this._z=r,this._order=l,this._onChangeCallback(),this}clone(){return new this.constructor(this._x,this._y,this._z,this._order)}copy(e){return this._x=e._x,this._y=e._y,this._z=e._z,this._order=e._order,this._onChangeCallback(),this}setFromRotationMatrix(e,i=this._order,r=!0){const l=e.elements,c=l[0],h=l[4],d=l[8],m=l[1],p=l[5],S=l[9],v=l[2],x=l[6],y=l[10];switch(i){case"XYZ":this._y=Math.asin(Se(d,-1,1)),Math.abs(d)<.9999999?(this._x=Math.atan2(-S,y),this._z=Math.atan2(-h,c)):(this._x=Math.atan2(x,p),this._z=0);break;case"YXZ":this._x=Math.asin(-Se(S,-1,1)),Math.abs(S)<.9999999?(this._y=Math.atan2(d,y),this._z=Math.atan2(m,p)):(this._y=Math.atan2(-v,c),this._z=0);break;case"ZXY":this._x=Math.asin(Se(x,-1,1)),Math.abs(x)<.9999999?(this._y=Math.atan2(-v,y),this._z=Math.atan2(-h,p)):(this._y=0,this._z=Math.atan2(m,c));break;case"ZYX":this._y=Math.asin(-Se(v,-1,1)),Math.abs(v)<.9999999?(this._x=Math.atan2(x,y),this._z=Math.atan2(m,c)):(this._x=0,this._z=Math.atan2(-h,p));break;case"YZX":this._z=Math.asin(Se(m,-1,1)),Math.abs(m)<.9999999?(this._x=Math.atan2(-S,p),this._y=Math.atan2(-v,c)):(this._x=0,this._y=Math.atan2(d,y));break;case"XZY":this._z=Math.asin(-Se(h,-1,1)),Math.abs(h)<.9999999?(this._x=Math.atan2(x,p),this._y=Math.atan2(d,c)):(this._x=Math.atan2(-S,y),this._y=0);break;default:console.warn("THREE.Euler: .setFromRotationMatrix() encountered an unknown order: "+i)}return this._order=i,r===!0&&this._onChangeCallback(),this}setFromQuaternion(e,i,r){return C_.makeRotationFromQuaternion(e),this.setFromRotationMatrix(C_,i,r)}setFromVector3(e,i=this._order){return this.set(e.x,e.y,e.z,i)}reorder(e){return w_.setFromEuler(this),this.setFromQuaternion(w_,e)}equals(e){return e._x===this._x&&e._y===this._y&&e._z===this._z&&e._order===this._order}fromArray(e){return this._x=e[0],this._y=e[1],this._z=e[2],e[3]!==void 0&&(this._order=e[3]),this._onChangeCallback(),this}toArray(e=[],i=0){return e[i]=this._x,e[i+1]=this._y,e[i+2]=this._z,e[i+3]=this._order,e}_onChange(e){return this._onChangeCallback=e,this}_onChangeCallback(){}*[Symbol.iterator](){yield this._x,yield this._y,yield this._z,yield this._order}}Li.DEFAULT_ORDER="XYZ";class B0{constructor(){this.mask=1}set(e){this.mask=(1<<e|0)>>>0}enable(e){this.mask|=1<<e|0}enableAll(){this.mask=-1}toggle(e){this.mask^=1<<e|0}disable(e){this.mask&=~(1<<e|0)}disableAll(){this.mask=0}test(e){return(this.mask&e.mask)!==0}isEnabled(e){return(this.mask&(1<<e|0))!==0}}let dM=0;const D_=new Q,os=new No,ta=new Ye,tu=new Q,Eo=new Q,pM=new Q,mM=new No,U_=new Q(1,0,0),L_=new Q(0,1,0),N_=new Q(0,0,1),O_={type:"added"},gM={type:"removed"},ls={type:"childadded",child:null},$f={type:"childremoved",child:null};class An extends Es{constructor(){super(),this.isObject3D=!0,Object.defineProperty(this,"id",{value:dM++}),this.uuid=Lo(),this.name="",this.type="Object3D",this.parent=null,this.children=[],this.up=An.DEFAULT_UP.clone();const e=new Q,i=new Li,r=new No,l=new Q(1,1,1);function c(){r.setFromEuler(i,!1)}function h(){i.setFromQuaternion(r,void 0,!1)}i._onChange(c),r._onChange(h),Object.defineProperties(this,{position:{configurable:!0,enumerable:!0,value:e},rotation:{configurable:!0,enumerable:!0,value:i},quaternion:{configurable:!0,enumerable:!0,value:r},scale:{configurable:!0,enumerable:!0,value:l},modelViewMatrix:{value:new Ye},normalMatrix:{value:new oe}}),this.matrix=new Ye,this.matrixWorld=new Ye,this.matrixAutoUpdate=An.DEFAULT_MATRIX_AUTO_UPDATE,this.matrixWorldAutoUpdate=An.DEFAULT_MATRIX_WORLD_AUTO_UPDATE,this.matrixWorldNeedsUpdate=!1,this.layers=new B0,this.visible=!0,this.castShadow=!1,this.receiveShadow=!1,this.frustumCulled=!0,this.renderOrder=0,this.animations=[],this.customDepthMaterial=void 0,this.customDistanceMaterial=void 0,this.userData={}}onBeforeShadow(){}onAfterShadow(){}onBeforeRender(){}onAfterRender(){}applyMatrix4(e){this.matrixAutoUpdate&&this.updateMatrix(),this.matrix.premultiply(e),this.matrix.decompose(this.position,this.quaternion,this.scale)}applyQuaternion(e){return this.quaternion.premultiply(e),this}setRotationFromAxisAngle(e,i){this.quaternion.setFromAxisAngle(e,i)}setRotationFromEuler(e){this.quaternion.setFromEuler(e,!0)}setRotationFromMatrix(e){this.quaternion.setFromRotationMatrix(e)}setRotationFromQuaternion(e){this.quaternion.copy(e)}rotateOnAxis(e,i){return os.setFromAxisAngle(e,i),this.quaternion.multiply(os),this}rotateOnWorldAxis(e,i){return os.setFromAxisAngle(e,i),this.quaternion.premultiply(os),this}rotateX(e){return this.rotateOnAxis(U_,e)}rotateY(e){return this.rotateOnAxis(L_,e)}rotateZ(e){return this.rotateOnAxis(N_,e)}translateOnAxis(e,i){return D_.copy(e).applyQuaternion(this.quaternion),this.position.add(D_.multiplyScalar(i)),this}translateX(e){return this.translateOnAxis(U_,e)}translateY(e){return this.translateOnAxis(L_,e)}translateZ(e){return this.translateOnAxis(N_,e)}localToWorld(e){return this.updateWorldMatrix(!0,!1),e.applyMatrix4(this.matrixWorld)}worldToLocal(e){return this.updateWorldMatrix(!0,!1),e.applyMatrix4(ta.copy(this.matrixWorld).invert())}lookAt(e,i,r){e.isVector3?tu.copy(e):tu.set(e,i,r);const l=this.parent;this.updateWorldMatrix(!0,!1),Eo.setFromMatrixPosition(this.matrixWorld),this.isCamera||this.isLight?ta.lookAt(Eo,tu,this.up):ta.lookAt(tu,Eo,this.up),this.quaternion.setFromRotationMatrix(ta),l&&(ta.extractRotation(l.matrixWorld),os.setFromRotationMatrix(ta),this.quaternion.premultiply(os.invert()))}add(e){if(arguments.length>1){for(let i=0;i<arguments.length;i++)this.add(arguments[i]);return this}return e===this?(console.error("THREE.Object3D.add: object can't be added as a child of itself.",e),this):(e&&e.isObject3D?(e.removeFromParent(),e.parent=this,this.children.push(e),e.dispatchEvent(O_),ls.child=e,this.dispatchEvent(ls),ls.child=null):console.error("THREE.Object3D.add: object not an instance of THREE.Object3D.",e),this)}remove(e){if(arguments.length>1){for(let r=0;r<arguments.length;r++)this.remove(arguments[r]);return this}const i=this.children.indexOf(e);return i!==-1&&(e.parent=null,this.children.splice(i,1),e.dispatchEvent(gM),$f.child=e,this.dispatchEvent($f),$f.child=null),this}removeFromParent(){const e=this.parent;return e!==null&&e.remove(this),this}clear(){return this.remove(...this.children)}attach(e){return this.updateWorldMatrix(!0,!1),ta.copy(this.matrixWorld).invert(),e.parent!==null&&(e.parent.updateWorldMatrix(!0,!1),ta.multiply(e.parent.matrixWorld)),e.applyMatrix4(ta),e.removeFromParent(),e.parent=this,this.children.push(e),e.updateWorldMatrix(!1,!0),e.dispatchEvent(O_),ls.child=e,this.dispatchEvent(ls),ls.child=null,this}getObjectById(e){return this.getObjectByProperty("id",e)}getObjectByName(e){return this.getObjectByProperty("name",e)}getObjectByProperty(e,i){if(this[e]===i)return this;for(let r=0,l=this.children.length;r<l;r++){const h=this.children[r].getObjectByProperty(e,i);if(h!==void 0)return h}}getObjectsByProperty(e,i,r=[]){this[e]===i&&r.push(this);const l=this.children;for(let c=0,h=l.length;c<h;c++)l[c].getObjectsByProperty(e,i,r);return r}getWorldPosition(e){return this.updateWorldMatrix(!0,!1),e.setFromMatrixPosition(this.matrixWorld)}getWorldQuaternion(e){return this.updateWorldMatrix(!0,!1),this.matrixWorld.decompose(Eo,e,pM),e}getWorldScale(e){return this.updateWorldMatrix(!0,!1),this.matrixWorld.decompose(Eo,mM,e),e}getWorldDirection(e){this.updateWorldMatrix(!0,!1);const i=this.matrixWorld.elements;return e.set(i[8],i[9],i[10]).normalize()}raycast(){}traverse(e){e(this);const i=this.children;for(let r=0,l=i.length;r<l;r++)i[r].traverse(e)}traverseVisible(e){if(this.visible===!1)return;e(this);const i=this.children;for(let r=0,l=i.length;r<l;r++)i[r].traverseVisible(e)}traverseAncestors(e){const i=this.parent;i!==null&&(e(i),i.traverseAncestors(e))}updateMatrix(){this.matrix.compose(this.position,this.quaternion,this.scale),this.matrixWorldNeedsUpdate=!0}updateMatrixWorld(e){this.matrixAutoUpdate&&this.updateMatrix(),(this.matrixWorldNeedsUpdate||e)&&(this.matrixWorldAutoUpdate===!0&&(this.parent===null?this.matrixWorld.copy(this.matrix):this.matrixWorld.multiplyMatrices(this.parent.matrixWorld,this.matrix)),this.matrixWorldNeedsUpdate=!1,e=!0);const i=this.children;for(let r=0,l=i.length;r<l;r++)i[r].updateMatrixWorld(e)}updateWorldMatrix(e,i){const r=this.parent;if(e===!0&&r!==null&&r.updateWorldMatrix(!0,!1),this.matrixAutoUpdate&&this.updateMatrix(),this.matrixWorldAutoUpdate===!0&&(this.parent===null?this.matrixWorld.copy(this.matrix):this.matrixWorld.multiplyMatrices(this.parent.matrixWorld,this.matrix)),i===!0){const l=this.children;for(let c=0,h=l.length;c<h;c++)l[c].updateWorldMatrix(!1,!0)}}toJSON(e){const i=e===void 0||typeof e=="string",r={};i&&(e={geometries:{},materials:{},textures:{},images:{},shapes:{},skeletons:{},animations:{},nodes:{}},r.metadata={version:4.6,type:"Object",generator:"Object3D.toJSON"});const l={};l.uuid=this.uuid,l.type=this.type,this.name!==""&&(l.name=this.name),this.castShadow===!0&&(l.castShadow=!0),this.receiveShadow===!0&&(l.receiveShadow=!0),this.visible===!1&&(l.visible=!1),this.frustumCulled===!1&&(l.frustumCulled=!1),this.renderOrder!==0&&(l.renderOrder=this.renderOrder),Object.keys(this.userData).length>0&&(l.userData=this.userData),l.layers=this.layers.mask,l.matrix=this.matrix.toArray(),l.up=this.up.toArray(),this.matrixAutoUpdate===!1&&(l.matrixAutoUpdate=!1),this.isInstancedMesh&&(l.type="InstancedMesh",l.count=this.count,l.instanceMatrix=this.instanceMatrix.toJSON(),this.instanceColor!==null&&(l.instanceColor=this.instanceColor.toJSON())),this.isBatchedMesh&&(l.type="BatchedMesh",l.perObjectFrustumCulled=this.perObjectFrustumCulled,l.sortObjects=this.sortObjects,l.drawRanges=this._drawRanges,l.reservedRanges=this._reservedRanges,l.geometryInfo=this._geometryInfo.map(d=>({...d,boundingBox:d.boundingBox?{min:d.boundingBox.min.toArray(),max:d.boundingBox.max.toArray()}:void 0,boundingSphere:d.boundingSphere?{radius:d.boundingSphere.radius,center:d.boundingSphere.center.toArray()}:void 0})),l.instanceInfo=this._instanceInfo.map(d=>({...d})),l.availableInstanceIds=this._availableInstanceIds.slice(),l.availableGeometryIds=this._availableGeometryIds.slice(),l.nextIndexStart=this._nextIndexStart,l.nextVertexStart=this._nextVertexStart,l.geometryCount=this._geometryCount,l.maxInstanceCount=this._maxInstanceCount,l.maxVertexCount=this._maxVertexCount,l.maxIndexCount=this._maxIndexCount,l.geometryInitialized=this._geometryInitialized,l.matricesTexture=this._matricesTexture.toJSON(e),l.indirectTexture=this._indirectTexture.toJSON(e),this._colorsTexture!==null&&(l.colorsTexture=this._colorsTexture.toJSON(e)),this.boundingSphere!==null&&(l.boundingSphere={center:this.boundingSphere.center.toArray(),radius:this.boundingSphere.radius}),this.boundingBox!==null&&(l.boundingBox={min:this.boundingBox.min.toArray(),max:this.boundingBox.max.toArray()}));function c(d,m){return d[m.uuid]===void 0&&(d[m.uuid]=m.toJSON(e)),m.uuid}if(this.isScene)this.background&&(this.background.isColor?l.background=this.background.toJSON():this.background.isTexture&&(l.background=this.background.toJSON(e).uuid)),this.environment&&this.environment.isTexture&&this.environment.isRenderTargetTexture!==!0&&(l.environment=this.environment.toJSON(e).uuid);else if(this.isMesh||this.isLine||this.isPoints){l.geometry=c(e.geometries,this.geometry);const d=this.geometry.parameters;if(d!==void 0&&d.shapes!==void 0){const m=d.shapes;if(Array.isArray(m))for(let p=0,S=m.length;p<S;p++){const v=m[p];c(e.shapes,v)}else c(e.shapes,m)}}if(this.isSkinnedMesh&&(l.bindMode=this.bindMode,l.bindMatrix=this.bindMatrix.toArray(),this.skeleton!==void 0&&(c(e.skeletons,this.skeleton),l.skeleton=this.skeleton.uuid)),this.material!==void 0)if(Array.isArray(this.material)){const d=[];for(let m=0,p=this.material.length;m<p;m++)d.push(c(e.materials,this.material[m]));l.material=d}else l.material=c(e.materials,this.material);if(this.children.length>0){l.children=[];for(let d=0;d<this.children.length;d++)l.children.push(this.children[d].toJSON(e).object)}if(this.animations.length>0){l.animations=[];for(let d=0;d<this.animations.length;d++){const m=this.animations[d];l.animations.push(c(e.animations,m))}}if(i){const d=h(e.geometries),m=h(e.materials),p=h(e.textures),S=h(e.images),v=h(e.shapes),x=h(e.skeletons),y=h(e.animations),R=h(e.nodes);d.length>0&&(r.geometries=d),m.length>0&&(r.materials=m),p.length>0&&(r.textures=p),S.length>0&&(r.images=S),v.length>0&&(r.shapes=v),x.length>0&&(r.skeletons=x),y.length>0&&(r.animations=y),R.length>0&&(r.nodes=R)}return r.object=l,r;function h(d){const m=[];for(const p in d){const S=d[p];delete S.metadata,m.push(S)}return m}}clone(e){return new this.constructor().copy(this,e)}copy(e,i=!0){if(this.name=e.name,this.up.copy(e.up),this.position.copy(e.position),this.rotation.order=e.rotation.order,this.quaternion.copy(e.quaternion),this.scale.copy(e.scale),this.matrix.copy(e.matrix),this.matrixWorld.copy(e.matrixWorld),this.matrixAutoUpdate=e.matrixAutoUpdate,this.matrixWorldAutoUpdate=e.matrixWorldAutoUpdate,this.matrixWorldNeedsUpdate=e.matrixWorldNeedsUpdate,this.layers.mask=e.layers.mask,this.visible=e.visible,this.castShadow=e.castShadow,this.receiveShadow=e.receiveShadow,this.frustumCulled=e.frustumCulled,this.renderOrder=e.renderOrder,this.animations=e.animations.slice(),this.userData=JSON.parse(JSON.stringify(e.userData)),i===!0)for(let r=0;r<e.children.length;r++){const l=e.children[r];this.add(l.clone())}return this}}An.DEFAULT_UP=new Q(0,1,0);An.DEFAULT_MATRIX_AUTO_UPDATE=!0;An.DEFAULT_MATRIX_WORLD_AUTO_UPDATE=!0;const vi=new Q,ea=new Q,th=new Q,na=new Q,us=new Q,cs=new Q,z_=new Q,eh=new Q,nh=new Q,ih=new Q,ah=new Ie,rh=new Ie,sh=new Ie;class xi{constructor(e=new Q,i=new Q,r=new Q){this.a=e,this.b=i,this.c=r}static getNormal(e,i,r,l){l.subVectors(r,i),vi.subVectors(e,i),l.cross(vi);const c=l.lengthSq();return c>0?l.multiplyScalar(1/Math.sqrt(c)):l.set(0,0,0)}static getBarycoord(e,i,r,l,c){vi.subVectors(l,i),ea.subVectors(r,i),th.subVectors(e,i);const h=vi.dot(vi),d=vi.dot(ea),m=vi.dot(th),p=ea.dot(ea),S=ea.dot(th),v=h*p-d*d;if(v===0)return c.set(0,0,0),null;const x=1/v,y=(p*m-d*S)*x,R=(h*S-d*m)*x;return c.set(1-y-R,R,y)}static containsPoint(e,i,r,l){return this.getBarycoord(e,i,r,l,na)===null?!1:na.x>=0&&na.y>=0&&na.x+na.y<=1}static getInterpolation(e,i,r,l,c,h,d,m){return this.getBarycoord(e,i,r,l,na)===null?(m.x=0,m.y=0,"z"in m&&(m.z=0),"w"in m&&(m.w=0),null):(m.setScalar(0),m.addScaledVector(c,na.x),m.addScaledVector(h,na.y),m.addScaledVector(d,na.z),m)}static getInterpolatedAttribute(e,i,r,l,c,h){return ah.setScalar(0),rh.setScalar(0),sh.setScalar(0),ah.fromBufferAttribute(e,i),rh.fromBufferAttribute(e,r),sh.fromBufferAttribute(e,l),h.setScalar(0),h.addScaledVector(ah,c.x),h.addScaledVector(rh,c.y),h.addScaledVector(sh,c.z),h}static isFrontFacing(e,i,r,l){return vi.subVectors(r,i),ea.subVectors(e,i),vi.cross(ea).dot(l)<0}set(e,i,r){return this.a.copy(e),this.b.copy(i),this.c.copy(r),this}setFromPointsAndIndices(e,i,r,l){return this.a.copy(e[i]),this.b.copy(e[r]),this.c.copy(e[l]),this}setFromAttributeAndIndices(e,i,r,l){return this.a.fromBufferAttribute(e,i),this.b.fromBufferAttribute(e,r),this.c.fromBufferAttribute(e,l),this}clone(){return new this.constructor().copy(this)}copy(e){return this.a.copy(e.a),this.b.copy(e.b),this.c.copy(e.c),this}getArea(){return vi.subVectors(this.c,this.b),ea.subVectors(this.a,this.b),vi.cross(ea).length()*.5}getMidpoint(e){return e.addVectors(this.a,this.b).add(this.c).multiplyScalar(1/3)}getNormal(e){return xi.getNormal(this.a,this.b,this.c,e)}getPlane(e){return e.setFromCoplanarPoints(this.a,this.b,this.c)}getBarycoord(e,i){return xi.getBarycoord(e,this.a,this.b,this.c,i)}getInterpolation(e,i,r,l,c){return xi.getInterpolation(e,this.a,this.b,this.c,i,r,l,c)}containsPoint(e){return xi.containsPoint(e,this.a,this.b,this.c)}isFrontFacing(e){return xi.isFrontFacing(this.a,this.b,this.c,e)}intersectsBox(e){return e.intersectsTriangle(this)}closestPointToPoint(e,i){const r=this.a,l=this.b,c=this.c;let h,d;us.subVectors(l,r),cs.subVectors(c,r),eh.subVectors(e,r);const m=us.dot(eh),p=cs.dot(eh);if(m<=0&&p<=0)return i.copy(r);nh.subVectors(e,l);const S=us.dot(nh),v=cs.dot(nh);if(S>=0&&v<=S)return i.copy(l);const x=m*v-S*p;if(x<=0&&m>=0&&S<=0)return h=m/(m-S),i.copy(r).addScaledVector(us,h);ih.subVectors(e,c);const y=us.dot(ih),R=cs.dot(ih);if(R>=0&&y<=R)return i.copy(c);const w=y*p-m*R;if(w<=0&&p>=0&&R<=0)return d=p/(p-R),i.copy(r).addScaledVector(cs,d);const M=S*R-y*v;if(M<=0&&v-S>=0&&y-R>=0)return z_.subVectors(c,l),d=(v-S)/(v-S+(y-R)),i.copy(l).addScaledVector(z_,d);const _=1/(M+w+x);return h=w*_,d=x*_,i.copy(r).addScaledVector(us,h).addScaledVector(cs,d)}equals(e){return e.a.equals(this.a)&&e.b.equals(this.b)&&e.c.equals(this.c)}}const I0={aliceblue:15792383,antiquewhite:16444375,aqua:65535,aquamarine:8388564,azure:15794175,beige:16119260,bisque:16770244,black:0,blanchedalmond:16772045,blue:255,blueviolet:9055202,brown:10824234,burlywood:14596231,cadetblue:6266528,chartreuse:8388352,chocolate:13789470,coral:16744272,cornflowerblue:6591981,cornsilk:16775388,crimson:14423100,cyan:65535,darkblue:139,darkcyan:35723,darkgoldenrod:12092939,darkgray:11119017,darkgreen:25600,darkgrey:11119017,darkkhaki:12433259,darkmagenta:9109643,darkolivegreen:5597999,darkorange:16747520,darkorchid:10040012,darkred:9109504,darksalmon:15308410,darkseagreen:9419919,darkslateblue:4734347,darkslategray:3100495,darkslategrey:3100495,darkturquoise:52945,darkviolet:9699539,deeppink:16716947,deepskyblue:49151,dimgray:6908265,dimgrey:6908265,dodgerblue:2003199,firebrick:11674146,floralwhite:16775920,forestgreen:2263842,fuchsia:16711935,gainsboro:14474460,ghostwhite:16316671,gold:16766720,goldenrod:14329120,gray:8421504,green:32768,greenyellow:11403055,grey:8421504,honeydew:15794160,hotpink:16738740,indianred:13458524,indigo:4915330,ivory:16777200,khaki:15787660,lavender:15132410,lavenderblush:16773365,lawngreen:8190976,lemonchiffon:16775885,lightblue:11393254,lightcoral:15761536,lightcyan:14745599,lightgoldenrodyellow:16448210,lightgray:13882323,lightgreen:9498256,lightgrey:13882323,lightpink:16758465,lightsalmon:16752762,lightseagreen:2142890,lightskyblue:8900346,lightslategray:7833753,lightslategrey:7833753,lightsteelblue:11584734,lightyellow:16777184,lime:65280,limegreen:3329330,linen:16445670,magenta:16711935,maroon:8388608,mediumaquamarine:6737322,mediumblue:205,mediumorchid:12211667,mediumpurple:9662683,mediumseagreen:3978097,mediumslateblue:8087790,mediumspringgreen:64154,mediumturquoise:4772300,mediumvioletred:13047173,midnightblue:1644912,mintcream:16121850,mistyrose:16770273,moccasin:16770229,navajowhite:16768685,navy:128,oldlace:16643558,olive:8421376,olivedrab:7048739,orange:16753920,orangered:16729344,orchid:14315734,palegoldenrod:15657130,palegreen:10025880,paleturquoise:11529966,palevioletred:14381203,papayawhip:16773077,peachpuff:16767673,peru:13468991,pink:16761035,plum:14524637,powderblue:11591910,purple:8388736,rebeccapurple:6697881,red:16711680,rosybrown:12357519,royalblue:4286945,saddlebrown:9127187,salmon:16416882,sandybrown:16032864,seagreen:3050327,seashell:16774638,sienna:10506797,silver:12632256,skyblue:8900331,slateblue:6970061,slategray:7372944,slategrey:7372944,snow:16775930,springgreen:65407,steelblue:4620980,tan:13808780,teal:32896,thistle:14204888,tomato:16737095,turquoise:4251856,violet:15631086,wheat:16113331,white:16777215,whitesmoke:16119285,yellow:16776960,yellowgreen:10145074},Pa={h:0,s:0,l:0},eu={h:0,s:0,l:0};function oh(o,e,i){return i<0&&(i+=1),i>1&&(i-=1),i<1/6?o+(e-o)*6*i:i<1/2?e:i<2/3?o+(e-o)*6*(2/3-i):o}class Me{constructor(e,i,r){return this.isColor=!0,this.r=1,this.g=1,this.b=1,this.set(e,i,r)}set(e,i,r){if(i===void 0&&r===void 0){const l=e;l&&l.isColor?this.copy(l):typeof l=="number"?this.setHex(l):typeof l=="string"&&this.setStyle(l)}else this.setRGB(e,i,r);return this}setScalar(e){return this.r=e,this.g=e,this.b=e,this}setHex(e,i=li){return e=Math.floor(e),this.r=(e>>16&255)/255,this.g=(e>>8&255)/255,this.b=(e&255)/255,Re.toWorkingColorSpace(this,i),this}setRGB(e,i,r,l=Re.workingColorSpace){return this.r=e,this.g=i,this.b=r,Re.toWorkingColorSpace(this,l),this}setHSL(e,i,r,l=Re.workingColorSpace){if(e=Jx(e,1),i=Se(i,0,1),r=Se(r,0,1),i===0)this.r=this.g=this.b=r;else{const c=r<=.5?r*(1+i):r+i-r*i,h=2*r-c;this.r=oh(h,c,e+1/3),this.g=oh(h,c,e),this.b=oh(h,c,e-1/3)}return Re.toWorkingColorSpace(this,l),this}setStyle(e,i=li){function r(c){c!==void 0&&parseFloat(c)<1&&console.warn("THREE.Color: Alpha component of "+e+" will be ignored.")}let l;if(l=/^(\w+)\(([^\)]*)\)/.exec(e)){let c;const h=l[1],d=l[2];switch(h){case"rgb":case"rgba":if(c=/^\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(d))return r(c[4]),this.setRGB(Math.min(255,parseInt(c[1],10))/255,Math.min(255,parseInt(c[2],10))/255,Math.min(255,parseInt(c[3],10))/255,i);if(c=/^\s*(\d+)\%\s*,\s*(\d+)\%\s*,\s*(\d+)\%\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(d))return r(c[4]),this.setRGB(Math.min(100,parseInt(c[1],10))/100,Math.min(100,parseInt(c[2],10))/100,Math.min(100,parseInt(c[3],10))/100,i);break;case"hsl":case"hsla":if(c=/^\s*(\d*\.?\d+)\s*,\s*(\d*\.?\d+)\%\s*,\s*(\d*\.?\d+)\%\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(d))return r(c[4]),this.setHSL(parseFloat(c[1])/360,parseFloat(c[2])/100,parseFloat(c[3])/100,i);break;default:console.warn("THREE.Color: Unknown color model "+e)}}else if(l=/^\#([A-Fa-f\d]+)$/.exec(e)){const c=l[1],h=c.length;if(h===3)return this.setRGB(parseInt(c.charAt(0),16)/15,parseInt(c.charAt(1),16)/15,parseInt(c.charAt(2),16)/15,i);if(h===6)return this.setHex(parseInt(c,16),i);console.warn("THREE.Color: Invalid hex color "+e)}else if(e&&e.length>0)return this.setColorName(e,i);return this}setColorName(e,i=li){const r=I0[e.toLowerCase()];return r!==void 0?this.setHex(r,i):console.warn("THREE.Color: Unknown color "+e),this}clone(){return new this.constructor(this.r,this.g,this.b)}copy(e){return this.r=e.r,this.g=e.g,this.b=e.b,this}copySRGBToLinear(e){return this.r=la(e.r),this.g=la(e.g),this.b=la(e.b),this}copyLinearToSRGB(e){return this.r=_s(e.r),this.g=_s(e.g),this.b=_s(e.b),this}convertSRGBToLinear(){return this.copySRGBToLinear(this),this}convertLinearToSRGB(){return this.copyLinearToSRGB(this),this}getHex(e=li){return Re.fromWorkingColorSpace(bn.copy(this),e),Math.round(Se(bn.r*255,0,255))*65536+Math.round(Se(bn.g*255,0,255))*256+Math.round(Se(bn.b*255,0,255))}getHexString(e=li){return("000000"+this.getHex(e).toString(16)).slice(-6)}getHSL(e,i=Re.workingColorSpace){Re.fromWorkingColorSpace(bn.copy(this),i);const r=bn.r,l=bn.g,c=bn.b,h=Math.max(r,l,c),d=Math.min(r,l,c);let m,p;const S=(d+h)/2;if(d===h)m=0,p=0;else{const v=h-d;switch(p=S<=.5?v/(h+d):v/(2-h-d),h){case r:m=(l-c)/v+(l<c?6:0);break;case l:m=(c-r)/v+2;break;case c:m=(r-l)/v+4;break}m/=6}return e.h=m,e.s=p,e.l=S,e}getRGB(e,i=Re.workingColorSpace){return Re.fromWorkingColorSpace(bn.copy(this),i),e.r=bn.r,e.g=bn.g,e.b=bn.b,e}getStyle(e=li){Re.fromWorkingColorSpace(bn.copy(this),e);const i=bn.r,r=bn.g,l=bn.b;return e!==li?`color(${e} ${i.toFixed(3)} ${r.toFixed(3)} ${l.toFixed(3)})`:`rgb(${Math.round(i*255)},${Math.round(r*255)},${Math.round(l*255)})`}offsetHSL(e,i,r){return this.getHSL(Pa),this.setHSL(Pa.h+e,Pa.s+i,Pa.l+r)}add(e){return this.r+=e.r,this.g+=e.g,this.b+=e.b,this}addColors(e,i){return this.r=e.r+i.r,this.g=e.g+i.g,this.b=e.b+i.b,this}addScalar(e){return this.r+=e,this.g+=e,this.b+=e,this}sub(e){return this.r=Math.max(0,this.r-e.r),this.g=Math.max(0,this.g-e.g),this.b=Math.max(0,this.b-e.b),this}multiply(e){return this.r*=e.r,this.g*=e.g,this.b*=e.b,this}multiplyScalar(e){return this.r*=e,this.g*=e,this.b*=e,this}lerp(e,i){return this.r+=(e.r-this.r)*i,this.g+=(e.g-this.g)*i,this.b+=(e.b-this.b)*i,this}lerpColors(e,i,r){return this.r=e.r+(i.r-e.r)*r,this.g=e.g+(i.g-e.g)*r,this.b=e.b+(i.b-e.b)*r,this}lerpHSL(e,i){this.getHSL(Pa),e.getHSL(eu);const r=kf(Pa.h,eu.h,i),l=kf(Pa.s,eu.s,i),c=kf(Pa.l,eu.l,i);return this.setHSL(r,l,c),this}setFromVector3(e){return this.r=e.x,this.g=e.y,this.b=e.z,this}applyMatrix3(e){const i=this.r,r=this.g,l=this.b,c=e.elements;return this.r=c[0]*i+c[3]*r+c[6]*l,this.g=c[1]*i+c[4]*r+c[7]*l,this.b=c[2]*i+c[5]*r+c[8]*l,this}equals(e){return e.r===this.r&&e.g===this.g&&e.b===this.b}fromArray(e,i=0){return this.r=e[i],this.g=e[i+1],this.b=e[i+2],this}toArray(e=[],i=0){return e[i]=this.r,e[i+1]=this.g,e[i+2]=this.b,e}fromBufferAttribute(e,i){return this.r=e.getX(i),this.g=e.getY(i),this.b=e.getZ(i),this}toJSON(){return this.getHex()}*[Symbol.iterator](){yield this.r,yield this.g,yield this.b}}const bn=new Me;Me.NAMES=I0;let _M=0;class zo extends Es{constructor(){super(),this.isMaterial=!0,Object.defineProperty(this,"id",{value:_M++}),this.uuid=Lo(),this.name="",this.type="Material",this.blending=gs,this.side=Ga,this.vertexColors=!1,this.opacity=1,this.transparent=!1,this.alphaHash=!1,this.blendSrc=Mh,this.blendDst=yh,this.blendEquation=gr,this.blendSrcAlpha=null,this.blendDstAlpha=null,this.blendEquationAlpha=null,this.blendColor=new Me(0,0,0),this.blendAlpha=0,this.depthFunc=vs,this.depthTest=!0,this.depthWrite=!0,this.stencilWriteMask=255,this.stencilFunc=M_,this.stencilRef=0,this.stencilFuncMask=255,this.stencilFail=es,this.stencilZFail=es,this.stencilZPass=es,this.stencilWrite=!1,this.clippingPlanes=null,this.clipIntersection=!1,this.clipShadows=!1,this.shadowSide=null,this.colorWrite=!0,this.precision=null,this.polygonOffset=!1,this.polygonOffsetFactor=0,this.polygonOffsetUnits=0,this.dithering=!1,this.alphaToCoverage=!1,this.premultipliedAlpha=!1,this.forceSinglePass=!1,this.allowOverride=!0,this.visible=!0,this.toneMapped=!0,this.userData={},this.version=0,this._alphaTest=0}get alphaTest(){return this._alphaTest}set alphaTest(e){this._alphaTest>0!=e>0&&this.version++,this._alphaTest=e}onBeforeRender(){}onBeforeCompile(){}customProgramCacheKey(){return this.onBeforeCompile.toString()}setValues(e){if(e!==void 0)for(const i in e){const r=e[i];if(r===void 0){console.warn(`THREE.Material: parameter '${i}' has value of undefined.`);continue}const l=this[i];if(l===void 0){console.warn(`THREE.Material: '${i}' is not a property of THREE.${this.type}.`);continue}l&&l.isColor?l.set(r):l&&l.isVector3&&r&&r.isVector3?l.copy(r):this[i]=r}}toJSON(e){const i=e===void 0||typeof e=="string";i&&(e={textures:{},images:{}});const r={metadata:{version:4.6,type:"Material",generator:"Material.toJSON"}};r.uuid=this.uuid,r.type=this.type,this.name!==""&&(r.name=this.name),this.color&&this.color.isColor&&(r.color=this.color.getHex()),this.roughness!==void 0&&(r.roughness=this.roughness),this.metalness!==void 0&&(r.metalness=this.metalness),this.sheen!==void 0&&(r.sheen=this.sheen),this.sheenColor&&this.sheenColor.isColor&&(r.sheenColor=this.sheenColor.getHex()),this.sheenRoughness!==void 0&&(r.sheenRoughness=this.sheenRoughness),this.emissive&&this.emissive.isColor&&(r.emissive=this.emissive.getHex()),this.emissiveIntensity!==void 0&&this.emissiveIntensity!==1&&(r.emissiveIntensity=this.emissiveIntensity),this.specular&&this.specular.isColor&&(r.specular=this.specular.getHex()),this.specularIntensity!==void 0&&(r.specularIntensity=this.specularIntensity),this.specularColor&&this.specularColor.isColor&&(r.specularColor=this.specularColor.getHex()),this.shininess!==void 0&&(r.shininess=this.shininess),this.clearcoat!==void 0&&(r.clearcoat=this.clearcoat),this.clearcoatRoughness!==void 0&&(r.clearcoatRoughness=this.clearcoatRoughness),this.clearcoatMap&&this.clearcoatMap.isTexture&&(r.clearcoatMap=this.clearcoatMap.toJSON(e).uuid),this.clearcoatRoughnessMap&&this.clearcoatRoughnessMap.isTexture&&(r.clearcoatRoughnessMap=this.clearcoatRoughnessMap.toJSON(e).uuid),this.clearcoatNormalMap&&this.clearcoatNormalMap.isTexture&&(r.clearcoatNormalMap=this.clearcoatNormalMap.toJSON(e).uuid,r.clearcoatNormalScale=this.clearcoatNormalScale.toArray()),this.dispersion!==void 0&&(r.dispersion=this.dispersion),this.iridescence!==void 0&&(r.iridescence=this.iridescence),this.iridescenceIOR!==void 0&&(r.iridescenceIOR=this.iridescenceIOR),this.iridescenceThicknessRange!==void 0&&(r.iridescenceThicknessRange=this.iridescenceThicknessRange),this.iridescenceMap&&this.iridescenceMap.isTexture&&(r.iridescenceMap=this.iridescenceMap.toJSON(e).uuid),this.iridescenceThicknessMap&&this.iridescenceThicknessMap.isTexture&&(r.iridescenceThicknessMap=this.iridescenceThicknessMap.toJSON(e).uuid),this.anisotropy!==void 0&&(r.anisotropy=this.anisotropy),this.anisotropyRotation!==void 0&&(r.anisotropyRotation=this.anisotropyRotation),this.anisotropyMap&&this.anisotropyMap.isTexture&&(r.anisotropyMap=this.anisotropyMap.toJSON(e).uuid),this.map&&this.map.isTexture&&(r.map=this.map.toJSON(e).uuid),this.matcap&&this.matcap.isTexture&&(r.matcap=this.matcap.toJSON(e).uuid),this.alphaMap&&this.alphaMap.isTexture&&(r.alphaMap=this.alphaMap.toJSON(e).uuid),this.lightMap&&this.lightMap.isTexture&&(r.lightMap=this.lightMap.toJSON(e).uuid,r.lightMapIntensity=this.lightMapIntensity),this.aoMap&&this.aoMap.isTexture&&(r.aoMap=this.aoMap.toJSON(e).uuid,r.aoMapIntensity=this.aoMapIntensity),this.bumpMap&&this.bumpMap.isTexture&&(r.bumpMap=this.bumpMap.toJSON(e).uuid,r.bumpScale=this.bumpScale),this.normalMap&&this.normalMap.isTexture&&(r.normalMap=this.normalMap.toJSON(e).uuid,r.normalMapType=this.normalMapType,r.normalScale=this.normalScale.toArray()),this.displacementMap&&this.displacementMap.isTexture&&(r.displacementMap=this.displacementMap.toJSON(e).uuid,r.displacementScale=this.displacementScale,r.displacementBias=this.displacementBias),this.roughnessMap&&this.roughnessMap.isTexture&&(r.roughnessMap=this.roughnessMap.toJSON(e).uuid),this.metalnessMap&&this.metalnessMap.isTexture&&(r.metalnessMap=this.metalnessMap.toJSON(e).uuid),this.emissiveMap&&this.emissiveMap.isTexture&&(r.emissiveMap=this.emissiveMap.toJSON(e).uuid),this.specularMap&&this.specularMap.isTexture&&(r.specularMap=this.specularMap.toJSON(e).uuid),this.specularIntensityMap&&this.specularIntensityMap.isTexture&&(r.specularIntensityMap=this.specularIntensityMap.toJSON(e).uuid),this.specularColorMap&&this.specularColorMap.isTexture&&(r.specularColorMap=this.specularColorMap.toJSON(e).uuid),this.envMap&&this.envMap.isTexture&&(r.envMap=this.envMap.toJSON(e).uuid,this.combine!==void 0&&(r.combine=this.combine)),this.envMapRotation!==void 0&&(r.envMapRotation=this.envMapRotation.toArray()),this.envMapIntensity!==void 0&&(r.envMapIntensity=this.envMapIntensity),this.reflectivity!==void 0&&(r.reflectivity=this.reflectivity),this.refractionRatio!==void 0&&(r.refractionRatio=this.refractionRatio),this.gradientMap&&this.gradientMap.isTexture&&(r.gradientMap=this.gradientMap.toJSON(e).uuid),this.transmission!==void 0&&(r.transmission=this.transmission),this.transmissionMap&&this.transmissionMap.isTexture&&(r.transmissionMap=this.transmissionMap.toJSON(e).uuid),this.thickness!==void 0&&(r.thickness=this.thickness),this.thicknessMap&&this.thicknessMap.isTexture&&(r.thicknessMap=this.thicknessMap.toJSON(e).uuid),this.attenuationDistance!==void 0&&this.attenuationDistance!==1/0&&(r.attenuationDistance=this.attenuationDistance),this.attenuationColor!==void 0&&(r.attenuationColor=this.attenuationColor.getHex()),this.size!==void 0&&(r.size=this.size),this.shadowSide!==null&&(r.shadowSide=this.shadowSide),this.sizeAttenuation!==void 0&&(r.sizeAttenuation=this.sizeAttenuation),this.blending!==gs&&(r.blending=this.blending),this.side!==Ga&&(r.side=this.side),this.vertexColors===!0&&(r.vertexColors=!0),this.opacity<1&&(r.opacity=this.opacity),this.transparent===!0&&(r.transparent=!0),this.blendSrc!==Mh&&(r.blendSrc=this.blendSrc),this.blendDst!==yh&&(r.blendDst=this.blendDst),this.blendEquation!==gr&&(r.blendEquation=this.blendEquation),this.blendSrcAlpha!==null&&(r.blendSrcAlpha=this.blendSrcAlpha),this.blendDstAlpha!==null&&(r.blendDstAlpha=this.blendDstAlpha),this.blendEquationAlpha!==null&&(r.blendEquationAlpha=this.blendEquationAlpha),this.blendColor&&this.blendColor.isColor&&(r.blendColor=this.blendColor.getHex()),this.blendAlpha!==0&&(r.blendAlpha=this.blendAlpha),this.depthFunc!==vs&&(r.depthFunc=this.depthFunc),this.depthTest===!1&&(r.depthTest=this.depthTest),this.depthWrite===!1&&(r.depthWrite=this.depthWrite),this.colorWrite===!1&&(r.colorWrite=this.colorWrite),this.stencilWriteMask!==255&&(r.stencilWriteMask=this.stencilWriteMask),this.stencilFunc!==M_&&(r.stencilFunc=this.stencilFunc),this.stencilRef!==0&&(r.stencilRef=this.stencilRef),this.stencilFuncMask!==255&&(r.stencilFuncMask=this.stencilFuncMask),this.stencilFail!==es&&(r.stencilFail=this.stencilFail),this.stencilZFail!==es&&(r.stencilZFail=this.stencilZFail),this.stencilZPass!==es&&(r.stencilZPass=this.stencilZPass),this.stencilWrite===!0&&(r.stencilWrite=this.stencilWrite),this.rotation!==void 0&&this.rotation!==0&&(r.rotation=this.rotation),this.polygonOffset===!0&&(r.polygonOffset=!0),this.polygonOffsetFactor!==0&&(r.polygonOffsetFactor=this.polygonOffsetFactor),this.polygonOffsetUnits!==0&&(r.polygonOffsetUnits=this.polygonOffsetUnits),this.linewidth!==void 0&&this.linewidth!==1&&(r.linewidth=this.linewidth),this.dashSize!==void 0&&(r.dashSize=this.dashSize),this.gapSize!==void 0&&(r.gapSize=this.gapSize),this.scale!==void 0&&(r.scale=this.scale),this.dithering===!0&&(r.dithering=!0),this.alphaTest>0&&(r.alphaTest=this.alphaTest),this.alphaHash===!0&&(r.alphaHash=!0),this.alphaToCoverage===!0&&(r.alphaToCoverage=!0),this.premultipliedAlpha===!0&&(r.premultipliedAlpha=!0),this.forceSinglePass===!0&&(r.forceSinglePass=!0),this.wireframe===!0&&(r.wireframe=!0),this.wireframeLinewidth>1&&(r.wireframeLinewidth=this.wireframeLinewidth),this.wireframeLinecap!=="round"&&(r.wireframeLinecap=this.wireframeLinecap),this.wireframeLinejoin!=="round"&&(r.wireframeLinejoin=this.wireframeLinejoin),this.flatShading===!0&&(r.flatShading=!0),this.visible===!1&&(r.visible=!1),this.toneMapped===!1&&(r.toneMapped=!1),this.fog===!1&&(r.fog=!1),Object.keys(this.userData).length>0&&(r.userData=this.userData);function l(c){const h=[];for(const d in c){const m=c[d];delete m.metadata,h.push(m)}return h}if(i){const c=l(e.textures),h=l(e.images);c.length>0&&(r.textures=c),h.length>0&&(r.images=h)}return r}clone(){return new this.constructor().copy(this)}copy(e){this.name=e.name,this.blending=e.blending,this.side=e.side,this.vertexColors=e.vertexColors,this.opacity=e.opacity,this.transparent=e.transparent,this.blendSrc=e.blendSrc,this.blendDst=e.blendDst,this.blendEquation=e.blendEquation,this.blendSrcAlpha=e.blendSrcAlpha,this.blendDstAlpha=e.blendDstAlpha,this.blendEquationAlpha=e.blendEquationAlpha,this.blendColor.copy(e.blendColor),this.blendAlpha=e.blendAlpha,this.depthFunc=e.depthFunc,this.depthTest=e.depthTest,this.depthWrite=e.depthWrite,this.stencilWriteMask=e.stencilWriteMask,this.stencilFunc=e.stencilFunc,this.stencilRef=e.stencilRef,this.stencilFuncMask=e.stencilFuncMask,this.stencilFail=e.stencilFail,this.stencilZFail=e.stencilZFail,this.stencilZPass=e.stencilZPass,this.stencilWrite=e.stencilWrite;const i=e.clippingPlanes;let r=null;if(i!==null){const l=i.length;r=new Array(l);for(let c=0;c!==l;++c)r[c]=i[c].clone()}return this.clippingPlanes=r,this.clipIntersection=e.clipIntersection,this.clipShadows=e.clipShadows,this.shadowSide=e.shadowSide,this.colorWrite=e.colorWrite,this.precision=e.precision,this.polygonOffset=e.polygonOffset,this.polygonOffsetFactor=e.polygonOffsetFactor,this.polygonOffsetUnits=e.polygonOffsetUnits,this.dithering=e.dithering,this.alphaTest=e.alphaTest,this.alphaHash=e.alphaHash,this.alphaToCoverage=e.alphaToCoverage,this.premultipliedAlpha=e.premultipliedAlpha,this.forceSinglePass=e.forceSinglePass,this.visible=e.visible,this.toneMapped=e.toneMapped,this.userData=JSON.parse(JSON.stringify(e.userData)),this}dispose(){this.dispatchEvent({type:"dispose"})}set needsUpdate(e){e===!0&&this.version++}}class vd extends zo{constructor(e){super(),this.isMeshBasicMaterial=!0,this.type="MeshBasicMaterial",this.color=new Me(16777215),this.map=null,this.lightMap=null,this.lightMapIntensity=1,this.aoMap=null,this.aoMapIntensity=1,this.specularMap=null,this.alphaMap=null,this.envMap=null,this.envMapRotation=new Li,this.combine=y0,this.reflectivity=1,this.refractionRatio=.98,this.wireframe=!1,this.wireframeLinewidth=1,this.wireframeLinecap="round",this.wireframeLinejoin="round",this.fog=!0,this.setValues(e)}copy(e){return super.copy(e),this.color.copy(e.color),this.map=e.map,this.lightMap=e.lightMap,this.lightMapIntensity=e.lightMapIntensity,this.aoMap=e.aoMap,this.aoMapIntensity=e.aoMapIntensity,this.specularMap=e.specularMap,this.alphaMap=e.alphaMap,this.envMap=e.envMap,this.envMapRotation.copy(e.envMapRotation),this.combine=e.combine,this.reflectivity=e.reflectivity,this.refractionRatio=e.refractionRatio,this.wireframe=e.wireframe,this.wireframeLinewidth=e.wireframeLinewidth,this.wireframeLinecap=e.wireframeLinecap,this.wireframeLinejoin=e.wireframeLinejoin,this.fog=e.fog,this}}const rn=new Q,nu=new ye;let vM=0;class Di{constructor(e,i,r=!1){if(Array.isArray(e))throw new TypeError("THREE.BufferAttribute: array should be a Typed Array.");this.isBufferAttribute=!0,Object.defineProperty(this,"id",{value:vM++}),this.name="",this.array=e,this.itemSize=i,this.count=e!==void 0?e.length/i:0,this.normalized=r,this.usage=y_,this.updateRanges=[],this.gpuType=sa,this.version=0}onUploadCallback(){}set needsUpdate(e){e===!0&&this.version++}setUsage(e){return this.usage=e,this}addUpdateRange(e,i){this.updateRanges.push({start:e,count:i})}clearUpdateRanges(){this.updateRanges.length=0}copy(e){return this.name=e.name,this.array=new e.array.constructor(e.array),this.itemSize=e.itemSize,this.count=e.count,this.normalized=e.normalized,this.usage=e.usage,this.gpuType=e.gpuType,this}copyAt(e,i,r){e*=this.itemSize,r*=i.itemSize;for(let l=0,c=this.itemSize;l<c;l++)this.array[e+l]=i.array[r+l];return this}copyArray(e){return this.array.set(e),this}applyMatrix3(e){if(this.itemSize===2)for(let i=0,r=this.count;i<r;i++)nu.fromBufferAttribute(this,i),nu.applyMatrix3(e),this.setXY(i,nu.x,nu.y);else if(this.itemSize===3)for(let i=0,r=this.count;i<r;i++)rn.fromBufferAttribute(this,i),rn.applyMatrix3(e),this.setXYZ(i,rn.x,rn.y,rn.z);return this}applyMatrix4(e){for(let i=0,r=this.count;i<r;i++)rn.fromBufferAttribute(this,i),rn.applyMatrix4(e),this.setXYZ(i,rn.x,rn.y,rn.z);return this}applyNormalMatrix(e){for(let i=0,r=this.count;i<r;i++)rn.fromBufferAttribute(this,i),rn.applyNormalMatrix(e),this.setXYZ(i,rn.x,rn.y,rn.z);return this}transformDirection(e){for(let i=0,r=this.count;i<r;i++)rn.fromBufferAttribute(this,i),rn.transformDirection(e),this.setXYZ(i,rn.x,rn.y,rn.z);return this}set(e,i=0){return this.array.set(e,i),this}getComponent(e,i){let r=this.array[e*this.itemSize+i];return this.normalized&&(r=xo(r,this.array)),r}setComponent(e,i,r){return this.normalized&&(r=Hn(r,this.array)),this.array[e*this.itemSize+i]=r,this}getX(e){let i=this.array[e*this.itemSize];return this.normalized&&(i=xo(i,this.array)),i}setX(e,i){return this.normalized&&(i=Hn(i,this.array)),this.array[e*this.itemSize]=i,this}getY(e){let i=this.array[e*this.itemSize+1];return this.normalized&&(i=xo(i,this.array)),i}setY(e,i){return this.normalized&&(i=Hn(i,this.array)),this.array[e*this.itemSize+1]=i,this}getZ(e){let i=this.array[e*this.itemSize+2];return this.normalized&&(i=xo(i,this.array)),i}setZ(e,i){return this.normalized&&(i=Hn(i,this.array)),this.array[e*this.itemSize+2]=i,this}getW(e){let i=this.array[e*this.itemSize+3];return this.normalized&&(i=xo(i,this.array)),i}setW(e,i){return this.normalized&&(i=Hn(i,this.array)),this.array[e*this.itemSize+3]=i,this}setXY(e,i,r){return e*=this.itemSize,this.normalized&&(i=Hn(i,this.array),r=Hn(r,this.array)),this.array[e+0]=i,this.array[e+1]=r,this}setXYZ(e,i,r,l){return e*=this.itemSize,this.normalized&&(i=Hn(i,this.array),r=Hn(r,this.array),l=Hn(l,this.array)),this.array[e+0]=i,this.array[e+1]=r,this.array[e+2]=l,this}setXYZW(e,i,r,l,c){return e*=this.itemSize,this.normalized&&(i=Hn(i,this.array),r=Hn(r,this.array),l=Hn(l,this.array),c=Hn(c,this.array)),this.array[e+0]=i,this.array[e+1]=r,this.array[e+2]=l,this.array[e+3]=c,this}onUpload(e){return this.onUploadCallback=e,this}clone(){return new this.constructor(this.array,this.itemSize).copy(this)}toJSON(){const e={itemSize:this.itemSize,type:this.array.constructor.name,array:Array.from(this.array),normalized:this.normalized};return this.name!==""&&(e.name=this.name),this.usage!==y_&&(e.usage=this.usage),e}}class F0 extends Di{constructor(e,i,r){super(new Uint16Array(e),i,r)}}class H0 extends Di{constructor(e,i,r){super(new Uint32Array(e),i,r)}}class Rn extends Di{constructor(e,i,r){super(new Float32Array(e),i,r)}}let SM=0;const oi=new Ye,lh=new An,fs=new Q,Qn=new Oo,To=new Oo,dn=new Q;class Ni extends Es{constructor(){super(),this.isBufferGeometry=!0,Object.defineProperty(this,"id",{value:SM++}),this.uuid=Lo(),this.name="",this.type="BufferGeometry",this.index=null,this.indirect=null,this.attributes={},this.morphAttributes={},this.morphTargetsRelative=!1,this.groups=[],this.boundingBox=null,this.boundingSphere=null,this.drawRange={start:0,count:1/0},this.userData={}}getIndex(){return this.index}setIndex(e){return Array.isArray(e)?this.index=new(z0(e)?H0:F0)(e,1):this.index=e,this}setIndirect(e){return this.indirect=e,this}getIndirect(){return this.indirect}getAttribute(e){return this.attributes[e]}setAttribute(e,i){return this.attributes[e]=i,this}deleteAttribute(e){return delete this.attributes[e],this}hasAttribute(e){return this.attributes[e]!==void 0}addGroup(e,i,r=0){this.groups.push({start:e,count:i,materialIndex:r})}clearGroups(){this.groups=[]}setDrawRange(e,i){this.drawRange.start=e,this.drawRange.count=i}applyMatrix4(e){const i=this.attributes.position;i!==void 0&&(i.applyMatrix4(e),i.needsUpdate=!0);const r=this.attributes.normal;if(r!==void 0){const c=new oe().getNormalMatrix(e);r.applyNormalMatrix(c),r.needsUpdate=!0}const l=this.attributes.tangent;return l!==void 0&&(l.transformDirection(e),l.needsUpdate=!0),this.boundingBox!==null&&this.computeBoundingBox(),this.boundingSphere!==null&&this.computeBoundingSphere(),this}applyQuaternion(e){return oi.makeRotationFromQuaternion(e),this.applyMatrix4(oi),this}rotateX(e){return oi.makeRotationX(e),this.applyMatrix4(oi),this}rotateY(e){return oi.makeRotationY(e),this.applyMatrix4(oi),this}rotateZ(e){return oi.makeRotationZ(e),this.applyMatrix4(oi),this}translate(e,i,r){return oi.makeTranslation(e,i,r),this.applyMatrix4(oi),this}scale(e,i,r){return oi.makeScale(e,i,r),this.applyMatrix4(oi),this}lookAt(e){return lh.lookAt(e),lh.updateMatrix(),this.applyMatrix4(lh.matrix),this}center(){return this.computeBoundingBox(),this.boundingBox.getCenter(fs).negate(),this.translate(fs.x,fs.y,fs.z),this}setFromPoints(e){const i=this.getAttribute("position");if(i===void 0){const r=[];for(let l=0,c=e.length;l<c;l++){const h=e[l];r.push(h.x,h.y,h.z||0)}this.setAttribute("position",new Rn(r,3))}else{const r=Math.min(e.length,i.count);for(let l=0;l<r;l++){const c=e[l];i.setXYZ(l,c.x,c.y,c.z||0)}e.length>i.count&&console.warn("THREE.BufferGeometry: Buffer size too small for points data. Use .dispose() and create a new geometry."),i.needsUpdate=!0}return this}computeBoundingBox(){this.boundingBox===null&&(this.boundingBox=new Oo);const e=this.attributes.position,i=this.morphAttributes.position;if(e&&e.isGLBufferAttribute){console.error("THREE.BufferGeometry.computeBoundingBox(): GLBufferAttribute requires a manual bounding box.",this),this.boundingBox.set(new Q(-1/0,-1/0,-1/0),new Q(1/0,1/0,1/0));return}if(e!==void 0){if(this.boundingBox.setFromBufferAttribute(e),i)for(let r=0,l=i.length;r<l;r++){const c=i[r];Qn.setFromBufferAttribute(c),this.morphTargetsRelative?(dn.addVectors(this.boundingBox.min,Qn.min),this.boundingBox.expandByPoint(dn),dn.addVectors(this.boundingBox.max,Qn.max),this.boundingBox.expandByPoint(dn)):(this.boundingBox.expandByPoint(Qn.min),this.boundingBox.expandByPoint(Qn.max))}}else this.boundingBox.makeEmpty();(isNaN(this.boundingBox.min.x)||isNaN(this.boundingBox.min.y)||isNaN(this.boundingBox.min.z))&&console.error('THREE.BufferGeometry.computeBoundingBox(): Computed min/max have NaN values. The "position" attribute is likely to have NaN values.',this)}computeBoundingSphere(){this.boundingSphere===null&&(this.boundingSphere=new _d);const e=this.attributes.position,i=this.morphAttributes.position;if(e&&e.isGLBufferAttribute){console.error("THREE.BufferGeometry.computeBoundingSphere(): GLBufferAttribute requires a manual bounding sphere.",this),this.boundingSphere.set(new Q,1/0);return}if(e){const r=this.boundingSphere.center;if(Qn.setFromBufferAttribute(e),i)for(let c=0,h=i.length;c<h;c++){const d=i[c];To.setFromBufferAttribute(d),this.morphTargetsRelative?(dn.addVectors(Qn.min,To.min),Qn.expandByPoint(dn),dn.addVectors(Qn.max,To.max),Qn.expandByPoint(dn)):(Qn.expandByPoint(To.min),Qn.expandByPoint(To.max))}Qn.getCenter(r);let l=0;for(let c=0,h=e.count;c<h;c++)dn.fromBufferAttribute(e,c),l=Math.max(l,r.distanceToSquared(dn));if(i)for(let c=0,h=i.length;c<h;c++){const d=i[c],m=this.morphTargetsRelative;for(let p=0,S=d.count;p<S;p++)dn.fromBufferAttribute(d,p),m&&(fs.fromBufferAttribute(e,p),dn.add(fs)),l=Math.max(l,r.distanceToSquared(dn))}this.boundingSphere.radius=Math.sqrt(l),isNaN(this.boundingSphere.radius)&&console.error('THREE.BufferGeometry.computeBoundingSphere(): Computed radius is NaN. The "position" attribute is likely to have NaN values.',this)}}computeTangents(){const e=this.index,i=this.attributes;if(e===null||i.position===void 0||i.normal===void 0||i.uv===void 0){console.error("THREE.BufferGeometry: .computeTangents() failed. Missing required attributes (index, position, normal or uv)");return}const r=i.position,l=i.normal,c=i.uv;this.hasAttribute("tangent")===!1&&this.setAttribute("tangent",new Di(new Float32Array(4*r.count),4));const h=this.getAttribute("tangent"),d=[],m=[];for(let V=0;V<r.count;V++)d[V]=new Q,m[V]=new Q;const p=new Q,S=new Q,v=new Q,x=new ye,y=new ye,R=new ye,w=new Q,M=new Q;function _(V,D,b){p.fromBufferAttribute(r,V),S.fromBufferAttribute(r,D),v.fromBufferAttribute(r,b),x.fromBufferAttribute(c,V),y.fromBufferAttribute(c,D),R.fromBufferAttribute(c,b),S.sub(p),v.sub(p),y.sub(x),R.sub(x);const B=1/(y.x*R.y-R.x*y.y);isFinite(B)&&(w.copy(S).multiplyScalar(R.y).addScaledVector(v,-y.y).multiplyScalar(B),M.copy(v).multiplyScalar(y.x).addScaledVector(S,-R.x).multiplyScalar(B),d[V].add(w),d[D].add(w),d[b].add(w),m[V].add(M),m[D].add(M),m[b].add(M))}let L=this.groups;L.length===0&&(L=[{start:0,count:e.count}]);for(let V=0,D=L.length;V<D;++V){const b=L[V],B=b.start,rt=b.count;for(let st=B,dt=B+rt;st<dt;st+=3)_(e.getX(st+0),e.getX(st+1),e.getX(st+2))}const U=new Q,C=new Q,G=new Q,I=new Q;function O(V){G.fromBufferAttribute(l,V),I.copy(G);const D=d[V];U.copy(D),U.sub(G.multiplyScalar(G.dot(D))).normalize(),C.crossVectors(I,D);const B=C.dot(m[V])<0?-1:1;h.setXYZW(V,U.x,U.y,U.z,B)}for(let V=0,D=L.length;V<D;++V){const b=L[V],B=b.start,rt=b.count;for(let st=B,dt=B+rt;st<dt;st+=3)O(e.getX(st+0)),O(e.getX(st+1)),O(e.getX(st+2))}}computeVertexNormals(){const e=this.index,i=this.getAttribute("position");if(i!==void 0){let r=this.getAttribute("normal");if(r===void 0)r=new Di(new Float32Array(i.count*3),3),this.setAttribute("normal",r);else for(let x=0,y=r.count;x<y;x++)r.setXYZ(x,0,0,0);const l=new Q,c=new Q,h=new Q,d=new Q,m=new Q,p=new Q,S=new Q,v=new Q;if(e)for(let x=0,y=e.count;x<y;x+=3){const R=e.getX(x+0),w=e.getX(x+1),M=e.getX(x+2);l.fromBufferAttribute(i,R),c.fromBufferAttribute(i,w),h.fromBufferAttribute(i,M),S.subVectors(h,c),v.subVectors(l,c),S.cross(v),d.fromBufferAttribute(r,R),m.fromBufferAttribute(r,w),p.fromBufferAttribute(r,M),d.add(S),m.add(S),p.add(S),r.setXYZ(R,d.x,d.y,d.z),r.setXYZ(w,m.x,m.y,m.z),r.setXYZ(M,p.x,p.y,p.z)}else for(let x=0,y=i.count;x<y;x+=3)l.fromBufferAttribute(i,x+0),c.fromBufferAttribute(i,x+1),h.fromBufferAttribute(i,x+2),S.subVectors(h,c),v.subVectors(l,c),S.cross(v),r.setXYZ(x+0,S.x,S.y,S.z),r.setXYZ(x+1,S.x,S.y,S.z),r.setXYZ(x+2,S.x,S.y,S.z);this.normalizeNormals(),r.needsUpdate=!0}}normalizeNormals(){const e=this.attributes.normal;for(let i=0,r=e.count;i<r;i++)dn.fromBufferAttribute(e,i),dn.normalize(),e.setXYZ(i,dn.x,dn.y,dn.z)}toNonIndexed(){function e(d,m){const p=d.array,S=d.itemSize,v=d.normalized,x=new p.constructor(m.length*S);let y=0,R=0;for(let w=0,M=m.length;w<M;w++){d.isInterleavedBufferAttribute?y=m[w]*d.data.stride+d.offset:y=m[w]*S;for(let _=0;_<S;_++)x[R++]=p[y++]}return new Di(x,S,v)}if(this.index===null)return console.warn("THREE.BufferGeometry.toNonIndexed(): BufferGeometry is already non-indexed."),this;const i=new Ni,r=this.index.array,l=this.attributes;for(const d in l){const m=l[d],p=e(m,r);i.setAttribute(d,p)}const c=this.morphAttributes;for(const d in c){const m=[],p=c[d];for(let S=0,v=p.length;S<v;S++){const x=p[S],y=e(x,r);m.push(y)}i.morphAttributes[d]=m}i.morphTargetsRelative=this.morphTargetsRelative;const h=this.groups;for(let d=0,m=h.length;d<m;d++){const p=h[d];i.addGroup(p.start,p.count,p.materialIndex)}return i}toJSON(){const e={metadata:{version:4.6,type:"BufferGeometry",generator:"BufferGeometry.toJSON"}};if(e.uuid=this.uuid,e.type=this.type,this.name!==""&&(e.name=this.name),Object.keys(this.userData).length>0&&(e.userData=this.userData),this.parameters!==void 0){const m=this.parameters;for(const p in m)m[p]!==void 0&&(e[p]=m[p]);return e}e.data={attributes:{}};const i=this.index;i!==null&&(e.data.index={type:i.array.constructor.name,array:Array.prototype.slice.call(i.array)});const r=this.attributes;for(const m in r){const p=r[m];e.data.attributes[m]=p.toJSON(e.data)}const l={};let c=!1;for(const m in this.morphAttributes){const p=this.morphAttributes[m],S=[];for(let v=0,x=p.length;v<x;v++){const y=p[v];S.push(y.toJSON(e.data))}S.length>0&&(l[m]=S,c=!0)}c&&(e.data.morphAttributes=l,e.data.morphTargetsRelative=this.morphTargetsRelative);const h=this.groups;h.length>0&&(e.data.groups=JSON.parse(JSON.stringify(h)));const d=this.boundingSphere;return d!==null&&(e.data.boundingSphere={center:d.center.toArray(),radius:d.radius}),e}clone(){return new this.constructor().copy(this)}copy(e){this.index=null,this.attributes={},this.morphAttributes={},this.groups=[],this.boundingBox=null,this.boundingSphere=null;const i={};this.name=e.name;const r=e.index;r!==null&&this.setIndex(r.clone());const l=e.attributes;for(const p in l){const S=l[p];this.setAttribute(p,S.clone(i))}const c=e.morphAttributes;for(const p in c){const S=[],v=c[p];for(let x=0,y=v.length;x<y;x++)S.push(v[x].clone(i));this.morphAttributes[p]=S}this.morphTargetsRelative=e.morphTargetsRelative;const h=e.groups;for(let p=0,S=h.length;p<S;p++){const v=h[p];this.addGroup(v.start,v.count,v.materialIndex)}const d=e.boundingBox;d!==null&&(this.boundingBox=d.clone());const m=e.boundingSphere;return m!==null&&(this.boundingSphere=m.clone()),this.drawRange.start=e.drawRange.start,this.drawRange.count=e.drawRange.count,this.userData=e.userData,this}dispose(){this.dispatchEvent({type:"dispose"})}}const P_=new Ye,cr=new cM,iu=new _d,B_=new Q,au=new Q,ru=new Q,su=new Q,uh=new Q,ou=new Q,I_=new Q,lu=new Q;class ui extends An{constructor(e=new Ni,i=new vd){super(),this.isMesh=!0,this.type="Mesh",this.geometry=e,this.material=i,this.morphTargetDictionary=void 0,this.morphTargetInfluences=void 0,this.updateMorphTargets()}copy(e,i){return super.copy(e,i),e.morphTargetInfluences!==void 0&&(this.morphTargetInfluences=e.morphTargetInfluences.slice()),e.morphTargetDictionary!==void 0&&(this.morphTargetDictionary=Object.assign({},e.morphTargetDictionary)),this.material=Array.isArray(e.material)?e.material.slice():e.material,this.geometry=e.geometry,this}updateMorphTargets(){const i=this.geometry.morphAttributes,r=Object.keys(i);if(r.length>0){const l=i[r[0]];if(l!==void 0){this.morphTargetInfluences=[],this.morphTargetDictionary={};for(let c=0,h=l.length;c<h;c++){const d=l[c].name||String(c);this.morphTargetInfluences.push(0),this.morphTargetDictionary[d]=c}}}}getVertexPosition(e,i){const r=this.geometry,l=r.attributes.position,c=r.morphAttributes.position,h=r.morphTargetsRelative;i.fromBufferAttribute(l,e);const d=this.morphTargetInfluences;if(c&&d){ou.set(0,0,0);for(let m=0,p=c.length;m<p;m++){const S=d[m],v=c[m];S!==0&&(uh.fromBufferAttribute(v,e),h?ou.addScaledVector(uh,S):ou.addScaledVector(uh.sub(i),S))}i.add(ou)}return i}raycast(e,i){const r=this.geometry,l=this.material,c=this.matrixWorld;l!==void 0&&(r.boundingSphere===null&&r.computeBoundingSphere(),iu.copy(r.boundingSphere),iu.applyMatrix4(c),cr.copy(e.ray).recast(e.near),!(iu.containsPoint(cr.origin)===!1&&(cr.intersectSphere(iu,B_)===null||cr.origin.distanceToSquared(B_)>(e.far-e.near)**2))&&(P_.copy(c).invert(),cr.copy(e.ray).applyMatrix4(P_),!(r.boundingBox!==null&&cr.intersectsBox(r.boundingBox)===!1)&&this._computeIntersections(e,i,cr)))}_computeIntersections(e,i,r){let l;const c=this.geometry,h=this.material,d=c.index,m=c.attributes.position,p=c.attributes.uv,S=c.attributes.uv1,v=c.attributes.normal,x=c.groups,y=c.drawRange;if(d!==null)if(Array.isArray(h))for(let R=0,w=x.length;R<w;R++){const M=x[R],_=h[M.materialIndex],L=Math.max(M.start,y.start),U=Math.min(d.count,Math.min(M.start+M.count,y.start+y.count));for(let C=L,G=U;C<G;C+=3){const I=d.getX(C),O=d.getX(C+1),V=d.getX(C+2);l=uu(this,_,e,r,p,S,v,I,O,V),l&&(l.faceIndex=Math.floor(C/3),l.face.materialIndex=M.materialIndex,i.push(l))}}else{const R=Math.max(0,y.start),w=Math.min(d.count,y.start+y.count);for(let M=R,_=w;M<_;M+=3){const L=d.getX(M),U=d.getX(M+1),C=d.getX(M+2);l=uu(this,h,e,r,p,S,v,L,U,C),l&&(l.faceIndex=Math.floor(M/3),i.push(l))}}else if(m!==void 0)if(Array.isArray(h))for(let R=0,w=x.length;R<w;R++){const M=x[R],_=h[M.materialIndex],L=Math.max(M.start,y.start),U=Math.min(m.count,Math.min(M.start+M.count,y.start+y.count));for(let C=L,G=U;C<G;C+=3){const I=C,O=C+1,V=C+2;l=uu(this,_,e,r,p,S,v,I,O,V),l&&(l.faceIndex=Math.floor(C/3),l.face.materialIndex=M.materialIndex,i.push(l))}}else{const R=Math.max(0,y.start),w=Math.min(m.count,y.start+y.count);for(let M=R,_=w;M<_;M+=3){const L=M,U=M+1,C=M+2;l=uu(this,h,e,r,p,S,v,L,U,C),l&&(l.faceIndex=Math.floor(M/3),i.push(l))}}}}function xM(o,e,i,r,l,c,h,d){let m;if(e.side===Gn?m=r.intersectTriangle(h,c,l,!0,d):m=r.intersectTriangle(l,c,h,e.side===Ga,d),m===null)return null;lu.copy(d),lu.applyMatrix4(o.matrixWorld);const p=i.ray.origin.distanceTo(lu);return p<i.near||p>i.far?null:{distance:p,point:lu.clone(),object:o}}function uu(o,e,i,r,l,c,h,d,m,p){o.getVertexPosition(d,au),o.getVertexPosition(m,ru),o.getVertexPosition(p,su);const S=xM(o,e,i,r,au,ru,su,I_);if(S){const v=new Q;xi.getBarycoord(I_,au,ru,su,v),l&&(S.uv=xi.getInterpolatedAttribute(l,d,m,p,v,new ye)),c&&(S.uv1=xi.getInterpolatedAttribute(c,d,m,p,v,new ye)),h&&(S.normal=xi.getInterpolatedAttribute(h,d,m,p,v,new Q),S.normal.dot(r.direction)>0&&S.normal.multiplyScalar(-1));const x={a:d,b:m,c:p,normal:new Q,materialIndex:0};xi.getNormal(au,ru,su,x.normal),S.face=x,S.barycoord=v}return S}class Po extends Ni{constructor(e=1,i=1,r=1,l=1,c=1,h=1){super(),this.type="BoxGeometry",this.parameters={width:e,height:i,depth:r,widthSegments:l,heightSegments:c,depthSegments:h};const d=this;l=Math.floor(l),c=Math.floor(c),h=Math.floor(h);const m=[],p=[],S=[],v=[];let x=0,y=0;R("z","y","x",-1,-1,r,i,e,h,c,0),R("z","y","x",1,-1,r,i,-e,h,c,1),R("x","z","y",1,1,e,r,i,l,h,2),R("x","z","y",1,-1,e,r,-i,l,h,3),R("x","y","z",1,-1,e,i,r,l,c,4),R("x","y","z",-1,-1,e,i,-r,l,c,5),this.setIndex(m),this.setAttribute("position",new Rn(p,3)),this.setAttribute("normal",new Rn(S,3)),this.setAttribute("uv",new Rn(v,2));function R(w,M,_,L,U,C,G,I,O,V,D){const b=C/O,B=G/V,rt=C/2,st=G/2,dt=I/2,pt=O+1,P=V+1;let Y=0,j=0;const vt=new Q;for(let Tt=0;Tt<P;Tt++){const z=Tt*B-st;for(let nt=0;nt<pt;nt++){const xt=nt*b-rt;vt[w]=xt*L,vt[M]=z*U,vt[_]=dt,p.push(vt.x,vt.y,vt.z),vt[w]=0,vt[M]=0,vt[_]=I>0?1:-1,S.push(vt.x,vt.y,vt.z),v.push(nt/O),v.push(1-Tt/V),Y+=1}}for(let Tt=0;Tt<V;Tt++)for(let z=0;z<O;z++){const nt=x+z+pt*Tt,xt=x+z+pt*(Tt+1),K=x+(z+1)+pt*(Tt+1),ft=x+(z+1)+pt*Tt;m.push(nt,xt,ft),m.push(xt,K,ft),j+=6}d.addGroup(y,j,D),y+=j,x+=Y}}copy(e){return super.copy(e),this.parameters=Object.assign({},e.parameters),this}static fromJSON(e){return new Po(e.width,e.height,e.depth,e.widthSegments,e.heightSegments,e.depthSegments)}}function ys(o){const e={};for(const i in o){e[i]={};for(const r in o[i]){const l=o[i][r];l&&(l.isColor||l.isMatrix3||l.isMatrix4||l.isVector2||l.isVector3||l.isVector4||l.isTexture||l.isQuaternion)?l.isRenderTargetTexture?(console.warn("UniformsUtils: Textures of render targets cannot be cloned via cloneUniforms() or mergeUniforms()."),e[i][r]=null):e[i][r]=l.clone():Array.isArray(l)?e[i][r]=l.slice():e[i][r]=l}}return e}function Un(o){const e={};for(let i=0;i<o.length;i++){const r=ys(o[i]);for(const l in r)e[l]=r[l]}return e}function MM(o){const e=[];for(let i=0;i<o.length;i++)e.push(o[i].clone());return e}function G0(o){const e=o.getRenderTarget();return e===null?o.outputColorSpace:e.isXRRenderTarget===!0?e.texture.colorSpace:Re.workingColorSpace}const yM={clone:ys,merge:Un};var EM=`void main() {
	gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );
}`,TM=`void main() {
	gl_FragColor = vec4( 1.0, 0.0, 0.0, 1.0 );
}`;class Va extends zo{constructor(e){super(),this.isShaderMaterial=!0,this.type="ShaderMaterial",this.defines={},this.uniforms={},this.uniformsGroups=[],this.vertexShader=EM,this.fragmentShader=TM,this.linewidth=1,this.wireframe=!1,this.wireframeLinewidth=1,this.fog=!1,this.lights=!1,this.clipping=!1,this.forceSinglePass=!0,this.extensions={clipCullDistance:!1,multiDraw:!1},this.defaultAttributeValues={color:[1,1,1],uv:[0,0],uv1:[0,0]},this.index0AttributeName=void 0,this.uniformsNeedUpdate=!1,this.glslVersion=null,e!==void 0&&this.setValues(e)}copy(e){return super.copy(e),this.fragmentShader=e.fragmentShader,this.vertexShader=e.vertexShader,this.uniforms=ys(e.uniforms),this.uniformsGroups=MM(e.uniformsGroups),this.defines=Object.assign({},e.defines),this.wireframe=e.wireframe,this.wireframeLinewidth=e.wireframeLinewidth,this.fog=e.fog,this.lights=e.lights,this.clipping=e.clipping,this.extensions=Object.assign({},e.extensions),this.glslVersion=e.glslVersion,this}toJSON(e){const i=super.toJSON(e);i.glslVersion=this.glslVersion,i.uniforms={};for(const l in this.uniforms){const h=this.uniforms[l].value;h&&h.isTexture?i.uniforms[l]={type:"t",value:h.toJSON(e).uuid}:h&&h.isColor?i.uniforms[l]={type:"c",value:h.getHex()}:h&&h.isVector2?i.uniforms[l]={type:"v2",value:h.toArray()}:h&&h.isVector3?i.uniforms[l]={type:"v3",value:h.toArray()}:h&&h.isVector4?i.uniforms[l]={type:"v4",value:h.toArray()}:h&&h.isMatrix3?i.uniforms[l]={type:"m3",value:h.toArray()}:h&&h.isMatrix4?i.uniforms[l]={type:"m4",value:h.toArray()}:i.uniforms[l]={value:h}}Object.keys(this.defines).length>0&&(i.defines=this.defines),i.vertexShader=this.vertexShader,i.fragmentShader=this.fragmentShader,i.lights=this.lights,i.clipping=this.clipping;const r={};for(const l in this.extensions)this.extensions[l]===!0&&(r[l]=!0);return Object.keys(r).length>0&&(i.extensions=r),i}}class V0 extends An{constructor(){super(),this.isCamera=!0,this.type="Camera",this.matrixWorldInverse=new Ye,this.projectionMatrix=new Ye,this.projectionMatrixInverse=new Ye,this.coordinateSystem=oa}copy(e,i){return super.copy(e,i),this.matrixWorldInverse.copy(e.matrixWorldInverse),this.projectionMatrix.copy(e.projectionMatrix),this.projectionMatrixInverse.copy(e.projectionMatrixInverse),this.coordinateSystem=e.coordinateSystem,this}getWorldDirection(e){return super.getWorldDirection(e).negate()}updateMatrixWorld(e){super.updateMatrixWorld(e),this.matrixWorldInverse.copy(this.matrixWorld).invert()}updateWorldMatrix(e,i){super.updateWorldMatrix(e,i),this.matrixWorldInverse.copy(this.matrixWorld).invert()}clone(){return new this.constructor().copy(this)}}const Ba=new Q,F_=new ye,H_=new ye;class Jn extends V0{constructor(e=50,i=1,r=.1,l=2e3){super(),this.isPerspectiveCamera=!0,this.type="PerspectiveCamera",this.fov=e,this.zoom=1,this.near=r,this.far=l,this.focus=10,this.aspect=i,this.view=null,this.filmGauge=35,this.filmOffset=0,this.updateProjectionMatrix()}copy(e,i){return super.copy(e,i),this.fov=e.fov,this.zoom=e.zoom,this.near=e.near,this.far=e.far,this.focus=e.focus,this.aspect=e.aspect,this.view=e.view===null?null:Object.assign({},e.view),this.filmGauge=e.filmGauge,this.filmOffset=e.filmOffset,this}setFocalLength(e){const i=.5*this.getFilmHeight()/e;this.fov=sd*2*Math.atan(i),this.updateProjectionMatrix()}getFocalLength(){const e=Math.tan(Xf*.5*this.fov);return .5*this.getFilmHeight()/e}getEffectiveFOV(){return sd*2*Math.atan(Math.tan(Xf*.5*this.fov)/this.zoom)}getFilmWidth(){return this.filmGauge*Math.min(this.aspect,1)}getFilmHeight(){return this.filmGauge/Math.max(this.aspect,1)}getViewBounds(e,i,r){Ba.set(-1,-1,.5).applyMatrix4(this.projectionMatrixInverse),i.set(Ba.x,Ba.y).multiplyScalar(-e/Ba.z),Ba.set(1,1,.5).applyMatrix4(this.projectionMatrixInverse),r.set(Ba.x,Ba.y).multiplyScalar(-e/Ba.z)}getViewSize(e,i){return this.getViewBounds(e,F_,H_),i.subVectors(H_,F_)}setViewOffset(e,i,r,l,c,h){this.aspect=e/i,this.view===null&&(this.view={enabled:!0,fullWidth:1,fullHeight:1,offsetX:0,offsetY:0,width:1,height:1}),this.view.enabled=!0,this.view.fullWidth=e,this.view.fullHeight=i,this.view.offsetX=r,this.view.offsetY=l,this.view.width=c,this.view.height=h,this.updateProjectionMatrix()}clearViewOffset(){this.view!==null&&(this.view.enabled=!1),this.updateProjectionMatrix()}updateProjectionMatrix(){const e=this.near;let i=e*Math.tan(Xf*.5*this.fov)/this.zoom,r=2*i,l=this.aspect*r,c=-.5*l;const h=this.view;if(this.view!==null&&this.view.enabled){const m=h.fullWidth,p=h.fullHeight;c+=h.offsetX*l/m,i-=h.offsetY*r/p,l*=h.width/m,r*=h.height/p}const d=this.filmOffset;d!==0&&(c+=e*d/this.getFilmWidth()),this.projectionMatrix.makePerspective(c,c+l,i,i-r,e,this.far,this.coordinateSystem),this.projectionMatrixInverse.copy(this.projectionMatrix).invert()}toJSON(e){const i=super.toJSON(e);return i.object.fov=this.fov,i.object.zoom=this.zoom,i.object.near=this.near,i.object.far=this.far,i.object.focus=this.focus,i.object.aspect=this.aspect,this.view!==null&&(i.object.view=Object.assign({},this.view)),i.object.filmGauge=this.filmGauge,i.object.filmOffset=this.filmOffset,i}}const hs=-90,ds=1;class bM extends An{constructor(e,i,r){super(),this.type="CubeCamera",this.renderTarget=r,this.coordinateSystem=null,this.activeMipmapLevel=0;const l=new Jn(hs,ds,e,i);l.layers=this.layers,this.add(l);const c=new Jn(hs,ds,e,i);c.layers=this.layers,this.add(c);const h=new Jn(hs,ds,e,i);h.layers=this.layers,this.add(h);const d=new Jn(hs,ds,e,i);d.layers=this.layers,this.add(d);const m=new Jn(hs,ds,e,i);m.layers=this.layers,this.add(m);const p=new Jn(hs,ds,e,i);p.layers=this.layers,this.add(p)}updateCoordinateSystem(){const e=this.coordinateSystem,i=this.children.concat(),[r,l,c,h,d,m]=i;for(const p of i)this.remove(p);if(e===oa)r.up.set(0,1,0),r.lookAt(1,0,0),l.up.set(0,1,0),l.lookAt(-1,0,0),c.up.set(0,0,-1),c.lookAt(0,1,0),h.up.set(0,0,1),h.lookAt(0,-1,0),d.up.set(0,1,0),d.lookAt(0,0,1),m.up.set(0,1,0),m.lookAt(0,0,-1);else if(e===Tu)r.up.set(0,-1,0),r.lookAt(-1,0,0),l.up.set(0,-1,0),l.lookAt(1,0,0),c.up.set(0,0,1),c.lookAt(0,1,0),h.up.set(0,0,-1),h.lookAt(0,-1,0),d.up.set(0,-1,0),d.lookAt(0,0,1),m.up.set(0,-1,0),m.lookAt(0,0,-1);else throw new Error("THREE.CubeCamera.updateCoordinateSystem(): Invalid coordinate system: "+e);for(const p of i)this.add(p),p.updateMatrixWorld()}update(e,i){this.parent===null&&this.updateMatrixWorld();const{renderTarget:r,activeMipmapLevel:l}=this;this.coordinateSystem!==e.coordinateSystem&&(this.coordinateSystem=e.coordinateSystem,this.updateCoordinateSystem());const[c,h,d,m,p,S]=this.children,v=e.getRenderTarget(),x=e.getActiveCubeFace(),y=e.getActiveMipmapLevel(),R=e.xr.enabled;e.xr.enabled=!1;const w=r.texture.generateMipmaps;r.texture.generateMipmaps=!1,e.setRenderTarget(r,0,l),e.render(i,c),e.setRenderTarget(r,1,l),e.render(i,h),e.setRenderTarget(r,2,l),e.render(i,d),e.setRenderTarget(r,3,l),e.render(i,m),e.setRenderTarget(r,4,l),e.render(i,p),r.texture.generateMipmaps=w,e.setRenderTarget(r,5,l),e.render(i,S),e.setRenderTarget(v,x,y),e.xr.enabled=R,r.texture.needsPMREMUpdate=!0}}class X0 extends Vn{constructor(e=[],i=Ss,r,l,c,h,d,m,p,S){super(e,i,r,l,c,h,d,m,p,S),this.isCubeTexture=!0,this.flipY=!1}get images(){return this.image}set images(e){this.image=e}}class AM extends Mr{constructor(e=1,i={}){super(e,e,i),this.isWebGLCubeRenderTarget=!0;const r={width:e,height:e,depth:1},l=[r,r,r,r,r,r];this.texture=new X0(l,i.mapping,i.wrapS,i.wrapT,i.magFilter,i.minFilter,i.format,i.type,i.anisotropy,i.colorSpace),this.texture.isRenderTargetTexture=!0,this.texture.generateMipmaps=i.generateMipmaps!==void 0?i.generateMipmaps:!1,this.texture.minFilter=i.minFilter!==void 0?i.minFilter:wi}fromEquirectangularTexture(e,i){this.texture.type=i.type,this.texture.colorSpace=i.colorSpace,this.texture.generateMipmaps=i.generateMipmaps,this.texture.minFilter=i.minFilter,this.texture.magFilter=i.magFilter;const r={uniforms:{tEquirect:{value:null}},vertexShader:`

				varying vec3 vWorldDirection;

				vec3 transformDirection( in vec3 dir, in mat4 matrix ) {

					return normalize( ( matrix * vec4( dir, 0.0 ) ).xyz );

				}

				void main() {

					vWorldDirection = transformDirection( position, modelMatrix );

					#include <begin_vertex>
					#include <project_vertex>

				}
			`,fragmentShader:`

				uniform sampler2D tEquirect;

				varying vec3 vWorldDirection;

				#include <common>

				void main() {

					vec3 direction = normalize( vWorldDirection );

					vec2 sampleUV = equirectUv( direction );

					gl_FragColor = texture2D( tEquirect, sampleUV );

				}
			`},l=new Po(5,5,5),c=new Va({name:"CubemapFromEquirect",uniforms:ys(r.uniforms),vertexShader:r.vertexShader,fragmentShader:r.fragmentShader,side:Gn,blending:Fa});c.uniforms.tEquirect.value=i;const h=new ui(l,c),d=i.minFilter;return i.minFilter===Sr&&(i.minFilter=wi),new bM(1,10,this).update(e,h),i.minFilter=d,h.geometry.dispose(),h.material.dispose(),this}clear(e,i=!0,r=!0,l=!0){const c=e.getRenderTarget();for(let h=0;h<6;h++)e.setRenderTarget(this,h),e.clear(i,r,l);e.setRenderTarget(c)}}class cu extends An{constructor(){super(),this.isGroup=!0,this.type="Group"}}const RM={type:"move"};class ch{constructor(){this._targetRay=null,this._grip=null,this._hand=null}getHandSpace(){return this._hand===null&&(this._hand=new cu,this._hand.matrixAutoUpdate=!1,this._hand.visible=!1,this._hand.joints={},this._hand.inputState={pinching:!1}),this._hand}getTargetRaySpace(){return this._targetRay===null&&(this._targetRay=new cu,this._targetRay.matrixAutoUpdate=!1,this._targetRay.visible=!1,this._targetRay.hasLinearVelocity=!1,this._targetRay.linearVelocity=new Q,this._targetRay.hasAngularVelocity=!1,this._targetRay.angularVelocity=new Q),this._targetRay}getGripSpace(){return this._grip===null&&(this._grip=new cu,this._grip.matrixAutoUpdate=!1,this._grip.visible=!1,this._grip.hasLinearVelocity=!1,this._grip.linearVelocity=new Q,this._grip.hasAngularVelocity=!1,this._grip.angularVelocity=new Q),this._grip}dispatchEvent(e){return this._targetRay!==null&&this._targetRay.dispatchEvent(e),this._grip!==null&&this._grip.dispatchEvent(e),this._hand!==null&&this._hand.dispatchEvent(e),this}connect(e){if(e&&e.hand){const i=this._hand;if(i)for(const r of e.hand.values())this._getHandJoint(i,r)}return this.dispatchEvent({type:"connected",data:e}),this}disconnect(e){return this.dispatchEvent({type:"disconnected",data:e}),this._targetRay!==null&&(this._targetRay.visible=!1),this._grip!==null&&(this._grip.visible=!1),this._hand!==null&&(this._hand.visible=!1),this}update(e,i,r){let l=null,c=null,h=null;const d=this._targetRay,m=this._grip,p=this._hand;if(e&&i.session.visibilityState!=="visible-blurred"){if(p&&e.hand){h=!0;for(const w of e.hand.values()){const M=i.getJointPose(w,r),_=this._getHandJoint(p,w);M!==null&&(_.matrix.fromArray(M.transform.matrix),_.matrix.decompose(_.position,_.rotation,_.scale),_.matrixWorldNeedsUpdate=!0,_.jointRadius=M.radius),_.visible=M!==null}const S=p.joints["index-finger-tip"],v=p.joints["thumb-tip"],x=S.position.distanceTo(v.position),y=.02,R=.005;p.inputState.pinching&&x>y+R?(p.inputState.pinching=!1,this.dispatchEvent({type:"pinchend",handedness:e.handedness,target:this})):!p.inputState.pinching&&x<=y-R&&(p.inputState.pinching=!0,this.dispatchEvent({type:"pinchstart",handedness:e.handedness,target:this}))}else m!==null&&e.gripSpace&&(c=i.getPose(e.gripSpace,r),c!==null&&(m.matrix.fromArray(c.transform.matrix),m.matrix.decompose(m.position,m.rotation,m.scale),m.matrixWorldNeedsUpdate=!0,c.linearVelocity?(m.hasLinearVelocity=!0,m.linearVelocity.copy(c.linearVelocity)):m.hasLinearVelocity=!1,c.angularVelocity?(m.hasAngularVelocity=!0,m.angularVelocity.copy(c.angularVelocity)):m.hasAngularVelocity=!1));d!==null&&(l=i.getPose(e.targetRaySpace,r),l===null&&c!==null&&(l=c),l!==null&&(d.matrix.fromArray(l.transform.matrix),d.matrix.decompose(d.position,d.rotation,d.scale),d.matrixWorldNeedsUpdate=!0,l.linearVelocity?(d.hasLinearVelocity=!0,d.linearVelocity.copy(l.linearVelocity)):d.hasLinearVelocity=!1,l.angularVelocity?(d.hasAngularVelocity=!0,d.angularVelocity.copy(l.angularVelocity)):d.hasAngularVelocity=!1,this.dispatchEvent(RM)))}return d!==null&&(d.visible=l!==null),m!==null&&(m.visible=c!==null),p!==null&&(p.visible=h!==null),this}_getHandJoint(e,i){if(e.joints[i.jointName]===void 0){const r=new cu;r.matrixAutoUpdate=!1,r.visible=!1,e.joints[i.jointName]=r,e.add(r)}return e.joints[i.jointName]}}class Sd{constructor(e,i=25e-5){this.isFogExp2=!0,this.name="",this.color=new Me(e),this.density=i}clone(){return new Sd(this.color,this.density)}toJSON(){return{type:"FogExp2",name:this.name,color:this.color.getHex(),density:this.density}}}class CM extends An{constructor(){super(),this.isScene=!0,this.type="Scene",this.background=null,this.environment=null,this.fog=null,this.backgroundBlurriness=0,this.backgroundIntensity=1,this.backgroundRotation=new Li,this.environmentIntensity=1,this.environmentRotation=new Li,this.overrideMaterial=null,typeof __THREE_DEVTOOLS__<"u"&&__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("observe",{detail:this}))}copy(e,i){return super.copy(e,i),e.background!==null&&(this.background=e.background.clone()),e.environment!==null&&(this.environment=e.environment.clone()),e.fog!==null&&(this.fog=e.fog.clone()),this.backgroundBlurriness=e.backgroundBlurriness,this.backgroundIntensity=e.backgroundIntensity,this.backgroundRotation.copy(e.backgroundRotation),this.environmentIntensity=e.environmentIntensity,this.environmentRotation.copy(e.environmentRotation),e.overrideMaterial!==null&&(this.overrideMaterial=e.overrideMaterial.clone()),this.matrixAutoUpdate=e.matrixAutoUpdate,this}toJSON(e){const i=super.toJSON(e);return this.fog!==null&&(i.object.fog=this.fog.toJSON()),this.backgroundBlurriness>0&&(i.object.backgroundBlurriness=this.backgroundBlurriness),this.backgroundIntensity!==1&&(i.object.backgroundIntensity=this.backgroundIntensity),i.object.backgroundRotation=this.backgroundRotation.toArray(),this.environmentIntensity!==1&&(i.object.environmentIntensity=this.environmentIntensity),i.object.environmentRotation=this.environmentRotation.toArray(),i}}const fh=new Q,wM=new Q,DM=new oe;class pr{constructor(e=new Q(1,0,0),i=0){this.isPlane=!0,this.normal=e,this.constant=i}set(e,i){return this.normal.copy(e),this.constant=i,this}setComponents(e,i,r,l){return this.normal.set(e,i,r),this.constant=l,this}setFromNormalAndCoplanarPoint(e,i){return this.normal.copy(e),this.constant=-i.dot(this.normal),this}setFromCoplanarPoints(e,i,r){const l=fh.subVectors(r,i).cross(wM.subVectors(e,i)).normalize();return this.setFromNormalAndCoplanarPoint(l,e),this}copy(e){return this.normal.copy(e.normal),this.constant=e.constant,this}normalize(){const e=1/this.normal.length();return this.normal.multiplyScalar(e),this.constant*=e,this}negate(){return this.constant*=-1,this.normal.negate(),this}distanceToPoint(e){return this.normal.dot(e)+this.constant}distanceToSphere(e){return this.distanceToPoint(e.center)-e.radius}projectPoint(e,i){return i.copy(e).addScaledVector(this.normal,-this.distanceToPoint(e))}intersectLine(e,i){const r=e.delta(fh),l=this.normal.dot(r);if(l===0)return this.distanceToPoint(e.start)===0?i.copy(e.start):null;const c=-(e.start.dot(this.normal)+this.constant)/l;return c<0||c>1?null:i.copy(e.start).addScaledVector(r,c)}intersectsLine(e){const i=this.distanceToPoint(e.start),r=this.distanceToPoint(e.end);return i<0&&r>0||r<0&&i>0}intersectsBox(e){return e.intersectsPlane(this)}intersectsSphere(e){return e.intersectsPlane(this)}coplanarPoint(e){return e.copy(this.normal).multiplyScalar(-this.constant)}applyMatrix4(e,i){const r=i||DM.getNormalMatrix(e),l=this.coplanarPoint(fh).applyMatrix4(e),c=this.normal.applyMatrix3(r).normalize();return this.constant=-l.dot(c),this}translate(e){return this.constant-=e.dot(this.normal),this}equals(e){return e.normal.equals(this.normal)&&e.constant===this.constant}clone(){return new this.constructor().copy(this)}}const fr=new _d,fu=new Q;class xd{constructor(e=new pr,i=new pr,r=new pr,l=new pr,c=new pr,h=new pr){this.planes=[e,i,r,l,c,h]}set(e,i,r,l,c,h){const d=this.planes;return d[0].copy(e),d[1].copy(i),d[2].copy(r),d[3].copy(l),d[4].copy(c),d[5].copy(h),this}copy(e){const i=this.planes;for(let r=0;r<6;r++)i[r].copy(e.planes[r]);return this}setFromProjectionMatrix(e,i=oa){const r=this.planes,l=e.elements,c=l[0],h=l[1],d=l[2],m=l[3],p=l[4],S=l[5],v=l[6],x=l[7],y=l[8],R=l[9],w=l[10],M=l[11],_=l[12],L=l[13],U=l[14],C=l[15];if(r[0].setComponents(m-c,x-p,M-y,C-_).normalize(),r[1].setComponents(m+c,x+p,M+y,C+_).normalize(),r[2].setComponents(m+h,x+S,M+R,C+L).normalize(),r[3].setComponents(m-h,x-S,M-R,C-L).normalize(),r[4].setComponents(m-d,x-v,M-w,C-U).normalize(),i===oa)r[5].setComponents(m+d,x+v,M+w,C+U).normalize();else if(i===Tu)r[5].setComponents(d,v,w,U).normalize();else throw new Error("THREE.Frustum.setFromProjectionMatrix(): Invalid coordinate system: "+i);return this}intersectsObject(e){if(e.boundingSphere!==void 0)e.boundingSphere===null&&e.computeBoundingSphere(),fr.copy(e.boundingSphere).applyMatrix4(e.matrixWorld);else{const i=e.geometry;i.boundingSphere===null&&i.computeBoundingSphere(),fr.copy(i.boundingSphere).applyMatrix4(e.matrixWorld)}return this.intersectsSphere(fr)}intersectsSprite(e){return fr.center.set(0,0,0),fr.radius=.7071067811865476,fr.applyMatrix4(e.matrixWorld),this.intersectsSphere(fr)}intersectsSphere(e){const i=this.planes,r=e.center,l=-e.radius;for(let c=0;c<6;c++)if(i[c].distanceToPoint(r)<l)return!1;return!0}intersectsBox(e){const i=this.planes;for(let r=0;r<6;r++){const l=i[r];if(fu.x=l.normal.x>0?e.max.x:e.min.x,fu.y=l.normal.y>0?e.max.y:e.min.y,fu.z=l.normal.z>0?e.max.z:e.min.z,l.distanceToPoint(fu)<0)return!1}return!0}containsPoint(e){const i=this.planes;for(let r=0;r<6;r++)if(i[r].distanceToPoint(e)<0)return!1;return!0}clone(){return new this.constructor().copy(this)}}class k0 extends Vn{constructor(e,i,r=xr,l,c,h,d=yi,m=yi,p,S=wo){if(S!==wo&&S!==Do)throw new Error("DepthTexture format must be either THREE.DepthFormat or THREE.DepthStencilFormat");super(null,l,c,h,d,m,S,r,p),this.isDepthTexture=!0,this.image={width:e,height:i},this.flipY=!1,this.generateMipmaps=!1,this.compareFunction=null}copy(e){return super.copy(e),this.source=new gd(Object.assign({},e.image)),this.compareFunction=e.compareFunction,this}toJSON(e){const i=super.toJSON(e);return this.compareFunction!==null&&(i.compareFunction=this.compareFunction),i}}class Md extends Ni{constructor(e=[],i=[],r=1,l=0){super(),this.type="PolyhedronGeometry",this.parameters={vertices:e,indices:i,radius:r,detail:l};const c=[],h=[];d(l),p(r),S(),this.setAttribute("position",new Rn(c,3)),this.setAttribute("normal",new Rn(c.slice(),3)),this.setAttribute("uv",new Rn(h,2)),l===0?this.computeVertexNormals():this.normalizeNormals();function d(L){const U=new Q,C=new Q,G=new Q;for(let I=0;I<i.length;I+=3)y(i[I+0],U),y(i[I+1],C),y(i[I+2],G),m(U,C,G,L)}function m(L,U,C,G){const I=G+1,O=[];for(let V=0;V<=I;V++){O[V]=[];const D=L.clone().lerp(C,V/I),b=U.clone().lerp(C,V/I),B=I-V;for(let rt=0;rt<=B;rt++)rt===0&&V===I?O[V][rt]=D:O[V][rt]=D.clone().lerp(b,rt/B)}for(let V=0;V<I;V++)for(let D=0;D<2*(I-V)-1;D++){const b=Math.floor(D/2);D%2===0?(x(O[V][b+1]),x(O[V+1][b]),x(O[V][b])):(x(O[V][b+1]),x(O[V+1][b+1]),x(O[V+1][b]))}}function p(L){const U=new Q;for(let C=0;C<c.length;C+=3)U.x=c[C+0],U.y=c[C+1],U.z=c[C+2],U.normalize().multiplyScalar(L),c[C+0]=U.x,c[C+1]=U.y,c[C+2]=U.z}function S(){const L=new Q;for(let U=0;U<c.length;U+=3){L.x=c[U+0],L.y=c[U+1],L.z=c[U+2];const C=M(L)/2/Math.PI+.5,G=_(L)/Math.PI+.5;h.push(C,1-G)}R(),v()}function v(){for(let L=0;L<h.length;L+=6){const U=h[L+0],C=h[L+2],G=h[L+4],I=Math.max(U,C,G),O=Math.min(U,C,G);I>.9&&O<.1&&(U<.2&&(h[L+0]+=1),C<.2&&(h[L+2]+=1),G<.2&&(h[L+4]+=1))}}function x(L){c.push(L.x,L.y,L.z)}function y(L,U){const C=L*3;U.x=e[C+0],U.y=e[C+1],U.z=e[C+2]}function R(){const L=new Q,U=new Q,C=new Q,G=new Q,I=new ye,O=new ye,V=new ye;for(let D=0,b=0;D<c.length;D+=9,b+=6){L.set(c[D+0],c[D+1],c[D+2]),U.set(c[D+3],c[D+4],c[D+5]),C.set(c[D+6],c[D+7],c[D+8]),I.set(h[b+0],h[b+1]),O.set(h[b+2],h[b+3]),V.set(h[b+4],h[b+5]),G.copy(L).add(U).add(C).divideScalar(3);const B=M(G);w(I,b+0,L,B),w(O,b+2,U,B),w(V,b+4,C,B)}}function w(L,U,C,G){G<0&&L.x===1&&(h[U]=L.x-1),C.x===0&&C.z===0&&(h[U]=G/2/Math.PI+.5)}function M(L){return Math.atan2(L.z,-L.x)}function _(L){return Math.atan2(-L.y,Math.sqrt(L.x*L.x+L.z*L.z))}}copy(e){return super.copy(e),this.parameters=Object.assign({},e.parameters),this}static fromJSON(e){return new Md(e.vertices,e.indices,e.radius,e.details)}}class yd extends Md{constructor(e=1,i=0){const r=(1+Math.sqrt(5))/2,l=[-1,r,0,1,r,0,-1,-r,0,1,-r,0,0,-1,r,0,1,r,0,-1,-r,0,1,-r,r,0,-1,r,0,1,-r,0,-1,-r,0,1],c=[0,11,5,0,5,1,0,1,7,0,7,10,0,10,11,1,5,9,5,11,4,11,10,2,10,7,6,7,1,8,3,9,4,3,4,2,3,2,6,3,6,8,3,8,9,4,9,5,2,4,11,6,2,10,8,6,7,9,8,1];super(l,c,e,i),this.type="IcosahedronGeometry",this.parameters={radius:e,detail:i}}static fromJSON(e){return new yd(e.radius,e.detail)}}class Ru extends Ni{constructor(e=1,i=1,r=1,l=1){super(),this.type="PlaneGeometry",this.parameters={width:e,height:i,widthSegments:r,heightSegments:l};const c=e/2,h=i/2,d=Math.floor(r),m=Math.floor(l),p=d+1,S=m+1,v=e/d,x=i/m,y=[],R=[],w=[],M=[];for(let _=0;_<S;_++){const L=_*x-h;for(let U=0;U<p;U++){const C=U*v-c;R.push(C,-L,0),w.push(0,0,1),M.push(U/d),M.push(1-_/m)}}for(let _=0;_<m;_++)for(let L=0;L<d;L++){const U=L+p*_,C=L+p*(_+1),G=L+1+p*(_+1),I=L+1+p*_;y.push(U,C,I),y.push(C,G,I)}this.setIndex(y),this.setAttribute("position",new Rn(R,3)),this.setAttribute("normal",new Rn(w,3)),this.setAttribute("uv",new Rn(M,2))}copy(e){return super.copy(e),this.parameters=Object.assign({},e.parameters),this}static fromJSON(e){return new Ru(e.width,e.height,e.widthSegments,e.heightSegments)}}class Ed extends Ni{constructor(e=1,i=32,r=16,l=0,c=Math.PI*2,h=0,d=Math.PI){super(),this.type="SphereGeometry",this.parameters={radius:e,widthSegments:i,heightSegments:r,phiStart:l,phiLength:c,thetaStart:h,thetaLength:d},i=Math.max(3,Math.floor(i)),r=Math.max(2,Math.floor(r));const m=Math.min(h+d,Math.PI);let p=0;const S=[],v=new Q,x=new Q,y=[],R=[],w=[],M=[];for(let _=0;_<=r;_++){const L=[],U=_/r;let C=0;_===0&&h===0?C=.5/i:_===r&&m===Math.PI&&(C=-.5/i);for(let G=0;G<=i;G++){const I=G/i;v.x=-e*Math.cos(l+I*c)*Math.sin(h+U*d),v.y=e*Math.cos(h+U*d),v.z=e*Math.sin(l+I*c)*Math.sin(h+U*d),R.push(v.x,v.y,v.z),x.copy(v).normalize(),w.push(x.x,x.y,x.z),M.push(I+C,1-U),L.push(p++)}S.push(L)}for(let _=0;_<r;_++)for(let L=0;L<i;L++){const U=S[_][L+1],C=S[_][L],G=S[_+1][L],I=S[_+1][L+1];(_!==0||h>0)&&y.push(U,C,I),(_!==r-1||m<Math.PI)&&y.push(C,G,I)}this.setIndex(y),this.setAttribute("position",new Rn(R,3)),this.setAttribute("normal",new Rn(w,3)),this.setAttribute("uv",new Rn(M,2))}copy(e){return super.copy(e),this.parameters=Object.assign({},e.parameters),this}static fromJSON(e){return new Ed(e.radius,e.widthSegments,e.heightSegments,e.phiStart,e.phiLength,e.thetaStart,e.thetaLength)}}class Td extends Ni{constructor(e=1,i=.4,r=64,l=8,c=2,h=3){super(),this.type="TorusKnotGeometry",this.parameters={radius:e,tube:i,tubularSegments:r,radialSegments:l,p:c,q:h},r=Math.floor(r),l=Math.floor(l);const d=[],m=[],p=[],S=[],v=new Q,x=new Q,y=new Q,R=new Q,w=new Q,M=new Q,_=new Q;for(let U=0;U<=r;++U){const C=U/r*c*Math.PI*2;L(C,c,h,e,y),L(C+.01,c,h,e,R),M.subVectors(R,y),_.addVectors(R,y),w.crossVectors(M,_),_.crossVectors(w,M),w.normalize(),_.normalize();for(let G=0;G<=l;++G){const I=G/l*Math.PI*2,O=-i*Math.cos(I),V=i*Math.sin(I);v.x=y.x+(O*_.x+V*w.x),v.y=y.y+(O*_.y+V*w.y),v.z=y.z+(O*_.z+V*w.z),m.push(v.x,v.y,v.z),x.subVectors(v,y).normalize(),p.push(x.x,x.y,x.z),S.push(U/r),S.push(G/l)}}for(let U=1;U<=r;U++)for(let C=1;C<=l;C++){const G=(l+1)*(U-1)+(C-1),I=(l+1)*U+(C-1),O=(l+1)*U+C,V=(l+1)*(U-1)+C;d.push(G,I,V),d.push(I,O,V)}this.setIndex(d),this.setAttribute("position",new Rn(m,3)),this.setAttribute("normal",new Rn(p,3)),this.setAttribute("uv",new Rn(S,2));function L(U,C,G,I,O){const V=Math.cos(U),D=Math.sin(U),b=G/C*U,B=Math.cos(b);O.x=I*(2+B)*.5*V,O.y=I*(2+B)*D*.5,O.z=I*Math.sin(b)*.5}}copy(e){return super.copy(e),this.parameters=Object.assign({},e.parameters),this}static fromJSON(e){return new Td(e.radius,e.tube,e.tubularSegments,e.radialSegments,e.p,e.q)}}class G_ extends zo{constructor(e){super(),this.isMeshStandardMaterial=!0,this.type="MeshStandardMaterial",this.defines={STANDARD:""},this.color=new Me(16777215),this.roughness=1,this.metalness=0,this.map=null,this.lightMap=null,this.lightMapIntensity=1,this.aoMap=null,this.aoMapIntensity=1,this.emissive=new Me(0),this.emissiveIntensity=1,this.emissiveMap=null,this.bumpMap=null,this.bumpScale=1,this.normalMap=null,this.normalMapType=N0,this.normalScale=new ye(1,1),this.displacementMap=null,this.displacementScale=1,this.displacementBias=0,this.roughnessMap=null,this.metalnessMap=null,this.alphaMap=null,this.envMap=null,this.envMapRotation=new Li,this.envMapIntensity=1,this.wireframe=!1,this.wireframeLinewidth=1,this.wireframeLinecap="round",this.wireframeLinejoin="round",this.flatShading=!1,this.fog=!0,this.setValues(e)}copy(e){return super.copy(e),this.defines={STANDARD:""},this.color.copy(e.color),this.roughness=e.roughness,this.metalness=e.metalness,this.map=e.map,this.lightMap=e.lightMap,this.lightMapIntensity=e.lightMapIntensity,this.aoMap=e.aoMap,this.aoMapIntensity=e.aoMapIntensity,this.emissive.copy(e.emissive),this.emissiveMap=e.emissiveMap,this.emissiveIntensity=e.emissiveIntensity,this.bumpMap=e.bumpMap,this.bumpScale=e.bumpScale,this.normalMap=e.normalMap,this.normalMapType=e.normalMapType,this.normalScale.copy(e.normalScale),this.displacementMap=e.displacementMap,this.displacementScale=e.displacementScale,this.displacementBias=e.displacementBias,this.roughnessMap=e.roughnessMap,this.metalnessMap=e.metalnessMap,this.alphaMap=e.alphaMap,this.envMap=e.envMap,this.envMapRotation.copy(e.envMapRotation),this.envMapIntensity=e.envMapIntensity,this.wireframe=e.wireframe,this.wireframeLinewidth=e.wireframeLinewidth,this.wireframeLinecap=e.wireframeLinecap,this.wireframeLinejoin=e.wireframeLinejoin,this.flatShading=e.flatShading,this.fog=e.fog,this}}class UM extends zo{constructor(e){super(),this.isMeshDepthMaterial=!0,this.type="MeshDepthMaterial",this.depthPacking=Vx,this.map=null,this.alphaMap=null,this.displacementMap=null,this.displacementScale=1,this.displacementBias=0,this.wireframe=!1,this.wireframeLinewidth=1,this.setValues(e)}copy(e){return super.copy(e),this.depthPacking=e.depthPacking,this.map=e.map,this.alphaMap=e.alphaMap,this.displacementMap=e.displacementMap,this.displacementScale=e.displacementScale,this.displacementBias=e.displacementBias,this.wireframe=e.wireframe,this.wireframeLinewidth=e.wireframeLinewidth,this}}class LM extends zo{constructor(e){super(),this.isMeshDistanceMaterial=!0,this.type="MeshDistanceMaterial",this.map=null,this.alphaMap=null,this.displacementMap=null,this.displacementScale=1,this.displacementBias=0,this.setValues(e)}copy(e){return super.copy(e),this.map=e.map,this.alphaMap=e.alphaMap,this.displacementMap=e.displacementMap,this.displacementScale=e.displacementScale,this.displacementBias=e.displacementBias,this}}class bd extends An{constructor(e,i=1){super(),this.isLight=!0,this.type="Light",this.color=new Me(e),this.intensity=i}dispose(){}copy(e,i){return super.copy(e,i),this.color.copy(e.color),this.intensity=e.intensity,this}toJSON(e){const i=super.toJSON(e);return i.object.color=this.color.getHex(),i.object.intensity=this.intensity,this.groundColor!==void 0&&(i.object.groundColor=this.groundColor.getHex()),this.distance!==void 0&&(i.object.distance=this.distance),this.angle!==void 0&&(i.object.angle=this.angle),this.decay!==void 0&&(i.object.decay=this.decay),this.penumbra!==void 0&&(i.object.penumbra=this.penumbra),this.shadow!==void 0&&(i.object.shadow=this.shadow.toJSON()),this.target!==void 0&&(i.object.target=this.target.uuid),i}}const hh=new Ye,V_=new Q,X_=new Q;class W0{constructor(e){this.camera=e,this.intensity=1,this.bias=0,this.normalBias=0,this.radius=1,this.blurSamples=8,this.mapSize=new ye(512,512),this.mapType=Ui,this.map=null,this.mapPass=null,this.matrix=new Ye,this.autoUpdate=!0,this.needsUpdate=!1,this._frustum=new xd,this._frameExtents=new ye(1,1),this._viewportCount=1,this._viewports=[new Ie(0,0,1,1)]}getViewportCount(){return this._viewportCount}getFrustum(){return this._frustum}updateMatrices(e){const i=this.camera,r=this.matrix;V_.setFromMatrixPosition(e.matrixWorld),i.position.copy(V_),X_.setFromMatrixPosition(e.target.matrixWorld),i.lookAt(X_),i.updateMatrixWorld(),hh.multiplyMatrices(i.projectionMatrix,i.matrixWorldInverse),this._frustum.setFromProjectionMatrix(hh),r.set(.5,0,0,.5,0,.5,0,.5,0,0,.5,.5,0,0,0,1),r.multiply(hh)}getViewport(e){return this._viewports[e]}getFrameExtents(){return this._frameExtents}dispose(){this.map&&this.map.dispose(),this.mapPass&&this.mapPass.dispose()}copy(e){return this.camera=e.camera.clone(),this.intensity=e.intensity,this.bias=e.bias,this.radius=e.radius,this.autoUpdate=e.autoUpdate,this.needsUpdate=e.needsUpdate,this.normalBias=e.normalBias,this.blurSamples=e.blurSamples,this.mapSize.copy(e.mapSize),this}clone(){return new this.constructor().copy(this)}toJSON(){const e={};return this.intensity!==1&&(e.intensity=this.intensity),this.bias!==0&&(e.bias=this.bias),this.normalBias!==0&&(e.normalBias=this.normalBias),this.radius!==1&&(e.radius=this.radius),(this.mapSize.x!==512||this.mapSize.y!==512)&&(e.mapSize=this.mapSize.toArray()),e.camera=this.camera.toJSON(!1).object,delete e.camera.matrix,e}}const k_=new Ye,bo=new Q,dh=new Q;class NM extends W0{constructor(){super(new Jn(90,1,.5,500)),this.isPointLightShadow=!0,this._frameExtents=new ye(4,2),this._viewportCount=6,this._viewports=[new Ie(2,1,1,1),new Ie(0,1,1,1),new Ie(3,1,1,1),new Ie(1,1,1,1),new Ie(3,0,1,1),new Ie(1,0,1,1)],this._cubeDirections=[new Q(1,0,0),new Q(-1,0,0),new Q(0,0,1),new Q(0,0,-1),new Q(0,1,0),new Q(0,-1,0)],this._cubeUps=[new Q(0,1,0),new Q(0,1,0),new Q(0,1,0),new Q(0,1,0),new Q(0,0,1),new Q(0,0,-1)]}updateMatrices(e,i=0){const r=this.camera,l=this.matrix,c=e.distance||r.far;c!==r.far&&(r.far=c,r.updateProjectionMatrix()),bo.setFromMatrixPosition(e.matrixWorld),r.position.copy(bo),dh.copy(r.position),dh.add(this._cubeDirections[i]),r.up.copy(this._cubeUps[i]),r.lookAt(dh),r.updateMatrixWorld(),l.makeTranslation(-bo.x,-bo.y,-bo.z),k_.multiplyMatrices(r.projectionMatrix,r.matrixWorldInverse),this._frustum.setFromProjectionMatrix(k_)}}class ph extends bd{constructor(e,i,r=0,l=2){super(e,i),this.isPointLight=!0,this.type="PointLight",this.distance=r,this.decay=l,this.shadow=new NM}get power(){return this.intensity*4*Math.PI}set power(e){this.intensity=e/(4*Math.PI)}dispose(){this.shadow.dispose()}copy(e,i){return super.copy(e,i),this.distance=e.distance,this.decay=e.decay,this.shadow=e.shadow.clone(),this}}class q0 extends V0{constructor(e=-1,i=1,r=1,l=-1,c=.1,h=2e3){super(),this.isOrthographicCamera=!0,this.type="OrthographicCamera",this.zoom=1,this.view=null,this.left=e,this.right=i,this.top=r,this.bottom=l,this.near=c,this.far=h,this.updateProjectionMatrix()}copy(e,i){return super.copy(e,i),this.left=e.left,this.right=e.right,this.top=e.top,this.bottom=e.bottom,this.near=e.near,this.far=e.far,this.zoom=e.zoom,this.view=e.view===null?null:Object.assign({},e.view),this}setViewOffset(e,i,r,l,c,h){this.view===null&&(this.view={enabled:!0,fullWidth:1,fullHeight:1,offsetX:0,offsetY:0,width:1,height:1}),this.view.enabled=!0,this.view.fullWidth=e,this.view.fullHeight=i,this.view.offsetX=r,this.view.offsetY=l,this.view.width=c,this.view.height=h,this.updateProjectionMatrix()}clearViewOffset(){this.view!==null&&(this.view.enabled=!1),this.updateProjectionMatrix()}updateProjectionMatrix(){const e=(this.right-this.left)/(2*this.zoom),i=(this.top-this.bottom)/(2*this.zoom),r=(this.right+this.left)/2,l=(this.top+this.bottom)/2;let c=r-e,h=r+e,d=l+i,m=l-i;if(this.view!==null&&this.view.enabled){const p=(this.right-this.left)/this.view.fullWidth/this.zoom,S=(this.top-this.bottom)/this.view.fullHeight/this.zoom;c+=p*this.view.offsetX,h=c+p*this.view.width,d-=S*this.view.offsetY,m=d-S*this.view.height}this.projectionMatrix.makeOrthographic(c,h,d,m,this.near,this.far,this.coordinateSystem),this.projectionMatrixInverse.copy(this.projectionMatrix).invert()}toJSON(e){const i=super.toJSON(e);return i.object.zoom=this.zoom,i.object.left=this.left,i.object.right=this.right,i.object.top=this.top,i.object.bottom=this.bottom,i.object.near=this.near,i.object.far=this.far,this.view!==null&&(i.object.view=Object.assign({},this.view)),i}}class OM extends W0{constructor(){super(new q0(-5,5,5,-5,.5,500)),this.isDirectionalLightShadow=!0}}class zM extends bd{constructor(e,i){super(e,i),this.isDirectionalLight=!0,this.type="DirectionalLight",this.position.copy(An.DEFAULT_UP),this.updateMatrix(),this.target=new An,this.shadow=new OM}dispose(){this.shadow.dispose()}copy(e){return super.copy(e),this.target=e.target.clone(),this.shadow=e.shadow.clone(),this}}class PM extends bd{constructor(e,i){super(e,i),this.isAmbientLight=!0,this.type="AmbientLight"}}class BM extends Jn{constructor(e=[]){super(),this.isArrayCamera=!0,this.isMultiViewCamera=!1,this.cameras=e}}class IM{constructor(e=!0){this.autoStart=e,this.startTime=0,this.oldTime=0,this.elapsedTime=0,this.running=!1}start(){this.startTime=W_(),this.oldTime=this.startTime,this.elapsedTime=0,this.running=!0}stop(){this.getElapsedTime(),this.running=!1,this.autoStart=!1}getElapsedTime(){return this.getDelta(),this.elapsedTime}getDelta(){let e=0;if(this.autoStart&&!this.running)return this.start(),0;if(this.running){const i=W_();e=(i-this.oldTime)/1e3,this.oldTime=i,this.elapsedTime+=e}return e}}function W_(){return performance.now()}function q_(o,e,i,r){const l=FM(r);switch(i){case C0:return o*e;case D0:return o*e/l.components*l.byteLength;case dd:return o*e/l.components*l.byteLength;case U0:return o*e*2/l.components*l.byteLength;case pd:return o*e*2/l.components*l.byteLength;case w0:return o*e*3/l.components*l.byteLength;case Mi:return o*e*4/l.components*l.byteLength;case md:return o*e*4/l.components*l.byteLength;case gu:case _u:return Math.floor((o+3)/4)*Math.floor((e+3)/4)*8;case vu:case Su:return Math.floor((o+3)/4)*Math.floor((e+3)/4)*16;case zh:case Bh:return Math.max(o,16)*Math.max(e,8)/4;case Oh:case Ph:return Math.max(o,8)*Math.max(e,8)/2;case Ih:case Fh:return Math.floor((o+3)/4)*Math.floor((e+3)/4)*8;case Hh:return Math.floor((o+3)/4)*Math.floor((e+3)/4)*16;case Gh:return Math.floor((o+3)/4)*Math.floor((e+3)/4)*16;case Vh:return Math.floor((o+4)/5)*Math.floor((e+3)/4)*16;case Xh:return Math.floor((o+4)/5)*Math.floor((e+4)/5)*16;case kh:return Math.floor((o+5)/6)*Math.floor((e+4)/5)*16;case Wh:return Math.floor((o+5)/6)*Math.floor((e+5)/6)*16;case qh:return Math.floor((o+7)/8)*Math.floor((e+4)/5)*16;case Yh:return Math.floor((o+7)/8)*Math.floor((e+5)/6)*16;case jh:return Math.floor((o+7)/8)*Math.floor((e+7)/8)*16;case Zh:return Math.floor((o+9)/10)*Math.floor((e+4)/5)*16;case Kh:return Math.floor((o+9)/10)*Math.floor((e+5)/6)*16;case Qh:return Math.floor((o+9)/10)*Math.floor((e+7)/8)*16;case Jh:return Math.floor((o+9)/10)*Math.floor((e+9)/10)*16;case $h:return Math.floor((o+11)/12)*Math.floor((e+9)/10)*16;case td:return Math.floor((o+11)/12)*Math.floor((e+11)/12)*16;case xu:case ed:case nd:return Math.ceil(o/4)*Math.ceil(e/4)*16;case L0:case id:return Math.ceil(o/4)*Math.ceil(e/4)*8;case ad:case rd:return Math.ceil(o/4)*Math.ceil(e/4)*16}throw new Error(`Unable to determine texture byte length for ${i} format.`)}function FM(o){switch(o){case Ui:case b0:return{byteLength:1,components:1};case Ro:case A0:case Uo:return{byteLength:2,components:1};case fd:case hd:return{byteLength:2,components:4};case xr:case cd:case sa:return{byteLength:4,components:1};case R0:return{byteLength:4,components:3}}throw new Error(`Unknown texture type ${o}.`)}typeof __THREE_DEVTOOLS__<"u"&&__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("register",{detail:{revision:ud}}));typeof window<"u"&&(window.__THREE__?console.warn("WARNING: Multiple instances of Three.js being imported."):window.__THREE__=ud);/**
 * @license
 * Copyright 2010-2025 Three.js Authors
 * SPDX-License-Identifier: MIT
 */function Y0(){let o=null,e=!1,i=null,r=null;function l(c,h){i(c,h),r=o.requestAnimationFrame(l)}return{start:function(){e!==!0&&i!==null&&(r=o.requestAnimationFrame(l),e=!0)},stop:function(){o.cancelAnimationFrame(r),e=!1},setAnimationLoop:function(c){i=c},setContext:function(c){o=c}}}function HM(o){const e=new WeakMap;function i(d,m){const p=d.array,S=d.usage,v=p.byteLength,x=o.createBuffer();o.bindBuffer(m,x),o.bufferData(m,p,S),d.onUploadCallback();let y;if(p instanceof Float32Array)y=o.FLOAT;else if(p instanceof Uint16Array)d.isFloat16BufferAttribute?y=o.HALF_FLOAT:y=o.UNSIGNED_SHORT;else if(p instanceof Int16Array)y=o.SHORT;else if(p instanceof Uint32Array)y=o.UNSIGNED_INT;else if(p instanceof Int32Array)y=o.INT;else if(p instanceof Int8Array)y=o.BYTE;else if(p instanceof Uint8Array)y=o.UNSIGNED_BYTE;else if(p instanceof Uint8ClampedArray)y=o.UNSIGNED_BYTE;else throw new Error("THREE.WebGLAttributes: Unsupported buffer data format: "+p);return{buffer:x,type:y,bytesPerElement:p.BYTES_PER_ELEMENT,version:d.version,size:v}}function r(d,m,p){const S=m.array,v=m.updateRanges;if(o.bindBuffer(p,d),v.length===0)o.bufferSubData(p,0,S);else{v.sort((y,R)=>y.start-R.start);let x=0;for(let y=1;y<v.length;y++){const R=v[x],w=v[y];w.start<=R.start+R.count+1?R.count=Math.max(R.count,w.start+w.count-R.start):(++x,v[x]=w)}v.length=x+1;for(let y=0,R=v.length;y<R;y++){const w=v[y];o.bufferSubData(p,w.start*S.BYTES_PER_ELEMENT,S,w.start,w.count)}m.clearUpdateRanges()}m.onUploadCallback()}function l(d){return d.isInterleavedBufferAttribute&&(d=d.data),e.get(d)}function c(d){d.isInterleavedBufferAttribute&&(d=d.data);const m=e.get(d);m&&(o.deleteBuffer(m.buffer),e.delete(d))}function h(d,m){if(d.isInterleavedBufferAttribute&&(d=d.data),d.isGLBufferAttribute){const S=e.get(d);(!S||S.version<d.version)&&e.set(d,{buffer:d.buffer,type:d.type,bytesPerElement:d.elementSize,version:d.version});return}const p=e.get(d);if(p===void 0)e.set(d,i(d,m));else if(p.version<d.version){if(p.size!==d.array.byteLength)throw new Error("THREE.WebGLAttributes: The size of the buffer attribute's array buffer does not match the original size. Resizing buffer attributes is not supported.");r(p.buffer,d,m),p.version=d.version}}return{get:l,remove:c,update:h}}var GM=`#ifdef USE_ALPHAHASH
	if ( diffuseColor.a < getAlphaHashThreshold( vPosition ) ) discard;
#endif`,VM=`#ifdef USE_ALPHAHASH
	const float ALPHA_HASH_SCALE = 0.05;
	float hash2D( vec2 value ) {
		return fract( 1.0e4 * sin( 17.0 * value.x + 0.1 * value.y ) * ( 0.1 + abs( sin( 13.0 * value.y + value.x ) ) ) );
	}
	float hash3D( vec3 value ) {
		return hash2D( vec2( hash2D( value.xy ), value.z ) );
	}
	float getAlphaHashThreshold( vec3 position ) {
		float maxDeriv = max(
			length( dFdx( position.xyz ) ),
			length( dFdy( position.xyz ) )
		);
		float pixScale = 1.0 / ( ALPHA_HASH_SCALE * maxDeriv );
		vec2 pixScales = vec2(
			exp2( floor( log2( pixScale ) ) ),
			exp2( ceil( log2( pixScale ) ) )
		);
		vec2 alpha = vec2(
			hash3D( floor( pixScales.x * position.xyz ) ),
			hash3D( floor( pixScales.y * position.xyz ) )
		);
		float lerpFactor = fract( log2( pixScale ) );
		float x = ( 1.0 - lerpFactor ) * alpha.x + lerpFactor * alpha.y;
		float a = min( lerpFactor, 1.0 - lerpFactor );
		vec3 cases = vec3(
			x * x / ( 2.0 * a * ( 1.0 - a ) ),
			( x - 0.5 * a ) / ( 1.0 - a ),
			1.0 - ( ( 1.0 - x ) * ( 1.0 - x ) / ( 2.0 * a * ( 1.0 - a ) ) )
		);
		float threshold = ( x < ( 1.0 - a ) )
			? ( ( x < a ) ? cases.x : cases.y )
			: cases.z;
		return clamp( threshold , 1.0e-6, 1.0 );
	}
#endif`,XM=`#ifdef USE_ALPHAMAP
	diffuseColor.a *= texture2D( alphaMap, vAlphaMapUv ).g;
#endif`,kM=`#ifdef USE_ALPHAMAP
	uniform sampler2D alphaMap;
#endif`,WM=`#ifdef USE_ALPHATEST
	#ifdef ALPHA_TO_COVERAGE
	diffuseColor.a = smoothstep( alphaTest, alphaTest + fwidth( diffuseColor.a ), diffuseColor.a );
	if ( diffuseColor.a == 0.0 ) discard;
	#else
	if ( diffuseColor.a < alphaTest ) discard;
	#endif
#endif`,qM=`#ifdef USE_ALPHATEST
	uniform float alphaTest;
#endif`,YM=`#ifdef USE_AOMAP
	float ambientOcclusion = ( texture2D( aoMap, vAoMapUv ).r - 1.0 ) * aoMapIntensity + 1.0;
	reflectedLight.indirectDiffuse *= ambientOcclusion;
	#if defined( USE_CLEARCOAT ) 
		clearcoatSpecularIndirect *= ambientOcclusion;
	#endif
	#if defined( USE_SHEEN ) 
		sheenSpecularIndirect *= ambientOcclusion;
	#endif
	#if defined( USE_ENVMAP ) && defined( STANDARD )
		float dotNV = saturate( dot( geometryNormal, geometryViewDir ) );
		reflectedLight.indirectSpecular *= computeSpecularOcclusion( dotNV, ambientOcclusion, material.roughness );
	#endif
#endif`,jM=`#ifdef USE_AOMAP
	uniform sampler2D aoMap;
	uniform float aoMapIntensity;
#endif`,ZM=`#ifdef USE_BATCHING
	#if ! defined( GL_ANGLE_multi_draw )
	#define gl_DrawID _gl_DrawID
	uniform int _gl_DrawID;
	#endif
	uniform highp sampler2D batchingTexture;
	uniform highp usampler2D batchingIdTexture;
	mat4 getBatchingMatrix( const in float i ) {
		int size = textureSize( batchingTexture, 0 ).x;
		int j = int( i ) * 4;
		int x = j % size;
		int y = j / size;
		vec4 v1 = texelFetch( batchingTexture, ivec2( x, y ), 0 );
		vec4 v2 = texelFetch( batchingTexture, ivec2( x + 1, y ), 0 );
		vec4 v3 = texelFetch( batchingTexture, ivec2( x + 2, y ), 0 );
		vec4 v4 = texelFetch( batchingTexture, ivec2( x + 3, y ), 0 );
		return mat4( v1, v2, v3, v4 );
	}
	float getIndirectIndex( const in int i ) {
		int size = textureSize( batchingIdTexture, 0 ).x;
		int x = i % size;
		int y = i / size;
		return float( texelFetch( batchingIdTexture, ivec2( x, y ), 0 ).r );
	}
#endif
#ifdef USE_BATCHING_COLOR
	uniform sampler2D batchingColorTexture;
	vec3 getBatchingColor( const in float i ) {
		int size = textureSize( batchingColorTexture, 0 ).x;
		int j = int( i );
		int x = j % size;
		int y = j / size;
		return texelFetch( batchingColorTexture, ivec2( x, y ), 0 ).rgb;
	}
#endif`,KM=`#ifdef USE_BATCHING
	mat4 batchingMatrix = getBatchingMatrix( getIndirectIndex( gl_DrawID ) );
#endif`,QM=`vec3 transformed = vec3( position );
#ifdef USE_ALPHAHASH
	vPosition = vec3( position );
#endif`,JM=`vec3 objectNormal = vec3( normal );
#ifdef USE_TANGENT
	vec3 objectTangent = vec3( tangent.xyz );
#endif`,$M=`float G_BlinnPhong_Implicit( ) {
	return 0.25;
}
float D_BlinnPhong( const in float shininess, const in float dotNH ) {
	return RECIPROCAL_PI * ( shininess * 0.5 + 1.0 ) * pow( dotNH, shininess );
}
vec3 BRDF_BlinnPhong( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in vec3 specularColor, const in float shininess ) {
	vec3 halfDir = normalize( lightDir + viewDir );
	float dotNH = saturate( dot( normal, halfDir ) );
	float dotVH = saturate( dot( viewDir, halfDir ) );
	vec3 F = F_Schlick( specularColor, 1.0, dotVH );
	float G = G_BlinnPhong_Implicit( );
	float D = D_BlinnPhong( shininess, dotNH );
	return F * ( G * D );
} // validated`,ty=`#ifdef USE_IRIDESCENCE
	const mat3 XYZ_TO_REC709 = mat3(
		 3.2404542, -0.9692660,  0.0556434,
		-1.5371385,  1.8760108, -0.2040259,
		-0.4985314,  0.0415560,  1.0572252
	);
	vec3 Fresnel0ToIor( vec3 fresnel0 ) {
		vec3 sqrtF0 = sqrt( fresnel0 );
		return ( vec3( 1.0 ) + sqrtF0 ) / ( vec3( 1.0 ) - sqrtF0 );
	}
	vec3 IorToFresnel0( vec3 transmittedIor, float incidentIor ) {
		return pow2( ( transmittedIor - vec3( incidentIor ) ) / ( transmittedIor + vec3( incidentIor ) ) );
	}
	float IorToFresnel0( float transmittedIor, float incidentIor ) {
		return pow2( ( transmittedIor - incidentIor ) / ( transmittedIor + incidentIor ));
	}
	vec3 evalSensitivity( float OPD, vec3 shift ) {
		float phase = 2.0 * PI * OPD * 1.0e-9;
		vec3 val = vec3( 5.4856e-13, 4.4201e-13, 5.2481e-13 );
		vec3 pos = vec3( 1.6810e+06, 1.7953e+06, 2.2084e+06 );
		vec3 var = vec3( 4.3278e+09, 9.3046e+09, 6.6121e+09 );
		vec3 xyz = val * sqrt( 2.0 * PI * var ) * cos( pos * phase + shift ) * exp( - pow2( phase ) * var );
		xyz.x += 9.7470e-14 * sqrt( 2.0 * PI * 4.5282e+09 ) * cos( 2.2399e+06 * phase + shift[ 0 ] ) * exp( - 4.5282e+09 * pow2( phase ) );
		xyz /= 1.0685e-7;
		vec3 rgb = XYZ_TO_REC709 * xyz;
		return rgb;
	}
	vec3 evalIridescence( float outsideIOR, float eta2, float cosTheta1, float thinFilmThickness, vec3 baseF0 ) {
		vec3 I;
		float iridescenceIOR = mix( outsideIOR, eta2, smoothstep( 0.0, 0.03, thinFilmThickness ) );
		float sinTheta2Sq = pow2( outsideIOR / iridescenceIOR ) * ( 1.0 - pow2( cosTheta1 ) );
		float cosTheta2Sq = 1.0 - sinTheta2Sq;
		if ( cosTheta2Sq < 0.0 ) {
			return vec3( 1.0 );
		}
		float cosTheta2 = sqrt( cosTheta2Sq );
		float R0 = IorToFresnel0( iridescenceIOR, outsideIOR );
		float R12 = F_Schlick( R0, 1.0, cosTheta1 );
		float T121 = 1.0 - R12;
		float phi12 = 0.0;
		if ( iridescenceIOR < outsideIOR ) phi12 = PI;
		float phi21 = PI - phi12;
		vec3 baseIOR = Fresnel0ToIor( clamp( baseF0, 0.0, 0.9999 ) );		vec3 R1 = IorToFresnel0( baseIOR, iridescenceIOR );
		vec3 R23 = F_Schlick( R1, 1.0, cosTheta2 );
		vec3 phi23 = vec3( 0.0 );
		if ( baseIOR[ 0 ] < iridescenceIOR ) phi23[ 0 ] = PI;
		if ( baseIOR[ 1 ] < iridescenceIOR ) phi23[ 1 ] = PI;
		if ( baseIOR[ 2 ] < iridescenceIOR ) phi23[ 2 ] = PI;
		float OPD = 2.0 * iridescenceIOR * thinFilmThickness * cosTheta2;
		vec3 phi = vec3( phi21 ) + phi23;
		vec3 R123 = clamp( R12 * R23, 1e-5, 0.9999 );
		vec3 r123 = sqrt( R123 );
		vec3 Rs = pow2( T121 ) * R23 / ( vec3( 1.0 ) - R123 );
		vec3 C0 = R12 + Rs;
		I = C0;
		vec3 Cm = Rs - T121;
		for ( int m = 1; m <= 2; ++ m ) {
			Cm *= r123;
			vec3 Sm = 2.0 * evalSensitivity( float( m ) * OPD, float( m ) * phi );
			I += Cm * Sm;
		}
		return max( I, vec3( 0.0 ) );
	}
#endif`,ey=`#ifdef USE_BUMPMAP
	uniform sampler2D bumpMap;
	uniform float bumpScale;
	vec2 dHdxy_fwd() {
		vec2 dSTdx = dFdx( vBumpMapUv );
		vec2 dSTdy = dFdy( vBumpMapUv );
		float Hll = bumpScale * texture2D( bumpMap, vBumpMapUv ).x;
		float dBx = bumpScale * texture2D( bumpMap, vBumpMapUv + dSTdx ).x - Hll;
		float dBy = bumpScale * texture2D( bumpMap, vBumpMapUv + dSTdy ).x - Hll;
		return vec2( dBx, dBy );
	}
	vec3 perturbNormalArb( vec3 surf_pos, vec3 surf_norm, vec2 dHdxy, float faceDirection ) {
		vec3 vSigmaX = normalize( dFdx( surf_pos.xyz ) );
		vec3 vSigmaY = normalize( dFdy( surf_pos.xyz ) );
		vec3 vN = surf_norm;
		vec3 R1 = cross( vSigmaY, vN );
		vec3 R2 = cross( vN, vSigmaX );
		float fDet = dot( vSigmaX, R1 ) * faceDirection;
		vec3 vGrad = sign( fDet ) * ( dHdxy.x * R1 + dHdxy.y * R2 );
		return normalize( abs( fDet ) * surf_norm - vGrad );
	}
#endif`,ny=`#if NUM_CLIPPING_PLANES > 0
	vec4 plane;
	#ifdef ALPHA_TO_COVERAGE
		float distanceToPlane, distanceGradient;
		float clipOpacity = 1.0;
		#pragma unroll_loop_start
		for ( int i = 0; i < UNION_CLIPPING_PLANES; i ++ ) {
			plane = clippingPlanes[ i ];
			distanceToPlane = - dot( vClipPosition, plane.xyz ) + plane.w;
			distanceGradient = fwidth( distanceToPlane ) / 2.0;
			clipOpacity *= smoothstep( - distanceGradient, distanceGradient, distanceToPlane );
			if ( clipOpacity == 0.0 ) discard;
		}
		#pragma unroll_loop_end
		#if UNION_CLIPPING_PLANES < NUM_CLIPPING_PLANES
			float unionClipOpacity = 1.0;
			#pragma unroll_loop_start
			for ( int i = UNION_CLIPPING_PLANES; i < NUM_CLIPPING_PLANES; i ++ ) {
				plane = clippingPlanes[ i ];
				distanceToPlane = - dot( vClipPosition, plane.xyz ) + plane.w;
				distanceGradient = fwidth( distanceToPlane ) / 2.0;
				unionClipOpacity *= 1.0 - smoothstep( - distanceGradient, distanceGradient, distanceToPlane );
			}
			#pragma unroll_loop_end
			clipOpacity *= 1.0 - unionClipOpacity;
		#endif
		diffuseColor.a *= clipOpacity;
		if ( diffuseColor.a == 0.0 ) discard;
	#else
		#pragma unroll_loop_start
		for ( int i = 0; i < UNION_CLIPPING_PLANES; i ++ ) {
			plane = clippingPlanes[ i ];
			if ( dot( vClipPosition, plane.xyz ) > plane.w ) discard;
		}
		#pragma unroll_loop_end
		#if UNION_CLIPPING_PLANES < NUM_CLIPPING_PLANES
			bool clipped = true;
			#pragma unroll_loop_start
			for ( int i = UNION_CLIPPING_PLANES; i < NUM_CLIPPING_PLANES; i ++ ) {
				plane = clippingPlanes[ i ];
				clipped = ( dot( vClipPosition, plane.xyz ) > plane.w ) && clipped;
			}
			#pragma unroll_loop_end
			if ( clipped ) discard;
		#endif
	#endif
#endif`,iy=`#if NUM_CLIPPING_PLANES > 0
	varying vec3 vClipPosition;
	uniform vec4 clippingPlanes[ NUM_CLIPPING_PLANES ];
#endif`,ay=`#if NUM_CLIPPING_PLANES > 0
	varying vec3 vClipPosition;
#endif`,ry=`#if NUM_CLIPPING_PLANES > 0
	vClipPosition = - mvPosition.xyz;
#endif`,sy=`#if defined( USE_COLOR_ALPHA )
	diffuseColor *= vColor;
#elif defined( USE_COLOR )
	diffuseColor.rgb *= vColor;
#endif`,oy=`#if defined( USE_COLOR_ALPHA )
	varying vec4 vColor;
#elif defined( USE_COLOR )
	varying vec3 vColor;
#endif`,ly=`#if defined( USE_COLOR_ALPHA )
	varying vec4 vColor;
#elif defined( USE_COLOR ) || defined( USE_INSTANCING_COLOR ) || defined( USE_BATCHING_COLOR )
	varying vec3 vColor;
#endif`,uy=`#if defined( USE_COLOR_ALPHA )
	vColor = vec4( 1.0 );
#elif defined( USE_COLOR ) || defined( USE_INSTANCING_COLOR ) || defined( USE_BATCHING_COLOR )
	vColor = vec3( 1.0 );
#endif
#ifdef USE_COLOR
	vColor *= color;
#endif
#ifdef USE_INSTANCING_COLOR
	vColor.xyz *= instanceColor.xyz;
#endif
#ifdef USE_BATCHING_COLOR
	vec3 batchingColor = getBatchingColor( getIndirectIndex( gl_DrawID ) );
	vColor.xyz *= batchingColor.xyz;
#endif`,cy=`#define PI 3.141592653589793
#define PI2 6.283185307179586
#define PI_HALF 1.5707963267948966
#define RECIPROCAL_PI 0.3183098861837907
#define RECIPROCAL_PI2 0.15915494309189535
#define EPSILON 1e-6
#ifndef saturate
#define saturate( a ) clamp( a, 0.0, 1.0 )
#endif
#define whiteComplement( a ) ( 1.0 - saturate( a ) )
float pow2( const in float x ) { return x*x; }
vec3 pow2( const in vec3 x ) { return x*x; }
float pow3( const in float x ) { return x*x*x; }
float pow4( const in float x ) { float x2 = x*x; return x2*x2; }
float max3( const in vec3 v ) { return max( max( v.x, v.y ), v.z ); }
float average( const in vec3 v ) { return dot( v, vec3( 0.3333333 ) ); }
highp float rand( const in vec2 uv ) {
	const highp float a = 12.9898, b = 78.233, c = 43758.5453;
	highp float dt = dot( uv.xy, vec2( a,b ) ), sn = mod( dt, PI );
	return fract( sin( sn ) * c );
}
#ifdef HIGH_PRECISION
	float precisionSafeLength( vec3 v ) { return length( v ); }
#else
	float precisionSafeLength( vec3 v ) {
		float maxComponent = max3( abs( v ) );
		return length( v / maxComponent ) * maxComponent;
	}
#endif
struct IncidentLight {
	vec3 color;
	vec3 direction;
	bool visible;
};
struct ReflectedLight {
	vec3 directDiffuse;
	vec3 directSpecular;
	vec3 indirectDiffuse;
	vec3 indirectSpecular;
};
#ifdef USE_ALPHAHASH
	varying vec3 vPosition;
#endif
vec3 transformDirection( in vec3 dir, in mat4 matrix ) {
	return normalize( ( matrix * vec4( dir, 0.0 ) ).xyz );
}
vec3 inverseTransformDirection( in vec3 dir, in mat4 matrix ) {
	return normalize( ( vec4( dir, 0.0 ) * matrix ).xyz );
}
mat3 transposeMat3( const in mat3 m ) {
	mat3 tmp;
	tmp[ 0 ] = vec3( m[ 0 ].x, m[ 1 ].x, m[ 2 ].x );
	tmp[ 1 ] = vec3( m[ 0 ].y, m[ 1 ].y, m[ 2 ].y );
	tmp[ 2 ] = vec3( m[ 0 ].z, m[ 1 ].z, m[ 2 ].z );
	return tmp;
}
bool isPerspectiveMatrix( mat4 m ) {
	return m[ 2 ][ 3 ] == - 1.0;
}
vec2 equirectUv( in vec3 dir ) {
	float u = atan( dir.z, dir.x ) * RECIPROCAL_PI2 + 0.5;
	float v = asin( clamp( dir.y, - 1.0, 1.0 ) ) * RECIPROCAL_PI + 0.5;
	return vec2( u, v );
}
vec3 BRDF_Lambert( const in vec3 diffuseColor ) {
	return RECIPROCAL_PI * diffuseColor;
}
vec3 F_Schlick( const in vec3 f0, const in float f90, const in float dotVH ) {
	float fresnel = exp2( ( - 5.55473 * dotVH - 6.98316 ) * dotVH );
	return f0 * ( 1.0 - fresnel ) + ( f90 * fresnel );
}
float F_Schlick( const in float f0, const in float f90, const in float dotVH ) {
	float fresnel = exp2( ( - 5.55473 * dotVH - 6.98316 ) * dotVH );
	return f0 * ( 1.0 - fresnel ) + ( f90 * fresnel );
} // validated`,fy=`#ifdef ENVMAP_TYPE_CUBE_UV
	#define cubeUV_minMipLevel 4.0
	#define cubeUV_minTileSize 16.0
	float getFace( vec3 direction ) {
		vec3 absDirection = abs( direction );
		float face = - 1.0;
		if ( absDirection.x > absDirection.z ) {
			if ( absDirection.x > absDirection.y )
				face = direction.x > 0.0 ? 0.0 : 3.0;
			else
				face = direction.y > 0.0 ? 1.0 : 4.0;
		} else {
			if ( absDirection.z > absDirection.y )
				face = direction.z > 0.0 ? 2.0 : 5.0;
			else
				face = direction.y > 0.0 ? 1.0 : 4.0;
		}
		return face;
	}
	vec2 getUV( vec3 direction, float face ) {
		vec2 uv;
		if ( face == 0.0 ) {
			uv = vec2( direction.z, direction.y ) / abs( direction.x );
		} else if ( face == 1.0 ) {
			uv = vec2( - direction.x, - direction.z ) / abs( direction.y );
		} else if ( face == 2.0 ) {
			uv = vec2( - direction.x, direction.y ) / abs( direction.z );
		} else if ( face == 3.0 ) {
			uv = vec2( - direction.z, direction.y ) / abs( direction.x );
		} else if ( face == 4.0 ) {
			uv = vec2( - direction.x, direction.z ) / abs( direction.y );
		} else {
			uv = vec2( direction.x, direction.y ) / abs( direction.z );
		}
		return 0.5 * ( uv + 1.0 );
	}
	vec3 bilinearCubeUV( sampler2D envMap, vec3 direction, float mipInt ) {
		float face = getFace( direction );
		float filterInt = max( cubeUV_minMipLevel - mipInt, 0.0 );
		mipInt = max( mipInt, cubeUV_minMipLevel );
		float faceSize = exp2( mipInt );
		highp vec2 uv = getUV( direction, face ) * ( faceSize - 2.0 ) + 1.0;
		if ( face > 2.0 ) {
			uv.y += faceSize;
			face -= 3.0;
		}
		uv.x += face * faceSize;
		uv.x += filterInt * 3.0 * cubeUV_minTileSize;
		uv.y += 4.0 * ( exp2( CUBEUV_MAX_MIP ) - faceSize );
		uv.x *= CUBEUV_TEXEL_WIDTH;
		uv.y *= CUBEUV_TEXEL_HEIGHT;
		#ifdef texture2DGradEXT
			return texture2DGradEXT( envMap, uv, vec2( 0.0 ), vec2( 0.0 ) ).rgb;
		#else
			return texture2D( envMap, uv ).rgb;
		#endif
	}
	#define cubeUV_r0 1.0
	#define cubeUV_m0 - 2.0
	#define cubeUV_r1 0.8
	#define cubeUV_m1 - 1.0
	#define cubeUV_r4 0.4
	#define cubeUV_m4 2.0
	#define cubeUV_r5 0.305
	#define cubeUV_m5 3.0
	#define cubeUV_r6 0.21
	#define cubeUV_m6 4.0
	float roughnessToMip( float roughness ) {
		float mip = 0.0;
		if ( roughness >= cubeUV_r1 ) {
			mip = ( cubeUV_r0 - roughness ) * ( cubeUV_m1 - cubeUV_m0 ) / ( cubeUV_r0 - cubeUV_r1 ) + cubeUV_m0;
		} else if ( roughness >= cubeUV_r4 ) {
			mip = ( cubeUV_r1 - roughness ) * ( cubeUV_m4 - cubeUV_m1 ) / ( cubeUV_r1 - cubeUV_r4 ) + cubeUV_m1;
		} else if ( roughness >= cubeUV_r5 ) {
			mip = ( cubeUV_r4 - roughness ) * ( cubeUV_m5 - cubeUV_m4 ) / ( cubeUV_r4 - cubeUV_r5 ) + cubeUV_m4;
		} else if ( roughness >= cubeUV_r6 ) {
			mip = ( cubeUV_r5 - roughness ) * ( cubeUV_m6 - cubeUV_m5 ) / ( cubeUV_r5 - cubeUV_r6 ) + cubeUV_m5;
		} else {
			mip = - 2.0 * log2( 1.16 * roughness );		}
		return mip;
	}
	vec4 textureCubeUV( sampler2D envMap, vec3 sampleDir, float roughness ) {
		float mip = clamp( roughnessToMip( roughness ), cubeUV_m0, CUBEUV_MAX_MIP );
		float mipF = fract( mip );
		float mipInt = floor( mip );
		vec3 color0 = bilinearCubeUV( envMap, sampleDir, mipInt );
		if ( mipF == 0.0 ) {
			return vec4( color0, 1.0 );
		} else {
			vec3 color1 = bilinearCubeUV( envMap, sampleDir, mipInt + 1.0 );
			return vec4( mix( color0, color1, mipF ), 1.0 );
		}
	}
#endif`,hy=`vec3 transformedNormal = objectNormal;
#ifdef USE_TANGENT
	vec3 transformedTangent = objectTangent;
#endif
#ifdef USE_BATCHING
	mat3 bm = mat3( batchingMatrix );
	transformedNormal /= vec3( dot( bm[ 0 ], bm[ 0 ] ), dot( bm[ 1 ], bm[ 1 ] ), dot( bm[ 2 ], bm[ 2 ] ) );
	transformedNormal = bm * transformedNormal;
	#ifdef USE_TANGENT
		transformedTangent = bm * transformedTangent;
	#endif
#endif
#ifdef USE_INSTANCING
	mat3 im = mat3( instanceMatrix );
	transformedNormal /= vec3( dot( im[ 0 ], im[ 0 ] ), dot( im[ 1 ], im[ 1 ] ), dot( im[ 2 ], im[ 2 ] ) );
	transformedNormal = im * transformedNormal;
	#ifdef USE_TANGENT
		transformedTangent = im * transformedTangent;
	#endif
#endif
transformedNormal = normalMatrix * transformedNormal;
#ifdef FLIP_SIDED
	transformedNormal = - transformedNormal;
#endif
#ifdef USE_TANGENT
	transformedTangent = ( modelViewMatrix * vec4( transformedTangent, 0.0 ) ).xyz;
	#ifdef FLIP_SIDED
		transformedTangent = - transformedTangent;
	#endif
#endif`,dy=`#ifdef USE_DISPLACEMENTMAP
	uniform sampler2D displacementMap;
	uniform float displacementScale;
	uniform float displacementBias;
#endif`,py=`#ifdef USE_DISPLACEMENTMAP
	transformed += normalize( objectNormal ) * ( texture2D( displacementMap, vDisplacementMapUv ).x * displacementScale + displacementBias );
#endif`,my=`#ifdef USE_EMISSIVEMAP
	vec4 emissiveColor = texture2D( emissiveMap, vEmissiveMapUv );
	#ifdef DECODE_VIDEO_TEXTURE_EMISSIVE
		emissiveColor = sRGBTransferEOTF( emissiveColor );
	#endif
	totalEmissiveRadiance *= emissiveColor.rgb;
#endif`,gy=`#ifdef USE_EMISSIVEMAP
	uniform sampler2D emissiveMap;
#endif`,_y="gl_FragColor = linearToOutputTexel( gl_FragColor );",vy=`vec4 LinearTransferOETF( in vec4 value ) {
	return value;
}
vec4 sRGBTransferEOTF( in vec4 value ) {
	return vec4( mix( pow( value.rgb * 0.9478672986 + vec3( 0.0521327014 ), vec3( 2.4 ) ), value.rgb * 0.0773993808, vec3( lessThanEqual( value.rgb, vec3( 0.04045 ) ) ) ), value.a );
}
vec4 sRGBTransferOETF( in vec4 value ) {
	return vec4( mix( pow( value.rgb, vec3( 0.41666 ) ) * 1.055 - vec3( 0.055 ), value.rgb * 12.92, vec3( lessThanEqual( value.rgb, vec3( 0.0031308 ) ) ) ), value.a );
}`,Sy=`#ifdef USE_ENVMAP
	#ifdef ENV_WORLDPOS
		vec3 cameraToFrag;
		if ( isOrthographic ) {
			cameraToFrag = normalize( vec3( - viewMatrix[ 0 ][ 2 ], - viewMatrix[ 1 ][ 2 ], - viewMatrix[ 2 ][ 2 ] ) );
		} else {
			cameraToFrag = normalize( vWorldPosition - cameraPosition );
		}
		vec3 worldNormal = inverseTransformDirection( normal, viewMatrix );
		#ifdef ENVMAP_MODE_REFLECTION
			vec3 reflectVec = reflect( cameraToFrag, worldNormal );
		#else
			vec3 reflectVec = refract( cameraToFrag, worldNormal, refractionRatio );
		#endif
	#else
		vec3 reflectVec = vReflect;
	#endif
	#ifdef ENVMAP_TYPE_CUBE
		vec4 envColor = textureCube( envMap, envMapRotation * vec3( flipEnvMap * reflectVec.x, reflectVec.yz ) );
	#else
		vec4 envColor = vec4( 0.0 );
	#endif
	#ifdef ENVMAP_BLENDING_MULTIPLY
		outgoingLight = mix( outgoingLight, outgoingLight * envColor.xyz, specularStrength * reflectivity );
	#elif defined( ENVMAP_BLENDING_MIX )
		outgoingLight = mix( outgoingLight, envColor.xyz, specularStrength * reflectivity );
	#elif defined( ENVMAP_BLENDING_ADD )
		outgoingLight += envColor.xyz * specularStrength * reflectivity;
	#endif
#endif`,xy=`#ifdef USE_ENVMAP
	uniform float envMapIntensity;
	uniform float flipEnvMap;
	uniform mat3 envMapRotation;
	#ifdef ENVMAP_TYPE_CUBE
		uniform samplerCube envMap;
	#else
		uniform sampler2D envMap;
	#endif
	
#endif`,My=`#ifdef USE_ENVMAP
	uniform float reflectivity;
	#if defined( USE_BUMPMAP ) || defined( USE_NORMALMAP ) || defined( PHONG ) || defined( LAMBERT )
		#define ENV_WORLDPOS
	#endif
	#ifdef ENV_WORLDPOS
		varying vec3 vWorldPosition;
		uniform float refractionRatio;
	#else
		varying vec3 vReflect;
	#endif
#endif`,yy=`#ifdef USE_ENVMAP
	#if defined( USE_BUMPMAP ) || defined( USE_NORMALMAP ) || defined( PHONG ) || defined( LAMBERT )
		#define ENV_WORLDPOS
	#endif
	#ifdef ENV_WORLDPOS
		
		varying vec3 vWorldPosition;
	#else
		varying vec3 vReflect;
		uniform float refractionRatio;
	#endif
#endif`,Ey=`#ifdef USE_ENVMAP
	#ifdef ENV_WORLDPOS
		vWorldPosition = worldPosition.xyz;
	#else
		vec3 cameraToVertex;
		if ( isOrthographic ) {
			cameraToVertex = normalize( vec3( - viewMatrix[ 0 ][ 2 ], - viewMatrix[ 1 ][ 2 ], - viewMatrix[ 2 ][ 2 ] ) );
		} else {
			cameraToVertex = normalize( worldPosition.xyz - cameraPosition );
		}
		vec3 worldNormal = inverseTransformDirection( transformedNormal, viewMatrix );
		#ifdef ENVMAP_MODE_REFLECTION
			vReflect = reflect( cameraToVertex, worldNormal );
		#else
			vReflect = refract( cameraToVertex, worldNormal, refractionRatio );
		#endif
	#endif
#endif`,Ty=`#ifdef USE_FOG
	vFogDepth = - mvPosition.z;
#endif`,by=`#ifdef USE_FOG
	varying float vFogDepth;
#endif`,Ay=`#ifdef USE_FOG
	#ifdef FOG_EXP2
		float fogFactor = 1.0 - exp( - fogDensity * fogDensity * vFogDepth * vFogDepth );
	#else
		float fogFactor = smoothstep( fogNear, fogFar, vFogDepth );
	#endif
	gl_FragColor.rgb = mix( gl_FragColor.rgb, fogColor, fogFactor );
#endif`,Ry=`#ifdef USE_FOG
	uniform vec3 fogColor;
	varying float vFogDepth;
	#ifdef FOG_EXP2
		uniform float fogDensity;
	#else
		uniform float fogNear;
		uniform float fogFar;
	#endif
#endif`,Cy=`#ifdef USE_GRADIENTMAP
	uniform sampler2D gradientMap;
#endif
vec3 getGradientIrradiance( vec3 normal, vec3 lightDirection ) {
	float dotNL = dot( normal, lightDirection );
	vec2 coord = vec2( dotNL * 0.5 + 0.5, 0.0 );
	#ifdef USE_GRADIENTMAP
		return vec3( texture2D( gradientMap, coord ).r );
	#else
		vec2 fw = fwidth( coord ) * 0.5;
		return mix( vec3( 0.7 ), vec3( 1.0 ), smoothstep( 0.7 - fw.x, 0.7 + fw.x, coord.x ) );
	#endif
}`,wy=`#ifdef USE_LIGHTMAP
	uniform sampler2D lightMap;
	uniform float lightMapIntensity;
#endif`,Dy=`LambertMaterial material;
material.diffuseColor = diffuseColor.rgb;
material.specularStrength = specularStrength;`,Uy=`varying vec3 vViewPosition;
struct LambertMaterial {
	vec3 diffuseColor;
	float specularStrength;
};
void RE_Direct_Lambert( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in LambertMaterial material, inout ReflectedLight reflectedLight ) {
	float dotNL = saturate( dot( geometryNormal, directLight.direction ) );
	vec3 irradiance = dotNL * directLight.color;
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectDiffuse_Lambert( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in LambertMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
#define RE_Direct				RE_Direct_Lambert
#define RE_IndirectDiffuse		RE_IndirectDiffuse_Lambert`,Ly=`uniform bool receiveShadow;
uniform vec3 ambientLightColor;
#if defined( USE_LIGHT_PROBES )
	uniform vec3 lightProbe[ 9 ];
#endif
vec3 shGetIrradianceAt( in vec3 normal, in vec3 shCoefficients[ 9 ] ) {
	float x = normal.x, y = normal.y, z = normal.z;
	vec3 result = shCoefficients[ 0 ] * 0.886227;
	result += shCoefficients[ 1 ] * 2.0 * 0.511664 * y;
	result += shCoefficients[ 2 ] * 2.0 * 0.511664 * z;
	result += shCoefficients[ 3 ] * 2.0 * 0.511664 * x;
	result += shCoefficients[ 4 ] * 2.0 * 0.429043 * x * y;
	result += shCoefficients[ 5 ] * 2.0 * 0.429043 * y * z;
	result += shCoefficients[ 6 ] * ( 0.743125 * z * z - 0.247708 );
	result += shCoefficients[ 7 ] * 2.0 * 0.429043 * x * z;
	result += shCoefficients[ 8 ] * 0.429043 * ( x * x - y * y );
	return result;
}
vec3 getLightProbeIrradiance( const in vec3 lightProbe[ 9 ], const in vec3 normal ) {
	vec3 worldNormal = inverseTransformDirection( normal, viewMatrix );
	vec3 irradiance = shGetIrradianceAt( worldNormal, lightProbe );
	return irradiance;
}
vec3 getAmbientLightIrradiance( const in vec3 ambientLightColor ) {
	vec3 irradiance = ambientLightColor;
	return irradiance;
}
float getDistanceAttenuation( const in float lightDistance, const in float cutoffDistance, const in float decayExponent ) {
	float distanceFalloff = 1.0 / max( pow( lightDistance, decayExponent ), 0.01 );
	if ( cutoffDistance > 0.0 ) {
		distanceFalloff *= pow2( saturate( 1.0 - pow4( lightDistance / cutoffDistance ) ) );
	}
	return distanceFalloff;
}
float getSpotAttenuation( const in float coneCosine, const in float penumbraCosine, const in float angleCosine ) {
	return smoothstep( coneCosine, penumbraCosine, angleCosine );
}
#if NUM_DIR_LIGHTS > 0
	struct DirectionalLight {
		vec3 direction;
		vec3 color;
	};
	uniform DirectionalLight directionalLights[ NUM_DIR_LIGHTS ];
	void getDirectionalLightInfo( const in DirectionalLight directionalLight, out IncidentLight light ) {
		light.color = directionalLight.color;
		light.direction = directionalLight.direction;
		light.visible = true;
	}
#endif
#if NUM_POINT_LIGHTS > 0
	struct PointLight {
		vec3 position;
		vec3 color;
		float distance;
		float decay;
	};
	uniform PointLight pointLights[ NUM_POINT_LIGHTS ];
	void getPointLightInfo( const in PointLight pointLight, const in vec3 geometryPosition, out IncidentLight light ) {
		vec3 lVector = pointLight.position - geometryPosition;
		light.direction = normalize( lVector );
		float lightDistance = length( lVector );
		light.color = pointLight.color;
		light.color *= getDistanceAttenuation( lightDistance, pointLight.distance, pointLight.decay );
		light.visible = ( light.color != vec3( 0.0 ) );
	}
#endif
#if NUM_SPOT_LIGHTS > 0
	struct SpotLight {
		vec3 position;
		vec3 direction;
		vec3 color;
		float distance;
		float decay;
		float coneCos;
		float penumbraCos;
	};
	uniform SpotLight spotLights[ NUM_SPOT_LIGHTS ];
	void getSpotLightInfo( const in SpotLight spotLight, const in vec3 geometryPosition, out IncidentLight light ) {
		vec3 lVector = spotLight.position - geometryPosition;
		light.direction = normalize( lVector );
		float angleCos = dot( light.direction, spotLight.direction );
		float spotAttenuation = getSpotAttenuation( spotLight.coneCos, spotLight.penumbraCos, angleCos );
		if ( spotAttenuation > 0.0 ) {
			float lightDistance = length( lVector );
			light.color = spotLight.color * spotAttenuation;
			light.color *= getDistanceAttenuation( lightDistance, spotLight.distance, spotLight.decay );
			light.visible = ( light.color != vec3( 0.0 ) );
		} else {
			light.color = vec3( 0.0 );
			light.visible = false;
		}
	}
#endif
#if NUM_RECT_AREA_LIGHTS > 0
	struct RectAreaLight {
		vec3 color;
		vec3 position;
		vec3 halfWidth;
		vec3 halfHeight;
	};
	uniform sampler2D ltc_1;	uniform sampler2D ltc_2;
	uniform RectAreaLight rectAreaLights[ NUM_RECT_AREA_LIGHTS ];
#endif
#if NUM_HEMI_LIGHTS > 0
	struct HemisphereLight {
		vec3 direction;
		vec3 skyColor;
		vec3 groundColor;
	};
	uniform HemisphereLight hemisphereLights[ NUM_HEMI_LIGHTS ];
	vec3 getHemisphereLightIrradiance( const in HemisphereLight hemiLight, const in vec3 normal ) {
		float dotNL = dot( normal, hemiLight.direction );
		float hemiDiffuseWeight = 0.5 * dotNL + 0.5;
		vec3 irradiance = mix( hemiLight.groundColor, hemiLight.skyColor, hemiDiffuseWeight );
		return irradiance;
	}
#endif`,Ny=`#ifdef USE_ENVMAP
	vec3 getIBLIrradiance( const in vec3 normal ) {
		#ifdef ENVMAP_TYPE_CUBE_UV
			vec3 worldNormal = inverseTransformDirection( normal, viewMatrix );
			vec4 envMapColor = textureCubeUV( envMap, envMapRotation * worldNormal, 1.0 );
			return PI * envMapColor.rgb * envMapIntensity;
		#else
			return vec3( 0.0 );
		#endif
	}
	vec3 getIBLRadiance( const in vec3 viewDir, const in vec3 normal, const in float roughness ) {
		#ifdef ENVMAP_TYPE_CUBE_UV
			vec3 reflectVec = reflect( - viewDir, normal );
			reflectVec = normalize( mix( reflectVec, normal, roughness * roughness) );
			reflectVec = inverseTransformDirection( reflectVec, viewMatrix );
			vec4 envMapColor = textureCubeUV( envMap, envMapRotation * reflectVec, roughness );
			return envMapColor.rgb * envMapIntensity;
		#else
			return vec3( 0.0 );
		#endif
	}
	#ifdef USE_ANISOTROPY
		vec3 getIBLAnisotropyRadiance( const in vec3 viewDir, const in vec3 normal, const in float roughness, const in vec3 bitangent, const in float anisotropy ) {
			#ifdef ENVMAP_TYPE_CUBE_UV
				vec3 bentNormal = cross( bitangent, viewDir );
				bentNormal = normalize( cross( bentNormal, bitangent ) );
				bentNormal = normalize( mix( bentNormal, normal, pow2( pow2( 1.0 - anisotropy * ( 1.0 - roughness ) ) ) ) );
				return getIBLRadiance( viewDir, bentNormal, roughness );
			#else
				return vec3( 0.0 );
			#endif
		}
	#endif
#endif`,Oy=`ToonMaterial material;
material.diffuseColor = diffuseColor.rgb;`,zy=`varying vec3 vViewPosition;
struct ToonMaterial {
	vec3 diffuseColor;
};
void RE_Direct_Toon( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in ToonMaterial material, inout ReflectedLight reflectedLight ) {
	vec3 irradiance = getGradientIrradiance( geometryNormal, directLight.direction ) * directLight.color;
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectDiffuse_Toon( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in ToonMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
#define RE_Direct				RE_Direct_Toon
#define RE_IndirectDiffuse		RE_IndirectDiffuse_Toon`,Py=`BlinnPhongMaterial material;
material.diffuseColor = diffuseColor.rgb;
material.specularColor = specular;
material.specularShininess = shininess;
material.specularStrength = specularStrength;`,By=`varying vec3 vViewPosition;
struct BlinnPhongMaterial {
	vec3 diffuseColor;
	vec3 specularColor;
	float specularShininess;
	float specularStrength;
};
void RE_Direct_BlinnPhong( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in BlinnPhongMaterial material, inout ReflectedLight reflectedLight ) {
	float dotNL = saturate( dot( geometryNormal, directLight.direction ) );
	vec3 irradiance = dotNL * directLight.color;
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
	reflectedLight.directSpecular += irradiance * BRDF_BlinnPhong( directLight.direction, geometryViewDir, geometryNormal, material.specularColor, material.specularShininess ) * material.specularStrength;
}
void RE_IndirectDiffuse_BlinnPhong( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in BlinnPhongMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
#define RE_Direct				RE_Direct_BlinnPhong
#define RE_IndirectDiffuse		RE_IndirectDiffuse_BlinnPhong`,Iy=`PhysicalMaterial material;
material.diffuseColor = diffuseColor.rgb * ( 1.0 - metalnessFactor );
vec3 dxy = max( abs( dFdx( nonPerturbedNormal ) ), abs( dFdy( nonPerturbedNormal ) ) );
float geometryRoughness = max( max( dxy.x, dxy.y ), dxy.z );
material.roughness = max( roughnessFactor, 0.0525 );material.roughness += geometryRoughness;
material.roughness = min( material.roughness, 1.0 );
#ifdef IOR
	material.ior = ior;
	#ifdef USE_SPECULAR
		float specularIntensityFactor = specularIntensity;
		vec3 specularColorFactor = specularColor;
		#ifdef USE_SPECULAR_COLORMAP
			specularColorFactor *= texture2D( specularColorMap, vSpecularColorMapUv ).rgb;
		#endif
		#ifdef USE_SPECULAR_INTENSITYMAP
			specularIntensityFactor *= texture2D( specularIntensityMap, vSpecularIntensityMapUv ).a;
		#endif
		material.specularF90 = mix( specularIntensityFactor, 1.0, metalnessFactor );
	#else
		float specularIntensityFactor = 1.0;
		vec3 specularColorFactor = vec3( 1.0 );
		material.specularF90 = 1.0;
	#endif
	material.specularColor = mix( min( pow2( ( material.ior - 1.0 ) / ( material.ior + 1.0 ) ) * specularColorFactor, vec3( 1.0 ) ) * specularIntensityFactor, diffuseColor.rgb, metalnessFactor );
#else
	material.specularColor = mix( vec3( 0.04 ), diffuseColor.rgb, metalnessFactor );
	material.specularF90 = 1.0;
#endif
#ifdef USE_CLEARCOAT
	material.clearcoat = clearcoat;
	material.clearcoatRoughness = clearcoatRoughness;
	material.clearcoatF0 = vec3( 0.04 );
	material.clearcoatF90 = 1.0;
	#ifdef USE_CLEARCOATMAP
		material.clearcoat *= texture2D( clearcoatMap, vClearcoatMapUv ).x;
	#endif
	#ifdef USE_CLEARCOAT_ROUGHNESSMAP
		material.clearcoatRoughness *= texture2D( clearcoatRoughnessMap, vClearcoatRoughnessMapUv ).y;
	#endif
	material.clearcoat = saturate( material.clearcoat );	material.clearcoatRoughness = max( material.clearcoatRoughness, 0.0525 );
	material.clearcoatRoughness += geometryRoughness;
	material.clearcoatRoughness = min( material.clearcoatRoughness, 1.0 );
#endif
#ifdef USE_DISPERSION
	material.dispersion = dispersion;
#endif
#ifdef USE_IRIDESCENCE
	material.iridescence = iridescence;
	material.iridescenceIOR = iridescenceIOR;
	#ifdef USE_IRIDESCENCEMAP
		material.iridescence *= texture2D( iridescenceMap, vIridescenceMapUv ).r;
	#endif
	#ifdef USE_IRIDESCENCE_THICKNESSMAP
		material.iridescenceThickness = (iridescenceThicknessMaximum - iridescenceThicknessMinimum) * texture2D( iridescenceThicknessMap, vIridescenceThicknessMapUv ).g + iridescenceThicknessMinimum;
	#else
		material.iridescenceThickness = iridescenceThicknessMaximum;
	#endif
#endif
#ifdef USE_SHEEN
	material.sheenColor = sheenColor;
	#ifdef USE_SHEEN_COLORMAP
		material.sheenColor *= texture2D( sheenColorMap, vSheenColorMapUv ).rgb;
	#endif
	material.sheenRoughness = clamp( sheenRoughness, 0.07, 1.0 );
	#ifdef USE_SHEEN_ROUGHNESSMAP
		material.sheenRoughness *= texture2D( sheenRoughnessMap, vSheenRoughnessMapUv ).a;
	#endif
#endif
#ifdef USE_ANISOTROPY
	#ifdef USE_ANISOTROPYMAP
		mat2 anisotropyMat = mat2( anisotropyVector.x, anisotropyVector.y, - anisotropyVector.y, anisotropyVector.x );
		vec3 anisotropyPolar = texture2D( anisotropyMap, vAnisotropyMapUv ).rgb;
		vec2 anisotropyV = anisotropyMat * normalize( 2.0 * anisotropyPolar.rg - vec2( 1.0 ) ) * anisotropyPolar.b;
	#else
		vec2 anisotropyV = anisotropyVector;
	#endif
	material.anisotropy = length( anisotropyV );
	if( material.anisotropy == 0.0 ) {
		anisotropyV = vec2( 1.0, 0.0 );
	} else {
		anisotropyV /= material.anisotropy;
		material.anisotropy = saturate( material.anisotropy );
	}
	material.alphaT = mix( pow2( material.roughness ), 1.0, pow2( material.anisotropy ) );
	material.anisotropyT = tbn[ 0 ] * anisotropyV.x + tbn[ 1 ] * anisotropyV.y;
	material.anisotropyB = tbn[ 1 ] * anisotropyV.x - tbn[ 0 ] * anisotropyV.y;
#endif`,Fy=`struct PhysicalMaterial {
	vec3 diffuseColor;
	float roughness;
	vec3 specularColor;
	float specularF90;
	float dispersion;
	#ifdef USE_CLEARCOAT
		float clearcoat;
		float clearcoatRoughness;
		vec3 clearcoatF0;
		float clearcoatF90;
	#endif
	#ifdef USE_IRIDESCENCE
		float iridescence;
		float iridescenceIOR;
		float iridescenceThickness;
		vec3 iridescenceFresnel;
		vec3 iridescenceF0;
	#endif
	#ifdef USE_SHEEN
		vec3 sheenColor;
		float sheenRoughness;
	#endif
	#ifdef IOR
		float ior;
	#endif
	#ifdef USE_TRANSMISSION
		float transmission;
		float transmissionAlpha;
		float thickness;
		float attenuationDistance;
		vec3 attenuationColor;
	#endif
	#ifdef USE_ANISOTROPY
		float anisotropy;
		float alphaT;
		vec3 anisotropyT;
		vec3 anisotropyB;
	#endif
};
vec3 clearcoatSpecularDirect = vec3( 0.0 );
vec3 clearcoatSpecularIndirect = vec3( 0.0 );
vec3 sheenSpecularDirect = vec3( 0.0 );
vec3 sheenSpecularIndirect = vec3(0.0 );
vec3 Schlick_to_F0( const in vec3 f, const in float f90, const in float dotVH ) {
    float x = clamp( 1.0 - dotVH, 0.0, 1.0 );
    float x2 = x * x;
    float x5 = clamp( x * x2 * x2, 0.0, 0.9999 );
    return ( f - vec3( f90 ) * x5 ) / ( 1.0 - x5 );
}
float V_GGX_SmithCorrelated( const in float alpha, const in float dotNL, const in float dotNV ) {
	float a2 = pow2( alpha );
	float gv = dotNL * sqrt( a2 + ( 1.0 - a2 ) * pow2( dotNV ) );
	float gl = dotNV * sqrt( a2 + ( 1.0 - a2 ) * pow2( dotNL ) );
	return 0.5 / max( gv + gl, EPSILON );
}
float D_GGX( const in float alpha, const in float dotNH ) {
	float a2 = pow2( alpha );
	float denom = pow2( dotNH ) * ( a2 - 1.0 ) + 1.0;
	return RECIPROCAL_PI * a2 / pow2( denom );
}
#ifdef USE_ANISOTROPY
	float V_GGX_SmithCorrelated_Anisotropic( const in float alphaT, const in float alphaB, const in float dotTV, const in float dotBV, const in float dotTL, const in float dotBL, const in float dotNV, const in float dotNL ) {
		float gv = dotNL * length( vec3( alphaT * dotTV, alphaB * dotBV, dotNV ) );
		float gl = dotNV * length( vec3( alphaT * dotTL, alphaB * dotBL, dotNL ) );
		float v = 0.5 / ( gv + gl );
		return saturate(v);
	}
	float D_GGX_Anisotropic( const in float alphaT, const in float alphaB, const in float dotNH, const in float dotTH, const in float dotBH ) {
		float a2 = alphaT * alphaB;
		highp vec3 v = vec3( alphaB * dotTH, alphaT * dotBH, a2 * dotNH );
		highp float v2 = dot( v, v );
		float w2 = a2 / v2;
		return RECIPROCAL_PI * a2 * pow2 ( w2 );
	}
#endif
#ifdef USE_CLEARCOAT
	vec3 BRDF_GGX_Clearcoat( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in PhysicalMaterial material) {
		vec3 f0 = material.clearcoatF0;
		float f90 = material.clearcoatF90;
		float roughness = material.clearcoatRoughness;
		float alpha = pow2( roughness );
		vec3 halfDir = normalize( lightDir + viewDir );
		float dotNL = saturate( dot( normal, lightDir ) );
		float dotNV = saturate( dot( normal, viewDir ) );
		float dotNH = saturate( dot( normal, halfDir ) );
		float dotVH = saturate( dot( viewDir, halfDir ) );
		vec3 F = F_Schlick( f0, f90, dotVH );
		float V = V_GGX_SmithCorrelated( alpha, dotNL, dotNV );
		float D = D_GGX( alpha, dotNH );
		return F * ( V * D );
	}
#endif
vec3 BRDF_GGX( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in PhysicalMaterial material ) {
	vec3 f0 = material.specularColor;
	float f90 = material.specularF90;
	float roughness = material.roughness;
	float alpha = pow2( roughness );
	vec3 halfDir = normalize( lightDir + viewDir );
	float dotNL = saturate( dot( normal, lightDir ) );
	float dotNV = saturate( dot( normal, viewDir ) );
	float dotNH = saturate( dot( normal, halfDir ) );
	float dotVH = saturate( dot( viewDir, halfDir ) );
	vec3 F = F_Schlick( f0, f90, dotVH );
	#ifdef USE_IRIDESCENCE
		F = mix( F, material.iridescenceFresnel, material.iridescence );
	#endif
	#ifdef USE_ANISOTROPY
		float dotTL = dot( material.anisotropyT, lightDir );
		float dotTV = dot( material.anisotropyT, viewDir );
		float dotTH = dot( material.anisotropyT, halfDir );
		float dotBL = dot( material.anisotropyB, lightDir );
		float dotBV = dot( material.anisotropyB, viewDir );
		float dotBH = dot( material.anisotropyB, halfDir );
		float V = V_GGX_SmithCorrelated_Anisotropic( material.alphaT, alpha, dotTV, dotBV, dotTL, dotBL, dotNV, dotNL );
		float D = D_GGX_Anisotropic( material.alphaT, alpha, dotNH, dotTH, dotBH );
	#else
		float V = V_GGX_SmithCorrelated( alpha, dotNL, dotNV );
		float D = D_GGX( alpha, dotNH );
	#endif
	return F * ( V * D );
}
vec2 LTC_Uv( const in vec3 N, const in vec3 V, const in float roughness ) {
	const float LUT_SIZE = 64.0;
	const float LUT_SCALE = ( LUT_SIZE - 1.0 ) / LUT_SIZE;
	const float LUT_BIAS = 0.5 / LUT_SIZE;
	float dotNV = saturate( dot( N, V ) );
	vec2 uv = vec2( roughness, sqrt( 1.0 - dotNV ) );
	uv = uv * LUT_SCALE + LUT_BIAS;
	return uv;
}
float LTC_ClippedSphereFormFactor( const in vec3 f ) {
	float l = length( f );
	return max( ( l * l + f.z ) / ( l + 1.0 ), 0.0 );
}
vec3 LTC_EdgeVectorFormFactor( const in vec3 v1, const in vec3 v2 ) {
	float x = dot( v1, v2 );
	float y = abs( x );
	float a = 0.8543985 + ( 0.4965155 + 0.0145206 * y ) * y;
	float b = 3.4175940 + ( 4.1616724 + y ) * y;
	float v = a / b;
	float theta_sintheta = ( x > 0.0 ) ? v : 0.5 * inversesqrt( max( 1.0 - x * x, 1e-7 ) ) - v;
	return cross( v1, v2 ) * theta_sintheta;
}
vec3 LTC_Evaluate( const in vec3 N, const in vec3 V, const in vec3 P, const in mat3 mInv, const in vec3 rectCoords[ 4 ] ) {
	vec3 v1 = rectCoords[ 1 ] - rectCoords[ 0 ];
	vec3 v2 = rectCoords[ 3 ] - rectCoords[ 0 ];
	vec3 lightNormal = cross( v1, v2 );
	if( dot( lightNormal, P - rectCoords[ 0 ] ) < 0.0 ) return vec3( 0.0 );
	vec3 T1, T2;
	T1 = normalize( V - N * dot( V, N ) );
	T2 = - cross( N, T1 );
	mat3 mat = mInv * transposeMat3( mat3( T1, T2, N ) );
	vec3 coords[ 4 ];
	coords[ 0 ] = mat * ( rectCoords[ 0 ] - P );
	coords[ 1 ] = mat * ( rectCoords[ 1 ] - P );
	coords[ 2 ] = mat * ( rectCoords[ 2 ] - P );
	coords[ 3 ] = mat * ( rectCoords[ 3 ] - P );
	coords[ 0 ] = normalize( coords[ 0 ] );
	coords[ 1 ] = normalize( coords[ 1 ] );
	coords[ 2 ] = normalize( coords[ 2 ] );
	coords[ 3 ] = normalize( coords[ 3 ] );
	vec3 vectorFormFactor = vec3( 0.0 );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 0 ], coords[ 1 ] );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 1 ], coords[ 2 ] );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 2 ], coords[ 3 ] );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 3 ], coords[ 0 ] );
	float result = LTC_ClippedSphereFormFactor( vectorFormFactor );
	return vec3( result );
}
#if defined( USE_SHEEN )
float D_Charlie( float roughness, float dotNH ) {
	float alpha = pow2( roughness );
	float invAlpha = 1.0 / alpha;
	float cos2h = dotNH * dotNH;
	float sin2h = max( 1.0 - cos2h, 0.0078125 );
	return ( 2.0 + invAlpha ) * pow( sin2h, invAlpha * 0.5 ) / ( 2.0 * PI );
}
float V_Neubelt( float dotNV, float dotNL ) {
	return saturate( 1.0 / ( 4.0 * ( dotNL + dotNV - dotNL * dotNV ) ) );
}
vec3 BRDF_Sheen( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, vec3 sheenColor, const in float sheenRoughness ) {
	vec3 halfDir = normalize( lightDir + viewDir );
	float dotNL = saturate( dot( normal, lightDir ) );
	float dotNV = saturate( dot( normal, viewDir ) );
	float dotNH = saturate( dot( normal, halfDir ) );
	float D = D_Charlie( sheenRoughness, dotNH );
	float V = V_Neubelt( dotNV, dotNL );
	return sheenColor * ( D * V );
}
#endif
float IBLSheenBRDF( const in vec3 normal, const in vec3 viewDir, const in float roughness ) {
	float dotNV = saturate( dot( normal, viewDir ) );
	float r2 = roughness * roughness;
	float a = roughness < 0.25 ? -339.2 * r2 + 161.4 * roughness - 25.9 : -8.48 * r2 + 14.3 * roughness - 9.95;
	float b = roughness < 0.25 ? 44.0 * r2 - 23.7 * roughness + 3.26 : 1.97 * r2 - 3.27 * roughness + 0.72;
	float DG = exp( a * dotNV + b ) + ( roughness < 0.25 ? 0.0 : 0.1 * ( roughness - 0.25 ) );
	return saturate( DG * RECIPROCAL_PI );
}
vec2 DFGApprox( const in vec3 normal, const in vec3 viewDir, const in float roughness ) {
	float dotNV = saturate( dot( normal, viewDir ) );
	const vec4 c0 = vec4( - 1, - 0.0275, - 0.572, 0.022 );
	const vec4 c1 = vec4( 1, 0.0425, 1.04, - 0.04 );
	vec4 r = roughness * c0 + c1;
	float a004 = min( r.x * r.x, exp2( - 9.28 * dotNV ) ) * r.x + r.y;
	vec2 fab = vec2( - 1.04, 1.04 ) * a004 + r.zw;
	return fab;
}
vec3 EnvironmentBRDF( const in vec3 normal, const in vec3 viewDir, const in vec3 specularColor, const in float specularF90, const in float roughness ) {
	vec2 fab = DFGApprox( normal, viewDir, roughness );
	return specularColor * fab.x + specularF90 * fab.y;
}
#ifdef USE_IRIDESCENCE
void computeMultiscatteringIridescence( const in vec3 normal, const in vec3 viewDir, const in vec3 specularColor, const in float specularF90, const in float iridescence, const in vec3 iridescenceF0, const in float roughness, inout vec3 singleScatter, inout vec3 multiScatter ) {
#else
void computeMultiscattering( const in vec3 normal, const in vec3 viewDir, const in vec3 specularColor, const in float specularF90, const in float roughness, inout vec3 singleScatter, inout vec3 multiScatter ) {
#endif
	vec2 fab = DFGApprox( normal, viewDir, roughness );
	#ifdef USE_IRIDESCENCE
		vec3 Fr = mix( specularColor, iridescenceF0, iridescence );
	#else
		vec3 Fr = specularColor;
	#endif
	vec3 FssEss = Fr * fab.x + specularF90 * fab.y;
	float Ess = fab.x + fab.y;
	float Ems = 1.0 - Ess;
	vec3 Favg = Fr + ( 1.0 - Fr ) * 0.047619;	vec3 Fms = FssEss * Favg / ( 1.0 - Ems * Favg );
	singleScatter += FssEss;
	multiScatter += Fms * Ems;
}
#if NUM_RECT_AREA_LIGHTS > 0
	void RE_Direct_RectArea_Physical( const in RectAreaLight rectAreaLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight ) {
		vec3 normal = geometryNormal;
		vec3 viewDir = geometryViewDir;
		vec3 position = geometryPosition;
		vec3 lightPos = rectAreaLight.position;
		vec3 halfWidth = rectAreaLight.halfWidth;
		vec3 halfHeight = rectAreaLight.halfHeight;
		vec3 lightColor = rectAreaLight.color;
		float roughness = material.roughness;
		vec3 rectCoords[ 4 ];
		rectCoords[ 0 ] = lightPos + halfWidth - halfHeight;		rectCoords[ 1 ] = lightPos - halfWidth - halfHeight;
		rectCoords[ 2 ] = lightPos - halfWidth + halfHeight;
		rectCoords[ 3 ] = lightPos + halfWidth + halfHeight;
		vec2 uv = LTC_Uv( normal, viewDir, roughness );
		vec4 t1 = texture2D( ltc_1, uv );
		vec4 t2 = texture2D( ltc_2, uv );
		mat3 mInv = mat3(
			vec3( t1.x, 0, t1.y ),
			vec3(    0, 1,    0 ),
			vec3( t1.z, 0, t1.w )
		);
		vec3 fresnel = ( material.specularColor * t2.x + ( vec3( 1.0 ) - material.specularColor ) * t2.y );
		reflectedLight.directSpecular += lightColor * fresnel * LTC_Evaluate( normal, viewDir, position, mInv, rectCoords );
		reflectedLight.directDiffuse += lightColor * material.diffuseColor * LTC_Evaluate( normal, viewDir, position, mat3( 1.0 ), rectCoords );
	}
#endif
void RE_Direct_Physical( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight ) {
	float dotNL = saturate( dot( geometryNormal, directLight.direction ) );
	vec3 irradiance = dotNL * directLight.color;
	#ifdef USE_CLEARCOAT
		float dotNLcc = saturate( dot( geometryClearcoatNormal, directLight.direction ) );
		vec3 ccIrradiance = dotNLcc * directLight.color;
		clearcoatSpecularDirect += ccIrradiance * BRDF_GGX_Clearcoat( directLight.direction, geometryViewDir, geometryClearcoatNormal, material );
	#endif
	#ifdef USE_SHEEN
		sheenSpecularDirect += irradiance * BRDF_Sheen( directLight.direction, geometryViewDir, geometryNormal, material.sheenColor, material.sheenRoughness );
	#endif
	reflectedLight.directSpecular += irradiance * BRDF_GGX( directLight.direction, geometryViewDir, geometryNormal, material );
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectDiffuse_Physical( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectSpecular_Physical( const in vec3 radiance, const in vec3 irradiance, const in vec3 clearcoatRadiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight) {
	#ifdef USE_CLEARCOAT
		clearcoatSpecularIndirect += clearcoatRadiance * EnvironmentBRDF( geometryClearcoatNormal, geometryViewDir, material.clearcoatF0, material.clearcoatF90, material.clearcoatRoughness );
	#endif
	#ifdef USE_SHEEN
		sheenSpecularIndirect += irradiance * material.sheenColor * IBLSheenBRDF( geometryNormal, geometryViewDir, material.sheenRoughness );
	#endif
	vec3 singleScattering = vec3( 0.0 );
	vec3 multiScattering = vec3( 0.0 );
	vec3 cosineWeightedIrradiance = irradiance * RECIPROCAL_PI;
	#ifdef USE_IRIDESCENCE
		computeMultiscatteringIridescence( geometryNormal, geometryViewDir, material.specularColor, material.specularF90, material.iridescence, material.iridescenceFresnel, material.roughness, singleScattering, multiScattering );
	#else
		computeMultiscattering( geometryNormal, geometryViewDir, material.specularColor, material.specularF90, material.roughness, singleScattering, multiScattering );
	#endif
	vec3 totalScattering = singleScattering + multiScattering;
	vec3 diffuse = material.diffuseColor * ( 1.0 - max( max( totalScattering.r, totalScattering.g ), totalScattering.b ) );
	reflectedLight.indirectSpecular += radiance * singleScattering;
	reflectedLight.indirectSpecular += multiScattering * cosineWeightedIrradiance;
	reflectedLight.indirectDiffuse += diffuse * cosineWeightedIrradiance;
}
#define RE_Direct				RE_Direct_Physical
#define RE_Direct_RectArea		RE_Direct_RectArea_Physical
#define RE_IndirectDiffuse		RE_IndirectDiffuse_Physical
#define RE_IndirectSpecular		RE_IndirectSpecular_Physical
float computeSpecularOcclusion( const in float dotNV, const in float ambientOcclusion, const in float roughness ) {
	return saturate( pow( dotNV + ambientOcclusion, exp2( - 16.0 * roughness - 1.0 ) ) - 1.0 + ambientOcclusion );
}`,Hy=`
vec3 geometryPosition = - vViewPosition;
vec3 geometryNormal = normal;
vec3 geometryViewDir = ( isOrthographic ) ? vec3( 0, 0, 1 ) : normalize( vViewPosition );
vec3 geometryClearcoatNormal = vec3( 0.0 );
#ifdef USE_CLEARCOAT
	geometryClearcoatNormal = clearcoatNormal;
#endif
#ifdef USE_IRIDESCENCE
	float dotNVi = saturate( dot( normal, geometryViewDir ) );
	if ( material.iridescenceThickness == 0.0 ) {
		material.iridescence = 0.0;
	} else {
		material.iridescence = saturate( material.iridescence );
	}
	if ( material.iridescence > 0.0 ) {
		material.iridescenceFresnel = evalIridescence( 1.0, material.iridescenceIOR, dotNVi, material.iridescenceThickness, material.specularColor );
		material.iridescenceF0 = Schlick_to_F0( material.iridescenceFresnel, 1.0, dotNVi );
	}
#endif
IncidentLight directLight;
#if ( NUM_POINT_LIGHTS > 0 ) && defined( RE_Direct )
	PointLight pointLight;
	#if defined( USE_SHADOWMAP ) && NUM_POINT_LIGHT_SHADOWS > 0
	PointLightShadow pointLightShadow;
	#endif
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_POINT_LIGHTS; i ++ ) {
		pointLight = pointLights[ i ];
		getPointLightInfo( pointLight, geometryPosition, directLight );
		#if defined( USE_SHADOWMAP ) && ( UNROLLED_LOOP_INDEX < NUM_POINT_LIGHT_SHADOWS )
		pointLightShadow = pointLightShadows[ i ];
		directLight.color *= ( directLight.visible && receiveShadow ) ? getPointShadow( pointShadowMap[ i ], pointLightShadow.shadowMapSize, pointLightShadow.shadowIntensity, pointLightShadow.shadowBias, pointLightShadow.shadowRadius, vPointShadowCoord[ i ], pointLightShadow.shadowCameraNear, pointLightShadow.shadowCameraFar ) : 1.0;
		#endif
		RE_Direct( directLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if ( NUM_SPOT_LIGHTS > 0 ) && defined( RE_Direct )
	SpotLight spotLight;
	vec4 spotColor;
	vec3 spotLightCoord;
	bool inSpotLightMap;
	#if defined( USE_SHADOWMAP ) && NUM_SPOT_LIGHT_SHADOWS > 0
	SpotLightShadow spotLightShadow;
	#endif
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_SPOT_LIGHTS; i ++ ) {
		spotLight = spotLights[ i ];
		getSpotLightInfo( spotLight, geometryPosition, directLight );
		#if ( UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS_WITH_MAPS )
		#define SPOT_LIGHT_MAP_INDEX UNROLLED_LOOP_INDEX
		#elif ( UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS )
		#define SPOT_LIGHT_MAP_INDEX NUM_SPOT_LIGHT_MAPS
		#else
		#define SPOT_LIGHT_MAP_INDEX ( UNROLLED_LOOP_INDEX - NUM_SPOT_LIGHT_SHADOWS + NUM_SPOT_LIGHT_SHADOWS_WITH_MAPS )
		#endif
		#if ( SPOT_LIGHT_MAP_INDEX < NUM_SPOT_LIGHT_MAPS )
			spotLightCoord = vSpotLightCoord[ i ].xyz / vSpotLightCoord[ i ].w;
			inSpotLightMap = all( lessThan( abs( spotLightCoord * 2. - 1. ), vec3( 1.0 ) ) );
			spotColor = texture2D( spotLightMap[ SPOT_LIGHT_MAP_INDEX ], spotLightCoord.xy );
			directLight.color = inSpotLightMap ? directLight.color * spotColor.rgb : directLight.color;
		#endif
		#undef SPOT_LIGHT_MAP_INDEX
		#if defined( USE_SHADOWMAP ) && ( UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS )
		spotLightShadow = spotLightShadows[ i ];
		directLight.color *= ( directLight.visible && receiveShadow ) ? getShadow( spotShadowMap[ i ], spotLightShadow.shadowMapSize, spotLightShadow.shadowIntensity, spotLightShadow.shadowBias, spotLightShadow.shadowRadius, vSpotLightCoord[ i ] ) : 1.0;
		#endif
		RE_Direct( directLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if ( NUM_DIR_LIGHTS > 0 ) && defined( RE_Direct )
	DirectionalLight directionalLight;
	#if defined( USE_SHADOWMAP ) && NUM_DIR_LIGHT_SHADOWS > 0
	DirectionalLightShadow directionalLightShadow;
	#endif
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_DIR_LIGHTS; i ++ ) {
		directionalLight = directionalLights[ i ];
		getDirectionalLightInfo( directionalLight, directLight );
		#if defined( USE_SHADOWMAP ) && ( UNROLLED_LOOP_INDEX < NUM_DIR_LIGHT_SHADOWS )
		directionalLightShadow = directionalLightShadows[ i ];
		directLight.color *= ( directLight.visible && receiveShadow ) ? getShadow( directionalShadowMap[ i ], directionalLightShadow.shadowMapSize, directionalLightShadow.shadowIntensity, directionalLightShadow.shadowBias, directionalLightShadow.shadowRadius, vDirectionalShadowCoord[ i ] ) : 1.0;
		#endif
		RE_Direct( directLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if ( NUM_RECT_AREA_LIGHTS > 0 ) && defined( RE_Direct_RectArea )
	RectAreaLight rectAreaLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_RECT_AREA_LIGHTS; i ++ ) {
		rectAreaLight = rectAreaLights[ i ];
		RE_Direct_RectArea( rectAreaLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if defined( RE_IndirectDiffuse )
	vec3 iblIrradiance = vec3( 0.0 );
	vec3 irradiance = getAmbientLightIrradiance( ambientLightColor );
	#if defined( USE_LIGHT_PROBES )
		irradiance += getLightProbeIrradiance( lightProbe, geometryNormal );
	#endif
	#if ( NUM_HEMI_LIGHTS > 0 )
		#pragma unroll_loop_start
		for ( int i = 0; i < NUM_HEMI_LIGHTS; i ++ ) {
			irradiance += getHemisphereLightIrradiance( hemisphereLights[ i ], geometryNormal );
		}
		#pragma unroll_loop_end
	#endif
#endif
#if defined( RE_IndirectSpecular )
	vec3 radiance = vec3( 0.0 );
	vec3 clearcoatRadiance = vec3( 0.0 );
#endif`,Gy=`#if defined( RE_IndirectDiffuse )
	#ifdef USE_LIGHTMAP
		vec4 lightMapTexel = texture2D( lightMap, vLightMapUv );
		vec3 lightMapIrradiance = lightMapTexel.rgb * lightMapIntensity;
		irradiance += lightMapIrradiance;
	#endif
	#if defined( USE_ENVMAP ) && defined( STANDARD ) && defined( ENVMAP_TYPE_CUBE_UV )
		iblIrradiance += getIBLIrradiance( geometryNormal );
	#endif
#endif
#if defined( USE_ENVMAP ) && defined( RE_IndirectSpecular )
	#ifdef USE_ANISOTROPY
		radiance += getIBLAnisotropyRadiance( geometryViewDir, geometryNormal, material.roughness, material.anisotropyB, material.anisotropy );
	#else
		radiance += getIBLRadiance( geometryViewDir, geometryNormal, material.roughness );
	#endif
	#ifdef USE_CLEARCOAT
		clearcoatRadiance += getIBLRadiance( geometryViewDir, geometryClearcoatNormal, material.clearcoatRoughness );
	#endif
#endif`,Vy=`#if defined( RE_IndirectDiffuse )
	RE_IndirectDiffuse( irradiance, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
#endif
#if defined( RE_IndirectSpecular )
	RE_IndirectSpecular( radiance, iblIrradiance, clearcoatRadiance, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
#endif`,Xy=`#if defined( USE_LOGDEPTHBUF )
	gl_FragDepth = vIsPerspective == 0.0 ? gl_FragCoord.z : log2( vFragDepth ) * logDepthBufFC * 0.5;
#endif`,ky=`#if defined( USE_LOGDEPTHBUF )
	uniform float logDepthBufFC;
	varying float vFragDepth;
	varying float vIsPerspective;
#endif`,Wy=`#ifdef USE_LOGDEPTHBUF
	varying float vFragDepth;
	varying float vIsPerspective;
#endif`,qy=`#ifdef USE_LOGDEPTHBUF
	vFragDepth = 1.0 + gl_Position.w;
	vIsPerspective = float( isPerspectiveMatrix( projectionMatrix ) );
#endif`,Yy=`#ifdef USE_MAP
	vec4 sampledDiffuseColor = texture2D( map, vMapUv );
	#ifdef DECODE_VIDEO_TEXTURE
		sampledDiffuseColor = sRGBTransferEOTF( sampledDiffuseColor );
	#endif
	diffuseColor *= sampledDiffuseColor;
#endif`,jy=`#ifdef USE_MAP
	uniform sampler2D map;
#endif`,Zy=`#if defined( USE_MAP ) || defined( USE_ALPHAMAP )
	#if defined( USE_POINTS_UV )
		vec2 uv = vUv;
	#else
		vec2 uv = ( uvTransform * vec3( gl_PointCoord.x, 1.0 - gl_PointCoord.y, 1 ) ).xy;
	#endif
#endif
#ifdef USE_MAP
	diffuseColor *= texture2D( map, uv );
#endif
#ifdef USE_ALPHAMAP
	diffuseColor.a *= texture2D( alphaMap, uv ).g;
#endif`,Ky=`#if defined( USE_POINTS_UV )
	varying vec2 vUv;
#else
	#if defined( USE_MAP ) || defined( USE_ALPHAMAP )
		uniform mat3 uvTransform;
	#endif
#endif
#ifdef USE_MAP
	uniform sampler2D map;
#endif
#ifdef USE_ALPHAMAP
	uniform sampler2D alphaMap;
#endif`,Qy=`float metalnessFactor = metalness;
#ifdef USE_METALNESSMAP
	vec4 texelMetalness = texture2D( metalnessMap, vMetalnessMapUv );
	metalnessFactor *= texelMetalness.b;
#endif`,Jy=`#ifdef USE_METALNESSMAP
	uniform sampler2D metalnessMap;
#endif`,$y=`#ifdef USE_INSTANCING_MORPH
	float morphTargetInfluences[ MORPHTARGETS_COUNT ];
	float morphTargetBaseInfluence = texelFetch( morphTexture, ivec2( 0, gl_InstanceID ), 0 ).r;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		morphTargetInfluences[i] =  texelFetch( morphTexture, ivec2( i + 1, gl_InstanceID ), 0 ).r;
	}
#endif`,tE=`#if defined( USE_MORPHCOLORS )
	vColor *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		#if defined( USE_COLOR_ALPHA )
			if ( morphTargetInfluences[ i ] != 0.0 ) vColor += getMorph( gl_VertexID, i, 2 ) * morphTargetInfluences[ i ];
		#elif defined( USE_COLOR )
			if ( morphTargetInfluences[ i ] != 0.0 ) vColor += getMorph( gl_VertexID, i, 2 ).rgb * morphTargetInfluences[ i ];
		#endif
	}
#endif`,eE=`#ifdef USE_MORPHNORMALS
	objectNormal *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		if ( morphTargetInfluences[ i ] != 0.0 ) objectNormal += getMorph( gl_VertexID, i, 1 ).xyz * morphTargetInfluences[ i ];
	}
#endif`,nE=`#ifdef USE_MORPHTARGETS
	#ifndef USE_INSTANCING_MORPH
		uniform float morphTargetBaseInfluence;
		uniform float morphTargetInfluences[ MORPHTARGETS_COUNT ];
	#endif
	uniform sampler2DArray morphTargetsTexture;
	uniform ivec2 morphTargetsTextureSize;
	vec4 getMorph( const in int vertexIndex, const in int morphTargetIndex, const in int offset ) {
		int texelIndex = vertexIndex * MORPHTARGETS_TEXTURE_STRIDE + offset;
		int y = texelIndex / morphTargetsTextureSize.x;
		int x = texelIndex - y * morphTargetsTextureSize.x;
		ivec3 morphUV = ivec3( x, y, morphTargetIndex );
		return texelFetch( morphTargetsTexture, morphUV, 0 );
	}
#endif`,iE=`#ifdef USE_MORPHTARGETS
	transformed *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		if ( morphTargetInfluences[ i ] != 0.0 ) transformed += getMorph( gl_VertexID, i, 0 ).xyz * morphTargetInfluences[ i ];
	}
#endif`,aE=`float faceDirection = gl_FrontFacing ? 1.0 : - 1.0;
#ifdef FLAT_SHADED
	vec3 fdx = dFdx( vViewPosition );
	vec3 fdy = dFdy( vViewPosition );
	vec3 normal = normalize( cross( fdx, fdy ) );
#else
	vec3 normal = normalize( vNormal );
	#ifdef DOUBLE_SIDED
		normal *= faceDirection;
	#endif
#endif
#if defined( USE_NORMALMAP_TANGENTSPACE ) || defined( USE_CLEARCOAT_NORMALMAP ) || defined( USE_ANISOTROPY )
	#ifdef USE_TANGENT
		mat3 tbn = mat3( normalize( vTangent ), normalize( vBitangent ), normal );
	#else
		mat3 tbn = getTangentFrame( - vViewPosition, normal,
		#if defined( USE_NORMALMAP )
			vNormalMapUv
		#elif defined( USE_CLEARCOAT_NORMALMAP )
			vClearcoatNormalMapUv
		#else
			vUv
		#endif
		);
	#endif
	#if defined( DOUBLE_SIDED ) && ! defined( FLAT_SHADED )
		tbn[0] *= faceDirection;
		tbn[1] *= faceDirection;
	#endif
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	#ifdef USE_TANGENT
		mat3 tbn2 = mat3( normalize( vTangent ), normalize( vBitangent ), normal );
	#else
		mat3 tbn2 = getTangentFrame( - vViewPosition, normal, vClearcoatNormalMapUv );
	#endif
	#if defined( DOUBLE_SIDED ) && ! defined( FLAT_SHADED )
		tbn2[0] *= faceDirection;
		tbn2[1] *= faceDirection;
	#endif
#endif
vec3 nonPerturbedNormal = normal;`,rE=`#ifdef USE_NORMALMAP_OBJECTSPACE
	normal = texture2D( normalMap, vNormalMapUv ).xyz * 2.0 - 1.0;
	#ifdef FLIP_SIDED
		normal = - normal;
	#endif
	#ifdef DOUBLE_SIDED
		normal = normal * faceDirection;
	#endif
	normal = normalize( normalMatrix * normal );
#elif defined( USE_NORMALMAP_TANGENTSPACE )
	vec3 mapN = texture2D( normalMap, vNormalMapUv ).xyz * 2.0 - 1.0;
	mapN.xy *= normalScale;
	normal = normalize( tbn * mapN );
#elif defined( USE_BUMPMAP )
	normal = perturbNormalArb( - vViewPosition, normal, dHdxy_fwd(), faceDirection );
#endif`,sE=`#ifndef FLAT_SHADED
	varying vec3 vNormal;
	#ifdef USE_TANGENT
		varying vec3 vTangent;
		varying vec3 vBitangent;
	#endif
#endif`,oE=`#ifndef FLAT_SHADED
	varying vec3 vNormal;
	#ifdef USE_TANGENT
		varying vec3 vTangent;
		varying vec3 vBitangent;
	#endif
#endif`,lE=`#ifndef FLAT_SHADED
	vNormal = normalize( transformedNormal );
	#ifdef USE_TANGENT
		vTangent = normalize( transformedTangent );
		vBitangent = normalize( cross( vNormal, vTangent ) * tangent.w );
	#endif
#endif`,uE=`#ifdef USE_NORMALMAP
	uniform sampler2D normalMap;
	uniform vec2 normalScale;
#endif
#ifdef USE_NORMALMAP_OBJECTSPACE
	uniform mat3 normalMatrix;
#endif
#if ! defined ( USE_TANGENT ) && ( defined ( USE_NORMALMAP_TANGENTSPACE ) || defined ( USE_CLEARCOAT_NORMALMAP ) || defined( USE_ANISOTROPY ) )
	mat3 getTangentFrame( vec3 eye_pos, vec3 surf_norm, vec2 uv ) {
		vec3 q0 = dFdx( eye_pos.xyz );
		vec3 q1 = dFdy( eye_pos.xyz );
		vec2 st0 = dFdx( uv.st );
		vec2 st1 = dFdy( uv.st );
		vec3 N = surf_norm;
		vec3 q1perp = cross( q1, N );
		vec3 q0perp = cross( N, q0 );
		vec3 T = q1perp * st0.x + q0perp * st1.x;
		vec3 B = q1perp * st0.y + q0perp * st1.y;
		float det = max( dot( T, T ), dot( B, B ) );
		float scale = ( det == 0.0 ) ? 0.0 : inversesqrt( det );
		return mat3( T * scale, B * scale, N );
	}
#endif`,cE=`#ifdef USE_CLEARCOAT
	vec3 clearcoatNormal = nonPerturbedNormal;
#endif`,fE=`#ifdef USE_CLEARCOAT_NORMALMAP
	vec3 clearcoatMapN = texture2D( clearcoatNormalMap, vClearcoatNormalMapUv ).xyz * 2.0 - 1.0;
	clearcoatMapN.xy *= clearcoatNormalScale;
	clearcoatNormal = normalize( tbn2 * clearcoatMapN );
#endif`,hE=`#ifdef USE_CLEARCOATMAP
	uniform sampler2D clearcoatMap;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	uniform sampler2D clearcoatNormalMap;
	uniform vec2 clearcoatNormalScale;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	uniform sampler2D clearcoatRoughnessMap;
#endif`,dE=`#ifdef USE_IRIDESCENCEMAP
	uniform sampler2D iridescenceMap;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	uniform sampler2D iridescenceThicknessMap;
#endif`,pE=`#ifdef OPAQUE
diffuseColor.a = 1.0;
#endif
#ifdef USE_TRANSMISSION
diffuseColor.a *= material.transmissionAlpha;
#endif
gl_FragColor = vec4( outgoingLight, diffuseColor.a );`,mE=`vec3 packNormalToRGB( const in vec3 normal ) {
	return normalize( normal ) * 0.5 + 0.5;
}
vec3 unpackRGBToNormal( const in vec3 rgb ) {
	return 2.0 * rgb.xyz - 1.0;
}
const float PackUpscale = 256. / 255.;const float UnpackDownscale = 255. / 256.;const float ShiftRight8 = 1. / 256.;
const float Inv255 = 1. / 255.;
const vec4 PackFactors = vec4( 1.0, 256.0, 256.0 * 256.0, 256.0 * 256.0 * 256.0 );
const vec2 UnpackFactors2 = vec2( UnpackDownscale, 1.0 / PackFactors.g );
const vec3 UnpackFactors3 = vec3( UnpackDownscale / PackFactors.rg, 1.0 / PackFactors.b );
const vec4 UnpackFactors4 = vec4( UnpackDownscale / PackFactors.rgb, 1.0 / PackFactors.a );
vec4 packDepthToRGBA( const in float v ) {
	if( v <= 0.0 )
		return vec4( 0., 0., 0., 0. );
	if( v >= 1.0 )
		return vec4( 1., 1., 1., 1. );
	float vuf;
	float af = modf( v * PackFactors.a, vuf );
	float bf = modf( vuf * ShiftRight8, vuf );
	float gf = modf( vuf * ShiftRight8, vuf );
	return vec4( vuf * Inv255, gf * PackUpscale, bf * PackUpscale, af );
}
vec3 packDepthToRGB( const in float v ) {
	if( v <= 0.0 )
		return vec3( 0., 0., 0. );
	if( v >= 1.0 )
		return vec3( 1., 1., 1. );
	float vuf;
	float bf = modf( v * PackFactors.b, vuf );
	float gf = modf( vuf * ShiftRight8, vuf );
	return vec3( vuf * Inv255, gf * PackUpscale, bf );
}
vec2 packDepthToRG( const in float v ) {
	if( v <= 0.0 )
		return vec2( 0., 0. );
	if( v >= 1.0 )
		return vec2( 1., 1. );
	float vuf;
	float gf = modf( v * 256., vuf );
	return vec2( vuf * Inv255, gf );
}
float unpackRGBAToDepth( const in vec4 v ) {
	return dot( v, UnpackFactors4 );
}
float unpackRGBToDepth( const in vec3 v ) {
	return dot( v, UnpackFactors3 );
}
float unpackRGToDepth( const in vec2 v ) {
	return v.r * UnpackFactors2.r + v.g * UnpackFactors2.g;
}
vec4 pack2HalfToRGBA( const in vec2 v ) {
	vec4 r = vec4( v.x, fract( v.x * 255.0 ), v.y, fract( v.y * 255.0 ) );
	return vec4( r.x - r.y / 255.0, r.y, r.z - r.w / 255.0, r.w );
}
vec2 unpackRGBATo2Half( const in vec4 v ) {
	return vec2( v.x + ( v.y / 255.0 ), v.z + ( v.w / 255.0 ) );
}
float viewZToOrthographicDepth( const in float viewZ, const in float near, const in float far ) {
	return ( viewZ + near ) / ( near - far );
}
float orthographicDepthToViewZ( const in float depth, const in float near, const in float far ) {
	return depth * ( near - far ) - near;
}
float viewZToPerspectiveDepth( const in float viewZ, const in float near, const in float far ) {
	return ( ( near + viewZ ) * far ) / ( ( far - near ) * viewZ );
}
float perspectiveDepthToViewZ( const in float depth, const in float near, const in float far ) {
	return ( near * far ) / ( ( far - near ) * depth - far );
}`,gE=`#ifdef PREMULTIPLIED_ALPHA
	gl_FragColor.rgb *= gl_FragColor.a;
#endif`,_E=`vec4 mvPosition = vec4( transformed, 1.0 );
#ifdef USE_BATCHING
	mvPosition = batchingMatrix * mvPosition;
#endif
#ifdef USE_INSTANCING
	mvPosition = instanceMatrix * mvPosition;
#endif
mvPosition = modelViewMatrix * mvPosition;
gl_Position = projectionMatrix * mvPosition;`,vE=`#ifdef DITHERING
	gl_FragColor.rgb = dithering( gl_FragColor.rgb );
#endif`,SE=`#ifdef DITHERING
	vec3 dithering( vec3 color ) {
		float grid_position = rand( gl_FragCoord.xy );
		vec3 dither_shift_RGB = vec3( 0.25 / 255.0, -0.25 / 255.0, 0.25 / 255.0 );
		dither_shift_RGB = mix( 2.0 * dither_shift_RGB, -2.0 * dither_shift_RGB, grid_position );
		return color + dither_shift_RGB;
	}
#endif`,xE=`float roughnessFactor = roughness;
#ifdef USE_ROUGHNESSMAP
	vec4 texelRoughness = texture2D( roughnessMap, vRoughnessMapUv );
	roughnessFactor *= texelRoughness.g;
#endif`,ME=`#ifdef USE_ROUGHNESSMAP
	uniform sampler2D roughnessMap;
#endif`,yE=`#if NUM_SPOT_LIGHT_COORDS > 0
	varying vec4 vSpotLightCoord[ NUM_SPOT_LIGHT_COORDS ];
#endif
#if NUM_SPOT_LIGHT_MAPS > 0
	uniform sampler2D spotLightMap[ NUM_SPOT_LIGHT_MAPS ];
#endif
#ifdef USE_SHADOWMAP
	#if NUM_DIR_LIGHT_SHADOWS > 0
		uniform sampler2D directionalShadowMap[ NUM_DIR_LIGHT_SHADOWS ];
		varying vec4 vDirectionalShadowCoord[ NUM_DIR_LIGHT_SHADOWS ];
		struct DirectionalLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform DirectionalLightShadow directionalLightShadows[ NUM_DIR_LIGHT_SHADOWS ];
	#endif
	#if NUM_SPOT_LIGHT_SHADOWS > 0
		uniform sampler2D spotShadowMap[ NUM_SPOT_LIGHT_SHADOWS ];
		struct SpotLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform SpotLightShadow spotLightShadows[ NUM_SPOT_LIGHT_SHADOWS ];
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
		uniform sampler2D pointShadowMap[ NUM_POINT_LIGHT_SHADOWS ];
		varying vec4 vPointShadowCoord[ NUM_POINT_LIGHT_SHADOWS ];
		struct PointLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
			float shadowCameraNear;
			float shadowCameraFar;
		};
		uniform PointLightShadow pointLightShadows[ NUM_POINT_LIGHT_SHADOWS ];
	#endif
	float texture2DCompare( sampler2D depths, vec2 uv, float compare ) {
		return step( compare, unpackRGBAToDepth( texture2D( depths, uv ) ) );
	}
	vec2 texture2DDistribution( sampler2D shadow, vec2 uv ) {
		return unpackRGBATo2Half( texture2D( shadow, uv ) );
	}
	float VSMShadow (sampler2D shadow, vec2 uv, float compare ){
		float occlusion = 1.0;
		vec2 distribution = texture2DDistribution( shadow, uv );
		float hard_shadow = step( compare , distribution.x );
		if (hard_shadow != 1.0 ) {
			float distance = compare - distribution.x ;
			float variance = max( 0.00000, distribution.y * distribution.y );
			float softness_probability = variance / (variance + distance * distance );			softness_probability = clamp( ( softness_probability - 0.3 ) / ( 0.95 - 0.3 ), 0.0, 1.0 );			occlusion = clamp( max( hard_shadow, softness_probability ), 0.0, 1.0 );
		}
		return occlusion;
	}
	float getShadow( sampler2D shadowMap, vec2 shadowMapSize, float shadowIntensity, float shadowBias, float shadowRadius, vec4 shadowCoord ) {
		float shadow = 1.0;
		shadowCoord.xyz /= shadowCoord.w;
		shadowCoord.z += shadowBias;
		bool inFrustum = shadowCoord.x >= 0.0 && shadowCoord.x <= 1.0 && shadowCoord.y >= 0.0 && shadowCoord.y <= 1.0;
		bool frustumTest = inFrustum && shadowCoord.z <= 1.0;
		if ( frustumTest ) {
		#if defined( SHADOWMAP_TYPE_PCF )
			vec2 texelSize = vec2( 1.0 ) / shadowMapSize;
			float dx0 = - texelSize.x * shadowRadius;
			float dy0 = - texelSize.y * shadowRadius;
			float dx1 = + texelSize.x * shadowRadius;
			float dy1 = + texelSize.y * shadowRadius;
			float dx2 = dx0 / 2.0;
			float dy2 = dy0 / 2.0;
			float dx3 = dx1 / 2.0;
			float dy3 = dy1 / 2.0;
			shadow = (
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx0, dy0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( 0.0, dy0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx1, dy0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx2, dy2 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( 0.0, dy2 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx3, dy2 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx0, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx2, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy, shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx3, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx1, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx2, dy3 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( 0.0, dy3 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx3, dy3 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx0, dy1 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( 0.0, dy1 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx1, dy1 ), shadowCoord.z )
			) * ( 1.0 / 17.0 );
		#elif defined( SHADOWMAP_TYPE_PCF_SOFT )
			vec2 texelSize = vec2( 1.0 ) / shadowMapSize;
			float dx = texelSize.x;
			float dy = texelSize.y;
			vec2 uv = shadowCoord.xy;
			vec2 f = fract( uv * shadowMapSize + 0.5 );
			uv -= f * texelSize;
			shadow = (
				texture2DCompare( shadowMap, uv, shadowCoord.z ) +
				texture2DCompare( shadowMap, uv + vec2( dx, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, uv + vec2( 0.0, dy ), shadowCoord.z ) +
				texture2DCompare( shadowMap, uv + texelSize, shadowCoord.z ) +
				mix( texture2DCompare( shadowMap, uv + vec2( -dx, 0.0 ), shadowCoord.z ),
					 texture2DCompare( shadowMap, uv + vec2( 2.0 * dx, 0.0 ), shadowCoord.z ),
					 f.x ) +
				mix( texture2DCompare( shadowMap, uv + vec2( -dx, dy ), shadowCoord.z ),
					 texture2DCompare( shadowMap, uv + vec2( 2.0 * dx, dy ), shadowCoord.z ),
					 f.x ) +
				mix( texture2DCompare( shadowMap, uv + vec2( 0.0, -dy ), shadowCoord.z ),
					 texture2DCompare( shadowMap, uv + vec2( 0.0, 2.0 * dy ), shadowCoord.z ),
					 f.y ) +
				mix( texture2DCompare( shadowMap, uv + vec2( dx, -dy ), shadowCoord.z ),
					 texture2DCompare( shadowMap, uv + vec2( dx, 2.0 * dy ), shadowCoord.z ),
					 f.y ) +
				mix( mix( texture2DCompare( shadowMap, uv + vec2( -dx, -dy ), shadowCoord.z ),
						  texture2DCompare( shadowMap, uv + vec2( 2.0 * dx, -dy ), shadowCoord.z ),
						  f.x ),
					 mix( texture2DCompare( shadowMap, uv + vec2( -dx, 2.0 * dy ), shadowCoord.z ),
						  texture2DCompare( shadowMap, uv + vec2( 2.0 * dx, 2.0 * dy ), shadowCoord.z ),
						  f.x ),
					 f.y )
			) * ( 1.0 / 9.0 );
		#elif defined( SHADOWMAP_TYPE_VSM )
			shadow = VSMShadow( shadowMap, shadowCoord.xy, shadowCoord.z );
		#else
			shadow = texture2DCompare( shadowMap, shadowCoord.xy, shadowCoord.z );
		#endif
		}
		return mix( 1.0, shadow, shadowIntensity );
	}
	vec2 cubeToUV( vec3 v, float texelSizeY ) {
		vec3 absV = abs( v );
		float scaleToCube = 1.0 / max( absV.x, max( absV.y, absV.z ) );
		absV *= scaleToCube;
		v *= scaleToCube * ( 1.0 - 2.0 * texelSizeY );
		vec2 planar = v.xy;
		float almostATexel = 1.5 * texelSizeY;
		float almostOne = 1.0 - almostATexel;
		if ( absV.z >= almostOne ) {
			if ( v.z > 0.0 )
				planar.x = 4.0 - v.x;
		} else if ( absV.x >= almostOne ) {
			float signX = sign( v.x );
			planar.x = v.z * signX + 2.0 * signX;
		} else if ( absV.y >= almostOne ) {
			float signY = sign( v.y );
			planar.x = v.x + 2.0 * signY + 2.0;
			planar.y = v.z * signY - 2.0;
		}
		return vec2( 0.125, 0.25 ) * planar + vec2( 0.375, 0.75 );
	}
	float getPointShadow( sampler2D shadowMap, vec2 shadowMapSize, float shadowIntensity, float shadowBias, float shadowRadius, vec4 shadowCoord, float shadowCameraNear, float shadowCameraFar ) {
		float shadow = 1.0;
		vec3 lightToPosition = shadowCoord.xyz;
		
		float lightToPositionLength = length( lightToPosition );
		if ( lightToPositionLength - shadowCameraFar <= 0.0 && lightToPositionLength - shadowCameraNear >= 0.0 ) {
			float dp = ( lightToPositionLength - shadowCameraNear ) / ( shadowCameraFar - shadowCameraNear );			dp += shadowBias;
			vec3 bd3D = normalize( lightToPosition );
			vec2 texelSize = vec2( 1.0 ) / ( shadowMapSize * vec2( 4.0, 2.0 ) );
			#if defined( SHADOWMAP_TYPE_PCF ) || defined( SHADOWMAP_TYPE_PCF_SOFT ) || defined( SHADOWMAP_TYPE_VSM )
				vec2 offset = vec2( - 1, 1 ) * shadowRadius * texelSize.y;
				shadow = (
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.xyy, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.yyy, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.xyx, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.yyx, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.xxy, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.yxy, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.xxx, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.yxx, texelSize.y ), dp )
				) * ( 1.0 / 9.0 );
			#else
				shadow = texture2DCompare( shadowMap, cubeToUV( bd3D, texelSize.y ), dp );
			#endif
		}
		return mix( 1.0, shadow, shadowIntensity );
	}
#endif`,EE=`#if NUM_SPOT_LIGHT_COORDS > 0
	uniform mat4 spotLightMatrix[ NUM_SPOT_LIGHT_COORDS ];
	varying vec4 vSpotLightCoord[ NUM_SPOT_LIGHT_COORDS ];
#endif
#ifdef USE_SHADOWMAP
	#if NUM_DIR_LIGHT_SHADOWS > 0
		uniform mat4 directionalShadowMatrix[ NUM_DIR_LIGHT_SHADOWS ];
		varying vec4 vDirectionalShadowCoord[ NUM_DIR_LIGHT_SHADOWS ];
		struct DirectionalLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform DirectionalLightShadow directionalLightShadows[ NUM_DIR_LIGHT_SHADOWS ];
	#endif
	#if NUM_SPOT_LIGHT_SHADOWS > 0
		struct SpotLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform SpotLightShadow spotLightShadows[ NUM_SPOT_LIGHT_SHADOWS ];
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
		uniform mat4 pointShadowMatrix[ NUM_POINT_LIGHT_SHADOWS ];
		varying vec4 vPointShadowCoord[ NUM_POINT_LIGHT_SHADOWS ];
		struct PointLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
			float shadowCameraNear;
			float shadowCameraFar;
		};
		uniform PointLightShadow pointLightShadows[ NUM_POINT_LIGHT_SHADOWS ];
	#endif
#endif`,TE=`#if ( defined( USE_SHADOWMAP ) && ( NUM_DIR_LIGHT_SHADOWS > 0 || NUM_POINT_LIGHT_SHADOWS > 0 ) ) || ( NUM_SPOT_LIGHT_COORDS > 0 )
	vec3 shadowWorldNormal = inverseTransformDirection( transformedNormal, viewMatrix );
	vec4 shadowWorldPosition;
#endif
#if defined( USE_SHADOWMAP )
	#if NUM_DIR_LIGHT_SHADOWS > 0
		#pragma unroll_loop_start
		for ( int i = 0; i < NUM_DIR_LIGHT_SHADOWS; i ++ ) {
			shadowWorldPosition = worldPosition + vec4( shadowWorldNormal * directionalLightShadows[ i ].shadowNormalBias, 0 );
			vDirectionalShadowCoord[ i ] = directionalShadowMatrix[ i ] * shadowWorldPosition;
		}
		#pragma unroll_loop_end
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
		#pragma unroll_loop_start
		for ( int i = 0; i < NUM_POINT_LIGHT_SHADOWS; i ++ ) {
			shadowWorldPosition = worldPosition + vec4( shadowWorldNormal * pointLightShadows[ i ].shadowNormalBias, 0 );
			vPointShadowCoord[ i ] = pointShadowMatrix[ i ] * shadowWorldPosition;
		}
		#pragma unroll_loop_end
	#endif
#endif
#if NUM_SPOT_LIGHT_COORDS > 0
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_SPOT_LIGHT_COORDS; i ++ ) {
		shadowWorldPosition = worldPosition;
		#if ( defined( USE_SHADOWMAP ) && UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS )
			shadowWorldPosition.xyz += shadowWorldNormal * spotLightShadows[ i ].shadowNormalBias;
		#endif
		vSpotLightCoord[ i ] = spotLightMatrix[ i ] * shadowWorldPosition;
	}
	#pragma unroll_loop_end
#endif`,bE=`float getShadowMask() {
	float shadow = 1.0;
	#ifdef USE_SHADOWMAP
	#if NUM_DIR_LIGHT_SHADOWS > 0
	DirectionalLightShadow directionalLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_DIR_LIGHT_SHADOWS; i ++ ) {
		directionalLight = directionalLightShadows[ i ];
		shadow *= receiveShadow ? getShadow( directionalShadowMap[ i ], directionalLight.shadowMapSize, directionalLight.shadowIntensity, directionalLight.shadowBias, directionalLight.shadowRadius, vDirectionalShadowCoord[ i ] ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#if NUM_SPOT_LIGHT_SHADOWS > 0
	SpotLightShadow spotLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_SPOT_LIGHT_SHADOWS; i ++ ) {
		spotLight = spotLightShadows[ i ];
		shadow *= receiveShadow ? getShadow( spotShadowMap[ i ], spotLight.shadowMapSize, spotLight.shadowIntensity, spotLight.shadowBias, spotLight.shadowRadius, vSpotLightCoord[ i ] ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
	PointLightShadow pointLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_POINT_LIGHT_SHADOWS; i ++ ) {
		pointLight = pointLightShadows[ i ];
		shadow *= receiveShadow ? getPointShadow( pointShadowMap[ i ], pointLight.shadowMapSize, pointLight.shadowIntensity, pointLight.shadowBias, pointLight.shadowRadius, vPointShadowCoord[ i ], pointLight.shadowCameraNear, pointLight.shadowCameraFar ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#endif
	return shadow;
}`,AE=`#ifdef USE_SKINNING
	mat4 boneMatX = getBoneMatrix( skinIndex.x );
	mat4 boneMatY = getBoneMatrix( skinIndex.y );
	mat4 boneMatZ = getBoneMatrix( skinIndex.z );
	mat4 boneMatW = getBoneMatrix( skinIndex.w );
#endif`,RE=`#ifdef USE_SKINNING
	uniform mat4 bindMatrix;
	uniform mat4 bindMatrixInverse;
	uniform highp sampler2D boneTexture;
	mat4 getBoneMatrix( const in float i ) {
		int size = textureSize( boneTexture, 0 ).x;
		int j = int( i ) * 4;
		int x = j % size;
		int y = j / size;
		vec4 v1 = texelFetch( boneTexture, ivec2( x, y ), 0 );
		vec4 v2 = texelFetch( boneTexture, ivec2( x + 1, y ), 0 );
		vec4 v3 = texelFetch( boneTexture, ivec2( x + 2, y ), 0 );
		vec4 v4 = texelFetch( boneTexture, ivec2( x + 3, y ), 0 );
		return mat4( v1, v2, v3, v4 );
	}
#endif`,CE=`#ifdef USE_SKINNING
	vec4 skinVertex = bindMatrix * vec4( transformed, 1.0 );
	vec4 skinned = vec4( 0.0 );
	skinned += boneMatX * skinVertex * skinWeight.x;
	skinned += boneMatY * skinVertex * skinWeight.y;
	skinned += boneMatZ * skinVertex * skinWeight.z;
	skinned += boneMatW * skinVertex * skinWeight.w;
	transformed = ( bindMatrixInverse * skinned ).xyz;
#endif`,wE=`#ifdef USE_SKINNING
	mat4 skinMatrix = mat4( 0.0 );
	skinMatrix += skinWeight.x * boneMatX;
	skinMatrix += skinWeight.y * boneMatY;
	skinMatrix += skinWeight.z * boneMatZ;
	skinMatrix += skinWeight.w * boneMatW;
	skinMatrix = bindMatrixInverse * skinMatrix * bindMatrix;
	objectNormal = vec4( skinMatrix * vec4( objectNormal, 0.0 ) ).xyz;
	#ifdef USE_TANGENT
		objectTangent = vec4( skinMatrix * vec4( objectTangent, 0.0 ) ).xyz;
	#endif
#endif`,DE=`float specularStrength;
#ifdef USE_SPECULARMAP
	vec4 texelSpecular = texture2D( specularMap, vSpecularMapUv );
	specularStrength = texelSpecular.r;
#else
	specularStrength = 1.0;
#endif`,UE=`#ifdef USE_SPECULARMAP
	uniform sampler2D specularMap;
#endif`,LE=`#if defined( TONE_MAPPING )
	gl_FragColor.rgb = toneMapping( gl_FragColor.rgb );
#endif`,NE=`#ifndef saturate
#define saturate( a ) clamp( a, 0.0, 1.0 )
#endif
uniform float toneMappingExposure;
vec3 LinearToneMapping( vec3 color ) {
	return saturate( toneMappingExposure * color );
}
vec3 ReinhardToneMapping( vec3 color ) {
	color *= toneMappingExposure;
	return saturate( color / ( vec3( 1.0 ) + color ) );
}
vec3 CineonToneMapping( vec3 color ) {
	color *= toneMappingExposure;
	color = max( vec3( 0.0 ), color - 0.004 );
	return pow( ( color * ( 6.2 * color + 0.5 ) ) / ( color * ( 6.2 * color + 1.7 ) + 0.06 ), vec3( 2.2 ) );
}
vec3 RRTAndODTFit( vec3 v ) {
	vec3 a = v * ( v + 0.0245786 ) - 0.000090537;
	vec3 b = v * ( 0.983729 * v + 0.4329510 ) + 0.238081;
	return a / b;
}
vec3 ACESFilmicToneMapping( vec3 color ) {
	const mat3 ACESInputMat = mat3(
		vec3( 0.59719, 0.07600, 0.02840 ),		vec3( 0.35458, 0.90834, 0.13383 ),
		vec3( 0.04823, 0.01566, 0.83777 )
	);
	const mat3 ACESOutputMat = mat3(
		vec3(  1.60475, -0.10208, -0.00327 ),		vec3( -0.53108,  1.10813, -0.07276 ),
		vec3( -0.07367, -0.00605,  1.07602 )
	);
	color *= toneMappingExposure / 0.6;
	color = ACESInputMat * color;
	color = RRTAndODTFit( color );
	color = ACESOutputMat * color;
	return saturate( color );
}
const mat3 LINEAR_REC2020_TO_LINEAR_SRGB = mat3(
	vec3( 1.6605, - 0.1246, - 0.0182 ),
	vec3( - 0.5876, 1.1329, - 0.1006 ),
	vec3( - 0.0728, - 0.0083, 1.1187 )
);
const mat3 LINEAR_SRGB_TO_LINEAR_REC2020 = mat3(
	vec3( 0.6274, 0.0691, 0.0164 ),
	vec3( 0.3293, 0.9195, 0.0880 ),
	vec3( 0.0433, 0.0113, 0.8956 )
);
vec3 agxDefaultContrastApprox( vec3 x ) {
	vec3 x2 = x * x;
	vec3 x4 = x2 * x2;
	return + 15.5 * x4 * x2
		- 40.14 * x4 * x
		+ 31.96 * x4
		- 6.868 * x2 * x
		+ 0.4298 * x2
		+ 0.1191 * x
		- 0.00232;
}
vec3 AgXToneMapping( vec3 color ) {
	const mat3 AgXInsetMatrix = mat3(
		vec3( 0.856627153315983, 0.137318972929847, 0.11189821299995 ),
		vec3( 0.0951212405381588, 0.761241990602591, 0.0767994186031903 ),
		vec3( 0.0482516061458583, 0.101439036467562, 0.811302368396859 )
	);
	const mat3 AgXOutsetMatrix = mat3(
		vec3( 1.1271005818144368, - 0.1413297634984383, - 0.14132976349843826 ),
		vec3( - 0.11060664309660323, 1.157823702216272, - 0.11060664309660294 ),
		vec3( - 0.016493938717834573, - 0.016493938717834257, 1.2519364065950405 )
	);
	const float AgxMinEv = - 12.47393;	const float AgxMaxEv = 4.026069;
	color *= toneMappingExposure;
	color = LINEAR_SRGB_TO_LINEAR_REC2020 * color;
	color = AgXInsetMatrix * color;
	color = max( color, 1e-10 );	color = log2( color );
	color = ( color - AgxMinEv ) / ( AgxMaxEv - AgxMinEv );
	color = clamp( color, 0.0, 1.0 );
	color = agxDefaultContrastApprox( color );
	color = AgXOutsetMatrix * color;
	color = pow( max( vec3( 0.0 ), color ), vec3( 2.2 ) );
	color = LINEAR_REC2020_TO_LINEAR_SRGB * color;
	color = clamp( color, 0.0, 1.0 );
	return color;
}
vec3 NeutralToneMapping( vec3 color ) {
	const float StartCompression = 0.8 - 0.04;
	const float Desaturation = 0.15;
	color *= toneMappingExposure;
	float x = min( color.r, min( color.g, color.b ) );
	float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
	color -= offset;
	float peak = max( color.r, max( color.g, color.b ) );
	if ( peak < StartCompression ) return color;
	float d = 1. - StartCompression;
	float newPeak = 1. - d * d / ( peak + d - StartCompression );
	color *= newPeak / peak;
	float g = 1. - 1. / ( Desaturation * ( peak - newPeak ) + 1. );
	return mix( color, vec3( newPeak ), g );
}
vec3 CustomToneMapping( vec3 color ) { return color; }`,OE=`#ifdef USE_TRANSMISSION
	material.transmission = transmission;
	material.transmissionAlpha = 1.0;
	material.thickness = thickness;
	material.attenuationDistance = attenuationDistance;
	material.attenuationColor = attenuationColor;
	#ifdef USE_TRANSMISSIONMAP
		material.transmission *= texture2D( transmissionMap, vTransmissionMapUv ).r;
	#endif
	#ifdef USE_THICKNESSMAP
		material.thickness *= texture2D( thicknessMap, vThicknessMapUv ).g;
	#endif
	vec3 pos = vWorldPosition;
	vec3 v = normalize( cameraPosition - pos );
	vec3 n = inverseTransformDirection( normal, viewMatrix );
	vec4 transmitted = getIBLVolumeRefraction(
		n, v, material.roughness, material.diffuseColor, material.specularColor, material.specularF90,
		pos, modelMatrix, viewMatrix, projectionMatrix, material.dispersion, material.ior, material.thickness,
		material.attenuationColor, material.attenuationDistance );
	material.transmissionAlpha = mix( material.transmissionAlpha, transmitted.a, material.transmission );
	totalDiffuse = mix( totalDiffuse, transmitted.rgb, material.transmission );
#endif`,zE=`#ifdef USE_TRANSMISSION
	uniform float transmission;
	uniform float thickness;
	uniform float attenuationDistance;
	uniform vec3 attenuationColor;
	#ifdef USE_TRANSMISSIONMAP
		uniform sampler2D transmissionMap;
	#endif
	#ifdef USE_THICKNESSMAP
		uniform sampler2D thicknessMap;
	#endif
	uniform vec2 transmissionSamplerSize;
	uniform sampler2D transmissionSamplerMap;
	uniform mat4 modelMatrix;
	uniform mat4 projectionMatrix;
	varying vec3 vWorldPosition;
	float w0( float a ) {
		return ( 1.0 / 6.0 ) * ( a * ( a * ( - a + 3.0 ) - 3.0 ) + 1.0 );
	}
	float w1( float a ) {
		return ( 1.0 / 6.0 ) * ( a *  a * ( 3.0 * a - 6.0 ) + 4.0 );
	}
	float w2( float a ){
		return ( 1.0 / 6.0 ) * ( a * ( a * ( - 3.0 * a + 3.0 ) + 3.0 ) + 1.0 );
	}
	float w3( float a ) {
		return ( 1.0 / 6.0 ) * ( a * a * a );
	}
	float g0( float a ) {
		return w0( a ) + w1( a );
	}
	float g1( float a ) {
		return w2( a ) + w3( a );
	}
	float h0( float a ) {
		return - 1.0 + w1( a ) / ( w0( a ) + w1( a ) );
	}
	float h1( float a ) {
		return 1.0 + w3( a ) / ( w2( a ) + w3( a ) );
	}
	vec4 bicubic( sampler2D tex, vec2 uv, vec4 texelSize, float lod ) {
		uv = uv * texelSize.zw + 0.5;
		vec2 iuv = floor( uv );
		vec2 fuv = fract( uv );
		float g0x = g0( fuv.x );
		float g1x = g1( fuv.x );
		float h0x = h0( fuv.x );
		float h1x = h1( fuv.x );
		float h0y = h0( fuv.y );
		float h1y = h1( fuv.y );
		vec2 p0 = ( vec2( iuv.x + h0x, iuv.y + h0y ) - 0.5 ) * texelSize.xy;
		vec2 p1 = ( vec2( iuv.x + h1x, iuv.y + h0y ) - 0.5 ) * texelSize.xy;
		vec2 p2 = ( vec2( iuv.x + h0x, iuv.y + h1y ) - 0.5 ) * texelSize.xy;
		vec2 p3 = ( vec2( iuv.x + h1x, iuv.y + h1y ) - 0.5 ) * texelSize.xy;
		return g0( fuv.y ) * ( g0x * textureLod( tex, p0, lod ) + g1x * textureLod( tex, p1, lod ) ) +
			g1( fuv.y ) * ( g0x * textureLod( tex, p2, lod ) + g1x * textureLod( tex, p3, lod ) );
	}
	vec4 textureBicubic( sampler2D sampler, vec2 uv, float lod ) {
		vec2 fLodSize = vec2( textureSize( sampler, int( lod ) ) );
		vec2 cLodSize = vec2( textureSize( sampler, int( lod + 1.0 ) ) );
		vec2 fLodSizeInv = 1.0 / fLodSize;
		vec2 cLodSizeInv = 1.0 / cLodSize;
		vec4 fSample = bicubic( sampler, uv, vec4( fLodSizeInv, fLodSize ), floor( lod ) );
		vec4 cSample = bicubic( sampler, uv, vec4( cLodSizeInv, cLodSize ), ceil( lod ) );
		return mix( fSample, cSample, fract( lod ) );
	}
	vec3 getVolumeTransmissionRay( const in vec3 n, const in vec3 v, const in float thickness, const in float ior, const in mat4 modelMatrix ) {
		vec3 refractionVector = refract( - v, normalize( n ), 1.0 / ior );
		vec3 modelScale;
		modelScale.x = length( vec3( modelMatrix[ 0 ].xyz ) );
		modelScale.y = length( vec3( modelMatrix[ 1 ].xyz ) );
		modelScale.z = length( vec3( modelMatrix[ 2 ].xyz ) );
		return normalize( refractionVector ) * thickness * modelScale;
	}
	float applyIorToRoughness( const in float roughness, const in float ior ) {
		return roughness * clamp( ior * 2.0 - 2.0, 0.0, 1.0 );
	}
	vec4 getTransmissionSample( const in vec2 fragCoord, const in float roughness, const in float ior ) {
		float lod = log2( transmissionSamplerSize.x ) * applyIorToRoughness( roughness, ior );
		return textureBicubic( transmissionSamplerMap, fragCoord.xy, lod );
	}
	vec3 volumeAttenuation( const in float transmissionDistance, const in vec3 attenuationColor, const in float attenuationDistance ) {
		if ( isinf( attenuationDistance ) ) {
			return vec3( 1.0 );
		} else {
			vec3 attenuationCoefficient = -log( attenuationColor ) / attenuationDistance;
			vec3 transmittance = exp( - attenuationCoefficient * transmissionDistance );			return transmittance;
		}
	}
	vec4 getIBLVolumeRefraction( const in vec3 n, const in vec3 v, const in float roughness, const in vec3 diffuseColor,
		const in vec3 specularColor, const in float specularF90, const in vec3 position, const in mat4 modelMatrix,
		const in mat4 viewMatrix, const in mat4 projMatrix, const in float dispersion, const in float ior, const in float thickness,
		const in vec3 attenuationColor, const in float attenuationDistance ) {
		vec4 transmittedLight;
		vec3 transmittance;
		#ifdef USE_DISPERSION
			float halfSpread = ( ior - 1.0 ) * 0.025 * dispersion;
			vec3 iors = vec3( ior - halfSpread, ior, ior + halfSpread );
			for ( int i = 0; i < 3; i ++ ) {
				vec3 transmissionRay = getVolumeTransmissionRay( n, v, thickness, iors[ i ], modelMatrix );
				vec3 refractedRayExit = position + transmissionRay;
				vec4 ndcPos = projMatrix * viewMatrix * vec4( refractedRayExit, 1.0 );
				vec2 refractionCoords = ndcPos.xy / ndcPos.w;
				refractionCoords += 1.0;
				refractionCoords /= 2.0;
				vec4 transmissionSample = getTransmissionSample( refractionCoords, roughness, iors[ i ] );
				transmittedLight[ i ] = transmissionSample[ i ];
				transmittedLight.a += transmissionSample.a;
				transmittance[ i ] = diffuseColor[ i ] * volumeAttenuation( length( transmissionRay ), attenuationColor, attenuationDistance )[ i ];
			}
			transmittedLight.a /= 3.0;
		#else
			vec3 transmissionRay = getVolumeTransmissionRay( n, v, thickness, ior, modelMatrix );
			vec3 refractedRayExit = position + transmissionRay;
			vec4 ndcPos = projMatrix * viewMatrix * vec4( refractedRayExit, 1.0 );
			vec2 refractionCoords = ndcPos.xy / ndcPos.w;
			refractionCoords += 1.0;
			refractionCoords /= 2.0;
			transmittedLight = getTransmissionSample( refractionCoords, roughness, ior );
			transmittance = diffuseColor * volumeAttenuation( length( transmissionRay ), attenuationColor, attenuationDistance );
		#endif
		vec3 attenuatedColor = transmittance * transmittedLight.rgb;
		vec3 F = EnvironmentBRDF( n, v, specularColor, specularF90, roughness );
		float transmittanceFactor = ( transmittance.r + transmittance.g + transmittance.b ) / 3.0;
		return vec4( ( 1.0 - F ) * attenuatedColor, 1.0 - ( 1.0 - transmittedLight.a ) * transmittanceFactor );
	}
#endif`,PE=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
	varying vec2 vUv;
#endif
#ifdef USE_MAP
	varying vec2 vMapUv;
#endif
#ifdef USE_ALPHAMAP
	varying vec2 vAlphaMapUv;
#endif
#ifdef USE_LIGHTMAP
	varying vec2 vLightMapUv;
#endif
#ifdef USE_AOMAP
	varying vec2 vAoMapUv;
#endif
#ifdef USE_BUMPMAP
	varying vec2 vBumpMapUv;
#endif
#ifdef USE_NORMALMAP
	varying vec2 vNormalMapUv;
#endif
#ifdef USE_EMISSIVEMAP
	varying vec2 vEmissiveMapUv;
#endif
#ifdef USE_METALNESSMAP
	varying vec2 vMetalnessMapUv;
#endif
#ifdef USE_ROUGHNESSMAP
	varying vec2 vRoughnessMapUv;
#endif
#ifdef USE_ANISOTROPYMAP
	varying vec2 vAnisotropyMapUv;
#endif
#ifdef USE_CLEARCOATMAP
	varying vec2 vClearcoatMapUv;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	varying vec2 vClearcoatNormalMapUv;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	varying vec2 vClearcoatRoughnessMapUv;
#endif
#ifdef USE_IRIDESCENCEMAP
	varying vec2 vIridescenceMapUv;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	varying vec2 vIridescenceThicknessMapUv;
#endif
#ifdef USE_SHEEN_COLORMAP
	varying vec2 vSheenColorMapUv;
#endif
#ifdef USE_SHEEN_ROUGHNESSMAP
	varying vec2 vSheenRoughnessMapUv;
#endif
#ifdef USE_SPECULARMAP
	varying vec2 vSpecularMapUv;
#endif
#ifdef USE_SPECULAR_COLORMAP
	varying vec2 vSpecularColorMapUv;
#endif
#ifdef USE_SPECULAR_INTENSITYMAP
	varying vec2 vSpecularIntensityMapUv;
#endif
#ifdef USE_TRANSMISSIONMAP
	uniform mat3 transmissionMapTransform;
	varying vec2 vTransmissionMapUv;
#endif
#ifdef USE_THICKNESSMAP
	uniform mat3 thicknessMapTransform;
	varying vec2 vThicknessMapUv;
#endif`,BE=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
	varying vec2 vUv;
#endif
#ifdef USE_MAP
	uniform mat3 mapTransform;
	varying vec2 vMapUv;
#endif
#ifdef USE_ALPHAMAP
	uniform mat3 alphaMapTransform;
	varying vec2 vAlphaMapUv;
#endif
#ifdef USE_LIGHTMAP
	uniform mat3 lightMapTransform;
	varying vec2 vLightMapUv;
#endif
#ifdef USE_AOMAP
	uniform mat3 aoMapTransform;
	varying vec2 vAoMapUv;
#endif
#ifdef USE_BUMPMAP
	uniform mat3 bumpMapTransform;
	varying vec2 vBumpMapUv;
#endif
#ifdef USE_NORMALMAP
	uniform mat3 normalMapTransform;
	varying vec2 vNormalMapUv;
#endif
#ifdef USE_DISPLACEMENTMAP
	uniform mat3 displacementMapTransform;
	varying vec2 vDisplacementMapUv;
#endif
#ifdef USE_EMISSIVEMAP
	uniform mat3 emissiveMapTransform;
	varying vec2 vEmissiveMapUv;
#endif
#ifdef USE_METALNESSMAP
	uniform mat3 metalnessMapTransform;
	varying vec2 vMetalnessMapUv;
#endif
#ifdef USE_ROUGHNESSMAP
	uniform mat3 roughnessMapTransform;
	varying vec2 vRoughnessMapUv;
#endif
#ifdef USE_ANISOTROPYMAP
	uniform mat3 anisotropyMapTransform;
	varying vec2 vAnisotropyMapUv;
#endif
#ifdef USE_CLEARCOATMAP
	uniform mat3 clearcoatMapTransform;
	varying vec2 vClearcoatMapUv;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	uniform mat3 clearcoatNormalMapTransform;
	varying vec2 vClearcoatNormalMapUv;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	uniform mat3 clearcoatRoughnessMapTransform;
	varying vec2 vClearcoatRoughnessMapUv;
#endif
#ifdef USE_SHEEN_COLORMAP
	uniform mat3 sheenColorMapTransform;
	varying vec2 vSheenColorMapUv;
#endif
#ifdef USE_SHEEN_ROUGHNESSMAP
	uniform mat3 sheenRoughnessMapTransform;
	varying vec2 vSheenRoughnessMapUv;
#endif
#ifdef USE_IRIDESCENCEMAP
	uniform mat3 iridescenceMapTransform;
	varying vec2 vIridescenceMapUv;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	uniform mat3 iridescenceThicknessMapTransform;
	varying vec2 vIridescenceThicknessMapUv;
#endif
#ifdef USE_SPECULARMAP
	uniform mat3 specularMapTransform;
	varying vec2 vSpecularMapUv;
#endif
#ifdef USE_SPECULAR_COLORMAP
	uniform mat3 specularColorMapTransform;
	varying vec2 vSpecularColorMapUv;
#endif
#ifdef USE_SPECULAR_INTENSITYMAP
	uniform mat3 specularIntensityMapTransform;
	varying vec2 vSpecularIntensityMapUv;
#endif
#ifdef USE_TRANSMISSIONMAP
	uniform mat3 transmissionMapTransform;
	varying vec2 vTransmissionMapUv;
#endif
#ifdef USE_THICKNESSMAP
	uniform mat3 thicknessMapTransform;
	varying vec2 vThicknessMapUv;
#endif`,IE=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
	vUv = vec3( uv, 1 ).xy;
#endif
#ifdef USE_MAP
	vMapUv = ( mapTransform * vec3( MAP_UV, 1 ) ).xy;
#endif
#ifdef USE_ALPHAMAP
	vAlphaMapUv = ( alphaMapTransform * vec3( ALPHAMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_LIGHTMAP
	vLightMapUv = ( lightMapTransform * vec3( LIGHTMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_AOMAP
	vAoMapUv = ( aoMapTransform * vec3( AOMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_BUMPMAP
	vBumpMapUv = ( bumpMapTransform * vec3( BUMPMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_NORMALMAP
	vNormalMapUv = ( normalMapTransform * vec3( NORMALMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_DISPLACEMENTMAP
	vDisplacementMapUv = ( displacementMapTransform * vec3( DISPLACEMENTMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_EMISSIVEMAP
	vEmissiveMapUv = ( emissiveMapTransform * vec3( EMISSIVEMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_METALNESSMAP
	vMetalnessMapUv = ( metalnessMapTransform * vec3( METALNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_ROUGHNESSMAP
	vRoughnessMapUv = ( roughnessMapTransform * vec3( ROUGHNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_ANISOTROPYMAP
	vAnisotropyMapUv = ( anisotropyMapTransform * vec3( ANISOTROPYMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_CLEARCOATMAP
	vClearcoatMapUv = ( clearcoatMapTransform * vec3( CLEARCOATMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	vClearcoatNormalMapUv = ( clearcoatNormalMapTransform * vec3( CLEARCOAT_NORMALMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	vClearcoatRoughnessMapUv = ( clearcoatRoughnessMapTransform * vec3( CLEARCOAT_ROUGHNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_IRIDESCENCEMAP
	vIridescenceMapUv = ( iridescenceMapTransform * vec3( IRIDESCENCEMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	vIridescenceThicknessMapUv = ( iridescenceThicknessMapTransform * vec3( IRIDESCENCE_THICKNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SHEEN_COLORMAP
	vSheenColorMapUv = ( sheenColorMapTransform * vec3( SHEEN_COLORMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SHEEN_ROUGHNESSMAP
	vSheenRoughnessMapUv = ( sheenRoughnessMapTransform * vec3( SHEEN_ROUGHNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SPECULARMAP
	vSpecularMapUv = ( specularMapTransform * vec3( SPECULARMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SPECULAR_COLORMAP
	vSpecularColorMapUv = ( specularColorMapTransform * vec3( SPECULAR_COLORMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SPECULAR_INTENSITYMAP
	vSpecularIntensityMapUv = ( specularIntensityMapTransform * vec3( SPECULAR_INTENSITYMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_TRANSMISSIONMAP
	vTransmissionMapUv = ( transmissionMapTransform * vec3( TRANSMISSIONMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_THICKNESSMAP
	vThicknessMapUv = ( thicknessMapTransform * vec3( THICKNESSMAP_UV, 1 ) ).xy;
#endif`,FE=`#if defined( USE_ENVMAP ) || defined( DISTANCE ) || defined ( USE_SHADOWMAP ) || defined ( USE_TRANSMISSION ) || NUM_SPOT_LIGHT_COORDS > 0
	vec4 worldPosition = vec4( transformed, 1.0 );
	#ifdef USE_BATCHING
		worldPosition = batchingMatrix * worldPosition;
	#endif
	#ifdef USE_INSTANCING
		worldPosition = instanceMatrix * worldPosition;
	#endif
	worldPosition = modelMatrix * worldPosition;
#endif`;const HE=`varying vec2 vUv;
uniform mat3 uvTransform;
void main() {
	vUv = ( uvTransform * vec3( uv, 1 ) ).xy;
	gl_Position = vec4( position.xy, 1.0, 1.0 );
}`,GE=`uniform sampler2D t2D;
uniform float backgroundIntensity;
varying vec2 vUv;
void main() {
	vec4 texColor = texture2D( t2D, vUv );
	#ifdef DECODE_VIDEO_TEXTURE
		texColor = vec4( mix( pow( texColor.rgb * 0.9478672986 + vec3( 0.0521327014 ), vec3( 2.4 ) ), texColor.rgb * 0.0773993808, vec3( lessThanEqual( texColor.rgb, vec3( 0.04045 ) ) ) ), texColor.w );
	#endif
	texColor.rgb *= backgroundIntensity;
	gl_FragColor = texColor;
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,VE=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
	gl_Position.z = gl_Position.w;
}`,XE=`#ifdef ENVMAP_TYPE_CUBE
	uniform samplerCube envMap;
#elif defined( ENVMAP_TYPE_CUBE_UV )
	uniform sampler2D envMap;
#endif
uniform float flipEnvMap;
uniform float backgroundBlurriness;
uniform float backgroundIntensity;
uniform mat3 backgroundRotation;
varying vec3 vWorldDirection;
#include <cube_uv_reflection_fragment>
void main() {
	#ifdef ENVMAP_TYPE_CUBE
		vec4 texColor = textureCube( envMap, backgroundRotation * vec3( flipEnvMap * vWorldDirection.x, vWorldDirection.yz ) );
	#elif defined( ENVMAP_TYPE_CUBE_UV )
		vec4 texColor = textureCubeUV( envMap, backgroundRotation * vWorldDirection, backgroundBlurriness );
	#else
		vec4 texColor = vec4( 0.0, 0.0, 0.0, 1.0 );
	#endif
	texColor.rgb *= backgroundIntensity;
	gl_FragColor = texColor;
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,kE=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
	gl_Position.z = gl_Position.w;
}`,WE=`uniform samplerCube tCube;
uniform float tFlip;
uniform float opacity;
varying vec3 vWorldDirection;
void main() {
	vec4 texColor = textureCube( tCube, vec3( tFlip * vWorldDirection.x, vWorldDirection.yz ) );
	gl_FragColor = texColor;
	gl_FragColor.a *= opacity;
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,qE=`#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
varying vec2 vHighPrecisionZW;
void main() {
	#include <uv_vertex>
	#include <batching_vertex>
	#include <skinbase_vertex>
	#include <morphinstance_vertex>
	#ifdef USE_DISPLACEMENTMAP
		#include <beginnormal_vertex>
		#include <morphnormal_vertex>
		#include <skinnormal_vertex>
	#endif
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vHighPrecisionZW = gl_Position.zw;
}`,YE=`#if DEPTH_PACKING == 3200
	uniform float opacity;
#endif
#include <common>
#include <packing>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
varying vec2 vHighPrecisionZW;
void main() {
	vec4 diffuseColor = vec4( 1.0 );
	#include <clipping_planes_fragment>
	#if DEPTH_PACKING == 3200
		diffuseColor.a = opacity;
	#endif
	#include <map_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <logdepthbuf_fragment>
	float fragCoordZ = 0.5 * vHighPrecisionZW[0] / vHighPrecisionZW[1] + 0.5;
	#if DEPTH_PACKING == 3200
		gl_FragColor = vec4( vec3( 1.0 - fragCoordZ ), opacity );
	#elif DEPTH_PACKING == 3201
		gl_FragColor = packDepthToRGBA( fragCoordZ );
	#elif DEPTH_PACKING == 3202
		gl_FragColor = vec4( packDepthToRGB( fragCoordZ ), 1.0 );
	#elif DEPTH_PACKING == 3203
		gl_FragColor = vec4( packDepthToRG( fragCoordZ ), 0.0, 1.0 );
	#endif
}`,jE=`#define DISTANCE
varying vec3 vWorldPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <batching_vertex>
	#include <skinbase_vertex>
	#include <morphinstance_vertex>
	#ifdef USE_DISPLACEMENTMAP
		#include <beginnormal_vertex>
		#include <morphnormal_vertex>
		#include <skinnormal_vertex>
	#endif
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <worldpos_vertex>
	#include <clipping_planes_vertex>
	vWorldPosition = worldPosition.xyz;
}`,ZE=`#define DISTANCE
uniform vec3 referencePosition;
uniform float nearDistance;
uniform float farDistance;
varying vec3 vWorldPosition;
#include <common>
#include <packing>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <clipping_planes_pars_fragment>
void main () {
	vec4 diffuseColor = vec4( 1.0 );
	#include <clipping_planes_fragment>
	#include <map_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	float dist = length( vWorldPosition - referencePosition );
	dist = ( dist - nearDistance ) / ( farDistance - nearDistance );
	dist = saturate( dist );
	gl_FragColor = packDepthToRGBA( dist );
}`,KE=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
}`,QE=`uniform sampler2D tEquirect;
varying vec3 vWorldDirection;
#include <common>
void main() {
	vec3 direction = normalize( vWorldDirection );
	vec2 sampleUV = equirectUv( direction );
	gl_FragColor = texture2D( tEquirect, sampleUV );
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,JE=`uniform float scale;
attribute float lineDistance;
varying float vLineDistance;
#include <common>
#include <uv_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	vLineDistance = scale * lineDistance;
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <fog_vertex>
}`,$E=`uniform vec3 diffuse;
uniform float opacity;
uniform float dashSize;
uniform float totalSize;
varying float vLineDistance;
#include <common>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <fog_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	if ( mod( vLineDistance, totalSize ) > dashSize ) {
		discard;
	}
	vec3 outgoingLight = vec3( 0.0 );
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	outgoingLight = diffuseColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
}`,tT=`#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <envmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#if defined ( USE_ENVMAP ) || defined ( USE_SKINNING )
		#include <beginnormal_vertex>
		#include <morphnormal_vertex>
		#include <skinbase_vertex>
		#include <skinnormal_vertex>
		#include <defaultnormal_vertex>
	#endif
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <worldpos_vertex>
	#include <envmap_vertex>
	#include <fog_vertex>
}`,eT=`uniform vec3 diffuse;
uniform float opacity;
#ifndef FLAT_SHADED
	varying vec3 vNormal;
#endif
#include <common>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_pars_fragment>
#include <fog_pars_fragment>
#include <specularmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <specularmap_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	#ifdef USE_LIGHTMAP
		vec4 lightMapTexel = texture2D( lightMap, vLightMapUv );
		reflectedLight.indirectDiffuse += lightMapTexel.rgb * lightMapIntensity * RECIPROCAL_PI;
	#else
		reflectedLight.indirectDiffuse += vec3( 1.0 );
	#endif
	#include <aomap_fragment>
	reflectedLight.indirectDiffuse *= diffuseColor.rgb;
	vec3 outgoingLight = reflectedLight.indirectDiffuse;
	#include <envmap_fragment>
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,nT=`#define LAMBERT
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <envmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <envmap_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,iT=`#define LAMBERT
uniform vec3 diffuse;
uniform vec3 emissive;
uniform float opacity;
#include <common>
#include <packing>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_pars_fragment>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_lambert_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <specularmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <specularmap_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_lambert_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 outgoingLight = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse + totalEmissiveRadiance;
	#include <envmap_fragment>
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,aT=`#define MATCAP
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <color_pars_vertex>
#include <displacementmap_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <fog_vertex>
	vViewPosition = - mvPosition.xyz;
}`,rT=`#define MATCAP
uniform vec3 diffuse;
uniform float opacity;
uniform sampler2D matcap;
varying vec3 vViewPosition;
#include <common>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <fog_pars_fragment>
#include <normal_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	vec3 viewDir = normalize( vViewPosition );
	vec3 x = normalize( vec3( viewDir.z, 0.0, - viewDir.x ) );
	vec3 y = cross( viewDir, x );
	vec2 uv = vec2( dot( x, normal ), dot( y, normal ) ) * 0.495 + 0.5;
	#ifdef USE_MATCAP
		vec4 matcapColor = texture2D( matcap, uv );
	#else
		vec4 matcapColor = vec4( vec3( mix( 0.2, 0.8, uv.y ) ), 1.0 );
	#endif
	vec3 outgoingLight = diffuseColor.rgb * matcapColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,sT=`#define NORMAL
#if defined( FLAT_SHADED ) || defined( USE_BUMPMAP ) || defined( USE_NORMALMAP_TANGENTSPACE )
	varying vec3 vViewPosition;
#endif
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphinstance_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
#if defined( FLAT_SHADED ) || defined( USE_BUMPMAP ) || defined( USE_NORMALMAP_TANGENTSPACE )
	vViewPosition = - mvPosition.xyz;
#endif
}`,oT=`#define NORMAL
uniform float opacity;
#if defined( FLAT_SHADED ) || defined( USE_BUMPMAP ) || defined( USE_NORMALMAP_TANGENTSPACE )
	varying vec3 vViewPosition;
#endif
#include <packing>
#include <uv_pars_fragment>
#include <normal_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( 0.0, 0.0, 0.0, opacity );
	#include <clipping_planes_fragment>
	#include <logdepthbuf_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	gl_FragColor = vec4( packNormalToRGB( normal ), diffuseColor.a );
	#ifdef OPAQUE
		gl_FragColor.a = 1.0;
	#endif
}`,lT=`#define PHONG
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <envmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphinstance_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <envmap_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,uT=`#define PHONG
uniform vec3 diffuse;
uniform vec3 emissive;
uniform vec3 specular;
uniform float shininess;
uniform float opacity;
#include <common>
#include <packing>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_pars_fragment>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_phong_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <specularmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <specularmap_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_phong_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 outgoingLight = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse + reflectedLight.directSpecular + reflectedLight.indirectSpecular + totalEmissiveRadiance;
	#include <envmap_fragment>
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,cT=`#define STANDARD
varying vec3 vViewPosition;
#ifdef USE_TRANSMISSION
	varying vec3 vWorldPosition;
#endif
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
#ifdef USE_TRANSMISSION
	vWorldPosition = worldPosition.xyz;
#endif
}`,fT=`#define STANDARD
#ifdef PHYSICAL
	#define IOR
	#define USE_SPECULAR
#endif
uniform vec3 diffuse;
uniform vec3 emissive;
uniform float roughness;
uniform float metalness;
uniform float opacity;
#ifdef IOR
	uniform float ior;
#endif
#ifdef USE_SPECULAR
	uniform float specularIntensity;
	uniform vec3 specularColor;
	#ifdef USE_SPECULAR_COLORMAP
		uniform sampler2D specularColorMap;
	#endif
	#ifdef USE_SPECULAR_INTENSITYMAP
		uniform sampler2D specularIntensityMap;
	#endif
#endif
#ifdef USE_CLEARCOAT
	uniform float clearcoat;
	uniform float clearcoatRoughness;
#endif
#ifdef USE_DISPERSION
	uniform float dispersion;
#endif
#ifdef USE_IRIDESCENCE
	uniform float iridescence;
	uniform float iridescenceIOR;
	uniform float iridescenceThicknessMinimum;
	uniform float iridescenceThicknessMaximum;
#endif
#ifdef USE_SHEEN
	uniform vec3 sheenColor;
	uniform float sheenRoughness;
	#ifdef USE_SHEEN_COLORMAP
		uniform sampler2D sheenColorMap;
	#endif
	#ifdef USE_SHEEN_ROUGHNESSMAP
		uniform sampler2D sheenRoughnessMap;
	#endif
#endif
#ifdef USE_ANISOTROPY
	uniform vec2 anisotropyVector;
	#ifdef USE_ANISOTROPYMAP
		uniform sampler2D anisotropyMap;
	#endif
#endif
varying vec3 vViewPosition;
#include <common>
#include <packing>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <iridescence_fragment>
#include <cube_uv_reflection_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_physical_pars_fragment>
#include <fog_pars_fragment>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_physical_pars_fragment>
#include <transmission_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <clearcoat_pars_fragment>
#include <iridescence_pars_fragment>
#include <roughnessmap_pars_fragment>
#include <metalnessmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <roughnessmap_fragment>
	#include <metalnessmap_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <clearcoat_normal_fragment_begin>
	#include <clearcoat_normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_physical_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 totalDiffuse = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse;
	vec3 totalSpecular = reflectedLight.directSpecular + reflectedLight.indirectSpecular;
	#include <transmission_fragment>
	vec3 outgoingLight = totalDiffuse + totalSpecular + totalEmissiveRadiance;
	#ifdef USE_SHEEN
		float sheenEnergyComp = 1.0 - 0.157 * max3( material.sheenColor );
		outgoingLight = outgoingLight * sheenEnergyComp + sheenSpecularDirect + sheenSpecularIndirect;
	#endif
	#ifdef USE_CLEARCOAT
		float dotNVcc = saturate( dot( geometryClearcoatNormal, geometryViewDir ) );
		vec3 Fcc = F_Schlick( material.clearcoatF0, material.clearcoatF90, dotNVcc );
		outgoingLight = outgoingLight * ( 1.0 - material.clearcoat * Fcc ) + ( clearcoatSpecularDirect + clearcoatSpecularIndirect ) * material.clearcoat;
	#endif
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,hT=`#define TOON
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,dT=`#define TOON
uniform vec3 diffuse;
uniform vec3 emissive;
uniform float opacity;
#include <common>
#include <packing>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <gradientmap_pars_fragment>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_toon_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_toon_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 outgoingLight = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse + totalEmissiveRadiance;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,pT=`uniform float size;
uniform float scale;
#include <common>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
#ifdef USE_POINTS_UV
	varying vec2 vUv;
	uniform mat3 uvTransform;
#endif
void main() {
	#ifdef USE_POINTS_UV
		vUv = ( uvTransform * vec3( uv, 1 ) ).xy;
	#endif
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <project_vertex>
	gl_PointSize = size;
	#ifdef USE_SIZEATTENUATION
		bool isPerspective = isPerspectiveMatrix( projectionMatrix );
		if ( isPerspective ) gl_PointSize *= ( scale / - mvPosition.z );
	#endif
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <worldpos_vertex>
	#include <fog_vertex>
}`,mT=`uniform vec3 diffuse;
uniform float opacity;
#include <common>
#include <color_pars_fragment>
#include <map_particle_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <fog_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	vec3 outgoingLight = vec3( 0.0 );
	#include <logdepthbuf_fragment>
	#include <map_particle_fragment>
	#include <color_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	outgoingLight = diffuseColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
}`,gT=`#include <common>
#include <batching_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <shadowmap_pars_vertex>
void main() {
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphinstance_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <worldpos_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,_T=`uniform vec3 color;
uniform float opacity;
#include <common>
#include <packing>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <logdepthbuf_pars_fragment>
#include <shadowmap_pars_fragment>
#include <shadowmask_pars_fragment>
void main() {
	#include <logdepthbuf_fragment>
	gl_FragColor = vec4( color, opacity * ( 1.0 - getShadowMask() ) );
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
}`,vT=`uniform float rotation;
uniform vec2 center;
#include <common>
#include <uv_pars_vertex>
#include <fog_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	vec4 mvPosition = modelViewMatrix[ 3 ];
	vec2 scale = vec2( length( modelMatrix[ 0 ].xyz ), length( modelMatrix[ 1 ].xyz ) );
	#ifndef USE_SIZEATTENUATION
		bool isPerspective = isPerspectiveMatrix( projectionMatrix );
		if ( isPerspective ) scale *= - mvPosition.z;
	#endif
	vec2 alignedPosition = ( position.xy - ( center - vec2( 0.5 ) ) ) * scale;
	vec2 rotatedPosition;
	rotatedPosition.x = cos( rotation ) * alignedPosition.x - sin( rotation ) * alignedPosition.y;
	rotatedPosition.y = sin( rotation ) * alignedPosition.x + cos( rotation ) * alignedPosition.y;
	mvPosition.xy += rotatedPosition;
	gl_Position = projectionMatrix * mvPosition;
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <fog_vertex>
}`,ST=`uniform vec3 diffuse;
uniform float opacity;
#include <common>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <fog_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	vec3 outgoingLight = vec3( 0.0 );
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	outgoingLight = diffuseColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
}`,le={alphahash_fragment:GM,alphahash_pars_fragment:VM,alphamap_fragment:XM,alphamap_pars_fragment:kM,alphatest_fragment:WM,alphatest_pars_fragment:qM,aomap_fragment:YM,aomap_pars_fragment:jM,batching_pars_vertex:ZM,batching_vertex:KM,begin_vertex:QM,beginnormal_vertex:JM,bsdfs:$M,iridescence_fragment:ty,bumpmap_pars_fragment:ey,clipping_planes_fragment:ny,clipping_planes_pars_fragment:iy,clipping_planes_pars_vertex:ay,clipping_planes_vertex:ry,color_fragment:sy,color_pars_fragment:oy,color_pars_vertex:ly,color_vertex:uy,common:cy,cube_uv_reflection_fragment:fy,defaultnormal_vertex:hy,displacementmap_pars_vertex:dy,displacementmap_vertex:py,emissivemap_fragment:my,emissivemap_pars_fragment:gy,colorspace_fragment:_y,colorspace_pars_fragment:vy,envmap_fragment:Sy,envmap_common_pars_fragment:xy,envmap_pars_fragment:My,envmap_pars_vertex:yy,envmap_physical_pars_fragment:Ny,envmap_vertex:Ey,fog_vertex:Ty,fog_pars_vertex:by,fog_fragment:Ay,fog_pars_fragment:Ry,gradientmap_pars_fragment:Cy,lightmap_pars_fragment:wy,lights_lambert_fragment:Dy,lights_lambert_pars_fragment:Uy,lights_pars_begin:Ly,lights_toon_fragment:Oy,lights_toon_pars_fragment:zy,lights_phong_fragment:Py,lights_phong_pars_fragment:By,lights_physical_fragment:Iy,lights_physical_pars_fragment:Fy,lights_fragment_begin:Hy,lights_fragment_maps:Gy,lights_fragment_end:Vy,logdepthbuf_fragment:Xy,logdepthbuf_pars_fragment:ky,logdepthbuf_pars_vertex:Wy,logdepthbuf_vertex:qy,map_fragment:Yy,map_pars_fragment:jy,map_particle_fragment:Zy,map_particle_pars_fragment:Ky,metalnessmap_fragment:Qy,metalnessmap_pars_fragment:Jy,morphinstance_vertex:$y,morphcolor_vertex:tE,morphnormal_vertex:eE,morphtarget_pars_vertex:nE,morphtarget_vertex:iE,normal_fragment_begin:aE,normal_fragment_maps:rE,normal_pars_fragment:sE,normal_pars_vertex:oE,normal_vertex:lE,normalmap_pars_fragment:uE,clearcoat_normal_fragment_begin:cE,clearcoat_normal_fragment_maps:fE,clearcoat_pars_fragment:hE,iridescence_pars_fragment:dE,opaque_fragment:pE,packing:mE,premultiplied_alpha_fragment:gE,project_vertex:_E,dithering_fragment:vE,dithering_pars_fragment:SE,roughnessmap_fragment:xE,roughnessmap_pars_fragment:ME,shadowmap_pars_fragment:yE,shadowmap_pars_vertex:EE,shadowmap_vertex:TE,shadowmask_pars_fragment:bE,skinbase_vertex:AE,skinning_pars_vertex:RE,skinning_vertex:CE,skinnormal_vertex:wE,specularmap_fragment:DE,specularmap_pars_fragment:UE,tonemapping_fragment:LE,tonemapping_pars_fragment:NE,transmission_fragment:OE,transmission_pars_fragment:zE,uv_pars_fragment:PE,uv_pars_vertex:BE,uv_vertex:IE,worldpos_vertex:FE,background_vert:HE,background_frag:GE,backgroundCube_vert:VE,backgroundCube_frag:XE,cube_vert:kE,cube_frag:WE,depth_vert:qE,depth_frag:YE,distanceRGBA_vert:jE,distanceRGBA_frag:ZE,equirect_vert:KE,equirect_frag:QE,linedashed_vert:JE,linedashed_frag:$E,meshbasic_vert:tT,meshbasic_frag:eT,meshlambert_vert:nT,meshlambert_frag:iT,meshmatcap_vert:aT,meshmatcap_frag:rT,meshnormal_vert:sT,meshnormal_frag:oT,meshphong_vert:lT,meshphong_frag:uT,meshphysical_vert:cT,meshphysical_frag:fT,meshtoon_vert:hT,meshtoon_frag:dT,points_vert:pT,points_frag:mT,shadow_vert:gT,shadow_frag:_T,sprite_vert:vT,sprite_frag:ST},Ut={common:{diffuse:{value:new Me(16777215)},opacity:{value:1},map:{value:null},mapTransform:{value:new oe},alphaMap:{value:null},alphaMapTransform:{value:new oe},alphaTest:{value:0}},specularmap:{specularMap:{value:null},specularMapTransform:{value:new oe}},envmap:{envMap:{value:null},envMapRotation:{value:new oe},flipEnvMap:{value:-1},reflectivity:{value:1},ior:{value:1.5},refractionRatio:{value:.98}},aomap:{aoMap:{value:null},aoMapIntensity:{value:1},aoMapTransform:{value:new oe}},lightmap:{lightMap:{value:null},lightMapIntensity:{value:1},lightMapTransform:{value:new oe}},bumpmap:{bumpMap:{value:null},bumpMapTransform:{value:new oe},bumpScale:{value:1}},normalmap:{normalMap:{value:null},normalMapTransform:{value:new oe},normalScale:{value:new ye(1,1)}},displacementmap:{displacementMap:{value:null},displacementMapTransform:{value:new oe},displacementScale:{value:1},displacementBias:{value:0}},emissivemap:{emissiveMap:{value:null},emissiveMapTransform:{value:new oe}},metalnessmap:{metalnessMap:{value:null},metalnessMapTransform:{value:new oe}},roughnessmap:{roughnessMap:{value:null},roughnessMapTransform:{value:new oe}},gradientmap:{gradientMap:{value:null}},fog:{fogDensity:{value:25e-5},fogNear:{value:1},fogFar:{value:2e3},fogColor:{value:new Me(16777215)}},lights:{ambientLightColor:{value:[]},lightProbe:{value:[]},directionalLights:{value:[],properties:{direction:{},color:{}}},directionalLightShadows:{value:[],properties:{shadowIntensity:1,shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{}}},directionalShadowMap:{value:[]},directionalShadowMatrix:{value:[]},spotLights:{value:[],properties:{color:{},position:{},direction:{},distance:{},coneCos:{},penumbraCos:{},decay:{}}},spotLightShadows:{value:[],properties:{shadowIntensity:1,shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{}}},spotLightMap:{value:[]},spotShadowMap:{value:[]},spotLightMatrix:{value:[]},pointLights:{value:[],properties:{color:{},position:{},decay:{},distance:{}}},pointLightShadows:{value:[],properties:{shadowIntensity:1,shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{},shadowCameraNear:{},shadowCameraFar:{}}},pointShadowMap:{value:[]},pointShadowMatrix:{value:[]},hemisphereLights:{value:[],properties:{direction:{},skyColor:{},groundColor:{}}},rectAreaLights:{value:[],properties:{color:{},position:{},width:{},height:{}}},ltc_1:{value:null},ltc_2:{value:null}},points:{diffuse:{value:new Me(16777215)},opacity:{value:1},size:{value:1},scale:{value:1},map:{value:null},alphaMap:{value:null},alphaMapTransform:{value:new oe},alphaTest:{value:0},uvTransform:{value:new oe}},sprite:{diffuse:{value:new Me(16777215)},opacity:{value:1},center:{value:new ye(.5,.5)},rotation:{value:0},map:{value:null},mapTransform:{value:new oe},alphaMap:{value:null},alphaMapTransform:{value:new oe},alphaTest:{value:0}}},Ci={basic:{uniforms:Un([Ut.common,Ut.specularmap,Ut.envmap,Ut.aomap,Ut.lightmap,Ut.fog]),vertexShader:le.meshbasic_vert,fragmentShader:le.meshbasic_frag},lambert:{uniforms:Un([Ut.common,Ut.specularmap,Ut.envmap,Ut.aomap,Ut.lightmap,Ut.emissivemap,Ut.bumpmap,Ut.normalmap,Ut.displacementmap,Ut.fog,Ut.lights,{emissive:{value:new Me(0)}}]),vertexShader:le.meshlambert_vert,fragmentShader:le.meshlambert_frag},phong:{uniforms:Un([Ut.common,Ut.specularmap,Ut.envmap,Ut.aomap,Ut.lightmap,Ut.emissivemap,Ut.bumpmap,Ut.normalmap,Ut.displacementmap,Ut.fog,Ut.lights,{emissive:{value:new Me(0)},specular:{value:new Me(1118481)},shininess:{value:30}}]),vertexShader:le.meshphong_vert,fragmentShader:le.meshphong_frag},standard:{uniforms:Un([Ut.common,Ut.envmap,Ut.aomap,Ut.lightmap,Ut.emissivemap,Ut.bumpmap,Ut.normalmap,Ut.displacementmap,Ut.roughnessmap,Ut.metalnessmap,Ut.fog,Ut.lights,{emissive:{value:new Me(0)},roughness:{value:1},metalness:{value:0},envMapIntensity:{value:1}}]),vertexShader:le.meshphysical_vert,fragmentShader:le.meshphysical_frag},toon:{uniforms:Un([Ut.common,Ut.aomap,Ut.lightmap,Ut.emissivemap,Ut.bumpmap,Ut.normalmap,Ut.displacementmap,Ut.gradientmap,Ut.fog,Ut.lights,{emissive:{value:new Me(0)}}]),vertexShader:le.meshtoon_vert,fragmentShader:le.meshtoon_frag},matcap:{uniforms:Un([Ut.common,Ut.bumpmap,Ut.normalmap,Ut.displacementmap,Ut.fog,{matcap:{value:null}}]),vertexShader:le.meshmatcap_vert,fragmentShader:le.meshmatcap_frag},points:{uniforms:Un([Ut.points,Ut.fog]),vertexShader:le.points_vert,fragmentShader:le.points_frag},dashed:{uniforms:Un([Ut.common,Ut.fog,{scale:{value:1},dashSize:{value:1},totalSize:{value:2}}]),vertexShader:le.linedashed_vert,fragmentShader:le.linedashed_frag},depth:{uniforms:Un([Ut.common,Ut.displacementmap]),vertexShader:le.depth_vert,fragmentShader:le.depth_frag},normal:{uniforms:Un([Ut.common,Ut.bumpmap,Ut.normalmap,Ut.displacementmap,{opacity:{value:1}}]),vertexShader:le.meshnormal_vert,fragmentShader:le.meshnormal_frag},sprite:{uniforms:Un([Ut.sprite,Ut.fog]),vertexShader:le.sprite_vert,fragmentShader:le.sprite_frag},background:{uniforms:{uvTransform:{value:new oe},t2D:{value:null},backgroundIntensity:{value:1}},vertexShader:le.background_vert,fragmentShader:le.background_frag},backgroundCube:{uniforms:{envMap:{value:null},flipEnvMap:{value:-1},backgroundBlurriness:{value:0},backgroundIntensity:{value:1},backgroundRotation:{value:new oe}},vertexShader:le.backgroundCube_vert,fragmentShader:le.backgroundCube_frag},cube:{uniforms:{tCube:{value:null},tFlip:{value:-1},opacity:{value:1}},vertexShader:le.cube_vert,fragmentShader:le.cube_frag},equirect:{uniforms:{tEquirect:{value:null}},vertexShader:le.equirect_vert,fragmentShader:le.equirect_frag},distanceRGBA:{uniforms:Un([Ut.common,Ut.displacementmap,{referencePosition:{value:new Q},nearDistance:{value:1},farDistance:{value:1e3}}]),vertexShader:le.distanceRGBA_vert,fragmentShader:le.distanceRGBA_frag},shadow:{uniforms:Un([Ut.lights,Ut.fog,{color:{value:new Me(0)},opacity:{value:1}}]),vertexShader:le.shadow_vert,fragmentShader:le.shadow_frag}};Ci.physical={uniforms:Un([Ci.standard.uniforms,{clearcoat:{value:0},clearcoatMap:{value:null},clearcoatMapTransform:{value:new oe},clearcoatNormalMap:{value:null},clearcoatNormalMapTransform:{value:new oe},clearcoatNormalScale:{value:new ye(1,1)},clearcoatRoughness:{value:0},clearcoatRoughnessMap:{value:null},clearcoatRoughnessMapTransform:{value:new oe},dispersion:{value:0},iridescence:{value:0},iridescenceMap:{value:null},iridescenceMapTransform:{value:new oe},iridescenceIOR:{value:1.3},iridescenceThicknessMinimum:{value:100},iridescenceThicknessMaximum:{value:400},iridescenceThicknessMap:{value:null},iridescenceThicknessMapTransform:{value:new oe},sheen:{value:0},sheenColor:{value:new Me(0)},sheenColorMap:{value:null},sheenColorMapTransform:{value:new oe},sheenRoughness:{value:1},sheenRoughnessMap:{value:null},sheenRoughnessMapTransform:{value:new oe},transmission:{value:0},transmissionMap:{value:null},transmissionMapTransform:{value:new oe},transmissionSamplerSize:{value:new ye},transmissionSamplerMap:{value:null},thickness:{value:0},thicknessMap:{value:null},thicknessMapTransform:{value:new oe},attenuationDistance:{value:0},attenuationColor:{value:new Me(0)},specularColor:{value:new Me(1,1,1)},specularColorMap:{value:null},specularColorMapTransform:{value:new oe},specularIntensity:{value:1},specularIntensityMap:{value:null},specularIntensityMapTransform:{value:new oe},anisotropyVector:{value:new ye},anisotropyMap:{value:null},anisotropyMapTransform:{value:new oe}}]),vertexShader:le.meshphysical_vert,fragmentShader:le.meshphysical_frag};const hu={r:0,b:0,g:0},hr=new Li,xT=new Ye;function MT(o,e,i,r,l,c,h){const d=new Me(0);let m=c===!0?0:1,p,S,v=null,x=0,y=null;function R(U){let C=U.isScene===!0?U.background:null;return C&&C.isTexture&&(C=(U.backgroundBlurriness>0?i:e).get(C)),C}function w(U){let C=!1;const G=R(U);G===null?_(d,m):G&&G.isColor&&(_(G,1),C=!0);const I=o.xr.getEnvironmentBlendMode();I==="additive"?r.buffers.color.setClear(0,0,0,1,h):I==="alpha-blend"&&r.buffers.color.setClear(0,0,0,0,h),(o.autoClear||C)&&(r.buffers.depth.setTest(!0),r.buffers.depth.setMask(!0),r.buffers.color.setMask(!0),o.clear(o.autoClearColor,o.autoClearDepth,o.autoClearStencil))}function M(U,C){const G=R(C);G&&(G.isCubeTexture||G.mapping===Au)?(S===void 0&&(S=new ui(new Po(1,1,1),new Va({name:"BackgroundCubeMaterial",uniforms:ys(Ci.backgroundCube.uniforms),vertexShader:Ci.backgroundCube.vertexShader,fragmentShader:Ci.backgroundCube.fragmentShader,side:Gn,depthTest:!1,depthWrite:!1,fog:!1,allowOverride:!1})),S.geometry.deleteAttribute("normal"),S.geometry.deleteAttribute("uv"),S.onBeforeRender=function(I,O,V){this.matrixWorld.copyPosition(V.matrixWorld)},Object.defineProperty(S.material,"envMap",{get:function(){return this.uniforms.envMap.value}}),l.update(S)),hr.copy(C.backgroundRotation),hr.x*=-1,hr.y*=-1,hr.z*=-1,G.isCubeTexture&&G.isRenderTargetTexture===!1&&(hr.y*=-1,hr.z*=-1),S.material.uniforms.envMap.value=G,S.material.uniforms.flipEnvMap.value=G.isCubeTexture&&G.isRenderTargetTexture===!1?-1:1,S.material.uniforms.backgroundBlurriness.value=C.backgroundBlurriness,S.material.uniforms.backgroundIntensity.value=C.backgroundIntensity,S.material.uniforms.backgroundRotation.value.setFromMatrix4(xT.makeRotationFromEuler(hr)),S.material.toneMapped=Re.getTransfer(G.colorSpace)!==Be,(v!==G||x!==G.version||y!==o.toneMapping)&&(S.material.needsUpdate=!0,v=G,x=G.version,y=o.toneMapping),S.layers.enableAll(),U.unshift(S,S.geometry,S.material,0,0,null)):G&&G.isTexture&&(p===void 0&&(p=new ui(new Ru(2,2),new Va({name:"BackgroundMaterial",uniforms:ys(Ci.background.uniforms),vertexShader:Ci.background.vertexShader,fragmentShader:Ci.background.fragmentShader,side:Ga,depthTest:!1,depthWrite:!1,fog:!1,allowOverride:!1})),p.geometry.deleteAttribute("normal"),Object.defineProperty(p.material,"map",{get:function(){return this.uniforms.t2D.value}}),l.update(p)),p.material.uniforms.t2D.value=G,p.material.uniforms.backgroundIntensity.value=C.backgroundIntensity,p.material.toneMapped=Re.getTransfer(G.colorSpace)!==Be,G.matrixAutoUpdate===!0&&G.updateMatrix(),p.material.uniforms.uvTransform.value.copy(G.matrix),(v!==G||x!==G.version||y!==o.toneMapping)&&(p.material.needsUpdate=!0,v=G,x=G.version,y=o.toneMapping),p.layers.enableAll(),U.unshift(p,p.geometry,p.material,0,0,null))}function _(U,C){U.getRGB(hu,G0(o)),r.buffers.color.setClear(hu.r,hu.g,hu.b,C,h)}function L(){S!==void 0&&(S.geometry.dispose(),S.material.dispose(),S=void 0),p!==void 0&&(p.geometry.dispose(),p.material.dispose(),p=void 0)}return{getClearColor:function(){return d},setClearColor:function(U,C=1){d.set(U),m=C,_(d,m)},getClearAlpha:function(){return m},setClearAlpha:function(U){m=U,_(d,m)},render:w,addToRenderList:M,dispose:L}}function yT(o,e){const i=o.getParameter(o.MAX_VERTEX_ATTRIBS),r={},l=x(null);let c=l,h=!1;function d(b,B,rt,st,dt){let pt=!1;const P=v(st,rt,B);c!==P&&(c=P,p(c.object)),pt=y(b,st,rt,dt),pt&&R(b,st,rt,dt),dt!==null&&e.update(dt,o.ELEMENT_ARRAY_BUFFER),(pt||h)&&(h=!1,C(b,B,rt,st),dt!==null&&o.bindBuffer(o.ELEMENT_ARRAY_BUFFER,e.get(dt).buffer))}function m(){return o.createVertexArray()}function p(b){return o.bindVertexArray(b)}function S(b){return o.deleteVertexArray(b)}function v(b,B,rt){const st=rt.wireframe===!0;let dt=r[b.id];dt===void 0&&(dt={},r[b.id]=dt);let pt=dt[B.id];pt===void 0&&(pt={},dt[B.id]=pt);let P=pt[st];return P===void 0&&(P=x(m()),pt[st]=P),P}function x(b){const B=[],rt=[],st=[];for(let dt=0;dt<i;dt++)B[dt]=0,rt[dt]=0,st[dt]=0;return{geometry:null,program:null,wireframe:!1,newAttributes:B,enabledAttributes:rt,attributeDivisors:st,object:b,attributes:{},index:null}}function y(b,B,rt,st){const dt=c.attributes,pt=B.attributes;let P=0;const Y=rt.getAttributes();for(const j in Y)if(Y[j].location>=0){const Tt=dt[j];let z=pt[j];if(z===void 0&&(j==="instanceMatrix"&&b.instanceMatrix&&(z=b.instanceMatrix),j==="instanceColor"&&b.instanceColor&&(z=b.instanceColor)),Tt===void 0||Tt.attribute!==z||z&&Tt.data!==z.data)return!0;P++}return c.attributesNum!==P||c.index!==st}function R(b,B,rt,st){const dt={},pt=B.attributes;let P=0;const Y=rt.getAttributes();for(const j in Y)if(Y[j].location>=0){let Tt=pt[j];Tt===void 0&&(j==="instanceMatrix"&&b.instanceMatrix&&(Tt=b.instanceMatrix),j==="instanceColor"&&b.instanceColor&&(Tt=b.instanceColor));const z={};z.attribute=Tt,Tt&&Tt.data&&(z.data=Tt.data),dt[j]=z,P++}c.attributes=dt,c.attributesNum=P,c.index=st}function w(){const b=c.newAttributes;for(let B=0,rt=b.length;B<rt;B++)b[B]=0}function M(b){_(b,0)}function _(b,B){const rt=c.newAttributes,st=c.enabledAttributes,dt=c.attributeDivisors;rt[b]=1,st[b]===0&&(o.enableVertexAttribArray(b),st[b]=1),dt[b]!==B&&(o.vertexAttribDivisor(b,B),dt[b]=B)}function L(){const b=c.newAttributes,B=c.enabledAttributes;for(let rt=0,st=B.length;rt<st;rt++)B[rt]!==b[rt]&&(o.disableVertexAttribArray(rt),B[rt]=0)}function U(b,B,rt,st,dt,pt,P){P===!0?o.vertexAttribIPointer(b,B,rt,dt,pt):o.vertexAttribPointer(b,B,rt,st,dt,pt)}function C(b,B,rt,st){w();const dt=st.attributes,pt=rt.getAttributes(),P=B.defaultAttributeValues;for(const Y in pt){const j=pt[Y];if(j.location>=0){let vt=dt[Y];if(vt===void 0&&(Y==="instanceMatrix"&&b.instanceMatrix&&(vt=b.instanceMatrix),Y==="instanceColor"&&b.instanceColor&&(vt=b.instanceColor)),vt!==void 0){const Tt=vt.normalized,z=vt.itemSize,nt=e.get(vt);if(nt===void 0)continue;const xt=nt.buffer,K=nt.type,ft=nt.bytesPerElement,yt=K===o.INT||K===o.UNSIGNED_INT||vt.gpuType===cd;if(vt.isInterleavedBufferAttribute){const St=vt.data,zt=St.stride,qt=vt.offset;if(St.isInstancedInterleavedBuffer){for(let jt=0;jt<j.locationSize;jt++)_(j.location+jt,St.meshPerAttribute);b.isInstancedMesh!==!0&&st._maxInstanceCount===void 0&&(st._maxInstanceCount=St.meshPerAttribute*St.count)}else for(let jt=0;jt<j.locationSize;jt++)M(j.location+jt);o.bindBuffer(o.ARRAY_BUFFER,xt);for(let jt=0;jt<j.locationSize;jt++)U(j.location+jt,z/j.locationSize,K,Tt,zt*ft,(qt+z/j.locationSize*jt)*ft,yt)}else{if(vt.isInstancedBufferAttribute){for(let St=0;St<j.locationSize;St++)_(j.location+St,vt.meshPerAttribute);b.isInstancedMesh!==!0&&st._maxInstanceCount===void 0&&(st._maxInstanceCount=vt.meshPerAttribute*vt.count)}else for(let St=0;St<j.locationSize;St++)M(j.location+St);o.bindBuffer(o.ARRAY_BUFFER,xt);for(let St=0;St<j.locationSize;St++)U(j.location+St,z/j.locationSize,K,Tt,z*ft,z/j.locationSize*St*ft,yt)}}else if(P!==void 0){const Tt=P[Y];if(Tt!==void 0)switch(Tt.length){case 2:o.vertexAttrib2fv(j.location,Tt);break;case 3:o.vertexAttrib3fv(j.location,Tt);break;case 4:o.vertexAttrib4fv(j.location,Tt);break;default:o.vertexAttrib1fv(j.location,Tt)}}}}L()}function G(){V();for(const b in r){const B=r[b];for(const rt in B){const st=B[rt];for(const dt in st)S(st[dt].object),delete st[dt];delete B[rt]}delete r[b]}}function I(b){if(r[b.id]===void 0)return;const B=r[b.id];for(const rt in B){const st=B[rt];for(const dt in st)S(st[dt].object),delete st[dt];delete B[rt]}delete r[b.id]}function O(b){for(const B in r){const rt=r[B];if(rt[b.id]===void 0)continue;const st=rt[b.id];for(const dt in st)S(st[dt].object),delete st[dt];delete rt[b.id]}}function V(){D(),h=!0,c!==l&&(c=l,p(c.object))}function D(){l.geometry=null,l.program=null,l.wireframe=!1}return{setup:d,reset:V,resetDefaultState:D,dispose:G,releaseStatesOfGeometry:I,releaseStatesOfProgram:O,initAttributes:w,enableAttribute:M,disableUnusedAttributes:L}}function ET(o,e,i){let r;function l(p){r=p}function c(p,S){o.drawArrays(r,p,S),i.update(S,r,1)}function h(p,S,v){v!==0&&(o.drawArraysInstanced(r,p,S,v),i.update(S,r,v))}function d(p,S,v){if(v===0)return;e.get("WEBGL_multi_draw").multiDrawArraysWEBGL(r,p,0,S,0,v);let y=0;for(let R=0;R<v;R++)y+=S[R];i.update(y,r,1)}function m(p,S,v,x){if(v===0)return;const y=e.get("WEBGL_multi_draw");if(y===null)for(let R=0;R<p.length;R++)h(p[R],S[R],x[R]);else{y.multiDrawArraysInstancedWEBGL(r,p,0,S,0,x,0,v);let R=0;for(let w=0;w<v;w++)R+=S[w]*x[w];i.update(R,r,1)}}this.setMode=l,this.render=c,this.renderInstances=h,this.renderMultiDraw=d,this.renderMultiDrawInstances=m}function TT(o,e,i,r){let l;function c(){if(l!==void 0)return l;if(e.has("EXT_texture_filter_anisotropic")===!0){const O=e.get("EXT_texture_filter_anisotropic");l=o.getParameter(O.MAX_TEXTURE_MAX_ANISOTROPY_EXT)}else l=0;return l}function h(O){return!(O!==Mi&&r.convert(O)!==o.getParameter(o.IMPLEMENTATION_COLOR_READ_FORMAT))}function d(O){const V=O===Uo&&(e.has("EXT_color_buffer_half_float")||e.has("EXT_color_buffer_float"));return!(O!==Ui&&r.convert(O)!==o.getParameter(o.IMPLEMENTATION_COLOR_READ_TYPE)&&O!==sa&&!V)}function m(O){if(O==="highp"){if(o.getShaderPrecisionFormat(o.VERTEX_SHADER,o.HIGH_FLOAT).precision>0&&o.getShaderPrecisionFormat(o.FRAGMENT_SHADER,o.HIGH_FLOAT).precision>0)return"highp";O="mediump"}return O==="mediump"&&o.getShaderPrecisionFormat(o.VERTEX_SHADER,o.MEDIUM_FLOAT).precision>0&&o.getShaderPrecisionFormat(o.FRAGMENT_SHADER,o.MEDIUM_FLOAT).precision>0?"mediump":"lowp"}let p=i.precision!==void 0?i.precision:"highp";const S=m(p);S!==p&&(console.warn("THREE.WebGLRenderer:",p,"not supported, using",S,"instead."),p=S);const v=i.logarithmicDepthBuffer===!0,x=i.reverseDepthBuffer===!0&&e.has("EXT_clip_control"),y=o.getParameter(o.MAX_TEXTURE_IMAGE_UNITS),R=o.getParameter(o.MAX_VERTEX_TEXTURE_IMAGE_UNITS),w=o.getParameter(o.MAX_TEXTURE_SIZE),M=o.getParameter(o.MAX_CUBE_MAP_TEXTURE_SIZE),_=o.getParameter(o.MAX_VERTEX_ATTRIBS),L=o.getParameter(o.MAX_VERTEX_UNIFORM_VECTORS),U=o.getParameter(o.MAX_VARYING_VECTORS),C=o.getParameter(o.MAX_FRAGMENT_UNIFORM_VECTORS),G=R>0,I=o.getParameter(o.MAX_SAMPLES);return{isWebGL2:!0,getMaxAnisotropy:c,getMaxPrecision:m,textureFormatReadable:h,textureTypeReadable:d,precision:p,logarithmicDepthBuffer:v,reverseDepthBuffer:x,maxTextures:y,maxVertexTextures:R,maxTextureSize:w,maxCubemapSize:M,maxAttributes:_,maxVertexUniforms:L,maxVaryings:U,maxFragmentUniforms:C,vertexTextures:G,maxSamples:I}}function bT(o){const e=this;let i=null,r=0,l=!1,c=!1;const h=new pr,d=new oe,m={value:null,needsUpdate:!1};this.uniform=m,this.numPlanes=0,this.numIntersection=0,this.init=function(v,x){const y=v.length!==0||x||r!==0||l;return l=x,r=v.length,y},this.beginShadows=function(){c=!0,S(null)},this.endShadows=function(){c=!1},this.setGlobalState=function(v,x){i=S(v,x,0)},this.setState=function(v,x,y){const R=v.clippingPlanes,w=v.clipIntersection,M=v.clipShadows,_=o.get(v);if(!l||R===null||R.length===0||c&&!M)c?S(null):p();else{const L=c?0:r,U=L*4;let C=_.clippingState||null;m.value=C,C=S(R,x,U,y);for(let G=0;G!==U;++G)C[G]=i[G];_.clippingState=C,this.numIntersection=w?this.numPlanes:0,this.numPlanes+=L}};function p(){m.value!==i&&(m.value=i,m.needsUpdate=r>0),e.numPlanes=r,e.numIntersection=0}function S(v,x,y,R){const w=v!==null?v.length:0;let M=null;if(w!==0){if(M=m.value,R!==!0||M===null){const _=y+w*4,L=x.matrixWorldInverse;d.getNormalMatrix(L),(M===null||M.length<_)&&(M=new Float32Array(_));for(let U=0,C=y;U!==w;++U,C+=4)h.copy(v[U]).applyMatrix4(L,d),h.normal.toArray(M,C),M[C+3]=h.constant}m.value=M,m.needsUpdate=!0}return e.numPlanes=w,e.numIntersection=0,M}}function AT(o){let e=new WeakMap;function i(h,d){return d===Dh?h.mapping=Ss:d===Uh&&(h.mapping=xs),h}function r(h){if(h&&h.isTexture){const d=h.mapping;if(d===Dh||d===Uh)if(e.has(h)){const m=e.get(h).texture;return i(m,h.mapping)}else{const m=h.image;if(m&&m.height>0){const p=new AM(m.height);return p.fromEquirectangularTexture(o,h),e.set(h,p),h.addEventListener("dispose",l),i(p.texture,h.mapping)}else return null}}return h}function l(h){const d=h.target;d.removeEventListener("dispose",l);const m=e.get(d);m!==void 0&&(e.delete(d),m.dispose())}function c(){e=new WeakMap}return{get:r,dispose:c}}const ms=4,Y_=[.125,.215,.35,.446,.526,.582],_r=20,mh=new q0,j_=new Me;let gh=null,_h=0,vh=0,Sh=!1;const mr=(1+Math.sqrt(5))/2,ps=1/mr,Z_=[new Q(-mr,ps,0),new Q(mr,ps,0),new Q(-ps,0,mr),new Q(ps,0,mr),new Q(0,mr,-ps),new Q(0,mr,ps),new Q(-1,1,-1),new Q(1,1,-1),new Q(-1,1,1),new Q(1,1,1)],RT=new Q;class K_{constructor(e){this._renderer=e,this._pingPongRenderTarget=null,this._lodMax=0,this._cubeSize=0,this._lodPlanes=[],this._sizeLods=[],this._sigmas=[],this._blurMaterial=null,this._cubemapMaterial=null,this._equirectMaterial=null,this._compileMaterial(this._blurMaterial)}fromScene(e,i=0,r=.1,l=100,c={}){const{size:h=256,position:d=RT}=c;gh=this._renderer.getRenderTarget(),_h=this._renderer.getActiveCubeFace(),vh=this._renderer.getActiveMipmapLevel(),Sh=this._renderer.xr.enabled,this._renderer.xr.enabled=!1,this._setSize(h);const m=this._allocateTargets();return m.depthBuffer=!0,this._sceneToCubeUV(e,r,l,m,d),i>0&&this._blur(m,0,0,i),this._applyPMREM(m),this._cleanup(m),m}fromEquirectangular(e,i=null){return this._fromTexture(e,i)}fromCubemap(e,i=null){return this._fromTexture(e,i)}compileCubemapShader(){this._cubemapMaterial===null&&(this._cubemapMaterial=$_(),this._compileMaterial(this._cubemapMaterial))}compileEquirectangularShader(){this._equirectMaterial===null&&(this._equirectMaterial=J_(),this._compileMaterial(this._equirectMaterial))}dispose(){this._dispose(),this._cubemapMaterial!==null&&this._cubemapMaterial.dispose(),this._equirectMaterial!==null&&this._equirectMaterial.dispose()}_setSize(e){this._lodMax=Math.floor(Math.log2(e)),this._cubeSize=Math.pow(2,this._lodMax)}_dispose(){this._blurMaterial!==null&&this._blurMaterial.dispose(),this._pingPongRenderTarget!==null&&this._pingPongRenderTarget.dispose();for(let e=0;e<this._lodPlanes.length;e++)this._lodPlanes[e].dispose()}_cleanup(e){this._renderer.setRenderTarget(gh,_h,vh),this._renderer.xr.enabled=Sh,e.scissorTest=!1,du(e,0,0,e.width,e.height)}_fromTexture(e,i){e.mapping===Ss||e.mapping===xs?this._setSize(e.image.length===0?16:e.image[0].width||e.image[0].image.width):this._setSize(e.image.width/4),gh=this._renderer.getRenderTarget(),_h=this._renderer.getActiveCubeFace(),vh=this._renderer.getActiveMipmapLevel(),Sh=this._renderer.xr.enabled,this._renderer.xr.enabled=!1;const r=i||this._allocateTargets();return this._textureToCubeUV(e,r),this._applyPMREM(r),this._cleanup(r),r}_allocateTargets(){const e=3*Math.max(this._cubeSize,112),i=4*this._cubeSize,r={magFilter:wi,minFilter:wi,generateMipmaps:!1,type:Uo,format:Mi,colorSpace:Ms,depthBuffer:!1},l=Q_(e,i,r);if(this._pingPongRenderTarget===null||this._pingPongRenderTarget.width!==e||this._pingPongRenderTarget.height!==i){this._pingPongRenderTarget!==null&&this._dispose(),this._pingPongRenderTarget=Q_(e,i,r);const{_lodMax:c}=this;({sizeLods:this._sizeLods,lodPlanes:this._lodPlanes,sigmas:this._sigmas}=CT(c)),this._blurMaterial=wT(c,e,i)}return l}_compileMaterial(e){const i=new ui(this._lodPlanes[0],e);this._renderer.compile(i,mh)}_sceneToCubeUV(e,i,r,l,c){const m=new Jn(90,1,i,r),p=[1,-1,1,1,1,1],S=[1,1,1,-1,-1,-1],v=this._renderer,x=v.autoClear,y=v.toneMapping;v.getClearColor(j_),v.toneMapping=Ha,v.autoClear=!1;const R=new vd({name:"PMREM.Background",side:Gn,depthWrite:!1,depthTest:!1}),w=new ui(new Po,R);let M=!1;const _=e.background;_?_.isColor&&(R.color.copy(_),e.background=null,M=!0):(R.color.copy(j_),M=!0);for(let L=0;L<6;L++){const U=L%3;U===0?(m.up.set(0,p[L],0),m.position.set(c.x,c.y,c.z),m.lookAt(c.x+S[L],c.y,c.z)):U===1?(m.up.set(0,0,p[L]),m.position.set(c.x,c.y,c.z),m.lookAt(c.x,c.y+S[L],c.z)):(m.up.set(0,p[L],0),m.position.set(c.x,c.y,c.z),m.lookAt(c.x,c.y,c.z+S[L]));const C=this._cubeSize;du(l,U*C,L>2?C:0,C,C),v.setRenderTarget(l),M&&v.render(w,m),v.render(e,m)}w.geometry.dispose(),w.material.dispose(),v.toneMapping=y,v.autoClear=x,e.background=_}_textureToCubeUV(e,i){const r=this._renderer,l=e.mapping===Ss||e.mapping===xs;l?(this._cubemapMaterial===null&&(this._cubemapMaterial=$_()),this._cubemapMaterial.uniforms.flipEnvMap.value=e.isRenderTargetTexture===!1?-1:1):this._equirectMaterial===null&&(this._equirectMaterial=J_());const c=l?this._cubemapMaterial:this._equirectMaterial,h=new ui(this._lodPlanes[0],c),d=c.uniforms;d.envMap.value=e;const m=this._cubeSize;du(i,0,0,3*m,2*m),r.setRenderTarget(i),r.render(h,mh)}_applyPMREM(e){const i=this._renderer,r=i.autoClear;i.autoClear=!1;const l=this._lodPlanes.length;for(let c=1;c<l;c++){const h=Math.sqrt(this._sigmas[c]*this._sigmas[c]-this._sigmas[c-1]*this._sigmas[c-1]),d=Z_[(l-c-1)%Z_.length];this._blur(e,c-1,c,h,d)}i.autoClear=r}_blur(e,i,r,l,c){const h=this._pingPongRenderTarget;this._halfBlur(e,h,i,r,l,"latitudinal",c),this._halfBlur(h,e,r,r,l,"longitudinal",c)}_halfBlur(e,i,r,l,c,h,d){const m=this._renderer,p=this._blurMaterial;h!=="latitudinal"&&h!=="longitudinal"&&console.error("blur direction must be either latitudinal or longitudinal!");const S=3,v=new ui(this._lodPlanes[l],p),x=p.uniforms,y=this._sizeLods[r]-1,R=isFinite(c)?Math.PI/(2*y):2*Math.PI/(2*_r-1),w=c/R,M=isFinite(c)?1+Math.floor(S*w):_r;M>_r&&console.warn(`sigmaRadians, ${c}, is too large and will clip, as it requested ${M} samples when the maximum is set to ${_r}`);const _=[];let L=0;for(let O=0;O<_r;++O){const V=O/w,D=Math.exp(-V*V/2);_.push(D),O===0?L+=D:O<M&&(L+=2*D)}for(let O=0;O<_.length;O++)_[O]=_[O]/L;x.envMap.value=e.texture,x.samples.value=M,x.weights.value=_,x.latitudinal.value=h==="latitudinal",d&&(x.poleAxis.value=d);const{_lodMax:U}=this;x.dTheta.value=R,x.mipInt.value=U-r;const C=this._sizeLods[l],G=3*C*(l>U-ms?l-U+ms:0),I=4*(this._cubeSize-C);du(i,G,I,3*C,2*C),m.setRenderTarget(i),m.render(v,mh)}}function CT(o){const e=[],i=[],r=[];let l=o;const c=o-ms+1+Y_.length;for(let h=0;h<c;h++){const d=Math.pow(2,l);i.push(d);let m=1/d;h>o-ms?m=Y_[h-o+ms-1]:h===0&&(m=0),r.push(m);const p=1/(d-2),S=-p,v=1+p,x=[S,S,v,S,v,v,S,S,v,v,S,v],y=6,R=6,w=3,M=2,_=1,L=new Float32Array(w*R*y),U=new Float32Array(M*R*y),C=new Float32Array(_*R*y);for(let I=0;I<y;I++){const O=I%3*2/3-1,V=I>2?0:-1,D=[O,V,0,O+2/3,V,0,O+2/3,V+1,0,O,V,0,O+2/3,V+1,0,O,V+1,0];L.set(D,w*R*I),U.set(x,M*R*I);const b=[I,I,I,I,I,I];C.set(b,_*R*I)}const G=new Ni;G.setAttribute("position",new Di(L,w)),G.setAttribute("uv",new Di(U,M)),G.setAttribute("faceIndex",new Di(C,_)),e.push(G),l>ms&&l--}return{lodPlanes:e,sizeLods:i,sigmas:r}}function Q_(o,e,i){const r=new Mr(o,e,i);return r.texture.mapping=Au,r.texture.name="PMREM.cubeUv",r.scissorTest=!0,r}function du(o,e,i,r,l){o.viewport.set(e,i,r,l),o.scissor.set(e,i,r,l)}function wT(o,e,i){const r=new Float32Array(_r),l=new Q(0,1,0);return new Va({name:"SphericalGaussianBlur",defines:{n:_r,CUBEUV_TEXEL_WIDTH:1/e,CUBEUV_TEXEL_HEIGHT:1/i,CUBEUV_MAX_MIP:`${o}.0`},uniforms:{envMap:{value:null},samples:{value:1},weights:{value:r},latitudinal:{value:!1},dTheta:{value:0},mipInt:{value:0},poleAxis:{value:l}},vertexShader:Ad(),fragmentShader:`

			precision mediump float;
			precision mediump int;

			varying vec3 vOutputDirection;

			uniform sampler2D envMap;
			uniform int samples;
			uniform float weights[ n ];
			uniform bool latitudinal;
			uniform float dTheta;
			uniform float mipInt;
			uniform vec3 poleAxis;

			#define ENVMAP_TYPE_CUBE_UV
			#include <cube_uv_reflection_fragment>

			vec3 getSample( float theta, vec3 axis ) {

				float cosTheta = cos( theta );
				// Rodrigues' axis-angle rotation
				vec3 sampleDirection = vOutputDirection * cosTheta
					+ cross( axis, vOutputDirection ) * sin( theta )
					+ axis * dot( axis, vOutputDirection ) * ( 1.0 - cosTheta );

				return bilinearCubeUV( envMap, sampleDirection, mipInt );

			}

			void main() {

				vec3 axis = latitudinal ? poleAxis : cross( poleAxis, vOutputDirection );

				if ( all( equal( axis, vec3( 0.0 ) ) ) ) {

					axis = vec3( vOutputDirection.z, 0.0, - vOutputDirection.x );

				}

				axis = normalize( axis );

				gl_FragColor = vec4( 0.0, 0.0, 0.0, 1.0 );
				gl_FragColor.rgb += weights[ 0 ] * getSample( 0.0, axis );

				for ( int i = 1; i < n; i++ ) {

					if ( i >= samples ) {

						break;

					}

					float theta = dTheta * float( i );
					gl_FragColor.rgb += weights[ i ] * getSample( -1.0 * theta, axis );
					gl_FragColor.rgb += weights[ i ] * getSample( theta, axis );

				}

			}
		`,blending:Fa,depthTest:!1,depthWrite:!1})}function J_(){return new Va({name:"EquirectangularToCubeUV",uniforms:{envMap:{value:null}},vertexShader:Ad(),fragmentShader:`

			precision mediump float;
			precision mediump int;

			varying vec3 vOutputDirection;

			uniform sampler2D envMap;

			#include <common>

			void main() {

				vec3 outputDirection = normalize( vOutputDirection );
				vec2 uv = equirectUv( outputDirection );

				gl_FragColor = vec4( texture2D ( envMap, uv ).rgb, 1.0 );

			}
		`,blending:Fa,depthTest:!1,depthWrite:!1})}function $_(){return new Va({name:"CubemapToCubeUV",uniforms:{envMap:{value:null},flipEnvMap:{value:-1}},vertexShader:Ad(),fragmentShader:`

			precision mediump float;
			precision mediump int;

			uniform float flipEnvMap;

			varying vec3 vOutputDirection;

			uniform samplerCube envMap;

			void main() {

				gl_FragColor = textureCube( envMap, vec3( flipEnvMap * vOutputDirection.x, vOutputDirection.yz ) );

			}
		`,blending:Fa,depthTest:!1,depthWrite:!1})}function Ad(){return`

		precision mediump float;
		precision mediump int;

		attribute float faceIndex;

		varying vec3 vOutputDirection;

		// RH coordinate system; PMREM face-indexing convention
		vec3 getDirection( vec2 uv, float face ) {

			uv = 2.0 * uv - 1.0;

			vec3 direction = vec3( uv, 1.0 );

			if ( face == 0.0 ) {

				direction = direction.zyx; // ( 1, v, u ) pos x

			} else if ( face == 1.0 ) {

				direction = direction.xzy;
				direction.xz *= -1.0; // ( -u, 1, -v ) pos y

			} else if ( face == 2.0 ) {

				direction.x *= -1.0; // ( -u, v, 1 ) pos z

			} else if ( face == 3.0 ) {

				direction = direction.zyx;
				direction.xz *= -1.0; // ( -1, v, -u ) neg x

			} else if ( face == 4.0 ) {

				direction = direction.xzy;
				direction.xy *= -1.0; // ( -u, -1, v ) neg y

			} else if ( face == 5.0 ) {

				direction.z *= -1.0; // ( u, v, -1 ) neg z

			}

			return direction;

		}

		void main() {

			vOutputDirection = getDirection( uv, faceIndex );
			gl_Position = vec4( position, 1.0 );

		}
	`}function DT(o){let e=new WeakMap,i=null;function r(d){if(d&&d.isTexture){const m=d.mapping,p=m===Dh||m===Uh,S=m===Ss||m===xs;if(p||S){let v=e.get(d);const x=v!==void 0?v.texture.pmremVersion:0;if(d.isRenderTargetTexture&&d.pmremVersion!==x)return i===null&&(i=new K_(o)),v=p?i.fromEquirectangular(d,v):i.fromCubemap(d,v),v.texture.pmremVersion=d.pmremVersion,e.set(d,v),v.texture;if(v!==void 0)return v.texture;{const y=d.image;return p&&y&&y.height>0||S&&y&&l(y)?(i===null&&(i=new K_(o)),v=p?i.fromEquirectangular(d):i.fromCubemap(d),v.texture.pmremVersion=d.pmremVersion,e.set(d,v),d.addEventListener("dispose",c),v.texture):null}}}return d}function l(d){let m=0;const p=6;for(let S=0;S<p;S++)d[S]!==void 0&&m++;return m===p}function c(d){const m=d.target;m.removeEventListener("dispose",c);const p=e.get(m);p!==void 0&&(e.delete(m),p.dispose())}function h(){e=new WeakMap,i!==null&&(i.dispose(),i=null)}return{get:r,dispose:h}}function UT(o){const e={};function i(r){if(e[r]!==void 0)return e[r];let l;switch(r){case"WEBGL_depth_texture":l=o.getExtension("WEBGL_depth_texture")||o.getExtension("MOZ_WEBGL_depth_texture")||o.getExtension("WEBKIT_WEBGL_depth_texture");break;case"EXT_texture_filter_anisotropic":l=o.getExtension("EXT_texture_filter_anisotropic")||o.getExtension("MOZ_EXT_texture_filter_anisotropic")||o.getExtension("WEBKIT_EXT_texture_filter_anisotropic");break;case"WEBGL_compressed_texture_s3tc":l=o.getExtension("WEBGL_compressed_texture_s3tc")||o.getExtension("MOZ_WEBGL_compressed_texture_s3tc")||o.getExtension("WEBKIT_WEBGL_compressed_texture_s3tc");break;case"WEBGL_compressed_texture_pvrtc":l=o.getExtension("WEBGL_compressed_texture_pvrtc")||o.getExtension("WEBKIT_WEBGL_compressed_texture_pvrtc");break;default:l=o.getExtension(r)}return e[r]=l,l}return{has:function(r){return i(r)!==null},init:function(){i("EXT_color_buffer_float"),i("WEBGL_clip_cull_distance"),i("OES_texture_float_linear"),i("EXT_color_buffer_half_float"),i("WEBGL_multisampled_render_to_texture"),i("WEBGL_render_shared_exponent")},get:function(r){const l=i(r);return l===null&&Mu("THREE.WebGLRenderer: "+r+" extension not supported."),l}}}function LT(o,e,i,r){const l={},c=new WeakMap;function h(v){const x=v.target;x.index!==null&&e.remove(x.index);for(const R in x.attributes)e.remove(x.attributes[R]);x.removeEventListener("dispose",h),delete l[x.id];const y=c.get(x);y&&(e.remove(y),c.delete(x)),r.releaseStatesOfGeometry(x),x.isInstancedBufferGeometry===!0&&delete x._maxInstanceCount,i.memory.geometries--}function d(v,x){return l[x.id]===!0||(x.addEventListener("dispose",h),l[x.id]=!0,i.memory.geometries++),x}function m(v){const x=v.attributes;for(const y in x)e.update(x[y],o.ARRAY_BUFFER)}function p(v){const x=[],y=v.index,R=v.attributes.position;let w=0;if(y!==null){const L=y.array;w=y.version;for(let U=0,C=L.length;U<C;U+=3){const G=L[U+0],I=L[U+1],O=L[U+2];x.push(G,I,I,O,O,G)}}else if(R!==void 0){const L=R.array;w=R.version;for(let U=0,C=L.length/3-1;U<C;U+=3){const G=U+0,I=U+1,O=U+2;x.push(G,I,I,O,O,G)}}else return;const M=new(z0(x)?H0:F0)(x,1);M.version=w;const _=c.get(v);_&&e.remove(_),c.set(v,M)}function S(v){const x=c.get(v);if(x){const y=v.index;y!==null&&x.version<y.version&&p(v)}else p(v);return c.get(v)}return{get:d,update:m,getWireframeAttribute:S}}function NT(o,e,i){let r;function l(x){r=x}let c,h;function d(x){c=x.type,h=x.bytesPerElement}function m(x,y){o.drawElements(r,y,c,x*h),i.update(y,r,1)}function p(x,y,R){R!==0&&(o.drawElementsInstanced(r,y,c,x*h,R),i.update(y,r,R))}function S(x,y,R){if(R===0)return;e.get("WEBGL_multi_draw").multiDrawElementsWEBGL(r,y,0,c,x,0,R);let M=0;for(let _=0;_<R;_++)M+=y[_];i.update(M,r,1)}function v(x,y,R,w){if(R===0)return;const M=e.get("WEBGL_multi_draw");if(M===null)for(let _=0;_<x.length;_++)p(x[_]/h,y[_],w[_]);else{M.multiDrawElementsInstancedWEBGL(r,y,0,c,x,0,w,0,R);let _=0;for(let L=0;L<R;L++)_+=y[L]*w[L];i.update(_,r,1)}}this.setMode=l,this.setIndex=d,this.render=m,this.renderInstances=p,this.renderMultiDraw=S,this.renderMultiDrawInstances=v}function OT(o){const e={geometries:0,textures:0},i={frame:0,calls:0,triangles:0,points:0,lines:0};function r(c,h,d){switch(i.calls++,h){case o.TRIANGLES:i.triangles+=d*(c/3);break;case o.LINES:i.lines+=d*(c/2);break;case o.LINE_STRIP:i.lines+=d*(c-1);break;case o.LINE_LOOP:i.lines+=d*c;break;case o.POINTS:i.points+=d*c;break;default:console.error("THREE.WebGLInfo: Unknown draw mode:",h);break}}function l(){i.calls=0,i.triangles=0,i.points=0,i.lines=0}return{memory:e,render:i,programs:null,autoReset:!0,reset:l,update:r}}function zT(o,e,i){const r=new WeakMap,l=new Ie;function c(h,d,m){const p=h.morphTargetInfluences,S=d.morphAttributes.position||d.morphAttributes.normal||d.morphAttributes.color,v=S!==void 0?S.length:0;let x=r.get(d);if(x===void 0||x.count!==v){let b=function(){V.dispose(),r.delete(d),d.removeEventListener("dispose",b)};var y=b;x!==void 0&&x.texture.dispose();const R=d.morphAttributes.position!==void 0,w=d.morphAttributes.normal!==void 0,M=d.morphAttributes.color!==void 0,_=d.morphAttributes.position||[],L=d.morphAttributes.normal||[],U=d.morphAttributes.color||[];let C=0;R===!0&&(C=1),w===!0&&(C=2),M===!0&&(C=3);let G=d.attributes.position.count*C,I=1;G>e.maxTextureSize&&(I=Math.ceil(G/e.maxTextureSize),G=e.maxTextureSize);const O=new Float32Array(G*I*4*v),V=new P0(O,G,I,v);V.type=sa,V.needsUpdate=!0;const D=C*4;for(let B=0;B<v;B++){const rt=_[B],st=L[B],dt=U[B],pt=G*I*4*B;for(let P=0;P<rt.count;P++){const Y=P*D;R===!0&&(l.fromBufferAttribute(rt,P),O[pt+Y+0]=l.x,O[pt+Y+1]=l.y,O[pt+Y+2]=l.z,O[pt+Y+3]=0),w===!0&&(l.fromBufferAttribute(st,P),O[pt+Y+4]=l.x,O[pt+Y+5]=l.y,O[pt+Y+6]=l.z,O[pt+Y+7]=0),M===!0&&(l.fromBufferAttribute(dt,P),O[pt+Y+8]=l.x,O[pt+Y+9]=l.y,O[pt+Y+10]=l.z,O[pt+Y+11]=dt.itemSize===4?l.w:1)}}x={count:v,texture:V,size:new ye(G,I)},r.set(d,x),d.addEventListener("dispose",b)}if(h.isInstancedMesh===!0&&h.morphTexture!==null)m.getUniforms().setValue(o,"morphTexture",h.morphTexture,i);else{let R=0;for(let M=0;M<p.length;M++)R+=p[M];const w=d.morphTargetsRelative?1:1-R;m.getUniforms().setValue(o,"morphTargetBaseInfluence",w),m.getUniforms().setValue(o,"morphTargetInfluences",p)}m.getUniforms().setValue(o,"morphTargetsTexture",x.texture,i),m.getUniforms().setValue(o,"morphTargetsTextureSize",x.size)}return{update:c}}function PT(o,e,i,r){let l=new WeakMap;function c(m){const p=r.render.frame,S=m.geometry,v=e.get(m,S);if(l.get(v)!==p&&(e.update(v),l.set(v,p)),m.isInstancedMesh&&(m.hasEventListener("dispose",d)===!1&&m.addEventListener("dispose",d),l.get(m)!==p&&(i.update(m.instanceMatrix,o.ARRAY_BUFFER),m.instanceColor!==null&&i.update(m.instanceColor,o.ARRAY_BUFFER),l.set(m,p))),m.isSkinnedMesh){const x=m.skeleton;l.get(x)!==p&&(x.update(),l.set(x,p))}return v}function h(){l=new WeakMap}function d(m){const p=m.target;p.removeEventListener("dispose",d),i.remove(p.instanceMatrix),p.instanceColor!==null&&i.remove(p.instanceColor)}return{update:c,dispose:h}}const j0=new Vn,t0=new k0(1,1),Z0=new P0,K0=new lM,Q0=new X0,e0=[],n0=[],i0=new Float32Array(16),a0=new Float32Array(9),r0=new Float32Array(4);function Ts(o,e,i){const r=o[0];if(r<=0||r>0)return o;const l=e*i;let c=e0[l];if(c===void 0&&(c=new Float32Array(l),e0[l]=c),e!==0){r.toArray(c,0);for(let h=1,d=0;h!==e;++h)d+=i,o[h].toArray(c,d)}return c}function un(o,e){if(o.length!==e.length)return!1;for(let i=0,r=o.length;i<r;i++)if(o[i]!==e[i])return!1;return!0}function cn(o,e){for(let i=0,r=e.length;i<r;i++)o[i]=e[i]}function Cu(o,e){let i=n0[e];i===void 0&&(i=new Int32Array(e),n0[e]=i);for(let r=0;r!==e;++r)i[r]=o.allocateTextureUnit();return i}function BT(o,e){const i=this.cache;i[0]!==e&&(o.uniform1f(this.addr,e),i[0]=e)}function IT(o,e){const i=this.cache;if(e.x!==void 0)(i[0]!==e.x||i[1]!==e.y)&&(o.uniform2f(this.addr,e.x,e.y),i[0]=e.x,i[1]=e.y);else{if(un(i,e))return;o.uniform2fv(this.addr,e),cn(i,e)}}function FT(o,e){const i=this.cache;if(e.x!==void 0)(i[0]!==e.x||i[1]!==e.y||i[2]!==e.z)&&(o.uniform3f(this.addr,e.x,e.y,e.z),i[0]=e.x,i[1]=e.y,i[2]=e.z);else if(e.r!==void 0)(i[0]!==e.r||i[1]!==e.g||i[2]!==e.b)&&(o.uniform3f(this.addr,e.r,e.g,e.b),i[0]=e.r,i[1]=e.g,i[2]=e.b);else{if(un(i,e))return;o.uniform3fv(this.addr,e),cn(i,e)}}function HT(o,e){const i=this.cache;if(e.x!==void 0)(i[0]!==e.x||i[1]!==e.y||i[2]!==e.z||i[3]!==e.w)&&(o.uniform4f(this.addr,e.x,e.y,e.z,e.w),i[0]=e.x,i[1]=e.y,i[2]=e.z,i[3]=e.w);else{if(un(i,e))return;o.uniform4fv(this.addr,e),cn(i,e)}}function GT(o,e){const i=this.cache,r=e.elements;if(r===void 0){if(un(i,e))return;o.uniformMatrix2fv(this.addr,!1,e),cn(i,e)}else{if(un(i,r))return;r0.set(r),o.uniformMatrix2fv(this.addr,!1,r0),cn(i,r)}}function VT(o,e){const i=this.cache,r=e.elements;if(r===void 0){if(un(i,e))return;o.uniformMatrix3fv(this.addr,!1,e),cn(i,e)}else{if(un(i,r))return;a0.set(r),o.uniformMatrix3fv(this.addr,!1,a0),cn(i,r)}}function XT(o,e){const i=this.cache,r=e.elements;if(r===void 0){if(un(i,e))return;o.uniformMatrix4fv(this.addr,!1,e),cn(i,e)}else{if(un(i,r))return;i0.set(r),o.uniformMatrix4fv(this.addr,!1,i0),cn(i,r)}}function kT(o,e){const i=this.cache;i[0]!==e&&(o.uniform1i(this.addr,e),i[0]=e)}function WT(o,e){const i=this.cache;if(e.x!==void 0)(i[0]!==e.x||i[1]!==e.y)&&(o.uniform2i(this.addr,e.x,e.y),i[0]=e.x,i[1]=e.y);else{if(un(i,e))return;o.uniform2iv(this.addr,e),cn(i,e)}}function qT(o,e){const i=this.cache;if(e.x!==void 0)(i[0]!==e.x||i[1]!==e.y||i[2]!==e.z)&&(o.uniform3i(this.addr,e.x,e.y,e.z),i[0]=e.x,i[1]=e.y,i[2]=e.z);else{if(un(i,e))return;o.uniform3iv(this.addr,e),cn(i,e)}}function YT(o,e){const i=this.cache;if(e.x!==void 0)(i[0]!==e.x||i[1]!==e.y||i[2]!==e.z||i[3]!==e.w)&&(o.uniform4i(this.addr,e.x,e.y,e.z,e.w),i[0]=e.x,i[1]=e.y,i[2]=e.z,i[3]=e.w);else{if(un(i,e))return;o.uniform4iv(this.addr,e),cn(i,e)}}function jT(o,e){const i=this.cache;i[0]!==e&&(o.uniform1ui(this.addr,e),i[0]=e)}function ZT(o,e){const i=this.cache;if(e.x!==void 0)(i[0]!==e.x||i[1]!==e.y)&&(o.uniform2ui(this.addr,e.x,e.y),i[0]=e.x,i[1]=e.y);else{if(un(i,e))return;o.uniform2uiv(this.addr,e),cn(i,e)}}function KT(o,e){const i=this.cache;if(e.x!==void 0)(i[0]!==e.x||i[1]!==e.y||i[2]!==e.z)&&(o.uniform3ui(this.addr,e.x,e.y,e.z),i[0]=e.x,i[1]=e.y,i[2]=e.z);else{if(un(i,e))return;o.uniform3uiv(this.addr,e),cn(i,e)}}function QT(o,e){const i=this.cache;if(e.x!==void 0)(i[0]!==e.x||i[1]!==e.y||i[2]!==e.z||i[3]!==e.w)&&(o.uniform4ui(this.addr,e.x,e.y,e.z,e.w),i[0]=e.x,i[1]=e.y,i[2]=e.z,i[3]=e.w);else{if(un(i,e))return;o.uniform4uiv(this.addr,e),cn(i,e)}}function JT(o,e,i){const r=this.cache,l=i.allocateTextureUnit();r[0]!==l&&(o.uniform1i(this.addr,l),r[0]=l);let c;this.type===o.SAMPLER_2D_SHADOW?(t0.compareFunction=O0,c=t0):c=j0,i.setTexture2D(e||c,l)}function $T(o,e,i){const r=this.cache,l=i.allocateTextureUnit();r[0]!==l&&(o.uniform1i(this.addr,l),r[0]=l),i.setTexture3D(e||K0,l)}function tb(o,e,i){const r=this.cache,l=i.allocateTextureUnit();r[0]!==l&&(o.uniform1i(this.addr,l),r[0]=l),i.setTextureCube(e||Q0,l)}function eb(o,e,i){const r=this.cache,l=i.allocateTextureUnit();r[0]!==l&&(o.uniform1i(this.addr,l),r[0]=l),i.setTexture2DArray(e||Z0,l)}function nb(o){switch(o){case 5126:return BT;case 35664:return IT;case 35665:return FT;case 35666:return HT;case 35674:return GT;case 35675:return VT;case 35676:return XT;case 5124:case 35670:return kT;case 35667:case 35671:return WT;case 35668:case 35672:return qT;case 35669:case 35673:return YT;case 5125:return jT;case 36294:return ZT;case 36295:return KT;case 36296:return QT;case 35678:case 36198:case 36298:case 36306:case 35682:return JT;case 35679:case 36299:case 36307:return $T;case 35680:case 36300:case 36308:case 36293:return tb;case 36289:case 36303:case 36311:case 36292:return eb}}function ib(o,e){o.uniform1fv(this.addr,e)}function ab(o,e){const i=Ts(e,this.size,2);o.uniform2fv(this.addr,i)}function rb(o,e){const i=Ts(e,this.size,3);o.uniform3fv(this.addr,i)}function sb(o,e){const i=Ts(e,this.size,4);o.uniform4fv(this.addr,i)}function ob(o,e){const i=Ts(e,this.size,4);o.uniformMatrix2fv(this.addr,!1,i)}function lb(o,e){const i=Ts(e,this.size,9);o.uniformMatrix3fv(this.addr,!1,i)}function ub(o,e){const i=Ts(e,this.size,16);o.uniformMatrix4fv(this.addr,!1,i)}function cb(o,e){o.uniform1iv(this.addr,e)}function fb(o,e){o.uniform2iv(this.addr,e)}function hb(o,e){o.uniform3iv(this.addr,e)}function db(o,e){o.uniform4iv(this.addr,e)}function pb(o,e){o.uniform1uiv(this.addr,e)}function mb(o,e){o.uniform2uiv(this.addr,e)}function gb(o,e){o.uniform3uiv(this.addr,e)}function _b(o,e){o.uniform4uiv(this.addr,e)}function vb(o,e,i){const r=this.cache,l=e.length,c=Cu(i,l);un(r,c)||(o.uniform1iv(this.addr,c),cn(r,c));for(let h=0;h!==l;++h)i.setTexture2D(e[h]||j0,c[h])}function Sb(o,e,i){const r=this.cache,l=e.length,c=Cu(i,l);un(r,c)||(o.uniform1iv(this.addr,c),cn(r,c));for(let h=0;h!==l;++h)i.setTexture3D(e[h]||K0,c[h])}function xb(o,e,i){const r=this.cache,l=e.length,c=Cu(i,l);un(r,c)||(o.uniform1iv(this.addr,c),cn(r,c));for(let h=0;h!==l;++h)i.setTextureCube(e[h]||Q0,c[h])}function Mb(o,e,i){const r=this.cache,l=e.length,c=Cu(i,l);un(r,c)||(o.uniform1iv(this.addr,c),cn(r,c));for(let h=0;h!==l;++h)i.setTexture2DArray(e[h]||Z0,c[h])}function yb(o){switch(o){case 5126:return ib;case 35664:return ab;case 35665:return rb;case 35666:return sb;case 35674:return ob;case 35675:return lb;case 35676:return ub;case 5124:case 35670:return cb;case 35667:case 35671:return fb;case 35668:case 35672:return hb;case 35669:case 35673:return db;case 5125:return pb;case 36294:return mb;case 36295:return gb;case 36296:return _b;case 35678:case 36198:case 36298:case 36306:case 35682:return vb;case 35679:case 36299:case 36307:return Sb;case 35680:case 36300:case 36308:case 36293:return xb;case 36289:case 36303:case 36311:case 36292:return Mb}}class Eb{constructor(e,i,r){this.id=e,this.addr=r,this.cache=[],this.type=i.type,this.setValue=nb(i.type)}}class Tb{constructor(e,i,r){this.id=e,this.addr=r,this.cache=[],this.type=i.type,this.size=i.size,this.setValue=yb(i.type)}}class bb{constructor(e){this.id=e,this.seq=[],this.map={}}setValue(e,i,r){const l=this.seq;for(let c=0,h=l.length;c!==h;++c){const d=l[c];d.setValue(e,i[d.id],r)}}}const xh=/(\w+)(\])?(\[|\.)?/g;function s0(o,e){o.seq.push(e),o.map[e.id]=e}function Ab(o,e,i){const r=o.name,l=r.length;for(xh.lastIndex=0;;){const c=xh.exec(r),h=xh.lastIndex;let d=c[1];const m=c[2]==="]",p=c[3];if(m&&(d=d|0),p===void 0||p==="["&&h+2===l){s0(i,p===void 0?new Eb(d,o,e):new Tb(d,o,e));break}else{let v=i.map[d];v===void 0&&(v=new bb(d),s0(i,v)),i=v}}}class yu{constructor(e,i){this.seq=[],this.map={};const r=e.getProgramParameter(i,e.ACTIVE_UNIFORMS);for(let l=0;l<r;++l){const c=e.getActiveUniform(i,l),h=e.getUniformLocation(i,c.name);Ab(c,h,this)}}setValue(e,i,r,l){const c=this.map[i];c!==void 0&&c.setValue(e,r,l)}setOptional(e,i,r){const l=i[r];l!==void 0&&this.setValue(e,r,l)}static upload(e,i,r,l){for(let c=0,h=i.length;c!==h;++c){const d=i[c],m=r[d.id];m.needsUpdate!==!1&&d.setValue(e,m.value,l)}}static seqWithValue(e,i){const r=[];for(let l=0,c=e.length;l!==c;++l){const h=e[l];h.id in i&&r.push(h)}return r}}function o0(o,e,i){const r=o.createShader(e);return o.shaderSource(r,i),o.compileShader(r),r}const Rb=37297;let Cb=0;function wb(o,e){const i=o.split(`
`),r=[],l=Math.max(e-6,0),c=Math.min(e+6,i.length);for(let h=l;h<c;h++){const d=h+1;r.push(`${d===e?">":" "} ${d}: ${i[h]}`)}return r.join(`
`)}const l0=new oe;function Db(o){Re._getMatrix(l0,Re.workingColorSpace,o);const e=`mat3( ${l0.elements.map(i=>i.toFixed(4))} )`;switch(Re.getTransfer(o)){case Eu:return[e,"LinearTransferOETF"];case Be:return[e,"sRGBTransferOETF"];default:return console.warn("THREE.WebGLProgram: Unsupported color space: ",o),[e,"LinearTransferOETF"]}}function u0(o,e,i){const r=o.getShaderParameter(e,o.COMPILE_STATUS),l=o.getShaderInfoLog(e).trim();if(r&&l==="")return"";const c=/ERROR: 0:(\d+)/.exec(l);if(c){const h=parseInt(c[1]);return i.toUpperCase()+`

`+l+`

`+wb(o.getShaderSource(e),h)}else return l}function Ub(o,e){const i=Db(e);return[`vec4 ${o}( vec4 value ) {`,`	return ${i[1]}( vec4( value.rgb * ${i[0]}, value.a ) );`,"}"].join(`
`)}function Lb(o,e){let i;switch(e){case zx:i="Linear";break;case Px:i="Reinhard";break;case Bx:i="Cineon";break;case E0:i="ACESFilmic";break;case Fx:i="AgX";break;case Hx:i="Neutral";break;case Ix:i="Custom";break;default:console.warn("THREE.WebGLProgram: Unsupported toneMapping:",e),i="Linear"}return"vec3 "+o+"( vec3 color ) { return "+i+"ToneMapping( color ); }"}const pu=new Q;function Nb(){Re.getLuminanceCoefficients(pu);const o=pu.x.toFixed(4),e=pu.y.toFixed(4),i=pu.z.toFixed(4);return["float luminance( const in vec3 rgb ) {",`	const vec3 weights = vec3( ${o}, ${e}, ${i} );`,"	return dot( weights, rgb );","}"].join(`
`)}function Ob(o){return[o.extensionClipCullDistance?"#extension GL_ANGLE_clip_cull_distance : require":"",o.extensionMultiDraw?"#extension GL_ANGLE_multi_draw : require":""].filter(Ao).join(`
`)}function zb(o){const e=[];for(const i in o){const r=o[i];r!==!1&&e.push("#define "+i+" "+r)}return e.join(`
`)}function Pb(o,e){const i={},r=o.getProgramParameter(e,o.ACTIVE_ATTRIBUTES);for(let l=0;l<r;l++){const c=o.getActiveAttrib(e,l),h=c.name;let d=1;c.type===o.FLOAT_MAT2&&(d=2),c.type===o.FLOAT_MAT3&&(d=3),c.type===o.FLOAT_MAT4&&(d=4),i[h]={type:c.type,location:o.getAttribLocation(e,h),locationSize:d}}return i}function Ao(o){return o!==""}function c0(o,e){const i=e.numSpotLightShadows+e.numSpotLightMaps-e.numSpotLightShadowsWithMaps;return o.replace(/NUM_DIR_LIGHTS/g,e.numDirLights).replace(/NUM_SPOT_LIGHTS/g,e.numSpotLights).replace(/NUM_SPOT_LIGHT_MAPS/g,e.numSpotLightMaps).replace(/NUM_SPOT_LIGHT_COORDS/g,i).replace(/NUM_RECT_AREA_LIGHTS/g,e.numRectAreaLights).replace(/NUM_POINT_LIGHTS/g,e.numPointLights).replace(/NUM_HEMI_LIGHTS/g,e.numHemiLights).replace(/NUM_DIR_LIGHT_SHADOWS/g,e.numDirLightShadows).replace(/NUM_SPOT_LIGHT_SHADOWS_WITH_MAPS/g,e.numSpotLightShadowsWithMaps).replace(/NUM_SPOT_LIGHT_SHADOWS/g,e.numSpotLightShadows).replace(/NUM_POINT_LIGHT_SHADOWS/g,e.numPointLightShadows)}function f0(o,e){return o.replace(/NUM_CLIPPING_PLANES/g,e.numClippingPlanes).replace(/UNION_CLIPPING_PLANES/g,e.numClippingPlanes-e.numClipIntersection)}const Bb=/^[ \t]*#include +<([\w\d./]+)>/gm;function od(o){return o.replace(Bb,Fb)}const Ib=new Map;function Fb(o,e){let i=le[e];if(i===void 0){const r=Ib.get(e);if(r!==void 0)i=le[r],console.warn('THREE.WebGLRenderer: Shader chunk "%s" has been deprecated. Use "%s" instead.',e,r);else throw new Error("Can not resolve #include <"+e+">")}return od(i)}const Hb=/#pragma unroll_loop_start\s+for\s*\(\s*int\s+i\s*=\s*(\d+)\s*;\s*i\s*<\s*(\d+)\s*;\s*i\s*\+\+\s*\)\s*{([\s\S]+?)}\s+#pragma unroll_loop_end/g;function h0(o){return o.replace(Hb,Gb)}function Gb(o,e,i,r){let l="";for(let c=parseInt(e);c<parseInt(i);c++)l+=r.replace(/\[\s*i\s*\]/g,"[ "+c+" ]").replace(/UNROLLED_LOOP_INDEX/g,c);return l}function d0(o){let e=`precision ${o.precision} float;
	precision ${o.precision} int;
	precision ${o.precision} sampler2D;
	precision ${o.precision} samplerCube;
	precision ${o.precision} sampler3D;
	precision ${o.precision} sampler2DArray;
	precision ${o.precision} sampler2DShadow;
	precision ${o.precision} samplerCubeShadow;
	precision ${o.precision} sampler2DArrayShadow;
	precision ${o.precision} isampler2D;
	precision ${o.precision} isampler3D;
	precision ${o.precision} isamplerCube;
	precision ${o.precision} isampler2DArray;
	precision ${o.precision} usampler2D;
	precision ${o.precision} usampler3D;
	precision ${o.precision} usamplerCube;
	precision ${o.precision} usampler2DArray;
	`;return o.precision==="highp"?e+=`
#define HIGH_PRECISION`:o.precision==="mediump"?e+=`
#define MEDIUM_PRECISION`:o.precision==="lowp"&&(e+=`
#define LOW_PRECISION`),e}function Vb(o){let e="SHADOWMAP_TYPE_BASIC";return o.shadowMapType===x0?e="SHADOWMAP_TYPE_PCF":o.shadowMapType===M0?e="SHADOWMAP_TYPE_PCF_SOFT":o.shadowMapType===ia&&(e="SHADOWMAP_TYPE_VSM"),e}function Xb(o){let e="ENVMAP_TYPE_CUBE";if(o.envMap)switch(o.envMapMode){case Ss:case xs:e="ENVMAP_TYPE_CUBE";break;case Au:e="ENVMAP_TYPE_CUBE_UV";break}return e}function kb(o){let e="ENVMAP_MODE_REFLECTION";if(o.envMap)switch(o.envMapMode){case xs:e="ENVMAP_MODE_REFRACTION";break}return e}function Wb(o){let e="ENVMAP_BLENDING_NONE";if(o.envMap)switch(o.combine){case y0:e="ENVMAP_BLENDING_MULTIPLY";break;case Nx:e="ENVMAP_BLENDING_MIX";break;case Ox:e="ENVMAP_BLENDING_ADD";break}return e}function qb(o){const e=o.envMapCubeUVHeight;if(e===null)return null;const i=Math.log2(e)-2,r=1/e;return{texelWidth:1/(3*Math.max(Math.pow(2,i),112)),texelHeight:r,maxMip:i}}function Yb(o,e,i,r){const l=o.getContext(),c=i.defines;let h=i.vertexShader,d=i.fragmentShader;const m=Vb(i),p=Xb(i),S=kb(i),v=Wb(i),x=qb(i),y=Ob(i),R=zb(c),w=l.createProgram();let M,_,L=i.glslVersion?"#version "+i.glslVersion+`
`:"";i.isRawShaderMaterial?(M=["#define SHADER_TYPE "+i.shaderType,"#define SHADER_NAME "+i.shaderName,R].filter(Ao).join(`
`),M.length>0&&(M+=`
`),_=["#define SHADER_TYPE "+i.shaderType,"#define SHADER_NAME "+i.shaderName,R].filter(Ao).join(`
`),_.length>0&&(_+=`
`)):(M=[d0(i),"#define SHADER_TYPE "+i.shaderType,"#define SHADER_NAME "+i.shaderName,R,i.extensionClipCullDistance?"#define USE_CLIP_DISTANCE":"",i.batching?"#define USE_BATCHING":"",i.batchingColor?"#define USE_BATCHING_COLOR":"",i.instancing?"#define USE_INSTANCING":"",i.instancingColor?"#define USE_INSTANCING_COLOR":"",i.instancingMorph?"#define USE_INSTANCING_MORPH":"",i.useFog&&i.fog?"#define USE_FOG":"",i.useFog&&i.fogExp2?"#define FOG_EXP2":"",i.map?"#define USE_MAP":"",i.envMap?"#define USE_ENVMAP":"",i.envMap?"#define "+S:"",i.lightMap?"#define USE_LIGHTMAP":"",i.aoMap?"#define USE_AOMAP":"",i.bumpMap?"#define USE_BUMPMAP":"",i.normalMap?"#define USE_NORMALMAP":"",i.normalMapObjectSpace?"#define USE_NORMALMAP_OBJECTSPACE":"",i.normalMapTangentSpace?"#define USE_NORMALMAP_TANGENTSPACE":"",i.displacementMap?"#define USE_DISPLACEMENTMAP":"",i.emissiveMap?"#define USE_EMISSIVEMAP":"",i.anisotropy?"#define USE_ANISOTROPY":"",i.anisotropyMap?"#define USE_ANISOTROPYMAP":"",i.clearcoatMap?"#define USE_CLEARCOATMAP":"",i.clearcoatRoughnessMap?"#define USE_CLEARCOAT_ROUGHNESSMAP":"",i.clearcoatNormalMap?"#define USE_CLEARCOAT_NORMALMAP":"",i.iridescenceMap?"#define USE_IRIDESCENCEMAP":"",i.iridescenceThicknessMap?"#define USE_IRIDESCENCE_THICKNESSMAP":"",i.specularMap?"#define USE_SPECULARMAP":"",i.specularColorMap?"#define USE_SPECULAR_COLORMAP":"",i.specularIntensityMap?"#define USE_SPECULAR_INTENSITYMAP":"",i.roughnessMap?"#define USE_ROUGHNESSMAP":"",i.metalnessMap?"#define USE_METALNESSMAP":"",i.alphaMap?"#define USE_ALPHAMAP":"",i.alphaHash?"#define USE_ALPHAHASH":"",i.transmission?"#define USE_TRANSMISSION":"",i.transmissionMap?"#define USE_TRANSMISSIONMAP":"",i.thicknessMap?"#define USE_THICKNESSMAP":"",i.sheenColorMap?"#define USE_SHEEN_COLORMAP":"",i.sheenRoughnessMap?"#define USE_SHEEN_ROUGHNESSMAP":"",i.mapUv?"#define MAP_UV "+i.mapUv:"",i.alphaMapUv?"#define ALPHAMAP_UV "+i.alphaMapUv:"",i.lightMapUv?"#define LIGHTMAP_UV "+i.lightMapUv:"",i.aoMapUv?"#define AOMAP_UV "+i.aoMapUv:"",i.emissiveMapUv?"#define EMISSIVEMAP_UV "+i.emissiveMapUv:"",i.bumpMapUv?"#define BUMPMAP_UV "+i.bumpMapUv:"",i.normalMapUv?"#define NORMALMAP_UV "+i.normalMapUv:"",i.displacementMapUv?"#define DISPLACEMENTMAP_UV "+i.displacementMapUv:"",i.metalnessMapUv?"#define METALNESSMAP_UV "+i.metalnessMapUv:"",i.roughnessMapUv?"#define ROUGHNESSMAP_UV "+i.roughnessMapUv:"",i.anisotropyMapUv?"#define ANISOTROPYMAP_UV "+i.anisotropyMapUv:"",i.clearcoatMapUv?"#define CLEARCOATMAP_UV "+i.clearcoatMapUv:"",i.clearcoatNormalMapUv?"#define CLEARCOAT_NORMALMAP_UV "+i.clearcoatNormalMapUv:"",i.clearcoatRoughnessMapUv?"#define CLEARCOAT_ROUGHNESSMAP_UV "+i.clearcoatRoughnessMapUv:"",i.iridescenceMapUv?"#define IRIDESCENCEMAP_UV "+i.iridescenceMapUv:"",i.iridescenceThicknessMapUv?"#define IRIDESCENCE_THICKNESSMAP_UV "+i.iridescenceThicknessMapUv:"",i.sheenColorMapUv?"#define SHEEN_COLORMAP_UV "+i.sheenColorMapUv:"",i.sheenRoughnessMapUv?"#define SHEEN_ROUGHNESSMAP_UV "+i.sheenRoughnessMapUv:"",i.specularMapUv?"#define SPECULARMAP_UV "+i.specularMapUv:"",i.specularColorMapUv?"#define SPECULAR_COLORMAP_UV "+i.specularColorMapUv:"",i.specularIntensityMapUv?"#define SPECULAR_INTENSITYMAP_UV "+i.specularIntensityMapUv:"",i.transmissionMapUv?"#define TRANSMISSIONMAP_UV "+i.transmissionMapUv:"",i.thicknessMapUv?"#define THICKNESSMAP_UV "+i.thicknessMapUv:"",i.vertexTangents&&i.flatShading===!1?"#define USE_TANGENT":"",i.vertexColors?"#define USE_COLOR":"",i.vertexAlphas?"#define USE_COLOR_ALPHA":"",i.vertexUv1s?"#define USE_UV1":"",i.vertexUv2s?"#define USE_UV2":"",i.vertexUv3s?"#define USE_UV3":"",i.pointsUvs?"#define USE_POINTS_UV":"",i.flatShading?"#define FLAT_SHADED":"",i.skinning?"#define USE_SKINNING":"",i.morphTargets?"#define USE_MORPHTARGETS":"",i.morphNormals&&i.flatShading===!1?"#define USE_MORPHNORMALS":"",i.morphColors?"#define USE_MORPHCOLORS":"",i.morphTargetsCount>0?"#define MORPHTARGETS_TEXTURE_STRIDE "+i.morphTextureStride:"",i.morphTargetsCount>0?"#define MORPHTARGETS_COUNT "+i.morphTargetsCount:"",i.doubleSided?"#define DOUBLE_SIDED":"",i.flipSided?"#define FLIP_SIDED":"",i.shadowMapEnabled?"#define USE_SHADOWMAP":"",i.shadowMapEnabled?"#define "+m:"",i.sizeAttenuation?"#define USE_SIZEATTENUATION":"",i.numLightProbes>0?"#define USE_LIGHT_PROBES":"",i.logarithmicDepthBuffer?"#define USE_LOGDEPTHBUF":"",i.reverseDepthBuffer?"#define USE_REVERSEDEPTHBUF":"","uniform mat4 modelMatrix;","uniform mat4 modelViewMatrix;","uniform mat4 projectionMatrix;","uniform mat4 viewMatrix;","uniform mat3 normalMatrix;","uniform vec3 cameraPosition;","uniform bool isOrthographic;","#ifdef USE_INSTANCING","	attribute mat4 instanceMatrix;","#endif","#ifdef USE_INSTANCING_COLOR","	attribute vec3 instanceColor;","#endif","#ifdef USE_INSTANCING_MORPH","	uniform sampler2D morphTexture;","#endif","attribute vec3 position;","attribute vec3 normal;","attribute vec2 uv;","#ifdef USE_UV1","	attribute vec2 uv1;","#endif","#ifdef USE_UV2","	attribute vec2 uv2;","#endif","#ifdef USE_UV3","	attribute vec2 uv3;","#endif","#ifdef USE_TANGENT","	attribute vec4 tangent;","#endif","#if defined( USE_COLOR_ALPHA )","	attribute vec4 color;","#elif defined( USE_COLOR )","	attribute vec3 color;","#endif","#ifdef USE_SKINNING","	attribute vec4 skinIndex;","	attribute vec4 skinWeight;","#endif",`
`].filter(Ao).join(`
`),_=[d0(i),"#define SHADER_TYPE "+i.shaderType,"#define SHADER_NAME "+i.shaderName,R,i.useFog&&i.fog?"#define USE_FOG":"",i.useFog&&i.fogExp2?"#define FOG_EXP2":"",i.alphaToCoverage?"#define ALPHA_TO_COVERAGE":"",i.map?"#define USE_MAP":"",i.matcap?"#define USE_MATCAP":"",i.envMap?"#define USE_ENVMAP":"",i.envMap?"#define "+p:"",i.envMap?"#define "+S:"",i.envMap?"#define "+v:"",x?"#define CUBEUV_TEXEL_WIDTH "+x.texelWidth:"",x?"#define CUBEUV_TEXEL_HEIGHT "+x.texelHeight:"",x?"#define CUBEUV_MAX_MIP "+x.maxMip+".0":"",i.lightMap?"#define USE_LIGHTMAP":"",i.aoMap?"#define USE_AOMAP":"",i.bumpMap?"#define USE_BUMPMAP":"",i.normalMap?"#define USE_NORMALMAP":"",i.normalMapObjectSpace?"#define USE_NORMALMAP_OBJECTSPACE":"",i.normalMapTangentSpace?"#define USE_NORMALMAP_TANGENTSPACE":"",i.emissiveMap?"#define USE_EMISSIVEMAP":"",i.anisotropy?"#define USE_ANISOTROPY":"",i.anisotropyMap?"#define USE_ANISOTROPYMAP":"",i.clearcoat?"#define USE_CLEARCOAT":"",i.clearcoatMap?"#define USE_CLEARCOATMAP":"",i.clearcoatRoughnessMap?"#define USE_CLEARCOAT_ROUGHNESSMAP":"",i.clearcoatNormalMap?"#define USE_CLEARCOAT_NORMALMAP":"",i.dispersion?"#define USE_DISPERSION":"",i.iridescence?"#define USE_IRIDESCENCE":"",i.iridescenceMap?"#define USE_IRIDESCENCEMAP":"",i.iridescenceThicknessMap?"#define USE_IRIDESCENCE_THICKNESSMAP":"",i.specularMap?"#define USE_SPECULARMAP":"",i.specularColorMap?"#define USE_SPECULAR_COLORMAP":"",i.specularIntensityMap?"#define USE_SPECULAR_INTENSITYMAP":"",i.roughnessMap?"#define USE_ROUGHNESSMAP":"",i.metalnessMap?"#define USE_METALNESSMAP":"",i.alphaMap?"#define USE_ALPHAMAP":"",i.alphaTest?"#define USE_ALPHATEST":"",i.alphaHash?"#define USE_ALPHAHASH":"",i.sheen?"#define USE_SHEEN":"",i.sheenColorMap?"#define USE_SHEEN_COLORMAP":"",i.sheenRoughnessMap?"#define USE_SHEEN_ROUGHNESSMAP":"",i.transmission?"#define USE_TRANSMISSION":"",i.transmissionMap?"#define USE_TRANSMISSIONMAP":"",i.thicknessMap?"#define USE_THICKNESSMAP":"",i.vertexTangents&&i.flatShading===!1?"#define USE_TANGENT":"",i.vertexColors||i.instancingColor||i.batchingColor?"#define USE_COLOR":"",i.vertexAlphas?"#define USE_COLOR_ALPHA":"",i.vertexUv1s?"#define USE_UV1":"",i.vertexUv2s?"#define USE_UV2":"",i.vertexUv3s?"#define USE_UV3":"",i.pointsUvs?"#define USE_POINTS_UV":"",i.gradientMap?"#define USE_GRADIENTMAP":"",i.flatShading?"#define FLAT_SHADED":"",i.doubleSided?"#define DOUBLE_SIDED":"",i.flipSided?"#define FLIP_SIDED":"",i.shadowMapEnabled?"#define USE_SHADOWMAP":"",i.shadowMapEnabled?"#define "+m:"",i.premultipliedAlpha?"#define PREMULTIPLIED_ALPHA":"",i.numLightProbes>0?"#define USE_LIGHT_PROBES":"",i.decodeVideoTexture?"#define DECODE_VIDEO_TEXTURE":"",i.decodeVideoTextureEmissive?"#define DECODE_VIDEO_TEXTURE_EMISSIVE":"",i.logarithmicDepthBuffer?"#define USE_LOGDEPTHBUF":"",i.reverseDepthBuffer?"#define USE_REVERSEDEPTHBUF":"","uniform mat4 viewMatrix;","uniform vec3 cameraPosition;","uniform bool isOrthographic;",i.toneMapping!==Ha?"#define TONE_MAPPING":"",i.toneMapping!==Ha?le.tonemapping_pars_fragment:"",i.toneMapping!==Ha?Lb("toneMapping",i.toneMapping):"",i.dithering?"#define DITHERING":"",i.opaque?"#define OPAQUE":"",le.colorspace_pars_fragment,Ub("linearToOutputTexel",i.outputColorSpace),Nb(),i.useDepthPacking?"#define DEPTH_PACKING "+i.depthPacking:"",`
`].filter(Ao).join(`
`)),h=od(h),h=c0(h,i),h=f0(h,i),d=od(d),d=c0(d,i),d=f0(d,i),h=h0(h),d=h0(d),i.isRawShaderMaterial!==!0&&(L=`#version 300 es
`,M=[y,"#define attribute in","#define varying out","#define texture2D texture"].join(`
`)+`
`+M,_=["#define varying in",i.glslVersion===E_?"":"layout(location = 0) out highp vec4 pc_fragColor;",i.glslVersion===E_?"":"#define gl_FragColor pc_fragColor","#define gl_FragDepthEXT gl_FragDepth","#define texture2D texture","#define textureCube texture","#define texture2DProj textureProj","#define texture2DLodEXT textureLod","#define texture2DProjLodEXT textureProjLod","#define textureCubeLodEXT textureLod","#define texture2DGradEXT textureGrad","#define texture2DProjGradEXT textureProjGrad","#define textureCubeGradEXT textureGrad"].join(`
`)+`
`+_);const U=L+M+h,C=L+_+d,G=o0(l,l.VERTEX_SHADER,U),I=o0(l,l.FRAGMENT_SHADER,C);l.attachShader(w,G),l.attachShader(w,I),i.index0AttributeName!==void 0?l.bindAttribLocation(w,0,i.index0AttributeName):i.morphTargets===!0&&l.bindAttribLocation(w,0,"position"),l.linkProgram(w);function O(B){if(o.debug.checkShaderErrors){const rt=l.getProgramInfoLog(w).trim(),st=l.getShaderInfoLog(G).trim(),dt=l.getShaderInfoLog(I).trim();let pt=!0,P=!0;if(l.getProgramParameter(w,l.LINK_STATUS)===!1)if(pt=!1,typeof o.debug.onShaderError=="function")o.debug.onShaderError(l,w,G,I);else{const Y=u0(l,G,"vertex"),j=u0(l,I,"fragment");console.error("THREE.WebGLProgram: Shader Error "+l.getError()+" - VALIDATE_STATUS "+l.getProgramParameter(w,l.VALIDATE_STATUS)+`

Material Name: `+B.name+`
Material Type: `+B.type+`

Program Info Log: `+rt+`
`+Y+`
`+j)}else rt!==""?console.warn("THREE.WebGLProgram: Program Info Log:",rt):(st===""||dt==="")&&(P=!1);P&&(B.diagnostics={runnable:pt,programLog:rt,vertexShader:{log:st,prefix:M},fragmentShader:{log:dt,prefix:_}})}l.deleteShader(G),l.deleteShader(I),V=new yu(l,w),D=Pb(l,w)}let V;this.getUniforms=function(){return V===void 0&&O(this),V};let D;this.getAttributes=function(){return D===void 0&&O(this),D};let b=i.rendererExtensionParallelShaderCompile===!1;return this.isReady=function(){return b===!1&&(b=l.getProgramParameter(w,Rb)),b},this.destroy=function(){r.releaseStatesOfProgram(this),l.deleteProgram(w),this.program=void 0},this.type=i.shaderType,this.name=i.shaderName,this.id=Cb++,this.cacheKey=e,this.usedTimes=1,this.program=w,this.vertexShader=G,this.fragmentShader=I,this}let jb=0;class Zb{constructor(){this.shaderCache=new Map,this.materialCache=new Map}update(e){const i=e.vertexShader,r=e.fragmentShader,l=this._getShaderStage(i),c=this._getShaderStage(r),h=this._getShaderCacheForMaterial(e);return h.has(l)===!1&&(h.add(l),l.usedTimes++),h.has(c)===!1&&(h.add(c),c.usedTimes++),this}remove(e){const i=this.materialCache.get(e);for(const r of i)r.usedTimes--,r.usedTimes===0&&this.shaderCache.delete(r.code);return this.materialCache.delete(e),this}getVertexShaderID(e){return this._getShaderStage(e.vertexShader).id}getFragmentShaderID(e){return this._getShaderStage(e.fragmentShader).id}dispose(){this.shaderCache.clear(),this.materialCache.clear()}_getShaderCacheForMaterial(e){const i=this.materialCache;let r=i.get(e);return r===void 0&&(r=new Set,i.set(e,r)),r}_getShaderStage(e){const i=this.shaderCache;let r=i.get(e);return r===void 0&&(r=new Kb(e),i.set(e,r)),r}}class Kb{constructor(e){this.id=jb++,this.code=e,this.usedTimes=0}}function Qb(o,e,i,r,l,c,h){const d=new B0,m=new Zb,p=new Set,S=[],v=l.logarithmicDepthBuffer,x=l.vertexTextures;let y=l.precision;const R={MeshDepthMaterial:"depth",MeshDistanceMaterial:"distanceRGBA",MeshNormalMaterial:"normal",MeshBasicMaterial:"basic",MeshLambertMaterial:"lambert",MeshPhongMaterial:"phong",MeshToonMaterial:"toon",MeshStandardMaterial:"physical",MeshPhysicalMaterial:"physical",MeshMatcapMaterial:"matcap",LineBasicMaterial:"basic",LineDashedMaterial:"dashed",PointsMaterial:"points",ShadowMaterial:"shadow",SpriteMaterial:"sprite"};function w(D){return p.add(D),D===0?"uv":`uv${D}`}function M(D,b,B,rt,st){const dt=rt.fog,pt=st.geometry,P=D.isMeshStandardMaterial?rt.environment:null,Y=(D.isMeshStandardMaterial?i:e).get(D.envMap||P),j=Y&&Y.mapping===Au?Y.image.height:null,vt=R[D.type];D.precision!==null&&(y=l.getMaxPrecision(D.precision),y!==D.precision&&console.warn("THREE.WebGLProgram.getParameters:",D.precision,"not supported, using",y,"instead."));const Tt=pt.morphAttributes.position||pt.morphAttributes.normal||pt.morphAttributes.color,z=Tt!==void 0?Tt.length:0;let nt=0;pt.morphAttributes.position!==void 0&&(nt=1),pt.morphAttributes.normal!==void 0&&(nt=2),pt.morphAttributes.color!==void 0&&(nt=3);let xt,K,ft,yt;if(vt){const Ee=Ci[vt];xt=Ee.vertexShader,K=Ee.fragmentShader}else xt=D.vertexShader,K=D.fragmentShader,m.update(D),ft=m.getVertexShaderID(D),yt=m.getFragmentShaderID(D);const St=o.getRenderTarget(),zt=o.state.buffers.depth.getReversed(),qt=st.isInstancedMesh===!0,jt=st.isBatchedMesh===!0,Ge=!!D.map,Fe=!!D.matcap,ue=!!Y,H=!!D.aoMap,Mn=!!D.lightMap,ce=!!D.bumpMap,de=!!D.normalMap,Vt=!!D.displacementMap,we=!!D.emissiveMap,Gt=!!D.metalnessMap,N=!!D.roughnessMap,T=D.anisotropy>0,et=D.clearcoat>0,ct=D.dispersion>0,Mt=D.iridescence>0,mt=D.sheen>0,Ft=D.transmission>0,Rt=T&&!!D.anisotropyMap,Zt=et&&!!D.clearcoatMap,Qt=et&&!!D.clearcoatNormalMap,bt=et&&!!D.clearcoatRoughnessMap,Pt=Mt&&!!D.iridescenceMap,Yt=Mt&&!!D.iridescenceThicknessMap,Ht=mt&&!!D.sheenColorMap,Nt=mt&&!!D.sheenRoughnessMap,$t=!!D.specularMap,ae=!!D.specularColorMap,Le=!!D.specularIntensityMap,W=Ft&&!!D.transmissionMap,Ct=Ft&&!!D.thicknessMap,lt=!!D.gradientMap,_t=!!D.alphaMap,At=D.alphaTest>0,wt=!!D.alphaHash,te=!!D.extensions;let We=Ha;D.toneMapped&&(St===null||St.isXRRenderTarget===!0)&&(We=o.toneMapping);const sn={shaderID:vt,shaderType:D.type,shaderName:D.name,vertexShader:xt,fragmentShader:K,defines:D.defines,customVertexShaderID:ft,customFragmentShaderID:yt,isRawShaderMaterial:D.isRawShaderMaterial===!0,glslVersion:D.glslVersion,precision:y,batching:jt,batchingColor:jt&&st._colorsTexture!==null,instancing:qt,instancingColor:qt&&st.instanceColor!==null,instancingMorph:qt&&st.morphTexture!==null,supportsVertexTextures:x,outputColorSpace:St===null?o.outputColorSpace:St.isXRRenderTarget===!0?St.texture.colorSpace:Ms,alphaToCoverage:!!D.alphaToCoverage,map:Ge,matcap:Fe,envMap:ue,envMapMode:ue&&Y.mapping,envMapCubeUVHeight:j,aoMap:H,lightMap:Mn,bumpMap:ce,normalMap:de,displacementMap:x&&Vt,emissiveMap:we,normalMapObjectSpace:de&&D.normalMapType===kx,normalMapTangentSpace:de&&D.normalMapType===N0,metalnessMap:Gt,roughnessMap:N,anisotropy:T,anisotropyMap:Rt,clearcoat:et,clearcoatMap:Zt,clearcoatNormalMap:Qt,clearcoatRoughnessMap:bt,dispersion:ct,iridescence:Mt,iridescenceMap:Pt,iridescenceThicknessMap:Yt,sheen:mt,sheenColorMap:Ht,sheenRoughnessMap:Nt,specularMap:$t,specularColorMap:ae,specularIntensityMap:Le,transmission:Ft,transmissionMap:W,thicknessMap:Ct,gradientMap:lt,opaque:D.transparent===!1&&D.blending===gs&&D.alphaToCoverage===!1,alphaMap:_t,alphaTest:At,alphaHash:wt,combine:D.combine,mapUv:Ge&&w(D.map.channel),aoMapUv:H&&w(D.aoMap.channel),lightMapUv:Mn&&w(D.lightMap.channel),bumpMapUv:ce&&w(D.bumpMap.channel),normalMapUv:de&&w(D.normalMap.channel),displacementMapUv:Vt&&w(D.displacementMap.channel),emissiveMapUv:we&&w(D.emissiveMap.channel),metalnessMapUv:Gt&&w(D.metalnessMap.channel),roughnessMapUv:N&&w(D.roughnessMap.channel),anisotropyMapUv:Rt&&w(D.anisotropyMap.channel),clearcoatMapUv:Zt&&w(D.clearcoatMap.channel),clearcoatNormalMapUv:Qt&&w(D.clearcoatNormalMap.channel),clearcoatRoughnessMapUv:bt&&w(D.clearcoatRoughnessMap.channel),iridescenceMapUv:Pt&&w(D.iridescenceMap.channel),iridescenceThicknessMapUv:Yt&&w(D.iridescenceThicknessMap.channel),sheenColorMapUv:Ht&&w(D.sheenColorMap.channel),sheenRoughnessMapUv:Nt&&w(D.sheenRoughnessMap.channel),specularMapUv:$t&&w(D.specularMap.channel),specularColorMapUv:ae&&w(D.specularColorMap.channel),specularIntensityMapUv:Le&&w(D.specularIntensityMap.channel),transmissionMapUv:W&&w(D.transmissionMap.channel),thicknessMapUv:Ct&&w(D.thicknessMap.channel),alphaMapUv:_t&&w(D.alphaMap.channel),vertexTangents:!!pt.attributes.tangent&&(de||T),vertexColors:D.vertexColors,vertexAlphas:D.vertexColors===!0&&!!pt.attributes.color&&pt.attributes.color.itemSize===4,pointsUvs:st.isPoints===!0&&!!pt.attributes.uv&&(Ge||_t),fog:!!dt,useFog:D.fog===!0,fogExp2:!!dt&&dt.isFogExp2,flatShading:D.flatShading===!0,sizeAttenuation:D.sizeAttenuation===!0,logarithmicDepthBuffer:v,reverseDepthBuffer:zt,skinning:st.isSkinnedMesh===!0,morphTargets:pt.morphAttributes.position!==void 0,morphNormals:pt.morphAttributes.normal!==void 0,morphColors:pt.morphAttributes.color!==void 0,morphTargetsCount:z,morphTextureStride:nt,numDirLights:b.directional.length,numPointLights:b.point.length,numSpotLights:b.spot.length,numSpotLightMaps:b.spotLightMap.length,numRectAreaLights:b.rectArea.length,numHemiLights:b.hemi.length,numDirLightShadows:b.directionalShadowMap.length,numPointLightShadows:b.pointShadowMap.length,numSpotLightShadows:b.spotShadowMap.length,numSpotLightShadowsWithMaps:b.numSpotLightShadowsWithMaps,numLightProbes:b.numLightProbes,numClippingPlanes:h.numPlanes,numClipIntersection:h.numIntersection,dithering:D.dithering,shadowMapEnabled:o.shadowMap.enabled&&B.length>0,shadowMapType:o.shadowMap.type,toneMapping:We,decodeVideoTexture:Ge&&D.map.isVideoTexture===!0&&Re.getTransfer(D.map.colorSpace)===Be,decodeVideoTextureEmissive:we&&D.emissiveMap.isVideoTexture===!0&&Re.getTransfer(D.emissiveMap.colorSpace)===Be,premultipliedAlpha:D.premultipliedAlpha,doubleSided:D.side===ra,flipSided:D.side===Gn,useDepthPacking:D.depthPacking>=0,depthPacking:D.depthPacking||0,index0AttributeName:D.index0AttributeName,extensionClipCullDistance:te&&D.extensions.clipCullDistance===!0&&r.has("WEBGL_clip_cull_distance"),extensionMultiDraw:(te&&D.extensions.multiDraw===!0||jt)&&r.has("WEBGL_multi_draw"),rendererExtensionParallelShaderCompile:r.has("KHR_parallel_shader_compile"),customProgramCacheKey:D.customProgramCacheKey()};return sn.vertexUv1s=p.has(1),sn.vertexUv2s=p.has(2),sn.vertexUv3s=p.has(3),p.clear(),sn}function _(D){const b=[];if(D.shaderID?b.push(D.shaderID):(b.push(D.customVertexShaderID),b.push(D.customFragmentShaderID)),D.defines!==void 0)for(const B in D.defines)b.push(B),b.push(D.defines[B]);return D.isRawShaderMaterial===!1&&(L(b,D),U(b,D),b.push(o.outputColorSpace)),b.push(D.customProgramCacheKey),b.join()}function L(D,b){D.push(b.precision),D.push(b.outputColorSpace),D.push(b.envMapMode),D.push(b.envMapCubeUVHeight),D.push(b.mapUv),D.push(b.alphaMapUv),D.push(b.lightMapUv),D.push(b.aoMapUv),D.push(b.bumpMapUv),D.push(b.normalMapUv),D.push(b.displacementMapUv),D.push(b.emissiveMapUv),D.push(b.metalnessMapUv),D.push(b.roughnessMapUv),D.push(b.anisotropyMapUv),D.push(b.clearcoatMapUv),D.push(b.clearcoatNormalMapUv),D.push(b.clearcoatRoughnessMapUv),D.push(b.iridescenceMapUv),D.push(b.iridescenceThicknessMapUv),D.push(b.sheenColorMapUv),D.push(b.sheenRoughnessMapUv),D.push(b.specularMapUv),D.push(b.specularColorMapUv),D.push(b.specularIntensityMapUv),D.push(b.transmissionMapUv),D.push(b.thicknessMapUv),D.push(b.combine),D.push(b.fogExp2),D.push(b.sizeAttenuation),D.push(b.morphTargetsCount),D.push(b.morphAttributeCount),D.push(b.numDirLights),D.push(b.numPointLights),D.push(b.numSpotLights),D.push(b.numSpotLightMaps),D.push(b.numHemiLights),D.push(b.numRectAreaLights),D.push(b.numDirLightShadows),D.push(b.numPointLightShadows),D.push(b.numSpotLightShadows),D.push(b.numSpotLightShadowsWithMaps),D.push(b.numLightProbes),D.push(b.shadowMapType),D.push(b.toneMapping),D.push(b.numClippingPlanes),D.push(b.numClipIntersection),D.push(b.depthPacking)}function U(D,b){d.disableAll(),b.supportsVertexTextures&&d.enable(0),b.instancing&&d.enable(1),b.instancingColor&&d.enable(2),b.instancingMorph&&d.enable(3),b.matcap&&d.enable(4),b.envMap&&d.enable(5),b.normalMapObjectSpace&&d.enable(6),b.normalMapTangentSpace&&d.enable(7),b.clearcoat&&d.enable(8),b.iridescence&&d.enable(9),b.alphaTest&&d.enable(10),b.vertexColors&&d.enable(11),b.vertexAlphas&&d.enable(12),b.vertexUv1s&&d.enable(13),b.vertexUv2s&&d.enable(14),b.vertexUv3s&&d.enable(15),b.vertexTangents&&d.enable(16),b.anisotropy&&d.enable(17),b.alphaHash&&d.enable(18),b.batching&&d.enable(19),b.dispersion&&d.enable(20),b.batchingColor&&d.enable(21),D.push(d.mask),d.disableAll(),b.fog&&d.enable(0),b.useFog&&d.enable(1),b.flatShading&&d.enable(2),b.logarithmicDepthBuffer&&d.enable(3),b.reverseDepthBuffer&&d.enable(4),b.skinning&&d.enable(5),b.morphTargets&&d.enable(6),b.morphNormals&&d.enable(7),b.morphColors&&d.enable(8),b.premultipliedAlpha&&d.enable(9),b.shadowMapEnabled&&d.enable(10),b.doubleSided&&d.enable(11),b.flipSided&&d.enable(12),b.useDepthPacking&&d.enable(13),b.dithering&&d.enable(14),b.transmission&&d.enable(15),b.sheen&&d.enable(16),b.opaque&&d.enable(17),b.pointsUvs&&d.enable(18),b.decodeVideoTexture&&d.enable(19),b.decodeVideoTextureEmissive&&d.enable(20),b.alphaToCoverage&&d.enable(21),D.push(d.mask)}function C(D){const b=R[D.type];let B;if(b){const rt=Ci[b];B=yM.clone(rt.uniforms)}else B=D.uniforms;return B}function G(D,b){let B;for(let rt=0,st=S.length;rt<st;rt++){const dt=S[rt];if(dt.cacheKey===b){B=dt,++B.usedTimes;break}}return B===void 0&&(B=new Yb(o,b,D,c),S.push(B)),B}function I(D){if(--D.usedTimes===0){const b=S.indexOf(D);S[b]=S[S.length-1],S.pop(),D.destroy()}}function O(D){m.remove(D)}function V(){m.dispose()}return{getParameters:M,getProgramCacheKey:_,getUniforms:C,acquireProgram:G,releaseProgram:I,releaseShaderCache:O,programs:S,dispose:V}}function Jb(){let o=new WeakMap;function e(h){return o.has(h)}function i(h){let d=o.get(h);return d===void 0&&(d={},o.set(h,d)),d}function r(h){o.delete(h)}function l(h,d,m){o.get(h)[d]=m}function c(){o=new WeakMap}return{has:e,get:i,remove:r,update:l,dispose:c}}function $b(o,e){return o.groupOrder!==e.groupOrder?o.groupOrder-e.groupOrder:o.renderOrder!==e.renderOrder?o.renderOrder-e.renderOrder:o.material.id!==e.material.id?o.material.id-e.material.id:o.z!==e.z?o.z-e.z:o.id-e.id}function p0(o,e){return o.groupOrder!==e.groupOrder?o.groupOrder-e.groupOrder:o.renderOrder!==e.renderOrder?o.renderOrder-e.renderOrder:o.z!==e.z?e.z-o.z:o.id-e.id}function m0(){const o=[];let e=0;const i=[],r=[],l=[];function c(){e=0,i.length=0,r.length=0,l.length=0}function h(v,x,y,R,w,M){let _=o[e];return _===void 0?(_={id:v.id,object:v,geometry:x,material:y,groupOrder:R,renderOrder:v.renderOrder,z:w,group:M},o[e]=_):(_.id=v.id,_.object=v,_.geometry=x,_.material=y,_.groupOrder=R,_.renderOrder=v.renderOrder,_.z=w,_.group=M),e++,_}function d(v,x,y,R,w,M){const _=h(v,x,y,R,w,M);y.transmission>0?r.push(_):y.transparent===!0?l.push(_):i.push(_)}function m(v,x,y,R,w,M){const _=h(v,x,y,R,w,M);y.transmission>0?r.unshift(_):y.transparent===!0?l.unshift(_):i.unshift(_)}function p(v,x){i.length>1&&i.sort(v||$b),r.length>1&&r.sort(x||p0),l.length>1&&l.sort(x||p0)}function S(){for(let v=e,x=o.length;v<x;v++){const y=o[v];if(y.id===null)break;y.id=null,y.object=null,y.geometry=null,y.material=null,y.group=null}}return{opaque:i,transmissive:r,transparent:l,init:c,push:d,unshift:m,finish:S,sort:p}}function tA(){let o=new WeakMap;function e(r,l){const c=o.get(r);let h;return c===void 0?(h=new m0,o.set(r,[h])):l>=c.length?(h=new m0,c.push(h)):h=c[l],h}function i(){o=new WeakMap}return{get:e,dispose:i}}function eA(){const o={};return{get:function(e){if(o[e.id]!==void 0)return o[e.id];let i;switch(e.type){case"DirectionalLight":i={direction:new Q,color:new Me};break;case"SpotLight":i={position:new Q,direction:new Q,color:new Me,distance:0,coneCos:0,penumbraCos:0,decay:0};break;case"PointLight":i={position:new Q,color:new Me,distance:0,decay:0};break;case"HemisphereLight":i={direction:new Q,skyColor:new Me,groundColor:new Me};break;case"RectAreaLight":i={color:new Me,position:new Q,halfWidth:new Q,halfHeight:new Q};break}return o[e.id]=i,i}}}function nA(){const o={};return{get:function(e){if(o[e.id]!==void 0)return o[e.id];let i;switch(e.type){case"DirectionalLight":i={shadowIntensity:1,shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new ye};break;case"SpotLight":i={shadowIntensity:1,shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new ye};break;case"PointLight":i={shadowIntensity:1,shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new ye,shadowCameraNear:1,shadowCameraFar:1e3};break}return o[e.id]=i,i}}}let iA=0;function aA(o,e){return(e.castShadow?2:0)-(o.castShadow?2:0)+(e.map?1:0)-(o.map?1:0)}function rA(o){const e=new eA,i=nA(),r={version:0,hash:{directionalLength:-1,pointLength:-1,spotLength:-1,rectAreaLength:-1,hemiLength:-1,numDirectionalShadows:-1,numPointShadows:-1,numSpotShadows:-1,numSpotMaps:-1,numLightProbes:-1},ambient:[0,0,0],probe:[],directional:[],directionalShadow:[],directionalShadowMap:[],directionalShadowMatrix:[],spot:[],spotLightMap:[],spotShadow:[],spotShadowMap:[],spotLightMatrix:[],rectArea:[],rectAreaLTC1:null,rectAreaLTC2:null,point:[],pointShadow:[],pointShadowMap:[],pointShadowMatrix:[],hemi:[],numSpotLightShadowsWithMaps:0,numLightProbes:0};for(let p=0;p<9;p++)r.probe.push(new Q);const l=new Q,c=new Ye,h=new Ye;function d(p){let S=0,v=0,x=0;for(let D=0;D<9;D++)r.probe[D].set(0,0,0);let y=0,R=0,w=0,M=0,_=0,L=0,U=0,C=0,G=0,I=0,O=0;p.sort(aA);for(let D=0,b=p.length;D<b;D++){const B=p[D],rt=B.color,st=B.intensity,dt=B.distance,pt=B.shadow&&B.shadow.map?B.shadow.map.texture:null;if(B.isAmbientLight)S+=rt.r*st,v+=rt.g*st,x+=rt.b*st;else if(B.isLightProbe){for(let P=0;P<9;P++)r.probe[P].addScaledVector(B.sh.coefficients[P],st);O++}else if(B.isDirectionalLight){const P=e.get(B);if(P.color.copy(B.color).multiplyScalar(B.intensity),B.castShadow){const Y=B.shadow,j=i.get(B);j.shadowIntensity=Y.intensity,j.shadowBias=Y.bias,j.shadowNormalBias=Y.normalBias,j.shadowRadius=Y.radius,j.shadowMapSize=Y.mapSize,r.directionalShadow[y]=j,r.directionalShadowMap[y]=pt,r.directionalShadowMatrix[y]=B.shadow.matrix,L++}r.directional[y]=P,y++}else if(B.isSpotLight){const P=e.get(B);P.position.setFromMatrixPosition(B.matrixWorld),P.color.copy(rt).multiplyScalar(st),P.distance=dt,P.coneCos=Math.cos(B.angle),P.penumbraCos=Math.cos(B.angle*(1-B.penumbra)),P.decay=B.decay,r.spot[w]=P;const Y=B.shadow;if(B.map&&(r.spotLightMap[G]=B.map,G++,Y.updateMatrices(B),B.castShadow&&I++),r.spotLightMatrix[w]=Y.matrix,B.castShadow){const j=i.get(B);j.shadowIntensity=Y.intensity,j.shadowBias=Y.bias,j.shadowNormalBias=Y.normalBias,j.shadowRadius=Y.radius,j.shadowMapSize=Y.mapSize,r.spotShadow[w]=j,r.spotShadowMap[w]=pt,C++}w++}else if(B.isRectAreaLight){const P=e.get(B);P.color.copy(rt).multiplyScalar(st),P.halfWidth.set(B.width*.5,0,0),P.halfHeight.set(0,B.height*.5,0),r.rectArea[M]=P,M++}else if(B.isPointLight){const P=e.get(B);if(P.color.copy(B.color).multiplyScalar(B.intensity),P.distance=B.distance,P.decay=B.decay,B.castShadow){const Y=B.shadow,j=i.get(B);j.shadowIntensity=Y.intensity,j.shadowBias=Y.bias,j.shadowNormalBias=Y.normalBias,j.shadowRadius=Y.radius,j.shadowMapSize=Y.mapSize,j.shadowCameraNear=Y.camera.near,j.shadowCameraFar=Y.camera.far,r.pointShadow[R]=j,r.pointShadowMap[R]=pt,r.pointShadowMatrix[R]=B.shadow.matrix,U++}r.point[R]=P,R++}else if(B.isHemisphereLight){const P=e.get(B);P.skyColor.copy(B.color).multiplyScalar(st),P.groundColor.copy(B.groundColor).multiplyScalar(st),r.hemi[_]=P,_++}}M>0&&(o.has("OES_texture_float_linear")===!0?(r.rectAreaLTC1=Ut.LTC_FLOAT_1,r.rectAreaLTC2=Ut.LTC_FLOAT_2):(r.rectAreaLTC1=Ut.LTC_HALF_1,r.rectAreaLTC2=Ut.LTC_HALF_2)),r.ambient[0]=S,r.ambient[1]=v,r.ambient[2]=x;const V=r.hash;(V.directionalLength!==y||V.pointLength!==R||V.spotLength!==w||V.rectAreaLength!==M||V.hemiLength!==_||V.numDirectionalShadows!==L||V.numPointShadows!==U||V.numSpotShadows!==C||V.numSpotMaps!==G||V.numLightProbes!==O)&&(r.directional.length=y,r.spot.length=w,r.rectArea.length=M,r.point.length=R,r.hemi.length=_,r.directionalShadow.length=L,r.directionalShadowMap.length=L,r.pointShadow.length=U,r.pointShadowMap.length=U,r.spotShadow.length=C,r.spotShadowMap.length=C,r.directionalShadowMatrix.length=L,r.pointShadowMatrix.length=U,r.spotLightMatrix.length=C+G-I,r.spotLightMap.length=G,r.numSpotLightShadowsWithMaps=I,r.numLightProbes=O,V.directionalLength=y,V.pointLength=R,V.spotLength=w,V.rectAreaLength=M,V.hemiLength=_,V.numDirectionalShadows=L,V.numPointShadows=U,V.numSpotShadows=C,V.numSpotMaps=G,V.numLightProbes=O,r.version=iA++)}function m(p,S){let v=0,x=0,y=0,R=0,w=0;const M=S.matrixWorldInverse;for(let _=0,L=p.length;_<L;_++){const U=p[_];if(U.isDirectionalLight){const C=r.directional[v];C.direction.setFromMatrixPosition(U.matrixWorld),l.setFromMatrixPosition(U.target.matrixWorld),C.direction.sub(l),C.direction.transformDirection(M),v++}else if(U.isSpotLight){const C=r.spot[y];C.position.setFromMatrixPosition(U.matrixWorld),C.position.applyMatrix4(M),C.direction.setFromMatrixPosition(U.matrixWorld),l.setFromMatrixPosition(U.target.matrixWorld),C.direction.sub(l),C.direction.transformDirection(M),y++}else if(U.isRectAreaLight){const C=r.rectArea[R];C.position.setFromMatrixPosition(U.matrixWorld),C.position.applyMatrix4(M),h.identity(),c.copy(U.matrixWorld),c.premultiply(M),h.extractRotation(c),C.halfWidth.set(U.width*.5,0,0),C.halfHeight.set(0,U.height*.5,0),C.halfWidth.applyMatrix4(h),C.halfHeight.applyMatrix4(h),R++}else if(U.isPointLight){const C=r.point[x];C.position.setFromMatrixPosition(U.matrixWorld),C.position.applyMatrix4(M),x++}else if(U.isHemisphereLight){const C=r.hemi[w];C.direction.setFromMatrixPosition(U.matrixWorld),C.direction.transformDirection(M),w++}}}return{setup:d,setupView:m,state:r}}function g0(o){const e=new rA(o),i=[],r=[];function l(S){p.camera=S,i.length=0,r.length=0}function c(S){i.push(S)}function h(S){r.push(S)}function d(){e.setup(i)}function m(S){e.setupView(i,S)}const p={lightsArray:i,shadowsArray:r,camera:null,lights:e,transmissionRenderTarget:{}};return{init:l,state:p,setupLights:d,setupLightsView:m,pushLight:c,pushShadow:h}}function sA(o){let e=new WeakMap;function i(l,c=0){const h=e.get(l);let d;return h===void 0?(d=new g0(o),e.set(l,[d])):c>=h.length?(d=new g0(o),h.push(d)):d=h[c],d}function r(){e=new WeakMap}return{get:i,dispose:r}}const oA=`void main() {
	gl_Position = vec4( position, 1.0 );
}`,lA=`uniform sampler2D shadow_pass;
uniform vec2 resolution;
uniform float radius;
#include <packing>
void main() {
	const float samples = float( VSM_SAMPLES );
	float mean = 0.0;
	float squared_mean = 0.0;
	float uvStride = samples <= 1.0 ? 0.0 : 2.0 / ( samples - 1.0 );
	float uvStart = samples <= 1.0 ? 0.0 : - 1.0;
	for ( float i = 0.0; i < samples; i ++ ) {
		float uvOffset = uvStart + i * uvStride;
		#ifdef HORIZONTAL_PASS
			vec2 distribution = unpackRGBATo2Half( texture2D( shadow_pass, ( gl_FragCoord.xy + vec2( uvOffset, 0.0 ) * radius ) / resolution ) );
			mean += distribution.x;
			squared_mean += distribution.y * distribution.y + distribution.x * distribution.x;
		#else
			float depth = unpackRGBAToDepth( texture2D( shadow_pass, ( gl_FragCoord.xy + vec2( 0.0, uvOffset ) * radius ) / resolution ) );
			mean += depth;
			squared_mean += depth * depth;
		#endif
	}
	mean = mean / samples;
	squared_mean = squared_mean / samples;
	float std_dev = sqrt( squared_mean - mean * mean );
	gl_FragColor = pack2HalfToRGBA( vec2( mean, std_dev ) );
}`;function uA(o,e,i){let r=new xd;const l=new ye,c=new ye,h=new Ie,d=new UM({depthPacking:Xx}),m=new LM,p={},S=i.maxTextureSize,v={[Ga]:Gn,[Gn]:Ga,[ra]:ra},x=new Va({defines:{VSM_SAMPLES:8},uniforms:{shadow_pass:{value:null},resolution:{value:new ye},radius:{value:4}},vertexShader:oA,fragmentShader:lA}),y=x.clone();y.defines.HORIZONTAL_PASS=1;const R=new Ni;R.setAttribute("position",new Di(new Float32Array([-1,-1,.5,3,-1,.5,-1,3,.5]),3));const w=new ui(R,x),M=this;this.enabled=!1,this.autoUpdate=!0,this.needsUpdate=!1,this.type=x0;let _=this.type;this.render=function(I,O,V){if(M.enabled===!1||M.autoUpdate===!1&&M.needsUpdate===!1||I.length===0)return;const D=o.getRenderTarget(),b=o.getActiveCubeFace(),B=o.getActiveMipmapLevel(),rt=o.state;rt.setBlending(Fa),rt.buffers.color.setClear(1,1,1,1),rt.buffers.depth.setTest(!0),rt.setScissorTest(!1);const st=_!==ia&&this.type===ia,dt=_===ia&&this.type!==ia;for(let pt=0,P=I.length;pt<P;pt++){const Y=I[pt],j=Y.shadow;if(j===void 0){console.warn("THREE.WebGLShadowMap:",Y,"has no shadow.");continue}if(j.autoUpdate===!1&&j.needsUpdate===!1)continue;l.copy(j.mapSize);const vt=j.getFrameExtents();if(l.multiply(vt),c.copy(j.mapSize),(l.x>S||l.y>S)&&(l.x>S&&(c.x=Math.floor(S/vt.x),l.x=c.x*vt.x,j.mapSize.x=c.x),l.y>S&&(c.y=Math.floor(S/vt.y),l.y=c.y*vt.y,j.mapSize.y=c.y)),j.map===null||st===!0||dt===!0){const z=this.type!==ia?{minFilter:yi,magFilter:yi}:{};j.map!==null&&j.map.dispose(),j.map=new Mr(l.x,l.y,z),j.map.texture.name=Y.name+".shadowMap",j.camera.updateProjectionMatrix()}o.setRenderTarget(j.map),o.clear();const Tt=j.getViewportCount();for(let z=0;z<Tt;z++){const nt=j.getViewport(z);h.set(c.x*nt.x,c.y*nt.y,c.x*nt.z,c.y*nt.w),rt.viewport(h),j.updateMatrices(Y,z),r=j.getFrustum(),C(O,V,j.camera,Y,this.type)}j.isPointLightShadow!==!0&&this.type===ia&&L(j,V),j.needsUpdate=!1}_=this.type,M.needsUpdate=!1,o.setRenderTarget(D,b,B)};function L(I,O){const V=e.update(w);x.defines.VSM_SAMPLES!==I.blurSamples&&(x.defines.VSM_SAMPLES=I.blurSamples,y.defines.VSM_SAMPLES=I.blurSamples,x.needsUpdate=!0,y.needsUpdate=!0),I.mapPass===null&&(I.mapPass=new Mr(l.x,l.y)),x.uniforms.shadow_pass.value=I.map.texture,x.uniforms.resolution.value=I.mapSize,x.uniforms.radius.value=I.radius,o.setRenderTarget(I.mapPass),o.clear(),o.renderBufferDirect(O,null,V,x,w,null),y.uniforms.shadow_pass.value=I.mapPass.texture,y.uniforms.resolution.value=I.mapSize,y.uniforms.radius.value=I.radius,o.setRenderTarget(I.map),o.clear(),o.renderBufferDirect(O,null,V,y,w,null)}function U(I,O,V,D){let b=null;const B=V.isPointLight===!0?I.customDistanceMaterial:I.customDepthMaterial;if(B!==void 0)b=B;else if(b=V.isPointLight===!0?m:d,o.localClippingEnabled&&O.clipShadows===!0&&Array.isArray(O.clippingPlanes)&&O.clippingPlanes.length!==0||O.displacementMap&&O.displacementScale!==0||O.alphaMap&&O.alphaTest>0||O.map&&O.alphaTest>0||O.alphaToCoverage===!0){const rt=b.uuid,st=O.uuid;let dt=p[rt];dt===void 0&&(dt={},p[rt]=dt);let pt=dt[st];pt===void 0&&(pt=b.clone(),dt[st]=pt,O.addEventListener("dispose",G)),b=pt}if(b.visible=O.visible,b.wireframe=O.wireframe,D===ia?b.side=O.shadowSide!==null?O.shadowSide:O.side:b.side=O.shadowSide!==null?O.shadowSide:v[O.side],b.alphaMap=O.alphaMap,b.alphaTest=O.alphaToCoverage===!0?.5:O.alphaTest,b.map=O.map,b.clipShadows=O.clipShadows,b.clippingPlanes=O.clippingPlanes,b.clipIntersection=O.clipIntersection,b.displacementMap=O.displacementMap,b.displacementScale=O.displacementScale,b.displacementBias=O.displacementBias,b.wireframeLinewidth=O.wireframeLinewidth,b.linewidth=O.linewidth,V.isPointLight===!0&&b.isMeshDistanceMaterial===!0){const rt=o.properties.get(b);rt.light=V}return b}function C(I,O,V,D,b){if(I.visible===!1)return;if(I.layers.test(O.layers)&&(I.isMesh||I.isLine||I.isPoints)&&(I.castShadow||I.receiveShadow&&b===ia)&&(!I.frustumCulled||r.intersectsObject(I))){I.modelViewMatrix.multiplyMatrices(V.matrixWorldInverse,I.matrixWorld);const st=e.update(I),dt=I.material;if(Array.isArray(dt)){const pt=st.groups;for(let P=0,Y=pt.length;P<Y;P++){const j=pt[P],vt=dt[j.materialIndex];if(vt&&vt.visible){const Tt=U(I,vt,D,b);I.onBeforeShadow(o,I,O,V,st,Tt,j),o.renderBufferDirect(V,null,st,Tt,I,j),I.onAfterShadow(o,I,O,V,st,Tt,j)}}}else if(dt.visible){const pt=U(I,dt,D,b);I.onBeforeShadow(o,I,O,V,st,pt,null),o.renderBufferDirect(V,null,st,pt,I,null),I.onAfterShadow(o,I,O,V,st,pt,null)}}const rt=I.children;for(let st=0,dt=rt.length;st<dt;st++)C(rt[st],O,V,D,b)}function G(I){I.target.removeEventListener("dispose",G);for(const V in p){const D=p[V],b=I.target.uuid;b in D&&(D[b].dispose(),delete D[b])}}}const cA={[Eh]:Th,[bh]:Ch,[Ah]:wh,[vs]:Rh,[Th]:Eh,[Ch]:bh,[wh]:Ah,[Rh]:vs};function fA(o,e){function i(){let W=!1;const Ct=new Ie;let lt=null;const _t=new Ie(0,0,0,0);return{setMask:function(At){lt!==At&&!W&&(o.colorMask(At,At,At,At),lt=At)},setLocked:function(At){W=At},setClear:function(At,wt,te,We,sn){sn===!0&&(At*=We,wt*=We,te*=We),Ct.set(At,wt,te,We),_t.equals(Ct)===!1&&(o.clearColor(At,wt,te,We),_t.copy(Ct))},reset:function(){W=!1,lt=null,_t.set(-1,0,0,0)}}}function r(){let W=!1,Ct=!1,lt=null,_t=null,At=null;return{setReversed:function(wt){if(Ct!==wt){const te=e.get("EXT_clip_control");wt?te.clipControlEXT(te.LOWER_LEFT_EXT,te.ZERO_TO_ONE_EXT):te.clipControlEXT(te.LOWER_LEFT_EXT,te.NEGATIVE_ONE_TO_ONE_EXT),Ct=wt;const We=At;At=null,this.setClear(We)}},getReversed:function(){return Ct},setTest:function(wt){wt?St(o.DEPTH_TEST):zt(o.DEPTH_TEST)},setMask:function(wt){lt!==wt&&!W&&(o.depthMask(wt),lt=wt)},setFunc:function(wt){if(Ct&&(wt=cA[wt]),_t!==wt){switch(wt){case Eh:o.depthFunc(o.NEVER);break;case Th:o.depthFunc(o.ALWAYS);break;case bh:o.depthFunc(o.LESS);break;case vs:o.depthFunc(o.LEQUAL);break;case Ah:o.depthFunc(o.EQUAL);break;case Rh:o.depthFunc(o.GEQUAL);break;case Ch:o.depthFunc(o.GREATER);break;case wh:o.depthFunc(o.NOTEQUAL);break;default:o.depthFunc(o.LEQUAL)}_t=wt}},setLocked:function(wt){W=wt},setClear:function(wt){At!==wt&&(Ct&&(wt=1-wt),o.clearDepth(wt),At=wt)},reset:function(){W=!1,lt=null,_t=null,At=null,Ct=!1}}}function l(){let W=!1,Ct=null,lt=null,_t=null,At=null,wt=null,te=null,We=null,sn=null;return{setTest:function(Ee){W||(Ee?St(o.STENCIL_TEST):zt(o.STENCIL_TEST))},setMask:function(Ee){Ct!==Ee&&!W&&(o.stencilMask(Ee),Ct=Ee)},setFunc:function(Ee,pn,ci){(lt!==Ee||_t!==pn||At!==ci)&&(o.stencilFunc(Ee,pn,ci),lt=Ee,_t=pn,At=ci)},setOp:function(Ee,pn,ci){(wt!==Ee||te!==pn||We!==ci)&&(o.stencilOp(Ee,pn,ci),wt=Ee,te=pn,We=ci)},setLocked:function(Ee){W=Ee},setClear:function(Ee){sn!==Ee&&(o.clearStencil(Ee),sn=Ee)},reset:function(){W=!1,Ct=null,lt=null,_t=null,At=null,wt=null,te=null,We=null,sn=null}}}const c=new i,h=new r,d=new l,m=new WeakMap,p=new WeakMap;let S={},v={},x=new WeakMap,y=[],R=null,w=!1,M=null,_=null,L=null,U=null,C=null,G=null,I=null,O=new Me(0,0,0),V=0,D=!1,b=null,B=null,rt=null,st=null,dt=null;const pt=o.getParameter(o.MAX_COMBINED_TEXTURE_IMAGE_UNITS);let P=!1,Y=0;const j=o.getParameter(o.VERSION);j.indexOf("WebGL")!==-1?(Y=parseFloat(/^WebGL (\d)/.exec(j)[1]),P=Y>=1):j.indexOf("OpenGL ES")!==-1&&(Y=parseFloat(/^OpenGL ES (\d)/.exec(j)[1]),P=Y>=2);let vt=null,Tt={};const z=o.getParameter(o.SCISSOR_BOX),nt=o.getParameter(o.VIEWPORT),xt=new Ie().fromArray(z),K=new Ie().fromArray(nt);function ft(W,Ct,lt,_t){const At=new Uint8Array(4),wt=o.createTexture();o.bindTexture(W,wt),o.texParameteri(W,o.TEXTURE_MIN_FILTER,o.NEAREST),o.texParameteri(W,o.TEXTURE_MAG_FILTER,o.NEAREST);for(let te=0;te<lt;te++)W===o.TEXTURE_3D||W===o.TEXTURE_2D_ARRAY?o.texImage3D(Ct,0,o.RGBA,1,1,_t,0,o.RGBA,o.UNSIGNED_BYTE,At):o.texImage2D(Ct+te,0,o.RGBA,1,1,0,o.RGBA,o.UNSIGNED_BYTE,At);return wt}const yt={};yt[o.TEXTURE_2D]=ft(o.TEXTURE_2D,o.TEXTURE_2D,1),yt[o.TEXTURE_CUBE_MAP]=ft(o.TEXTURE_CUBE_MAP,o.TEXTURE_CUBE_MAP_POSITIVE_X,6),yt[o.TEXTURE_2D_ARRAY]=ft(o.TEXTURE_2D_ARRAY,o.TEXTURE_2D_ARRAY,1,1),yt[o.TEXTURE_3D]=ft(o.TEXTURE_3D,o.TEXTURE_3D,1,1),c.setClear(0,0,0,1),h.setClear(1),d.setClear(0),St(o.DEPTH_TEST),h.setFunc(vs),ce(!1),de(__),St(o.CULL_FACE),H(Fa);function St(W){S[W]!==!0&&(o.enable(W),S[W]=!0)}function zt(W){S[W]!==!1&&(o.disable(W),S[W]=!1)}function qt(W,Ct){return v[W]!==Ct?(o.bindFramebuffer(W,Ct),v[W]=Ct,W===o.DRAW_FRAMEBUFFER&&(v[o.FRAMEBUFFER]=Ct),W===o.FRAMEBUFFER&&(v[o.DRAW_FRAMEBUFFER]=Ct),!0):!1}function jt(W,Ct){let lt=y,_t=!1;if(W){lt=x.get(Ct),lt===void 0&&(lt=[],x.set(Ct,lt));const At=W.textures;if(lt.length!==At.length||lt[0]!==o.COLOR_ATTACHMENT0){for(let wt=0,te=At.length;wt<te;wt++)lt[wt]=o.COLOR_ATTACHMENT0+wt;lt.length=At.length,_t=!0}}else lt[0]!==o.BACK&&(lt[0]=o.BACK,_t=!0);_t&&o.drawBuffers(lt)}function Ge(W){return R!==W?(o.useProgram(W),R=W,!0):!1}const Fe={[gr]:o.FUNC_ADD,[gx]:o.FUNC_SUBTRACT,[_x]:o.FUNC_REVERSE_SUBTRACT};Fe[vx]=o.MIN,Fe[Sx]=o.MAX;const ue={[xx]:o.ZERO,[Mx]:o.ONE,[yx]:o.SRC_COLOR,[Mh]:o.SRC_ALPHA,[Cx]:o.SRC_ALPHA_SATURATE,[Ax]:o.DST_COLOR,[Tx]:o.DST_ALPHA,[Ex]:o.ONE_MINUS_SRC_COLOR,[yh]:o.ONE_MINUS_SRC_ALPHA,[Rx]:o.ONE_MINUS_DST_COLOR,[bx]:o.ONE_MINUS_DST_ALPHA,[wx]:o.CONSTANT_COLOR,[Dx]:o.ONE_MINUS_CONSTANT_COLOR,[Ux]:o.CONSTANT_ALPHA,[Lx]:o.ONE_MINUS_CONSTANT_ALPHA};function H(W,Ct,lt,_t,At,wt,te,We,sn,Ee){if(W===Fa){w===!0&&(zt(o.BLEND),w=!1);return}if(w===!1&&(St(o.BLEND),w=!0),W!==mx){if(W!==M||Ee!==D){if((_!==gr||C!==gr)&&(o.blendEquation(o.FUNC_ADD),_=gr,C=gr),Ee)switch(W){case gs:o.blendFuncSeparate(o.ONE,o.ONE_MINUS_SRC_ALPHA,o.ONE,o.ONE_MINUS_SRC_ALPHA);break;case v_:o.blendFunc(o.ONE,o.ONE);break;case S_:o.blendFuncSeparate(o.ZERO,o.ONE_MINUS_SRC_COLOR,o.ZERO,o.ONE);break;case x_:o.blendFuncSeparate(o.ZERO,o.SRC_COLOR,o.ZERO,o.SRC_ALPHA);break;default:console.error("THREE.WebGLState: Invalid blending: ",W);break}else switch(W){case gs:o.blendFuncSeparate(o.SRC_ALPHA,o.ONE_MINUS_SRC_ALPHA,o.ONE,o.ONE_MINUS_SRC_ALPHA);break;case v_:o.blendFunc(o.SRC_ALPHA,o.ONE);break;case S_:o.blendFuncSeparate(o.ZERO,o.ONE_MINUS_SRC_COLOR,o.ZERO,o.ONE);break;case x_:o.blendFunc(o.ZERO,o.SRC_COLOR);break;default:console.error("THREE.WebGLState: Invalid blending: ",W);break}L=null,U=null,G=null,I=null,O.set(0,0,0),V=0,M=W,D=Ee}return}At=At||Ct,wt=wt||lt,te=te||_t,(Ct!==_||At!==C)&&(o.blendEquationSeparate(Fe[Ct],Fe[At]),_=Ct,C=At),(lt!==L||_t!==U||wt!==G||te!==I)&&(o.blendFuncSeparate(ue[lt],ue[_t],ue[wt],ue[te]),L=lt,U=_t,G=wt,I=te),(We.equals(O)===!1||sn!==V)&&(o.blendColor(We.r,We.g,We.b,sn),O.copy(We),V=sn),M=W,D=!1}function Mn(W,Ct){W.side===ra?zt(o.CULL_FACE):St(o.CULL_FACE);let lt=W.side===Gn;Ct&&(lt=!lt),ce(lt),W.blending===gs&&W.transparent===!1?H(Fa):H(W.blending,W.blendEquation,W.blendSrc,W.blendDst,W.blendEquationAlpha,W.blendSrcAlpha,W.blendDstAlpha,W.blendColor,W.blendAlpha,W.premultipliedAlpha),h.setFunc(W.depthFunc),h.setTest(W.depthTest),h.setMask(W.depthWrite),c.setMask(W.colorWrite);const _t=W.stencilWrite;d.setTest(_t),_t&&(d.setMask(W.stencilWriteMask),d.setFunc(W.stencilFunc,W.stencilRef,W.stencilFuncMask),d.setOp(W.stencilFail,W.stencilZFail,W.stencilZPass)),we(W.polygonOffset,W.polygonOffsetFactor,W.polygonOffsetUnits),W.alphaToCoverage===!0?St(o.SAMPLE_ALPHA_TO_COVERAGE):zt(o.SAMPLE_ALPHA_TO_COVERAGE)}function ce(W){b!==W&&(W?o.frontFace(o.CW):o.frontFace(o.CCW),b=W)}function de(W){W!==dx?(St(o.CULL_FACE),W!==B&&(W===__?o.cullFace(o.BACK):W===px?o.cullFace(o.FRONT):o.cullFace(o.FRONT_AND_BACK))):zt(o.CULL_FACE),B=W}function Vt(W){W!==rt&&(P&&o.lineWidth(W),rt=W)}function we(W,Ct,lt){W?(St(o.POLYGON_OFFSET_FILL),(st!==Ct||dt!==lt)&&(o.polygonOffset(Ct,lt),st=Ct,dt=lt)):zt(o.POLYGON_OFFSET_FILL)}function Gt(W){W?St(o.SCISSOR_TEST):zt(o.SCISSOR_TEST)}function N(W){W===void 0&&(W=o.TEXTURE0+pt-1),vt!==W&&(o.activeTexture(W),vt=W)}function T(W,Ct,lt){lt===void 0&&(vt===null?lt=o.TEXTURE0+pt-1:lt=vt);let _t=Tt[lt];_t===void 0&&(_t={type:void 0,texture:void 0},Tt[lt]=_t),(_t.type!==W||_t.texture!==Ct)&&(vt!==lt&&(o.activeTexture(lt),vt=lt),o.bindTexture(W,Ct||yt[W]),_t.type=W,_t.texture=Ct)}function et(){const W=Tt[vt];W!==void 0&&W.type!==void 0&&(o.bindTexture(W.type,null),W.type=void 0,W.texture=void 0)}function ct(){try{o.compressedTexImage2D(...arguments)}catch(W){console.error("THREE.WebGLState:",W)}}function Mt(){try{o.compressedTexImage3D(...arguments)}catch(W){console.error("THREE.WebGLState:",W)}}function mt(){try{o.texSubImage2D(...arguments)}catch(W){console.error("THREE.WebGLState:",W)}}function Ft(){try{o.texSubImage3D(...arguments)}catch(W){console.error("THREE.WebGLState:",W)}}function Rt(){try{o.compressedTexSubImage2D(...arguments)}catch(W){console.error("THREE.WebGLState:",W)}}function Zt(){try{o.compressedTexSubImage3D(...arguments)}catch(W){console.error("THREE.WebGLState:",W)}}function Qt(){try{o.texStorage2D(...arguments)}catch(W){console.error("THREE.WebGLState:",W)}}function bt(){try{o.texStorage3D(...arguments)}catch(W){console.error("THREE.WebGLState:",W)}}function Pt(){try{o.texImage2D(...arguments)}catch(W){console.error("THREE.WebGLState:",W)}}function Yt(){try{o.texImage3D(...arguments)}catch(W){console.error("THREE.WebGLState:",W)}}function Ht(W){xt.equals(W)===!1&&(o.scissor(W.x,W.y,W.z,W.w),xt.copy(W))}function Nt(W){K.equals(W)===!1&&(o.viewport(W.x,W.y,W.z,W.w),K.copy(W))}function $t(W,Ct){let lt=p.get(Ct);lt===void 0&&(lt=new WeakMap,p.set(Ct,lt));let _t=lt.get(W);_t===void 0&&(_t=o.getUniformBlockIndex(Ct,W.name),lt.set(W,_t))}function ae(W,Ct){const _t=p.get(Ct).get(W);m.get(Ct)!==_t&&(o.uniformBlockBinding(Ct,_t,W.__bindingPointIndex),m.set(Ct,_t))}function Le(){o.disable(o.BLEND),o.disable(o.CULL_FACE),o.disable(o.DEPTH_TEST),o.disable(o.POLYGON_OFFSET_FILL),o.disable(o.SCISSOR_TEST),o.disable(o.STENCIL_TEST),o.disable(o.SAMPLE_ALPHA_TO_COVERAGE),o.blendEquation(o.FUNC_ADD),o.blendFunc(o.ONE,o.ZERO),o.blendFuncSeparate(o.ONE,o.ZERO,o.ONE,o.ZERO),o.blendColor(0,0,0,0),o.colorMask(!0,!0,!0,!0),o.clearColor(0,0,0,0),o.depthMask(!0),o.depthFunc(o.LESS),h.setReversed(!1),o.clearDepth(1),o.stencilMask(4294967295),o.stencilFunc(o.ALWAYS,0,4294967295),o.stencilOp(o.KEEP,o.KEEP,o.KEEP),o.clearStencil(0),o.cullFace(o.BACK),o.frontFace(o.CCW),o.polygonOffset(0,0),o.activeTexture(o.TEXTURE0),o.bindFramebuffer(o.FRAMEBUFFER,null),o.bindFramebuffer(o.DRAW_FRAMEBUFFER,null),o.bindFramebuffer(o.READ_FRAMEBUFFER,null),o.useProgram(null),o.lineWidth(1),o.scissor(0,0,o.canvas.width,o.canvas.height),o.viewport(0,0,o.canvas.width,o.canvas.height),S={},vt=null,Tt={},v={},x=new WeakMap,y=[],R=null,w=!1,M=null,_=null,L=null,U=null,C=null,G=null,I=null,O=new Me(0,0,0),V=0,D=!1,b=null,B=null,rt=null,st=null,dt=null,xt.set(0,0,o.canvas.width,o.canvas.height),K.set(0,0,o.canvas.width,o.canvas.height),c.reset(),h.reset(),d.reset()}return{buffers:{color:c,depth:h,stencil:d},enable:St,disable:zt,bindFramebuffer:qt,drawBuffers:jt,useProgram:Ge,setBlending:H,setMaterial:Mn,setFlipSided:ce,setCullFace:de,setLineWidth:Vt,setPolygonOffset:we,setScissorTest:Gt,activeTexture:N,bindTexture:T,unbindTexture:et,compressedTexImage2D:ct,compressedTexImage3D:Mt,texImage2D:Pt,texImage3D:Yt,updateUBOMapping:$t,uniformBlockBinding:ae,texStorage2D:Qt,texStorage3D:bt,texSubImage2D:mt,texSubImage3D:Ft,compressedTexSubImage2D:Rt,compressedTexSubImage3D:Zt,scissor:Ht,viewport:Nt,reset:Le}}function hA(o,e,i,r,l,c,h){const d=e.has("WEBGL_multisampled_render_to_texture")?e.get("WEBGL_multisampled_render_to_texture"):null,m=typeof navigator>"u"?!1:/OculusBrowser/g.test(navigator.userAgent),p=new ye,S=new WeakMap;let v;const x=new WeakMap;let y=!1;try{y=typeof OffscreenCanvas<"u"&&new OffscreenCanvas(1,1).getContext("2d")!==null}catch{}function R(N,T){return y?new OffscreenCanvas(N,T):bu("canvas")}function w(N,T,et){let ct=1;const Mt=Gt(N);if((Mt.width>et||Mt.height>et)&&(ct=et/Math.max(Mt.width,Mt.height)),ct<1)if(typeof HTMLImageElement<"u"&&N instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&N instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&N instanceof ImageBitmap||typeof VideoFrame<"u"&&N instanceof VideoFrame){const mt=Math.floor(ct*Mt.width),Ft=Math.floor(ct*Mt.height);v===void 0&&(v=R(mt,Ft));const Rt=T?R(mt,Ft):v;return Rt.width=mt,Rt.height=Ft,Rt.getContext("2d").drawImage(N,0,0,mt,Ft),console.warn("THREE.WebGLRenderer: Texture has been resized from ("+Mt.width+"x"+Mt.height+") to ("+mt+"x"+Ft+")."),Rt}else return"data"in N&&console.warn("THREE.WebGLRenderer: Image in DataTexture is too big ("+Mt.width+"x"+Mt.height+")."),N;return N}function M(N){return N.generateMipmaps}function _(N){o.generateMipmap(N)}function L(N){return N.isWebGLCubeRenderTarget?o.TEXTURE_CUBE_MAP:N.isWebGL3DRenderTarget?o.TEXTURE_3D:N.isWebGLArrayRenderTarget||N.isCompressedArrayTexture?o.TEXTURE_2D_ARRAY:o.TEXTURE_2D}function U(N,T,et,ct,Mt=!1){if(N!==null){if(o[N]!==void 0)return o[N];console.warn("THREE.WebGLRenderer: Attempt to use non-existing WebGL internal format '"+N+"'")}let mt=T;if(T===o.RED&&(et===o.FLOAT&&(mt=o.R32F),et===o.HALF_FLOAT&&(mt=o.R16F),et===o.UNSIGNED_BYTE&&(mt=o.R8)),T===o.RED_INTEGER&&(et===o.UNSIGNED_BYTE&&(mt=o.R8UI),et===o.UNSIGNED_SHORT&&(mt=o.R16UI),et===o.UNSIGNED_INT&&(mt=o.R32UI),et===o.BYTE&&(mt=o.R8I),et===o.SHORT&&(mt=o.R16I),et===o.INT&&(mt=o.R32I)),T===o.RG&&(et===o.FLOAT&&(mt=o.RG32F),et===o.HALF_FLOAT&&(mt=o.RG16F),et===o.UNSIGNED_BYTE&&(mt=o.RG8)),T===o.RG_INTEGER&&(et===o.UNSIGNED_BYTE&&(mt=o.RG8UI),et===o.UNSIGNED_SHORT&&(mt=o.RG16UI),et===o.UNSIGNED_INT&&(mt=o.RG32UI),et===o.BYTE&&(mt=o.RG8I),et===o.SHORT&&(mt=o.RG16I),et===o.INT&&(mt=o.RG32I)),T===o.RGB_INTEGER&&(et===o.UNSIGNED_BYTE&&(mt=o.RGB8UI),et===o.UNSIGNED_SHORT&&(mt=o.RGB16UI),et===o.UNSIGNED_INT&&(mt=o.RGB32UI),et===o.BYTE&&(mt=o.RGB8I),et===o.SHORT&&(mt=o.RGB16I),et===o.INT&&(mt=o.RGB32I)),T===o.RGBA_INTEGER&&(et===o.UNSIGNED_BYTE&&(mt=o.RGBA8UI),et===o.UNSIGNED_SHORT&&(mt=o.RGBA16UI),et===o.UNSIGNED_INT&&(mt=o.RGBA32UI),et===o.BYTE&&(mt=o.RGBA8I),et===o.SHORT&&(mt=o.RGBA16I),et===o.INT&&(mt=o.RGBA32I)),T===o.RGB&&et===o.UNSIGNED_INT_5_9_9_9_REV&&(mt=o.RGB9_E5),T===o.RGBA){const Ft=Mt?Eu:Re.getTransfer(ct);et===o.FLOAT&&(mt=o.RGBA32F),et===o.HALF_FLOAT&&(mt=o.RGBA16F),et===o.UNSIGNED_BYTE&&(mt=Ft===Be?o.SRGB8_ALPHA8:o.RGBA8),et===o.UNSIGNED_SHORT_4_4_4_4&&(mt=o.RGBA4),et===o.UNSIGNED_SHORT_5_5_5_1&&(mt=o.RGB5_A1)}return(mt===o.R16F||mt===o.R32F||mt===o.RG16F||mt===o.RG32F||mt===o.RGBA16F||mt===o.RGBA32F)&&e.get("EXT_color_buffer_float"),mt}function C(N,T){let et;return N?T===null||T===xr||T===Co?et=o.DEPTH24_STENCIL8:T===sa?et=o.DEPTH32F_STENCIL8:T===Ro&&(et=o.DEPTH24_STENCIL8,console.warn("DepthTexture: 16 bit depth attachment is not supported with stencil. Using 24-bit attachment.")):T===null||T===xr||T===Co?et=o.DEPTH_COMPONENT24:T===sa?et=o.DEPTH_COMPONENT32F:T===Ro&&(et=o.DEPTH_COMPONENT16),et}function G(N,T){return M(N)===!0||N.isFramebufferTexture&&N.minFilter!==yi&&N.minFilter!==wi?Math.log2(Math.max(T.width,T.height))+1:N.mipmaps!==void 0&&N.mipmaps.length>0?N.mipmaps.length:N.isCompressedTexture&&Array.isArray(N.image)?T.mipmaps.length:1}function I(N){const T=N.target;T.removeEventListener("dispose",I),V(T),T.isVideoTexture&&S.delete(T)}function O(N){const T=N.target;T.removeEventListener("dispose",O),b(T)}function V(N){const T=r.get(N);if(T.__webglInit===void 0)return;const et=N.source,ct=x.get(et);if(ct){const Mt=ct[T.__cacheKey];Mt.usedTimes--,Mt.usedTimes===0&&D(N),Object.keys(ct).length===0&&x.delete(et)}r.remove(N)}function D(N){const T=r.get(N);o.deleteTexture(T.__webglTexture);const et=N.source,ct=x.get(et);delete ct[T.__cacheKey],h.memory.textures--}function b(N){const T=r.get(N);if(N.depthTexture&&(N.depthTexture.dispose(),r.remove(N.depthTexture)),N.isWebGLCubeRenderTarget)for(let ct=0;ct<6;ct++){if(Array.isArray(T.__webglFramebuffer[ct]))for(let Mt=0;Mt<T.__webglFramebuffer[ct].length;Mt++)o.deleteFramebuffer(T.__webglFramebuffer[ct][Mt]);else o.deleteFramebuffer(T.__webglFramebuffer[ct]);T.__webglDepthbuffer&&o.deleteRenderbuffer(T.__webglDepthbuffer[ct])}else{if(Array.isArray(T.__webglFramebuffer))for(let ct=0;ct<T.__webglFramebuffer.length;ct++)o.deleteFramebuffer(T.__webglFramebuffer[ct]);else o.deleteFramebuffer(T.__webglFramebuffer);if(T.__webglDepthbuffer&&o.deleteRenderbuffer(T.__webglDepthbuffer),T.__webglMultisampledFramebuffer&&o.deleteFramebuffer(T.__webglMultisampledFramebuffer),T.__webglColorRenderbuffer)for(let ct=0;ct<T.__webglColorRenderbuffer.length;ct++)T.__webglColorRenderbuffer[ct]&&o.deleteRenderbuffer(T.__webglColorRenderbuffer[ct]);T.__webglDepthRenderbuffer&&o.deleteRenderbuffer(T.__webglDepthRenderbuffer)}const et=N.textures;for(let ct=0,Mt=et.length;ct<Mt;ct++){const mt=r.get(et[ct]);mt.__webglTexture&&(o.deleteTexture(mt.__webglTexture),h.memory.textures--),r.remove(et[ct])}r.remove(N)}let B=0;function rt(){B=0}function st(){const N=B;return N>=l.maxTextures&&console.warn("THREE.WebGLTextures: Trying to use "+N+" texture units while this GPU supports only "+l.maxTextures),B+=1,N}function dt(N){const T=[];return T.push(N.wrapS),T.push(N.wrapT),T.push(N.wrapR||0),T.push(N.magFilter),T.push(N.minFilter),T.push(N.anisotropy),T.push(N.internalFormat),T.push(N.format),T.push(N.type),T.push(N.generateMipmaps),T.push(N.premultiplyAlpha),T.push(N.flipY),T.push(N.unpackAlignment),T.push(N.colorSpace),T.join()}function pt(N,T){const et=r.get(N);if(N.isVideoTexture&&Vt(N),N.isRenderTargetTexture===!1&&N.version>0&&et.__version!==N.version){const ct=N.image;if(ct===null)console.warn("THREE.WebGLRenderer: Texture marked for update but no image data found.");else if(ct.complete===!1)console.warn("THREE.WebGLRenderer: Texture marked for update but image is incomplete");else{K(et,N,T);return}}i.bindTexture(o.TEXTURE_2D,et.__webglTexture,o.TEXTURE0+T)}function P(N,T){const et=r.get(N);if(N.version>0&&et.__version!==N.version){K(et,N,T);return}i.bindTexture(o.TEXTURE_2D_ARRAY,et.__webglTexture,o.TEXTURE0+T)}function Y(N,T){const et=r.get(N);if(N.version>0&&et.__version!==N.version){K(et,N,T);return}i.bindTexture(o.TEXTURE_3D,et.__webglTexture,o.TEXTURE0+T)}function j(N,T){const et=r.get(N);if(N.version>0&&et.__version!==N.version){ft(et,N,T);return}i.bindTexture(o.TEXTURE_CUBE_MAP,et.__webglTexture,o.TEXTURE0+T)}const vt={[Lh]:o.REPEAT,[vr]:o.CLAMP_TO_EDGE,[Nh]:o.MIRRORED_REPEAT},Tt={[yi]:o.NEAREST,[Gx]:o.NEAREST_MIPMAP_NEAREST,[Yl]:o.NEAREST_MIPMAP_LINEAR,[wi]:o.LINEAR,[Vf]:o.LINEAR_MIPMAP_NEAREST,[Sr]:o.LINEAR_MIPMAP_LINEAR},z={[Wx]:o.NEVER,[Qx]:o.ALWAYS,[qx]:o.LESS,[O0]:o.LEQUAL,[Yx]:o.EQUAL,[Kx]:o.GEQUAL,[jx]:o.GREATER,[Zx]:o.NOTEQUAL};function nt(N,T){if(T.type===sa&&e.has("OES_texture_float_linear")===!1&&(T.magFilter===wi||T.magFilter===Vf||T.magFilter===Yl||T.magFilter===Sr||T.minFilter===wi||T.minFilter===Vf||T.minFilter===Yl||T.minFilter===Sr)&&console.warn("THREE.WebGLRenderer: Unable to use linear filtering with floating point textures. OES_texture_float_linear not supported on this device."),o.texParameteri(N,o.TEXTURE_WRAP_S,vt[T.wrapS]),o.texParameteri(N,o.TEXTURE_WRAP_T,vt[T.wrapT]),(N===o.TEXTURE_3D||N===o.TEXTURE_2D_ARRAY)&&o.texParameteri(N,o.TEXTURE_WRAP_R,vt[T.wrapR]),o.texParameteri(N,o.TEXTURE_MAG_FILTER,Tt[T.magFilter]),o.texParameteri(N,o.TEXTURE_MIN_FILTER,Tt[T.minFilter]),T.compareFunction&&(o.texParameteri(N,o.TEXTURE_COMPARE_MODE,o.COMPARE_REF_TO_TEXTURE),o.texParameteri(N,o.TEXTURE_COMPARE_FUNC,z[T.compareFunction])),e.has("EXT_texture_filter_anisotropic")===!0){if(T.magFilter===yi||T.minFilter!==Yl&&T.minFilter!==Sr||T.type===sa&&e.has("OES_texture_float_linear")===!1)return;if(T.anisotropy>1||r.get(T).__currentAnisotropy){const et=e.get("EXT_texture_filter_anisotropic");o.texParameterf(N,et.TEXTURE_MAX_ANISOTROPY_EXT,Math.min(T.anisotropy,l.getMaxAnisotropy())),r.get(T).__currentAnisotropy=T.anisotropy}}}function xt(N,T){let et=!1;N.__webglInit===void 0&&(N.__webglInit=!0,T.addEventListener("dispose",I));const ct=T.source;let Mt=x.get(ct);Mt===void 0&&(Mt={},x.set(ct,Mt));const mt=dt(T);if(mt!==N.__cacheKey){Mt[mt]===void 0&&(Mt[mt]={texture:o.createTexture(),usedTimes:0},h.memory.textures++,et=!0),Mt[mt].usedTimes++;const Ft=Mt[N.__cacheKey];Ft!==void 0&&(Mt[N.__cacheKey].usedTimes--,Ft.usedTimes===0&&D(T)),N.__cacheKey=mt,N.__webglTexture=Mt[mt].texture}return et}function K(N,T,et){let ct=o.TEXTURE_2D;(T.isDataArrayTexture||T.isCompressedArrayTexture)&&(ct=o.TEXTURE_2D_ARRAY),T.isData3DTexture&&(ct=o.TEXTURE_3D);const Mt=xt(N,T),mt=T.source;i.bindTexture(ct,N.__webglTexture,o.TEXTURE0+et);const Ft=r.get(mt);if(mt.version!==Ft.__version||Mt===!0){i.activeTexture(o.TEXTURE0+et);const Rt=Re.getPrimaries(Re.workingColorSpace),Zt=T.colorSpace===Ia?null:Re.getPrimaries(T.colorSpace),Qt=T.colorSpace===Ia||Rt===Zt?o.NONE:o.BROWSER_DEFAULT_WEBGL;o.pixelStorei(o.UNPACK_FLIP_Y_WEBGL,T.flipY),o.pixelStorei(o.UNPACK_PREMULTIPLY_ALPHA_WEBGL,T.premultiplyAlpha),o.pixelStorei(o.UNPACK_ALIGNMENT,T.unpackAlignment),o.pixelStorei(o.UNPACK_COLORSPACE_CONVERSION_WEBGL,Qt);let bt=w(T.image,!1,l.maxTextureSize);bt=we(T,bt);const Pt=c.convert(T.format,T.colorSpace),Yt=c.convert(T.type);let Ht=U(T.internalFormat,Pt,Yt,T.colorSpace,T.isVideoTexture);nt(ct,T);let Nt;const $t=T.mipmaps,ae=T.isVideoTexture!==!0,Le=Ft.__version===void 0||Mt===!0,W=mt.dataReady,Ct=G(T,bt);if(T.isDepthTexture)Ht=C(T.format===Do,T.type),Le&&(ae?i.texStorage2D(o.TEXTURE_2D,1,Ht,bt.width,bt.height):i.texImage2D(o.TEXTURE_2D,0,Ht,bt.width,bt.height,0,Pt,Yt,null));else if(T.isDataTexture)if($t.length>0){ae&&Le&&i.texStorage2D(o.TEXTURE_2D,Ct,Ht,$t[0].width,$t[0].height);for(let lt=0,_t=$t.length;lt<_t;lt++)Nt=$t[lt],ae?W&&i.texSubImage2D(o.TEXTURE_2D,lt,0,0,Nt.width,Nt.height,Pt,Yt,Nt.data):i.texImage2D(o.TEXTURE_2D,lt,Ht,Nt.width,Nt.height,0,Pt,Yt,Nt.data);T.generateMipmaps=!1}else ae?(Le&&i.texStorage2D(o.TEXTURE_2D,Ct,Ht,bt.width,bt.height),W&&i.texSubImage2D(o.TEXTURE_2D,0,0,0,bt.width,bt.height,Pt,Yt,bt.data)):i.texImage2D(o.TEXTURE_2D,0,Ht,bt.width,bt.height,0,Pt,Yt,bt.data);else if(T.isCompressedTexture)if(T.isCompressedArrayTexture){ae&&Le&&i.texStorage3D(o.TEXTURE_2D_ARRAY,Ct,Ht,$t[0].width,$t[0].height,bt.depth);for(let lt=0,_t=$t.length;lt<_t;lt++)if(Nt=$t[lt],T.format!==Mi)if(Pt!==null)if(ae){if(W)if(T.layerUpdates.size>0){const At=q_(Nt.width,Nt.height,T.format,T.type);for(const wt of T.layerUpdates){const te=Nt.data.subarray(wt*At/Nt.data.BYTES_PER_ELEMENT,(wt+1)*At/Nt.data.BYTES_PER_ELEMENT);i.compressedTexSubImage3D(o.TEXTURE_2D_ARRAY,lt,0,0,wt,Nt.width,Nt.height,1,Pt,te)}T.clearLayerUpdates()}else i.compressedTexSubImage3D(o.TEXTURE_2D_ARRAY,lt,0,0,0,Nt.width,Nt.height,bt.depth,Pt,Nt.data)}else i.compressedTexImage3D(o.TEXTURE_2D_ARRAY,lt,Ht,Nt.width,Nt.height,bt.depth,0,Nt.data,0,0);else console.warn("THREE.WebGLRenderer: Attempt to load unsupported compressed texture format in .uploadTexture()");else ae?W&&i.texSubImage3D(o.TEXTURE_2D_ARRAY,lt,0,0,0,Nt.width,Nt.height,bt.depth,Pt,Yt,Nt.data):i.texImage3D(o.TEXTURE_2D_ARRAY,lt,Ht,Nt.width,Nt.height,bt.depth,0,Pt,Yt,Nt.data)}else{ae&&Le&&i.texStorage2D(o.TEXTURE_2D,Ct,Ht,$t[0].width,$t[0].height);for(let lt=0,_t=$t.length;lt<_t;lt++)Nt=$t[lt],T.format!==Mi?Pt!==null?ae?W&&i.compressedTexSubImage2D(o.TEXTURE_2D,lt,0,0,Nt.width,Nt.height,Pt,Nt.data):i.compressedTexImage2D(o.TEXTURE_2D,lt,Ht,Nt.width,Nt.height,0,Nt.data):console.warn("THREE.WebGLRenderer: Attempt to load unsupported compressed texture format in .uploadTexture()"):ae?W&&i.texSubImage2D(o.TEXTURE_2D,lt,0,0,Nt.width,Nt.height,Pt,Yt,Nt.data):i.texImage2D(o.TEXTURE_2D,lt,Ht,Nt.width,Nt.height,0,Pt,Yt,Nt.data)}else if(T.isDataArrayTexture)if(ae){if(Le&&i.texStorage3D(o.TEXTURE_2D_ARRAY,Ct,Ht,bt.width,bt.height,bt.depth),W)if(T.layerUpdates.size>0){const lt=q_(bt.width,bt.height,T.format,T.type);for(const _t of T.layerUpdates){const At=bt.data.subarray(_t*lt/bt.data.BYTES_PER_ELEMENT,(_t+1)*lt/bt.data.BYTES_PER_ELEMENT);i.texSubImage3D(o.TEXTURE_2D_ARRAY,0,0,0,_t,bt.width,bt.height,1,Pt,Yt,At)}T.clearLayerUpdates()}else i.texSubImage3D(o.TEXTURE_2D_ARRAY,0,0,0,0,bt.width,bt.height,bt.depth,Pt,Yt,bt.data)}else i.texImage3D(o.TEXTURE_2D_ARRAY,0,Ht,bt.width,bt.height,bt.depth,0,Pt,Yt,bt.data);else if(T.isData3DTexture)ae?(Le&&i.texStorage3D(o.TEXTURE_3D,Ct,Ht,bt.width,bt.height,bt.depth),W&&i.texSubImage3D(o.TEXTURE_3D,0,0,0,0,bt.width,bt.height,bt.depth,Pt,Yt,bt.data)):i.texImage3D(o.TEXTURE_3D,0,Ht,bt.width,bt.height,bt.depth,0,Pt,Yt,bt.data);else if(T.isFramebufferTexture){if(Le)if(ae)i.texStorage2D(o.TEXTURE_2D,Ct,Ht,bt.width,bt.height);else{let lt=bt.width,_t=bt.height;for(let At=0;At<Ct;At++)i.texImage2D(o.TEXTURE_2D,At,Ht,lt,_t,0,Pt,Yt,null),lt>>=1,_t>>=1}}else if($t.length>0){if(ae&&Le){const lt=Gt($t[0]);i.texStorage2D(o.TEXTURE_2D,Ct,Ht,lt.width,lt.height)}for(let lt=0,_t=$t.length;lt<_t;lt++)Nt=$t[lt],ae?W&&i.texSubImage2D(o.TEXTURE_2D,lt,0,0,Pt,Yt,Nt):i.texImage2D(o.TEXTURE_2D,lt,Ht,Pt,Yt,Nt);T.generateMipmaps=!1}else if(ae){if(Le){const lt=Gt(bt);i.texStorage2D(o.TEXTURE_2D,Ct,Ht,lt.width,lt.height)}W&&i.texSubImage2D(o.TEXTURE_2D,0,0,0,Pt,Yt,bt)}else i.texImage2D(o.TEXTURE_2D,0,Ht,Pt,Yt,bt);M(T)&&_(ct),Ft.__version=mt.version,T.onUpdate&&T.onUpdate(T)}N.__version=T.version}function ft(N,T,et){if(T.image.length!==6)return;const ct=xt(N,T),Mt=T.source;i.bindTexture(o.TEXTURE_CUBE_MAP,N.__webglTexture,o.TEXTURE0+et);const mt=r.get(Mt);if(Mt.version!==mt.__version||ct===!0){i.activeTexture(o.TEXTURE0+et);const Ft=Re.getPrimaries(Re.workingColorSpace),Rt=T.colorSpace===Ia?null:Re.getPrimaries(T.colorSpace),Zt=T.colorSpace===Ia||Ft===Rt?o.NONE:o.BROWSER_DEFAULT_WEBGL;o.pixelStorei(o.UNPACK_FLIP_Y_WEBGL,T.flipY),o.pixelStorei(o.UNPACK_PREMULTIPLY_ALPHA_WEBGL,T.premultiplyAlpha),o.pixelStorei(o.UNPACK_ALIGNMENT,T.unpackAlignment),o.pixelStorei(o.UNPACK_COLORSPACE_CONVERSION_WEBGL,Zt);const Qt=T.isCompressedTexture||T.image[0].isCompressedTexture,bt=T.image[0]&&T.image[0].isDataTexture,Pt=[];for(let _t=0;_t<6;_t++)!Qt&&!bt?Pt[_t]=w(T.image[_t],!0,l.maxCubemapSize):Pt[_t]=bt?T.image[_t].image:T.image[_t],Pt[_t]=we(T,Pt[_t]);const Yt=Pt[0],Ht=c.convert(T.format,T.colorSpace),Nt=c.convert(T.type),$t=U(T.internalFormat,Ht,Nt,T.colorSpace),ae=T.isVideoTexture!==!0,Le=mt.__version===void 0||ct===!0,W=Mt.dataReady;let Ct=G(T,Yt);nt(o.TEXTURE_CUBE_MAP,T);let lt;if(Qt){ae&&Le&&i.texStorage2D(o.TEXTURE_CUBE_MAP,Ct,$t,Yt.width,Yt.height);for(let _t=0;_t<6;_t++){lt=Pt[_t].mipmaps;for(let At=0;At<lt.length;At++){const wt=lt[At];T.format!==Mi?Ht!==null?ae?W&&i.compressedTexSubImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_t,At,0,0,wt.width,wt.height,Ht,wt.data):i.compressedTexImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_t,At,$t,wt.width,wt.height,0,wt.data):console.warn("THREE.WebGLRenderer: Attempt to load unsupported compressed texture format in .setTextureCube()"):ae?W&&i.texSubImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_t,At,0,0,wt.width,wt.height,Ht,Nt,wt.data):i.texImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_t,At,$t,wt.width,wt.height,0,Ht,Nt,wt.data)}}}else{if(lt=T.mipmaps,ae&&Le){lt.length>0&&Ct++;const _t=Gt(Pt[0]);i.texStorage2D(o.TEXTURE_CUBE_MAP,Ct,$t,_t.width,_t.height)}for(let _t=0;_t<6;_t++)if(bt){ae?W&&i.texSubImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_t,0,0,0,Pt[_t].width,Pt[_t].height,Ht,Nt,Pt[_t].data):i.texImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_t,0,$t,Pt[_t].width,Pt[_t].height,0,Ht,Nt,Pt[_t].data);for(let At=0;At<lt.length;At++){const te=lt[At].image[_t].image;ae?W&&i.texSubImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_t,At+1,0,0,te.width,te.height,Ht,Nt,te.data):i.texImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_t,At+1,$t,te.width,te.height,0,Ht,Nt,te.data)}}else{ae?W&&i.texSubImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_t,0,0,0,Ht,Nt,Pt[_t]):i.texImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_t,0,$t,Ht,Nt,Pt[_t]);for(let At=0;At<lt.length;At++){const wt=lt[At];ae?W&&i.texSubImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_t,At+1,0,0,Ht,Nt,wt.image[_t]):i.texImage2D(o.TEXTURE_CUBE_MAP_POSITIVE_X+_t,At+1,$t,Ht,Nt,wt.image[_t])}}}M(T)&&_(o.TEXTURE_CUBE_MAP),mt.__version=Mt.version,T.onUpdate&&T.onUpdate(T)}N.__version=T.version}function yt(N,T,et,ct,Mt,mt){const Ft=c.convert(et.format,et.colorSpace),Rt=c.convert(et.type),Zt=U(et.internalFormat,Ft,Rt,et.colorSpace),Qt=r.get(T),bt=r.get(et);if(bt.__renderTarget=T,!Qt.__hasExternalTextures){const Pt=Math.max(1,T.width>>mt),Yt=Math.max(1,T.height>>mt);Mt===o.TEXTURE_3D||Mt===o.TEXTURE_2D_ARRAY?i.texImage3D(Mt,mt,Zt,Pt,Yt,T.depth,0,Ft,Rt,null):i.texImage2D(Mt,mt,Zt,Pt,Yt,0,Ft,Rt,null)}i.bindFramebuffer(o.FRAMEBUFFER,N),de(T)?d.framebufferTexture2DMultisampleEXT(o.FRAMEBUFFER,ct,Mt,bt.__webglTexture,0,ce(T)):(Mt===o.TEXTURE_2D||Mt>=o.TEXTURE_CUBE_MAP_POSITIVE_X&&Mt<=o.TEXTURE_CUBE_MAP_NEGATIVE_Z)&&o.framebufferTexture2D(o.FRAMEBUFFER,ct,Mt,bt.__webglTexture,mt),i.bindFramebuffer(o.FRAMEBUFFER,null)}function St(N,T,et){if(o.bindRenderbuffer(o.RENDERBUFFER,N),T.depthBuffer){const ct=T.depthTexture,Mt=ct&&ct.isDepthTexture?ct.type:null,mt=C(T.stencilBuffer,Mt),Ft=T.stencilBuffer?o.DEPTH_STENCIL_ATTACHMENT:o.DEPTH_ATTACHMENT,Rt=ce(T);de(T)?d.renderbufferStorageMultisampleEXT(o.RENDERBUFFER,Rt,mt,T.width,T.height):et?o.renderbufferStorageMultisample(o.RENDERBUFFER,Rt,mt,T.width,T.height):o.renderbufferStorage(o.RENDERBUFFER,mt,T.width,T.height),o.framebufferRenderbuffer(o.FRAMEBUFFER,Ft,o.RENDERBUFFER,N)}else{const ct=T.textures;for(let Mt=0;Mt<ct.length;Mt++){const mt=ct[Mt],Ft=c.convert(mt.format,mt.colorSpace),Rt=c.convert(mt.type),Zt=U(mt.internalFormat,Ft,Rt,mt.colorSpace),Qt=ce(T);et&&de(T)===!1?o.renderbufferStorageMultisample(o.RENDERBUFFER,Qt,Zt,T.width,T.height):de(T)?d.renderbufferStorageMultisampleEXT(o.RENDERBUFFER,Qt,Zt,T.width,T.height):o.renderbufferStorage(o.RENDERBUFFER,Zt,T.width,T.height)}}o.bindRenderbuffer(o.RENDERBUFFER,null)}function zt(N,T){if(T&&T.isWebGLCubeRenderTarget)throw new Error("Depth Texture with cube render targets is not supported");if(i.bindFramebuffer(o.FRAMEBUFFER,N),!(T.depthTexture&&T.depthTexture.isDepthTexture))throw new Error("renderTarget.depthTexture must be an instance of THREE.DepthTexture");const ct=r.get(T.depthTexture);ct.__renderTarget=T,(!ct.__webglTexture||T.depthTexture.image.width!==T.width||T.depthTexture.image.height!==T.height)&&(T.depthTexture.image.width=T.width,T.depthTexture.image.height=T.height,T.depthTexture.needsUpdate=!0),pt(T.depthTexture,0);const Mt=ct.__webglTexture,mt=ce(T);if(T.depthTexture.format===wo)de(T)?d.framebufferTexture2DMultisampleEXT(o.FRAMEBUFFER,o.DEPTH_ATTACHMENT,o.TEXTURE_2D,Mt,0,mt):o.framebufferTexture2D(o.FRAMEBUFFER,o.DEPTH_ATTACHMENT,o.TEXTURE_2D,Mt,0);else if(T.depthTexture.format===Do)de(T)?d.framebufferTexture2DMultisampleEXT(o.FRAMEBUFFER,o.DEPTH_STENCIL_ATTACHMENT,o.TEXTURE_2D,Mt,0,mt):o.framebufferTexture2D(o.FRAMEBUFFER,o.DEPTH_STENCIL_ATTACHMENT,o.TEXTURE_2D,Mt,0);else throw new Error("Unknown depthTexture format")}function qt(N){const T=r.get(N),et=N.isWebGLCubeRenderTarget===!0;if(T.__boundDepthTexture!==N.depthTexture){const ct=N.depthTexture;if(T.__depthDisposeCallback&&T.__depthDisposeCallback(),ct){const Mt=()=>{delete T.__boundDepthTexture,delete T.__depthDisposeCallback,ct.removeEventListener("dispose",Mt)};ct.addEventListener("dispose",Mt),T.__depthDisposeCallback=Mt}T.__boundDepthTexture=ct}if(N.depthTexture&&!T.__autoAllocateDepthBuffer){if(et)throw new Error("target.depthTexture not supported in Cube render targets");const ct=N.texture.mipmaps;ct&&ct.length>0?zt(T.__webglFramebuffer[0],N):zt(T.__webglFramebuffer,N)}else if(et){T.__webglDepthbuffer=[];for(let ct=0;ct<6;ct++)if(i.bindFramebuffer(o.FRAMEBUFFER,T.__webglFramebuffer[ct]),T.__webglDepthbuffer[ct]===void 0)T.__webglDepthbuffer[ct]=o.createRenderbuffer(),St(T.__webglDepthbuffer[ct],N,!1);else{const Mt=N.stencilBuffer?o.DEPTH_STENCIL_ATTACHMENT:o.DEPTH_ATTACHMENT,mt=T.__webglDepthbuffer[ct];o.bindRenderbuffer(o.RENDERBUFFER,mt),o.framebufferRenderbuffer(o.FRAMEBUFFER,Mt,o.RENDERBUFFER,mt)}}else{const ct=N.texture.mipmaps;if(ct&&ct.length>0?i.bindFramebuffer(o.FRAMEBUFFER,T.__webglFramebuffer[0]):i.bindFramebuffer(o.FRAMEBUFFER,T.__webglFramebuffer),T.__webglDepthbuffer===void 0)T.__webglDepthbuffer=o.createRenderbuffer(),St(T.__webglDepthbuffer,N,!1);else{const Mt=N.stencilBuffer?o.DEPTH_STENCIL_ATTACHMENT:o.DEPTH_ATTACHMENT,mt=T.__webglDepthbuffer;o.bindRenderbuffer(o.RENDERBUFFER,mt),o.framebufferRenderbuffer(o.FRAMEBUFFER,Mt,o.RENDERBUFFER,mt)}}i.bindFramebuffer(o.FRAMEBUFFER,null)}function jt(N,T,et){const ct=r.get(N);T!==void 0&&yt(ct.__webglFramebuffer,N,N.texture,o.COLOR_ATTACHMENT0,o.TEXTURE_2D,0),et!==void 0&&qt(N)}function Ge(N){const T=N.texture,et=r.get(N),ct=r.get(T);N.addEventListener("dispose",O);const Mt=N.textures,mt=N.isWebGLCubeRenderTarget===!0,Ft=Mt.length>1;if(Ft||(ct.__webglTexture===void 0&&(ct.__webglTexture=o.createTexture()),ct.__version=T.version,h.memory.textures++),mt){et.__webglFramebuffer=[];for(let Rt=0;Rt<6;Rt++)if(T.mipmaps&&T.mipmaps.length>0){et.__webglFramebuffer[Rt]=[];for(let Zt=0;Zt<T.mipmaps.length;Zt++)et.__webglFramebuffer[Rt][Zt]=o.createFramebuffer()}else et.__webglFramebuffer[Rt]=o.createFramebuffer()}else{if(T.mipmaps&&T.mipmaps.length>0){et.__webglFramebuffer=[];for(let Rt=0;Rt<T.mipmaps.length;Rt++)et.__webglFramebuffer[Rt]=o.createFramebuffer()}else et.__webglFramebuffer=o.createFramebuffer();if(Ft)for(let Rt=0,Zt=Mt.length;Rt<Zt;Rt++){const Qt=r.get(Mt[Rt]);Qt.__webglTexture===void 0&&(Qt.__webglTexture=o.createTexture(),h.memory.textures++)}if(N.samples>0&&de(N)===!1){et.__webglMultisampledFramebuffer=o.createFramebuffer(),et.__webglColorRenderbuffer=[],i.bindFramebuffer(o.FRAMEBUFFER,et.__webglMultisampledFramebuffer);for(let Rt=0;Rt<Mt.length;Rt++){const Zt=Mt[Rt];et.__webglColorRenderbuffer[Rt]=o.createRenderbuffer(),o.bindRenderbuffer(o.RENDERBUFFER,et.__webglColorRenderbuffer[Rt]);const Qt=c.convert(Zt.format,Zt.colorSpace),bt=c.convert(Zt.type),Pt=U(Zt.internalFormat,Qt,bt,Zt.colorSpace,N.isXRRenderTarget===!0),Yt=ce(N);o.renderbufferStorageMultisample(o.RENDERBUFFER,Yt,Pt,N.width,N.height),o.framebufferRenderbuffer(o.FRAMEBUFFER,o.COLOR_ATTACHMENT0+Rt,o.RENDERBUFFER,et.__webglColorRenderbuffer[Rt])}o.bindRenderbuffer(o.RENDERBUFFER,null),N.depthBuffer&&(et.__webglDepthRenderbuffer=o.createRenderbuffer(),St(et.__webglDepthRenderbuffer,N,!0)),i.bindFramebuffer(o.FRAMEBUFFER,null)}}if(mt){i.bindTexture(o.TEXTURE_CUBE_MAP,ct.__webglTexture),nt(o.TEXTURE_CUBE_MAP,T);for(let Rt=0;Rt<6;Rt++)if(T.mipmaps&&T.mipmaps.length>0)for(let Zt=0;Zt<T.mipmaps.length;Zt++)yt(et.__webglFramebuffer[Rt][Zt],N,T,o.COLOR_ATTACHMENT0,o.TEXTURE_CUBE_MAP_POSITIVE_X+Rt,Zt);else yt(et.__webglFramebuffer[Rt],N,T,o.COLOR_ATTACHMENT0,o.TEXTURE_CUBE_MAP_POSITIVE_X+Rt,0);M(T)&&_(o.TEXTURE_CUBE_MAP),i.unbindTexture()}else if(Ft){for(let Rt=0,Zt=Mt.length;Rt<Zt;Rt++){const Qt=Mt[Rt],bt=r.get(Qt);i.bindTexture(o.TEXTURE_2D,bt.__webglTexture),nt(o.TEXTURE_2D,Qt),yt(et.__webglFramebuffer,N,Qt,o.COLOR_ATTACHMENT0+Rt,o.TEXTURE_2D,0),M(Qt)&&_(o.TEXTURE_2D)}i.unbindTexture()}else{let Rt=o.TEXTURE_2D;if((N.isWebGL3DRenderTarget||N.isWebGLArrayRenderTarget)&&(Rt=N.isWebGL3DRenderTarget?o.TEXTURE_3D:o.TEXTURE_2D_ARRAY),i.bindTexture(Rt,ct.__webglTexture),nt(Rt,T),T.mipmaps&&T.mipmaps.length>0)for(let Zt=0;Zt<T.mipmaps.length;Zt++)yt(et.__webglFramebuffer[Zt],N,T,o.COLOR_ATTACHMENT0,Rt,Zt);else yt(et.__webglFramebuffer,N,T,o.COLOR_ATTACHMENT0,Rt,0);M(T)&&_(Rt),i.unbindTexture()}N.depthBuffer&&qt(N)}function Fe(N){const T=N.textures;for(let et=0,ct=T.length;et<ct;et++){const Mt=T[et];if(M(Mt)){const mt=L(N),Ft=r.get(Mt).__webglTexture;i.bindTexture(mt,Ft),_(mt),i.unbindTexture()}}}const ue=[],H=[];function Mn(N){if(N.samples>0){if(de(N)===!1){const T=N.textures,et=N.width,ct=N.height;let Mt=o.COLOR_BUFFER_BIT;const mt=N.stencilBuffer?o.DEPTH_STENCIL_ATTACHMENT:o.DEPTH_ATTACHMENT,Ft=r.get(N),Rt=T.length>1;if(Rt)for(let Qt=0;Qt<T.length;Qt++)i.bindFramebuffer(o.FRAMEBUFFER,Ft.__webglMultisampledFramebuffer),o.framebufferRenderbuffer(o.FRAMEBUFFER,o.COLOR_ATTACHMENT0+Qt,o.RENDERBUFFER,null),i.bindFramebuffer(o.FRAMEBUFFER,Ft.__webglFramebuffer),o.framebufferTexture2D(o.DRAW_FRAMEBUFFER,o.COLOR_ATTACHMENT0+Qt,o.TEXTURE_2D,null,0);i.bindFramebuffer(o.READ_FRAMEBUFFER,Ft.__webglMultisampledFramebuffer);const Zt=N.texture.mipmaps;Zt&&Zt.length>0?i.bindFramebuffer(o.DRAW_FRAMEBUFFER,Ft.__webglFramebuffer[0]):i.bindFramebuffer(o.DRAW_FRAMEBUFFER,Ft.__webglFramebuffer);for(let Qt=0;Qt<T.length;Qt++){if(N.resolveDepthBuffer&&(N.depthBuffer&&(Mt|=o.DEPTH_BUFFER_BIT),N.stencilBuffer&&N.resolveStencilBuffer&&(Mt|=o.STENCIL_BUFFER_BIT)),Rt){o.framebufferRenderbuffer(o.READ_FRAMEBUFFER,o.COLOR_ATTACHMENT0,o.RENDERBUFFER,Ft.__webglColorRenderbuffer[Qt]);const bt=r.get(T[Qt]).__webglTexture;o.framebufferTexture2D(o.DRAW_FRAMEBUFFER,o.COLOR_ATTACHMENT0,o.TEXTURE_2D,bt,0)}o.blitFramebuffer(0,0,et,ct,0,0,et,ct,Mt,o.NEAREST),m===!0&&(ue.length=0,H.length=0,ue.push(o.COLOR_ATTACHMENT0+Qt),N.depthBuffer&&N.resolveDepthBuffer===!1&&(ue.push(mt),H.push(mt),o.invalidateFramebuffer(o.DRAW_FRAMEBUFFER,H)),o.invalidateFramebuffer(o.READ_FRAMEBUFFER,ue))}if(i.bindFramebuffer(o.READ_FRAMEBUFFER,null),i.bindFramebuffer(o.DRAW_FRAMEBUFFER,null),Rt)for(let Qt=0;Qt<T.length;Qt++){i.bindFramebuffer(o.FRAMEBUFFER,Ft.__webglMultisampledFramebuffer),o.framebufferRenderbuffer(o.FRAMEBUFFER,o.COLOR_ATTACHMENT0+Qt,o.RENDERBUFFER,Ft.__webglColorRenderbuffer[Qt]);const bt=r.get(T[Qt]).__webglTexture;i.bindFramebuffer(o.FRAMEBUFFER,Ft.__webglFramebuffer),o.framebufferTexture2D(o.DRAW_FRAMEBUFFER,o.COLOR_ATTACHMENT0+Qt,o.TEXTURE_2D,bt,0)}i.bindFramebuffer(o.DRAW_FRAMEBUFFER,Ft.__webglMultisampledFramebuffer)}else if(N.depthBuffer&&N.resolveDepthBuffer===!1&&m){const T=N.stencilBuffer?o.DEPTH_STENCIL_ATTACHMENT:o.DEPTH_ATTACHMENT;o.invalidateFramebuffer(o.DRAW_FRAMEBUFFER,[T])}}}function ce(N){return Math.min(l.maxSamples,N.samples)}function de(N){const T=r.get(N);return N.samples>0&&e.has("WEBGL_multisampled_render_to_texture")===!0&&T.__useRenderToTexture!==!1}function Vt(N){const T=h.render.frame;S.get(N)!==T&&(S.set(N,T),N.update())}function we(N,T){const et=N.colorSpace,ct=N.format,Mt=N.type;return N.isCompressedTexture===!0||N.isVideoTexture===!0||et!==Ms&&et!==Ia&&(Re.getTransfer(et)===Be?(ct!==Mi||Mt!==Ui)&&console.warn("THREE.WebGLTextures: sRGB encoded textures have to use RGBAFormat and UnsignedByteType."):console.error("THREE.WebGLTextures: Unsupported texture color space:",et)),T}function Gt(N){return typeof HTMLImageElement<"u"&&N instanceof HTMLImageElement?(p.width=N.naturalWidth||N.width,p.height=N.naturalHeight||N.height):typeof VideoFrame<"u"&&N instanceof VideoFrame?(p.width=N.displayWidth,p.height=N.displayHeight):(p.width=N.width,p.height=N.height),p}this.allocateTextureUnit=st,this.resetTextureUnits=rt,this.setTexture2D=pt,this.setTexture2DArray=P,this.setTexture3D=Y,this.setTextureCube=j,this.rebindTextures=jt,this.setupRenderTarget=Ge,this.updateRenderTargetMipmap=Fe,this.updateMultisampleRenderTarget=Mn,this.setupDepthRenderbuffer=qt,this.setupFrameBufferTexture=yt,this.useMultisampledRTT=de}function dA(o,e){function i(r,l=Ia){let c;const h=Re.getTransfer(l);if(r===Ui)return o.UNSIGNED_BYTE;if(r===fd)return o.UNSIGNED_SHORT_4_4_4_4;if(r===hd)return o.UNSIGNED_SHORT_5_5_5_1;if(r===R0)return o.UNSIGNED_INT_5_9_9_9_REV;if(r===b0)return o.BYTE;if(r===A0)return o.SHORT;if(r===Ro)return o.UNSIGNED_SHORT;if(r===cd)return o.INT;if(r===xr)return o.UNSIGNED_INT;if(r===sa)return o.FLOAT;if(r===Uo)return o.HALF_FLOAT;if(r===C0)return o.ALPHA;if(r===w0)return o.RGB;if(r===Mi)return o.RGBA;if(r===wo)return o.DEPTH_COMPONENT;if(r===Do)return o.DEPTH_STENCIL;if(r===D0)return o.RED;if(r===dd)return o.RED_INTEGER;if(r===U0)return o.RG;if(r===pd)return o.RG_INTEGER;if(r===md)return o.RGBA_INTEGER;if(r===gu||r===_u||r===vu||r===Su)if(h===Be)if(c=e.get("WEBGL_compressed_texture_s3tc_srgb"),c!==null){if(r===gu)return c.COMPRESSED_SRGB_S3TC_DXT1_EXT;if(r===_u)return c.COMPRESSED_SRGB_ALPHA_S3TC_DXT1_EXT;if(r===vu)return c.COMPRESSED_SRGB_ALPHA_S3TC_DXT3_EXT;if(r===Su)return c.COMPRESSED_SRGB_ALPHA_S3TC_DXT5_EXT}else return null;else if(c=e.get("WEBGL_compressed_texture_s3tc"),c!==null){if(r===gu)return c.COMPRESSED_RGB_S3TC_DXT1_EXT;if(r===_u)return c.COMPRESSED_RGBA_S3TC_DXT1_EXT;if(r===vu)return c.COMPRESSED_RGBA_S3TC_DXT3_EXT;if(r===Su)return c.COMPRESSED_RGBA_S3TC_DXT5_EXT}else return null;if(r===Oh||r===zh||r===Ph||r===Bh)if(c=e.get("WEBGL_compressed_texture_pvrtc"),c!==null){if(r===Oh)return c.COMPRESSED_RGB_PVRTC_4BPPV1_IMG;if(r===zh)return c.COMPRESSED_RGB_PVRTC_2BPPV1_IMG;if(r===Ph)return c.COMPRESSED_RGBA_PVRTC_4BPPV1_IMG;if(r===Bh)return c.COMPRESSED_RGBA_PVRTC_2BPPV1_IMG}else return null;if(r===Ih||r===Fh||r===Hh)if(c=e.get("WEBGL_compressed_texture_etc"),c!==null){if(r===Ih||r===Fh)return h===Be?c.COMPRESSED_SRGB8_ETC2:c.COMPRESSED_RGB8_ETC2;if(r===Hh)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ETC2_EAC:c.COMPRESSED_RGBA8_ETC2_EAC}else return null;if(r===Gh||r===Vh||r===Xh||r===kh||r===Wh||r===qh||r===Yh||r===jh||r===Zh||r===Kh||r===Qh||r===Jh||r===$h||r===td)if(c=e.get("WEBGL_compressed_texture_astc"),c!==null){if(r===Gh)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ASTC_4x4_KHR:c.COMPRESSED_RGBA_ASTC_4x4_KHR;if(r===Vh)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ASTC_5x4_KHR:c.COMPRESSED_RGBA_ASTC_5x4_KHR;if(r===Xh)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ASTC_5x5_KHR:c.COMPRESSED_RGBA_ASTC_5x5_KHR;if(r===kh)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ASTC_6x5_KHR:c.COMPRESSED_RGBA_ASTC_6x5_KHR;if(r===Wh)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ASTC_6x6_KHR:c.COMPRESSED_RGBA_ASTC_6x6_KHR;if(r===qh)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ASTC_8x5_KHR:c.COMPRESSED_RGBA_ASTC_8x5_KHR;if(r===Yh)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ASTC_8x6_KHR:c.COMPRESSED_RGBA_ASTC_8x6_KHR;if(r===jh)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ASTC_8x8_KHR:c.COMPRESSED_RGBA_ASTC_8x8_KHR;if(r===Zh)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ASTC_10x5_KHR:c.COMPRESSED_RGBA_ASTC_10x5_KHR;if(r===Kh)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ASTC_10x6_KHR:c.COMPRESSED_RGBA_ASTC_10x6_KHR;if(r===Qh)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ASTC_10x8_KHR:c.COMPRESSED_RGBA_ASTC_10x8_KHR;if(r===Jh)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ASTC_10x10_KHR:c.COMPRESSED_RGBA_ASTC_10x10_KHR;if(r===$h)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ASTC_12x10_KHR:c.COMPRESSED_RGBA_ASTC_12x10_KHR;if(r===td)return h===Be?c.COMPRESSED_SRGB8_ALPHA8_ASTC_12x12_KHR:c.COMPRESSED_RGBA_ASTC_12x12_KHR}else return null;if(r===xu||r===ed||r===nd)if(c=e.get("EXT_texture_compression_bptc"),c!==null){if(r===xu)return h===Be?c.COMPRESSED_SRGB_ALPHA_BPTC_UNORM_EXT:c.COMPRESSED_RGBA_BPTC_UNORM_EXT;if(r===ed)return c.COMPRESSED_RGB_BPTC_SIGNED_FLOAT_EXT;if(r===nd)return c.COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT_EXT}else return null;if(r===L0||r===id||r===ad||r===rd)if(c=e.get("EXT_texture_compression_rgtc"),c!==null){if(r===xu)return c.COMPRESSED_RED_RGTC1_EXT;if(r===id)return c.COMPRESSED_SIGNED_RED_RGTC1_EXT;if(r===ad)return c.COMPRESSED_RED_GREEN_RGTC2_EXT;if(r===rd)return c.COMPRESSED_SIGNED_RED_GREEN_RGTC2_EXT}else return null;return r===Co?o.UNSIGNED_INT_24_8:o[r]!==void 0?o[r]:null}return{convert:i}}const pA=`
void main() {

	gl_Position = vec4( position, 1.0 );

}`,mA=`
uniform sampler2DArray depthColor;
uniform float depthWidth;
uniform float depthHeight;

void main() {

	vec2 coord = vec2( gl_FragCoord.x / depthWidth, gl_FragCoord.y / depthHeight );

	if ( coord.x >= 1.0 ) {

		gl_FragDepth = texture( depthColor, vec3( coord.x - 1.0, coord.y, 1 ) ).r;

	} else {

		gl_FragDepth = texture( depthColor, vec3( coord.x, coord.y, 0 ) ).r;

	}

}`;class gA{constructor(){this.texture=null,this.mesh=null,this.depthNear=0,this.depthFar=0}init(e,i,r){if(this.texture===null){const l=new Vn,c=e.properties.get(l);c.__webglTexture=i.texture,(i.depthNear!==r.depthNear||i.depthFar!==r.depthFar)&&(this.depthNear=i.depthNear,this.depthFar=i.depthFar),this.texture=l}}getMesh(e){if(this.texture!==null&&this.mesh===null){const i=e.cameras[0].viewport,r=new Va({vertexShader:pA,fragmentShader:mA,uniforms:{depthColor:{value:this.texture},depthWidth:{value:i.z},depthHeight:{value:i.w}}});this.mesh=new ui(new Ru(20,20),r)}return this.mesh}reset(){this.texture=null,this.mesh=null}getDepthTexture(){return this.texture}}class _A extends Es{constructor(e,i){super();const r=this;let l=null,c=1,h=null,d="local-floor",m=1,p=null,S=null,v=null,x=null,y=null,R=null;const w=new gA,M=i.getContextAttributes();let _=null,L=null;const U=[],C=[],G=new ye;let I=null;const O=new Jn;O.viewport=new Ie;const V=new Jn;V.viewport=new Ie;const D=[O,V],b=new BM;let B=null,rt=null;this.cameraAutoUpdate=!0,this.enabled=!1,this.isPresenting=!1,this.getController=function(K){let ft=U[K];return ft===void 0&&(ft=new ch,U[K]=ft),ft.getTargetRaySpace()},this.getControllerGrip=function(K){let ft=U[K];return ft===void 0&&(ft=new ch,U[K]=ft),ft.getGripSpace()},this.getHand=function(K){let ft=U[K];return ft===void 0&&(ft=new ch,U[K]=ft),ft.getHandSpace()};function st(K){const ft=C.indexOf(K.inputSource);if(ft===-1)return;const yt=U[ft];yt!==void 0&&(yt.update(K.inputSource,K.frame,p||h),yt.dispatchEvent({type:K.type,data:K.inputSource}))}function dt(){l.removeEventListener("select",st),l.removeEventListener("selectstart",st),l.removeEventListener("selectend",st),l.removeEventListener("squeeze",st),l.removeEventListener("squeezestart",st),l.removeEventListener("squeezeend",st),l.removeEventListener("end",dt),l.removeEventListener("inputsourceschange",pt);for(let K=0;K<U.length;K++){const ft=C[K];ft!==null&&(C[K]=null,U[K].disconnect(ft))}B=null,rt=null,w.reset(),e.setRenderTarget(_),y=null,x=null,v=null,l=null,L=null,xt.stop(),r.isPresenting=!1,e.setPixelRatio(I),e.setSize(G.width,G.height,!1),r.dispatchEvent({type:"sessionend"})}this.setFramebufferScaleFactor=function(K){c=K,r.isPresenting===!0&&console.warn("THREE.WebXRManager: Cannot change framebuffer scale while presenting.")},this.setReferenceSpaceType=function(K){d=K,r.isPresenting===!0&&console.warn("THREE.WebXRManager: Cannot change reference space type while presenting.")},this.getReferenceSpace=function(){return p||h},this.setReferenceSpace=function(K){p=K},this.getBaseLayer=function(){return x!==null?x:y},this.getBinding=function(){return v},this.getFrame=function(){return R},this.getSession=function(){return l},this.setSession=async function(K){if(l=K,l!==null){if(_=e.getRenderTarget(),l.addEventListener("select",st),l.addEventListener("selectstart",st),l.addEventListener("selectend",st),l.addEventListener("squeeze",st),l.addEventListener("squeezestart",st),l.addEventListener("squeezeend",st),l.addEventListener("end",dt),l.addEventListener("inputsourceschange",pt),M.xrCompatible!==!0&&await i.makeXRCompatible(),I=e.getPixelRatio(),e.getSize(G),typeof XRWebGLBinding<"u"&&"createProjectionLayer"in XRWebGLBinding.prototype){let yt=null,St=null,zt=null;M.depth&&(zt=M.stencil?i.DEPTH24_STENCIL8:i.DEPTH_COMPONENT24,yt=M.stencil?Do:wo,St=M.stencil?Co:xr);const qt={colorFormat:i.RGBA8,depthFormat:zt,scaleFactor:c};v=new XRWebGLBinding(l,i),x=v.createProjectionLayer(qt),l.updateRenderState({layers:[x]}),e.setPixelRatio(1),e.setSize(x.textureWidth,x.textureHeight,!1),L=new Mr(x.textureWidth,x.textureHeight,{format:Mi,type:Ui,depthTexture:new k0(x.textureWidth,x.textureHeight,St,void 0,void 0,void 0,void 0,void 0,void 0,yt),stencilBuffer:M.stencil,colorSpace:e.outputColorSpace,samples:M.antialias?4:0,resolveDepthBuffer:x.ignoreDepthValues===!1,resolveStencilBuffer:x.ignoreDepthValues===!1})}else{const yt={antialias:M.antialias,alpha:!0,depth:M.depth,stencil:M.stencil,framebufferScaleFactor:c};y=new XRWebGLLayer(l,i,yt),l.updateRenderState({baseLayer:y}),e.setPixelRatio(1),e.setSize(y.framebufferWidth,y.framebufferHeight,!1),L=new Mr(y.framebufferWidth,y.framebufferHeight,{format:Mi,type:Ui,colorSpace:e.outputColorSpace,stencilBuffer:M.stencil,resolveDepthBuffer:y.ignoreDepthValues===!1,resolveStencilBuffer:y.ignoreDepthValues===!1})}L.isXRRenderTarget=!0,this.setFoveation(m),p=null,h=await l.requestReferenceSpace(d),xt.setContext(l),xt.start(),r.isPresenting=!0,r.dispatchEvent({type:"sessionstart"})}},this.getEnvironmentBlendMode=function(){if(l!==null)return l.environmentBlendMode},this.getDepthTexture=function(){return w.getDepthTexture()};function pt(K){for(let ft=0;ft<K.removed.length;ft++){const yt=K.removed[ft],St=C.indexOf(yt);St>=0&&(C[St]=null,U[St].disconnect(yt))}for(let ft=0;ft<K.added.length;ft++){const yt=K.added[ft];let St=C.indexOf(yt);if(St===-1){for(let qt=0;qt<U.length;qt++)if(qt>=C.length){C.push(yt),St=qt;break}else if(C[qt]===null){C[qt]=yt,St=qt;break}if(St===-1)break}const zt=U[St];zt&&zt.connect(yt)}}const P=new Q,Y=new Q;function j(K,ft,yt){P.setFromMatrixPosition(ft.matrixWorld),Y.setFromMatrixPosition(yt.matrixWorld);const St=P.distanceTo(Y),zt=ft.projectionMatrix.elements,qt=yt.projectionMatrix.elements,jt=zt[14]/(zt[10]-1),Ge=zt[14]/(zt[10]+1),Fe=(zt[9]+1)/zt[5],ue=(zt[9]-1)/zt[5],H=(zt[8]-1)/zt[0],Mn=(qt[8]+1)/qt[0],ce=jt*H,de=jt*Mn,Vt=St/(-H+Mn),we=Vt*-H;if(ft.matrixWorld.decompose(K.position,K.quaternion,K.scale),K.translateX(we),K.translateZ(Vt),K.matrixWorld.compose(K.position,K.quaternion,K.scale),K.matrixWorldInverse.copy(K.matrixWorld).invert(),zt[10]===-1)K.projectionMatrix.copy(ft.projectionMatrix),K.projectionMatrixInverse.copy(ft.projectionMatrixInverse);else{const Gt=jt+Vt,N=Ge+Vt,T=ce-we,et=de+(St-we),ct=Fe*Ge/N*Gt,Mt=ue*Ge/N*Gt;K.projectionMatrix.makePerspective(T,et,ct,Mt,Gt,N),K.projectionMatrixInverse.copy(K.projectionMatrix).invert()}}function vt(K,ft){ft===null?K.matrixWorld.copy(K.matrix):K.matrixWorld.multiplyMatrices(ft.matrixWorld,K.matrix),K.matrixWorldInverse.copy(K.matrixWorld).invert()}this.updateCamera=function(K){if(l===null)return;let ft=K.near,yt=K.far;w.texture!==null&&(w.depthNear>0&&(ft=w.depthNear),w.depthFar>0&&(yt=w.depthFar)),b.near=V.near=O.near=ft,b.far=V.far=O.far=yt,(B!==b.near||rt!==b.far)&&(l.updateRenderState({depthNear:b.near,depthFar:b.far}),B=b.near,rt=b.far),O.layers.mask=K.layers.mask|2,V.layers.mask=K.layers.mask|4,b.layers.mask=O.layers.mask|V.layers.mask;const St=K.parent,zt=b.cameras;vt(b,St);for(let qt=0;qt<zt.length;qt++)vt(zt[qt],St);zt.length===2?j(b,O,V):b.projectionMatrix.copy(O.projectionMatrix),Tt(K,b,St)};function Tt(K,ft,yt){yt===null?K.matrix.copy(ft.matrixWorld):(K.matrix.copy(yt.matrixWorld),K.matrix.invert(),K.matrix.multiply(ft.matrixWorld)),K.matrix.decompose(K.position,K.quaternion,K.scale),K.updateMatrixWorld(!0),K.projectionMatrix.copy(ft.projectionMatrix),K.projectionMatrixInverse.copy(ft.projectionMatrixInverse),K.isPerspectiveCamera&&(K.fov=sd*2*Math.atan(1/K.projectionMatrix.elements[5]),K.zoom=1)}this.getCamera=function(){return b},this.getFoveation=function(){if(!(x===null&&y===null))return m},this.setFoveation=function(K){m=K,x!==null&&(x.fixedFoveation=K),y!==null&&y.fixedFoveation!==void 0&&(y.fixedFoveation=K)},this.hasDepthSensing=function(){return w.texture!==null},this.getDepthSensingMesh=function(){return w.getMesh(b)};let z=null;function nt(K,ft){if(S=ft.getViewerPose(p||h),R=ft,S!==null){const yt=S.views;y!==null&&(e.setRenderTargetFramebuffer(L,y.framebuffer),e.setRenderTarget(L));let St=!1;yt.length!==b.cameras.length&&(b.cameras.length=0,St=!0);for(let jt=0;jt<yt.length;jt++){const Ge=yt[jt];let Fe=null;if(y!==null)Fe=y.getViewport(Ge);else{const H=v.getViewSubImage(x,Ge);Fe=H.viewport,jt===0&&(e.setRenderTargetTextures(L,H.colorTexture,H.depthStencilTexture),e.setRenderTarget(L))}let ue=D[jt];ue===void 0&&(ue=new Jn,ue.layers.enable(jt),ue.viewport=new Ie,D[jt]=ue),ue.matrix.fromArray(Ge.transform.matrix),ue.matrix.decompose(ue.position,ue.quaternion,ue.scale),ue.projectionMatrix.fromArray(Ge.projectionMatrix),ue.projectionMatrixInverse.copy(ue.projectionMatrix).invert(),ue.viewport.set(Fe.x,Fe.y,Fe.width,Fe.height),jt===0&&(b.matrix.copy(ue.matrix),b.matrix.decompose(b.position,b.quaternion,b.scale)),St===!0&&b.cameras.push(ue)}const zt=l.enabledFeatures;if(zt&&zt.includes("depth-sensing")&&l.depthUsage=="gpu-optimized"&&v){const jt=v.getDepthInformation(yt[0]);jt&&jt.isValid&&jt.texture&&w.init(e,jt,l.renderState)}}for(let yt=0;yt<U.length;yt++){const St=C[yt],zt=U[yt];St!==null&&zt!==void 0&&zt.update(St,ft,p||h)}z&&z(K,ft),ft.detectedPlanes&&r.dispatchEvent({type:"planesdetected",data:ft}),R=null}const xt=new Y0;xt.setAnimationLoop(nt),this.setAnimationLoop=function(K){z=K},this.dispose=function(){}}}const dr=new Li,vA=new Ye;function SA(o,e){function i(M,_){M.matrixAutoUpdate===!0&&M.updateMatrix(),_.value.copy(M.matrix)}function r(M,_){_.color.getRGB(M.fogColor.value,G0(o)),_.isFog?(M.fogNear.value=_.near,M.fogFar.value=_.far):_.isFogExp2&&(M.fogDensity.value=_.density)}function l(M,_,L,U,C){_.isMeshBasicMaterial||_.isMeshLambertMaterial?c(M,_):_.isMeshToonMaterial?(c(M,_),v(M,_)):_.isMeshPhongMaterial?(c(M,_),S(M,_)):_.isMeshStandardMaterial?(c(M,_),x(M,_),_.isMeshPhysicalMaterial&&y(M,_,C)):_.isMeshMatcapMaterial?(c(M,_),R(M,_)):_.isMeshDepthMaterial?c(M,_):_.isMeshDistanceMaterial?(c(M,_),w(M,_)):_.isMeshNormalMaterial?c(M,_):_.isLineBasicMaterial?(h(M,_),_.isLineDashedMaterial&&d(M,_)):_.isPointsMaterial?m(M,_,L,U):_.isSpriteMaterial?p(M,_):_.isShadowMaterial?(M.color.value.copy(_.color),M.opacity.value=_.opacity):_.isShaderMaterial&&(_.uniformsNeedUpdate=!1)}function c(M,_){M.opacity.value=_.opacity,_.color&&M.diffuse.value.copy(_.color),_.emissive&&M.emissive.value.copy(_.emissive).multiplyScalar(_.emissiveIntensity),_.map&&(M.map.value=_.map,i(_.map,M.mapTransform)),_.alphaMap&&(M.alphaMap.value=_.alphaMap,i(_.alphaMap,M.alphaMapTransform)),_.bumpMap&&(M.bumpMap.value=_.bumpMap,i(_.bumpMap,M.bumpMapTransform),M.bumpScale.value=_.bumpScale,_.side===Gn&&(M.bumpScale.value*=-1)),_.normalMap&&(M.normalMap.value=_.normalMap,i(_.normalMap,M.normalMapTransform),M.normalScale.value.copy(_.normalScale),_.side===Gn&&M.normalScale.value.negate()),_.displacementMap&&(M.displacementMap.value=_.displacementMap,i(_.displacementMap,M.displacementMapTransform),M.displacementScale.value=_.displacementScale,M.displacementBias.value=_.displacementBias),_.emissiveMap&&(M.emissiveMap.value=_.emissiveMap,i(_.emissiveMap,M.emissiveMapTransform)),_.specularMap&&(M.specularMap.value=_.specularMap,i(_.specularMap,M.specularMapTransform)),_.alphaTest>0&&(M.alphaTest.value=_.alphaTest);const L=e.get(_),U=L.envMap,C=L.envMapRotation;U&&(M.envMap.value=U,dr.copy(C),dr.x*=-1,dr.y*=-1,dr.z*=-1,U.isCubeTexture&&U.isRenderTargetTexture===!1&&(dr.y*=-1,dr.z*=-1),M.envMapRotation.value.setFromMatrix4(vA.makeRotationFromEuler(dr)),M.flipEnvMap.value=U.isCubeTexture&&U.isRenderTargetTexture===!1?-1:1,M.reflectivity.value=_.reflectivity,M.ior.value=_.ior,M.refractionRatio.value=_.refractionRatio),_.lightMap&&(M.lightMap.value=_.lightMap,M.lightMapIntensity.value=_.lightMapIntensity,i(_.lightMap,M.lightMapTransform)),_.aoMap&&(M.aoMap.value=_.aoMap,M.aoMapIntensity.value=_.aoMapIntensity,i(_.aoMap,M.aoMapTransform))}function h(M,_){M.diffuse.value.copy(_.color),M.opacity.value=_.opacity,_.map&&(M.map.value=_.map,i(_.map,M.mapTransform))}function d(M,_){M.dashSize.value=_.dashSize,M.totalSize.value=_.dashSize+_.gapSize,M.scale.value=_.scale}function m(M,_,L,U){M.diffuse.value.copy(_.color),M.opacity.value=_.opacity,M.size.value=_.size*L,M.scale.value=U*.5,_.map&&(M.map.value=_.map,i(_.map,M.uvTransform)),_.alphaMap&&(M.alphaMap.value=_.alphaMap,i(_.alphaMap,M.alphaMapTransform)),_.alphaTest>0&&(M.alphaTest.value=_.alphaTest)}function p(M,_){M.diffuse.value.copy(_.color),M.opacity.value=_.opacity,M.rotation.value=_.rotation,_.map&&(M.map.value=_.map,i(_.map,M.mapTransform)),_.alphaMap&&(M.alphaMap.value=_.alphaMap,i(_.alphaMap,M.alphaMapTransform)),_.alphaTest>0&&(M.alphaTest.value=_.alphaTest)}function S(M,_){M.specular.value.copy(_.specular),M.shininess.value=Math.max(_.shininess,1e-4)}function v(M,_){_.gradientMap&&(M.gradientMap.value=_.gradientMap)}function x(M,_){M.metalness.value=_.metalness,_.metalnessMap&&(M.metalnessMap.value=_.metalnessMap,i(_.metalnessMap,M.metalnessMapTransform)),M.roughness.value=_.roughness,_.roughnessMap&&(M.roughnessMap.value=_.roughnessMap,i(_.roughnessMap,M.roughnessMapTransform)),_.envMap&&(M.envMapIntensity.value=_.envMapIntensity)}function y(M,_,L){M.ior.value=_.ior,_.sheen>0&&(M.sheenColor.value.copy(_.sheenColor).multiplyScalar(_.sheen),M.sheenRoughness.value=_.sheenRoughness,_.sheenColorMap&&(M.sheenColorMap.value=_.sheenColorMap,i(_.sheenColorMap,M.sheenColorMapTransform)),_.sheenRoughnessMap&&(M.sheenRoughnessMap.value=_.sheenRoughnessMap,i(_.sheenRoughnessMap,M.sheenRoughnessMapTransform))),_.clearcoat>0&&(M.clearcoat.value=_.clearcoat,M.clearcoatRoughness.value=_.clearcoatRoughness,_.clearcoatMap&&(M.clearcoatMap.value=_.clearcoatMap,i(_.clearcoatMap,M.clearcoatMapTransform)),_.clearcoatRoughnessMap&&(M.clearcoatRoughnessMap.value=_.clearcoatRoughnessMap,i(_.clearcoatRoughnessMap,M.clearcoatRoughnessMapTransform)),_.clearcoatNormalMap&&(M.clearcoatNormalMap.value=_.clearcoatNormalMap,i(_.clearcoatNormalMap,M.clearcoatNormalMapTransform),M.clearcoatNormalScale.value.copy(_.clearcoatNormalScale),_.side===Gn&&M.clearcoatNormalScale.value.negate())),_.dispersion>0&&(M.dispersion.value=_.dispersion),_.iridescence>0&&(M.iridescence.value=_.iridescence,M.iridescenceIOR.value=_.iridescenceIOR,M.iridescenceThicknessMinimum.value=_.iridescenceThicknessRange[0],M.iridescenceThicknessMaximum.value=_.iridescenceThicknessRange[1],_.iridescenceMap&&(M.iridescenceMap.value=_.iridescenceMap,i(_.iridescenceMap,M.iridescenceMapTransform)),_.iridescenceThicknessMap&&(M.iridescenceThicknessMap.value=_.iridescenceThicknessMap,i(_.iridescenceThicknessMap,M.iridescenceThicknessMapTransform))),_.transmission>0&&(M.transmission.value=_.transmission,M.transmissionSamplerMap.value=L.texture,M.transmissionSamplerSize.value.set(L.width,L.height),_.transmissionMap&&(M.transmissionMap.value=_.transmissionMap,i(_.transmissionMap,M.transmissionMapTransform)),M.thickness.value=_.thickness,_.thicknessMap&&(M.thicknessMap.value=_.thicknessMap,i(_.thicknessMap,M.thicknessMapTransform)),M.attenuationDistance.value=_.attenuationDistance,M.attenuationColor.value.copy(_.attenuationColor)),_.anisotropy>0&&(M.anisotropyVector.value.set(_.anisotropy*Math.cos(_.anisotropyRotation),_.anisotropy*Math.sin(_.anisotropyRotation)),_.anisotropyMap&&(M.anisotropyMap.value=_.anisotropyMap,i(_.anisotropyMap,M.anisotropyMapTransform))),M.specularIntensity.value=_.specularIntensity,M.specularColor.value.copy(_.specularColor),_.specularColorMap&&(M.specularColorMap.value=_.specularColorMap,i(_.specularColorMap,M.specularColorMapTransform)),_.specularIntensityMap&&(M.specularIntensityMap.value=_.specularIntensityMap,i(_.specularIntensityMap,M.specularIntensityMapTransform))}function R(M,_){_.matcap&&(M.matcap.value=_.matcap)}function w(M,_){const L=e.get(_).light;M.referencePosition.value.setFromMatrixPosition(L.matrixWorld),M.nearDistance.value=L.shadow.camera.near,M.farDistance.value=L.shadow.camera.far}return{refreshFogUniforms:r,refreshMaterialUniforms:l}}function xA(o,e,i,r){let l={},c={},h=[];const d=o.getParameter(o.MAX_UNIFORM_BUFFER_BINDINGS);function m(L,U){const C=U.program;r.uniformBlockBinding(L,C)}function p(L,U){let C=l[L.id];C===void 0&&(R(L),C=S(L),l[L.id]=C,L.addEventListener("dispose",M));const G=U.program;r.updateUBOMapping(L,G);const I=e.render.frame;c[L.id]!==I&&(x(L),c[L.id]=I)}function S(L){const U=v();L.__bindingPointIndex=U;const C=o.createBuffer(),G=L.__size,I=L.usage;return o.bindBuffer(o.UNIFORM_BUFFER,C),o.bufferData(o.UNIFORM_BUFFER,G,I),o.bindBuffer(o.UNIFORM_BUFFER,null),o.bindBufferBase(o.UNIFORM_BUFFER,U,C),C}function v(){for(let L=0;L<d;L++)if(h.indexOf(L)===-1)return h.push(L),L;return console.error("THREE.WebGLRenderer: Maximum number of simultaneously usable uniforms groups reached."),0}function x(L){const U=l[L.id],C=L.uniforms,G=L.__cache;o.bindBuffer(o.UNIFORM_BUFFER,U);for(let I=0,O=C.length;I<O;I++){const V=Array.isArray(C[I])?C[I]:[C[I]];for(let D=0,b=V.length;D<b;D++){const B=V[D];if(y(B,I,D,G)===!0){const rt=B.__offset,st=Array.isArray(B.value)?B.value:[B.value];let dt=0;for(let pt=0;pt<st.length;pt++){const P=st[pt],Y=w(P);typeof P=="number"||typeof P=="boolean"?(B.__data[0]=P,o.bufferSubData(o.UNIFORM_BUFFER,rt+dt,B.__data)):P.isMatrix3?(B.__data[0]=P.elements[0],B.__data[1]=P.elements[1],B.__data[2]=P.elements[2],B.__data[3]=0,B.__data[4]=P.elements[3],B.__data[5]=P.elements[4],B.__data[6]=P.elements[5],B.__data[7]=0,B.__data[8]=P.elements[6],B.__data[9]=P.elements[7],B.__data[10]=P.elements[8],B.__data[11]=0):(P.toArray(B.__data,dt),dt+=Y.storage/Float32Array.BYTES_PER_ELEMENT)}o.bufferSubData(o.UNIFORM_BUFFER,rt,B.__data)}}}o.bindBuffer(o.UNIFORM_BUFFER,null)}function y(L,U,C,G){const I=L.value,O=U+"_"+C;if(G[O]===void 0)return typeof I=="number"||typeof I=="boolean"?G[O]=I:G[O]=I.clone(),!0;{const V=G[O];if(typeof I=="number"||typeof I=="boolean"){if(V!==I)return G[O]=I,!0}else if(V.equals(I)===!1)return V.copy(I),!0}return!1}function R(L){const U=L.uniforms;let C=0;const G=16;for(let O=0,V=U.length;O<V;O++){const D=Array.isArray(U[O])?U[O]:[U[O]];for(let b=0,B=D.length;b<B;b++){const rt=D[b],st=Array.isArray(rt.value)?rt.value:[rt.value];for(let dt=0,pt=st.length;dt<pt;dt++){const P=st[dt],Y=w(P),j=C%G,vt=j%Y.boundary,Tt=j+vt;C+=vt,Tt!==0&&G-Tt<Y.storage&&(C+=G-Tt),rt.__data=new Float32Array(Y.storage/Float32Array.BYTES_PER_ELEMENT),rt.__offset=C,C+=Y.storage}}}const I=C%G;return I>0&&(C+=G-I),L.__size=C,L.__cache={},this}function w(L){const U={boundary:0,storage:0};return typeof L=="number"||typeof L=="boolean"?(U.boundary=4,U.storage=4):L.isVector2?(U.boundary=8,U.storage=8):L.isVector3||L.isColor?(U.boundary=16,U.storage=12):L.isVector4?(U.boundary=16,U.storage=16):L.isMatrix3?(U.boundary=48,U.storage=48):L.isMatrix4?(U.boundary=64,U.storage=64):L.isTexture?console.warn("THREE.WebGLRenderer: Texture samplers can not be part of an uniforms group."):console.warn("THREE.WebGLRenderer: Unsupported uniform value type.",L),U}function M(L){const U=L.target;U.removeEventListener("dispose",M);const C=h.indexOf(U.__bindingPointIndex);h.splice(C,1),o.deleteBuffer(l[U.id]),delete l[U.id],delete c[U.id]}function _(){for(const L in l)o.deleteBuffer(l[L]);h=[],l={},c={}}return{bind:m,update:p,dispose:_}}class MA{constructor(e={}){const{canvas:i=$x(),context:r=null,depth:l=!0,stencil:c=!1,alpha:h=!1,antialias:d=!1,premultipliedAlpha:m=!0,preserveDrawingBuffer:p=!1,powerPreference:S="default",failIfMajorPerformanceCaveat:v=!1,reverseDepthBuffer:x=!1}=e;this.isWebGLRenderer=!0;let y;if(r!==null){if(typeof WebGLRenderingContext<"u"&&r instanceof WebGLRenderingContext)throw new Error("THREE.WebGLRenderer: WebGL 1 is not supported since r163.");y=r.getContextAttributes().alpha}else y=h;const R=new Uint32Array(4),w=new Int32Array(4);let M=null,_=null;const L=[],U=[];this.domElement=i,this.debug={checkShaderErrors:!0,onShaderError:null},this.autoClear=!0,this.autoClearColor=!0,this.autoClearDepth=!0,this.autoClearStencil=!0,this.sortObjects=!0,this.clippingPlanes=[],this.localClippingEnabled=!1,this.toneMapping=Ha,this.toneMappingExposure=1,this.transmissionResolutionScale=1;const C=this;let G=!1;this._outputColorSpace=li;let I=0,O=0,V=null,D=-1,b=null;const B=new Ie,rt=new Ie;let st=null;const dt=new Me(0);let pt=0,P=i.width,Y=i.height,j=1,vt=null,Tt=null;const z=new Ie(0,0,P,Y),nt=new Ie(0,0,P,Y);let xt=!1;const K=new xd;let ft=!1,yt=!1;const St=new Ye,zt=new Ye,qt=new Q,jt=new Ie,Ge={background:null,fog:null,environment:null,overrideMaterial:null,isScene:!0};let Fe=!1;function ue(){return V===null?j:1}let H=r;function Mn(A,q){return i.getContext(A,q)}try{const A={alpha:!0,depth:l,stencil:c,antialias:d,premultipliedAlpha:m,preserveDrawingBuffer:p,powerPreference:S,failIfMajorPerformanceCaveat:v};if("setAttribute"in i&&i.setAttribute("data-engine",`three.js r${ud}`),i.addEventListener("webglcontextlost",_t,!1),i.addEventListener("webglcontextrestored",At,!1),i.addEventListener("webglcontextcreationerror",wt,!1),H===null){const q="webgl2";if(H=Mn(q,A),H===null)throw Mn(q)?new Error("Error creating WebGL context with your selected attributes."):new Error("Error creating WebGL context.")}}catch(A){throw console.error("THREE.WebGLRenderer: "+A.message),A}let ce,de,Vt,we,Gt,N,T,et,ct,Mt,mt,Ft,Rt,Zt,Qt,bt,Pt,Yt,Ht,Nt,$t,ae,Le,W;function Ct(){ce=new UT(H),ce.init(),ae=new dA(H,ce),de=new TT(H,ce,e,ae),Vt=new fA(H,ce),de.reverseDepthBuffer&&x&&Vt.buffers.depth.setReversed(!0),we=new OT(H),Gt=new Jb,N=new hA(H,ce,Vt,Gt,de,ae,we),T=new AT(C),et=new DT(C),ct=new HM(H),Le=new yT(H,ct),Mt=new LT(H,ct,we,Le),mt=new PT(H,Mt,ct,we),Ht=new zT(H,de,N),bt=new bT(Gt),Ft=new Qb(C,T,et,ce,de,Le,bt),Rt=new SA(C,Gt),Zt=new tA,Qt=new sA(ce),Yt=new MT(C,T,et,Vt,mt,y,m),Pt=new uA(C,mt,de),W=new xA(H,we,de,Vt),Nt=new ET(H,ce,we),$t=new NT(H,ce,we),we.programs=Ft.programs,C.capabilities=de,C.extensions=ce,C.properties=Gt,C.renderLists=Zt,C.shadowMap=Pt,C.state=Vt,C.info=we}Ct();const lt=new _A(C,H);this.xr=lt,this.getContext=function(){return H},this.getContextAttributes=function(){return H.getContextAttributes()},this.forceContextLoss=function(){const A=ce.get("WEBGL_lose_context");A&&A.loseContext()},this.forceContextRestore=function(){const A=ce.get("WEBGL_lose_context");A&&A.restoreContext()},this.getPixelRatio=function(){return j},this.setPixelRatio=function(A){A!==void 0&&(j=A,this.setSize(P,Y,!1))},this.getSize=function(A){return A.set(P,Y)},this.setSize=function(A,q,it=!0){if(lt.isPresenting){console.warn("THREE.WebGLRenderer: Can't change size while VR device is presenting.");return}P=A,Y=q,i.width=Math.floor(A*j),i.height=Math.floor(q*j),it===!0&&(i.style.width=A+"px",i.style.height=q+"px"),this.setViewport(0,0,A,q)},this.getDrawingBufferSize=function(A){return A.set(P*j,Y*j).floor()},this.setDrawingBufferSize=function(A,q,it){P=A,Y=q,j=it,i.width=Math.floor(A*it),i.height=Math.floor(q*it),this.setViewport(0,0,A,q)},this.getCurrentViewport=function(A){return A.copy(B)},this.getViewport=function(A){return A.copy(z)},this.setViewport=function(A,q,it,at){A.isVector4?z.set(A.x,A.y,A.z,A.w):z.set(A,q,it,at),Vt.viewport(B.copy(z).multiplyScalar(j).round())},this.getScissor=function(A){return A.copy(nt)},this.setScissor=function(A,q,it,at){A.isVector4?nt.set(A.x,A.y,A.z,A.w):nt.set(A,q,it,at),Vt.scissor(rt.copy(nt).multiplyScalar(j).round())},this.getScissorTest=function(){return xt},this.setScissorTest=function(A){Vt.setScissorTest(xt=A)},this.setOpaqueSort=function(A){vt=A},this.setTransparentSort=function(A){Tt=A},this.getClearColor=function(A){return A.copy(Yt.getClearColor())},this.setClearColor=function(){Yt.setClearColor(...arguments)},this.getClearAlpha=function(){return Yt.getClearAlpha()},this.setClearAlpha=function(){Yt.setClearAlpha(...arguments)},this.clear=function(A=!0,q=!0,it=!0){let at=0;if(A){let k=!1;if(V!==null){const Et=V.texture.format;k=Et===md||Et===pd||Et===dd}if(k){const Et=V.texture.type,Dt=Et===Ui||Et===xr||Et===Ro||Et===Co||Et===fd||Et===hd,Lt=Yt.getClearColor(),Ot=Yt.getClearAlpha(),ee=Lt.r,Jt=Lt.g,Xt=Lt.b;Dt?(R[0]=ee,R[1]=Jt,R[2]=Xt,R[3]=Ot,H.clearBufferuiv(H.COLOR,0,R)):(w[0]=ee,w[1]=Jt,w[2]=Xt,w[3]=Ot,H.clearBufferiv(H.COLOR,0,w))}else at|=H.COLOR_BUFFER_BIT}q&&(at|=H.DEPTH_BUFFER_BIT),it&&(at|=H.STENCIL_BUFFER_BIT,this.state.buffers.stencil.setMask(4294967295)),H.clear(at)},this.clearColor=function(){this.clear(!0,!1,!1)},this.clearDepth=function(){this.clear(!1,!0,!1)},this.clearStencil=function(){this.clear(!1,!1,!0)},this.dispose=function(){i.removeEventListener("webglcontextlost",_t,!1),i.removeEventListener("webglcontextrestored",At,!1),i.removeEventListener("webglcontextcreationerror",wt,!1),Yt.dispose(),Zt.dispose(),Qt.dispose(),Gt.dispose(),T.dispose(),et.dispose(),mt.dispose(),Le.dispose(),W.dispose(),Ft.dispose(),lt.dispose(),lt.removeEventListener("sessionstart",bs),lt.removeEventListener("sessionend",As),Ei.stop()};function _t(A){A.preventDefault(),console.log("THREE.WebGLRenderer: Context Lost."),G=!0}function At(){console.log("THREE.WebGLRenderer: Context Restored."),G=!1;const A=we.autoReset,q=Pt.enabled,it=Pt.autoUpdate,at=Pt.needsUpdate,k=Pt.type;Ct(),we.autoReset=A,Pt.enabled=q,Pt.autoUpdate=it,Pt.needsUpdate=at,Pt.type=k}function wt(A){console.error("THREE.WebGLRenderer: A WebGL context could not be created. Reason: ",A.statusMessage)}function te(A){const q=A.target;q.removeEventListener("dispose",te),We(q)}function We(A){sn(A),Gt.remove(A)}function sn(A){const q=Gt.get(A).programs;q!==void 0&&(q.forEach(function(it){Ft.releaseProgram(it)}),A.isShaderMaterial&&Ft.releaseShaderCache(A))}this.renderBufferDirect=function(A,q,it,at,k,Et){q===null&&(q=Ge);const Dt=k.isMesh&&k.matrixWorld.determinant()<0,Lt=Cs(A,q,it,at,k);Vt.setMaterial(at,Dt);let Ot=it.index,ee=1;if(at.wireframe===!0){if(Ot=Mt.getWireframeAttribute(it),Ot===void 0)return;ee=2}const Jt=it.drawRange,Xt=it.attributes.position;let ge=Jt.start*ee,_e=(Jt.start+Jt.count)*ee;Et!==null&&(ge=Math.max(ge,Et.start*ee),_e=Math.min(_e,(Et.start+Et.count)*ee)),Ot!==null?(ge=Math.max(ge,0),_e=Math.min(_e,Ot.count)):Xt!=null&&(ge=Math.max(ge,0),_e=Math.min(_e,Xt.count));const Ve=_e-ge;if(Ve<0||Ve===1/0)return;Le.setup(k,at,Lt,it,Ot);let Te,ne=Nt;if(Ot!==null&&(Te=ct.get(Ot),ne=$t,ne.setIndex(Te)),k.isMesh)at.wireframe===!0?(Vt.setLineWidth(at.wireframeLinewidth*ue()),ne.setMode(H.LINES)):ne.setMode(H.TRIANGLES);else if(k.isLine){let Wt=at.linewidth;Wt===void 0&&(Wt=1),Vt.setLineWidth(Wt*ue()),k.isLineSegments?ne.setMode(H.LINES):k.isLineLoop?ne.setMode(H.LINE_LOOP):ne.setMode(H.LINE_STRIP)}else k.isPoints?ne.setMode(H.POINTS):k.isSprite&&ne.setMode(H.TRIANGLES);if(k.isBatchedMesh)if(k._multiDrawInstances!==null)Mu("THREE.WebGLRenderer: renderMultiDrawInstances has been deprecated and will be removed in r184. Append to renderMultiDraw arguments and use indirection."),ne.renderMultiDrawInstances(k._multiDrawStarts,k._multiDrawCounts,k._multiDrawCount,k._multiDrawInstances);else if(ce.get("WEBGL_multi_draw"))ne.renderMultiDraw(k._multiDrawStarts,k._multiDrawCounts,k._multiDrawCount);else{const Wt=k._multiDrawStarts,on=k._multiDrawCounts,xe=k._multiDrawCount,Ln=Ot?ct.get(Ot).bytesPerElement:1,hi=Gt.get(at).currentProgram.getUniforms();for(let Cn=0;Cn<xe;Cn++)hi.setValue(H,"_gl_DrawID",Cn),ne.render(Wt[Cn]/Ln,on[Cn])}else if(k.isInstancedMesh)ne.renderInstances(ge,Ve,k.count);else if(it.isInstancedBufferGeometry){const Wt=it._maxInstanceCount!==void 0?it._maxInstanceCount:1/0,on=Math.min(it.instanceCount,Wt);ne.renderInstances(ge,Ve,on)}else ne.render(ge,Ve)};function Ee(A,q,it){A.transparent===!0&&A.side===ra&&A.forceSinglePass===!1?(A.side=Gn,A.needsUpdate=!0,je(A,q,it),A.side=Ga,A.needsUpdate=!0,je(A,q,it),A.side=ra):je(A,q,it)}this.compile=function(A,q,it=null){it===null&&(it=A),_=Qt.get(it),_.init(q),U.push(_),it.traverseVisible(function(k){k.isLight&&k.layers.test(q.layers)&&(_.pushLight(k),k.castShadow&&_.pushShadow(k))}),A!==it&&A.traverseVisible(function(k){k.isLight&&k.layers.test(q.layers)&&(_.pushLight(k),k.castShadow&&_.pushShadow(k))}),_.setupLights();const at=new Set;return A.traverse(function(k){if(!(k.isMesh||k.isPoints||k.isLine||k.isSprite))return;const Et=k.material;if(Et)if(Array.isArray(Et))for(let Dt=0;Dt<Et.length;Dt++){const Lt=Et[Dt];Ee(Lt,it,k),at.add(Lt)}else Ee(Et,it,k),at.add(Et)}),_=U.pop(),at},this.compileAsync=function(A,q,it=null){const at=this.compile(A,q,it);return new Promise(k=>{function Et(){if(at.forEach(function(Dt){Gt.get(Dt).currentProgram.isReady()&&at.delete(Dt)}),at.size===0){k(A);return}setTimeout(Et,10)}ce.get("KHR_parallel_shader_compile")!==null?Et():setTimeout(Et,10)})};let pn=null;function ci(A){pn&&pn(A)}function bs(){Ei.stop()}function As(){Ei.start()}const Ei=new Y0;Ei.setAnimationLoop(ci),typeof self<"u"&&Ei.setContext(self),this.setAnimationLoop=function(A){pn=A,lt.setAnimationLoop(A),A===null?Ei.stop():Ei.start()},lt.addEventListener("sessionstart",bs),lt.addEventListener("sessionend",As),this.render=function(A,q){if(q!==void 0&&q.isCamera!==!0){console.error("THREE.WebGLRenderer.render: camera is not an instance of THREE.Camera.");return}if(G===!0)return;if(A.matrixWorldAutoUpdate===!0&&A.updateMatrixWorld(),q.parent===null&&q.matrixWorldAutoUpdate===!0&&q.updateMatrixWorld(),lt.enabled===!0&&lt.isPresenting===!0&&(lt.cameraAutoUpdate===!0&&lt.updateCamera(q),q=lt.getCamera()),A.isScene===!0&&A.onBeforeRender(C,A,q,V),_=Qt.get(A,U.length),_.init(q),U.push(_),zt.multiplyMatrices(q.projectionMatrix,q.matrixWorldInverse),K.setFromProjectionMatrix(zt),yt=this.localClippingEnabled,ft=bt.init(this.clippingPlanes,yt),M=Zt.get(A,L.length),M.init(),L.push(M),lt.enabled===!0&&lt.isPresenting===!0){const Et=C.xr.getDepthSensingMesh();Et!==null&&Xa(Et,q,-1/0,C.sortObjects)}Xa(A,q,0,C.sortObjects),M.finish(),C.sortObjects===!0&&M.sort(vt,Tt),Fe=lt.enabled===!1||lt.isPresenting===!1||lt.hasDepthSensing()===!1,Fe&&Yt.addToRenderList(M,A),this.info.render.frame++,ft===!0&&bt.beginShadows();const it=_.state.shadowsArray;Pt.render(it,A,q),ft===!0&&bt.endShadows(),this.info.autoReset===!0&&this.info.reset();const at=M.opaque,k=M.transmissive;if(_.setupLights(),q.isArrayCamera){const Et=q.cameras;if(k.length>0)for(let Dt=0,Lt=Et.length;Dt<Lt;Dt++){const Ot=Et[Dt];Rs(at,k,A,Ot)}Fe&&Yt.render(A);for(let Dt=0,Lt=Et.length;Dt<Lt;Dt++){const Ot=Et[Dt];yr(M,A,Ot,Ot.viewport)}}else k.length>0&&Rs(at,k,A,q),Fe&&Yt.render(A),yr(M,A,q);V!==null&&O===0&&(N.updateMultisampleRenderTarget(V),N.updateRenderTargetMipmap(V)),A.isScene===!0&&A.onAfterRender(C,A,q),Le.resetDefaultState(),D=-1,b=null,U.pop(),U.length>0?(_=U[U.length-1],ft===!0&&bt.setGlobalState(C.clippingPlanes,_.state.camera)):_=null,L.pop(),L.length>0?M=L[L.length-1]:M=null};function Xa(A,q,it,at){if(A.visible===!1)return;if(A.layers.test(q.layers)){if(A.isGroup)it=A.renderOrder;else if(A.isLOD)A.autoUpdate===!0&&A.update(q);else if(A.isLight)_.pushLight(A),A.castShadow&&_.pushShadow(A);else if(A.isSprite){if(!A.frustumCulled||K.intersectsSprite(A)){at&&jt.setFromMatrixPosition(A.matrixWorld).applyMatrix4(zt);const Dt=mt.update(A),Lt=A.material;Lt.visible&&M.push(A,Dt,Lt,it,jt.z,null)}}else if((A.isMesh||A.isLine||A.isPoints)&&(!A.frustumCulled||K.intersectsObject(A))){const Dt=mt.update(A),Lt=A.material;if(at&&(A.boundingSphere!==void 0?(A.boundingSphere===null&&A.computeBoundingSphere(),jt.copy(A.boundingSphere.center)):(Dt.boundingSphere===null&&Dt.computeBoundingSphere(),jt.copy(Dt.boundingSphere.center)),jt.applyMatrix4(A.matrixWorld).applyMatrix4(zt)),Array.isArray(Lt)){const Ot=Dt.groups;for(let ee=0,Jt=Ot.length;ee<Jt;ee++){const Xt=Ot[ee],ge=Lt[Xt.materialIndex];ge&&ge.visible&&M.push(A,Dt,ge,it,jt.z,Xt)}}else Lt.visible&&M.push(A,Dt,Lt,it,jt.z,null)}}const Et=A.children;for(let Dt=0,Lt=Et.length;Dt<Lt;Dt++)Xa(Et[Dt],q,it,at)}function yr(A,q,it,at){const k=A.opaque,Et=A.transmissive,Dt=A.transparent;_.setupLightsView(it),ft===!0&&bt.setGlobalState(C.clippingPlanes,it),at&&Vt.viewport(B.copy(at)),k.length>0&&ka(k,q,it),Et.length>0&&ka(Et,q,it),Dt.length>0&&ka(Dt,q,it),Vt.buffers.depth.setTest(!0),Vt.buffers.depth.setMask(!0),Vt.buffers.color.setMask(!0),Vt.setPolygonOffset(!1)}function Rs(A,q,it,at){if((it.isScene===!0?it.overrideMaterial:null)!==null)return;_.state.transmissionRenderTarget[at.id]===void 0&&(_.state.transmissionRenderTarget[at.id]=new Mr(1,1,{generateMipmaps:!0,type:ce.has("EXT_color_buffer_half_float")||ce.has("EXT_color_buffer_float")?Uo:Ui,minFilter:Sr,samples:4,stencilBuffer:c,resolveDepthBuffer:!1,resolveStencilBuffer:!1,colorSpace:Re.workingColorSpace}));const Et=_.state.transmissionRenderTarget[at.id],Dt=at.viewport||B;Et.setSize(Dt.z*C.transmissionResolutionScale,Dt.w*C.transmissionResolutionScale);const Lt=C.getRenderTarget();C.setRenderTarget(Et),C.getClearColor(dt),pt=C.getClearAlpha(),pt<1&&C.setClearColor(16777215,.5),C.clear(),Fe&&Yt.render(it);const Ot=C.toneMapping;C.toneMapping=Ha;const ee=at.viewport;if(at.viewport!==void 0&&(at.viewport=void 0),_.setupLightsView(at),ft===!0&&bt.setGlobalState(C.clippingPlanes,at),ka(A,it,at),N.updateMultisampleRenderTarget(Et),N.updateRenderTargetMipmap(Et),ce.has("WEBGL_multisampled_render_to_texture")===!1){let Jt=!1;for(let Xt=0,ge=q.length;Xt<ge;Xt++){const _e=q[Xt],Ve=_e.object,Te=_e.geometry,ne=_e.material,Wt=_e.group;if(ne.side===ra&&Ve.layers.test(at.layers)){const on=ne.side;ne.side=Gn,ne.needsUpdate=!0,fi(Ve,it,at,Te,ne,Wt),ne.side=on,ne.needsUpdate=!0,Jt=!0}}Jt===!0&&(N.updateMultisampleRenderTarget(Et),N.updateRenderTargetMipmap(Et))}C.setRenderTarget(Lt),C.setClearColor(dt,pt),ee!==void 0&&(at.viewport=ee),C.toneMapping=Ot}function ka(A,q,it){const at=q.isScene===!0?q.overrideMaterial:null;for(let k=0,Et=A.length;k<Et;k++){const Dt=A[k],Lt=Dt.object,Ot=Dt.geometry,ee=Dt.group;let Jt=Dt.material;Jt.allowOverride===!0&&at!==null&&(Jt=at),Lt.layers.test(it.layers)&&fi(Lt,q,it,Ot,Jt,ee)}}function fi(A,q,it,at,k,Et){A.onBeforeRender(C,q,it,at,k,Et),A.modelViewMatrix.multiplyMatrices(it.matrixWorldInverse,A.matrixWorld),A.normalMatrix.getNormalMatrix(A.modelViewMatrix),k.onBeforeRender(C,q,it,at,A,Et),k.transparent===!0&&k.side===ra&&k.forceSinglePass===!1?(k.side=Gn,k.needsUpdate=!0,C.renderBufferDirect(it,q,at,k,A,Et),k.side=Ga,k.needsUpdate=!0,C.renderBufferDirect(it,q,at,k,A,Et),k.side=ra):C.renderBufferDirect(it,q,at,k,A,Et),A.onAfterRender(C,q,it,at,k,Et)}function je(A,q,it){q.isScene!==!0&&(q=Ge);const at=Gt.get(A),k=_.state.lights,Et=_.state.shadowsArray,Dt=k.state.version,Lt=Ft.getParameters(A,k.state,Et,q,it),Ot=Ft.getProgramCacheKey(Lt);let ee=at.programs;at.environment=A.isMeshStandardMaterial?q.environment:null,at.fog=q.fog,at.envMap=(A.isMeshStandardMaterial?et:T).get(A.envMap||at.environment),at.envMapRotation=at.environment!==null&&A.envMap===null?q.environmentRotation:A.envMapRotation,ee===void 0&&(A.addEventListener("dispose",te),ee=new Map,at.programs=ee);let Jt=ee.get(Ot);if(Jt!==void 0){if(at.currentProgram===Jt&&at.lightsStateVersion===Dt)return Oi(A,Lt),Jt}else Lt.uniforms=Ft.getUniforms(A),A.onBeforeCompile(Lt,C),Jt=Ft.acquireProgram(Lt,Ot),ee.set(Ot,Jt),at.uniforms=Lt.uniforms;const Xt=at.uniforms;return(!A.isShaderMaterial&&!A.isRawShaderMaterial||A.clipping===!0)&&(Xt.clippingPlanes=bt.uniform),Oi(A,Lt),at.needsLights=Du(A),at.lightsStateVersion=Dt,at.needsLights&&(Xt.ambientLightColor.value=k.state.ambient,Xt.lightProbe.value=k.state.probe,Xt.directionalLights.value=k.state.directional,Xt.directionalLightShadows.value=k.state.directionalShadow,Xt.spotLights.value=k.state.spot,Xt.spotLightShadows.value=k.state.spotShadow,Xt.rectAreaLights.value=k.state.rectArea,Xt.ltc_1.value=k.state.rectAreaLTC1,Xt.ltc_2.value=k.state.rectAreaLTC2,Xt.pointLights.value=k.state.point,Xt.pointLightShadows.value=k.state.pointShadow,Xt.hemisphereLights.value=k.state.hemi,Xt.directionalShadowMap.value=k.state.directionalShadowMap,Xt.directionalShadowMatrix.value=k.state.directionalShadowMatrix,Xt.spotShadowMap.value=k.state.spotShadowMap,Xt.spotLightMatrix.value=k.state.spotLightMatrix,Xt.spotLightMap.value=k.state.spotLightMap,Xt.pointShadowMap.value=k.state.pointShadowMap,Xt.pointShadowMatrix.value=k.state.pointShadowMatrix),at.currentProgram=Jt,at.uniformsList=null,Jt}function mn(A){if(A.uniformsList===null){const q=A.currentProgram.getUniforms();A.uniformsList=yu.seqWithValue(q.seq,A.uniforms)}return A.uniformsList}function Oi(A,q){const it=Gt.get(A);it.outputColorSpace=q.outputColorSpace,it.batching=q.batching,it.batchingColor=q.batchingColor,it.instancing=q.instancing,it.instancingColor=q.instancingColor,it.instancingMorph=q.instancingMorph,it.skinning=q.skinning,it.morphTargets=q.morphTargets,it.morphNormals=q.morphNormals,it.morphColors=q.morphColors,it.morphTargetsCount=q.morphTargetsCount,it.numClippingPlanes=q.numClippingPlanes,it.numIntersection=q.numClipIntersection,it.vertexAlphas=q.vertexAlphas,it.vertexTangents=q.vertexTangents,it.toneMapping=q.toneMapping}function Cs(A,q,it,at,k){q.isScene!==!0&&(q=Ge),N.resetTextureUnits();const Et=q.fog,Dt=at.isMeshStandardMaterial?q.environment:null,Lt=V===null?C.outputColorSpace:V.isXRRenderTarget===!0?V.texture.colorSpace:Ms,Ot=(at.isMeshStandardMaterial?et:T).get(at.envMap||Dt),ee=at.vertexColors===!0&&!!it.attributes.color&&it.attributes.color.itemSize===4,Jt=!!it.attributes.tangent&&(!!at.normalMap||at.anisotropy>0),Xt=!!it.morphAttributes.position,ge=!!it.morphAttributes.normal,_e=!!it.morphAttributes.color;let Ve=Ha;at.toneMapped&&(V===null||V.isXRRenderTarget===!0)&&(Ve=C.toneMapping);const Te=it.morphAttributes.position||it.morphAttributes.normal||it.morphAttributes.color,ne=Te!==void 0?Te.length:0,Wt=Gt.get(at),on=_.state.lights;if(ft===!0&&(yt===!0||A!==b)){const Ze=A===b&&at.id===D;bt.setState(at,A,Ze)}let xe=!1;at.version===Wt.__version?(Wt.needsLights&&Wt.lightsStateVersion!==on.state.version||Wt.outputColorSpace!==Lt||k.isBatchedMesh&&Wt.batching===!1||!k.isBatchedMesh&&Wt.batching===!0||k.isBatchedMesh&&Wt.batchingColor===!0&&k.colorTexture===null||k.isBatchedMesh&&Wt.batchingColor===!1&&k.colorTexture!==null||k.isInstancedMesh&&Wt.instancing===!1||!k.isInstancedMesh&&Wt.instancing===!0||k.isSkinnedMesh&&Wt.skinning===!1||!k.isSkinnedMesh&&Wt.skinning===!0||k.isInstancedMesh&&Wt.instancingColor===!0&&k.instanceColor===null||k.isInstancedMesh&&Wt.instancingColor===!1&&k.instanceColor!==null||k.isInstancedMesh&&Wt.instancingMorph===!0&&k.morphTexture===null||k.isInstancedMesh&&Wt.instancingMorph===!1&&k.morphTexture!==null||Wt.envMap!==Ot||at.fog===!0&&Wt.fog!==Et||Wt.numClippingPlanes!==void 0&&(Wt.numClippingPlanes!==bt.numPlanes||Wt.numIntersection!==bt.numIntersection)||Wt.vertexAlphas!==ee||Wt.vertexTangents!==Jt||Wt.morphTargets!==Xt||Wt.morphNormals!==ge||Wt.morphColors!==_e||Wt.toneMapping!==Ve||Wt.morphTargetsCount!==ne)&&(xe=!0):(xe=!0,Wt.__version=at.version);let Ln=Wt.currentProgram;xe===!0&&(Ln=je(at,q,k));let hi=!1,Cn=!1,fn=!1;const Ne=Ln.getUniforms(),wn=Wt.uniforms;if(Vt.useProgram(Ln.program)&&(hi=!0,Cn=!0,fn=!0),at.id!==D&&(D=at.id,Cn=!0),hi||b!==A){Vt.buffers.depth.getReversed()?(St.copy(A.projectionMatrix),eM(St),nM(St),Ne.setValue(H,"projectionMatrix",St)):Ne.setValue(H,"projectionMatrix",A.projectionMatrix),Ne.setValue(H,"viewMatrix",A.matrixWorldInverse);const gn=Ne.map.cameraPosition;gn!==void 0&&gn.setValue(H,qt.setFromMatrixPosition(A.matrixWorld)),de.logarithmicDepthBuffer&&Ne.setValue(H,"logDepthBufFC",2/(Math.log(A.far+1)/Math.LN2)),(at.isMeshPhongMaterial||at.isMeshToonMaterial||at.isMeshLambertMaterial||at.isMeshBasicMaterial||at.isMeshStandardMaterial||at.isShaderMaterial)&&Ne.setValue(H,"isOrthographic",A.isOrthographicCamera===!0),b!==A&&(b=A,Cn=!0,fn=!0)}if(k.isSkinnedMesh){Ne.setOptional(H,k,"bindMatrix"),Ne.setOptional(H,k,"bindMatrixInverse");const Ze=k.skeleton;Ze&&(Ze.boneTexture===null&&Ze.computeBoneTexture(),Ne.setValue(H,"boneTexture",Ze.boneTexture,N))}k.isBatchedMesh&&(Ne.setOptional(H,k,"batchingTexture"),Ne.setValue(H,"batchingTexture",k._matricesTexture,N),Ne.setOptional(H,k,"batchingIdTexture"),Ne.setValue(H,"batchingIdTexture",k._indirectTexture,N),Ne.setOptional(H,k,"batchingColorTexture"),k._colorsTexture!==null&&Ne.setValue(H,"batchingColorTexture",k._colorsTexture,N));const yn=it.morphAttributes;if((yn.position!==void 0||yn.normal!==void 0||yn.color!==void 0)&&Ht.update(k,it,Ln),(Cn||Wt.receiveShadow!==k.receiveShadow)&&(Wt.receiveShadow=k.receiveShadow,Ne.setValue(H,"receiveShadow",k.receiveShadow)),at.isMeshGouraudMaterial&&at.envMap!==null&&(wn.envMap.value=Ot,wn.flipEnvMap.value=Ot.isCubeTexture&&Ot.isRenderTargetTexture===!1?-1:1),at.isMeshStandardMaterial&&at.envMap===null&&q.environment!==null&&(wn.envMapIntensity.value=q.environmentIntensity),Cn&&(Ne.setValue(H,"toneMappingExposure",C.toneMappingExposure),Wt.needsLights&&wu(wn,fn),Et&&at.fog===!0&&Rt.refreshFogUniforms(wn,Et),Rt.refreshMaterialUniforms(wn,at,j,Y,_.state.transmissionRenderTarget[A.id]),yu.upload(H,mn(Wt),wn,N)),at.isShaderMaterial&&at.uniformsNeedUpdate===!0&&(yu.upload(H,mn(Wt),wn,N),at.uniformsNeedUpdate=!1),at.isSpriteMaterial&&Ne.setValue(H,"center",k.center),Ne.setValue(H,"modelViewMatrix",k.modelViewMatrix),Ne.setValue(H,"normalMatrix",k.normalMatrix),Ne.setValue(H,"modelMatrix",k.matrixWorld),at.isShaderMaterial||at.isRawShaderMaterial){const Ze=at.uniformsGroups;for(let gn=0,Er=Ze.length;gn<Er;gn++){const Nn=Ze[gn];W.update(Nn,Ln),W.bind(Nn,Ln)}}return Ln}function wu(A,q){A.ambientLightColor.needsUpdate=q,A.lightProbe.needsUpdate=q,A.directionalLights.needsUpdate=q,A.directionalLightShadows.needsUpdate=q,A.pointLights.needsUpdate=q,A.pointLightShadows.needsUpdate=q,A.spotLights.needsUpdate=q,A.spotLightShadows.needsUpdate=q,A.rectAreaLights.needsUpdate=q,A.hemisphereLights.needsUpdate=q}function Du(A){return A.isMeshLambertMaterial||A.isMeshToonMaterial||A.isMeshPhongMaterial||A.isMeshStandardMaterial||A.isShadowMaterial||A.isShaderMaterial&&A.lights===!0}this.getActiveCubeFace=function(){return I},this.getActiveMipmapLevel=function(){return O},this.getRenderTarget=function(){return V},this.setRenderTargetTextures=function(A,q,it){const at=Gt.get(A);at.__autoAllocateDepthBuffer=A.resolveDepthBuffer===!1,at.__autoAllocateDepthBuffer===!1&&(at.__useRenderToTexture=!1),Gt.get(A.texture).__webglTexture=q,Gt.get(A.depthTexture).__webglTexture=at.__autoAllocateDepthBuffer?void 0:it,at.__hasExternalTextures=!0},this.setRenderTargetFramebuffer=function(A,q){const it=Gt.get(A);it.__webglFramebuffer=q,it.__useDefaultFramebuffer=q===void 0};const Bo=H.createFramebuffer();this.setRenderTarget=function(A,q=0,it=0){V=A,I=q,O=it;let at=!0,k=null,Et=!1,Dt=!1;if(A){const Ot=Gt.get(A);if(Ot.__useDefaultFramebuffer!==void 0)Vt.bindFramebuffer(H.FRAMEBUFFER,null),at=!1;else if(Ot.__webglFramebuffer===void 0)N.setupRenderTarget(A);else if(Ot.__hasExternalTextures)N.rebindTextures(A,Gt.get(A.texture).__webglTexture,Gt.get(A.depthTexture).__webglTexture);else if(A.depthBuffer){const Xt=A.depthTexture;if(Ot.__boundDepthTexture!==Xt){if(Xt!==null&&Gt.has(Xt)&&(A.width!==Xt.image.width||A.height!==Xt.image.height))throw new Error("WebGLRenderTarget: Attached DepthTexture is initialized to the incorrect size.");N.setupDepthRenderbuffer(A)}}const ee=A.texture;(ee.isData3DTexture||ee.isDataArrayTexture||ee.isCompressedArrayTexture)&&(Dt=!0);const Jt=Gt.get(A).__webglFramebuffer;A.isWebGLCubeRenderTarget?(Array.isArray(Jt[q])?k=Jt[q][it]:k=Jt[q],Et=!0):A.samples>0&&N.useMultisampledRTT(A)===!1?k=Gt.get(A).__webglMultisampledFramebuffer:Array.isArray(Jt)?k=Jt[it]:k=Jt,B.copy(A.viewport),rt.copy(A.scissor),st=A.scissorTest}else B.copy(z).multiplyScalar(j).floor(),rt.copy(nt).multiplyScalar(j).floor(),st=xt;if(it!==0&&(k=Bo),Vt.bindFramebuffer(H.FRAMEBUFFER,k)&&at&&Vt.drawBuffers(A,k),Vt.viewport(B),Vt.scissor(rt),Vt.setScissorTest(st),Et){const Ot=Gt.get(A.texture);H.framebufferTexture2D(H.FRAMEBUFFER,H.COLOR_ATTACHMENT0,H.TEXTURE_CUBE_MAP_POSITIVE_X+q,Ot.__webglTexture,it)}else if(Dt){const Ot=Gt.get(A.texture),ee=q;H.framebufferTextureLayer(H.FRAMEBUFFER,H.COLOR_ATTACHMENT0,Ot.__webglTexture,it,ee)}else if(A!==null&&it!==0){const Ot=Gt.get(A.texture);H.framebufferTexture2D(H.FRAMEBUFFER,H.COLOR_ATTACHMENT0,H.TEXTURE_2D,Ot.__webglTexture,it)}D=-1},this.readRenderTargetPixels=function(A,q,it,at,k,Et,Dt){if(!(A&&A.isWebGLRenderTarget)){console.error("THREE.WebGLRenderer.readRenderTargetPixels: renderTarget is not THREE.WebGLRenderTarget.");return}let Lt=Gt.get(A).__webglFramebuffer;if(A.isWebGLCubeRenderTarget&&Dt!==void 0&&(Lt=Lt[Dt]),Lt){Vt.bindFramebuffer(H.FRAMEBUFFER,Lt);try{const Ot=A.texture,ee=Ot.format,Jt=Ot.type;if(!de.textureFormatReadable(ee)){console.error("THREE.WebGLRenderer.readRenderTargetPixels: renderTarget is not in RGBA or implementation defined format.");return}if(!de.textureTypeReadable(Jt)){console.error("THREE.WebGLRenderer.readRenderTargetPixels: renderTarget is not in UnsignedByteType or implementation defined type.");return}q>=0&&q<=A.width-at&&it>=0&&it<=A.height-k&&H.readPixels(q,it,at,k,ae.convert(ee),ae.convert(Jt),Et)}finally{const Ot=V!==null?Gt.get(V).__webglFramebuffer:null;Vt.bindFramebuffer(H.FRAMEBUFFER,Ot)}}},this.readRenderTargetPixelsAsync=async function(A,q,it,at,k,Et,Dt){if(!(A&&A.isWebGLRenderTarget))throw new Error("THREE.WebGLRenderer.readRenderTargetPixels: renderTarget is not THREE.WebGLRenderTarget.");let Lt=Gt.get(A).__webglFramebuffer;if(A.isWebGLCubeRenderTarget&&Dt!==void 0&&(Lt=Lt[Dt]),Lt)if(q>=0&&q<=A.width-at&&it>=0&&it<=A.height-k){Vt.bindFramebuffer(H.FRAMEBUFFER,Lt);const Ot=A.texture,ee=Ot.format,Jt=Ot.type;if(!de.textureFormatReadable(ee))throw new Error("THREE.WebGLRenderer.readRenderTargetPixelsAsync: renderTarget is not in RGBA or implementation defined format.");if(!de.textureTypeReadable(Jt))throw new Error("THREE.WebGLRenderer.readRenderTargetPixelsAsync: renderTarget is not in UnsignedByteType or implementation defined type.");const Xt=H.createBuffer();H.bindBuffer(H.PIXEL_PACK_BUFFER,Xt),H.bufferData(H.PIXEL_PACK_BUFFER,Et.byteLength,H.STREAM_READ),H.readPixels(q,it,at,k,ae.convert(ee),ae.convert(Jt),0);const ge=V!==null?Gt.get(V).__webglFramebuffer:null;Vt.bindFramebuffer(H.FRAMEBUFFER,ge);const _e=H.fenceSync(H.SYNC_GPU_COMMANDS_COMPLETE,0);return H.flush(),await tM(H,_e,4),H.bindBuffer(H.PIXEL_PACK_BUFFER,Xt),H.getBufferSubData(H.PIXEL_PACK_BUFFER,0,Et),H.deleteBuffer(Xt),H.deleteSync(_e),Et}else throw new Error("THREE.WebGLRenderer.readRenderTargetPixelsAsync: requested read bounds are out of range.")},this.copyFramebufferToTexture=function(A,q=null,it=0){const at=Math.pow(2,-it),k=Math.floor(A.image.width*at),Et=Math.floor(A.image.height*at),Dt=q!==null?q.x:0,Lt=q!==null?q.y:0;N.setTexture2D(A,0),H.copyTexSubImage2D(H.TEXTURE_2D,it,0,0,Dt,Lt,k,Et),Vt.unbindTexture()};const Wa=H.createFramebuffer(),ws=H.createFramebuffer();this.copyTextureToTexture=function(A,q,it=null,at=null,k=0,Et=null){Et===null&&(k!==0?(Mu("WebGLRenderer: copyTextureToTexture function signature has changed to support src and dst mipmap levels."),Et=k,k=0):Et=0);let Dt,Lt,Ot,ee,Jt,Xt,ge,_e,Ve;const Te=A.isCompressedTexture?A.mipmaps[Et]:A.image;if(it!==null)Dt=it.max.x-it.min.x,Lt=it.max.y-it.min.y,Ot=it.isBox3?it.max.z-it.min.z:1,ee=it.min.x,Jt=it.min.y,Xt=it.isBox3?it.min.z:0;else{const yn=Math.pow(2,-k);Dt=Math.floor(Te.width*yn),Lt=Math.floor(Te.height*yn),A.isDataArrayTexture?Ot=Te.depth:A.isData3DTexture?Ot=Math.floor(Te.depth*yn):Ot=1,ee=0,Jt=0,Xt=0}at!==null?(ge=at.x,_e=at.y,Ve=at.z):(ge=0,_e=0,Ve=0);const ne=ae.convert(q.format),Wt=ae.convert(q.type);let on;q.isData3DTexture?(N.setTexture3D(q,0),on=H.TEXTURE_3D):q.isDataArrayTexture||q.isCompressedArrayTexture?(N.setTexture2DArray(q,0),on=H.TEXTURE_2D_ARRAY):(N.setTexture2D(q,0),on=H.TEXTURE_2D),H.pixelStorei(H.UNPACK_FLIP_Y_WEBGL,q.flipY),H.pixelStorei(H.UNPACK_PREMULTIPLY_ALPHA_WEBGL,q.premultiplyAlpha),H.pixelStorei(H.UNPACK_ALIGNMENT,q.unpackAlignment);const xe=H.getParameter(H.UNPACK_ROW_LENGTH),Ln=H.getParameter(H.UNPACK_IMAGE_HEIGHT),hi=H.getParameter(H.UNPACK_SKIP_PIXELS),Cn=H.getParameter(H.UNPACK_SKIP_ROWS),fn=H.getParameter(H.UNPACK_SKIP_IMAGES);H.pixelStorei(H.UNPACK_ROW_LENGTH,Te.width),H.pixelStorei(H.UNPACK_IMAGE_HEIGHT,Te.height),H.pixelStorei(H.UNPACK_SKIP_PIXELS,ee),H.pixelStorei(H.UNPACK_SKIP_ROWS,Jt),H.pixelStorei(H.UNPACK_SKIP_IMAGES,Xt);const Ne=A.isDataArrayTexture||A.isData3DTexture,wn=q.isDataArrayTexture||q.isData3DTexture;if(A.isDepthTexture){const yn=Gt.get(A),Ze=Gt.get(q),gn=Gt.get(yn.__renderTarget),Er=Gt.get(Ze.__renderTarget);Vt.bindFramebuffer(H.READ_FRAMEBUFFER,gn.__webglFramebuffer),Vt.bindFramebuffer(H.DRAW_FRAMEBUFFER,Er.__webglFramebuffer);for(let Nn=0;Nn<Ot;Nn++)Ne&&(H.framebufferTextureLayer(H.READ_FRAMEBUFFER,H.COLOR_ATTACHMENT0,Gt.get(A).__webglTexture,k,Xt+Nn),H.framebufferTextureLayer(H.DRAW_FRAMEBUFFER,H.COLOR_ATTACHMENT0,Gt.get(q).__webglTexture,Et,Ve+Nn)),H.blitFramebuffer(ee,Jt,Dt,Lt,ge,_e,Dt,Lt,H.DEPTH_BUFFER_BIT,H.NEAREST);Vt.bindFramebuffer(H.READ_FRAMEBUFFER,null),Vt.bindFramebuffer(H.DRAW_FRAMEBUFFER,null)}else if(k!==0||A.isRenderTargetTexture||Gt.has(A)){const yn=Gt.get(A),Ze=Gt.get(q);Vt.bindFramebuffer(H.READ_FRAMEBUFFER,Wa),Vt.bindFramebuffer(H.DRAW_FRAMEBUFFER,ws);for(let gn=0;gn<Ot;gn++)Ne?H.framebufferTextureLayer(H.READ_FRAMEBUFFER,H.COLOR_ATTACHMENT0,yn.__webglTexture,k,Xt+gn):H.framebufferTexture2D(H.READ_FRAMEBUFFER,H.COLOR_ATTACHMENT0,H.TEXTURE_2D,yn.__webglTexture,k),wn?H.framebufferTextureLayer(H.DRAW_FRAMEBUFFER,H.COLOR_ATTACHMENT0,Ze.__webglTexture,Et,Ve+gn):H.framebufferTexture2D(H.DRAW_FRAMEBUFFER,H.COLOR_ATTACHMENT0,H.TEXTURE_2D,Ze.__webglTexture,Et),k!==0?H.blitFramebuffer(ee,Jt,Dt,Lt,ge,_e,Dt,Lt,H.COLOR_BUFFER_BIT,H.NEAREST):wn?H.copyTexSubImage3D(on,Et,ge,_e,Ve+gn,ee,Jt,Dt,Lt):H.copyTexSubImage2D(on,Et,ge,_e,ee,Jt,Dt,Lt);Vt.bindFramebuffer(H.READ_FRAMEBUFFER,null),Vt.bindFramebuffer(H.DRAW_FRAMEBUFFER,null)}else wn?A.isDataTexture||A.isData3DTexture?H.texSubImage3D(on,Et,ge,_e,Ve,Dt,Lt,Ot,ne,Wt,Te.data):q.isCompressedArrayTexture?H.compressedTexSubImage3D(on,Et,ge,_e,Ve,Dt,Lt,Ot,ne,Te.data):H.texSubImage3D(on,Et,ge,_e,Ve,Dt,Lt,Ot,ne,Wt,Te):A.isDataTexture?H.texSubImage2D(H.TEXTURE_2D,Et,ge,_e,Dt,Lt,ne,Wt,Te.data):A.isCompressedTexture?H.compressedTexSubImage2D(H.TEXTURE_2D,Et,ge,_e,Te.width,Te.height,ne,Te.data):H.texSubImage2D(H.TEXTURE_2D,Et,ge,_e,Dt,Lt,ne,Wt,Te);H.pixelStorei(H.UNPACK_ROW_LENGTH,xe),H.pixelStorei(H.UNPACK_IMAGE_HEIGHT,Ln),H.pixelStorei(H.UNPACK_SKIP_PIXELS,hi),H.pixelStorei(H.UNPACK_SKIP_ROWS,Cn),H.pixelStorei(H.UNPACK_SKIP_IMAGES,fn),Et===0&&q.generateMipmaps&&H.generateMipmap(on),Vt.unbindTexture()},this.copyTextureToTexture3D=function(A,q,it=null,at=null,k=0){return Mu('WebGLRenderer: copyTextureToTexture3D function has been deprecated. Use "copyTextureToTexture" instead.'),this.copyTextureToTexture(A,q,it,at,k)},this.initRenderTarget=function(A){Gt.get(A).__webglFramebuffer===void 0&&N.setupRenderTarget(A)},this.initTexture=function(A){A.isCubeTexture?N.setTextureCube(A,0):A.isData3DTexture?N.setTexture3D(A,0):A.isDataArrayTexture||A.isCompressedArrayTexture?N.setTexture2DArray(A,0):N.setTexture2D(A,0),Vt.unbindTexture()},this.resetState=function(){I=0,O=0,V=null,Vt.reset(),Le.reset()},typeof __THREE_DEVTOOLS__<"u"&&__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("observe",{detail:this}))}get coordinateSystem(){return oa}get outputColorSpace(){return this._outputColorSpace}set outputColorSpace(e){this._outputColorSpace=e;const i=this.getContext();i.drawingBufferColorSpace=Re._getDrawingBufferColorSpace(e),i.unpackColorSpace=Re._getUnpackColorSpace()}}const Si=7,_0=10,yA=.18,EA=.6,v0=1.4,S0=.55;function TA(){const o=mu.useRef(null),e=mu.useRef(null);return mu.useEffect(()=>{const i=o.current,r=new MA({antialias:!0});r.setPixelRatio(Math.min(window.devicePixelRatio,2)),r.setSize(window.innerWidth,window.innerHeight),r.shadowMap.enabled=!0,r.shadowMap.type=M0,r.toneMapping=E0,r.toneMappingExposure=1.2,i.appendChild(r.domElement);const l=new CM;l.background=new Me(657935),l.fog=new Sd(657935,.032);const c=new Jn(60,window.innerWidth/window.innerHeight,.1,200);c.position.set(0,5,18),c.lookAt(0,0,0);const h=new PM(1710650,1.2);l.add(h);const d=new zM(16777215,2.5);d.position.set(8,14,6),d.castShadow=!0,d.shadow.mapSize.set(1024,1024),d.shadow.camera.near=.5,d.shadow.camera.far=60,d.shadow.camera.top=15,d.shadow.camera.bottom=-15,d.shadow.camera.left=-15,d.shadow.camera.right=15,l.add(d);const m=new ph(6702335,6,25);m.position.set(-5,4,3),l.add(m);const p=new ph(16729190,6,25);p.position.set(5,-3,4),l.add(p);const S=new ph(4521932,4,20);S.position.set(0,-6,-5),l.add(S);const v=new Td(2.2,.65,180,24,2,3),x=new G_({color:8939263,metalness:.85,roughness:.12,envMapIntensity:1}),y=new ui(v,x);y.castShadow=!0,y.receiveShadow=!1,l.add(y);const R=new yd(4.5,1),w=new vd({color:4508927,wireframe:!0,transparent:!0,opacity:.35}),M=new ui(R,w);l.add(M);const _=new Ed(yA,14,14),L=[],U=[];for(let B=0;B<Si;B++)for(let rt=0;rt<Si;rt++){const dt=(B*Si+rt)/(Si*Si)*.75+.55,pt=new Me().setHSL(dt,.9,.6),P=new G_({color:pt,metalness:.4,roughness:.3,emissive:pt,emissiveIntensity:.25});U.push(P);const Y=new ui(_,P),j=(B/(Si-1)-.5)*_0,vt=(rt/(Si-1)-.5)*_0;Y.position.set(j,-4,vt),Y.castShadow=!0,Y.receiveShadow=!0,l.add(Y),L.push(Y)}let C=0,G=performance.now(),I=0,O;const V=new IM;function D(){O=requestAnimationFrame(D);const B=V.getElapsedTime();y.rotation.x=B*.38,y.rotation.y=B*.55,M.rotation.x=B*.12,M.rotation.y=B*.18,M.rotation.z=B*.09;for(let st=0;st<Si;st++)for(let dt=0;dt<Si;dt++){const pt=L[st*Si+dt],P=pt.position.x,Y=pt.position.z,j=Math.sqrt(P*P+Y*Y);pt.position.y=-4+Math.sin(B*v0-j*S0)*EA;const vt=U[st*Si+dt];vt.emissiveIntensity=.15+.35*(.5+.5*Math.sin(B*v0-j*S0))}m.position.x=Math.cos(B*.7)*7,m.position.z=Math.sin(B*.7)*7,p.position.x=Math.cos(B*.5+Math.PI)*7,p.position.z=Math.sin(B*.5+Math.PI)*7,c.position.y=5+Math.sin(B*.22)*.8,c.lookAt(0,0,0),r.render(l,c),C++;const rt=performance.now();rt-G>=500&&(I=Math.round(C*1e3/(rt-G)),C=0,G=rt,e.current&&(e.current.textContent=`${I} FPS`))}D();function b(){const B=window.innerWidth,rt=window.innerHeight;c.aspect=B/rt,c.updateProjectionMatrix(),r.setSize(B,rt)}return window.addEventListener("resize",b),cyfr.ready(),()=>{cancelAnimationFrame(O),window.removeEventListener("resize",b),r.dispose(),v.dispose(),x.dispose(),R.dispose(),w.dispose(),_.dispose(),U.forEach(B=>B.dispose()),i.contains(r.domElement)&&i.removeChild(r.domElement)}},[]),aa.jsxs("div",{style:{position:"relative",width:"100vw",height:"100vh",overflow:"hidden"},children:[aa.jsx("div",{ref:o,style:{position:"absolute",inset:0}}),aa.jsxs("div",{style:{position:"absolute",top:16,left:16,color:"rgba(200, 190, 255, 0.9)",fontFamily:"'SF Mono', 'Fira Code', 'Consolas', monospace",fontSize:13,lineHeight:1.6,pointerEvents:"none",userSelect:"none",textShadow:"0 0 12px rgba(120, 80, 255, 0.8)"},children:[aa.jsx("div",{style:{fontSize:17,fontWeight:700,letterSpacing:"0.08em",textTransform:"uppercase",color:"rgba(180, 160, 255, 1)",marginBottom:4},children:"three.js demo"}),aa.jsx("div",{style:{opacity:.75},children:"torus knot · wireframe orbiter · sphere grid"}),aa.jsx("div",{style:{marginTop:6,color:"rgba(100, 255, 180, 0.9)"},children:aa.jsx("span",{ref:e,children:"— FPS"})})]})]})}hx.createRoot(document.getElementById("root")).render(aa.jsx(mu.StrictMode,{children:aa.jsx(TA,{})}));
