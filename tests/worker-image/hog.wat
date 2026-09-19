;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A reagent whose `compute` takes all the linear memory the engine lets one
;; guest have, and touches every page of it, so the runner holds it resident.
;; The engine bounds each memory, not the guest (`Opus.Runtime`'s store
;; limits: at most ten memories, each at most the execution's
;; `max_memory_bytes`, 64 MiB unless a consent raises it): this guest asks
;; for exactly that, ten memories of 64 MiB, 640 MiB in all, and nothing the
;; engine refuses. It first proves the engine's own bound holds: growing
;; its first memory past 64 MiB must fail, or it traps. Then it grows that
;; memory to 64 MiB and writes one byte to every 4 KiB page of all ten,
;; and answers its input unchanged. A runner whose memory bound is below
;; what it holds is ended by the kernel while it writes; a runner with
;; room for it completes.
;;
;; The canonical ABI of `cyfr:reagent/compute@0.1.0` is echo.wat's: the
;; export takes the string's pointer and length and answers a pointer to a
;; return area holding the result string's pointer and length.
;;
;; To regenerate (the memories past the first need multi-memory):
;;   wat2wasm --enable-multi-memory hog.wat -o hog.core.wasm
;;   wasm-tools component embed ../../wit/reagent --world reagent hog.core.wasm -o hog.embedded.wasm
;;   wasm-tools component new hog.embedded.wasm -o hog.wasm
(module
  (memory $io (export "memory") 1)
  (memory $m1 1024)
  (memory $m2 1024)
  (memory $m3 1024)
  (memory $m4 1024)
  (memory $m5 1024)
  (memory $m6 1024)
  (memory $m7 1024)
  (memory $m8 1024)
  (memory $m9 1024)
  (global $heap (mut i32) (i32.const 1024))
  (func (export "cabi_realloc") (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $heap))
    (global.set $heap (i32.add (global.get $heap) (i32.add (local.get $new_size) (i32.const 8))))
    (local.get $ptr))
  (func $touch_io
    (local $at i32)
    (loop $page
      (i32.store8 $io (local.get $at) (i32.const 1))
      (local.set $at (i32.add (local.get $at) (i32.const 4096)))
      (br_if $page (i32.lt_u (local.get $at) (i32.const 67108864)))))
  (func $touch_m1
    (local $at i32)
    (loop $page
      (i32.store8 $m1 (local.get $at) (i32.const 1))
      (local.set $at (i32.add (local.get $at) (i32.const 4096)))
      (br_if $page (i32.lt_u (local.get $at) (i32.const 67108864)))))
  (func $touch_m2
    (local $at i32)
    (loop $page
      (i32.store8 $m2 (local.get $at) (i32.const 1))
      (local.set $at (i32.add (local.get $at) (i32.const 4096)))
      (br_if $page (i32.lt_u (local.get $at) (i32.const 67108864)))))
  (func $touch_m3
    (local $at i32)
    (loop $page
      (i32.store8 $m3 (local.get $at) (i32.const 1))
      (local.set $at (i32.add (local.get $at) (i32.const 4096)))
      (br_if $page (i32.lt_u (local.get $at) (i32.const 67108864)))))
  (func $touch_m4
    (local $at i32)
    (loop $page
      (i32.store8 $m4 (local.get $at) (i32.const 1))
      (local.set $at (i32.add (local.get $at) (i32.const 4096)))
      (br_if $page (i32.lt_u (local.get $at) (i32.const 67108864)))))
  (func $touch_m5
    (local $at i32)
    (loop $page
      (i32.store8 $m5 (local.get $at) (i32.const 1))
      (local.set $at (i32.add (local.get $at) (i32.const 4096)))
      (br_if $page (i32.lt_u (local.get $at) (i32.const 67108864)))))
  (func $touch_m6
    (local $at i32)
    (loop $page
      (i32.store8 $m6 (local.get $at) (i32.const 1))
      (local.set $at (i32.add (local.get $at) (i32.const 4096)))
      (br_if $page (i32.lt_u (local.get $at) (i32.const 67108864)))))
  (func $touch_m7
    (local $at i32)
    (loop $page
      (i32.store8 $m7 (local.get $at) (i32.const 1))
      (local.set $at (i32.add (local.get $at) (i32.const 4096)))
      (br_if $page (i32.lt_u (local.get $at) (i32.const 67108864)))))
  (func $touch_m8
    (local $at i32)
    (loop $page
      (i32.store8 $m8 (local.get $at) (i32.const 1))
      (local.set $at (i32.add (local.get $at) (i32.const 4096)))
      (br_if $page (i32.lt_u (local.get $at) (i32.const 67108864)))))
  (func $touch_m9
    (local $at i32)
    (loop $page
      (i32.store8 $m9 (local.get $at) (i32.const 1))
      (local.set $at (i32.add (local.get $at) (i32.const 4096)))
      (br_if $page (i32.lt_u (local.get $at) (i32.const 67108864)))))
  (func (export "cyfr:reagent/compute@0.1.0#compute") (param $ptr i32) (param $len i32) (result i32)
    ;; Past 64 MiB the engine refuses the growth (-1); if it did not, its
    ;; bound is not what this guest assumes, and the guest traps.
    (if (i32.ne (memory.grow $io (i32.const 1100)) (i32.const -1))
      (then (unreachable)))
    (if (i32.eq (memory.grow $io (i32.const 1023)) (i32.const -1))
      (then (unreachable)))
    (call $touch_io)
    (call $touch_m1)
    (call $touch_m2)
    (call $touch_m3)
    (call $touch_m4)
    (call $touch_m5)
    (call $touch_m6)
    (call $touch_m7)
    (call $touch_m8)
    (call $touch_m9)
    (i32.store (i32.const 8) (local.get $ptr))
    (i32.store (i32.const 12) (local.get $len))
    (i32.const 8)))
