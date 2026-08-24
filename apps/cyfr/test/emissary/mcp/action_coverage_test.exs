# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ActionCoverageTest do
  @moduledoc """
  Verifies that every action value in a tool's JSON Schema enum
  has a corresponding handler clause in its MCP provider module.

  If an action is listed in the enum but not handled, the provider's
  catch-all clause returns an "Invalid ... action" error — this test
  catches that.
  """
  use ExUnit.Case, async: false

  # The registered providers, read from config rather than listed again
  # here. A second list meant the two could disagree, and they did:
  # ExternalProvider and SystemProvider were registered but absent from this
  # test, so the audit that exists to catch an action with no handler clause
  # silently skipped two providers.
  # config:compile-runtime-ok — this roster generates the test cases below, so
  # it has to exist at compile time; the runtime readers are the live registry.
  @all_providers Application.compile_env(:cyfr, :tool_providers, [])

  # Filter to only providers available in this app's compilation context.
  # Opus.MCP, Opus.CronMCP, and Locus.MCP are cross-app modules that aren't
  # available when running `apps/cyfr` tests standalone.
  @providers Enum.filter(@all_providers, &Code.ensure_loaded?/1)

  for provider <- @providers do
    describe "#{inspect(provider)} action coverage" do
      setup do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
        Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
        %{ctx: Sanctum.TestContext.local()}
      end

      for tool <- provider.tools() do
        action_enum =
          get_in(tool.input_schema, ["properties", "action", "enum"]) || []

        if action_enum != [] do
          for action <- action_enum do
            test "#{tool.name} handles action #{inspect(action)}", %{ctx: ctx} do
              result =
                try do
                  unquote(provider).handle(
                    unquote(tool.name),
                    ctx,
                    %{"action" => unquote(action)}
                  )
                rescue
                  # Any exception proves the action was dispatched to a
                  # specific handler clause (e.g. DB ownership, missing
                  # params causing MatchError). Catch-all clauses return
                  # {:error, "Invalid ... action"} without raising.
                  _ -> :handled_raised
                end

              case result do
                :handled_raised ->
                  :ok

                {:error, message} when is_binary(message) ->
                  refute message =~ ~r/Invalid .* action/,
                         "Action #{unquote(action)} for tool #{unquote(tool.name)} " <>
                           "in #{unquote(inspect(provider))} fell through to catch-all: #{message}"

                _ ->
                  :ok
              end
            end
          end
        end
      end
    end
  end
end
