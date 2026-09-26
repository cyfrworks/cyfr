# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.SecretMasker do
  @moduledoc """
  Masks credential values in execution output to prevent leakage in logs.

  A component that reads a credential must not have it echoed back into
  execution logs or audit records, so every value it was handed is replaced
  with `[REDACTED]` before the output is recorded.

  Each secret is searched in its raw form and, for a secret of four or more
  characters, as base64, url-safe base64, lower- and upper-case hex, JSON
  string content (as Jason writes it, without the quotes) and URL encoding
  (both `application/x-www-form-urlencoded` and percent-encoding of every
  character outside the unreserved set). A shorter secret is searched raw only: its encodings
  match too much unrelated text.

  ## Usage

  The caller supplies the values, because it is the caller that dispensed
  them (the vault fields unsealed for the run plus the OAuth tokens handed
  out during it), and masks at each egress of guest-influenced text:
  completed output, failure messages and guest-emitted events.

      masked_output = Prima.SecretMasker.mask(output, secret_values)

  ## Security Note

  This is a defense-in-depth measure against accidental disclosure. The
  primary control is that a credential reaches a component only through a
  consent edge, and the projection and egress bounds are what stop a
  malicious guest; masking covers the case where the component puts one in
  its own output under an encoding listed above.
  """

  @redacted "[REDACTED]"

  @doc """
  Mask secret values in output.

  Replaces any occurrence of secret values in the output with `[REDACTED]`.
  Works with maps, lists, and string values.

  ## Examples

      iex> Prima.SecretMasker.mask(%{"result" => "key is sk-secret123"}, ["sk-secret123"])
      %{"result" => "key is [REDACTED]"}

      iex> Prima.SecretMasker.mask(%{"data" => ["value1", "sk-secret"]}, ["sk-secret"])
      %{"data" => ["value1", "[REDACTED]"]}

  """
  @spec mask(term(), [String.t()]) :: term()
  def mask(output, secret_values) do
    case search_forms(secret_values) do
      [] -> output
      forms -> do_mask(output, forms)
    end
  end

  @doc """
  How many bytes at the end of `text` could begin a form `mask/2` replaces
  without completing it: the longest tail of `text` that is a proper prefix
  of one. A stream that holds those bytes back until more text arrives never
  releases part of a credential it would have masked whole, and holds
  nothing back when the text ends in no such prefix.

      iex> Prima.SecretMasker.pending_prefix("key: sk-se", ["sk-secret"])
      5

      iex> Prima.SecretMasker.pending_prefix("nothing to hold", ["sk-secret"])
      0
  """
  @spec pending_prefix(binary(), [String.t()]) :: non_neg_integer()
  def pending_prefix(text, secret_values) when is_binary(text) do
    secret_values
    |> search_forms()
    |> Enum.map(&open_prefix(text, &1))
    |> Enum.max(fn -> 0 end)
  end

  defp open_prefix(text, form) do
    size = byte_size(text)

    Enum.find(min(size, byte_size(form) - 1)..1//-1, 0, fn k ->
      binary_part(text, size - k, k) == binary_part(form, 0, k)
    end)
  end

  # Every form of every usable secret, deduplicated across the whole set and
  # longest first. Replacing in that order means a form that is a prefix or
  # substring of another secret's form never masks part of it and leaves the
  # remainder in clear; the longest form also bounds what `pending_prefix/2`
  # can hold back, at one byte short of its size.
  defp search_forms(secret_values) do
    secret_values
    |> usable_secrets()
    |> Enum.flat_map(&forms/1)
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  # A secret is replaceable only as a non-empty binary. `String.replace/3`
  # with `""` inserts the marker between every character — corrupting the
  # whole output rather than redacting anything — and a non-binary raises.
  # Both shapes come from caller data (a vault field projected empty, a
  # token bundle that carried a non-string), so they are filtered, not
  # trusted.
  defp usable_secrets(values) when is_list(values),
    do: Enum.filter(values, &(is_binary(&1) and &1 != ""))

  defp usable_secrets(_values), do: []

  # Through JSON, so nested structures mask consistently. A value JSON
  # cannot carry, or a replacement that broke the JSON, masks the map
  # directly instead.
  defp do_mask(output, forms) when is_map(output) do
    with {:ok, json} <- Jason.encode(output),
         {:ok, result} <- json |> mask_in_string(forms) |> Jason.decode() do
      result
    else
      {:error, _} -> mask_map(output, forms)
    end
  end

  defp do_mask(output, forms) when is_binary(output) do
    mask_in_string(output, forms)
  end

  defp do_mask(output, forms) when is_list(output) do
    Enum.map(output, fn item -> do_mask(item, forms) end)
  end

  defp do_mask(output, _forms), do: output

  # Mask secrets directly in a map (fallback for non-JSON-encodable maps)
  defp mask_map(map, forms) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      {do_mask(k, forms), do_mask(v, forms)}
    end)
    |> Map.new()
  end

  # Replace every form in a string, in `search_forms/1`'s order, which keeps
  # a longer form from being split by a shorter one replaced first.
  defp mask_in_string(str, forms) when is_binary(str) do
    Enum.reduce(forms, str, &String.replace(&2, &1, @redacted))
  end

  # A secret and, for one of four or more characters, its encodings; a
  # shorter secret's encodings match too much unrelated text. Every encoding
  # of a four-character secret is at least four characters long.
  defp forms(secret) do
    if String.length(secret) >= 4 do
      [
        secret,
        Base.encode64(secret),
        Base.url_encode64(secret),
        Base.encode16(secret, case: :lower),
        Base.encode16(secret, case: :upper)
        | json_escaped(secret) ++ url_encoded(secret)
      ]
    else
      [secret]
    end
  end

  # The secret as the content of a JSON string, as Jason writes it, when
  # that differs from the raw bytes. A secret that is not valid UTF-8 has
  # no JSON form.
  defp json_escaped(secret) do
    case Jason.encode(secret) do
      {:ok, json} ->
        escaped = binary_part(json, 1, byte_size(json) - 2)
        if escaped == secret, do: [], else: [escaped]

      {:error, _} ->
        []
    end
  end

  # The secret form-encoded (space as `+`) and percent-encoded (space as
  # `%20`), each when it differs from the raw bytes.
  defp url_encoded(secret) do
    [URI.encode_www_form(secret), URI.encode(secret, &URI.char_unreserved?/1)]
    |> Enum.reject(&(&1 == secret))
    |> Enum.uniq()
  end
end
