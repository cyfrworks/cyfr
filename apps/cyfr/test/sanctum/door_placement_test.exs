# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DoorPlacementTest do
  @moduledoc """
  A session is minted at exactly two places, and both sit behind the
  door. Reads the sources rather than the behaviour: a new
  `Session.create/1` caller that forgot the door would pass every
  behavioural test on the paths that remembered it.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../lib", __DIR__)

  # The CLI device flow mints for itself; the browser flows mint through
  # the shared sign-in responder.
  @minters ~w(emissary_web/sign_in_response.ex sanctum/auth/device_flow.ex)

  test "every Session.create/1 call site sits behind Sanctum.Door.admit_identity/2" do
    callers =
      Path.wildcard(Path.join(@lib, "**/*.ex"))
      |> Enum.reject(&String.ends_with?(&1, "sanctum/session.ex"))
      |> Enum.filter(&(File.read!(&1) =~ ~r/\bSession\.create\(/))
      |> Enum.map(&Path.relative_to(&1, @lib))
      |> Enum.sort()

    assert callers == Enum.sort(@minters),
           "Session.create/1 is called from #{inspect(callers)}; only the sign-in paths may mint"

    # The device flow asks the door itself.
    assert File.read!(Path.join(@lib, "sanctum/auth/device_flow.ex")) =~ "Door.admit_identity",
           "sanctum/auth/device_flow.ex mints sessions without asking the door"

    # The responder mints only when a flow hands it `session: {:mint, ctx}`;
    # the one producer of that option must be the browser callback, and the
    # callback must ask the door before it does.
    mint_handers =
      Path.wildcard(Path.join(@lib, "**/*.ex"))
      |> Enum.filter(&(File.read!(&1) =~ ~r/session: \{:mint,/))
      |> Enum.map(&Path.relative_to(&1, @lib))
      |> Enum.sort()

    assert mint_handers == ["emissary_web/controllers/auth_controller.ex"],
           "session: {:mint, ...} is produced from #{inspect(mint_handers)}; " <>
             "only the browser callback may hand the responder a context to mint for"

    assert File.read!(Path.join(@lib, "emissary_web/controllers/auth_controller.ex")) =~
             "Door.admit_identity",
           "the browser callback mints sessions without asking the door"
  end
end
