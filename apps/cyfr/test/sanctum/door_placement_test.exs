# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DoorPlacementTest do
  @moduledoc """
  A session is minted at exactly two places, and both ask the door first.
  Reads the sources rather than the behaviour: a new `Session.create/1`
  caller that forgot the door would pass every behavioural test on the
  paths that remembered it.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../lib", __DIR__)

  # The two sign-in paths: the browser callback and the CLI device flow.
  @minters ~w(emissary_web/controllers/auth_controller.ex sanctum/auth/device_flow.ex)

  test "every Session.create/1 call site sits behind Sanctum.Door.admit_identity/2" do
    callers =
      Path.wildcard(Path.join(@lib, "**/*.ex"))
      |> Enum.reject(&String.ends_with?(&1, "sanctum/session.ex"))
      |> Enum.filter(&(File.read!(&1) =~ ~r/\bSession\.create\(/))
      |> Enum.map(&Path.relative_to(&1, @lib))
      |> Enum.sort()

    assert callers == Enum.sort(@minters),
           "Session.create/1 is called from #{inspect(callers)}; only the sign-in paths may mint"

    for rel <- @minters do
      assert File.read!(Path.join(@lib, rel)) =~ "Door.admit_identity",
             "#{rel} mints sessions without asking the door"
    end
  end
end
