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

  # Use the configured provider roster to generate handler coverage cases.
  # config:compile-runtime-ok — cases require the live registry’s roster at compile time.
  @all_providers Application.compile_env(:cyfr, :tool_providers, [])

  # Every provider in the roster is this app's own.
  @providers @all_providers

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

                {:error, refusal} ->
                  refute catch_all?(refusal),
                         "Action #{unquote(action)} for tool #{unquote(tool.name)} " <>
                           "in #{unquote(inspect(provider))} fell through to catch-all: " <>
                           inspect(refusal)

                _ ->
                  :ok
              end
            end
          end
        end
      end
    end
  end

  # A provider's catch-all clause answers "Invalid <tool> action" inside a
  # typed invalid-argument refusal; an action that reached a clause of its
  # own is refused in some other way, or not at all.
  #
  # One clause, because there is one refusal vocabulary. This case read
  # two, and its bare-sentence arm was the only one any provider answered
  # — so the four providers that were already typed fell through it
  # unchecked, and it tested one provider of five.
  defp catch_all?({:invalid_argument, message}) when is_binary(message),
    do: message =~ ~r/Invalid .* action/

  defp catch_all?(_refusal), do: false
end
