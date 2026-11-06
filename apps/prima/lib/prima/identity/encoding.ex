# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Identity.Encoding do
  @moduledoc """
  The encodings every shape of the identity, device-certificate, device,
  confirmation, registry-request and sign-in protocols shares, so a value
  has one spelling on every side.

    * **Identifier.** `per_` and the 64 lowercase hexadecimal digits of
      SHA-256 over the genesis entry's JCS bytes (`Prima.Identity.identifier/1`),
      the same form as a person's local `usr_` id. Its 32 digest bytes are a
      passkey's WebAuthn `user.id` (`Prima.Identity.user_id/1`).
    * **Every other hash** is `Prima.Digest.sha256/1`'s `sha256:<hex>`: entry
      hashes, `prev` and `head`, a key's `kid` (over its public key's
      bytes), and request, payload and confirmation digests.
    * **Binary values** in JSON (public keys, signatures, nonces, a seed) are
      unpadded base64url. Decoding refuses padding, a wrong length and any
      spelling that does not re-encode to itself.
    * **Signatures.** Each signed shape carries its protocol string as a
      field inside what it signs. An Ed25519 signature, the field `sig`,
      covers the JCS bytes (`Prima.JCS`) of the shape's map without its `sig`;
      a passkey's is a WebAuthn assertion over those bytes' SHA-256
      (`Prima.Identity.WebAuthn`).
      A decoder takes only its own protocol string (`protocol/2`) and
      answers any other `:wrong_protocol`, so a shape at a version this
      side does not know is refused, never read as one it knows.
    * **Timestamps** are integer Unix milliseconds, within JCS's integer
      domain.
    * **A home** is named by its origin: `http` or `https`, a lowercase host
      name, and a port only when it is not the scheme's default, with no
      path, user, query or fragment. Only that spelling is accepted, so two
      homes are one exactly when their spellings are equal.
    * **An id** (a client, athanor, carry action, confirmation, request,
      intent or restore id) is 1 to 128 characters of `[A-Za-z0-9_-]`,
      starting with a letter or digit.

  A map a decoder is handed must hold exactly its shape's fields: an unknown
  field answers `{:unknown_field, name}` before a missing one answers
  `{:missing_field, name}`, and a field of the wrong shape answers
  `{:invalid_field, name}`.
  """

  alias Prima.JCS

  @key_bytes 32
  @signature_bytes 64
  @max_ms 9_007_199_254_740_991
  @default_ports %{"http" => 80, "https" => 443}

  @host ~r/\A(?=.{1,253}\z)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/
  @id ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/
  @digest ~r/\Asha256:[0-9a-f]{64}\z/
  @identifier ~r/\Aper_[0-9a-f]{64}\z/
  @path ~r/\A(?:\/[A-Za-z0-9._~!$&'()*+,;=:@%-]+)*\z/
  @max_url_bytes 2048

  @type reason ::
          {:unknown_field, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc "The length of an Ed25519 public or private key, in bytes."
  @spec key_bytes() :: pos_integer()
  def key_bytes, do: @key_bytes

  @doc "Unpadded base64url."
  @spec b64(binary()) :: String.t()
  def b64(bytes) when is_binary(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc """
  Decode unpadded base64url of exactly `size` bytes. Any other spelling of
  the same bytes, padded or with stray trailing bits, is refused.
  """
  @spec unb64(term(), pos_integer()) :: {:ok, binary()} | :error
  def unb64(value, size) when is_binary(value) and is_integer(size) do
    with {:ok, bytes} when byte_size(bytes) == size <- Base.url_decode64(value, padding: false),
         ^value <- b64(bytes) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  def unb64(_value, _size), do: :error

  @doc """
  Decode unpadded base64url of `min` to `max` bytes, in its one spelling,
  for a value whose length varies, such as a passkey's credential id.
  """
  @spec unb64(term(), pos_integer(), pos_integer()) :: {:ok, binary()} | :error
  def unb64(value, min, max) when is_binary(value) and is_integer(min) and is_integer(max) do
    with {:ok, bytes} when byte_size(bytes) >= min and byte_size(bytes) <= max <-
           Base.url_decode64(value, padding: false),
         ^value <- b64(bytes) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  def unb64(_value, _min, _max), do: :error

  @doc "Whether `value` is an Ed25519 public key: 32 bytes."
  @spec key?(term()) :: boolean()
  def key?(value), do: is_binary(value) and byte_size(value) == @key_bytes

  @doc "Whether `value` is a `sha256:<hex>` digest."
  @spec digest?(term()) :: boolean()
  def digest?(value), do: is_binary(value) and Regex.match?(@digest, value)

  @doc "Whether `value` is a person identifier, `per_<hex>`."
  @spec identifier?(term()) :: boolean()
  def identifier?(value), do: is_binary(value) and Regex.match?(@identifier, value)

  @doc "Whether `value` is an id."
  @spec id?(term()) :: boolean()
  def id?(value), do: is_binary(value) and Regex.match?(@id, value)

  @doc "Whether `value` is a timestamp: a non-negative integer of milliseconds."
  @spec ms?(term()) :: boolean()
  def ms?(value), do: is_integer(value) and value >= 0 and value <= @max_ms

  @doc "Whether `value` is non-empty UTF-8 of at most `max` bytes with no control character."
  @spec text?(term(), pos_integer()) :: boolean()
  def text?(value, max) do
    is_binary(value) and value != "" and byte_size(value) <= max and String.valid?(value) and
      not String.match?(value, ~r/[\x00-\x1f\x7f]/u)
  end

  @doc "Whether `value` is a lowercase host name."
  @spec host?(term()) :: boolean()
  def host?(value), do: is_binary(value) and Regex.match?(@host, value)

  @doc "Whether `value` names a home in its one accepted spelling."
  @spec home?(term()) :: boolean()
  def home?(value), do: match?({:ok, ^value, _host}, parse_home(value))

  @doc """
  The one accepted spelling of a home written another way: its scheme and
  host lowercased (ASCII only), the scheme's default port and a trailing
  `/` dropped. Anything that is not a home however it is spelled, such as
  another scheme, a path, a user, a query or a fragment, is `:error`.

  It is for an origin this side was configured with. A home on the wire
  must already be in its spelling (`home?/1`).
  """
  @spec canonical_home(term()) :: {:ok, String.t()} | :error
  def canonical_home(value) do
    case parse_home(value) do
      {:ok, home, _host} -> {:ok, home}
      :error -> :error
    end
  end

  @doc "A home's host name. The home must be a valid spelling."
  @spec home_host(String.t()) :: String.t()
  def home_host(home) do
    {:ok, ^home, host} = parse_home(home)
    host
  end

  @doc """
  Whether `value` is a directory URL: a home's origin followed by an
  optional path of `/`-separated segments with no trailing `/`, no user,
  query or fragment, at most 2048 bytes.
  """
  @spec directory_url?(term()) :: boolean()
  def directory_url?(value) when is_binary(value) and byte_size(value) <= @max_url_bytes do
    with {:ok, %URI{scheme: scheme, host: host} = uri}
         when is_binary(scheme) and is_binary(host) <- URI.new(value),
         true <- bare?(uri),
         origin = origin(scheme, host, uri.port),
         path = uri.path || "",
         true <- home?(origin) and Regex.match?(@path, path) do
      value == origin <> path
    else
      _ -> false
    end
  end

  def directory_url?(_value), do: false

  @doc """
  A directory URL's origin and host: the origin its account pages are
  served at, and the host that is its passkeys' relying party. The URL
  must be one `directory_url?/1` accepts.
  """
  @spec directory_origin(String.t()) :: {String.t(), String.t()}
  def directory_origin(url) do
    true = directory_url?(url)
    {:ok, %URI{scheme: scheme, host: host, port: port}} = URI.new(url)
    {origin(scheme, host, port), host}
  end

  defp bare?(uri), do: is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)

  # A home's spelling and host, from any spelling of it. `URI.new/1`
  # lowercases the scheme; the host is lowercased in ASCII alone, so no
  # Unicode case mapping (the Kelvin sign to `k`) can make a host.
  defp parse_home(value) when is_binary(value) and byte_size(value) <= 300 do
    with {:ok, %URI{scheme: scheme, host: host, port: port} = uri}
         when scheme in ["http", "https"] and is_binary(host) <- URI.new(value),
         true <- bare?(uri),
         host = String.downcase(host, :ascii),
         true <- uri.path in [nil, "", "/"] and Regex.match?(@host, host) do
      {:ok, origin(scheme, host, port), host}
    else
      _ -> :error
    end
  end

  defp parse_home(_value), do: :error

  defp origin(scheme, host, port) do
    if port == Map.get(@default_ports, scheme),
      do: scheme <> "://" <> host,
      else: scheme <> "://" <> host <> ":" <> to_string(port)
  end

  @doc "The JCS bytes of a map of this protocol's own making; anything outside JCS's domain raises."
  @spec jcs!(map()) :: binary()
  def jcs!(map) do
    case JCS.encode(map) do
      {:ok, bytes} ->
        bytes

      {:error, reason} ->
        raise ArgumentError, "not canonical JSON: #{Prima.LoggerContext.shape(reason)}"
    end
  end

  @doc """
  The JCS bytes of an untrusted map, or the field that is outside JCS's
  domain (a float, a null, a key that is not a string).
  """
  @spec jcs(term()) :: {:ok, binary()} | {:error, reason()}
  def jcs(map) when is_map(map) and not is_struct(map) do
    case JCS.encode(map) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, {:invalid_value, [field | _path], _why}} -> {:error, {:invalid_field, field}}
      {:error, {:invalid_value, [], _why}} -> {:error, {:invalid_field, ""}}
    end
  end

  def jcs(_value), do: {:error, {:invalid_field, ""}}

  @doc "`map` with `sig`: the Ed25519 signature under `private_key` over the JCS bytes of `map` without `sig`."
  @spec sign(map(), binary()) :: map()
  def sign(map, private_key) when is_map(map) and is_binary(private_key) do
    message = map |> Map.delete("sig") |> jcs!()
    Map.put(map, "sig", b64(:crypto.sign(:eddsa, :none, message, [private_key, :ed25519])))
  end

  @doc "Whether `map`'s `sig` is `public_key`'s signature over the JCS bytes of `map` without `sig`."
  @spec verify(map(), binary()) :: boolean()
  def verify(map, public_key) when is_map(map) do
    with true <- key?(public_key),
         {:ok, signature} <- unb64(Map.get(map, "sig"), @signature_bytes),
         {:ok, message} <- JCS.encode(Map.delete(map, "sig")) do
      :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
    else
      _ -> false
    end
  end

  @doc "Decode a signature field."
  @spec signature(term()) :: {:ok, binary()} | :error
  def signature(value), do: unb64(value, @signature_bytes)

  @doc """
  Hold `map` to exactly `required` and `optional` fields: an unknown field
  first, in sorted order, then a missing one, in `required`'s order.
  """
  @spec fields(map(), [String.t()], [String.t()]) :: :ok | {:error, reason()}
  def fields(map, required, optional) do
    allowed = required ++ optional
    keys = map |> Map.keys() |> Enum.sort()

    # The unknown key is found by its index, never by its value: a nil key
    # is unknown, not read as "no unknown key". `required` holds strings,
    # so its search can answer the missing field itself.
    case Enum.find_index(keys, &(&1 not in allowed)) do
      nil ->
        case Enum.find(required, &(not Map.has_key?(map, &1))) do
          nil -> :ok
          field -> missing(field)
        end

      index ->
        unknown(Enum.at(keys, index))
    end
  end

  defp missing(field), do: {:error, {:missing_field, field}}
  defp unknown(field) when is_binary(field), do: {:error, {:unknown_field, field}}
  defp unknown(field), do: {:error, {:unknown_field, inspect(field)}}

  @doc "Check the `protocol` field against `protocol`."
  @spec protocol(map(), String.t()) :: :ok | {:error, :wrong_protocol | reason()}
  def protocol(map, protocol) do
    case Map.fetch(map, "protocol") do
      {:ok, ^protocol} -> :ok
      {:ok, _other} -> {:error, :wrong_protocol}
      :error -> {:error, {:missing_field, "protocol"}}
    end
  end

  @doc "Fetch `field` and hold it to `valid?`, or answer it invalid."
  @spec check(map(), String.t(), (term() -> boolean())) :: {:ok, term()} | {:error, reason()}
  def check(map, field, valid?) do
    value = Map.get(map, field)
    if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, field}}
  end

  @doc "Fetch an optional `field`: nil when absent, else held to `valid?`."
  @spec optional(map(), String.t(), (term() -> boolean())) :: {:ok, term()} | {:error, reason()}
  def optional(map, field, valid?) do
    if Map.has_key?(map, field), do: check(map, field, valid?), else: {:ok, nil}
  end

  @doc "Fetch a base64url field of `size` bytes."
  @spec binary(map(), String.t(), pos_integer()) :: {:ok, binary()} | {:error, reason()}
  def binary(map, field, size) do
    case unb64(Map.get(map, field), size) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:invalid_field, field}}
    end
  end

  @doc "Fetch a list of distinct public keys, non-empty."
  @spec keys(map(), String.t()) :: {:ok, [binary()]} | {:error, reason()}
  def keys(map, field) do
    with [_ | _] = values <- Map.get(map, field),
         decoded = Enum.map(values, &unb64(&1, @key_bytes)),
         false <- Enum.member?(decoded, :error),
         keys = Enum.map(decoded, fn {:ok, key} -> key end),
         true <- length(Enum.uniq(keys)) == length(keys) do
      {:ok, keys}
    else
      _ -> {:error, {:invalid_field, field}}
    end
  end

  @doc "The JSON spelling of a list of keys."
  @spec b64_keys([binary()]) :: [String.t()]
  def b64_keys(keys), do: Enum.map(keys, &b64/1)

  @doc "Drop the fields whose value is nil, so an absent field stays absent in JCS."
  @spec compact(map()) :: map()
  def compact(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end
