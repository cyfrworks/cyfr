;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A catalyst whose `run` opens a stream with its input as the request and
;; closes it unread, opens a second the same way, reads it once, closes it
;; and answers that read: the first stream's answer arrives after its
;; guest closed it.
;; Its ABI is `stream_once`'s: a stream's handle is its request's answer
;; from its 12th byte to its last two, and a refused request, whose answer
;; is `{"error"...`, is the output. Built by `build.sh` (README.md).
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
    (call $request (local.get $ptr) (local.get $len) (i32.const 16))
    (if (i32.ne (i32.load8_u (i32.add (i32.load (i32.const 16)) (i32.const 2))) (i32.const 104))
      (then (return (i32.const 16))))
    (i32.store (i32.const 64) (i32.add (i32.load (i32.const 16)) (i32.const 11)))
    (i32.store (i32.const 68) (i32.sub (i32.load (i32.const 20)) (i32.const 13)))
    (call $close (i32.load (i32.const 64)) (i32.load (i32.const 68)) (i32.const 40))
    (call $request (local.get $ptr) (local.get $len) (i32.const 24))
    (if (i32.ne (i32.load8_u (i32.add (i32.load (i32.const 24)) (i32.const 2))) (i32.const 104))
      (then (return (i32.const 24))))
    (i32.store (i32.const 72) (i32.add (i32.load (i32.const 24)) (i32.const 11)))
    (i32.store (i32.const 76) (i32.sub (i32.load (i32.const 28)) (i32.const 13)))
    (call $read (i32.load (i32.const 72)) (i32.load (i32.const 76)) (i32.const 32))
    (call $close (i32.load (i32.const 72)) (i32.load (i32.const 76)) (i32.const 48))
    (i32.const 32)))
