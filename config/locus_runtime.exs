# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
import Config

# The runtime configuration of the `locus` release, the cyfr-locus image,
# for every role a node serves. A runner (`RUNTIME_ROLE=runner`) is
# configured by nothing here: it reads its `RUNTIME_*` environment when the
# application starts (`Locus.Runtime.Settings.runner/1`). Every other boot
# is a node, whose `LOCUS_RUNTIME_*`, `LOCUS_BUILDS_*`, `LOCUS_BACKENDS_*`
# and `LOCUS_LOG_*` environment `Locus.Config` reads (its moduledoc and
# `Locus.Runtime.Settings`' list every variable with its accepted values
# and default), written as the `:locus` application environment and
# nothing else. Any of the control plane's own variables in this
# environment, an undeclared `LOCUS_*` name, a set variable that does not
# parse or none of the three keys refuses the boot: a Locus node holds no
# keyring, database or tenant state, and config/runtime.exs is not read
# here.
if System.get_env("RUNTIME_ROLE") != "runner" do
  case Locus.Config.from_env(&System.get_env/1) do
    {:ok, settings} -> config :locus, settings
    {:error, message} -> raise "[Locus] FATAL: #{message}"
  end
end
