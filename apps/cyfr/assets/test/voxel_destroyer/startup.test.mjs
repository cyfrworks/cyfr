// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The shipped game voxel-destroyer (seed/components/tinctures/local/
// voxel-destroyer): its built page run as the browser runs it, in a context
// of its own, against the few parts of a document React and three.js touch,
// on a browser whose canvas gives no WebGL context.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"
import vm from "node:vm"

import {eventually} from "../sdk/support.mjs"

const VERSION = new URL("../../../../../seed/components/tinctures/local/voxel-destroyer/0.1.3/", import.meta.url)
const entry = readFileSync(new URL("dist/index.html", VERSION), "utf8")
const script = entry.match(/<script type="module" crossorigin src="\.\/([^"]+)"/)[1]
const source = readFileSync(new URL(`dist/${script}`, VERSION), "utf8")

// A document of plain nodes: enough for React to mount, render and unmount,
// and for three.js to ask a canvas for a context it never gets.
function documentOf() {
  class Node {
    constructor(nodeType, nodeName) {
      this.nodeType = nodeType
      this.nodeName = nodeName
      this.childNodes = []
      this.parentNode = null
    }
    get ownerDocument() {
      return this === doc ? null : doc
    }
    get firstChild() {
      return this.childNodes[0] || null
    }
    get lastChild() {
      return this.childNodes.at(-1) || null
    }
    get nextSibling() {
      if (!this.parentNode) return null
      const siblings = this.parentNode.childNodes
      return siblings[siblings.indexOf(this) + 1] || null
    }
    appendChild(child) {
      return this.insertBefore(child, null)
    }
    insertBefore(child, before) {
      if (child.parentNode) child.parentNode.removeChild(child)
      const at = before ? this.childNodes.indexOf(before) : -1
      at < 0 ? this.childNodes.push(child) : this.childNodes.splice(at, 0, child)
      child.parentNode = this
      return child
    }
    removeChild(child) {
      this.childNodes.splice(this.childNodes.indexOf(child), 1)
      child.parentNode = null
      return child
    }
    get textContent() {
      return this.nodeType === 3 ? this.nodeValue : this.childNodes.map((child) => child.textContent).join("")
    }
    set textContent(text) {
      this.childNodes.forEach((child) => (child.parentNode = null))
      this.childNodes = text === "" ? [] : [doc.createTextNode(text)]
      this.childNodes.forEach((child) => (child.parentNode = this))
    }
    addEventListener() {}
    removeEventListener() {}
  }

  class Element extends Node {
    constructor(tag) {
      super(1, tag.toUpperCase())
      this.tagName = this.nodeName
      this.namespaceURI = "http://www.w3.org/1999/xhtml"
      this.attributes = {}
      this.style = {setProperty() {}, removeProperty() {}}
      this.relList = {supports: () => true}
    }
    setAttribute(name, value) {
      this.attributes[name] = String(value)
    }
    getAttribute(name) {
      return this.attributes[name] ?? null
    }
    removeAttribute(name) {
      delete this.attributes[name]
    }
    // No WebGL: the browser's answer when it or the device offers none.
    getContext() {
      return null
    }
  }

  const doc = new Node(9, "#document")
  doc.createElement = (tag) => new Element(tag)
  doc.createElementNS = (_namespace, tag) => new Element(tag)
  doc.createTextNode = (text) => Object.assign(new Node(3, "#text"), {nodeValue: String(text)})
  doc.documentElement = doc.appendChild(new Element("html"))
  doc.body = doc.documentElement.appendChild(new Element("body"))
  const root = doc.body.appendChild(new Element("div"))
  root.setAttribute("id", "root")
  doc.getElementById = (id) => (id === "root" ? root : null)
  doc.querySelectorAll = () => []
  Object.defineProperty(doc, "activeElement", {get: () => doc.body})
  return {doc, root, HTMLIFrameElement: class {}}
}

// The page in a context of its own. What it schedules runs on this
// process's event loop; an error none of the page's own code catches is
// kept, as the browser would report it, rather than ending the test.
function page() {
  const {doc, root, HTMLIFrameElement} = documentOf()
  const uncaught = []
  const logged = []
  const frames = []
  const listeners = new Set()
  const guarded =
    (schedule) =>
    (fn, ...args) =>
      schedule(() => {
        try {
          fn(...args)
        } catch (error) {
          uncaught.push(error)
        }
      })
  const context = {
    document: doc,
    HTMLIFrameElement,
    devicePixelRatio: 1,
    innerWidth: 800,
    innerHeight: 600,
    performance,
    console: {...console, error: (...args) => logged.push(args), warn() {}},
    setImmediate: guarded(setImmediate),
    setTimeout: guarded(setTimeout),
    clearTimeout,
    queueMicrotask: guarded(queueMicrotask),
    requestAnimationFrame: (fn) => frames.push(fn),
    cancelAnimationFrame() {},
    addEventListener: (type, fn) => listeners.add(`${type}:${fn}`),
    removeEventListener: (type, fn) => listeners.delete(`${type}:${fn}`),
    MutationObserver: class {
      observe() {}
    },
    fetch: () => new Promise(() => {})
  }
  context.window = context
  vm.runInNewContext(`"use strict";\n${source}`, context)
  return {root, uncaught, logged, frames, listeners}
}

test("without WebGL the game says it needs WebGL 2 in its own area, and nothing of it keeps running", async () => {
  const {root, uncaught, logged, frames, listeners} = page()

  // The game's first render draws its HUD; the renderer is made after it.
  await eventually(() => logged.length > 0 && !root.textContent.includes("WEAPONS"), {tries: 200})
  assert.deepEqual(uncaught, [])
  assert.equal(
    root.textContent,
    "💥 VOXEL DESTROYER" +
      "Voxel Destroyer needs WebGL 2, which this browser or device does not offer. " +
      "Try another browser, or turn on hardware acceleration."
  )
  const notice = root.firstChild
  assert.equal(notice.getAttribute("role"), "alert")
  assert.equal(notice.getAttribute("class"), "notice")

  // The renderer's own refusal is reported, and no frame or window listener
  // was left behind for a renderer that does not exist.
  assert.ok(logged.some((args) => String(args[0]).includes("Error creating WebGL context")))
  assert.equal(frames.length, 0)
  assert.deepEqual([...listeners], [])
})
