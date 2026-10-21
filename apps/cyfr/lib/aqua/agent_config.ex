# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.AgentConfig do
  require Logger

  @moduledoc """
  The soul's and the roles' definitions, and the catalysts they run on,
  as a turn reads them.

  `roster/1` reads the athanor's `aqua/` tree in-process through the
  `Compendium` facade — the same files the `aqua` tool serves, without the
  tool's round trip — and answers string-keyed maps in the tool's own
  projection. Every write goes through the `aqua` tool.

  Each turn reads the roster and the catalyst listing
  (`catalyst_listing/1`) once and resolves its catalysts against that
  listing (`resolve_catalyst/2`).
  """

  alias Sanctum.Context

  # The authored tool_policy is edited on the AQUA page. Chat approvals are
  # stored separately in Aqua.ToolGrants and composed with it at use time.

  # What a storage fault reads as on the tape: the adapter's term is for
  # the log, the person gets the one sentence every storage-backed answer
  # gives.
  @unavailable {:unavailable, "The athanor's AQUA tree"}

  @doc """
  The athanor's agents, read once: the soul first, then the roles by name,
  disabled ones dropped — each as the string-keyed map the `aqua` tool's
  `list` with `detail` answers (`"name"`, `"title"`, `"description"`,
  `"type"`, `"content"`, `"tool_policy"`, `"catalyst_ref"`, `"model"`).

  Fails as it reads: a tree that cannot be listed is
  `{:error, {:unavailable, _}}`, never an empty roster a turn would
  quietly run without a crew. A single file that fails to parse is skipped
  and logged — one broken role must not take the soul down
  (`Compendium.agents/1`).

  The read is also where an athanor gets its bundle on first need
  (`Sanctum.Provisioning.start_provisioning/1`): a group athanor is minted
  as a bare row and filled the first time something reads it, and a turn
  roots an authority in that bundle right after this read. The `aqua`
  tool hooks its own reads the same way for callers outside the harness.
  """
  @spec roster(Context.t()) :: {:ok, [map()]} | {:error, {:unavailable, String.t()}}
  def roster(%Context{} = ctx) do
    Sanctum.Provisioning.start_provisioning(ctx)

    case Compendium.agents(ctx) do
      {:ok, agents, errors} ->
        Enum.each(errors, fn {name, reason} ->
          Logger.warning(
            "[Aqua.AgentConfig] agent #{inspect(name)} skipped — it does not parse: " <>
              inspect(reason)
          )
        end)

        {:ok, agents |> Enum.reject(& &1.disabled) |> Enum.map(&project/1)}

      {:error, reason} ->
        Logger.error("[Aqua.AgentConfig] the aqua tree could not be listed: #{inspect(reason)}")
        {:error, @unavailable}
    end
  end

  # The tool's `list detail: true` / `get` projection, string-keyed — the
  # one spelling this module's consumers read.
  defp project(agent) do
    %{
      "name" => agent.name,
      "title" => agent.title,
      "description" => agent.description,
      "type" => Compendium.agent_type_of(agent),
      "content" => agent.prompt,
      "tool_policy" => agent.tool_policy,
      "catalyst_ref" => agent.catalyst_ref,
      "model" => agent.model,
      "disabled" => agent.disabled
    }
  end

  @doc """
  The installed release a versionless catalyst ref resolves to in
  `listing` — the newest by semver precedence, never lexicographic max
  ("10.0.0" outranks "9.0.0").
  """
  @spec resolve_catalyst([map()], String.t() | nil) ::
          {:ok, String.t()} | {:error, :catalyst_not_found | :no_catalyst_ref}
  def resolve_catalyst(listing, versionless_ref)
      when is_list(listing) and is_binary(versionless_ref),
      do: find_matching_catalyst(listing, versionless_ref)

  def resolve_catalyst(_listing, nil), do: {:error, :no_catalyst_ref}

  @doc """
  Returns the working athanor's installed catalysts through `component.list`.
  Read once per turn and pass to `resolve_catalyst/2`.

  Each row names its release in `component_ref`; that is the key the
  resolvers match on.
  """
  @spec catalyst_listing(Context.t()) :: {:ok, [map()]} | {:error, :catalyst_lookup_failed}
  def catalyst_listing(%Context{} = ctx) do
    result =
      Aqua.Ops.call_tool("component", ctx, %{
        "action" => "list",
        "type" => "catalyst"
      })

    case result do
      {:ok, listing} when is_map(listing) ->
        case stringify_deep(listing) do
          %{"components" => components} when is_list(components) -> {:ok, components}
          _ -> {:error, :catalyst_lookup_failed}
        end

      _ ->
        {:error, :catalyst_lookup_failed}
    end
  end

  defp find_matching_catalyst(components, versionless_ref) do
    prefix = versionless_ref <> ":"

    match =
      components
      |> Enum.filter(fn c -> String.starts_with?(c["component_ref"] || "", prefix) end)
      # Semver precedence, not lexicographic max — "10.0.0" outranks "9.0.0".
      |> Prima.Semver.sort_desc_by(fn c -> c["version"] || "0" end)
      |> List.first()

    case match do
      nil -> {:error, :catalyst_not_found}
      c -> {:ok, c["component_ref"]}
    end
  end

  @doc """
  Deep-convert a map's keys to strings: the catalyst listing a turn reads
  and the options a turn row stores are both read in the string-keyed
  spelling of their JSON form.
  """
  @spec stringify_deep(term()) :: term()
  def stringify_deep(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify_deep(v)} end)

  def stringify_deep(list) when is_list(list), do: Enum.map(list, &stringify_deep/1)
  def stringify_deep(other), do: other
end
