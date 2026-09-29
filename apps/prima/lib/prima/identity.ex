# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Identity.Encoding do
  @moduledoc """
  The encodings every shape of the identity, device-certificate, device,
  person-assertion, confirmation and sign-in carry protocols shares, so a
  value has one spelling on every side.

    * **Identifier.** `per_` and the 64 lowercase hexadecimal digits of
      SHA-256 over the genesis entry's JCS bytes (`Prima.Identity.identifier/1`),
      the same form as a person's local `usr_` id.
    * **Every other hash** is `Prima.Digest.sha256/1`'s `sha256:<hex>`: entry
      hashes and `prev`, `key_epoch`, request, payload and registration
      digests, and the confirmation digest.
    * **Binary values** in JSON (public keys, signatures, nonces, a seed) are
      unpadded base64url. Decoding refuses padding, a wrong length and any
      spelling that does not re-encode to itself.
    * **Signatures.** Each signed shape carries its protocol string as a
      field inside what it signs. An Ed25519 signature, the field `sig`,
      covers the JCS bytes (`Prima.JCS`) of the shape's map without its `sig`.
    * **Timestamps** are integer Unix milliseconds, within JCS's integer
      domain.
    * **A home** is named by its origin: `http` or `https`, a lowercase host
      name, and a port only when it is not the scheme's default, with no
      path, user, query or fragment. Only that spelling is accepted, so two
      homes are one exactly when their spellings are equal.
    * **An id** (a client, athanor, carry action, confirmation, request or
      intent id) is 1 to 128 characters of `[A-Za-z0-9_-]`, starting with a
      letter or digit.

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
  def home?(value), do: match?({:ok, _host}, parse_home(value))

  @doc "A home's host name. The home must be a valid spelling."
  @spec home_host(String.t()) :: String.t()
  def home_host(home) do
    {:ok, host} = parse_home(home)
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

  defp bare?(uri), do: is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)

  defp parse_home(value) when is_binary(value) and byte_size(value) <= 300 do
    with {:ok, %URI{scheme: scheme, host: host, port: port} = uri}
         when scheme in ["http", "https"] and is_binary(host) <- URI.new(value),
         true <- bare?(uri),
         true <- uri.path in [nil, ""] and Regex.match?(@host, host),
         ^value <- origin(scheme, host, port) do
      {:ok, host}
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

    with nil <- map |> Map.keys() |> Enum.sort() |> Enum.find(&(&1 not in allowed)),
         nil <- Enum.find(required, &(not Map.has_key?(map, &1))) do
      :ok
    else
      field -> if field in required, do: missing(field), else: unknown(field)
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

defmodule Prima.Identity.RecoverRequest do
  @moduledoc """
  What a recovering person submits: the protocol, the identifier it
  recovers, the directory that orders that identifier, the new live and
  operational public keys, optionally a new recovery set (absent keeps the
  current one), the recovery policy revision it expects, and a request id,
  signed by one recovery key over exactly those fields.

  A request signed for one identifier is refused for every other, so one
  recovery key enrolled under two identifiers authorizes each only by name.
  It names its directory so a recovery can never move an identifier: a
  request naming another directory than the chain's is refused. Its digest
  (`Prima.Identity.request_digest/1`) is over the whole signed request; a
  request id is scoped to its identifier and that digest.
  """

  alias Prima.Identity
  alias Prima.Identity.Encoding

  @required ~w(protocol identifier directory live_key operational_key expected_revision request_id)
  @optional ~w(recovery_keys)

  @type t :: %__MODULE__{
          identifier: String.t(),
          directory: String.t(),
          live_key: binary(),
          operational_key: binary(),
          recovery_keys: [binary()] | nil,
          expected_revision: non_neg_integer(),
          request_id: String.t(),
          sig: binary() | nil
        }

  @enforce_keys [:identifier, :directory, :live_key, :operational_key, :expected_revision]
  defstruct [
    :identifier,
    :directory,
    :live_key,
    :operational_key,
    :expected_revision,
    :request_id,
    recovery_keys: nil,
    sig: nil
  ]

  @doc """
  An unsigned request from its fields (atom keys, keys as raw bytes). Sign
  it with `Prima.Identity.sign/2` under a recovery private key.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Encoding.reason()}
  def new(attrs) do
    attrs = Map.new(attrs)

    %{
      "protocol" => Identity.protocol(),
      "identifier" => attrs[:identifier],
      "directory" => attrs[:directory],
      "live_key" => b64_or_nil(attrs[:live_key]),
      "operational_key" => b64_or_nil(attrs[:operational_key]),
      "recovery_keys" => attrs[:recovery_keys] && Encoding.b64_keys(attrs[:recovery_keys]),
      "expected_revision" => attrs[:expected_revision],
      "request_id" => attrs[:request_id]
    }
    |> Encoding.compact()
    |> read(false)
  end

  @doc "Read a signed request from its JSON map."
  @spec decode(term()) :: {:ok, t()} | {:error, Encoding.reason() | :wrong_protocol}
  def decode(map), do: read(map, true)

  @doc "The JSON map of a request; `sig` is absent while unsigned."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = request) do
    Encoding.compact(%{
      "protocol" => Identity.protocol(),
      "identifier" => request.identifier,
      "directory" => request.directory,
      "live_key" => Encoding.b64(request.live_key),
      "operational_key" => Encoding.b64(request.operational_key),
      "recovery_keys" => request.recovery_keys && Encoding.b64_keys(request.recovery_keys),
      "expected_revision" => request.expected_revision,
      "request_id" => request.request_id,
      "sig" => request.sig && Encoding.b64(request.sig)
    })
  end

  @doc """
  The recovery key among `recovery_keys` whose signature the request
  carries, or `:wrong_signer` when none verifies it.
  """
  @spec signer(t(), [binary()]) :: {:ok, binary()} | {:error, :wrong_signer}
  def signer(%__MODULE__{} = request, recovery_keys) do
    map = encode(request)

    case Enum.find(recovery_keys, &Encoding.verify(map, &1)) do
      nil -> {:error, :wrong_signer}
      key -> {:ok, key}
    end
  end

  defp read(map, signed?) when is_map(map) and not is_struct(map) do
    sig = if signed?, do: ["sig"], else: []

    with :ok <- Encoding.protocol(map, Identity.protocol()),
         :ok <- Encoding.fields(map, @required ++ sig, @optional),
         {:ok, identifier} <- Encoding.check(map, "identifier", &Encoding.identifier?/1),
         {:ok, directory} <- Encoding.check(map, "directory", &Encoding.directory_url?/1),
         {:ok, live} <- Encoding.binary(map, "live_key", Encoding.key_bytes()),
         {:ok, operational} <- Encoding.binary(map, "operational_key", Encoding.key_bytes()),
         {:ok, recovery} <- recovery_keys(map),
         {:ok, revision} <- Encoding.check(map, "expected_revision", &Encoding.ms?/1),
         {:ok, request_id} <- Encoding.check(map, "request_id", &Encoding.id?/1),
         {:ok, signature} <- signature(map, signed?) do
      {:ok,
       %__MODULE__{
         identifier: identifier,
         directory: directory,
         live_key: live,
         operational_key: operational,
         recovery_keys: recovery,
         expected_revision: revision,
         request_id: request_id,
         sig: signature
       }}
    end
  end

  defp read(_value, _signed?), do: {:error, {:invalid_field, "request"}}

  defp recovery_keys(map) do
    if Map.has_key?(map, "recovery_keys"),
      do: Encoding.keys(map, "recovery_keys"),
      else: {:ok, nil}
  end

  defp signature(_map, false), do: {:ok, nil}

  defp signature(map, true) do
    case Encoding.signature(map["sig"]) do
      {:ok, sig} -> {:ok, sig}
      :error -> {:error, {:invalid_field, "sig"}}
    end
  end

  defp b64_or_nil(nil), do: nil
  defp b64_or_nil(bytes), do: Encoding.b64(bytes)
end

defmodule Prima.Identity.Entry do
  @moduledoc """
  One entry of an identity log. `kind` is `:genesis`, `:rotate` or
  `:recover`, and no other kind exists; the fields a kind does not carry
  are nil.

    * `:genesis` — `live_key`, `operational_key`, `recovery_keys`,
      `directory`, `revision` (always 0) and `sig`, by its own operational
      key.
    * `:rotate` — `prev` and the new `live_key`, and `sig`, by the current
      operational key.
    * `:recover` — `prev` and the `request` embedded verbatim. The entry
      carries no signature of its own: the request's is the only one.

  Every entry carries the protocol string `cyfr-identity/v1`, and its JCS
  form is at most `Prima.Identity.max_entry_bytes/0`.
  """

  alias Prima.Identity
  alias Prima.Identity.{Encoding, RecoverRequest}

  @type kind :: :genesis | :rotate | :recover
  @type t :: %__MODULE__{
          kind: kind(),
          prev: String.t() | nil,
          live_key: binary() | nil,
          operational_key: binary() | nil,
          recovery_keys: [binary()] | nil,
          directory: String.t() | nil,
          revision: 0 | nil,
          request: RecoverRequest.t() | nil,
          sig: binary() | nil
        }

  @enforce_keys [:kind]
  defstruct [
    :kind,
    :prev,
    :live_key,
    :operational_key,
    :recovery_keys,
    :directory,
    :revision,
    :request,
    :sig
  ]

  @kinds %{"genesis" => :genesis, "rotate" => :rotate, "recover" => :recover}

  @fields %{
    genesis: ~w(protocol kind live_key operational_key recovery_keys directory revision),
    rotate: ~w(protocol kind prev live_key),
    recover: ~w(protocol kind prev request)
  }

  @doc "An unsigned genesis from its keys (raw bytes) and directory URL; sign it with its operational key."
  @spec genesis(map() | keyword()) :: {:ok, t()} | {:error, Encoding.reason()}
  def genesis(attrs) do
    attrs = Map.new(attrs)

    %{
      "protocol" => Identity.protocol(),
      "kind" => "genesis",
      "live_key" => attrs[:live_key] && Encoding.b64(attrs[:live_key]),
      "operational_key" => attrs[:operational_key] && Encoding.b64(attrs[:operational_key]),
      "recovery_keys" => attrs[:recovery_keys] && Encoding.b64_keys(attrs[:recovery_keys]),
      "directory" => attrs[:directory],
      "revision" => 0
    }
    |> Encoding.compact()
    |> read(false)
  end

  @doc "An unsigned rotation to `live_key` after the entry hashing to `prev`; sign it with the operational key."
  @spec rotate(String.t(), binary()) :: {:ok, t()} | {:error, Encoding.reason()}
  def rotate(prev, live_key) do
    read(
      %{
        "protocol" => Identity.protocol(),
        "kind" => "rotate",
        "prev" => prev,
        "live_key" => Encoding.b64(live_key)
      },
      false
    )
  end

  @doc "The recovery entry a directory commits: the signed `request` after the entry hashing to `prev`."
  @spec recover(String.t(), RecoverRequest.t()) :: {:ok, t()} | {:error, Encoding.reason()}
  def recover(prev, %RecoverRequest{} = request) do
    read(
      %{
        "protocol" => Identity.protocol(),
        "kind" => "recover",
        "prev" => prev,
        "request" => RecoverRequest.encode(request)
      },
      true
    )
  end

  @doc "Read a signed entry from its JSON map."
  @spec decode(term()) ::
          {:ok, t()}
          | {:error, Encoding.reason() | :wrong_protocol | :too_large | {:unknown_kind, term()}}
  def decode(map), do: read(map, true)

  @doc "The JSON map of an entry; `sig` is absent while unsigned."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{kind: :genesis} = entry) do
    Encoding.compact(%{
      "protocol" => Identity.protocol(),
      "kind" => "genesis",
      "live_key" => Encoding.b64(entry.live_key),
      "operational_key" => Encoding.b64(entry.operational_key),
      "recovery_keys" => Encoding.b64_keys(entry.recovery_keys),
      "directory" => entry.directory,
      "revision" => 0,
      "sig" => entry.sig && Encoding.b64(entry.sig)
    })
  end

  def encode(%__MODULE__{kind: :rotate} = entry) do
    Encoding.compact(%{
      "protocol" => Identity.protocol(),
      "kind" => "rotate",
      "prev" => entry.prev,
      "live_key" => Encoding.b64(entry.live_key),
      "sig" => entry.sig && Encoding.b64(entry.sig)
    })
  end

  def encode(%__MODULE__{kind: :recover} = entry) do
    %{
      "protocol" => Identity.protocol(),
      "kind" => "recover",
      "prev" => entry.prev,
      "request" => RecoverRequest.encode(entry.request)
    }
  end

  defp read(map, signed?) when is_map(map) and not is_struct(map) do
    with {:ok, bytes} <- Encoding.jcs(map),
         :ok <- size(bytes),
         :ok <- Encoding.protocol(map, Identity.protocol()),
         {:ok, kind} <- kind(map),
         :ok <- Encoding.fields(map, fields(kind, signed?), []) do
      read(kind, map, signed?)
    end
  end

  defp read(_value, _signed?), do: {:error, {:invalid_field, "entry"}}

  defp read(:genesis, map, signed?) do
    with {:ok, live} <- Encoding.binary(map, "live_key", Encoding.key_bytes()),
         {:ok, operational} <- Encoding.binary(map, "operational_key", Encoding.key_bytes()),
         {:ok, recovery} <- Encoding.keys(map, "recovery_keys"),
         {:ok, directory} <- Encoding.check(map, "directory", &Encoding.directory_url?/1),
         {:ok, 0} <- Encoding.check(map, "revision", &(&1 === 0)),
         {:ok, sig} <- signature(map, signed?) do
      {:ok,
       %__MODULE__{
         kind: :genesis,
         live_key: live,
         operational_key: operational,
         recovery_keys: recovery,
         directory: directory,
         revision: 0,
         sig: sig
       }}
    end
  end

  defp read(:rotate, map, signed?) do
    with {:ok, prev} <- Encoding.check(map, "prev", &Encoding.digest?/1),
         {:ok, live} <- Encoding.binary(map, "live_key", Encoding.key_bytes()),
         {:ok, sig} <- signature(map, signed?) do
      {:ok, %__MODULE__{kind: :rotate, prev: prev, live_key: live, sig: sig}}
    end
  end

  defp read(:recover, map, _signed?) do
    with {:ok, prev} <- Encoding.check(map, "prev", &Encoding.digest?/1),
         {:ok, request} <- RecoverRequest.decode(map["request"]) do
      {:ok, %__MODULE__{kind: :recover, prev: prev, request: request}}
    end
  end

  defp size(bytes) do
    if byte_size(bytes) > Identity.max_entry_bytes(), do: {:error, :too_large}, else: :ok
  end

  defp kind(map) do
    case Map.fetch(map, "kind") do
      {:ok, name} when is_map_key(@kinds, name) -> {:ok, Map.fetch!(@kinds, name)}
      {:ok, name} -> {:error, {:unknown_kind, name}}
      :error -> {:error, {:missing_field, "kind"}}
    end
  end

  # A recover entry carries no signature of its own, signed or not.
  defp fields(:recover, _signed?), do: @fields.recover
  defp fields(kind, true), do: Map.fetch!(@fields, kind) ++ ["sig"]
  defp fields(kind, false), do: Map.fetch!(@fields, kind)

  defp signature(_map, false), do: {:ok, nil}

  defp signature(map, true) do
    case Encoding.signature(map["sig"]) do
      {:ok, sig} -> {:ok, sig}
      :error -> {:error, {:invalid_field, "sig"}}
    end
  end
end

defmodule Prima.Identity.State do
  @moduledoc """
  What a verified identity log answers (`Prima.Identity.verify_chain/1`):
  the identifier; the directory that orders it; `head`, the hash of the
  last entry; `key_epoch`, the hash of the genesis, rotate or recover
  entry that introduced the current live key; the current live,
  operational and recovery public keys; the recovery policy revision; the
  number of entries; and the request ids the log's recoveries carried.
  """

  alias Prima.Identity.Encoding

  @type t :: %__MODULE__{
          identifier: String.t(),
          directory: String.t(),
          head: String.t(),
          key_epoch: String.t(),
          live_key: binary(),
          operational_key: binary(),
          recovery_keys: [binary()],
          revision: non_neg_integer(),
          length: pos_integer(),
          request_ids: [String.t()]
        }

  @enforce_keys [
    :identifier,
    :directory,
    :head,
    :key_epoch,
    :live_key,
    :operational_key,
    :recovery_keys,
    :revision,
    :length
  ]
  defstruct [
    :identifier,
    :directory,
    :head,
    :key_epoch,
    :live_key,
    :operational_key,
    :recovery_keys,
    :revision,
    :length,
    request_ids: []
  ]

  @doc "The JSON map of a state, keys in base64url."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = state) do
    %{
      "identifier" => state.identifier,
      "directory" => state.directory,
      "head" => state.head,
      "key_epoch" => state.key_epoch,
      "live_key" => Encoding.b64(state.live_key),
      "operational_key" => Encoding.b64(state.operational_key),
      "recovery_keys" => Encoding.b64_keys(state.recovery_keys),
      "revision" => state.revision,
      "length" => state.length,
      "request_ids" => state.request_ids
    }
  end
end

defmodule Prima.Identity do
  @moduledoc """
  A person's identity: the log that names their keys, the identifier it
  hashes to, and the one check that walks it. `tests/fixtures/identity.json`
  holds the vectors every side reproduces; the shared encodings are
  `Prima.Identity.Encoding`'s.

  ## The log

  An append-only sequence of `Prima.Identity.Entry`, each naming the hash
  of the entry before it (`prev`) and signed by a key that entry
  authorized. Three kinds exist and no other (`kinds/0`); any other kind,
  an `address` among them, is refused.

    * **genesis** names the initial live, operational and recovery public
      keys, the directory URL and recovery policy revision 0, and is
      signed by its own operational key. Its hash is the identifier.
    * **rotate** names a new live key and is signed by the operational key.
    * **recover** embeds a `Prima.Identity.RecoverRequest` verbatim beside
      `prev`. The request is signed by a recovery key the chain authorized
      at the preceding entry, names the identifier and the directory, and
      expects the chain's revision there; the entry replaces the live and
      operational keys, optionally the recovery set, and raises the
      revision by one. It never changes the directory.

  The live, operational and recovery keys are always distinct: the online
  keys can never stand in for a recovery key.

  `prev` records the directory's ordering, which is trusted for ordering
  alone. The identifier, `key_epoch` and every signature are checked from
  the genesis, so a fresh backend verifies the whole chain from the
  genesis alone.

  ## Recovery keys

  A kit seed is 32 bytes and is the Ed25519 private key of one recovery
  holder (RFC 8032): `derive_recovery_key/1` answers its key pair. No
  encryption key is derived from it.

  ## Locating a remote person

  `locate/2` holds a genesis a relying home was handed to the identifier it
  claims: at most `max_entry_bytes/0` before it is read, a genesis by
  shape, hashing to that identifier and signed by its own operational key.
  Its directory is the only locator for that identifier. The genesis
  proves neither membership nor a fresh head.
  """

  alias Prima.Identity.{Encoding, Entry, RecoverRequest, State}

  @protocol "cyfr-identity/v1"
  @prefix "per"
  @max_entry_bytes 16_384
  @seed_bytes 32

  @type reason ::
          Encoding.reason()
          | :wrong_protocol
          | :too_large
          | {:unknown_kind, term()}
          | :not_genesis
          | :unexpected_genesis
          | :broken_link
          | :wrong_signer
          | :wrong_identifier
          | :directory_changed
          | :stale_revision
          | :request_id_reused
          | :key_overlap

  @doc "The protocol string every entry and recover request carries."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc "The identifier's prefix."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "The largest entry, or transported genesis, in bytes."
  @spec max_entry_bytes() :: pos_integer()
  def max_entry_bytes, do: @max_entry_bytes

  @doc "The three entry kinds, exhaustively."
  @spec kinds() :: [Entry.kind()]
  def kinds, do: [:genesis, :rotate, :recover]

  @doc "The JCS bytes of an entry or a recover request, `sig` included."
  @spec canonical(Entry.t() | RecoverRequest.t()) :: binary()
  def canonical(%Entry{} = entry), do: entry |> Entry.encode() |> Encoding.jcs!()

  def canonical(%RecoverRequest{} = request),
    do: request |> RecoverRequest.encode() |> Encoding.jcs!()

  @doc """
  Sign a genesis or rotate entry, or a recover request, with an Ed25519
  private key: its `sig` covers the JCS bytes of its map without `sig`.
  """
  @spec sign(Entry.t(), binary()) :: Entry.t()
  @spec sign(RecoverRequest.t(), binary()) :: RecoverRequest.t()
  def sign(%Entry{kind: kind} = entry, private_key) when kind in [:genesis, :rotate] do
    %{entry | sig: signature(Entry.encode(%{entry | sig: nil}), private_key)}
  end

  def sign(%RecoverRequest{} = request, private_key) do
    %{request | sig: signature(RecoverRequest.encode(%{request | sig: nil}), private_key)}
  end

  @doc "Whether a signed genesis or rotate entry, or a recover request, carries `public_key`'s signature."
  @spec verify(Entry.t() | RecoverRequest.t(), binary()) :: :ok | {:error, :wrong_signer}
  def verify(%Entry{kind: kind} = entry, public_key) when kind in [:genesis, :rotate],
    do: verified(Encoding.verify(Entry.encode(entry), public_key))

  def verify(%RecoverRequest{} = request, public_key),
    do: verified(Encoding.verify(RecoverRequest.encode(request), public_key))

  @doc """
  The identifier a genesis hashes to: `per_` and the lowercase hex of
  SHA-256 over its JCS bytes. A map is read as an entry first; anything
  that is not a genesis raises, and an untrusted genesis goes through
  `locate/2`.
  """
  @spec identifier(Entry.t() | map()) :: String.t()
  def identifier(%Entry{kind: :genesis} = genesis),
    do: @prefix <> "_" <> Prima.Digest.sha256_hex(canonical(genesis))

  def identifier(map) when is_map(map) and not is_struct(map) do
    case Entry.decode(map) do
      {:ok, %Entry{kind: :genesis} = genesis} -> identifier(genesis)
      _other -> raise ArgumentError, "not a genesis entry"
    end
  end

  @doc "An entry's hash, `sha256:<hex>` over its JCS bytes: what the next entry's `prev` names."
  @spec hash(Entry.t()) :: String.t()
  def hash(%Entry{} = entry), do: Prima.Digest.sha256(canonical(entry))

  @doc "A recover request's digest, over the whole signed request."
  @spec request_digest(RecoverRequest.t() | map()) :: String.t()
  def request_digest(%RecoverRequest{} = request), do: Prima.Digest.sha256(canonical(request))

  def request_digest(map) when is_map(map) do
    case RecoverRequest.decode(map) do
      {:ok, request} -> request_digest(request)
      {:error, _reason} -> raise ArgumentError, "not a signed recover request"
    end
  end

  @doc "The recovery key pair, `{public, private}`, a 32-byte kit seed derives (RFC 8032)."
  @spec derive_recovery_key(binary()) :: {:ok, {binary(), binary()}} | {:error, :invalid_seed}
  def derive_recovery_key(seed) when is_binary(seed) and byte_size(seed) == @seed_bytes,
    do: {:ok, :crypto.generate_key(:eddsa, :ed25519, seed)}

  def derive_recovery_key(_seed), do: {:error, :invalid_seed}

  @doc """
  Hold a genesis a relying home was handed to the identifier it claims,
  before any network use: a binary is read only at most
  `max_entry_bytes/0`; the genesis must be one by shape, hash to
  `identifier` and carry its own operational key's signature. Answers the
  genesis, whose `directory` is the identifier's one locator.
  """
  @spec locate(binary() | map(), String.t()) ::
          {:ok, Entry.t()}
          | {:error, :too_large | :invalid_json | :not_genesis | :identifier_mismatch | reason()}
  def locate(genesis, identifier) when is_binary(genesis) do
    if byte_size(genesis) > @max_entry_bytes,
      do: {:error, :too_large},
      else: locate_json(Prima.Json.decode(genesis), identifier)
  end

  def locate(genesis, identifier) when is_map(genesis) and not is_struct(genesis) do
    with {:ok, %Entry{kind: :genesis} = entry} <- genesis_entry(genesis),
         :ok <- same_identifier(entry, identifier),
         :ok <- verify(entry, entry.operational_key) do
      {:ok, entry}
    end
  end

  def locate(_genesis, _identifier), do: {:error, :invalid_json}

  defp locate_json({:ok, %{} = map}, identifier), do: locate(map, identifier)
  defp locate_json(_other, _identifier), do: {:error, :invalid_json}

  defp genesis_entry(map) do
    case Entry.decode(map) do
      {:ok, %Entry{kind: :genesis} = entry} -> {:ok, entry}
      {:ok, %Entry{}} -> {:error, :not_genesis}
      {:error, reason} -> {:error, reason}
    end
  end

  defp same_identifier(entry, identifier) do
    if identifier(entry) == identifier, do: :ok, else: {:error, :identifier_mismatch}
  end

  @doc """
  Walk a log from its genesis and answer the current state, or the index
  of the first entry refused and why: a first entry that is not a genesis,
  a later genesis, a broken link, a wrong signer for its kind (a genesis
  its operational key does not verify, a rotate the operational key did not
  sign, a recover whose request no authorized recovery key signed), a
  recover for another identifier, naming another directory, expecting a
  revision that is not the chain's there or reusing a request id, keys that
  are not distinct, an unknown kind or a malformed entry.
  """
  @spec verify_chain([Entry.t() | map()]) ::
          {:ok, State.t()} | {:error, {non_neg_integer(), reason() | :empty}}
  def verify_chain([]), do: {:error, {0, :empty}}

  def verify_chain([first | rest]) do
    with {:ok, state} <- at(0, begin(first)) do
      rest
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, state}, &step/2)
    end
  end

  def verify_chain(_entries), do: {:error, {0, {:invalid_field, "entries"}}}

  defp step({entry, index}, {:ok, state}) do
    case at(index, extend(state, entry)) do
      {:ok, state} -> {:cont, {:ok, state}}
      error -> {:halt, error}
    end
  end

  defp at(_index, {:ok, _state} = ok), do: ok
  defp at(index, {:error, reason}), do: {:error, {index, reason}}

  @doc """
  Apply one more entry to a verified state: the check a directory makes
  before it appends, and the step `verify_chain/1` repeats.
  """
  @spec extend(State.t(), Entry.t() | map()) :: {:ok, State.t()} | {:error, reason()}
  def extend(%State{} = state, entry) do
    with {:ok, entry} <- read(entry),
         :ok <- later(entry),
         :ok <- link(entry, state) do
      apply_entry(entry, state)
    end
  end

  defp begin(entry) do
    with {:ok, entry} <- read(entry),
         :ok <- first(entry),
         :ok <- distinct(entry.live_key, entry.operational_key, entry.recovery_keys),
         :ok <- verify(entry, entry.operational_key) do
      hash = hash(entry)

      {:ok,
       %State{
         identifier: identifier(entry),
         directory: entry.directory,
         head: hash,
         key_epoch: hash,
         live_key: entry.live_key,
         operational_key: entry.operational_key,
         recovery_keys: entry.recovery_keys,
         revision: 0,
         length: 1
       }}
    end
  end

  # A struct is re-read from its map, so a hand-built one is held to the
  # same shape as a decoded one.
  defp read(%Entry{} = entry), do: entry |> Entry.encode() |> Entry.decode()
  defp read(map), do: Entry.decode(map)

  defp first(%Entry{kind: :genesis}), do: :ok
  defp first(%Entry{}), do: {:error, :not_genesis}

  defp later(%Entry{kind: :genesis}), do: {:error, :unexpected_genesis}
  defp later(%Entry{}), do: :ok

  defp link(%Entry{prev: prev}, %State{head: prev}), do: :ok
  defp link(%Entry{}, %State{}), do: {:error, :broken_link}

  defp apply_entry(%Entry{kind: :rotate} = entry, state) do
    with :ok <- verify(entry, state.operational_key),
         :ok <- distinct(entry.live_key, state.operational_key, state.recovery_keys) do
      hash = hash(entry)

      {:ok,
       %{state | live_key: entry.live_key, head: hash, key_epoch: hash, length: state.length + 1}}
    end
  end

  defp apply_entry(%Entry{kind: :recover, request: request} = entry, state) do
    recovery = request.recovery_keys || state.recovery_keys

    with :ok <- match(request.identifier, state.identifier, :wrong_identifier),
         :ok <- match(request.directory, state.directory, :directory_changed),
         :ok <- match(request.expected_revision, state.revision, :stale_revision),
         {:ok, _signer} <- RecoverRequest.signer(request, state.recovery_keys),
         :ok <- fresh_request(request.request_id, state),
         :ok <- distinct(request.live_key, request.operational_key, recovery) do
      hash = hash(entry)

      {:ok,
       %{
         state
         | live_key: request.live_key,
           operational_key: request.operational_key,
           recovery_keys: recovery,
           revision: state.revision + 1,
           head: hash,
           key_epoch: hash,
           length: state.length + 1,
           request_ids: state.request_ids ++ [request.request_id]
       }}
    end
  end

  defp match(value, value, _reason), do: :ok
  defp match(_value, _expected, reason), do: {:error, reason}

  defp fresh_request(request_id, state) do
    if request_id in state.request_ids, do: {:error, :request_id_reused}, else: :ok
  end

  defp distinct(live, operational, recovery) do
    if live != operational and live not in recovery and operational not in recovery,
      do: :ok,
      else: {:error, :key_overlap}
  end

  defp signature(map, private_key),
    do: map |> Encoding.sign(private_key) |> Map.fetch!("sig") |> decode_sig()

  defp decode_sig(sig) do
    {:ok, bytes} = Encoding.signature(sig)
    bytes
  end

  defp verified(true), do: :ok
  defp verified(false), do: {:error, :wrong_signer}
end
