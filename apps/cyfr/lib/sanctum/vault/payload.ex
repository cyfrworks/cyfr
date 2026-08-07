# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.Payload do
  @moduledoc """
  The sealed vault-entry payload document, both versions:

      v1 — legacy pointer into the pre-vault stores
      {"v":1,"legacy":{"secrets":[{"name":"KEY","scope":"project"}],
                       "oauth":[{"component_ref":"catalyst:local.gmail",
                                 "provider":"google"}]}}

      v2 — the material itself
      {"v":2,"fields":{"url":"https://…","anon_key":"…"},
       "oauth":{"access_token":"…","refresh_token":"…",
                "expires_at":"2026-08-07T12:00:00Z","token_type":"bearer"}}

  Decoding is strict: unknown top-level keys, non-string field values and
  malformed oauth blocks are refused, so a tampered or mis-written payload
  fails before any of it is dispensed. v1 pointer internals are validated
  by the reader that resolves them.
  """

  @type t :: map()

  @oauth_keys ~w(access_token refresh_token expires_at token_type scopes)

  @doc "Decode and validate a sealed payload's plaintext."
  @spec decode(binary()) :: {:ok, t()} | {:error, {:invalid_payload, term()}}
  def decode(plaintext) when is_binary(plaintext) do
    case Jason.decode(plaintext) do
      {:ok, decoded} -> validate(decoded)
      {:error, reason} -> {:error, {:invalid_payload, reason}}
    end
  end

  @doc """
  Encode a v2 material payload. `fields` is the name → value map mirrored
  (names only) by the row's unsealed `field_names` column; `oauth` is the
  token bundle or nil.
  """
  @spec encode_material(%{String.t() => String.t()}, map() | nil) ::
          {:ok, binary()} | {:error, {:invalid_payload, term()}}
  def encode_material(fields, oauth \\ nil) do
    doc =
      %{"v" => 2, "fields" => fields}
      |> then(fn doc -> if oauth, do: Map.put(doc, "oauth", oauth), else: doc end)

    with {:ok, valid} <- validate(doc) do
      {:ok, Jason.encode!(valid)}
    end
  end

  @doc "Whether a decoded payload is a v1 legacy pointer."
  @spec legacy?(t()) :: boolean()
  def legacy?(%{"v" => 1}), do: true
  def legacy?(_), do: false

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate(%{"v" => 1, "legacy" => legacy} = doc) when is_map(legacy) do
    with :ok <- only_keys(doc, ~w(v legacy)),
         :ok <- only_keys(legacy, ~w(secrets oauth)),
         :ok <- check_pointer_list(legacy, "secrets"),
         :ok <- check_pointer_list(legacy, "oauth") do
      {:ok, doc}
    end
  end

  defp validate(%{"v" => 2, "fields" => fields} = doc) when is_map(fields) do
    with :ok <- only_keys(doc, ~w(v fields oauth)),
         :ok <- check_fields(fields),
         :ok <- check_oauth(Map.get(doc, "oauth")) do
      {:ok, doc}
    end
  end

  defp validate(other), do: {:error, {:invalid_payload, other}}

  defp only_keys(map, allowed) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      extra -> {:error, {:invalid_payload, {:unknown_keys, Enum.sort(extra)}}}
    end
  end

  defp check_pointer_list(legacy, key) do
    case Map.get(legacy, key) do
      nil -> :ok
      list when is_list(list) -> if Enum.all?(list, &is_map/1), do: :ok, else: bad(key)
      _ -> bad(key)
    end
  end

  defp check_fields(fields) do
    valid? =
      Enum.all?(fields, fn
        {name, value} -> is_binary(name) and name != "" and is_binary(value)
      end)

    if valid?, do: :ok, else: bad("fields")
  end

  defp check_oauth(nil), do: :ok

  defp check_oauth(%{"access_token" => token} = oauth) when is_binary(token) do
    with :ok <- only_keys(oauth, @oauth_keys) do
      optional_ok? =
        optional_string?(oauth, "refresh_token") and
          optional_string?(oauth, "expires_at") and
          optional_string?(oauth, "token_type") and
          optional_string_list?(oauth, "scopes")

      if optional_ok?, do: :ok, else: bad("oauth")
    end
  end

  defp check_oauth(_), do: bad("oauth")

  defp optional_string?(map, key) do
    case Map.get(map, key) do
      nil -> true
      v -> is_binary(v)
    end
  end

  defp optional_string_list?(map, key) do
    case Map.get(map, key) do
      nil -> true
      list when is_list(list) -> Enum.all?(list, &is_binary/1)
      _ -> false
    end
  end

  defp bad(key), do: {:error, {:invalid_payload, {:malformed, key}}}
end
