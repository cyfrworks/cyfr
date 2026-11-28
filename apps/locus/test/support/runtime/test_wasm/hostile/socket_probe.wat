;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A guest that opens a socket of its own through WASI, a TCP one and a
;; UDP one, and answers what the host said to each:
;; {"tcp":T,"udp":U}, each "ok" when the host made the socket, else the
;; index of `wasi:sockets/network`'s error-code as two digits ("01" is
;; access-denied). It exports its one function as a reagent's `compute`
;; and a catalyst's and a formula's `run`. No component type is granted
;; the network through WASI, so both are refused (`apps/locus/runner`).
;; A component text, built by `build.sh` (README.md).
(component
  (import "wasi:sockets/network@0.2.0" (instance $network
    (type $error-code (enum "unknown" "access-denied" "not-supported" "invalid-argument"
      "out-of-memory" "timeout" "concurrency-conflict" "not-in-progress" "would-block"
      "invalid-state" "new-socket-limit" "address-not-bindable" "address-in-use"
      "remote-unreachable" "connection-refused" "connection-reset" "connection-aborted"
      "datagram-too-large" "name-unresolvable" "temporary-resolver-failure"
      "permanent-resolver-failure"))
    (export "error-code" (type (eq $error-code)))
    (type $family (enum "ipv4" "ipv6"))
    (export "ip-address-family" (type (eq $family)))))
  (alias export $network "error-code" (type $error-code))
  (alias export $network "ip-address-family" (type $family))
  (import "wasi:sockets/tcp@0.2.0" (instance $tcp
    (export "tcp-socket" (type (sub resource)))))
  (alias export $tcp "tcp-socket" (type $tcp-socket))
  (import "wasi:sockets/udp@0.2.0" (instance $udp
    (export "udp-socket" (type (sub resource)))))
  (alias export $udp "udp-socket" (type $udp-socket))
  (import "wasi:sockets/tcp-create-socket@0.2.0" (instance $tcp-create
    (alias outer 1 $error-code (type $e))
    (export "error-code" (type $ec (eq $e)))
    (alias outer 1 $family (type $f))
    (export "ip-address-family" (type $fam (eq $f)))
    (alias outer 1 $tcp-socket (type $s))
    (export "tcp-socket" (type $sock (eq $s)))
    (export "create-tcp-socket"
      (func (param "address-family" $fam) (result (result (own $sock) (error $ec)))))))
  (import "wasi:sockets/udp-create-socket@0.2.0" (instance $udp-create
    (alias outer 1 $error-code (type $e))
    (export "error-code" (type $ec (eq $e)))
    (alias outer 1 $family (type $f))
    (export "ip-address-family" (type $fam (eq $f)))
    (alias outer 1 $udp-socket (type $s))
    (export "udp-socket" (type $sock (eq $s)))
    (export "create-udp-socket"
      (func (param "address-family" $fam) (result (result (own $sock) (error $ec)))))))

  (core module $libc (memory (export "memory") 1))
  (core instance $libc (instantiate $libc))
  (core func $create-tcp
    (canon lower (func $tcp-create "create-tcp-socket") (memory (core memory $libc "memory"))))
  (core func $create-udp
    (canon lower (func $udp-create "create-udp-socket") (memory (core memory $libc "memory"))))

  (core module $m
    (import "libc" "memory" (memory 1))
    (import "sockets" "create-tcp-socket" (func $create-tcp (param i32 i32)))
    (import "sockets" "create-udp-socket" (func $create-udp (param i32 i32)))
    ;; The answer's template; each socket's two characters are filled in.
    (data (i32.const 64) "{\"tcp\":\"__\",\"udp\":\"__\"}")
    ;; One socket's result at `area` (its case byte, then the error-code
    ;; byte at +4), written as two characters at `at`.
    (func $put (param $at i32) (param $area i32)
      (local $code i32)
      (if (i32.eqz (i32.load8_u (local.get $area)))
        (then
          (i32.store8 (local.get $at) (i32.const 0x6f))
          (i32.store8 offset=1 (local.get $at) (i32.const 0x6b))
          (return)))
      (local.set $code (i32.load8_u offset=4 (local.get $area)))
      (i32.store8 (local.get $at)
        (i32.add (i32.const 0x30) (i32.div_u (local.get $code) (i32.const 10))))
      (i32.store8 offset=1 (local.get $at)
        (i32.add (i32.const 0x30) (i32.rem_u (local.get $code) (i32.const 10)))))
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 1024))
    (func (export "compute") (param i32 i32) (result i32)
      (call $create-tcp (i32.const 0) (i32.const 0))
      (call $create-udp (i32.const 0) (i32.const 16))
      (call $put (i32.const 72) (i32.const 0))
      (call $put (i32.const 83) (i32.const 16))
      (i32.store (i32.const 32) (i32.const 64))
      (i32.store offset=4 (i32.const 32) (i32.const 23))
      (i32.const 32)))
  (core instance $i (instantiate $m
    (with "libc" (instance $libc))
    (with "sockets" (instance
      (export "create-tcp-socket" (func $create-tcp))
      (export "create-udp-socket" (func $create-udp))))))
  (func $compute (param "input" string) (result string)
    (canon lift (core func $i "compute")
      (memory (core memory $libc "memory")) (realloc (core func $i "cabi_realloc"))))
  ;; One function under each type's export, so every type runs it.
  (instance $compute-instance (export "compute" (func $compute)))
  (instance $run-instance (export "run" (func $compute)))
  (export "cyfr:reagent/compute@0.1.0" (instance $compute-instance))
  (export "cyfr:catalyst/run@0.1.0" (instance $run-instance))
  (export "cyfr:formula/run@0.1.0" (instance $run-instance)))
