# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ConsentFacts do
  @moduledoc """
  What the component domain answers consent with: the implementation of
  `Sanctum.Consent.Components`.

  Consent decides what a component may do; deciding it means reading what
  the estate holds, which is this domain's to know. Four of the five
  answers are one call each — the activation, the verified activation, the
  row a ref names, the estate's agents. The fifth, `shipped_nodes/2`,
  is the seed-vouching fact the consent bootstrap mints over: the release
  digest the **install media** ships at a row's path, never the athanor's
  copy. Its three cases are this domain's own layout — an agent file under
  the seed's AQUA tree, a tincture whose artifact is its directory and
  must be unedited, a WASM unit whose seed release is recomputed from the
  media — and consent must not learn any of them.

  A row the seed does not ship, or ships in a form that cannot be read, is
  simply absent from the map: absent means "not vouched for by the
  operator", which is what the bootstrap walk does with it.
  """

  @behaviour Sanctum.Consent.Components

  alias Compendium.{Activation, AgentSource, ComponentPath, Provenance, Registry}
  alias Sanctum.Context

  @wasm_types ~w(catalyst reagent formula)

  @impl Sanctum.Consent.Components
  def resolve(%Context{} = ctx, component), do: Activation.resolve(ctx, component)

  @impl Sanctum.Consent.Components
  def resolve_verified(%Context{} = ctx, component),
    do: Activation.resolve_verified(ctx, component)

  @impl Sanctum.Consent.Components
  def get_component(%Context{} = ctx, name, nil, publisher, type),
    do: Registry.get_latest(ctx, name, publisher, type)

  def get_component(%Context{} = ctx, name, version, publisher, type),
    do: Registry.get(ctx, name, version, publisher, type)

  @impl Sanctum.Consent.Components
  def agent_rows(%Context{} = ctx), do: AgentSource.rows(ctx)

  @impl Sanctum.Consent.Components
  def shipped_nodes(%Context{} = ctx, rows) do
    # The roster the seed's own agent files project against: an agent's
    # row names its clone edges, and which roles exist decides them.
    roster =
      rows
      |> Enum.filter(&(to_string(Cyfr.ComponentRow.field(&1, :component_type)) == agent_type()))
      |> MapSet.new(&Cyfr.ComponentRow.field(&1, :name))

    {:ok,
     Enum.reduce(rows, %{}, fn row, acc ->
       case shipped_digest(ctx, row, roster) do
         {:ok, digest} when is_binary(digest) ->
           Map.put(acc, Cyfr.ComponentRow.node_key(row), digest)

         _not_shipped ->
           acc
       end
     end)}
  end

  defp agent_type, do: AgentSource.type()

  defp shipped_digest(ctx, row, roster) do
    type = to_string(Cyfr.ComponentRow.field(row, :component_type))

    cond do
      type == agent_type() -> seed_agent_digest(Cyfr.ComponentRow.field(row, :name), roster)
      type == "tincture" -> pristine_tincture_digest(ctx, row)
      type in @wasm_types -> Provenance.shipped_release_digest(row)
      true -> :error
    end
  end

  # The seed's own agent file, projected under the estate's roster: a
  # prose-only edit of the athanor's copy leaves this digest alone, a
  # policy, model or catalyst edit of the seed file moves it.
  defp seed_agent_digest(name, roster) do
    path = Arca.Storage.seed_prefix("aqua") ++ Enum.drop(AgentSource.unit(name), 1)

    with {:ok, bytes} <- Arca.get(Cyfr.Actor.system(), path),
         {:ok, row} <- AgentSource.shipped_row(name, bytes, roster) do
      {:ok, Cyfr.ComponentRow.field(row, :release_digest)}
    end
  end

  # A tincture's artifact is its directory; vouch only an unedited
  # shipped copy.
  defp pristine_tincture_digest(ctx, row) do
    unit =
      ComponentPath.version_dir(
        "tincture",
        Cyfr.ComponentRow.field(row, :publisher),
        Cyfr.ComponentRow.field(row, :name),
        Cyfr.ComponentRow.field(row, :version)
      )

    actor = Context.actor(ctx)

    with {:ok, :shipped} <- Arca.Overlay.unit_status(actor, unit),
         {:ok, false} <- Arca.Overlay.edited?(actor, unit),
         digest when is_binary(digest) <- Cyfr.ComponentRow.field(row, :release_digest) do
      {:ok, digest}
    else
      _ -> :error
    end
  end
end
