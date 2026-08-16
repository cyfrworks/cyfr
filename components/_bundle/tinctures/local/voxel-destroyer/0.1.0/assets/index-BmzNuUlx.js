(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const n of document.querySelectorAll('link[rel="modulepreload"]'))i(n);new MutationObserver(n=>{for(const a of n)if(a.type==="childList")for(const s of a.addedNodes)s.tagName==="LINK"&&s.rel==="modulepreload"&&i(s)}).observe(document,{childList:!0,subtree:!0});function r(n){const a={};return n.integrity&&(a.integrity=n.integrity),n.referrerPolicy&&(a.referrerPolicy=n.referrerPolicy),n.crossOrigin==="use-credentials"?a.credentials="include":n.crossOrigin==="anonymous"?a.credentials="omit":a.credentials="same-origin",a}function i(n){if(n.ep)return;n.ep=!0;const a=r(n);fetch(n.href,a)}})();(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const i of document.querySelectorAll('link[rel="modulepreload"]'))r(i);new MutationObserver(i=>{for(const n of i)if(n.type==="childList")for(const a of n.addedNodes)a.tagName==="LINK"&&a.rel==="modulepreload"&&r(a)}).observe(document,{childList:!0,subtree:!0});function e(i){const n={};return i.integrity&&(n.integrity=i.integrity),i.referrerPolicy&&(n.referrerPolicy=i.referrerPolicy),i.crossOrigin==="use-credentials"?n.credentials="include":i.crossOrigin==="anonymous"?n.credentials="omit":n.credentials="same-origin",n}function r(i){if(i.ep)return;i.ep=!0;const n=e(i);fetch(i.href,n)}})();var Tm={exports:{}},Zl={},Am={exports:{}},et={};/**
* @license React
* react.production.min.js
*
* Copyright (c) Facebook, Inc. and its affiliates.
*
* This source code is licensed under the MIT license found in the
* LICENSE file in the root directory of this source tree.
*/var Js=Symbol.for("react.element"),T_=Symbol.for("react.portal"),A_=Symbol.for("react.fragment"),C_=Symbol.for("react.strict_mode"),R_=Symbol.for("react.profiler"),P_=Symbol.for("react.provider"),L_=Symbol.for("react.context"),U_=Symbol.for("react.forward_ref"),D_=Symbol.for("react.suspense"),I_=Symbol.for("react.memo"),N_=Symbol.for("react.lazy"),Dh=Symbol.iterator;function O_(t){return t===null||typeof t!="object"?null:(t=Dh&&t[Dh]||t["@@iterator"],typeof t=="function"?t:null)}var Cm={isMounted:function(){return!1},enqueueForceUpdate:function(){},enqueueReplaceState:function(){},enqueueSetState:function(){}},Rm=Object.assign,Pm={};function qa(t,e,r){this.props=t,this.context=e,this.refs=Pm,this.updater=r||Cm}qa.prototype.isReactComponent={};qa.prototype.setState=function(t,e){if(typeof t!="object"&&typeof t!="function"&&t!=null)throw Error("setState(...): takes an object of state variables to update or a function which returns an object of state variables.");this.updater.enqueueSetState(this,t,e,"setState")};qa.prototype.forceUpdate=function(t){this.updater.enqueueForceUpdate(this,t,"forceUpdate")};function Lm(){}Lm.prototype=qa.prototype;function Ud(t,e,r){this.props=t,this.context=e,this.refs=Pm,this.updater=r||Cm}var Dd=Ud.prototype=new Lm;Dd.constructor=Ud;Rm(Dd,qa.prototype);Dd.isPureReactComponent=!0;var Ih=Array.isArray,Um=Object.prototype.hasOwnProperty,Id={current:null},Dm={key:!0,ref:!0,__self:!0,__source:!0};function Im(t,e,r){var i,n={},a=null,s=null;if(e!=null)for(i in e.ref!==void 0&&(s=e.ref),e.key!==void 0&&(a=""+e.key),e)Um.call(e,i)&&!Dm.hasOwnProperty(i)&&(n[i]=e[i]);var o=arguments.length-2;if(o===1)n.children=r;else if(1<o){for(var l=Array(o),u=0;u<o;u++)l[u]=arguments[u+2];n.children=l}if(t&&t.defaultProps)for(i in o=t.defaultProps,o)n[i]===void 0&&(n[i]=o[i]);return{$$typeof:Js,type:t,key:a,ref:s,props:n,_owner:Id.current}}function k_(t,e){return{$$typeof:Js,type:t.type,key:e,ref:t.ref,props:t.props,_owner:t._owner}}function Nd(t){return typeof t=="object"&&t!==null&&t.$$typeof===Js}function F_(t){var e={"=":"=0",":":"=2"};return"$"+t.replace(/[=:]/g,function(r){return e[r]})}var Nh=/\/+/g;function Mu(t,e){return typeof t=="object"&&t!==null&&t.key!=null?F_(""+t.key):e.toString(36)}function tl(t,e,r,i,n){var a=typeof t;(a==="undefined"||a==="boolean")&&(t=null);var s=!1;if(t===null)s=!0;else switch(a){case"string":case"number":s=!0;break;case"object":switch(t.$$typeof){case Js:case T_:s=!0}}if(s)return s=t,n=n(s),t=i===""?"."+Mu(s,0):i,Ih(n)?(r="",t!=null&&(r=t.replace(Nh,"$&/")+"/"),tl(n,e,r,"",function(u){return u})):n!=null&&(Nd(n)&&(n=k_(n,r+(!n.key||s&&s.key===n.key?"":(""+n.key).replace(Nh,"$&/")+"/")+t)),e.push(n)),1;if(s=0,i=i===""?".":i+":",Ih(t))for(var o=0;o<t.length;o++){a=t[o];var l=i+Mu(a,o);s+=tl(a,e,r,l,n)}else if(l=O_(t),typeof l=="function")for(t=l.call(t),o=0;!(a=t.next()).done;)a=a.value,l=i+Mu(a,o++),s+=tl(a,e,r,l,n);else if(a==="object")throw e=String(t),Error("Objects are not valid as a React child (found: "+(e==="[object Object]"?"object with keys {"+Object.keys(t).join(", ")+"}":e)+"). If you meant to render a collection of children, use an array instead.");return s}function oo(t,e,r){if(t==null)return t;var i=[],n=0;return tl(t,i,"","",function(a){return e.call(r,a,n++)}),i}function z_(t){if(t._status===-1){var e=t._result;e=e(),e.then(function(r){(t._status===0||t._status===-1)&&(t._status=1,t._result=r)},function(r){(t._status===0||t._status===-1)&&(t._status=2,t._result=r)}),t._status===-1&&(t._status=0,t._result=e)}if(t._status===1)return t._result.default;throw t._result}var or={current:null},rl={transition:null},B_={ReactCurrentDispatcher:or,ReactCurrentBatchConfig:rl,ReactCurrentOwner:Id};function Nm(){throw Error("act(...) is not supported in production builds of React.")}et.Children={map:oo,forEach:function(t,e,r){oo(t,function(){e.apply(this,arguments)},r)},count:function(t){var e=0;return oo(t,function(){e++}),e},toArray:function(t){return oo(t,function(e){return e})||[]},only:function(t){if(!Nd(t))throw Error("React.Children.only expected to receive a single React element child.");return t}};et.Component=qa;et.Fragment=A_;et.Profiler=R_;et.PureComponent=Ud;et.StrictMode=C_;et.Suspense=D_;et.__SECRET_INTERNALS_DO_NOT_USE_OR_YOU_WILL_BE_FIRED=B_;et.act=Nm;et.cloneElement=function(t,e,r){if(t==null)throw Error("React.cloneElement(...): The argument must be a React element, but you passed "+t+".");var i=Rm({},t.props),n=t.key,a=t.ref,s=t._owner;if(e!=null){if(e.ref!==void 0&&(a=e.ref,s=Id.current),e.key!==void 0&&(n=""+e.key),t.type&&t.type.defaultProps)var o=t.type.defaultProps;for(l in e)Um.call(e,l)&&!Dm.hasOwnProperty(l)&&(i[l]=e[l]===void 0&&o!==void 0?o[l]:e[l])}var l=arguments.length-2;if(l===1)i.children=r;else if(1<l){o=Array(l);for(var u=0;u<l;u++)o[u]=arguments[u+2];i.children=o}return{$$typeof:Js,type:t.type,key:n,ref:a,props:i,_owner:s}};et.createContext=function(t){return t={$$typeof:L_,_currentValue:t,_currentValue2:t,_threadCount:0,Provider:null,Consumer:null,_defaultValue:null,_globalName:null},t.Provider={$$typeof:P_,_context:t},t.Consumer=t};et.createElement=Im;et.createFactory=function(t){var e=Im.bind(null,t);return e.type=t,e};et.createRef=function(){return{current:null}};et.forwardRef=function(t){return{$$typeof:U_,render:t}};et.isValidElement=Nd;et.lazy=function(t){return{$$typeof:N_,_payload:{_status:-1,_result:t},_init:z_}};et.memo=function(t,e){return{$$typeof:I_,type:t,compare:e===void 0?null:e}};et.startTransition=function(t){var e=rl.transition;rl.transition={};try{t()}finally{rl.transition=e}};et.unstable_act=Nm;et.useCallback=function(t,e){return or.current.useCallback(t,e)};et.useContext=function(t){return or.current.useContext(t)};et.useDebugValue=function(){};et.useDeferredValue=function(t){return or.current.useDeferredValue(t)};et.useEffect=function(t,e){return or.current.useEffect(t,e)};et.useId=function(){return or.current.useId()};et.useImperativeHandle=function(t,e,r){return or.current.useImperativeHandle(t,e,r)};et.useInsertionEffect=function(t,e){return or.current.useInsertionEffect(t,e)};et.useLayoutEffect=function(t,e){return or.current.useLayoutEffect(t,e)};et.useMemo=function(t,e){return or.current.useMemo(t,e)};et.useReducer=function(t,e,r){return or.current.useReducer(t,e,r)};et.useRef=function(t){return or.current.useRef(t)};et.useState=function(t){return or.current.useState(t)};et.useSyncExternalStore=function(t,e,r){return or.current.useSyncExternalStore(t,e,r)};et.useTransition=function(){return or.current.useTransition()};et.version="18.3.1";Am.exports=et;var cr=Am.exports;/**
* @license React
* react-jsx-runtime.production.min.js
*
* Copyright (c) Facebook, Inc. and its affiliates.
*
* This source code is licensed under the MIT license found in the
* LICENSE file in the root directory of this source tree.
*/var V_=cr,H_=Symbol.for("react.element"),G_=Symbol.for("react.fragment"),W_=Object.prototype.hasOwnProperty,j_=V_.__SECRET_INTERNALS_DO_NOT_USE_OR_YOU_WILL_BE_FIRED.ReactCurrentOwner,X_={key:!0,ref:!0,__self:!0,__source:!0};function Om(t,e,r){var i,n={},a=null,s=null;r!==void 0&&(a=""+r),e.key!==void 0&&(a=""+e.key),e.ref!==void 0&&(s=e.ref);for(i in e)W_.call(e,i)&&!X_.hasOwnProperty(i)&&(n[i]=e[i]);if(t&&t.defaultProps)for(i in e=t.defaultProps,e)n[i]===void 0&&(n[i]=e[i]);return{$$typeof:H_,type:t,key:a,ref:s,props:n,_owner:j_.current}}Zl.Fragment=G_;Zl.jsx=Om;Zl.jsxs=Om;Tm.exports=Zl;var Ut=Tm.exports,km={exports:{}},Tr={},Fm={exports:{}},zm={};/**
* @license React
* scheduler.production.min.js
*
* Copyright (c) Facebook, Inc. and its affiliates.
*
* This source code is licensed under the MIT license found in the
* LICENSE file in the root directory of this source tree.
*/(function(t){function e(I,Z){var re=I.length;I.push(Z);e:for(;0<re;){var xe=re-1>>>1,fe=I[xe];if(0<n(fe,Z))I[xe]=Z,I[re]=fe,re=xe;else break e}}function r(I){return I.length===0?null:I[0]}function i(I){if(I.length===0)return null;var Z=I[0],re=I.pop();if(re!==Z){I[0]=re;e:for(var xe=0,fe=I.length,Ue=fe>>>1;xe<Ue;){var Y=2*(xe+1)-1,ee=I[Y],ae=Y+1,ue=I[ae];if(0>n(ee,re))ae<fe&&0>n(ue,ee)?(I[xe]=ue,I[ae]=re,xe=ae):(I[xe]=ee,I[Y]=re,xe=Y);else if(ae<fe&&0>n(ue,re))I[xe]=ue,I[ae]=re,xe=ae;else break e}}return Z}function n(I,Z){var re=I.sortIndex-Z.sortIndex;return re!==0?re:I.id-Z.id}if(typeof performance=="object"&&typeof performance.now=="function"){var a=performance;t.unstable_now=function(){return a.now()}}else{var s=Date,o=s.now();t.unstable_now=function(){return s.now()-o}}var l=[],u=[],h=1,f=null,d=3,p=!1,_=!1,x=!1,m=typeof setTimeout=="function"?setTimeout:null,c=typeof clearTimeout=="function"?clearTimeout:null,g=typeof setImmediate<"u"?setImmediate:null;typeof navigator<"u"&&navigator.scheduling!==void 0&&navigator.scheduling.isInputPending!==void 0&&navigator.scheduling.isInputPending.bind(navigator.scheduling);function v(I){for(var Z=r(u);Z!==null;){if(Z.callback===null)i(u);else if(Z.startTime<=I)i(u),Z.sortIndex=Z.expirationTime,e(l,Z);else break;Z=r(u)}}function M(I){if(x=!1,v(I),!_)if(r(l)!==null)_=!0,K(P);else{var Z=r(u);Z!==null&&ne(M,Z.startTime-I)}}function P(I,Z){_=!1,x&&(x=!1,c(L),L=-1),p=!0;var re=d;try{for(v(Z),f=r(l);f!==null&&(!(f.expirationTime>Z)||I&&!U());){var xe=f.callback;if(typeof xe=="function"){f.callback=null,d=f.priorityLevel;var fe=xe(f.expirationTime<=Z);Z=t.unstable_now(),typeof fe=="function"?f.callback=fe:f===r(l)&&i(l),v(Z)}else i(l);f=r(l)}if(f!==null)var Ue=!0;else{var Y=r(u);Y!==null&&ne(M,Y.startTime-Z),Ue=!1}return Ue}finally{f=null,d=re,p=!1}}var T=!1,w=null,L=-1,b=5,y=-1;function U(){return!(t.unstable_now()-y<b)}function B(){if(w!==null){var I=t.unstable_now();y=I;var Z=!0;try{Z=w(!0,I)}finally{Z?V():(T=!1,w=null)}}else T=!1}var V;if(typeof g=="function")V=function(){g(B)};else if(typeof MessageChannel<"u"){var q=new MessageChannel,J=q.port2;q.port1.onmessage=B,V=function(){J.postMessage(null)}}else V=function(){m(B,0)};function K(I){w=I,T||(T=!0,V())}function ne(I,Z){L=m(function(){I(t.unstable_now())},Z)}t.unstable_IdlePriority=5,t.unstable_ImmediatePriority=1,t.unstable_LowPriority=4,t.unstable_NormalPriority=3,t.unstable_Profiling=null,t.unstable_UserBlockingPriority=2,t.unstable_cancelCallback=function(I){I.callback=null},t.unstable_continueExecution=function(){_||p||(_=!0,K(P))},t.unstable_forceFrameRate=function(I){0>I||125<I?console.error("forceFrameRate takes a positive int between 0 and 125, forcing frame rates higher than 125 fps is not supported"):b=0<I?Math.floor(1e3/I):5},t.unstable_getCurrentPriorityLevel=function(){return d},t.unstable_getFirstCallbackNode=function(){return r(l)},t.unstable_next=function(I){switch(d){case 1:case 2:case 3:var Z=3;break;default:Z=d}var re=d;d=Z;try{return I()}finally{d=re}},t.unstable_pauseExecution=function(){},t.unstable_requestPaint=function(){},t.unstable_runWithPriority=function(I,Z){switch(I){case 1:case 2:case 3:case 4:case 5:break;default:I=3}var re=d;d=I;try{return Z()}finally{d=re}},t.unstable_scheduleCallback=function(I,Z,re){var xe=t.unstable_now();switch(typeof re=="object"&&re!==null?(re=re.delay,re=typeof re=="number"&&0<re?xe+re:xe):re=xe,I){case 1:var fe=-1;break;case 2:fe=250;break;case 5:fe=1073741823;break;case 4:fe=1e4;break;default:fe=5e3}return fe=re+fe,I={id:h++,callback:Z,priorityLevel:I,startTime:re,expirationTime:fe,sortIndex:-1},re>xe?(I.sortIndex=re,e(u,I),r(l)===null&&I===r(u)&&(x?(c(L),L=-1):x=!0,ne(M,re-xe))):(I.sortIndex=fe,e(l,I),_||p||(_=!0,K(P))),I},t.unstable_shouldYield=U,t.unstable_wrapCallback=function(I){var Z=d;return function(){var re=d;d=Z;try{return I.apply(this,arguments)}finally{d=re}}}})(zm);Fm.exports=zm;var Y_=Fm.exports;/**
* @license React
* react-dom.production.min.js
*
* Copyright (c) Facebook, Inc. and its affiliates.
*
* This source code is licensed under the MIT license found in the
* LICENSE file in the root directory of this source tree.
*/var q_=cr,wr=Y_;function ce(t){for(var e="https://reactjs.org/docs/error-decoder.html?invariant="+t,r=1;r<arguments.length;r++)e+="&args[]="+encodeURIComponent(arguments[r]);return"Minified React error #"+t+"; visit "+e+" for the full message or use the non-minified dev environment for full errors and additional helpful warnings."}var Bm=new Set,Ns={};function Vn(t,e){Na(t,e),Na(t+"Capture",e)}function Na(t,e){for(Ns[t]=e,t=0;t<e.length;t++)Bm.add(e[t])}var wi=!(typeof window>"u"||typeof window.document>"u"||typeof window.document.createElement>"u"),Uc=Object.prototype.hasOwnProperty,K_=/^[:A-Z_a-z\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u02FF\u0370-\u037D\u037F-\u1FFF\u200C-\u200D\u2070-\u218F\u2C00-\u2FEF\u3001-\uD7FF\uF900-\uFDCF\uFDF0-\uFFFD][:A-Z_a-z\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u02FF\u0370-\u037D\u037F-\u1FFF\u200C-\u200D\u2070-\u218F\u2C00-\u2FEF\u3001-\uD7FF\uF900-\uFDCF\uFDF0-\uFFFD\-.0-9\u00B7\u0300-\u036F\u203F-\u2040]*$/,Oh={},kh={};function Z_(t){return Uc.call(kh,t)?!0:Uc.call(Oh,t)?!1:K_.test(t)?kh[t]=!0:(Oh[t]=!0,!1)}function $_(t,e,r,i){if(r!==null&&r.type===0)return!1;switch(typeof e){case"function":case"symbol":return!0;case"boolean":return i?!1:r!==null?!r.acceptsBooleans:(t=t.toLowerCase().slice(0,5),t!=="data-"&&t!=="aria-");default:return!1}}function Q_(t,e,r,i){if(e===null||typeof e>"u"||$_(t,e,r,i))return!0;if(i)return!1;if(r!==null)switch(r.type){case 3:return!e;case 4:return e===!1;case 5:return isNaN(e);case 6:return isNaN(e)||1>e}return!1}function lr(t,e,r,i,n,a,s){this.acceptsBooleans=e===2||e===3||e===4,this.attributeName=i,this.attributeNamespace=n,this.mustUseProperty=r,this.propertyName=t,this.type=e,this.sanitizeURL=a,this.removeEmptyString=s}var qt={};"children dangerouslySetInnerHTML defaultValue defaultChecked innerHTML suppressContentEditableWarning suppressHydrationWarning style".split(" ").forEach(function(t){qt[t]=new lr(t,0,!1,t,null,!1,!1)});[["acceptCharset","accept-charset"],["className","class"],["htmlFor","for"],["httpEquiv","http-equiv"]].forEach(function(t){var e=t[0];qt[e]=new lr(e,1,!1,t[1],null,!1,!1)});["contentEditable","draggable","spellCheck","value"].forEach(function(t){qt[t]=new lr(t,2,!1,t.toLowerCase(),null,!1,!1)});["autoReverse","externalResourcesRequired","focusable","preserveAlpha"].forEach(function(t){qt[t]=new lr(t,2,!1,t,null,!1,!1)});"allowFullScreen async autoFocus autoPlay controls default defer disabled disablePictureInPicture disableRemotePlayback formNoValidate hidden loop noModule noValidate open playsInline readOnly required reversed scoped seamless itemScope".split(" ").forEach(function(t){qt[t]=new lr(t,3,!1,t.toLowerCase(),null,!1,!1)});["checked","multiple","muted","selected"].forEach(function(t){qt[t]=new lr(t,3,!0,t,null,!1,!1)});["capture","download"].forEach(function(t){qt[t]=new lr(t,4,!1,t,null,!1,!1)});["cols","rows","size","span"].forEach(function(t){qt[t]=new lr(t,6,!1,t,null,!1,!1)});["rowSpan","start"].forEach(function(t){qt[t]=new lr(t,5,!1,t.toLowerCase(),null,!1,!1)});var Od=/[\-:]([a-z])/g;function kd(t){return t[1].toUpperCase()}"accent-height alignment-baseline arabic-form baseline-shift cap-height clip-path clip-rule color-interpolation color-interpolation-filters color-profile color-rendering dominant-baseline enable-background fill-opacity fill-rule flood-color flood-opacity font-family font-size font-size-adjust font-stretch font-style font-variant font-weight glyph-name glyph-orientation-horizontal glyph-orientation-vertical horiz-adv-x horiz-origin-x image-rendering letter-spacing lighting-color marker-end marker-mid marker-start overline-position overline-thickness paint-order panose-1 pointer-events rendering-intent shape-rendering stop-color stop-opacity strikethrough-position strikethrough-thickness stroke-dasharray stroke-dashoffset stroke-linecap stroke-linejoin stroke-miterlimit stroke-opacity stroke-width text-anchor text-decoration text-rendering underline-position underline-thickness unicode-bidi unicode-range units-per-em v-alphabetic v-hanging v-ideographic v-mathematical vector-effect vert-adv-y vert-origin-x vert-origin-y word-spacing writing-mode xmlns:xlink x-height".split(" ").forEach(function(t){var e=t.replace(Od,kd);qt[e]=new lr(e,1,!1,t,null,!1,!1)});"xlink:actuate xlink:arcrole xlink:role xlink:show xlink:title xlink:type".split(" ").forEach(function(t){var e=t.replace(Od,kd);qt[e]=new lr(e,1,!1,t,"http://www.w3.org/1999/xlink",!1,!1)});["xml:base","xml:lang","xml:space"].forEach(function(t){var e=t.replace(Od,kd);qt[e]=new lr(e,1,!1,t,"http://www.w3.org/XML/1998/namespace",!1,!1)});["tabIndex","crossOrigin"].forEach(function(t){qt[t]=new lr(t,1,!1,t.toLowerCase(),null,!1,!1)});qt.xlinkHref=new lr("xlinkHref",1,!1,"xlink:href","http://www.w3.org/1999/xlink",!0,!1);["src","href","action","formAction"].forEach(function(t){qt[t]=new lr(t,1,!1,t.toLowerCase(),null,!0,!0)});function Fd(t,e,r,i){var n=qt.hasOwnProperty(e)?qt[e]:null;(n!==null?n.type!==0:i||!(2<e.length)||e[0]!=="o"&&e[0]!=="O"||e[1]!=="n"&&e[1]!=="N")&&(Q_(e,r,n,i)&&(r=null),i||n===null?Z_(e)&&(r===null?t.removeAttribute(e):t.setAttribute(e,""+r)):n.mustUseProperty?t[n.propertyName]=r===null?n.type===3?!1:"":r:(e=n.attributeName,i=n.attributeNamespace,r===null?t.removeAttribute(e):(n=n.type,r=n===3||n===4&&r===!0?"":""+r,i?t.setAttributeNS(i,e,r):t.setAttribute(e,r))))}var Ri=q_.__SECRET_INTERNALS_DO_NOT_USE_OR_YOU_WILL_BE_FIRED,lo=Symbol.for("react.element"),ha=Symbol.for("react.portal"),fa=Symbol.for("react.fragment"),zd=Symbol.for("react.strict_mode"),Dc=Symbol.for("react.profiler"),Vm=Symbol.for("react.provider"),Hm=Symbol.for("react.context"),Bd=Symbol.for("react.forward_ref"),Ic=Symbol.for("react.suspense"),Nc=Symbol.for("react.suspense_list"),Vd=Symbol.for("react.memo"),Fi=Symbol.for("react.lazy"),Gm=Symbol.for("react.offscreen"),Fh=Symbol.iterator;function ts(t){return t===null||typeof t!="object"?null:(t=Fh&&t[Fh]||t["@@iterator"],typeof t=="function"?t:null)}var wt=Object.assign,Su;function ys(t){if(Su===void 0)try{throw Error()}catch(r){var e=r.stack.trim().match(/\n( *(at )?)/);Su=e&&e[1]||""}return`
`+Su+t}var bu=!1;function Eu(t,e){if(!t||bu)return"";bu=!0;var r=Error.prepareStackTrace;Error.prepareStackTrace=void 0;try{if(e)if(e=function(){throw Error()},Object.defineProperty(e.prototype,"props",{set:function(){throw Error()}}),typeof Reflect=="object"&&Reflect.construct){try{Reflect.construct(e,[])}catch(u){var i=u}Reflect.construct(t,[],e)}else{try{e.call()}catch(u){i=u}t.call(e.prototype)}else{try{throw Error()}catch(u){i=u}t()}}catch(u){if(u&&i&&typeof u.stack=="string"){for(var n=u.stack.split(`
`),a=i.stack.split(`
`),s=n.length-1,o=a.length-1;1<=s&&0<=o&&n[s]!==a[o];)o--;for(;1<=s&&0<=o;s--,o--)if(n[s]!==a[o]){if(s!==1||o!==1)do if(s--,o--,0>o||n[s]!==a[o]){var l=`
`+n[s].replace(" at new "," at ");return t.displayName&&l.includes("<anonymous>")&&(l=l.replace("<anonymous>",t.displayName)),l}while(1<=s&&0<=o);break}}}finally{bu=!1,Error.prepareStackTrace=r}return(t=t?t.displayName||t.name:"")?ys(t):""}function J_(t){switch(t.tag){case 5:return ys(t.type);case 16:return ys("Lazy");case 13:return ys("Suspense");case 19:return ys("SuspenseList");case 0:case 2:case 15:return t=Eu(t.type,!1),t;case 11:return t=Eu(t.type.render,!1),t;case 1:return t=Eu(t.type,!0),t;default:return""}}function Oc(t){if(t==null)return null;if(typeof t=="function")return t.displayName||t.name||null;if(typeof t=="string")return t;switch(t){case fa:return"Fragment";case ha:return"Portal";case Dc:return"Profiler";case zd:return"StrictMode";case Ic:return"Suspense";case Nc:return"SuspenseList"}if(typeof t=="object")switch(t.$$typeof){case Hm:return(t.displayName||"Context")+".Consumer";case Vm:return(t._context.displayName||"Context")+".Provider";case Bd:var e=t.render;return t=t.displayName,t||(t=e.displayName||e.name||"",t=t!==""?"ForwardRef("+t+")":"ForwardRef"),t;case Vd:return e=t.displayName||null,e!==null?e:Oc(t.type)||"Memo";case Fi:e=t._payload,t=t._init;try{return Oc(t(e))}catch{}}return null}function e0(t){var e=t.type;switch(t.tag){case 24:return"Cache";case 9:return(e.displayName||"Context")+".Consumer";case 10:return(e._context.displayName||"Context")+".Provider";case 18:return"DehydratedFragment";case 11:return t=e.render,t=t.displayName||t.name||"",e.displayName||(t!==""?"ForwardRef("+t+")":"ForwardRef");case 7:return"Fragment";case 5:return e;case 4:return"Portal";case 3:return"Root";case 6:return"Text";case 16:return Oc(e);case 8:return e===zd?"StrictMode":"Mode";case 22:return"Offscreen";case 12:return"Profiler";case 21:return"Scope";case 13:return"Suspense";case 19:return"SuspenseList";case 25:return"TracingMarker";case 1:case 0:case 17:case 2:case 14:case 15:if(typeof e=="function")return e.displayName||e.name||null;if(typeof e=="string")return e}return null}function an(t){switch(typeof t){case"boolean":case"number":case"string":case"undefined":return t;case"object":return t;default:return""}}function Wm(t){var e=t.type;return(t=t.nodeName)&&t.toLowerCase()==="input"&&(e==="checkbox"||e==="radio")}function t0(t){var e=Wm(t)?"checked":"value",r=Object.getOwnPropertyDescriptor(t.constructor.prototype,e),i=""+t[e];if(!t.hasOwnProperty(e)&&typeof r<"u"&&typeof r.get=="function"&&typeof r.set=="function"){var n=r.get,a=r.set;return Object.defineProperty(t,e,{configurable:!0,get:function(){return n.call(this)},set:function(s){i=""+s,a.call(this,s)}}),Object.defineProperty(t,e,{enumerable:r.enumerable}),{getValue:function(){return i},setValue:function(s){i=""+s},stopTracking:function(){t._valueTracker=null,delete t[e]}}}}function uo(t){t._valueTracker||(t._valueTracker=t0(t))}function jm(t){if(!t)return!1;var e=t._valueTracker;if(!e)return!0;var r=e.getValue(),i="";return t&&(i=Wm(t)?t.checked?"true":"false":t.value),t=i,t!==r?(e.setValue(t),!0):!1}function ml(t){if(t=t||(typeof document<"u"?document:void 0),typeof t>"u")return null;try{return t.activeElement||t.body}catch{return t.body}}function kc(t,e){var r=e.checked;return wt({},e,{defaultChecked:void 0,defaultValue:void 0,value:void 0,checked:r??t._wrapperState.initialChecked})}function zh(t,e){var r=e.defaultValue==null?"":e.defaultValue,i=e.checked!=null?e.checked:e.defaultChecked;r=an(e.value!=null?e.value:r),t._wrapperState={initialChecked:i,initialValue:r,controlled:e.type==="checkbox"||e.type==="radio"?e.checked!=null:e.value!=null}}function Xm(t,e){e=e.checked,e!=null&&Fd(t,"checked",e,!1)}function Fc(t,e){Xm(t,e);var r=an(e.value),i=e.type;if(r!=null)i==="number"?(r===0&&t.value===""||t.value!=r)&&(t.value=""+r):t.value!==""+r&&(t.value=""+r);else if(i==="submit"||i==="reset"){t.removeAttribute("value");return}e.hasOwnProperty("value")?zc(t,e.type,r):e.hasOwnProperty("defaultValue")&&zc(t,e.type,an(e.defaultValue)),e.checked==null&&e.defaultChecked!=null&&(t.defaultChecked=!!e.defaultChecked)}function Bh(t,e,r){if(e.hasOwnProperty("value")||e.hasOwnProperty("defaultValue")){var i=e.type;if(!(i!=="submit"&&i!=="reset"||e.value!==void 0&&e.value!==null))return;e=""+t._wrapperState.initialValue,r||e===t.value||(t.value=e),t.defaultValue=e}r=t.name,r!==""&&(t.name=""),t.defaultChecked=!!t._wrapperState.initialChecked,r!==""&&(t.name=r)}function zc(t,e,r){(e!=="number"||ml(t.ownerDocument)!==t)&&(r==null?t.defaultValue=""+t._wrapperState.initialValue:t.defaultValue!==""+r&&(t.defaultValue=""+r))}var Ms=Array.isArray;function wa(t,e,r,i){if(t=t.options,e){e={};for(var n=0;n<r.length;n++)e["$"+r[n]]=!0;for(r=0;r<t.length;r++)n=e.hasOwnProperty("$"+t[r].value),t[r].selected!==n&&(t[r].selected=n),n&&i&&(t[r].defaultSelected=!0)}else{for(r=""+an(r),e=null,n=0;n<t.length;n++){if(t[n].value===r){t[n].selected=!0,i&&(t[n].defaultSelected=!0);return}e!==null||t[n].disabled||(e=t[n])}e!==null&&(e.selected=!0)}}function Bc(t,e){if(e.dangerouslySetInnerHTML!=null)throw Error(ce(91));return wt({},e,{value:void 0,defaultValue:void 0,children:""+t._wrapperState.initialValue})}function Vh(t,e){var r=e.value;if(r==null){if(r=e.children,e=e.defaultValue,r!=null){if(e!=null)throw Error(ce(92));if(Ms(r)){if(1<r.length)throw Error(ce(93));r=r[0]}e=r}e==null&&(e=""),r=e}t._wrapperState={initialValue:an(r)}}function Ym(t,e){var r=an(e.value),i=an(e.defaultValue);r!=null&&(r=""+r,r!==t.value&&(t.value=r),e.defaultValue==null&&t.defaultValue!==r&&(t.defaultValue=r)),i!=null&&(t.defaultValue=""+i)}function Hh(t){var e=t.textContent;e===t._wrapperState.initialValue&&e!==""&&e!==null&&(t.value=e)}function qm(t){switch(t){case"svg":return"http://www.w3.org/2000/svg";case"math":return"http://www.w3.org/1998/Math/MathML";default:return"http://www.w3.org/1999/xhtml"}}function Vc(t,e){return t==null||t==="http://www.w3.org/1999/xhtml"?qm(e):t==="http://www.w3.org/2000/svg"&&e==="foreignObject"?"http://www.w3.org/1999/xhtml":t}var co,Km=function(t){return typeof MSApp<"u"&&MSApp.execUnsafeLocalFunction?function(e,r,i,n){MSApp.execUnsafeLocalFunction(function(){return t(e,r,i,n)})}:t}(function(t,e){if(t.namespaceURI!=="http://www.w3.org/2000/svg"||"innerHTML"in t)t.innerHTML=e;else{for(co=co||document.createElement("div"),co.innerHTML="<svg>"+e.valueOf().toString()+"</svg>",e=co.firstChild;t.firstChild;)t.removeChild(t.firstChild);for(;e.firstChild;)t.appendChild(e.firstChild)}});function Os(t,e){if(e){var r=t.firstChild;if(r&&r===t.lastChild&&r.nodeType===3){r.nodeValue=e;return}}t.textContent=e}var ws={animationIterationCount:!0,aspectRatio:!0,borderImageOutset:!0,borderImageSlice:!0,borderImageWidth:!0,boxFlex:!0,boxFlexGroup:!0,boxOrdinalGroup:!0,columnCount:!0,columns:!0,flex:!0,flexGrow:!0,flexPositive:!0,flexShrink:!0,flexNegative:!0,flexOrder:!0,gridArea:!0,gridRow:!0,gridRowEnd:!0,gridRowSpan:!0,gridRowStart:!0,gridColumn:!0,gridColumnEnd:!0,gridColumnSpan:!0,gridColumnStart:!0,fontWeight:!0,lineClamp:!0,lineHeight:!0,opacity:!0,order:!0,orphans:!0,tabSize:!0,widows:!0,zIndex:!0,zoom:!0,fillOpacity:!0,floodOpacity:!0,stopOpacity:!0,strokeDasharray:!0,strokeDashoffset:!0,strokeMiterlimit:!0,strokeOpacity:!0,strokeWidth:!0},r0=["Webkit","ms","Moz","O"];Object.keys(ws).forEach(function(t){r0.forEach(function(e){e=e+t.charAt(0).toUpperCase()+t.substring(1),ws[e]=ws[t]})});function Zm(t,e,r){return e==null||typeof e=="boolean"||e===""?"":r||typeof e!="number"||e===0||ws.hasOwnProperty(t)&&ws[t]?(""+e).trim():e+"px"}function $m(t,e){t=t.style;for(var r in e)if(e.hasOwnProperty(r)){var i=r.indexOf("--")===0,n=Zm(r,e[r],i);r==="float"&&(r="cssFloat"),i?t.setProperty(r,n):t[r]=n}}var i0=wt({menuitem:!0},{area:!0,base:!0,br:!0,col:!0,embed:!0,hr:!0,img:!0,input:!0,keygen:!0,link:!0,meta:!0,param:!0,source:!0,track:!0,wbr:!0});function Hc(t,e){if(e){if(i0[t]&&(e.children!=null||e.dangerouslySetInnerHTML!=null))throw Error(ce(137,t));if(e.dangerouslySetInnerHTML!=null){if(e.children!=null)throw Error(ce(60));if(typeof e.dangerouslySetInnerHTML!="object"||!("__html"in e.dangerouslySetInnerHTML))throw Error(ce(61))}if(e.style!=null&&typeof e.style!="object")throw Error(ce(62))}}function Gc(t,e){if(t.indexOf("-")===-1)return typeof e.is=="string";switch(t){case"annotation-xml":case"color-profile":case"font-face":case"font-face-src":case"font-face-uri":case"font-face-format":case"font-face-name":case"missing-glyph":return!1;default:return!0}}var Wc=null;function Hd(t){return t=t.target||t.srcElement||window,t.correspondingUseElement&&(t=t.correspondingUseElement),t.nodeType===3?t.parentNode:t}var jc=null,Ta=null,Aa=null;function Gh(t){if(t=ro(t)){if(typeof jc!="function")throw Error(ce(280));var e=t.stateNode;e&&(e=tu(e),jc(t.stateNode,t.type,e))}}function Qm(t){Ta?Aa?Aa.push(t):Aa=[t]:Ta=t}function Jm(){if(Ta){var t=Ta,e=Aa;if(Aa=Ta=null,Gh(t),e)for(t=0;t<e.length;t++)Gh(e[t])}}function eg(t,e){return t(e)}function tg(){}var wu=!1;function rg(t,e,r){if(wu)return t(e,r);wu=!0;try{return eg(t,e,r)}finally{wu=!1,(Ta!==null||Aa!==null)&&(tg(),Jm())}}function ks(t,e){var r=t.stateNode;if(r===null)return null;var i=tu(r);if(i===null)return null;r=i[e];e:switch(e){case"onClick":case"onClickCapture":case"onDoubleClick":case"onDoubleClickCapture":case"onMouseDown":case"onMouseDownCapture":case"onMouseMove":case"onMouseMoveCapture":case"onMouseUp":case"onMouseUpCapture":case"onMouseEnter":(i=!i.disabled)||(t=t.type,i=!(t==="button"||t==="input"||t==="select"||t==="textarea")),t=!i;break e;default:t=!1}if(t)return null;if(r&&typeof r!="function")throw Error(ce(231,e,typeof r));return r}var Xc=!1;if(wi)try{var rs={};Object.defineProperty(rs,"passive",{get:function(){Xc=!0}}),window.addEventListener("test",rs,rs),window.removeEventListener("test",rs,rs)}catch{Xc=!1}function n0(t,e,r,i,n,a,s,o,l){var u=Array.prototype.slice.call(arguments,3);try{e.apply(r,u)}catch(h){this.onError(h)}}var Ts=!1,gl=null,vl=!1,Yc=null,a0={onError:function(t){Ts=!0,gl=t}};function s0(t,e,r,i,n,a,s,o,l){Ts=!1,gl=null,n0.apply(a0,arguments)}function o0(t,e,r,i,n,a,s,o,l){if(s0.apply(this,arguments),Ts){if(Ts){var u=gl;Ts=!1,gl=null}else throw Error(ce(198));vl||(vl=!0,Yc=u)}}function Hn(t){var e=t,r=t;if(t.alternate)for(;e.return;)e=e.return;else{t=e;do e=t,e.flags&4098&&(r=e.return),t=e.return;while(t)}return e.tag===3?r:null}function ig(t){if(t.tag===13){var e=t.memoizedState;if(e===null&&(t=t.alternate,t!==null&&(e=t.memoizedState)),e!==null)return e.dehydrated}return null}function Wh(t){if(Hn(t)!==t)throw Error(ce(188))}function l0(t){var e=t.alternate;if(!e){if(e=Hn(t),e===null)throw Error(ce(188));return e!==t?null:t}for(var r=t,i=e;;){var n=r.return;if(n===null)break;var a=n.alternate;if(a===null){if(i=n.return,i!==null){r=i;continue}break}if(n.child===a.child){for(a=n.child;a;){if(a===r)return Wh(n),t;if(a===i)return Wh(n),e;a=a.sibling}throw Error(ce(188))}if(r.return!==i.return)r=n,i=a;else{for(var s=!1,o=n.child;o;){if(o===r){s=!0,r=n,i=a;break}if(o===i){s=!0,i=n,r=a;break}o=o.sibling}if(!s){for(o=a.child;o;){if(o===r){s=!0,r=a,i=n;break}if(o===i){s=!0,i=a,r=n;break}o=o.sibling}if(!s)throw Error(ce(189))}}if(r.alternate!==i)throw Error(ce(190))}if(r.tag!==3)throw Error(ce(188));return r.stateNode.current===r?t:e}function ng(t){return t=l0(t),t!==null?ag(t):null}function ag(t){if(t.tag===5||t.tag===6)return t;for(t=t.child;t!==null;){var e=ag(t);if(e!==null)return e;t=t.sibling}return null}var sg=wr.unstable_scheduleCallback,jh=wr.unstable_cancelCallback,u0=wr.unstable_shouldYield,c0=wr.unstable_requestPaint,Ct=wr.unstable_now,d0=wr.unstable_getCurrentPriorityLevel,Gd=wr.unstable_ImmediatePriority,og=wr.unstable_UserBlockingPriority,_l=wr.unstable_NormalPriority,h0=wr.unstable_LowPriority,lg=wr.unstable_IdlePriority,$l=null,ai=null;function f0(t){if(ai&&typeof ai.onCommitFiberRoot=="function")try{ai.onCommitFiberRoot($l,t,void 0,(t.current.flags&128)===128)}catch{}}var Yr=Math.clz32?Math.clz32:g0,p0=Math.log,m0=Math.LN2;function g0(t){return t>>>=0,t===0?32:31-(p0(t)/m0|0)|0}var ho=64,fo=4194304;function Ss(t){switch(t&-t){case 1:return 1;case 2:return 2;case 4:return 4;case 8:return 8;case 16:return 16;case 32:return 32;case 64:case 128:case 256:case 512:case 1024:case 2048:case 4096:case 8192:case 16384:case 32768:case 65536:case 131072:case 262144:case 524288:case 1048576:case 2097152:return t&4194240;case 4194304:case 8388608:case 16777216:case 33554432:case 67108864:return t&130023424;case 134217728:return 134217728;case 268435456:return 268435456;case 536870912:return 536870912;case 1073741824:return 1073741824;default:return t}}function xl(t,e){var r=t.pendingLanes;if(r===0)return 0;var i=0,n=t.suspendedLanes,a=t.pingedLanes,s=r&268435455;if(s!==0){var o=s&~n;o!==0?i=Ss(o):(a&=s,a!==0&&(i=Ss(a)))}else s=r&~n,s!==0?i=Ss(s):a!==0&&(i=Ss(a));if(i===0)return 0;if(e!==0&&e!==i&&!(e&n)&&(n=i&-i,a=e&-e,n>=a||n===16&&(a&4194240)!==0))return e;if(i&4&&(i|=r&16),e=t.entangledLanes,e!==0)for(t=t.entanglements,e&=i;0<e;)r=31-Yr(e),n=1<<r,i|=t[r],e&=~n;return i}function v0(t,e){switch(t){case 1:case 2:case 4:return e+250;case 8:case 16:case 32:case 64:case 128:case 256:case 512:case 1024:case 2048:case 4096:case 8192:case 16384:case 32768:case 65536:case 131072:case 262144:case 524288:case 1048576:case 2097152:return e+5e3;case 4194304:case 8388608:case 16777216:case 33554432:case 67108864:return-1;case 134217728:case 268435456:case 536870912:case 1073741824:return-1;default:return-1}}function _0(t,e){for(var r=t.suspendedLanes,i=t.pingedLanes,n=t.expirationTimes,a=t.pendingLanes;0<a;){var s=31-Yr(a),o=1<<s,l=n[s];l===-1?(!(o&r)||o&i)&&(n[s]=v0(o,e)):l<=e&&(t.expiredLanes|=o),a&=~o}}function qc(t){return t=t.pendingLanes&-1073741825,t!==0?t:t&1073741824?1073741824:0}function ug(){var t=ho;return ho<<=1,!(ho&4194240)&&(ho=64),t}function Tu(t){for(var e=[],r=0;31>r;r++)e.push(t);return e}function eo(t,e,r){t.pendingLanes|=e,e!==536870912&&(t.suspendedLanes=0,t.pingedLanes=0),t=t.eventTimes,e=31-Yr(e),t[e]=r}function x0(t,e){var r=t.pendingLanes&~e;t.pendingLanes=e,t.suspendedLanes=0,t.pingedLanes=0,t.expiredLanes&=e,t.mutableReadLanes&=e,t.entangledLanes&=e,e=t.entanglements;var i=t.eventTimes;for(t=t.expirationTimes;0<r;){var n=31-Yr(r),a=1<<n;e[n]=0,i[n]=-1,t[n]=-1,r&=~a}}function Wd(t,e){var r=t.entangledLanes|=e;for(t=t.entanglements;r;){var i=31-Yr(r),n=1<<i;n&e|t[i]&e&&(t[i]|=e),r&=~n}}var ct=0;function cg(t){return t&=-t,1<t?4<t?t&268435455?16:536870912:4:1}var dg,jd,hg,fg,pg,Kc=!1,po=[],qi=null,Ki=null,Zi=null,Fs=new Map,zs=new Map,Gi=[],y0="mousedown mouseup touchcancel touchend touchstart auxclick dblclick pointercancel pointerdown pointerup dragend dragstart drop compositionend compositionstart keydown keypress keyup input textInput copy cut paste click change contextmenu reset submit".split(" ");function Xh(t,e){switch(t){case"focusin":case"focusout":qi=null;break;case"dragenter":case"dragleave":Ki=null;break;case"mouseover":case"mouseout":Zi=null;break;case"pointerover":case"pointerout":Fs.delete(e.pointerId);break;case"gotpointercapture":case"lostpointercapture":zs.delete(e.pointerId)}}function is(t,e,r,i,n,a){return t===null||t.nativeEvent!==a?(t={blockedOn:e,domEventName:r,eventSystemFlags:i,nativeEvent:a,targetContainers:[n]},e!==null&&(e=ro(e),e!==null&&jd(e)),t):(t.eventSystemFlags|=i,e=t.targetContainers,n!==null&&e.indexOf(n)===-1&&e.push(n),t)}function M0(t,e,r,i,n){switch(e){case"focusin":return qi=is(qi,t,e,r,i,n),!0;case"dragenter":return Ki=is(Ki,t,e,r,i,n),!0;case"mouseover":return Zi=is(Zi,t,e,r,i,n),!0;case"pointerover":var a=n.pointerId;return Fs.set(a,is(Fs.get(a)||null,t,e,r,i,n)),!0;case"gotpointercapture":return a=n.pointerId,zs.set(a,is(zs.get(a)||null,t,e,r,i,n)),!0}return!1}function mg(t){var e=An(t.target);if(e!==null){var r=Hn(e);if(r!==null){if(e=r.tag,e===13){if(e=ig(r),e!==null){t.blockedOn=e,pg(t.priority,function(){hg(r)});return}}else if(e===3&&r.stateNode.current.memoizedState.isDehydrated){t.blockedOn=r.tag===3?r.stateNode.containerInfo:null;return}}}t.blockedOn=null}function il(t){if(t.blockedOn!==null)return!1;for(var e=t.targetContainers;0<e.length;){var r=Zc(t.domEventName,t.eventSystemFlags,e[0],t.nativeEvent);if(r===null){r=t.nativeEvent;var i=new r.constructor(r.type,r);Wc=i,r.target.dispatchEvent(i),Wc=null}else return e=ro(r),e!==null&&jd(e),t.blockedOn=r,!1;e.shift()}return!0}function Yh(t,e,r){il(t)&&r.delete(e)}function S0(){Kc=!1,qi!==null&&il(qi)&&(qi=null),Ki!==null&&il(Ki)&&(Ki=null),Zi!==null&&il(Zi)&&(Zi=null),Fs.forEach(Yh),zs.forEach(Yh)}function ns(t,e){t.blockedOn===e&&(t.blockedOn=null,Kc||(Kc=!0,wr.unstable_scheduleCallback(wr.unstable_NormalPriority,S0)))}function Bs(t){function e(n){return ns(n,t)}if(0<po.length){ns(po[0],t);for(var r=1;r<po.length;r++){var i=po[r];i.blockedOn===t&&(i.blockedOn=null)}}for(qi!==null&&ns(qi,t),Ki!==null&&ns(Ki,t),Zi!==null&&ns(Zi,t),Fs.forEach(e),zs.forEach(e),r=0;r<Gi.length;r++)i=Gi[r],i.blockedOn===t&&(i.blockedOn=null);for(;0<Gi.length&&(r=Gi[0],r.blockedOn===null);)mg(r),r.blockedOn===null&&Gi.shift()}var Ca=Ri.ReactCurrentBatchConfig,yl=!0;function b0(t,e,r,i){var n=ct,a=Ca.transition;Ca.transition=null;try{ct=1,Xd(t,e,r,i)}finally{ct=n,Ca.transition=a}}function E0(t,e,r,i){var n=ct,a=Ca.transition;Ca.transition=null;try{ct=4,Xd(t,e,r,i)}finally{ct=n,Ca.transition=a}}function Xd(t,e,r,i){if(yl){var n=Zc(t,e,r,i);if(n===null)Ou(t,e,i,Ml,r),Xh(t,i);else if(M0(n,t,e,r,i))i.stopPropagation();else if(Xh(t,i),e&4&&-1<y0.indexOf(t)){for(;n!==null;){var a=ro(n);if(a!==null&&dg(a),a=Zc(t,e,r,i),a===null&&Ou(t,e,i,Ml,r),a===n)break;n=a}n!==null&&i.stopPropagation()}else Ou(t,e,i,null,r)}}var Ml=null;function Zc(t,e,r,i){if(Ml=null,t=Hd(i),t=An(t),t!==null)if(e=Hn(t),e===null)t=null;else if(r=e.tag,r===13){if(t=ig(e),t!==null)return t;t=null}else if(r===3){if(e.stateNode.current.memoizedState.isDehydrated)return e.tag===3?e.stateNode.containerInfo:null;t=null}else e!==t&&(t=null);return Ml=t,null}function gg(t){switch(t){case"cancel":case"click":case"close":case"contextmenu":case"copy":case"cut":case"auxclick":case"dblclick":case"dragend":case"dragstart":case"drop":case"focusin":case"focusout":case"input":case"invalid":case"keydown":case"keypress":case"keyup":case"mousedown":case"mouseup":case"paste":case"pause":case"play":case"pointercancel":case"pointerdown":case"pointerup":case"ratechange":case"reset":case"resize":case"seeked":case"submit":case"touchcancel":case"touchend":case"touchstart":case"volumechange":case"change":case"selectionchange":case"textInput":case"compositionstart":case"compositionend":case"compositionupdate":case"beforeblur":case"afterblur":case"beforeinput":case"blur":case"fullscreenchange":case"focus":case"hashchange":case"popstate":case"select":case"selectstart":return 1;case"drag":case"dragenter":case"dragexit":case"dragleave":case"dragover":case"mousemove":case"mouseout":case"mouseover":case"pointermove":case"pointerout":case"pointerover":case"scroll":case"toggle":case"touchmove":case"wheel":case"mouseenter":case"mouseleave":case"pointerenter":case"pointerleave":return 4;case"message":switch(d0()){case Gd:return 1;case og:return 4;case _l:case h0:return 16;case lg:return 536870912;default:return 16}default:return 16}}var Xi=null,Yd=null,nl=null;function vg(){if(nl)return nl;var t,e=Yd,r=e.length,i,n="value"in Xi?Xi.value:Xi.textContent,a=n.length;for(t=0;t<r&&e[t]===n[t];t++);var s=r-t;for(i=1;i<=s&&e[r-i]===n[a-i];i++);return nl=n.slice(t,1<i?1-i:void 0)}function al(t){var e=t.keyCode;return"charCode"in t?(t=t.charCode,t===0&&e===13&&(t=13)):t=e,t===10&&(t=13),32<=t||t===13?t:0}function mo(){return!0}function qh(){return!1}function Ar(t){function e(r,i,n,a,s){this._reactName=r,this._targetInst=n,this.type=i,this.nativeEvent=a,this.target=s,this.currentTarget=null;for(var o in t)t.hasOwnProperty(o)&&(r=t[o],this[o]=r?r(a):a[o]);return this.isDefaultPrevented=(a.defaultPrevented!=null?a.defaultPrevented:a.returnValue===!1)?mo:qh,this.isPropagationStopped=qh,this}return wt(e.prototype,{preventDefault:function(){this.defaultPrevented=!0;var r=this.nativeEvent;r&&(r.preventDefault?r.preventDefault():typeof r.returnValue!="unknown"&&(r.returnValue=!1),this.isDefaultPrevented=mo)},stopPropagation:function(){var r=this.nativeEvent;r&&(r.stopPropagation?r.stopPropagation():typeof r.cancelBubble!="unknown"&&(r.cancelBubble=!0),this.isPropagationStopped=mo)},persist:function(){},isPersistent:mo}),e}var Ka={eventPhase:0,bubbles:0,cancelable:0,timeStamp:function(t){return t.timeStamp||Date.now()},defaultPrevented:0,isTrusted:0},qd=Ar(Ka),to=wt({},Ka,{view:0,detail:0}),w0=Ar(to),Au,Cu,as,Ql=wt({},to,{screenX:0,screenY:0,clientX:0,clientY:0,pageX:0,pageY:0,ctrlKey:0,shiftKey:0,altKey:0,metaKey:0,getModifierState:Kd,button:0,buttons:0,relatedTarget:function(t){return t.relatedTarget===void 0?t.fromElement===t.srcElement?t.toElement:t.fromElement:t.relatedTarget},movementX:function(t){return"movementX"in t?t.movementX:(t!==as&&(as&&t.type==="mousemove"?(Au=t.screenX-as.screenX,Cu=t.screenY-as.screenY):Cu=Au=0,as=t),Au)},movementY:function(t){return"movementY"in t?t.movementY:Cu}}),Kh=Ar(Ql),T0=wt({},Ql,{dataTransfer:0}),A0=Ar(T0),C0=wt({},to,{relatedTarget:0}),Ru=Ar(C0),R0=wt({},Ka,{animationName:0,elapsedTime:0,pseudoElement:0}),P0=Ar(R0),L0=wt({},Ka,{clipboardData:function(t){return"clipboardData"in t?t.clipboardData:window.clipboardData}}),U0=Ar(L0),D0=wt({},Ka,{data:0}),Zh=Ar(D0),I0={Esc:"Escape",Spacebar:" ",Left:"ArrowLeft",Up:"ArrowUp",Right:"ArrowRight",Down:"ArrowDown",Del:"Delete",Win:"OS",Menu:"ContextMenu",Apps:"ContextMenu",Scroll:"ScrollLock",MozPrintableKey:"Unidentified"},N0={8:"Backspace",9:"Tab",12:"Clear",13:"Enter",16:"Shift",17:"Control",18:"Alt",19:"Pause",20:"CapsLock",27:"Escape",32:" ",33:"PageUp",34:"PageDown",35:"End",36:"Home",37:"ArrowLeft",38:"ArrowUp",39:"ArrowRight",40:"ArrowDown",45:"Insert",46:"Delete",112:"F1",113:"F2",114:"F3",115:"F4",116:"F5",117:"F6",118:"F7",119:"F8",120:"F9",121:"F10",122:"F11",123:"F12",144:"NumLock",145:"ScrollLock",224:"Meta"},O0={Alt:"altKey",Control:"ctrlKey",Meta:"metaKey",Shift:"shiftKey"};function k0(t){var e=this.nativeEvent;return e.getModifierState?e.getModifierState(t):(t=O0[t])?!!e[t]:!1}function Kd(){return k0}var F0=wt({},to,{key:function(t){if(t.key){var e=I0[t.key]||t.key;if(e!=="Unidentified")return e}return t.type==="keypress"?(t=al(t),t===13?"Enter":String.fromCharCode(t)):t.type==="keydown"||t.type==="keyup"?N0[t.keyCode]||"Unidentified":""},code:0,location:0,ctrlKey:0,shiftKey:0,altKey:0,metaKey:0,repeat:0,locale:0,getModifierState:Kd,charCode:function(t){return t.type==="keypress"?al(t):0},keyCode:function(t){return t.type==="keydown"||t.type==="keyup"?t.keyCode:0},which:function(t){return t.type==="keypress"?al(t):t.type==="keydown"||t.type==="keyup"?t.keyCode:0}}),z0=Ar(F0),B0=wt({},Ql,{pointerId:0,width:0,height:0,pressure:0,tangentialPressure:0,tiltX:0,tiltY:0,twist:0,pointerType:0,isPrimary:0}),$h=Ar(B0),V0=wt({},to,{touches:0,targetTouches:0,changedTouches:0,altKey:0,metaKey:0,ctrlKey:0,shiftKey:0,getModifierState:Kd}),H0=Ar(V0),G0=wt({},Ka,{propertyName:0,elapsedTime:0,pseudoElement:0}),W0=Ar(G0),j0=wt({},Ql,{deltaX:function(t){return"deltaX"in t?t.deltaX:"wheelDeltaX"in t?-t.wheelDeltaX:0},deltaY:function(t){return"deltaY"in t?t.deltaY:"wheelDeltaY"in t?-t.wheelDeltaY:"wheelDelta"in t?-t.wheelDelta:0},deltaZ:0,deltaMode:0}),X0=Ar(j0),Y0=[9,13,27,32],Zd=wi&&"CompositionEvent"in window,As=null;wi&&"documentMode"in document&&(As=document.documentMode);var q0=wi&&"TextEvent"in window&&!As,_g=wi&&(!Zd||As&&8<As&&11>=As),Qh=" ",Jh=!1;function xg(t,e){switch(t){case"keyup":return Y0.indexOf(e.keyCode)!==-1;case"keydown":return e.keyCode!==229;case"keypress":case"mousedown":case"focusout":return!0;default:return!1}}function yg(t){return t=t.detail,typeof t=="object"&&"data"in t?t.data:null}var pa=!1;function K0(t,e){switch(t){case"compositionend":return yg(e);case"keypress":return e.which!==32?null:(Jh=!0,Qh);case"textInput":return t=e.data,t===Qh&&Jh?null:t;default:return null}}function Z0(t,e){if(pa)return t==="compositionend"||!Zd&&xg(t,e)?(t=vg(),nl=Yd=Xi=null,pa=!1,t):null;switch(t){case"paste":return null;case"keypress":if(!(e.ctrlKey||e.altKey||e.metaKey)||e.ctrlKey&&e.altKey){if(e.char&&1<e.char.length)return e.char;if(e.which)return String.fromCharCode(e.which)}return null;case"compositionend":return _g&&e.locale!=="ko"?null:e.data;default:return null}}var $0={color:!0,date:!0,datetime:!0,"datetime-local":!0,email:!0,month:!0,number:!0,password:!0,range:!0,search:!0,tel:!0,text:!0,time:!0,url:!0,week:!0};function ef(t){var e=t&&t.nodeName&&t.nodeName.toLowerCase();return e==="input"?!!$0[t.type]:e==="textarea"}function Mg(t,e,r,i){Qm(i),e=Sl(e,"onChange"),0<e.length&&(r=new qd("onChange","change",null,r,i),t.push({event:r,listeners:e}))}var Cs=null,Vs=null;function Q0(t){Ug(t,0)}function Jl(t){var e=va(t);if(jm(e))return t}function J0(t,e){if(t==="change")return e}var Sg=!1;if(wi){var Pu;if(wi){var Lu="oninput"in document;if(!Lu){var tf=document.createElement("div");tf.setAttribute("oninput","return;"),Lu=typeof tf.oninput=="function"}Pu=Lu}else Pu=!1;Sg=Pu&&(!document.documentMode||9<document.documentMode)}function rf(){Cs&&(Cs.detachEvent("onpropertychange",bg),Vs=Cs=null)}function bg(t){if(t.propertyName==="value"&&Jl(Vs)){var e=[];Mg(e,Vs,t,Hd(t)),rg(Q0,e)}}function ex(t,e,r){t==="focusin"?(rf(),Cs=e,Vs=r,Cs.attachEvent("onpropertychange",bg)):t==="focusout"&&rf()}function tx(t){if(t==="selectionchange"||t==="keyup"||t==="keydown")return Jl(Vs)}function rx(t,e){if(t==="click")return Jl(e)}function ix(t,e){if(t==="input"||t==="change")return Jl(e)}function nx(t,e){return t===e&&(t!==0||1/t===1/e)||t!==t&&e!==e}var Zr=typeof Object.is=="function"?Object.is:nx;function Hs(t,e){if(Zr(t,e))return!0;if(typeof t!="object"||t===null||typeof e!="object"||e===null)return!1;var r=Object.keys(t),i=Object.keys(e);if(r.length!==i.length)return!1;for(i=0;i<r.length;i++){var n=r[i];if(!Uc.call(e,n)||!Zr(t[n],e[n]))return!1}return!0}function nf(t){for(;t&&t.firstChild;)t=t.firstChild;return t}function af(t,e){var r=nf(t);t=0;for(var i;r;){if(r.nodeType===3){if(i=t+r.textContent.length,t<=e&&i>=e)return{node:r,offset:e-t};t=i}e:{for(;r;){if(r.nextSibling){r=r.nextSibling;break e}r=r.parentNode}r=void 0}r=nf(r)}}function Eg(t,e){return t&&e?t===e?!0:t&&t.nodeType===3?!1:e&&e.nodeType===3?Eg(t,e.parentNode):"contains"in t?t.contains(e):t.compareDocumentPosition?!!(t.compareDocumentPosition(e)&16):!1:!1}function wg(){for(var t=window,e=ml();e instanceof t.HTMLIFrameElement;){try{var r=typeof e.contentWindow.location.href=="string"}catch{r=!1}if(r)t=e.contentWindow;else break;e=ml(t.document)}return e}function $d(t){var e=t&&t.nodeName&&t.nodeName.toLowerCase();return e&&(e==="input"&&(t.type==="text"||t.type==="search"||t.type==="tel"||t.type==="url"||t.type==="password")||e==="textarea"||t.contentEditable==="true")}function ax(t){var e=wg(),r=t.focusedElem,i=t.selectionRange;if(e!==r&&r&&r.ownerDocument&&Eg(r.ownerDocument.documentElement,r)){if(i!==null&&$d(r)){if(e=i.start,t=i.end,t===void 0&&(t=e),"selectionStart"in r)r.selectionStart=e,r.selectionEnd=Math.min(t,r.value.length);else if(t=(e=r.ownerDocument||document)&&e.defaultView||window,t.getSelection){t=t.getSelection();var n=r.textContent.length,a=Math.min(i.start,n);i=i.end===void 0?a:Math.min(i.end,n),!t.extend&&a>i&&(n=i,i=a,a=n),n=af(r,a);var s=af(r,i);n&&s&&(t.rangeCount!==1||t.anchorNode!==n.node||t.anchorOffset!==n.offset||t.focusNode!==s.node||t.focusOffset!==s.offset)&&(e=e.createRange(),e.setStart(n.node,n.offset),t.removeAllRanges(),a>i?(t.addRange(e),t.extend(s.node,s.offset)):(e.setEnd(s.node,s.offset),t.addRange(e)))}}for(e=[],t=r;t=t.parentNode;)t.nodeType===1&&e.push({element:t,left:t.scrollLeft,top:t.scrollTop});for(typeof r.focus=="function"&&r.focus(),r=0;r<e.length;r++)t=e[r],t.element.scrollLeft=t.left,t.element.scrollTop=t.top}}var sx=wi&&"documentMode"in document&&11>=document.documentMode,ma=null,$c=null,Rs=null,Qc=!1;function sf(t,e,r){var i=r.window===r?r.document:r.nodeType===9?r:r.ownerDocument;Qc||ma==null||ma!==ml(i)||(i=ma,"selectionStart"in i&&$d(i)?i={start:i.selectionStart,end:i.selectionEnd}:(i=(i.ownerDocument&&i.ownerDocument.defaultView||window).getSelection(),i={anchorNode:i.anchorNode,anchorOffset:i.anchorOffset,focusNode:i.focusNode,focusOffset:i.focusOffset}),Rs&&Hs(Rs,i)||(Rs=i,i=Sl($c,"onSelect"),0<i.length&&(e=new qd("onSelect","select",null,e,r),t.push({event:e,listeners:i}),e.target=ma)))}function go(t,e){var r={};return r[t.toLowerCase()]=e.toLowerCase(),r["Webkit"+t]="webkit"+e,r["Moz"+t]="moz"+e,r}var ga={animationend:go("Animation","AnimationEnd"),animationiteration:go("Animation","AnimationIteration"),animationstart:go("Animation","AnimationStart"),transitionend:go("Transition","TransitionEnd")},Uu={},Tg={};wi&&(Tg=document.createElement("div").style,"AnimationEvent"in window||(delete ga.animationend.animation,delete ga.animationiteration.animation,delete ga.animationstart.animation),"TransitionEvent"in window||delete ga.transitionend.transition);function eu(t){if(Uu[t])return Uu[t];if(!ga[t])return t;var e=ga[t],r;for(r in e)if(e.hasOwnProperty(r)&&r in Tg)return Uu[t]=e[r];return t}var Ag=eu("animationend"),Cg=eu("animationiteration"),Rg=eu("animationstart"),Pg=eu("transitionend"),Lg=new Map,of="abort auxClick cancel canPlay canPlayThrough click close contextMenu copy cut drag dragEnd dragEnter dragExit dragLeave dragOver dragStart drop durationChange emptied encrypted ended error gotPointerCapture input invalid keyDown keyPress keyUp load loadedData loadedMetadata loadStart lostPointerCapture mouseDown mouseMove mouseOut mouseOver mouseUp paste pause play playing pointerCancel pointerDown pointerMove pointerOut pointerOver pointerUp progress rateChange reset resize seeked seeking stalled submit suspend timeUpdate touchCancel touchEnd touchStart volumeChange scroll toggle touchMove waiting wheel".split(" ");function cn(t,e){Lg.set(t,e),Vn(e,[t])}for(var Du=0;Du<of.length;Du++){var Iu=of[Du],ox=Iu.toLowerCase(),lx=Iu[0].toUpperCase()+Iu.slice(1);cn(ox,"on"+lx)}cn(Ag,"onAnimationEnd");cn(Cg,"onAnimationIteration");cn(Rg,"onAnimationStart");cn("dblclick","onDoubleClick");cn("focusin","onFocus");cn("focusout","onBlur");cn(Pg,"onTransitionEnd");Na("onMouseEnter",["mouseout","mouseover"]);Na("onMouseLeave",["mouseout","mouseover"]);Na("onPointerEnter",["pointerout","pointerover"]);Na("onPointerLeave",["pointerout","pointerover"]);Vn("onChange","change click focusin focusout input keydown keyup selectionchange".split(" "));Vn("onSelect","focusout contextmenu dragend focusin keydown keyup mousedown mouseup selectionchange".split(" "));Vn("onBeforeInput",["compositionend","keypress","textInput","paste"]);Vn("onCompositionEnd","compositionend focusout keydown keypress keyup mousedown".split(" "));Vn("onCompositionStart","compositionstart focusout keydown keypress keyup mousedown".split(" "));Vn("onCompositionUpdate","compositionupdate focusout keydown keypress keyup mousedown".split(" "));var bs="abort canplay canplaythrough durationchange emptied encrypted ended error loadeddata loadedmetadata loadstart pause play playing progress ratechange resize seeked seeking stalled suspend timeupdate volumechange waiting".split(" "),ux=new Set("cancel close invalid load scroll toggle".split(" ").concat(bs));function lf(t,e,r){var i=t.type||"unknown-event";t.currentTarget=r,o0(i,e,void 0,t),t.currentTarget=null}function Ug(t,e){e=(e&4)!==0;for(var r=0;r<t.length;r++){var i=t[r],n=i.event;i=i.listeners;e:{var a=void 0;if(e)for(var s=i.length-1;0<=s;s--){var o=i[s],l=o.instance,u=o.currentTarget;if(o=o.listener,l!==a&&n.isPropagationStopped())break e;lf(n,o,u),a=l}else for(s=0;s<i.length;s++){if(o=i[s],l=o.instance,u=o.currentTarget,o=o.listener,l!==a&&n.isPropagationStopped())break e;lf(n,o,u),a=l}}}if(vl)throw t=Yc,vl=!1,Yc=null,t}function vt(t,e){var r=e[id];r===void 0&&(r=e[id]=new Set);var i=t+"__bubble";r.has(i)||(Dg(e,t,2,!1),r.add(i))}function Nu(t,e,r){var i=0;e&&(i|=4),Dg(r,t,i,e)}var vo="_reactListening"+Math.random().toString(36).slice(2);function Gs(t){if(!t[vo]){t[vo]=!0,Bm.forEach(function(r){r!=="selectionchange"&&(ux.has(r)||Nu(r,!1,t),Nu(r,!0,t))});var e=t.nodeType===9?t:t.ownerDocument;e===null||e[vo]||(e[vo]=!0,Nu("selectionchange",!1,e))}}function Dg(t,e,r,i){switch(gg(e)){case 1:var n=b0;break;case 4:n=E0;break;default:n=Xd}r=n.bind(null,e,r,t),n=void 0,!Xc||e!=="touchstart"&&e!=="touchmove"&&e!=="wheel"||(n=!0),i?n!==void 0?t.addEventListener(e,r,{capture:!0,passive:n}):t.addEventListener(e,r,!0):n!==void 0?t.addEventListener(e,r,{passive:n}):t.addEventListener(e,r,!1)}function Ou(t,e,r,i,n){var a=i;if(!(e&1)&&!(e&2)&&i!==null)e:for(;;){if(i===null)return;var s=i.tag;if(s===3||s===4){var o=i.stateNode.containerInfo;if(o===n||o.nodeType===8&&o.parentNode===n)break;if(s===4)for(s=i.return;s!==null;){var l=s.tag;if((l===3||l===4)&&(l=s.stateNode.containerInfo,l===n||l.nodeType===8&&l.parentNode===n))return;s=s.return}for(;o!==null;){if(s=An(o),s===null)return;if(l=s.tag,l===5||l===6){i=a=s;continue e}o=o.parentNode}}i=i.return}rg(function(){var u=a,h=Hd(r),f=[];e:{var d=Lg.get(t);if(d!==void 0){var p=qd,_=t;switch(t){case"keypress":if(al(r)===0)break e;case"keydown":case"keyup":p=z0;break;case"focusin":_="focus",p=Ru;break;case"focusout":_="blur",p=Ru;break;case"beforeblur":case"afterblur":p=Ru;break;case"click":if(r.button===2)break e;case"auxclick":case"dblclick":case"mousedown":case"mousemove":case"mouseup":case"mouseout":case"mouseover":case"contextmenu":p=Kh;break;case"drag":case"dragend":case"dragenter":case"dragexit":case"dragleave":case"dragover":case"dragstart":case"drop":p=A0;break;case"touchcancel":case"touchend":case"touchmove":case"touchstart":p=H0;break;case Ag:case Cg:case Rg:p=P0;break;case Pg:p=W0;break;case"scroll":p=w0;break;case"wheel":p=X0;break;case"copy":case"cut":case"paste":p=U0;break;case"gotpointercapture":case"lostpointercapture":case"pointercancel":case"pointerdown":case"pointermove":case"pointerout":case"pointerover":case"pointerup":p=$h}var x=(e&4)!==0,m=!x&&t==="scroll",c=x?d!==null?d+"Capture":null:d;x=[];for(var g=u,v;g!==null;){v=g;var M=v.stateNode;if(v.tag===5&&M!==null&&(v=M,c!==null&&(M=ks(g,c),M!=null&&x.push(Ws(g,M,v)))),m)break;g=g.return}0<x.length&&(d=new p(d,_,null,r,h),f.push({event:d,listeners:x}))}}if(!(e&7)){e:{if(d=t==="mouseover"||t==="pointerover",p=t==="mouseout"||t==="pointerout",d&&r!==Wc&&(_=r.relatedTarget||r.fromElement)&&(An(_)||_[Ti]))break e;if((p||d)&&(d=h.window===h?h:(d=h.ownerDocument)?d.defaultView||d.parentWindow:window,p?(_=r.relatedTarget||r.toElement,p=u,_=_?An(_):null,_!==null&&(m=Hn(_),_!==m||_.tag!==5&&_.tag!==6)&&(_=null)):(p=null,_=u),p!==_)){if(x=Kh,M="onMouseLeave",c="onMouseEnter",g="mouse",(t==="pointerout"||t==="pointerover")&&(x=$h,M="onPointerLeave",c="onPointerEnter",g="pointer"),m=p==null?d:va(p),v=_==null?d:va(_),d=new x(M,g+"leave",p,r,h),d.target=m,d.relatedTarget=v,M=null,An(h)===u&&(x=new x(c,g+"enter",_,r,h),x.target=v,x.relatedTarget=m,M=x),m=M,p&&_)t:{for(x=p,c=_,g=0,v=x;v;v=jn(v))g++;for(v=0,M=c;M;M=jn(M))v++;for(;0<g-v;)x=jn(x),g--;for(;0<v-g;)c=jn(c),v--;for(;g--;){if(x===c||c!==null&&x===c.alternate)break t;x=jn(x),c=jn(c)}x=null}else x=null;p!==null&&uf(f,d,p,x,!1),_!==null&&m!==null&&uf(f,m,_,x,!0)}}e:{if(d=u?va(u):window,p=d.nodeName&&d.nodeName.toLowerCase(),p==="select"||p==="input"&&d.type==="file")var P=J0;else if(ef(d))if(Sg)P=ix;else{P=tx;var T=ex}else(p=d.nodeName)&&p.toLowerCase()==="input"&&(d.type==="checkbox"||d.type==="radio")&&(P=rx);if(P&&(P=P(t,u))){Mg(f,P,r,h);break e}T&&T(t,d,u),t==="focusout"&&(T=d._wrapperState)&&T.controlled&&d.type==="number"&&zc(d,"number",d.value)}switch(T=u?va(u):window,t){case"focusin":(ef(T)||T.contentEditable==="true")&&(ma=T,$c=u,Rs=null);break;case"focusout":Rs=$c=ma=null;break;case"mousedown":Qc=!0;break;case"contextmenu":case"mouseup":case"dragend":Qc=!1,sf(f,r,h);break;case"selectionchange":if(sx)break;case"keydown":case"keyup":sf(f,r,h)}var w;if(Zd)e:{switch(t){case"compositionstart":var L="onCompositionStart";break e;case"compositionend":L="onCompositionEnd";break e;case"compositionupdate":L="onCompositionUpdate";break e}L=void 0}else pa?xg(t,r)&&(L="onCompositionEnd"):t==="keydown"&&r.keyCode===229&&(L="onCompositionStart");L&&(_g&&r.locale!=="ko"&&(pa||L!=="onCompositionStart"?L==="onCompositionEnd"&&pa&&(w=vg()):(Xi=h,Yd="value"in Xi?Xi.value:Xi.textContent,pa=!0)),T=Sl(u,L),0<T.length&&(L=new Zh(L,t,null,r,h),f.push({event:L,listeners:T}),w?L.data=w:(w=yg(r),w!==null&&(L.data=w)))),(w=q0?K0(t,r):Z0(t,r))&&(u=Sl(u,"onBeforeInput"),0<u.length&&(h=new Zh("onBeforeInput","beforeinput",null,r,h),f.push({event:h,listeners:u}),h.data=w))}Ug(f,e)})}function Ws(t,e,r){return{instance:t,listener:e,currentTarget:r}}function Sl(t,e){for(var r=e+"Capture",i=[];t!==null;){var n=t,a=n.stateNode;n.tag===5&&a!==null&&(n=a,a=ks(t,r),a!=null&&i.unshift(Ws(t,a,n)),a=ks(t,e),a!=null&&i.push(Ws(t,a,n))),t=t.return}return i}function jn(t){if(t===null)return null;do t=t.return;while(t&&t.tag!==5);return t||null}function uf(t,e,r,i,n){for(var a=e._reactName,s=[];r!==null&&r!==i;){var o=r,l=o.alternate,u=o.stateNode;if(l!==null&&l===i)break;o.tag===5&&u!==null&&(o=u,n?(l=ks(r,a),l!=null&&s.unshift(Ws(r,l,o))):n||(l=ks(r,a),l!=null&&s.push(Ws(r,l,o)))),r=r.return}s.length!==0&&t.push({event:e,listeners:s})}var cx=/\r\n?/g,dx=/\u0000|\uFFFD/g;function cf(t){return(typeof t=="string"?t:""+t).replace(cx,`
`).replace(dx,"")}function _o(t,e,r){if(e=cf(e),cf(t)!==e&&r)throw Error(ce(425))}function bl(){}var Jc=null,ed=null;function td(t,e){return t==="textarea"||t==="noscript"||typeof e.children=="string"||typeof e.children=="number"||typeof e.dangerouslySetInnerHTML=="object"&&e.dangerouslySetInnerHTML!==null&&e.dangerouslySetInnerHTML.__html!=null}var rd=typeof setTimeout=="function"?setTimeout:void 0,hx=typeof clearTimeout=="function"?clearTimeout:void 0,df=typeof Promise=="function"?Promise:void 0,fx=typeof queueMicrotask=="function"?queueMicrotask:typeof df<"u"?function(t){return df.resolve(null).then(t).catch(px)}:rd;function px(t){setTimeout(function(){throw t})}function ku(t,e){var r=e,i=0;do{var n=r.nextSibling;if(t.removeChild(r),n&&n.nodeType===8)if(r=n.data,r==="/$"){if(i===0){t.removeChild(n),Bs(e);return}i--}else r!=="$"&&r!=="$?"&&r!=="$!"||i++;r=n}while(r);Bs(e)}function $i(t){for(;t!=null;t=t.nextSibling){var e=t.nodeType;if(e===1||e===3)break;if(e===8){if(e=t.data,e==="$"||e==="$!"||e==="$?")break;if(e==="/$")return null}}return t}function hf(t){t=t.previousSibling;for(var e=0;t;){if(t.nodeType===8){var r=t.data;if(r==="$"||r==="$!"||r==="$?"){if(e===0)return t;e--}else r==="/$"&&e++}t=t.previousSibling}return null}var Za=Math.random().toString(36).slice(2),ri="__reactFiber$"+Za,js="__reactProps$"+Za,Ti="__reactContainer$"+Za,id="__reactEvents$"+Za,mx="__reactListeners$"+Za,gx="__reactHandles$"+Za;function An(t){var e=t[ri];if(e)return e;for(var r=t.parentNode;r;){if(e=r[Ti]||r[ri]){if(r=e.alternate,e.child!==null||r!==null&&r.child!==null)for(t=hf(t);t!==null;){if(r=t[ri])return r;t=hf(t)}return e}t=r,r=t.parentNode}return null}function ro(t){return t=t[ri]||t[Ti],!t||t.tag!==5&&t.tag!==6&&t.tag!==13&&t.tag!==3?null:t}function va(t){if(t.tag===5||t.tag===6)return t.stateNode;throw Error(ce(33))}function tu(t){return t[js]||null}var nd=[],_a=-1;function dn(t){return{current:t}}function xt(t){0>_a||(t.current=nd[_a],nd[_a]=null,_a--)}function gt(t,e){_a++,nd[_a]=t.current,t.current=e}var sn={},er=dn(sn),pr=dn(!1),In=sn;function Oa(t,e){var r=t.type.contextTypes;if(!r)return sn;var i=t.stateNode;if(i&&i.__reactInternalMemoizedUnmaskedChildContext===e)return i.__reactInternalMemoizedMaskedChildContext;var n={},a;for(a in r)n[a]=e[a];return i&&(t=t.stateNode,t.__reactInternalMemoizedUnmaskedChildContext=e,t.__reactInternalMemoizedMaskedChildContext=n),n}function mr(t){return t=t.childContextTypes,t!=null}function El(){xt(pr),xt(er)}function ff(t,e,r){if(er.current!==sn)throw Error(ce(168));gt(er,e),gt(pr,r)}function Ig(t,e,r){var i=t.stateNode;if(e=e.childContextTypes,typeof i.getChildContext!="function")return r;i=i.getChildContext();for(var n in i)if(!(n in e))throw Error(ce(108,e0(t)||"Unknown",n));return wt({},r,i)}function wl(t){return t=(t=t.stateNode)&&t.__reactInternalMemoizedMergedChildContext||sn,In=er.current,gt(er,t),gt(pr,pr.current),!0}function pf(t,e,r){var i=t.stateNode;if(!i)throw Error(ce(169));r?(t=Ig(t,e,In),i.__reactInternalMemoizedMergedChildContext=t,xt(pr),xt(er),gt(er,t)):xt(pr),gt(pr,r)}var gi=null,ru=!1,Fu=!1;function Ng(t){gi===null?gi=[t]:gi.push(t)}function vx(t){ru=!0,Ng(t)}function hn(){if(!Fu&&gi!==null){Fu=!0;var t=0,e=ct;try{var r=gi;for(ct=1;t<r.length;t++){var i=r[t];do i=i(!0);while(i!==null)}gi=null,ru=!1}catch(n){throw gi!==null&&(gi=gi.slice(t+1)),sg(Gd,hn),n}finally{ct=e,Fu=!1}}return null}var xa=[],ya=0,Tl=null,Al=0,Pr=[],Lr=0,Nn=null,xi=1,yi="";function Sn(t,e){xa[ya++]=Al,xa[ya++]=Tl,Tl=t,Al=e}function Og(t,e,r){Pr[Lr++]=xi,Pr[Lr++]=yi,Pr[Lr++]=Nn,Nn=t;var i=xi;t=yi;var n=32-Yr(i)-1;i&=~(1<<n),r+=1;var a=32-Yr(e)+n;if(30<a){var s=n-n%5;a=(i&(1<<s)-1).toString(32),i>>=s,n-=s,xi=1<<32-Yr(e)+n|r<<n|i,yi=a+t}else xi=1<<a|r<<n|i,yi=t}function Qd(t){t.return!==null&&(Sn(t,1),Og(t,1,0))}function Jd(t){for(;t===Tl;)Tl=xa[--ya],xa[ya]=null,Al=xa[--ya],xa[ya]=null;for(;t===Nn;)Nn=Pr[--Lr],Pr[Lr]=null,yi=Pr[--Lr],Pr[Lr]=null,xi=Pr[--Lr],Pr[Lr]=null}var Er=null,br=null,yt=!1,Wr=null;function kg(t,e){var r=Ur(5,null,null,0);r.elementType="DELETED",r.stateNode=e,r.return=t,e=t.deletions,e===null?(t.deletions=[r],t.flags|=16):e.push(r)}function mf(t,e){switch(t.tag){case 5:var r=t.type;return e=e.nodeType!==1||r.toLowerCase()!==e.nodeName.toLowerCase()?null:e,e!==null?(t.stateNode=e,Er=t,br=$i(e.firstChild),!0):!1;case 6:return e=t.pendingProps===""||e.nodeType!==3?null:e,e!==null?(t.stateNode=e,Er=t,br=null,!0):!1;case 13:return e=e.nodeType!==8?null:e,e!==null?(r=Nn!==null?{id:xi,overflow:yi}:null,t.memoizedState={dehydrated:e,treeContext:r,retryLane:1073741824},r=Ur(18,null,null,0),r.stateNode=e,r.return=t,t.child=r,Er=t,br=null,!0):!1;default:return!1}}function ad(t){return(t.mode&1)!==0&&(t.flags&128)===0}function sd(t){if(yt){var e=br;if(e){var r=e;if(!mf(t,e)){if(ad(t))throw Error(ce(418));e=$i(r.nextSibling);var i=Er;e&&mf(t,e)?kg(i,r):(t.flags=t.flags&-4097|2,yt=!1,Er=t)}}else{if(ad(t))throw Error(ce(418));t.flags=t.flags&-4097|2,yt=!1,Er=t}}}function gf(t){for(t=t.return;t!==null&&t.tag!==5&&t.tag!==3&&t.tag!==13;)t=t.return;Er=t}function xo(t){if(t!==Er)return!1;if(!yt)return gf(t),yt=!0,!1;var e;if((e=t.tag!==3)&&!(e=t.tag!==5)&&(e=t.type,e=e!=="head"&&e!=="body"&&!td(t.type,t.memoizedProps)),e&&(e=br)){if(ad(t))throw Fg(),Error(ce(418));for(;e;)kg(t,e),e=$i(e.nextSibling)}if(gf(t),t.tag===13){if(t=t.memoizedState,t=t!==null?t.dehydrated:null,!t)throw Error(ce(317));e:{for(t=t.nextSibling,e=0;t;){if(t.nodeType===8){var r=t.data;if(r==="/$"){if(e===0){br=$i(t.nextSibling);break e}e--}else r!=="$"&&r!=="$!"&&r!=="$?"||e++}t=t.nextSibling}br=null}}else br=Er?$i(t.stateNode.nextSibling):null;return!0}function Fg(){for(var t=br;t;)t=$i(t.nextSibling)}function ka(){br=Er=null,yt=!1}function eh(t){Wr===null?Wr=[t]:Wr.push(t)}var _x=Ri.ReactCurrentBatchConfig;function ss(t,e,r){if(t=r.ref,t!==null&&typeof t!="function"&&typeof t!="object"){if(r._owner){if(r=r._owner,r){if(r.tag!==1)throw Error(ce(309));var i=r.stateNode}if(!i)throw Error(ce(147,t));var n=i,a=""+t;return e!==null&&e.ref!==null&&typeof e.ref=="function"&&e.ref._stringRef===a?e.ref:(e=function(s){var o=n.refs;s===null?delete o[a]:o[a]=s},e._stringRef=a,e)}if(typeof t!="string")throw Error(ce(284));if(!r._owner)throw Error(ce(290,t))}return t}function yo(t,e){throw t=Object.prototype.toString.call(e),Error(ce(31,t==="[object Object]"?"object with keys {"+Object.keys(e).join(", ")+"}":t))}function vf(t){var e=t._init;return e(t._payload)}function zg(t){function e(c,g){if(t){var v=c.deletions;v===null?(c.deletions=[g],c.flags|=16):v.push(g)}}function r(c,g){if(!t)return null;for(;g!==null;)e(c,g),g=g.sibling;return null}function i(c,g){for(c=new Map;g!==null;)g.key!==null?c.set(g.key,g):c.set(g.index,g),g=g.sibling;return c}function n(c,g){return c=tn(c,g),c.index=0,c.sibling=null,c}function a(c,g,v){return c.index=v,t?(v=c.alternate,v!==null?(v=v.index,v<g?(c.flags|=2,g):v):(c.flags|=2,g)):(c.flags|=1048576,g)}function s(c){return t&&c.alternate===null&&(c.flags|=2),c}function o(c,g,v,M){return g===null||g.tag!==6?(g=ju(v,c.mode,M),g.return=c,g):(g=n(g,v),g.return=c,g)}function l(c,g,v,M){var P=v.type;return P===fa?h(c,g,v.props.children,M,v.key):g!==null&&(g.elementType===P||typeof P=="object"&&P!==null&&P.$$typeof===Fi&&vf(P)===g.type)?(M=n(g,v.props),M.ref=ss(c,g,v),M.return=c,M):(M=hl(v.type,v.key,v.props,null,c.mode,M),M.ref=ss(c,g,v),M.return=c,M)}function u(c,g,v,M){return g===null||g.tag!==4||g.stateNode.containerInfo!==v.containerInfo||g.stateNode.implementation!==v.implementation?(g=Xu(v,c.mode,M),g.return=c,g):(g=n(g,v.children||[]),g.return=c,g)}function h(c,g,v,M,P){return g===null||g.tag!==7?(g=Dn(v,c.mode,M,P),g.return=c,g):(g=n(g,v),g.return=c,g)}function f(c,g,v){if(typeof g=="string"&&g!==""||typeof g=="number")return g=ju(""+g,c.mode,v),g.return=c,g;if(typeof g=="object"&&g!==null){switch(g.$$typeof){case lo:return v=hl(g.type,g.key,g.props,null,c.mode,v),v.ref=ss(c,null,g),v.return=c,v;case ha:return g=Xu(g,c.mode,v),g.return=c,g;case Fi:var M=g._init;return f(c,M(g._payload),v)}if(Ms(g)||ts(g))return g=Dn(g,c.mode,v,null),g.return=c,g;yo(c,g)}return null}function d(c,g,v,M){var P=g!==null?g.key:null;if(typeof v=="string"&&v!==""||typeof v=="number")return P!==null?null:o(c,g,""+v,M);if(typeof v=="object"&&v!==null){switch(v.$$typeof){case lo:return v.key===P?l(c,g,v,M):null;case ha:return v.key===P?u(c,g,v,M):null;case Fi:return P=v._init,d(c,g,P(v._payload),M)}if(Ms(v)||ts(v))return P!==null?null:h(c,g,v,M,null);yo(c,v)}return null}function p(c,g,v,M,P){if(typeof M=="string"&&M!==""||typeof M=="number")return c=c.get(v)||null,o(g,c,""+M,P);if(typeof M=="object"&&M!==null){switch(M.$$typeof){case lo:return c=c.get(M.key===null?v:M.key)||null,l(g,c,M,P);case ha:return c=c.get(M.key===null?v:M.key)||null,u(g,c,M,P);case Fi:var T=M._init;return p(c,g,v,T(M._payload),P)}if(Ms(M)||ts(M))return c=c.get(v)||null,h(g,c,M,P,null);yo(g,M)}return null}function _(c,g,v,M){for(var P=null,T=null,w=g,L=g=0,b=null;w!==null&&L<v.length;L++){w.index>L?(b=w,w=null):b=w.sibling;var y=d(c,w,v[L],M);if(y===null){w===null&&(w=b);break}t&&w&&y.alternate===null&&e(c,w),g=a(y,g,L),T===null?P=y:T.sibling=y,T=y,w=b}if(L===v.length)return r(c,w),yt&&Sn(c,L),P;if(w===null){for(;L<v.length;L++)w=f(c,v[L],M),w!==null&&(g=a(w,g,L),T===null?P=w:T.sibling=w,T=w);return yt&&Sn(c,L),P}for(w=i(c,w);L<v.length;L++)b=p(w,c,L,v[L],M),b!==null&&(t&&b.alternate!==null&&w.delete(b.key===null?L:b.key),g=a(b,g,L),T===null?P=b:T.sibling=b,T=b);return t&&w.forEach(function(U){return e(c,U)}),yt&&Sn(c,L),P}function x(c,g,v,M){var P=ts(v);if(typeof P!="function")throw Error(ce(150));if(v=P.call(v),v==null)throw Error(ce(151));for(var T=P=null,w=g,L=g=0,b=null,y=v.next();w!==null&&!y.done;L++,y=v.next()){w.index>L?(b=w,w=null):b=w.sibling;var U=d(c,w,y.value,M);if(U===null){w===null&&(w=b);break}t&&w&&U.alternate===null&&e(c,w),g=a(U,g,L),T===null?P=U:T.sibling=U,T=U,w=b}if(y.done)return r(c,w),yt&&Sn(c,L),P;if(w===null){for(;!y.done;L++,y=v.next())y=f(c,y.value,M),y!==null&&(g=a(y,g,L),T===null?P=y:T.sibling=y,T=y);return yt&&Sn(c,L),P}for(w=i(c,w);!y.done;L++,y=v.next())y=p(w,c,L,y.value,M),y!==null&&(t&&y.alternate!==null&&w.delete(y.key===null?L:y.key),g=a(y,g,L),T===null?P=y:T.sibling=y,T=y);return t&&w.forEach(function(B){return e(c,B)}),yt&&Sn(c,L),P}function m(c,g,v,M){if(typeof v=="object"&&v!==null&&v.type===fa&&v.key===null&&(v=v.props.children),typeof v=="object"&&v!==null){switch(v.$$typeof){case lo:e:{for(var P=v.key,T=g;T!==null;){if(T.key===P){if(P=v.type,P===fa){if(T.tag===7){r(c,T.sibling),g=n(T,v.props.children),g.return=c,c=g;break e}}else if(T.elementType===P||typeof P=="object"&&P!==null&&P.$$typeof===Fi&&vf(P)===T.type){r(c,T.sibling),g=n(T,v.props),g.ref=ss(c,T,v),g.return=c,c=g;break e}r(c,T);break}else e(c,T);T=T.sibling}v.type===fa?(g=Dn(v.props.children,c.mode,M,v.key),g.return=c,c=g):(M=hl(v.type,v.key,v.props,null,c.mode,M),M.ref=ss(c,g,v),M.return=c,c=M)}return s(c);case ha:e:{for(T=v.key;g!==null;){if(g.key===T)if(g.tag===4&&g.stateNode.containerInfo===v.containerInfo&&g.stateNode.implementation===v.implementation){r(c,g.sibling),g=n(g,v.children||[]),g.return=c,c=g;break e}else{r(c,g);break}else e(c,g);g=g.sibling}g=Xu(v,c.mode,M),g.return=c,c=g}return s(c);case Fi:return T=v._init,m(c,g,T(v._payload),M)}if(Ms(v))return _(c,g,v,M);if(ts(v))return x(c,g,v,M);yo(c,v)}return typeof v=="string"&&v!==""||typeof v=="number"?(v=""+v,g!==null&&g.tag===6?(r(c,g.sibling),g=n(g,v),g.return=c,c=g):(r(c,g),g=ju(v,c.mode,M),g.return=c,c=g),s(c)):r(c,g)}return m}var Fa=zg(!0),Bg=zg(!1),Cl=dn(null),Rl=null,Ma=null,th=null;function rh(){th=Ma=Rl=null}function ih(t){var e=Cl.current;xt(Cl),t._currentValue=e}function od(t,e,r){for(;t!==null;){var i=t.alternate;if((t.childLanes&e)!==e?(t.childLanes|=e,i!==null&&(i.childLanes|=e)):i!==null&&(i.childLanes&e)!==e&&(i.childLanes|=e),t===r)break;t=t.return}}function Ra(t,e){Rl=t,th=Ma=null,t=t.dependencies,t!==null&&t.firstContext!==null&&(t.lanes&e&&(hr=!0),t.firstContext=null)}function Ir(t){var e=t._currentValue;if(th!==t)if(t={context:t,memoizedValue:e,next:null},Ma===null){if(Rl===null)throw Error(ce(308));Ma=t,Rl.dependencies={lanes:0,firstContext:t}}else Ma=Ma.next=t;return e}var Cn=null;function nh(t){Cn===null?Cn=[t]:Cn.push(t)}function Vg(t,e,r,i){var n=e.interleaved;return n===null?(r.next=r,nh(e)):(r.next=n.next,n.next=r),e.interleaved=r,Ai(t,i)}function Ai(t,e){t.lanes|=e;var r=t.alternate;for(r!==null&&(r.lanes|=e),r=t,t=t.return;t!==null;)t.childLanes|=e,r=t.alternate,r!==null&&(r.childLanes|=e),r=t,t=t.return;return r.tag===3?r.stateNode:null}var zi=!1;function ah(t){t.updateQueue={baseState:t.memoizedState,firstBaseUpdate:null,lastBaseUpdate:null,shared:{pending:null,interleaved:null,lanes:0},effects:null}}function Hg(t,e){t=t.updateQueue,e.updateQueue===t&&(e.updateQueue={baseState:t.baseState,firstBaseUpdate:t.firstBaseUpdate,lastBaseUpdate:t.lastBaseUpdate,shared:t.shared,effects:t.effects})}function Ei(t,e){return{eventTime:t,lane:e,tag:0,payload:null,callback:null,next:null}}function Qi(t,e,r){var i=t.updateQueue;if(i===null)return null;if(i=i.shared,it&2){var n=i.pending;return n===null?e.next=e:(e.next=n.next,n.next=e),i.pending=e,Ai(t,r)}return n=i.interleaved,n===null?(e.next=e,nh(i)):(e.next=n.next,n.next=e),i.interleaved=e,Ai(t,r)}function sl(t,e,r){if(e=e.updateQueue,e!==null&&(e=e.shared,(r&4194240)!==0)){var i=e.lanes;i&=t.pendingLanes,r|=i,e.lanes=r,Wd(t,r)}}function _f(t,e){var r=t.updateQueue,i=t.alternate;if(i!==null&&(i=i.updateQueue,r===i)){var n=null,a=null;if(r=r.firstBaseUpdate,r!==null){do{var s={eventTime:r.eventTime,lane:r.lane,tag:r.tag,payload:r.payload,callback:r.callback,next:null};a===null?n=a=s:a=a.next=s,r=r.next}while(r!==null);a===null?n=a=e:a=a.next=e}else n=a=e;r={baseState:i.baseState,firstBaseUpdate:n,lastBaseUpdate:a,shared:i.shared,effects:i.effects},t.updateQueue=r;return}t=r.lastBaseUpdate,t===null?r.firstBaseUpdate=e:t.next=e,r.lastBaseUpdate=e}function Pl(t,e,r,i){var n=t.updateQueue;zi=!1;var a=n.firstBaseUpdate,s=n.lastBaseUpdate,o=n.shared.pending;if(o!==null){n.shared.pending=null;var l=o,u=l.next;l.next=null,s===null?a=u:s.next=u,s=l;var h=t.alternate;h!==null&&(h=h.updateQueue,o=h.lastBaseUpdate,o!==s&&(o===null?h.firstBaseUpdate=u:o.next=u,h.lastBaseUpdate=l))}if(a!==null){var f=n.baseState;s=0,h=u=l=null,o=a;do{var d=o.lane,p=o.eventTime;if((i&d)===d){h!==null&&(h=h.next={eventTime:p,lane:0,tag:o.tag,payload:o.payload,callback:o.callback,next:null});e:{var _=t,x=o;switch(d=e,p=r,x.tag){case 1:if(_=x.payload,typeof _=="function"){f=_.call(p,f,d);break e}f=_;break e;case 3:_.flags=_.flags&-65537|128;case 0:if(_=x.payload,d=typeof _=="function"?_.call(p,f,d):_,d==null)break e;f=wt({},f,d);break e;case 2:zi=!0}}o.callback!==null&&o.lane!==0&&(t.flags|=64,d=n.effects,d===null?n.effects=[o]:d.push(o))}else p={eventTime:p,lane:d,tag:o.tag,payload:o.payload,callback:o.callback,next:null},h===null?(u=h=p,l=f):h=h.next=p,s|=d;if(o=o.next,o===null){if(o=n.shared.pending,o===null)break;d=o,o=d.next,d.next=null,n.lastBaseUpdate=d,n.shared.pending=null}}while(!0);if(h===null&&(l=f),n.baseState=l,n.firstBaseUpdate=u,n.lastBaseUpdate=h,e=n.shared.interleaved,e!==null){n=e;do s|=n.lane,n=n.next;while(n!==e)}else a===null&&(n.shared.lanes=0);kn|=s,t.lanes=s,t.memoizedState=f}}function xf(t,e,r){if(t=e.effects,e.effects=null,t!==null)for(e=0;e<t.length;e++){var i=t[e],n=i.callback;if(n!==null){if(i.callback=null,i=r,typeof n!="function")throw Error(ce(191,n));n.call(i)}}}var io={},si=dn(io),Xs=dn(io),Ys=dn(io);function Rn(t){if(t===io)throw Error(ce(174));return t}function sh(t,e){switch(gt(Ys,e),gt(Xs,t),gt(si,io),t=e.nodeType,t){case 9:case 11:e=(e=e.documentElement)?e.namespaceURI:Vc(null,"");break;default:t=t===8?e.parentNode:e,e=t.namespaceURI||null,t=t.tagName,e=Vc(e,t)}xt(si),gt(si,e)}function za(){xt(si),xt(Xs),xt(Ys)}function Gg(t){Rn(Ys.current);var e=Rn(si.current),r=Vc(e,t.type);e!==r&&(gt(Xs,t),gt(si,r))}function oh(t){Xs.current===t&&(xt(si),xt(Xs))}var bt=dn(0);function Ll(t){for(var e=t;e!==null;){if(e.tag===13){var r=e.memoizedState;if(r!==null&&(r=r.dehydrated,r===null||r.data==="$?"||r.data==="$!"))return e}else if(e.tag===19&&e.memoizedProps.revealOrder!==void 0){if(e.flags&128)return e}else if(e.child!==null){e.child.return=e,e=e.child;continue}if(e===t)break;for(;e.sibling===null;){if(e.return===null||e.return===t)return null;e=e.return}e.sibling.return=e.return,e=e.sibling}return null}var zu=[];function lh(){for(var t=0;t<zu.length;t++)zu[t]._workInProgressVersionPrimary=null;zu.length=0}var ol=Ri.ReactCurrentDispatcher,Bu=Ri.ReactCurrentBatchConfig,On=0,Et=null,Nt=null,Vt=null,Ul=!1,Ps=!1,qs=0,xx=0;function Kt(){throw Error(ce(321))}function uh(t,e){if(e===null)return!1;for(var r=0;r<e.length&&r<t.length;r++)if(!Zr(t[r],e[r]))return!1;return!0}function ch(t,e,r,i,n,a){if(On=a,Et=e,e.memoizedState=null,e.updateQueue=null,e.lanes=0,ol.current=t===null||t.memoizedState===null?bx:Ex,t=r(i,n),Ps){a=0;do{if(Ps=!1,qs=0,25<=a)throw Error(ce(301));a+=1,Vt=Nt=null,e.updateQueue=null,ol.current=wx,t=r(i,n)}while(Ps)}if(ol.current=Dl,e=Nt!==null&&Nt.next!==null,On=0,Vt=Nt=Et=null,Ul=!1,e)throw Error(ce(300));return t}function dh(){var t=qs!==0;return qs=0,t}function Qr(){var t={memoizedState:null,baseState:null,baseQueue:null,queue:null,next:null};return Vt===null?Et.memoizedState=Vt=t:Vt=Vt.next=t,Vt}function Nr(){if(Nt===null){var t=Et.alternate;t=t!==null?t.memoizedState:null}else t=Nt.next;var e=Vt===null?Et.memoizedState:Vt.next;if(e!==null)Vt=e,Nt=t;else{if(t===null)throw Error(ce(310));Nt=t,t={memoizedState:Nt.memoizedState,baseState:Nt.baseState,baseQueue:Nt.baseQueue,queue:Nt.queue,next:null},Vt===null?Et.memoizedState=Vt=t:Vt=Vt.next=t}return Vt}function Ks(t,e){return typeof e=="function"?e(t):e}function Vu(t){var e=Nr(),r=e.queue;if(r===null)throw Error(ce(311));r.lastRenderedReducer=t;var i=Nt,n=i.baseQueue,a=r.pending;if(a!==null){if(n!==null){var s=n.next;n.next=a.next,a.next=s}i.baseQueue=n=a,r.pending=null}if(n!==null){a=n.next,i=i.baseState;var o=s=null,l=null,u=a;do{var h=u.lane;if((On&h)===h)l!==null&&(l=l.next={lane:0,action:u.action,hasEagerState:u.hasEagerState,eagerState:u.eagerState,next:null}),i=u.hasEagerState?u.eagerState:t(i,u.action);else{var f={lane:h,action:u.action,hasEagerState:u.hasEagerState,eagerState:u.eagerState,next:null};l===null?(o=l=f,s=i):l=l.next=f,Et.lanes|=h,kn|=h}u=u.next}while(u!==null&&u!==a);l===null?s=i:l.next=o,Zr(i,e.memoizedState)||(hr=!0),e.memoizedState=i,e.baseState=s,e.baseQueue=l,r.lastRenderedState=i}if(t=r.interleaved,t!==null){n=t;do a=n.lane,Et.lanes|=a,kn|=a,n=n.next;while(n!==t)}else n===null&&(r.lanes=0);return[e.memoizedState,r.dispatch]}function Hu(t){var e=Nr(),r=e.queue;if(r===null)throw Error(ce(311));r.lastRenderedReducer=t;var i=r.dispatch,n=r.pending,a=e.memoizedState;if(n!==null){r.pending=null;var s=n=n.next;do a=t(a,s.action),s=s.next;while(s!==n);Zr(a,e.memoizedState)||(hr=!0),e.memoizedState=a,e.baseQueue===null&&(e.baseState=a),r.lastRenderedState=a}return[a,i]}function Wg(){}function jg(t,e){var r=Et,i=Nr(),n=e(),a=!Zr(i.memoizedState,n);if(a&&(i.memoizedState=n,hr=!0),i=i.queue,hh(qg.bind(null,r,i,t),[t]),i.getSnapshot!==e||a||Vt!==null&&Vt.memoizedState.tag&1){if(r.flags|=2048,Zs(9,Yg.bind(null,r,i,n,e),void 0,null),Ht===null)throw Error(ce(349));On&30||Xg(r,e,n)}return n}function Xg(t,e,r){t.flags|=16384,t={getSnapshot:e,value:r},e=Et.updateQueue,e===null?(e={lastEffect:null,stores:null},Et.updateQueue=e,e.stores=[t]):(r=e.stores,r===null?e.stores=[t]:r.push(t))}function Yg(t,e,r,i){e.value=r,e.getSnapshot=i,Kg(e)&&Zg(t)}function qg(t,e,r){return r(function(){Kg(e)&&Zg(t)})}function Kg(t){var e=t.getSnapshot;t=t.value;try{var r=e();return!Zr(t,r)}catch{return!0}}function Zg(t){var e=Ai(t,1);e!==null&&qr(e,t,1,-1)}function yf(t){var e=Qr();return typeof t=="function"&&(t=t()),e.memoizedState=e.baseState=t,t={pending:null,interleaved:null,lanes:0,dispatch:null,lastRenderedReducer:Ks,lastRenderedState:t},e.queue=t,t=t.dispatch=Sx.bind(null,Et,t),[e.memoizedState,t]}function Zs(t,e,r,i){return t={tag:t,create:e,destroy:r,deps:i,next:null},e=Et.updateQueue,e===null?(e={lastEffect:null,stores:null},Et.updateQueue=e,e.lastEffect=t.next=t):(r=e.lastEffect,r===null?e.lastEffect=t.next=t:(i=r.next,r.next=t,t.next=i,e.lastEffect=t)),t}function $g(){return Nr().memoizedState}function ll(t,e,r,i){var n=Qr();Et.flags|=t,n.memoizedState=Zs(1|e,r,void 0,i===void 0?null:i)}function iu(t,e,r,i){var n=Nr();i=i===void 0?null:i;var a=void 0;if(Nt!==null){var s=Nt.memoizedState;if(a=s.destroy,i!==null&&uh(i,s.deps)){n.memoizedState=Zs(e,r,a,i);return}}Et.flags|=t,n.memoizedState=Zs(1|e,r,a,i)}function Mf(t,e){return ll(8390656,8,t,e)}function hh(t,e){return iu(2048,8,t,e)}function Qg(t,e){return iu(4,2,t,e)}function Jg(t,e){return iu(4,4,t,e)}function ev(t,e){if(typeof e=="function")return t=t(),e(t),function(){e(null)};if(e!=null)return t=t(),e.current=t,function(){e.current=null}}function tv(t,e,r){return r=r!=null?r.concat([t]):null,iu(4,4,ev.bind(null,e,t),r)}function fh(){}function rv(t,e){var r=Nr();e=e===void 0?null:e;var i=r.memoizedState;return i!==null&&e!==null&&uh(e,i[1])?i[0]:(r.memoizedState=[t,e],t)}function iv(t,e){var r=Nr();e=e===void 0?null:e;var i=r.memoizedState;return i!==null&&e!==null&&uh(e,i[1])?i[0]:(t=t(),r.memoizedState=[t,e],t)}function nv(t,e,r){return On&21?(Zr(r,e)||(r=ug(),Et.lanes|=r,kn|=r,t.baseState=!0),e):(t.baseState&&(t.baseState=!1,hr=!0),t.memoizedState=r)}function yx(t,e){var r=ct;ct=r!==0&&4>r?r:4,t(!0);var i=Bu.transition;Bu.transition={};try{t(!1),e()}finally{ct=r,Bu.transition=i}}function av(){return Nr().memoizedState}function Mx(t,e,r){var i=en(t);if(r={lane:i,action:r,hasEagerState:!1,eagerState:null,next:null},sv(t))ov(e,r);else if(r=Vg(t,e,r,i),r!==null){var n=ar();qr(r,t,i,n),lv(r,e,i)}}function Sx(t,e,r){var i=en(t),n={lane:i,action:r,hasEagerState:!1,eagerState:null,next:null};if(sv(t))ov(e,n);else{var a=t.alternate;if(t.lanes===0&&(a===null||a.lanes===0)&&(a=e.lastRenderedReducer,a!==null))try{var s=e.lastRenderedState,o=a(s,r);if(n.hasEagerState=!0,n.eagerState=o,Zr(o,s)){var l=e.interleaved;l===null?(n.next=n,nh(e)):(n.next=l.next,l.next=n),e.interleaved=n;return}}catch{}finally{}r=Vg(t,e,n,i),r!==null&&(n=ar(),qr(r,t,i,n),lv(r,e,i))}}function sv(t){var e=t.alternate;return t===Et||e!==null&&e===Et}function ov(t,e){Ps=Ul=!0;var r=t.pending;r===null?e.next=e:(e.next=r.next,r.next=e),t.pending=e}function lv(t,e,r){if(r&4194240){var i=e.lanes;i&=t.pendingLanes,r|=i,e.lanes=r,Wd(t,r)}}var Dl={readContext:Ir,useCallback:Kt,useContext:Kt,useEffect:Kt,useImperativeHandle:Kt,useInsertionEffect:Kt,useLayoutEffect:Kt,useMemo:Kt,useReducer:Kt,useRef:Kt,useState:Kt,useDebugValue:Kt,useDeferredValue:Kt,useTransition:Kt,useMutableSource:Kt,useSyncExternalStore:Kt,useId:Kt,unstable_isNewReconciler:!1},bx={readContext:Ir,useCallback:function(t,e){return Qr().memoizedState=[t,e===void 0?null:e],t},useContext:Ir,useEffect:Mf,useImperativeHandle:function(t,e,r){return r=r!=null?r.concat([t]):null,ll(4194308,4,ev.bind(null,e,t),r)},useLayoutEffect:function(t,e){return ll(4194308,4,t,e)},useInsertionEffect:function(t,e){return ll(4,2,t,e)},useMemo:function(t,e){var r=Qr();return e=e===void 0?null:e,t=t(),r.memoizedState=[t,e],t},useReducer:function(t,e,r){var i=Qr();return e=r!==void 0?r(e):e,i.memoizedState=i.baseState=e,t={pending:null,interleaved:null,lanes:0,dispatch:null,lastRenderedReducer:t,lastRenderedState:e},i.queue=t,t=t.dispatch=Mx.bind(null,Et,t),[i.memoizedState,t]},useRef:function(t){var e=Qr();return t={current:t},e.memoizedState=t},useState:yf,useDebugValue:fh,useDeferredValue:function(t){return Qr().memoizedState=t},useTransition:function(){var t=yf(!1),e=t[0];return t=yx.bind(null,t[1]),Qr().memoizedState=t,[e,t]},useMutableSource:function(){},useSyncExternalStore:function(t,e,r){var i=Et,n=Qr();if(yt){if(r===void 0)throw Error(ce(407));r=r()}else{if(r=e(),Ht===null)throw Error(ce(349));On&30||Xg(i,e,r)}n.memoizedState=r;var a={value:r,getSnapshot:e};return n.queue=a,Mf(qg.bind(null,i,a,t),[t]),i.flags|=2048,Zs(9,Yg.bind(null,i,a,r,e),void 0,null),r},useId:function(){var t=Qr(),e=Ht.identifierPrefix;if(yt){var r=yi,i=xi;r=(i&~(1<<32-Yr(i)-1)).toString(32)+r,e=":"+e+"R"+r,r=qs++,0<r&&(e+="H"+r.toString(32)),e+=":"}else r=xx++,e=":"+e+"r"+r.toString(32)+":";return t.memoizedState=e},unstable_isNewReconciler:!1},Ex={readContext:Ir,useCallback:rv,useContext:Ir,useEffect:hh,useImperativeHandle:tv,useInsertionEffect:Qg,useLayoutEffect:Jg,useMemo:iv,useReducer:Vu,useRef:$g,useState:function(){return Vu(Ks)},useDebugValue:fh,useDeferredValue:function(t){var e=Nr();return nv(e,Nt.memoizedState,t)},useTransition:function(){var t=Vu(Ks)[0],e=Nr().memoizedState;return[t,e]},useMutableSource:Wg,useSyncExternalStore:jg,useId:av,unstable_isNewReconciler:!1},wx={readContext:Ir,useCallback:rv,useContext:Ir,useEffect:hh,useImperativeHandle:tv,useInsertionEffect:Qg,useLayoutEffect:Jg,useMemo:iv,useReducer:Hu,useRef:$g,useState:function(){return Hu(Ks)},useDebugValue:fh,useDeferredValue:function(t){var e=Nr();return Nt===null?e.memoizedState=t:nv(e,Nt.memoizedState,t)},useTransition:function(){var t=Hu(Ks)[0],e=Nr().memoizedState;return[t,e]},useMutableSource:Wg,useSyncExternalStore:jg,useId:av,unstable_isNewReconciler:!1};function Vr(t,e){if(t&&t.defaultProps){e=wt({},e),t=t.defaultProps;for(var r in t)e[r]===void 0&&(e[r]=t[r]);return e}return e}function ld(t,e,r,i){e=t.memoizedState,r=r(i,e),r=r==null?e:wt({},e,r),t.memoizedState=r,t.lanes===0&&(t.updateQueue.baseState=r)}var nu={isMounted:function(t){return(t=t._reactInternals)?Hn(t)===t:!1},enqueueSetState:function(t,e,r){t=t._reactInternals;var i=ar(),n=en(t),a=Ei(i,n);a.payload=e,r!=null&&(a.callback=r),e=Qi(t,a,n),e!==null&&(qr(e,t,n,i),sl(e,t,n))},enqueueReplaceState:function(t,e,r){t=t._reactInternals;var i=ar(),n=en(t),a=Ei(i,n);a.tag=1,a.payload=e,r!=null&&(a.callback=r),e=Qi(t,a,n),e!==null&&(qr(e,t,n,i),sl(e,t,n))},enqueueForceUpdate:function(t,e){t=t._reactInternals;var r=ar(),i=en(t),n=Ei(r,i);n.tag=2,e!=null&&(n.callback=e),e=Qi(t,n,i),e!==null&&(qr(e,t,i,r),sl(e,t,i))}};function Sf(t,e,r,i,n,a,s){return t=t.stateNode,typeof t.shouldComponentUpdate=="function"?t.shouldComponentUpdate(i,a,s):e.prototype&&e.prototype.isPureReactComponent?!Hs(r,i)||!Hs(n,a):!0}function uv(t,e,r){var i=!1,n=sn,a=e.contextType;return typeof a=="object"&&a!==null?a=Ir(a):(n=mr(e)?In:er.current,i=e.contextTypes,a=(i=i!=null)?Oa(t,n):sn),e=new e(r,a),t.memoizedState=e.state!==null&&e.state!==void 0?e.state:null,e.updater=nu,t.stateNode=e,e._reactInternals=t,i&&(t=t.stateNode,t.__reactInternalMemoizedUnmaskedChildContext=n,t.__reactInternalMemoizedMaskedChildContext=a),e}function bf(t,e,r,i){t=e.state,typeof e.componentWillReceiveProps=="function"&&e.componentWillReceiveProps(r,i),typeof e.UNSAFE_componentWillReceiveProps=="function"&&e.UNSAFE_componentWillReceiveProps(r,i),e.state!==t&&nu.enqueueReplaceState(e,e.state,null)}function ud(t,e,r,i){var n=t.stateNode;n.props=r,n.state=t.memoizedState,n.refs={},ah(t);var a=e.contextType;typeof a=="object"&&a!==null?n.context=Ir(a):(a=mr(e)?In:er.current,n.context=Oa(t,a)),n.state=t.memoizedState,a=e.getDerivedStateFromProps,typeof a=="function"&&(ld(t,e,a,r),n.state=t.memoizedState),typeof e.getDerivedStateFromProps=="function"||typeof n.getSnapshotBeforeUpdate=="function"||typeof n.UNSAFE_componentWillMount!="function"&&typeof n.componentWillMount!="function"||(e=n.state,typeof n.componentWillMount=="function"&&n.componentWillMount(),typeof n.UNSAFE_componentWillMount=="function"&&n.UNSAFE_componentWillMount(),e!==n.state&&nu.enqueueReplaceState(n,n.state,null),Pl(t,r,n,i),n.state=t.memoizedState),typeof n.componentDidMount=="function"&&(t.flags|=4194308)}function Ba(t,e){try{var r="",i=e;do r+=J_(i),i=i.return;while(i);var n=r}catch(a){n=`
Error generating stack: `+a.message+`
`+a.stack}return{value:t,source:e,stack:n,digest:null}}function Gu(t,e,r){return{value:t,source:null,stack:r??null,digest:e??null}}function cd(t,e){try{console.error(e.value)}catch(r){setTimeout(function(){throw r})}}var Tx=typeof WeakMap=="function"?WeakMap:Map;function cv(t,e,r){r=Ei(-1,r),r.tag=3,r.payload={element:null};var i=e.value;return r.callback=function(){Nl||(Nl=!0,xd=i),cd(t,e)},r}function dv(t,e,r){r=Ei(-1,r),r.tag=3;var i=t.type.getDerivedStateFromError;if(typeof i=="function"){var n=e.value;r.payload=function(){return i(n)},r.callback=function(){cd(t,e)}}var a=t.stateNode;return a!==null&&typeof a.componentDidCatch=="function"&&(r.callback=function(){cd(t,e),typeof i!="function"&&(Ji===null?Ji=new Set([this]):Ji.add(this));var s=e.stack;this.componentDidCatch(e.value,{componentStack:s!==null?s:""})}),r}function Ef(t,e,r){var i=t.pingCache;if(i===null){i=t.pingCache=new Tx;var n=new Set;i.set(e,n)}else n=i.get(e),n===void 0&&(n=new Set,i.set(e,n));n.has(r)||(n.add(r),t=Bx.bind(null,t,e,r),e.then(t,t))}function wf(t){do{var e;if((e=t.tag===13)&&(e=t.memoizedState,e=e!==null?e.dehydrated!==null:!0),e)return t;t=t.return}while(t!==null);return null}function Tf(t,e,r,i,n){return t.mode&1?(t.flags|=65536,t.lanes=n,t):(t===e?t.flags|=65536:(t.flags|=128,r.flags|=131072,r.flags&=-52805,r.tag===1&&(r.alternate===null?r.tag=17:(e=Ei(-1,1),e.tag=2,Qi(r,e,1))),r.lanes|=1),t)}var Ax=Ri.ReactCurrentOwner,hr=!1;function ir(t,e,r,i){e.child=t===null?Bg(e,null,r,i):Fa(e,t.child,r,i)}function Af(t,e,r,i,n){r=r.render;var a=e.ref;return Ra(e,n),i=ch(t,e,r,i,a,n),r=dh(),t!==null&&!hr?(e.updateQueue=t.updateQueue,e.flags&=-2053,t.lanes&=~n,Ci(t,e,n)):(yt&&r&&Qd(e),e.flags|=1,ir(t,e,i,n),e.child)}function Cf(t,e,r,i,n){if(t===null){var a=r.type;return typeof a=="function"&&!Mh(a)&&a.defaultProps===void 0&&r.compare===null&&r.defaultProps===void 0?(e.tag=15,e.type=a,hv(t,e,a,i,n)):(t=hl(r.type,null,i,e,e.mode,n),t.ref=e.ref,t.return=e,e.child=t)}if(a=t.child,!(t.lanes&n)){var s=a.memoizedProps;if(r=r.compare,r=r!==null?r:Hs,r(s,i)&&t.ref===e.ref)return Ci(t,e,n)}return e.flags|=1,t=tn(a,i),t.ref=e.ref,t.return=e,e.child=t}function hv(t,e,r,i,n){if(t!==null){var a=t.memoizedProps;if(Hs(a,i)&&t.ref===e.ref)if(hr=!1,e.pendingProps=i=a,(t.lanes&n)!==0)t.flags&131072&&(hr=!0);else return e.lanes=t.lanes,Ci(t,e,n)}return dd(t,e,r,i,n)}function fv(t,e,r){var i=e.pendingProps,n=i.children,a=t!==null?t.memoizedState:null;if(i.mode==="hidden")if(!(e.mode&1))e.memoizedState={baseLanes:0,cachePool:null,transitions:null},gt(ba,Mr),Mr|=r;else{if(!(r&1073741824))return t=a!==null?a.baseLanes|r:r,e.lanes=e.childLanes=1073741824,e.memoizedState={baseLanes:t,cachePool:null,transitions:null},e.updateQueue=null,gt(ba,Mr),Mr|=t,null;e.memoizedState={baseLanes:0,cachePool:null,transitions:null},i=a!==null?a.baseLanes:r,gt(ba,Mr),Mr|=i}else a!==null?(i=a.baseLanes|r,e.memoizedState=null):i=r,gt(ba,Mr),Mr|=i;return ir(t,e,n,r),e.child}function pv(t,e){var r=e.ref;(t===null&&r!==null||t!==null&&t.ref!==r)&&(e.flags|=512,e.flags|=2097152)}function dd(t,e,r,i,n){var a=mr(r)?In:er.current;return a=Oa(e,a),Ra(e,n),r=ch(t,e,r,i,a,n),i=dh(),t!==null&&!hr?(e.updateQueue=t.updateQueue,e.flags&=-2053,t.lanes&=~n,Ci(t,e,n)):(yt&&i&&Qd(e),e.flags|=1,ir(t,e,r,n),e.child)}function Rf(t,e,r,i,n){if(mr(r)){var a=!0;wl(e)}else a=!1;if(Ra(e,n),e.stateNode===null)ul(t,e),uv(e,r,i),ud(e,r,i,n),i=!0;else if(t===null){var s=e.stateNode,o=e.memoizedProps;s.props=o;var l=s.context,u=r.contextType;typeof u=="object"&&u!==null?u=Ir(u):(u=mr(r)?In:er.current,u=Oa(e,u));var h=r.getDerivedStateFromProps,f=typeof h=="function"||typeof s.getSnapshotBeforeUpdate=="function";f||typeof s.UNSAFE_componentWillReceiveProps!="function"&&typeof s.componentWillReceiveProps!="function"||(o!==i||l!==u)&&bf(e,s,i,u),zi=!1;var d=e.memoizedState;s.state=d,Pl(e,i,s,n),l=e.memoizedState,o!==i||d!==l||pr.current||zi?(typeof h=="function"&&(ld(e,r,h,i),l=e.memoizedState),(o=zi||Sf(e,r,o,i,d,l,u))?(f||typeof s.UNSAFE_componentWillMount!="function"&&typeof s.componentWillMount!="function"||(typeof s.componentWillMount=="function"&&s.componentWillMount(),typeof s.UNSAFE_componentWillMount=="function"&&s.UNSAFE_componentWillMount()),typeof s.componentDidMount=="function"&&(e.flags|=4194308)):(typeof s.componentDidMount=="function"&&(e.flags|=4194308),e.memoizedProps=i,e.memoizedState=l),s.props=i,s.state=l,s.context=u,i=o):(typeof s.componentDidMount=="function"&&(e.flags|=4194308),i=!1)}else{s=e.stateNode,Hg(t,e),o=e.memoizedProps,u=e.type===e.elementType?o:Vr(e.type,o),s.props=u,f=e.pendingProps,d=s.context,l=r.contextType,typeof l=="object"&&l!==null?l=Ir(l):(l=mr(r)?In:er.current,l=Oa(e,l));var p=r.getDerivedStateFromProps;(h=typeof p=="function"||typeof s.getSnapshotBeforeUpdate=="function")||typeof s.UNSAFE_componentWillReceiveProps!="function"&&typeof s.componentWillReceiveProps!="function"||(o!==f||d!==l)&&bf(e,s,i,l),zi=!1,d=e.memoizedState,s.state=d,Pl(e,i,s,n);var _=e.memoizedState;o!==f||d!==_||pr.current||zi?(typeof p=="function"&&(ld(e,r,p,i),_=e.memoizedState),(u=zi||Sf(e,r,u,i,d,_,l)||!1)?(h||typeof s.UNSAFE_componentWillUpdate!="function"&&typeof s.componentWillUpdate!="function"||(typeof s.componentWillUpdate=="function"&&s.componentWillUpdate(i,_,l),typeof s.UNSAFE_componentWillUpdate=="function"&&s.UNSAFE_componentWillUpdate(i,_,l)),typeof s.componentDidUpdate=="function"&&(e.flags|=4),typeof s.getSnapshotBeforeUpdate=="function"&&(e.flags|=1024)):(typeof s.componentDidUpdate!="function"||o===t.memoizedProps&&d===t.memoizedState||(e.flags|=4),typeof s.getSnapshotBeforeUpdate!="function"||o===t.memoizedProps&&d===t.memoizedState||(e.flags|=1024),e.memoizedProps=i,e.memoizedState=_),s.props=i,s.state=_,s.context=l,i=u):(typeof s.componentDidUpdate!="function"||o===t.memoizedProps&&d===t.memoizedState||(e.flags|=4),typeof s.getSnapshotBeforeUpdate!="function"||o===t.memoizedProps&&d===t.memoizedState||(e.flags|=1024),i=!1)}return hd(t,e,r,i,a,n)}function hd(t,e,r,i,n,a){pv(t,e);var s=(e.flags&128)!==0;if(!i&&!s)return n&&pf(e,r,!1),Ci(t,e,a);i=e.stateNode,Ax.current=e;var o=s&&typeof r.getDerivedStateFromError!="function"?null:i.render();return e.flags|=1,t!==null&&s?(e.child=Fa(e,t.child,null,a),e.child=Fa(e,null,o,a)):ir(t,e,o,a),e.memoizedState=i.state,n&&pf(e,r,!0),e.child}function mv(t){var e=t.stateNode;e.pendingContext?ff(t,e.pendingContext,e.pendingContext!==e.context):e.context&&ff(t,e.context,!1),sh(t,e.containerInfo)}function Pf(t,e,r,i,n){return ka(),eh(n),e.flags|=256,ir(t,e,r,i),e.child}var fd={dehydrated:null,treeContext:null,retryLane:0};function pd(t){return{baseLanes:t,cachePool:null,transitions:null}}function gv(t,e,r){var i=e.pendingProps,n=bt.current,a=!1,s=(e.flags&128)!==0,o;if((o=s)||(o=t!==null&&t.memoizedState===null?!1:(n&2)!==0),o?(a=!0,e.flags&=-129):(t===null||t.memoizedState!==null)&&(n|=1),gt(bt,n&1),t===null)return sd(e),t=e.memoizedState,t!==null&&(t=t.dehydrated,t!==null)?(e.mode&1?t.data==="$!"?e.lanes=8:e.lanes=1073741824:e.lanes=1,null):(s=i.children,t=i.fallback,a?(i=e.mode,a=e.child,s={mode:"hidden",children:s},!(i&1)&&a!==null?(a.childLanes=0,a.pendingProps=s):a=ou(s,i,0,null),t=Dn(t,i,r,null),a.return=e,t.return=e,a.sibling=t,e.child=a,e.child.memoizedState=pd(r),e.memoizedState=fd,t):ph(e,s));if(n=t.memoizedState,n!==null&&(o=n.dehydrated,o!==null))return Cx(t,e,s,i,o,n,r);if(a){a=i.fallback,s=e.mode,n=t.child,o=n.sibling;var l={mode:"hidden",children:i.children};return!(s&1)&&e.child!==n?(i=e.child,i.childLanes=0,i.pendingProps=l,e.deletions=null):(i=tn(n,l),i.subtreeFlags=n.subtreeFlags&14680064),o!==null?a=tn(o,a):(a=Dn(a,s,r,null),a.flags|=2),a.return=e,i.return=e,i.sibling=a,e.child=i,i=a,a=e.child,s=t.child.memoizedState,s=s===null?pd(r):{baseLanes:s.baseLanes|r,cachePool:null,transitions:s.transitions},a.memoizedState=s,a.childLanes=t.childLanes&~r,e.memoizedState=fd,i}return a=t.child,t=a.sibling,i=tn(a,{mode:"visible",children:i.children}),!(e.mode&1)&&(i.lanes=r),i.return=e,i.sibling=null,t!==null&&(r=e.deletions,r===null?(e.deletions=[t],e.flags|=16):r.push(t)),e.child=i,e.memoizedState=null,i}function ph(t,e){return e=ou({mode:"visible",children:e},t.mode,0,null),e.return=t,t.child=e}function Mo(t,e,r,i){return i!==null&&eh(i),Fa(e,t.child,null,r),t=ph(e,e.pendingProps.children),t.flags|=2,e.memoizedState=null,t}function Cx(t,e,r,i,n,a,s){if(r)return e.flags&256?(e.flags&=-257,i=Gu(Error(ce(422))),Mo(t,e,s,i)):e.memoizedState!==null?(e.child=t.child,e.flags|=128,null):(a=i.fallback,n=e.mode,i=ou({mode:"visible",children:i.children},n,0,null),a=Dn(a,n,s,null),a.flags|=2,i.return=e,a.return=e,i.sibling=a,e.child=i,e.mode&1&&Fa(e,t.child,null,s),e.child.memoizedState=pd(s),e.memoizedState=fd,a);if(!(e.mode&1))return Mo(t,e,s,null);if(n.data==="$!"){if(i=n.nextSibling&&n.nextSibling.dataset,i)var o=i.dgst;return i=o,a=Error(ce(419)),i=Gu(a,i,void 0),Mo(t,e,s,i)}if(o=(s&t.childLanes)!==0,hr||o){if(i=Ht,i!==null){switch(s&-s){case 4:n=2;break;case 16:n=8;break;case 64:case 128:case 256:case 512:case 1024:case 2048:case 4096:case 8192:case 16384:case 32768:case 65536:case 131072:case 262144:case 524288:case 1048576:case 2097152:case 4194304:case 8388608:case 16777216:case 33554432:case 67108864:n=32;break;case 536870912:n=268435456;break;default:n=0}n=n&(i.suspendedLanes|s)?0:n,n!==0&&n!==a.retryLane&&(a.retryLane=n,Ai(t,n),qr(i,t,n,-1))}return yh(),i=Gu(Error(ce(421))),Mo(t,e,s,i)}return n.data==="$?"?(e.flags|=128,e.child=t.child,e=Vx.bind(null,t),n._reactRetry=e,null):(t=a.treeContext,br=$i(n.nextSibling),Er=e,yt=!0,Wr=null,t!==null&&(Pr[Lr++]=xi,Pr[Lr++]=yi,Pr[Lr++]=Nn,xi=t.id,yi=t.overflow,Nn=e),e=ph(e,i.children),e.flags|=4096,e)}function Lf(t,e,r){t.lanes|=e;var i=t.alternate;i!==null&&(i.lanes|=e),od(t.return,e,r)}function Wu(t,e,r,i,n){var a=t.memoizedState;a===null?t.memoizedState={isBackwards:e,rendering:null,renderingStartTime:0,last:i,tail:r,tailMode:n}:(a.isBackwards=e,a.rendering=null,a.renderingStartTime=0,a.last=i,a.tail=r,a.tailMode=n)}function vv(t,e,r){var i=e.pendingProps,n=i.revealOrder,a=i.tail;if(ir(t,e,i.children,r),i=bt.current,i&2)i=i&1|2,e.flags|=128;else{if(t!==null&&t.flags&128)e:for(t=e.child;t!==null;){if(t.tag===13)t.memoizedState!==null&&Lf(t,r,e);else if(t.tag===19)Lf(t,r,e);else if(t.child!==null){t.child.return=t,t=t.child;continue}if(t===e)break e;for(;t.sibling===null;){if(t.return===null||t.return===e)break e;t=t.return}t.sibling.return=t.return,t=t.sibling}i&=1}if(gt(bt,i),!(e.mode&1))e.memoizedState=null;else switch(n){case"forwards":for(r=e.child,n=null;r!==null;)t=r.alternate,t!==null&&Ll(t)===null&&(n=r),r=r.sibling;r=n,r===null?(n=e.child,e.child=null):(n=r.sibling,r.sibling=null),Wu(e,!1,n,r,a);break;case"backwards":for(r=null,n=e.child,e.child=null;n!==null;){if(t=n.alternate,t!==null&&Ll(t)===null){e.child=n;break}t=n.sibling,n.sibling=r,r=n,n=t}Wu(e,!0,r,null,a);break;case"together":Wu(e,!1,null,null,void 0);break;default:e.memoizedState=null}return e.child}function ul(t,e){!(e.mode&1)&&t!==null&&(t.alternate=null,e.alternate=null,e.flags|=2)}function Ci(t,e,r){if(t!==null&&(e.dependencies=t.dependencies),kn|=e.lanes,!(r&e.childLanes))return null;if(t!==null&&e.child!==t.child)throw Error(ce(153));if(e.child!==null){for(t=e.child,r=tn(t,t.pendingProps),e.child=r,r.return=e;t.sibling!==null;)t=t.sibling,r=r.sibling=tn(t,t.pendingProps),r.return=e;r.sibling=null}return e.child}function Rx(t,e,r){switch(e.tag){case 3:mv(e),ka();break;case 5:Gg(e);break;case 1:mr(e.type)&&wl(e);break;case 4:sh(e,e.stateNode.containerInfo);break;case 10:var i=e.type._context,n=e.memoizedProps.value;gt(Cl,i._currentValue),i._currentValue=n;break;case 13:if(i=e.memoizedState,i!==null)return i.dehydrated!==null?(gt(bt,bt.current&1),e.flags|=128,null):r&e.child.childLanes?gv(t,e,r):(gt(bt,bt.current&1),t=Ci(t,e,r),t!==null?t.sibling:null);gt(bt,bt.current&1);break;case 19:if(i=(r&e.childLanes)!==0,t.flags&128){if(i)return vv(t,e,r);e.flags|=128}if(n=e.memoizedState,n!==null&&(n.rendering=null,n.tail=null,n.lastEffect=null),gt(bt,bt.current),i)break;return null;case 22:case 23:return e.lanes=0,fv(t,e,r)}return Ci(t,e,r)}var _v,md,xv,yv;_v=function(t,e){for(var r=e.child;r!==null;){if(r.tag===5||r.tag===6)t.appendChild(r.stateNode);else if(r.tag!==4&&r.child!==null){r.child.return=r,r=r.child;continue}if(r===e)break;for(;r.sibling===null;){if(r.return===null||r.return===e)return;r=r.return}r.sibling.return=r.return,r=r.sibling}};md=function(){};xv=function(t,e,r,i){var n=t.memoizedProps;if(n!==i){t=e.stateNode,Rn(si.current);var a=null;switch(r){case"input":n=kc(t,n),i=kc(t,i),a=[];break;case"select":n=wt({},n,{value:void 0}),i=wt({},i,{value:void 0}),a=[];break;case"textarea":n=Bc(t,n),i=Bc(t,i),a=[];break;default:typeof n.onClick!="function"&&typeof i.onClick=="function"&&(t.onclick=bl)}Hc(r,i);var s;r=null;for(u in n)if(!i.hasOwnProperty(u)&&n.hasOwnProperty(u)&&n[u]!=null)if(u==="style"){var o=n[u];for(s in o)o.hasOwnProperty(s)&&(r||(r={}),r[s]="")}else u!=="dangerouslySetInnerHTML"&&u!=="children"&&u!=="suppressContentEditableWarning"&&u!=="suppressHydrationWarning"&&u!=="autoFocus"&&(Ns.hasOwnProperty(u)?a||(a=[]):(a=a||[]).push(u,null));for(u in i){var l=i[u];if(o=n!=null?n[u]:void 0,i.hasOwnProperty(u)&&l!==o&&(l!=null||o!=null))if(u==="style")if(o){for(s in o)!o.hasOwnProperty(s)||l&&l.hasOwnProperty(s)||(r||(r={}),r[s]="");for(s in l)l.hasOwnProperty(s)&&o[s]!==l[s]&&(r||(r={}),r[s]=l[s])}else r||(a||(a=[]),a.push(u,r)),r=l;else u==="dangerouslySetInnerHTML"?(l=l?l.__html:void 0,o=o?o.__html:void 0,l!=null&&o!==l&&(a=a||[]).push(u,l)):u==="children"?typeof l!="string"&&typeof l!="number"||(a=a||[]).push(u,""+l):u!=="suppressContentEditableWarning"&&u!=="suppressHydrationWarning"&&(Ns.hasOwnProperty(u)?(l!=null&&u==="onScroll"&&vt("scroll",t),a||o===l||(a=[])):(a=a||[]).push(u,l))}r&&(a=a||[]).push("style",r);var u=a;(e.updateQueue=u)&&(e.flags|=4)}};yv=function(t,e,r,i){r!==i&&(e.flags|=4)};function os(t,e){if(!yt)switch(t.tailMode){case"hidden":e=t.tail;for(var r=null;e!==null;)e.alternate!==null&&(r=e),e=e.sibling;r===null?t.tail=null:r.sibling=null;break;case"collapsed":r=t.tail;for(var i=null;r!==null;)r.alternate!==null&&(i=r),r=r.sibling;i===null?e||t.tail===null?t.tail=null:t.tail.sibling=null:i.sibling=null}}function Zt(t){var e=t.alternate!==null&&t.alternate.child===t.child,r=0,i=0;if(e)for(var n=t.child;n!==null;)r|=n.lanes|n.childLanes,i|=n.subtreeFlags&14680064,i|=n.flags&14680064,n.return=t,n=n.sibling;else for(n=t.child;n!==null;)r|=n.lanes|n.childLanes,i|=n.subtreeFlags,i|=n.flags,n.return=t,n=n.sibling;return t.subtreeFlags|=i,t.childLanes=r,e}function Px(t,e,r){var i=e.pendingProps;switch(Jd(e),e.tag){case 2:case 16:case 15:case 0:case 11:case 7:case 8:case 12:case 9:case 14:return Zt(e),null;case 1:return mr(e.type)&&El(),Zt(e),null;case 3:return i=e.stateNode,za(),xt(pr),xt(er),lh(),i.pendingContext&&(i.context=i.pendingContext,i.pendingContext=null),(t===null||t.child===null)&&(xo(e)?e.flags|=4:t===null||t.memoizedState.isDehydrated&&!(e.flags&256)||(e.flags|=1024,Wr!==null&&(Sd(Wr),Wr=null))),md(t,e),Zt(e),null;case 5:oh(e);var n=Rn(Ys.current);if(r=e.type,t!==null&&e.stateNode!=null)xv(t,e,r,i,n),t.ref!==e.ref&&(e.flags|=512,e.flags|=2097152);else{if(!i){if(e.stateNode===null)throw Error(ce(166));return Zt(e),null}if(t=Rn(si.current),xo(e)){i=e.stateNode,r=e.type;var a=e.memoizedProps;switch(i[ri]=e,i[js]=a,t=(e.mode&1)!==0,r){case"dialog":vt("cancel",i),vt("close",i);break;case"iframe":case"object":case"embed":vt("load",i);break;case"video":case"audio":for(n=0;n<bs.length;n++)vt(bs[n],i);break;case"source":vt("error",i);break;case"img":case"image":case"link":vt("error",i),vt("load",i);break;case"details":vt("toggle",i);break;case"input":zh(i,a),vt("invalid",i);break;case"select":i._wrapperState={wasMultiple:!!a.multiple},vt("invalid",i);break;case"textarea":Vh(i,a),vt("invalid",i)}Hc(r,a),n=null;for(var s in a)if(a.hasOwnProperty(s)){var o=a[s];s==="children"?typeof o=="string"?i.textContent!==o&&(a.suppressHydrationWarning!==!0&&_o(i.textContent,o,t),n=["children",o]):typeof o=="number"&&i.textContent!==""+o&&(a.suppressHydrationWarning!==!0&&_o(i.textContent,o,t),n=["children",""+o]):Ns.hasOwnProperty(s)&&o!=null&&s==="onScroll"&&vt("scroll",i)}switch(r){case"input":uo(i),Bh(i,a,!0);break;case"textarea":uo(i),Hh(i);break;case"select":case"option":break;default:typeof a.onClick=="function"&&(i.onclick=bl)}i=n,e.updateQueue=i,i!==null&&(e.flags|=4)}else{s=n.nodeType===9?n:n.ownerDocument,t==="http://www.w3.org/1999/xhtml"&&(t=qm(r)),t==="http://www.w3.org/1999/xhtml"?r==="script"?(t=s.createElement("div"),t.innerHTML="<script><\/script>",t=t.removeChild(t.firstChild)):typeof i.is=="string"?t=s.createElement(r,{is:i.is}):(t=s.createElement(r),r==="select"&&(s=t,i.multiple?s.multiple=!0:i.size&&(s.size=i.size))):t=s.createElementNS(t,r),t[ri]=e,t[js]=i,_v(t,e,!1,!1),e.stateNode=t;e:{switch(s=Gc(r,i),r){case"dialog":vt("cancel",t),vt("close",t),n=i;break;case"iframe":case"object":case"embed":vt("load",t),n=i;break;case"video":case"audio":for(n=0;n<bs.length;n++)vt(bs[n],t);n=i;break;case"source":vt("error",t),n=i;break;case"img":case"image":case"link":vt("error",t),vt("load",t),n=i;break;case"details":vt("toggle",t),n=i;break;case"input":zh(t,i),n=kc(t,i),vt("invalid",t);break;case"option":n=i;break;case"select":t._wrapperState={wasMultiple:!!i.multiple},n=wt({},i,{value:void 0}),vt("invalid",t);break;case"textarea":Vh(t,i),n=Bc(t,i),vt("invalid",t);break;default:n=i}Hc(r,n),o=n;for(a in o)if(o.hasOwnProperty(a)){var l=o[a];a==="style"?$m(t,l):a==="dangerouslySetInnerHTML"?(l=l?l.__html:void 0,l!=null&&Km(t,l)):a==="children"?typeof l=="string"?(r!=="textarea"||l!=="")&&Os(t,l):typeof l=="number"&&Os(t,""+l):a!=="suppressContentEditableWarning"&&a!=="suppressHydrationWarning"&&a!=="autoFocus"&&(Ns.hasOwnProperty(a)?l!=null&&a==="onScroll"&&vt("scroll",t):l!=null&&Fd(t,a,l,s))}switch(r){case"input":uo(t),Bh(t,i,!1);break;case"textarea":uo(t),Hh(t);break;case"option":i.value!=null&&t.setAttribute("value",""+an(i.value));break;case"select":t.multiple=!!i.multiple,a=i.value,a!=null?wa(t,!!i.multiple,a,!1):i.defaultValue!=null&&wa(t,!!i.multiple,i.defaultValue,!0);break;default:typeof n.onClick=="function"&&(t.onclick=bl)}switch(r){case"button":case"input":case"select":case"textarea":i=!!i.autoFocus;break e;case"img":i=!0;break e;default:i=!1}}i&&(e.flags|=4)}e.ref!==null&&(e.flags|=512,e.flags|=2097152)}return Zt(e),null;case 6:if(t&&e.stateNode!=null)yv(t,e,t.memoizedProps,i);else{if(typeof i!="string"&&e.stateNode===null)throw Error(ce(166));if(r=Rn(Ys.current),Rn(si.current),xo(e)){if(i=e.stateNode,r=e.memoizedProps,i[ri]=e,(a=i.nodeValue!==r)&&(t=Er,t!==null))switch(t.tag){case 3:_o(i.nodeValue,r,(t.mode&1)!==0);break;case 5:t.memoizedProps.suppressHydrationWarning!==!0&&_o(i.nodeValue,r,(t.mode&1)!==0)}a&&(e.flags|=4)}else i=(r.nodeType===9?r:r.ownerDocument).createTextNode(i),i[ri]=e,e.stateNode=i}return Zt(e),null;case 13:if(xt(bt),i=e.memoizedState,t===null||t.memoizedState!==null&&t.memoizedState.dehydrated!==null){if(yt&&br!==null&&e.mode&1&&!(e.flags&128))Fg(),ka(),e.flags|=98560,a=!1;else if(a=xo(e),i!==null&&i.dehydrated!==null){if(t===null){if(!a)throw Error(ce(318));if(a=e.memoizedState,a=a!==null?a.dehydrated:null,!a)throw Error(ce(317));a[ri]=e}else ka(),!(e.flags&128)&&(e.memoizedState=null),e.flags|=4;Zt(e),a=!1}else Wr!==null&&(Sd(Wr),Wr=null),a=!0;if(!a)return e.flags&65536?e:null}return e.flags&128?(e.lanes=r,e):(i=i!==null,i!==(t!==null&&t.memoizedState!==null)&&i&&(e.child.flags|=8192,e.mode&1&&(t===null||bt.current&1?Ot===0&&(Ot=3):yh())),e.updateQueue!==null&&(e.flags|=4),Zt(e),null);case 4:return za(),md(t,e),t===null&&Gs(e.stateNode.containerInfo),Zt(e),null;case 10:return ih(e.type._context),Zt(e),null;case 17:return mr(e.type)&&El(),Zt(e),null;case 19:if(xt(bt),a=e.memoizedState,a===null)return Zt(e),null;if(i=(e.flags&128)!==0,s=a.rendering,s===null)if(i)os(a,!1);else{if(Ot!==0||t!==null&&t.flags&128)for(t=e.child;t!==null;){if(s=Ll(t),s!==null){for(e.flags|=128,os(a,!1),i=s.updateQueue,i!==null&&(e.updateQueue=i,e.flags|=4),e.subtreeFlags=0,i=r,r=e.child;r!==null;)a=r,t=i,a.flags&=14680066,s=a.alternate,s===null?(a.childLanes=0,a.lanes=t,a.child=null,a.subtreeFlags=0,a.memoizedProps=null,a.memoizedState=null,a.updateQueue=null,a.dependencies=null,a.stateNode=null):(a.childLanes=s.childLanes,a.lanes=s.lanes,a.child=s.child,a.subtreeFlags=0,a.deletions=null,a.memoizedProps=s.memoizedProps,a.memoizedState=s.memoizedState,a.updateQueue=s.updateQueue,a.type=s.type,t=s.dependencies,a.dependencies=t===null?null:{lanes:t.lanes,firstContext:t.firstContext}),r=r.sibling;return gt(bt,bt.current&1|2),e.child}t=t.sibling}a.tail!==null&&Ct()>Va&&(e.flags|=128,i=!0,os(a,!1),e.lanes=4194304)}else{if(!i)if(t=Ll(s),t!==null){if(e.flags|=128,i=!0,r=t.updateQueue,r!==null&&(e.updateQueue=r,e.flags|=4),os(a,!0),a.tail===null&&a.tailMode==="hidden"&&!s.alternate&&!yt)return Zt(e),null}else 2*Ct()-a.renderingStartTime>Va&&r!==1073741824&&(e.flags|=128,i=!0,os(a,!1),e.lanes=4194304);a.isBackwards?(s.sibling=e.child,e.child=s):(r=a.last,r!==null?r.sibling=s:e.child=s,a.last=s)}return a.tail!==null?(e=a.tail,a.rendering=e,a.tail=e.sibling,a.renderingStartTime=Ct(),e.sibling=null,r=bt.current,gt(bt,i?r&1|2:r&1),e):(Zt(e),null);case 22:case 23:return xh(),i=e.memoizedState!==null,t!==null&&t.memoizedState!==null!==i&&(e.flags|=8192),i&&e.mode&1?Mr&1073741824&&(Zt(e),e.subtreeFlags&6&&(e.flags|=8192)):Zt(e),null;case 24:return null;case 25:return null}throw Error(ce(156,e.tag))}function Lx(t,e){switch(Jd(e),e.tag){case 1:return mr(e.type)&&El(),t=e.flags,t&65536?(e.flags=t&-65537|128,e):null;case 3:return za(),xt(pr),xt(er),lh(),t=e.flags,t&65536&&!(t&128)?(e.flags=t&-65537|128,e):null;case 5:return oh(e),null;case 13:if(xt(bt),t=e.memoizedState,t!==null&&t.dehydrated!==null){if(e.alternate===null)throw Error(ce(340));ka()}return t=e.flags,t&65536?(e.flags=t&-65537|128,e):null;case 19:return xt(bt),null;case 4:return za(),null;case 10:return ih(e.type._context),null;case 22:case 23:return xh(),null;case 24:return null;default:return null}}var So=!1,Jt=!1,Ux=typeof WeakSet=="function"?WeakSet:Set,ye=null;function Sa(t,e){var r=t.ref;if(r!==null)if(typeof r=="function")try{r(null)}catch(i){Tt(t,e,i)}else r.current=null}function Mv(t,e,r){try{r()}catch(i){Tt(t,e,i)}}var Uf=!1;function Dx(t,e){if(Jc=yl,t=wg(),$d(t)){if("selectionStart"in t)var r={start:t.selectionStart,end:t.selectionEnd};else e:{r=(r=t.ownerDocument)&&r.defaultView||window;var i=r.getSelection&&r.getSelection();if(i&&i.rangeCount!==0){r=i.anchorNode;var n=i.anchorOffset,a=i.focusNode;i=i.focusOffset;try{r.nodeType,a.nodeType}catch{r=null;break e}var s=0,o=-1,l=-1,u=0,h=0,f=t,d=null;t:for(;;){for(var p;f!==r||n!==0&&f.nodeType!==3||(o=s+n),f!==a||i!==0&&f.nodeType!==3||(l=s+i),f.nodeType===3&&(s+=f.nodeValue.length),(p=f.firstChild)!==null;)d=f,f=p;for(;;){if(f===t)break t;if(d===r&&++u===n&&(o=s),d===a&&++h===i&&(l=s),(p=f.nextSibling)!==null)break;f=d,d=f.parentNode}f=p}r=o===-1||l===-1?null:{start:o,end:l}}else r=null}r=r||{start:0,end:0}}else r=null;for(ed={focusedElem:t,selectionRange:r},yl=!1,ye=e;ye!==null;)if(e=ye,t=e.child,(e.subtreeFlags&1028)!==0&&t!==null)t.return=e,ye=t;else for(;ye!==null;){e=ye;try{var _=e.alternate;if(e.flags&1024)switch(e.tag){case 0:case 11:case 15:break;case 1:if(_!==null){var x=_.memoizedProps,m=_.memoizedState,c=e.stateNode,g=c.getSnapshotBeforeUpdate(e.elementType===e.type?x:Vr(e.type,x),m);c.__reactInternalSnapshotBeforeUpdate=g}break;case 3:var v=e.stateNode.containerInfo;v.nodeType===1?v.textContent="":v.nodeType===9&&v.documentElement&&v.removeChild(v.documentElement);break;case 5:case 6:case 4:case 17:break;default:throw Error(ce(163))}}catch(M){Tt(e,e.return,M)}if(t=e.sibling,t!==null){t.return=e.return,ye=t;break}ye=e.return}return _=Uf,Uf=!1,_}function Ls(t,e,r){var i=e.updateQueue;if(i=i!==null?i.lastEffect:null,i!==null){var n=i=i.next;do{if((n.tag&t)===t){var a=n.destroy;n.destroy=void 0,a!==void 0&&Mv(e,r,a)}n=n.next}while(n!==i)}}function au(t,e){if(e=e.updateQueue,e=e!==null?e.lastEffect:null,e!==null){var r=e=e.next;do{if((r.tag&t)===t){var i=r.create;r.destroy=i()}r=r.next}while(r!==e)}}function gd(t){var e=t.ref;if(e!==null){var r=t.stateNode;switch(t.tag){case 5:t=r;break;default:t=r}typeof e=="function"?e(t):e.current=t}}function Sv(t){var e=t.alternate;e!==null&&(t.alternate=null,Sv(e)),t.child=null,t.deletions=null,t.sibling=null,t.tag===5&&(e=t.stateNode,e!==null&&(delete e[ri],delete e[js],delete e[id],delete e[mx],delete e[gx])),t.stateNode=null,t.return=null,t.dependencies=null,t.memoizedProps=null,t.memoizedState=null,t.pendingProps=null,t.stateNode=null,t.updateQueue=null}function bv(t){return t.tag===5||t.tag===3||t.tag===4}function Df(t){e:for(;;){for(;t.sibling===null;){if(t.return===null||bv(t.return))return null;t=t.return}for(t.sibling.return=t.return,t=t.sibling;t.tag!==5&&t.tag!==6&&t.tag!==18;){if(t.flags&2||t.child===null||t.tag===4)continue e;t.child.return=t,t=t.child}if(!(t.flags&2))return t.stateNode}}function vd(t,e,r){var i=t.tag;if(i===5||i===6)t=t.stateNode,e?r.nodeType===8?r.parentNode.insertBefore(t,e):r.insertBefore(t,e):(r.nodeType===8?(e=r.parentNode,e.insertBefore(t,r)):(e=r,e.appendChild(t)),r=r._reactRootContainer,r!=null||e.onclick!==null||(e.onclick=bl));else if(i!==4&&(t=t.child,t!==null))for(vd(t,e,r),t=t.sibling;t!==null;)vd(t,e,r),t=t.sibling}function _d(t,e,r){var i=t.tag;if(i===5||i===6)t=t.stateNode,e?r.insertBefore(t,e):r.appendChild(t);else if(i!==4&&(t=t.child,t!==null))for(_d(t,e,r),t=t.sibling;t!==null;)_d(t,e,r),t=t.sibling}var jt=null,Gr=!1;function Li(t,e,r){for(r=r.child;r!==null;)Ev(t,e,r),r=r.sibling}function Ev(t,e,r){if(ai&&typeof ai.onCommitFiberUnmount=="function")try{ai.onCommitFiberUnmount($l,r)}catch{}switch(r.tag){case 5:Jt||Sa(r,e);case 6:var i=jt,n=Gr;jt=null,Li(t,e,r),jt=i,Gr=n,jt!==null&&(Gr?(t=jt,r=r.stateNode,t.nodeType===8?t.parentNode.removeChild(r):t.removeChild(r)):jt.removeChild(r.stateNode));break;case 18:jt!==null&&(Gr?(t=jt,r=r.stateNode,t.nodeType===8?ku(t.parentNode,r):t.nodeType===1&&ku(t,r),Bs(t)):ku(jt,r.stateNode));break;case 4:i=jt,n=Gr,jt=r.stateNode.containerInfo,Gr=!0,Li(t,e,r),jt=i,Gr=n;break;case 0:case 11:case 14:case 15:if(!Jt&&(i=r.updateQueue,i!==null&&(i=i.lastEffect,i!==null))){n=i=i.next;do{var a=n,s=a.destroy;a=a.tag,s!==void 0&&(a&2||a&4)&&Mv(r,e,s),n=n.next}while(n!==i)}Li(t,e,r);break;case 1:if(!Jt&&(Sa(r,e),i=r.stateNode,typeof i.componentWillUnmount=="function"))try{i.props=r.memoizedProps,i.state=r.memoizedState,i.componentWillUnmount()}catch(o){Tt(r,e,o)}Li(t,e,r);break;case 21:Li(t,e,r);break;case 22:r.mode&1?(Jt=(i=Jt)||r.memoizedState!==null,Li(t,e,r),Jt=i):Li(t,e,r);break;default:Li(t,e,r)}}function If(t){var e=t.updateQueue;if(e!==null){t.updateQueue=null;var r=t.stateNode;r===null&&(r=t.stateNode=new Ux),e.forEach(function(i){var n=Hx.bind(null,t,i);r.has(i)||(r.add(i),i.then(n,n))})}}function kr(t,e){var r=e.deletions;if(r!==null)for(var i=0;i<r.length;i++){var n=r[i];try{var a=t,s=e,o=s;e:for(;o!==null;){switch(o.tag){case 5:jt=o.stateNode,Gr=!1;break e;case 3:jt=o.stateNode.containerInfo,Gr=!0;break e;case 4:jt=o.stateNode.containerInfo,Gr=!0;break e}o=o.return}if(jt===null)throw Error(ce(160));Ev(a,s,n),jt=null,Gr=!1;var l=n.alternate;l!==null&&(l.return=null),n.return=null}catch(u){Tt(n,e,u)}}if(e.subtreeFlags&12854)for(e=e.child;e!==null;)wv(e,t),e=e.sibling}function wv(t,e){var r=t.alternate,i=t.flags;switch(t.tag){case 0:case 11:case 14:case 15:if(kr(e,t),$r(t),i&4){try{Ls(3,t,t.return),au(3,t)}catch(x){Tt(t,t.return,x)}try{Ls(5,t,t.return)}catch(x){Tt(t,t.return,x)}}break;case 1:kr(e,t),$r(t),i&512&&r!==null&&Sa(r,r.return);break;case 5:if(kr(e,t),$r(t),i&512&&r!==null&&Sa(r,r.return),t.flags&32){var n=t.stateNode;try{Os(n,"")}catch(x){Tt(t,t.return,x)}}if(i&4&&(n=t.stateNode,n!=null)){var a=t.memoizedProps,s=r!==null?r.memoizedProps:a,o=t.type,l=t.updateQueue;if(t.updateQueue=null,l!==null)try{o==="input"&&a.type==="radio"&&a.name!=null&&Xm(n,a),Gc(o,s);var u=Gc(o,a);for(s=0;s<l.length;s+=2){var h=l[s],f=l[s+1];h==="style"?$m(n,f):h==="dangerouslySetInnerHTML"?Km(n,f):h==="children"?Os(n,f):Fd(n,h,f,u)}switch(o){case"input":Fc(n,a);break;case"textarea":Ym(n,a);break;case"select":var d=n._wrapperState.wasMultiple;n._wrapperState.wasMultiple=!!a.multiple;var p=a.value;p!=null?wa(n,!!a.multiple,p,!1):d!==!!a.multiple&&(a.defaultValue!=null?wa(n,!!a.multiple,a.defaultValue,!0):wa(n,!!a.multiple,a.multiple?[]:"",!1))}n[js]=a}catch(x){Tt(t,t.return,x)}}break;case 6:if(kr(e,t),$r(t),i&4){if(t.stateNode===null)throw Error(ce(162));n=t.stateNode,a=t.memoizedProps;try{n.nodeValue=a}catch(x){Tt(t,t.return,x)}}break;case 3:if(kr(e,t),$r(t),i&4&&r!==null&&r.memoizedState.isDehydrated)try{Bs(e.containerInfo)}catch(x){Tt(t,t.return,x)}break;case 4:kr(e,t),$r(t);break;case 13:kr(e,t),$r(t),n=t.child,n.flags&8192&&(a=n.memoizedState!==null,n.stateNode.isHidden=a,!a||n.alternate!==null&&n.alternate.memoizedState!==null||(vh=Ct())),i&4&&If(t);break;case 22:if(h=r!==null&&r.memoizedState!==null,t.mode&1?(Jt=(u=Jt)||h,kr(e,t),Jt=u):kr(e,t),$r(t),i&8192){if(u=t.memoizedState!==null,(t.stateNode.isHidden=u)&&!h&&t.mode&1)for(ye=t,h=t.child;h!==null;){for(f=ye=h;ye!==null;){switch(d=ye,p=d.child,d.tag){case 0:case 11:case 14:case 15:Ls(4,d,d.return);break;case 1:Sa(d,d.return);var _=d.stateNode;if(typeof _.componentWillUnmount=="function"){i=d,r=d.return;try{e=i,_.props=e.memoizedProps,_.state=e.memoizedState,_.componentWillUnmount()}catch(x){Tt(i,r,x)}}break;case 5:Sa(d,d.return);break;case 22:if(d.memoizedState!==null){Of(f);continue}}p!==null?(p.return=d,ye=p):Of(f)}h=h.sibling}e:for(h=null,f=t;;){if(f.tag===5){if(h===null){h=f;try{n=f.stateNode,u?(a=n.style,typeof a.setProperty=="function"?a.setProperty("display","none","important"):a.display="none"):(o=f.stateNode,l=f.memoizedProps.style,s=l!=null&&l.hasOwnProperty("display")?l.display:null,o.style.display=Zm("display",s))}catch(x){Tt(t,t.return,x)}}}else if(f.tag===6){if(h===null)try{f.stateNode.nodeValue=u?"":f.memoizedProps}catch(x){Tt(t,t.return,x)}}else if((f.tag!==22&&f.tag!==23||f.memoizedState===null||f===t)&&f.child!==null){f.child.return=f,f=f.child;continue}if(f===t)break e;for(;f.sibling===null;){if(f.return===null||f.return===t)break e;h===f&&(h=null),f=f.return}h===f&&(h=null),f.sibling.return=f.return,f=f.sibling}}break;case 19:kr(e,t),$r(t),i&4&&If(t);break;case 21:break;default:kr(e,t),$r(t)}}function $r(t){var e=t.flags;if(e&2){try{e:{for(var r=t.return;r!==null;){if(bv(r)){var i=r;break e}r=r.return}throw Error(ce(160))}switch(i.tag){case 5:var n=i.stateNode;i.flags&32&&(Os(n,""),i.flags&=-33);var a=Df(t);_d(t,a,n);break;case 3:case 4:var s=i.stateNode.containerInfo,o=Df(t);vd(t,o,s);break;default:throw Error(ce(161))}}catch(l){Tt(t,t.return,l)}t.flags&=-3}e&4096&&(t.flags&=-4097)}function Ix(t,e,r){ye=t,Tv(t)}function Tv(t,e,r){for(var i=(t.mode&1)!==0;ye!==null;){var n=ye,a=n.child;if(n.tag===22&&i){var s=n.memoizedState!==null||So;if(!s){var o=n.alternate,l=o!==null&&o.memoizedState!==null||Jt;o=So;var u=Jt;if(So=s,(Jt=l)&&!u)for(ye=n;ye!==null;)s=ye,l=s.child,s.tag===22&&s.memoizedState!==null?kf(n):l!==null?(l.return=s,ye=l):kf(n);for(;a!==null;)ye=a,Tv(a),a=a.sibling;ye=n,So=o,Jt=u}Nf(t)}else n.subtreeFlags&8772&&a!==null?(a.return=n,ye=a):Nf(t)}}function Nf(t){for(;ye!==null;){var e=ye;if(e.flags&8772){var r=e.alternate;try{if(e.flags&8772)switch(e.tag){case 0:case 11:case 15:Jt||au(5,e);break;case 1:var i=e.stateNode;if(e.flags&4&&!Jt)if(r===null)i.componentDidMount();else{var n=e.elementType===e.type?r.memoizedProps:Vr(e.type,r.memoizedProps);i.componentDidUpdate(n,r.memoizedState,i.__reactInternalSnapshotBeforeUpdate)}var a=e.updateQueue;a!==null&&xf(e,a,i);break;case 3:var s=e.updateQueue;if(s!==null){if(r=null,e.child!==null)switch(e.child.tag){case 5:r=e.child.stateNode;break;case 1:r=e.child.stateNode}xf(e,s,r)}break;case 5:var o=e.stateNode;if(r===null&&e.flags&4){r=o;var l=e.memoizedProps;switch(e.type){case"button":case"input":case"select":case"textarea":l.autoFocus&&r.focus();break;case"img":l.src&&(r.src=l.src)}}break;case 6:break;case 4:break;case 12:break;case 13:if(e.memoizedState===null){var u=e.alternate;if(u!==null){var h=u.memoizedState;if(h!==null){var f=h.dehydrated;f!==null&&Bs(f)}}}break;case 19:case 17:case 21:case 22:case 23:case 25:break;default:throw Error(ce(163))}Jt||e.flags&512&&gd(e)}catch(d){Tt(e,e.return,d)}}if(e===t){ye=null;break}if(r=e.sibling,r!==null){r.return=e.return,ye=r;break}ye=e.return}}function Of(t){for(;ye!==null;){var e=ye;if(e===t){ye=null;break}var r=e.sibling;if(r!==null){r.return=e.return,ye=r;break}ye=e.return}}function kf(t){for(;ye!==null;){var e=ye;try{switch(e.tag){case 0:case 11:case 15:var r=e.return;try{au(4,e)}catch(l){Tt(e,r,l)}break;case 1:var i=e.stateNode;if(typeof i.componentDidMount=="function"){var n=e.return;try{i.componentDidMount()}catch(l){Tt(e,n,l)}}var a=e.return;try{gd(e)}catch(l){Tt(e,a,l)}break;case 5:var s=e.return;try{gd(e)}catch(l){Tt(e,s,l)}}}catch(l){Tt(e,e.return,l)}if(e===t){ye=null;break}var o=e.sibling;if(o!==null){o.return=e.return,ye=o;break}ye=e.return}}var Nx=Math.ceil,Il=Ri.ReactCurrentDispatcher,mh=Ri.ReactCurrentOwner,Dr=Ri.ReactCurrentBatchConfig,it=0,Ht=null,Dt=null,Xt=0,Mr=0,ba=dn(0),Ot=0,$s=null,kn=0,su=0,gh=0,Us=null,dr=null,vh=0,Va=1/0,mi=null,Nl=!1,xd=null,Ji=null,bo=!1,Yi=null,Ol=0,Ds=0,yd=null,cl=-1,dl=0;function ar(){return it&6?Ct():cl!==-1?cl:cl=Ct()}function en(t){return t.mode&1?it&2&&Xt!==0?Xt&-Xt:_x.transition!==null?(dl===0&&(dl=ug()),dl):(t=ct,t!==0||(t=window.event,t=t===void 0?16:gg(t.type)),t):1}function qr(t,e,r,i){if(50<Ds)throw Ds=0,yd=null,Error(ce(185));eo(t,r,i),(!(it&2)||t!==Ht)&&(t===Ht&&(!(it&2)&&(su|=r),Ot===4&&Wi(t,Xt)),gr(t,i),r===1&&it===0&&!(e.mode&1)&&(Va=Ct()+500,ru&&hn()))}function gr(t,e){var r=t.callbackNode;_0(t,e);var i=xl(t,t===Ht?Xt:0);if(i===0)r!==null&&jh(r),t.callbackNode=null,t.callbackPriority=0;else if(e=i&-i,t.callbackPriority!==e){if(r!=null&&jh(r),e===1)t.tag===0?vx(Ff.bind(null,t)):Ng(Ff.bind(null,t)),fx(function(){!(it&6)&&hn()}),r=null;else{switch(cg(i)){case 1:r=Gd;break;case 4:r=og;break;case 16:r=_l;break;case 536870912:r=lg;break;default:r=_l}r=Iv(r,Av.bind(null,t))}t.callbackPriority=e,t.callbackNode=r}}function Av(t,e){if(cl=-1,dl=0,it&6)throw Error(ce(327));var r=t.callbackNode;if(Pa()&&t.callbackNode!==r)return null;var i=xl(t,t===Ht?Xt:0);if(i===0)return null;if(i&30||i&t.expiredLanes||e)e=kl(t,i);else{e=i;var n=it;it|=2;var a=Rv();(Ht!==t||Xt!==e)&&(mi=null,Va=Ct()+500,Un(t,e));do try{Fx();break}catch(o){Cv(t,o)}while(!0);rh(),Il.current=a,it=n,Dt!==null?e=0:(Ht=null,Xt=0,e=Ot)}if(e!==0){if(e===2&&(n=qc(t),n!==0&&(i=n,e=Md(t,n))),e===1)throw r=$s,Un(t,0),Wi(t,i),gr(t,Ct()),r;if(e===6)Wi(t,i);else{if(n=t.current.alternate,!(i&30)&&!Ox(n)&&(e=kl(t,i),e===2&&(a=qc(t),a!==0&&(i=a,e=Md(t,a))),e===1))throw r=$s,Un(t,0),Wi(t,i),gr(t,Ct()),r;switch(t.finishedWork=n,t.finishedLanes=i,e){case 0:case 1:throw Error(ce(345));case 2:bn(t,dr,mi);break;case 3:if(Wi(t,i),(i&130023424)===i&&(e=vh+500-Ct(),10<e)){if(xl(t,0)!==0)break;if(n=t.suspendedLanes,(n&i)!==i){ar(),t.pingedLanes|=t.suspendedLanes&n;break}t.timeoutHandle=rd(bn.bind(null,t,dr,mi),e);break}bn(t,dr,mi);break;case 4:if(Wi(t,i),(i&4194240)===i)break;for(e=t.eventTimes,n=-1;0<i;){var s=31-Yr(i);a=1<<s,s=e[s],s>n&&(n=s),i&=~a}if(i=n,i=Ct()-i,i=(120>i?120:480>i?480:1080>i?1080:1920>i?1920:3e3>i?3e3:4320>i?4320:1960*Nx(i/1960))-i,10<i){t.timeoutHandle=rd(bn.bind(null,t,dr,mi),i);break}bn(t,dr,mi);break;case 5:bn(t,dr,mi);break;default:throw Error(ce(329))}}}return gr(t,Ct()),t.callbackNode===r?Av.bind(null,t):null}function Md(t,e){var r=Us;return t.current.memoizedState.isDehydrated&&(Un(t,e).flags|=256),t=kl(t,e),t!==2&&(e=dr,dr=r,e!==null&&Sd(e)),t}function Sd(t){dr===null?dr=t:dr.push.apply(dr,t)}function Ox(t){for(var e=t;;){if(e.flags&16384){var r=e.updateQueue;if(r!==null&&(r=r.stores,r!==null))for(var i=0;i<r.length;i++){var n=r[i],a=n.getSnapshot;n=n.value;try{if(!Zr(a(),n))return!1}catch{return!1}}}if(r=e.child,e.subtreeFlags&16384&&r!==null)r.return=e,e=r;else{if(e===t)break;for(;e.sibling===null;){if(e.return===null||e.return===t)return!0;e=e.return}e.sibling.return=e.return,e=e.sibling}}return!0}function Wi(t,e){for(e&=~gh,e&=~su,t.suspendedLanes|=e,t.pingedLanes&=~e,t=t.expirationTimes;0<e;){var r=31-Yr(e),i=1<<r;t[r]=-1,e&=~i}}function Ff(t){if(it&6)throw Error(ce(327));Pa();var e=xl(t,0);if(!(e&1))return gr(t,Ct()),null;var r=kl(t,e);if(t.tag!==0&&r===2){var i=qc(t);i!==0&&(e=i,r=Md(t,i))}if(r===1)throw r=$s,Un(t,0),Wi(t,e),gr(t,Ct()),r;if(r===6)throw Error(ce(345));return t.finishedWork=t.current.alternate,t.finishedLanes=e,bn(t,dr,mi),gr(t,Ct()),null}function _h(t,e){var r=it;it|=1;try{return t(e)}finally{it=r,it===0&&(Va=Ct()+500,ru&&hn())}}function Fn(t){Yi!==null&&Yi.tag===0&&!(it&6)&&Pa();var e=it;it|=1;var r=Dr.transition,i=ct;try{if(Dr.transition=null,ct=1,t)return t()}finally{ct=i,Dr.transition=r,it=e,!(it&6)&&hn()}}function xh(){Mr=ba.current,xt(ba)}function Un(t,e){t.finishedWork=null,t.finishedLanes=0;var r=t.timeoutHandle;if(r!==-1&&(t.timeoutHandle=-1,hx(r)),Dt!==null)for(r=Dt.return;r!==null;){var i=r;switch(Jd(i),i.tag){case 1:i=i.type.childContextTypes,i!=null&&El();break;case 3:za(),xt(pr),xt(er),lh();break;case 5:oh(i);break;case 4:za();break;case 13:xt(bt);break;case 19:xt(bt);break;case 10:ih(i.type._context);break;case 22:case 23:xh()}r=r.return}if(Ht=t,Dt=t=tn(t.current,null),Xt=Mr=e,Ot=0,$s=null,gh=su=kn=0,dr=Us=null,Cn!==null){for(e=0;e<Cn.length;e++)if(r=Cn[e],i=r.interleaved,i!==null){r.interleaved=null;var n=i.next,a=r.pending;if(a!==null){var s=a.next;a.next=n,i.next=s}r.pending=i}Cn=null}return t}function Cv(t,e){do{var r=Dt;try{if(rh(),ol.current=Dl,Ul){for(var i=Et.memoizedState;i!==null;){var n=i.queue;n!==null&&(n.pending=null),i=i.next}Ul=!1}if(On=0,Vt=Nt=Et=null,Ps=!1,qs=0,mh.current=null,r===null||r.return===null){Ot=1,$s=e,Dt=null;break}e:{var a=t,s=r.return,o=r,l=e;if(e=Xt,o.flags|=32768,l!==null&&typeof l=="object"&&typeof l.then=="function"){var u=l,h=o,f=h.tag;if(!(h.mode&1)&&(f===0||f===11||f===15)){var d=h.alternate;d?(h.updateQueue=d.updateQueue,h.memoizedState=d.memoizedState,h.lanes=d.lanes):(h.updateQueue=null,h.memoizedState=null)}var p=wf(s);if(p!==null){p.flags&=-257,Tf(p,s,o,a,e),p.mode&1&&Ef(a,u,e),e=p,l=u;var _=e.updateQueue;if(_===null){var x=new Set;x.add(l),e.updateQueue=x}else _.add(l);break e}else{if(!(e&1)){Ef(a,u,e),yh();break e}l=Error(ce(426))}}else if(yt&&o.mode&1){var m=wf(s);if(m!==null){!(m.flags&65536)&&(m.flags|=256),Tf(m,s,o,a,e),eh(Ba(l,o));break e}}a=l=Ba(l,o),Ot!==4&&(Ot=2),Us===null?Us=[a]:Us.push(a),a=s;do{switch(a.tag){case 3:a.flags|=65536,e&=-e,a.lanes|=e;var c=cv(a,l,e);_f(a,c);break e;case 1:o=l;var g=a.type,v=a.stateNode;if(!(a.flags&128)&&(typeof g.getDerivedStateFromError=="function"||v!==null&&typeof v.componentDidCatch=="function"&&(Ji===null||!Ji.has(v)))){a.flags|=65536,e&=-e,a.lanes|=e;var M=dv(a,o,e);_f(a,M);break e}}a=a.return}while(a!==null)}Lv(r)}catch(P){e=P,Dt===r&&r!==null&&(Dt=r=r.return);continue}break}while(!0)}function Rv(){var t=Il.current;return Il.current=Dl,t===null?Dl:t}function yh(){(Ot===0||Ot===3||Ot===2)&&(Ot=4),Ht===null||!(kn&268435455)&&!(su&268435455)||Wi(Ht,Xt)}function kl(t,e){var r=it;it|=2;var i=Rv();(Ht!==t||Xt!==e)&&(mi=null,Un(t,e));do try{kx();break}catch(n){Cv(t,n)}while(!0);if(rh(),it=r,Il.current=i,Dt!==null)throw Error(ce(261));return Ht=null,Xt=0,Ot}function kx(){for(;Dt!==null;)Pv(Dt)}function Fx(){for(;Dt!==null&&!u0();)Pv(Dt)}function Pv(t){var e=Dv(t.alternate,t,Mr);t.memoizedProps=t.pendingProps,e===null?Lv(t):Dt=e,mh.current=null}function Lv(t){var e=t;do{var r=e.alternate;if(t=e.return,e.flags&32768){if(r=Lx(r,e),r!==null){r.flags&=32767,Dt=r;return}if(t!==null)t.flags|=32768,t.subtreeFlags=0,t.deletions=null;else{Ot=6,Dt=null;return}}else if(r=Px(r,e,Mr),r!==null){Dt=r;return}if(e=e.sibling,e!==null){Dt=e;return}Dt=e=t}while(e!==null);Ot===0&&(Ot=5)}function bn(t,e,r){var i=ct,n=Dr.transition;try{Dr.transition=null,ct=1,zx(t,e,r,i)}finally{Dr.transition=n,ct=i}return null}function zx(t,e,r,i){do Pa();while(Yi!==null);if(it&6)throw Error(ce(327));r=t.finishedWork;var n=t.finishedLanes;if(r===null)return null;if(t.finishedWork=null,t.finishedLanes=0,r===t.current)throw Error(ce(177));t.callbackNode=null,t.callbackPriority=0;var a=r.lanes|r.childLanes;if(x0(t,a),t===Ht&&(Dt=Ht=null,Xt=0),!(r.subtreeFlags&2064)&&!(r.flags&2064)||bo||(bo=!0,Iv(_l,function(){return Pa(),null})),a=(r.flags&15990)!==0,r.subtreeFlags&15990||a){a=Dr.transition,Dr.transition=null;var s=ct;ct=1;var o=it;it|=4,mh.current=null,Dx(t,r),wv(r,t),ax(ed),yl=!!Jc,ed=Jc=null,t.current=r,Ix(r),c0(),it=o,ct=s,Dr.transition=a}else t.current=r;if(bo&&(bo=!1,Yi=t,Ol=n),a=t.pendingLanes,a===0&&(Ji=null),f0(r.stateNode),gr(t,Ct()),e!==null)for(i=t.onRecoverableError,r=0;r<e.length;r++)n=e[r],i(n.value,{componentStack:n.stack,digest:n.digest});if(Nl)throw Nl=!1,t=xd,xd=null,t;return Ol&1&&t.tag!==0&&Pa(),a=t.pendingLanes,a&1?t===yd?Ds++:(Ds=0,yd=t):Ds=0,hn(),null}function Pa(){if(Yi!==null){var t=cg(Ol),e=Dr.transition,r=ct;try{if(Dr.transition=null,ct=16>t?16:t,Yi===null)var i=!1;else{if(t=Yi,Yi=null,Ol=0,it&6)throw Error(ce(331));var n=it;for(it|=4,ye=t.current;ye!==null;){var a=ye,s=a.child;if(ye.flags&16){var o=a.deletions;if(o!==null){for(var l=0;l<o.length;l++){var u=o[l];for(ye=u;ye!==null;){var h=ye;switch(h.tag){case 0:case 11:case 15:Ls(8,h,a)}var f=h.child;if(f!==null)f.return=h,ye=f;else for(;ye!==null;){h=ye;var d=h.sibling,p=h.return;if(Sv(h),h===u){ye=null;break}if(d!==null){d.return=p,ye=d;break}ye=p}}}var _=a.alternate;if(_!==null){var x=_.child;if(x!==null){_.child=null;do{var m=x.sibling;x.sibling=null,x=m}while(x!==null)}}ye=a}}if(a.subtreeFlags&2064&&s!==null)s.return=a,ye=s;else e:for(;ye!==null;){if(a=ye,a.flags&2048)switch(a.tag){case 0:case 11:case 15:Ls(9,a,a.return)}var c=a.sibling;if(c!==null){c.return=a.return,ye=c;break e}ye=a.return}}var g=t.current;for(ye=g;ye!==null;){s=ye;var v=s.child;if(s.subtreeFlags&2064&&v!==null)v.return=s,ye=v;else e:for(s=g;ye!==null;){if(o=ye,o.flags&2048)try{switch(o.tag){case 0:case 11:case 15:au(9,o)}}catch(P){Tt(o,o.return,P)}if(o===s){ye=null;break e}var M=o.sibling;if(M!==null){M.return=o.return,ye=M;break e}ye=o.return}}if(it=n,hn(),ai&&typeof ai.onPostCommitFiberRoot=="function")try{ai.onPostCommitFiberRoot($l,t)}catch{}i=!0}return i}finally{ct=r,Dr.transition=e}}return!1}function zf(t,e,r){e=Ba(r,e),e=cv(t,e,1),t=Qi(t,e,1),e=ar(),t!==null&&(eo(t,1,e),gr(t,e))}function Tt(t,e,r){if(t.tag===3)zf(t,t,r);else for(;e!==null;){if(e.tag===3){zf(e,t,r);break}else if(e.tag===1){var i=e.stateNode;if(typeof e.type.getDerivedStateFromError=="function"||typeof i.componentDidCatch=="function"&&(Ji===null||!Ji.has(i))){t=Ba(r,t),t=dv(e,t,1),e=Qi(e,t,1),t=ar(),e!==null&&(eo(e,1,t),gr(e,t));break}}e=e.return}}function Bx(t,e,r){var i=t.pingCache;i!==null&&i.delete(e),e=ar(),t.pingedLanes|=t.suspendedLanes&r,Ht===t&&(Xt&r)===r&&(Ot===4||Ot===3&&(Xt&130023424)===Xt&&500>Ct()-vh?Un(t,0):gh|=r),gr(t,e)}function Uv(t,e){e===0&&(t.mode&1?(e=fo,fo<<=1,!(fo&130023424)&&(fo=4194304)):e=1);var r=ar();t=Ai(t,e),t!==null&&(eo(t,e,r),gr(t,r))}function Vx(t){var e=t.memoizedState,r=0;e!==null&&(r=e.retryLane),Uv(t,r)}function Hx(t,e){var r=0;switch(t.tag){case 13:var i=t.stateNode,n=t.memoizedState;n!==null&&(r=n.retryLane);break;case 19:i=t.stateNode;break;default:throw Error(ce(314))}i!==null&&i.delete(e),Uv(t,r)}var Dv;Dv=function(t,e,r){if(t!==null)if(t.memoizedProps!==e.pendingProps||pr.current)hr=!0;else{if(!(t.lanes&r)&&!(e.flags&128))return hr=!1,Rx(t,e,r);hr=!!(t.flags&131072)}else hr=!1,yt&&e.flags&1048576&&Og(e,Al,e.index);switch(e.lanes=0,e.tag){case 2:var i=e.type;ul(t,e),t=e.pendingProps;var n=Oa(e,er.current);Ra(e,r),n=ch(null,e,i,t,n,r);var a=dh();return e.flags|=1,typeof n=="object"&&n!==null&&typeof n.render=="function"&&n.$$typeof===void 0?(e.tag=1,e.memoizedState=null,e.updateQueue=null,mr(i)?(a=!0,wl(e)):a=!1,e.memoizedState=n.state!==null&&n.state!==void 0?n.state:null,ah(e),n.updater=nu,e.stateNode=n,n._reactInternals=e,ud(e,i,t,r),e=hd(null,e,i,!0,a,r)):(e.tag=0,yt&&a&&Qd(e),ir(null,e,n,r),e=e.child),e;case 16:i=e.elementType;e:{switch(ul(t,e),t=e.pendingProps,n=i._init,i=n(i._payload),e.type=i,n=e.tag=Wx(i),t=Vr(i,t),n){case 0:e=dd(null,e,i,t,r);break e;case 1:e=Rf(null,e,i,t,r);break e;case 11:e=Af(null,e,i,t,r);break e;case 14:e=Cf(null,e,i,Vr(i.type,t),r);break e}throw Error(ce(306,i,""))}return e;case 0:return i=e.type,n=e.pendingProps,n=e.elementType===i?n:Vr(i,n),dd(t,e,i,n,r);case 1:return i=e.type,n=e.pendingProps,n=e.elementType===i?n:Vr(i,n),Rf(t,e,i,n,r);case 3:e:{if(mv(e),t===null)throw Error(ce(387));i=e.pendingProps,a=e.memoizedState,n=a.element,Hg(t,e),Pl(e,i,null,r);var s=e.memoizedState;if(i=s.element,a.isDehydrated)if(a={element:i,isDehydrated:!1,cache:s.cache,pendingSuspenseBoundaries:s.pendingSuspenseBoundaries,transitions:s.transitions},e.updateQueue.baseState=a,e.memoizedState=a,e.flags&256){n=Ba(Error(ce(423)),e),e=Pf(t,e,i,r,n);break e}else if(i!==n){n=Ba(Error(ce(424)),e),e=Pf(t,e,i,r,n);break e}else for(br=$i(e.stateNode.containerInfo.firstChild),Er=e,yt=!0,Wr=null,r=Bg(e,null,i,r),e.child=r;r;)r.flags=r.flags&-3|4096,r=r.sibling;else{if(ka(),i===n){e=Ci(t,e,r);break e}ir(t,e,i,r)}e=e.child}return e;case 5:return Gg(e),t===null&&sd(e),i=e.type,n=e.pendingProps,a=t!==null?t.memoizedProps:null,s=n.children,td(i,n)?s=null:a!==null&&td(i,a)&&(e.flags|=32),pv(t,e),ir(t,e,s,r),e.child;case 6:return t===null&&sd(e),null;case 13:return gv(t,e,r);case 4:return sh(e,e.stateNode.containerInfo),i=e.pendingProps,t===null?e.child=Fa(e,null,i,r):ir(t,e,i,r),e.child;case 11:return i=e.type,n=e.pendingProps,n=e.elementType===i?n:Vr(i,n),Af(t,e,i,n,r);case 7:return ir(t,e,e.pendingProps,r),e.child;case 8:return ir(t,e,e.pendingProps.children,r),e.child;case 12:return ir(t,e,e.pendingProps.children,r),e.child;case 10:e:{if(i=e.type._context,n=e.pendingProps,a=e.memoizedProps,s=n.value,gt(Cl,i._currentValue),i._currentValue=s,a!==null)if(Zr(a.value,s)){if(a.children===n.children&&!pr.current){e=Ci(t,e,r);break e}}else for(a=e.child,a!==null&&(a.return=e);a!==null;){var o=a.dependencies;if(o!==null){s=a.child;for(var l=o.firstContext;l!==null;){if(l.context===i){if(a.tag===1){l=Ei(-1,r&-r),l.tag=2;var u=a.updateQueue;if(u!==null){u=u.shared;var h=u.pending;h===null?l.next=l:(l.next=h.next,h.next=l),u.pending=l}}a.lanes|=r,l=a.alternate,l!==null&&(l.lanes|=r),od(a.return,r,e),o.lanes|=r;break}l=l.next}}else if(a.tag===10)s=a.type===e.type?null:a.child;else if(a.tag===18){if(s=a.return,s===null)throw Error(ce(341));s.lanes|=r,o=s.alternate,o!==null&&(o.lanes|=r),od(s,r,e),s=a.sibling}else s=a.child;if(s!==null)s.return=a;else for(s=a;s!==null;){if(s===e){s=null;break}if(a=s.sibling,a!==null){a.return=s.return,s=a;break}s=s.return}a=s}ir(t,e,n.children,r),e=e.child}return e;case 9:return n=e.type,i=e.pendingProps.children,Ra(e,r),n=Ir(n),i=i(n),e.flags|=1,ir(t,e,i,r),e.child;case 14:return i=e.type,n=Vr(i,e.pendingProps),n=Vr(i.type,n),Cf(t,e,i,n,r);case 15:return hv(t,e,e.type,e.pendingProps,r);case 17:return i=e.type,n=e.pendingProps,n=e.elementType===i?n:Vr(i,n),ul(t,e),e.tag=1,mr(i)?(t=!0,wl(e)):t=!1,Ra(e,r),uv(e,i,n),ud(e,i,n,r),hd(null,e,i,!0,t,r);case 19:return vv(t,e,r);case 22:return fv(t,e,r)}throw Error(ce(156,e.tag))};function Iv(t,e){return sg(t,e)}function Gx(t,e,r,i){this.tag=t,this.key=r,this.sibling=this.child=this.return=this.stateNode=this.type=this.elementType=null,this.index=0,this.ref=null,this.pendingProps=e,this.dependencies=this.memoizedState=this.updateQueue=this.memoizedProps=null,this.mode=i,this.subtreeFlags=this.flags=0,this.deletions=null,this.childLanes=this.lanes=0,this.alternate=null}function Ur(t,e,r,i){return new Gx(t,e,r,i)}function Mh(t){return t=t.prototype,!(!t||!t.isReactComponent)}function Wx(t){if(typeof t=="function")return Mh(t)?1:0;if(t!=null){if(t=t.$$typeof,t===Bd)return 11;if(t===Vd)return 14}return 2}function tn(t,e){var r=t.alternate;return r===null?(r=Ur(t.tag,e,t.key,t.mode),r.elementType=t.elementType,r.type=t.type,r.stateNode=t.stateNode,r.alternate=t,t.alternate=r):(r.pendingProps=e,r.type=t.type,r.flags=0,r.subtreeFlags=0,r.deletions=null),r.flags=t.flags&14680064,r.childLanes=t.childLanes,r.lanes=t.lanes,r.child=t.child,r.memoizedProps=t.memoizedProps,r.memoizedState=t.memoizedState,r.updateQueue=t.updateQueue,e=t.dependencies,r.dependencies=e===null?null:{lanes:e.lanes,firstContext:e.firstContext},r.sibling=t.sibling,r.index=t.index,r.ref=t.ref,r}function hl(t,e,r,i,n,a){var s=2;if(i=t,typeof t=="function")Mh(t)&&(s=1);else if(typeof t=="string")s=5;else e:switch(t){case fa:return Dn(r.children,n,a,e);case zd:s=8,n|=8;break;case Dc:return t=Ur(12,r,e,n|2),t.elementType=Dc,t.lanes=a,t;case Ic:return t=Ur(13,r,e,n),t.elementType=Ic,t.lanes=a,t;case Nc:return t=Ur(19,r,e,n),t.elementType=Nc,t.lanes=a,t;case Gm:return ou(r,n,a,e);default:if(typeof t=="object"&&t!==null)switch(t.$$typeof){case Vm:s=10;break e;case Hm:s=9;break e;case Bd:s=11;break e;case Vd:s=14;break e;case Fi:s=16,i=null;break e}throw Error(ce(130,t==null?t:typeof t,""))}return e=Ur(s,r,e,n),e.elementType=t,e.type=i,e.lanes=a,e}function Dn(t,e,r,i){return t=Ur(7,t,i,e),t.lanes=r,t}function ou(t,e,r,i){return t=Ur(22,t,i,e),t.elementType=Gm,t.lanes=r,t.stateNode={isHidden:!1},t}function ju(t,e,r){return t=Ur(6,t,null,e),t.lanes=r,t}function Xu(t,e,r){return e=Ur(4,t.children!==null?t.children:[],t.key,e),e.lanes=r,e.stateNode={containerInfo:t.containerInfo,pendingChildren:null,implementation:t.implementation},e}function jx(t,e,r,i,n){this.tag=e,this.containerInfo=t,this.finishedWork=this.pingCache=this.current=this.pendingChildren=null,this.timeoutHandle=-1,this.callbackNode=this.pendingContext=this.context=null,this.callbackPriority=0,this.eventTimes=Tu(0),this.expirationTimes=Tu(-1),this.entangledLanes=this.finishedLanes=this.mutableReadLanes=this.expiredLanes=this.pingedLanes=this.suspendedLanes=this.pendingLanes=0,this.entanglements=Tu(0),this.identifierPrefix=i,this.onRecoverableError=n,this.mutableSourceEagerHydrationData=null}function Sh(t,e,r,i,n,a,s,o,l){return t=new jx(t,e,r,o,l),e===1?(e=1,a===!0&&(e|=8)):e=0,a=Ur(3,null,null,e),t.current=a,a.stateNode=t,a.memoizedState={element:i,isDehydrated:r,cache:null,transitions:null,pendingSuspenseBoundaries:null},ah(a),t}function Xx(t,e,r){var i=3<arguments.length&&arguments[3]!==void 0?arguments[3]:null;return{$$typeof:ha,key:i==null?null:""+i,children:t,containerInfo:e,implementation:r}}function Nv(t){if(!t)return sn;t=t._reactInternals;e:{if(Hn(t)!==t||t.tag!==1)throw Error(ce(170));var e=t;do{switch(e.tag){case 3:e=e.stateNode.context;break e;case 1:if(mr(e.type)){e=e.stateNode.__reactInternalMemoizedMergedChildContext;break e}}e=e.return}while(e!==null);throw Error(ce(171))}if(t.tag===1){var r=t.type;if(mr(r))return Ig(t,r,e)}return e}function Ov(t,e,r,i,n,a,s,o,l){return t=Sh(r,i,!0,t,n,a,s,o,l),t.context=Nv(null),r=t.current,i=ar(),n=en(r),a=Ei(i,n),a.callback=e??null,Qi(r,a,n),t.current.lanes=n,eo(t,n,i),gr(t,i),t}function lu(t,e,r,i){var n=e.current,a=ar(),s=en(n);return r=Nv(r),e.context===null?e.context=r:e.pendingContext=r,e=Ei(a,s),e.payload={element:t},i=i===void 0?null:i,i!==null&&(e.callback=i),t=Qi(n,e,s),t!==null&&(qr(t,n,s,a),sl(t,n,s)),s}function Fl(t){if(t=t.current,!t.child)return null;switch(t.child.tag){case 5:return t.child.stateNode;default:return t.child.stateNode}}function Bf(t,e){if(t=t.memoizedState,t!==null&&t.dehydrated!==null){var r=t.retryLane;t.retryLane=r!==0&&r<e?r:e}}function bh(t,e){Bf(t,e),(t=t.alternate)&&Bf(t,e)}function Yx(){return null}var kv=typeof reportError=="function"?reportError:function(t){console.error(t)};function Eh(t){this._internalRoot=t}uu.prototype.render=Eh.prototype.render=function(t){var e=this._internalRoot;if(e===null)throw Error(ce(409));lu(t,e,null,null)};uu.prototype.unmount=Eh.prototype.unmount=function(){var t=this._internalRoot;if(t!==null){this._internalRoot=null;var e=t.containerInfo;Fn(function(){lu(null,t,null,null)}),e[Ti]=null}};function uu(t){this._internalRoot=t}uu.prototype.unstable_scheduleHydration=function(t){if(t){var e=fg();t={blockedOn:null,target:t,priority:e};for(var r=0;r<Gi.length&&e!==0&&e<Gi[r].priority;r++);Gi.splice(r,0,t),r===0&&mg(t)}};function wh(t){return!(!t||t.nodeType!==1&&t.nodeType!==9&&t.nodeType!==11)}function cu(t){return!(!t||t.nodeType!==1&&t.nodeType!==9&&t.nodeType!==11&&(t.nodeType!==8||t.nodeValue!==" react-mount-point-unstable "))}function Vf(){}function qx(t,e,r,i,n){if(n){if(typeof i=="function"){var a=i;i=function(){var u=Fl(s);a.call(u)}}var s=Ov(e,i,t,0,null,!1,!1,"",Vf);return t._reactRootContainer=s,t[Ti]=s.current,Gs(t.nodeType===8?t.parentNode:t),Fn(),s}for(;n=t.lastChild;)t.removeChild(n);if(typeof i=="function"){var o=i;i=function(){var u=Fl(l);o.call(u)}}var l=Sh(t,0,!1,null,null,!1,!1,"",Vf);return t._reactRootContainer=l,t[Ti]=l.current,Gs(t.nodeType===8?t.parentNode:t),Fn(function(){lu(e,l,r,i)}),l}function du(t,e,r,i,n){var a=r._reactRootContainer;if(a){var s=a;if(typeof n=="function"){var o=n;n=function(){var l=Fl(s);o.call(l)}}lu(e,s,t,n)}else s=qx(r,e,t,n,i);return Fl(s)}dg=function(t){switch(t.tag){case 3:var e=t.stateNode;if(e.current.memoizedState.isDehydrated){var r=Ss(e.pendingLanes);r!==0&&(Wd(e,r|1),gr(e,Ct()),!(it&6)&&(Va=Ct()+500,hn()))}break;case 13:Fn(function(){var i=Ai(t,1);if(i!==null){var n=ar();qr(i,t,1,n)}}),bh(t,1)}};jd=function(t){if(t.tag===13){var e=Ai(t,134217728);if(e!==null){var r=ar();qr(e,t,134217728,r)}bh(t,134217728)}};hg=function(t){if(t.tag===13){var e=en(t),r=Ai(t,e);if(r!==null){var i=ar();qr(r,t,e,i)}bh(t,e)}};fg=function(){return ct};pg=function(t,e){var r=ct;try{return ct=t,e()}finally{ct=r}};jc=function(t,e,r){switch(e){case"input":if(Fc(t,r),e=r.name,r.type==="radio"&&e!=null){for(r=t;r.parentNode;)r=r.parentNode;for(r=r.querySelectorAll("input[name="+JSON.stringify(""+e)+'][type="radio"]'),e=0;e<r.length;e++){var i=r[e];if(i!==t&&i.form===t.form){var n=tu(i);if(!n)throw Error(ce(90));jm(i),Fc(i,n)}}}break;case"textarea":Ym(t,r);break;case"select":e=r.value,e!=null&&wa(t,!!r.multiple,e,!1)}};eg=_h;tg=Fn;var Kx={usingClientEntryPoint:!1,Events:[ro,va,tu,Qm,Jm,_h]},ls={findFiberByHostInstance:An,bundleType:0,version:"18.3.1",rendererPackageName:"react-dom"},Zx={bundleType:ls.bundleType,version:ls.version,rendererPackageName:ls.rendererPackageName,rendererConfig:ls.rendererConfig,overrideHookState:null,overrideHookStateDeletePath:null,overrideHookStateRenamePath:null,overrideProps:null,overridePropsDeletePath:null,overridePropsRenamePath:null,setErrorHandler:null,setSuspenseHandler:null,scheduleUpdate:null,currentDispatcherRef:Ri.ReactCurrentDispatcher,findHostInstanceByFiber:function(t){return t=ng(t),t===null?null:t.stateNode},findFiberByHostInstance:ls.findFiberByHostInstance||Yx,findHostInstancesForRefresh:null,scheduleRefresh:null,scheduleRoot:null,setRefreshHandler:null,getCurrentFiber:null,reconcilerVersion:"18.3.1-next-f1338f8080-20240426"};if(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__<"u"){var Eo=__REACT_DEVTOOLS_GLOBAL_HOOK__;if(!Eo.isDisabled&&Eo.supportsFiber)try{$l=Eo.inject(Zx),ai=Eo}catch{}}Tr.__SECRET_INTERNALS_DO_NOT_USE_OR_YOU_WILL_BE_FIRED=Kx;Tr.createPortal=function(t,e){var r=2<arguments.length&&arguments[2]!==void 0?arguments[2]:null;if(!wh(e))throw Error(ce(200));return Xx(t,e,null,r)};Tr.createRoot=function(t,e){if(!wh(t))throw Error(ce(299));var r=!1,i="",n=kv;return e!=null&&(e.unstable_strictMode===!0&&(r=!0),e.identifierPrefix!==void 0&&(i=e.identifierPrefix),e.onRecoverableError!==void 0&&(n=e.onRecoverableError)),e=Sh(t,1,!1,null,null,r,!1,i,n),t[Ti]=e.current,Gs(t.nodeType===8?t.parentNode:t),new Eh(e)};Tr.findDOMNode=function(t){if(t==null)return null;if(t.nodeType===1)return t;var e=t._reactInternals;if(e===void 0)throw typeof t.render=="function"?Error(ce(188)):(t=Object.keys(t).join(","),Error(ce(268,t)));return t=ng(e),t=t===null?null:t.stateNode,t};Tr.flushSync=function(t){return Fn(t)};Tr.hydrate=function(t,e,r){if(!cu(e))throw Error(ce(200));return du(null,t,e,!0,r)};Tr.hydrateRoot=function(t,e,r){if(!wh(t))throw Error(ce(405));var i=r!=null&&r.hydratedSources||null,n=!1,a="",s=kv;if(r!=null&&(r.unstable_strictMode===!0&&(n=!0),r.identifierPrefix!==void 0&&(a=r.identifierPrefix),r.onRecoverableError!==void 0&&(s=r.onRecoverableError)),e=Ov(e,null,t,1,r??null,n,!1,a,s),t[Ti]=e.current,Gs(t),i)for(t=0;t<i.length;t++)r=i[t],n=r._getVersion,n=n(r._source),e.mutableSourceEagerHydrationData==null?e.mutableSourceEagerHydrationData=[r,n]:e.mutableSourceEagerHydrationData.push(r,n);return new uu(e)};Tr.render=function(t,e,r){if(!cu(e))throw Error(ce(200));return du(null,t,e,!1,r)};Tr.unmountComponentAtNode=function(t){if(!cu(t))throw Error(ce(40));return t._reactRootContainer?(Fn(function(){du(null,null,t,!1,function(){t._reactRootContainer=null,t[Ti]=null})}),!0):!1};Tr.unstable_batchedUpdates=_h;Tr.unstable_renderSubtreeIntoContainer=function(t,e,r,i){if(!cu(r))throw Error(ce(200));if(t==null||t._reactInternals===void 0)throw Error(ce(38));return du(t,e,r,!1,i)};Tr.version="18.3.1-next-f1338f8080-20240426";function Fv(){if(!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__>"u"||typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE!="function"))try{__REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(Fv)}catch(t){console.error(t)}}Fv(),km.exports=Tr;var $x=km.exports,zv,Hf=$x;zv=Hf.createRoot,Hf.hydrateRoot;/**
* @license
* Copyright 2010-2024 Three.js Authors
* SPDX-License-Identifier: MIT
*/const Th="165",vi={ROTATE:0,DOLLY:1,PAN:2},Bi={ROTATE:0,PAN:1,DOLLY_PAN:2,DOLLY_ROTATE:3},Qx=0,Gf=1,Jx=2,Bv=1,Vv=2,pi=3,on=0,vr=1,jr=2,rn=0,La=1,Wf=2,jf=3,Xf=4,ey=5,wn=100,ty=101,ry=102,iy=103,ny=104,ay=200,sy=201,oy=202,ly=203,bd=204,Ed=205,uy=206,cy=207,dy=208,hy=209,fy=210,py=211,my=212,gy=213,vy=214,_y=0,xy=1,yy=2,zl=3,My=4,Sy=5,by=6,Ey=7,Hv=0,wy=1,Ty=2,nn=0,Ay=1,Cy=2,Ry=3,Gv=4,Py=5,Ly=6,Uy=7,Wv=300,Ha=301,Ga=302,wd=303,Td=304,hu=306,Ad=1e3,Pn=1001,Cd=1002,fr=1003,Dy=1004,wo=1005,Xr=1006,Yu=1007,Ln=1008,ln=1009,Iy=1010,Ny=1011,Bl=1012,jv=1013,Wa=1014,Mi=1015,fu=1016,Xv=1017,Yv=1018,ja=1020,Oy=35902,ky=1021,Fy=1022,ni=1023,zy=1024,By=1025,Ua=1026,Xa=1027,qv=1028,Kv=1029,Vy=1030,Zv=1031,$v=1033,qu=33776,Ku=33777,Zu=33778,$u=33779,Yf=35840,qf=35841,Kf=35842,Zf=35843,$f=36196,Qf=37492,Jf=37496,ep=37808,tp=37809,rp=37810,ip=37811,np=37812,ap=37813,sp=37814,op=37815,lp=37816,up=37817,cp=37818,dp=37819,hp=37820,fp=37821,Qu=36492,pp=36494,mp=36495,Hy=36283,gp=36284,vp=36285,_p=36286,Gy=3200,Wy=3201,Qv=0,jy=1,ji="",ei="srgb",fn="srgb-linear",Ah="display-p3",pu="display-p3-linear",Vl="linear",_t="srgb",Hl="rec709",Gl="p3",Xn=7680,xp=519,Xy=512,Yy=513,qy=514,Jv=515,Ky=516,Zy=517,$y=518,Qy=519,yp=35044,Ju=35048,Mp="300 es",Si=2e3,Wl=2001;class Gn{addEventListener(e,r){this._listeners===void 0&&(this._listeners={});const i=this._listeners;i[e]===void 0&&(i[e]=[]),i[e].indexOf(r)===-1&&i[e].push(r)}hasEventListener(e,r){if(this._listeners===void 0)return!1;const i=this._listeners;return i[e]!==void 0&&i[e].indexOf(r)!==-1}removeEventListener(e,r){if(this._listeners===void 0)return;const i=this._listeners[e];if(i!==void 0){const n=i.indexOf(r);n!==-1&&i.splice(n,1)}}dispatchEvent(e){if(this._listeners===void 0)return;const r=this._listeners[e.type];if(r!==void 0){e.target=this;const i=r.slice(0);for(let n=0,a=i.length;n<a;n++)i[n].call(this,e);e.target=null}}}const $t=["00","01","02","03","04","05","06","07","08","09","0a","0b","0c","0d","0e","0f","10","11","12","13","14","15","16","17","18","19","1a","1b","1c","1d","1e","1f","20","21","22","23","24","25","26","27","28","29","2a","2b","2c","2d","2e","2f","30","31","32","33","34","35","36","37","38","39","3a","3b","3c","3d","3e","3f","40","41","42","43","44","45","46","47","48","49","4a","4b","4c","4d","4e","4f","50","51","52","53","54","55","56","57","58","59","5a","5b","5c","5d","5e","5f","60","61","62","63","64","65","66","67","68","69","6a","6b","6c","6d","6e","6f","70","71","72","73","74","75","76","77","78","79","7a","7b","7c","7d","7e","7f","80","81","82","83","84","85","86","87","88","89","8a","8b","8c","8d","8e","8f","90","91","92","93","94","95","96","97","98","99","9a","9b","9c","9d","9e","9f","a0","a1","a2","a3","a4","a5","a6","a7","a8","a9","aa","ab","ac","ad","ae","af","b0","b1","b2","b3","b4","b5","b6","b7","b8","b9","ba","bb","bc","bd","be","bf","c0","c1","c2","c3","c4","c5","c6","c7","c8","c9","ca","cb","cc","cd","ce","cf","d0","d1","d2","d3","d4","d5","d6","d7","d8","d9","da","db","dc","dd","de","df","e0","e1","e2","e3","e4","e5","e6","e7","e8","e9","ea","eb","ec","ed","ee","ef","f0","f1","f2","f3","f4","f5","f6","f7","f8","f9","fa","fb","fc","fd","fe","ff"],fl=Math.PI/180,Rd=180/Math.PI;function no(){const t=Math.random()*4294967295|0,e=Math.random()*4294967295|0,r=Math.random()*4294967295|0,i=Math.random()*4294967295|0;return($t[t&255]+$t[t>>8&255]+$t[t>>16&255]+$t[t>>24&255]+"-"+$t[e&255]+$t[e>>8&255]+"-"+$t[e>>16&15|64]+$t[e>>24&255]+"-"+$t[r&63|128]+$t[r>>8&255]+"-"+$t[r>>16&255]+$t[r>>24&255]+$t[i&255]+$t[i>>8&255]+$t[i>>16&255]+$t[i>>24&255]).toLowerCase()}function nr(t,e,r){return Math.max(e,Math.min(r,t))}function Jy(t,e){return(t%e+e)%e}function ec(t,e,r){return(1-r)*t+r*e}function us(t,e){switch(e.constructor){case Float32Array:return t;case Uint32Array:return t/4294967295;case Uint16Array:return t/65535;case Uint8Array:return t/255;case Int32Array:return Math.max(t/2147483647,-1);case Int16Array:return Math.max(t/32767,-1);case Int8Array:return Math.max(t/127,-1);default:throw new Error("Invalid component type.")}}function ur(t,e){switch(e.constructor){case Float32Array:return t;case Uint32Array:return Math.round(t*4294967295);case Uint16Array:return Math.round(t*65535);case Uint8Array:return Math.round(t*255);case Int32Array:return Math.round(t*2147483647);case Int16Array:return Math.round(t*32767);case Int8Array:return Math.round(t*127);default:throw new Error("Invalid component type.")}}const eM={DEG2RAD:fl};class Ne{constructor(e=0,r=0){Ne.prototype.isVector2=!0,this.x=e,this.y=r}get width(){return this.x}set width(e){this.x=e}get height(){return this.y}set height(e){this.y=e}set(e,r){return this.x=e,this.y=r,this}setScalar(e){return this.x=e,this.y=e,this}setX(e){return this.x=e,this}setY(e){return this.y=e,this}setComponent(e,r){switch(e){case 0:this.x=r;break;case 1:this.y=r;break;default:throw new Error("index is out of range: "+e)}return this}getComponent(e){switch(e){case 0:return this.x;case 1:return this.y;default:throw new Error("index is out of range: "+e)}}clone(){return new this.constructor(this.x,this.y)}copy(e){return this.x=e.x,this.y=e.y,this}add(e){return this.x+=e.x,this.y+=e.y,this}addScalar(e){return this.x+=e,this.y+=e,this}addVectors(e,r){return this.x=e.x+r.x,this.y=e.y+r.y,this}addScaledVector(e,r){return this.x+=e.x*r,this.y+=e.y*r,this}sub(e){return this.x-=e.x,this.y-=e.y,this}subScalar(e){return this.x-=e,this.y-=e,this}subVectors(e,r){return this.x=e.x-r.x,this.y=e.y-r.y,this}multiply(e){return this.x*=e.x,this.y*=e.y,this}multiplyScalar(e){return this.x*=e,this.y*=e,this}divide(e){return this.x/=e.x,this.y/=e.y,this}divideScalar(e){return this.multiplyScalar(1/e)}applyMatrix3(e){const r=this.x,i=this.y,n=e.elements;return this.x=n[0]*r+n[3]*i+n[6],this.y=n[1]*r+n[4]*i+n[7],this}min(e){return this.x=Math.min(this.x,e.x),this.y=Math.min(this.y,e.y),this}max(e){return this.x=Math.max(this.x,e.x),this.y=Math.max(this.y,e.y),this}clamp(e,r){return this.x=Math.max(e.x,Math.min(r.x,this.x)),this.y=Math.max(e.y,Math.min(r.y,this.y)),this}clampScalar(e,r){return this.x=Math.max(e,Math.min(r,this.x)),this.y=Math.max(e,Math.min(r,this.y)),this}clampLength(e,r){const i=this.length();return this.divideScalar(i||1).multiplyScalar(Math.max(e,Math.min(r,i)))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this}negate(){return this.x=-this.x,this.y=-this.y,this}dot(e){return this.x*e.x+this.y*e.y}cross(e){return this.x*e.y-this.y*e.x}lengthSq(){return this.x*this.x+this.y*this.y}length(){return Math.sqrt(this.x*this.x+this.y*this.y)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)}normalize(){return this.divideScalar(this.length()||1)}angle(){return Math.atan2(-this.y,-this.x)+Math.PI}angleTo(e){const r=Math.sqrt(this.lengthSq()*e.lengthSq());if(r===0)return Math.PI/2;const i=this.dot(e)/r;return Math.acos(nr(i,-1,1))}distanceTo(e){return Math.sqrt(this.distanceToSquared(e))}distanceToSquared(e){const r=this.x-e.x,i=this.y-e.y;return r*r+i*i}manhattanDistanceTo(e){return Math.abs(this.x-e.x)+Math.abs(this.y-e.y)}setLength(e){return this.normalize().multiplyScalar(e)}lerp(e,r){return this.x+=(e.x-this.x)*r,this.y+=(e.y-this.y)*r,this}lerpVectors(e,r,i){return this.x=e.x+(r.x-e.x)*i,this.y=e.y+(r.y-e.y)*i,this}equals(e){return e.x===this.x&&e.y===this.y}fromArray(e,r=0){return this.x=e[r],this.y=e[r+1],this}toArray(e=[],r=0){return e[r]=this.x,e[r+1]=this.y,e}fromBufferAttribute(e,r){return this.x=e.getX(r),this.y=e.getY(r),this}rotateAround(e,r){const i=Math.cos(r),n=Math.sin(r),a=this.x-e.x,s=this.y-e.y;return this.x=a*i-s*n+e.x,this.y=a*n+s*i+e.y,this}random(){return this.x=Math.random(),this.y=Math.random(),this}*[Symbol.iterator](){yield this.x,yield this.y}}class Ke{constructor(e,r,i,n,a,s,o,l,u){Ke.prototype.isMatrix3=!0,this.elements=[1,0,0,0,1,0,0,0,1],e!==void 0&&this.set(e,r,i,n,a,s,o,l,u)}set(e,r,i,n,a,s,o,l,u){const h=this.elements;return h[0]=e,h[1]=n,h[2]=o,h[3]=r,h[4]=a,h[5]=l,h[6]=i,h[7]=s,h[8]=u,this}identity(){return this.set(1,0,0,0,1,0,0,0,1),this}copy(e){const r=this.elements,i=e.elements;return r[0]=i[0],r[1]=i[1],r[2]=i[2],r[3]=i[3],r[4]=i[4],r[5]=i[5],r[6]=i[6],r[7]=i[7],r[8]=i[8],this}extractBasis(e,r,i){return e.setFromMatrix3Column(this,0),r.setFromMatrix3Column(this,1),i.setFromMatrix3Column(this,2),this}setFromMatrix4(e){const r=e.elements;return this.set(r[0],r[4],r[8],r[1],r[5],r[9],r[2],r[6],r[10]),this}multiply(e){return this.multiplyMatrices(this,e)}premultiply(e){return this.multiplyMatrices(e,this)}multiplyMatrices(e,r){const i=e.elements,n=r.elements,a=this.elements,s=i[0],o=i[3],l=i[6],u=i[1],h=i[4],f=i[7],d=i[2],p=i[5],_=i[8],x=n[0],m=n[3],c=n[6],g=n[1],v=n[4],M=n[7],P=n[2],T=n[5],w=n[8];return a[0]=s*x+o*g+l*P,a[3]=s*m+o*v+l*T,a[6]=s*c+o*M+l*w,a[1]=u*x+h*g+f*P,a[4]=u*m+h*v+f*T,a[7]=u*c+h*M+f*w,a[2]=d*x+p*g+_*P,a[5]=d*m+p*v+_*T,a[8]=d*c+p*M+_*w,this}multiplyScalar(e){const r=this.elements;return r[0]*=e,r[3]*=e,r[6]*=e,r[1]*=e,r[4]*=e,r[7]*=e,r[2]*=e,r[5]*=e,r[8]*=e,this}determinant(){const e=this.elements,r=e[0],i=e[1],n=e[2],a=e[3],s=e[4],o=e[5],l=e[6],u=e[7],h=e[8];return r*s*h-r*o*u-i*a*h+i*o*l+n*a*u-n*s*l}invert(){const e=this.elements,r=e[0],i=e[1],n=e[2],a=e[3],s=e[4],o=e[5],l=e[6],u=e[7],h=e[8],f=h*s-o*u,d=o*l-h*a,p=u*a-s*l,_=r*f+i*d+n*p;if(_===0)return this.set(0,0,0,0,0,0,0,0,0);const x=1/_;return e[0]=f*x,e[1]=(n*u-h*i)*x,e[2]=(o*i-n*s)*x,e[3]=d*x,e[4]=(h*r-n*l)*x,e[5]=(n*a-o*r)*x,e[6]=p*x,e[7]=(i*l-u*r)*x,e[8]=(s*r-i*a)*x,this}transpose(){let e;const r=this.elements;return e=r[1],r[1]=r[3],r[3]=e,e=r[2],r[2]=r[6],r[6]=e,e=r[5],r[5]=r[7],r[7]=e,this}getNormalMatrix(e){return this.setFromMatrix4(e).invert().transpose()}transposeIntoArray(e){const r=this.elements;return e[0]=r[0],e[1]=r[3],e[2]=r[6],e[3]=r[1],e[4]=r[4],e[5]=r[7],e[6]=r[2],e[7]=r[5],e[8]=r[8],this}setUvTransform(e,r,i,n,a,s,o){const l=Math.cos(a),u=Math.sin(a);return this.set(i*l,i*u,-i*(l*s+u*o)+s+e,-n*u,n*l,-n*(-u*s+l*o)+o+r,0,0,1),this}scale(e,r){return this.premultiply(tc.makeScale(e,r)),this}rotate(e){return this.premultiply(tc.makeRotation(-e)),this}translate(e,r){return this.premultiply(tc.makeTranslation(e,r)),this}makeTranslation(e,r){return e.isVector2?this.set(1,0,e.x,0,1,e.y,0,0,1):this.set(1,0,e,0,1,r,0,0,1),this}makeRotation(e){const r=Math.cos(e),i=Math.sin(e);return this.set(r,-i,0,i,r,0,0,0,1),this}makeScale(e,r){return this.set(e,0,0,0,r,0,0,0,1),this}equals(e){const r=this.elements,i=e.elements;for(let n=0;n<9;n++)if(r[n]!==i[n])return!1;return!0}fromArray(e,r=0){for(let i=0;i<9;i++)this.elements[i]=e[i+r];return this}toArray(e=[],r=0){const i=this.elements;return e[r]=i[0],e[r+1]=i[1],e[r+2]=i[2],e[r+3]=i[3],e[r+4]=i[4],e[r+5]=i[5],e[r+6]=i[6],e[r+7]=i[7],e[r+8]=i[8],e}clone(){return new this.constructor().fromArray(this.elements)}}const tc=new Ke;function e_(t){for(let e=t.length-1;e>=0;--e)if(t[e]>=65535)return!0;return!1}function jl(t){return document.createElementNS("http://www.w3.org/1999/xhtml",t)}function tM(){const t=jl("canvas");return t.style.display="block",t}const Sp={};function t_(t){t in Sp||(Sp[t]=!0,console.warn(t))}function rM(t,e,r){return new Promise(function(i,n){function a(){switch(t.clientWaitSync(e,t.SYNC_FLUSH_COMMANDS_BIT,0)){case t.WAIT_FAILED:n();break;case t.TIMEOUT_EXPIRED:setTimeout(a,r);break;default:i()}}setTimeout(a,r)})}const bp=new Ke().set(.8224621,.177538,0,.0331941,.9668058,0,.0170827,.0723974,.9105199),Ep=new Ke().set(1.2249401,-.2249404,0,-.0420569,1.0420571,0,-.0196376,-.0786361,1.0982735),To={[fn]:{transfer:Vl,primaries:Hl,toReference:t=>t,fromReference:t=>t},[ei]:{transfer:_t,primaries:Hl,toReference:t=>t.convertSRGBToLinear(),fromReference:t=>t.convertLinearToSRGB()},[pu]:{transfer:Vl,primaries:Gl,toReference:t=>t.applyMatrix3(Ep),fromReference:t=>t.applyMatrix3(bp)},[Ah]:{transfer:_t,primaries:Gl,toReference:t=>t.convertSRGBToLinear().applyMatrix3(Ep),fromReference:t=>t.applyMatrix3(bp).convertLinearToSRGB()}},iM=new Set([fn,pu]),ut={enabled:!0,_workingColorSpace:fn,get workingColorSpace(){return this._workingColorSpace},set workingColorSpace(t){if(!iM.has(t))throw new Error(`Unsupported working color space, "${t}".`);this._workingColorSpace=t},convert:function(t,e,r){if(this.enabled===!1||e===r||!e||!r)return t;const i=To[e].toReference,n=To[r].fromReference;return n(i(t))},fromWorkingColorSpace:function(t,e){return this.convert(t,this._workingColorSpace,e)},toWorkingColorSpace:function(t,e){return this.convert(t,e,this._workingColorSpace)},getPrimaries:function(t){return To[t].primaries},getTransfer:function(t){return t===ji?Vl:To[t].transfer}};function Da(t){return t<.04045?t*.0773993808:Math.pow(t*.9478672986+.0521327014,2.4)}function rc(t){return t<.0031308?t*12.92:1.055*Math.pow(t,.41666)-.055}let Yn;class nM{static getDataURL(e){if(/^data:/i.test(e.src)||typeof HTMLCanvasElement>"u")return e.src;let r;if(e instanceof HTMLCanvasElement)r=e;else{Yn===void 0&&(Yn=jl("canvas")),Yn.width=e.width,Yn.height=e.height;const i=Yn.getContext("2d");e instanceof ImageData?i.putImageData(e,0,0):i.drawImage(e,0,0,e.width,e.height),r=Yn}return r.width>2048||r.height>2048?(console.warn("THREE.ImageUtils.getDataURL: Image converted to jpg for performance reasons",e),r.toDataURL("image/jpeg",.6)):r.toDataURL("image/png")}static sRGBToLinear(e){if(typeof HTMLImageElement<"u"&&e instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&e instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&e instanceof ImageBitmap){const r=jl("canvas");r.width=e.width,r.height=e.height;const i=r.getContext("2d");i.drawImage(e,0,0,e.width,e.height);const n=i.getImageData(0,0,e.width,e.height),a=n.data;for(let s=0;s<a.length;s++)a[s]=Da(a[s]/255)*255;return i.putImageData(n,0,0),r}else if(e.data){const r=e.data.slice(0);for(let i=0;i<r.length;i++)r instanceof Uint8Array||r instanceof Uint8ClampedArray?r[i]=Math.floor(Da(r[i]/255)*255):r[i]=Da(r[i]);return{data:r,width:e.width,height:e.height}}else return console.warn("THREE.ImageUtils.sRGBToLinear(): Unsupported image type. No color space conversion applied."),e}}let aM=0;class r_{constructor(e=null){this.isSource=!0,Object.defineProperty(this,"id",{value:aM++}),this.uuid=no(),this.data=e,this.dataReady=!0,this.version=0}set needsUpdate(e){e===!0&&this.version++}toJSON(e){const r=e===void 0||typeof e=="string";if(!r&&e.images[this.uuid]!==void 0)return e.images[this.uuid];const i={uuid:this.uuid,url:""},n=this.data;if(n!==null){let a;if(Array.isArray(n)){a=[];for(let s=0,o=n.length;s<o;s++)n[s].isDataTexture?a.push(ic(n[s].image)):a.push(ic(n[s]))}else a=ic(n);i.url=a}return r||(e.images[this.uuid]=i),i}}function ic(t){return typeof HTMLImageElement<"u"&&t instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&t instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&t instanceof ImageBitmap?nM.getDataURL(t):t.data?{data:Array.from(t.data),width:t.width,height:t.height,type:t.data.constructor.name}:(console.warn("THREE.Texture: Unable to serialize Texture."),{})}let sM=0;class sr extends Gn{constructor(e=sr.DEFAULT_IMAGE,r=sr.DEFAULT_MAPPING,i=Pn,n=Pn,a=Xr,s=Ln,o=ni,l=ln,u=sr.DEFAULT_ANISOTROPY,h=ji){super(),this.isTexture=!0,Object.defineProperty(this,"id",{value:sM++}),this.uuid=no(),this.name="",this.source=new r_(e),this.mipmaps=[],this.mapping=r,this.channel=0,this.wrapS=i,this.wrapT=n,this.magFilter=a,this.minFilter=s,this.anisotropy=u,this.format=o,this.internalFormat=null,this.type=l,this.offset=new Ne(0,0),this.repeat=new Ne(1,1),this.center=new Ne(0,0),this.rotation=0,this.matrixAutoUpdate=!0,this.matrix=new Ke,this.generateMipmaps=!0,this.premultiplyAlpha=!1,this.flipY=!0,this.unpackAlignment=4,this.colorSpace=h,this.userData={},this.version=0,this.onUpdate=null,this.isRenderTargetTexture=!1,this.pmremVersion=0}get image(){return this.source.data}set image(e=null){this.source.data=e}updateMatrix(){this.matrix.setUvTransform(this.offset.x,this.offset.y,this.repeat.x,this.repeat.y,this.rotation,this.center.x,this.center.y)}clone(){return new this.constructor().copy(this)}copy(e){return this.name=e.name,this.source=e.source,this.mipmaps=e.mipmaps.slice(0),this.mapping=e.mapping,this.channel=e.channel,this.wrapS=e.wrapS,this.wrapT=e.wrapT,this.magFilter=e.magFilter,this.minFilter=e.minFilter,this.anisotropy=e.anisotropy,this.format=e.format,this.internalFormat=e.internalFormat,this.type=e.type,this.offset.copy(e.offset),this.repeat.copy(e.repeat),this.center.copy(e.center),this.rotation=e.rotation,this.matrixAutoUpdate=e.matrixAutoUpdate,this.matrix.copy(e.matrix),this.generateMipmaps=e.generateMipmaps,this.premultiplyAlpha=e.premultiplyAlpha,this.flipY=e.flipY,this.unpackAlignment=e.unpackAlignment,this.colorSpace=e.colorSpace,this.userData=JSON.parse(JSON.stringify(e.userData)),this.needsUpdate=!0,this}toJSON(e){const r=e===void 0||typeof e=="string";if(!r&&e.textures[this.uuid]!==void 0)return e.textures[this.uuid];const i={metadata:{version:4.6,type:"Texture",generator:"Texture.toJSON"},uuid:this.uuid,name:this.name,image:this.source.toJSON(e).uuid,mapping:this.mapping,channel:this.channel,repeat:[this.repeat.x,this.repeat.y],offset:[this.offset.x,this.offset.y],center:[this.center.x,this.center.y],rotation:this.rotation,wrap:[this.wrapS,this.wrapT],format:this.format,internalFormat:this.internalFormat,type:this.type,colorSpace:this.colorSpace,minFilter:this.minFilter,magFilter:this.magFilter,anisotropy:this.anisotropy,flipY:this.flipY,generateMipmaps:this.generateMipmaps,premultiplyAlpha:this.premultiplyAlpha,unpackAlignment:this.unpackAlignment};return Object.keys(this.userData).length>0&&(i.userData=this.userData),r||(e.textures[this.uuid]=i),i}dispose(){this.dispatchEvent({type:"dispose"})}transformUv(e){if(this.mapping!==Wv)return e;if(e.applyMatrix3(this.matrix),e.x<0||e.x>1)switch(this.wrapS){case Ad:e.x=e.x-Math.floor(e.x);break;case Pn:e.x=e.x<0?0:1;break;case Cd:Math.abs(Math.floor(e.x)%2)===1?e.x=Math.ceil(e.x)-e.x:e.x=e.x-Math.floor(e.x);break}if(e.y<0||e.y>1)switch(this.wrapT){case Ad:e.y=e.y-Math.floor(e.y);break;case Pn:e.y=e.y<0?0:1;break;case Cd:Math.abs(Math.floor(e.y)%2)===1?e.y=Math.ceil(e.y)-e.y:e.y=e.y-Math.floor(e.y);break}return this.flipY&&(e.y=1-e.y),e}set needsUpdate(e){e===!0&&(this.version++,this.source.needsUpdate=!0)}set needsPMREMUpdate(e){e===!0&&this.pmremVersion++}}sr.DEFAULT_IMAGE=null;sr.DEFAULT_MAPPING=Wv;sr.DEFAULT_ANISOTROPY=1;class Mt{constructor(e=0,r=0,i=0,n=1){Mt.prototype.isVector4=!0,this.x=e,this.y=r,this.z=i,this.w=n}get width(){return this.z}set width(e){this.z=e}get height(){return this.w}set height(e){this.w=e}set(e,r,i,n){return this.x=e,this.y=r,this.z=i,this.w=n,this}setScalar(e){return this.x=e,this.y=e,this.z=e,this.w=e,this}setX(e){return this.x=e,this}setY(e){return this.y=e,this}setZ(e){return this.z=e,this}setW(e){return this.w=e,this}setComponent(e,r){switch(e){case 0:this.x=r;break;case 1:this.y=r;break;case 2:this.z=r;break;case 3:this.w=r;break;default:throw new Error("index is out of range: "+e)}return this}getComponent(e){switch(e){case 0:return this.x;case 1:return this.y;case 2:return this.z;case 3:return this.w;default:throw new Error("index is out of range: "+e)}}clone(){return new this.constructor(this.x,this.y,this.z,this.w)}copy(e){return this.x=e.x,this.y=e.y,this.z=e.z,this.w=e.w!==void 0?e.w:1,this}add(e){return this.x+=e.x,this.y+=e.y,this.z+=e.z,this.w+=e.w,this}addScalar(e){return this.x+=e,this.y+=e,this.z+=e,this.w+=e,this}addVectors(e,r){return this.x=e.x+r.x,this.y=e.y+r.y,this.z=e.z+r.z,this.w=e.w+r.w,this}addScaledVector(e,r){return this.x+=e.x*r,this.y+=e.y*r,this.z+=e.z*r,this.w+=e.w*r,this}sub(e){return this.x-=e.x,this.y-=e.y,this.z-=e.z,this.w-=e.w,this}subScalar(e){return this.x-=e,this.y-=e,this.z-=e,this.w-=e,this}subVectors(e,r){return this.x=e.x-r.x,this.y=e.y-r.y,this.z=e.z-r.z,this.w=e.w-r.w,this}multiply(e){return this.x*=e.x,this.y*=e.y,this.z*=e.z,this.w*=e.w,this}multiplyScalar(e){return this.x*=e,this.y*=e,this.z*=e,this.w*=e,this}applyMatrix4(e){const r=this.x,i=this.y,n=this.z,a=this.w,s=e.elements;return this.x=s[0]*r+s[4]*i+s[8]*n+s[12]*a,this.y=s[1]*r+s[5]*i+s[9]*n+s[13]*a,this.z=s[2]*r+s[6]*i+s[10]*n+s[14]*a,this.w=s[3]*r+s[7]*i+s[11]*n+s[15]*a,this}divideScalar(e){return this.multiplyScalar(1/e)}setAxisAngleFromQuaternion(e){this.w=2*Math.acos(e.w);const r=Math.sqrt(1-e.w*e.w);return r<1e-4?(this.x=1,this.y=0,this.z=0):(this.x=e.x/r,this.y=e.y/r,this.z=e.z/r),this}setAxisAngleFromRotationMatrix(e){let r,i,n,a;const s=e.elements,o=s[0],l=s[4],u=s[8],h=s[1],f=s[5],d=s[9],p=s[2],_=s[6],x=s[10];if(Math.abs(l-h)<.01&&Math.abs(u-p)<.01&&Math.abs(d-_)<.01){if(Math.abs(l+h)<.1&&Math.abs(u+p)<.1&&Math.abs(d+_)<.1&&Math.abs(o+f+x-3)<.1)return this.set(1,0,0,0),this;r=Math.PI;const c=(o+1)/2,g=(f+1)/2,v=(x+1)/2,M=(l+h)/4,P=(u+p)/4,T=(d+_)/4;return c>g&&c>v?c<.01?(i=0,n=.707106781,a=.707106781):(i=Math.sqrt(c),n=M/i,a=P/i):g>v?g<.01?(i=.707106781,n=0,a=.707106781):(n=Math.sqrt(g),i=M/n,a=T/n):v<.01?(i=.707106781,n=.707106781,a=0):(a=Math.sqrt(v),i=P/a,n=T/a),this.set(i,n,a,r),this}let m=Math.sqrt((_-d)*(_-d)+(u-p)*(u-p)+(h-l)*(h-l));return Math.abs(m)<.001&&(m=1),this.x=(_-d)/m,this.y=(u-p)/m,this.z=(h-l)/m,this.w=Math.acos((o+f+x-1)/2),this}min(e){return this.x=Math.min(this.x,e.x),this.y=Math.min(this.y,e.y),this.z=Math.min(this.z,e.z),this.w=Math.min(this.w,e.w),this}max(e){return this.x=Math.max(this.x,e.x),this.y=Math.max(this.y,e.y),this.z=Math.max(this.z,e.z),this.w=Math.max(this.w,e.w),this}clamp(e,r){return this.x=Math.max(e.x,Math.min(r.x,this.x)),this.y=Math.max(e.y,Math.min(r.y,this.y)),this.z=Math.max(e.z,Math.min(r.z,this.z)),this.w=Math.max(e.w,Math.min(r.w,this.w)),this}clampScalar(e,r){return this.x=Math.max(e,Math.min(r,this.x)),this.y=Math.max(e,Math.min(r,this.y)),this.z=Math.max(e,Math.min(r,this.z)),this.w=Math.max(e,Math.min(r,this.w)),this}clampLength(e,r){const i=this.length();return this.divideScalar(i||1).multiplyScalar(Math.max(e,Math.min(r,i)))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this.z=Math.floor(this.z),this.w=Math.floor(this.w),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this.z=Math.ceil(this.z),this.w=Math.ceil(this.w),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this.z=Math.round(this.z),this.w=Math.round(this.w),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this.z=Math.trunc(this.z),this.w=Math.trunc(this.w),this}negate(){return this.x=-this.x,this.y=-this.y,this.z=-this.z,this.w=-this.w,this}dot(e){return this.x*e.x+this.y*e.y+this.z*e.z+this.w*e.w}lengthSq(){return this.x*this.x+this.y*this.y+this.z*this.z+this.w*this.w}length(){return Math.sqrt(this.x*this.x+this.y*this.y+this.z*this.z+this.w*this.w)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)+Math.abs(this.z)+Math.abs(this.w)}normalize(){return this.divideScalar(this.length()||1)}setLength(e){return this.normalize().multiplyScalar(e)}lerp(e,r){return this.x+=(e.x-this.x)*r,this.y+=(e.y-this.y)*r,this.z+=(e.z-this.z)*r,this.w+=(e.w-this.w)*r,this}lerpVectors(e,r,i){return this.x=e.x+(r.x-e.x)*i,this.y=e.y+(r.y-e.y)*i,this.z=e.z+(r.z-e.z)*i,this.w=e.w+(r.w-e.w)*i,this}equals(e){return e.x===this.x&&e.y===this.y&&e.z===this.z&&e.w===this.w}fromArray(e,r=0){return this.x=e[r],this.y=e[r+1],this.z=e[r+2],this.w=e[r+3],this}toArray(e=[],r=0){return e[r]=this.x,e[r+1]=this.y,e[r+2]=this.z,e[r+3]=this.w,e}fromBufferAttribute(e,r){return this.x=e.getX(r),this.y=e.getY(r),this.z=e.getZ(r),this.w=e.getW(r),this}random(){return this.x=Math.random(),this.y=Math.random(),this.z=Math.random(),this.w=Math.random(),this}*[Symbol.iterator](){yield this.x,yield this.y,yield this.z,yield this.w}}class oM extends Gn{constructor(e=1,r=1,i={}){super(),this.isRenderTarget=!0,this.width=e,this.height=r,this.depth=1,this.scissor=new Mt(0,0,e,r),this.scissorTest=!1,this.viewport=new Mt(0,0,e,r);const n={width:e,height:r,depth:1};i=Object.assign({generateMipmaps:!1,internalFormat:null,minFilter:Xr,depthBuffer:!0,stencilBuffer:!1,resolveDepthBuffer:!0,resolveStencilBuffer:!0,depthTexture:null,samples:0,count:1},i);const a=new sr(n,i.mapping,i.wrapS,i.wrapT,i.magFilter,i.minFilter,i.format,i.type,i.anisotropy,i.colorSpace);a.flipY=!1,a.generateMipmaps=i.generateMipmaps,a.internalFormat=i.internalFormat,this.textures=[];const s=i.count;for(let o=0;o<s;o++)this.textures[o]=a.clone(),this.textures[o].isRenderTargetTexture=!0;this.depthBuffer=i.depthBuffer,this.stencilBuffer=i.stencilBuffer,this.resolveDepthBuffer=i.resolveDepthBuffer,this.resolveStencilBuffer=i.resolveStencilBuffer,this.depthTexture=i.depthTexture,this.samples=i.samples}get texture(){return this.textures[0]}set texture(e){this.textures[0]=e}setSize(e,r,i=1){if(this.width!==e||this.height!==r||this.depth!==i){this.width=e,this.height=r,this.depth=i;for(let n=0,a=this.textures.length;n<a;n++)this.textures[n].image.width=e,this.textures[n].image.height=r,this.textures[n].image.depth=i;this.dispose()}this.viewport.set(0,0,e,r),this.scissor.set(0,0,e,r)}clone(){return new this.constructor().copy(this)}copy(e){this.width=e.width,this.height=e.height,this.depth=e.depth,this.scissor.copy(e.scissor),this.scissorTest=e.scissorTest,this.viewport.copy(e.viewport),this.textures.length=0;for(let i=0,n=e.textures.length;i<n;i++)this.textures[i]=e.textures[i].clone(),this.textures[i].isRenderTargetTexture=!0;const r=Object.assign({},e.texture.image);return this.texture.source=new r_(r),this.depthBuffer=e.depthBuffer,this.stencilBuffer=e.stencilBuffer,this.resolveDepthBuffer=e.resolveDepthBuffer,this.resolveStencilBuffer=e.resolveStencilBuffer,e.depthTexture!==null&&(this.depthTexture=e.depthTexture.clone()),this.samples=e.samples,this}dispose(){this.dispatchEvent({type:"dispose"})}}class zn extends oM{constructor(e=1,r=1,i={}){super(e,r,i),this.isWebGLRenderTarget=!0}}class i_ extends sr{constructor(e=null,r=1,i=1,n=1){super(null),this.isDataArrayTexture=!0,this.image={data:e,width:r,height:i,depth:n},this.magFilter=fr,this.minFilter=fr,this.wrapR=Pn,this.generateMipmaps=!1,this.flipY=!1,this.unpackAlignment=1,this.layerUpdates=new Set}addLayerUpdate(e){this.layerUpdates.add(e)}clearLayerUpdates(){this.layerUpdates.clear()}}class lM extends sr{constructor(e=null,r=1,i=1,n=1){super(null),this.isData3DTexture=!0,this.image={data:e,width:r,height:i,depth:n},this.magFilter=fr,this.minFilter=fr,this.wrapR=Pn,this.generateMipmaps=!1,this.flipY=!1,this.unpackAlignment=1}}class Bn{constructor(e=0,r=0,i=0,n=1){this.isQuaternion=!0,this._x=e,this._y=r,this._z=i,this._w=n}static slerpFlat(e,r,i,n,a,s,o){let l=i[n+0],u=i[n+1],h=i[n+2],f=i[n+3];const d=a[s+0],p=a[s+1],_=a[s+2],x=a[s+3];if(o===0){e[r+0]=l,e[r+1]=u,e[r+2]=h,e[r+3]=f;return}if(o===1){e[r+0]=d,e[r+1]=p,e[r+2]=_,e[r+3]=x;return}if(f!==x||l!==d||u!==p||h!==_){let m=1-o;const c=l*d+u*p+h*_+f*x,g=c>=0?1:-1,v=1-c*c;if(v>Number.EPSILON){const P=Math.sqrt(v),T=Math.atan2(P,c*g);m=Math.sin(m*T)/P,o=Math.sin(o*T)/P}const M=o*g;if(l=l*m+d*M,u=u*m+p*M,h=h*m+_*M,f=f*m+x*M,m===1-o){const P=1/Math.sqrt(l*l+u*u+h*h+f*f);l*=P,u*=P,h*=P,f*=P}}e[r]=l,e[r+1]=u,e[r+2]=h,e[r+3]=f}static multiplyQuaternionsFlat(e,r,i,n,a,s){const o=i[n],l=i[n+1],u=i[n+2],h=i[n+3],f=a[s],d=a[s+1],p=a[s+2],_=a[s+3];return e[r]=o*_+h*f+l*p-u*d,e[r+1]=l*_+h*d+u*f-o*p,e[r+2]=u*_+h*p+o*d-l*f,e[r+3]=h*_-o*f-l*d-u*p,e}get x(){return this._x}set x(e){this._x=e,this._onChangeCallback()}get y(){return this._y}set y(e){this._y=e,this._onChangeCallback()}get z(){return this._z}set z(e){this._z=e,this._onChangeCallback()}get w(){return this._w}set w(e){this._w=e,this._onChangeCallback()}set(e,r,i,n){return this._x=e,this._y=r,this._z=i,this._w=n,this._onChangeCallback(),this}clone(){return new this.constructor(this._x,this._y,this._z,this._w)}copy(e){return this._x=e.x,this._y=e.y,this._z=e.z,this._w=e.w,this._onChangeCallback(),this}setFromEuler(e,r=!0){const i=e._x,n=e._y,a=e._z,s=e._order,o=Math.cos,l=Math.sin,u=o(i/2),h=o(n/2),f=o(a/2),d=l(i/2),p=l(n/2),_=l(a/2);switch(s){case"XYZ":this._x=d*h*f+u*p*_,this._y=u*p*f-d*h*_,this._z=u*h*_+d*p*f,this._w=u*h*f-d*p*_;break;case"YXZ":this._x=d*h*f+u*p*_,this._y=u*p*f-d*h*_,this._z=u*h*_-d*p*f,this._w=u*h*f+d*p*_;break;case"ZXY":this._x=d*h*f-u*p*_,this._y=u*p*f+d*h*_,this._z=u*h*_+d*p*f,this._w=u*h*f-d*p*_;break;case"ZYX":this._x=d*h*f-u*p*_,this._y=u*p*f+d*h*_,this._z=u*h*_-d*p*f,this._w=u*h*f+d*p*_;break;case"YZX":this._x=d*h*f+u*p*_,this._y=u*p*f+d*h*_,this._z=u*h*_-d*p*f,this._w=u*h*f-d*p*_;break;case"XZY":this._x=d*h*f-u*p*_,this._y=u*p*f-d*h*_,this._z=u*h*_+d*p*f,this._w=u*h*f+d*p*_;break;default:console.warn("THREE.Quaternion: .setFromEuler() encountered an unknown order: "+s)}return r===!0&&this._onChangeCallback(),this}setFromAxisAngle(e,r){const i=r/2,n=Math.sin(i);return this._x=e.x*n,this._y=e.y*n,this._z=e.z*n,this._w=Math.cos(i),this._onChangeCallback(),this}setFromRotationMatrix(e){const r=e.elements,i=r[0],n=r[4],a=r[8],s=r[1],o=r[5],l=r[9],u=r[2],h=r[6],f=r[10],d=i+o+f;if(d>0){const p=.5/Math.sqrt(d+1);this._w=.25/p,this._x=(h-l)*p,this._y=(a-u)*p,this._z=(s-n)*p}else if(i>o&&i>f){const p=2*Math.sqrt(1+i-o-f);this._w=(h-l)/p,this._x=.25*p,this._y=(n+s)/p,this._z=(a+u)/p}else if(o>f){const p=2*Math.sqrt(1+o-i-f);this._w=(a-u)/p,this._x=(n+s)/p,this._y=.25*p,this._z=(l+h)/p}else{const p=2*Math.sqrt(1+f-i-o);this._w=(s-n)/p,this._x=(a+u)/p,this._y=(l+h)/p,this._z=.25*p}return this._onChangeCallback(),this}setFromUnitVectors(e,r){let i=e.dot(r)+1;return i<Number.EPSILON?(i=0,Math.abs(e.x)>Math.abs(e.z)?(this._x=-e.y,this._y=e.x,this._z=0,this._w=i):(this._x=0,this._y=-e.z,this._z=e.y,this._w=i)):(this._x=e.y*r.z-e.z*r.y,this._y=e.z*r.x-e.x*r.z,this._z=e.x*r.y-e.y*r.x,this._w=i),this.normalize()}angleTo(e){return 2*Math.acos(Math.abs(nr(this.dot(e),-1,1)))}rotateTowards(e,r){const i=this.angleTo(e);if(i===0)return this;const n=Math.min(1,r/i);return this.slerp(e,n),this}identity(){return this.set(0,0,0,1)}invert(){return this.conjugate()}conjugate(){return this._x*=-1,this._y*=-1,this._z*=-1,this._onChangeCallback(),this}dot(e){return this._x*e._x+this._y*e._y+this._z*e._z+this._w*e._w}lengthSq(){return this._x*this._x+this._y*this._y+this._z*this._z+this._w*this._w}length(){return Math.sqrt(this._x*this._x+this._y*this._y+this._z*this._z+this._w*this._w)}normalize(){let e=this.length();return e===0?(this._x=0,this._y=0,this._z=0,this._w=1):(e=1/e,this._x=this._x*e,this._y=this._y*e,this._z=this._z*e,this._w=this._w*e),this._onChangeCallback(),this}multiply(e){return this.multiplyQuaternions(this,e)}premultiply(e){return this.multiplyQuaternions(e,this)}multiplyQuaternions(e,r){const i=e._x,n=e._y,a=e._z,s=e._w,o=r._x,l=r._y,u=r._z,h=r._w;return this._x=i*h+s*o+n*u-a*l,this._y=n*h+s*l+a*o-i*u,this._z=a*h+s*u+i*l-n*o,this._w=s*h-i*o-n*l-a*u,this._onChangeCallback(),this}slerp(e,r){if(r===0)return this;if(r===1)return this.copy(e);const i=this._x,n=this._y,a=this._z,s=this._w;let o=s*e._w+i*e._x+n*e._y+a*e._z;if(o<0?(this._w=-e._w,this._x=-e._x,this._y=-e._y,this._z=-e._z,o=-o):this.copy(e),o>=1)return this._w=s,this._x=i,this._y=n,this._z=a,this;const l=1-o*o;if(l<=Number.EPSILON){const p=1-r;return this._w=p*s+r*this._w,this._x=p*i+r*this._x,this._y=p*n+r*this._y,this._z=p*a+r*this._z,this.normalize(),this}const u=Math.sqrt(l),h=Math.atan2(u,o),f=Math.sin((1-r)*h)/u,d=Math.sin(r*h)/u;return this._w=s*f+this._w*d,this._x=i*f+this._x*d,this._y=n*f+this._y*d,this._z=a*f+this._z*d,this._onChangeCallback(),this}slerpQuaternions(e,r,i){return this.copy(e).slerp(r,i)}random(){const e=2*Math.PI*Math.random(),r=2*Math.PI*Math.random(),i=Math.random(),n=Math.sqrt(1-i),a=Math.sqrt(i);return this.set(n*Math.sin(e),n*Math.cos(e),a*Math.sin(r),a*Math.cos(r))}equals(e){return e._x===this._x&&e._y===this._y&&e._z===this._z&&e._w===this._w}fromArray(e,r=0){return this._x=e[r],this._y=e[r+1],this._z=e[r+2],this._w=e[r+3],this._onChangeCallback(),this}toArray(e=[],r=0){return e[r]=this._x,e[r+1]=this._y,e[r+2]=this._z,e[r+3]=this._w,e}fromBufferAttribute(e,r){return this._x=e.getX(r),this._y=e.getY(r),this._z=e.getZ(r),this._w=e.getW(r),this._onChangeCallback(),this}toJSON(){return this.toArray()}_onChange(e){return this._onChangeCallback=e,this}_onChangeCallback(){}*[Symbol.iterator](){yield this._x,yield this._y,yield this._z,yield this._w}}class O{constructor(e=0,r=0,i=0){O.prototype.isVector3=!0,this.x=e,this.y=r,this.z=i}set(e,r,i){return i===void 0&&(i=this.z),this.x=e,this.y=r,this.z=i,this}setScalar(e){return this.x=e,this.y=e,this.z=e,this}setX(e){return this.x=e,this}setY(e){return this.y=e,this}setZ(e){return this.z=e,this}setComponent(e,r){switch(e){case 0:this.x=r;break;case 1:this.y=r;break;case 2:this.z=r;break;default:throw new Error("index is out of range: "+e)}return this}getComponent(e){switch(e){case 0:return this.x;case 1:return this.y;case 2:return this.z;default:throw new Error("index is out of range: "+e)}}clone(){return new this.constructor(this.x,this.y,this.z)}copy(e){return this.x=e.x,this.y=e.y,this.z=e.z,this}add(e){return this.x+=e.x,this.y+=e.y,this.z+=e.z,this}addScalar(e){return this.x+=e,this.y+=e,this.z+=e,this}addVectors(e,r){return this.x=e.x+r.x,this.y=e.y+r.y,this.z=e.z+r.z,this}addScaledVector(e,r){return this.x+=e.x*r,this.y+=e.y*r,this.z+=e.z*r,this}sub(e){return this.x-=e.x,this.y-=e.y,this.z-=e.z,this}subScalar(e){return this.x-=e,this.y-=e,this.z-=e,this}subVectors(e,r){return this.x=e.x-r.x,this.y=e.y-r.y,this.z=e.z-r.z,this}multiply(e){return this.x*=e.x,this.y*=e.y,this.z*=e.z,this}multiplyScalar(e){return this.x*=e,this.y*=e,this.z*=e,this}multiplyVectors(e,r){return this.x=e.x*r.x,this.y=e.y*r.y,this.z=e.z*r.z,this}applyEuler(e){return this.applyQuaternion(wp.setFromEuler(e))}applyAxisAngle(e,r){return this.applyQuaternion(wp.setFromAxisAngle(e,r))}applyMatrix3(e){const r=this.x,i=this.y,n=this.z,a=e.elements;return this.x=a[0]*r+a[3]*i+a[6]*n,this.y=a[1]*r+a[4]*i+a[7]*n,this.z=a[2]*r+a[5]*i+a[8]*n,this}applyNormalMatrix(e){return this.applyMatrix3(e).normalize()}applyMatrix4(e){const r=this.x,i=this.y,n=this.z,a=e.elements,s=1/(a[3]*r+a[7]*i+a[11]*n+a[15]);return this.x=(a[0]*r+a[4]*i+a[8]*n+a[12])*s,this.y=(a[1]*r+a[5]*i+a[9]*n+a[13])*s,this.z=(a[2]*r+a[6]*i+a[10]*n+a[14])*s,this}applyQuaternion(e){const r=this.x,i=this.y,n=this.z,a=e.x,s=e.y,o=e.z,l=e.w,u=2*(s*n-o*i),h=2*(o*r-a*n),f=2*(a*i-s*r);return this.x=r+l*u+s*f-o*h,this.y=i+l*h+o*u-a*f,this.z=n+l*f+a*h-s*u,this}project(e){return this.applyMatrix4(e.matrixWorldInverse).applyMatrix4(e.projectionMatrix)}unproject(e){return this.applyMatrix4(e.projectionMatrixInverse).applyMatrix4(e.matrixWorld)}transformDirection(e){const r=this.x,i=this.y,n=this.z,a=e.elements;return this.x=a[0]*r+a[4]*i+a[8]*n,this.y=a[1]*r+a[5]*i+a[9]*n,this.z=a[2]*r+a[6]*i+a[10]*n,this.normalize()}divide(e){return this.x/=e.x,this.y/=e.y,this.z/=e.z,this}divideScalar(e){return this.multiplyScalar(1/e)}min(e){return this.x=Math.min(this.x,e.x),this.y=Math.min(this.y,e.y),this.z=Math.min(this.z,e.z),this}max(e){return this.x=Math.max(this.x,e.x),this.y=Math.max(this.y,e.y),this.z=Math.max(this.z,e.z),this}clamp(e,r){return this.x=Math.max(e.x,Math.min(r.x,this.x)),this.y=Math.max(e.y,Math.min(r.y,this.y)),this.z=Math.max(e.z,Math.min(r.z,this.z)),this}clampScalar(e,r){return this.x=Math.max(e,Math.min(r,this.x)),this.y=Math.max(e,Math.min(r,this.y)),this.z=Math.max(e,Math.min(r,this.z)),this}clampLength(e,r){const i=this.length();return this.divideScalar(i||1).multiplyScalar(Math.max(e,Math.min(r,i)))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this.z=Math.floor(this.z),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this.z=Math.ceil(this.z),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this.z=Math.round(this.z),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this.z=Math.trunc(this.z),this}negate(){return this.x=-this.x,this.y=-this.y,this.z=-this.z,this}dot(e){return this.x*e.x+this.y*e.y+this.z*e.z}lengthSq(){return this.x*this.x+this.y*this.y+this.z*this.z}length(){return Math.sqrt(this.x*this.x+this.y*this.y+this.z*this.z)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)+Math.abs(this.z)}normalize(){return this.divideScalar(this.length()||1)}setLength(e){return this.normalize().multiplyScalar(e)}lerp(e,r){return this.x+=(e.x-this.x)*r,this.y+=(e.y-this.y)*r,this.z+=(e.z-this.z)*r,this}lerpVectors(e,r,i){return this.x=e.x+(r.x-e.x)*i,this.y=e.y+(r.y-e.y)*i,this.z=e.z+(r.z-e.z)*i,this}cross(e){return this.crossVectors(this,e)}crossVectors(e,r){const i=e.x,n=e.y,a=e.z,s=r.x,o=r.y,l=r.z;return this.x=n*l-a*o,this.y=a*s-i*l,this.z=i*o-n*s,this}projectOnVector(e){const r=e.lengthSq();if(r===0)return this.set(0,0,0);const i=e.dot(this)/r;return this.copy(e).multiplyScalar(i)}projectOnPlane(e){return nc.copy(this).projectOnVector(e),this.sub(nc)}reflect(e){return this.sub(nc.copy(e).multiplyScalar(2*this.dot(e)))}angleTo(e){const r=Math.sqrt(this.lengthSq()*e.lengthSq());if(r===0)return Math.PI/2;const i=this.dot(e)/r;return Math.acos(nr(i,-1,1))}distanceTo(e){return Math.sqrt(this.distanceToSquared(e))}distanceToSquared(e){const r=this.x-e.x,i=this.y-e.y,n=this.z-e.z;return r*r+i*i+n*n}manhattanDistanceTo(e){return Math.abs(this.x-e.x)+Math.abs(this.y-e.y)+Math.abs(this.z-e.z)}setFromSpherical(e){return this.setFromSphericalCoords(e.radius,e.phi,e.theta)}setFromSphericalCoords(e,r,i){const n=Math.sin(r)*e;return this.x=n*Math.sin(i),this.y=Math.cos(r)*e,this.z=n*Math.cos(i),this}setFromCylindrical(e){return this.setFromCylindricalCoords(e.radius,e.theta,e.y)}setFromCylindricalCoords(e,r,i){return this.x=e*Math.sin(r),this.y=i,this.z=e*Math.cos(r),this}setFromMatrixPosition(e){const r=e.elements;return this.x=r[12],this.y=r[13],this.z=r[14],this}setFromMatrixScale(e){const r=this.setFromMatrixColumn(e,0).length(),i=this.setFromMatrixColumn(e,1).length(),n=this.setFromMatrixColumn(e,2).length();return this.x=r,this.y=i,this.z=n,this}setFromMatrixColumn(e,r){return this.fromArray(e.elements,r*4)}setFromMatrix3Column(e,r){return this.fromArray(e.elements,r*3)}setFromEuler(e){return this.x=e._x,this.y=e._y,this.z=e._z,this}setFromColor(e){return this.x=e.r,this.y=e.g,this.z=e.b,this}equals(e){return e.x===this.x&&e.y===this.y&&e.z===this.z}fromArray(e,r=0){return this.x=e[r],this.y=e[r+1],this.z=e[r+2],this}toArray(e=[],r=0){return e[r]=this.x,e[r+1]=this.y,e[r+2]=this.z,e}fromBufferAttribute(e,r){return this.x=e.getX(r),this.y=e.getY(r),this.z=e.getZ(r),this}random(){return this.x=Math.random(),this.y=Math.random(),this.z=Math.random(),this}randomDirection(){const e=Math.random()*Math.PI*2,r=Math.random()*2-1,i=Math.sqrt(1-r*r);return this.x=i*Math.cos(e),this.y=r,this.z=i*Math.sin(e),this}*[Symbol.iterator](){yield this.x,yield this.y,yield this.z}}const nc=new O,wp=new Bn;class Wn{constructor(e=new O(1/0,1/0,1/0),r=new O(-1/0,-1/0,-1/0)){this.isBox3=!0,this.min=e,this.max=r}set(e,r){return this.min.copy(e),this.max.copy(r),this}setFromArray(e){this.makeEmpty();for(let r=0,i=e.length;r<i;r+=3)this.expandByPoint(Fr.fromArray(e,r));return this}setFromBufferAttribute(e){this.makeEmpty();for(let r=0,i=e.count;r<i;r++)this.expandByPoint(Fr.fromBufferAttribute(e,r));return this}setFromPoints(e){this.makeEmpty();for(let r=0,i=e.length;r<i;r++)this.expandByPoint(e[r]);return this}setFromCenterAndSize(e,r){const i=Fr.copy(r).multiplyScalar(.5);return this.min.copy(e).sub(i),this.max.copy(e).add(i),this}setFromObject(e,r=!1){return this.makeEmpty(),this.expandByObject(e,r)}clone(){return new this.constructor().copy(this)}copy(e){return this.min.copy(e.min),this.max.copy(e.max),this}makeEmpty(){return this.min.x=this.min.y=this.min.z=1/0,this.max.x=this.max.y=this.max.z=-1/0,this}isEmpty(){return this.max.x<this.min.x||this.max.y<this.min.y||this.max.z<this.min.z}getCenter(e){return this.isEmpty()?e.set(0,0,0):e.addVectors(this.min,this.max).multiplyScalar(.5)}getSize(e){return this.isEmpty()?e.set(0,0,0):e.subVectors(this.max,this.min)}expandByPoint(e){return this.min.min(e),this.max.max(e),this}expandByVector(e){return this.min.sub(e),this.max.add(e),this}expandByScalar(e){return this.min.addScalar(-e),this.max.addScalar(e),this}expandByObject(e,r=!1){e.updateWorldMatrix(!1,!1);const i=e.geometry;if(i!==void 0){const a=i.getAttribute("position");if(r===!0&&a!==void 0&&e.isInstancedMesh!==!0)for(let s=0,o=a.count;s<o;s++)e.isMesh===!0?e.getVertexPosition(s,Fr):Fr.fromBufferAttribute(a,s),Fr.applyMatrix4(e.matrixWorld),this.expandByPoint(Fr);else e.boundingBox!==void 0?(e.boundingBox===null&&e.computeBoundingBox(),Ao.copy(e.boundingBox)):(i.boundingBox===null&&i.computeBoundingBox(),Ao.copy(i.boundingBox)),Ao.applyMatrix4(e.matrixWorld),this.union(Ao)}const n=e.children;for(let a=0,s=n.length;a<s;a++)this.expandByObject(n[a],r);return this}containsPoint(e){return!(e.x<this.min.x||e.x>this.max.x||e.y<this.min.y||e.y>this.max.y||e.z<this.min.z||e.z>this.max.z)}containsBox(e){return this.min.x<=e.min.x&&e.max.x<=this.max.x&&this.min.y<=e.min.y&&e.max.y<=this.max.y&&this.min.z<=e.min.z&&e.max.z<=this.max.z}getParameter(e,r){return r.set((e.x-this.min.x)/(this.max.x-this.min.x),(e.y-this.min.y)/(this.max.y-this.min.y),(e.z-this.min.z)/(this.max.z-this.min.z))}intersectsBox(e){return!(e.max.x<this.min.x||e.min.x>this.max.x||e.max.y<this.min.y||e.min.y>this.max.y||e.max.z<this.min.z||e.min.z>this.max.z)}intersectsSphere(e){return this.clampPoint(e.center,Fr),Fr.distanceToSquared(e.center)<=e.radius*e.radius}intersectsPlane(e){let r,i;return e.normal.x>0?(r=e.normal.x*this.min.x,i=e.normal.x*this.max.x):(r=e.normal.x*this.max.x,i=e.normal.x*this.min.x),e.normal.y>0?(r+=e.normal.y*this.min.y,i+=e.normal.y*this.max.y):(r+=e.normal.y*this.max.y,i+=e.normal.y*this.min.y),e.normal.z>0?(r+=e.normal.z*this.min.z,i+=e.normal.z*this.max.z):(r+=e.normal.z*this.max.z,i+=e.normal.z*this.min.z),r<=-e.constant&&i>=-e.constant}intersectsTriangle(e){if(this.isEmpty())return!1;this.getCenter(cs),Co.subVectors(this.max,cs),qn.subVectors(e.a,cs),Kn.subVectors(e.b,cs),Zn.subVectors(e.c,cs),Ui.subVectors(Kn,qn),Di.subVectors(Zn,Kn),mn.subVectors(qn,Zn);let r=[0,-Ui.z,Ui.y,0,-Di.z,Di.y,0,-mn.z,mn.y,Ui.z,0,-Ui.x,Di.z,0,-Di.x,mn.z,0,-mn.x,-Ui.y,Ui.x,0,-Di.y,Di.x,0,-mn.y,mn.x,0];return!ac(r,qn,Kn,Zn,Co)||(r=[1,0,0,0,1,0,0,0,1],!ac(r,qn,Kn,Zn,Co))?!1:(Ro.crossVectors(Ui,Di),r=[Ro.x,Ro.y,Ro.z],ac(r,qn,Kn,Zn,Co))}clampPoint(e,r){return r.copy(e).clamp(this.min,this.max)}distanceToPoint(e){return this.clampPoint(e,Fr).distanceTo(e)}getBoundingSphere(e){return this.isEmpty()?e.makeEmpty():(this.getCenter(e.center),e.radius=this.getSize(Fr).length()*.5),e}intersect(e){return this.min.max(e.min),this.max.min(e.max),this.isEmpty()&&this.makeEmpty(),this}union(e){return this.min.min(e.min),this.max.max(e.max),this}applyMatrix4(e){return this.isEmpty()?this:(ui[0].set(this.min.x,this.min.y,this.min.z).applyMatrix4(e),ui[1].set(this.min.x,this.min.y,this.max.z).applyMatrix4(e),ui[2].set(this.min.x,this.max.y,this.min.z).applyMatrix4(e),ui[3].set(this.min.x,this.max.y,this.max.z).applyMatrix4(e),ui[4].set(this.max.x,this.min.y,this.min.z).applyMatrix4(e),ui[5].set(this.max.x,this.min.y,this.max.z).applyMatrix4(e),ui[6].set(this.max.x,this.max.y,this.min.z).applyMatrix4(e),ui[7].set(this.max.x,this.max.y,this.max.z).applyMatrix4(e),this.setFromPoints(ui),this)}translate(e){return this.min.add(e),this.max.add(e),this}equals(e){return e.min.equals(this.min)&&e.max.equals(this.max)}}const ui=[new O,new O,new O,new O,new O,new O,new O,new O],Fr=new O,Ao=new Wn,qn=new O,Kn=new O,Zn=new O,Ui=new O,Di=new O,mn=new O,cs=new O,Co=new O,Ro=new O,gn=new O;function ac(t,e,r,i,n){for(let a=0,s=t.length-3;a<=s;a+=3){gn.fromArray(t,a);const o=n.x*Math.abs(gn.x)+n.y*Math.abs(gn.y)+n.z*Math.abs(gn.z),l=e.dot(gn),u=r.dot(gn),h=i.dot(gn);if(Math.max(-Math.max(l,u,h),Math.min(l,u,h))>o)return!1}return!0}const uM=new Wn,ds=new O,sc=new O;class $a{constructor(e=new O,r=-1){this.isSphere=!0,this.center=e,this.radius=r}set(e,r){return this.center.copy(e),this.radius=r,this}setFromPoints(e,r){const i=this.center;r!==void 0?i.copy(r):uM.setFromPoints(e).getCenter(i);let n=0;for(let a=0,s=e.length;a<s;a++)n=Math.max(n,i.distanceToSquared(e[a]));return this.radius=Math.sqrt(n),this}copy(e){return this.center.copy(e.center),this.radius=e.radius,this}isEmpty(){return this.radius<0}makeEmpty(){return this.center.set(0,0,0),this.radius=-1,this}containsPoint(e){return e.distanceToSquared(this.center)<=this.radius*this.radius}distanceToPoint(e){return e.distanceTo(this.center)-this.radius}intersectsSphere(e){const r=this.radius+e.radius;return e.center.distanceToSquared(this.center)<=r*r}intersectsBox(e){return e.intersectsSphere(this)}intersectsPlane(e){return Math.abs(e.distanceToPoint(this.center))<=this.radius}clampPoint(e,r){const i=this.center.distanceToSquared(e);return r.copy(e),i>this.radius*this.radius&&(r.sub(this.center).normalize(),r.multiplyScalar(this.radius).add(this.center)),r}getBoundingBox(e){return this.isEmpty()?(e.makeEmpty(),e):(e.set(this.center,this.center),e.expandByScalar(this.radius),e)}applyMatrix4(e){return this.center.applyMatrix4(e),this.radius=this.radius*e.getMaxScaleOnAxis(),this}translate(e){return this.center.add(e),this}expandByPoint(e){if(this.isEmpty())return this.center.copy(e),this.radius=0,this;ds.subVectors(e,this.center);const r=ds.lengthSq();if(r>this.radius*this.radius){const i=Math.sqrt(r),n=(i-this.radius)*.5;this.center.addScaledVector(ds,n/i),this.radius+=n}return this}union(e){return e.isEmpty()?this:this.isEmpty()?(this.copy(e),this):(this.center.equals(e.center)===!0?this.radius=Math.max(this.radius,e.radius):(sc.subVectors(e.center,this.center).setLength(e.radius),this.expandByPoint(ds.copy(e.center).add(sc)),this.expandByPoint(ds.copy(e.center).sub(sc))),this)}equals(e){return e.center.equals(this.center)&&e.radius===this.radius}clone(){return new this.constructor().copy(this)}}const ci=new O,oc=new O,Po=new O,Ii=new O,lc=new O,Lo=new O,uc=new O;class mu{constructor(e=new O,r=new O(0,0,-1)){this.origin=e,this.direction=r}set(e,r){return this.origin.copy(e),this.direction.copy(r),this}copy(e){return this.origin.copy(e.origin),this.direction.copy(e.direction),this}at(e,r){return r.copy(this.origin).addScaledVector(this.direction,e)}lookAt(e){return this.direction.copy(e).sub(this.origin).normalize(),this}recast(e){return this.origin.copy(this.at(e,ci)),this}closestPointToPoint(e,r){r.subVectors(e,this.origin);const i=r.dot(this.direction);return i<0?r.copy(this.origin):r.copy(this.origin).addScaledVector(this.direction,i)}distanceToPoint(e){return Math.sqrt(this.distanceSqToPoint(e))}distanceSqToPoint(e){const r=ci.subVectors(e,this.origin).dot(this.direction);return r<0?this.origin.distanceToSquared(e):(ci.copy(this.origin).addScaledVector(this.direction,r),ci.distanceToSquared(e))}distanceSqToSegment(e,r,i,n){oc.copy(e).add(r).multiplyScalar(.5),Po.copy(r).sub(e).normalize(),Ii.copy(this.origin).sub(oc);const a=e.distanceTo(r)*.5,s=-this.direction.dot(Po),o=Ii.dot(this.direction),l=-Ii.dot(Po),u=Ii.lengthSq(),h=Math.abs(1-s*s);let f,d,p,_;if(h>0)if(f=s*l-o,d=s*o-l,_=a*h,f>=0)if(d>=-_)if(d<=_){const x=1/h;f*=x,d*=x,p=f*(f+s*d+2*o)+d*(s*f+d+2*l)+u}else d=a,f=Math.max(0,-(s*d+o)),p=-f*f+d*(d+2*l)+u;else d=-a,f=Math.max(0,-(s*d+o)),p=-f*f+d*(d+2*l)+u;else d<=-_?(f=Math.max(0,-(-s*a+o)),d=f>0?-a:Math.min(Math.max(-a,-l),a),p=-f*f+d*(d+2*l)+u):d<=_?(f=0,d=Math.min(Math.max(-a,-l),a),p=d*(d+2*l)+u):(f=Math.max(0,-(s*a+o)),d=f>0?a:Math.min(Math.max(-a,-l),a),p=-f*f+d*(d+2*l)+u);else d=s>0?-a:a,f=Math.max(0,-(s*d+o)),p=-f*f+d*(d+2*l)+u;return i&&i.copy(this.origin).addScaledVector(this.direction,f),n&&n.copy(oc).addScaledVector(Po,d),p}intersectSphere(e,r){ci.subVectors(e.center,this.origin);const i=ci.dot(this.direction),n=ci.dot(ci)-i*i,a=e.radius*e.radius;if(n>a)return null;const s=Math.sqrt(a-n),o=i-s,l=i+s;return l<0?null:o<0?this.at(l,r):this.at(o,r)}intersectsSphere(e){return this.distanceSqToPoint(e.center)<=e.radius*e.radius}distanceToPlane(e){const r=e.normal.dot(this.direction);if(r===0)return e.distanceToPoint(this.origin)===0?0:null;const i=-(this.origin.dot(e.normal)+e.constant)/r;return i>=0?i:null}intersectPlane(e,r){const i=this.distanceToPlane(e);return i===null?null:this.at(i,r)}intersectsPlane(e){const r=e.distanceToPoint(this.origin);return r===0||e.normal.dot(this.direction)*r<0}intersectBox(e,r){let i,n,a,s,o,l;const u=1/this.direction.x,h=1/this.direction.y,f=1/this.direction.z,d=this.origin;return u>=0?(i=(e.min.x-d.x)*u,n=(e.max.x-d.x)*u):(i=(e.max.x-d.x)*u,n=(e.min.x-d.x)*u),h>=0?(a=(e.min.y-d.y)*h,s=(e.max.y-d.y)*h):(a=(e.max.y-d.y)*h,s=(e.min.y-d.y)*h),i>s||a>n||((a>i||isNaN(i))&&(i=a),(s<n||isNaN(n))&&(n=s),f>=0?(o=(e.min.z-d.z)*f,l=(e.max.z-d.z)*f):(o=(e.max.z-d.z)*f,l=(e.min.z-d.z)*f),i>l||o>n)||((o>i||i!==i)&&(i=o),(l<n||n!==n)&&(n=l),n<0)?null:this.at(i>=0?i:n,r)}intersectsBox(e){return this.intersectBox(e,ci)!==null}intersectTriangle(e,r,i,n,a){lc.subVectors(r,e),Lo.subVectors(i,e),uc.crossVectors(lc,Lo);let s=this.direction.dot(uc),o;if(s>0){if(n)return null;o=1}else if(s<0)o=-1,s=-s;else return null;Ii.subVectors(this.origin,e);const l=o*this.direction.dot(Lo.crossVectors(Ii,Lo));if(l<0)return null;const u=o*this.direction.dot(lc.cross(Ii));if(u<0||l+u>s)return null;const h=-o*Ii.dot(uc);return h<0?null:this.at(h/s,a)}applyMatrix4(e){return this.origin.applyMatrix4(e),this.direction.transformDirection(e),this}equals(e){return e.origin.equals(this.origin)&&e.direction.equals(this.direction)}clone(){return new this.constructor().copy(this)}}class ft{constructor(e,r,i,n,a,s,o,l,u,h,f,d,p,_,x,m){ft.prototype.isMatrix4=!0,this.elements=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],e!==void 0&&this.set(e,r,i,n,a,s,o,l,u,h,f,d,p,_,x,m)}set(e,r,i,n,a,s,o,l,u,h,f,d,p,_,x,m){const c=this.elements;return c[0]=e,c[4]=r,c[8]=i,c[12]=n,c[1]=a,c[5]=s,c[9]=o,c[13]=l,c[2]=u,c[6]=h,c[10]=f,c[14]=d,c[3]=p,c[7]=_,c[11]=x,c[15]=m,this}identity(){return this.set(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1),this}clone(){return new ft().fromArray(this.elements)}copy(e){const r=this.elements,i=e.elements;return r[0]=i[0],r[1]=i[1],r[2]=i[2],r[3]=i[3],r[4]=i[4],r[5]=i[5],r[6]=i[6],r[7]=i[7],r[8]=i[8],r[9]=i[9],r[10]=i[10],r[11]=i[11],r[12]=i[12],r[13]=i[13],r[14]=i[14],r[15]=i[15],this}copyPosition(e){const r=this.elements,i=e.elements;return r[12]=i[12],r[13]=i[13],r[14]=i[14],this}setFromMatrix3(e){const r=e.elements;return this.set(r[0],r[3],r[6],0,r[1],r[4],r[7],0,r[2],r[5],r[8],0,0,0,0,1),this}extractBasis(e,r,i){return e.setFromMatrixColumn(this,0),r.setFromMatrixColumn(this,1),i.setFromMatrixColumn(this,2),this}makeBasis(e,r,i){return this.set(e.x,r.x,i.x,0,e.y,r.y,i.y,0,e.z,r.z,i.z,0,0,0,0,1),this}extractRotation(e){const r=this.elements,i=e.elements,n=1/$n.setFromMatrixColumn(e,0).length(),a=1/$n.setFromMatrixColumn(e,1).length(),s=1/$n.setFromMatrixColumn(e,2).length();return r[0]=i[0]*n,r[1]=i[1]*n,r[2]=i[2]*n,r[3]=0,r[4]=i[4]*a,r[5]=i[5]*a,r[6]=i[6]*a,r[7]=0,r[8]=i[8]*s,r[9]=i[9]*s,r[10]=i[10]*s,r[11]=0,r[12]=0,r[13]=0,r[14]=0,r[15]=1,this}makeRotationFromEuler(e){const r=this.elements,i=e.x,n=e.y,a=e.z,s=Math.cos(i),o=Math.sin(i),l=Math.cos(n),u=Math.sin(n),h=Math.cos(a),f=Math.sin(a);if(e.order==="XYZ"){const d=s*h,p=s*f,_=o*h,x=o*f;r[0]=l*h,r[4]=-l*f,r[8]=u,r[1]=p+_*u,r[5]=d-x*u,r[9]=-o*l,r[2]=x-d*u,r[6]=_+p*u,r[10]=s*l}else if(e.order==="YXZ"){const d=l*h,p=l*f,_=u*h,x=u*f;r[0]=d+x*o,r[4]=_*o-p,r[8]=s*u,r[1]=s*f,r[5]=s*h,r[9]=-o,r[2]=p*o-_,r[6]=x+d*o,r[10]=s*l}else if(e.order==="ZXY"){const d=l*h,p=l*f,_=u*h,x=u*f;r[0]=d-x*o,r[4]=-s*f,r[8]=_+p*o,r[1]=p+_*o,r[5]=s*h,r[9]=x-d*o,r[2]=-s*u,r[6]=o,r[10]=s*l}else if(e.order==="ZYX"){const d=s*h,p=s*f,_=o*h,x=o*f;r[0]=l*h,r[4]=_*u-p,r[8]=d*u+x,r[1]=l*f,r[5]=x*u+d,r[9]=p*u-_,r[2]=-u,r[6]=o*l,r[10]=s*l}else if(e.order==="YZX"){const d=s*l,p=s*u,_=o*l,x=o*u;r[0]=l*h,r[4]=x-d*f,r[8]=_*f+p,r[1]=f,r[5]=s*h,r[9]=-o*h,r[2]=-u*h,r[6]=p*f+_,r[10]=d-x*f}else if(e.order==="XZY"){const d=s*l,p=s*u,_=o*l,x=o*u;r[0]=l*h,r[4]=-f,r[8]=u*h,r[1]=d*f+x,r[5]=s*h,r[9]=p*f-_,r[2]=_*f-p,r[6]=o*h,r[10]=x*f+d}return r[3]=0,r[7]=0,r[11]=0,r[12]=0,r[13]=0,r[14]=0,r[15]=1,this}makeRotationFromQuaternion(e){return this.compose(cM,e,dM)}lookAt(e,r,i){const n=this.elements;return xr.subVectors(e,r),xr.lengthSq()===0&&(xr.z=1),xr.normalize(),Ni.crossVectors(i,xr),Ni.lengthSq()===0&&(Math.abs(i.z)===1?xr.x+=1e-4:xr.z+=1e-4,xr.normalize(),Ni.crossVectors(i,xr)),Ni.normalize(),Uo.crossVectors(xr,Ni),n[0]=Ni.x,n[4]=Uo.x,n[8]=xr.x,n[1]=Ni.y,n[5]=Uo.y,n[9]=xr.y,n[2]=Ni.z,n[6]=Uo.z,n[10]=xr.z,this}multiply(e){return this.multiplyMatrices(this,e)}premultiply(e){return this.multiplyMatrices(e,this)}multiplyMatrices(e,r){const i=e.elements,n=r.elements,a=this.elements,s=i[0],o=i[4],l=i[8],u=i[12],h=i[1],f=i[5],d=i[9],p=i[13],_=i[2],x=i[6],m=i[10],c=i[14],g=i[3],v=i[7],M=i[11],P=i[15],T=n[0],w=n[4],L=n[8],b=n[12],y=n[1],U=n[5],B=n[9],V=n[13],q=n[2],J=n[6],K=n[10],ne=n[14],I=n[3],Z=n[7],re=n[11],xe=n[15];return a[0]=s*T+o*y+l*q+u*I,a[4]=s*w+o*U+l*J+u*Z,a[8]=s*L+o*B+l*K+u*re,a[12]=s*b+o*V+l*ne+u*xe,a[1]=h*T+f*y+d*q+p*I,a[5]=h*w+f*U+d*J+p*Z,a[9]=h*L+f*B+d*K+p*re,a[13]=h*b+f*V+d*ne+p*xe,a[2]=_*T+x*y+m*q+c*I,a[6]=_*w+x*U+m*J+c*Z,a[10]=_*L+x*B+m*K+c*re,a[14]=_*b+x*V+m*ne+c*xe,a[3]=g*T+v*y+M*q+P*I,a[7]=g*w+v*U+M*J+P*Z,a[11]=g*L+v*B+M*K+P*re,a[15]=g*b+v*V+M*ne+P*xe,this}multiplyScalar(e){const r=this.elements;return r[0]*=e,r[4]*=e,r[8]*=e,r[12]*=e,r[1]*=e,r[5]*=e,r[9]*=e,r[13]*=e,r[2]*=e,r[6]*=e,r[10]*=e,r[14]*=e,r[3]*=e,r[7]*=e,r[11]*=e,r[15]*=e,this}determinant(){const e=this.elements,r=e[0],i=e[4],n=e[8],a=e[12],s=e[1],o=e[5],l=e[9],u=e[13],h=e[2],f=e[6],d=e[10],p=e[14],_=e[3],x=e[7],m=e[11],c=e[15];return _*(+a*l*f-n*u*f-a*o*d+i*u*d+n*o*p-i*l*p)+x*(+r*l*p-r*u*d+a*s*d-n*s*p+n*u*h-a*l*h)+m*(+r*u*f-r*o*p-a*s*f+i*s*p+a*o*h-i*u*h)+c*(-n*o*h-r*l*f+r*o*d+n*s*f-i*s*d+i*l*h)}transpose(){const e=this.elements;let r;return r=e[1],e[1]=e[4],e[4]=r,r=e[2],e[2]=e[8],e[8]=r,r=e[6],e[6]=e[9],e[9]=r,r=e[3],e[3]=e[12],e[12]=r,r=e[7],e[7]=e[13],e[13]=r,r=e[11],e[11]=e[14],e[14]=r,this}setPosition(e,r,i){const n=this.elements;return e.isVector3?(n[12]=e.x,n[13]=e.y,n[14]=e.z):(n[12]=e,n[13]=r,n[14]=i),this}invert(){const e=this.elements,r=e[0],i=e[1],n=e[2],a=e[3],s=e[4],o=e[5],l=e[6],u=e[7],h=e[8],f=e[9],d=e[10],p=e[11],_=e[12],x=e[13],m=e[14],c=e[15],g=f*m*u-x*d*u+x*l*p-o*m*p-f*l*c+o*d*c,v=_*d*u-h*m*u-_*l*p+s*m*p+h*l*c-s*d*c,M=h*x*u-_*f*u+_*o*p-s*x*p-h*o*c+s*f*c,P=_*f*l-h*x*l-_*o*d+s*x*d+h*o*m-s*f*m,T=r*g+i*v+n*M+a*P;if(T===0)return this.set(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0);const w=1/T;return e[0]=g*w,e[1]=(x*d*a-f*m*a-x*n*p+i*m*p+f*n*c-i*d*c)*w,e[2]=(o*m*a-x*l*a+x*n*u-i*m*u-o*n*c+i*l*c)*w,e[3]=(f*l*a-o*d*a-f*n*u+i*d*u+o*n*p-i*l*p)*w,e[4]=v*w,e[5]=(h*m*a-_*d*a+_*n*p-r*m*p-h*n*c+r*d*c)*w,e[6]=(_*l*a-s*m*a-_*n*u+r*m*u+s*n*c-r*l*c)*w,e[7]=(s*d*a-h*l*a+h*n*u-r*d*u-s*n*p+r*l*p)*w,e[8]=M*w,e[9]=(_*f*a-h*x*a-_*i*p+r*x*p+h*i*c-r*f*c)*w,e[10]=(s*x*a-_*o*a+_*i*u-r*x*u-s*i*c+r*o*c)*w,e[11]=(h*o*a-s*f*a-h*i*u+r*f*u+s*i*p-r*o*p)*w,e[12]=P*w,e[13]=(h*x*n-_*f*n+_*i*d-r*x*d-h*i*m+r*f*m)*w,e[14]=(_*o*n-s*x*n-_*i*l+r*x*l+s*i*m-r*o*m)*w,e[15]=(s*f*n-h*o*n+h*i*l-r*f*l-s*i*d+r*o*d)*w,this}scale(e){const r=this.elements,i=e.x,n=e.y,a=e.z;return r[0]*=i,r[4]*=n,r[8]*=a,r[1]*=i,r[5]*=n,r[9]*=a,r[2]*=i,r[6]*=n,r[10]*=a,r[3]*=i,r[7]*=n,r[11]*=a,this}getMaxScaleOnAxis(){const e=this.elements,r=e[0]*e[0]+e[1]*e[1]+e[2]*e[2],i=e[4]*e[4]+e[5]*e[5]+e[6]*e[6],n=e[8]*e[8]+e[9]*e[9]+e[10]*e[10];return Math.sqrt(Math.max(r,i,n))}makeTranslation(e,r,i){return e.isVector3?this.set(1,0,0,e.x,0,1,0,e.y,0,0,1,e.z,0,0,0,1):this.set(1,0,0,e,0,1,0,r,0,0,1,i,0,0,0,1),this}makeRotationX(e){const r=Math.cos(e),i=Math.sin(e);return this.set(1,0,0,0,0,r,-i,0,0,i,r,0,0,0,0,1),this}makeRotationY(e){const r=Math.cos(e),i=Math.sin(e);return this.set(r,0,i,0,0,1,0,0,-i,0,r,0,0,0,0,1),this}makeRotationZ(e){const r=Math.cos(e),i=Math.sin(e);return this.set(r,-i,0,0,i,r,0,0,0,0,1,0,0,0,0,1),this}makeRotationAxis(e,r){const i=Math.cos(r),n=Math.sin(r),a=1-i,s=e.x,o=e.y,l=e.z,u=a*s,h=a*o;return this.set(u*s+i,u*o-n*l,u*l+n*o,0,u*o+n*l,h*o+i,h*l-n*s,0,u*l-n*o,h*l+n*s,a*l*l+i,0,0,0,0,1),this}makeScale(e,r,i){return this.set(e,0,0,0,0,r,0,0,0,0,i,0,0,0,0,1),this}makeShear(e,r,i,n,a,s){return this.set(1,i,a,0,e,1,s,0,r,n,1,0,0,0,0,1),this}compose(e,r,i){const n=this.elements,a=r._x,s=r._y,o=r._z,l=r._w,u=a+a,h=s+s,f=o+o,d=a*u,p=a*h,_=a*f,x=s*h,m=s*f,c=o*f,g=l*u,v=l*h,M=l*f,P=i.x,T=i.y,w=i.z;return n[0]=(1-(x+c))*P,n[1]=(p+M)*P,n[2]=(_-v)*P,n[3]=0,n[4]=(p-M)*T,n[5]=(1-(d+c))*T,n[6]=(m+g)*T,n[7]=0,n[8]=(_+v)*w,n[9]=(m-g)*w,n[10]=(1-(d+x))*w,n[11]=0,n[12]=e.x,n[13]=e.y,n[14]=e.z,n[15]=1,this}decompose(e,r,i){const n=this.elements;let a=$n.set(n[0],n[1],n[2]).length();const s=$n.set(n[4],n[5],n[6]).length(),o=$n.set(n[8],n[9],n[10]).length();this.determinant()<0&&(a=-a),e.x=n[12],e.y=n[13],e.z=n[14],zr.copy(this);const l=1/a,u=1/s,h=1/o;return zr.elements[0]*=l,zr.elements[1]*=l,zr.elements[2]*=l,zr.elements[4]*=u,zr.elements[5]*=u,zr.elements[6]*=u,zr.elements[8]*=h,zr.elements[9]*=h,zr.elements[10]*=h,r.setFromRotationMatrix(zr),i.x=a,i.y=s,i.z=o,this}makePerspective(e,r,i,n,a,s,o=Si){const l=this.elements,u=2*a/(r-e),h=2*a/(i-n),f=(r+e)/(r-e),d=(i+n)/(i-n);let p,_;if(o===Si)p=-(s+a)/(s-a),_=-2*s*a/(s-a);else if(o===Wl)p=-s/(s-a),_=-s*a/(s-a);else throw new Error("THREE.Matrix4.makePerspective(): Invalid coordinate system: "+o);return l[0]=u,l[4]=0,l[8]=f,l[12]=0,l[1]=0,l[5]=h,l[9]=d,l[13]=0,l[2]=0,l[6]=0,l[10]=p,l[14]=_,l[3]=0,l[7]=0,l[11]=-1,l[15]=0,this}makeOrthographic(e,r,i,n,a,s,o=Si){const l=this.elements,u=1/(r-e),h=1/(i-n),f=1/(s-a),d=(r+e)*u,p=(i+n)*h;let _,x;if(o===Si)_=(s+a)*f,x=-2*f;else if(o===Wl)_=a*f,x=-1*f;else throw new Error("THREE.Matrix4.makeOrthographic(): Invalid coordinate system: "+o);return l[0]=2*u,l[4]=0,l[8]=0,l[12]=-d,l[1]=0,l[5]=2*h,l[9]=0,l[13]=-p,l[2]=0,l[6]=0,l[10]=x,l[14]=-_,l[3]=0,l[7]=0,l[11]=0,l[15]=1,this}equals(e){const r=this.elements,i=e.elements;for(let n=0;n<16;n++)if(r[n]!==i[n])return!1;return!0}fromArray(e,r=0){for(let i=0;i<16;i++)this.elements[i]=e[i+r];return this}toArray(e=[],r=0){const i=this.elements;return e[r]=i[0],e[r+1]=i[1],e[r+2]=i[2],e[r+3]=i[3],e[r+4]=i[4],e[r+5]=i[5],e[r+6]=i[6],e[r+7]=i[7],e[r+8]=i[8],e[r+9]=i[9],e[r+10]=i[10],e[r+11]=i[11],e[r+12]=i[12],e[r+13]=i[13],e[r+14]=i[14],e[r+15]=i[15],e}}const $n=new O,zr=new ft,cM=new O(0,0,0),dM=new O(1,1,1),Ni=new O,Uo=new O,xr=new O,Tp=new ft,Ap=new Bn;class oi{constructor(e=0,r=0,i=0,n=oi.DEFAULT_ORDER){this.isEuler=!0,this._x=e,this._y=r,this._z=i,this._order=n}get x(){return this._x}set x(e){this._x=e,this._onChangeCallback()}get y(){return this._y}set y(e){this._y=e,this._onChangeCallback()}get z(){return this._z}set z(e){this._z=e,this._onChangeCallback()}get order(){return this._order}set order(e){this._order=e,this._onChangeCallback()}set(e,r,i,n=this._order){return this._x=e,this._y=r,this._z=i,this._order=n,this._onChangeCallback(),this}clone(){return new this.constructor(this._x,this._y,this._z,this._order)}copy(e){return this._x=e._x,this._y=e._y,this._z=e._z,this._order=e._order,this._onChangeCallback(),this}setFromRotationMatrix(e,r=this._order,i=!0){const n=e.elements,a=n[0],s=n[4],o=n[8],l=n[1],u=n[5],h=n[9],f=n[2],d=n[6],p=n[10];switch(r){case"XYZ":this._y=Math.asin(nr(o,-1,1)),Math.abs(o)<.9999999?(this._x=Math.atan2(-h,p),this._z=Math.atan2(-s,a)):(this._x=Math.atan2(d,u),this._z=0);break;case"YXZ":this._x=Math.asin(-nr(h,-1,1)),Math.abs(h)<.9999999?(this._y=Math.atan2(o,p),this._z=Math.atan2(l,u)):(this._y=Math.atan2(-f,a),this._z=0);break;case"ZXY":this._x=Math.asin(nr(d,-1,1)),Math.abs(d)<.9999999?(this._y=Math.atan2(-f,p),this._z=Math.atan2(-s,u)):(this._y=0,this._z=Math.atan2(l,a));break;case"ZYX":this._y=Math.asin(-nr(f,-1,1)),Math.abs(f)<.9999999?(this._x=Math.atan2(d,p),this._z=Math.atan2(l,a)):(this._x=0,this._z=Math.atan2(-s,u));break;case"YZX":this._z=Math.asin(nr(l,-1,1)),Math.abs(l)<.9999999?(this._x=Math.atan2(-h,u),this._y=Math.atan2(-f,a)):(this._x=0,this._y=Math.atan2(o,p));break;case"XZY":this._z=Math.asin(-nr(s,-1,1)),Math.abs(s)<.9999999?(this._x=Math.atan2(d,u),this._y=Math.atan2(o,a)):(this._x=Math.atan2(-h,p),this._y=0);break;default:console.warn("THREE.Euler: .setFromRotationMatrix() encountered an unknown order: "+r)}return this._order=r,i===!0&&this._onChangeCallback(),this}setFromQuaternion(e,r,i){return Tp.makeRotationFromQuaternion(e),this.setFromRotationMatrix(Tp,r,i)}setFromVector3(e,r=this._order){return this.set(e.x,e.y,e.z,r)}reorder(e){return Ap.setFromEuler(this),this.setFromQuaternion(Ap,e)}equals(e){return e._x===this._x&&e._y===this._y&&e._z===this._z&&e._order===this._order}fromArray(e){return this._x=e[0],this._y=e[1],this._z=e[2],e[3]!==void 0&&(this._order=e[3]),this._onChangeCallback(),this}toArray(e=[],r=0){return e[r]=this._x,e[r+1]=this._y,e[r+2]=this._z,e[r+3]=this._order,e}_onChange(e){return this._onChangeCallback=e,this}_onChangeCallback(){}*[Symbol.iterator](){yield this._x,yield this._y,yield this._z,yield this._order}}oi.DEFAULT_ORDER="XYZ";class Ch{constructor(){this.mask=1}set(e){this.mask=(1<<e|0)>>>0}enable(e){this.mask|=1<<e|0}enableAll(){this.mask=-1}toggle(e){this.mask^=1<<e|0}disable(e){this.mask&=~(1<<e|0)}disableAll(){this.mask=0}test(e){return(this.mask&e.mask)!==0}isEnabled(e){return(this.mask&(1<<e|0))!==0}}let hM=0;const Cp=new O,Qn=new Bn,di=new ft,Do=new O,hs=new O,fM=new O,pM=new Bn,Rp=new O(1,0,0),Pp=new O(0,1,0),Lp=new O(0,0,1),Up={type:"added"},mM={type:"removed"},Jn={type:"childadded",child:null},cc={type:"childremoved",child:null};class Rt extends Gn{constructor(){super(),this.isObject3D=!0,Object.defineProperty(this,"id",{value:hM++}),this.uuid=no(),this.name="",this.type="Object3D",this.parent=null,this.children=[],this.up=Rt.DEFAULT_UP.clone();const e=new O,r=new oi,i=new Bn,n=new O(1,1,1);function a(){i.setFromEuler(r,!1)}function s(){r.setFromQuaternion(i,void 0,!1)}r._onChange(a),i._onChange(s),Object.defineProperties(this,{position:{configurable:!0,enumerable:!0,value:e},rotation:{configurable:!0,enumerable:!0,value:r},quaternion:{configurable:!0,enumerable:!0,value:i},scale:{configurable:!0,enumerable:!0,value:n},modelViewMatrix:{value:new ft},normalMatrix:{value:new Ke}}),this.matrix=new ft,this.matrixWorld=new ft,this.matrixAutoUpdate=Rt.DEFAULT_MATRIX_AUTO_UPDATE,this.matrixWorldAutoUpdate=Rt.DEFAULT_MATRIX_WORLD_AUTO_UPDATE,this.matrixWorldNeedsUpdate=!1,this.layers=new Ch,this.visible=!0,this.castShadow=!1,this.receiveShadow=!1,this.frustumCulled=!0,this.renderOrder=0,this.animations=[],this.userData={}}onBeforeShadow(){}onAfterShadow(){}onBeforeRender(){}onAfterRender(){}applyMatrix4(e){this.matrixAutoUpdate&&this.updateMatrix(),this.matrix.premultiply(e),this.matrix.decompose(this.position,this.quaternion,this.scale)}applyQuaternion(e){return this.quaternion.premultiply(e),this}setRotationFromAxisAngle(e,r){this.quaternion.setFromAxisAngle(e,r)}setRotationFromEuler(e){this.quaternion.setFromEuler(e,!0)}setRotationFromMatrix(e){this.quaternion.setFromRotationMatrix(e)}setRotationFromQuaternion(e){this.quaternion.copy(e)}rotateOnAxis(e,r){return Qn.setFromAxisAngle(e,r),this.quaternion.multiply(Qn),this}rotateOnWorldAxis(e,r){return Qn.setFromAxisAngle(e,r),this.quaternion.premultiply(Qn),this}rotateX(e){return this.rotateOnAxis(Rp,e)}rotateY(e){return this.rotateOnAxis(Pp,e)}rotateZ(e){return this.rotateOnAxis(Lp,e)}translateOnAxis(e,r){return Cp.copy(e).applyQuaternion(this.quaternion),this.position.add(Cp.multiplyScalar(r)),this}translateX(e){return this.translateOnAxis(Rp,e)}translateY(e){return this.translateOnAxis(Pp,e)}translateZ(e){return this.translateOnAxis(Lp,e)}localToWorld(e){return this.updateWorldMatrix(!0,!1),e.applyMatrix4(this.matrixWorld)}worldToLocal(e){return this.updateWorldMatrix(!0,!1),e.applyMatrix4(di.copy(this.matrixWorld).invert())}lookAt(e,r,i){e.isVector3?Do.copy(e):Do.set(e,r,i);const n=this.parent;this.updateWorldMatrix(!0,!1),hs.setFromMatrixPosition(this.matrixWorld),this.isCamera||this.isLight?di.lookAt(hs,Do,this.up):di.lookAt(Do,hs,this.up),this.quaternion.setFromRotationMatrix(di),n&&(di.extractRotation(n.matrixWorld),Qn.setFromRotationMatrix(di),this.quaternion.premultiply(Qn.invert()))}add(e){if(arguments.length>1){for(let r=0;r<arguments.length;r++)this.add(arguments[r]);return this}return e===this?(console.error("THREE.Object3D.add: object can't be added as a child of itself.",e),this):(e&&e.isObject3D?(e.removeFromParent(),e.parent=this,this.children.push(e),e.dispatchEvent(Up),Jn.child=e,this.dispatchEvent(Jn),Jn.child=null):console.error("THREE.Object3D.add: object not an instance of THREE.Object3D.",e),this)}remove(e){if(arguments.length>1){for(let i=0;i<arguments.length;i++)this.remove(arguments[i]);return this}const r=this.children.indexOf(e);return r!==-1&&(e.parent=null,this.children.splice(r,1),e.dispatchEvent(mM),cc.child=e,this.dispatchEvent(cc),cc.child=null),this}removeFromParent(){const e=this.parent;return e!==null&&e.remove(this),this}clear(){return this.remove(...this.children)}attach(e){return this.updateWorldMatrix(!0,!1),di.copy(this.matrixWorld).invert(),e.parent!==null&&(e.parent.updateWorldMatrix(!0,!1),di.multiply(e.parent.matrixWorld)),e.applyMatrix4(di),e.removeFromParent(),e.parent=this,this.children.push(e),e.updateWorldMatrix(!1,!0),e.dispatchEvent(Up),Jn.child=e,this.dispatchEvent(Jn),Jn.child=null,this}getObjectById(e){return this.getObjectByProperty("id",e)}getObjectByName(e){return this.getObjectByProperty("name",e)}getObjectByProperty(e,r){if(this[e]===r)return this;for(let i=0,n=this.children.length;i<n;i++){const a=this.children[i].getObjectByProperty(e,r);if(a!==void 0)return a}}getObjectsByProperty(e,r,i=[]){this[e]===r&&i.push(this);const n=this.children;for(let a=0,s=n.length;a<s;a++)n[a].getObjectsByProperty(e,r,i);return i}getWorldPosition(e){return this.updateWorldMatrix(!0,!1),e.setFromMatrixPosition(this.matrixWorld)}getWorldQuaternion(e){return this.updateWorldMatrix(!0,!1),this.matrixWorld.decompose(hs,e,fM),e}getWorldScale(e){return this.updateWorldMatrix(!0,!1),this.matrixWorld.decompose(hs,pM,e),e}getWorldDirection(e){this.updateWorldMatrix(!0,!1);const r=this.matrixWorld.elements;return e.set(r[8],r[9],r[10]).normalize()}raycast(){}traverse(e){e(this);const r=this.children;for(let i=0,n=r.length;i<n;i++)r[i].traverse(e)}traverseVisible(e){if(this.visible===!1)return;e(this);const r=this.children;for(let i=0,n=r.length;i<n;i++)r[i].traverseVisible(e)}traverseAncestors(e){const r=this.parent;r!==null&&(e(r),r.traverseAncestors(e))}updateMatrix(){this.matrix.compose(this.position,this.quaternion,this.scale),this.matrixWorldNeedsUpdate=!0}updateMatrixWorld(e){this.matrixAutoUpdate&&this.updateMatrix(),(this.matrixWorldNeedsUpdate||e)&&(this.parent===null?this.matrixWorld.copy(this.matrix):this.matrixWorld.multiplyMatrices(this.parent.matrixWorld,this.matrix),this.matrixWorldNeedsUpdate=!1,e=!0);const r=this.children;for(let i=0,n=r.length;i<n;i++){const a=r[i];(a.matrixWorldAutoUpdate===!0||e===!0)&&a.updateMatrixWorld(e)}}updateWorldMatrix(e,r){const i=this.parent;if(e===!0&&i!==null&&i.matrixWorldAutoUpdate===!0&&i.updateWorldMatrix(!0,!1),this.matrixAutoUpdate&&this.updateMatrix(),this.parent===null?this.matrixWorld.copy(this.matrix):this.matrixWorld.multiplyMatrices(this.parent.matrixWorld,this.matrix),r===!0){const n=this.children;for(let a=0,s=n.length;a<s;a++){const o=n[a];o.matrixWorldAutoUpdate===!0&&o.updateWorldMatrix(!1,!0)}}}toJSON(e){const r=e===void 0||typeof e=="string",i={};r&&(e={geometries:{},materials:{},textures:{},images:{},shapes:{},skeletons:{},animations:{},nodes:{}},i.metadata={version:4.6,type:"Object",generator:"Object3D.toJSON"});const n={};n.uuid=this.uuid,n.type=this.type,this.name!==""&&(n.name=this.name),this.castShadow===!0&&(n.castShadow=!0),this.receiveShadow===!0&&(n.receiveShadow=!0),this.visible===!1&&(n.visible=!1),this.frustumCulled===!1&&(n.frustumCulled=!1),this.renderOrder!==0&&(n.renderOrder=this.renderOrder),Object.keys(this.userData).length>0&&(n.userData=this.userData),n.layers=this.layers.mask,n.matrix=this.matrix.toArray(),n.up=this.up.toArray(),this.matrixAutoUpdate===!1&&(n.matrixAutoUpdate=!1),this.isInstancedMesh&&(n.type="InstancedMesh",n.count=this.count,n.instanceMatrix=this.instanceMatrix.toJSON(),this.instanceColor!==null&&(n.instanceColor=this.instanceColor.toJSON())),this.isBatchedMesh&&(n.type="BatchedMesh",n.perObjectFrustumCulled=this.perObjectFrustumCulled,n.sortObjects=this.sortObjects,n.drawRanges=this._drawRanges,n.reservedRanges=this._reservedRanges,n.visibility=this._visibility,n.active=this._active,n.bounds=this._bounds.map(o=>({boxInitialized:o.boxInitialized,boxMin:o.box.min.toArray(),boxMax:o.box.max.toArray(),sphereInitialized:o.sphereInitialized,sphereRadius:o.sphere.radius,sphereCenter:o.sphere.center.toArray()})),n.maxGeometryCount=this._maxGeometryCount,n.maxVertexCount=this._maxVertexCount,n.maxIndexCount=this._maxIndexCount,n.geometryInitialized=this._geometryInitialized,n.geometryCount=this._geometryCount,n.matricesTexture=this._matricesTexture.toJSON(e),this._colorsTexture!==null&&(n.colorsTexture=this._colorsTexture.toJSON(e)),this.boundingSphere!==null&&(n.boundingSphere={center:n.boundingSphere.center.toArray(),radius:n.boundingSphere.radius}),this.boundingBox!==null&&(n.boundingBox={min:n.boundingBox.min.toArray(),max:n.boundingBox.max.toArray()}));function a(o,l){return o[l.uuid]===void 0&&(o[l.uuid]=l.toJSON(e)),l.uuid}if(this.isScene)this.background&&(this.background.isColor?n.background=this.background.toJSON():this.background.isTexture&&(n.background=this.background.toJSON(e).uuid)),this.environment&&this.environment.isTexture&&this.environment.isRenderTargetTexture!==!0&&(n.environment=this.environment.toJSON(e).uuid);else if(this.isMesh||this.isLine||this.isPoints){n.geometry=a(e.geometries,this.geometry);const o=this.geometry.parameters;if(o!==void 0&&o.shapes!==void 0){const l=o.shapes;if(Array.isArray(l))for(let u=0,h=l.length;u<h;u++){const f=l[u];a(e.shapes,f)}else a(e.shapes,l)}}if(this.isSkinnedMesh&&(n.bindMode=this.bindMode,n.bindMatrix=this.bindMatrix.toArray(),this.skeleton!==void 0&&(a(e.skeletons,this.skeleton),n.skeleton=this.skeleton.uuid)),this.material!==void 0)if(Array.isArray(this.material)){const o=[];for(let l=0,u=this.material.length;l<u;l++)o.push(a(e.materials,this.material[l]));n.material=o}else n.material=a(e.materials,this.material);if(this.children.length>0){n.children=[];for(let o=0;o<this.children.length;o++)n.children.push(this.children[o].toJSON(e).object)}if(this.animations.length>0){n.animations=[];for(let o=0;o<this.animations.length;o++){const l=this.animations[o];n.animations.push(a(e.animations,l))}}if(r){const o=s(e.geometries),l=s(e.materials),u=s(e.textures),h=s(e.images),f=s(e.shapes),d=s(e.skeletons),p=s(e.animations),_=s(e.nodes);o.length>0&&(i.geometries=o),l.length>0&&(i.materials=l),u.length>0&&(i.textures=u),h.length>0&&(i.images=h),f.length>0&&(i.shapes=f),d.length>0&&(i.skeletons=d),p.length>0&&(i.animations=p),_.length>0&&(i.nodes=_)}return i.object=n,i;function s(o){const l=[];for(const u in o){const h=o[u];delete h.metadata,l.push(h)}return l}}clone(e){return new this.constructor().copy(this,e)}copy(e,r=!0){if(this.name=e.name,this.up.copy(e.up),this.position.copy(e.position),this.rotation.order=e.rotation.order,this.quaternion.copy(e.quaternion),this.scale.copy(e.scale),this.matrix.copy(e.matrix),this.matrixWorld.copy(e.matrixWorld),this.matrixAutoUpdate=e.matrixAutoUpdate,this.matrixWorldAutoUpdate=e.matrixWorldAutoUpdate,this.matrixWorldNeedsUpdate=e.matrixWorldNeedsUpdate,this.layers.mask=e.layers.mask,this.visible=e.visible,this.castShadow=e.castShadow,this.receiveShadow=e.receiveShadow,this.frustumCulled=e.frustumCulled,this.renderOrder=e.renderOrder,this.animations=e.animations.slice(),this.userData=JSON.parse(JSON.stringify(e.userData)),r===!0)for(let i=0;i<e.children.length;i++){const n=e.children[i];this.add(n.clone())}return this}}Rt.DEFAULT_UP=new O(0,1,0);Rt.DEFAULT_MATRIX_AUTO_UPDATE=!0;Rt.DEFAULT_MATRIX_WORLD_AUTO_UPDATE=!0;const Br=new O,hi=new O,dc=new O,fi=new O,ea=new O,ta=new O,Dp=new O,hc=new O,fc=new O,pc=new O;class ii{constructor(e=new O,r=new O,i=new O){this.a=e,this.b=r,this.c=i}static getNormal(e,r,i,n){n.subVectors(i,r),Br.subVectors(e,r),n.cross(Br);const a=n.lengthSq();return a>0?n.multiplyScalar(1/Math.sqrt(a)):n.set(0,0,0)}static getBarycoord(e,r,i,n,a){Br.subVectors(n,r),hi.subVectors(i,r),dc.subVectors(e,r);const s=Br.dot(Br),o=Br.dot(hi),l=Br.dot(dc),u=hi.dot(hi),h=hi.dot(dc),f=s*u-o*o;if(f===0)return a.set(0,0,0),null;const d=1/f,p=(u*l-o*h)*d,_=(s*h-o*l)*d;return a.set(1-p-_,_,p)}static containsPoint(e,r,i,n){return this.getBarycoord(e,r,i,n,fi)===null?!1:fi.x>=0&&fi.y>=0&&fi.x+fi.y<=1}static getInterpolation(e,r,i,n,a,s,o,l){return this.getBarycoord(e,r,i,n,fi)===null?(l.x=0,l.y=0,"z"in l&&(l.z=0),"w"in l&&(l.w=0),null):(l.setScalar(0),l.addScaledVector(a,fi.x),l.addScaledVector(s,fi.y),l.addScaledVector(o,fi.z),l)}static isFrontFacing(e,r,i,n){return Br.subVectors(i,r),hi.subVectors(e,r),Br.cross(hi).dot(n)<0}set(e,r,i){return this.a.copy(e),this.b.copy(r),this.c.copy(i),this}setFromPointsAndIndices(e,r,i,n){return this.a.copy(e[r]),this.b.copy(e[i]),this.c.copy(e[n]),this}setFromAttributeAndIndices(e,r,i,n){return this.a.fromBufferAttribute(e,r),this.b.fromBufferAttribute(e,i),this.c.fromBufferAttribute(e,n),this}clone(){return new this.constructor().copy(this)}copy(e){return this.a.copy(e.a),this.b.copy(e.b),this.c.copy(e.c),this}getArea(){return Br.subVectors(this.c,this.b),hi.subVectors(this.a,this.b),Br.cross(hi).length()*.5}getMidpoint(e){return e.addVectors(this.a,this.b).add(this.c).multiplyScalar(1/3)}getNormal(e){return ii.getNormal(this.a,this.b,this.c,e)}getPlane(e){return e.setFromCoplanarPoints(this.a,this.b,this.c)}getBarycoord(e,r){return ii.getBarycoord(e,this.a,this.b,this.c,r)}getInterpolation(e,r,i,n,a){return ii.getInterpolation(e,this.a,this.b,this.c,r,i,n,a)}containsPoint(e){return ii.containsPoint(e,this.a,this.b,this.c)}isFrontFacing(e){return ii.isFrontFacing(this.a,this.b,this.c,e)}intersectsBox(e){return e.intersectsTriangle(this)}closestPointToPoint(e,r){const i=this.a,n=this.b,a=this.c;let s,o;ea.subVectors(n,i),ta.subVectors(a,i),hc.subVectors(e,i);const l=ea.dot(hc),u=ta.dot(hc);if(l<=0&&u<=0)return r.copy(i);fc.subVectors(e,n);const h=ea.dot(fc),f=ta.dot(fc);if(h>=0&&f<=h)return r.copy(n);const d=l*f-h*u;if(d<=0&&l>=0&&h<=0)return s=l/(l-h),r.copy(i).addScaledVector(ea,s);pc.subVectors(e,a);const p=ea.dot(pc),_=ta.dot(pc);if(_>=0&&p<=_)return r.copy(a);const x=p*u-l*_;if(x<=0&&u>=0&&_<=0)return o=u/(u-_),r.copy(i).addScaledVector(ta,o);const m=h*_-p*f;if(m<=0&&f-h>=0&&p-_>=0)return Dp.subVectors(a,n),o=(f-h)/(f-h+(p-_)),r.copy(n).addScaledVector(Dp,o);const c=1/(m+x+d);return s=x*c,o=d*c,r.copy(i).addScaledVector(ea,s).addScaledVector(ta,o)}equals(e){return e.a.equals(this.a)&&e.b.equals(this.b)&&e.c.equals(this.c)}}const n_={aliceblue:15792383,antiquewhite:16444375,aqua:65535,aquamarine:8388564,azure:15794175,beige:16119260,bisque:16770244,black:0,blanchedalmond:16772045,blue:255,blueviolet:9055202,brown:10824234,burlywood:14596231,cadetblue:6266528,chartreuse:8388352,chocolate:13789470,coral:16744272,cornflowerblue:6591981,cornsilk:16775388,crimson:14423100,cyan:65535,darkblue:139,darkcyan:35723,darkgoldenrod:12092939,darkgray:11119017,darkgreen:25600,darkgrey:11119017,darkkhaki:12433259,darkmagenta:9109643,darkolivegreen:5597999,darkorange:16747520,darkorchid:10040012,darkred:9109504,darksalmon:15308410,darkseagreen:9419919,darkslateblue:4734347,darkslategray:3100495,darkslategrey:3100495,darkturquoise:52945,darkviolet:9699539,deeppink:16716947,deepskyblue:49151,dimgray:6908265,dimgrey:6908265,dodgerblue:2003199,firebrick:11674146,floralwhite:16775920,forestgreen:2263842,fuchsia:16711935,gainsboro:14474460,ghostwhite:16316671,gold:16766720,goldenrod:14329120,gray:8421504,green:32768,greenyellow:11403055,grey:8421504,honeydew:15794160,hotpink:16738740,indianred:13458524,indigo:4915330,ivory:16777200,khaki:15787660,lavender:15132410,lavenderblush:16773365,lawngreen:8190976,lemonchiffon:16775885,lightblue:11393254,lightcoral:15761536,lightcyan:14745599,lightgoldenrodyellow:16448210,lightgray:13882323,lightgreen:9498256,lightgrey:13882323,lightpink:16758465,lightsalmon:16752762,lightseagreen:2142890,lightskyblue:8900346,lightslategray:7833753,lightslategrey:7833753,lightsteelblue:11584734,lightyellow:16777184,lime:65280,limegreen:3329330,linen:16445670,magenta:16711935,maroon:8388608,mediumaquamarine:6737322,mediumblue:205,mediumorchid:12211667,mediumpurple:9662683,mediumseagreen:3978097,mediumslateblue:8087790,mediumspringgreen:64154,mediumturquoise:4772300,mediumvioletred:13047173,midnightblue:1644912,mintcream:16121850,mistyrose:16770273,moccasin:16770229,navajowhite:16768685,navy:128,oldlace:16643558,olive:8421376,olivedrab:7048739,orange:16753920,orangered:16729344,orchid:14315734,palegoldenrod:15657130,palegreen:10025880,paleturquoise:11529966,palevioletred:14381203,papayawhip:16773077,peachpuff:16767673,peru:13468991,pink:16761035,plum:14524637,powderblue:11591910,purple:8388736,rebeccapurple:6697881,red:16711680,rosybrown:12357519,royalblue:4286945,saddlebrown:9127187,salmon:16416882,sandybrown:16032864,seagreen:3050327,seashell:16774638,sienna:10506797,silver:12632256,skyblue:8900331,slateblue:6970061,slategray:7372944,slategrey:7372944,snow:16775930,springgreen:65407,steelblue:4620980,tan:13808780,teal:32896,thistle:14204888,tomato:16737095,turquoise:4251856,violet:15631086,wheat:16113331,white:16777215,whitesmoke:16119285,yellow:16776960,yellowgreen:10145074},Oi={h:0,s:0,l:0},Io={h:0,s:0,l:0};function mc(t,e,r){return r<0&&(r+=1),r>1&&(r-=1),r<1/6?t+(e-t)*6*r:r<1/2?e:r<2/3?t+(e-t)*6*(2/3-r):t}class ke{constructor(e,r,i){return this.isColor=!0,this.r=1,this.g=1,this.b=1,this.set(e,r,i)}set(e,r,i){if(r===void 0&&i===void 0){const n=e;n&&n.isColor?this.copy(n):typeof n=="number"?this.setHex(n):typeof n=="string"&&this.setStyle(n)}else this.setRGB(e,r,i);return this}setScalar(e){return this.r=e,this.g=e,this.b=e,this}setHex(e,r=ei){return e=Math.floor(e),this.r=(e>>16&255)/255,this.g=(e>>8&255)/255,this.b=(e&255)/255,ut.toWorkingColorSpace(this,r),this}setRGB(e,r,i,n=ut.workingColorSpace){return this.r=e,this.g=r,this.b=i,ut.toWorkingColorSpace(this,n),this}setHSL(e,r,i,n=ut.workingColorSpace){if(e=Jy(e,1),r=nr(r,0,1),i=nr(i,0,1),r===0)this.r=this.g=this.b=i;else{const a=i<=.5?i*(1+r):i+r-i*r,s=2*i-a;this.r=mc(s,a,e+1/3),this.g=mc(s,a,e),this.b=mc(s,a,e-1/3)}return ut.toWorkingColorSpace(this,n),this}setStyle(e,r=ei){function i(a){a!==void 0&&parseFloat(a)<1&&console.warn("THREE.Color: Alpha component of "+e+" will be ignored.")}let n;if(n=/^(\w+)\(([^\)]*)\)/.exec(e)){let a;const s=n[1],o=n[2];switch(s){case"rgb":case"rgba":if(a=/^\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(o))return i(a[4]),this.setRGB(Math.min(255,parseInt(a[1],10))/255,Math.min(255,parseInt(a[2],10))/255,Math.min(255,parseInt(a[3],10))/255,r);if(a=/^\s*(\d+)\%\s*,\s*(\d+)\%\s*,\s*(\d+)\%\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(o))return i(a[4]),this.setRGB(Math.min(100,parseInt(a[1],10))/100,Math.min(100,parseInt(a[2],10))/100,Math.min(100,parseInt(a[3],10))/100,r);break;case"hsl":case"hsla":if(a=/^\s*(\d*\.?\d+)\s*,\s*(\d*\.?\d+)\%\s*,\s*(\d*\.?\d+)\%\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(o))return i(a[4]),this.setHSL(parseFloat(a[1])/360,parseFloat(a[2])/100,parseFloat(a[3])/100,r);break;default:console.warn("THREE.Color: Unknown color model "+e)}}else if(n=/^\#([A-Fa-f\d]+)$/.exec(e)){const a=n[1],s=a.length;if(s===3)return this.setRGB(parseInt(a.charAt(0),16)/15,parseInt(a.charAt(1),16)/15,parseInt(a.charAt(2),16)/15,r);if(s===6)return this.setHex(parseInt(a,16),r);console.warn("THREE.Color: Invalid hex color "+e)}else if(e&&e.length>0)return this.setColorName(e,r);return this}setColorName(e,r=ei){const i=n_[e.toLowerCase()];return i!==void 0?this.setHex(i,r):console.warn("THREE.Color: Unknown color "+e),this}clone(){return new this.constructor(this.r,this.g,this.b)}copy(e){return this.r=e.r,this.g=e.g,this.b=e.b,this}copySRGBToLinear(e){return this.r=Da(e.r),this.g=Da(e.g),this.b=Da(e.b),this}copyLinearToSRGB(e){return this.r=rc(e.r),this.g=rc(e.g),this.b=rc(e.b),this}convertSRGBToLinear(){return this.copySRGBToLinear(this),this}convertLinearToSRGB(){return this.copyLinearToSRGB(this),this}getHex(e=ei){return ut.fromWorkingColorSpace(Qt.copy(this),e),Math.round(nr(Qt.r*255,0,255))*65536+Math.round(nr(Qt.g*255,0,255))*256+Math.round(nr(Qt.b*255,0,255))}getHexString(e=ei){return("000000"+this.getHex(e).toString(16)).slice(-6)}getHSL(e,r=ut.workingColorSpace){ut.fromWorkingColorSpace(Qt.copy(this),r);const i=Qt.r,n=Qt.g,a=Qt.b,s=Math.max(i,n,a),o=Math.min(i,n,a);let l,u;const h=(o+s)/2;if(o===s)l=0,u=0;else{const f=s-o;switch(u=h<=.5?f/(s+o):f/(2-s-o),s){case i:l=(n-a)/f+(n<a?6:0);break;case n:l=(a-i)/f+2;break;case a:l=(i-n)/f+4;break}l/=6}return e.h=l,e.s=u,e.l=h,e}getRGB(e,r=ut.workingColorSpace){return ut.fromWorkingColorSpace(Qt.copy(this),r),e.r=Qt.r,e.g=Qt.g,e.b=Qt.b,e}getStyle(e=ei){ut.fromWorkingColorSpace(Qt.copy(this),e);const r=Qt.r,i=Qt.g,n=Qt.b;return e!==ei?`color(${e} ${r.toFixed(3)} ${i.toFixed(3)} ${n.toFixed(3)})`:`rgb(${Math.round(r*255)},${Math.round(i*255)},${Math.round(n*255)})`}offsetHSL(e,r,i){return this.getHSL(Oi),this.setHSL(Oi.h+e,Oi.s+r,Oi.l+i)}add(e){return this.r+=e.r,this.g+=e.g,this.b+=e.b,this}addColors(e,r){return this.r=e.r+r.r,this.g=e.g+r.g,this.b=e.b+r.b,this}addScalar(e){return this.r+=e,this.g+=e,this.b+=e,this}sub(e){return this.r=Math.max(0,this.r-e.r),this.g=Math.max(0,this.g-e.g),this.b=Math.max(0,this.b-e.b),this}multiply(e){return this.r*=e.r,this.g*=e.g,this.b*=e.b,this}multiplyScalar(e){return this.r*=e,this.g*=e,this.b*=e,this}lerp(e,r){return this.r+=(e.r-this.r)*r,this.g+=(e.g-this.g)*r,this.b+=(e.b-this.b)*r,this}lerpColors(e,r,i){return this.r=e.r+(r.r-e.r)*i,this.g=e.g+(r.g-e.g)*i,this.b=e.b+(r.b-e.b)*i,this}lerpHSL(e,r){this.getHSL(Oi),e.getHSL(Io);const i=ec(Oi.h,Io.h,r),n=ec(Oi.s,Io.s,r),a=ec(Oi.l,Io.l,r);return this.setHSL(i,n,a),this}setFromVector3(e){return this.r=e.x,this.g=e.y,this.b=e.z,this}applyMatrix3(e){const r=this.r,i=this.g,n=this.b,a=e.elements;return this.r=a[0]*r+a[3]*i+a[6]*n,this.g=a[1]*r+a[4]*i+a[7]*n,this.b=a[2]*r+a[5]*i+a[8]*n,this}equals(e){return e.r===this.r&&e.g===this.g&&e.b===this.b}fromArray(e,r=0){return this.r=e[r],this.g=e[r+1],this.b=e[r+2],this}toArray(e=[],r=0){return e[r]=this.r,e[r+1]=this.g,e[r+2]=this.b,e}fromBufferAttribute(e,r){return this.r=e.getX(r),this.g=e.getY(r),this.b=e.getZ(r),this}toJSON(){return this.getHex()}*[Symbol.iterator](){yield this.r,yield this.g,yield this.b}}const Qt=new ke;ke.NAMES=n_;let gM=0;class Qa extends Gn{constructor(){super(),this.isMaterial=!0,Object.defineProperty(this,"id",{value:gM++}),this.uuid=no(),this.name="",this.type="Material",this.blending=La,this.side=on,this.vertexColors=!1,this.opacity=1,this.transparent=!1,this.alphaHash=!1,this.blendSrc=bd,this.blendDst=Ed,this.blendEquation=wn,this.blendSrcAlpha=null,this.blendDstAlpha=null,this.blendEquationAlpha=null,this.blendColor=new ke(0,0,0),this.blendAlpha=0,this.depthFunc=zl,this.depthTest=!0,this.depthWrite=!0,this.stencilWriteMask=255,this.stencilFunc=xp,this.stencilRef=0,this.stencilFuncMask=255,this.stencilFail=Xn,this.stencilZFail=Xn,this.stencilZPass=Xn,this.stencilWrite=!1,this.clippingPlanes=null,this.clipIntersection=!1,this.clipShadows=!1,this.shadowSide=null,this.colorWrite=!0,this.precision=null,this.polygonOffset=!1,this.polygonOffsetFactor=0,this.polygonOffsetUnits=0,this.dithering=!1,this.alphaToCoverage=!1,this.premultipliedAlpha=!1,this.forceSinglePass=!1,this.visible=!0,this.toneMapped=!0,this.userData={},this.version=0,this._alphaTest=0}get alphaTest(){return this._alphaTest}set alphaTest(e){this._alphaTest>0!=e>0&&this.version++,this._alphaTest=e}onBuild(){}onBeforeRender(){}onBeforeCompile(){}customProgramCacheKey(){return this.onBeforeCompile.toString()}setValues(e){if(e!==void 0)for(const r in e){const i=e[r];if(i===void 0){console.warn(`THREE.Material: parameter '${r}' has value of undefined.`);continue}const n=this[r];if(n===void 0){console.warn(`THREE.Material: '${r}' is not a property of THREE.${this.type}.`);continue}n&&n.isColor?n.set(i):n&&n.isVector3&&i&&i.isVector3?n.copy(i):this[r]=i}}toJSON(e){const r=e===void 0||typeof e=="string";r&&(e={textures:{},images:{}});const i={metadata:{version:4.6,type:"Material",generator:"Material.toJSON"}};i.uuid=this.uuid,i.type=this.type,this.name!==""&&(i.name=this.name),this.color&&this.color.isColor&&(i.color=this.color.getHex()),this.roughness!==void 0&&(i.roughness=this.roughness),this.metalness!==void 0&&(i.metalness=this.metalness),this.sheen!==void 0&&(i.sheen=this.sheen),this.sheenColor&&this.sheenColor.isColor&&(i.sheenColor=this.sheenColor.getHex()),this.sheenRoughness!==void 0&&(i.sheenRoughness=this.sheenRoughness),this.emissive&&this.emissive.isColor&&(i.emissive=this.emissive.getHex()),this.emissiveIntensity!==void 0&&this.emissiveIntensity!==1&&(i.emissiveIntensity=this.emissiveIntensity),this.specular&&this.specular.isColor&&(i.specular=this.specular.getHex()),this.specularIntensity!==void 0&&(i.specularIntensity=this.specularIntensity),this.specularColor&&this.specularColor.isColor&&(i.specularColor=this.specularColor.getHex()),this.shininess!==void 0&&(i.shininess=this.shininess),this.clearcoat!==void 0&&(i.clearcoat=this.clearcoat),this.clearcoatRoughness!==void 0&&(i.clearcoatRoughness=this.clearcoatRoughness),this.clearcoatMap&&this.clearcoatMap.isTexture&&(i.clearcoatMap=this.clearcoatMap.toJSON(e).uuid),this.clearcoatRoughnessMap&&this.clearcoatRoughnessMap.isTexture&&(i.clearcoatRoughnessMap=this.clearcoatRoughnessMap.toJSON(e).uuid),this.clearcoatNormalMap&&this.clearcoatNormalMap.isTexture&&(i.clearcoatNormalMap=this.clearcoatNormalMap.toJSON(e).uuid,i.clearcoatNormalScale=this.clearcoatNormalScale.toArray()),this.dispersion!==void 0&&(i.dispersion=this.dispersion),this.iridescence!==void 0&&(i.iridescence=this.iridescence),this.iridescenceIOR!==void 0&&(i.iridescenceIOR=this.iridescenceIOR),this.iridescenceThicknessRange!==void 0&&(i.iridescenceThicknessRange=this.iridescenceThicknessRange),this.iridescenceMap&&this.iridescenceMap.isTexture&&(i.iridescenceMap=this.iridescenceMap.toJSON(e).uuid),this.iridescenceThicknessMap&&this.iridescenceThicknessMap.isTexture&&(i.iridescenceThicknessMap=this.iridescenceThicknessMap.toJSON(e).uuid),this.anisotropy!==void 0&&(i.anisotropy=this.anisotropy),this.anisotropyRotation!==void 0&&(i.anisotropyRotation=this.anisotropyRotation),this.anisotropyMap&&this.anisotropyMap.isTexture&&(i.anisotropyMap=this.anisotropyMap.toJSON(e).uuid),this.map&&this.map.isTexture&&(i.map=this.map.toJSON(e).uuid),this.matcap&&this.matcap.isTexture&&(i.matcap=this.matcap.toJSON(e).uuid),this.alphaMap&&this.alphaMap.isTexture&&(i.alphaMap=this.alphaMap.toJSON(e).uuid),this.lightMap&&this.lightMap.isTexture&&(i.lightMap=this.lightMap.toJSON(e).uuid,i.lightMapIntensity=this.lightMapIntensity),this.aoMap&&this.aoMap.isTexture&&(i.aoMap=this.aoMap.toJSON(e).uuid,i.aoMapIntensity=this.aoMapIntensity),this.bumpMap&&this.bumpMap.isTexture&&(i.bumpMap=this.bumpMap.toJSON(e).uuid,i.bumpScale=this.bumpScale),this.normalMap&&this.normalMap.isTexture&&(i.normalMap=this.normalMap.toJSON(e).uuid,i.normalMapType=this.normalMapType,i.normalScale=this.normalScale.toArray()),this.displacementMap&&this.displacementMap.isTexture&&(i.displacementMap=this.displacementMap.toJSON(e).uuid,i.displacementScale=this.displacementScale,i.displacementBias=this.displacementBias),this.roughnessMap&&this.roughnessMap.isTexture&&(i.roughnessMap=this.roughnessMap.toJSON(e).uuid),this.metalnessMap&&this.metalnessMap.isTexture&&(i.metalnessMap=this.metalnessMap.toJSON(e).uuid),this.emissiveMap&&this.emissiveMap.isTexture&&(i.emissiveMap=this.emissiveMap.toJSON(e).uuid),this.specularMap&&this.specularMap.isTexture&&(i.specularMap=this.specularMap.toJSON(e).uuid),this.specularIntensityMap&&this.specularIntensityMap.isTexture&&(i.specularIntensityMap=this.specularIntensityMap.toJSON(e).uuid),this.specularColorMap&&this.specularColorMap.isTexture&&(i.specularColorMap=this.specularColorMap.toJSON(e).uuid),this.envMap&&this.envMap.isTexture&&(i.envMap=this.envMap.toJSON(e).uuid,this.combine!==void 0&&(i.combine=this.combine)),this.envMapRotation!==void 0&&(i.envMapRotation=this.envMapRotation.toArray()),this.envMapIntensity!==void 0&&(i.envMapIntensity=this.envMapIntensity),this.reflectivity!==void 0&&(i.reflectivity=this.reflectivity),this.refractionRatio!==void 0&&(i.refractionRatio=this.refractionRatio),this.gradientMap&&this.gradientMap.isTexture&&(i.gradientMap=this.gradientMap.toJSON(e).uuid),this.transmission!==void 0&&(i.transmission=this.transmission),this.transmissionMap&&this.transmissionMap.isTexture&&(i.transmissionMap=this.transmissionMap.toJSON(e).uuid),this.thickness!==void 0&&(i.thickness=this.thickness),this.thicknessMap&&this.thicknessMap.isTexture&&(i.thicknessMap=this.thicknessMap.toJSON(e).uuid),this.attenuationDistance!==void 0&&this.attenuationDistance!==1/0&&(i.attenuationDistance=this.attenuationDistance),this.attenuationColor!==void 0&&(i.attenuationColor=this.attenuationColor.getHex()),this.size!==void 0&&(i.size=this.size),this.shadowSide!==null&&(i.shadowSide=this.shadowSide),this.sizeAttenuation!==void 0&&(i.sizeAttenuation=this.sizeAttenuation),this.blending!==La&&(i.blending=this.blending),this.side!==on&&(i.side=this.side),this.vertexColors===!0&&(i.vertexColors=!0),this.opacity<1&&(i.opacity=this.opacity),this.transparent===!0&&(i.transparent=!0),this.blendSrc!==bd&&(i.blendSrc=this.blendSrc),this.blendDst!==Ed&&(i.blendDst=this.blendDst),this.blendEquation!==wn&&(i.blendEquation=this.blendEquation),this.blendSrcAlpha!==null&&(i.blendSrcAlpha=this.blendSrcAlpha),this.blendDstAlpha!==null&&(i.blendDstAlpha=this.blendDstAlpha),this.blendEquationAlpha!==null&&(i.blendEquationAlpha=this.blendEquationAlpha),this.blendColor&&this.blendColor.isColor&&(i.blendColor=this.blendColor.getHex()),this.blendAlpha!==0&&(i.blendAlpha=this.blendAlpha),this.depthFunc!==zl&&(i.depthFunc=this.depthFunc),this.depthTest===!1&&(i.depthTest=this.depthTest),this.depthWrite===!1&&(i.depthWrite=this.depthWrite),this.colorWrite===!1&&(i.colorWrite=this.colorWrite),this.stencilWriteMask!==255&&(i.stencilWriteMask=this.stencilWriteMask),this.stencilFunc!==xp&&(i.stencilFunc=this.stencilFunc),this.stencilRef!==0&&(i.stencilRef=this.stencilRef),this.stencilFuncMask!==255&&(i.stencilFuncMask=this.stencilFuncMask),this.stencilFail!==Xn&&(i.stencilFail=this.stencilFail),this.stencilZFail!==Xn&&(i.stencilZFail=this.stencilZFail),this.stencilZPass!==Xn&&(i.stencilZPass=this.stencilZPass),this.stencilWrite===!0&&(i.stencilWrite=this.stencilWrite),this.rotation!==void 0&&this.rotation!==0&&(i.rotation=this.rotation),this.polygonOffset===!0&&(i.polygonOffset=!0),this.polygonOffsetFactor!==0&&(i.polygonOffsetFactor=this.polygonOffsetFactor),this.polygonOffsetUnits!==0&&(i.polygonOffsetUnits=this.polygonOffsetUnits),this.linewidth!==void 0&&this.linewidth!==1&&(i.linewidth=this.linewidth),this.dashSize!==void 0&&(i.dashSize=this.dashSize),this.gapSize!==void 0&&(i.gapSize=this.gapSize),this.scale!==void 0&&(i.scale=this.scale),this.dithering===!0&&(i.dithering=!0),this.alphaTest>0&&(i.alphaTest=this.alphaTest),this.alphaHash===!0&&(i.alphaHash=!0),this.alphaToCoverage===!0&&(i.alphaToCoverage=!0),this.premultipliedAlpha===!0&&(i.premultipliedAlpha=!0),this.forceSinglePass===!0&&(i.forceSinglePass=!0),this.wireframe===!0&&(i.wireframe=!0),this.wireframeLinewidth>1&&(i.wireframeLinewidth=this.wireframeLinewidth),this.wireframeLinecap!=="round"&&(i.wireframeLinecap=this.wireframeLinecap),this.wireframeLinejoin!=="round"&&(i.wireframeLinejoin=this.wireframeLinejoin),this.flatShading===!0&&(i.flatShading=!0),this.visible===!1&&(i.visible=!1),this.toneMapped===!1&&(i.toneMapped=!1),this.fog===!1&&(i.fog=!1),Object.keys(this.userData).length>0&&(i.userData=this.userData);function n(a){const s=[];for(const o in a){const l=a[o];delete l.metadata,s.push(l)}return s}if(r){const a=n(e.textures),s=n(e.images);a.length>0&&(i.textures=a),s.length>0&&(i.images=s)}return i}clone(){return new this.constructor().copy(this)}copy(e){this.name=e.name,this.blending=e.blending,this.side=e.side,this.vertexColors=e.vertexColors,this.opacity=e.opacity,this.transparent=e.transparent,this.blendSrc=e.blendSrc,this.blendDst=e.blendDst,this.blendEquation=e.blendEquation,this.blendSrcAlpha=e.blendSrcAlpha,this.blendDstAlpha=e.blendDstAlpha,this.blendEquationAlpha=e.blendEquationAlpha,this.blendColor.copy(e.blendColor),this.blendAlpha=e.blendAlpha,this.depthFunc=e.depthFunc,this.depthTest=e.depthTest,this.depthWrite=e.depthWrite,this.stencilWriteMask=e.stencilWriteMask,this.stencilFunc=e.stencilFunc,this.stencilRef=e.stencilRef,this.stencilFuncMask=e.stencilFuncMask,this.stencilFail=e.stencilFail,this.stencilZFail=e.stencilZFail,this.stencilZPass=e.stencilZPass,this.stencilWrite=e.stencilWrite;const r=e.clippingPlanes;let i=null;if(r!==null){const n=r.length;i=new Array(n);for(let a=0;a!==n;++a)i[a]=r[a].clone()}return this.clippingPlanes=i,this.clipIntersection=e.clipIntersection,this.clipShadows=e.clipShadows,this.shadowSide=e.shadowSide,this.colorWrite=e.colorWrite,this.precision=e.precision,this.polygonOffset=e.polygonOffset,this.polygonOffsetFactor=e.polygonOffsetFactor,this.polygonOffsetUnits=e.polygonOffsetUnits,this.dithering=e.dithering,this.alphaTest=e.alphaTest,this.alphaHash=e.alphaHash,this.alphaToCoverage=e.alphaToCoverage,this.premultipliedAlpha=e.premultipliedAlpha,this.forceSinglePass=e.forceSinglePass,this.visible=e.visible,this.toneMapped=e.toneMapped,this.userData=JSON.parse(JSON.stringify(e.userData)),this}dispose(){this.dispatchEvent({type:"dispose"})}set needsUpdate(e){e===!0&&this.version++}}class Is extends Qa{constructor(e){super(),this.isMeshBasicMaterial=!0,this.type="MeshBasicMaterial",this.color=new ke(16777215),this.map=null,this.lightMap=null,this.lightMapIntensity=1,this.aoMap=null,this.aoMapIntensity=1,this.specularMap=null,this.alphaMap=null,this.envMap=null,this.envMapRotation=new oi,this.combine=Hv,this.reflectivity=1,this.refractionRatio=.98,this.wireframe=!1,this.wireframeLinewidth=1,this.wireframeLinecap="round",this.wireframeLinejoin="round",this.fog=!0,this.setValues(e)}copy(e){return super.copy(e),this.color.copy(e.color),this.map=e.map,this.lightMap=e.lightMap,this.lightMapIntensity=e.lightMapIntensity,this.aoMap=e.aoMap,this.aoMapIntensity=e.aoMapIntensity,this.specularMap=e.specularMap,this.alphaMap=e.alphaMap,this.envMap=e.envMap,this.envMapRotation.copy(e.envMapRotation),this.combine=e.combine,this.reflectivity=e.reflectivity,this.refractionRatio=e.refractionRatio,this.wireframe=e.wireframe,this.wireframeLinewidth=e.wireframeLinewidth,this.wireframeLinecap=e.wireframeLinecap,this.wireframeLinejoin=e.wireframeLinejoin,this.fog=e.fog,this}}const Lt=new O,No=new Ne;class Kr{constructor(e,r,i=!1){if(Array.isArray(e))throw new TypeError("THREE.BufferAttribute: array should be a Typed Array.");this.isBufferAttribute=!0,this.name="",this.array=e,this.itemSize=r,this.count=e!==void 0?e.length/r:0,this.normalized=i,this.usage=yp,this._updateRange={offset:0,count:-1},this.updateRanges=[],this.gpuType=Mi,this.version=0}onUploadCallback(){}set needsUpdate(e){e===!0&&this.version++}get updateRange(){return t_("THREE.BufferAttribute: updateRange() is deprecated and will be removed in r169. Use addUpdateRange() instead."),this._updateRange}setUsage(e){return this.usage=e,this}addUpdateRange(e,r){this.updateRanges.push({start:e,count:r})}clearUpdateRanges(){this.updateRanges.length=0}copy(e){return this.name=e.name,this.array=new e.array.constructor(e.array),this.itemSize=e.itemSize,this.count=e.count,this.normalized=e.normalized,this.usage=e.usage,this.gpuType=e.gpuType,this}copyAt(e,r,i){e*=this.itemSize,i*=r.itemSize;for(let n=0,a=this.itemSize;n<a;n++)this.array[e+n]=r.array[i+n];return this}copyArray(e){return this.array.set(e),this}applyMatrix3(e){if(this.itemSize===2)for(let r=0,i=this.count;r<i;r++)No.fromBufferAttribute(this,r),No.applyMatrix3(e),this.setXY(r,No.x,No.y);else if(this.itemSize===3)for(let r=0,i=this.count;r<i;r++)Lt.fromBufferAttribute(this,r),Lt.applyMatrix3(e),this.setXYZ(r,Lt.x,Lt.y,Lt.z);return this}applyMatrix4(e){for(let r=0,i=this.count;r<i;r++)Lt.fromBufferAttribute(this,r),Lt.applyMatrix4(e),this.setXYZ(r,Lt.x,Lt.y,Lt.z);return this}applyNormalMatrix(e){for(let r=0,i=this.count;r<i;r++)Lt.fromBufferAttribute(this,r),Lt.applyNormalMatrix(e),this.setXYZ(r,Lt.x,Lt.y,Lt.z);return this}transformDirection(e){for(let r=0,i=this.count;r<i;r++)Lt.fromBufferAttribute(this,r),Lt.transformDirection(e),this.setXYZ(r,Lt.x,Lt.y,Lt.z);return this}set(e,r=0){return this.array.set(e,r),this}getComponent(e,r){let i=this.array[e*this.itemSize+r];return this.normalized&&(i=us(i,this.array)),i}setComponent(e,r,i){return this.normalized&&(i=ur(i,this.array)),this.array[e*this.itemSize+r]=i,this}getX(e){let r=this.array[e*this.itemSize];return this.normalized&&(r=us(r,this.array)),r}setX(e,r){return this.normalized&&(r=ur(r,this.array)),this.array[e*this.itemSize]=r,this}getY(e){let r=this.array[e*this.itemSize+1];return this.normalized&&(r=us(r,this.array)),r}setY(e,r){return this.normalized&&(r=ur(r,this.array)),this.array[e*this.itemSize+1]=r,this}getZ(e){let r=this.array[e*this.itemSize+2];return this.normalized&&(r=us(r,this.array)),r}setZ(e,r){return this.normalized&&(r=ur(r,this.array)),this.array[e*this.itemSize+2]=r,this}getW(e){let r=this.array[e*this.itemSize+3];return this.normalized&&(r=us(r,this.array)),r}setW(e,r){return this.normalized&&(r=ur(r,this.array)),this.array[e*this.itemSize+3]=r,this}setXY(e,r,i){return e*=this.itemSize,this.normalized&&(r=ur(r,this.array),i=ur(i,this.array)),this.array[e+0]=r,this.array[e+1]=i,this}setXYZ(e,r,i,n){return e*=this.itemSize,this.normalized&&(r=ur(r,this.array),i=ur(i,this.array),n=ur(n,this.array)),this.array[e+0]=r,this.array[e+1]=i,this.array[e+2]=n,this}setXYZW(e,r,i,n,a){return e*=this.itemSize,this.normalized&&(r=ur(r,this.array),i=ur(i,this.array),n=ur(n,this.array),a=ur(a,this.array)),this.array[e+0]=r,this.array[e+1]=i,this.array[e+2]=n,this.array[e+3]=a,this}onUpload(e){return this.onUploadCallback=e,this}clone(){return new this.constructor(this.array,this.itemSize).copy(this)}toJSON(){const e={itemSize:this.itemSize,type:this.array.constructor.name,array:Array.from(this.array),normalized:this.normalized};return this.name!==""&&(e.name=this.name),this.usage!==yp&&(e.usage=this.usage),e}}class a_ extends Kr{constructor(e,r,i){super(new Uint16Array(e),r,i)}}class s_ extends Kr{constructor(e,r,i){super(new Uint32Array(e),r,i)}}class Yt extends Kr{constructor(e,r,i){super(new Float32Array(e),r,i)}}let vM=0;const Rr=new ft,gc=new Rt,ra=new O,yr=new Wn,fs=new Wn,Bt=new O;class Or extends Gn{constructor(){super(),this.isBufferGeometry=!0,Object.defineProperty(this,"id",{value:vM++}),this.uuid=no(),this.name="",this.type="BufferGeometry",this.index=null,this.attributes={},this.morphAttributes={},this.morphTargetsRelative=!1,this.groups=[],this.boundingBox=null,this.boundingSphere=null,this.drawRange={start:0,count:1/0},this.userData={}}getIndex(){return this.index}setIndex(e){return Array.isArray(e)?this.index=new(e_(e)?s_:a_)(e,1):this.index=e,this}getAttribute(e){return this.attributes[e]}setAttribute(e,r){return this.attributes[e]=r,this}deleteAttribute(e){return delete this.attributes[e],this}hasAttribute(e){return this.attributes[e]!==void 0}addGroup(e,r,i=0){this.groups.push({start:e,count:r,materialIndex:i})}clearGroups(){this.groups=[]}setDrawRange(e,r){this.drawRange.start=e,this.drawRange.count=r}applyMatrix4(e){const r=this.attributes.position;r!==void 0&&(r.applyMatrix4(e),r.needsUpdate=!0);const i=this.attributes.normal;if(i!==void 0){const a=new Ke().getNormalMatrix(e);i.applyNormalMatrix(a),i.needsUpdate=!0}const n=this.attributes.tangent;return n!==void 0&&(n.transformDirection(e),n.needsUpdate=!0),this.boundingBox!==null&&this.computeBoundingBox(),this.boundingSphere!==null&&this.computeBoundingSphere(),this}applyQuaternion(e){return Rr.makeRotationFromQuaternion(e),this.applyMatrix4(Rr),this}rotateX(e){return Rr.makeRotationX(e),this.applyMatrix4(Rr),this}rotateY(e){return Rr.makeRotationY(e),this.applyMatrix4(Rr),this}rotateZ(e){return Rr.makeRotationZ(e),this.applyMatrix4(Rr),this}translate(e,r,i){return Rr.makeTranslation(e,r,i),this.applyMatrix4(Rr),this}scale(e,r,i){return Rr.makeScale(e,r,i),this.applyMatrix4(Rr),this}lookAt(e){return gc.lookAt(e),gc.updateMatrix(),this.applyMatrix4(gc.matrix),this}center(){return this.computeBoundingBox(),this.boundingBox.getCenter(ra).negate(),this.translate(ra.x,ra.y,ra.z),this}setFromPoints(e){const r=[];for(let i=0,n=e.length;i<n;i++){const a=e[i];r.push(a.x,a.y,a.z||0)}return this.setAttribute("position",new Yt(r,3)),this}computeBoundingBox(){this.boundingBox===null&&(this.boundingBox=new Wn);const e=this.attributes.position,r=this.morphAttributes.position;if(e&&e.isGLBufferAttribute){console.error("THREE.BufferGeometry.computeBoundingBox(): GLBufferAttribute requires a manual bounding box.",this),this.boundingBox.set(new O(-1/0,-1/0,-1/0),new O(1/0,1/0,1/0));return}if(e!==void 0){if(this.boundingBox.setFromBufferAttribute(e),r)for(let i=0,n=r.length;i<n;i++){const a=r[i];yr.setFromBufferAttribute(a),this.morphTargetsRelative?(Bt.addVectors(this.boundingBox.min,yr.min),this.boundingBox.expandByPoint(Bt),Bt.addVectors(this.boundingBox.max,yr.max),this.boundingBox.expandByPoint(Bt)):(this.boundingBox.expandByPoint(yr.min),this.boundingBox.expandByPoint(yr.max))}}else this.boundingBox.makeEmpty();(isNaN(this.boundingBox.min.x)||isNaN(this.boundingBox.min.y)||isNaN(this.boundingBox.min.z))&&console.error('THREE.BufferGeometry.computeBoundingBox(): Computed min/max have NaN values. The "position" attribute is likely to have NaN values.',this)}computeBoundingSphere(){this.boundingSphere===null&&(this.boundingSphere=new $a);const e=this.attributes.position,r=this.morphAttributes.position;if(e&&e.isGLBufferAttribute){console.error("THREE.BufferGeometry.computeBoundingSphere(): GLBufferAttribute requires a manual bounding sphere.",this),this.boundingSphere.set(new O,1/0);return}if(e){const i=this.boundingSphere.center;if(yr.setFromBufferAttribute(e),r)for(let a=0,s=r.length;a<s;a++){const o=r[a];fs.setFromBufferAttribute(o),this.morphTargetsRelative?(Bt.addVectors(yr.min,fs.min),yr.expandByPoint(Bt),Bt.addVectors(yr.max,fs.max),yr.expandByPoint(Bt)):(yr.expandByPoint(fs.min),yr.expandByPoint(fs.max))}yr.getCenter(i);let n=0;for(let a=0,s=e.count;a<s;a++)Bt.fromBufferAttribute(e,a),n=Math.max(n,i.distanceToSquared(Bt));if(r)for(let a=0,s=r.length;a<s;a++){const o=r[a],l=this.morphTargetsRelative;for(let u=0,h=o.count;u<h;u++)Bt.fromBufferAttribute(o,u),l&&(ra.fromBufferAttribute(e,u),Bt.add(ra)),n=Math.max(n,i.distanceToSquared(Bt))}this.boundingSphere.radius=Math.sqrt(n),isNaN(this.boundingSphere.radius)&&console.error('THREE.BufferGeometry.computeBoundingSphere(): Computed radius is NaN. The "position" attribute is likely to have NaN values.',this)}}computeTangents(){const e=this.index,r=this.attributes;if(e===null||r.position===void 0||r.normal===void 0||r.uv===void 0){console.error("THREE.BufferGeometry: .computeTangents() failed. Missing required attributes (index, position, normal or uv)");return}const i=r.position,n=r.normal,a=r.uv;this.hasAttribute("tangent")===!1&&this.setAttribute("tangent",new Kr(new Float32Array(4*i.count),4));const s=this.getAttribute("tangent"),o=[],l=[];for(let L=0;L<i.count;L++)o[L]=new O,l[L]=new O;const u=new O,h=new O,f=new O,d=new Ne,p=new Ne,_=new Ne,x=new O,m=new O;function c(L,b,y){u.fromBufferAttribute(i,L),h.fromBufferAttribute(i,b),f.fromBufferAttribute(i,y),d.fromBufferAttribute(a,L),p.fromBufferAttribute(a,b),_.fromBufferAttribute(a,y),h.sub(u),f.sub(u),p.sub(d),_.sub(d);const U=1/(p.x*_.y-_.x*p.y);isFinite(U)&&(x.copy(h).multiplyScalar(_.y).addScaledVector(f,-p.y).multiplyScalar(U),m.copy(f).multiplyScalar(p.x).addScaledVector(h,-_.x).multiplyScalar(U),o[L].add(x),o[b].add(x),o[y].add(x),l[L].add(m),l[b].add(m),l[y].add(m))}let g=this.groups;g.length===0&&(g=[{start:0,count:e.count}]);for(let L=0,b=g.length;L<b;++L){const y=g[L],U=y.start,B=y.count;for(let V=U,q=U+B;V<q;V+=3)c(e.getX(V+0),e.getX(V+1),e.getX(V+2))}const v=new O,M=new O,P=new O,T=new O;function w(L){P.fromBufferAttribute(n,L),T.copy(P);const b=o[L];v.copy(b),v.sub(P.multiplyScalar(P.dot(b))).normalize(),M.crossVectors(T,b);const y=M.dot(l[L])<0?-1:1;s.setXYZW(L,v.x,v.y,v.z,y)}for(let L=0,b=g.length;L<b;++L){const y=g[L],U=y.start,B=y.count;for(let V=U,q=U+B;V<q;V+=3)w(e.getX(V+0)),w(e.getX(V+1)),w(e.getX(V+2))}}computeVertexNormals(){const e=this.index,r=this.getAttribute("position");if(r!==void 0){let i=this.getAttribute("normal");if(i===void 0)i=new Kr(new Float32Array(r.count*3),3),this.setAttribute("normal",i);else for(let d=0,p=i.count;d<p;d++)i.setXYZ(d,0,0,0);const n=new O,a=new O,s=new O,o=new O,l=new O,u=new O,h=new O,f=new O;if(e)for(let d=0,p=e.count;d<p;d+=3){const _=e.getX(d+0),x=e.getX(d+1),m=e.getX(d+2);n.fromBufferAttribute(r,_),a.fromBufferAttribute(r,x),s.fromBufferAttribute(r,m),h.subVectors(s,a),f.subVectors(n,a),h.cross(f),o.fromBufferAttribute(i,_),l.fromBufferAttribute(i,x),u.fromBufferAttribute(i,m),o.add(h),l.add(h),u.add(h),i.setXYZ(_,o.x,o.y,o.z),i.setXYZ(x,l.x,l.y,l.z),i.setXYZ(m,u.x,u.y,u.z)}else for(let d=0,p=r.count;d<p;d+=3)n.fromBufferAttribute(r,d+0),a.fromBufferAttribute(r,d+1),s.fromBufferAttribute(r,d+2),h.subVectors(s,a),f.subVectors(n,a),h.cross(f),i.setXYZ(d+0,h.x,h.y,h.z),i.setXYZ(d+1,h.x,h.y,h.z),i.setXYZ(d+2,h.x,h.y,h.z);this.normalizeNormals(),i.needsUpdate=!0}}normalizeNormals(){const e=this.attributes.normal;for(let r=0,i=e.count;r<i;r++)Bt.fromBufferAttribute(e,r),Bt.normalize(),e.setXYZ(r,Bt.x,Bt.y,Bt.z)}toNonIndexed(){function e(o,l){const u=o.array,h=o.itemSize,f=o.normalized,d=new u.constructor(l.length*h);let p=0,_=0;for(let x=0,m=l.length;x<m;x++){o.isInterleavedBufferAttribute?p=l[x]*o.data.stride+o.offset:p=l[x]*h;for(let c=0;c<h;c++)d[_++]=u[p++]}return new Kr(d,h,f)}if(this.index===null)return console.warn("THREE.BufferGeometry.toNonIndexed(): BufferGeometry is already non-indexed."),this;const r=new Or,i=this.index.array,n=this.attributes;for(const o in n){const l=n[o],u=e(l,i);r.setAttribute(o,u)}const a=this.morphAttributes;for(const o in a){const l=[],u=a[o];for(let h=0,f=u.length;h<f;h++){const d=u[h],p=e(d,i);l.push(p)}r.morphAttributes[o]=l}r.morphTargetsRelative=this.morphTargetsRelative;const s=this.groups;for(let o=0,l=s.length;o<l;o++){const u=s[o];r.addGroup(u.start,u.count,u.materialIndex)}return r}toJSON(){const e={metadata:{version:4.6,type:"BufferGeometry",generator:"BufferGeometry.toJSON"}};if(e.uuid=this.uuid,e.type=this.type,this.name!==""&&(e.name=this.name),Object.keys(this.userData).length>0&&(e.userData=this.userData),this.parameters!==void 0){const l=this.parameters;for(const u in l)l[u]!==void 0&&(e[u]=l[u]);return e}e.data={attributes:{}};const r=this.index;r!==null&&(e.data.index={type:r.array.constructor.name,array:Array.prototype.slice.call(r.array)});const i=this.attributes;for(const l in i){const u=i[l];e.data.attributes[l]=u.toJSON(e.data)}const n={};let a=!1;for(const l in this.morphAttributes){const u=this.morphAttributes[l],h=[];for(let f=0,d=u.length;f<d;f++){const p=u[f];h.push(p.toJSON(e.data))}h.length>0&&(n[l]=h,a=!0)}a&&(e.data.morphAttributes=n,e.data.morphTargetsRelative=this.morphTargetsRelative);const s=this.groups;s.length>0&&(e.data.groups=JSON.parse(JSON.stringify(s)));const o=this.boundingSphere;return o!==null&&(e.data.boundingSphere={center:o.center.toArray(),radius:o.radius}),e}clone(){return new this.constructor().copy(this)}copy(e){this.index=null,this.attributes={},this.morphAttributes={},this.groups=[],this.boundingBox=null,this.boundingSphere=null;const r={};this.name=e.name;const i=e.index;i!==null&&this.setIndex(i.clone(r));const n=e.attributes;for(const u in n){const h=n[u];this.setAttribute(u,h.clone(r))}const a=e.morphAttributes;for(const u in a){const h=[],f=a[u];for(let d=0,p=f.length;d<p;d++)h.push(f[d].clone(r));this.morphAttributes[u]=h}this.morphTargetsRelative=e.morphTargetsRelative;const s=e.groups;for(let u=0,h=s.length;u<h;u++){const f=s[u];this.addGroup(f.start,f.count,f.materialIndex)}const o=e.boundingBox;o!==null&&(this.boundingBox=o.clone());const l=e.boundingSphere;return l!==null&&(this.boundingSphere=l.clone()),this.drawRange.start=e.drawRange.start,this.drawRange.count=e.drawRange.count,this.userData=e.userData,this}dispose(){this.dispatchEvent({type:"dispose"})}}const Ip=new ft,vn=new mu,Oo=new $a,Np=new O,ia=new O,na=new O,aa=new O,vc=new O,ko=new O,Fo=new Ne,zo=new Ne,Bo=new Ne,Op=new O,kp=new O,Fp=new O,Vo=new O,Ho=new O;class mt extends Rt{constructor(e=new Or,r=new Is){super(),this.isMesh=!0,this.type="Mesh",this.geometry=e,this.material=r,this.updateMorphTargets()}copy(e,r){return super.copy(e,r),e.morphTargetInfluences!==void 0&&(this.morphTargetInfluences=e.morphTargetInfluences.slice()),e.morphTargetDictionary!==void 0&&(this.morphTargetDictionary=Object.assign({},e.morphTargetDictionary)),this.material=Array.isArray(e.material)?e.material.slice():e.material,this.geometry=e.geometry,this}updateMorphTargets(){const e=this.geometry.morphAttributes,r=Object.keys(e);if(r.length>0){const i=e[r[0]];if(i!==void 0){this.morphTargetInfluences=[],this.morphTargetDictionary={};for(let n=0,a=i.length;n<a;n++){const s=i[n].name||String(n);this.morphTargetInfluences.push(0),this.morphTargetDictionary[s]=n}}}}getVertexPosition(e,r){const i=this.geometry,n=i.attributes.position,a=i.morphAttributes.position,s=i.morphTargetsRelative;r.fromBufferAttribute(n,e);const o=this.morphTargetInfluences;if(a&&o){ko.set(0,0,0);for(let l=0,u=a.length;l<u;l++){const h=o[l],f=a[l];h!==0&&(vc.fromBufferAttribute(f,e),s?ko.addScaledVector(vc,h):ko.addScaledVector(vc.sub(r),h))}r.add(ko)}return r}raycast(e,r){const i=this.geometry,n=this.material,a=this.matrixWorld;n!==void 0&&(i.boundingSphere===null&&i.computeBoundingSphere(),Oo.copy(i.boundingSphere),Oo.applyMatrix4(a),vn.copy(e.ray).recast(e.near),!(Oo.containsPoint(vn.origin)===!1&&(vn.intersectSphere(Oo,Np)===null||vn.origin.distanceToSquared(Np)>(e.far-e.near)**2))&&(Ip.copy(a).invert(),vn.copy(e.ray).applyMatrix4(Ip),!(i.boundingBox!==null&&vn.intersectsBox(i.boundingBox)===!1)&&this._computeIntersections(e,r,vn)))}_computeIntersections(e,r,i){let n;const a=this.geometry,s=this.material,o=a.index,l=a.attributes.position,u=a.attributes.uv,h=a.attributes.uv1,f=a.attributes.normal,d=a.groups,p=a.drawRange;if(o!==null)if(Array.isArray(s))for(let _=0,x=d.length;_<x;_++){const m=d[_],c=s[m.materialIndex],g=Math.max(m.start,p.start),v=Math.min(o.count,Math.min(m.start+m.count,p.start+p.count));for(let M=g,P=v;M<P;M+=3){const T=o.getX(M),w=o.getX(M+1),L=o.getX(M+2);n=Go(this,c,e,i,u,h,f,T,w,L),n&&(n.faceIndex=Math.floor(M/3),n.face.materialIndex=m.materialIndex,r.push(n))}}else{const _=Math.max(0,p.start),x=Math.min(o.count,p.start+p.count);for(let m=_,c=x;m<c;m+=3){const g=o.getX(m),v=o.getX(m+1),M=o.getX(m+2);n=Go(this,s,e,i,u,h,f,g,v,M),n&&(n.faceIndex=Math.floor(m/3),r.push(n))}}else if(l!==void 0)if(Array.isArray(s))for(let _=0,x=d.length;_<x;_++){const m=d[_],c=s[m.materialIndex],g=Math.max(m.start,p.start),v=Math.min(l.count,Math.min(m.start+m.count,p.start+p.count));for(let M=g,P=v;M<P;M+=3){const T=M,w=M+1,L=M+2;n=Go(this,c,e,i,u,h,f,T,w,L),n&&(n.faceIndex=Math.floor(M/3),n.face.materialIndex=m.materialIndex,r.push(n))}}else{const _=Math.max(0,p.start),x=Math.min(l.count,p.start+p.count);for(let m=_,c=x;m<c;m+=3){const g=m,v=m+1,M=m+2;n=Go(this,s,e,i,u,h,f,g,v,M),n&&(n.faceIndex=Math.floor(m/3),r.push(n))}}}}function _M(t,e,r,i,n,a,s,o){let l;if(e.side===vr?l=i.intersectTriangle(s,a,n,!0,o):l=i.intersectTriangle(n,a,s,e.side===on,o),l===null)return null;Ho.copy(o),Ho.applyMatrix4(t.matrixWorld);const u=r.ray.origin.distanceTo(Ho);return u<r.near||u>r.far?null:{distance:u,point:Ho.clone(),object:t}}function Go(t,e,r,i,n,a,s,o,l,u){t.getVertexPosition(o,ia),t.getVertexPosition(l,na),t.getVertexPosition(u,aa);const h=_M(t,e,r,i,ia,na,aa,Vo);if(h){n&&(Fo.fromBufferAttribute(n,o),zo.fromBufferAttribute(n,l),Bo.fromBufferAttribute(n,u),h.uv=ii.getInterpolation(Vo,ia,na,aa,Fo,zo,Bo,new Ne)),a&&(Fo.fromBufferAttribute(a,o),zo.fromBufferAttribute(a,l),Bo.fromBufferAttribute(a,u),h.uv1=ii.getInterpolation(Vo,ia,na,aa,Fo,zo,Bo,new Ne)),s&&(Op.fromBufferAttribute(s,o),kp.fromBufferAttribute(s,l),Fp.fromBufferAttribute(s,u),h.normal=ii.getInterpolation(Vo,ia,na,aa,Op,kp,Fp,new O),h.normal.dot(i.direction)>0&&h.normal.multiplyScalar(-1));const f={a:o,b:l,c:u,normal:new O,materialIndex:0};ii.getNormal(ia,na,aa,f.normal),h.face=f}return h}class bi extends Or{constructor(e=1,r=1,i=1,n=1,a=1,s=1){super(),this.type="BoxGeometry",this.parameters={width:e,height:r,depth:i,widthSegments:n,heightSegments:a,depthSegments:s};const o=this;n=Math.floor(n),a=Math.floor(a),s=Math.floor(s);const l=[],u=[],h=[],f=[];let d=0,p=0;_("z","y","x",-1,-1,i,r,e,s,a,0),_("z","y","x",1,-1,i,r,-e,s,a,1),_("x","z","y",1,1,e,i,r,n,s,2),_("x","z","y",1,-1,e,i,-r,n,s,3),_("x","y","z",1,-1,e,r,i,n,a,4),_("x","y","z",-1,-1,e,r,-i,n,a,5),this.setIndex(l),this.setAttribute("position",new Yt(u,3)),this.setAttribute("normal",new Yt(h,3)),this.setAttribute("uv",new Yt(f,2));function _(x,m,c,g,v,M,P,T,w,L,b){const y=M/w,U=P/L,B=M/2,V=P/2,q=T/2,J=w+1,K=L+1;let ne=0,I=0;const Z=new O;for(let re=0;re<K;re++){const xe=re*U-V;for(let fe=0;fe<J;fe++){const Ue=fe*y-B;Z[x]=Ue*g,Z[m]=xe*v,Z[c]=q,u.push(Z.x,Z.y,Z.z),Z[x]=0,Z[m]=0,Z[c]=T>0?1:-1,h.push(Z.x,Z.y,Z.z),f.push(fe/w),f.push(1-re/L),ne+=1}}for(let re=0;re<L;re++)for(let xe=0;xe<w;xe++){const fe=d+xe+J*re,Ue=d+xe+J*(re+1),Y=d+(xe+1)+J*(re+1),ee=d+(xe+1)+J*re;l.push(fe,Ue,ee),l.push(Ue,Y,ee),I+=6}o.addGroup(p,I,b),p+=I,d+=ne}}copy(e){return super.copy(e),this.parameters=Object.assign({},e.parameters),this}static fromJSON(e){return new bi(e.width,e.height,e.depth,e.widthSegments,e.heightSegments,e.depthSegments)}}function Ya(t){const e={};for(const r in t){e[r]={};for(const i in t[r]){const n=t[r][i];n&&(n.isColor||n.isMatrix3||n.isMatrix4||n.isVector2||n.isVector3||n.isVector4||n.isTexture||n.isQuaternion)?n.isRenderTargetTexture?(console.warn("UniformsUtils: Textures of render targets cannot be cloned via cloneUniforms() or mergeUniforms()."),e[r][i]=null):e[r][i]=n.clone():Array.isArray(n)?e[r][i]=n.slice():e[r][i]=n}}return e}function rr(t){const e={};for(let r=0;r<t.length;r++){const i=Ya(t[r]);for(const n in i)e[n]=i[n]}return e}function xM(t){const e=[];for(let r=0;r<t.length;r++)e.push(t[r].clone());return e}function o_(t){const e=t.getRenderTarget();return e===null?t.outputColorSpace:e.isXRRenderTarget===!0?e.texture.colorSpace:ut.workingColorSpace}const yM={clone:Ya,merge:rr};var MM=`void main() {
	gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );
}`,SM=`void main() {
	gl_FragColor = vec4( 1.0, 0.0, 0.0, 1.0 );
}`;class un extends Qa{constructor(e){super(),this.isShaderMaterial=!0,this.type="ShaderMaterial",this.defines={},this.uniforms={},this.uniformsGroups=[],this.vertexShader=MM,this.fragmentShader=SM,this.linewidth=1,this.wireframe=!1,this.wireframeLinewidth=1,this.fog=!1,this.lights=!1,this.clipping=!1,this.forceSinglePass=!0,this.extensions={clipCullDistance:!1,multiDraw:!1},this.defaultAttributeValues={color:[1,1,1],uv:[0,0],uv1:[0,0]},this.index0AttributeName=void 0,this.uniformsNeedUpdate=!1,this.glslVersion=null,e!==void 0&&this.setValues(e)}copy(e){return super.copy(e),this.fragmentShader=e.fragmentShader,this.vertexShader=e.vertexShader,this.uniforms=Ya(e.uniforms),this.uniformsGroups=xM(e.uniformsGroups),this.defines=Object.assign({},e.defines),this.wireframe=e.wireframe,this.wireframeLinewidth=e.wireframeLinewidth,this.fog=e.fog,this.lights=e.lights,this.clipping=e.clipping,this.extensions=Object.assign({},e.extensions),this.glslVersion=e.glslVersion,this}toJSON(e){const r=super.toJSON(e);r.glslVersion=this.glslVersion,r.uniforms={};for(const n in this.uniforms){const a=this.uniforms[n].value;a&&a.isTexture?r.uniforms[n]={type:"t",value:a.toJSON(e).uuid}:a&&a.isColor?r.uniforms[n]={type:"c",value:a.getHex()}:a&&a.isVector2?r.uniforms[n]={type:"v2",value:a.toArray()}:a&&a.isVector3?r.uniforms[n]={type:"v3",value:a.toArray()}:a&&a.isVector4?r.uniforms[n]={type:"v4",value:a.toArray()}:a&&a.isMatrix3?r.uniforms[n]={type:"m3",value:a.toArray()}:a&&a.isMatrix4?r.uniforms[n]={type:"m4",value:a.toArray()}:r.uniforms[n]={value:a}}Object.keys(this.defines).length>0&&(r.defines=this.defines),r.vertexShader=this.vertexShader,r.fragmentShader=this.fragmentShader,r.lights=this.lights,r.clipping=this.clipping;const i={};for(const n in this.extensions)this.extensions[n]===!0&&(i[n]=!0);return Object.keys(i).length>0&&(r.extensions=i),r}}class l_ extends Rt{constructor(){super(),this.isCamera=!0,this.type="Camera",this.matrixWorldInverse=new ft,this.projectionMatrix=new ft,this.projectionMatrixInverse=new ft,this.coordinateSystem=Si}copy(e,r){return super.copy(e,r),this.matrixWorldInverse.copy(e.matrixWorldInverse),this.projectionMatrix.copy(e.projectionMatrix),this.projectionMatrixInverse.copy(e.projectionMatrixInverse),this.coordinateSystem=e.coordinateSystem,this}getWorldDirection(e){return super.getWorldDirection(e).negate()}updateMatrixWorld(e){super.updateMatrixWorld(e),this.matrixWorldInverse.copy(this.matrixWorld).invert()}updateWorldMatrix(e,r){super.updateWorldMatrix(e,r),this.matrixWorldInverse.copy(this.matrixWorld).invert()}clone(){return new this.constructor().copy(this)}}const ki=new O,zp=new Ne,Bp=new Ne;class Sr extends l_{constructor(e=50,r=1,i=.1,n=2e3){super(),this.isPerspectiveCamera=!0,this.type="PerspectiveCamera",this.fov=e,this.zoom=1,this.near=i,this.far=n,this.focus=10,this.aspect=r,this.view=null,this.filmGauge=35,this.filmOffset=0,this.updateProjectionMatrix()}copy(e,r){return super.copy(e,r),this.fov=e.fov,this.zoom=e.zoom,this.near=e.near,this.far=e.far,this.focus=e.focus,this.aspect=e.aspect,this.view=e.view===null?null:Object.assign({},e.view),this.filmGauge=e.filmGauge,this.filmOffset=e.filmOffset,this}setFocalLength(e){const r=.5*this.getFilmHeight()/e;this.fov=Rd*2*Math.atan(r),this.updateProjectionMatrix()}getFocalLength(){const e=Math.tan(fl*.5*this.fov);return .5*this.getFilmHeight()/e}getEffectiveFOV(){return Rd*2*Math.atan(Math.tan(fl*.5*this.fov)/this.zoom)}getFilmWidth(){return this.filmGauge*Math.min(this.aspect,1)}getFilmHeight(){return this.filmGauge/Math.max(this.aspect,1)}getViewBounds(e,r,i){ki.set(-1,-1,.5).applyMatrix4(this.projectionMatrixInverse),r.set(ki.x,ki.y).multiplyScalar(-e/ki.z),ki.set(1,1,.5).applyMatrix4(this.projectionMatrixInverse),i.set(ki.x,ki.y).multiplyScalar(-e/ki.z)}getViewSize(e,r){return this.getViewBounds(e,zp,Bp),r.subVectors(Bp,zp)}setViewOffset(e,r,i,n,a,s){this.aspect=e/r,this.view===null&&(this.view={enabled:!0,fullWidth:1,fullHeight:1,offsetX:0,offsetY:0,width:1,height:1}),this.view.enabled=!0,this.view.fullWidth=e,this.view.fullHeight=r,this.view.offsetX=i,this.view.offsetY=n,this.view.width=a,this.view.height=s,this.updateProjectionMatrix()}clearViewOffset(){this.view!==null&&(this.view.enabled=!1),this.updateProjectionMatrix()}updateProjectionMatrix(){const e=this.near;let r=e*Math.tan(fl*.5*this.fov)/this.zoom,i=2*r,n=this.aspect*i,a=-.5*n;const s=this.view;if(this.view!==null&&this.view.enabled){const l=s.fullWidth,u=s.fullHeight;a+=s.offsetX*n/l,r-=s.offsetY*i/u,n*=s.width/l,i*=s.height/u}const o=this.filmOffset;o!==0&&(a+=e*o/this.getFilmWidth()),this.projectionMatrix.makePerspective(a,a+n,r,r-i,e,this.far,this.coordinateSystem),this.projectionMatrixInverse.copy(this.projectionMatrix).invert()}toJSON(e){const r=super.toJSON(e);return r.object.fov=this.fov,r.object.zoom=this.zoom,r.object.near=this.near,r.object.far=this.far,r.object.focus=this.focus,r.object.aspect=this.aspect,this.view!==null&&(r.object.view=Object.assign({},this.view)),r.object.filmGauge=this.filmGauge,r.object.filmOffset=this.filmOffset,r}}const sa=-90,oa=1;class bM extends Rt{constructor(e,r,i){super(),this.type="CubeCamera",this.renderTarget=i,this.coordinateSystem=null,this.activeMipmapLevel=0;const n=new Sr(sa,oa,e,r);n.layers=this.layers,this.add(n);const a=new Sr(sa,oa,e,r);a.layers=this.layers,this.add(a);const s=new Sr(sa,oa,e,r);s.layers=this.layers,this.add(s);const o=new Sr(sa,oa,e,r);o.layers=this.layers,this.add(o);const l=new Sr(sa,oa,e,r);l.layers=this.layers,this.add(l);const u=new Sr(sa,oa,e,r);u.layers=this.layers,this.add(u)}updateCoordinateSystem(){const e=this.coordinateSystem,r=this.children.concat(),[i,n,a,s,o,l]=r;for(const u of r)this.remove(u);if(e===Si)i.up.set(0,1,0),i.lookAt(1,0,0),n.up.set(0,1,0),n.lookAt(-1,0,0),a.up.set(0,0,-1),a.lookAt(0,1,0),s.up.set(0,0,1),s.lookAt(0,-1,0),o.up.set(0,1,0),o.lookAt(0,0,1),l.up.set(0,1,0),l.lookAt(0,0,-1);else if(e===Wl)i.up.set(0,-1,0),i.lookAt(-1,0,0),n.up.set(0,-1,0),n.lookAt(1,0,0),a.up.set(0,0,1),a.lookAt(0,1,0),s.up.set(0,0,-1),s.lookAt(0,-1,0),o.up.set(0,-1,0),o.lookAt(0,0,1),l.up.set(0,-1,0),l.lookAt(0,0,-1);else throw new Error("THREE.CubeCamera.updateCoordinateSystem(): Invalid coordinate system: "+e);for(const u of r)this.add(u),u.updateMatrixWorld()}update(e,r){this.parent===null&&this.updateMatrixWorld();const{renderTarget:i,activeMipmapLevel:n}=this;this.coordinateSystem!==e.coordinateSystem&&(this.coordinateSystem=e.coordinateSystem,this.updateCoordinateSystem());const[a,s,o,l,u,h]=this.children,f=e.getRenderTarget(),d=e.getActiveCubeFace(),p=e.getActiveMipmapLevel(),_=e.xr.enabled;e.xr.enabled=!1;const x=i.texture.generateMipmaps;i.texture.generateMipmaps=!1,e.setRenderTarget(i,0,n),e.render(r,a),e.setRenderTarget(i,1,n),e.render(r,s),e.setRenderTarget(i,2,n),e.render(r,o),e.setRenderTarget(i,3,n),e.render(r,l),e.setRenderTarget(i,4,n),e.render(r,u),i.texture.generateMipmaps=x,e.setRenderTarget(i,5,n),e.render(r,h),e.setRenderTarget(f,d,p),e.xr.enabled=_,i.texture.needsPMREMUpdate=!0}}class u_ extends sr{constructor(e,r,i,n,a,s,o,l,u,h){e=e!==void 0?e:[],r=r!==void 0?r:Ha,super(e,r,i,n,a,s,o,l,u,h),this.isCubeTexture=!0,this.flipY=!1}get images(){return this.image}set images(e){this.image=e}}class EM extends zn{constructor(e=1,r={}){super(e,e,r),this.isWebGLCubeRenderTarget=!0;const i={width:e,height:e,depth:1},n=[i,i,i,i,i,i];this.texture=new u_(n,r.mapping,r.wrapS,r.wrapT,r.magFilter,r.minFilter,r.format,r.type,r.anisotropy,r.colorSpace),this.texture.isRenderTargetTexture=!0,this.texture.generateMipmaps=r.generateMipmaps!==void 0?r.generateMipmaps:!1,this.texture.minFilter=r.minFilter!==void 0?r.minFilter:Xr}fromEquirectangularTexture(e,r){this.texture.type=r.type,this.texture.colorSpace=r.colorSpace,this.texture.generateMipmaps=r.generateMipmaps,this.texture.minFilter=r.minFilter,this.texture.magFilter=r.magFilter;const i={uniforms:{tEquirect:{value:null}},vertexShader:`

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
			`},n=new bi(5,5,5),a=new un({name:"CubemapFromEquirect",uniforms:Ya(i.uniforms),vertexShader:i.vertexShader,fragmentShader:i.fragmentShader,side:vr,blending:rn});a.uniforms.tEquirect.value=r;const s=new mt(n,a),o=r.minFilter;return r.minFilter===Ln&&(r.minFilter=Xr),new bM(1,10,this).update(e,s),r.minFilter=o,s.geometry.dispose(),s.material.dispose(),this}clear(e,r,i,n){const a=e.getRenderTarget();for(let s=0;s<6;s++)e.setRenderTarget(this,s),e.clear(r,i,n);e.setRenderTarget(a)}}const _c=new O,wM=new O,TM=new Ke;class Vi{constructor(e=new O(1,0,0),r=0){this.isPlane=!0,this.normal=e,this.constant=r}set(e,r){return this.normal.copy(e),this.constant=r,this}setComponents(e,r,i,n){return this.normal.set(e,r,i),this.constant=n,this}setFromNormalAndCoplanarPoint(e,r){return this.normal.copy(e),this.constant=-r.dot(this.normal),this}setFromCoplanarPoints(e,r,i){const n=_c.subVectors(i,r).cross(wM.subVectors(e,r)).normalize();return this.setFromNormalAndCoplanarPoint(n,e),this}copy(e){return this.normal.copy(e.normal),this.constant=e.constant,this}normalize(){const e=1/this.normal.length();return this.normal.multiplyScalar(e),this.constant*=e,this}negate(){return this.constant*=-1,this.normal.negate(),this}distanceToPoint(e){return this.normal.dot(e)+this.constant}distanceToSphere(e){return this.distanceToPoint(e.center)-e.radius}projectPoint(e,r){return r.copy(e).addScaledVector(this.normal,-this.distanceToPoint(e))}intersectLine(e,r){const i=e.delta(_c),n=this.normal.dot(i);if(n===0)return this.distanceToPoint(e.start)===0?r.copy(e.start):null;const a=-(e.start.dot(this.normal)+this.constant)/n;return a<0||a>1?null:r.copy(e.start).addScaledVector(i,a)}intersectsLine(e){const r=this.distanceToPoint(e.start),i=this.distanceToPoint(e.end);return r<0&&i>0||i<0&&r>0}intersectsBox(e){return e.intersectsPlane(this)}intersectsSphere(e){return e.intersectsPlane(this)}coplanarPoint(e){return e.copy(this.normal).multiplyScalar(-this.constant)}applyMatrix4(e,r){const i=r||TM.getNormalMatrix(e),n=this.coplanarPoint(_c).applyMatrix4(e),a=this.normal.applyMatrix3(i).normalize();return this.constant=-n.dot(a),this}translate(e){return this.constant-=e.dot(this.normal),this}equals(e){return e.normal.equals(this.normal)&&e.constant===this.constant}clone(){return new this.constructor().copy(this)}}const _n=new $a,Wo=new O;class Rh{constructor(e=new Vi,r=new Vi,i=new Vi,n=new Vi,a=new Vi,s=new Vi){this.planes=[e,r,i,n,a,s]}set(e,r,i,n,a,s){const o=this.planes;return o[0].copy(e),o[1].copy(r),o[2].copy(i),o[3].copy(n),o[4].copy(a),o[5].copy(s),this}copy(e){const r=this.planes;for(let i=0;i<6;i++)r[i].copy(e.planes[i]);return this}setFromProjectionMatrix(e,r=Si){const i=this.planes,n=e.elements,a=n[0],s=n[1],o=n[2],l=n[3],u=n[4],h=n[5],f=n[6],d=n[7],p=n[8],_=n[9],x=n[10],m=n[11],c=n[12],g=n[13],v=n[14],M=n[15];if(i[0].setComponents(l-a,d-u,m-p,M-c).normalize(),i[1].setComponents(l+a,d+u,m+p,M+c).normalize(),i[2].setComponents(l+s,d+h,m+_,M+g).normalize(),i[3].setComponents(l-s,d-h,m-_,M-g).normalize(),i[4].setComponents(l-o,d-f,m-x,M-v).normalize(),r===Si)i[5].setComponents(l+o,d+f,m+x,M+v).normalize();else if(r===Wl)i[5].setComponents(o,f,x,v).normalize();else throw new Error("THREE.Frustum.setFromProjectionMatrix(): Invalid coordinate system: "+r);return this}intersectsObject(e){if(e.boundingSphere!==void 0)e.boundingSphere===null&&e.computeBoundingSphere(),_n.copy(e.boundingSphere).applyMatrix4(e.matrixWorld);else{const r=e.geometry;r.boundingSphere===null&&r.computeBoundingSphere(),_n.copy(r.boundingSphere).applyMatrix4(e.matrixWorld)}return this.intersectsSphere(_n)}intersectsSprite(e){return _n.center.set(0,0,0),_n.radius=.7071067811865476,_n.applyMatrix4(e.matrixWorld),this.intersectsSphere(_n)}intersectsSphere(e){const r=this.planes,i=e.center,n=-e.radius;for(let a=0;a<6;a++)if(r[a].distanceToPoint(i)<n)return!1;return!0}intersectsBox(e){const r=this.planes;for(let i=0;i<6;i++){const n=r[i];if(Wo.x=n.normal.x>0?e.max.x:e.min.x,Wo.y=n.normal.y>0?e.max.y:e.min.y,Wo.z=n.normal.z>0?e.max.z:e.min.z,n.distanceToPoint(Wo)<0)return!1}return!0}containsPoint(e){const r=this.planes;for(let i=0;i<6;i++)if(r[i].distanceToPoint(e)<0)return!1;return!0}clone(){return new this.constructor().copy(this)}}function c_(){let t=null,e=!1,r=null,i=null;function n(a,s){r(a,s),i=t.requestAnimationFrame(n)}return{start:function(){e!==!0&&r!==null&&(i=t.requestAnimationFrame(n),e=!0)},stop:function(){t.cancelAnimationFrame(i),e=!1},setAnimationLoop:function(a){r=a},setContext:function(a){t=a}}}function AM(t){const e=new WeakMap;function r(o,l){const u=o.array,h=o.usage,f=u.byteLength,d=t.createBuffer();t.bindBuffer(l,d),t.bufferData(l,u,h),o.onUploadCallback();let p;if(u instanceof Float32Array)p=t.FLOAT;else if(u instanceof Uint16Array)o.isFloat16BufferAttribute?p=t.HALF_FLOAT:p=t.UNSIGNED_SHORT;else if(u instanceof Int16Array)p=t.SHORT;else if(u instanceof Uint32Array)p=t.UNSIGNED_INT;else if(u instanceof Int32Array)p=t.INT;else if(u instanceof Int8Array)p=t.BYTE;else if(u instanceof Uint8Array)p=t.UNSIGNED_BYTE;else if(u instanceof Uint8ClampedArray)p=t.UNSIGNED_BYTE;else throw new Error("THREE.WebGLAttributes: Unsupported buffer data format: "+u);return{buffer:d,type:p,bytesPerElement:u.BYTES_PER_ELEMENT,version:o.version,size:f}}function i(o,l,u){const h=l.array,f=l._updateRange,d=l.updateRanges;if(t.bindBuffer(u,o),f.count===-1&&d.length===0&&t.bufferSubData(u,0,h),d.length!==0){for(let p=0,_=d.length;p<_;p++){const x=d[p];t.bufferSubData(u,x.start*h.BYTES_PER_ELEMENT,h,x.start,x.count)}l.clearUpdateRanges()}f.count!==-1&&(t.bufferSubData(u,f.offset*h.BYTES_PER_ELEMENT,h,f.offset,f.count),f.count=-1),l.onUploadCallback()}function n(o){return o.isInterleavedBufferAttribute&&(o=o.data),e.get(o)}function a(o){o.isInterleavedBufferAttribute&&(o=o.data);const l=e.get(o);l&&(t.deleteBuffer(l.buffer),e.delete(o))}function s(o,l){if(o.isGLBufferAttribute){const h=e.get(o);(!h||h.version<o.version)&&e.set(o,{buffer:o.buffer,type:o.type,bytesPerElement:o.elementSize,version:o.version});return}o.isInterleavedBufferAttribute&&(o=o.data);const u=e.get(o);if(u===void 0)e.set(o,r(o,l));else if(u.version<o.version){if(u.size!==o.array.byteLength)throw new Error("THREE.WebGLAttributes: The size of the buffer attribute's array buffer does not match the original size. Resizing buffer attributes is not supported.");i(u.buffer,o,l),u.version=o.version}}return{get:n,remove:a,update:s}}class ao extends Or{constructor(e=1,r=1,i=1,n=1){super(),this.type="PlaneGeometry",this.parameters={width:e,height:r,widthSegments:i,heightSegments:n};const a=e/2,s=r/2,o=Math.floor(i),l=Math.floor(n),u=o+1,h=l+1,f=e/o,d=r/l,p=[],_=[],x=[],m=[];for(let c=0;c<h;c++){const g=c*d-s;for(let v=0;v<u;v++){const M=v*f-a;_.push(M,-g,0),x.push(0,0,1),m.push(v/o),m.push(1-c/l)}}for(let c=0;c<l;c++)for(let g=0;g<o;g++){const v=g+u*c,M=g+u*(c+1),P=g+1+u*(c+1),T=g+1+u*c;p.push(v,M,T),p.push(M,P,T)}this.setIndex(p),this.setAttribute("position",new Yt(_,3)),this.setAttribute("normal",new Yt(x,3)),this.setAttribute("uv",new Yt(m,2))}copy(e){return super.copy(e),this.parameters=Object.assign({},e.parameters),this}static fromJSON(e){return new ao(e.width,e.height,e.widthSegments,e.heightSegments)}}var CM=`#ifdef USE_ALPHAHASH
	if ( diffuseColor.a < getAlphaHashThreshold( vPosition ) ) discard;
#endif`,RM=`#ifdef USE_ALPHAHASH
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
#endif`,PM=`#ifdef USE_ALPHAMAP
	diffuseColor.a *= texture2D( alphaMap, vAlphaMapUv ).g;
#endif`,LM=`#ifdef USE_ALPHAMAP
	uniform sampler2D alphaMap;
#endif`,UM=`#ifdef USE_ALPHATEST
	#ifdef ALPHA_TO_COVERAGE
	diffuseColor.a = smoothstep( alphaTest, alphaTest + fwidth( diffuseColor.a ), diffuseColor.a );
	if ( diffuseColor.a == 0.0 ) discard;
	#else
	if ( diffuseColor.a < alphaTest ) discard;
	#endif
#endif`,DM=`#ifdef USE_ALPHATEST
	uniform float alphaTest;
#endif`,IM=`#ifdef USE_AOMAP
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
#endif`,NM=`#ifdef USE_AOMAP
	uniform sampler2D aoMap;
	uniform float aoMapIntensity;
#endif`,OM=`#ifdef USE_BATCHING
	attribute float batchId;
	uniform highp sampler2D batchingTexture;
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
#endif`,kM=`#ifdef USE_BATCHING
	mat4 batchingMatrix = getBatchingMatrix( batchId );
#endif`,FM=`vec3 transformed = vec3( position );
#ifdef USE_ALPHAHASH
	vPosition = vec3( position );
#endif`,zM=`vec3 objectNormal = vec3( normal );
#ifdef USE_TANGENT
	vec3 objectTangent = vec3( tangent.xyz );
#endif`,BM=`float G_BlinnPhong_Implicit( ) {
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
} // validated`,VM=`#ifdef USE_IRIDESCENCE
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
#endif`,HM=`#ifdef USE_BUMPMAP
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
#endif`,GM=`#if NUM_CLIPPING_PLANES > 0
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
#endif`,WM=`#if NUM_CLIPPING_PLANES > 0
	varying vec3 vClipPosition;
	uniform vec4 clippingPlanes[ NUM_CLIPPING_PLANES ];
#endif`,jM=`#if NUM_CLIPPING_PLANES > 0
	varying vec3 vClipPosition;
#endif`,XM=`#if NUM_CLIPPING_PLANES > 0
	vClipPosition = - mvPosition.xyz;
#endif`,YM=`#if defined( USE_COLOR_ALPHA )
	diffuseColor *= vColor;
#elif defined( USE_COLOR )
	diffuseColor.rgb *= vColor;
#endif`,qM=`#if defined( USE_COLOR_ALPHA )
	varying vec4 vColor;
#elif defined( USE_COLOR )
	varying vec3 vColor;
#endif`,KM=`#if defined( USE_COLOR_ALPHA )
	varying vec4 vColor;
#elif defined( USE_COLOR ) || defined( USE_INSTANCING_COLOR ) || defined( USE_BATCHING_COLOR )
	varying vec3 vColor;
#endif`,ZM=`#if defined( USE_COLOR_ALPHA )
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
	vec3 batchingColor = getBatchingColor( batchId );
	vColor.xyz *= batchingColor.xyz;
#endif`,$M=`#define PI 3.141592653589793
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
float luminance( const in vec3 rgb ) {
	const vec3 weights = vec3( 0.2126729, 0.7151522, 0.0721750 );
	return dot( weights, rgb );
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
} // validated`,QM=`#ifdef ENVMAP_TYPE_CUBE_UV
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
#endif`,JM=`vec3 transformedNormal = objectNormal;
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
#endif`,eS=`#ifdef USE_DISPLACEMENTMAP
	uniform sampler2D displacementMap;
	uniform float displacementScale;
	uniform float displacementBias;
#endif`,tS=`#ifdef USE_DISPLACEMENTMAP
	transformed += normalize( objectNormal ) * ( texture2D( displacementMap, vDisplacementMapUv ).x * displacementScale + displacementBias );
#endif`,rS=`#ifdef USE_EMISSIVEMAP
	vec4 emissiveColor = texture2D( emissiveMap, vEmissiveMapUv );
	totalEmissiveRadiance *= emissiveColor.rgb;
#endif`,iS=`#ifdef USE_EMISSIVEMAP
	uniform sampler2D emissiveMap;
#endif`,nS="gl_FragColor = linearToOutputTexel( gl_FragColor );",aS=`
const mat3 LINEAR_SRGB_TO_LINEAR_DISPLAY_P3 = mat3(
	vec3( 0.8224621, 0.177538, 0.0 ),
	vec3( 0.0331941, 0.9668058, 0.0 ),
	vec3( 0.0170827, 0.0723974, 0.9105199 )
);
const mat3 LINEAR_DISPLAY_P3_TO_LINEAR_SRGB = mat3(
	vec3( 1.2249401, - 0.2249404, 0.0 ),
	vec3( - 0.0420569, 1.0420571, 0.0 ),
	vec3( - 0.0196376, - 0.0786361, 1.0982735 )
);
vec4 LinearSRGBToLinearDisplayP3( in vec4 value ) {
	return vec4( value.rgb * LINEAR_SRGB_TO_LINEAR_DISPLAY_P3, value.a );
}
vec4 LinearDisplayP3ToLinearSRGB( in vec4 value ) {
	return vec4( value.rgb * LINEAR_DISPLAY_P3_TO_LINEAR_SRGB, value.a );
}
vec4 LinearTransferOETF( in vec4 value ) {
	return value;
}
vec4 sRGBTransferOETF( in vec4 value ) {
	return vec4( mix( pow( value.rgb, vec3( 0.41666 ) ) * 1.055 - vec3( 0.055 ), value.rgb * 12.92, vec3( lessThanEqual( value.rgb, vec3( 0.0031308 ) ) ) ), value.a );
}
vec4 LinearToLinear( in vec4 value ) {
	return value;
}
vec4 LinearTosRGB( in vec4 value ) {
	return sRGBTransferOETF( value );
}`,sS=`#ifdef USE_ENVMAP
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
#endif`,oS=`#ifdef USE_ENVMAP
	uniform float envMapIntensity;
	uniform float flipEnvMap;
	uniform mat3 envMapRotation;
	#ifdef ENVMAP_TYPE_CUBE
		uniform samplerCube envMap;
	#else
		uniform sampler2D envMap;
	#endif
	
#endif`,lS=`#ifdef USE_ENVMAP
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
#endif`,uS=`#ifdef USE_ENVMAP
	#if defined( USE_BUMPMAP ) || defined( USE_NORMALMAP ) || defined( PHONG ) || defined( LAMBERT )
		#define ENV_WORLDPOS
	#endif
	#ifdef ENV_WORLDPOS
		
		varying vec3 vWorldPosition;
	#else
		varying vec3 vReflect;
		uniform float refractionRatio;
	#endif
#endif`,cS=`#ifdef USE_ENVMAP
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
#endif`,dS=`#ifdef USE_FOG
	vFogDepth = - mvPosition.z;
#endif`,hS=`#ifdef USE_FOG
	varying float vFogDepth;
#endif`,fS=`#ifdef USE_FOG
	#ifdef FOG_EXP2
		float fogFactor = 1.0 - exp( - fogDensity * fogDensity * vFogDepth * vFogDepth );
	#else
		float fogFactor = smoothstep( fogNear, fogFar, vFogDepth );
	#endif
	gl_FragColor.rgb = mix( gl_FragColor.rgb, fogColor, fogFactor );
#endif`,pS=`#ifdef USE_FOG
	uniform vec3 fogColor;
	varying float vFogDepth;
	#ifdef FOG_EXP2
		uniform float fogDensity;
	#else
		uniform float fogNear;
		uniform float fogFar;
	#endif
#endif`,mS=`#ifdef USE_GRADIENTMAP
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
}`,gS=`#ifdef USE_LIGHTMAP
	uniform sampler2D lightMap;
	uniform float lightMapIntensity;
#endif`,vS=`LambertMaterial material;
material.diffuseColor = diffuseColor.rgb;
material.specularStrength = specularStrength;`,_S=`varying vec3 vViewPosition;
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
#define RE_IndirectDiffuse		RE_IndirectDiffuse_Lambert`,xS=`uniform bool receiveShadow;
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
#endif`,yS=`#ifdef USE_ENVMAP
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
#endif`,MS=`ToonMaterial material;
material.diffuseColor = diffuseColor.rgb;`,SS=`varying vec3 vViewPosition;
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
#define RE_IndirectDiffuse		RE_IndirectDiffuse_Toon`,bS=`BlinnPhongMaterial material;
material.diffuseColor = diffuseColor.rgb;
material.specularColor = specular;
material.specularShininess = shininess;
material.specularStrength = specularStrength;`,ES=`varying vec3 vViewPosition;
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
#define RE_IndirectDiffuse		RE_IndirectDiffuse_BlinnPhong`,wS=`PhysicalMaterial material;
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
#endif`,TS=`struct PhysicalMaterial {
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
}`,AS=`
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
		directLight.color *= ( directLight.visible && receiveShadow ) ? getPointShadow( pointShadowMap[ i ], pointLightShadow.shadowMapSize, pointLightShadow.shadowBias, pointLightShadow.shadowRadius, vPointShadowCoord[ i ], pointLightShadow.shadowCameraNear, pointLightShadow.shadowCameraFar ) : 1.0;
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
		directLight.color *= ( directLight.visible && receiveShadow ) ? getShadow( spotShadowMap[ i ], spotLightShadow.shadowMapSize, spotLightShadow.shadowBias, spotLightShadow.shadowRadius, vSpotLightCoord[ i ] ) : 1.0;
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
		directLight.color *= ( directLight.visible && receiveShadow ) ? getShadow( directionalShadowMap[ i ], directionalLightShadow.shadowMapSize, directionalLightShadow.shadowBias, directionalLightShadow.shadowRadius, vDirectionalShadowCoord[ i ] ) : 1.0;
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
#endif`,CS=`#if defined( RE_IndirectDiffuse )
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
#endif`,RS=`#if defined( RE_IndirectDiffuse )
	RE_IndirectDiffuse( irradiance, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
#endif
#if defined( RE_IndirectSpecular )
	RE_IndirectSpecular( radiance, iblIrradiance, clearcoatRadiance, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
#endif`,PS=`#if defined( USE_LOGDEPTHBUF )
	gl_FragDepth = vIsPerspective == 0.0 ? gl_FragCoord.z : log2( vFragDepth ) * logDepthBufFC * 0.5;
#endif`,LS=`#if defined( USE_LOGDEPTHBUF )
	uniform float logDepthBufFC;
	varying float vFragDepth;
	varying float vIsPerspective;
#endif`,US=`#ifdef USE_LOGDEPTHBUF
	varying float vFragDepth;
	varying float vIsPerspective;
#endif`,DS=`#ifdef USE_LOGDEPTHBUF
	vFragDepth = 1.0 + gl_Position.w;
	vIsPerspective = float( isPerspectiveMatrix( projectionMatrix ) );
#endif`,IS=`#ifdef USE_MAP
	vec4 sampledDiffuseColor = texture2D( map, vMapUv );
	#ifdef DECODE_VIDEO_TEXTURE
		sampledDiffuseColor = vec4( mix( pow( sampledDiffuseColor.rgb * 0.9478672986 + vec3( 0.0521327014 ), vec3( 2.4 ) ), sampledDiffuseColor.rgb * 0.0773993808, vec3( lessThanEqual( sampledDiffuseColor.rgb, vec3( 0.04045 ) ) ) ), sampledDiffuseColor.w );
	
	#endif
	diffuseColor *= sampledDiffuseColor;
#endif`,NS=`#ifdef USE_MAP
	uniform sampler2D map;
#endif`,OS=`#if defined( USE_MAP ) || defined( USE_ALPHAMAP )
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
#endif`,kS=`#if defined( USE_POINTS_UV )
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
#endif`,FS=`float metalnessFactor = metalness;
#ifdef USE_METALNESSMAP
	vec4 texelMetalness = texture2D( metalnessMap, vMetalnessMapUv );
	metalnessFactor *= texelMetalness.b;
#endif`,zS=`#ifdef USE_METALNESSMAP
	uniform sampler2D metalnessMap;
#endif`,BS=`#ifdef USE_INSTANCING_MORPH
	float morphTargetInfluences[ MORPHTARGETS_COUNT ];
	float morphTargetBaseInfluence = texelFetch( morphTexture, ivec2( 0, gl_InstanceID ), 0 ).r;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		morphTargetInfluences[i] =  texelFetch( morphTexture, ivec2( i + 1, gl_InstanceID ), 0 ).r;
	}
#endif`,VS=`#if defined( USE_MORPHCOLORS )
	vColor *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		#if defined( USE_COLOR_ALPHA )
			if ( morphTargetInfluences[ i ] != 0.0 ) vColor += getMorph( gl_VertexID, i, 2 ) * morphTargetInfluences[ i ];
		#elif defined( USE_COLOR )
			if ( morphTargetInfluences[ i ] != 0.0 ) vColor += getMorph( gl_VertexID, i, 2 ).rgb * morphTargetInfluences[ i ];
		#endif
	}
#endif`,HS=`#ifdef USE_MORPHNORMALS
	objectNormal *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		if ( morphTargetInfluences[ i ] != 0.0 ) objectNormal += getMorph( gl_VertexID, i, 1 ).xyz * morphTargetInfluences[ i ];
	}
#endif`,GS=`#ifdef USE_MORPHTARGETS
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
#endif`,WS=`#ifdef USE_MORPHTARGETS
	transformed *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		if ( morphTargetInfluences[ i ] != 0.0 ) transformed += getMorph( gl_VertexID, i, 0 ).xyz * morphTargetInfluences[ i ];
	}
#endif`,jS=`float faceDirection = gl_FrontFacing ? 1.0 : - 1.0;
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
vec3 nonPerturbedNormal = normal;`,XS=`#ifdef USE_NORMALMAP_OBJECTSPACE
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
#endif`,YS=`#ifndef FLAT_SHADED
	varying vec3 vNormal;
	#ifdef USE_TANGENT
		varying vec3 vTangent;
		varying vec3 vBitangent;
	#endif
#endif`,qS=`#ifndef FLAT_SHADED
	varying vec3 vNormal;
	#ifdef USE_TANGENT
		varying vec3 vTangent;
		varying vec3 vBitangent;
	#endif
#endif`,KS=`#ifndef FLAT_SHADED
	vNormal = normalize( transformedNormal );
	#ifdef USE_TANGENT
		vTangent = normalize( transformedTangent );
		vBitangent = normalize( cross( vNormal, vTangent ) * tangent.w );
	#endif
#endif`,ZS=`#ifdef USE_NORMALMAP
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
#endif`,$S=`#ifdef USE_CLEARCOAT
	vec3 clearcoatNormal = nonPerturbedNormal;
#endif`,QS=`#ifdef USE_CLEARCOAT_NORMALMAP
	vec3 clearcoatMapN = texture2D( clearcoatNormalMap, vClearcoatNormalMapUv ).xyz * 2.0 - 1.0;
	clearcoatMapN.xy *= clearcoatNormalScale;
	clearcoatNormal = normalize( tbn2 * clearcoatMapN );
#endif`,JS=`#ifdef USE_CLEARCOATMAP
	uniform sampler2D clearcoatMap;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	uniform sampler2D clearcoatNormalMap;
	uniform vec2 clearcoatNormalScale;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	uniform sampler2D clearcoatRoughnessMap;
#endif`,eb=`#ifdef USE_IRIDESCENCEMAP
	uniform sampler2D iridescenceMap;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	uniform sampler2D iridescenceThicknessMap;
#endif`,tb=`#ifdef OPAQUE
diffuseColor.a = 1.0;
#endif
#ifdef USE_TRANSMISSION
diffuseColor.a *= material.transmissionAlpha;
#endif
gl_FragColor = vec4( outgoingLight, diffuseColor.a );`,rb=`vec3 packNormalToRGB( const in vec3 normal ) {
	return normalize( normal ) * 0.5 + 0.5;
}
vec3 unpackRGBToNormal( const in vec3 rgb ) {
	return 2.0 * rgb.xyz - 1.0;
}
const float PackUpscale = 256. / 255.;const float UnpackDownscale = 255. / 256.;
const vec3 PackFactors = vec3( 256. * 256. * 256., 256. * 256., 256. );
const vec4 UnpackFactors = UnpackDownscale / vec4( PackFactors, 1. );
const float ShiftRight8 = 1. / 256.;
vec4 packDepthToRGBA( const in float v ) {
	vec4 r = vec4( fract( v * PackFactors ), v );
	r.yzw -= r.xyz * ShiftRight8;	return r * PackUpscale;
}
float unpackRGBAToDepth( const in vec4 v ) {
	return dot( v, UnpackFactors );
}
vec2 packDepthToRG( in highp float v ) {
	return packDepthToRGBA( v ).yx;
}
float unpackRGToDepth( const in highp vec2 v ) {
	return unpackRGBAToDepth( vec4( v.xy, 0.0, 0.0 ) );
}
vec4 pack2HalfToRGBA( vec2 v ) {
	vec4 r = vec4( v.x, fract( v.x * 255.0 ), v.y, fract( v.y * 255.0 ) );
	return vec4( r.x - r.y / 255.0, r.y, r.z - r.w / 255.0, r.w );
}
vec2 unpackRGBATo2Half( vec4 v ) {
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
}`,ib=`#ifdef PREMULTIPLIED_ALPHA
	gl_FragColor.rgb *= gl_FragColor.a;
#endif`,nb=`vec4 mvPosition = vec4( transformed, 1.0 );
#ifdef USE_BATCHING
	mvPosition = batchingMatrix * mvPosition;
#endif
#ifdef USE_INSTANCING
	mvPosition = instanceMatrix * mvPosition;
#endif
mvPosition = modelViewMatrix * mvPosition;
gl_Position = projectionMatrix * mvPosition;`,ab=`#ifdef DITHERING
	gl_FragColor.rgb = dithering( gl_FragColor.rgb );
#endif`,sb=`#ifdef DITHERING
	vec3 dithering( vec3 color ) {
		float grid_position = rand( gl_FragCoord.xy );
		vec3 dither_shift_RGB = vec3( 0.25 / 255.0, -0.25 / 255.0, 0.25 / 255.0 );
		dither_shift_RGB = mix( 2.0 * dither_shift_RGB, -2.0 * dither_shift_RGB, grid_position );
		return color + dither_shift_RGB;
	}
#endif`,ob=`float roughnessFactor = roughness;
#ifdef USE_ROUGHNESSMAP
	vec4 texelRoughness = texture2D( roughnessMap, vRoughnessMapUv );
	roughnessFactor *= texelRoughness.g;
#endif`,lb=`#ifdef USE_ROUGHNESSMAP
	uniform sampler2D roughnessMap;
#endif`,ub=`#if NUM_SPOT_LIGHT_COORDS > 0
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
	float getShadow( sampler2D shadowMap, vec2 shadowMapSize, float shadowBias, float shadowRadius, vec4 shadowCoord ) {
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
		return shadow;
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
	float getPointShadow( sampler2D shadowMap, vec2 shadowMapSize, float shadowBias, float shadowRadius, vec4 shadowCoord, float shadowCameraNear, float shadowCameraFar ) {
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
		return shadow;
	}
#endif`,cb=`#if NUM_SPOT_LIGHT_COORDS > 0
	uniform mat4 spotLightMatrix[ NUM_SPOT_LIGHT_COORDS ];
	varying vec4 vSpotLightCoord[ NUM_SPOT_LIGHT_COORDS ];
#endif
#ifdef USE_SHADOWMAP
	#if NUM_DIR_LIGHT_SHADOWS > 0
		uniform mat4 directionalShadowMatrix[ NUM_DIR_LIGHT_SHADOWS ];
		varying vec4 vDirectionalShadowCoord[ NUM_DIR_LIGHT_SHADOWS ];
		struct DirectionalLightShadow {
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform DirectionalLightShadow directionalLightShadows[ NUM_DIR_LIGHT_SHADOWS ];
	#endif
	#if NUM_SPOT_LIGHT_SHADOWS > 0
		struct SpotLightShadow {
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
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
			float shadowCameraNear;
			float shadowCameraFar;
		};
		uniform PointLightShadow pointLightShadows[ NUM_POINT_LIGHT_SHADOWS ];
	#endif
#endif`,db=`#if ( defined( USE_SHADOWMAP ) && ( NUM_DIR_LIGHT_SHADOWS > 0 || NUM_POINT_LIGHT_SHADOWS > 0 ) ) || ( NUM_SPOT_LIGHT_COORDS > 0 )
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
#endif`,hb=`float getShadowMask() {
	float shadow = 1.0;
	#ifdef USE_SHADOWMAP
	#if NUM_DIR_LIGHT_SHADOWS > 0
	DirectionalLightShadow directionalLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_DIR_LIGHT_SHADOWS; i ++ ) {
		directionalLight = directionalLightShadows[ i ];
		shadow *= receiveShadow ? getShadow( directionalShadowMap[ i ], directionalLight.shadowMapSize, directionalLight.shadowBias, directionalLight.shadowRadius, vDirectionalShadowCoord[ i ] ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#if NUM_SPOT_LIGHT_SHADOWS > 0
	SpotLightShadow spotLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_SPOT_LIGHT_SHADOWS; i ++ ) {
		spotLight = spotLightShadows[ i ];
		shadow *= receiveShadow ? getShadow( spotShadowMap[ i ], spotLight.shadowMapSize, spotLight.shadowBias, spotLight.shadowRadius, vSpotLightCoord[ i ] ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
	PointLightShadow pointLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_POINT_LIGHT_SHADOWS; i ++ ) {
		pointLight = pointLightShadows[ i ];
		shadow *= receiveShadow ? getPointShadow( pointShadowMap[ i ], pointLight.shadowMapSize, pointLight.shadowBias, pointLight.shadowRadius, vPointShadowCoord[ i ], pointLight.shadowCameraNear, pointLight.shadowCameraFar ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#endif
	return shadow;
}`,fb=`#ifdef USE_SKINNING
	mat4 boneMatX = getBoneMatrix( skinIndex.x );
	mat4 boneMatY = getBoneMatrix( skinIndex.y );
	mat4 boneMatZ = getBoneMatrix( skinIndex.z );
	mat4 boneMatW = getBoneMatrix( skinIndex.w );
#endif`,pb=`#ifdef USE_SKINNING
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
#endif`,mb=`#ifdef USE_SKINNING
	vec4 skinVertex = bindMatrix * vec4( transformed, 1.0 );
	vec4 skinned = vec4( 0.0 );
	skinned += boneMatX * skinVertex * skinWeight.x;
	skinned += boneMatY * skinVertex * skinWeight.y;
	skinned += boneMatZ * skinVertex * skinWeight.z;
	skinned += boneMatW * skinVertex * skinWeight.w;
	transformed = ( bindMatrixInverse * skinned ).xyz;
#endif`,gb=`#ifdef USE_SKINNING
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
#endif`,vb=`float specularStrength;
#ifdef USE_SPECULARMAP
	vec4 texelSpecular = texture2D( specularMap, vSpecularMapUv );
	specularStrength = texelSpecular.r;
#else
	specularStrength = 1.0;
#endif`,_b=`#ifdef USE_SPECULARMAP
	uniform sampler2D specularMap;
#endif`,xb=`#if defined( TONE_MAPPING )
	gl_FragColor.rgb = toneMapping( gl_FragColor.rgb );
#endif`,yb=`#ifndef saturate
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
vec3 OptimizedCineonToneMapping( vec3 color ) {
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
vec3 CustomToneMapping( vec3 color ) { return color; }`,Mb=`#ifdef USE_TRANSMISSION
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
#endif`,Sb=`#ifdef USE_TRANSMISSION
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
#endif`,bb=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
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
#endif`,Eb=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
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
#endif`,wb=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
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
#endif`,Tb=`#if defined( USE_ENVMAP ) || defined( DISTANCE ) || defined ( USE_SHADOWMAP ) || defined ( USE_TRANSMISSION ) || NUM_SPOT_LIGHT_COORDS > 0
	vec4 worldPosition = vec4( transformed, 1.0 );
	#ifdef USE_BATCHING
		worldPosition = batchingMatrix * worldPosition;
	#endif
	#ifdef USE_INSTANCING
		worldPosition = instanceMatrix * worldPosition;
	#endif
	worldPosition = modelMatrix * worldPosition;
#endif`;const Ab=`varying vec2 vUv;
uniform mat3 uvTransform;
void main() {
	vUv = ( uvTransform * vec3( uv, 1 ) ).xy;
	gl_Position = vec4( position.xy, 1.0, 1.0 );
}`,Cb=`uniform sampler2D t2D;
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
}`,Rb=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
	gl_Position.z = gl_Position.w;
}`,Pb=`#ifdef ENVMAP_TYPE_CUBE
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
}`,Lb=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
	gl_Position.z = gl_Position.w;
}`,Ub=`uniform samplerCube tCube;
uniform float tFlip;
uniform float opacity;
varying vec3 vWorldDirection;
void main() {
	vec4 texColor = textureCube( tCube, vec3( tFlip * vWorldDirection.x, vWorldDirection.yz ) );
	gl_FragColor = texColor;
	gl_FragColor.a *= opacity;
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,Db=`#include <common>
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
}`,Ib=`#if DEPTH_PACKING == 3200
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
	#endif
}`,Nb=`#define DISTANCE
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
}`,Ob=`#define DISTANCE
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
}`,kb=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
}`,Fb=`uniform sampler2D tEquirect;
varying vec3 vWorldDirection;
#include <common>
void main() {
	vec3 direction = normalize( vWorldDirection );
	vec2 sampleUV = equirectUv( direction );
	gl_FragColor = texture2D( tEquirect, sampleUV );
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,zb=`uniform float scale;
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
}`,Bb=`uniform vec3 diffuse;
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
}`,Vb=`#include <common>
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
}`,Hb=`uniform vec3 diffuse;
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
}`,Gb=`#define LAMBERT
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
}`,Wb=`#define LAMBERT
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
}`,jb=`#define MATCAP
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
}`,Xb=`#define MATCAP
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
}`,Yb=`#define NORMAL
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
}`,qb=`#define NORMAL
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
}`,Kb=`#define PHONG
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
}`,Zb=`#define PHONG
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
}`,$b=`#define STANDARD
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
}`,Qb=`#define STANDARD
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
}`,Jb=`#define TOON
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
}`,eE=`#define TOON
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
}`,tE=`uniform float size;
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
}`,rE=`uniform vec3 diffuse;
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
}`,iE=`#include <common>
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
}`,nE=`uniform vec3 color;
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
}`,aE=`uniform float rotation;
uniform vec2 center;
#include <common>
#include <uv_pars_vertex>
#include <fog_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	vec4 mvPosition = modelViewMatrix * vec4( 0.0, 0.0, 0.0, 1.0 );
	vec2 scale;
	scale.x = length( vec3( modelMatrix[ 0 ].x, modelMatrix[ 0 ].y, modelMatrix[ 0 ].z ) );
	scale.y = length( vec3( modelMatrix[ 1 ].x, modelMatrix[ 1 ].y, modelMatrix[ 1 ].z ) );
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
}`,sE=`uniform vec3 diffuse;
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
}`,qe={alphahash_fragment:CM,alphahash_pars_fragment:RM,alphamap_fragment:PM,alphamap_pars_fragment:LM,alphatest_fragment:UM,alphatest_pars_fragment:DM,aomap_fragment:IM,aomap_pars_fragment:NM,batching_pars_vertex:OM,batching_vertex:kM,begin_vertex:FM,beginnormal_vertex:zM,bsdfs:BM,iridescence_fragment:VM,bumpmap_pars_fragment:HM,clipping_planes_fragment:GM,clipping_planes_pars_fragment:WM,clipping_planes_pars_vertex:jM,clipping_planes_vertex:XM,color_fragment:YM,color_pars_fragment:qM,color_pars_vertex:KM,color_vertex:ZM,common:$M,cube_uv_reflection_fragment:QM,defaultnormal_vertex:JM,displacementmap_pars_vertex:eS,displacementmap_vertex:tS,emissivemap_fragment:rS,emissivemap_pars_fragment:iS,colorspace_fragment:nS,colorspace_pars_fragment:aS,envmap_fragment:sS,envmap_common_pars_fragment:oS,envmap_pars_fragment:lS,envmap_pars_vertex:uS,envmap_physical_pars_fragment:yS,envmap_vertex:cS,fog_vertex:dS,fog_pars_vertex:hS,fog_fragment:fS,fog_pars_fragment:pS,gradientmap_pars_fragment:mS,lightmap_pars_fragment:gS,lights_lambert_fragment:vS,lights_lambert_pars_fragment:_S,lights_pars_begin:xS,lights_toon_fragment:MS,lights_toon_pars_fragment:SS,lights_phong_fragment:bS,lights_phong_pars_fragment:ES,lights_physical_fragment:wS,lights_physical_pars_fragment:TS,lights_fragment_begin:AS,lights_fragment_maps:CS,lights_fragment_end:RS,logdepthbuf_fragment:PS,logdepthbuf_pars_fragment:LS,logdepthbuf_pars_vertex:US,logdepthbuf_vertex:DS,map_fragment:IS,map_pars_fragment:NS,map_particle_fragment:OS,map_particle_pars_fragment:kS,metalnessmap_fragment:FS,metalnessmap_pars_fragment:zS,morphinstance_vertex:BS,morphcolor_vertex:VS,morphnormal_vertex:HS,morphtarget_pars_vertex:GS,morphtarget_vertex:WS,normal_fragment_begin:jS,normal_fragment_maps:XS,normal_pars_fragment:YS,normal_pars_vertex:qS,normal_vertex:KS,normalmap_pars_fragment:ZS,clearcoat_normal_fragment_begin:$S,clearcoat_normal_fragment_maps:QS,clearcoat_pars_fragment:JS,iridescence_pars_fragment:eb,opaque_fragment:tb,packing:rb,premultiplied_alpha_fragment:ib,project_vertex:nb,dithering_fragment:ab,dithering_pars_fragment:sb,roughnessmap_fragment:ob,roughnessmap_pars_fragment:lb,shadowmap_pars_fragment:ub,shadowmap_pars_vertex:cb,shadowmap_vertex:db,shadowmask_pars_fragment:hb,skinbase_vertex:fb,skinning_pars_vertex:pb,skinning_vertex:mb,skinnormal_vertex:gb,specularmap_fragment:vb,specularmap_pars_fragment:_b,tonemapping_fragment:xb,tonemapping_pars_fragment:yb,transmission_fragment:Mb,transmission_pars_fragment:Sb,uv_pars_fragment:bb,uv_pars_vertex:Eb,uv_vertex:wb,worldpos_vertex:Tb,background_vert:Ab,background_frag:Cb,backgroundCube_vert:Rb,backgroundCube_frag:Pb,cube_vert:Lb,cube_frag:Ub,depth_vert:Db,depth_frag:Ib,distanceRGBA_vert:Nb,distanceRGBA_frag:Ob,equirect_vert:kb,equirect_frag:Fb,linedashed_vert:zb,linedashed_frag:Bb,meshbasic_vert:Vb,meshbasic_frag:Hb,meshlambert_vert:Gb,meshlambert_frag:Wb,meshmatcap_vert:jb,meshmatcap_frag:Xb,meshnormal_vert:Yb,meshnormal_frag:qb,meshphong_vert:Kb,meshphong_frag:Zb,meshphysical_vert:$b,meshphysical_frag:Qb,meshtoon_vert:Jb,meshtoon_frag:eE,points_vert:tE,points_frag:rE,shadow_vert:iE,shadow_frag:nE,sprite_vert:aE,sprite_frag:sE},_e={common:{diffuse:{value:new ke(16777215)},opacity:{value:1},map:{value:null},mapTransform:{value:new Ke},alphaMap:{value:null},alphaMapTransform:{value:new Ke},alphaTest:{value:0}},specularmap:{specularMap:{value:null},specularMapTransform:{value:new Ke}},envmap:{envMap:{value:null},envMapRotation:{value:new Ke},flipEnvMap:{value:-1},reflectivity:{value:1},ior:{value:1.5},refractionRatio:{value:.98}},aomap:{aoMap:{value:null},aoMapIntensity:{value:1},aoMapTransform:{value:new Ke}},lightmap:{lightMap:{value:null},lightMapIntensity:{value:1},lightMapTransform:{value:new Ke}},bumpmap:{bumpMap:{value:null},bumpMapTransform:{value:new Ke},bumpScale:{value:1}},normalmap:{normalMap:{value:null},normalMapTransform:{value:new Ke},normalScale:{value:new Ne(1,1)}},displacementmap:{displacementMap:{value:null},displacementMapTransform:{value:new Ke},displacementScale:{value:1},displacementBias:{value:0}},emissivemap:{emissiveMap:{value:null},emissiveMapTransform:{value:new Ke}},metalnessmap:{metalnessMap:{value:null},metalnessMapTransform:{value:new Ke}},roughnessmap:{roughnessMap:{value:null},roughnessMapTransform:{value:new Ke}},gradientmap:{gradientMap:{value:null}},fog:{fogDensity:{value:25e-5},fogNear:{value:1},fogFar:{value:2e3},fogColor:{value:new ke(16777215)}},lights:{ambientLightColor:{value:[]},lightProbe:{value:[]},directionalLights:{value:[],properties:{direction:{},color:{}}},directionalLightShadows:{value:[],properties:{shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{}}},directionalShadowMap:{value:[]},directionalShadowMatrix:{value:[]},spotLights:{value:[],properties:{color:{},position:{},direction:{},distance:{},coneCos:{},penumbraCos:{},decay:{}}},spotLightShadows:{value:[],properties:{shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{}}},spotLightMap:{value:[]},spotShadowMap:{value:[]},spotLightMatrix:{value:[]},pointLights:{value:[],properties:{color:{},position:{},decay:{},distance:{}}},pointLightShadows:{value:[],properties:{shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{},shadowCameraNear:{},shadowCameraFar:{}}},pointShadowMap:{value:[]},pointShadowMatrix:{value:[]},hemisphereLights:{value:[],properties:{direction:{},skyColor:{},groundColor:{}}},rectAreaLights:{value:[],properties:{color:{},position:{},width:{},height:{}}},ltc_1:{value:null},ltc_2:{value:null}},points:{diffuse:{value:new ke(16777215)},opacity:{value:1},size:{value:1},scale:{value:1},map:{value:null},alphaMap:{value:null},alphaMapTransform:{value:new Ke},alphaTest:{value:0},uvTransform:{value:new Ke}},sprite:{diffuse:{value:new ke(16777215)},opacity:{value:1},center:{value:new Ne(.5,.5)},rotation:{value:0},map:{value:null},mapTransform:{value:new Ke},alphaMap:{value:null},alphaMapTransform:{value:new Ke},alphaTest:{value:0}}},ti={basic:{uniforms:rr([_e.common,_e.specularmap,_e.envmap,_e.aomap,_e.lightmap,_e.fog]),vertexShader:qe.meshbasic_vert,fragmentShader:qe.meshbasic_frag},lambert:{uniforms:rr([_e.common,_e.specularmap,_e.envmap,_e.aomap,_e.lightmap,_e.emissivemap,_e.bumpmap,_e.normalmap,_e.displacementmap,_e.fog,_e.lights,{emissive:{value:new ke(0)}}]),vertexShader:qe.meshlambert_vert,fragmentShader:qe.meshlambert_frag},phong:{uniforms:rr([_e.common,_e.specularmap,_e.envmap,_e.aomap,_e.lightmap,_e.emissivemap,_e.bumpmap,_e.normalmap,_e.displacementmap,_e.fog,_e.lights,{emissive:{value:new ke(0)},specular:{value:new ke(1118481)},shininess:{value:30}}]),vertexShader:qe.meshphong_vert,fragmentShader:qe.meshphong_frag},standard:{uniforms:rr([_e.common,_e.envmap,_e.aomap,_e.lightmap,_e.emissivemap,_e.bumpmap,_e.normalmap,_e.displacementmap,_e.roughnessmap,_e.metalnessmap,_e.fog,_e.lights,{emissive:{value:new ke(0)},roughness:{value:1},metalness:{value:0},envMapIntensity:{value:1}}]),vertexShader:qe.meshphysical_vert,fragmentShader:qe.meshphysical_frag},toon:{uniforms:rr([_e.common,_e.aomap,_e.lightmap,_e.emissivemap,_e.bumpmap,_e.normalmap,_e.displacementmap,_e.gradientmap,_e.fog,_e.lights,{emissive:{value:new ke(0)}}]),vertexShader:qe.meshtoon_vert,fragmentShader:qe.meshtoon_frag},matcap:{uniforms:rr([_e.common,_e.bumpmap,_e.normalmap,_e.displacementmap,_e.fog,{matcap:{value:null}}]),vertexShader:qe.meshmatcap_vert,fragmentShader:qe.meshmatcap_frag},points:{uniforms:rr([_e.points,_e.fog]),vertexShader:qe.points_vert,fragmentShader:qe.points_frag},dashed:{uniforms:rr([_e.common,_e.fog,{scale:{value:1},dashSize:{value:1},totalSize:{value:2}}]),vertexShader:qe.linedashed_vert,fragmentShader:qe.linedashed_frag},depth:{uniforms:rr([_e.common,_e.displacementmap]),vertexShader:qe.depth_vert,fragmentShader:qe.depth_frag},normal:{uniforms:rr([_e.common,_e.bumpmap,_e.normalmap,_e.displacementmap,{opacity:{value:1}}]),vertexShader:qe.meshnormal_vert,fragmentShader:qe.meshnormal_frag},sprite:{uniforms:rr([_e.sprite,_e.fog]),vertexShader:qe.sprite_vert,fragmentShader:qe.sprite_frag},background:{uniforms:{uvTransform:{value:new Ke},t2D:{value:null},backgroundIntensity:{value:1}},vertexShader:qe.background_vert,fragmentShader:qe.background_frag},backgroundCube:{uniforms:{envMap:{value:null},flipEnvMap:{value:-1},backgroundBlurriness:{value:0},backgroundIntensity:{value:1},backgroundRotation:{value:new Ke}},vertexShader:qe.backgroundCube_vert,fragmentShader:qe.backgroundCube_frag},cube:{uniforms:{tCube:{value:null},tFlip:{value:-1},opacity:{value:1}},vertexShader:qe.cube_vert,fragmentShader:qe.cube_frag},equirect:{uniforms:{tEquirect:{value:null}},vertexShader:qe.equirect_vert,fragmentShader:qe.equirect_frag},distanceRGBA:{uniforms:rr([_e.common,_e.displacementmap,{referencePosition:{value:new O},nearDistance:{value:1},farDistance:{value:1e3}}]),vertexShader:qe.distanceRGBA_vert,fragmentShader:qe.distanceRGBA_frag},shadow:{uniforms:rr([_e.lights,_e.fog,{color:{value:new ke(0)},opacity:{value:1}}]),vertexShader:qe.shadow_vert,fragmentShader:qe.shadow_frag}};ti.physical={uniforms:rr([ti.standard.uniforms,{clearcoat:{value:0},clearcoatMap:{value:null},clearcoatMapTransform:{value:new Ke},clearcoatNormalMap:{value:null},clearcoatNormalMapTransform:{value:new Ke},clearcoatNormalScale:{value:new Ne(1,1)},clearcoatRoughness:{value:0},clearcoatRoughnessMap:{value:null},clearcoatRoughnessMapTransform:{value:new Ke},dispersion:{value:0},iridescence:{value:0},iridescenceMap:{value:null},iridescenceMapTransform:{value:new Ke},iridescenceIOR:{value:1.3},iridescenceThicknessMinimum:{value:100},iridescenceThicknessMaximum:{value:400},iridescenceThicknessMap:{value:null},iridescenceThicknessMapTransform:{value:new Ke},sheen:{value:0},sheenColor:{value:new ke(0)},sheenColorMap:{value:null},sheenColorMapTransform:{value:new Ke},sheenRoughness:{value:1},sheenRoughnessMap:{value:null},sheenRoughnessMapTransform:{value:new Ke},transmission:{value:0},transmissionMap:{value:null},transmissionMapTransform:{value:new Ke},transmissionSamplerSize:{value:new Ne},transmissionSamplerMap:{value:null},thickness:{value:0},thicknessMap:{value:null},thicknessMapTransform:{value:new Ke},attenuationDistance:{value:0},attenuationColor:{value:new ke(0)},specularColor:{value:new ke(1,1,1)},specularColorMap:{value:null},specularColorMapTransform:{value:new Ke},specularIntensity:{value:1},specularIntensityMap:{value:null},specularIntensityMapTransform:{value:new Ke},anisotropyVector:{value:new Ne},anisotropyMap:{value:null},anisotropyMapTransform:{value:new Ke}}]),vertexShader:qe.meshphysical_vert,fragmentShader:qe.meshphysical_frag};const jo={r:0,b:0,g:0},xn=new oi,oE=new ft;function lE(t,e,r,i,n,a,s){const o=new ke(0);let l=a===!0?0:1,u,h,f=null,d=0,p=null;function _(g){let v=g.isScene===!0?g.background:null;return v&&v.isTexture&&(v=(g.backgroundBlurriness>0?r:e).get(v)),v}function x(g){let v=!1;const M=_(g);M===null?c(o,l):M&&M.isColor&&(c(M,1),v=!0);const P=t.xr.getEnvironmentBlendMode();P==="additive"?i.buffers.color.setClear(0,0,0,1,s):P==="alpha-blend"&&i.buffers.color.setClear(0,0,0,0,s),(t.autoClear||v)&&(i.buffers.depth.setTest(!0),i.buffers.depth.setMask(!0),i.buffers.color.setMask(!0),t.clear(t.autoClearColor,t.autoClearDepth,t.autoClearStencil))}function m(g,v){const M=_(v);M&&(M.isCubeTexture||M.mapping===hu)?(h===void 0&&(h=new mt(new bi(1,1,1),new un({name:"BackgroundCubeMaterial",uniforms:Ya(ti.backgroundCube.uniforms),vertexShader:ti.backgroundCube.vertexShader,fragmentShader:ti.backgroundCube.fragmentShader,side:vr,depthTest:!1,depthWrite:!1,fog:!1})),h.geometry.deleteAttribute("normal"),h.geometry.deleteAttribute("uv"),h.onBeforeRender=function(P,T,w){this.matrixWorld.copyPosition(w.matrixWorld)},Object.defineProperty(h.material,"envMap",{get:function(){return this.uniforms.envMap.value}}),n.update(h)),xn.copy(v.backgroundRotation),xn.x*=-1,xn.y*=-1,xn.z*=-1,M.isCubeTexture&&M.isRenderTargetTexture===!1&&(xn.y*=-1,xn.z*=-1),h.material.uniforms.envMap.value=M,h.material.uniforms.flipEnvMap.value=M.isCubeTexture&&M.isRenderTargetTexture===!1?-1:1,h.material.uniforms.backgroundBlurriness.value=v.backgroundBlurriness,h.material.uniforms.backgroundIntensity.value=v.backgroundIntensity,h.material.uniforms.backgroundRotation.value.setFromMatrix4(oE.makeRotationFromEuler(xn)),h.material.toneMapped=ut.getTransfer(M.colorSpace)!==_t,(f!==M||d!==M.version||p!==t.toneMapping)&&(h.material.needsUpdate=!0,f=M,d=M.version,p=t.toneMapping),h.layers.enableAll(),g.unshift(h,h.geometry,h.material,0,0,null)):M&&M.isTexture&&(u===void 0&&(u=new mt(new ao(2,2),new un({name:"BackgroundMaterial",uniforms:Ya(ti.background.uniforms),vertexShader:ti.background.vertexShader,fragmentShader:ti.background.fragmentShader,side:on,depthTest:!1,depthWrite:!1,fog:!1})),u.geometry.deleteAttribute("normal"),Object.defineProperty(u.material,"map",{get:function(){return this.uniforms.t2D.value}}),n.update(u)),u.material.uniforms.t2D.value=M,u.material.uniforms.backgroundIntensity.value=v.backgroundIntensity,u.material.toneMapped=ut.getTransfer(M.colorSpace)!==_t,M.matrixAutoUpdate===!0&&M.updateMatrix(),u.material.uniforms.uvTransform.value.copy(M.matrix),(f!==M||d!==M.version||p!==t.toneMapping)&&(u.material.needsUpdate=!0,f=M,d=M.version,p=t.toneMapping),u.layers.enableAll(),g.unshift(u,u.geometry,u.material,0,0,null))}function c(g,v){g.getRGB(jo,o_(t)),i.buffers.color.setClear(jo.r,jo.g,jo.b,v,s)}return{getClearColor:function(){return o},setClearColor:function(g,v=1){o.set(g),l=v,c(o,l)},getClearAlpha:function(){return l},setClearAlpha:function(g){l=g,c(o,l)},render:x,addToRenderList:m}}function uE(t,e){const r=t.getParameter(t.MAX_VERTEX_ATTRIBS),i={},n=d(null);let a=n,s=!1;function o(y,U,B,V,q){let J=!1;const K=f(V,B,U);a!==K&&(a=K,u(a.object)),J=p(y,V,B,q),J&&_(y,V,B,q),q!==null&&e.update(q,t.ELEMENT_ARRAY_BUFFER),(J||s)&&(s=!1,M(y,U,B,V),q!==null&&t.bindBuffer(t.ELEMENT_ARRAY_BUFFER,e.get(q).buffer))}function l(){return t.createVertexArray()}function u(y){return t.bindVertexArray(y)}function h(y){return t.deleteVertexArray(y)}function f(y,U,B){const V=B.wireframe===!0;let q=i[y.id];q===void 0&&(q={},i[y.id]=q);let J=q[U.id];J===void 0&&(J={},q[U.id]=J);let K=J[V];return K===void 0&&(K=d(l()),J[V]=K),K}function d(y){const U=[],B=[],V=[];for(let q=0;q<r;q++)U[q]=0,B[q]=0,V[q]=0;return{geometry:null,program:null,wireframe:!1,newAttributes:U,enabledAttributes:B,attributeDivisors:V,object:y,attributes:{},index:null}}function p(y,U,B,V){const q=a.attributes,J=U.attributes;let K=0;const ne=B.getAttributes();for(const I in ne)if(ne[I].location>=0){const Z=q[I];let re=J[I];if(re===void 0&&(I==="instanceMatrix"&&y.instanceMatrix&&(re=y.instanceMatrix),I==="instanceColor"&&y.instanceColor&&(re=y.instanceColor)),Z===void 0||Z.attribute!==re||re&&Z.data!==re.data)return!0;K++}return a.attributesNum!==K||a.index!==V}function _(y,U,B,V){const q={},J=U.attributes;let K=0;const ne=B.getAttributes();for(const I in ne)if(ne[I].location>=0){let Z=J[I];Z===void 0&&(I==="instanceMatrix"&&y.instanceMatrix&&(Z=y.instanceMatrix),I==="instanceColor"&&y.instanceColor&&(Z=y.instanceColor));const re={};re.attribute=Z,Z&&Z.data&&(re.data=Z.data),q[I]=re,K++}a.attributes=q,a.attributesNum=K,a.index=V}function x(){const y=a.newAttributes;for(let U=0,B=y.length;U<B;U++)y[U]=0}function m(y){c(y,0)}function c(y,U){const B=a.newAttributes,V=a.enabledAttributes,q=a.attributeDivisors;B[y]=1,V[y]===0&&(t.enableVertexAttribArray(y),V[y]=1),q[y]!==U&&(t.vertexAttribDivisor(y,U),q[y]=U)}function g(){const y=a.newAttributes,U=a.enabledAttributes;for(let B=0,V=U.length;B<V;B++)U[B]!==y[B]&&(t.disableVertexAttribArray(B),U[B]=0)}function v(y,U,B,V,q,J,K){K===!0?t.vertexAttribIPointer(y,U,B,q,J):t.vertexAttribPointer(y,U,B,V,q,J)}function M(y,U,B,V){x();const q=V.attributes,J=B.getAttributes(),K=U.defaultAttributeValues;for(const ne in J){const I=J[ne];if(I.location>=0){let Z=q[ne];if(Z===void 0&&(ne==="instanceMatrix"&&y.instanceMatrix&&(Z=y.instanceMatrix),ne==="instanceColor"&&y.instanceColor&&(Z=y.instanceColor)),Z!==void 0){const re=Z.normalized,xe=Z.itemSize,fe=e.get(Z);if(fe===void 0)continue;const Ue=fe.buffer,Y=fe.type,ee=fe.bytesPerElement,ae=Y===t.INT||Y===t.UNSIGNED_INT||Z.gpuType===jv;if(Z.isInterleavedBufferAttribute){const ue=Z.data,Ce=ue.stride,Fe=Z.offset;if(ue.isInstancedInterleavedBuffer){for(let Ze=0;Ze<I.locationSize;Ze++)c(I.location+Ze,ue.meshPerAttribute);y.isInstancedMesh!==!0&&V._maxInstanceCount===void 0&&(V._maxInstanceCount=ue.meshPerAttribute*ue.count)}else for(let Ze=0;Ze<I.locationSize;Ze++)m(I.location+Ze);t.bindBuffer(t.ARRAY_BUFFER,Ue);for(let Ze=0;Ze<I.locationSize;Ze++)v(I.location+Ze,xe/I.locationSize,Y,re,Ce*ee,(Fe+xe/I.locationSize*Ze)*ee,ae)}else{if(Z.isInstancedBufferAttribute){for(let ue=0;ue<I.locationSize;ue++)c(I.location+ue,Z.meshPerAttribute);y.isInstancedMesh!==!0&&V._maxInstanceCount===void 0&&(V._maxInstanceCount=Z.meshPerAttribute*Z.count)}else for(let ue=0;ue<I.locationSize;ue++)m(I.location+ue);t.bindBuffer(t.ARRAY_BUFFER,Ue);for(let ue=0;ue<I.locationSize;ue++)v(I.location+ue,xe/I.locationSize,Y,re,xe*ee,xe/I.locationSize*ue*ee,ae)}}else if(K!==void 0){const re=K[ne];if(re!==void 0)switch(re.length){case 2:t.vertexAttrib2fv(I.location,re);break;case 3:t.vertexAttrib3fv(I.location,re);break;case 4:t.vertexAttrib4fv(I.location,re);break;default:t.vertexAttrib1fv(I.location,re)}}}}g()}function P(){L();for(const y in i){const U=i[y];for(const B in U){const V=U[B];for(const q in V)h(V[q].object),delete V[q];delete U[B]}delete i[y]}}function T(y){if(i[y.id]===void 0)return;const U=i[y.id];for(const B in U){const V=U[B];for(const q in V)h(V[q].object),delete V[q];delete U[B]}delete i[y.id]}function w(y){for(const U in i){const B=i[U];if(B[y.id]===void 0)continue;const V=B[y.id];for(const q in V)h(V[q].object),delete V[q];delete B[y.id]}}function L(){b(),s=!0,a!==n&&(a=n,u(a.object))}function b(){n.geometry=null,n.program=null,n.wireframe=!1}return{setup:o,reset:L,resetDefaultState:b,dispose:P,releaseStatesOfGeometry:T,releaseStatesOfProgram:w,initAttributes:x,enableAttribute:m,disableUnusedAttributes:g}}function cE(t,e,r){let i;function n(u){i=u}function a(u,h){t.drawArrays(i,u,h),r.update(h,i,1)}function s(u,h,f){f!==0&&(t.drawArraysInstanced(i,u,h,f),r.update(h,i,f))}function o(u,h,f){if(f===0)return;const d=e.get("WEBGL_multi_draw");if(d===null)for(let p=0;p<f;p++)this.render(u[p],h[p]);else{d.multiDrawArraysWEBGL(i,u,0,h,0,f);let p=0;for(let _=0;_<f;_++)p+=h[_];r.update(p,i,1)}}function l(u,h,f,d){if(f===0)return;const p=e.get("WEBGL_multi_draw");if(p===null)for(let _=0;_<u.length;_++)s(u[_],h[_],d[_]);else{p.multiDrawArraysInstancedWEBGL(i,u,0,h,0,d,0,f);let _=0;for(let x=0;x<f;x++)_+=h[x];for(let x=0;x<d.length;x++)r.update(_,i,d[x])}}this.setMode=n,this.render=a,this.renderInstances=s,this.renderMultiDraw=o,this.renderMultiDrawInstances=l}function dE(t,e,r,i){let n;function a(){if(n!==void 0)return n;if(e.has("EXT_texture_filter_anisotropic")===!0){const T=e.get("EXT_texture_filter_anisotropic");n=t.getParameter(T.MAX_TEXTURE_MAX_ANISOTROPY_EXT)}else n=0;return n}function s(T){return!(T!==ni&&i.convert(T)!==t.getParameter(t.IMPLEMENTATION_COLOR_READ_FORMAT))}function o(T){const w=T===fu&&(e.has("EXT_color_buffer_half_float")||e.has("EXT_color_buffer_float"));return!(T!==ln&&i.convert(T)!==t.getParameter(t.IMPLEMENTATION_COLOR_READ_TYPE)&&T!==Mi&&!w)}function l(T){if(T==="highp"){if(t.getShaderPrecisionFormat(t.VERTEX_SHADER,t.HIGH_FLOAT).precision>0&&t.getShaderPrecisionFormat(t.FRAGMENT_SHADER,t.HIGH_FLOAT).precision>0)return"highp";T="mediump"}return T==="mediump"&&t.getShaderPrecisionFormat(t.VERTEX_SHADER,t.MEDIUM_FLOAT).precision>0&&t.getShaderPrecisionFormat(t.FRAGMENT_SHADER,t.MEDIUM_FLOAT).precision>0?"mediump":"lowp"}let u=r.precision!==void 0?r.precision:"highp";const h=l(u);h!==u&&(console.warn("THREE.WebGLRenderer:",u,"not supported, using",h,"instead."),u=h);const f=r.logarithmicDepthBuffer===!0,d=t.getParameter(t.MAX_TEXTURE_IMAGE_UNITS),p=t.getParameter(t.MAX_VERTEX_TEXTURE_IMAGE_UNITS),_=t.getParameter(t.MAX_TEXTURE_SIZE),x=t.getParameter(t.MAX_CUBE_MAP_TEXTURE_SIZE),m=t.getParameter(t.MAX_VERTEX_ATTRIBS),c=t.getParameter(t.MAX_VERTEX_UNIFORM_VECTORS),g=t.getParameter(t.MAX_VARYING_VECTORS),v=t.getParameter(t.MAX_FRAGMENT_UNIFORM_VECTORS),M=p>0,P=t.getParameter(t.MAX_SAMPLES);return{isWebGL2:!0,getMaxAnisotropy:a,getMaxPrecision:l,textureFormatReadable:s,textureTypeReadable:o,precision:u,logarithmicDepthBuffer:f,maxTextures:d,maxVertexTextures:p,maxTextureSize:_,maxCubemapSize:x,maxAttributes:m,maxVertexUniforms:c,maxVaryings:g,maxFragmentUniforms:v,vertexTextures:M,maxSamples:P}}function hE(t){const e=this;let r=null,i=0,n=!1,a=!1;const s=new Vi,o=new Ke,l={value:null,needsUpdate:!1};this.uniform=l,this.numPlanes=0,this.numIntersection=0,this.init=function(f,d){const p=f.length!==0||d||i!==0||n;return n=d,i=f.length,p},this.beginShadows=function(){a=!0,h(null)},this.endShadows=function(){a=!1},this.setGlobalState=function(f,d){r=h(f,d,0)},this.setState=function(f,d,p){const _=f.clippingPlanes,x=f.clipIntersection,m=f.clipShadows,c=t.get(f);if(!n||_===null||_.length===0||a&&!m)a?h(null):u();else{const g=a?0:i,v=g*4;let M=c.clippingState||null;l.value=M,M=h(_,d,v,p);for(let P=0;P!==v;++P)M[P]=r[P];c.clippingState=M,this.numIntersection=x?this.numPlanes:0,this.numPlanes+=g}};function u(){l.value!==r&&(l.value=r,l.needsUpdate=i>0),e.numPlanes=i,e.numIntersection=0}function h(f,d,p,_){const x=f!==null?f.length:0;let m=null;if(x!==0){if(m=l.value,_!==!0||m===null){const c=p+x*4,g=d.matrixWorldInverse;o.getNormalMatrix(g),(m===null||m.length<c)&&(m=new Float32Array(c));for(let v=0,M=p;v!==x;++v,M+=4)s.copy(f[v]).applyMatrix4(g,o),s.normal.toArray(m,M),m[M+3]=s.constant}l.value=m,l.needsUpdate=!0}return e.numPlanes=x,e.numIntersection=0,m}}function fE(t){let e=new WeakMap;function r(s,o){return o===wd?s.mapping=Ha:o===Td&&(s.mapping=Ga),s}function i(s){if(s&&s.isTexture){const o=s.mapping;if(o===wd||o===Td)if(e.has(s)){const l=e.get(s).texture;return r(l,s.mapping)}else{const l=s.image;if(l&&l.height>0){const u=new EM(l.height);return u.fromEquirectangularTexture(t,s),e.set(s,u),s.addEventListener("dispose",n),r(u.texture,s.mapping)}else return null}}return s}function n(s){const o=s.target;o.removeEventListener("dispose",n);const l=e.get(o);l!==void 0&&(e.delete(o),l.dispose())}function a(){e=new WeakMap}return{get:i,dispose:a}}class d_ extends l_{constructor(e=-1,r=1,i=1,n=-1,a=.1,s=2e3){super(),this.isOrthographicCamera=!0,this.type="OrthographicCamera",this.zoom=1,this.view=null,this.left=e,this.right=r,this.top=i,this.bottom=n,this.near=a,this.far=s,this.updateProjectionMatrix()}copy(e,r){return super.copy(e,r),this.left=e.left,this.right=e.right,this.top=e.top,this.bottom=e.bottom,this.near=e.near,this.far=e.far,this.zoom=e.zoom,this.view=e.view===null?null:Object.assign({},e.view),this}setViewOffset(e,r,i,n,a,s){this.view===null&&(this.view={enabled:!0,fullWidth:1,fullHeight:1,offsetX:0,offsetY:0,width:1,height:1}),this.view.enabled=!0,this.view.fullWidth=e,this.view.fullHeight=r,this.view.offsetX=i,this.view.offsetY=n,this.view.width=a,this.view.height=s,this.updateProjectionMatrix()}clearViewOffset(){this.view!==null&&(this.view.enabled=!1),this.updateProjectionMatrix()}updateProjectionMatrix(){const e=(this.right-this.left)/(2*this.zoom),r=(this.top-this.bottom)/(2*this.zoom),i=(this.right+this.left)/2,n=(this.top+this.bottom)/2;let a=i-e,s=i+e,o=n+r,l=n-r;if(this.view!==null&&this.view.enabled){const u=(this.right-this.left)/this.view.fullWidth/this.zoom,h=(this.top-this.bottom)/this.view.fullHeight/this.zoom;a+=u*this.view.offsetX,s=a+u*this.view.width,o-=h*this.view.offsetY,l=o-h*this.view.height}this.projectionMatrix.makeOrthographic(a,s,o,l,this.near,this.far,this.coordinateSystem),this.projectionMatrixInverse.copy(this.projectionMatrix).invert()}toJSON(e){const r=super.toJSON(e);return r.object.zoom=this.zoom,r.object.left=this.left,r.object.right=this.right,r.object.top=this.top,r.object.bottom=this.bottom,r.object.near=this.near,r.object.far=this.far,this.view!==null&&(r.object.view=Object.assign({},this.view)),r}}const Ea=4,Vp=[.125,.215,.35,.446,.526,.582],Tn=20,xc=new d_,Hp=new ke;let yc=null,Mc=0,Sc=0,bc=!1;const En=(1+Math.sqrt(5))/2,la=1/En,Gp=[new O(-En,la,0),new O(En,la,0),new O(-la,0,En),new O(la,0,En),new O(0,En,-la),new O(0,En,la),new O(-1,1,-1),new O(1,1,-1),new O(-1,1,1),new O(1,1,1)];class Wp{constructor(e){this._renderer=e,this._pingPongRenderTarget=null,this._lodMax=0,this._cubeSize=0,this._lodPlanes=[],this._sizeLods=[],this._sigmas=[],this._blurMaterial=null,this._cubemapMaterial=null,this._equirectMaterial=null,this._compileMaterial(this._blurMaterial)}fromScene(e,r=0,i=.1,n=100){yc=this._renderer.getRenderTarget(),Mc=this._renderer.getActiveCubeFace(),Sc=this._renderer.getActiveMipmapLevel(),bc=this._renderer.xr.enabled,this._renderer.xr.enabled=!1,this._setSize(256);const a=this._allocateTargets();return a.depthBuffer=!0,this._sceneToCubeUV(e,i,n,a),r>0&&this._blur(a,0,0,r),this._applyPMREM(a),this._cleanup(a),a}fromEquirectangular(e,r=null){return this._fromTexture(e,r)}fromCubemap(e,r=null){return this._fromTexture(e,r)}compileCubemapShader(){this._cubemapMaterial===null&&(this._cubemapMaterial=Yp(),this._compileMaterial(this._cubemapMaterial))}compileEquirectangularShader(){this._equirectMaterial===null&&(this._equirectMaterial=Xp(),this._compileMaterial(this._equirectMaterial))}dispose(){this._dispose(),this._cubemapMaterial!==null&&this._cubemapMaterial.dispose(),this._equirectMaterial!==null&&this._equirectMaterial.dispose()}_setSize(e){this._lodMax=Math.floor(Math.log2(e)),this._cubeSize=Math.pow(2,this._lodMax)}_dispose(){this._blurMaterial!==null&&this._blurMaterial.dispose(),this._pingPongRenderTarget!==null&&this._pingPongRenderTarget.dispose();for(let e=0;e<this._lodPlanes.length;e++)this._lodPlanes[e].dispose()}_cleanup(e){this._renderer.setRenderTarget(yc,Mc,Sc),this._renderer.xr.enabled=bc,e.scissorTest=!1,Xo(e,0,0,e.width,e.height)}_fromTexture(e,r){e.mapping===Ha||e.mapping===Ga?this._setSize(e.image.length===0?16:e.image[0].width||e.image[0].image.width):this._setSize(e.image.width/4),yc=this._renderer.getRenderTarget(),Mc=this._renderer.getActiveCubeFace(),Sc=this._renderer.getActiveMipmapLevel(),bc=this._renderer.xr.enabled,this._renderer.xr.enabled=!1;const i=r||this._allocateTargets();return this._textureToCubeUV(e,i),this._applyPMREM(i),this._cleanup(i),i}_allocateTargets(){const e=3*Math.max(this._cubeSize,112),r=4*this._cubeSize,i={magFilter:Xr,minFilter:Xr,generateMipmaps:!1,type:fu,format:ni,colorSpace:fn,depthBuffer:!1},n=jp(e,r,i);if(this._pingPongRenderTarget===null||this._pingPongRenderTarget.width!==e||this._pingPongRenderTarget.height!==r){this._pingPongRenderTarget!==null&&this._dispose(),this._pingPongRenderTarget=jp(e,r,i);const{_lodMax:a}=this;({sizeLods:this._sizeLods,lodPlanes:this._lodPlanes,sigmas:this._sigmas}=pE(a)),this._blurMaterial=mE(a,e,r)}return n}_compileMaterial(e){const r=new mt(this._lodPlanes[0],e);this._renderer.compile(r,xc)}_sceneToCubeUV(e,r,i,n){const a=new Sr(90,1,r,i),s=[1,-1,1,1,1,1],o=[1,1,1,-1,-1,-1],l=this._renderer,u=l.autoClear,h=l.toneMapping;l.getClearColor(Hp),l.toneMapping=nn,l.autoClear=!1;const f=new Is({name:"PMREM.Background",side:vr,depthWrite:!1,depthTest:!1}),d=new mt(new bi,f);let p=!1;const _=e.background;_?_.isColor&&(f.color.copy(_),e.background=null,p=!0):(f.color.copy(Hp),p=!0);for(let x=0;x<6;x++){const m=x%3;m===0?(a.up.set(0,s[x],0),a.lookAt(o[x],0,0)):m===1?(a.up.set(0,0,s[x]),a.lookAt(0,o[x],0)):(a.up.set(0,s[x],0),a.lookAt(0,0,o[x]));const c=this._cubeSize;Xo(n,m*c,x>2?c:0,c,c),l.setRenderTarget(n),p&&l.render(d,a),l.render(e,a)}d.geometry.dispose(),d.material.dispose(),l.toneMapping=h,l.autoClear=u,e.background=_}_textureToCubeUV(e,r){const i=this._renderer,n=e.mapping===Ha||e.mapping===Ga;n?(this._cubemapMaterial===null&&(this._cubemapMaterial=Yp()),this._cubemapMaterial.uniforms.flipEnvMap.value=e.isRenderTargetTexture===!1?-1:1):this._equirectMaterial===null&&(this._equirectMaterial=Xp());const a=n?this._cubemapMaterial:this._equirectMaterial,s=new mt(this._lodPlanes[0],a),o=a.uniforms;o.envMap.value=e;const l=this._cubeSize;Xo(r,0,0,3*l,2*l),i.setRenderTarget(r),i.render(s,xc)}_applyPMREM(e){const r=this._renderer,i=r.autoClear;r.autoClear=!1;const n=this._lodPlanes.length;for(let a=1;a<n;a++){const s=Math.sqrt(this._sigmas[a]*this._sigmas[a]-this._sigmas[a-1]*this._sigmas[a-1]),o=Gp[(n-a-1)%Gp.length];this._blur(e,a-1,a,s,o)}r.autoClear=i}_blur(e,r,i,n,a){const s=this._pingPongRenderTarget;this._halfBlur(e,s,r,i,n,"latitudinal",a),this._halfBlur(s,e,i,i,n,"longitudinal",a)}_halfBlur(e,r,i,n,a,s,o){const l=this._renderer,u=this._blurMaterial;s!=="latitudinal"&&s!=="longitudinal"&&console.error("blur direction must be either latitudinal or longitudinal!");const h=3,f=new mt(this._lodPlanes[n],u),d=u.uniforms,p=this._sizeLods[i]-1,_=isFinite(a)?Math.PI/(2*p):2*Math.PI/(2*Tn-1),x=a/_,m=isFinite(a)?1+Math.floor(h*x):Tn;m>Tn&&console.warn(`sigmaRadians, ${a}, is too large and will clip, as it requested ${m} samples when the maximum is set to ${Tn}`);const c=[];let g=0;for(let w=0;w<Tn;++w){const L=w/x,b=Math.exp(-L*L/2);c.push(b),w===0?g+=b:w<m&&(g+=2*b)}for(let w=0;w<c.length;w++)c[w]=c[w]/g;d.envMap.value=e.texture,d.samples.value=m,d.weights.value=c,d.latitudinal.value=s==="latitudinal",o&&(d.poleAxis.value=o);const{_lodMax:v}=this;d.dTheta.value=_,d.mipInt.value=v-i;const M=this._sizeLods[n],P=3*M*(n>v-Ea?n-v+Ea:0),T=4*(this._cubeSize-M);Xo(r,P,T,3*M,2*M),l.setRenderTarget(r),l.render(f,xc)}}function pE(t){const e=[],r=[],i=[];let n=t;const a=t-Ea+1+Vp.length;for(let s=0;s<a;s++){const o=Math.pow(2,n);r.push(o);let l=1/o;s>t-Ea?l=Vp[s-t+Ea-1]:s===0&&(l=0),i.push(l);const u=1/(o-2),h=-u,f=1+u,d=[h,h,f,h,f,f,h,h,f,f,h,f],p=6,_=6,x=3,m=2,c=1,g=new Float32Array(x*_*p),v=new Float32Array(m*_*p),M=new Float32Array(c*_*p);for(let T=0;T<p;T++){const w=T%3*2/3-1,L=T>2?0:-1,b=[w,L,0,w+2/3,L,0,w+2/3,L+1,0,w,L,0,w+2/3,L+1,0,w,L+1,0];g.set(b,x*_*T),v.set(d,m*_*T);const y=[T,T,T,T,T,T];M.set(y,c*_*T)}const P=new Or;P.setAttribute("position",new Kr(g,x)),P.setAttribute("uv",new Kr(v,m)),P.setAttribute("faceIndex",new Kr(M,c)),e.push(P),n>Ea&&n--}return{lodPlanes:e,sizeLods:r,sigmas:i}}function jp(t,e,r){const i=new zn(t,e,r);return i.texture.mapping=hu,i.texture.name="PMREM.cubeUv",i.scissorTest=!0,i}function Xo(t,e,r,i,n){t.viewport.set(e,r,i,n),t.scissor.set(e,r,i,n)}function mE(t,e,r){const i=new Float32Array(Tn),n=new O(0,1,0);return new un({name:"SphericalGaussianBlur",defines:{n:Tn,CUBEUV_TEXEL_WIDTH:1/e,CUBEUV_TEXEL_HEIGHT:1/r,CUBEUV_MAX_MIP:`${t}.0`},uniforms:{envMap:{value:null},samples:{value:1},weights:{value:i},latitudinal:{value:!1},dTheta:{value:0},mipInt:{value:0},poleAxis:{value:n}},vertexShader:Ph(),fragmentShader:`

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
		`,blending:rn,depthTest:!1,depthWrite:!1})}function Xp(){return new un({name:"EquirectangularToCubeUV",uniforms:{envMap:{value:null}},vertexShader:Ph(),fragmentShader:`

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
		`,blending:rn,depthTest:!1,depthWrite:!1})}function Yp(){return new un({name:"CubemapToCubeUV",uniforms:{envMap:{value:null},flipEnvMap:{value:-1}},vertexShader:Ph(),fragmentShader:`

			precision mediump float;
			precision mediump int;

			uniform float flipEnvMap;

			varying vec3 vOutputDirection;

			uniform samplerCube envMap;

			void main() {

				gl_FragColor = textureCube( envMap, vec3( flipEnvMap * vOutputDirection.x, vOutputDirection.yz ) );

			}
		`,blending:rn,depthTest:!1,depthWrite:!1})}function Ph(){return`

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
	`}function gE(t){let e=new WeakMap,r=null;function i(o){if(o&&o.isTexture){const l=o.mapping,u=l===wd||l===Td,h=l===Ha||l===Ga;if(u||h){let f=e.get(o);const d=f!==void 0?f.texture.pmremVersion:0;if(o.isRenderTargetTexture&&o.pmremVersion!==d)return r===null&&(r=new Wp(t)),f=u?r.fromEquirectangular(o,f):r.fromCubemap(o,f),f.texture.pmremVersion=o.pmremVersion,e.set(o,f),f.texture;if(f!==void 0)return f.texture;{const p=o.image;return u&&p&&p.height>0||h&&p&&n(p)?(r===null&&(r=new Wp(t)),f=u?r.fromEquirectangular(o):r.fromCubemap(o),f.texture.pmremVersion=o.pmremVersion,e.set(o,f),o.addEventListener("dispose",a),f.texture):null}}}return o}function n(o){let l=0;const u=6;for(let h=0;h<u;h++)o[h]!==void 0&&l++;return l===u}function a(o){const l=o.target;l.removeEventListener("dispose",a);const u=e.get(l);u!==void 0&&(e.delete(l),u.dispose())}function s(){e=new WeakMap,r!==null&&(r.dispose(),r=null)}return{get:i,dispose:s}}function vE(t){const e={};function r(i){if(e[i]!==void 0)return e[i];let n;switch(i){case"WEBGL_depth_texture":n=t.getExtension("WEBGL_depth_texture")||t.getExtension("MOZ_WEBGL_depth_texture")||t.getExtension("WEBKIT_WEBGL_depth_texture");break;case"EXT_texture_filter_anisotropic":n=t.getExtension("EXT_texture_filter_anisotropic")||t.getExtension("MOZ_EXT_texture_filter_anisotropic")||t.getExtension("WEBKIT_EXT_texture_filter_anisotropic");break;case"WEBGL_compressed_texture_s3tc":n=t.getExtension("WEBGL_compressed_texture_s3tc")||t.getExtension("MOZ_WEBGL_compressed_texture_s3tc")||t.getExtension("WEBKIT_WEBGL_compressed_texture_s3tc");break;case"WEBGL_compressed_texture_pvrtc":n=t.getExtension("WEBGL_compressed_texture_pvrtc")||t.getExtension("WEBKIT_WEBGL_compressed_texture_pvrtc");break;default:n=t.getExtension(i)}return e[i]=n,n}return{has:function(i){return r(i)!==null},init:function(){r("EXT_color_buffer_float"),r("WEBGL_clip_cull_distance"),r("OES_texture_float_linear"),r("EXT_color_buffer_half_float"),r("WEBGL_multisampled_render_to_texture"),r("WEBGL_render_shared_exponent")},get:function(i){const n=r(i);return n===null&&t_("THREE.WebGLRenderer: "+i+" extension not supported."),n}}}function _E(t,e,r,i){const n={},a=new WeakMap;function s(f){const d=f.target;d.index!==null&&e.remove(d.index);for(const _ in d.attributes)e.remove(d.attributes[_]);for(const _ in d.morphAttributes){const x=d.morphAttributes[_];for(let m=0,c=x.length;m<c;m++)e.remove(x[m])}d.removeEventListener("dispose",s),delete n[d.id];const p=a.get(d);p&&(e.remove(p),a.delete(d)),i.releaseStatesOfGeometry(d),d.isInstancedBufferGeometry===!0&&delete d._maxInstanceCount,r.memory.geometries--}function o(f,d){return n[d.id]===!0||(d.addEventListener("dispose",s),n[d.id]=!0,r.memory.geometries++),d}function l(f){const d=f.attributes;for(const _ in d)e.update(d[_],t.ARRAY_BUFFER);const p=f.morphAttributes;for(const _ in p){const x=p[_];for(let m=0,c=x.length;m<c;m++)e.update(x[m],t.ARRAY_BUFFER)}}function u(f){const d=[],p=f.index,_=f.attributes.position;let x=0;if(p!==null){const g=p.array;x=p.version;for(let v=0,M=g.length;v<M;v+=3){const P=g[v+0],T=g[v+1],w=g[v+2];d.push(P,T,T,w,w,P)}}else if(_!==void 0){const g=_.array;x=_.version;for(let v=0,M=g.length/3-1;v<M;v+=3){const P=v+0,T=v+1,w=v+2;d.push(P,T,T,w,w,P)}}else return;const m=new(e_(d)?s_:a_)(d,1);m.version=x;const c=a.get(f);c&&e.remove(c),a.set(f,m)}function h(f){const d=a.get(f);if(d){const p=f.index;p!==null&&d.version<p.version&&u(f)}else u(f);return a.get(f)}return{get:o,update:l,getWireframeAttribute:h}}function xE(t,e,r){let i;function n(d){i=d}let a,s;function o(d){a=d.type,s=d.bytesPerElement}function l(d,p){t.drawElements(i,p,a,d*s),r.update(p,i,1)}function u(d,p,_){_!==0&&(t.drawElementsInstanced(i,p,a,d*s,_),r.update(p,i,_))}function h(d,p,_){if(_===0)return;const x=e.get("WEBGL_multi_draw");if(x===null)for(let m=0;m<_;m++)this.render(d[m]/s,p[m]);else{x.multiDrawElementsWEBGL(i,p,0,a,d,0,_);let m=0;for(let c=0;c<_;c++)m+=p[c];r.update(m,i,1)}}function f(d,p,_,x){if(_===0)return;const m=e.get("WEBGL_multi_draw");if(m===null)for(let c=0;c<d.length;c++)u(d[c]/s,p[c],x[c]);else{m.multiDrawElementsInstancedWEBGL(i,p,0,a,d,0,x,0,_);let c=0;for(let g=0;g<_;g++)c+=p[g];for(let g=0;g<x.length;g++)r.update(c,i,x[g])}}this.setMode=n,this.setIndex=o,this.render=l,this.renderInstances=u,this.renderMultiDraw=h,this.renderMultiDrawInstances=f}function yE(t){const e={geometries:0,textures:0},r={frame:0,calls:0,triangles:0,points:0,lines:0};function i(a,s,o){switch(r.calls++,s){case t.TRIANGLES:r.triangles+=o*(a/3);break;case t.LINES:r.lines+=o*(a/2);break;case t.LINE_STRIP:r.lines+=o*(a-1);break;case t.LINE_LOOP:r.lines+=o*a;break;case t.POINTS:r.points+=o*a;break;default:console.error("THREE.WebGLInfo: Unknown draw mode:",s);break}}function n(){r.calls=0,r.triangles=0,r.points=0,r.lines=0}return{memory:e,render:r,programs:null,autoReset:!0,reset:n,update:i}}function ME(t,e,r){const i=new WeakMap,n=new Mt;function a(s,o,l){const u=s.morphTargetInfluences,h=o.morphAttributes.position||o.morphAttributes.normal||o.morphAttributes.color,f=h!==void 0?h.length:0;let d=i.get(o);if(d===void 0||d.count!==f){let p=function(){L.dispose(),i.delete(o),o.removeEventListener("dispose",p)};d!==void 0&&d.texture.dispose();const _=o.morphAttributes.position!==void 0,x=o.morphAttributes.normal!==void 0,m=o.morphAttributes.color!==void 0,c=o.morphAttributes.position||[],g=o.morphAttributes.normal||[],v=o.morphAttributes.color||[];let M=0;_===!0&&(M=1),x===!0&&(M=2),m===!0&&(M=3);let P=o.attributes.position.count*M,T=1;P>e.maxTextureSize&&(T=Math.ceil(P/e.maxTextureSize),P=e.maxTextureSize);const w=new Float32Array(P*T*4*f),L=new i_(w,P,T,f);L.type=Mi,L.needsUpdate=!0;const b=M*4;for(let y=0;y<f;y++){const U=c[y],B=g[y],V=v[y],q=P*T*4*y;for(let J=0;J<U.count;J++){const K=J*b;_===!0&&(n.fromBufferAttribute(U,J),w[q+K+0]=n.x,w[q+K+1]=n.y,w[q+K+2]=n.z,w[q+K+3]=0),x===!0&&(n.fromBufferAttribute(B,J),w[q+K+4]=n.x,w[q+K+5]=n.y,w[q+K+6]=n.z,w[q+K+7]=0),m===!0&&(n.fromBufferAttribute(V,J),w[q+K+8]=n.x,w[q+K+9]=n.y,w[q+K+10]=n.z,w[q+K+11]=V.itemSize===4?n.w:1)}}d={count:f,texture:L,size:new Ne(P,T)},i.set(o,d),o.addEventListener("dispose",p)}if(s.isInstancedMesh===!0&&s.morphTexture!==null)l.getUniforms().setValue(t,"morphTexture",s.morphTexture,r);else{let p=0;for(let x=0;x<u.length;x++)p+=u[x];const _=o.morphTargetsRelative?1:1-p;l.getUniforms().setValue(t,"morphTargetBaseInfluence",_),l.getUniforms().setValue(t,"morphTargetInfluences",u)}l.getUniforms().setValue(t,"morphTargetsTexture",d.texture,r),l.getUniforms().setValue(t,"morphTargetsTextureSize",d.size)}return{update:a}}function SE(t,e,r,i){let n=new WeakMap;function a(l){const u=i.render.frame,h=l.geometry,f=e.get(l,h);if(n.get(f)!==u&&(e.update(f),n.set(f,u)),l.isInstancedMesh&&(l.hasEventListener("dispose",o)===!1&&l.addEventListener("dispose",o),n.get(l)!==u&&(r.update(l.instanceMatrix,t.ARRAY_BUFFER),l.instanceColor!==null&&r.update(l.instanceColor,t.ARRAY_BUFFER),n.set(l,u))),l.isSkinnedMesh){const d=l.skeleton;n.get(d)!==u&&(d.update(),n.set(d,u))}return f}function s(){n=new WeakMap}function o(l){const u=l.target;u.removeEventListener("dispose",o),r.remove(u.instanceMatrix),u.instanceColor!==null&&r.remove(u.instanceColor)}return{update:a,dispose:s}}class h_ extends sr{constructor(e,r,i,n,a,s,o,l,u,h=Ua){if(h!==Ua&&h!==Xa)throw new Error("DepthTexture format must be either THREE.DepthFormat or THREE.DepthStencilFormat");i===void 0&&h===Ua&&(i=Wa),i===void 0&&h===Xa&&(i=ja),super(null,n,a,s,o,l,h,i,u),this.isDepthTexture=!0,this.image={width:e,height:r},this.magFilter=o!==void 0?o:fr,this.minFilter=l!==void 0?l:fr,this.flipY=!1,this.generateMipmaps=!1,this.compareFunction=null}copy(e){return super.copy(e),this.compareFunction=e.compareFunction,this}toJSON(e){const r=super.toJSON(e);return this.compareFunction!==null&&(r.compareFunction=this.compareFunction),r}}const f_=new sr,p_=new h_(1,1);p_.compareFunction=Jv;const m_=new i_,g_=new lM,v_=new u_,qp=[],Kp=[],Zp=new Float32Array(16),$p=new Float32Array(9),Qp=new Float32Array(4);function Ja(t,e,r){const i=t[0];if(i<=0||i>0)return t;const n=e*r;let a=qp[n];if(a===void 0&&(a=new Float32Array(n),qp[n]=a),e!==0){i.toArray(a,0);for(let s=1,o=0;s!==e;++s)o+=r,t[s].toArray(a,o)}return a}function kt(t,e){if(t.length!==e.length)return!1;for(let r=0,i=t.length;r<i;r++)if(t[r]!==e[r])return!1;return!0}function Ft(t,e){for(let r=0,i=e.length;r<i;r++)t[r]=e[r]}function gu(t,e){let r=Kp[e];r===void 0&&(r=new Int32Array(e),Kp[e]=r);for(let i=0;i!==e;++i)r[i]=t.allocateTextureUnit();return r}function bE(t,e){const r=this.cache;r[0]!==e&&(t.uniform1f(this.addr,e),r[0]=e)}function EE(t,e){const r=this.cache;if(e.x!==void 0)(r[0]!==e.x||r[1]!==e.y)&&(t.uniform2f(this.addr,e.x,e.y),r[0]=e.x,r[1]=e.y);else{if(kt(r,e))return;t.uniform2fv(this.addr,e),Ft(r,e)}}function wE(t,e){const r=this.cache;if(e.x!==void 0)(r[0]!==e.x||r[1]!==e.y||r[2]!==e.z)&&(t.uniform3f(this.addr,e.x,e.y,e.z),r[0]=e.x,r[1]=e.y,r[2]=e.z);else if(e.r!==void 0)(r[0]!==e.r||r[1]!==e.g||r[2]!==e.b)&&(t.uniform3f(this.addr,e.r,e.g,e.b),r[0]=e.r,r[1]=e.g,r[2]=e.b);else{if(kt(r,e))return;t.uniform3fv(this.addr,e),Ft(r,e)}}function TE(t,e){const r=this.cache;if(e.x!==void 0)(r[0]!==e.x||r[1]!==e.y||r[2]!==e.z||r[3]!==e.w)&&(t.uniform4f(this.addr,e.x,e.y,e.z,e.w),r[0]=e.x,r[1]=e.y,r[2]=e.z,r[3]=e.w);else{if(kt(r,e))return;t.uniform4fv(this.addr,e),Ft(r,e)}}function AE(t,e){const r=this.cache,i=e.elements;if(i===void 0){if(kt(r,e))return;t.uniformMatrix2fv(this.addr,!1,e),Ft(r,e)}else{if(kt(r,i))return;Qp.set(i),t.uniformMatrix2fv(this.addr,!1,Qp),Ft(r,i)}}function CE(t,e){const r=this.cache,i=e.elements;if(i===void 0){if(kt(r,e))return;t.uniformMatrix3fv(this.addr,!1,e),Ft(r,e)}else{if(kt(r,i))return;$p.set(i),t.uniformMatrix3fv(this.addr,!1,$p),Ft(r,i)}}function RE(t,e){const r=this.cache,i=e.elements;if(i===void 0){if(kt(r,e))return;t.uniformMatrix4fv(this.addr,!1,e),Ft(r,e)}else{if(kt(r,i))return;Zp.set(i),t.uniformMatrix4fv(this.addr,!1,Zp),Ft(r,i)}}function PE(t,e){const r=this.cache;r[0]!==e&&(t.uniform1i(this.addr,e),r[0]=e)}function LE(t,e){const r=this.cache;if(e.x!==void 0)(r[0]!==e.x||r[1]!==e.y)&&(t.uniform2i(this.addr,e.x,e.y),r[0]=e.x,r[1]=e.y);else{if(kt(r,e))return;t.uniform2iv(this.addr,e),Ft(r,e)}}function UE(t,e){const r=this.cache;if(e.x!==void 0)(r[0]!==e.x||r[1]!==e.y||r[2]!==e.z)&&(t.uniform3i(this.addr,e.x,e.y,e.z),r[0]=e.x,r[1]=e.y,r[2]=e.z);else{if(kt(r,e))return;t.uniform3iv(this.addr,e),Ft(r,e)}}function DE(t,e){const r=this.cache;if(e.x!==void 0)(r[0]!==e.x||r[1]!==e.y||r[2]!==e.z||r[3]!==e.w)&&(t.uniform4i(this.addr,e.x,e.y,e.z,e.w),r[0]=e.x,r[1]=e.y,r[2]=e.z,r[3]=e.w);else{if(kt(r,e))return;t.uniform4iv(this.addr,e),Ft(r,e)}}function IE(t,e){const r=this.cache;r[0]!==e&&(t.uniform1ui(this.addr,e),r[0]=e)}function NE(t,e){const r=this.cache;if(e.x!==void 0)(r[0]!==e.x||r[1]!==e.y)&&(t.uniform2ui(this.addr,e.x,e.y),r[0]=e.x,r[1]=e.y);else{if(kt(r,e))return;t.uniform2uiv(this.addr,e),Ft(r,e)}}function OE(t,e){const r=this.cache;if(e.x!==void 0)(r[0]!==e.x||r[1]!==e.y||r[2]!==e.z)&&(t.uniform3ui(this.addr,e.x,e.y,e.z),r[0]=e.x,r[1]=e.y,r[2]=e.z);else{if(kt(r,e))return;t.uniform3uiv(this.addr,e),Ft(r,e)}}function kE(t,e){const r=this.cache;if(e.x!==void 0)(r[0]!==e.x||r[1]!==e.y||r[2]!==e.z||r[3]!==e.w)&&(t.uniform4ui(this.addr,e.x,e.y,e.z,e.w),r[0]=e.x,r[1]=e.y,r[2]=e.z,r[3]=e.w);else{if(kt(r,e))return;t.uniform4uiv(this.addr,e),Ft(r,e)}}function FE(t,e,r){const i=this.cache,n=r.allocateTextureUnit();i[0]!==n&&(t.uniform1i(this.addr,n),i[0]=n);const a=this.type===t.SAMPLER_2D_SHADOW?p_:f_;r.setTexture2D(e||a,n)}function zE(t,e,r){const i=this.cache,n=r.allocateTextureUnit();i[0]!==n&&(t.uniform1i(this.addr,n),i[0]=n),r.setTexture3D(e||g_,n)}function BE(t,e,r){const i=this.cache,n=r.allocateTextureUnit();i[0]!==n&&(t.uniform1i(this.addr,n),i[0]=n),r.setTextureCube(e||v_,n)}function VE(t,e,r){const i=this.cache,n=r.allocateTextureUnit();i[0]!==n&&(t.uniform1i(this.addr,n),i[0]=n),r.setTexture2DArray(e||m_,n)}function HE(t){switch(t){case 5126:return bE;case 35664:return EE;case 35665:return wE;case 35666:return TE;case 35674:return AE;case 35675:return CE;case 35676:return RE;case 5124:case 35670:return PE;case 35667:case 35671:return LE;case 35668:case 35672:return UE;case 35669:case 35673:return DE;case 5125:return IE;case 36294:return NE;case 36295:return OE;case 36296:return kE;case 35678:case 36198:case 36298:case 36306:case 35682:return FE;case 35679:case 36299:case 36307:return zE;case 35680:case 36300:case 36308:case 36293:return BE;case 36289:case 36303:case 36311:case 36292:return VE}}function GE(t,e){t.uniform1fv(this.addr,e)}function WE(t,e){const r=Ja(e,this.size,2);t.uniform2fv(this.addr,r)}function jE(t,e){const r=Ja(e,this.size,3);t.uniform3fv(this.addr,r)}function XE(t,e){const r=Ja(e,this.size,4);t.uniform4fv(this.addr,r)}function YE(t,e){const r=Ja(e,this.size,4);t.uniformMatrix2fv(this.addr,!1,r)}function qE(t,e){const r=Ja(e,this.size,9);t.uniformMatrix3fv(this.addr,!1,r)}function KE(t,e){const r=Ja(e,this.size,16);t.uniformMatrix4fv(this.addr,!1,r)}function ZE(t,e){t.uniform1iv(this.addr,e)}function $E(t,e){t.uniform2iv(this.addr,e)}function QE(t,e){t.uniform3iv(this.addr,e)}function JE(t,e){t.uniform4iv(this.addr,e)}function e1(t,e){t.uniform1uiv(this.addr,e)}function t1(t,e){t.uniform2uiv(this.addr,e)}function r1(t,e){t.uniform3uiv(this.addr,e)}function i1(t,e){t.uniform4uiv(this.addr,e)}function n1(t,e,r){const i=this.cache,n=e.length,a=gu(r,n);kt(i,a)||(t.uniform1iv(this.addr,a),Ft(i,a));for(let s=0;s!==n;++s)r.setTexture2D(e[s]||f_,a[s])}function a1(t,e,r){const i=this.cache,n=e.length,a=gu(r,n);kt(i,a)||(t.uniform1iv(this.addr,a),Ft(i,a));for(let s=0;s!==n;++s)r.setTexture3D(e[s]||g_,a[s])}function s1(t,e,r){const i=this.cache,n=e.length,a=gu(r,n);kt(i,a)||(t.uniform1iv(this.addr,a),Ft(i,a));for(let s=0;s!==n;++s)r.setTextureCube(e[s]||v_,a[s])}function o1(t,e,r){const i=this.cache,n=e.length,a=gu(r,n);kt(i,a)||(t.uniform1iv(this.addr,a),Ft(i,a));for(let s=0;s!==n;++s)r.setTexture2DArray(e[s]||m_,a[s])}function l1(t){switch(t){case 5126:return GE;case 35664:return WE;case 35665:return jE;case 35666:return XE;case 35674:return YE;case 35675:return qE;case 35676:return KE;case 5124:case 35670:return ZE;case 35667:case 35671:return $E;case 35668:case 35672:return QE;case 35669:case 35673:return JE;case 5125:return e1;case 36294:return t1;case 36295:return r1;case 36296:return i1;case 35678:case 36198:case 36298:case 36306:case 35682:return n1;case 35679:case 36299:case 36307:return a1;case 35680:case 36300:case 36308:case 36293:return s1;case 36289:case 36303:case 36311:case 36292:return o1}}class u1{constructor(e,r,i){this.id=e,this.addr=i,this.cache=[],this.type=r.type,this.setValue=HE(r.type)}}class c1{constructor(e,r,i){this.id=e,this.addr=i,this.cache=[],this.type=r.type,this.size=r.size,this.setValue=l1(r.type)}}class d1{constructor(e){this.id=e,this.seq=[],this.map={}}setValue(e,r,i){const n=this.seq;for(let a=0,s=n.length;a!==s;++a){const o=n[a];o.setValue(e,r[o.id],i)}}}const Ec=/(\w+)(\])?(\[|\.)?/g;function Jp(t,e){t.seq.push(e),t.map[e.id]=e}function h1(t,e,r){const i=t.name,n=i.length;for(Ec.lastIndex=0;;){const a=Ec.exec(i),s=Ec.lastIndex;let o=a[1];const l=a[2]==="]",u=a[3];if(l&&(o=o|0),u===void 0||u==="["&&s+2===n){Jp(r,u===void 0?new u1(o,t,e):new c1(o,t,e));break}else{let h=r.map[o];h===void 0&&(h=new d1(o),Jp(r,h)),r=h}}}class pl{constructor(e,r){this.seq=[],this.map={};const i=e.getProgramParameter(r,e.ACTIVE_UNIFORMS);for(let n=0;n<i;++n){const a=e.getActiveUniform(r,n),s=e.getUniformLocation(r,a.name);h1(a,s,this)}}setValue(e,r,i,n){const a=this.map[r];a!==void 0&&a.setValue(e,i,n)}setOptional(e,r,i){const n=r[i];n!==void 0&&this.setValue(e,i,n)}static upload(e,r,i,n){for(let a=0,s=r.length;a!==s;++a){const o=r[a],l=i[o.id];l.needsUpdate!==!1&&o.setValue(e,l.value,n)}}static seqWithValue(e,r){const i=[];for(let n=0,a=e.length;n!==a;++n){const s=e[n];s.id in r&&i.push(s)}return i}}function em(t,e,r){const i=t.createShader(e);return t.shaderSource(i,r),t.compileShader(i),i}const f1=37297;let p1=0;function m1(t,e){const r=t.split(`
`),i=[],n=Math.max(e-6,0),a=Math.min(e+6,r.length);for(let s=n;s<a;s++){const o=s+1;i.push(`${o===e?">":" "} ${o}: ${r[s]}`)}return i.join(`
`)}function g1(t){const e=ut.getPrimaries(ut.workingColorSpace),r=ut.getPrimaries(t);let i;switch(e===r?i="":e===Gl&&r===Hl?i="LinearDisplayP3ToLinearSRGB":e===Hl&&r===Gl&&(i="LinearSRGBToLinearDisplayP3"),t){case fn:case pu:return[i,"LinearTransferOETF"];case ei:case Ah:return[i,"sRGBTransferOETF"];default:return console.warn("THREE.WebGLProgram: Unsupported color space:",t),[i,"LinearTransferOETF"]}}function tm(t,e,r){const i=t.getShaderParameter(e,t.COMPILE_STATUS),n=t.getShaderInfoLog(e).trim();if(i&&n==="")return"";const a=/ERROR: 0:(\d+)/.exec(n);if(a){const s=parseInt(a[1]);return r.toUpperCase()+`

`+n+`

`+m1(t.getShaderSource(e),s)}else return n}function v1(t,e){const r=g1(e);return`vec4 ${t}( vec4 value ) { return ${r[0]}( ${r[1]}( value ) ); }`}function _1(t,e){let r;switch(e){case Ay:r="Linear";break;case Cy:r="Reinhard";break;case Ry:r="OptimizedCineon";break;case Gv:r="ACESFilmic";break;case Ly:r="AgX";break;case Uy:r="Neutral";break;case Py:r="Custom";break;default:console.warn("THREE.WebGLProgram: Unsupported toneMapping:",e),r="Linear"}return"vec3 "+t+"( vec3 color ) { return "+r+"ToneMapping( color ); }"}function x1(t){return[t.extensionClipCullDistance?"#extension GL_ANGLE_clip_cull_distance : require":"",t.extensionMultiDraw?"#extension GL_ANGLE_multi_draw : require":""].filter(Es).join(`
`)}function y1(t){const e=[];for(const r in t){const i=t[r];i!==!1&&e.push("#define "+r+" "+i)}return e.join(`
`)}function M1(t,e){const r={},i=t.getProgramParameter(e,t.ACTIVE_ATTRIBUTES);for(let n=0;n<i;n++){const a=t.getActiveAttrib(e,n),s=a.name;let o=1;a.type===t.FLOAT_MAT2&&(o=2),a.type===t.FLOAT_MAT3&&(o=3),a.type===t.FLOAT_MAT4&&(o=4),r[s]={type:a.type,location:t.getAttribLocation(e,s),locationSize:o}}return r}function Es(t){return t!==""}function rm(t,e){const r=e.numSpotLightShadows+e.numSpotLightMaps-e.numSpotLightShadowsWithMaps;return t.replace(/NUM_DIR_LIGHTS/g,e.numDirLights).replace(/NUM_SPOT_LIGHTS/g,e.numSpotLights).replace(/NUM_SPOT_LIGHT_MAPS/g,e.numSpotLightMaps).replace(/NUM_SPOT_LIGHT_COORDS/g,r).replace(/NUM_RECT_AREA_LIGHTS/g,e.numRectAreaLights).replace(/NUM_POINT_LIGHTS/g,e.numPointLights).replace(/NUM_HEMI_LIGHTS/g,e.numHemiLights).replace(/NUM_DIR_LIGHT_SHADOWS/g,e.numDirLightShadows).replace(/NUM_SPOT_LIGHT_SHADOWS_WITH_MAPS/g,e.numSpotLightShadowsWithMaps).replace(/NUM_SPOT_LIGHT_SHADOWS/g,e.numSpotLightShadows).replace(/NUM_POINT_LIGHT_SHADOWS/g,e.numPointLightShadows)}function im(t,e){return t.replace(/NUM_CLIPPING_PLANES/g,e.numClippingPlanes).replace(/UNION_CLIPPING_PLANES/g,e.numClippingPlanes-e.numClipIntersection)}const S1=/^[ \t]*#include +<([\w\d./]+)>/gm;function Pd(t){return t.replace(S1,E1)}const b1=new Map;function E1(t,e){let r=qe[e];if(r===void 0){const i=b1.get(e);if(i!==void 0)r=qe[i],console.warn('THREE.WebGLRenderer: Shader chunk "%s" has been deprecated. Use "%s" instead.',e,i);else throw new Error("Can not resolve #include <"+e+">")}return Pd(r)}const w1=/#pragma unroll_loop_start\s+for\s*\(\s*int\s+i\s*=\s*(\d+)\s*;\s*i\s*<\s*(\d+)\s*;\s*i\s*\+\+\s*\)\s*{([\s\S]+?)}\s+#pragma unroll_loop_end/g;function nm(t){return t.replace(w1,T1)}function T1(t,e,r,i){let n="";for(let a=parseInt(e);a<parseInt(r);a++)n+=i.replace(/\[\s*i\s*\]/g,"[ "+a+" ]").replace(/UNROLLED_LOOP_INDEX/g,a);return n}function am(t){let e=`precision ${t.precision} float;
	precision ${t.precision} int;
	precision ${t.precision} sampler2D;
	precision ${t.precision} samplerCube;
	precision ${t.precision} sampler3D;
	precision ${t.precision} sampler2DArray;
	precision ${t.precision} sampler2DShadow;
	precision ${t.precision} samplerCubeShadow;
	precision ${t.precision} sampler2DArrayShadow;
	precision ${t.precision} isampler2D;
	precision ${t.precision} isampler3D;
	precision ${t.precision} isamplerCube;
	precision ${t.precision} isampler2DArray;
	precision ${t.precision} usampler2D;
	precision ${t.precision} usampler3D;
	precision ${t.precision} usamplerCube;
	precision ${t.precision} usampler2DArray;
	`;return t.precision==="highp"?e+=`
#define HIGH_PRECISION`:t.precision==="mediump"?e+=`
#define MEDIUM_PRECISION`:t.precision==="lowp"&&(e+=`
#define LOW_PRECISION`),e}function A1(t){let e="SHADOWMAP_TYPE_BASIC";return t.shadowMapType===Bv?e="SHADOWMAP_TYPE_PCF":t.shadowMapType===Vv?e="SHADOWMAP_TYPE_PCF_SOFT":t.shadowMapType===pi&&(e="SHADOWMAP_TYPE_VSM"),e}function C1(t){let e="ENVMAP_TYPE_CUBE";if(t.envMap)switch(t.envMapMode){case Ha:case Ga:e="ENVMAP_TYPE_CUBE";break;case hu:e="ENVMAP_TYPE_CUBE_UV";break}return e}function R1(t){let e="ENVMAP_MODE_REFLECTION";if(t.envMap)switch(t.envMapMode){case Ga:e="ENVMAP_MODE_REFRACTION";break}return e}function P1(t){let e="ENVMAP_BLENDING_NONE";if(t.envMap)switch(t.combine){case Hv:e="ENVMAP_BLENDING_MULTIPLY";break;case wy:e="ENVMAP_BLENDING_MIX";break;case Ty:e="ENVMAP_BLENDING_ADD";break}return e}function L1(t){const e=t.envMapCubeUVHeight;if(e===null)return null;const r=Math.log2(e)-2,i=1/e;return{texelWidth:1/(3*Math.max(Math.pow(2,r),7*16)),texelHeight:i,maxMip:r}}function U1(t,e,r,i){const n=t.getContext(),a=r.defines;let s=r.vertexShader,o=r.fragmentShader;const l=A1(r),u=C1(r),h=R1(r),f=P1(r),d=L1(r),p=x1(r),_=y1(a),x=n.createProgram();let m,c,g=r.glslVersion?"#version "+r.glslVersion+`
`:"";r.isRawShaderMaterial?(m=["#define SHADER_TYPE "+r.shaderType,"#define SHADER_NAME "+r.shaderName,_].filter(Es).join(`
`),m.length>0&&(m+=`
`),c=["#define SHADER_TYPE "+r.shaderType,"#define SHADER_NAME "+r.shaderName,_].filter(Es).join(`
`),c.length>0&&(c+=`
`)):(m=[am(r),"#define SHADER_TYPE "+r.shaderType,"#define SHADER_NAME "+r.shaderName,_,r.extensionClipCullDistance?"#define USE_CLIP_DISTANCE":"",r.batching?"#define USE_BATCHING":"",r.batchingColor?"#define USE_BATCHING_COLOR":"",r.instancing?"#define USE_INSTANCING":"",r.instancingColor?"#define USE_INSTANCING_COLOR":"",r.instancingMorph?"#define USE_INSTANCING_MORPH":"",r.useFog&&r.fog?"#define USE_FOG":"",r.useFog&&r.fogExp2?"#define FOG_EXP2":"",r.map?"#define USE_MAP":"",r.envMap?"#define USE_ENVMAP":"",r.envMap?"#define "+h:"",r.lightMap?"#define USE_LIGHTMAP":"",r.aoMap?"#define USE_AOMAP":"",r.bumpMap?"#define USE_BUMPMAP":"",r.normalMap?"#define USE_NORMALMAP":"",r.normalMapObjectSpace?"#define USE_NORMALMAP_OBJECTSPACE":"",r.normalMapTangentSpace?"#define USE_NORMALMAP_TANGENTSPACE":"",r.displacementMap?"#define USE_DISPLACEMENTMAP":"",r.emissiveMap?"#define USE_EMISSIVEMAP":"",r.anisotropy?"#define USE_ANISOTROPY":"",r.anisotropyMap?"#define USE_ANISOTROPYMAP":"",r.clearcoatMap?"#define USE_CLEARCOATMAP":"",r.clearcoatRoughnessMap?"#define USE_CLEARCOAT_ROUGHNESSMAP":"",r.clearcoatNormalMap?"#define USE_CLEARCOAT_NORMALMAP":"",r.iridescenceMap?"#define USE_IRIDESCENCEMAP":"",r.iridescenceThicknessMap?"#define USE_IRIDESCENCE_THICKNESSMAP":"",r.specularMap?"#define USE_SPECULARMAP":"",r.specularColorMap?"#define USE_SPECULAR_COLORMAP":"",r.specularIntensityMap?"#define USE_SPECULAR_INTENSITYMAP":"",r.roughnessMap?"#define USE_ROUGHNESSMAP":"",r.metalnessMap?"#define USE_METALNESSMAP":"",r.alphaMap?"#define USE_ALPHAMAP":"",r.alphaHash?"#define USE_ALPHAHASH":"",r.transmission?"#define USE_TRANSMISSION":"",r.transmissionMap?"#define USE_TRANSMISSIONMAP":"",r.thicknessMap?"#define USE_THICKNESSMAP":"",r.sheenColorMap?"#define USE_SHEEN_COLORMAP":"",r.sheenRoughnessMap?"#define USE_SHEEN_ROUGHNESSMAP":"",r.mapUv?"#define MAP_UV "+r.mapUv:"",r.alphaMapUv?"#define ALPHAMAP_UV "+r.alphaMapUv:"",r.lightMapUv?"#define LIGHTMAP_UV "+r.lightMapUv:"",r.aoMapUv?"#define AOMAP_UV "+r.aoMapUv:"",r.emissiveMapUv?"#define EMISSIVEMAP_UV "+r.emissiveMapUv:"",r.bumpMapUv?"#define BUMPMAP_UV "+r.bumpMapUv:"",r.normalMapUv?"#define NORMALMAP_UV "+r.normalMapUv:"",r.displacementMapUv?"#define DISPLACEMENTMAP_UV "+r.displacementMapUv:"",r.metalnessMapUv?"#define METALNESSMAP_UV "+r.metalnessMapUv:"",r.roughnessMapUv?"#define ROUGHNESSMAP_UV "+r.roughnessMapUv:"",r.anisotropyMapUv?"#define ANISOTROPYMAP_UV "+r.anisotropyMapUv:"",r.clearcoatMapUv?"#define CLEARCOATMAP_UV "+r.clearcoatMapUv:"",r.clearcoatNormalMapUv?"#define CLEARCOAT_NORMALMAP_UV "+r.clearcoatNormalMapUv:"",r.clearcoatRoughnessMapUv?"#define CLEARCOAT_ROUGHNESSMAP_UV "+r.clearcoatRoughnessMapUv:"",r.iridescenceMapUv?"#define IRIDESCENCEMAP_UV "+r.iridescenceMapUv:"",r.iridescenceThicknessMapUv?"#define IRIDESCENCE_THICKNESSMAP_UV "+r.iridescenceThicknessMapUv:"",r.sheenColorMapUv?"#define SHEEN_COLORMAP_UV "+r.sheenColorMapUv:"",r.sheenRoughnessMapUv?"#define SHEEN_ROUGHNESSMAP_UV "+r.sheenRoughnessMapUv:"",r.specularMapUv?"#define SPECULARMAP_UV "+r.specularMapUv:"",r.specularColorMapUv?"#define SPECULAR_COLORMAP_UV "+r.specularColorMapUv:"",r.specularIntensityMapUv?"#define SPECULAR_INTENSITYMAP_UV "+r.specularIntensityMapUv:"",r.transmissionMapUv?"#define TRANSMISSIONMAP_UV "+r.transmissionMapUv:"",r.thicknessMapUv?"#define THICKNESSMAP_UV "+r.thicknessMapUv:"",r.vertexTangents&&r.flatShading===!1?"#define USE_TANGENT":"",r.vertexColors?"#define USE_COLOR":"",r.vertexAlphas?"#define USE_COLOR_ALPHA":"",r.vertexUv1s?"#define USE_UV1":"",r.vertexUv2s?"#define USE_UV2":"",r.vertexUv3s?"#define USE_UV3":"",r.pointsUvs?"#define USE_POINTS_UV":"",r.flatShading?"#define FLAT_SHADED":"",r.skinning?"#define USE_SKINNING":"",r.morphTargets?"#define USE_MORPHTARGETS":"",r.morphNormals&&r.flatShading===!1?"#define USE_MORPHNORMALS":"",r.morphColors?"#define USE_MORPHCOLORS":"",r.morphTargetsCount>0?"#define MORPHTARGETS_TEXTURE_STRIDE "+r.morphTextureStride:"",r.morphTargetsCount>0?"#define MORPHTARGETS_COUNT "+r.morphTargetsCount:"",r.doubleSided?"#define DOUBLE_SIDED":"",r.flipSided?"#define FLIP_SIDED":"",r.shadowMapEnabled?"#define USE_SHADOWMAP":"",r.shadowMapEnabled?"#define "+l:"",r.sizeAttenuation?"#define USE_SIZEATTENUATION":"",r.numLightProbes>0?"#define USE_LIGHT_PROBES":"",r.logarithmicDepthBuffer?"#define USE_LOGDEPTHBUF":"","uniform mat4 modelMatrix;","uniform mat4 modelViewMatrix;","uniform mat4 projectionMatrix;","uniform mat4 viewMatrix;","uniform mat3 normalMatrix;","uniform vec3 cameraPosition;","uniform bool isOrthographic;","#ifdef USE_INSTANCING","	attribute mat4 instanceMatrix;","#endif","#ifdef USE_INSTANCING_COLOR","	attribute vec3 instanceColor;","#endif","#ifdef USE_INSTANCING_MORPH","	uniform sampler2D morphTexture;","#endif","attribute vec3 position;","attribute vec3 normal;","attribute vec2 uv;","#ifdef USE_UV1","	attribute vec2 uv1;","#endif","#ifdef USE_UV2","	attribute vec2 uv2;","#endif","#ifdef USE_UV3","	attribute vec2 uv3;","#endif","#ifdef USE_TANGENT","	attribute vec4 tangent;","#endif","#if defined( USE_COLOR_ALPHA )","	attribute vec4 color;","#elif defined( USE_COLOR )","	attribute vec3 color;","#endif","#ifdef USE_SKINNING","	attribute vec4 skinIndex;","	attribute vec4 skinWeight;","#endif",`
`].filter(Es).join(`
`),c=[am(r),"#define SHADER_TYPE "+r.shaderType,"#define SHADER_NAME "+r.shaderName,_,r.useFog&&r.fog?"#define USE_FOG":"",r.useFog&&r.fogExp2?"#define FOG_EXP2":"",r.alphaToCoverage?"#define ALPHA_TO_COVERAGE":"",r.map?"#define USE_MAP":"",r.matcap?"#define USE_MATCAP":"",r.envMap?"#define USE_ENVMAP":"",r.envMap?"#define "+u:"",r.envMap?"#define "+h:"",r.envMap?"#define "+f:"",d?"#define CUBEUV_TEXEL_WIDTH "+d.texelWidth:"",d?"#define CUBEUV_TEXEL_HEIGHT "+d.texelHeight:"",d?"#define CUBEUV_MAX_MIP "+d.maxMip+".0":"",r.lightMap?"#define USE_LIGHTMAP":"",r.aoMap?"#define USE_AOMAP":"",r.bumpMap?"#define USE_BUMPMAP":"",r.normalMap?"#define USE_NORMALMAP":"",r.normalMapObjectSpace?"#define USE_NORMALMAP_OBJECTSPACE":"",r.normalMapTangentSpace?"#define USE_NORMALMAP_TANGENTSPACE":"",r.emissiveMap?"#define USE_EMISSIVEMAP":"",r.anisotropy?"#define USE_ANISOTROPY":"",r.anisotropyMap?"#define USE_ANISOTROPYMAP":"",r.clearcoat?"#define USE_CLEARCOAT":"",r.clearcoatMap?"#define USE_CLEARCOATMAP":"",r.clearcoatRoughnessMap?"#define USE_CLEARCOAT_ROUGHNESSMAP":"",r.clearcoatNormalMap?"#define USE_CLEARCOAT_NORMALMAP":"",r.dispersion?"#define USE_DISPERSION":"",r.iridescence?"#define USE_IRIDESCENCE":"",r.iridescenceMap?"#define USE_IRIDESCENCEMAP":"",r.iridescenceThicknessMap?"#define USE_IRIDESCENCE_THICKNESSMAP":"",r.specularMap?"#define USE_SPECULARMAP":"",r.specularColorMap?"#define USE_SPECULAR_COLORMAP":"",r.specularIntensityMap?"#define USE_SPECULAR_INTENSITYMAP":"",r.roughnessMap?"#define USE_ROUGHNESSMAP":"",r.metalnessMap?"#define USE_METALNESSMAP":"",r.alphaMap?"#define USE_ALPHAMAP":"",r.alphaTest?"#define USE_ALPHATEST":"",r.alphaHash?"#define USE_ALPHAHASH":"",r.sheen?"#define USE_SHEEN":"",r.sheenColorMap?"#define USE_SHEEN_COLORMAP":"",r.sheenRoughnessMap?"#define USE_SHEEN_ROUGHNESSMAP":"",r.transmission?"#define USE_TRANSMISSION":"",r.transmissionMap?"#define USE_TRANSMISSIONMAP":"",r.thicknessMap?"#define USE_THICKNESSMAP":"",r.vertexTangents&&r.flatShading===!1?"#define USE_TANGENT":"",r.vertexColors||r.instancingColor||r.batchingColor?"#define USE_COLOR":"",r.vertexAlphas?"#define USE_COLOR_ALPHA":"",r.vertexUv1s?"#define USE_UV1":"",r.vertexUv2s?"#define USE_UV2":"",r.vertexUv3s?"#define USE_UV3":"",r.pointsUvs?"#define USE_POINTS_UV":"",r.gradientMap?"#define USE_GRADIENTMAP":"",r.flatShading?"#define FLAT_SHADED":"",r.doubleSided?"#define DOUBLE_SIDED":"",r.flipSided?"#define FLIP_SIDED":"",r.shadowMapEnabled?"#define USE_SHADOWMAP":"",r.shadowMapEnabled?"#define "+l:"",r.premultipliedAlpha?"#define PREMULTIPLIED_ALPHA":"",r.numLightProbes>0?"#define USE_LIGHT_PROBES":"",r.decodeVideoTexture?"#define DECODE_VIDEO_TEXTURE":"",r.logarithmicDepthBuffer?"#define USE_LOGDEPTHBUF":"","uniform mat4 viewMatrix;","uniform vec3 cameraPosition;","uniform bool isOrthographic;",r.toneMapping!==nn?"#define TONE_MAPPING":"",r.toneMapping!==nn?qe.tonemapping_pars_fragment:"",r.toneMapping!==nn?_1("toneMapping",r.toneMapping):"",r.dithering?"#define DITHERING":"",r.opaque?"#define OPAQUE":"",qe.colorspace_pars_fragment,v1("linearToOutputTexel",r.outputColorSpace),r.useDepthPacking?"#define DEPTH_PACKING "+r.depthPacking:"",`
`].filter(Es).join(`
`)),s=Pd(s),s=rm(s,r),s=im(s,r),o=Pd(o),o=rm(o,r),o=im(o,r),s=nm(s),o=nm(o),r.isRawShaderMaterial!==!0&&(g=`#version 300 es
`,m=[p,"#define attribute in","#define varying out","#define texture2D texture"].join(`
`)+`
`+m,c=["#define varying in",r.glslVersion===Mp?"":"layout(location = 0) out highp vec4 pc_fragColor;",r.glslVersion===Mp?"":"#define gl_FragColor pc_fragColor","#define gl_FragDepthEXT gl_FragDepth","#define texture2D texture","#define textureCube texture","#define texture2DProj textureProj","#define texture2DLodEXT textureLod","#define texture2DProjLodEXT textureProjLod","#define textureCubeLodEXT textureLod","#define texture2DGradEXT textureGrad","#define texture2DProjGradEXT textureProjGrad","#define textureCubeGradEXT textureGrad"].join(`
`)+`
`+c);const v=g+m+s,M=g+c+o,P=em(n,n.VERTEX_SHADER,v),T=em(n,n.FRAGMENT_SHADER,M);n.attachShader(x,P),n.attachShader(x,T),r.index0AttributeName!==void 0?n.bindAttribLocation(x,0,r.index0AttributeName):r.morphTargets===!0&&n.bindAttribLocation(x,0,"position"),n.linkProgram(x);function w(U){if(t.debug.checkShaderErrors){const B=n.getProgramInfoLog(x).trim(),V=n.getShaderInfoLog(P).trim(),q=n.getShaderInfoLog(T).trim();let J=!0,K=!0;if(n.getProgramParameter(x,n.LINK_STATUS)===!1)if(J=!1,typeof t.debug.onShaderError=="function")t.debug.onShaderError(n,x,P,T);else{const ne=tm(n,P,"vertex"),I=tm(n,T,"fragment");console.error("THREE.WebGLProgram: Shader Error "+n.getError()+" - VALIDATE_STATUS "+n.getProgramParameter(x,n.VALIDATE_STATUS)+`

Material Name: `+U.name+`
Material Type: `+U.type+`

Program Info Log: `+B+`
`+ne+`
`+I)}else B!==""?console.warn("THREE.WebGLProgram: Program Info Log:",B):(V===""||q==="")&&(K=!1);K&&(U.diagnostics={runnable:J,programLog:B,vertexShader:{log:V,prefix:m},fragmentShader:{log:q,prefix:c}})}n.deleteShader(P),n.deleteShader(T),L=new pl(n,x),b=M1(n,x)}let L;this.getUniforms=function(){return L===void 0&&w(this),L};let b;this.getAttributes=function(){return b===void 0&&w(this),b};let y=r.rendererExtensionParallelShaderCompile===!1;return this.isReady=function(){return y===!1&&(y=n.getProgramParameter(x,f1)),y},this.destroy=function(){i.releaseStatesOfProgram(this),n.deleteProgram(x),this.program=void 0},this.type=r.shaderType,this.name=r.shaderName,this.id=p1++,this.cacheKey=e,this.usedTimes=1,this.program=x,this.vertexShader=P,this.fragmentShader=T,this}let D1=0;class I1{constructor(){this.shaderCache=new Map,this.materialCache=new Map}update(e){const r=e.vertexShader,i=e.fragmentShader,n=this._getShaderStage(r),a=this._getShaderStage(i),s=this._getShaderCacheForMaterial(e);return s.has(n)===!1&&(s.add(n),n.usedTimes++),s.has(a)===!1&&(s.add(a),a.usedTimes++),this}remove(e){const r=this.materialCache.get(e);for(const i of r)i.usedTimes--,i.usedTimes===0&&this.shaderCache.delete(i.code);return this.materialCache.delete(e),this}getVertexShaderID(e){return this._getShaderStage(e.vertexShader).id}getFragmentShaderID(e){return this._getShaderStage(e.fragmentShader).id}dispose(){this.shaderCache.clear(),this.materialCache.clear()}_getShaderCacheForMaterial(e){const r=this.materialCache;let i=r.get(e);return i===void 0&&(i=new Set,r.set(e,i)),i}_getShaderStage(e){const r=this.shaderCache;let i=r.get(e);return i===void 0&&(i=new N1(e),r.set(e,i)),i}}class N1{constructor(e){this.id=D1++,this.code=e,this.usedTimes=0}}function O1(t,e,r,i,n,a,s){const o=new Ch,l=new I1,u=new Set,h=[],f=n.logarithmicDepthBuffer,d=n.vertexTextures;let p=n.precision;const _={MeshDepthMaterial:"depth",MeshDistanceMaterial:"distanceRGBA",MeshNormalMaterial:"normal",MeshBasicMaterial:"basic",MeshLambertMaterial:"lambert",MeshPhongMaterial:"phong",MeshToonMaterial:"toon",MeshStandardMaterial:"physical",MeshPhysicalMaterial:"physical",MeshMatcapMaterial:"matcap",LineBasicMaterial:"basic",LineDashedMaterial:"dashed",PointsMaterial:"points",ShadowMaterial:"shadow",SpriteMaterial:"sprite"};function x(b){return u.add(b),b===0?"uv":`uv${b}`}function m(b,y,U,B,V){const q=B.fog,J=V.geometry,K=b.isMeshStandardMaterial?B.environment:null,ne=(b.isMeshStandardMaterial?r:e).get(b.envMap||K),I=ne&&ne.mapping===hu?ne.image.height:null,Z=_[b.type];b.precision!==null&&(p=n.getMaxPrecision(b.precision),p!==b.precision&&console.warn("THREE.WebGLProgram.getParameters:",b.precision,"not supported, using",p,"instead."));const re=J.morphAttributes.position||J.morphAttributes.normal||J.morphAttributes.color,xe=re!==void 0?re.length:0;let fe=0;J.morphAttributes.position!==void 0&&(fe=1),J.morphAttributes.normal!==void 0&&(fe=2),J.morphAttributes.color!==void 0&&(fe=3);let Ue,Y,ee,ae;if(Z){const H=ti[Z];Ue=H.vertexShader,Y=H.fragmentShader}else Ue=b.vertexShader,Y=b.fragmentShader,l.update(b),ee=l.getVertexShaderID(b),ae=l.getFragmentShaderID(b);const ue=t.getRenderTarget(),Ce=V.isInstancedMesh===!0,Fe=V.isBatchedMesh===!0,Ze=!!b.map,D=!!b.matcap,$e=!!ne,Qe=!!b.aoMap,nt=!!b.lightMap,Re=!!b.bumpMap,Je=!!b.normalMap,We=!!b.displacementMap,Be=!!b.emissiveMap,dt=!!b.metalnessMap,C=!!b.roughnessMap,S=b.anisotropy>0,j=b.clearcoat>0,ie=b.dispersion>0,le=b.iridescence>0,se=b.sheen>0,Ae=b.transmission>0,me=S&&!!b.anisotropyMap,ge=j&&!!b.clearcoatMap,Le=j&&!!b.clearcoatNormalMap,he=j&&!!b.clearcoatRoughnessMap,we=le&&!!b.iridescenceMap,Xe=le&&!!b.iridescenceThicknessMap,De=se&&!!b.sheenColorMap,ve=se&&!!b.sheenRoughnessMap,ze=!!b.specularMap,Ve=!!b.specularColorMap,R=!!b.specularIntensityMap,A=Ae&&!!b.transmissionMap,te=Ae&&!!b.thicknessMap,W=!!b.gradientMap,Q=!!b.alphaMap,oe=b.alphaTest>0,Se=!!b.alphaHash,at=!!b.extensions;let ht=nn;b.toneMapped&&(ue===null||ue.isXRRenderTarget===!0)&&(ht=t.toneMapping);const z={shaderID:Z,shaderType:b.type,shaderName:b.name,vertexShader:Ue,fragmentShader:Y,defines:b.defines,customVertexShaderID:ee,customFragmentShaderID:ae,isRawShaderMaterial:b.isRawShaderMaterial===!0,glslVersion:b.glslVersion,precision:p,batching:Fe,batchingColor:Fe&&V._colorsTexture!==null,instancing:Ce,instancingColor:Ce&&V.instanceColor!==null,instancingMorph:Ce&&V.morphTexture!==null,supportsVertexTextures:d,outputColorSpace:ue===null?t.outputColorSpace:ue.isXRRenderTarget===!0?ue.texture.colorSpace:fn,alphaToCoverage:!!b.alphaToCoverage,map:Ze,matcap:D,envMap:$e,envMapMode:$e&&ne.mapping,envMapCubeUVHeight:I,aoMap:Qe,lightMap:nt,bumpMap:Re,normalMap:Je,displacementMap:d&&We,emissiveMap:Be,normalMapObjectSpace:Je&&b.normalMapType===jy,normalMapTangentSpace:Je&&b.normalMapType===Qv,metalnessMap:dt,roughnessMap:C,anisotropy:S,anisotropyMap:me,clearcoat:j,clearcoatMap:ge,clearcoatNormalMap:Le,clearcoatRoughnessMap:he,dispersion:ie,iridescence:le,iridescenceMap:we,iridescenceThicknessMap:Xe,sheen:se,sheenColorMap:De,sheenRoughnessMap:ve,specularMap:ze,specularColorMap:Ve,specularIntensityMap:R,transmission:Ae,transmissionMap:A,thicknessMap:te,gradientMap:W,opaque:b.transparent===!1&&b.blending===La&&b.alphaToCoverage===!1,alphaMap:Q,alphaTest:oe,alphaHash:Se,combine:b.combine,mapUv:Ze&&x(b.map.channel),aoMapUv:Qe&&x(b.aoMap.channel),lightMapUv:nt&&x(b.lightMap.channel),bumpMapUv:Re&&x(b.bumpMap.channel),normalMapUv:Je&&x(b.normalMap.channel),displacementMapUv:We&&x(b.displacementMap.channel),emissiveMapUv:Be&&x(b.emissiveMap.channel),metalnessMapUv:dt&&x(b.metalnessMap.channel),roughnessMapUv:C&&x(b.roughnessMap.channel),anisotropyMapUv:me&&x(b.anisotropyMap.channel),clearcoatMapUv:ge&&x(b.clearcoatMap.channel),clearcoatNormalMapUv:Le&&x(b.clearcoatNormalMap.channel),clearcoatRoughnessMapUv:he&&x(b.clearcoatRoughnessMap.channel),iridescenceMapUv:we&&x(b.iridescenceMap.channel),iridescenceThicknessMapUv:Xe&&x(b.iridescenceThicknessMap.channel),sheenColorMapUv:De&&x(b.sheenColorMap.channel),sheenRoughnessMapUv:ve&&x(b.sheenRoughnessMap.channel),specularMapUv:ze&&x(b.specularMap.channel),specularColorMapUv:Ve&&x(b.specularColorMap.channel),specularIntensityMapUv:R&&x(b.specularIntensityMap.channel),transmissionMapUv:A&&x(b.transmissionMap.channel),thicknessMapUv:te&&x(b.thicknessMap.channel),alphaMapUv:Q&&x(b.alphaMap.channel),vertexTangents:!!J.attributes.tangent&&(Je||S),vertexColors:b.vertexColors,vertexAlphas:b.vertexColors===!0&&!!J.attributes.color&&J.attributes.color.itemSize===4,pointsUvs:V.isPoints===!0&&!!J.attributes.uv&&(Ze||Q),fog:!!q,useFog:b.fog===!0,fogExp2:!!q&&q.isFogExp2,flatShading:b.flatShading===!0,sizeAttenuation:b.sizeAttenuation===!0,logarithmicDepthBuffer:f,skinning:V.isSkinnedMesh===!0,morphTargets:J.morphAttributes.position!==void 0,morphNormals:J.morphAttributes.normal!==void 0,morphColors:J.morphAttributes.color!==void 0,morphTargetsCount:xe,morphTextureStride:fe,numDirLights:y.directional.length,numPointLights:y.point.length,numSpotLights:y.spot.length,numSpotLightMaps:y.spotLightMap.length,numRectAreaLights:y.rectArea.length,numHemiLights:y.hemi.length,numDirLightShadows:y.directionalShadowMap.length,numPointLightShadows:y.pointShadowMap.length,numSpotLightShadows:y.spotShadowMap.length,numSpotLightShadowsWithMaps:y.numSpotLightShadowsWithMaps,numLightProbes:y.numLightProbes,numClippingPlanes:s.numPlanes,numClipIntersection:s.numIntersection,dithering:b.dithering,shadowMapEnabled:t.shadowMap.enabled&&U.length>0,shadowMapType:t.shadowMap.type,toneMapping:ht,decodeVideoTexture:Ze&&b.map.isVideoTexture===!0&&ut.getTransfer(b.map.colorSpace)===_t,premultipliedAlpha:b.premultipliedAlpha,doubleSided:b.side===jr,flipSided:b.side===vr,useDepthPacking:b.depthPacking>=0,depthPacking:b.depthPacking||0,index0AttributeName:b.index0AttributeName,extensionClipCullDistance:at&&b.extensions.clipCullDistance===!0&&i.has("WEBGL_clip_cull_distance"),extensionMultiDraw:at&&b.extensions.multiDraw===!0&&i.has("WEBGL_multi_draw"),rendererExtensionParallelShaderCompile:i.has("KHR_parallel_shader_compile"),customProgramCacheKey:b.customProgramCacheKey()};return z.vertexUv1s=u.has(1),z.vertexUv2s=u.has(2),z.vertexUv3s=u.has(3),u.clear(),z}function c(b){const y=[];if(b.shaderID?y.push(b.shaderID):(y.push(b.customVertexShaderID),y.push(b.customFragmentShaderID)),b.defines!==void 0)for(const U in b.defines)y.push(U),y.push(b.defines[U]);return b.isRawShaderMaterial===!1&&(g(y,b),v(y,b),y.push(t.outputColorSpace)),y.push(b.customProgramCacheKey),y.join()}function g(b,y){b.push(y.precision),b.push(y.outputColorSpace),b.push(y.envMapMode),b.push(y.envMapCubeUVHeight),b.push(y.mapUv),b.push(y.alphaMapUv),b.push(y.lightMapUv),b.push(y.aoMapUv),b.push(y.bumpMapUv),b.push(y.normalMapUv),b.push(y.displacementMapUv),b.push(y.emissiveMapUv),b.push(y.metalnessMapUv),b.push(y.roughnessMapUv),b.push(y.anisotropyMapUv),b.push(y.clearcoatMapUv),b.push(y.clearcoatNormalMapUv),b.push(y.clearcoatRoughnessMapUv),b.push(y.iridescenceMapUv),b.push(y.iridescenceThicknessMapUv),b.push(y.sheenColorMapUv),b.push(y.sheenRoughnessMapUv),b.push(y.specularMapUv),b.push(y.specularColorMapUv),b.push(y.specularIntensityMapUv),b.push(y.transmissionMapUv),b.push(y.thicknessMapUv),b.push(y.combine),b.push(y.fogExp2),b.push(y.sizeAttenuation),b.push(y.morphTargetsCount),b.push(y.morphAttributeCount),b.push(y.numDirLights),b.push(y.numPointLights),b.push(y.numSpotLights),b.push(y.numSpotLightMaps),b.push(y.numHemiLights),b.push(y.numRectAreaLights),b.push(y.numDirLightShadows),b.push(y.numPointLightShadows),b.push(y.numSpotLightShadows),b.push(y.numSpotLightShadowsWithMaps),b.push(y.numLightProbes),b.push(y.shadowMapType),b.push(y.toneMapping),b.push(y.numClippingPlanes),b.push(y.numClipIntersection),b.push(y.depthPacking)}function v(b,y){o.disableAll(),y.supportsVertexTextures&&o.enable(0),y.instancing&&o.enable(1),y.instancingColor&&o.enable(2),y.instancingMorph&&o.enable(3),y.matcap&&o.enable(4),y.envMap&&o.enable(5),y.normalMapObjectSpace&&o.enable(6),y.normalMapTangentSpace&&o.enable(7),y.clearcoat&&o.enable(8),y.iridescence&&o.enable(9),y.alphaTest&&o.enable(10),y.vertexColors&&o.enable(11),y.vertexAlphas&&o.enable(12),y.vertexUv1s&&o.enable(13),y.vertexUv2s&&o.enable(14),y.vertexUv3s&&o.enable(15),y.vertexTangents&&o.enable(16),y.anisotropy&&o.enable(17),y.alphaHash&&o.enable(18),y.batching&&o.enable(19),y.dispersion&&o.enable(20),y.batchingColor&&o.enable(21),b.push(o.mask),o.disableAll(),y.fog&&o.enable(0),y.useFog&&o.enable(1),y.flatShading&&o.enable(2),y.logarithmicDepthBuffer&&o.enable(3),y.skinning&&o.enable(4),y.morphTargets&&o.enable(5),y.morphNormals&&o.enable(6),y.morphColors&&o.enable(7),y.premultipliedAlpha&&o.enable(8),y.shadowMapEnabled&&o.enable(9),y.doubleSided&&o.enable(10),y.flipSided&&o.enable(11),y.useDepthPacking&&o.enable(12),y.dithering&&o.enable(13),y.transmission&&o.enable(14),y.sheen&&o.enable(15),y.opaque&&o.enable(16),y.pointsUvs&&o.enable(17),y.decodeVideoTexture&&o.enable(18),y.alphaToCoverage&&o.enable(19),b.push(o.mask)}function M(b){const y=_[b.type];let U;if(y){const B=ti[y];U=yM.clone(B.uniforms)}else U=b.uniforms;return U}function P(b,y){let U;for(let B=0,V=h.length;B<V;B++){const q=h[B];if(q.cacheKey===y){U=q,++U.usedTimes;break}}return U===void 0&&(U=new U1(t,y,b,a),h.push(U)),U}function T(b){if(--b.usedTimes===0){const y=h.indexOf(b);h[y]=h[h.length-1],h.pop(),b.destroy()}}function w(b){l.remove(b)}function L(){l.dispose()}return{getParameters:m,getProgramCacheKey:c,getUniforms:M,acquireProgram:P,releaseProgram:T,releaseShaderCache:w,programs:h,dispose:L}}function k1(){let t=new WeakMap;function e(a){let s=t.get(a);return s===void 0&&(s={},t.set(a,s)),s}function r(a){t.delete(a)}function i(a,s,o){t.get(a)[s]=o}function n(){t=new WeakMap}return{get:e,remove:r,update:i,dispose:n}}function F1(t,e){return t.groupOrder!==e.groupOrder?t.groupOrder-e.groupOrder:t.renderOrder!==e.renderOrder?t.renderOrder-e.renderOrder:t.material.id!==e.material.id?t.material.id-e.material.id:t.z!==e.z?t.z-e.z:t.id-e.id}function sm(t,e){return t.groupOrder!==e.groupOrder?t.groupOrder-e.groupOrder:t.renderOrder!==e.renderOrder?t.renderOrder-e.renderOrder:t.z!==e.z?e.z-t.z:t.id-e.id}function om(){const t=[];let e=0;const r=[],i=[],n=[];function a(){e=0,r.length=0,i.length=0,n.length=0}function s(f,d,p,_,x,m){let c=t[e];return c===void 0?(c={id:f.id,object:f,geometry:d,material:p,groupOrder:_,renderOrder:f.renderOrder,z:x,group:m},t[e]=c):(c.id=f.id,c.object=f,c.geometry=d,c.material=p,c.groupOrder=_,c.renderOrder=f.renderOrder,c.z=x,c.group=m),e++,c}function o(f,d,p,_,x,m){const c=s(f,d,p,_,x,m);p.transmission>0?i.push(c):p.transparent===!0?n.push(c):r.push(c)}function l(f,d,p,_,x,m){const c=s(f,d,p,_,x,m);p.transmission>0?i.unshift(c):p.transparent===!0?n.unshift(c):r.unshift(c)}function u(f,d){r.length>1&&r.sort(f||F1),i.length>1&&i.sort(d||sm),n.length>1&&n.sort(d||sm)}function h(){for(let f=e,d=t.length;f<d;f++){const p=t[f];if(p.id===null)break;p.id=null,p.object=null,p.geometry=null,p.material=null,p.group=null}}return{opaque:r,transmissive:i,transparent:n,init:a,push:o,unshift:l,finish:h,sort:u}}function z1(){let t=new WeakMap;function e(i,n){const a=t.get(i);let s;return a===void 0?(s=new om,t.set(i,[s])):n>=a.length?(s=new om,a.push(s)):s=a[n],s}function r(){t=new WeakMap}return{get:e,dispose:r}}function B1(){const t={};return{get:function(e){if(t[e.id]!==void 0)return t[e.id];let r;switch(e.type){case"DirectionalLight":r={direction:new O,color:new ke};break;case"SpotLight":r={position:new O,direction:new O,color:new ke,distance:0,coneCos:0,penumbraCos:0,decay:0};break;case"PointLight":r={position:new O,color:new ke,distance:0,decay:0};break;case"HemisphereLight":r={direction:new O,skyColor:new ke,groundColor:new ke};break;case"RectAreaLight":r={color:new ke,position:new O,halfWidth:new O,halfHeight:new O};break}return t[e.id]=r,r}}}function V1(){const t={};return{get:function(e){if(t[e.id]!==void 0)return t[e.id];let r;switch(e.type){case"DirectionalLight":r={shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new Ne};break;case"SpotLight":r={shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new Ne};break;case"PointLight":r={shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new Ne,shadowCameraNear:1,shadowCameraFar:1e3};break}return t[e.id]=r,r}}}let H1=0;function G1(t,e){return(e.castShadow?2:0)-(t.castShadow?2:0)+(e.map?1:0)-(t.map?1:0)}function W1(t){const e=new B1,r=V1(),i={version:0,hash:{directionalLength:-1,pointLength:-1,spotLength:-1,rectAreaLength:-1,hemiLength:-1,numDirectionalShadows:-1,numPointShadows:-1,numSpotShadows:-1,numSpotMaps:-1,numLightProbes:-1},ambient:[0,0,0],probe:[],directional:[],directionalShadow:[],directionalShadowMap:[],directionalShadowMatrix:[],spot:[],spotLightMap:[],spotShadow:[],spotShadowMap:[],spotLightMatrix:[],rectArea:[],rectAreaLTC1:null,rectAreaLTC2:null,point:[],pointShadow:[],pointShadowMap:[],pointShadowMatrix:[],hemi:[],numSpotLightShadowsWithMaps:0,numLightProbes:0};for(let u=0;u<9;u++)i.probe.push(new O);const n=new O,a=new ft,s=new ft;function o(u){let h=0,f=0,d=0;for(let b=0;b<9;b++)i.probe[b].set(0,0,0);let p=0,_=0,x=0,m=0,c=0,g=0,v=0,M=0,P=0,T=0,w=0;u.sort(G1);for(let b=0,y=u.length;b<y;b++){const U=u[b],B=U.color,V=U.intensity,q=U.distance,J=U.shadow&&U.shadow.map?U.shadow.map.texture:null;if(U.isAmbientLight)h+=B.r*V,f+=B.g*V,d+=B.b*V;else if(U.isLightProbe){for(let K=0;K<9;K++)i.probe[K].addScaledVector(U.sh.coefficients[K],V);w++}else if(U.isDirectionalLight){const K=e.get(U);if(K.color.copy(U.color).multiplyScalar(U.intensity),U.castShadow){const ne=U.shadow,I=r.get(U);I.shadowBias=ne.bias,I.shadowNormalBias=ne.normalBias,I.shadowRadius=ne.radius,I.shadowMapSize=ne.mapSize,i.directionalShadow[p]=I,i.directionalShadowMap[p]=J,i.directionalShadowMatrix[p]=U.shadow.matrix,g++}i.directional[p]=K,p++}else if(U.isSpotLight){const K=e.get(U);K.position.setFromMatrixPosition(U.matrixWorld),K.color.copy(B).multiplyScalar(V),K.distance=q,K.coneCos=Math.cos(U.angle),K.penumbraCos=Math.cos(U.angle*(1-U.penumbra)),K.decay=U.decay,i.spot[x]=K;const ne=U.shadow;if(U.map&&(i.spotLightMap[P]=U.map,P++,ne.updateMatrices(U),U.castShadow&&T++),i.spotLightMatrix[x]=ne.matrix,U.castShadow){const I=r.get(U);I.shadowBias=ne.bias,I.shadowNormalBias=ne.normalBias,I.shadowRadius=ne.radius,I.shadowMapSize=ne.mapSize,i.spotShadow[x]=I,i.spotShadowMap[x]=J,M++}x++}else if(U.isRectAreaLight){const K=e.get(U);K.color.copy(B).multiplyScalar(V),K.halfWidth.set(U.width*.5,0,0),K.halfHeight.set(0,U.height*.5,0),i.rectArea[m]=K,m++}else if(U.isPointLight){const K=e.get(U);if(K.color.copy(U.color).multiplyScalar(U.intensity),K.distance=U.distance,K.decay=U.decay,U.castShadow){const ne=U.shadow,I=r.get(U);I.shadowBias=ne.bias,I.shadowNormalBias=ne.normalBias,I.shadowRadius=ne.radius,I.shadowMapSize=ne.mapSize,I.shadowCameraNear=ne.camera.near,I.shadowCameraFar=ne.camera.far,i.pointShadow[_]=I,i.pointShadowMap[_]=J,i.pointShadowMatrix[_]=U.shadow.matrix,v++}i.point[_]=K,_++}else if(U.isHemisphereLight){const K=e.get(U);K.skyColor.copy(U.color).multiplyScalar(V),K.groundColor.copy(U.groundColor).multiplyScalar(V),i.hemi[c]=K,c++}}m>0&&(t.has("OES_texture_float_linear")===!0?(i.rectAreaLTC1=_e.LTC_FLOAT_1,i.rectAreaLTC2=_e.LTC_FLOAT_2):(i.rectAreaLTC1=_e.LTC_HALF_1,i.rectAreaLTC2=_e.LTC_HALF_2)),i.ambient[0]=h,i.ambient[1]=f,i.ambient[2]=d;const L=i.hash;(L.directionalLength!==p||L.pointLength!==_||L.spotLength!==x||L.rectAreaLength!==m||L.hemiLength!==c||L.numDirectionalShadows!==g||L.numPointShadows!==v||L.numSpotShadows!==M||L.numSpotMaps!==P||L.numLightProbes!==w)&&(i.directional.length=p,i.spot.length=x,i.rectArea.length=m,i.point.length=_,i.hemi.length=c,i.directionalShadow.length=g,i.directionalShadowMap.length=g,i.pointShadow.length=v,i.pointShadowMap.length=v,i.spotShadow.length=M,i.spotShadowMap.length=M,i.directionalShadowMatrix.length=g,i.pointShadowMatrix.length=v,i.spotLightMatrix.length=M+P-T,i.spotLightMap.length=P,i.numSpotLightShadowsWithMaps=T,i.numLightProbes=w,L.directionalLength=p,L.pointLength=_,L.spotLength=x,L.rectAreaLength=m,L.hemiLength=c,L.numDirectionalShadows=g,L.numPointShadows=v,L.numSpotShadows=M,L.numSpotMaps=P,L.numLightProbes=w,i.version=H1++)}function l(u,h){let f=0,d=0,p=0,_=0,x=0;const m=h.matrixWorldInverse;for(let c=0,g=u.length;c<g;c++){const v=u[c];if(v.isDirectionalLight){const M=i.directional[f];M.direction.setFromMatrixPosition(v.matrixWorld),n.setFromMatrixPosition(v.target.matrixWorld),M.direction.sub(n),M.direction.transformDirection(m),f++}else if(v.isSpotLight){const M=i.spot[p];M.position.setFromMatrixPosition(v.matrixWorld),M.position.applyMatrix4(m),M.direction.setFromMatrixPosition(v.matrixWorld),n.setFromMatrixPosition(v.target.matrixWorld),M.direction.sub(n),M.direction.transformDirection(m),p++}else if(v.isRectAreaLight){const M=i.rectArea[_];M.position.setFromMatrixPosition(v.matrixWorld),M.position.applyMatrix4(m),s.identity(),a.copy(v.matrixWorld),a.premultiply(m),s.extractRotation(a),M.halfWidth.set(v.width*.5,0,0),M.halfHeight.set(0,v.height*.5,0),M.halfWidth.applyMatrix4(s),M.halfHeight.applyMatrix4(s),_++}else if(v.isPointLight){const M=i.point[d];M.position.setFromMatrixPosition(v.matrixWorld),M.position.applyMatrix4(m),d++}else if(v.isHemisphereLight){const M=i.hemi[x];M.direction.setFromMatrixPosition(v.matrixWorld),M.direction.transformDirection(m),x++}}}return{setup:o,setupView:l,state:i}}function lm(t){const e=new W1(t),r=[],i=[];function n(h){u.camera=h,r.length=0,i.length=0}function a(h){r.push(h)}function s(h){i.push(h)}function o(){e.setup(r)}function l(h){e.setupView(r,h)}const u={lightsArray:r,shadowsArray:i,camera:null,lights:e,transmissionRenderTarget:{}};return{init:n,state:u,setupLights:o,setupLightsView:l,pushLight:a,pushShadow:s}}function j1(t){let e=new WeakMap;function r(n,a=0){const s=e.get(n);let o;return s===void 0?(o=new lm(t),e.set(n,[o])):a>=s.length?(o=new lm(t),s.push(o)):o=s[a],o}function i(){e=new WeakMap}return{get:r,dispose:i}}class X1 extends Qa{constructor(e){super(),this.isMeshDepthMaterial=!0,this.type="MeshDepthMaterial",this.depthPacking=Gy,this.map=null,this.alphaMap=null,this.displacementMap=null,this.displacementScale=1,this.displacementBias=0,this.wireframe=!1,this.wireframeLinewidth=1,this.setValues(e)}copy(e){return super.copy(e),this.depthPacking=e.depthPacking,this.map=e.map,this.alphaMap=e.alphaMap,this.displacementMap=e.displacementMap,this.displacementScale=e.displacementScale,this.displacementBias=e.displacementBias,this.wireframe=e.wireframe,this.wireframeLinewidth=e.wireframeLinewidth,this}}class Y1 extends Qa{constructor(e){super(),this.isMeshDistanceMaterial=!0,this.type="MeshDistanceMaterial",this.map=null,this.alphaMap=null,this.displacementMap=null,this.displacementScale=1,this.displacementBias=0,this.setValues(e)}copy(e){return super.copy(e),this.map=e.map,this.alphaMap=e.alphaMap,this.displacementMap=e.displacementMap,this.displacementScale=e.displacementScale,this.displacementBias=e.displacementBias,this}}const q1=`void main() {
	gl_Position = vec4( position, 1.0 );
}`,K1=`uniform sampler2D shadow_pass;
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
}`;function Z1(t,e,r){let i=new Rh;const n=new Ne,a=new Ne,s=new Mt,o=new X1({depthPacking:Wy}),l=new Y1,u={},h=r.maxTextureSize,f={[on]:vr,[vr]:on,[jr]:jr},d=new un({defines:{VSM_SAMPLES:8},uniforms:{shadow_pass:{value:null},resolution:{value:new Ne},radius:{value:4}},vertexShader:q1,fragmentShader:K1}),p=d.clone();p.defines.HORIZONTAL_PASS=1;const _=new Or;_.setAttribute("position",new Kr(new Float32Array([-1,-1,.5,3,-1,.5,-1,3,.5]),3));const x=new mt(_,d),m=this;this.enabled=!1,this.autoUpdate=!0,this.needsUpdate=!1,this.type=Bv;let c=this.type;this.render=function(T,w,L){if(m.enabled===!1||m.autoUpdate===!1&&m.needsUpdate===!1||T.length===0)return;const b=t.getRenderTarget(),y=t.getActiveCubeFace(),U=t.getActiveMipmapLevel(),B=t.state;B.setBlending(rn),B.buffers.color.setClear(1,1,1,1),B.buffers.depth.setTest(!0),B.setScissorTest(!1);const V=c!==pi&&this.type===pi,q=c===pi&&this.type!==pi;for(let J=0,K=T.length;J<K;J++){const ne=T[J],I=ne.shadow;if(I===void 0){console.warn("THREE.WebGLShadowMap:",ne,"has no shadow.");continue}if(I.autoUpdate===!1&&I.needsUpdate===!1)continue;n.copy(I.mapSize);const Z=I.getFrameExtents();if(n.multiply(Z),a.copy(I.mapSize),(n.x>h||n.y>h)&&(n.x>h&&(a.x=Math.floor(h/Z.x),n.x=a.x*Z.x,I.mapSize.x=a.x),n.y>h&&(a.y=Math.floor(h/Z.y),n.y=a.y*Z.y,I.mapSize.y=a.y)),I.map===null||V===!0||q===!0){const xe=this.type!==pi?{minFilter:fr,magFilter:fr}:{};I.map!==null&&I.map.dispose(),I.map=new zn(n.x,n.y,xe),I.map.texture.name=ne.name+".shadowMap",I.camera.updateProjectionMatrix()}t.setRenderTarget(I.map),t.clear();const re=I.getViewportCount();for(let xe=0;xe<re;xe++){const fe=I.getViewport(xe);s.set(a.x*fe.x,a.y*fe.y,a.x*fe.z,a.y*fe.w),B.viewport(s),I.updateMatrices(ne,xe),i=I.getFrustum(),M(w,L,I.camera,ne,this.type)}I.isPointLightShadow!==!0&&this.type===pi&&g(I,L),I.needsUpdate=!1}c=this.type,m.needsUpdate=!1,t.setRenderTarget(b,y,U)};function g(T,w){const L=e.update(x);d.defines.VSM_SAMPLES!==T.blurSamples&&(d.defines.VSM_SAMPLES=T.blurSamples,p.defines.VSM_SAMPLES=T.blurSamples,d.needsUpdate=!0,p.needsUpdate=!0),T.mapPass===null&&(T.mapPass=new zn(n.x,n.y)),d.uniforms.shadow_pass.value=T.map.texture,d.uniforms.resolution.value=T.mapSize,d.uniforms.radius.value=T.radius,t.setRenderTarget(T.mapPass),t.clear(),t.renderBufferDirect(w,null,L,d,x,null),p.uniforms.shadow_pass.value=T.mapPass.texture,p.uniforms.resolution.value=T.mapSize,p.uniforms.radius.value=T.radius,t.setRenderTarget(T.map),t.clear(),t.renderBufferDirect(w,null,L,p,x,null)}function v(T,w,L,b){let y=null;const U=L.isPointLight===!0?T.customDistanceMaterial:T.customDepthMaterial;if(U!==void 0)y=U;else if(y=L.isPointLight===!0?l:o,t.localClippingEnabled&&w.clipShadows===!0&&Array.isArray(w.clippingPlanes)&&w.clippingPlanes.length!==0||w.displacementMap&&w.displacementScale!==0||w.alphaMap&&w.alphaTest>0||w.map&&w.alphaTest>0){const B=y.uuid,V=w.uuid;let q=u[B];q===void 0&&(q={},u[B]=q);let J=q[V];J===void 0&&(J=y.clone(),q[V]=J,w.addEventListener("dispose",P)),y=J}if(y.visible=w.visible,y.wireframe=w.wireframe,b===pi?y.side=w.shadowSide!==null?w.shadowSide:w.side:y.side=w.shadowSide!==null?w.shadowSide:f[w.side],y.alphaMap=w.alphaMap,y.alphaTest=w.alphaTest,y.map=w.map,y.clipShadows=w.clipShadows,y.clippingPlanes=w.clippingPlanes,y.clipIntersection=w.clipIntersection,y.displacementMap=w.displacementMap,y.displacementScale=w.displacementScale,y.displacementBias=w.displacementBias,y.wireframeLinewidth=w.wireframeLinewidth,y.linewidth=w.linewidth,L.isPointLight===!0&&y.isMeshDistanceMaterial===!0){const B=t.properties.get(y);B.light=L}return y}function M(T,w,L,b,y){if(T.visible===!1)return;if(T.layers.test(w.layers)&&(T.isMesh||T.isLine||T.isPoints)&&(T.castShadow||T.receiveShadow&&y===pi)&&(!T.frustumCulled||i.intersectsObject(T))){T.modelViewMatrix.multiplyMatrices(L.matrixWorldInverse,T.matrixWorld);const B=e.update(T),V=T.material;if(Array.isArray(V)){const q=B.groups;for(let J=0,K=q.length;J<K;J++){const ne=q[J],I=V[ne.materialIndex];if(I&&I.visible){const Z=v(T,I,b,y);T.onBeforeShadow(t,T,w,L,B,Z,ne),t.renderBufferDirect(L,null,B,Z,T,ne),T.onAfterShadow(t,T,w,L,B,Z,ne)}}}else if(V.visible){const q=v(T,V,b,y);T.onBeforeShadow(t,T,w,L,B,q,null),t.renderBufferDirect(L,null,B,q,T,null),T.onAfterShadow(t,T,w,L,B,q,null)}}const U=T.children;for(let B=0,V=U.length;B<V;B++)M(U[B],w,L,b,y)}function P(T){T.target.removeEventListener("dispose",P);for(const w in u){const L=u[w],b=T.target.uuid;b in L&&(L[b].dispose(),delete L[b])}}}function $1(t){function e(){let A=!1;const te=new Mt;let W=null;const Q=new Mt(0,0,0,0);return{setMask:function(oe){W!==oe&&!A&&(t.colorMask(oe,oe,oe,oe),W=oe)},setLocked:function(oe){A=oe},setClear:function(oe,Se,at,ht,z){z===!0&&(oe*=ht,Se*=ht,at*=ht),te.set(oe,Se,at,ht),Q.equals(te)===!1&&(t.clearColor(oe,Se,at,ht),Q.copy(te))},reset:function(){A=!1,W=null,Q.set(-1,0,0,0)}}}function r(){let A=!1,te=null,W=null,Q=null;return{setTest:function(oe){oe?ae(t.DEPTH_TEST):ue(t.DEPTH_TEST)},setMask:function(oe){te!==oe&&!A&&(t.depthMask(oe),te=oe)},setFunc:function(oe){if(W!==oe){switch(oe){case _y:t.depthFunc(t.NEVER);break;case xy:t.depthFunc(t.ALWAYS);break;case yy:t.depthFunc(t.LESS);break;case zl:t.depthFunc(t.LEQUAL);break;case My:t.depthFunc(t.EQUAL);break;case Sy:t.depthFunc(t.GEQUAL);break;case by:t.depthFunc(t.GREATER);break;case Ey:t.depthFunc(t.NOTEQUAL);break;default:t.depthFunc(t.LEQUAL)}W=oe}},setLocked:function(oe){A=oe},setClear:function(oe){Q!==oe&&(t.clearDepth(oe),Q=oe)},reset:function(){A=!1,te=null,W=null,Q=null}}}function i(){let A=!1,te=null,W=null,Q=null,oe=null,Se=null,at=null,ht=null,z=null;return{setTest:function(H){A||(H?ae(t.STENCIL_TEST):ue(t.STENCIL_TEST))},setMask:function(H){te!==H&&!A&&(t.stencilMask(H),te=H)},setFunc:function(H,$,N){(W!==H||Q!==$||oe!==N)&&(t.stencilFunc(H,$,N),W=H,Q=$,oe=N)},setOp:function(H,$,N){(Se!==H||at!==$||ht!==N)&&(t.stencilOp(H,$,N),Se=H,at=$,ht=N)},setLocked:function(H){A=H},setClear:function(H){z!==H&&(t.clearStencil(H),z=H)},reset:function(){A=!1,te=null,W=null,Q=null,oe=null,Se=null,at=null,ht=null,z=null}}}const n=new e,a=new r,s=new i,o=new WeakMap,l=new WeakMap;let u={},h={},f=new WeakMap,d=[],p=null,_=!1,x=null,m=null,c=null,g=null,v=null,M=null,P=null,T=new ke(0,0,0),w=0,L=!1,b=null,y=null,U=null,B=null,V=null;const q=t.getParameter(t.MAX_COMBINED_TEXTURE_IMAGE_UNITS);let J=!1,K=0;const ne=t.getParameter(t.VERSION);ne.indexOf("WebGL")!==-1?(K=parseFloat(/^WebGL (\d)/.exec(ne)[1]),J=K>=1):ne.indexOf("OpenGL ES")!==-1&&(K=parseFloat(/^OpenGL ES (\d)/.exec(ne)[1]),J=K>=2);let I=null,Z={};const re=t.getParameter(t.SCISSOR_BOX),xe=t.getParameter(t.VIEWPORT),fe=new Mt().fromArray(re),Ue=new Mt().fromArray(xe);function Y(A,te,W,Q){const oe=new Uint8Array(4),Se=t.createTexture();t.bindTexture(A,Se),t.texParameteri(A,t.TEXTURE_MIN_FILTER,t.NEAREST),t.texParameteri(A,t.TEXTURE_MAG_FILTER,t.NEAREST);for(let at=0;at<W;at++)A===t.TEXTURE_3D||A===t.TEXTURE_2D_ARRAY?t.texImage3D(te,0,t.RGBA,1,1,Q,0,t.RGBA,t.UNSIGNED_BYTE,oe):t.texImage2D(te+at,0,t.RGBA,1,1,0,t.RGBA,t.UNSIGNED_BYTE,oe);return Se}const ee={};ee[t.TEXTURE_2D]=Y(t.TEXTURE_2D,t.TEXTURE_2D,1),ee[t.TEXTURE_CUBE_MAP]=Y(t.TEXTURE_CUBE_MAP,t.TEXTURE_CUBE_MAP_POSITIVE_X,6),ee[t.TEXTURE_2D_ARRAY]=Y(t.TEXTURE_2D_ARRAY,t.TEXTURE_2D_ARRAY,1,1),ee[t.TEXTURE_3D]=Y(t.TEXTURE_3D,t.TEXTURE_3D,1,1),n.setClear(0,0,0,1),a.setClear(1),s.setClear(0),ae(t.DEPTH_TEST),a.setFunc(zl),Re(!1),Je(Gf),ae(t.CULL_FACE),Qe(rn);function ae(A){u[A]!==!0&&(t.enable(A),u[A]=!0)}function ue(A){u[A]!==!1&&(t.disable(A),u[A]=!1)}function Ce(A,te){return h[A]!==te?(t.bindFramebuffer(A,te),h[A]=te,A===t.DRAW_FRAMEBUFFER&&(h[t.FRAMEBUFFER]=te),A===t.FRAMEBUFFER&&(h[t.DRAW_FRAMEBUFFER]=te),!0):!1}function Fe(A,te){let W=d,Q=!1;if(A){W=f.get(te),W===void 0&&(W=[],f.set(te,W));const oe=A.textures;if(W.length!==oe.length||W[0]!==t.COLOR_ATTACHMENT0){for(let Se=0,at=oe.length;Se<at;Se++)W[Se]=t.COLOR_ATTACHMENT0+Se;W.length=oe.length,Q=!0}}else W[0]!==t.BACK&&(W[0]=t.BACK,Q=!0);Q&&t.drawBuffers(W)}function Ze(A){return p!==A?(t.useProgram(A),p=A,!0):!1}const D={[wn]:t.FUNC_ADD,[ty]:t.FUNC_SUBTRACT,[ry]:t.FUNC_REVERSE_SUBTRACT};D[iy]=t.MIN,D[ny]=t.MAX;const $e={[ay]:t.ZERO,[sy]:t.ONE,[oy]:t.SRC_COLOR,[bd]:t.SRC_ALPHA,[fy]:t.SRC_ALPHA_SATURATE,[dy]:t.DST_COLOR,[uy]:t.DST_ALPHA,[ly]:t.ONE_MINUS_SRC_COLOR,[Ed]:t.ONE_MINUS_SRC_ALPHA,[hy]:t.ONE_MINUS_DST_COLOR,[cy]:t.ONE_MINUS_DST_ALPHA,[py]:t.CONSTANT_COLOR,[my]:t.ONE_MINUS_CONSTANT_COLOR,[gy]:t.CONSTANT_ALPHA,[vy]:t.ONE_MINUS_CONSTANT_ALPHA};function Qe(A,te,W,Q,oe,Se,at,ht,z,H){if(A===rn){_===!0&&(ue(t.BLEND),_=!1);return}if(_===!1&&(ae(t.BLEND),_=!0),A!==ey){if(A!==x||H!==L){if((m!==wn||v!==wn)&&(t.blendEquation(t.FUNC_ADD),m=wn,v=wn),H)switch(A){case La:t.blendFuncSeparate(t.ONE,t.ONE_MINUS_SRC_ALPHA,t.ONE,t.ONE_MINUS_SRC_ALPHA);break;case Wf:t.blendFunc(t.ONE,t.ONE);break;case jf:t.blendFuncSeparate(t.ZERO,t.ONE_MINUS_SRC_COLOR,t.ZERO,t.ONE);break;case Xf:t.blendFuncSeparate(t.ZERO,t.SRC_COLOR,t.ZERO,t.SRC_ALPHA);break;default:console.error("THREE.WebGLState: Invalid blending: ",A);break}else switch(A){case La:t.blendFuncSeparate(t.SRC_ALPHA,t.ONE_MINUS_SRC_ALPHA,t.ONE,t.ONE_MINUS_SRC_ALPHA);break;case Wf:t.blendFunc(t.SRC_ALPHA,t.ONE);break;case jf:t.blendFuncSeparate(t.ZERO,t.ONE_MINUS_SRC_COLOR,t.ZERO,t.ONE);break;case Xf:t.blendFunc(t.ZERO,t.SRC_COLOR);break;default:console.error("THREE.WebGLState: Invalid blending: ",A);break}c=null,g=null,M=null,P=null,T.set(0,0,0),w=0,x=A,L=H}return}oe=oe||te,Se=Se||W,at=at||Q,(te!==m||oe!==v)&&(t.blendEquationSeparate(D[te],D[oe]),m=te,v=oe),(W!==c||Q!==g||Se!==M||at!==P)&&(t.blendFuncSeparate($e[W],$e[Q],$e[Se],$e[at]),c=W,g=Q,M=Se,P=at),(ht.equals(T)===!1||z!==w)&&(t.blendColor(ht.r,ht.g,ht.b,z),T.copy(ht),w=z),x=A,L=!1}function nt(A,te){A.side===jr?ue(t.CULL_FACE):ae(t.CULL_FACE);let W=A.side===vr;te&&(W=!W),Re(W),A.blending===La&&A.transparent===!1?Qe(rn):Qe(A.blending,A.blendEquation,A.blendSrc,A.blendDst,A.blendEquationAlpha,A.blendSrcAlpha,A.blendDstAlpha,A.blendColor,A.blendAlpha,A.premultipliedAlpha),a.setFunc(A.depthFunc),a.setTest(A.depthTest),a.setMask(A.depthWrite),n.setMask(A.colorWrite);const Q=A.stencilWrite;s.setTest(Q),Q&&(s.setMask(A.stencilWriteMask),s.setFunc(A.stencilFunc,A.stencilRef,A.stencilFuncMask),s.setOp(A.stencilFail,A.stencilZFail,A.stencilZPass)),Be(A.polygonOffset,A.polygonOffsetFactor,A.polygonOffsetUnits),A.alphaToCoverage===!0?ae(t.SAMPLE_ALPHA_TO_COVERAGE):ue(t.SAMPLE_ALPHA_TO_COVERAGE)}function Re(A){b!==A&&(A?t.frontFace(t.CW):t.frontFace(t.CCW),b=A)}function Je(A){A!==Qx?(ae(t.CULL_FACE),A!==y&&(A===Gf?t.cullFace(t.BACK):A===Jx?t.cullFace(t.FRONT):t.cullFace(t.FRONT_AND_BACK))):ue(t.CULL_FACE),y=A}function We(A){A!==U&&(J&&t.lineWidth(A),U=A)}function Be(A,te,W){A?(ae(t.POLYGON_OFFSET_FILL),(B!==te||V!==W)&&(t.polygonOffset(te,W),B=te,V=W)):ue(t.POLYGON_OFFSET_FILL)}function dt(A){A?ae(t.SCISSOR_TEST):ue(t.SCISSOR_TEST)}function C(A){A===void 0&&(A=t.TEXTURE0+q-1),I!==A&&(t.activeTexture(A),I=A)}function S(A,te,W){W===void 0&&(I===null?W=t.TEXTURE0+q-1:W=I);let Q=Z[W];Q===void 0&&(Q={type:void 0,texture:void 0},Z[W]=Q),(Q.type!==A||Q.texture!==te)&&(I!==W&&(t.activeTexture(W),I=W),t.bindTexture(A,te||ee[A]),Q.type=A,Q.texture=te)}function j(){const A=Z[I];A!==void 0&&A.type!==void 0&&(t.bindTexture(A.type,null),A.type=void 0,A.texture=void 0)}function ie(){try{t.compressedTexImage2D.apply(t,arguments)}catch(A){console.error("THREE.WebGLState:",A)}}function le(){try{t.compressedTexImage3D.apply(t,arguments)}catch(A){console.error("THREE.WebGLState:",A)}}function se(){try{t.texSubImage2D.apply(t,arguments)}catch(A){console.error("THREE.WebGLState:",A)}}function Ae(){try{t.texSubImage3D.apply(t,arguments)}catch(A){console.error("THREE.WebGLState:",A)}}function me(){try{t.compressedTexSubImage2D.apply(t,arguments)}catch(A){console.error("THREE.WebGLState:",A)}}function ge(){try{t.compressedTexSubImage3D.apply(t,arguments)}catch(A){console.error("THREE.WebGLState:",A)}}function Le(){try{t.texStorage2D.apply(t,arguments)}catch(A){console.error("THREE.WebGLState:",A)}}function he(){try{t.texStorage3D.apply(t,arguments)}catch(A){console.error("THREE.WebGLState:",A)}}function we(){try{t.texImage2D.apply(t,arguments)}catch(A){console.error("THREE.WebGLState:",A)}}function Xe(){try{t.texImage3D.apply(t,arguments)}catch(A){console.error("THREE.WebGLState:",A)}}function De(A){fe.equals(A)===!1&&(t.scissor(A.x,A.y,A.z,A.w),fe.copy(A))}function ve(A){Ue.equals(A)===!1&&(t.viewport(A.x,A.y,A.z,A.w),Ue.copy(A))}function ze(A,te){let W=l.get(te);W===void 0&&(W=new WeakMap,l.set(te,W));let Q=W.get(A);Q===void 0&&(Q=t.getUniformBlockIndex(te,A.name),W.set(A,Q))}function Ve(A,te){const W=l.get(te).get(A);o.get(te)!==W&&(t.uniformBlockBinding(te,W,A.__bindingPointIndex),o.set(te,W))}function R(){t.disable(t.BLEND),t.disable(t.CULL_FACE),t.disable(t.DEPTH_TEST),t.disable(t.POLYGON_OFFSET_FILL),t.disable(t.SCISSOR_TEST),t.disable(t.STENCIL_TEST),t.disable(t.SAMPLE_ALPHA_TO_COVERAGE),t.blendEquation(t.FUNC_ADD),t.blendFunc(t.ONE,t.ZERO),t.blendFuncSeparate(t.ONE,t.ZERO,t.ONE,t.ZERO),t.blendColor(0,0,0,0),t.colorMask(!0,!0,!0,!0),t.clearColor(0,0,0,0),t.depthMask(!0),t.depthFunc(t.LESS),t.clearDepth(1),t.stencilMask(4294967295),t.stencilFunc(t.ALWAYS,0,4294967295),t.stencilOp(t.KEEP,t.KEEP,t.KEEP),t.clearStencil(0),t.cullFace(t.BACK),t.frontFace(t.CCW),t.polygonOffset(0,0),t.activeTexture(t.TEXTURE0),t.bindFramebuffer(t.FRAMEBUFFER,null),t.bindFramebuffer(t.DRAW_FRAMEBUFFER,null),t.bindFramebuffer(t.READ_FRAMEBUFFER,null),t.useProgram(null),t.lineWidth(1),t.scissor(0,0,t.canvas.width,t.canvas.height),t.viewport(0,0,t.canvas.width,t.canvas.height),u={},I=null,Z={},h={},f=new WeakMap,d=[],p=null,_=!1,x=null,m=null,c=null,g=null,v=null,M=null,P=null,T=new ke(0,0,0),w=0,L=!1,b=null,y=null,U=null,B=null,V=null,fe.set(0,0,t.canvas.width,t.canvas.height),Ue.set(0,0,t.canvas.width,t.canvas.height),n.reset(),a.reset(),s.reset()}return{buffers:{color:n,depth:a,stencil:s},enable:ae,disable:ue,bindFramebuffer:Ce,drawBuffers:Fe,useProgram:Ze,setBlending:Qe,setMaterial:nt,setFlipSided:Re,setCullFace:Je,setLineWidth:We,setPolygonOffset:Be,setScissorTest:dt,activeTexture:C,bindTexture:S,unbindTexture:j,compressedTexImage2D:ie,compressedTexImage3D:le,texImage2D:we,texImage3D:Xe,updateUBOMapping:ze,uniformBlockBinding:Ve,texStorage2D:Le,texStorage3D:he,texSubImage2D:se,texSubImage3D:Ae,compressedTexSubImage2D:me,compressedTexSubImage3D:ge,scissor:De,viewport:ve,reset:R}}function Q1(t,e,r,i,n,a,s){const o=e.has("WEBGL_multisampled_render_to_texture")?e.get("WEBGL_multisampled_render_to_texture"):null,l=typeof navigator>"u"?!1:/OculusBrowser/g.test(navigator.userAgent),u=new Ne,h=new WeakMap;let f;const d=new WeakMap;let p=!1;try{p=typeof OffscreenCanvas<"u"&&new OffscreenCanvas(1,1).getContext("2d")!==null}catch{}function _(C,S){return p?new OffscreenCanvas(C,S):jl("canvas")}function x(C,S,j){let ie=1;const le=dt(C);if((le.width>j||le.height>j)&&(ie=j/Math.max(le.width,le.height)),ie<1)if(typeof HTMLImageElement<"u"&&C instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&C instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&C instanceof ImageBitmap||typeof VideoFrame<"u"&&C instanceof VideoFrame){const se=Math.floor(ie*le.width),Ae=Math.floor(ie*le.height);f===void 0&&(f=_(se,Ae));const me=S?_(se,Ae):f;return me.width=se,me.height=Ae,me.getContext("2d").drawImage(C,0,0,se,Ae),console.warn("THREE.WebGLRenderer: Texture has been resized from ("+le.width+"x"+le.height+") to ("+se+"x"+Ae+")."),me}else return"data"in C&&console.warn("THREE.WebGLRenderer: Image in DataTexture is too big ("+le.width+"x"+le.height+")."),C;return C}function m(C){return C.generateMipmaps&&C.minFilter!==fr&&C.minFilter!==Xr}function c(C){t.generateMipmap(C)}function g(C,S,j,ie,le=!1){if(C!==null){if(t[C]!==void 0)return t[C];console.warn("THREE.WebGLRenderer: Attempt to use non-existing WebGL internal format '"+C+"'")}let se=S;if(S===t.RED&&(j===t.FLOAT&&(se=t.R32F),j===t.HALF_FLOAT&&(se=t.R16F),j===t.UNSIGNED_BYTE&&(se=t.R8)),S===t.RED_INTEGER&&(j===t.UNSIGNED_BYTE&&(se=t.R8UI),j===t.UNSIGNED_SHORT&&(se=t.R16UI),j===t.UNSIGNED_INT&&(se=t.R32UI),j===t.BYTE&&(se=t.R8I),j===t.SHORT&&(se=t.R16I),j===t.INT&&(se=t.R32I)),S===t.RG&&(j===t.FLOAT&&(se=t.RG32F),j===t.HALF_FLOAT&&(se=t.RG16F),j===t.UNSIGNED_BYTE&&(se=t.RG8)),S===t.RG_INTEGER&&(j===t.UNSIGNED_BYTE&&(se=t.RG8UI),j===t.UNSIGNED_SHORT&&(se=t.RG16UI),j===t.UNSIGNED_INT&&(se=t.RG32UI),j===t.BYTE&&(se=t.RG8I),j===t.SHORT&&(se=t.RG16I),j===t.INT&&(se=t.RG32I)),S===t.RGB&&j===t.UNSIGNED_INT_5_9_9_9_REV&&(se=t.RGB9_E5),S===t.RGBA){const Ae=le?Vl:ut.getTransfer(ie);j===t.FLOAT&&(se=t.RGBA32F),j===t.HALF_FLOAT&&(se=t.RGBA16F),j===t.UNSIGNED_BYTE&&(se=Ae===_t?t.SRGB8_ALPHA8:t.RGBA8),j===t.UNSIGNED_SHORT_4_4_4_4&&(se=t.RGBA4),j===t.UNSIGNED_SHORT_5_5_5_1&&(se=t.RGB5_A1)}return(se===t.R16F||se===t.R32F||se===t.RG16F||se===t.RG32F||se===t.RGBA16F||se===t.RGBA32F)&&e.get("EXT_color_buffer_float"),se}function v(C,S){let j;return C?S===null||S===Wa||S===ja?j=t.DEPTH24_STENCIL8:S===Mi?j=t.DEPTH32F_STENCIL8:S===Bl&&(j=t.DEPTH24_STENCIL8,console.warn("DepthTexture: 16 bit depth attachment is not supported with stencil. Using 24-bit attachment.")):S===null||S===Wa||S===ja?j=t.DEPTH_COMPONENT24:S===Mi?j=t.DEPTH_COMPONENT32F:S===Bl&&(j=t.DEPTH_COMPONENT16),j}function M(C,S){return m(C)===!0||C.isFramebufferTexture&&C.minFilter!==fr&&C.minFilter!==Xr?Math.log2(Math.max(S.width,S.height))+1:C.mipmaps!==void 0&&C.mipmaps.length>0?C.mipmaps.length:C.isCompressedTexture&&Array.isArray(C.image)?S.mipmaps.length:1}function P(C){const S=C.target;S.removeEventListener("dispose",P),w(S),S.isVideoTexture&&h.delete(S)}function T(C){const S=C.target;S.removeEventListener("dispose",T),b(S)}function w(C){const S=i.get(C);if(S.__webglInit===void 0)return;const j=C.source,ie=d.get(j);if(ie){const le=ie[S.__cacheKey];le.usedTimes--,le.usedTimes===0&&L(C),Object.keys(ie).length===0&&d.delete(j)}i.remove(C)}function L(C){const S=i.get(C);t.deleteTexture(S.__webglTexture);const j=C.source,ie=d.get(j);delete ie[S.__cacheKey],s.memory.textures--}function b(C){const S=i.get(C);if(C.depthTexture&&C.depthTexture.dispose(),C.isWebGLCubeRenderTarget)for(let ie=0;ie<6;ie++){if(Array.isArray(S.__webglFramebuffer[ie]))for(let le=0;le<S.__webglFramebuffer[ie].length;le++)t.deleteFramebuffer(S.__webglFramebuffer[ie][le]);else t.deleteFramebuffer(S.__webglFramebuffer[ie]);S.__webglDepthbuffer&&t.deleteRenderbuffer(S.__webglDepthbuffer[ie])}else{if(Array.isArray(S.__webglFramebuffer))for(let ie=0;ie<S.__webglFramebuffer.length;ie++)t.deleteFramebuffer(S.__webglFramebuffer[ie]);else t.deleteFramebuffer(S.__webglFramebuffer);if(S.__webglDepthbuffer&&t.deleteRenderbuffer(S.__webglDepthbuffer),S.__webglMultisampledFramebuffer&&t.deleteFramebuffer(S.__webglMultisampledFramebuffer),S.__webglColorRenderbuffer)for(let ie=0;ie<S.__webglColorRenderbuffer.length;ie++)S.__webglColorRenderbuffer[ie]&&t.deleteRenderbuffer(S.__webglColorRenderbuffer[ie]);S.__webglDepthRenderbuffer&&t.deleteRenderbuffer(S.__webglDepthRenderbuffer)}const j=C.textures;for(let ie=0,le=j.length;ie<le;ie++){const se=i.get(j[ie]);se.__webglTexture&&(t.deleteTexture(se.__webglTexture),s.memory.textures--),i.remove(j[ie])}i.remove(C)}let y=0;function U(){y=0}function B(){const C=y;return C>=n.maxTextures&&console.warn("THREE.WebGLTextures: Trying to use "+C+" texture units while this GPU supports only "+n.maxTextures),y+=1,C}function V(C){const S=[];return S.push(C.wrapS),S.push(C.wrapT),S.push(C.wrapR||0),S.push(C.magFilter),S.push(C.minFilter),S.push(C.anisotropy),S.push(C.internalFormat),S.push(C.format),S.push(C.type),S.push(C.generateMipmaps),S.push(C.premultiplyAlpha),S.push(C.flipY),S.push(C.unpackAlignment),S.push(C.colorSpace),S.join()}function q(C,S){const j=i.get(C);if(C.isVideoTexture&&We(C),C.isRenderTargetTexture===!1&&C.version>0&&j.__version!==C.version){const ie=C.image;if(ie===null)console.warn("THREE.WebGLRenderer: Texture marked for update but no image data found.");else if(ie.complete===!1)console.warn("THREE.WebGLRenderer: Texture marked for update but image is incomplete");else{Ue(j,C,S);return}}r.bindTexture(t.TEXTURE_2D,j.__webglTexture,t.TEXTURE0+S)}function J(C,S){const j=i.get(C);if(C.version>0&&j.__version!==C.version){Ue(j,C,S);return}r.bindTexture(t.TEXTURE_2D_ARRAY,j.__webglTexture,t.TEXTURE0+S)}function K(C,S){const j=i.get(C);if(C.version>0&&j.__version!==C.version){Ue(j,C,S);return}r.bindTexture(t.TEXTURE_3D,j.__webglTexture,t.TEXTURE0+S)}function ne(C,S){const j=i.get(C);if(C.version>0&&j.__version!==C.version){Y(j,C,S);return}r.bindTexture(t.TEXTURE_CUBE_MAP,j.__webglTexture,t.TEXTURE0+S)}const I={[Ad]:t.REPEAT,[Pn]:t.CLAMP_TO_EDGE,[Cd]:t.MIRRORED_REPEAT},Z={[fr]:t.NEAREST,[Dy]:t.NEAREST_MIPMAP_NEAREST,[wo]:t.NEAREST_MIPMAP_LINEAR,[Xr]:t.LINEAR,[Yu]:t.LINEAR_MIPMAP_NEAREST,[Ln]:t.LINEAR_MIPMAP_LINEAR},re={[Xy]:t.NEVER,[Qy]:t.ALWAYS,[Yy]:t.LESS,[Jv]:t.LEQUAL,[qy]:t.EQUAL,[$y]:t.GEQUAL,[Ky]:t.GREATER,[Zy]:t.NOTEQUAL};function xe(C,S){if(S.type===Mi&&e.has("OES_texture_float_linear")===!1&&(S.magFilter===Xr||S.magFilter===Yu||S.magFilter===wo||S.magFilter===Ln||S.minFilter===Xr||S.minFilter===Yu||S.minFilter===wo||S.minFilter===Ln)&&console.warn("THREE.WebGLRenderer: Unable to use linear filtering with floating point textures. OES_texture_float_linear not supported on this device."),t.texParameteri(C,t.TEXTURE_WRAP_S,I[S.wrapS]),t.texParameteri(C,t.TEXTURE_WRAP_T,I[S.wrapT]),(C===t.TEXTURE_3D||C===t.TEXTURE_2D_ARRAY)&&t.texParameteri(C,t.TEXTURE_WRAP_R,I[S.wrapR]),t.texParameteri(C,t.TEXTURE_MAG_FILTER,Z[S.magFilter]),t.texParameteri(C,t.TEXTURE_MIN_FILTER,Z[S.minFilter]),S.compareFunction&&(t.texParameteri(C,t.TEXTURE_COMPARE_MODE,t.COMPARE_REF_TO_TEXTURE),t.texParameteri(C,t.TEXTURE_COMPARE_FUNC,re[S.compareFunction])),e.has("EXT_texture_filter_anisotropic")===!0){if(S.magFilter===fr||S.minFilter!==wo&&S.minFilter!==Ln||S.type===Mi&&e.has("OES_texture_float_linear")===!1)return;if(S.anisotropy>1||i.get(S).__currentAnisotropy){const j=e.get("EXT_texture_filter_anisotropic");t.texParameterf(C,j.TEXTURE_MAX_ANISOTROPY_EXT,Math.min(S.anisotropy,n.getMaxAnisotropy())),i.get(S).__currentAnisotropy=S.anisotropy}}}function fe(C,S){let j=!1;C.__webglInit===void 0&&(C.__webglInit=!0,S.addEventListener("dispose",P));const ie=S.source;let le=d.get(ie);le===void 0&&(le={},d.set(ie,le));const se=V(S);if(se!==C.__cacheKey){le[se]===void 0&&(le[se]={texture:t.createTexture(),usedTimes:0},s.memory.textures++,j=!0),le[se].usedTimes++;const Ae=le[C.__cacheKey];Ae!==void 0&&(le[C.__cacheKey].usedTimes--,Ae.usedTimes===0&&L(S)),C.__cacheKey=se,C.__webglTexture=le[se].texture}return j}function Ue(C,S,j){let ie=t.TEXTURE_2D;(S.isDataArrayTexture||S.isCompressedArrayTexture)&&(ie=t.TEXTURE_2D_ARRAY),S.isData3DTexture&&(ie=t.TEXTURE_3D);const le=fe(C,S),se=S.source;r.bindTexture(ie,C.__webglTexture,t.TEXTURE0+j);const Ae=i.get(se);if(se.version!==Ae.__version||le===!0){r.activeTexture(t.TEXTURE0+j);const me=ut.getPrimaries(ut.workingColorSpace),ge=S.colorSpace===ji?null:ut.getPrimaries(S.colorSpace),Le=S.colorSpace===ji||me===ge?t.NONE:t.BROWSER_DEFAULT_WEBGL;t.pixelStorei(t.UNPACK_FLIP_Y_WEBGL,S.flipY),t.pixelStorei(t.UNPACK_PREMULTIPLY_ALPHA_WEBGL,S.premultiplyAlpha),t.pixelStorei(t.UNPACK_ALIGNMENT,S.unpackAlignment),t.pixelStorei(t.UNPACK_COLORSPACE_CONVERSION_WEBGL,Le);let he=x(S.image,!1,n.maxTextureSize);he=Be(S,he);const we=a.convert(S.format,S.colorSpace),Xe=a.convert(S.type);let De=g(S.internalFormat,we,Xe,S.colorSpace,S.isVideoTexture);xe(ie,S);let ve;const ze=S.mipmaps,Ve=S.isVideoTexture!==!0,R=Ae.__version===void 0||le===!0,A=se.dataReady,te=M(S,he);if(S.isDepthTexture)De=v(S.format===Xa,S.type),R&&(Ve?r.texStorage2D(t.TEXTURE_2D,1,De,he.width,he.height):r.texImage2D(t.TEXTURE_2D,0,De,he.width,he.height,0,we,Xe,null));else if(S.isDataTexture)if(ze.length>0){Ve&&R&&r.texStorage2D(t.TEXTURE_2D,te,De,ze[0].width,ze[0].height);for(let W=0,Q=ze.length;W<Q;W++)ve=ze[W],Ve?A&&r.texSubImage2D(t.TEXTURE_2D,W,0,0,ve.width,ve.height,we,Xe,ve.data):r.texImage2D(t.TEXTURE_2D,W,De,ve.width,ve.height,0,we,Xe,ve.data);S.generateMipmaps=!1}else Ve?(R&&r.texStorage2D(t.TEXTURE_2D,te,De,he.width,he.height),A&&r.texSubImage2D(t.TEXTURE_2D,0,0,0,he.width,he.height,we,Xe,he.data)):r.texImage2D(t.TEXTURE_2D,0,De,he.width,he.height,0,we,Xe,he.data);else if(S.isCompressedTexture)if(S.isCompressedArrayTexture){Ve&&R&&r.texStorage3D(t.TEXTURE_2D_ARRAY,te,De,ze[0].width,ze[0].height,he.depth);for(let W=0,Q=ze.length;W<Q;W++)if(ve=ze[W],S.format!==ni)if(we!==null)if(Ve){if(A)if(S.layerUpdates.size>0){for(const oe of S.layerUpdates){const Se=ve.width*ve.height;r.compressedTexSubImage3D(t.TEXTURE_2D_ARRAY,W,0,0,oe,ve.width,ve.height,1,we,ve.data.slice(Se*oe,Se*(oe+1)),0,0)}S.clearLayerUpdates()}else r.compressedTexSubImage3D(t.TEXTURE_2D_ARRAY,W,0,0,0,ve.width,ve.height,he.depth,we,ve.data,0,0)}else r.compressedTexImage3D(t.TEXTURE_2D_ARRAY,W,De,ve.width,ve.height,he.depth,0,ve.data,0,0);else console.warn("THREE.WebGLRenderer: Attempt to load unsupported compressed texture format in .uploadTexture()");else Ve?A&&r.texSubImage3D(t.TEXTURE_2D_ARRAY,W,0,0,0,ve.width,ve.height,he.depth,we,Xe,ve.data):r.texImage3D(t.TEXTURE_2D_ARRAY,W,De,ve.width,ve.height,he.depth,0,we,Xe,ve.data)}else{Ve&&R&&r.texStorage2D(t.TEXTURE_2D,te,De,ze[0].width,ze[0].height);for(let W=0,Q=ze.length;W<Q;W++)ve=ze[W],S.format!==ni?we!==null?Ve?A&&r.compressedTexSubImage2D(t.TEXTURE_2D,W,0,0,ve.width,ve.height,we,ve.data):r.compressedTexImage2D(t.TEXTURE_2D,W,De,ve.width,ve.height,0,ve.data):console.warn("THREE.WebGLRenderer: Attempt to load unsupported compressed texture format in .uploadTexture()"):Ve?A&&r.texSubImage2D(t.TEXTURE_2D,W,0,0,ve.width,ve.height,we,Xe,ve.data):r.texImage2D(t.TEXTURE_2D,W,De,ve.width,ve.height,0,we,Xe,ve.data)}else if(S.isDataArrayTexture)if(Ve){if(R&&r.texStorage3D(t.TEXTURE_2D_ARRAY,te,De,he.width,he.height,he.depth),A)if(S.layerUpdates.size>0){let W;switch(Xe){case t.UNSIGNED_BYTE:switch(we){case t.ALPHA:W=1;break;case t.LUMINANCE:W=1;break;case t.LUMINANCE_ALPHA:W=2;break;case t.RGB:W=3;break;case t.RGBA:W=4;break;default:throw new Error(`Unknown texel size for format ${we}.`)}break;case t.UNSIGNED_SHORT_4_4_4_4:case t.UNSIGNED_SHORT_5_5_5_1:case t.UNSIGNED_SHORT_5_6_5:W=1;break;default:throw new Error(`Unknown texel size for type ${Xe}.`)}const Q=he.width*he.height*W;for(const oe of S.layerUpdates)r.texSubImage3D(t.TEXTURE_2D_ARRAY,0,0,0,oe,he.width,he.height,1,we,Xe,he.data.slice(Q*oe,Q*(oe+1)));S.clearLayerUpdates()}else r.texSubImage3D(t.TEXTURE_2D_ARRAY,0,0,0,0,he.width,he.height,he.depth,we,Xe,he.data)}else r.texImage3D(t.TEXTURE_2D_ARRAY,0,De,he.width,he.height,he.depth,0,we,Xe,he.data);else if(S.isData3DTexture)Ve?(R&&r.texStorage3D(t.TEXTURE_3D,te,De,he.width,he.height,he.depth),A&&r.texSubImage3D(t.TEXTURE_3D,0,0,0,0,he.width,he.height,he.depth,we,Xe,he.data)):r.texImage3D(t.TEXTURE_3D,0,De,he.width,he.height,he.depth,0,we,Xe,he.data);else if(S.isFramebufferTexture){if(R)if(Ve)r.texStorage2D(t.TEXTURE_2D,te,De,he.width,he.height);else{let W=he.width,Q=he.height;for(let oe=0;oe<te;oe++)r.texImage2D(t.TEXTURE_2D,oe,De,W,Q,0,we,Xe,null),W>>=1,Q>>=1}}else if(ze.length>0){if(Ve&&R){const W=dt(ze[0]);r.texStorage2D(t.TEXTURE_2D,te,De,W.width,W.height)}for(let W=0,Q=ze.length;W<Q;W++)ve=ze[W],Ve?A&&r.texSubImage2D(t.TEXTURE_2D,W,0,0,we,Xe,ve):r.texImage2D(t.TEXTURE_2D,W,De,we,Xe,ve);S.generateMipmaps=!1}else if(Ve){if(R){const W=dt(he);r.texStorage2D(t.TEXTURE_2D,te,De,W.width,W.height)}A&&r.texSubImage2D(t.TEXTURE_2D,0,0,0,we,Xe,he)}else r.texImage2D(t.TEXTURE_2D,0,De,we,Xe,he);m(S)&&c(ie),Ae.__version=se.version,S.onUpdate&&S.onUpdate(S)}C.__version=S.version}function Y(C,S,j){if(S.image.length!==6)return;const ie=fe(C,S),le=S.source;r.bindTexture(t.TEXTURE_CUBE_MAP,C.__webglTexture,t.TEXTURE0+j);const se=i.get(le);if(le.version!==se.__version||ie===!0){r.activeTexture(t.TEXTURE0+j);const Ae=ut.getPrimaries(ut.workingColorSpace),me=S.colorSpace===ji?null:ut.getPrimaries(S.colorSpace),ge=S.colorSpace===ji||Ae===me?t.NONE:t.BROWSER_DEFAULT_WEBGL;t.pixelStorei(t.UNPACK_FLIP_Y_WEBGL,S.flipY),t.pixelStorei(t.UNPACK_PREMULTIPLY_ALPHA_WEBGL,S.premultiplyAlpha),t.pixelStorei(t.UNPACK_ALIGNMENT,S.unpackAlignment),t.pixelStorei(t.UNPACK_COLORSPACE_CONVERSION_WEBGL,ge);const Le=S.isCompressedTexture||S.image[0].isCompressedTexture,he=S.image[0]&&S.image[0].isDataTexture,we=[];for(let Q=0;Q<6;Q++)!Le&&!he?we[Q]=x(S.image[Q],!0,n.maxCubemapSize):we[Q]=he?S.image[Q].image:S.image[Q],we[Q]=Be(S,we[Q]);const Xe=we[0],De=a.convert(S.format,S.colorSpace),ve=a.convert(S.type),ze=g(S.internalFormat,De,ve,S.colorSpace),Ve=S.isVideoTexture!==!0,R=se.__version===void 0||ie===!0,A=le.dataReady;let te=M(S,Xe);xe(t.TEXTURE_CUBE_MAP,S);let W;if(Le){Ve&&R&&r.texStorage2D(t.TEXTURE_CUBE_MAP,te,ze,Xe.width,Xe.height);for(let Q=0;Q<6;Q++){W=we[Q].mipmaps;for(let oe=0;oe<W.length;oe++){const Se=W[oe];S.format!==ni?De!==null?Ve?A&&r.compressedTexSubImage2D(t.TEXTURE_CUBE_MAP_POSITIVE_X+Q,oe,0,0,Se.width,Se.height,De,Se.data):r.compressedTexImage2D(t.TEXTURE_CUBE_MAP_POSITIVE_X+Q,oe,ze,Se.width,Se.height,0,Se.data):console.warn("THREE.WebGLRenderer: Attempt to load unsupported compressed texture format in .setTextureCube()"):Ve?A&&r.texSubImage2D(t.TEXTURE_CUBE_MAP_POSITIVE_X+Q,oe,0,0,Se.width,Se.height,De,ve,Se.data):r.texImage2D(t.TEXTURE_CUBE_MAP_POSITIVE_X+Q,oe,ze,Se.width,Se.height,0,De,ve,Se.data)}}}else{if(W=S.mipmaps,Ve&&R){W.length>0&&te++;const Q=dt(we[0]);r.texStorage2D(t.TEXTURE_CUBE_MAP,te,ze,Q.width,Q.height)}for(let Q=0;Q<6;Q++)if(he){Ve?A&&r.texSubImage2D(t.TEXTURE_CUBE_MAP_POSITIVE_X+Q,0,0,0,we[Q].width,we[Q].height,De,ve,we[Q].data):r.texImage2D(t.TEXTURE_CUBE_MAP_POSITIVE_X+Q,0,ze,we[Q].width,we[Q].height,0,De,ve,we[Q].data);for(let oe=0;oe<W.length;oe++){const Se=W[oe].image[Q].image;Ve?A&&r.texSubImage2D(t.TEXTURE_CUBE_MAP_POSITIVE_X+Q,oe+1,0,0,Se.width,Se.height,De,ve,Se.data):r.texImage2D(t.TEXTURE_CUBE_MAP_POSITIVE_X+Q,oe+1,ze,Se.width,Se.height,0,De,ve,Se.data)}}else{Ve?A&&r.texSubImage2D(t.TEXTURE_CUBE_MAP_POSITIVE_X+Q,0,0,0,De,ve,we[Q]):r.texImage2D(t.TEXTURE_CUBE_MAP_POSITIVE_X+Q,0,ze,De,ve,we[Q]);for(let oe=0;oe<W.length;oe++){const Se=W[oe];Ve?A&&r.texSubImage2D(t.TEXTURE_CUBE_MAP_POSITIVE_X+Q,oe+1,0,0,De,ve,Se.image[Q]):r.texImage2D(t.TEXTURE_CUBE_MAP_POSITIVE_X+Q,oe+1,ze,De,ve,Se.image[Q])}}}m(S)&&c(t.TEXTURE_CUBE_MAP),se.__version=le.version,S.onUpdate&&S.onUpdate(S)}C.__version=S.version}function ee(C,S,j,ie,le,se){const Ae=a.convert(j.format,j.colorSpace),me=a.convert(j.type),ge=g(j.internalFormat,Ae,me,j.colorSpace);if(!i.get(S).__hasExternalTextures){const Le=Math.max(1,S.width>>se),he=Math.max(1,S.height>>se);le===t.TEXTURE_3D||le===t.TEXTURE_2D_ARRAY?r.texImage3D(le,se,ge,Le,he,S.depth,0,Ae,me,null):r.texImage2D(le,se,ge,Le,he,0,Ae,me,null)}r.bindFramebuffer(t.FRAMEBUFFER,C),Je(S)?o.framebufferTexture2DMultisampleEXT(t.FRAMEBUFFER,ie,le,i.get(j).__webglTexture,0,Re(S)):(le===t.TEXTURE_2D||le>=t.TEXTURE_CUBE_MAP_POSITIVE_X&&le<=t.TEXTURE_CUBE_MAP_NEGATIVE_Z)&&t.framebufferTexture2D(t.FRAMEBUFFER,ie,le,i.get(j).__webglTexture,se),r.bindFramebuffer(t.FRAMEBUFFER,null)}function ae(C,S,j){if(t.bindRenderbuffer(t.RENDERBUFFER,C),S.depthBuffer){const ie=S.depthTexture,le=ie&&ie.isDepthTexture?ie.type:null,se=v(S.stencilBuffer,le),Ae=S.stencilBuffer?t.DEPTH_STENCIL_ATTACHMENT:t.DEPTH_ATTACHMENT,me=Re(S);Je(S)?o.renderbufferStorageMultisampleEXT(t.RENDERBUFFER,me,se,S.width,S.height):j?t.renderbufferStorageMultisample(t.RENDERBUFFER,me,se,S.width,S.height):t.renderbufferStorage(t.RENDERBUFFER,se,S.width,S.height),t.framebufferRenderbuffer(t.FRAMEBUFFER,Ae,t.RENDERBUFFER,C)}else{const ie=S.textures;for(let le=0;le<ie.length;le++){const se=ie[le],Ae=a.convert(se.format,se.colorSpace),me=a.convert(se.type),ge=g(se.internalFormat,Ae,me,se.colorSpace),Le=Re(S);j&&Je(S)===!1?t.renderbufferStorageMultisample(t.RENDERBUFFER,Le,ge,S.width,S.height):Je(S)?o.renderbufferStorageMultisampleEXT(t.RENDERBUFFER,Le,ge,S.width,S.height):t.renderbufferStorage(t.RENDERBUFFER,ge,S.width,S.height)}}t.bindRenderbuffer(t.RENDERBUFFER,null)}function ue(C,S){if(S&&S.isWebGLCubeRenderTarget)throw new Error("Depth Texture with cube render targets is not supported");if(r.bindFramebuffer(t.FRAMEBUFFER,C),!(S.depthTexture&&S.depthTexture.isDepthTexture))throw new Error("renderTarget.depthTexture must be an instance of THREE.DepthTexture");(!i.get(S.depthTexture).__webglTexture||S.depthTexture.image.width!==S.width||S.depthTexture.image.height!==S.height)&&(S.depthTexture.image.width=S.width,S.depthTexture.image.height=S.height,S.depthTexture.needsUpdate=!0),q(S.depthTexture,0);const j=i.get(S.depthTexture).__webglTexture,ie=Re(S);if(S.depthTexture.format===Ua)Je(S)?o.framebufferTexture2DMultisampleEXT(t.FRAMEBUFFER,t.DEPTH_ATTACHMENT,t.TEXTURE_2D,j,0,ie):t.framebufferTexture2D(t.FRAMEBUFFER,t.DEPTH_ATTACHMENT,t.TEXTURE_2D,j,0);else if(S.depthTexture.format===Xa)Je(S)?o.framebufferTexture2DMultisampleEXT(t.FRAMEBUFFER,t.DEPTH_STENCIL_ATTACHMENT,t.TEXTURE_2D,j,0,ie):t.framebufferTexture2D(t.FRAMEBUFFER,t.DEPTH_STENCIL_ATTACHMENT,t.TEXTURE_2D,j,0);else throw new Error("Unknown depthTexture format")}function Ce(C){const S=i.get(C),j=C.isWebGLCubeRenderTarget===!0;if(C.depthTexture&&!S.__autoAllocateDepthBuffer){if(j)throw new Error("target.depthTexture not supported in Cube render targets");ue(S.__webglFramebuffer,C)}else if(j){S.__webglDepthbuffer=[];for(let ie=0;ie<6;ie++)r.bindFramebuffer(t.FRAMEBUFFER,S.__webglFramebuffer[ie]),S.__webglDepthbuffer[ie]=t.createRenderbuffer(),ae(S.__webglDepthbuffer[ie],C,!1)}else r.bindFramebuffer(t.FRAMEBUFFER,S.__webglFramebuffer),S.__webglDepthbuffer=t.createRenderbuffer(),ae(S.__webglDepthbuffer,C,!1);r.bindFramebuffer(t.FRAMEBUFFER,null)}function Fe(C,S,j){const ie=i.get(C);S!==void 0&&ee(ie.__webglFramebuffer,C,C.texture,t.COLOR_ATTACHMENT0,t.TEXTURE_2D,0),j!==void 0&&Ce(C)}function Ze(C){const S=C.texture,j=i.get(C),ie=i.get(S);C.addEventListener("dispose",T);const le=C.textures,se=C.isWebGLCubeRenderTarget===!0,Ae=le.length>1;if(Ae||(ie.__webglTexture===void 0&&(ie.__webglTexture=t.createTexture()),ie.__version=S.version,s.memory.textures++),se){j.__webglFramebuffer=[];for(let me=0;me<6;me++)if(S.mipmaps&&S.mipmaps.length>0){j.__webglFramebuffer[me]=[];for(let ge=0;ge<S.mipmaps.length;ge++)j.__webglFramebuffer[me][ge]=t.createFramebuffer()}else j.__webglFramebuffer[me]=t.createFramebuffer()}else{if(S.mipmaps&&S.mipmaps.length>0){j.__webglFramebuffer=[];for(let me=0;me<S.mipmaps.length;me++)j.__webglFramebuffer[me]=t.createFramebuffer()}else j.__webglFramebuffer=t.createFramebuffer();if(Ae)for(let me=0,ge=le.length;me<ge;me++){const Le=i.get(le[me]);Le.__webglTexture===void 0&&(Le.__webglTexture=t.createTexture(),s.memory.textures++)}if(C.samples>0&&Je(C)===!1){j.__webglMultisampledFramebuffer=t.createFramebuffer(),j.__webglColorRenderbuffer=[],r.bindFramebuffer(t.FRAMEBUFFER,j.__webglMultisampledFramebuffer);for(let me=0;me<le.length;me++){const ge=le[me];j.__webglColorRenderbuffer[me]=t.createRenderbuffer(),t.bindRenderbuffer(t.RENDERBUFFER,j.__webglColorRenderbuffer[me]);const Le=a.convert(ge.format,ge.colorSpace),he=a.convert(ge.type),we=g(ge.internalFormat,Le,he,ge.colorSpace,C.isXRRenderTarget===!0),Xe=Re(C);t.renderbufferStorageMultisample(t.RENDERBUFFER,Xe,we,C.width,C.height),t.framebufferRenderbuffer(t.FRAMEBUFFER,t.COLOR_ATTACHMENT0+me,t.RENDERBUFFER,j.__webglColorRenderbuffer[me])}t.bindRenderbuffer(t.RENDERBUFFER,null),C.depthBuffer&&(j.__webglDepthRenderbuffer=t.createRenderbuffer(),ae(j.__webglDepthRenderbuffer,C,!0)),r.bindFramebuffer(t.FRAMEBUFFER,null)}}if(se){r.bindTexture(t.TEXTURE_CUBE_MAP,ie.__webglTexture),xe(t.TEXTURE_CUBE_MAP,S);for(let me=0;me<6;me++)if(S.mipmaps&&S.mipmaps.length>0)for(let ge=0;ge<S.mipmaps.length;ge++)ee(j.__webglFramebuffer[me][ge],C,S,t.COLOR_ATTACHMENT0,t.TEXTURE_CUBE_MAP_POSITIVE_X+me,ge);else ee(j.__webglFramebuffer[me],C,S,t.COLOR_ATTACHMENT0,t.TEXTURE_CUBE_MAP_POSITIVE_X+me,0);m(S)&&c(t.TEXTURE_CUBE_MAP),r.unbindTexture()}else if(Ae){for(let me=0,ge=le.length;me<ge;me++){const Le=le[me],he=i.get(Le);r.bindTexture(t.TEXTURE_2D,he.__webglTexture),xe(t.TEXTURE_2D,Le),ee(j.__webglFramebuffer,C,Le,t.COLOR_ATTACHMENT0+me,t.TEXTURE_2D,0),m(Le)&&c(t.TEXTURE_2D)}r.unbindTexture()}else{let me=t.TEXTURE_2D;if((C.isWebGL3DRenderTarget||C.isWebGLArrayRenderTarget)&&(me=C.isWebGL3DRenderTarget?t.TEXTURE_3D:t.TEXTURE_2D_ARRAY),r.bindTexture(me,ie.__webglTexture),xe(me,S),S.mipmaps&&S.mipmaps.length>0)for(let ge=0;ge<S.mipmaps.length;ge++)ee(j.__webglFramebuffer[ge],C,S,t.COLOR_ATTACHMENT0,me,ge);else ee(j.__webglFramebuffer,C,S,t.COLOR_ATTACHMENT0,me,0);m(S)&&c(me),r.unbindTexture()}C.depthBuffer&&Ce(C)}function D(C){const S=C.textures;for(let j=0,ie=S.length;j<ie;j++){const le=S[j];if(m(le)){const se=C.isWebGLCubeRenderTarget?t.TEXTURE_CUBE_MAP:t.TEXTURE_2D,Ae=i.get(le).__webglTexture;r.bindTexture(se,Ae),c(se),r.unbindTexture()}}}const $e=[],Qe=[];function nt(C){if(C.samples>0){if(Je(C)===!1){const S=C.textures,j=C.width,ie=C.height;let le=t.COLOR_BUFFER_BIT;const se=C.stencilBuffer?t.DEPTH_STENCIL_ATTACHMENT:t.DEPTH_ATTACHMENT,Ae=i.get(C),me=S.length>1;if(me)for(let ge=0;ge<S.length;ge++)r.bindFramebuffer(t.FRAMEBUFFER,Ae.__webglMultisampledFramebuffer),t.framebufferRenderbuffer(t.FRAMEBUFFER,t.COLOR_ATTACHMENT0+ge,t.RENDERBUFFER,null),r.bindFramebuffer(t.FRAMEBUFFER,Ae.__webglFramebuffer),t.framebufferTexture2D(t.DRAW_FRAMEBUFFER,t.COLOR_ATTACHMENT0+ge,t.TEXTURE_2D,null,0);r.bindFramebuffer(t.READ_FRAMEBUFFER,Ae.__webglMultisampledFramebuffer),r.bindFramebuffer(t.DRAW_FRAMEBUFFER,Ae.__webglFramebuffer);for(let ge=0;ge<S.length;ge++){if(C.resolveDepthBuffer&&(C.depthBuffer&&(le|=t.DEPTH_BUFFER_BIT),C.stencilBuffer&&C.resolveStencilBuffer&&(le|=t.STENCIL_BUFFER_BIT)),me){t.framebufferRenderbuffer(t.READ_FRAMEBUFFER,t.COLOR_ATTACHMENT0,t.RENDERBUFFER,Ae.__webglColorRenderbuffer[ge]);const Le=i.get(S[ge]).__webglTexture;t.framebufferTexture2D(t.DRAW_FRAMEBUFFER,t.COLOR_ATTACHMENT0,t.TEXTURE_2D,Le,0)}t.blitFramebuffer(0,0,j,ie,0,0,j,ie,le,t.NEAREST),l===!0&&($e.length=0,Qe.length=0,$e.push(t.COLOR_ATTACHMENT0+ge),C.depthBuffer&&C.resolveDepthBuffer===!1&&($e.push(se),Qe.push(se),t.invalidateFramebuffer(t.DRAW_FRAMEBUFFER,Qe)),t.invalidateFramebuffer(t.READ_FRAMEBUFFER,$e))}if(r.bindFramebuffer(t.READ_FRAMEBUFFER,null),r.bindFramebuffer(t.DRAW_FRAMEBUFFER,null),me)for(let ge=0;ge<S.length;ge++){r.bindFramebuffer(t.FRAMEBUFFER,Ae.__webglMultisampledFramebuffer),t.framebufferRenderbuffer(t.FRAMEBUFFER,t.COLOR_ATTACHMENT0+ge,t.RENDERBUFFER,Ae.__webglColorRenderbuffer[ge]);const Le=i.get(S[ge]).__webglTexture;r.bindFramebuffer(t.FRAMEBUFFER,Ae.__webglFramebuffer),t.framebufferTexture2D(t.DRAW_FRAMEBUFFER,t.COLOR_ATTACHMENT0+ge,t.TEXTURE_2D,Le,0)}r.bindFramebuffer(t.DRAW_FRAMEBUFFER,Ae.__webglMultisampledFramebuffer)}else if(C.depthBuffer&&C.resolveDepthBuffer===!1&&l){const S=C.stencilBuffer?t.DEPTH_STENCIL_ATTACHMENT:t.DEPTH_ATTACHMENT;t.invalidateFramebuffer(t.DRAW_FRAMEBUFFER,[S])}}}function Re(C){return Math.min(n.maxSamples,C.samples)}function Je(C){const S=i.get(C);return C.samples>0&&e.has("WEBGL_multisampled_render_to_texture")===!0&&S.__useRenderToTexture!==!1}function We(C){const S=s.render.frame;h.get(C)!==S&&(h.set(C,S),C.update())}function Be(C,S){const j=C.colorSpace,ie=C.format,le=C.type;return C.isCompressedTexture===!0||C.isVideoTexture===!0||j!==fn&&j!==ji&&(ut.getTransfer(j)===_t?(ie!==ni||le!==ln)&&console.warn("THREE.WebGLTextures: sRGB encoded textures have to use RGBAFormat and UnsignedByteType."):console.error("THREE.WebGLTextures: Unsupported texture color space:",j)),S}function dt(C){return typeof HTMLImageElement<"u"&&C instanceof HTMLImageElement?(u.width=C.naturalWidth||C.width,u.height=C.naturalHeight||C.height):typeof VideoFrame<"u"&&C instanceof VideoFrame?(u.width=C.displayWidth,u.height=C.displayHeight):(u.width=C.width,u.height=C.height),u}this.allocateTextureUnit=B,this.resetTextureUnits=U,this.setTexture2D=q,this.setTexture2DArray=J,this.setTexture3D=K,this.setTextureCube=ne,this.rebindTextures=Fe,this.setupRenderTarget=Ze,this.updateRenderTargetMipmap=D,this.updateMultisampleRenderTarget=nt,this.setupDepthRenderbuffer=Ce,this.setupFrameBufferTexture=ee,this.useMultisampledRTT=Je}function J1(t,e){function r(i,n=ji){let a;const s=ut.getTransfer(n);if(i===ln)return t.UNSIGNED_BYTE;if(i===Xv)return t.UNSIGNED_SHORT_4_4_4_4;if(i===Yv)return t.UNSIGNED_SHORT_5_5_5_1;if(i===Oy)return t.UNSIGNED_INT_5_9_9_9_REV;if(i===Iy)return t.BYTE;if(i===Ny)return t.SHORT;if(i===Bl)return t.UNSIGNED_SHORT;if(i===jv)return t.INT;if(i===Wa)return t.UNSIGNED_INT;if(i===Mi)return t.FLOAT;if(i===fu)return t.HALF_FLOAT;if(i===ky)return t.ALPHA;if(i===Fy)return t.RGB;if(i===ni)return t.RGBA;if(i===zy)return t.LUMINANCE;if(i===By)return t.LUMINANCE_ALPHA;if(i===Ua)return t.DEPTH_COMPONENT;if(i===Xa)return t.DEPTH_STENCIL;if(i===qv)return t.RED;if(i===Kv)return t.RED_INTEGER;if(i===Vy)return t.RG;if(i===Zv)return t.RG_INTEGER;if(i===$v)return t.RGBA_INTEGER;if(i===qu||i===Ku||i===Zu||i===$u)if(s===_t)if(a=e.get("WEBGL_compressed_texture_s3tc_srgb"),a!==null){if(i===qu)return a.COMPRESSED_SRGB_S3TC_DXT1_EXT;if(i===Ku)return a.COMPRESSED_SRGB_ALPHA_S3TC_DXT1_EXT;if(i===Zu)return a.COMPRESSED_SRGB_ALPHA_S3TC_DXT3_EXT;if(i===$u)return a.COMPRESSED_SRGB_ALPHA_S3TC_DXT5_EXT}else return null;else if(a=e.get("WEBGL_compressed_texture_s3tc"),a!==null){if(i===qu)return a.COMPRESSED_RGB_S3TC_DXT1_EXT;if(i===Ku)return a.COMPRESSED_RGBA_S3TC_DXT1_EXT;if(i===Zu)return a.COMPRESSED_RGBA_S3TC_DXT3_EXT;if(i===$u)return a.COMPRESSED_RGBA_S3TC_DXT5_EXT}else return null;if(i===Yf||i===qf||i===Kf||i===Zf)if(a=e.get("WEBGL_compressed_texture_pvrtc"),a!==null){if(i===Yf)return a.COMPRESSED_RGB_PVRTC_4BPPV1_IMG;if(i===qf)return a.COMPRESSED_RGB_PVRTC_2BPPV1_IMG;if(i===Kf)return a.COMPRESSED_RGBA_PVRTC_4BPPV1_IMG;if(i===Zf)return a.COMPRESSED_RGBA_PVRTC_2BPPV1_IMG}else return null;if(i===$f||i===Qf||i===Jf)if(a=e.get("WEBGL_compressed_texture_etc"),a!==null){if(i===$f||i===Qf)return s===_t?a.COMPRESSED_SRGB8_ETC2:a.COMPRESSED_RGB8_ETC2;if(i===Jf)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ETC2_EAC:a.COMPRESSED_RGBA8_ETC2_EAC}else return null;if(i===ep||i===tp||i===rp||i===ip||i===np||i===ap||i===sp||i===op||i===lp||i===up||i===cp||i===dp||i===hp||i===fp)if(a=e.get("WEBGL_compressed_texture_astc"),a!==null){if(i===ep)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ASTC_4x4_KHR:a.COMPRESSED_RGBA_ASTC_4x4_KHR;if(i===tp)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ASTC_5x4_KHR:a.COMPRESSED_RGBA_ASTC_5x4_KHR;if(i===rp)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ASTC_5x5_KHR:a.COMPRESSED_RGBA_ASTC_5x5_KHR;if(i===ip)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ASTC_6x5_KHR:a.COMPRESSED_RGBA_ASTC_6x5_KHR;if(i===np)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ASTC_6x6_KHR:a.COMPRESSED_RGBA_ASTC_6x6_KHR;if(i===ap)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ASTC_8x5_KHR:a.COMPRESSED_RGBA_ASTC_8x5_KHR;if(i===sp)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ASTC_8x6_KHR:a.COMPRESSED_RGBA_ASTC_8x6_KHR;if(i===op)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ASTC_8x8_KHR:a.COMPRESSED_RGBA_ASTC_8x8_KHR;if(i===lp)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ASTC_10x5_KHR:a.COMPRESSED_RGBA_ASTC_10x5_KHR;if(i===up)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ASTC_10x6_KHR:a.COMPRESSED_RGBA_ASTC_10x6_KHR;if(i===cp)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ASTC_10x8_KHR:a.COMPRESSED_RGBA_ASTC_10x8_KHR;if(i===dp)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ASTC_10x10_KHR:a.COMPRESSED_RGBA_ASTC_10x10_KHR;if(i===hp)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ASTC_12x10_KHR:a.COMPRESSED_RGBA_ASTC_12x10_KHR;if(i===fp)return s===_t?a.COMPRESSED_SRGB8_ALPHA8_ASTC_12x12_KHR:a.COMPRESSED_RGBA_ASTC_12x12_KHR}else return null;if(i===Qu||i===pp||i===mp)if(a=e.get("EXT_texture_compression_bptc"),a!==null){if(i===Qu)return s===_t?a.COMPRESSED_SRGB_ALPHA_BPTC_UNORM_EXT:a.COMPRESSED_RGBA_BPTC_UNORM_EXT;if(i===pp)return a.COMPRESSED_RGB_BPTC_SIGNED_FLOAT_EXT;if(i===mp)return a.COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT_EXT}else return null;if(i===Hy||i===gp||i===vp||i===_p)if(a=e.get("EXT_texture_compression_rgtc"),a!==null){if(i===Qu)return a.COMPRESSED_RED_RGTC1_EXT;if(i===gp)return a.COMPRESSED_SIGNED_RED_RGTC1_EXT;if(i===vp)return a.COMPRESSED_RED_GREEN_RGTC2_EXT;if(i===_p)return a.COMPRESSED_SIGNED_RED_GREEN_RGTC2_EXT}else return null;return i===ja?t.UNSIGNED_INT_24_8:t[i]!==void 0?t[i]:null}return{convert:r}}class ew extends Sr{constructor(e=[]){super(),this.isArrayCamera=!0,this.cameras=e}}class _i extends Rt{constructor(){super(),this.isGroup=!0,this.type="Group"}}const tw={type:"move"};class wc{constructor(){this._targetRay=null,this._grip=null,this._hand=null}getHandSpace(){return this._hand===null&&(this._hand=new _i,this._hand.matrixAutoUpdate=!1,this._hand.visible=!1,this._hand.joints={},this._hand.inputState={pinching:!1}),this._hand}getTargetRaySpace(){return this._targetRay===null&&(this._targetRay=new _i,this._targetRay.matrixAutoUpdate=!1,this._targetRay.visible=!1,this._targetRay.hasLinearVelocity=!1,this._targetRay.linearVelocity=new O,this._targetRay.hasAngularVelocity=!1,this._targetRay.angularVelocity=new O),this._targetRay}getGripSpace(){return this._grip===null&&(this._grip=new _i,this._grip.matrixAutoUpdate=!1,this._grip.visible=!1,this._grip.hasLinearVelocity=!1,this._grip.linearVelocity=new O,this._grip.hasAngularVelocity=!1,this._grip.angularVelocity=new O),this._grip}dispatchEvent(e){return this._targetRay!==null&&this._targetRay.dispatchEvent(e),this._grip!==null&&this._grip.dispatchEvent(e),this._hand!==null&&this._hand.dispatchEvent(e),this}connect(e){if(e&&e.hand){const r=this._hand;if(r)for(const i of e.hand.values())this._getHandJoint(r,i)}return this.dispatchEvent({type:"connected",data:e}),this}disconnect(e){return this.dispatchEvent({type:"disconnected",data:e}),this._targetRay!==null&&(this._targetRay.visible=!1),this._grip!==null&&(this._grip.visible=!1),this._hand!==null&&(this._hand.visible=!1),this}update(e,r,i){let n=null,a=null,s=null;const o=this._targetRay,l=this._grip,u=this._hand;if(e&&r.session.visibilityState!=="visible-blurred"){if(u&&e.hand){s=!0;for(const x of e.hand.values()){const m=r.getJointPose(x,i),c=this._getHandJoint(u,x);m!==null&&(c.matrix.fromArray(m.transform.matrix),c.matrix.decompose(c.position,c.rotation,c.scale),c.matrixWorldNeedsUpdate=!0,c.jointRadius=m.radius),c.visible=m!==null}const h=u.joints["index-finger-tip"],f=u.joints["thumb-tip"],d=h.position.distanceTo(f.position),p=.02,_=.005;u.inputState.pinching&&d>p+_?(u.inputState.pinching=!1,this.dispatchEvent({type:"pinchend",handedness:e.handedness,target:this})):!u.inputState.pinching&&d<=p-_&&(u.inputState.pinching=!0,this.dispatchEvent({type:"pinchstart",handedness:e.handedness,target:this}))}else l!==null&&e.gripSpace&&(a=r.getPose(e.gripSpace,i),a!==null&&(l.matrix.fromArray(a.transform.matrix),l.matrix.decompose(l.position,l.rotation,l.scale),l.matrixWorldNeedsUpdate=!0,a.linearVelocity?(l.hasLinearVelocity=!0,l.linearVelocity.copy(a.linearVelocity)):l.hasLinearVelocity=!1,a.angularVelocity?(l.hasAngularVelocity=!0,l.angularVelocity.copy(a.angularVelocity)):l.hasAngularVelocity=!1));o!==null&&(n=r.getPose(e.targetRaySpace,i),n===null&&a!==null&&(n=a),n!==null&&(o.matrix.fromArray(n.transform.matrix),o.matrix.decompose(o.position,o.rotation,o.scale),o.matrixWorldNeedsUpdate=!0,n.linearVelocity?(o.hasLinearVelocity=!0,o.linearVelocity.copy(n.linearVelocity)):o.hasLinearVelocity=!1,n.angularVelocity?(o.hasAngularVelocity=!0,o.angularVelocity.copy(n.angularVelocity)):o.hasAngularVelocity=!1,this.dispatchEvent(tw)))}return o!==null&&(o.visible=n!==null),l!==null&&(l.visible=a!==null),u!==null&&(u.visible=s!==null),this}_getHandJoint(e,r){if(e.joints[r.jointName]===void 0){const i=new _i;i.matrixAutoUpdate=!1,i.visible=!1,e.joints[r.jointName]=i,e.add(i)}return e.joints[r.jointName]}}const rw=`
void main() {

	gl_Position = vec4( position, 1.0 );

}`,iw=`
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

}`;class nw{constructor(){this.texture=null,this.mesh=null,this.depthNear=0,this.depthFar=0}init(e,r,i){if(this.texture===null){const n=new sr,a=e.properties.get(n);a.__webglTexture=r.texture,(r.depthNear!=i.depthNear||r.depthFar!=i.depthFar)&&(this.depthNear=r.depthNear,this.depthFar=r.depthFar),this.texture=n}}getMesh(e){if(this.texture!==null&&this.mesh===null){const r=e.cameras[0].viewport,i=new un({vertexShader:rw,fragmentShader:iw,uniforms:{depthColor:{value:this.texture},depthWidth:{value:r.z},depthHeight:{value:r.w}}});this.mesh=new mt(new ao(20,20),i)}return this.mesh}reset(){this.texture=null,this.mesh=null}}class aw extends Gn{constructor(e,r){super();const i=this;let n=null,a=1,s=null,o="local-floor",l=1,u=null,h=null,f=null,d=null,p=null,_=null;const x=new nw,m=r.getContextAttributes();let c=null,g=null;const v=[],M=[],P=new Ne;let T=null;const w=new Sr;w.layers.enable(1),w.viewport=new Mt;const L=new Sr;L.layers.enable(2),L.viewport=new Mt;const b=[w,L],y=new ew;y.layers.enable(1),y.layers.enable(2);let U=null,B=null;this.cameraAutoUpdate=!0,this.enabled=!1,this.isPresenting=!1,this.getController=function(Y){let ee=v[Y];return ee===void 0&&(ee=new wc,v[Y]=ee),ee.getTargetRaySpace()},this.getControllerGrip=function(Y){let ee=v[Y];return ee===void 0&&(ee=new wc,v[Y]=ee),ee.getGripSpace()},this.getHand=function(Y){let ee=v[Y];return ee===void 0&&(ee=new wc,v[Y]=ee),ee.getHandSpace()};function V(Y){const ee=M.indexOf(Y.inputSource);if(ee===-1)return;const ae=v[ee];ae!==void 0&&(ae.update(Y.inputSource,Y.frame,u||s),ae.dispatchEvent({type:Y.type,data:Y.inputSource}))}function q(){n.removeEventListener("select",V),n.removeEventListener("selectstart",V),n.removeEventListener("selectend",V),n.removeEventListener("squeeze",V),n.removeEventListener("squeezestart",V),n.removeEventListener("squeezeend",V),n.removeEventListener("end",q),n.removeEventListener("inputsourceschange",J);for(let Y=0;Y<v.length;Y++){const ee=M[Y];ee!==null&&(M[Y]=null,v[Y].disconnect(ee))}U=null,B=null,x.reset(),e.setRenderTarget(c),p=null,d=null,f=null,n=null,g=null,Ue.stop(),i.isPresenting=!1,e.setPixelRatio(T),e.setSize(P.width,P.height,!1),i.dispatchEvent({type:"sessionend"})}this.setFramebufferScaleFactor=function(Y){a=Y,i.isPresenting===!0&&console.warn("THREE.WebXRManager: Cannot change framebuffer scale while presenting.")},this.setReferenceSpaceType=function(Y){o=Y,i.isPresenting===!0&&console.warn("THREE.WebXRManager: Cannot change reference space type while presenting.")},this.getReferenceSpace=function(){return u||s},this.setReferenceSpace=function(Y){u=Y},this.getBaseLayer=function(){return d!==null?d:p},this.getBinding=function(){return f},this.getFrame=function(){return _},this.getSession=function(){return n},this.setSession=async function(Y){if(n=Y,n!==null){if(c=e.getRenderTarget(),n.addEventListener("select",V),n.addEventListener("selectstart",V),n.addEventListener("selectend",V),n.addEventListener("squeeze",V),n.addEventListener("squeezestart",V),n.addEventListener("squeezeend",V),n.addEventListener("end",q),n.addEventListener("inputsourceschange",J),m.xrCompatible!==!0&&await r.makeXRCompatible(),T=e.getPixelRatio(),e.getSize(P),n.renderState.layers===void 0){const ee={antialias:m.antialias,alpha:!0,depth:m.depth,stencil:m.stencil,framebufferScaleFactor:a};p=new XRWebGLLayer(n,r,ee),n.updateRenderState({baseLayer:p}),e.setPixelRatio(1),e.setSize(p.framebufferWidth,p.framebufferHeight,!1),g=new zn(p.framebufferWidth,p.framebufferHeight,{format:ni,type:ln,colorSpace:e.outputColorSpace,stencilBuffer:m.stencil})}else{let ee=null,ae=null,ue=null;m.depth&&(ue=m.stencil?r.DEPTH24_STENCIL8:r.DEPTH_COMPONENT24,ee=m.stencil?Xa:Ua,ae=m.stencil?ja:Wa);const Ce={colorFormat:r.RGBA8,depthFormat:ue,scaleFactor:a};f=new XRWebGLBinding(n,r),d=f.createProjectionLayer(Ce),n.updateRenderState({layers:[d]}),e.setPixelRatio(1),e.setSize(d.textureWidth,d.textureHeight,!1),g=new zn(d.textureWidth,d.textureHeight,{format:ni,type:ln,depthTexture:new h_(d.textureWidth,d.textureHeight,ae,void 0,void 0,void 0,void 0,void 0,void 0,ee),stencilBuffer:m.stencil,colorSpace:e.outputColorSpace,samples:m.antialias?4:0,resolveDepthBuffer:d.ignoreDepthValues===!1})}g.isXRRenderTarget=!0,this.setFoveation(l),u=null,s=await n.requestReferenceSpace(o),Ue.setContext(n),Ue.start(),i.isPresenting=!0,i.dispatchEvent({type:"sessionstart"})}},this.getEnvironmentBlendMode=function(){if(n!==null)return n.environmentBlendMode};function J(Y){for(let ee=0;ee<Y.removed.length;ee++){const ae=Y.removed[ee],ue=M.indexOf(ae);ue>=0&&(M[ue]=null,v[ue].disconnect(ae))}for(let ee=0;ee<Y.added.length;ee++){const ae=Y.added[ee];let ue=M.indexOf(ae);if(ue===-1){for(let Fe=0;Fe<v.length;Fe++)if(Fe>=M.length){M.push(ae),ue=Fe;break}else if(M[Fe]===null){M[Fe]=ae,ue=Fe;break}if(ue===-1)break}const Ce=v[ue];Ce&&Ce.connect(ae)}}const K=new O,ne=new O;function I(Y,ee,ae){K.setFromMatrixPosition(ee.matrixWorld),ne.setFromMatrixPosition(ae.matrixWorld);const ue=K.distanceTo(ne),Ce=ee.projectionMatrix.elements,Fe=ae.projectionMatrix.elements,Ze=Ce[14]/(Ce[10]-1),D=Ce[14]/(Ce[10]+1),$e=(Ce[9]+1)/Ce[5],Qe=(Ce[9]-1)/Ce[5],nt=(Ce[8]-1)/Ce[0],Re=(Fe[8]+1)/Fe[0],Je=Ze*nt,We=Ze*Re,Be=ue/(-nt+Re),dt=Be*-nt;ee.matrixWorld.decompose(Y.position,Y.quaternion,Y.scale),Y.translateX(dt),Y.translateZ(Be),Y.matrixWorld.compose(Y.position,Y.quaternion,Y.scale),Y.matrixWorldInverse.copy(Y.matrixWorld).invert();const C=Ze+Be,S=D+Be,j=Je-dt,ie=We+(ue-dt),le=$e*D/S*C,se=Qe*D/S*C;Y.projectionMatrix.makePerspective(j,ie,le,se,C,S),Y.projectionMatrixInverse.copy(Y.projectionMatrix).invert()}function Z(Y,ee){ee===null?Y.matrixWorld.copy(Y.matrix):Y.matrixWorld.multiplyMatrices(ee.matrixWorld,Y.matrix),Y.matrixWorldInverse.copy(Y.matrixWorld).invert()}this.updateCamera=function(Y){if(n===null)return;x.texture!==null&&(Y.near=x.depthNear,Y.far=x.depthFar),y.near=L.near=w.near=Y.near,y.far=L.far=w.far=Y.far,(U!==y.near||B!==y.far)&&(n.updateRenderState({depthNear:y.near,depthFar:y.far}),U=y.near,B=y.far,w.near=U,w.far=B,L.near=U,L.far=B,w.updateProjectionMatrix(),L.updateProjectionMatrix(),Y.updateProjectionMatrix());const ee=Y.parent,ae=y.cameras;Z(y,ee);for(let ue=0;ue<ae.length;ue++)Z(ae[ue],ee);ae.length===2?I(y,w,L):y.projectionMatrix.copy(w.projectionMatrix),re(Y,y,ee)};function re(Y,ee,ae){ae===null?Y.matrix.copy(ee.matrixWorld):(Y.matrix.copy(ae.matrixWorld),Y.matrix.invert(),Y.matrix.multiply(ee.matrixWorld)),Y.matrix.decompose(Y.position,Y.quaternion,Y.scale),Y.updateMatrixWorld(!0),Y.projectionMatrix.copy(ee.projectionMatrix),Y.projectionMatrixInverse.copy(ee.projectionMatrixInverse),Y.isPerspectiveCamera&&(Y.fov=Rd*2*Math.atan(1/Y.projectionMatrix.elements[5]),Y.zoom=1)}this.getCamera=function(){return y},this.getFoveation=function(){if(!(d===null&&p===null))return l},this.setFoveation=function(Y){l=Y,d!==null&&(d.fixedFoveation=Y),p!==null&&p.fixedFoveation!==void 0&&(p.fixedFoveation=Y)},this.hasDepthSensing=function(){return x.texture!==null},this.getDepthSensingMesh=function(){return x.getMesh(y)};let xe=null;function fe(Y,ee){if(h=ee.getViewerPose(u||s),_=ee,h!==null){const ae=h.views;p!==null&&(e.setRenderTargetFramebuffer(g,p.framebuffer),e.setRenderTarget(g));let ue=!1;ae.length!==y.cameras.length&&(y.cameras.length=0,ue=!0);for(let Fe=0;Fe<ae.length;Fe++){const Ze=ae[Fe];let D=null;if(p!==null)D=p.getViewport(Ze);else{const Qe=f.getViewSubImage(d,Ze);D=Qe.viewport,Fe===0&&(e.setRenderTargetTextures(g,Qe.colorTexture,d.ignoreDepthValues?void 0:Qe.depthStencilTexture),e.setRenderTarget(g))}let $e=b[Fe];$e===void 0&&($e=new Sr,$e.layers.enable(Fe),$e.viewport=new Mt,b[Fe]=$e),$e.matrix.fromArray(Ze.transform.matrix),$e.matrix.decompose($e.position,$e.quaternion,$e.scale),$e.projectionMatrix.fromArray(Ze.projectionMatrix),$e.projectionMatrixInverse.copy($e.projectionMatrix).invert(),$e.viewport.set(D.x,D.y,D.width,D.height),Fe===0&&(y.matrix.copy($e.matrix),y.matrix.decompose(y.position,y.quaternion,y.scale)),ue===!0&&y.cameras.push($e)}const Ce=n.enabledFeatures;if(Ce&&Ce.includes("depth-sensing")){const Fe=f.getDepthInformation(ae[0]);Fe&&Fe.isValid&&Fe.texture&&x.init(e,Fe,n.renderState)}}for(let ae=0;ae<v.length;ae++){const ue=M[ae],Ce=v[ae];ue!==null&&Ce!==void 0&&Ce.update(ue,ee,u||s)}xe&&xe(Y,ee),ee.detectedPlanes&&i.dispatchEvent({type:"planesdetected",data:ee}),_=null}const Ue=new c_;Ue.setAnimationLoop(fe),this.setAnimationLoop=function(Y){xe=Y},this.dispose=function(){}}}const yn=new oi,sw=new ft;function ow(t,e){function r(m,c){m.matrixAutoUpdate===!0&&m.updateMatrix(),c.value.copy(m.matrix)}function i(m,c){c.color.getRGB(m.fogColor.value,o_(t)),c.isFog?(m.fogNear.value=c.near,m.fogFar.value=c.far):c.isFogExp2&&(m.fogDensity.value=c.density)}function n(m,c,g,v,M){c.isMeshBasicMaterial||c.isMeshLambertMaterial?a(m,c):c.isMeshToonMaterial?(a(m,c),f(m,c)):c.isMeshPhongMaterial?(a(m,c),h(m,c)):c.isMeshStandardMaterial?(a(m,c),d(m,c),c.isMeshPhysicalMaterial&&p(m,c,M)):c.isMeshMatcapMaterial?(a(m,c),_(m,c)):c.isMeshDepthMaterial?a(m,c):c.isMeshDistanceMaterial?(a(m,c),x(m,c)):c.isMeshNormalMaterial?a(m,c):c.isLineBasicMaterial?(s(m,c),c.isLineDashedMaterial&&o(m,c)):c.isPointsMaterial?l(m,c,g,v):c.isSpriteMaterial?u(m,c):c.isShadowMaterial?(m.color.value.copy(c.color),m.opacity.value=c.opacity):c.isShaderMaterial&&(c.uniformsNeedUpdate=!1)}function a(m,c){m.opacity.value=c.opacity,c.color&&m.diffuse.value.copy(c.color),c.emissive&&m.emissive.value.copy(c.emissive).multiplyScalar(c.emissiveIntensity),c.map&&(m.map.value=c.map,r(c.map,m.mapTransform)),c.alphaMap&&(m.alphaMap.value=c.alphaMap,r(c.alphaMap,m.alphaMapTransform)),c.bumpMap&&(m.bumpMap.value=c.bumpMap,r(c.bumpMap,m.bumpMapTransform),m.bumpScale.value=c.bumpScale,c.side===vr&&(m.bumpScale.value*=-1)),c.normalMap&&(m.normalMap.value=c.normalMap,r(c.normalMap,m.normalMapTransform),m.normalScale.value.copy(c.normalScale),c.side===vr&&m.normalScale.value.negate()),c.displacementMap&&(m.displacementMap.value=c.displacementMap,r(c.displacementMap,m.displacementMapTransform),m.displacementScale.value=c.displacementScale,m.displacementBias.value=c.displacementBias),c.emissiveMap&&(m.emissiveMap.value=c.emissiveMap,r(c.emissiveMap,m.emissiveMapTransform)),c.specularMap&&(m.specularMap.value=c.specularMap,r(c.specularMap,m.specularMapTransform)),c.alphaTest>0&&(m.alphaTest.value=c.alphaTest);const g=e.get(c),v=g.envMap,M=g.envMapRotation;v&&(m.envMap.value=v,yn.copy(M),yn.x*=-1,yn.y*=-1,yn.z*=-1,v.isCubeTexture&&v.isRenderTargetTexture===!1&&(yn.y*=-1,yn.z*=-1),m.envMapRotation.value.setFromMatrix4(sw.makeRotationFromEuler(yn)),m.flipEnvMap.value=v.isCubeTexture&&v.isRenderTargetTexture===!1?-1:1,m.reflectivity.value=c.reflectivity,m.ior.value=c.ior,m.refractionRatio.value=c.refractionRatio),c.lightMap&&(m.lightMap.value=c.lightMap,m.lightMapIntensity.value=c.lightMapIntensity,r(c.lightMap,m.lightMapTransform)),c.aoMap&&(m.aoMap.value=c.aoMap,m.aoMapIntensity.value=c.aoMapIntensity,r(c.aoMap,m.aoMapTransform))}function s(m,c){m.diffuse.value.copy(c.color),m.opacity.value=c.opacity,c.map&&(m.map.value=c.map,r(c.map,m.mapTransform))}function o(m,c){m.dashSize.value=c.dashSize,m.totalSize.value=c.dashSize+c.gapSize,m.scale.value=c.scale}function l(m,c,g,v){m.diffuse.value.copy(c.color),m.opacity.value=c.opacity,m.size.value=c.size*g,m.scale.value=v*.5,c.map&&(m.map.value=c.map,r(c.map,m.uvTransform)),c.alphaMap&&(m.alphaMap.value=c.alphaMap,r(c.alphaMap,m.alphaMapTransform)),c.alphaTest>0&&(m.alphaTest.value=c.alphaTest)}function u(m,c){m.diffuse.value.copy(c.color),m.opacity.value=c.opacity,m.rotation.value=c.rotation,c.map&&(m.map.value=c.map,r(c.map,m.mapTransform)),c.alphaMap&&(m.alphaMap.value=c.alphaMap,r(c.alphaMap,m.alphaMapTransform)),c.alphaTest>0&&(m.alphaTest.value=c.alphaTest)}function h(m,c){m.specular.value.copy(c.specular),m.shininess.value=Math.max(c.shininess,1e-4)}function f(m,c){c.gradientMap&&(m.gradientMap.value=c.gradientMap)}function d(m,c){m.metalness.value=c.metalness,c.metalnessMap&&(m.metalnessMap.value=c.metalnessMap,r(c.metalnessMap,m.metalnessMapTransform)),m.roughness.value=c.roughness,c.roughnessMap&&(m.roughnessMap.value=c.roughnessMap,r(c.roughnessMap,m.roughnessMapTransform)),c.envMap&&(m.envMapIntensity.value=c.envMapIntensity)}function p(m,c,g){m.ior.value=c.ior,c.sheen>0&&(m.sheenColor.value.copy(c.sheenColor).multiplyScalar(c.sheen),m.sheenRoughness.value=c.sheenRoughness,c.sheenColorMap&&(m.sheenColorMap.value=c.sheenColorMap,r(c.sheenColorMap,m.sheenColorMapTransform)),c.sheenRoughnessMap&&(m.sheenRoughnessMap.value=c.sheenRoughnessMap,r(c.sheenRoughnessMap,m.sheenRoughnessMapTransform))),c.clearcoat>0&&(m.clearcoat.value=c.clearcoat,m.clearcoatRoughness.value=c.clearcoatRoughness,c.clearcoatMap&&(m.clearcoatMap.value=c.clearcoatMap,r(c.clearcoatMap,m.clearcoatMapTransform)),c.clearcoatRoughnessMap&&(m.clearcoatRoughnessMap.value=c.clearcoatRoughnessMap,r(c.clearcoatRoughnessMap,m.clearcoatRoughnessMapTransform)),c.clearcoatNormalMap&&(m.clearcoatNormalMap.value=c.clearcoatNormalMap,r(c.clearcoatNormalMap,m.clearcoatNormalMapTransform),m.clearcoatNormalScale.value.copy(c.clearcoatNormalScale),c.side===vr&&m.clearcoatNormalScale.value.negate())),c.dispersion>0&&(m.dispersion.value=c.dispersion),c.iridescence>0&&(m.iridescence.value=c.iridescence,m.iridescenceIOR.value=c.iridescenceIOR,m.iridescenceThicknessMinimum.value=c.iridescenceThicknessRange[0],m.iridescenceThicknessMaximum.value=c.iridescenceThicknessRange[1],c.iridescenceMap&&(m.iridescenceMap.value=c.iridescenceMap,r(c.iridescenceMap,m.iridescenceMapTransform)),c.iridescenceThicknessMap&&(m.iridescenceThicknessMap.value=c.iridescenceThicknessMap,r(c.iridescenceThicknessMap,m.iridescenceThicknessMapTransform))),c.transmission>0&&(m.transmission.value=c.transmission,m.transmissionSamplerMap.value=g.texture,m.transmissionSamplerSize.value.set(g.width,g.height),c.transmissionMap&&(m.transmissionMap.value=c.transmissionMap,r(c.transmissionMap,m.transmissionMapTransform)),m.thickness.value=c.thickness,c.thicknessMap&&(m.thicknessMap.value=c.thicknessMap,r(c.thicknessMap,m.thicknessMapTransform)),m.attenuationDistance.value=c.attenuationDistance,m.attenuationColor.value.copy(c.attenuationColor)),c.anisotropy>0&&(m.anisotropyVector.value.set(c.anisotropy*Math.cos(c.anisotropyRotation),c.anisotropy*Math.sin(c.anisotropyRotation)),c.anisotropyMap&&(m.anisotropyMap.value=c.anisotropyMap,r(c.anisotropyMap,m.anisotropyMapTransform))),m.specularIntensity.value=c.specularIntensity,m.specularColor.value.copy(c.specularColor),c.specularColorMap&&(m.specularColorMap.value=c.specularColorMap,r(c.specularColorMap,m.specularColorMapTransform)),c.specularIntensityMap&&(m.specularIntensityMap.value=c.specularIntensityMap,r(c.specularIntensityMap,m.specularIntensityMapTransform))}function _(m,c){c.matcap&&(m.matcap.value=c.matcap)}function x(m,c){const g=e.get(c).light;m.referencePosition.value.setFromMatrixPosition(g.matrixWorld),m.nearDistance.value=g.shadow.camera.near,m.farDistance.value=g.shadow.camera.far}return{refreshFogUniforms:i,refreshMaterialUniforms:n}}function lw(t,e,r,i){let n={},a={},s=[];const o=t.getParameter(t.MAX_UNIFORM_BUFFER_BINDINGS);function l(g,v){const M=v.program;i.uniformBlockBinding(g,M)}function u(g,v){let M=n[g.id];M===void 0&&(_(g),M=h(g),n[g.id]=M,g.addEventListener("dispose",m));const P=v.program;i.updateUBOMapping(g,P);const T=e.render.frame;a[g.id]!==T&&(d(g),a[g.id]=T)}function h(g){const v=f();g.__bindingPointIndex=v;const M=t.createBuffer(),P=g.__size,T=g.usage;return t.bindBuffer(t.UNIFORM_BUFFER,M),t.bufferData(t.UNIFORM_BUFFER,P,T),t.bindBuffer(t.UNIFORM_BUFFER,null),t.bindBufferBase(t.UNIFORM_BUFFER,v,M),M}function f(){for(let g=0;g<o;g++)if(s.indexOf(g)===-1)return s.push(g),g;return console.error("THREE.WebGLRenderer: Maximum number of simultaneously usable uniforms groups reached."),0}function d(g){const v=n[g.id],M=g.uniforms,P=g.__cache;t.bindBuffer(t.UNIFORM_BUFFER,v);for(let T=0,w=M.length;T<w;T++){const L=Array.isArray(M[T])?M[T]:[M[T]];for(let b=0,y=L.length;b<y;b++){const U=L[b];if(p(U,T,b,P)===!0){const B=U.__offset,V=Array.isArray(U.value)?U.value:[U.value];let q=0;for(let J=0;J<V.length;J++){const K=V[J],ne=x(K);typeof K=="number"||typeof K=="boolean"?(U.__data[0]=K,t.bufferSubData(t.UNIFORM_BUFFER,B+q,U.__data)):K.isMatrix3?(U.__data[0]=K.elements[0],U.__data[1]=K.elements[1],U.__data[2]=K.elements[2],U.__data[3]=0,U.__data[4]=K.elements[3],U.__data[5]=K.elements[4],U.__data[6]=K.elements[5],U.__data[7]=0,U.__data[8]=K.elements[6],U.__data[9]=K.elements[7],U.__data[10]=K.elements[8],U.__data[11]=0):(K.toArray(U.__data,q),q+=ne.storage/Float32Array.BYTES_PER_ELEMENT)}t.bufferSubData(t.UNIFORM_BUFFER,B,U.__data)}}}t.bindBuffer(t.UNIFORM_BUFFER,null)}function p(g,v,M,P){const T=g.value,w=v+"_"+M;if(P[w]===void 0)return typeof T=="number"||typeof T=="boolean"?P[w]=T:P[w]=T.clone(),!0;{const L=P[w];if(typeof T=="number"||typeof T=="boolean"){if(L!==T)return P[w]=T,!0}else if(L.equals(T)===!1)return L.copy(T),!0}return!1}function _(g){const v=g.uniforms;let M=0;const P=16;for(let w=0,L=v.length;w<L;w++){const b=Array.isArray(v[w])?v[w]:[v[w]];for(let y=0,U=b.length;y<U;y++){const B=b[y],V=Array.isArray(B.value)?B.value:[B.value];for(let q=0,J=V.length;q<J;q++){const K=V[q],ne=x(K),I=M%P;I!==0&&P-I<ne.boundary&&(M+=P-I),B.__data=new Float32Array(ne.storage/Float32Array.BYTES_PER_ELEMENT),B.__offset=M,M+=ne.storage}}}const T=M%P;return T>0&&(M+=P-T),g.__size=M,g.__cache={},this}function x(g){const v={boundary:0,storage:0};return typeof g=="number"||typeof g=="boolean"?(v.boundary=4,v.storage=4):g.isVector2?(v.boundary=8,v.storage=8):g.isVector3||g.isColor?(v.boundary=16,v.storage=12):g.isVector4?(v.boundary=16,v.storage=16):g.isMatrix3?(v.boundary=48,v.storage=48):g.isMatrix4?(v.boundary=64,v.storage=64):g.isTexture?console.warn("THREE.WebGLRenderer: Texture samplers can not be part of an uniforms group."):console.warn("THREE.WebGLRenderer: Unsupported uniform value type.",g),v}function m(g){const v=g.target;v.removeEventListener("dispose",m);const M=s.indexOf(v.__bindingPointIndex);s.splice(M,1),t.deleteBuffer(n[v.id]),delete n[v.id],delete a[v.id]}function c(){for(const g in n)t.deleteBuffer(n[g]);s=[],n={},a={}}return{bind:l,update:u,dispose:c}}class uw{constructor(e={}){const{canvas:r=tM(),context:i=null,depth:n=!0,stencil:a=!1,alpha:s=!1,antialias:o=!1,premultipliedAlpha:l=!0,preserveDrawingBuffer:u=!1,powerPreference:h="default",failIfMajorPerformanceCaveat:f=!1}=e;this.isWebGLRenderer=!0;let d;if(i!==null){if(typeof WebGLRenderingContext<"u"&&i instanceof WebGLRenderingContext)throw new Error("THREE.WebGLRenderer: WebGL 1 is not supported since r163.");d=i.getContextAttributes().alpha}else d=s;const p=new Uint32Array(4),_=new Int32Array(4);let x=null,m=null;const c=[],g=[];this.domElement=r,this.debug={checkShaderErrors:!0,onShaderError:null},this.autoClear=!0,this.autoClearColor=!0,this.autoClearDepth=!0,this.autoClearStencil=!0,this.sortObjects=!0,this.clippingPlanes=[],this.localClippingEnabled=!1,this._outputColorSpace=ei,this.toneMapping=nn,this.toneMappingExposure=1;const v=this;let M=!1,P=0,T=0,w=null,L=-1,b=null;const y=new Mt,U=new Mt;let B=null;const V=new ke(0);let q=0,J=r.width,K=r.height,ne=1,I=null,Z=null;const re=new Mt(0,0,J,K),xe=new Mt(0,0,J,K);let fe=!1;const Ue=new Rh;let Y=!1,ee=!1;const ae=new ft,ue=new O,Ce={background:null,fog:null,environment:null,overrideMaterial:null,isScene:!0};let Fe=!1;function Ze(){return w===null?ne:1}let D=i;function $e(E,k){return r.getContext(E,k)}try{const E={alpha:!0,depth:n,stencil:a,antialias:o,premultipliedAlpha:l,preserveDrawingBuffer:u,powerPreference:h,failIfMajorPerformanceCaveat:f};if("setAttribute"in r&&r.setAttribute("data-engine",`three.js r${Th}`),r.addEventListener("webglcontextlost",te,!1),r.addEventListener("webglcontextrestored",W,!1),r.addEventListener("webglcontextcreationerror",Q,!1),D===null){const k="webgl2";if(D=$e(k,E),D===null)throw $e(k)?new Error("Error creating WebGL context with your selected attributes."):new Error("Error creating WebGL context.")}}catch(E){throw console.error("THREE.WebGLRenderer: "+E.message),E}let Qe,nt,Re,Je,We,Be,dt,C,S,j,ie,le,se,Ae,me,ge,Le,he,we,Xe,De,ve,ze,Ve;function R(){Qe=new vE(D),Qe.init(),ve=new J1(D,Qe),nt=new dE(D,Qe,e,ve),Re=new $1(D),Je=new yE(D),We=new k1,Be=new Q1(D,Qe,Re,We,nt,ve,Je),dt=new fE(v),C=new gE(v),S=new AM(D),ze=new uE(D,S),j=new _E(D,S,Je,ze),ie=new SE(D,j,S,Je),we=new ME(D,nt,Be),ge=new hE(We),le=new O1(v,dt,C,Qe,nt,ze,ge),se=new ow(v,We),Ae=new z1,me=new j1(Qe),he=new lE(v,dt,C,Re,ie,d,l),Le=new Z1(v,ie,nt),Ve=new lw(D,Je,nt,Re),Xe=new cE(D,Qe,Je),De=new xE(D,Qe,Je),Je.programs=le.programs,v.capabilities=nt,v.extensions=Qe,v.properties=We,v.renderLists=Ae,v.shadowMap=Le,v.state=Re,v.info=Je}R();const A=new aw(v,D);this.xr=A,this.getContext=function(){return D},this.getContextAttributes=function(){return D.getContextAttributes()},this.forceContextLoss=function(){const E=Qe.get("WEBGL_lose_context");E&&E.loseContext()},this.forceContextRestore=function(){const E=Qe.get("WEBGL_lose_context");E&&E.restoreContext()},this.getPixelRatio=function(){return ne},this.setPixelRatio=function(E){E!==void 0&&(ne=E,this.setSize(J,K,!1))},this.getSize=function(E){return E.set(J,K)},this.setSize=function(E,k,G=!0){if(A.isPresenting){console.warn("THREE.WebGLRenderer: Can't change size while VR device is presenting.");return}J=E,K=k,r.width=Math.floor(E*ne),r.height=Math.floor(k*ne),G===!0&&(r.style.width=E+"px",r.style.height=k+"px"),this.setViewport(0,0,E,k)},this.getDrawingBufferSize=function(E){return E.set(J*ne,K*ne).floor()},this.setDrawingBufferSize=function(E,k,G){J=E,K=k,ne=G,r.width=Math.floor(E*G),r.height=Math.floor(k*G),this.setViewport(0,0,E,k)},this.getCurrentViewport=function(E){return E.copy(y)},this.getViewport=function(E){return E.copy(re)},this.setViewport=function(E,k,G,X){E.isVector4?re.set(E.x,E.y,E.z,E.w):re.set(E,k,G,X),Re.viewport(y.copy(re).multiplyScalar(ne).round())},this.getScissor=function(E){return E.copy(xe)},this.setScissor=function(E,k,G,X){E.isVector4?xe.set(E.x,E.y,E.z,E.w):xe.set(E,k,G,X),Re.scissor(U.copy(xe).multiplyScalar(ne).round())},this.getScissorTest=function(){return fe},this.setScissorTest=function(E){Re.setScissorTest(fe=E)},this.setOpaqueSort=function(E){I=E},this.setTransparentSort=function(E){Z=E},this.getClearColor=function(E){return E.copy(he.getClearColor())},this.setClearColor=function(){he.setClearColor.apply(he,arguments)},this.getClearAlpha=function(){return he.getClearAlpha()},this.setClearAlpha=function(){he.setClearAlpha.apply(he,arguments)},this.clear=function(E=!0,k=!0,G=!0){let X=0;if(E){let F=!1;if(w!==null){const de=w.texture.format;F=de===$v||de===Zv||de===Kv}if(F){const de=w.texture.type,Me=de===ln||de===Wa||de===Bl||de===ja||de===Xv||de===Yv,Ee=he.getClearColor(),Te=he.getClearAlpha(),Oe=Ee.r,je=Ee.g,Ie=Ee.b;Me?(p[0]=Oe,p[1]=je,p[2]=Ie,p[3]=Te,D.clearBufferuiv(D.COLOR,0,p)):(_[0]=Oe,_[1]=je,_[2]=Ie,_[3]=Te,D.clearBufferiv(D.COLOR,0,_))}else X|=D.COLOR_BUFFER_BIT}k&&(X|=D.DEPTH_BUFFER_BIT),G&&(X|=D.STENCIL_BUFFER_BIT,this.state.buffers.stencil.setMask(4294967295)),D.clear(X)},this.clearColor=function(){this.clear(!0,!1,!1)},this.clearDepth=function(){this.clear(!1,!0,!1)},this.clearStencil=function(){this.clear(!1,!1,!0)},this.dispose=function(){r.removeEventListener("webglcontextlost",te,!1),r.removeEventListener("webglcontextrestored",W,!1),r.removeEventListener("webglcontextcreationerror",Q,!1),Ae.dispose(),me.dispose(),We.dispose(),dt.dispose(),C.dispose(),ie.dispose(),ze.dispose(),Ve.dispose(),le.dispose(),A.dispose(),A.removeEventListener("sessionstart",$),A.removeEventListener("sessionend",N),pe.stop()};function te(E){E.preventDefault(),console.log("THREE.WebGLRenderer: Context Lost."),M=!0}function W(){console.log("THREE.WebGLRenderer: Context Restored."),M=!1;const E=Je.autoReset,k=Le.enabled,G=Le.autoUpdate,X=Le.needsUpdate,F=Le.type;R(),Je.autoReset=E,Le.enabled=k,Le.autoUpdate=G,Le.needsUpdate=X,Le.type=F}function Q(E){console.error("THREE.WebGLRenderer: A WebGL context could not be created. Reason: ",E.statusMessage)}function oe(E){const k=E.target;k.removeEventListener("dispose",oe),Se(k)}function Se(E){at(E),We.remove(E)}function at(E){const k=We.get(E).programs;k!==void 0&&(k.forEach(function(G){le.releaseProgram(G)}),E.isShaderMaterial&&le.releaseShaderCache(E))}this.renderBufferDirect=function(E,k,G,X,F,de){k===null&&(k=Ce);const Me=F.isMesh&&F.matrixWorld.determinant()<0,Ee=Wt(E,k,G,X,F);Re.setMaterial(X,Me);let Te=G.index,Oe=1;if(X.wireframe===!0){if(Te=j.getWireframeAttribute(G),Te===void 0)return;Oe=2}const je=G.drawRange,Ie=G.attributes.position;let lt=je.start*Oe,Pt=(je.start+je.count)*Oe;de!==null&&(lt=Math.max(lt,de.start*Oe),Pt=Math.min(Pt,(de.start+de.count)*Oe)),Te!==null?(lt=Math.max(lt,0),Pt=Math.min(Pt,Te.count)):Ie!=null&&(lt=Math.max(lt,0),Pt=Math.min(Pt,Ie.count));const At=Pt-lt;if(At<0||At===1/0)return;ze.setup(F,X,Ee,G,Te);let It,St=Xe;if(Te!==null&&(It=S.get(Te),St=De,St.setIndex(It)),F.isMesh)X.wireframe===!0?(Re.setLineWidth(X.wireframeLinewidth*Ze()),St.setMode(D.LINES)):St.setMode(D.TRIANGLES);else if(F.isLine){let Pe=X.linewidth;Pe===void 0&&(Pe=1),Re.setLineWidth(Pe*Ze()),F.isLineSegments?St.setMode(D.LINES):F.isLineLoop?St.setMode(D.LINE_LOOP):St.setMode(D.LINE_STRIP)}else F.isPoints?St.setMode(D.POINTS):F.isSprite&&St.setMode(D.TRIANGLES);if(F.isBatchedMesh)F._multiDrawInstances!==null?St.renderMultiDrawInstances(F._multiDrawStarts,F._multiDrawCounts,F._multiDrawCount,F._multiDrawInstances):St.renderMultiDraw(F._multiDrawStarts,F._multiDrawCounts,F._multiDrawCount);else if(F.isInstancedMesh)St.renderInstances(lt,At,F.count);else if(G.isInstancedBufferGeometry){const Pe=G._maxInstanceCount!==void 0?G._maxInstanceCount:1/0,_r=Math.min(G.instanceCount,Pe);St.renderInstances(lt,At,_r)}else St.render(lt,At)};function ht(E,k,G){E.transparent===!0&&E.side===jr&&E.forceSinglePass===!1?(E.side=vr,E.needsUpdate=!0,tt(E,k,G),E.side=on,E.needsUpdate=!0,tt(E,k,G),E.side=jr):tt(E,k,G)}this.compile=function(E,k,G=null){G===null&&(G=E),m=me.get(G),m.init(k),g.push(m),G.traverseVisible(function(F){F.isLight&&F.layers.test(k.layers)&&(m.pushLight(F),F.castShadow&&m.pushShadow(F))}),E!==G&&E.traverseVisible(function(F){F.isLight&&F.layers.test(k.layers)&&(m.pushLight(F),F.castShadow&&m.pushShadow(F))}),m.setupLights();const X=new Set;return E.traverse(function(F){const de=F.material;if(de)if(Array.isArray(de))for(let Me=0;Me<de.length;Me++){const Ee=de[Me];ht(Ee,G,F),X.add(Ee)}else ht(de,G,F),X.add(de)}),g.pop(),m=null,X},this.compileAsync=function(E,k,G=null){const X=this.compile(E,k,G);return new Promise(F=>{function de(){if(X.forEach(function(Me){We.get(Me).currentProgram.isReady()&&X.delete(Me)}),X.size===0){F(E);return}setTimeout(de,10)}Qe.get("KHR_parallel_shader_compile")!==null?de():setTimeout(de,10)})};let z=null;function H(E){z&&z(E)}function $(){pe.stop()}function N(){pe.start()}const pe=new c_;pe.setAnimationLoop(H),typeof self<"u"&&pe.setContext(self),this.setAnimationLoop=function(E){z=E,A.setAnimationLoop(E),E===null?pe.stop():pe.start()},A.addEventListener("sessionstart",$),A.addEventListener("sessionend",N),this.render=function(E,k){if(k!==void 0&&k.isCamera!==!0){console.error("THREE.WebGLRenderer.render: camera is not an instance of THREE.Camera.");return}if(M===!0)return;if(E.matrixWorldAutoUpdate===!0&&E.updateMatrixWorld(),k.parent===null&&k.matrixWorldAutoUpdate===!0&&k.updateMatrixWorld(),A.enabled===!0&&A.isPresenting===!0&&(A.cameraAutoUpdate===!0&&A.updateCamera(k),k=A.getCamera()),E.isScene===!0&&E.onBeforeRender(v,E,k,w),m=me.get(E,g.length),m.init(k),g.push(m),ae.multiplyMatrices(k.projectionMatrix,k.matrixWorldInverse),Ue.setFromProjectionMatrix(ae),ee=this.localClippingEnabled,Y=ge.init(this.clippingPlanes,ee),x=Ae.get(E,c.length),x.init(),c.push(x),A.enabled===!0&&A.isPresenting===!0){const de=v.xr.getDepthSensingMesh();de!==null&&be(de,k,-1/0,v.sortObjects)}be(E,k,0,v.sortObjects),x.finish(),v.sortObjects===!0&&x.sort(I,Z),Fe=A.enabled===!1||A.isPresenting===!1||A.hasDepthSensing()===!1,Fe&&he.addToRenderList(x,E),this.info.render.frame++,Y===!0&&ge.beginShadows();const G=m.state.shadowsArray;Le.render(G,E,k),Y===!0&&ge.endShadows(),this.info.autoReset===!0&&this.info.reset();const X=x.opaque,F=x.transmissive;if(m.setupLights(),k.isArrayCamera){const de=k.cameras;if(F.length>0)for(let Me=0,Ee=de.length;Me<Ee;Me++){const Te=de[Me];He(X,F,E,Te)}Fe&&he.render(E);for(let Me=0,Ee=de.length;Me<Ee;Me++){const Te=de[Me];Ge(x,E,Te,Te.viewport)}}else F.length>0&&He(X,F,E,k),Fe&&he.render(E),Ge(x,E,k);w!==null&&(Be.updateMultisampleRenderTarget(w),Be.updateRenderTargetMipmap(w)),E.isScene===!0&&E.onAfterRender(v,E,k),ze.resetDefaultState(),L=-1,b=null,g.pop(),g.length>0?(m=g[g.length-1],Y===!0&&ge.setGlobalState(v.clippingPlanes,m.state.camera)):m=null,c.pop(),c.length>0?x=c[c.length-1]:x=null};function be(E,k,G,X){if(E.visible===!1)return;if(E.layers.test(k.layers)){if(E.isGroup)G=E.renderOrder;else if(E.isLOD)E.autoUpdate===!0&&E.update(k);else if(E.isLight)m.pushLight(E),E.castShadow&&m.pushShadow(E);else if(E.isSprite){if(!E.frustumCulled||Ue.intersectsSprite(E)){X&&ue.setFromMatrixPosition(E.matrixWorld).applyMatrix4(ae);const de=ie.update(E),Me=E.material;Me.visible&&x.push(E,de,Me,G,ue.z,null)}}else if((E.isMesh||E.isLine||E.isPoints)&&(!E.frustumCulled||Ue.intersectsObject(E))){const de=ie.update(E),Me=E.material;if(X&&(E.boundingSphere!==void 0?(E.boundingSphere===null&&E.computeBoundingSphere(),ue.copy(E.boundingSphere.center)):(de.boundingSphere===null&&de.computeBoundingSphere(),ue.copy(de.boundingSphere.center)),ue.applyMatrix4(E.matrixWorld).applyMatrix4(ae)),Array.isArray(Me)){const Ee=de.groups;for(let Te=0,Oe=Ee.length;Te<Oe;Te++){const je=Ee[Te],Ie=Me[je.materialIndex];Ie&&Ie.visible&&x.push(E,de,Ie,G,ue.z,je)}}else Me.visible&&x.push(E,de,Me,G,ue.z,null)}}const F=E.children;for(let de=0,Me=F.length;de<Me;de++)be(F[de],k,G,X)}function Ge(E,k,G,X){const F=E.opaque,de=E.transmissive,Me=E.transparent;m.setupLightsView(G),Y===!0&&ge.setGlobalState(v.clippingPlanes,G),X&&Re.viewport(y.copy(X)),F.length>0&&Ye(F,k,G),de.length>0&&Ye(de,k,G),Me.length>0&&Ye(Me,k,G),Re.buffers.depth.setTest(!0),Re.buffers.depth.setMask(!0),Re.buffers.color.setMask(!0),Re.setPolygonOffset(!1)}function He(E,k,G,X){if((G.isScene===!0?G.overrideMaterial:null)!==null)return;m.state.transmissionRenderTarget[X.id]===void 0&&(m.state.transmissionRenderTarget[X.id]=new zn(1,1,{generateMipmaps:!0,type:Qe.has("EXT_color_buffer_half_float")||Qe.has("EXT_color_buffer_float")?fu:ln,minFilter:Ln,samples:4,stencilBuffer:a,resolveDepthBuffer:!1,resolveStencilBuffer:!1,colorSpace:ut.workingColorSpace}));const F=m.state.transmissionRenderTarget[X.id],de=X.viewport||y;F.setSize(de.z,de.w);const Me=v.getRenderTarget();v.setRenderTarget(F),v.getClearColor(V),q=v.getClearAlpha(),q<1&&v.setClearColor(16777215,.5),Fe?he.render(G):v.clear();const Ee=v.toneMapping;v.toneMapping=nn;const Te=X.viewport;if(X.viewport!==void 0&&(X.viewport=void 0),m.setupLightsView(X),Y===!0&&ge.setGlobalState(v.clippingPlanes,X),Ye(E,G,X),Be.updateMultisampleRenderTarget(F),Be.updateRenderTargetMipmap(F),Qe.has("WEBGL_multisampled_render_to_texture")===!1){let Oe=!1;for(let je=0,Ie=k.length;je<Ie;je++){const lt=k[je],Pt=lt.object,At=lt.geometry,It=lt.material,St=lt.group;if(It.side===jr&&Pt.layers.test(X.layers)){const Pe=It.side;It.side=vr,It.needsUpdate=!0,rt(Pt,G,X,At,It,St),It.side=Pe,It.needsUpdate=!0,Oe=!0}}Oe===!0&&(Be.updateMultisampleRenderTarget(F),Be.updateRenderTargetMipmap(F))}v.setRenderTarget(Me),v.setClearColor(V,q),Te!==void 0&&(X.viewport=Te),v.toneMapping=Ee}function Ye(E,k,G){const X=k.isScene===!0?k.overrideMaterial:null;for(let F=0,de=E.length;F<de;F++){const Me=E[F],Ee=Me.object,Te=Me.geometry,Oe=X===null?Me.material:X,je=Me.group;Ee.layers.test(G.layers)&&rt(Ee,k,G,Te,Oe,je)}}function rt(E,k,G,X,F,de){E.onBeforeRender(v,k,G,X,F,de),E.modelViewMatrix.multiplyMatrices(G.matrixWorldInverse,E.matrixWorld),E.normalMatrix.getNormalMatrix(E.modelViewMatrix),F.onBeforeRender(v,k,G,X,E,de),F.transparent===!0&&F.side===jr&&F.forceSinglePass===!1?(F.side=vr,F.needsUpdate=!0,v.renderBufferDirect(G,k,X,F,E,de),F.side=on,F.needsUpdate=!0,v.renderBufferDirect(G,k,X,F,E,de),F.side=jr):v.renderBufferDirect(G,k,X,F,E,de),E.onAfterRender(v,k,G,X,F,de)}function tt(E,k,G){k.isScene!==!0&&(k=Ce);const X=We.get(E),F=m.state.lights,de=m.state.shadowsArray,Me=F.state.version,Ee=le.getParameters(E,F.state,de,k,G),Te=le.getProgramCacheKey(Ee);let Oe=X.programs;X.environment=E.isMeshStandardMaterial?k.environment:null,X.fog=k.fog,X.envMap=(E.isMeshStandardMaterial?C:dt).get(E.envMap||X.environment),X.envMapRotation=X.environment!==null&&E.envMap===null?k.environmentRotation:E.envMapRotation,Oe===void 0&&(E.addEventListener("dispose",oe),Oe=new Map,X.programs=Oe);let je=Oe.get(Te);if(je!==void 0){if(X.currentProgram===je&&X.lightsStateVersion===Me)return Gt(E,Ee),je}else Ee.uniforms=le.getUniforms(E),E.onBuild(G,Ee,v),E.onBeforeCompile(Ee,v),je=le.acquireProgram(Ee,Te),Oe.set(Te,je),X.uniforms=Ee.uniforms;const Ie=X.uniforms;return(!E.isShaderMaterial&&!E.isRawShaderMaterial||E.clipping===!0)&&(Ie.clippingPlanes=ge.uniform),Gt(E,Ee),X.needsLights=ot(E),X.lightsStateVersion=Me,X.needsLights&&(Ie.ambientLightColor.value=F.state.ambient,Ie.lightProbe.value=F.state.probe,Ie.directionalLights.value=F.state.directional,Ie.directionalLightShadows.value=F.state.directionalShadow,Ie.spotLights.value=F.state.spot,Ie.spotLightShadows.value=F.state.spotShadow,Ie.rectAreaLights.value=F.state.rectArea,Ie.ltc_1.value=F.state.rectAreaLTC1,Ie.ltc_2.value=F.state.rectAreaLTC2,Ie.pointLights.value=F.state.point,Ie.pointLightShadows.value=F.state.pointShadow,Ie.hemisphereLights.value=F.state.hemi,Ie.directionalShadowMap.value=F.state.directionalShadowMap,Ie.directionalShadowMatrix.value=F.state.directionalShadowMatrix,Ie.spotShadowMap.value=F.state.spotShadowMap,Ie.spotLightMatrix.value=F.state.spotLightMatrix,Ie.spotLightMap.value=F.state.spotLightMap,Ie.pointShadowMap.value=F.state.pointShadowMap,Ie.pointShadowMatrix.value=F.state.pointShadowMatrix),X.currentProgram=je,X.uniformsList=null,je}function st(E){if(E.uniformsList===null){const k=E.currentProgram.getUniforms();E.uniformsList=pl.seqWithValue(k.seq,E.uniforms)}return E.uniformsList}function Gt(E,k){const G=We.get(E);G.outputColorSpace=k.outputColorSpace,G.batching=k.batching,G.batchingColor=k.batchingColor,G.instancing=k.instancing,G.instancingColor=k.instancingColor,G.instancingMorph=k.instancingMorph,G.skinning=k.skinning,G.morphTargets=k.morphTargets,G.morphNormals=k.morphNormals,G.morphColors=k.morphColors,G.morphTargetsCount=k.morphTargetsCount,G.numClippingPlanes=k.numClippingPlanes,G.numIntersection=k.numClipIntersection,G.vertexAlphas=k.vertexAlphas,G.vertexTangents=k.vertexTangents,G.toneMapping=k.toneMapping}function Wt(E,k,G,X,F){k.isScene!==!0&&(k=Ce),Be.resetTextureUnits();const de=k.fog,Me=X.isMeshStandardMaterial?k.environment:null,Ee=w===null?v.outputColorSpace:w.isXRRenderTarget===!0?w.texture.colorSpace:fn,Te=(X.isMeshStandardMaterial?C:dt).get(X.envMap||Me),Oe=X.vertexColors===!0&&!!G.attributes.color&&G.attributes.color.itemSize===4,je=!!G.attributes.tangent&&(!!X.normalMap||X.anisotropy>0),Ie=!!G.morphAttributes.position,lt=!!G.morphAttributes.normal,Pt=!!G.morphAttributes.color;let At=nn;X.toneMapped&&(w===null||w.isXRRenderTarget===!0)&&(At=v.toneMapping);const It=G.morphAttributes.position||G.morphAttributes.normal||G.morphAttributes.color,St=It!==void 0?It.length:0,Pe=We.get(X),_r=m.state.lights;if(Y===!0&&(ee===!0||E!==b)){const Cr=E===b&&X.id===L;ge.setState(X,E,Cr)}let es=!1;X.version===Pe.__version?(Pe.needsLights&&Pe.lightsStateVersion!==_r.state.version||Pe.outputColorSpace!==Ee||F.isBatchedMesh&&Pe.batching===!1||!F.isBatchedMesh&&Pe.batching===!0||F.isBatchedMesh&&Pe.batchingColor===!0&&F.colorTexture===null||F.isBatchedMesh&&Pe.batchingColor===!1&&F.colorTexture!==null||F.isInstancedMesh&&Pe.instancing===!1||!F.isInstancedMesh&&Pe.instancing===!0||F.isSkinnedMesh&&Pe.skinning===!1||!F.isSkinnedMesh&&Pe.skinning===!0||F.isInstancedMesh&&Pe.instancingColor===!0&&F.instanceColor===null||F.isInstancedMesh&&Pe.instancingColor===!1&&F.instanceColor!==null||F.isInstancedMesh&&Pe.instancingMorph===!0&&F.morphTexture===null||F.isInstancedMesh&&Pe.instancingMorph===!1&&F.morphTexture!==null||Pe.envMap!==Te||X.fog===!0&&Pe.fog!==de||Pe.numClippingPlanes!==void 0&&(Pe.numClippingPlanes!==ge.numPlanes||Pe.numIntersection!==ge.numIntersection)||Pe.vertexAlphas!==Oe||Pe.vertexTangents!==je||Pe.morphTargets!==Ie||Pe.morphNormals!==lt||Pe.morphColors!==Pt||Pe.toneMapping!==At||Pe.morphTargetsCount!==St)&&(es=!0):(es=!0,Pe.__version=X.version);let li=Pe.currentProgram;es===!0&&(li=tt(X,k,F));let so=!1,pn=!1,_u=!1;const zt=li.getUniforms(),Pi=Pe.uniforms;if(Re.useProgram(li.program)&&(so=!0,pn=!0,_u=!0),X.id!==L&&(L=X.id,pn=!0),so||b!==E){zt.setValue(D,"projectionMatrix",E.projectionMatrix),zt.setValue(D,"viewMatrix",E.matrixWorldInverse);const Cr=zt.map.cameraPosition;Cr!==void 0&&Cr.setValue(D,ue.setFromMatrixPosition(E.matrixWorld)),nt.logarithmicDepthBuffer&&zt.setValue(D,"logDepthBufFC",2/(Math.log(E.far+1)/Math.LN2)),(X.isMeshPhongMaterial||X.isMeshToonMaterial||X.isMeshLambertMaterial||X.isMeshBasicMaterial||X.isMeshStandardMaterial||X.isShaderMaterial)&&zt.setValue(D,"isOrthographic",E.isOrthographicCamera===!0),b!==E&&(b=E,pn=!0,_u=!0)}if(F.isSkinnedMesh){zt.setOptional(D,F,"bindMatrix"),zt.setOptional(D,F,"bindMatrixInverse");const Cr=F.skeleton;Cr&&(Cr.boneTexture===null&&Cr.computeBoneTexture(),zt.setValue(D,"boneTexture",Cr.boneTexture,Be))}F.isBatchedMesh&&(zt.setOptional(D,F,"batchingTexture"),zt.setValue(D,"batchingTexture",F._matricesTexture,Be),zt.setOptional(D,F,"batchingColorTexture"),F._colorsTexture!==null&&zt.setValue(D,"batchingColorTexture",F._colorsTexture,Be));const xu=G.morphAttributes;if((xu.position!==void 0||xu.normal!==void 0||xu.color!==void 0)&&we.update(F,G,li),(pn||Pe.receiveShadow!==F.receiveShadow)&&(Pe.receiveShadow=F.receiveShadow,zt.setValue(D,"receiveShadow",F.receiveShadow)),X.isMeshGouraudMaterial&&X.envMap!==null&&(Pi.envMap.value=Te,Pi.flipEnvMap.value=Te.isCubeTexture&&Te.isRenderTargetTexture===!1?-1:1),X.isMeshStandardMaterial&&X.envMap===null&&k.environment!==null&&(Pi.envMapIntensity.value=k.environmentIntensity),pn&&(zt.setValue(D,"toneMappingExposure",v.toneMappingExposure),Pe.needsLights&&pt(Pi,_u),de&&X.fog===!0&&se.refreshFogUniforms(Pi,de),se.refreshMaterialUniforms(Pi,X,ne,K,m.state.transmissionRenderTarget[E.id]),pl.upload(D,st(Pe),Pi,Be)),X.isShaderMaterial&&X.uniformsNeedUpdate===!0&&(pl.upload(D,st(Pe),Pi,Be),X.uniformsNeedUpdate=!1),X.isSpriteMaterial&&zt.setValue(D,"center",F.center),zt.setValue(D,"modelViewMatrix",F.modelViewMatrix),zt.setValue(D,"normalMatrix",F.normalMatrix),zt.setValue(D,"modelMatrix",F.matrixWorld),X.isShaderMaterial||X.isRawShaderMaterial){const Cr=X.uniformsGroups;for(let yu=0,w_=Cr.length;yu<w_;yu++){const Uh=Cr[yu];Ve.update(Uh,li),Ve.bind(Uh,li)}}return li}function pt(E,k){E.ambientLightColor.needsUpdate=k,E.lightProbe.needsUpdate=k,E.directionalLights.needsUpdate=k,E.directionalLightShadows.needsUpdate=k,E.pointLights.needsUpdate=k,E.pointLightShadows.needsUpdate=k,E.spotLights.needsUpdate=k,E.spotLightShadows.needsUpdate=k,E.rectAreaLights.needsUpdate=k,E.hemisphereLights.needsUpdate=k}function ot(E){return E.isMeshLambertMaterial||E.isMeshToonMaterial||E.isMeshPhongMaterial||E.isMeshStandardMaterial||E.isShadowMaterial||E.isShaderMaterial&&E.lights===!0}this.getActiveCubeFace=function(){return P},this.getActiveMipmapLevel=function(){return T},this.getRenderTarget=function(){return w},this.setRenderTargetTextures=function(E,k,G){We.get(E.texture).__webglTexture=k,We.get(E.depthTexture).__webglTexture=G;const X=We.get(E);X.__hasExternalTextures=!0,X.__autoAllocateDepthBuffer=G===void 0,X.__autoAllocateDepthBuffer||Qe.has("WEBGL_multisampled_render_to_texture")===!0&&(console.warn("THREE.WebGLRenderer: Render-to-texture extension was disabled because an external texture was provided"),X.__useRenderToTexture=!1)},this.setRenderTargetFramebuffer=function(E,k){const G=We.get(E);G.__webglFramebuffer=k,G.__useDefaultFramebuffer=k===void 0},this.setRenderTarget=function(E,k=0,G=0){w=E,P=k,T=G;let X=!0,F=null,de=!1,Me=!1;if(E){const Ee=We.get(E);Ee.__useDefaultFramebuffer!==void 0?(Re.bindFramebuffer(D.FRAMEBUFFER,null),X=!1):Ee.__webglFramebuffer===void 0?Be.setupRenderTarget(E):Ee.__hasExternalTextures&&Be.rebindTextures(E,We.get(E.texture).__webglTexture,We.get(E.depthTexture).__webglTexture);const Te=E.texture;(Te.isData3DTexture||Te.isDataArrayTexture||Te.isCompressedArrayTexture)&&(Me=!0);const Oe=We.get(E).__webglFramebuffer;E.isWebGLCubeRenderTarget?(Array.isArray(Oe[k])?F=Oe[k][G]:F=Oe[k],de=!0):E.samples>0&&Be.useMultisampledRTT(E)===!1?F=We.get(E).__webglMultisampledFramebuffer:Array.isArray(Oe)?F=Oe[G]:F=Oe,y.copy(E.viewport),U.copy(E.scissor),B=E.scissorTest}else y.copy(re).multiplyScalar(ne).floor(),U.copy(xe).multiplyScalar(ne).floor(),B=fe;if(Re.bindFramebuffer(D.FRAMEBUFFER,F)&&X&&Re.drawBuffers(E,F),Re.viewport(y),Re.scissor(U),Re.setScissorTest(B),de){const Ee=We.get(E.texture);D.framebufferTexture2D(D.FRAMEBUFFER,D.COLOR_ATTACHMENT0,D.TEXTURE_CUBE_MAP_POSITIVE_X+k,Ee.__webglTexture,G)}else if(Me){const Ee=We.get(E.texture),Te=k||0;D.framebufferTextureLayer(D.FRAMEBUFFER,D.COLOR_ATTACHMENT0,Ee.__webglTexture,G||0,Te)}L=-1},this.readRenderTargetPixels=function(E,k,G,X,F,de,Me){if(!(E&&E.isWebGLRenderTarget)){console.error("THREE.WebGLRenderer.readRenderTargetPixels: renderTarget is not THREE.WebGLRenderTarget.");return}let Ee=We.get(E).__webglFramebuffer;if(E.isWebGLCubeRenderTarget&&Me!==void 0&&(Ee=Ee[Me]),Ee){Re.bindFramebuffer(D.FRAMEBUFFER,Ee);try{const Te=E.texture,Oe=Te.format,je=Te.type;if(!nt.textureFormatReadable(Oe)){console.error("THREE.WebGLRenderer.readRenderTargetPixels: renderTarget is not in RGBA or implementation defined format.");return}if(!nt.textureTypeReadable(je)){console.error("THREE.WebGLRenderer.readRenderTargetPixels: renderTarget is not in UnsignedByteType or implementation defined type.");return}k>=0&&k<=E.width-X&&G>=0&&G<=E.height-F&&D.readPixels(k,G,X,F,ve.convert(Oe),ve.convert(je),de)}finally{const Te=w!==null?We.get(w).__webglFramebuffer:null;Re.bindFramebuffer(D.FRAMEBUFFER,Te)}}},this.readRenderTargetPixelsAsync=async function(E,k,G,X,F,de,Me){if(!(E&&E.isWebGLRenderTarget))throw new Error("THREE.WebGLRenderer.readRenderTargetPixels: renderTarget is not THREE.WebGLRenderTarget.");let Ee=We.get(E).__webglFramebuffer;if(E.isWebGLCubeRenderTarget&&Me!==void 0&&(Ee=Ee[Me]),Ee){Re.bindFramebuffer(D.FRAMEBUFFER,Ee);try{const Te=E.texture,Oe=Te.format,je=Te.type;if(!nt.textureFormatReadable(Oe))throw new Error("THREE.WebGLRenderer.readRenderTargetPixelsAsync: renderTarget is not in RGBA or implementation defined format.");if(!nt.textureTypeReadable(je))throw new Error("THREE.WebGLRenderer.readRenderTargetPixelsAsync: renderTarget is not in UnsignedByteType or implementation defined type.");if(k>=0&&k<=E.width-X&&G>=0&&G<=E.height-F){const Ie=D.createBuffer();D.bindBuffer(D.PIXEL_PACK_BUFFER,Ie),D.bufferData(D.PIXEL_PACK_BUFFER,de.byteLength,D.STREAM_READ),D.readPixels(k,G,X,F,ve.convert(Oe),ve.convert(je),0),D.flush();const lt=D.fenceSync(D.SYNC_GPU_COMMANDS_COMPLETE,0);await rM(D,lt,4);try{D.bindBuffer(D.PIXEL_PACK_BUFFER,Ie),D.getBufferSubData(D.PIXEL_PACK_BUFFER,0,de)}finally{D.deleteBuffer(Ie),D.deleteSync(lt)}return de}}finally{const Te=w!==null?We.get(w).__webglFramebuffer:null;Re.bindFramebuffer(D.FRAMEBUFFER,Te)}}},this.copyFramebufferToTexture=function(E,k=null,G=0){E.isTexture!==!0&&(console.warn("WebGLRenderer: copyFramebufferToTexture function signature has changed."),k=arguments[0]||null,E=arguments[1]);const X=Math.pow(2,-G),F=Math.floor(E.image.width*X),de=Math.floor(E.image.height*X),Me=k!==null?k.x:0,Ee=k!==null?k.y:0;Be.setTexture2D(E,0),D.copyTexSubImage2D(D.TEXTURE_2D,G,0,0,Me,Ee,F,de),Re.unbindTexture()},this.copyTextureToTexture=function(E,k,G=null,X=null,F=0){E.isTexture!==!0&&(console.warn("WebGLRenderer: copyTextureToTexture function signature has changed."),X=arguments[0]||null,E=arguments[1],k=arguments[2],F=arguments[3]||0,G=null);let de,Me,Ee,Te,Oe,je;G!==null?(de=G.max.x-G.min.x,Me=G.max.y-G.min.y,Ee=G.min.x,Te=G.min.y):(de=E.image.width,Me=E.image.height,Ee=0,Te=0),X!==null?(Oe=X.x,je=X.y):(Oe=0,je=0);const Ie=ve.convert(k.format),lt=ve.convert(k.type);Be.setTexture2D(k,0),D.pixelStorei(D.UNPACK_FLIP_Y_WEBGL,k.flipY),D.pixelStorei(D.UNPACK_PREMULTIPLY_ALPHA_WEBGL,k.premultiplyAlpha),D.pixelStorei(D.UNPACK_ALIGNMENT,k.unpackAlignment);const Pt=D.getParameter(D.UNPACK_ROW_LENGTH),At=D.getParameter(D.UNPACK_IMAGE_HEIGHT),It=D.getParameter(D.UNPACK_SKIP_PIXELS),St=D.getParameter(D.UNPACK_SKIP_ROWS),Pe=D.getParameter(D.UNPACK_SKIP_IMAGES),_r=E.isCompressedTexture?E.mipmaps[F]:E.image;D.pixelStorei(D.UNPACK_ROW_LENGTH,_r.width),D.pixelStorei(D.UNPACK_IMAGE_HEIGHT,_r.height),D.pixelStorei(D.UNPACK_SKIP_PIXELS,Ee),D.pixelStorei(D.UNPACK_SKIP_ROWS,Te),E.isDataTexture?D.texSubImage2D(D.TEXTURE_2D,F,Oe,je,de,Me,Ie,lt,_r.data):E.isCompressedTexture?D.compressedTexSubImage2D(D.TEXTURE_2D,F,Oe,je,_r.width,_r.height,Ie,_r.data):D.texSubImage2D(D.TEXTURE_2D,F,Oe,je,Ie,lt,_r),D.pixelStorei(D.UNPACK_ROW_LENGTH,Pt),D.pixelStorei(D.UNPACK_IMAGE_HEIGHT,At),D.pixelStorei(D.UNPACK_SKIP_PIXELS,It),D.pixelStorei(D.UNPACK_SKIP_ROWS,St),D.pixelStorei(D.UNPACK_SKIP_IMAGES,Pe),F===0&&k.generateMipmaps&&D.generateMipmap(D.TEXTURE_2D),Re.unbindTexture()},this.copyTextureToTexture3D=function(E,k,G=null,X=null,F=0){E.isTexture!==!0&&(console.warn("WebGLRenderer: copyTextureToTexture3D function signature has changed."),G=arguments[0]||null,X=arguments[1]||null,E=arguments[2],k=arguments[3],F=arguments[4]||0);let de,Me,Ee,Te,Oe,je,Ie,lt,Pt;const At=E.isCompressedTexture?E.mipmaps[F]:E.image;G!==null?(de=G.max.x-G.min.x,Me=G.max.y-G.min.y,Ee=G.max.z-G.min.z,Te=G.min.x,Oe=G.min.y,je=G.min.z):(de=At.width,Me=At.height,Ee=At.depth,Te=0,Oe=0,je=0),X!==null?(Ie=X.x,lt=X.y,Pt=X.z):(Ie=0,lt=0,Pt=0);const It=ve.convert(k.format),St=ve.convert(k.type);let Pe;if(k.isData3DTexture)Be.setTexture3D(k,0),Pe=D.TEXTURE_3D;else if(k.isDataArrayTexture||k.isCompressedArrayTexture)Be.setTexture2DArray(k,0),Pe=D.TEXTURE_2D_ARRAY;else{console.warn("THREE.WebGLRenderer.copyTextureToTexture3D: only supports THREE.DataTexture3D and THREE.DataTexture2DArray.");return}D.pixelStorei(D.UNPACK_FLIP_Y_WEBGL,k.flipY),D.pixelStorei(D.UNPACK_PREMULTIPLY_ALPHA_WEBGL,k.premultiplyAlpha),D.pixelStorei(D.UNPACK_ALIGNMENT,k.unpackAlignment);const _r=D.getParameter(D.UNPACK_ROW_LENGTH),es=D.getParameter(D.UNPACK_IMAGE_HEIGHT),li=D.getParameter(D.UNPACK_SKIP_PIXELS),so=D.getParameter(D.UNPACK_SKIP_ROWS),pn=D.getParameter(D.UNPACK_SKIP_IMAGES);D.pixelStorei(D.UNPACK_ROW_LENGTH,At.width),D.pixelStorei(D.UNPACK_IMAGE_HEIGHT,At.height),D.pixelStorei(D.UNPACK_SKIP_PIXELS,Te),D.pixelStorei(D.UNPACK_SKIP_ROWS,Oe),D.pixelStorei(D.UNPACK_SKIP_IMAGES,je),E.isDataTexture||E.isData3DTexture?D.texSubImage3D(Pe,F,Ie,lt,Pt,de,Me,Ee,It,St,At.data):k.isCompressedArrayTexture?D.compressedTexSubImage3D(Pe,F,Ie,lt,Pt,de,Me,Ee,It,At.data):D.texSubImage3D(Pe,F,Ie,lt,Pt,de,Me,Ee,It,St,At),D.pixelStorei(D.UNPACK_ROW_LENGTH,_r),D.pixelStorei(D.UNPACK_IMAGE_HEIGHT,es),D.pixelStorei(D.UNPACK_SKIP_PIXELS,li),D.pixelStorei(D.UNPACK_SKIP_ROWS,so),D.pixelStorei(D.UNPACK_SKIP_IMAGES,pn),F===0&&k.generateMipmaps&&D.generateMipmap(Pe),Re.unbindTexture()},this.initRenderTarget=function(E){We.get(E).__webglFramebuffer===void 0&&Be.setupRenderTarget(E)},this.initTexture=function(E){E.isCubeTexture?Be.setTextureCube(E,0):E.isData3DTexture?Be.setTexture3D(E,0):E.isDataArrayTexture||E.isCompressedArrayTexture?Be.setTexture2DArray(E,0):Be.setTexture2D(E,0),Re.unbindTexture()},this.resetState=function(){P=0,T=0,w=null,Re.reset(),ze.reset()},typeof __THREE_DEVTOOLS__<"u"&&__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("observe",{detail:this}))}get coordinateSystem(){return Si}get outputColorSpace(){return this._outputColorSpace}set outputColorSpace(e){this._outputColorSpace=e;const r=this.getContext();r.drawingBufferColorSpace=e===Ah?"display-p3":"srgb",r.unpackColorSpace=ut.workingColorSpace===pu?"display-p3":"srgb"}}class Lh{constructor(e,r=25e-5){this.isFogExp2=!0,this.name="",this.color=new ke(e),this.density=r}clone(){return new Lh(this.color,this.density)}toJSON(){return{type:"FogExp2",name:this.name,color:this.color.getHex(),density:this.density}}}class cw extends Rt{constructor(){super(),this.isScene=!0,this.type="Scene",this.background=null,this.environment=null,this.fog=null,this.backgroundBlurriness=0,this.backgroundIntensity=1,this.backgroundRotation=new oi,this.environmentIntensity=1,this.environmentRotation=new oi,this.overrideMaterial=null,typeof __THREE_DEVTOOLS__<"u"&&__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("observe",{detail:this}))}copy(e,r){return super.copy(e,r),e.background!==null&&(this.background=e.background.clone()),e.environment!==null&&(this.environment=e.environment.clone()),e.fog!==null&&(this.fog=e.fog.clone()),this.backgroundBlurriness=e.backgroundBlurriness,this.backgroundIntensity=e.backgroundIntensity,this.backgroundRotation.copy(e.backgroundRotation),this.environmentIntensity=e.environmentIntensity,this.environmentRotation.copy(e.environmentRotation),e.overrideMaterial!==null&&(this.overrideMaterial=e.overrideMaterial.clone()),this.matrixAutoUpdate=e.matrixAutoUpdate,this}toJSON(e){const r=super.toJSON(e);return this.fog!==null&&(r.object.fog=this.fog.toJSON()),this.backgroundBlurriness>0&&(r.object.backgroundBlurriness=this.backgroundBlurriness),this.backgroundIntensity!==1&&(r.object.backgroundIntensity=this.backgroundIntensity),r.object.backgroundRotation=this.backgroundRotation.toArray(),this.environmentIntensity!==1&&(r.object.environmentIntensity=this.environmentIntensity),r.object.environmentRotation=this.environmentRotation.toArray(),r}}class dw extends sr{constructor(e=null,r=1,i=1,n,a,s,o,l,u=fr,h=fr,f,d){super(null,s,o,l,u,h,n,a,f,d),this.isDataTexture=!0,this.image={data:e,width:r,height:i},this.generateMipmaps=!1,this.flipY=!1,this.unpackAlignment=1}}class um extends Kr{constructor(e,r,i,n=1){super(e,r,i),this.isInstancedBufferAttribute=!0,this.meshPerAttribute=n}copy(e){return super.copy(e),this.meshPerAttribute=e.meshPerAttribute,this}toJSON(){const e=super.toJSON();return e.meshPerAttribute=this.meshPerAttribute,e.isInstancedBufferAttribute=!0,e}}const ua=new ft,cm=new ft,Yo=[],dm=new Wn,hw=new ft,ps=new mt,ms=new $a;class Tc extends mt{constructor(e,r,i){super(e,r),this.isInstancedMesh=!0,this.instanceMatrix=new um(new Float32Array(i*16),16),this.instanceColor=null,this.morphTexture=null,this.count=i,this.boundingBox=null,this.boundingSphere=null;for(let n=0;n<i;n++)this.setMatrixAt(n,hw)}computeBoundingBox(){const e=this.geometry,r=this.count;this.boundingBox===null&&(this.boundingBox=new Wn),e.boundingBox===null&&e.computeBoundingBox(),this.boundingBox.makeEmpty();for(let i=0;i<r;i++)this.getMatrixAt(i,ua),dm.copy(e.boundingBox).applyMatrix4(ua),this.boundingBox.union(dm)}computeBoundingSphere(){const e=this.geometry,r=this.count;this.boundingSphere===null&&(this.boundingSphere=new $a),e.boundingSphere===null&&e.computeBoundingSphere(),this.boundingSphere.makeEmpty();for(let i=0;i<r;i++)this.getMatrixAt(i,ua),ms.copy(e.boundingSphere).applyMatrix4(ua),this.boundingSphere.union(ms)}copy(e,r){return super.copy(e,r),this.instanceMatrix.copy(e.instanceMatrix),e.morphTexture!==null&&(this.morphTexture=e.morphTexture.clone()),e.instanceColor!==null&&(this.instanceColor=e.instanceColor.clone()),this.count=e.count,e.boundingBox!==null&&(this.boundingBox=e.boundingBox.clone()),e.boundingSphere!==null&&(this.boundingSphere=e.boundingSphere.clone()),this}getColorAt(e,r){r.fromArray(this.instanceColor.array,e*3)}getMatrixAt(e,r){r.fromArray(this.instanceMatrix.array,e*16)}getMorphAt(e,r){const i=r.morphTargetInfluences,n=this.morphTexture.source.data.data,a=i.length+1,s=e*a+1;for(let o=0;o<i.length;o++)i[o]=n[s+o]}raycast(e,r){const i=this.matrixWorld,n=this.count;if(ps.geometry=this.geometry,ps.material=this.material,ps.material!==void 0&&(this.boundingSphere===null&&this.computeBoundingSphere(),ms.copy(this.boundingSphere),ms.applyMatrix4(i),e.ray.intersectsSphere(ms)!==!1))for(let a=0;a<n;a++){this.getMatrixAt(a,ua),cm.multiplyMatrices(i,ua),ps.matrixWorld=cm,ps.raycast(e,Yo);for(let s=0,o=Yo.length;s<o;s++){const l=Yo[s];l.instanceId=a,l.object=this,r.push(l)}Yo.length=0}}setColorAt(e,r){this.instanceColor===null&&(this.instanceColor=new um(new Float32Array(this.instanceMatrix.count*3),3)),r.toArray(this.instanceColor.array,e*3)}setMatrixAt(e,r){r.toArray(this.instanceMatrix.array,e*16)}setMorphAt(e,r){const i=r.morphTargetInfluences,n=i.length+1;this.morphTexture===null&&(this.morphTexture=new dw(new Float32Array(n*this.count),n,this.count,qv,Mi));const a=this.morphTexture.source.data.data;let s=0;for(let u=0;u<i.length;u++)s+=i[u];const o=this.geometry.morphTargetsRelative?1:1-s,l=n*e;a[l]=o,a.set(i,l+1)}updateMorphTargets(){}dispose(){return this.dispatchEvent({type:"dispose"}),this.morphTexture!==null&&(this.morphTexture.dispose(),this.morphTexture=null),this}}class __ extends Qa{constructor(e){super(),this.isLineBasicMaterial=!0,this.type="LineBasicMaterial",this.color=new ke(16777215),this.map=null,this.linewidth=1,this.linecap="round",this.linejoin="round",this.fog=!0,this.setValues(e)}copy(e){return super.copy(e),this.color.copy(e.color),this.map=e.map,this.linewidth=e.linewidth,this.linecap=e.linecap,this.linejoin=e.linejoin,this.fog=e.fog,this}}const Xl=new O,Yl=new O,hm=new ft,gs=new mu,qo=new $a,Ac=new O,fm=new O;class fw extends Rt{constructor(e=new Or,r=new __){super(),this.isLine=!0,this.type="Line",this.geometry=e,this.material=r,this.updateMorphTargets()}copy(e,r){return super.copy(e,r),this.material=Array.isArray(e.material)?e.material.slice():e.material,this.geometry=e.geometry,this}computeLineDistances(){const e=this.geometry;if(e.index===null){const r=e.attributes.position,i=[0];for(let n=1,a=r.count;n<a;n++)Xl.fromBufferAttribute(r,n-1),Yl.fromBufferAttribute(r,n),i[n]=i[n-1],i[n]+=Xl.distanceTo(Yl);e.setAttribute("lineDistance",new Yt(i,1))}else console.warn("THREE.Line.computeLineDistances(): Computation only possible with non-indexed BufferGeometry.");return this}raycast(e,r){const i=this.geometry,n=this.matrixWorld,a=e.params.Line.threshold,s=i.drawRange;if(i.boundingSphere===null&&i.computeBoundingSphere(),qo.copy(i.boundingSphere),qo.applyMatrix4(n),qo.radius+=a,e.ray.intersectsSphere(qo)===!1)return;hm.copy(n).invert(),gs.copy(e.ray).applyMatrix4(hm);const o=a/((this.scale.x+this.scale.y+this.scale.z)/3),l=o*o,u=this.isLineSegments?2:1,h=i.index,f=i.attributes.position;if(h!==null){const d=Math.max(0,s.start),p=Math.min(h.count,s.start+s.count);for(let _=d,x=p-1;_<x;_+=u){const m=h.getX(_),c=h.getX(_+1),g=Ko(this,e,gs,l,m,c);g&&r.push(g)}if(this.isLineLoop){const _=h.getX(p-1),x=h.getX(d),m=Ko(this,e,gs,l,_,x);m&&r.push(m)}}else{const d=Math.max(0,s.start),p=Math.min(f.count,s.start+s.count);for(let _=d,x=p-1;_<x;_+=u){const m=Ko(this,e,gs,l,_,_+1);m&&r.push(m)}if(this.isLineLoop){const _=Ko(this,e,gs,l,p-1,d);_&&r.push(_)}}}updateMorphTargets(){const e=this.geometry.morphAttributes,r=Object.keys(e);if(r.length>0){const i=e[r[0]];if(i!==void 0){this.morphTargetInfluences=[],this.morphTargetDictionary={};for(let n=0,a=i.length;n<a;n++){const s=i[n].name||String(n);this.morphTargetInfluences.push(0),this.morphTargetDictionary[s]=n}}}}}function Ko(t,e,r,i,n,a){const s=t.geometry.attributes.position;if(Xl.fromBufferAttribute(s,n),Yl.fromBufferAttribute(s,a),r.distanceSqToSegment(Xl,Yl,Ac,fm)>i)return;Ac.applyMatrix4(t.matrixWorld);const o=e.ray.origin.distanceTo(Ac);if(!(o<e.near||o>e.far))return{distance:o,point:fm.clone().applyMatrix4(t.matrixWorld),index:n,face:null,faceIndex:null,object:t}}class Ia extends Or{constructor(e=1,r=1,i=1,n=32,a=1,s=!1,o=0,l=Math.PI*2){super(),this.type="CylinderGeometry",this.parameters={radiusTop:e,radiusBottom:r,height:i,radialSegments:n,heightSegments:a,openEnded:s,thetaStart:o,thetaLength:l};const u=this;n=Math.floor(n),a=Math.floor(a);const h=[],f=[],d=[],p=[];let _=0;const x=[],m=i/2;let c=0;g(),s===!1&&(e>0&&v(!0),r>0&&v(!1)),this.setIndex(h),this.setAttribute("position",new Yt(f,3)),this.setAttribute("normal",new Yt(d,3)),this.setAttribute("uv",new Yt(p,2));function g(){const M=new O,P=new O;let T=0;const w=(r-e)/i;for(let L=0;L<=a;L++){const b=[],y=L/a,U=y*(r-e)+e;for(let B=0;B<=n;B++){const V=B/n,q=V*l+o,J=Math.sin(q),K=Math.cos(q);P.x=U*J,P.y=-y*i+m,P.z=U*K,f.push(P.x,P.y,P.z),M.set(J,w,K).normalize(),d.push(M.x,M.y,M.z),p.push(V,1-y),b.push(_++)}x.push(b)}for(let L=0;L<n;L++)for(let b=0;b<a;b++){const y=x[b][L],U=x[b+1][L],B=x[b+1][L+1],V=x[b][L+1];h.push(y,U,V),h.push(U,B,V),T+=6}u.addGroup(c,T,0),c+=T}function v(M){const P=_,T=new Ne,w=new O;let L=0;const b=M===!0?e:r,y=M===!0?1:-1;for(let B=1;B<=n;B++)f.push(0,m*y,0),d.push(0,y,0),p.push(.5,.5),_++;const U=_;for(let B=0;B<=n;B++){const V=B/n*l+o,q=Math.cos(V),J=Math.sin(V);w.x=b*J,w.y=m*y,w.z=b*q,f.push(w.x,w.y,w.z),d.push(0,y,0),T.x=q*.5+.5,T.y=J*.5*y+.5,p.push(T.x,T.y),_++}for(let B=0;B<n;B++){const V=P+B,q=U+B;M===!0?h.push(q,q+1,V):h.push(q+1,q,V),L+=3}u.addGroup(c,L,M===!0?1:2),c+=L}}copy(e){return super.copy(e),this.parameters=Object.assign({},e.parameters),this}static fromJSON(e){return new Ia(e.radiusTop,e.radiusBottom,e.height,e.radialSegments,e.heightSegments,e.openEnded,e.thetaStart,e.thetaLength)}}class ql extends Ia{constructor(e=1,r=1,i=32,n=1,a=!1,s=0,o=Math.PI*2){super(0,e,r,i,n,a,s,o),this.type="ConeGeometry",this.parameters={radius:e,height:r,radialSegments:i,heightSegments:n,openEnded:a,thetaStart:s,thetaLength:o}}static fromJSON(e){return new ql(e.radius,e.height,e.radialSegments,e.heightSegments,e.openEnded,e.thetaStart,e.thetaLength)}}class Kl extends Or{constructor(e=.5,r=1,i=32,n=1,a=0,s=Math.PI*2){super(),this.type="RingGeometry",this.parameters={innerRadius:e,outerRadius:r,thetaSegments:i,phiSegments:n,thetaStart:a,thetaLength:s},i=Math.max(3,i),n=Math.max(1,n);const o=[],l=[],u=[],h=[];let f=e;const d=(r-e)/n,p=new O,_=new Ne;for(let x=0;x<=n;x++){for(let m=0;m<=i;m++){const c=a+m/i*s;p.x=f*Math.cos(c),p.y=f*Math.sin(c),l.push(p.x,p.y,p.z),u.push(0,0,1),_.x=(p.x/r+1)/2,_.y=(p.y/r+1)/2,h.push(_.x,_.y)}f+=d}for(let x=0;x<n;x++){const m=x*(i+1);for(let c=0;c<i;c++){const g=c+m,v=g,M=g+i+1,P=g+i+2,T=g+1;o.push(v,M,T),o.push(M,P,T)}}this.setIndex(o),this.setAttribute("position",new Yt(l,3)),this.setAttribute("normal",new Yt(u,3)),this.setAttribute("uv",new Yt(h,2))}copy(e){return super.copy(e),this.parameters=Object.assign({},e.parameters),this}static fromJSON(e){return new Kl(e.innerRadius,e.outerRadius,e.thetaSegments,e.phiSegments,e.thetaStart,e.thetaLength)}}class Hi extends Or{constructor(e=1,r=32,i=16,n=0,a=Math.PI*2,s=0,o=Math.PI){super(),this.type="SphereGeometry",this.parameters={radius:e,widthSegments:r,heightSegments:i,phiStart:n,phiLength:a,thetaStart:s,thetaLength:o},r=Math.max(3,Math.floor(r)),i=Math.max(2,Math.floor(i));const l=Math.min(s+o,Math.PI);let u=0;const h=[],f=new O,d=new O,p=[],_=[],x=[],m=[];for(let c=0;c<=i;c++){const g=[],v=c/i;let M=0;c===0&&s===0?M=.5/r:c===i&&l===Math.PI&&(M=-.5/r);for(let P=0;P<=r;P++){const T=P/r;f.x=-e*Math.cos(n+T*a)*Math.sin(s+v*o),f.y=e*Math.cos(s+v*o),f.z=e*Math.sin(n+T*a)*Math.sin(s+v*o),_.push(f.x,f.y,f.z),d.copy(f).normalize(),x.push(d.x,d.y,d.z),m.push(T+M,1-v),g.push(u++)}h.push(g)}for(let c=0;c<i;c++)for(let g=0;g<r;g++){const v=h[c][g+1],M=h[c][g],P=h[c+1][g],T=h[c+1][g+1];(c!==0||s>0)&&p.push(v,M,T),(c!==i-1||l<Math.PI)&&p.push(M,P,T)}this.setIndex(p),this.setAttribute("position",new Yt(_,3)),this.setAttribute("normal",new Yt(x,3)),this.setAttribute("uv",new Yt(m,2))}copy(e){return super.copy(e),this.parameters=Object.assign({},e.parameters),this}static fromJSON(e){return new Hi(e.radius,e.widthSegments,e.heightSegments,e.phiStart,e.phiLength,e.thetaStart,e.thetaLength)}}class tr extends Qa{constructor(e){super(),this.isMeshStandardMaterial=!0,this.defines={STANDARD:""},this.type="MeshStandardMaterial",this.color=new ke(16777215),this.roughness=1,this.metalness=0,this.map=null,this.lightMap=null,this.lightMapIntensity=1,this.aoMap=null,this.aoMapIntensity=1,this.emissive=new ke(0),this.emissiveIntensity=1,this.emissiveMap=null,this.bumpMap=null,this.bumpScale=1,this.normalMap=null,this.normalMapType=Qv,this.normalScale=new Ne(1,1),this.displacementMap=null,this.displacementScale=1,this.displacementBias=0,this.roughnessMap=null,this.metalnessMap=null,this.alphaMap=null,this.envMap=null,this.envMapRotation=new oi,this.envMapIntensity=1,this.wireframe=!1,this.wireframeLinewidth=1,this.wireframeLinecap="round",this.wireframeLinejoin="round",this.flatShading=!1,this.fog=!0,this.setValues(e)}copy(e){return super.copy(e),this.defines={STANDARD:""},this.color.copy(e.color),this.roughness=e.roughness,this.metalness=e.metalness,this.map=e.map,this.lightMap=e.lightMap,this.lightMapIntensity=e.lightMapIntensity,this.aoMap=e.aoMap,this.aoMapIntensity=e.aoMapIntensity,this.emissive.copy(e.emissive),this.emissiveMap=e.emissiveMap,this.emissiveIntensity=e.emissiveIntensity,this.bumpMap=e.bumpMap,this.bumpScale=e.bumpScale,this.normalMap=e.normalMap,this.normalMapType=e.normalMapType,this.normalScale.copy(e.normalScale),this.displacementMap=e.displacementMap,this.displacementScale=e.displacementScale,this.displacementBias=e.displacementBias,this.roughnessMap=e.roughnessMap,this.metalnessMap=e.metalnessMap,this.alphaMap=e.alphaMap,this.envMap=e.envMap,this.envMapRotation.copy(e.envMapRotation),this.envMapIntensity=e.envMapIntensity,this.wireframe=e.wireframe,this.wireframeLinewidth=e.wireframeLinewidth,this.wireframeLinecap=e.wireframeLinecap,this.wireframeLinejoin=e.wireframeLinejoin,this.flatShading=e.flatShading,this.fog=e.fog,this}}class vu extends Rt{constructor(e,r=1){super(),this.isLight=!0,this.type="Light",this.color=new ke(e),this.intensity=r}dispose(){}copy(e,r){return super.copy(e,r),this.color.copy(e.color),this.intensity=e.intensity,this}toJSON(e){const r=super.toJSON(e);return r.object.color=this.color.getHex(),r.object.intensity=this.intensity,this.groundColor!==void 0&&(r.object.groundColor=this.groundColor.getHex()),this.distance!==void 0&&(r.object.distance=this.distance),this.angle!==void 0&&(r.object.angle=this.angle),this.decay!==void 0&&(r.object.decay=this.decay),this.penumbra!==void 0&&(r.object.penumbra=this.penumbra),this.shadow!==void 0&&(r.object.shadow=this.shadow.toJSON()),r}}class pw extends vu{constructor(e,r,i){super(e,i),this.isHemisphereLight=!0,this.type="HemisphereLight",this.position.copy(Rt.DEFAULT_UP),this.updateMatrix(),this.groundColor=new ke(r)}copy(e,r){return super.copy(e,r),this.groundColor.copy(e.groundColor),this}}const Cc=new ft,pm=new O,mm=new O;class x_{constructor(e){this.camera=e,this.bias=0,this.normalBias=0,this.radius=1,this.blurSamples=8,this.mapSize=new Ne(512,512),this.map=null,this.mapPass=null,this.matrix=new ft,this.autoUpdate=!0,this.needsUpdate=!1,this._frustum=new Rh,this._frameExtents=new Ne(1,1),this._viewportCount=1,this._viewports=[new Mt(0,0,1,1)]}getViewportCount(){return this._viewportCount}getFrustum(){return this._frustum}updateMatrices(e){const r=this.camera,i=this.matrix;pm.setFromMatrixPosition(e.matrixWorld),r.position.copy(pm),mm.setFromMatrixPosition(e.target.matrixWorld),r.lookAt(mm),r.updateMatrixWorld(),Cc.multiplyMatrices(r.projectionMatrix,r.matrixWorldInverse),this._frustum.setFromProjectionMatrix(Cc),i.set(.5,0,0,.5,0,.5,0,.5,0,0,.5,.5,0,0,0,1),i.multiply(Cc)}getViewport(e){return this._viewports[e]}getFrameExtents(){return this._frameExtents}dispose(){this.map&&this.map.dispose(),this.mapPass&&this.mapPass.dispose()}copy(e){return this.camera=e.camera.clone(),this.bias=e.bias,this.radius=e.radius,this.mapSize.copy(e.mapSize),this}clone(){return new this.constructor().copy(this)}toJSON(){const e={};return this.bias!==0&&(e.bias=this.bias),this.normalBias!==0&&(e.normalBias=this.normalBias),this.radius!==1&&(e.radius=this.radius),(this.mapSize.x!==512||this.mapSize.y!==512)&&(e.mapSize=this.mapSize.toArray()),e.camera=this.camera.toJSON(!1).object,delete e.camera.matrix,e}}const gm=new ft,vs=new O,Rc=new O;class mw extends x_{constructor(){super(new Sr(90,1,.5,500)),this.isPointLightShadow=!0,this._frameExtents=new Ne(4,2),this._viewportCount=6,this._viewports=[new Mt(2,1,1,1),new Mt(0,1,1,1),new Mt(3,1,1,1),new Mt(1,1,1,1),new Mt(3,0,1,1),new Mt(1,0,1,1)],this._cubeDirections=[new O(1,0,0),new O(-1,0,0),new O(0,0,1),new O(0,0,-1),new O(0,1,0),new O(0,-1,0)],this._cubeUps=[new O(0,1,0),new O(0,1,0),new O(0,1,0),new O(0,1,0),new O(0,0,1),new O(0,0,-1)]}updateMatrices(e,r=0){const i=this.camera,n=this.matrix,a=e.distance||i.far;a!==i.far&&(i.far=a,i.updateProjectionMatrix()),vs.setFromMatrixPosition(e.matrixWorld),i.position.copy(vs),Rc.copy(i.position),Rc.add(this._cubeDirections[r]),i.up.copy(this._cubeUps[r]),i.lookAt(Rc),i.updateMatrixWorld(),n.makeTranslation(-vs.x,-vs.y,-vs.z),gm.multiplyMatrices(i.projectionMatrix,i.matrixWorldInverse),this._frustum.setFromProjectionMatrix(gm)}}class Mn extends vu{constructor(e,r,i=0,n=2){super(e,r),this.isPointLight=!0,this.type="PointLight",this.distance=i,this.decay=n,this.shadow=new mw}get power(){return this.intensity*4*Math.PI}set power(e){this.intensity=e/(4*Math.PI)}dispose(){this.shadow.dispose()}copy(e,r){return super.copy(e,r),this.distance=e.distance,this.decay=e.decay,this.shadow=e.shadow.clone(),this}}class gw extends x_{constructor(){super(new d_(-5,5,5,-5,.5,500)),this.isDirectionalLightShadow=!0}}class vm extends vu{constructor(e,r){super(e,r),this.isDirectionalLight=!0,this.type="DirectionalLight",this.position.copy(Rt.DEFAULT_UP),this.updateMatrix(),this.target=new Rt,this.shadow=new gw}dispose(){this.shadow.dispose()}copy(e){return super.copy(e),this.target=e.target.clone(),this.shadow=e.shadow.clone(),this}}class vw extends vu{constructor(e,r){super(e,r),this.isAmbientLight=!0,this.type="AmbientLight"}}class _w{constructor(e=!0){this.autoStart=e,this.startTime=0,this.oldTime=0,this.elapsedTime=0,this.running=!1}start(){this.startTime=_m(),this.oldTime=this.startTime,this.elapsedTime=0,this.running=!0}stop(){this.getElapsedTime(),this.running=!1,this.autoStart=!1}getElapsedTime(){return this.getDelta(),this.elapsedTime}getDelta(){let e=0;if(this.autoStart&&!this.running)return this.start(),0;if(this.running){const r=_m();e=(r-this.oldTime)/1e3,this.oldTime=r,this.elapsedTime+=e}return e}}function _m(){return(typeof performance>"u"?Date:performance).now()}const xm=new ft;class xw{constructor(e,r,i=0,n=1/0){this.ray=new mu(e,r),this.near=i,this.far=n,this.camera=null,this.layers=new Ch,this.params={Mesh:{},Line:{threshold:1},LOD:{},Points:{threshold:1},Sprite:{}}}set(e,r){this.ray.set(e,r)}setFromCamera(e,r){r.isPerspectiveCamera?(this.ray.origin.setFromMatrixPosition(r.matrixWorld),this.ray.direction.set(e.x,e.y,.5).unproject(r).sub(this.ray.origin).normalize(),this.camera=r):r.isOrthographicCamera?(this.ray.origin.set(e.x,e.y,(r.near+r.far)/(r.near-r.far)).unproject(r),this.ray.direction.set(0,0,-1).transformDirection(r.matrixWorld),this.camera=r):console.error("THREE.Raycaster: Unsupported camera type: "+r.type)}setFromXRController(e){return xm.identity().extractRotation(e.matrixWorld),this.ray.origin.setFromMatrixPosition(e.matrixWorld),this.ray.direction.set(0,0,-1).applyMatrix4(xm),this}intersectObject(e,r=!0,i=[]){return Ld(e,this,i,r),i.sort(ym),i}intersectObjects(e,r=!0,i=[]){for(let n=0,a=e.length;n<a;n++)Ld(e[n],this,i,r);return i.sort(ym),i}}function ym(t,e){return t.distance-e.distance}function Ld(t,e,r,i){let n=!0;if(t.layers.test(e.layers)&&t.raycast(e,r)===!1&&(n=!1),n===!0&&i===!0){const a=t.children;for(let s=0,o=a.length;s<o;s++)Ld(a[s],e,r,!0)}}class Mm{constructor(e=1,r=0,i=0){return this.radius=e,this.phi=r,this.theta=i,this}set(e,r,i){return this.radius=e,this.phi=r,this.theta=i,this}copy(e){return this.radius=e.radius,this.phi=e.phi,this.theta=e.theta,this}makeSafe(){return this.phi=Math.max(1e-6,Math.min(Math.PI-1e-6,this.phi)),this}setFromVector3(e){return this.setFromCartesianCoords(e.x,e.y,e.z)}setFromCartesianCoords(e,r,i){return this.radius=Math.sqrt(e*e+r*r+i*i),this.radius===0?(this.theta=0,this.phi=0):(this.theta=Math.atan2(e,i),this.phi=Math.acos(nr(r/this.radius,-1,1))),this}clone(){return new this.constructor().copy(this)}}typeof __THREE_DEVTOOLS__<"u"&&__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("register",{detail:{revision:Th}}));typeof window<"u"&&(window.__THREE__?console.warn("WARNING: Multiple instances of Three.js being imported."):window.__THREE__=Th);const Sm={type:"change"},Pc={type:"start"},bm={type:"end"},Zo=new mu,Em=new Vi,yw=Math.cos(70*eM.DEG2RAD);class Mw extends Gn{constructor(e,r){super(),this.object=e,this.domElement=r,this.domElement.style.touchAction="none",this.enabled=!0,this.target=new O,this.cursor=new O,this.minDistance=0,this.maxDistance=1/0,this.minZoom=0,this.maxZoom=1/0,this.minTargetRadius=0,this.maxTargetRadius=1/0,this.minPolarAngle=0,this.maxPolarAngle=Math.PI,this.minAzimuthAngle=-1/0,this.maxAzimuthAngle=1/0,this.enableDamping=!1,this.dampingFactor=.05,this.enableZoom=!0,this.zoomSpeed=1,this.enableRotate=!0,this.rotateSpeed=1,this.enablePan=!0,this.panSpeed=1,this.screenSpacePanning=!0,this.keyPanSpeed=7,this.zoomToCursor=!1,this.autoRotate=!1,this.autoRotateSpeed=2,this.keys={LEFT:"ArrowLeft",UP:"ArrowUp",RIGHT:"ArrowRight",BOTTOM:"ArrowDown"},this.mouseButtons={LEFT:vi.ROTATE,MIDDLE:vi.DOLLY,RIGHT:vi.PAN},this.touches={ONE:Bi.ROTATE,TWO:Bi.DOLLY_PAN},this.target0=this.target.clone(),this.position0=this.object.position.clone(),this.zoom0=this.object.zoom,this._domElementKeyEvents=null,this.getPolarAngle=function(){return o.phi},this.getAzimuthalAngle=function(){return o.theta},this.getDistance=function(){return this.object.position.distanceTo(this.target)},this.listenToKeyEvents=function(R){R.addEventListener("keydown",ge),this._domElementKeyEvents=R},this.stopListenToKeyEvents=function(){this._domElementKeyEvents.removeEventListener("keydown",ge),this._domElementKeyEvents=null},this.saveState=function(){i.target0.copy(i.target),i.position0.copy(i.object.position),i.zoom0=i.object.zoom},this.reset=function(){i.target.copy(i.target0),i.object.position.copy(i.position0),i.object.zoom=i.zoom0,i.object.updateProjectionMatrix(),i.dispatchEvent(Sm),i.update(),a=n.NONE},this.update=function(){const R=new O,A=new Bn().setFromUnitVectors(e.up,new O(0,1,0)),te=A.clone().invert(),W=new O,Q=new Bn,oe=new O,Se=2*Math.PI;return function(at=null){const ht=i.object.position;R.copy(ht).sub(i.target),R.applyQuaternion(A),o.setFromVector3(R),i.autoRotate&&a===n.NONE&&B(y(at)),i.enableDamping?(o.theta+=l.theta*i.dampingFactor,o.phi+=l.phi*i.dampingFactor):(o.theta+=l.theta,o.phi+=l.phi);let z=i.minAzimuthAngle,H=i.maxAzimuthAngle;isFinite(z)&&isFinite(H)&&(z<-Math.PI?z+=Se:z>Math.PI&&(z-=Se),H<-Math.PI?H+=Se:H>Math.PI&&(H-=Se),z<=H?o.theta=Math.max(z,Math.min(H,o.theta)):o.theta=o.theta>(z+H)/2?Math.max(z,o.theta):Math.min(H,o.theta)),o.phi=Math.max(i.minPolarAngle,Math.min(i.maxPolarAngle,o.phi)),o.makeSafe(),i.enableDamping===!0?i.target.addScaledVector(h,i.dampingFactor):i.target.add(h),i.target.sub(i.cursor),i.target.clampLength(i.minTargetRadius,i.maxTargetRadius),i.target.add(i.cursor);let $=!1;if(i.zoomToCursor&&T||i.object.isOrthographicCamera)o.radius=re(o.radius);else{const N=o.radius;o.radius=re(o.radius*u),$=N!=o.radius}if(R.setFromSpherical(o),R.applyQuaternion(te),ht.copy(i.target).add(R),i.object.lookAt(i.target),i.enableDamping===!0?(l.theta*=1-i.dampingFactor,l.phi*=1-i.dampingFactor,h.multiplyScalar(1-i.dampingFactor)):(l.set(0,0,0),h.set(0,0,0)),i.zoomToCursor&&T){let N=null;if(i.object.isPerspectiveCamera){const pe=R.length();N=re(pe*u);const be=pe-N;i.object.position.addScaledVector(M,be),i.object.updateMatrixWorld(),$=!!be}else if(i.object.isOrthographicCamera){const pe=new O(P.x,P.y,0);pe.unproject(i.object);const be=i.object.zoom;i.object.zoom=Math.max(i.minZoom,Math.min(i.maxZoom,i.object.zoom/u)),i.object.updateProjectionMatrix(),$=be!==i.object.zoom;const Ge=new O(P.x,P.y,0);Ge.unproject(i.object),i.object.position.sub(Ge).add(pe),i.object.updateMatrixWorld(),N=R.length()}else console.warn("WARNING: OrbitControls.js encountered an unknown camera type - zoom to cursor disabled."),i.zoomToCursor=!1;N!==null&&(this.screenSpacePanning?i.target.set(0,0,-1).transformDirection(i.object.matrix).multiplyScalar(N).add(i.object.position):(Zo.origin.copy(i.object.position),Zo.direction.set(0,0,-1).transformDirection(i.object.matrix),Math.abs(i.object.up.dot(Zo.direction))<yw?e.lookAt(i.target):(Em.setFromNormalAndCoplanarPoint(i.object.up,i.target),Zo.intersectPlane(Em,i.target))))}else if(i.object.isOrthographicCamera){const N=i.object.zoom;i.object.zoom=Math.max(i.minZoom,Math.min(i.maxZoom,i.object.zoom/u)),N!==i.object.zoom&&(i.object.updateProjectionMatrix(),$=!0)}return u=1,T=!1,$||W.distanceToSquared(i.object.position)>s||8*(1-Q.dot(i.object.quaternion))>s||oe.distanceToSquared(i.target)>s?(i.dispatchEvent(Sm),W.copy(i.object.position),Q.copy(i.object.quaternion),oe.copy(i.target),!0):!1}}(),this.dispose=function(){i.domElement.removeEventListener("contextmenu",we),i.domElement.removeEventListener("pointerdown",dt),i.domElement.removeEventListener("pointercancel",S),i.domElement.removeEventListener("wheel",le),i.domElement.removeEventListener("pointermove",C),i.domElement.removeEventListener("pointerup",S),i.domElement.getRootNode().removeEventListener("keydown",Ae,{capture:!0}),i._domElementKeyEvents!==null&&(i._domElementKeyEvents.removeEventListener("keydown",ge),i._domElementKeyEvents=null)};const i=this,n={NONE:-1,ROTATE:0,DOLLY:1,PAN:2,TOUCH_ROTATE:3,TOUCH_PAN:4,TOUCH_DOLLY_PAN:5,TOUCH_DOLLY_ROTATE:6};let a=n.NONE;const s=1e-6,o=new Mm,l=new Mm;let u=1;const h=new O,f=new Ne,d=new Ne,p=new Ne,_=new Ne,x=new Ne,m=new Ne,c=new Ne,g=new Ne,v=new Ne,M=new O,P=new Ne;let T=!1;const w=[],L={};let b=!1;function y(R){return R!==null?2*Math.PI/60*i.autoRotateSpeed*R:2*Math.PI/60/60*i.autoRotateSpeed}function U(R){const A=Math.abs(R*.01);return Math.pow(.95,i.zoomSpeed*A)}function B(R){l.theta-=R}function V(R){l.phi-=R}const q=function(){const R=new O;return function(A,te){R.setFromMatrixColumn(te,0),R.multiplyScalar(-A),h.add(R)}}(),J=function(){const R=new O;return function(A,te){i.screenSpacePanning===!0?R.setFromMatrixColumn(te,1):(R.setFromMatrixColumn(te,0),R.crossVectors(i.object.up,R)),R.multiplyScalar(A),h.add(R)}}(),K=function(){const R=new O;return function(A,te){const W=i.domElement;if(i.object.isPerspectiveCamera){const Q=i.object.position;R.copy(Q).sub(i.target);let oe=R.length();oe*=Math.tan(i.object.fov/2*Math.PI/180),q(2*A*oe/W.clientHeight,i.object.matrix),J(2*te*oe/W.clientHeight,i.object.matrix)}else i.object.isOrthographicCamera?(q(A*(i.object.right-i.object.left)/i.object.zoom/W.clientWidth,i.object.matrix),J(te*(i.object.top-i.object.bottom)/i.object.zoom/W.clientHeight,i.object.matrix)):(console.warn("WARNING: OrbitControls.js encountered an unknown camera type - pan disabled."),i.enablePan=!1)}}();function ne(R){i.object.isPerspectiveCamera||i.object.isOrthographicCamera?u/=R:(console.warn("WARNING: OrbitControls.js encountered an unknown camera type - dolly/zoom disabled."),i.enableZoom=!1)}function I(R){i.object.isPerspectiveCamera||i.object.isOrthographicCamera?u*=R:(console.warn("WARNING: OrbitControls.js encountered an unknown camera type - dolly/zoom disabled."),i.enableZoom=!1)}function Z(R,A){if(!i.zoomToCursor)return;T=!0;const te=i.domElement.getBoundingClientRect(),W=R-te.left,Q=A-te.top,oe=te.width,Se=te.height;P.x=W/oe*2-1,P.y=-(Q/Se)*2+1,M.set(P.x,P.y,1).unproject(i.object).sub(i.object.position).normalize()}function re(R){return Math.max(i.minDistance,Math.min(i.maxDistance,R))}function xe(R){f.set(R.clientX,R.clientY)}function fe(R){Z(R.clientX,R.clientX),c.set(R.clientX,R.clientY)}function Ue(R){_.set(R.clientX,R.clientY)}function Y(R){d.set(R.clientX,R.clientY),p.subVectors(d,f).multiplyScalar(i.rotateSpeed);const A=i.domElement;B(2*Math.PI*p.x/A.clientHeight),V(2*Math.PI*p.y/A.clientHeight),f.copy(d),i.update()}function ee(R){g.set(R.clientX,R.clientY),v.subVectors(g,c),v.y>0?ne(U(v.y)):v.y<0&&I(U(v.y)),c.copy(g),i.update()}function ae(R){x.set(R.clientX,R.clientY),m.subVectors(x,_).multiplyScalar(i.panSpeed),K(m.x,m.y),_.copy(x),i.update()}function ue(R){Z(R.clientX,R.clientY),R.deltaY<0?I(U(R.deltaY)):R.deltaY>0&&ne(U(R.deltaY)),i.update()}function Ce(R){let A=!1;switch(R.code){case i.keys.UP:R.ctrlKey||R.metaKey||R.shiftKey?V(2*Math.PI*i.rotateSpeed/i.domElement.clientHeight):K(0,i.keyPanSpeed),A=!0;break;case i.keys.BOTTOM:R.ctrlKey||R.metaKey||R.shiftKey?V(-2*Math.PI*i.rotateSpeed/i.domElement.clientHeight):K(0,-i.keyPanSpeed),A=!0;break;case i.keys.LEFT:R.ctrlKey||R.metaKey||R.shiftKey?B(2*Math.PI*i.rotateSpeed/i.domElement.clientHeight):K(i.keyPanSpeed,0),A=!0;break;case i.keys.RIGHT:R.ctrlKey||R.metaKey||R.shiftKey?B(-2*Math.PI*i.rotateSpeed/i.domElement.clientHeight):K(-i.keyPanSpeed,0),A=!0;break}A&&(R.preventDefault(),i.update())}function Fe(R){if(w.length===1)f.set(R.pageX,R.pageY);else{const A=Ve(R),te=.5*(R.pageX+A.x),W=.5*(R.pageY+A.y);f.set(te,W)}}function Ze(R){if(w.length===1)_.set(R.pageX,R.pageY);else{const A=Ve(R),te=.5*(R.pageX+A.x),W=.5*(R.pageY+A.y);_.set(te,W)}}function D(R){const A=Ve(R),te=R.pageX-A.x,W=R.pageY-A.y,Q=Math.sqrt(te*te+W*W);c.set(0,Q)}function $e(R){i.enableZoom&&D(R),i.enablePan&&Ze(R)}function Qe(R){i.enableZoom&&D(R),i.enableRotate&&Fe(R)}function nt(R){if(w.length==1)d.set(R.pageX,R.pageY);else{const te=Ve(R),W=.5*(R.pageX+te.x),Q=.5*(R.pageY+te.y);d.set(W,Q)}p.subVectors(d,f).multiplyScalar(i.rotateSpeed);const A=i.domElement;B(2*Math.PI*p.x/A.clientHeight),V(2*Math.PI*p.y/A.clientHeight),f.copy(d)}function Re(R){if(w.length===1)x.set(R.pageX,R.pageY);else{const A=Ve(R),te=.5*(R.pageX+A.x),W=.5*(R.pageY+A.y);x.set(te,W)}m.subVectors(x,_).multiplyScalar(i.panSpeed),K(m.x,m.y),_.copy(x)}function Je(R){const A=Ve(R),te=R.pageX-A.x,W=R.pageY-A.y,Q=Math.sqrt(te*te+W*W);g.set(0,Q),v.set(0,Math.pow(g.y/c.y,i.zoomSpeed)),ne(v.y),c.copy(g);const oe=(R.pageX+A.x)*.5,Se=(R.pageY+A.y)*.5;Z(oe,Se)}function We(R){i.enableZoom&&Je(R),i.enablePan&&Re(R)}function Be(R){i.enableZoom&&Je(R),i.enableRotate&&nt(R)}function dt(R){i.enabled!==!1&&(w.length===0&&(i.domElement.setPointerCapture(R.pointerId),i.domElement.addEventListener("pointermove",C),i.domElement.addEventListener("pointerup",S)),!ve(R)&&(Xe(R),R.pointerType==="touch"?Le(R):j(R)))}function C(R){i.enabled!==!1&&(R.pointerType==="touch"?he(R):ie(R))}function S(R){switch(De(R),w.length){case 0:i.domElement.releasePointerCapture(R.pointerId),i.domElement.removeEventListener("pointermove",C),i.domElement.removeEventListener("pointerup",S),i.dispatchEvent(bm),a=n.NONE;break;case 1:const A=w[0],te=L[A];Le({pointerId:A,pageX:te.x,pageY:te.y});break}}function j(R){let A;switch(R.button){case 0:A=i.mouseButtons.LEFT;break;case 1:A=i.mouseButtons.MIDDLE;break;case 2:A=i.mouseButtons.RIGHT;break;default:A=-1}switch(A){case vi.DOLLY:if(i.enableZoom===!1)return;fe(R),a=n.DOLLY;break;case vi.ROTATE:if(R.ctrlKey||R.metaKey||R.shiftKey){if(i.enablePan===!1)return;Ue(R),a=n.PAN}else{if(i.enableRotate===!1)return;xe(R),a=n.ROTATE}break;case vi.PAN:if(R.ctrlKey||R.metaKey||R.shiftKey){if(i.enableRotate===!1)return;xe(R),a=n.ROTATE}else{if(i.enablePan===!1)return;Ue(R),a=n.PAN}break;default:a=n.NONE}a!==n.NONE&&i.dispatchEvent(Pc)}function ie(R){switch(a){case n.ROTATE:if(i.enableRotate===!1)return;Y(R);break;case n.DOLLY:if(i.enableZoom===!1)return;ee(R);break;case n.PAN:if(i.enablePan===!1)return;ae(R);break}}function le(R){i.enabled===!1||i.enableZoom===!1||a!==n.NONE||(R.preventDefault(),i.dispatchEvent(Pc),ue(se(R)),i.dispatchEvent(bm))}function se(R){const A=R.deltaMode,te={clientX:R.clientX,clientY:R.clientY,deltaY:R.deltaY};switch(A){case 1:te.deltaY*=16;break;case 2:te.deltaY*=100;break}return R.ctrlKey&&!b&&(te.deltaY*=10),te}function Ae(R){R.key==="Control"&&(b=!0,i.domElement.getRootNode().addEventListener("keyup",me,{passive:!0,capture:!0}))}function me(R){R.key==="Control"&&(b=!1,i.domElement.getRootNode().removeEventListener("keyup",me,{passive:!0,capture:!0}))}function ge(R){i.enabled===!1||i.enablePan===!1||Ce(R)}function Le(R){switch(ze(R),w.length){case 1:switch(i.touches.ONE){case Bi.ROTATE:if(i.enableRotate===!1)return;Fe(R),a=n.TOUCH_ROTATE;break;case Bi.PAN:if(i.enablePan===!1)return;Ze(R),a=n.TOUCH_PAN;break;default:a=n.NONE}break;case 2:switch(i.touches.TWO){case Bi.DOLLY_PAN:if(i.enableZoom===!1&&i.enablePan===!1)return;$e(R),a=n.TOUCH_DOLLY_PAN;break;case Bi.DOLLY_ROTATE:if(i.enableZoom===!1&&i.enableRotate===!1)return;Qe(R),a=n.TOUCH_DOLLY_ROTATE;break;default:a=n.NONE}break;default:a=n.NONE}a!==n.NONE&&i.dispatchEvent(Pc)}function he(R){switch(ze(R),a){case n.TOUCH_ROTATE:if(i.enableRotate===!1)return;nt(R),i.update();break;case n.TOUCH_PAN:if(i.enablePan===!1)return;Re(R),i.update();break;case n.TOUCH_DOLLY_PAN:if(i.enableZoom===!1&&i.enablePan===!1)return;We(R),i.update();break;case n.TOUCH_DOLLY_ROTATE:if(i.enableZoom===!1&&i.enableRotate===!1)return;Be(R),i.update();break;default:a=n.NONE}}function we(R){i.enabled!==!1&&R.preventDefault()}function Xe(R){w.push(R.pointerId)}function De(R){delete L[R.pointerId];for(let A=0;A<w.length;A++)if(w[A]==R.pointerId){w.splice(A,1);return}}function ve(R){for(let A=0;A<w.length;A++)if(w[A]==R.pointerId)return!0;return!1}function ze(R){let A=L[R.pointerId];A===void 0&&(A=new Ne,L[R.pointerId]=A),A.set(R.pageX,R.pageY)}function Ve(R){const A=R.pointerId===w[0]?w[1]:w[0];return L[A]}i.domElement.addEventListener("contextmenu",we),i.domElement.addEventListener("pointerdown",dt),i.domElement.addEventListener("pointercancel",S),i.domElement.addEventListener("wheel",le,{passive:!1}),i.domElement.getRootNode().addEventListener("keydown",Ae,{passive:!0,capture:!0}),this.update()}}const Hr=44,Qs=22,Jr=44,$o=Hr*Qs*Jr,ca=1200,da=300,Lc=1,y_=1,M_=2,S_=3,b_=4,E_=5,_s={[y_]:new ke(5025616),[M_]:new ke(9262372),[S_]:new ke(10395294),[b_]:new ke(7901340),[E_]:new ke(4545124)},xs={cannon:{radius:3,delay:0,speed:28,color:11184810,sparksPerVoxel:3,debrisPerVoxel:4,shake:.4},bomb:{radius:6,delay:1200,speed:10,color:16733440,sparksPerVoxel:4,debrisPerVoxel:6,shake:1.2,gravityAffected:!0},laser:{radius:1,delay:0,speed:60,color:16711680,sparksPerVoxel:2,debrisPerVoxel:2,shake:.1,isLaser:!0},cluster:{radius:2,delay:0,speed:22,color:16763904,sparksPerVoxel:3,debrisPerVoxel:4,shake:.6,subCount:5},nuke:{radius:13,delay:800,speed:7,color:65484,sparksPerVoxel:6,debrisPerVoxel:10,shake:3,isNuke:!0}},Sw={cannon:{icon:"💣",name:"CANNON",info:"R=3  Fast"},bomb:{icon:"💥",name:"BOMB",info:"R=6  Arcing"},laser:{icon:"🔴",name:"LASER",info:"Hold to drill"},cluster:{icon:"🌟",name:"CLUSTER",info:"R=2×5 Multi"},nuke:{icon:"☢️",name:"NUKE",info:"R=13 KABOOM"}};function Qo(t,e,r){return t+Hr*(e+Qs*r)}function wm(t,e,r){return t>=0&&t<Hr&&e>=0&&e<Qs&&r>=0&&r<Jr}function Jo(t){const e=Math.sin(t)*43758.5453123;return e-Math.floor(e)}function el(t,e){const r=Math.floor(t),i=Math.floor(e),n=t-r,a=e-i,s=n*n*(3-2*n),o=a*a*(3-2*a),l=Jo(r+i*57),u=Jo(r+1+i*57),h=Jo(r+(i+1)*57),f=Jo(r+1+(i+1)*57);return l+(u-l)*s+(h-l)*o+(f-u+l-h)*s*o}function bw(t,e){return el(t*.08,e*.08)*.55+el(t*.2,e*.2)*.28+el(t*.5,e*.5)*.12+el(t*1.2,e*1.2)*.05}function Ew(){const t=cr.useRef(null),e=cr.useRef(null),r=cr.useRef(null),[i,n]=cr.useState(0),[a,s]=cr.useState("cannon"),[o,l]=cr.useState("Tap/click terrain to fire • Drag to rotate • Pinch to zoom • 1-5: weapons • R: restart"),u=cr.useRef("cannon"),h=cr.useRef(0),f=cr.useCallback(d=>{u.current=d,s(d)},[]);return cr.useEffect(()=>{const d=new Uint8Array($o),p=new Int32Array($o),_=new Int32Array($o).fill(-1);let x=0,m=[];const c=Array.from({length:ca},()=>({x:0,y:0,z:0,vx:0,vy:0,vz:0,rx:0,ry:0,rz:0,angVx:0,angVy:0,angVz:0,life:0,maxLife:1,r:1,g:1,b:1,active:!1})),g=Array.from({length:da},()=>({x:0,y:0,z:0,vx:0,vy:0,vz:0,life:0,maxLife:1,r:1,g:1,b:1,scale:.1,active:!1}));let v=null,M=null,P=null,T=0,w=0;const L=new Rt,b=new Rt,y=new Rt,U=new Ne,B=new xw,V=new Set;let q=-1,J=!1,K=!1,ne={x:0,y:0},I={x:0,y:0},Z=!1,re=0,xe,fe,Ue,Y,ee,ae,ue,Ce,Fe;function Ze(){d.fill(0),_.fill(-1),x=0;for(let z=0;z<Hr;z++)for(let H=0;H<Jr;H++){const $=bw(z,H),N=Math.floor(3+$*(Qs-5));for(let pe=0;pe<=N;pe++){let be;pe===N?be=y_:pe>=N-2?be=M_:pe>=N-6?be=S_:pe>=1?be=b_:be=E_,d[Qo(z,pe,H)]=be}}for(let z=0;z<Hr;z++)for(let H=0;H<Qs;H++)for(let $=0;$<Jr;$++){const N=Qo(z,H,$);if(!d[N])continue;const pe=x++;p[pe]=N,_[N]=pe,L.position.set(z,H,$),L.updateMatrix(),ae.setMatrixAt(pe,L.matrix),ae.setColorAt(pe,_s[d[N]])}ae.count=x,ae.instanceMatrix.needsUpdate=!0,ae.instanceColor&&(ae.instanceColor.needsUpdate=!0)}function D(z){const H=_[z];if(H<0)return;const $=x-1;if(H!==$){const N=p[$];ae.getMatrixAt($,L.matrix),ae.setMatrixAt(H,L.matrix);const pe=new ke;ae.getColorAt($,pe),ae.setColorAt(H,pe),p[H]=N,_[N]=H}_[z]=-1,x--,ae.count=x}function $e(z,H,$,N,pe,be,Ge,He){let Ye=0;const rt=z-pe,tt=$-Ge,st=Math.sqrt(rt*rt+tt*tt)||1,Gt=rt/st,Wt=tt/st;for(let pt=0;pt<ca&&Ye<He;pt++){if(c[pt].active)continue;const ot=c[pt];ot.active=!0,ot.x=z,ot.y=H,ot.z=$,ot.vx=(Math.random()-.5)*16+Gt*9,ot.vy=Math.random()*14+5,ot.vz=(Math.random()-.5)*16+Wt*9,ot.rx=Math.random()*Math.PI*2,ot.ry=Math.random()*Math.PI*2,ot.rz=Math.random()*Math.PI*2,ot.angVx=(Math.random()-.5)*14,ot.angVy=(Math.random()-.5)*14,ot.angVz=(Math.random()-.5)*14,ot.life=3+Math.random()*1.5,ot.maxLife=ot.life,ot.r=N.r,ot.g=N.g,ot.b=N.b,Ye++}}function Qe(z){const H=new ke;for(let $=0;$<ca;$++){const N=c[$];if(!N.active){b.scale.setScalar(0),b.position.set(0,-999,0),b.updateMatrix(),ue.setMatrixAt($,b.matrix);continue}if(N.vy-=22*z,N.x+=N.vx*z,N.y+=N.vy*z,N.z+=N.vz*z,N.rx+=N.angVx*z,N.ry+=N.angVy*z,N.rz+=N.angVz*z,N.life-=z,N.y<.45&&N.vy<-1&&(N.y=.45,N.vy*=-.32,N.vx*=.65,N.vz*=.65,N.angVx*=.7,N.angVz*=.7),N.life<=0){N.active=!1,b.scale.setScalar(0),b.position.set(0,-999,0),b.updateMatrix(),ue.setMatrixAt($,b.matrix);continue}const pe=Math.min(N.life/.6,1);b.position.set(N.x,N.y,N.z),b.rotation.set(N.rx,N.ry,N.rz),b.scale.setScalar(pe),b.updateMatrix(),ue.setMatrixAt($,b.matrix);const be=.5+N.life/N.maxLife*.5;H.setRGB(N.r*be,N.g*be,N.b*be),ue.setColorAt($,H)}ue.instanceMatrix.needsUpdate=!0,ue.instanceColor&&(ue.instanceColor.needsUpdate=!0)}function nt(z,H,$,N,pe){let be=0;for(let Ge=0;Ge<da&&be<pe;Ge++){if(g[Ge].active)continue;const He=g[Ge];He.active=!0,He.x=z,He.y=H,He.z=$,He.vx=(Math.random()-.5)*10,He.vy=Math.random()*7+2,He.vz=(Math.random()-.5)*10,He.life=.5+Math.random()*.4,He.maxLife=He.life,He.r=N.r,He.g=N.g,He.b=N.b,He.scale=.08+Math.random()*.1,be++}}function Re(z){const H=new ke;for(let $=0;$<da;$++){const N=g[$];if(!N.active){y.scale.setScalar(0),y.position.set(0,-999,0),y.updateMatrix(),Ce.setMatrixAt($,y.matrix);continue}if(N.vy-=18*z,N.x+=N.vx*z,N.y+=N.vy*z,N.z+=N.vz*z,N.life-=z,N.life<=0||N.y<-5){N.active=!1,y.scale.setScalar(0),y.position.set(0,-999,0),y.updateMatrix(),Ce.setMatrixAt($,y.matrix);continue}const pe=N.life/N.maxLife;y.position.set(N.x,N.y,N.z),y.scale.setScalar(N.scale*pe),y.updateMatrix(),Ce.setMatrixAt($,y.matrix),H.setRGB(N.r,N.g*pe,.1),Ce.setColorAt($,H)}Ce.instanceMatrix.needsUpdate=!0,Ce.instanceColor&&(Ce.instanceColor.needsUpdate=!0)}function Je(z,H){const $=new _i,N=new Kl(.4,.7,32),pe=new Is({color:H,transparent:!0,opacity:.9,side:jr}),be=new mt(N,pe);be.rotation.x=-Math.PI/2,$.add(be);const Ge=new Ia(.04,.04,2.2,6),He=new Is({color:H,transparent:!0,opacity:.85}),Ye=new mt(Ge,He);Ye.position.y=1.1,$.add(Ye);const rt=new Mn(H,4,6);$.add(rt),$.position.set(z.x,z.y+.05,z.z),fe.add($);const tt=Date.now(),st=1200,Gt=()=>{const Wt=Date.now()-tt,pt=Math.max(0,1-Wt/st);if(pt<=0){fe.remove($),pe.dispose(),He.dispose(),N.dispose(),Ge.dispose();return}pe.opacity=.9*pt,He.opacity=.85*pt,rt.intensity=4*pt;const ot=1+(1-pt)*.5;$.scale.setScalar(ot),requestAnimationFrame(Gt)};requestAnimationFrame(Gt)}function We(z){if(!P){const $=new _i,N=new Kl(.3,.55,24),pe=new Is({color:16716049,transparent:!0,opacity:.85,side:jr}),be=new mt(N,pe);be.rotation.x=-Math.PI/2,$.add(be),P=$,fe.add($)}P.position.set(z.x,z.y+.05,z.z);const H=Math.sin(Date.now()*.012)*.5+.5;P.scale.setScalar(.8+H*.6)}function Be(){P&&(fe.remove(P),P=null)}function dt(z,H,$,N,pe,be){let Ge=0;const He=N*N;for(let Ye=Math.floor(z-N);Ye<=Math.ceil(z+N);Ye++)for(let rt=Math.floor(H-N);rt<=Math.ceil(H+N);rt++)for(let tt=Math.floor($-N);tt<=Math.ceil($+N);tt++){if(!wm(Ye,rt,tt))continue;const st=Ye-z,Gt=rt-H,Wt=tt-$;if(st*st+Gt*Gt+Wt*Wt>He)continue;const pt=Qo(Ye,rt,tt);if(!d[pt])continue;const ot=d[pt];$e(Ye,rt,tt,_s[ot],z,H,$,be),nt(Ye,rt,tt,_s[ot],pe),d[pt]=0,D(pt),Ge++}return ae.instanceMatrix.needsUpdate=!0,ae.instanceColor&&(ae.instanceColor.needsUpdate=!0),Ge}function C(z,H,$,N,pe,be,Ge,He){let Ye=0;const rt=40;for(let tt=0;tt<rt;tt++){const st=Math.round(z+N*tt),Gt=Math.round(H+pe*tt),Wt=Math.round($+be*tt);if(!wm(st,Gt,Wt))break;const pt=Qo(st,Gt,Wt);if(d[pt]){const ot=d[pt];$e(st,Gt,Wt,_s[ot],z,H,$,He),nt(st,Gt,Wt,_s[ot],Ge),d[pt]=0,D(pt),Ye++}}return ae.instanceMatrix.needsUpdate=!0,ae.instanceColor&&(ae.instanceColor.needsUpdate=!0),Ye}function S(){const z=new Hi(.4,10,8),H=new tr({color:2236962,metalness:.95,roughness:.15}),$=new mt(z,H),N=new Mn(8947848,1.2,5);return $.add(N),{obj:$,animLight:N}}function j(){const z=new _i,H=new Hi(.5,10,8),$=new tr({color:1118481,metalness:.7,roughness:.4});z.add(new mt(H,$));const N=new Ia(.03,.03,.45,5),pe=new tr({color:9127187}),be=new mt(N,pe);be.position.set(.1,.55,0),be.rotation.z=.4,z.add(be);const Ge=new Hi(.07,4,4),He=new tr({color:16763904,emissive:16755200,emissiveIntensity:2}),Ye=new mt(Ge,He);Ye.position.set(.22,.78,0),z.add(Ye);const rt=new Mn(16737792,2.5,6);return rt.position.set(.22,.78,0),z.add(rt),{obj:z,animLight:rt}}function ie(){const z=new _i,H=new Hi(.35,8,6),$=new tr({color:16755200,emissive:16755200,emissiveIntensity:1.2,metalness:.3,roughness:.4});z.add(new mt(H,$));const N=new tr({color:16733440,emissive:16724736,emissiveIntensity:.8});for(let be=0;be<4;be++){const Ge=new Hi(.13,5,4),He=new mt(Ge,N),Ye=be/4*Math.PI*2;He.position.set(Math.cos(Ye)*.42,0,Math.sin(Ye)*.42),z.add(He)}const pe=new Mn(16755200,2,6);return z.add(pe),{obj:z,animLight:pe}}function le(){const z=new _i,H=new Ia(.16,.22,1.3,8),$=new tr({color:7833753,metalness:.85,roughness:.2});z.add(new mt(H,$));const N=new ql(.16,.55,8),pe=new tr({color:13378082,metalness:.7,roughness:.3}),be=new mt(N,pe);be.position.y=.92,z.add(be);const Ge=new tr({color:5596791,metalness:.8});for(let st=0;st<3;st++){const Gt=new bi(.06,.35,.45),Wt=new mt(Gt,Ge),pt=st/3*Math.PI*2;Wt.position.set(Math.cos(pt)*.22,-.55,Math.sin(pt)*.22),Wt.rotation.y=pt,z.add(Wt)}const He=new Mn(65484,4,10);He.position.y=-.8,z.add(He);const Ye=new ql(.14,.4,8),rt=new tr({color:65484,emissive:65484,emissiveIntensity:2,transparent:!0,opacity:.7}),tt=new mt(Ye,rt);return tt.rotation.x=Math.PI,tt.position.y=-.9,z.add(tt),{obj:z,animLight:He}}function se(z){var H;switch(z){case"cannon":return S();case"bomb":return j();case"cluster":return ie();case"nuke":return le();default:{const $=new Hi(.3,6,6),N=new tr({color:((H=xs[z])==null?void 0:H.color)??16777215});return{obj:new mt($,N)}}}}function Ae(z,H,$){const N=xs[$],pe=H.clone().sub(z).normalize(),{obj:be,animLight:Ge}=se($);be.position.copy(z),$==="nuke"&&be.quaternion.setFromUnitVectors(new O(0,1,0),pe),fe.add(be),m.push({mesh:be,dir:pe,speed:N.speed,target:H.clone(),weaponKey:$,exploded:!1,startDist:z.distanceTo(H),travelDist:0,animLight:Ge,gravityAffected:N.gravityAffected})}function me(z){const H=Date.now();for(let $=m.length-1;$>=0;$--){const N=m[$];if(N.exploded){m.splice($,1);continue}N.animLight&&(N.weaponKey==="bomb"?N.animLight.intensity=1.8+Math.sin(H*.025)*.7:N.weaponKey==="nuke"?N.animLight.intensity=3.5+Math.sin(H*.015)*1.5:N.weaponKey==="cluster"&&(N.animLight.intensity=1.5+Math.sin(H*.03)*.5)),N.weaponKey==="cluster"&&(N.mesh.rotation.z+=5*z),N.gravityAffected&&(N.dir.y-=9.8/N.speed*z,N.dir.y<-.9&&(N.dir.y=-.9),N.dir.normalize()),N.weaponKey==="nuke"&&N.mesh.quaternion.setFromUnitVectors(new O(0,1,0),N.dir);const pe=N.speed*z;N.mesh.position.addScaledVector(N.dir,pe),N.travelDist+=pe,N.travelDist>=N.startDist&&(N.exploded=!0,ge(N.target,N.weaponKey),fe.remove(N.mesh),m.splice($,1))}}function ge(z,H){const $=xs[H],N=Math.round(z.x),pe=Math.round(z.y),be=Math.round(z.z);let Ge=0;if($.isLaser){const Ye=z.clone().normalize();Ge=C(N,pe,be,Ye.x,Ye.y,Ye.z,$.sparksPerVoxel,$.debrisPerVoxel)}else if($.subCount){Ge+=dt(N,pe,be,$.radius,$.sparksPerVoxel,$.debrisPerVoxel);for(let Ye=0;Ye<$.subCount;Ye++){const rt=N+Math.round((Math.random()-.5)*8),tt=pe+Math.round(Math.random()*3),st=be+Math.round((Math.random()-.5)*8);Ge+=dt(rt,tt,st,$.radius,$.sparksPerVoxel,$.debrisPerVoxel)}}else Ge=dt(N,pe,be,$.radius,$.sparksPerVoxel,$.debrisPerVoxel);h.current+=Ge,De(),$.shake>0&&ze($.shake),$.isNuke&&Ve();const He=new Mn($.color,8,$.radius*7);He.position.set(N,pe,be),fe.add(He),setTimeout(()=>fe.remove(He),350),Ge>0&&ve(Ge,H)}function Le(){v&&(fe.remove(v),v=null),M&&(fe.remove(M),M=null),Be()}function he(z,H,$){v&&fe.remove(v);const N=[z.clone(),H.clone()],pe=new Or().setFromPoints(N),be=new __({color:16716049,linewidth:3,transparent:!0,opacity:.95});v=new fw(pe,be),fe.add(v),M||(M=new Mn(16711680,5,10),fe.add(M)),M.position.copy(H),We($)}function we(z,H){U.x=z/Y.domElement.clientWidth*2-1,U.y=-(H/Y.domElement.clientHeight)*2+1,B.setFromCamera(U,Ue);const $=B.intersectObject(ae);if(!$.length){Le();return}const N=$[0].point.clone(),pe=B.ray.direction.clone(),be=Math.round(N.x),Ge=Math.round(N.y),He=Math.round(N.z),Ye=N.clone().addScaledVector(pe,50);he(Ue.position,Ye,N);const rt=xs.laser,tt=C(be,Ge,He,pe.x,pe.y,pe.z,rt.sparksPerVoxel,rt.debrisPerVoxel);tt>0&&(h.current+=tt,De(),ze(rt.shake),ve(tt,"laser"))}function Xe(z,H){U.x=z/Y.domElement.clientWidth*2-1,U.y=-(H/Y.domElement.clientHeight)*2+1,B.setFromCamera(U,Ue);const $=B.intersectObject(ae);if(!$.length)return;const N=$[0].point.clone(),pe=u.current;if(pe==="laser")return;const be=xs[pe];Je(N,be.color);const Ge=Ue.position.clone().addScaledVector(N.clone().sub(Ue.position).normalize(),2);Ae(Ge,N,pe)}function De(){n(h.current);const z=r.current;z&&(z.classList.remove("bump"),z.offsetWidth,z.classList.add("bump"),setTimeout(()=>z.classList.remove("bump"),150))}function ve(z,H){const $=document.createElement("div");$.className="damage-popup";const N={cannon:"💣",bomb:"💥",laser:"🔴",cluster:"🌟",nuke:"☢️"};$.textContent=`${N[H]||"💥"} -${z}`,$.style.left=30+Math.random()*40+"%",$.style.top=30+Math.random()*30+"%",document.body.appendChild($),setTimeout(()=>$.remove(),1100)}function ze(z){T=z,w=5}function Ve(){const z=e.current;z&&(z.classList.add("active"),setTimeout(()=>z.classList.remove("active"),60)),fe.background=new ke(16777215),setTimeout(()=>{fe.background=new ke(8900331),fe.fog.color.set(8900331)},180)}function R(){m.forEach(z=>fe.remove(z.mesh)),m=[],Le(),Z=!1,ee.enabled=!0,V.clear(),q=-1,c.forEach(z=>{z.active=!1}),g.forEach(z=>{z.active=!1}),h.current=0,n(0),Ze(),l("New round started! Tap terrain to fire."),fe.background=new ke(8900331)}function A(z){u.current==="laser"&&z!=="laser"&&(Z=!1,Le(),ee.enabled=!0),f(z),l(`${{cannon:"Cannon",bomb:"Bomb",laser:"Laser Drill (hold to fire)",cluster:"Cluster Bomb",nuke:"NUKE ☢️"}[z]} selected — ${z==="laser"?"hold/tap & drag to aim laser":"tap terrain"} to fire!`)}function te(){const z=t.current;Y=new uw({canvas:z,antialias:!0}),Y.setPixelRatio(Math.min(window.devicePixelRatio,2)),Y.setSize(window.innerWidth,window.innerHeight),Y.shadowMap.enabled=!0,Y.shadowMap.type=Vv,Y.toneMapping=Gv,Y.toneMappingExposure=1.1,fe=new cw,fe.background=new ke(8900331),fe.fog=new Lh(8900331,.012),Ue=new Sr(65,window.innerWidth/window.innerHeight,.5,300),Ue.position.set(Hr/2,28,Jr*1.6),ee=new Mw(Ue,Y.domElement),ee.target.set(Hr/2,4,Jr/2),ee.enableDamping=!0,ee.dampingFactor=.06,ee.minDistance=8,ee.maxDistance=140,ee.maxPolarAngle=Math.PI/2.05,ee.mouseButtons={LEFT:vi.ROTATE,MIDDLE:vi.DOLLY,RIGHT:vi.PAN},ee.touches={ONE:Bi.ROTATE,TWO:Bi.DOLLY_PAN},fe.add(new vw(13162751,.6));const H=new vm(16775392,1.4);H.position.set(Hr*.6,60,Jr*.4),H.castShadow=!0,H.shadow.mapSize.set(2048,2048),H.shadow.camera.left=-70,H.shadow.camera.right=70,H.shadow.camera.top=70,H.shadow.camera.bottom=-70,H.shadow.camera.far=200,H.shadow.bias=-.001,fe.add(H),fe.add(new vm(8952268,.4).translateX(-Hr).translateY(20).translateZ(-Jr)),fe.add(new pw(8900331,4863784,.5));const $=new ao(Hr+20,Jr+20),N=new tr({color:2759178,roughness:1}),pe=new mt($,N);pe.rotation.x=-Math.PI/2,pe.position.set(Hr/2,-.5,Jr/2),pe.receiveShadow=!0,fe.add(pe);const be=new bi(Lc,Lc,Lc),Ge=new tr({roughness:.85,metalness:.05});ae=new Tc(be,Ge,$o),ae.instanceMatrix.setUsage(Ju),ae.castShadow=!0,ae.receiveShadow=!0,ae.count=0,fe.add(ae);const He=new bi(.9,.9,.9),Ye=new tr({roughness:.75,metalness:.1});ue=new Tc(He,Ye,ca),ue.instanceMatrix.setUsage(Ju),ue.castShadow=!1,ue.count=ca,fe.add(ue);const rt=new bi(1,1,1),tt=new tr({roughness:.5,metalness:0});Ce=new Tc(rt,tt,da),Ce.instanceMatrix.setUsage(Ju),Ce.count=da,fe.add(Ce);for(let st=0;st<ca;st++)b.scale.setScalar(0),b.position.set(0,-999,0),b.updateMatrix(),ue.setMatrixAt(st,b.matrix);for(let st=0;st<da;st++)y.scale.setScalar(0),y.position.set(0,-999,0),y.updateMatrix(),Ce.setMatrixAt(st,y.matrix);ue.instanceMatrix.needsUpdate=!0,Ce.instanceMatrix.needsUpdate=!0,Fe=new _w}function W(){const z=Y.domElement;z.addEventListener("pointerdown",H=>{if(V.add(H.pointerId),V.size>1){Z&&(Z=!1,Le(),ee.enabled=!0),J=!1,q=-1;return}q=H.pointerId,J=!0,K=!1,ne={x:H.clientX,y:H.clientY},I={x:H.clientX,y:H.clientY},u.current==="laser"&&(Z=!0,ee.enabled=!1)}),z.addEventListener("pointermove",H=>{if(H.pointerId===q&&(I={x:H.clientX,y:H.clientY}),!J||H.pointerId!==q)return;const $=H.clientX-ne.x,N=H.clientY-ne.y,pe=H.pointerType==="touch"?12:5;Math.sqrt($*$+N*N)>pe&&(K=!0,Z||(ee.enabled=!0))}),z.addEventListener("pointerup",H=>{V.delete(H.pointerId),H.pointerId===q&&(Z?(Z=!1,Le(),ee.enabled=!0):K||Xe(H.clientX,H.clientY),J=!1,K=!1,q=-1,Z||(ee.enabled=!0))}),z.addEventListener("pointercancel",H=>{V.delete(H.pointerId),H.pointerId===q&&(Z&&(Z=!1,Le()),ee.enabled=!0,J=!1,K=!1,q=-1)}),window.addEventListener("keydown",Q),window.addEventListener("resize",oe),window.addEventListener("vd-restart",Se),window.addEventListener("vd-select-weapon",at)}function Q(z){const H={1:"cannon",2:"bomb",3:"laser",4:"cluster",5:"nuke"};H[z.key]&&A(H[z.key]),(z.key==="r"||z.key==="R")&&R()}function oe(){Ue.aspect=window.innerWidth/window.innerHeight,Ue.updateProjectionMatrix(),Y.setSize(window.innerWidth,window.innerHeight)}function Se(){R()}function at(z){A(z.detail)}function ht(){xe=requestAnimationFrame(ht);const z=Math.min(Fe.getDelta(),.05);if(ee.update(),T>0&&(Ue.position.x+=(Math.random()-.5)*T*.3,Ue.position.y+=(Math.random()-.5)*T*.15,T-=w*z,T<0&&(T=0)),Z){const H=Date.now();H-re>55&&(re=H,we(I.x,I.y))}Qe(z),Re(z),me(z),Y.render(fe,Ue)}return te(),Ze(),W(),ht(),()=>{cancelAnimationFrame(xe),window.removeEventListener("keydown",Q),window.removeEventListener("resize",oe),window.removeEventListener("vd-restart",Se),window.removeEventListener("vd-select-weapon",at),Le(),ee.dispose(),Y.dispose()}},[]),cr.useEffect(()=>{u.current=a},[a]),Ut.jsxs("div",{style:{width:"100%",height:"100%",position:"relative"},children:[Ut.jsx("canvas",{ref:t,id:"game-canvas",style:{position:"absolute",top:0,left:0,width:"100%",height:"100%",display:"block",touchAction:"none"}}),Ut.jsxs("div",{id:"hud",children:[Ut.jsxs("div",{id:"top-bar",children:[Ut.jsx("span",{id:"game-title",children:"💥 VOXEL DESTROYER"}),Ut.jsxs("div",{id:"counter-display",children:[Ut.jsx("span",{id:"counter-label",children:"VOXELS DESTROYED"}),Ut.jsx("span",{id:"counter-value",ref:r,children:i.toLocaleString()})]}),Ut.jsx("button",{id:"restart-btn",onClick:()=>window.dispatchEvent(new CustomEvent("vd-restart")),children:"🔄 NEW ROUND"})]}),Ut.jsxs("div",{id:"weapon-bar",children:[Ut.jsx("span",{className:"weapon-label",children:"WEAPONS"}),Object.entries(Sw).map(([d,p])=>Ut.jsxs("button",{className:`weapon-btn${a===d?" active":""}`,onClick:()=>window.dispatchEvent(new CustomEvent("vd-select-weapon",{detail:d})),children:[Ut.jsx("span",{className:"w-icon",children:p.icon}),Ut.jsx("span",{className:"w-name",children:p.name}),Ut.jsx("span",{className:"w-info",children:p.info})]},d))]}),Ut.jsx("div",{id:"status-bar",children:Ut.jsx("span",{id:"status-text",children:o})}),Ut.jsx("div",{id:"flash-overlay",ref:e})]})]})}zv(document.getElementById("root")).render(Ut.jsx(cr.StrictMode,{children:Ut.jsx(Ew,{})}));
