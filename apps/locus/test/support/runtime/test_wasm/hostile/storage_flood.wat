;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A catalyst whose `run` calls `cyfr:storage/files` `call` forever with a
;; request that is no JSON. Each call is refused before any host call and
;; is one `storage.call` event on the runner's control channel, so the
;; guest causes events as fast as it can loop; only its run's budget ends
;; it. Built by `build.sh` (README.md).
(module
  (import "cyfr:storage/files@0.1.0" "call" (func $call (param i32 i32 i32)))
  (memory (export "memory") 1)
  (data (i32.const 256) "x")
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
    (i32.const 4096))
  (func (export "cyfr:catalyst/run@0.1.0#run") (param i32 i32) (result i32)
    (loop $again
      (call $call (i32.const 256) (i32.const 1) (i32.const 64))
      (br $again))
    (i32.const 8)))
