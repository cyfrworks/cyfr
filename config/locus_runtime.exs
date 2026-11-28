# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
import Config

# The runtime configuration of the `locus` release, the cyfr-locus image,
# for every role a node serves. A runner is no boot of this release but
# the runner program, which reads nothing here. Every boot is a node,
# whose `LOCUS_RUNTIME_*`, `LOCUS_BUILDS_*`, `LOCUS_BACKENDS_*` and
# `LOCUS_LOG_*` environment `Locus.Config` reads (its roster declares
# every variable of the release by role, and its moduledoc lists each
# with its accepted values and default), written as the `:locus`
# application environment and nothing else. Any of the control plane's
# own variables in this environment, an undeclared `LOCUS_*` name, a set
# variable that does not parse or none of the three keys refuses the
# boot: a Locus node holds no keyring, database or tenant state, and
# config/runtime.exs is not read here.
case Locus.Config.from_env(&System.get_env/1) do
  {:ok, settings} -> config :locus, settings
  {:error, message} -> raise "[Locus] FATAL: #{message}"
end
