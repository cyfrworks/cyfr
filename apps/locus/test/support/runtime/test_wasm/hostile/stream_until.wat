;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A catalyst whose `run` opens one stream with its input as the request
;; and reads it, at most a hundred times, until a read hands data, an error
;; or the answer's end, and answers that read: an empty read's answer is
;; `{"data":""` and more, its tenth byte a quote. Its ABI is
;; `stream_once`'s. Built by `build.sh` (README.md).
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
    (local $n i32)
    (local $read i32)
    (call $request (local.get $ptr) (local.get $len) (i32.const 16))
    (local.set $answer (i32.load (i32.const 16)))
    (if (i32.ne (i32.load8_u (i32.add (local.get $answer) (i32.const 2))) (i32.const 104))
      (then (return (i32.const 16))))
    (local.set $handle (i32.add (local.get $answer) (i32.const 11)))
    (local.set $handle_len (i32.sub (i32.load (i32.const 20)) (i32.const 13)))
    (local.set $n (i32.const 100))
    (block $done
      (loop $again
        (call $read (local.get $handle) (local.get $handle_len) (i32.const 24))
        (local.set $read (i32.load (i32.const 24)))
        ;; Data, an error or the end: anything but `{"data":"",...` not done.
        (br_if $done (i32.ne (i32.load8_u (i32.add (local.get $read) (i32.const 9))) (i32.const 34)))
        (br_if $done (i32.eq (i32.load8_u (i32.add (local.get $read) (i32.const 18))) (i32.const 116)))
        (local.set $n (i32.sub (local.get $n) (i32.const 1)))
        (br_if $again (i32.gt_s (local.get $n) (i32.const 0)))))
    (i32.const 24)))
