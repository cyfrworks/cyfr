# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.TelemetryFamilies do
  @moduledoc """
  The telemetry families a producer emits with the kind as a variable,
  held there to the one list of the family's kinds: each family's event
  prefix and that list. The two source scans of the telemetry roster
  (`Cyfr.TelemetryCatalogTest` and `Cyfr.Telemetry.EmitterDriftTest`)
  read a call that passes `[prefix..., kind]` to `:telemetry.execute` as
  emitting every event of the family, and nothing else as emitting one.
  """

  @doc "Each family as `{prefix, kinds}`, the prefix a list of atoms."
  @spec all() :: [{[atom()], [atom()]}]
  def all, do: [{[:cyfr, :sanctum, :share], Prima.ShareKinds.all()}]

  @doc "The family whose prefix is `prefix`, as its events, or nil."
  @spec events([atom()]) :: [[atom()]] | nil
  def events(prefix) do
    Enum.find_value(all(), fn
      {^prefix, kinds} -> for kind <- kinds, do: prefix ++ [kind]
      _other -> nil
    end)
  end
end
