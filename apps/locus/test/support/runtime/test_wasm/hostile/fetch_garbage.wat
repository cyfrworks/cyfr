;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A catalyst whose `run` hands `cyfr:http/fetch`'s `request` the text
;; `{"method":`, which is no JSON, whatever its input, and answers the
;; request's answer. Its ABI is `attached_header_probe`'s. Built by
;; `build.sh` (README.md).
(module
  (import "cyfr:http/fetch@0.1.0" "request" (func $request (param i32 i32 i32)))
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
  (data (i32.const 256) "{\"method\":")
  (func (export "cyfr:catalyst/run@0.1.0#run") (param $ptr i32) (param $len i32) (result i32)
    (call $request (i32.const 256) (i32.const 10) (i32.const 16))
    (i32.const 16)))
