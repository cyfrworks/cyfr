;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A catalyst whose `run` hands its whole input string to
;; `cyfr:http/fetch`'s `request` as the request JSON and answers the
;; fetch's answer string as its output. It reads no credential and writes
;; no request of its own: what it asks for is what its input names. An
;; input naming a `connection` is a request CYFR makes with the
;; credential that need is bound to attached; one that also sets an
;; `Authorization` header is refused by shape, in the runner and again
;; at CYFR.
;;
;; The canonical ABI of `request: func(json-request: string) -> string`
;; lowers to (pointer, length, return pointer): the host writes the
;; answer's pointer and length at the return pointer, allocating the
;; string through `cabi_realloc`, a bump allocator that grows the memory
;; as an answer needs it. `run` answers the same return area, which
;; holds the answer string. Built by `build.sh` (README.md).
(module
  (import "cyfr:http/fetch@0.1.0" "request" (func $request (param i32 i32 i32)))
  (memory $io (export "memory") 1)
  (global $heap (mut i32) (i32.const 1024))
  (func (export "cabi_realloc") (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32) (result i32)
    (local $ptr i32)
    (local $end i32)
    ;; The next address aligned to `align`, a power of two.
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
    (i32.const 16)))
