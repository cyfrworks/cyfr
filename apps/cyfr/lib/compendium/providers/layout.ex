# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.Layout do
  @moduledoc """
  The `layout` tool: the caller's own layout document (`Prima.Layout`),
  which tinctures sit where on their desktop, at what size, per posture.

    * `get` answers the caller's document, its revision and digest, or the
      shipped default at revision 0 when they have never arranged one; with
      a `posture`, also that posture's arrangement.
    * `edit` takes a whole document and the revision `get` answered, holds
      it to the layout's shape and publishes it fenced (`Arca.Layouts`): a
      document published since the revision was read refuses the edit, and
      nothing is merged.

  A layout can only arrange: the shape names tinctures, sizes and places
  and nothing else, so an edit never references an operation or a stream
  and never widens a grant. A tincture nobody installed is kept and drawn
  as a placeholder. Which tinctures are installed is the component
  listing's to answer, not this tool's.

  Both actions run under the caller's context, for the person the context
  names, in the athanor in focus. The console reads through
  `Compendium.layout/2`; every edit, the console's or the assistant's,
  is this tool's `edit` through the gate.
  """

  @behaviour Prima.Provider

  require Logger

  alias Sanctum.Context

  @impl true
  def service, do: "compendium"

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    alias Prima.{Arg, Operation}

    Operation.tool(
      [
        Operation.new(
          "layout",
          "get",
          "Get your layout",
          [
            Arg.new("posture", :string,
              description: "get: also answer this posture's arrangement",
              enum: Prima.Layout.postures()
            )
          ],
          kind: :read,
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "layout",
          "edit",
          "Arrange your layout",
          [
            Arg.new("document", :json,
              required: true,
              description:
                "edit: the whole layout document — {version: 1, postures: {hand|desk: " <>
                  "{desktop, slots: [{id, tincture, size: icon|card|full, order, card}], " <>
                  "floating: [{tincture, position: {x, y}}]}}}"
            ),
            Arg.new("revision", :integer,
              required: true,
              min: 0,
              description:
                "edit: the revision get answered; a layout published since refuses the edit"
            )
          ],
          kind: :write,
          planes: [:external, :in_chain]
        )
      ],
      description:
        "Your desktop's layout: which tinctures sit where, at what size, per posture. " <>
          "An edit can only arrange; it names no operation, stream or grant.",
      title: "Layout"
    )
  end

  @impl true
  def handle("layout", %Context{} = ctx, %{"action" => "get"} = args) do
    with {:ok, layout} <- read(ctx) do
      answer = %{
        document: Prima.Layout.to_json(layout.document),
        revision: layout.revision,
        digest: layout.digest,
        shipped_default: layout.shipped_default
      }

      case Map.get(args, "posture") do
        nil ->
          {:ok, answer}

        posture ->
          with {:ok, arrangement} <- arrangement(layout.document, posture) do
            {:ok,
             Map.merge(answer, %{
               posture: posture,
               arrangement: Prima.Layout.posture_to_json(arrangement)
             })}
          end
      end
    end
  end

  def handle("layout", %Context{} = ctx, %{"action" => "edit"} = args) do
    with {:ok, person} <- person(ctx),
         {:ok, revision} <- revision(Map.get(args, "revision")),
         {:ok, layout} <- document(Map.get(args, "document")) do
      case Arca.Layouts.publish(Context.actor(ctx), person, layout, revision) do
        {:ok, published} ->
          {:ok, %{revision: published, digest: Prima.Layout.digest(layout)}}

        {:error, reason} ->
          {:error, refusal(reason, revision)}
      end
    end
  end

  def handle(_name, _ctx, _args), do: {:error, :unknown_tool}

  @typedoc "The caller's layout as the console renders it."
  @type read :: %{
          document: Prima.Layout.t(),
          revision: non_neg_integer(),
          digest: String.t(),
          shipped_default: boolean()
        }

  @doc """
  The caller's layout document, its revision and digest, or the shipped
  default at revision 0 when none was published (`shipped_default: true`).
  Refused for a caller that is not a person, as `{:corrupt, {:digest,
  "The layout"}}` when the stored bytes no longer hold their digest, and
  `{:unavailable, "Layout"}` when the store cannot answer.
  """
  @spec read(Context.t()) :: {:ok, read()} | {:error, term()}
  def read(%Context{} = ctx) do
    with {:ok, person} <- person(ctx) do
      case Arca.Layouts.get(Context.actor(ctx), person) do
        {:ok, %{document: document, revision: revision, digest: digest}} ->
          {:ok, %{document: document, revision: revision, digest: digest, shipped_default: false}}

        {:error, :not_found} ->
          default = Prima.Layout.default()

          {:ok,
           %{
             document: default,
             revision: 0,
             digest: Prima.Layout.digest(default),
             shipped_default: true
           }}

        {:error, reason} ->
          {:error, refusal(reason, nil)}
      end
    end
  end

  @doc """
  The arrangement of `posture` in `layout`: the document's own, or the
  shipped default's when the document does not name it.
  """
  @spec arrangement(Prima.Layout.t(), term()) ::
          {:ok, Prima.Layout.posture()} | {:error, {:invalid_argument, String.t()}}
  def arrangement(%Prima.Layout{} = layout, posture) do
    case Prima.Layout.posture(layout, posture) do
      {:ok, arrangement} ->
        {:ok, arrangement}

      :error ->
        {:error,
         {:invalid_argument, "a posture is one of #{Enum.join(Prima.Layout.postures(), ", ")}"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # A layout is a person's: a context that names no person (the server's
  # own principals) has none to read or arrange.
  defp person(%Context{user_id: user_id}) do
    if Prima.PersonId.person?(user_id),
      do: {:ok, user_id},
      else:
        {:error, {:invalid_argument, "a layout belongs to a person, and this caller is not one"}}
  end

  defp revision(revision) when is_integer(revision) and revision >= 0, do: {:ok, revision}

  defp revision(_revision),
    do:
      {:error, {:invalid_argument, "edit needs the revision get answered, a whole number from 0"}}

  defp document(document) do
    case Prima.Layout.validate(document) do
      {:ok, layout} -> {:ok, layout}
      {:error, {:invalid_layout, sentence}} -> {:error, {:invalid_argument, sentence}}
    end
  end

  # A layout published since the revision was read is the one refusal the
  # caller can act on; the storage cap keeps a sentence of its own; every
  # other failure wrote nothing and is answered as a retry.
  defp refusal(:stale, revision) do
    {:conflict,
     "the layout changed since revision #{revision} was read — get it again and arrange from there"}
  end

  defp refusal(:corrupt, _revision), do: {:corrupt, {:digest, "The layout"}}

  defp refusal({:storage, {:limit_reached, :athanor_storage_bytes, cap}}, _revision) do
    {:invalid_argument, "the athanor's storage cap of #{cap} bytes is reached"}
  end

  defp refusal(reason, _revision) do
    Logger.warning(
      "[Compendium.Providers.Layout] no layout was read or published: #{inspect(reason)}"
    )

    {:unavailable, "Layout"}
  end
end
