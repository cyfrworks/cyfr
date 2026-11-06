// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The account pages' service worker, scoped to /account/. It keeps the
// pages, their script and their stylesheet, so a browser that visited once
// signs in while the directory is unreachable (plan §9). Each is fetched
// from the network first, so a fixed page reaches the next visit, and
// served from the cache when the network fails or is slower than
// NETWORK_MS. Nothing else is touched: config.json, the directory's log and
// the registry always go to the network.

const CACHE = "cyfr-account-v1"
const FILES = ["new", "sign", "add", "recover", "devices", "account.js", "account.css"]
const NETWORK_MS = 3000

const kept = (url) => url.origin === self.location.origin && FILES.some((file) => new URL(file, self.registration.scope).pathname === url.pathname)

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      .then((cache) => Promise.all(FILES.map((file) => cache.add(new URL(file, self.registration.scope)).catch(() => {}))))
      .then(() => self.skipWaiting())
  )
})

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key.startsWith("cyfr-account-") && key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  )
})

self.addEventListener("fetch", (event) => {
  const request = event.request
  if (request.method !== "GET" || !kept(new URL(request.url))) return
  event.respondWith(respond(request))
})

async function respond(request) {
  const cache = await caches.open(CACHE)
  try {
    const response = await Promise.race([
      fetch(request),
      new Promise((_resolve, reject) => setTimeout(() => reject(new Error("slow")), NETWORK_MS))
    ])
    if (response.ok && !response.redirected) await cache.put(request.url, response.clone())
    return response
  } catch (error) {
    const cached = await cache.match(request.url)
    if (cached) return cached
    throw error
  }
}
