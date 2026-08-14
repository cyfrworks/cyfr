# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.Payload do
  @moduledoc """
  The sealed vault-entry payload document:

      {"v":2,"fields":{"url":"https://…","anon_key":"…"},
       "oauth":{"access_token":"…","refresh_token":"…",
                "expires_at":"2026-08-07T12:00:00Z","token_type":"bearer"}}

  Decoding is strict: unknown top-level keys, non-string field values and
  malformed oauth blocks are refused, so a tampered or mis-written payload
  fails before any of it is dispensed.

  The retired v1 pointer document (`{"v":1,"legacy":…}`, which pointed into
  credential stores that no longer exist) is refused HERE, in the one place
  every read decodes through, as `:legacy_pointer_retired` — recreate the
  entry to store real material.
  """

  @type t :: map()

  @oauth_keys ~w(access_token refresh_token expires_at token_type scopes)

  @doc "Decode and validate a sealed payload's plaintext."
  @spec decode(binary()) ::
          {:ok, t()} | {:error, {:invalid_payload, term()} | :legacy_pointer_retired}
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

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate(%{"v" => 1}), do: {:error, :legacy_pointer_retired}

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
