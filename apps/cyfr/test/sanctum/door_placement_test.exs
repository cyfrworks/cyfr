# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DoorPlacementTest do
  @moduledoc """
  A session is minted at exactly two places, and both sit behind the
  door. Reads the sources rather than the behaviour: a new
  `Session.create/1` caller that forgot the door would pass every
  behavioural test on the paths that remembered it.
  """
  use ExUnit.Case, async: true

  # Both minters are named relative to the umbrella: one is the auth
  # domain's own device flow, the other the console's sign-in response,
  # so the scan spans two applications.
  @root Path.expand("../../../..", __DIR__)

  # The CLI device flow mints for itself; the browser flows mint through
  # the shared sign-in responder.
  @device_flow "apps/sanctum/lib/sanctum/auth/device_flow.ex"
  @browser_callback "apps/cyfr/lib/emissary_web/controllers/auth_controller.ex"
  @minters ["apps/cyfr/lib/prism_web/sign_in_response.ex", @device_flow]

  defp lib_files do
    for dir <- Prima.Test.SourceTree.app_libs(@root),
        file <- Prima.Test.SourceTree.files!(Path.join([@root, dir, "**/*.ex"])),
        do: file
  end

  test "every Session.create/1 call site sits behind Sanctum.Door.admit_identity/2" do
    callers =
      lib_files()
      |> Enum.reject(&String.ends_with?(&1, "sanctum/session.ex"))
      |> Enum.filter(&(Prima.Test.SourceTree.read(&1) =~ ~r/\bSession\.create\(/))
      |> Enum.map(&Path.relative_to(&1, @root))
      |> Enum.sort()

    assert callers == Enum.sort(@minters),
           "Session.create/1 is called from #{inspect(callers)}; only the sign-in paths may mint"

    # The device flow asks the door itself.
    assert Prima.Test.SourceTree.read(Path.join(@root, @device_flow)) =~
             "Door.admit_identity",
           "#{@device_flow} mints sessions without asking the door"

    # The responder mints only when a flow hands it `session: {:mint, ctx}`;
    # the one producer of that option must be the browser callback, and the
    # callback must ask the door before it does.
    mint_handers =
      lib_files()
      |> Enum.filter(&(Prima.Test.SourceTree.read(&1) =~ ~r/session: \{:mint,/))
      |> Enum.map(&Path.relative_to(&1, @root))
      |> Enum.sort()

    assert mint_handers == [@browser_callback],
           "session: {:mint, ...} is produced from #{inspect(mint_handers)}; " <>
             "only the browser callback may hand the responder a context to mint for"

    assert Prima.Test.SourceTree.read(Path.join(@root, @browser_callback)) =~
             "Door.admit_identity",
           "the browser callback mints sessions without asking the door"
  end
end
