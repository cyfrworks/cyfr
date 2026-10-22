;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A catalyst whose `run` answers `{"ran":true}` to any input but one: the
;; input `{"trap":true}`, byte for byte, reaches an `unreachable`
;; instruction, so a run of it fails as it runs. It imports nothing. Built
;; by `build.sh` (../README.md).
(module
  (memory (export "memory") 1)
  (data (i32.const 256) "{\22ran\22:true}")
  (data (i32.const 272) "{\22trap\22:true}")
  (global $heap (mut i32) (i32.const 1024))
  (func (export "cabi_realloc") (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $heap))
    (global.set $heap (i32.add (global.get $heap) (i32.add (local.get $new_size) (i32.const 8))))
    (local.get $ptr))
  (func (export "cyfr:catalyst/run@0.1.0#run") (param $ptr i32) (param $len i32) (result i32)
    ;; The input's 13 bytes against the trap input's, read only when the
    ;; input is 13 bytes long.
    (if (i32.eq (local.get $len) (i32.const 13))
      (then
        (if (i32.and
              (i64.eq (i64.load (local.get $ptr)) (i64.load (i32.const 272)))
              (i32.and
                (i32.eq (i32.load offset=8 (local.get $ptr)) (i32.load (i32.const 280)))
                (i32.eq (i32.load8_u offset=12 (local.get $ptr)) (i32.load8_u (i32.const 284)))))
          (then (unreachable)))))
    (i32.store (i32.const 8) (i32.const 256))
    (i32.store (i32.const 12) (i32.const 12))
    (i32.const 8)))
