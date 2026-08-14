# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Source.DB do
  @moduledoc """
  The production consent source: profiles and head consents from Arca,
  decoded strictly into the loader's vocabulary.

  Decoding fails closed — a stored scope, kind or invoke mode outside the
  closed vocabulary, or an activation blob that does not parse, refuses
  the consent rather than guessing. Rows can only get that way through a
  bug or a hand edit, and neither may root an execution.
  """

  @behaviour Sanctum.Consent.Source

  alias Sanctum.Context

  @impl Sanctum.Consent.Source
  def profiles(%Context{} = ctx, source_ref) do
    with {:ok, rows} <-
           Arca.ProfileStorage.list_for_source(ctx.org_id, ctx.project_id, source_ref) do
      summaries =
        rows
        |> Enum.map(&profile_summary/1)
        |> Enum.reject(&is_nil/1)

      {:ok, summaries}
    end
  end

  @impl Sanctum.Consent.Source
  def head_consent(%Context{} = ctx, profile_id) do
    with {:ok, consent, refs} <- Arca.ConsentStorage.get_head(ctx.org_id, ctx.project_id, profile_id) do
      decode_consent(consent, refs)
    end
  end

  defp profile_summary(row) do
    with {:ok, kind} <- decode_enum(row.kind, %{"owner" => :owner, "public" => :public}),
         {:ok, status} <-
           decode_enum(row.status, %{
             "active" => :active,
             "needs_consent" => :needs_consent,
             "revoked" => :revoked
           }) do
      %{id: row.id, kind: kind, source_ref: row.source_ref, label: row.label, status: status}
    else
      _ -> nil
    end
  end

  defp decode_consent(consent, refs) do
    with {:ok, scope} <-
           decode_enum(consent.scope, %{"versionless" => :versionless, "pinned" => :pinned}),
         {:ok, invoke_mode} <-
           decode_enum(consent.invoke_mode, %{
             "open_inert" => :open_inert,
             "edge_only" => :edge_only
           }),
         {:ok, activation} <- decode_activation(consent.activation) do
      {:ok,
       %{
         id: consent.id,
         revision: consent.revision,
         scope: scope,
         pinned_version: consent.pinned_version,
         invoke_mode: invoke_mode,
         shape_digest: consent.shape_digest,
         commit_digest: consent.commit_digest,
         resolved_policy: consent.resolved_policy,
         activation: activation,
         vault_refs:
           Enum.map(refs, fn r ->
             %{vault_entry_id: r.vault_entry_id, binding_digest: r.binding_digest}
           end)
       }}
    end
  end

  defp decode_enum(value, mapping) do
    case Map.fetch(mapping, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_stored_value, value}}
    end
  end

  defp decode_activation(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, %{} = graph} ->
        if Enum.all?(graph, fn {k, v} -> is_binary(k) and is_binary(v) end) do
          {:ok, graph}
        else
          {:error, {:invalid_stored_value, :activation}}
        end

      _ ->
        {:error, {:invalid_stored_value, :activation}}
    end
  end

  defp decode_activation(_), do: {:error, {:invalid_stored_value, :activation}}
end
