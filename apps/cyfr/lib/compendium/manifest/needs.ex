# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Manifest.Needs do
  @moduledoc """
  The manifest `needs` block: named roles a component asks the operator
  to satisfy with Connections.

  Two vocabularies meet only at consent — the developer names *roles*
  (`source`, `dest`, `api_key`); the operator names *credentials*;
  consent maps them. A component never writes or learns a vault entry
  name.

  ## Shape

      "needs": {
        "api_key": { "type": "api_key:anthropic.com",
                     "reason": "to call the Anthropic API with your key",
                     "fields": ["ANTHROPIC_API_KEY"], "required": true }
      }

  The need name is the slot key (`ref|need` in blob edge keys), so the
  edge-key grammar constrains it: lowercase, no `@` prefix, no `|`.
  `type` is `kind:qualifier` — a credential kind (`api_key`, `oauth`,
  `bundle`) or a component type for component-typed needs. `reason` is
  the prose the operator sees instead of the developer's key names.
  `fields` are the guest-visible read keys, served from the bound entry's
  material as the projection — the names the binary already passes to
  `cyfr:secrets/read.get`, so no interface changes. `scopes` applies to
  OAuth kinds only.
  """

  @name_re ~r/^[a-z][a-z0-9_-]{0,31}$/
  @type_re ~r/^[a-z_]+:[a-z0-9._-]+$/
  @kinds ~w(api_key oauth bundle catalyst reagent formula)
  @entry_keys ~w(type reason fields scopes required)

  @type error :: {:invalid_needs, term()}

  @doc """
  Validate a decoded manifest's `needs` block. Absent is valid.
  """
  @spec validate(map() | nil) :: :ok | {:error, error()}
  def validate(nil), do: :ok

  def validate(%{"needs" => needs}) when is_map(needs) do
    Enum.reduce_while(needs, :ok, fn {name, entry}, :ok ->
      case validate_need(name, entry) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def validate(%{"needs" => other}), do: {:error, {:invalid_needs, {:not_a_map, other}}}
  def validate(manifest) when is_map(manifest), do: :ok

  @doc """
  The normalized needs for a decoded manifest: a sorted list of
  `%{name, kind, qualifier, reason, fields, scopes, required}`. Returns
  `nil` when the manifest declares no `needs` block.
  """
  @spec from_manifest(map() | nil) :: [map()] | nil
  def from_manifest(%{"needs" => needs} = manifest) when is_map(needs) do
    case validate(manifest) do
      :ok ->
        needs
        |> Enum.map(fn {name, entry} ->
          [kind, qualifier] = String.split(entry["type"], ":", parts: 2)

          %{
            name: name,
            kind: kind,
            qualifier: qualifier,
            reason: entry["reason"],
            fields: Enum.sort(entry["fields"] || []),
            scopes: Enum.sort(entry["scopes"] || []),
            required: Map.get(entry, "required", true)
          }
        end)
        |> Enum.sort_by(& &1.name)

      {:error, _} ->
        nil
    end
  end

  def from_manifest(_manifest), do: nil

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp validate_need(name, entry) do
    cond do
      not is_binary(name) or not Regex.match?(@name_re, name) ->
        {:error, {:invalid_needs, {:invalid_name, name}}}

      not is_map(entry) ->
        {:error, {:invalid_needs, {:not_a_map, name}}}

      true ->
        with :ok <- only_keys(entry, name),
             :ok <- validate_type(name, entry["type"]),
             :ok <- validate_reason(name, entry["reason"]),
             :ok <- validate_names(name, :fields, entry["fields"]),
             :ok <- validate_scopes(name, entry),
             :ok <- validate_required(name, entry) do
          :ok
        end
    end
  end

  defp only_keys(entry, name) do
    case Map.keys(entry) -- @entry_keys do
      [] -> :ok
      unknown -> {:error, {:invalid_needs, {:unknown_keys, name, Enum.sort(unknown)}}}
    end
  end

  defp validate_type(name, type) do
    with true <- is_binary(type),
         true <- Regex.match?(@type_re, type),
         [kind, _qualifier] <- String.split(type, ":", parts: 2),
         true <- kind in @kinds do
      :ok
    else
      _ -> {:error, {:invalid_needs, {:invalid_type, name, type}}}
    end
  end

  defp validate_reason(name, reason) do
    if is_binary(reason) and String.trim(reason) != "",
      do: :ok,
      else: {:error, {:invalid_needs, {:reason_required, name}}}
  end

  defp validate_names(_name, _key, nil), do: :ok

  defp validate_names(name, key, list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, {:invalid_needs, {:invalid_list, name, key}}}
  end

  defp validate_names(name, key, _other),
    do: {:error, {:invalid_needs, {:invalid_list, name, key}}}

  defp validate_scopes(name, entry) do
    case entry["scopes"] do
      nil ->
        :ok

      scopes ->
        with :ok <- validate_names(name, :scopes, scopes) do
          if String.starts_with?(entry["type"] || "", "oauth:"),
            do: :ok,
            else: {:error, {:invalid_needs, {:scopes_on_non_oauth, name}}}
        end
    end
  end

  defp validate_required(name, entry) do
    case Map.get(entry, "required", true) do
      value when is_boolean(value) -> :ok
      other -> {:error, {:invalid_needs, {:invalid_required, name, other}}}
    end
  end
end
