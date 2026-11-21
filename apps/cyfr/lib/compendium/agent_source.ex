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
  file (`Compendium.AquaAgent`), so nothing downstream needs a second
  path.

  What the projection carries, and what it leaves out:

    * `caps.tools` are Aqua's `tools`, the tools every crew member is
      offered (`Compendium.AquaAgent.under_soul/2`), that name tool
      actions (`tool.action`, one action an entry), which consent expands
      against the live catalog: a key no catalogued action matches
      expands to nothing (`Prima.ToolPattern.expand/2`); and
      `native_search`, the provider's own search, which no catalog action
      is and the consent carries by its name.
    * `dependencies.static` are the catalysts behind the tool families
      Aqua's tools name, its hands. No brain is one: a turn's model call
      runs under the brain's own grant (its key, network and limits),
      which the turn loads and pins beside this one (`Aqua.Loop`), as a
      program brain's turn starts its program by that program's own row.
      So connecting a brain, changing its key or installing one asks
      nothing here.
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
          {:ok, [row(soul)]}

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

  @doc "The consent manifest of Aqua's grant: its tools and its hands."
  @spec manifest(AquaAgent.t()) :: map()
  def manifest(%{name: name} = soul) do
    tools = Map.get(soul, :tools) || []

    hands =
      tools
      |> Enum.map(&tool_family/1)
      |> Enum.map(&Sanctum.VirtualTools.catalyst_for/1)
      |> Enum.reject(&is_nil/1)

    dependencies =
      hands
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

  @doc "The grant's consent row: Aqua's file."
  @spec row(AquaAgent.t()) :: map()
  def row(%{name: _} = soul) do
    manifest = manifest(soul)
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
  The grant's row the seed vouches for: the seed's Aqua
  (`Compendium.AquaTemplate.shipped_agent/1`). A prose-only edit of the
  athanor's copy does not change it; a tools edit of the seed file does.
  A crew member, shipped or not, has none (`{:error, :not_found}`), and
  neither has a disabled seed Aqua.
  """
  @spec shipped_row(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def shipped_row(%Context{}, name) when is_binary(name) do
    if Prima.AgentRef.soul?(name), do: shipped_soul_row(name), else: {:error, :not_found}
  end

  defp shipped_soul_row(name) do
    with {:ok, soul} <- Compendium.AquaTemplate.shipped_agent(name),
         :ok <- if(soul.disabled, do: {:error, :disabled}, else: :ok),
         do: {:ok, row(soul)}
  end

  defp tool_family(key) do
    case String.split(key, ".", parts: 2) do
      [tool, _action] -> tool
      [tool] -> tool
    end
  end
end
