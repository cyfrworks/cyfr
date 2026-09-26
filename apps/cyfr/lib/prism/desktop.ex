# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.Desktop do
  @moduledoc """
  The desktop's arrangement as the shell reads it: plain functions over
  the person's layout document (`Prima.Layout`), holding no state.

    * `layout/2` reads the caller's layout and one posture's arrangement
      through `Compendium.layout/2`, under the caller's context.
    * `slots/2` is that arrangement's slots in order, each with its size
      and its tincture resolved against the installed ones the caller
      lists: the installed tincture, or a placeholder for a reference
      nobody installed (the layout keeps it).
    * `percent/1` turns a floating position, 0 to 10000 per axis, into
      percentages of the viewport.
    * `edit/3` publishes a whole document at the revision it was read at,
      through the gate's `layout.edit` under the caller's context, and
      answers the gate's result: an edit is only ever made there.
  """

  alias Sanctum.Context

  @max_position 10_000

  @typedoc "A slot as the desktop draws it."
  @type slot :: %{
          id: String.t(),
          tincture: Prima.Layout.ref(),
          size: Prima.Layout.size(),
          order: non_neg_integer(),
          card: String.t() | nil,
          resolved: {:installed, map()} | :placeholder
        }

  @doc "The caller's layout and `posture`'s arrangement (`Compendium.layout/2`)."
  @spec layout(Context.t(), Prima.Layout.posture_name()) :: {:ok, map()} | {:error, term()}
  def layout(%Context{} = ctx, posture), do: Compendium.layout(ctx, posture)

  @doc """
  The slots of `arrangement` (a posture of `Prima.Layout`) in their
  `{order, id}` order, each resolved against `installed`: rows naming a
  tincture by `publisher` and `name` (as `Prism.TinctureRegistry` lists
  them). A reference no row names resolves to `:placeholder`.
  """
  @spec slots(Prima.Layout.posture(), [map()]) :: [slot()]
  def slots(%{slots: slots}, installed) when is_list(installed) do
    by_ref =
      Map.new(installed, fn row ->
        {Prima.ComponentRef.build("tincture", row.publisher, row.name), row}
      end)

    slots
    |> Enum.sort_by(&{&1.order, &1.id})
    |> Enum.map(fn slot ->
      resolved =
        case Map.fetch(by_ref, slot.tincture) do
          {:ok, row} -> {:installed, row}
          :error -> :placeholder
        end

      Map.put(slot, :resolved, resolved)
    end)
  end

  @doc """
  A floating position as percentages of the viewport: `x` and `y` are
  hundredths of a percent, 0 to #{@max_position}, so 2500 is 25.0.
  """
  @spec percent(%{x: non_neg_integer(), y: non_neg_integer()}) :: %{x: float(), y: float()}
  def percent(%{x: x, y: y})
      when x in 0..@max_position//1 and y in 0..@max_position//1,
      do: %{x: x / 100, y: y / 100}

  @doc """
  Publish `document` (the whole layout, in its JSON form) over `revision`
  through the gate's `layout.edit` under the caller's context. The gate's
  answer is the answer: `{:ok, %{revision, digest}}`, or its refusal — a
  document published since `revision` was read is a conflict, and the
  desktop reads again.
  """
  @spec edit(Context.t(), map(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def edit(%Context{} = ctx, document, revision) do
    Grimoire.call_external("layout", ctx, %{
      "action" => "edit",
      "document" => document,
      "revision" => revision
    })
  end
end
