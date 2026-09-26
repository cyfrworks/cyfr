// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

/**
 * The system layer's focus order, with no DOM access: each candidate is a
 * plain description of an element (`{tabIndex, disabled, hidden}`), in
 * document order.
 */

/**
 * The positions of the candidates Tab reaches, in the order it reaches
 * them: a positive tabindex first, ascending, ties in document order; then
 * tabindex 0 in document order. A negative tabindex, a disabled control
 * and a hidden element are never reached.
 */
export function tabOrder(candidates) {
  const reachable = candidates
    .map((candidate, position) => ({...candidate, position}))
    .filter(({tabIndex, disabled, hidden}) => tabIndex >= 0 && !disabled && !hidden)

  const positive = reachable
    .filter(({tabIndex}) => tabIndex > 0)
    .sort((a, b) => a.tabIndex - b.tabIndex || a.position - b.position)

  const zero = reachable.filter(({tabIndex}) => tabIndex === 0)

  return [...positive, ...zero].map(({position}) => position)
}

/**
 * Where Tab (or Shift+Tab when `backwards`) goes from `current` in an
 * order of `length` stops: it wraps at both ends, so focus never leaves
 * the prompt. From outside the order (`current` of -1) it enters at the
 * first stop, or the last going backwards. An empty order has no stop:
 * -1.
 */
export function nextStop(length, current, backwards) {
  if (length <= 0) return -1
  if (current < 0 || current >= length) return backwards ? length - 1 : 0
  return backwards ? (current - 1 + length) % length : (current + 1) % length
}
