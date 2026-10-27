# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.RegistryRequest do
  @moduledoc """
  The one signed request that carries every registry operation a person
  makes, `cyfr-registry-request/v1`. `tests/fixtures/registry_wire.json`
  holds its vectors, which the registry's verifier reads too.

  A request is a JSON object of at most 16 KiB with exactly the keys
  `protocol`, `registry` (the registry's lowercase host), `operation`,
  `identifier`, `key_epoch` (of the head the signing live key belongs
  to), `nonce` (16 bytes), `expires_at` (Unix milliseconds), `body` and
  `sig`, the live key's signature over the JCS bytes of every key but
  `sig`, in the encodings of `Prima.Identity.Encoding`.

  Each operation's body holds exactly its keys:

    * `handle.claim` — `handle`, a personal slug
      (`Prima.ComponentRef.valid_personal_slug?/1`).
    * `tokens.mint` — `label`, the device label: 1 to 64 printable ASCII
      characters.
    * `address.set` — `address`, a home's origin
      (`Prima.Identity.Encoding.home?/1`) to publish; a body without it
      withdraws the published address. JCS has no null (`Prima.JCS`), so
      absence is the one spelling of "none", and a null is refused.
    * `policy.accept` — `policy_version`, the version the registry
      publishes: text of at most 128 bytes.
    * `appeal.file` — `action_type` (`takedown` or `ban`), `action_ref`
      (text of at most 256 bytes) and `argument` (1 to 4000 bytes of UTF-8,
      not only spaces, tabs and line breaks).
    * `publisher.claim` — `slug`, a publisher namespace: one
      `Prima.ComponentRef.validate_namespace/1` accepts that holds a dot.
    * `publisher.verify` — `slug`, as `publisher.claim`'s, and `label`, as
      `tokens.mint`'s, for the founding member's token.

  The signer sets `expires_at` `lifetime_ms/0` ahead of its clock.
  `verify/4` checks a request in this order, and the first failure
  answers:

    1. size, JSON, exact keys and their types: `:request_malformed`;
    2. `protocol`: `:wrong_protocol`;
    3. `registry` against the registry's own host: `:wrong_registry`;
    4. a known operation (`:unknown_operation`) with exactly its body's
       keys and valid values (`:request_malformed`);
    5. `expires_at`: `:expired` at or before the clock, `:expiry_too_far`
       more than `max_ahead_ms/0` after it;
    6. the head the registry read for the request's identifier: a head of
       another identifier is no log of this one, `:unknown_identity`;
    7. the head's directory against the registry's: `:wrong_directory`;
    8. `key_epoch` against the head's: `:stale_key_epoch`;
    9. the signature under the head's live key: `:bad_signature`.

  The refusals after these (a replayed nonce, a ban and the operations'
  own rules) need the registry's database and are the registry's alone.

  ## Refusals on the wire

  The registry answers a refusal in its error envelope,
  `{"errors": [{"code": ..., "message": ...}]}`, beside any further
  top-level field a refusal carries (`required_version` with
  `POLICY_ACCEPTANCE_REQUIRED`). `refusals/0` is the one table of every
  refusal of this protocol and of the handle answer: CYFR's name for it,
  the registry's code and the HTTP status. `refusal/1` reads an envelope
  back to CYFR's name.
  """

  alias Prima.ComponentRef
  alias Prima.Identity.{Encoding, State}

  @protocol "cyfr-registry-request/v1"
  @max_bytes 16_384
  @nonce_bytes 16
  @lifetime_ms 120_000
  @max_ahead_ms 360_000
  @envelope ~w(protocol registry operation identifier key_epoch nonce expires_at body)

  # Each operation's body: its required keys and its optional keys. `valid?/2`
  # checks each value by its key.
  @bodies %{
    "handle.claim" => {~w(handle), []},
    "tokens.mint" => {~w(label), []},
    "address.set" => {[], ~w(address)},
    "policy.accept" => {~w(policy_version), []},
    "appeal.file" => {~w(action_type action_ref argument), []},
    "publisher.claim" => {~w(slug), []},
    "publisher.verify" => {~w(slug label), []}
  }

  # Every refusal: CYFR's name, the registry's code and the HTTP status.
  @refusals [
    request_malformed: {"REQUEST_MALFORMED", 400},
    wrong_protocol: {"WRONG_PROTOCOL", 400},
    wrong_registry: {"WRONG_REGISTRY", 400},
    unknown_operation: {"UNKNOWN_OPERATION", 400},
    expired: {"REQUEST_EXPIRED", 400},
    expiry_too_far: {"EXPIRY_TOO_FAR", 400},
    unknown_identity: {"UNKNOWN_IDENTITY", 404},
    directory_unavailable: {"DIRECTORY_UNAVAILABLE", 503},
    wrong_directory: {"WRONG_DIRECTORY", 403},
    stale_key_epoch: {"STALE_KEY_EPOCH", 409},
    bad_signature: {"BAD_SIGNATURE", 401},
    replayed: {"REPLAYED", 409},
    banned: {"IDENTITY_BANNED", 403},
    handle_taken: {"SLUG_TAKEN", 409},
    has_other_handle: {"ALREADY_CLAIMED", 409},
    handle_invalid: {"INVALID_USERNAME", 400},
    handle_reserved: {"RESERVED", 400},
    no_handle: {"NO_HANDLE", 409},
    namespace_reserved: {"NAMESPACE_RESERVED", 403},
    claim_not_pending: {"CLAIM_NOT_PENDING", 409},
    dns_unverified: {"DNS_UNVERIFIED", 400},
    dns_timeout: {"DNS_TIMEOUT", 504},
    policy_required: {"POLICY_ACCEPTANCE_REQUIRED", 412},
    rate_limited: {"RATE_LIMITED", 429},
    handle_not_found: {"HANDLE_NOT_FOUND", 404}
  ]

  @by_code Map.new(@refusals, fn {name, {code, _status}} -> {code, name} end)

  @label ~r/\A[\x20-\x7E]{1,64}\z/
  @blank ~r/\A[ \t\r\n]*\z/
  @max_argument_bytes 4000

  @type operation :: String.t()

  @type registry :: %{host: String.t(), directory: String.t()}

  @type refusal ::
          reason()
          | :directory_unavailable
          | :replayed
          | :banned
          | :handle_taken
          | :has_other_handle
          | :handle_invalid
          | :handle_reserved
          | :no_handle
          | :namespace_reserved
          | :claim_not_pending
          | :dns_unverified
          | :dns_timeout
          | :policy_required
          | :rate_limited
          | :handle_not_found

  @type reason ::
          :request_malformed
          | :wrong_protocol
          | :wrong_registry
          | :unknown_operation
          | :expired
          | :expiry_too_far
          | :unknown_identity
          | :wrong_directory
          | :stale_key_epoch
          | :bad_signature

  @type t :: %__MODULE__{
          registry: String.t(),
          operation: operation(),
          identifier: String.t(),
          key_epoch: String.t(),
          nonce: binary(),
          expires_at: non_neg_integer(),
          body: %{String.t() => term()},
          sig: binary() | nil
        }

  @enforce_keys [:registry, :operation, :identifier, :key_epoch, :nonce, :expires_at, :body]
  defstruct [:registry, :operation, :identifier, :key_epoch, :nonce, :expires_at, :body, sig: nil]

  @doc "The protocol string a request carries."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc "The operations, exhaustively."
  @spec operations() :: [operation()]
  def operations, do: @bodies |> Map.keys() |> Enum.sort()

  @doc "The largest request, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The length of a nonce, in bytes."
  @spec nonce_bytes() :: pos_integer()
  def nonce_bytes, do: @nonce_bytes

  @doc "How far ahead of its clock the signer sets `expires_at`, in milliseconds."
  @spec lifetime_ms() :: pos_integer()
  def lifetime_ms, do: @lifetime_ms

  @doc """
  How far ahead of the registry's clock an `expires_at` may lie, in
  milliseconds: the 300-second window and 60 seconds of clock skew.
  """
  @spec max_ahead_ms() :: pos_integer()
  def max_ahead_ms, do: @max_ahead_ms

  @doc """
  Every refusal in its table order: CYFR's name, the registry's code and
  the HTTP status.
  """
  @spec refusals() :: [{refusal(), {String.t(), pos_integer()}}]
  def refusals, do: @refusals

  @doc """
  CYFR's name for the refusal in a registry error envelope, its JSON bytes
  or their decoded map: the code of its first error, which carries a
  string `message` beside it. An envelope of another shape, a null or a
  float anywhere in it, or a code outside `refusals/0`, is
  `:malformed_answer`.
  """
  @spec refusal(binary() | map()) :: {:ok, refusal()} | {:error, :malformed_answer}
  def refusal(envelope) when is_binary(envelope) do
    case Prima.Json.decode(envelope) do
      {:ok, map} when is_map(map) -> refusal(map)
      _ -> {:error, :malformed_answer}
    end
  end

  def refusal(%{"errors" => [%{"code" => code, "message" => message} | _]} = envelope)
      when is_map_key(@by_code, code) and is_binary(message) do
    case Encoding.jcs(envelope) do
      {:ok, _bytes} -> {:ok, Map.fetch!(@by_code, code)}
      {:error, _reason} -> {:error, :malformed_answer}
    end
  end

  def refusal(_envelope), do: {:error, :malformed_answer}

  @doc """
  An unsigned request from its fields (atom keys; the nonce as raw bytes,
  the body a map with string keys, held as given: a key the operation does
  not take is refused even when its value is nil). A field of the wrong
  shape answers `:request_malformed` and an operation this protocol does
  not know `:unknown_operation`, as the registry would. Sign it with
  `sign/2`.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, :request_malformed | :unknown_operation}
  def new(attrs) do
    attrs = Map.new(attrs)

    map =
      Encoding.compact(%{
        "protocol" => @protocol,
        "registry" => attrs[:registry],
        "operation" => attrs[:operation],
        "identifier" => attrs[:identifier],
        "key_epoch" => attrs[:key_epoch],
        "nonce" => is_binary(attrs[:nonce]) && Encoding.b64(attrs[:nonce]),
        "expires_at" => attrs[:expires_at],
        "body" => attrs[:body]
      })

    with {:ok, request} <- read(map, false),
         :ok <- body(request),
         do: {:ok, request}
  end

  @doc """
  The JSON map of a request; `sig` is absent while unsigned. `address.set`
  without an address has no `address` key.
  """
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = request) do
    Encoding.compact(%{
      "protocol" => @protocol,
      "registry" => request.registry,
      "operation" => request.operation,
      "identifier" => request.identifier,
      "key_epoch" => request.key_epoch,
      "nonce" => Encoding.b64(request.nonce),
      "expires_at" => request.expires_at,
      "body" => request.body,
      "sig" => request.sig && Encoding.b64(request.sig)
    })
  end

  @doc """
  Sign a request with the person's live private key: the bytes the signer
  sends, the JCS form of the request with its `sig`. A request whose bytes
  would exceed `max_bytes/0` (JSON escaping can make a body that fits its
  own bounds larger) is `:request_malformed`, as the registry would answer
  it.
  """
  @spec sign(t(), binary()) :: {:ok, binary()} | {:error, :request_malformed}
  def sign(%__MODULE__{} = request, live_private_key) do
    bytes =
      %{request | sig: nil}
      |> encode()
      |> Encoding.sign(live_private_key)
      |> Encoding.jcs!()

    if byte_size(bytes) > @max_bytes, do: {:error, :request_malformed}, else: {:ok, bytes}
  end

  @doc """
  Check the bytes of a request as the registry `registry` (its host and
  the directory every identity it accepts names) does at `now` (Unix
  milliseconds), under `head`, the state it verified from the log it read
  at its directory for the request's identifier. Refusals in the
  moduledoc's order.
  """
  @spec verify(binary(), State.t(), registry(), integer()) :: {:ok, t()} | {:error, reason()}
  def verify(bytes, %State{} = head, %{host: host, directory: directory}, now)
      when is_binary(bytes) and is_integer(now) do
    with {:ok, map} <- parse(bytes),
         {:ok, request} <- read(map, true),
         :ok <- same(request.registry, host, :wrong_registry),
         :ok <- body(request),
         :ok <- expiry(request.expires_at, now),
         :ok <- same(request.identifier, head.identifier, :unknown_identity),
         :ok <- same(head.directory, directory, :wrong_directory),
         :ok <- same(request.key_epoch, head.key_epoch, :stale_key_epoch),
         :ok <- signed(map, head.live_key) do
      {:ok, request}
    end
  end

  defp parse(bytes) when byte_size(bytes) > @max_bytes, do: {:error, :request_malformed}

  defp parse(bytes) do
    case Prima.Json.decode(bytes) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :request_malformed}
    end
  end

  # Steps 1 and 2: exact keys and their types over the whole map, inside
  # JCS's domain, then the protocol.
  defp read(map, signed?) do
    fields = if signed?, do: @envelope ++ ["sig"], else: @envelope

    with :ok <- Encoding.fields(map, fields, []),
         {:ok, _bytes} <- Encoding.jcs(map),
         {:ok, protocol} <- Encoding.check(map, "protocol", &is_binary/1),
         {:ok, registry} <- Encoding.check(map, "registry", &Encoding.host?/1),
         {:ok, operation} <- Encoding.check(map, "operation", &is_binary/1),
         {:ok, identifier} <- Encoding.check(map, "identifier", &Encoding.identifier?/1),
         {:ok, key_epoch} <- Encoding.check(map, "key_epoch", &Encoding.digest?/1),
         {:ok, nonce} <- Encoding.binary(map, "nonce", @nonce_bytes),
         {:ok, expires_at} <- Encoding.check(map, "expires_at", &Encoding.ms?/1),
         {:ok, body} <- Encoding.check(map, "body", &is_map/1),
         {:ok, sig} <- signature(map, signed?) do
      if protocol == @protocol do
        {:ok,
         %__MODULE__{
           registry: registry,
           operation: operation,
           identifier: identifier,
           key_epoch: key_epoch,
           nonce: nonce,
           expires_at: expires_at,
           body: body,
           sig: sig
         }}
      else
        {:error, :wrong_protocol}
      end
    else
      {:error, _reason} -> {:error, :request_malformed}
    end
  end

  defp signature(_map, false), do: {:ok, nil}
  defp signature(map, true), do: Encoding.binary(map, "sig", 64)

  defp body(%__MODULE__{operation: operation, body: body}) do
    case Map.fetch(@bodies, operation) do
      {:ok, {required, optional}} ->
        if Encoding.fields(body, required, optional) == :ok and
             Enum.all?(body, fn {key, value} -> valid?(key, value) end),
           do: :ok,
           else: {:error, :request_malformed}

      :error ->
        {:error, :unknown_operation}
    end
  end

  defp valid?("handle", value), do: ComponentRef.valid_personal_slug?(value)
  defp valid?("label", value), do: is_binary(value) and Regex.match?(@label, value)
  defp valid?("address", value), do: Encoding.home?(value)
  defp valid?("policy_version", value), do: Encoding.text?(value, 128)
  defp valid?("action_type", value), do: value in ["takedown", "ban"]
  defp valid?("action_ref", value), do: Encoding.text?(value, 256)

  defp valid?("argument", value) do
    is_binary(value) and byte_size(value) <= @max_argument_bytes and String.valid?(value) and
      not Regex.match?(@blank, value)
  end

  defp valid?("slug", value) do
    is_binary(value) and String.contains?(value, ".") and
      ComponentRef.validate_namespace(value) == :ok
  end

  defp expiry(expires_at, now) do
    cond do
      expires_at <= now -> {:error, :expired}
      expires_at - now > @max_ahead_ms -> {:error, :expiry_too_far}
      true -> :ok
    end
  end

  defp same(value, value, _reason), do: :ok
  defp same(_value, _expected, reason), do: {:error, reason}

  defp signed(map, live_key) do
    if Encoding.verify(map, live_key), do: :ok, else: {:error, :bad_signature}
  end
end
