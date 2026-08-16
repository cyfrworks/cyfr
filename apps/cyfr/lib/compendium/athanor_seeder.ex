# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AthanorSeeder do
  @moduledoc """
  Seed an athanor with the bundled components.

  Component storage is athanor-scoped (`components/{athanor_id}/...`), so a
  brand-new athanor starts empty. The seed bundle (`Compendium.Bundle`,
  `components/_bundle/`) is copied in — the `http`/`files` catalysts, the
  `aqua`/`list-models` formulas, sample tinctures — and the athanor's own
  scan registers the copies, giving every athanor the same working baseline.

  Seeding is idempotent — re-seeding copies identical bytes and the rescan
  reports the components as unchanged. It is not best-effort: a copy failure
  is returned, and the caller decides what an athanor without its baseline
  means.
  """

  require Logger

  alias Compendium.{AutoIndexer, Bundle, ComponentPath}

  @doc """
  Copy the bundle into the athanor and register it.

  Returns `:ok`, `{:error, :bundle_missing}` when the install has no bundle,
  or `{:error, reason}` on the first failed copy.
  """
  @spec seed(String.t() | %{id: String.t()}) :: :ok | {:error, term()}
  def seed(%{id: athanor_id}), do: seed(athanor_id)

  def seed(athanor_id) when is_binary(athanor_id) and athanor_id != "" do
    # A server-internal context working inside the new athanor: the only kind
    # of context allowed to read the bundle, and the one whose scan registers
    # rows for this athanor alone.
    ctx =
      Sanctum.internal_context(
        user_id: "_seed",
        athanor_id: athanor_id,
        scope: :athanor
      )

    with :ok <- bundle_present(ctx),
         :ok <- copy_bundle(ctx, athanor_id) do
      AutoIndexer.scan(ctx: ctx)
      :ok
    end
  end

  # An install without its bundle cannot provision anyone; say so rather than
  # minting an empty athanor.
  defp bundle_present(ctx) do
    case Arca.list_recursive(ctx, Bundle.bundle_prefix()) do
      {:ok, [_ | _]} -> :ok
      {:ok, []} -> {:error, :bundle_missing}
      {:error, reason} -> {:error, {:bundle_unreadable, reason}}
    end
  end

  # A type the bundle does not carry (no reagents shipped, say) lists empty
  # and copies nothing.
  defp copy_bundle(ctx, athanor_id) do
    Enum.reduce_while(Bundle.type_plurals(), :ok, fn type_plural, :ok ->
      src = Bundle.bundle_prefix() ++ [type_plural, Bundle.publisher()]
      dest = ComponentPath.base_prefix(athanor_id) ++ [type_plural, Bundle.publisher()]

      case Arca.copy_tree(ctx, src, dest) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          Logger.warning(
            "[AthanorSeeder] Failed to seed #{athanor_id} (#{type_plural}): #{inspect(reason)}"
          )

          {:halt, {:error, {:seed_failed, type_plural, reason}}}
      end
    end)
  end
end
