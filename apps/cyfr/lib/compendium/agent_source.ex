# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AgentSource do
  @moduledoc """
  An AQUA agent — the soul or a role — as a consent source node.

  `agent:local.<name>` is a source ref like any component's: it plans,
  consents, activates and loads through the same machinery, which reads
  every node as a row (`component_type`, `publisher`, `name`, `manifest`,
  `digest`, `release_digest`). This module projects that row from the
  agent file (`Compendium.AquaAgent`) so nothing downstream needs a second
  path.

  What the projection carries, and what it leaves out:

    * The artifact digest is the agent's **capability** digest
      (`Compendium.AquaAgent.capability_digest/1`): type, catalyst, model,
      tool policy, disabled. The prompt is not in it, so editing what an
      agent says never moves a consent; the file's bytes are its
      **revision**, kept by `Arca.AgentRevisions` for a turn to pin.
    * `caps.tools` are the policy keys that name tool actions
      (`tool.action`, `tool.*`), which consent expands against the live
      catalog. `native_search` is a provider tool, not a catalog action,
      and a role's clone glob (`<role>.*`) is an edge, not a tool.
    * `dependencies.static` are the model catalyst the agent runs on
      (required), the catalysts behind the tool families it names — its
      hands — (required), and every role its policy lets it clone into
      (optional: a role that cannot resolve is simply not clonable).
    * `model` is the model target, which the shape digest reads.

  A disabled agent has no row: it is out of the roster, and a soul's
  clone edge to it resolves to nothing.
  """

  alias Compendium.{AquaAgent, AquaPath}
  alias Sanctum.ComponentRef
  alias Sanctum.Context

  @type_name "agent"
  @publisher "local"

  @doc "The source type an agent ref carries: `agent`."
  @spec type() :: String.t()
  def type, do: @type_name

  @doc "The name-level ref of the agent `name`: `agent:local.<name>`."
  @spec ref(String.t()) :: String.t()
  def ref(name) when is_binary(name), do: ComponentRef.build(@type_name, @publisher, name)

  @doc "Whether `ref` names an agent source."
  @spec agent_ref?(String.t()) :: boolean()
  def agent_ref?(ref) when is_binary(ref) do
    match?({:ok, %ComponentRef{type: @type_name}}, ComponentRef.parse(ref))
  end

  def agent_ref?(_), do: false

  @doc """
  The row of every enabled agent in the estate's tree, the soul first.
  A file that fails to parse has no row.
  """
  @spec rows(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def rows(%Context{} = ctx) do
    with {:ok, agents, _errors} <- AquaAgent.list(ctx) do
      enabled = Enum.reject(agents, & &1.disabled)
      roster = MapSet.new(enabled, & &1.name)
      {:ok, Enum.map(enabled, &row(&1, roster))}
    end
  end

  @doc "The row of the enabled agent `name`, or `{:error, :not_found}`."
  @spec latest_row(Context.t(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def latest_row(%Context{} = ctx, name) when is_binary(name) do
    with {:ok, rows} <- rows(ctx) do
      case Enum.find(rows, &(&1.name == name)) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end
  end

  @doc """
  The consent manifest of an agent, given the names of the estate's
  enabled agents (which decide which policy globs are clone edges).
  """
  @spec manifest(AquaAgent.t(), MapSet.t(String.t())) :: map()
  def manifest(%{name: name} = agent, roster) do
    clone_globs =
      roster
      |> MapSet.delete(name)
      |> Enum.map(&AquaAgent.clone_glob/1)
      |> MapSet.new()

    {clones, tools} =
      (agent.tool_policy || %{})
      |> Map.keys()
      |> Enum.reject(&(&1 == "native_search"))
      |> Enum.split_with(&MapSet.member?(clone_globs, &1))

    hands =
      tools
      |> Enum.map(&tool_family/1)
      |> Enum.uniq()
      |> Enum.map(&Aqua.VirtualTools.catalyst_for/1)
      |> Enum.reject(&is_nil/1)

    required =
      Enum.map(List.wrap(agent.catalyst_ref) ++ hands, &%{"ref" => &1})

    optional =
      Enum.map(clones, fn glob ->
        %{"ref" => ref(String.trim_trailing(glob, ".*")), "optional" => true}
      end)

    dependencies =
      (required ++ optional)
      |> Enum.uniq_by(& &1["ref"])
      |> Enum.sort_by(& &1["ref"])

    %{
      "name" => name,
      "type" => @type_name,
      "version" => "",
      "publisher" => @publisher,
      "description" => agent.description || "",
      "caps" => %{"tools" => Enum.sort(tools)},
      "dependencies" => %{"static" => dependencies}
    }
    |> Cyfr.MapUtil.put_present("model", agent.model)
  end

  @doc "Whether `name` is the estate's soul."
  @spec soul?(String.t()) :: boolean()
  def soul?(name) when is_binary(name), do: AquaPath.soul?(name)

  @doc "The overlay unit an agent's file is: what `Arca.Overlay.unit_status/2` classifies."
  @spec unit(String.t()) :: Arca.Storage.path()
  def unit(name) when is_binary(name), do: AquaPath.agent_file(name)

  defp row(agent, roster) do
    manifest = manifest(agent, roster)
    {:ok, digest} = AquaAgent.capability_digest(agent)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)

    %{
      id: ref(agent.name),
      component_type: @type_name,
      publisher: @publisher,
      name: agent.name,
      version: "",
      description: agent.description || "",
      manifest: manifest,
      digest: digest,
      release_digest: release_digest
    }
  end

  defp tool_family(key) do
    case String.split(key, ".", parts: 2) do
      [tool, _action] -> tool
      [tool] -> tool
    end
  end
end
