# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Cards do
  @moduledoc """
  A card placed on a person's desktop, refreshed or pressed: the `card`
  tool's work (`Crucible.Provider`).

  The caller names a slot of their own layout (`Compendium.layout/2`) and
  nothing else. The slot names the tincture and which of its cards it
  shows (the first declared one when it names none); the tincture's
  newest installed version, read through `Compendium`, declares the rest.
  A slot that is not card-size, a tincture that is not installed and a
  card the tincture does not declare are each refused before anything
  runs.

    * `refresh/3` runs the card's `source` — an invoke of a component the
      tincture may invoke, with arguments fixed at publish — exactly as a
      frame's invoke of it runs (`Crucible.invoke_tincture/3`, the
      protected route): the card tincture's owner profile roots the run,
      as the person, charged to their athanor, so a tincture the person
      has not granted answers the consent-needed refusal and runs
      nothing. A card with no source is static and runs nothing. The
      answer is projected through the declaration (`Prima.Card.project/3`),
      broadcast on the person's own cards topic (`Cyfr.Bus.cards/2`) once
      the refresh has completed, and answered as `Prima.Card.to_json/1`
      gives it. A projection the card's bounds refuse is refused, and
      nothing is broadcast.
    * `press/4` fires the action the card's declared button names, with
      its declared arguments, through the gate under the caller's context.
      A button never fires the `card` tool itself.
  """

  alias Prima.Manifest.Tincture
  alias Sanctum.Context

  require Logger

  @typedoc "A placed card: its slot, its tincture's reference and row, and its declaration."
  @type placed :: %{
          slot: Prima.Layout.slot(),
          reference: Prima.ComponentRef.t(),
          declaration: Tincture.t(),
          card: Tincture.Card.t()
        }

  @doc """
  Refresh the card in `slot_id` of the caller's `posture`: its source run
  under the card tincture's grant, projected, broadcast to the caller's own
  cards topic, and answered as the desktop draws it.
  """
  @spec refresh(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def refresh(%Context{} = ctx, slot_id, posture) do
    with {:ok, placed} <- placed(ctx, slot_id, posture),
         {:ok, projection} <- run(ctx, placed),
         {:ok, card} <- project(placed.card, projection) do
      data = Prima.Card.to_json(card)
      broadcast(ctx, placed, data)
      {:ok, data}
    end
  end

  @doc """
  Press button `index` of the card in `slot_id` of the caller's `posture`:
  the button's declared action with its declared arguments, through the
  gate under the caller's context. The gate's answer is the answer.
  """
  @spec press(Context.t(), String.t(), String.t(), integer()) :: {:ok, term()} | {:error, term()}
  def press(%Context{} = ctx, slot_id, posture, index) do
    with {:ok, placed} <- placed(ctx, slot_id, posture),
         {:ok, button} <- button(placed.card, index),
         {:ok, tool, action} <- button_action(placed.card, button) do
      Grimoire.call_external(tool, ctx, Map.put(button.args, "action", action))
    end
  end

  # ---------------------------------------------------------------------------
  # The placed card
  # ---------------------------------------------------------------------------

  defp placed(ctx, slot_id, posture) do
    with {:ok, layout} <- Compendium.layout(ctx, posture),
         {:ok, slot} <- slot(layout.arrangement, slot_id),
         {:ok, reference, manifest} <- installed(ctx, slot.tincture),
         {:ok, declaration} <- declaration(slot.tincture, manifest),
         {:ok, card} <- card(slot, declaration) do
      {:ok, %{slot: slot, reference: reference, declaration: declaration, card: card}}
    end
  end

  defp slot(arrangement, slot_id) do
    case Enum.find(arrangement.slots, &(&1.id == slot_id)) do
      nil ->
        {:error, {:not_found, "Slot", slot_id}}

      %{size: :card} = slot ->
        {:ok, slot}

      %{size: size} ->
        {:error,
         {:invalid_argument,
          "slot #{slot_id} is #{size}-size; only a card-size slot shows a card"}}
    end
  end

  # The tincture's newest installed version in the caller's athanor.
  defp installed(ctx, tincture) do
    with {:ok, reference} <- Prima.ComponentRef.parse(tincture),
         {:ok, row} <- Compendium.inspect_component(ctx, tincture) do
      {:ok, reference, manifest(row["manifest"])}
    else
      {:error, {:not_found, _what}} ->
        {:error, {:not_found, "Tincture", tincture}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp manifest(manifest) when is_map(manifest), do: manifest

  defp manifest(manifest) when is_binary(manifest) do
    case Jason.decode(manifest) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp manifest(_manifest), do: %{}

  defp declaration(tincture, manifest) do
    case Compendium.tincture_declaration(manifest) do
      {:ok, declaration} ->
        {:ok, declaration}

      {:error, {:invalid_tincture, sentence}} ->
        {:error, {:invalid_argument, "#{tincture} declares no card it can show: #{sentence}"}}
    end
  end

  defp card(%{card: nil, tincture: tincture}, %Tincture{cards: []}),
    do: {:error, {:not_found, "Card", "#{tincture} declares no card"}}

  defp card(%{card: nil}, %Tincture{cards: [first | _]}), do: {:ok, first}

  defp card(%{card: name, tincture: tincture}, declaration) do
    case Prima.Card.declared(declaration, name) do
      {:ok, card} -> {:ok, card}
      :error -> {:error, {:not_found, "Card", "#{tincture} #{name}"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Refresh
  # ---------------------------------------------------------------------------

  # A static card runs nothing.
  defp run(_ctx, %{card: %Tincture.Card{source: nil}}), do: {:ok, %{}}

  # The source runs as a frame's invoke of the same component runs: the
  # tincture's own grant, rooted and charged as the person.
  defp run(ctx, %{card: %Tincture.Card{source: source}, reference: reference}) do
    args = %{
      "publisher" => reference.namespace,
      "tincture_name" => reference.name,
      "reference" => source.component,
      "input" => %{"operation" => source.operation, "params" => source.args}
    }

    case Crucible.invoke_tincture(ctx, args, :protected) do
      {:ok, %{output: output}} -> {:ok, output}
      {:error, refusal} -> {:error, refusal}
    end
  end

  defp project(card, projection) do
    case Prima.Card.project(card, projection, DateTime.utc_now()) do
      {:ok, shown} -> {:ok, shown}
      {:error, {:invalid_card, sentence}} -> {:error, {:conflict, sentence}}
    end
  end

  defp broadcast(ctx, placed, data) do
    actor = Context.actor(ctx)

    payload =
      Cyfr.Bus.CardRefreshed.new(actor, %{
        tincture: placed.slot.tincture,
        card: placed.card.name,
        slot: placed.slot.id,
        user_id: ctx.user_id,
        data: data
      })

    case Cyfr.Bus.broadcast(actor, Cyfr.Bus.cards(actor, ctx.user_id), payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Crucible.Cards] a refreshed card was not broadcast: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Press
  # ---------------------------------------------------------------------------

  defp button(%Tincture.Card{name: name, buttons: buttons}, index) do
    case is_integer(index) and index >= 0 and Enum.at(buttons, index) do
      %Tincture.Button{} = button ->
        {:ok, button}

      _none ->
        {:error,
         {:invalid_argument,
          "card #{name} has #{length(buttons)} button(s); there is no button #{index}"}}
    end
  end

  # A button fires a system action and never the card tool, so a press can
  # neither refresh nor press again.
  defp button_action(%Tincture.Card{name: name}, %Tincture.Button{action: operation}) do
    case String.split(operation, ".", parts: 2) do
      ["card", _action] ->
        {:error, {:invalid_argument, "card #{name}: a button never fires #{operation}"}}

      [tool, action] ->
        {:ok, tool, action}
    end
  end
end
