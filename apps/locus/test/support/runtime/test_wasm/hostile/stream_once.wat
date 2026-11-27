;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A catalyst whose `run` opens one stream with its whole input as the
;; request JSON (`cyfr:http/streaming`'s `request`), reads it once, closes
;; it and answers that one read's answer as its output: a guest that reads
;; part of a stream and closes it early, then completes. A request the
;; host refuses answers the refusal as the output, unread and unclosed.
;;
;; The canonical ABI of each `func(string) -> string` lowers to (pointer,
;; length, return pointer); the host writes the answer's pointer and
;; length at the return pointer, allocating through `cabi_realloc`, a bump
;; allocator. `request` answers `{"handle":"<h>"}` exactly, so the handle
;; is the answer from its 12th byte to its last two. Built by `build.sh`
;; (README.md).
(module
  (import "cyfr:http/streaming@0.1.0" "request" (func $request (param i32 i32 i32)))
  (import "cyfr:http/streaming@0.1.0" "read" (func $read (param i32 i32 i32)))
  (import "cyfr:http/streaming@0.1.0" "close" (func $close (param i32 i32 i32)))
  (memory $io (export "memory") 1)
  (global $heap (mut i32) (i32.const 1024))
  (func (export "cabi_realloc") (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32) (result i32)
    (local $ptr i32)
    (local $end i32)
    (local.set $ptr
      (i32.and
        (i32.add (global.get $heap) (i32.sub (local.get $align) (i32.const 1)))
        (i32.sub (i32.const 0) (local.get $align))))
    (local.set $end (i32.add (local.get $ptr) (local.get $new_size)))
    (block $fits
      (loop $grow
        (br_if $fits (i32.le_u (local.get $end) (i32.mul (memory.size) (i32.const 65536))))
        (if (i32.eq (memory.grow (i32.const 1)) (i32.const -1)) (then unreachable))
        (br $grow)))
    (global.set $heap (local.get $end))
    (local.get $ptr))
  (func (export "cyfr:catalyst/run@0.1.0#run") (param $ptr i32) (param $len i32) (result i32)
    (local $answer i32)
    (local $handle i32)
    (local $handle_len i32)
    (call $request (local.get $ptr) (local.get $len) (i32.const 16))
    (local.set $answer (i32.load (i32.const 16)))
    ;; `{"error"...` rather than `{"handle"...`: the refusal is the output.
    (if (i32.ne (i32.load8_u (i32.add (local.get $answer) (i32.const 2))) (i32.const 104))
      (then (return (i32.const 16))))
    (local.set $handle (i32.add (local.get $answer) (i32.const 11)))
    (local.set $handle_len (i32.sub (i32.load (i32.const 20)) (i32.const 13)))
    (call $read (local.get $handle) (local.get $handle_len) (i32.const 24))
    (call $close (local.get $handle) (local.get $handle_len) (i32.const 32))
    (i32.const 24)))
