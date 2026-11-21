# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AgentSource do
  @moduledoc """
  The crew's one grant as a consent source node: `agent:local.aqua`.

  Every turn of the crew, Aqua's and each crew member's, runs under the
  one grant whose source is Aqua (`Prima.AgentRef.soul_ref/0`): toward
  CYFR the crew is one caller, and a crew member holds no consent of its
  own. `agent:local.aqua` is a source ref like any component's: it plans,
  consents, activates and loads through the same machinery, which reads
  every node as a row (`component_type`, `publisher`, `name`, `manifest`,
  `digest`, `release_digest`). This module projects that row from Aqua's
  file (`Compendium.AquaAgent`) and the athanor's brains, so nothing
  downstream needs a second path.

  What the projection carries, and what it leaves out:

    * `caps.tools` are Aqua's `tools`, the tools every crew member is
      offered (`Compendium.AquaAgent.under_soul/2`), that name tool
      actions (`tool.action`, one action an entry), which consent expands
      against the live catalog: a key no catalogued action matches
      expands to nothing (`Prima.ToolPattern.expand/2`); and
      `native_search`, the provider's own search, which no catalog action
      is and the consent carries by its name.
    * `dependencies.static` are the catalysts behind the tool families
      Aqua's tools name, its hands, and every brain the athanor can
      connect: each installed catalyst whose newest release speaks
      `model/chat@1` (`brains/1`). So the grant covers every brain a crew
      member may run on, whichever member Aqua runs on, and making a
      member, changing its brain or choosing Aqua's member moves nothing
      here. Each brain's edge takes its key from the brain's own grant
      (`Sanctum.Consent.Bootstrap`'s selection of its `default` profile),
      so connecting a brain is the one grant of its key. A brain that is a
      program is no dependency: each of its turns is admitted by that
      turn's own `program.start` step, never by this consent.
    * Nothing of a crew member: no brain, model, options or mode is in it,
      and the mode a member runs in grants nothing the consent does not
      (`ARCHITECTURE.md` §5.4).

  The artifact digest is the digest of the manifest, so the release moves
  exactly when what the grant covers moves. Aqua's prompt is not in it,
  so editing what Aqua says never moves the grant; the file's bytes are
  its **revision**, kept by `Arca.AgentRevisions` for a turn to pin.

  A disabled Aqua, or a tree with none, has no row.
  """

  alias Compendium.AquaAgent
  alias Sanctum.Context

  # The ref vocabulary — the type segment, the publisher and the soul's
  # reserved name — is `Prima.AgentRef`, where the identity domain reads it
  # too: consent has to recognise an agent source it never mints.
  @type_name Prima.AgentRef.type()
  @publisher "local"

  @doc """
  The grant's row, `[row]`, or `[]` for a tree with no Aqua or a disabled
  one. Aqua's file that fails to parse has no row.
  """
  @spec rows(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def rows(%Context{} = ctx) do
    with {:ok, agents, _errors} <- AquaAgent.list(ctx) do
      case Enum.find(agents, &Prima.AgentRef.soul?(&1.name)) do
        %{disabled: false} = soul ->
          with {:ok, brains} <- brains(ctx), do: {:ok, [row(soul, brains)]}

        _none_or_disabled ->
          {:ok, []}
      end
    end
  end

  @doc """
  The grant's row when `name` is Aqua's, or `{:error, :not_found}`: a crew
  member is no consent source.
  """
  @spec latest_row(Context.t(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def latest_row(%Context{} = ctx, name) when is_binary(name) do
    with true <- Prima.AgentRef.soul?(name),
         {:ok, [row]} <- rows(ctx) do
      {:ok, row}
    else
      {:error, _} = error -> error
      _not_aqua_or_none -> {:error, :not_found}
    end
  end

  @doc """
  Every brain the athanor can connect, as the versionless refs the grant
  names: each installed catalyst whose newest release declares
  `model/chat@1`, sorted. A release whose stored manifest does not decode
  speaks nothing. A component index behind its tree that cannot catch up,
  or a store that cannot answer, is its refusal.
  """
  @spec brains(Context.t()) :: {:ok, [String.t()]} | {:error, term()}
  def brains(%Context{} = ctx) do
    with :ok <- Compendium.ProjectionReconciler.await(ctx, "components"),
         {:ok, rows} <-
           Arca.ComponentStorage.list_components(Context.actor(ctx),
             component_type: "catalyst",
             limit: :none
           ) do
      {:ok,
       rows
       |> Enum.group_by(&{&1.publisher, &1.name})
       |> Enum.map(fn {_name, versions} -> Prima.ComponentRow.latest_of(versions) end)
       |> Enum.filter(&Prima.Model.speaks_chat?(&1.manifest))
       |> Enum.map(&Prima.ComponentRow.node_key/1)
       |> Enum.sort()}
    end
  end

  @doc "The consent manifest of Aqua's grant over `brains` (`brains/1`)."
  @spec manifest(AquaAgent.t(), [String.t()]) :: map()
  def manifest(%{name: name} = soul, brains) when is_list(brains) do
    tools = Map.get(soul, :tools) || []

    hands =
      tools
      |> Enum.map(&tool_family/1)
      |> Enum.map(&Sanctum.VirtualTools.catalyst_for/1)
      |> Enum.reject(&is_nil/1)

    dependencies =
      (hands ++ brains)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&%{"ref" => &1})

    %{
      "name" => name,
      "type" => @type_name,
      "version" => "",
      "publisher" => @publisher,
      "description" => soul.description || "",
      "caps" => %{"tools" => Enum.sort(tools)},
      "dependencies" => %{"static" => dependencies}
    }
  end

  @doc "The grant's consent row: Aqua's file over the athanor's brains."
  @spec row(AquaAgent.t(), [String.t()]) :: map()
  def row(%{name: _} = soul, brains) do
    manifest = manifest(soul, brains)
    {:ok, digest} = Prima.JCS.hash(manifest)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)

    %{
      id: Prima.AgentRef.ref(soul.name),
      component_type: @type_name,
      publisher: @publisher,
      name: soul.name,
      version: "",
      description: soul.description,
      manifest: manifest,
      digest: digest,
      release_digest: release_digest
    }
  end

  @doc """
  The grant's row the seed's Aqua projects over the athanor's brains
  (`Compendium.AquaTemplate.shipped_agent/1`): a prose-only edit of the
  athanor's copy does not change it; a tools edit of the seed file does.
  A crew member, shipped or not, has none (`{:error, :not_found}`), and
  neither has a disabled seed Aqua.
  """
  @spec shipped_row(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def shipped_row(%Context{} = ctx, name) when is_binary(name) do
    if Prima.AgentRef.soul?(name), do: shipped_soul_row(ctx, name), else: {:error, :not_found}
  end

  defp shipped_soul_row(ctx, name) do
    with {:ok, soul} <- Compendium.AquaTemplate.shipped_agent(name),
         :ok <- if(soul.disabled, do: {:error, :disabled}, else: :ok),
         {:ok, brains} <- brains(ctx) do
      {:ok, row(soul, brains)}
    end
  end

  defp tool_family(key) do
    case String.split(key, ".", parts: 2) do
      [tool, _action] -> tool
      [tool] -> tool
    end
  end
end
