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
      catalog: a key no catalogued action matches expands to nothing
      (`Prima.ToolPattern.expand/2`). `native_search` is a provider tool,
      not a catalog action.
    * `dependencies.static` are the model catalyst the agent runs on and
      the catalysts behind the tool families it names — its hands. An
      agent has no edge into another agent: a role consents and runs as
      its own source.
    * `agent` is the model target and the policy modes (`auto` / `ask`
      sets), which the shape digest reads. The flat `"model"` key is not
      written.

  A disabled agent has no row: it is out of the roster.
  """

  alias Compendium.{AquaAgent, AquaPath}
  alias Sanctum.Context

  # The ref vocabulary — the type segment, the publisher and the soul's
  # reserved name — is `Prima.AgentRef`, where the identity domain reads it
  # too: consent has to recognise an agent source it never mints.
  @type_name Prima.AgentRef.type()
  @publisher "local"

  @doc """
  The row of every enabled agent in the athanor's tree, the soul first.
  A file that fails to parse has no row.
  """
  @spec rows(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def rows(%Context{} = ctx) do
    with {:ok, agents, _errors} <- AquaAgent.list(ctx) do
      {:ok, agents |> Enum.reject(& &1.disabled) |> Enum.map(&row/1)}
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

  @doc "The consent manifest of an agent."
  @spec manifest(AquaAgent.t()) :: map()
  def manifest(%{name: name} = agent) do
    tools =
      (agent.tool_policy || %{})
      |> Map.keys()
      |> Enum.reject(&(&1 == "native_search"))

    hands =
      tools
      |> Enum.map(&tool_family/1)
      |> Enum.map(&Sanctum.VirtualTools.catalyst_for/1)
      |> Enum.reject(&is_nil/1)

    dependencies =
      (List.wrap(agent.catalyst_ref) ++ hands)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&%{"ref" => &1})

    {auto, ask} =
      (agent.tool_policy || %{})
      |> Enum.split_with(fn {_key, mode} -> mode == "auto" end)

    agent_block =
      %{
        "policy" => %{
          "auto" => auto |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
          "ask" => ask |> Enum.map(&elem(&1, 0)) |> Enum.sort()
        }
      }
      |> Prima.MapUtil.put_present("catalyst", agent.catalyst_ref)
      |> Prima.MapUtil.put_present("model", agent.model)

    %{
      "name" => name,
      "type" => @type_name,
      "version" => "",
      "publisher" => @publisher,
      "description" => agent.description || "",
      "caps" => %{"tools" => Enum.sort(tools)},
      "dependencies" => %{"static" => dependencies},
      "agent" => agent_block
    }
  end

  @doc "The overlay unit an agent's file is: what `Arca.Overlay.unit_status/2` classifies."
  @spec unit(String.t()) :: Arca.Storage.path()
  def unit(name) when is_binary(name), do: AquaPath.agent_file(name)

  @doc "The consent row of an agent file — the soul or a role."
  @spec row(AquaAgent.t()) :: map()
  def row(%{name: _} = agent) do
    manifest = manifest(agent)
    {:ok, digest} = AquaAgent.capability_digest(agent)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)

    %{
      id: Prima.AgentRef.ref(agent.name),
      component_type: @type_name,
      publisher: @publisher,
      name: agent.name,
      version: "",
      description: agent.description,
      manifest: manifest,
      digest: digest,
      release_digest: release_digest
    }
  end

  @doc """
  The consent row the seed file projects. A prose-only edit of the
  athanor's copy does not change this row; a policy, model or catalyst
  edit of the seed file does. A disabled seed agent has no row.
  """
  @spec shipped_row(String.t(), binary()) :: {:ok, map()} | {:error, term()}
  def shipped_row(name, bytes) when is_binary(name) and is_binary(bytes) do
    with {:ok, agent} <- AquaAgent.parse(name, bytes) do
      if agent.disabled, do: {:error, :disabled}, else: {:ok, row(agent)}
    end
  end

  defp tool_family(key) do
    case String.split(key, ".", parts: 2) do
      [tool, _action] -> tool
      [tool] -> tool
    end
  end
end
