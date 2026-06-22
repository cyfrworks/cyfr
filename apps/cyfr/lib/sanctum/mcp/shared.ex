# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.Shared do
  @moduledoc """
  Helpers shared across the Sanctum MCP tool modules
  (`Sanctum.MCP` facade and the per-tool modules).

  These are moved verbatim from the original `Sanctum.MCP` module to
  preserve behaviour exactly; only their visibility changed from `defp`
  to `def` so the tool modules can call them.
  """

  alias Sanctum.Context

  def normalize_ref(ref) when is_binary(ref) do
    Sanctum.ComponentRef.normalize_or_name_ref(ref)
  end

  def normalize_ref(ref), do: {:ok, ref}

  # Auto-promote versioned refs to name-level unless pin_version is true.
  # Returns {:ok, store_ref, promoted_from | nil}
  def maybe_promote_to_name_level(ref, true = _pin_version), do: {:ok, ref, nil}

  def maybe_promote_to_name_level(ref, _pin_version) do
    case Sanctum.ComponentRef.parse(ref) do
      {:ok, %Sanctum.ComponentRef{version: nil}} ->
        # Already name-level
        {:ok, ref, nil}

      {:ok, parsed} ->
        name_ref = Sanctum.ComponentRef.to_name_ref(parsed)
        {:ok, name_ref, ref}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def format_permissions(permissions) do
    permissions
    |> MapSet.to_list()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  def require_permission(ctx, permission), do: Context.require_permission(ctx, permission)
end
