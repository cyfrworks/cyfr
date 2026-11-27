;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A catalyst whose `run` asks its vault (`cyfr:vault/read`) forever for a
;; name carrying a control byte (a newline), which is no field name: each
;; read is refused unreported, and is one line the runner would log. Only
;; its run's budget ends it. Built by `build.sh` (README.md).
(module
  (import "cyfr:vault/read@0.1.0" "get" (func $get (param i32 i32 i32)))
  (memory (export "memory") 1)
  (data (i32.const 256) "\0a")
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
    (i32.const 4096))
  (func (export "cyfr:catalyst/run@0.1.0#run") (param i32 i32) (result i32)
    (loop $again
      (call $get (i32.const 256) (i32.const 1) (i32.const 64))
      (br $again))
    (i32.const 8)))
