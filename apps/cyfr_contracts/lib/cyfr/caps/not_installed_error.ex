# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Caps.NotInstalledError do
  @moduledoc """
  Raised by `Cyfr.Caps.impl/0` when nothing has installed the cap port.

  The port is written once at boot (`Cyfr.Caps.install!/1`, from
  `Cyfr.Application`), and the implementation is `Sanctum.Tenancy.Caps`.
  A caller that asks before then is not told "no cap": an uninstalled port
  cannot say what the ceilings are, and a write nothing can measure must
  not land.
  """

  @message "Cyfr.Caps has no installed implementation: nothing called " <>
             "Cyfr.Caps.install!/1. A port that was never installed is not a " <>
             "server with no caps — every counted and storage check refuses " <>
             "until boot installs one."

  defexception message: @message
end
