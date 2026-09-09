# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LiveEventCatchallTest do
  @moduledoc """
  Unknown client-supplied event names must be handled without
  crashing or remounting the LiveView.

  It is one clause now, appended after each module's own by
  `PrismWeb.LiveDefaults`. This test is what keeps it appended: a LiveView
  that stops going through `use PrismWeb, :live_view` loses the clause
  silently otherwise.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  defp live_modules do
    Path.wildcard(Path.join(__DIR__, "../../lib/prism_web/**/*.ex"))
    |> Enum.filter(fn path ->
      source = File.read!(path)

      String.contains?(source, "use PrismWeb, :live_view") or
        String.contains?(source, "use PrismWeb, :live_component")
    end)
    |> Enum.map(fn path ->
      [module] = Regex.run(~r/^defmodule ([\w.]+) do/m, File.read!(path), capture: :all_but_first)
      {Path.basename(path), Module.concat([module])}
    end)
  end

  test "every console LiveView and LiveComponent answers an unknown event" do
    modules = live_modules()

    assert length(modules) > 20,
           "expected the console's LiveViews to be found, got #{length(modules)}"

    for {file, module} <- modules do
      Code.ensure_loaded!(module)

      assert function_exported?(module, :handle_event, 3),
             "#{file} defines no handle_event/3 at all — the catch-all should have supplied one"

      log =
        capture_log(fn ->
          assert {:noreply, %Phoenix.LiveView.Socket{}} =
                   module.handle_event("no-such-event-cd6f", %{}, %Phoenix.LiveView.Socket{})
        end)

      assert log =~ "unhandled event",
             "#{file} swallowed an unknown event without saying so"
    end
  end
end
