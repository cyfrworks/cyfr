;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A catalyst whose `run` asks its vault (`cyfr:vault/read`) for four
;; names, in order, and answers `{"status": 200, "data": {"read": R}}`,
;; where R holds one letter per name: `O` for a value handed over, `E` for
;; a refusal. It never answers a value. The names:
;;
;;   PROBE_KEY      the field a test's projection grants
;;   PROBE_HIDDEN   a field of the same entry the projection leaves out
;;   N x 257        a name past the 256-byte bound on a field name
;;   PROBE\nKEY     a name carrying a control byte (a newline)
;;
;; The canonical ABI of `get: func(name: string) -> result<string, string>`
;; lowers to (name pointer, name length, return pointer); the host writes
;; the result's case at the return pointer (a byte, 0 for ok) and its
;; string's pointer and length after it, allocating the string through
;; `cabi_realloc`. Built by `build.sh` (README.md).
(module
  (import "cyfr:vault/read@0.1.0" "get" (func $get (param i32 i32 i32)))
  (memory $io (export "memory") 1)
  (data (i32.const 256) "PROBE_KEY")
  (data (i32.const 272) "PROBE_HIDDEN")
  (data (i32.const 288) "PROBE\0aKEY")
  (data (i32.const 512) "{\22status\22:200,\22data\22:{\22read\22:\22????\22}}")
  (global $heap (mut i32) (i32.const 4096))
  (func (export "cabi_realloc") (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $heap))
    (global.set $heap (i32.add (global.get $heap) (i32.add (local.get $new_size) (i32.const 8))))
    (local.get $ptr))
  ;; Ask for the `len` bytes at `name`, and mark the answer at `mark`.
  (func $read (param $name i32) (param $len i32) (param $mark i32)
    (call $get (local.get $name) (local.get $len) (i32.const 64))
    (i32.store8 (local.get $mark)
      (select (i32.const 69) (i32.const 79) (i32.load8_u (i32.const 64)))))
  (func (export "cyfr:catalyst/run@0.1.0#run") (param $ptr i32) (param $len i32) (result i32)
    (memory.fill (i32.const 2048) (i32.const 78) (i32.const 257))
    (call $read (i32.const 256) (i32.const 9) (i32.const 542))
    (call $read (i32.const 272) (i32.const 12) (i32.const 543))
    (call $read (i32.const 2048) (i32.const 257) (i32.const 544))
    (call $read (i32.const 288) (i32.const 9) (i32.const 545))
    (i32.store (i32.const 8) (i32.const 512))
    (i32.store (i32.const 12) (i32.const 37))
    (i32.const 8)))
