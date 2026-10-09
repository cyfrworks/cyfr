# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The configuration a standalone Locus build and test run boot with (`cd
# apps/locus`). Builds and backends need none: every setting has its
# default in `Locus.Config`. The runtime role's settings are one keyword,
# `config :locus, :runtime`: a worker service reaching a host API on this
# machine. Umbrella builds supply the root application's config, and the
# `locus` release reads every role's environment through
# `config/locus_runtime.exs`.
import Config

config :locus, :runtime,
  service_id: "wrk_local",
  # A development key. CYFR derives a service's key from its runtime root
  # (`mix cyfr.locus.runtime_key <service_id>`); a deployment configures that one.
  service_key: "0000000000000000000000000000000000000000000000000000000000000000",
  host_url: "http://127.0.0.1:4300",
  bind: "127.0.0.1",
  port: 4200

# A test binds no fixed port: each listener a test needs is started on
# port 0 and asked which it was given. Its runners are OS processes of
# their own, started by the direct keeper its test support compiles
# (`Locus.Runtime.Keeper.direct_keeper/0`), which no other build names.
if config_env() == :test do
  config :locus, :runtime,
    port: 0,
    keeper: :direct,
    direct_keeper: Locus.Runtime.Keeper.Direct
end
