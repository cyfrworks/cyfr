# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
import Config

# The runtime configuration of the `locus` release, the builder image: its
# `LOCUS_BUILDS_*` environment read by `Locus.Config`, whose moduledoc
# lists every variable with its accepted values and default, written as
# the `:locus` application environment and nothing else. A set variable
# that does not parse, a missing key, or any of the control plane's own
# variables in this environment refuses the boot: the builder holds no
# keyring, database or tenant state, and config/runtime.exs is not read
# here.
case Locus.Config.from_env(&System.get_env/1) do
  {:ok, settings} -> config :locus, settings
  {:error, message} -> raise "[Locus] FATAL: #{message}"
end
