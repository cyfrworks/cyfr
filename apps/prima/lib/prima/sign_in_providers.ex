# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.SignInProviders do
  @moduledoc """
  The sign-in providers, in one place.

  A person signs in through one of these doors, and a session, an identity
  key and a linked door name it. A device flow, which the CLI and a linked
  device start, reaches the subset `device_flow/0`; generic OIDC has no
  device flow.

  The identity domain derives its bounded atoms (`Sanctum.Atoms`) and the
  device flow's providers (`Sanctum.Auth.DeviceFlow`) from the lists here;
  the component domain, the surfaces and `mix ops.gen.cli`, which renders
  them for the CLI, read them here too. Spelling a list again anywhere else
  is drift.
  """

  @all ~w(github google oidcc)
  @device_flow ~w(github google)

  @doc ~s|Every sign-in provider: `["github", "google", "oidcc"]`.|
  @spec all() :: [String.t()]
  def all, do: @all

  @doc ~s|The sign-in providers a device flow starts with: `["github", "google"]`.|
  @spec device_flow() :: [String.t()]
  def device_flow, do: @device_flow
end
