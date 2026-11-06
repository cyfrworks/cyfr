# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.RegistryRequest do
  @moduledoc """
  The one signed request that carries every registry operation a person
  makes, `cyfr-registry-request/v2`. `tests/fixtures/registry_wire.json`
  holds its vectors, which the registry's verifier reads too.

  A request is a JSON object of at most 16 KiB with exactly the keys
  `protocol`, `registry` (the registry's lowercase host), `operation`,
  `identifier`, `signer` (a key the identifier's log lists, by its `kid`,
  or `recovery:<kid>` for one of its recovery keys), `nonce` (16 bytes),
  `expires_at` (Unix milliseconds), `body` and `sig`, in the encodings of
  `Prima.Identity.Encoding`. `sig` is the signer's, over the JCS bytes of
  every key but `sig`: an Ed25519 signature over those bytes for a device
  or recovery key (`sign/2`), or a passkey's `Prima.Identity.WebAuthn`
  assertion whose challenge is their SHA-256 (`challenge/1`, `attach/2`).
  Whoever signs chooses the signer, as in the log: a CYFR hands the
  account pages the request without `signer` and `sig` (`to_sign/1`), and
  the passkey's kid is set before it signs. `policy.accept` precedes a
  person's first `handle.claim`; at an account's birth both are signed by
  its recovery key.

  Each operation's body holds exactly its keys:

    * `handle.claim` — `handle`, a personal slug
      (`Prima.ComponentRef.valid_personal_slug?/1`).
    * `tokens.mint` — `label`, the device label: 1 to 64 printable ASCII
      characters.
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
    6. the head the registry read for the request's identifier at the
       directory it is configured with: a head of another identifier is no
       log of this one, `:unknown_identity`;
    7. the head's directory against the registry's: `:wrong_directory`;
    8. the signature by the signer, a key or recovery key the head lists,
       checked as `Prima.Identity` checks an entry's (a passkey's at the
       registry's directory): `:bad_signature` for a signer the head does
       not list, a `sig` of the other algorithm's shape, or a signature
       that does not verify.

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
  alias Prima.Identity.{Encoding, Key, State, WebAuthn}

  @protocol "cyfr-registry-request/v2"
  @max_bytes 16_384
  @nonce_bytes 16
  @lifetime_ms 120_000
  @max_ahead_ms 360_000
  @envelope ~w(protocol registry operation identifier signer nonce expires_at body)
  @signer ~r/\A(?:recovery:)?sha256:[0-9a-f]{64}\z/

  # Each operation's body: its required keys and its optional keys. `valid?/2`
  # checks each value by its key.
  @bodies %{
    "handle.claim" => {~w(handle), []},
    "tokens.mint" => {~w(label), []},
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
    bad_signature: {"BAD_SIGNATURE", 401},
    replayed: {"REPLAYED", 409},
    banned: {"IDENTITY_BANNED", 403},
    not_appellant: {"NOT_APPELLANT_OF_RECORD", 403},
    action_not_found: {"ACTION_NOT_FOUND", 404},
    appeal_too_early: {"APPEAL_TOO_EARLY", 403},
    namespace_unowned: {"NAMESPACE_UNOWNED", 403},
    handle_taken: {"SLUG_TAKEN", 409},
    has_other_handle: {"ALREADY_CLAIMED", 409},
    handle_invalid: {"INVALID_USERNAME", 400},
    handle_reserved: {"RESERVED", 400},
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
          | :not_appellant
          | :action_not_found
          | :appeal_too_early
          | :namespace_unowned
          | :handle_taken
          | :has_other_handle
          | :handle_invalid
          | :handle_reserved
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
          | :bad_signature

  @type t :: %__MODULE__{
          registry: String.t(),
          operation: operation(),
          identifier: String.t(),
          signer: String.t() | nil,
          nonce: binary(),
          expires_at: non_neg_integer(),
          body: %{String.t() => term()},
          sig: binary() | WebAuthn.t() | nil
        }

  @enforce_keys [:registry, :operation, :identifier, :signer, :nonce, :expires_at, :body]
  defstruct [:registry, :operation, :identifier, :signer, :nonce, :expires_at, :body, sig: nil]

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
  `sign/2`, or attach a passkey's assertion over `challenge/1` with
  `attach/2`.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, :request_malformed | :unknown_operation}
  def new(attrs) do
    attrs = Map.new(attrs)

    checked(
      Encoding.compact(%{
        "protocol" => @protocol,
        "registry" => attrs[:registry],
        "operation" => attrs[:operation],
        "identifier" => attrs[:identifier],
        "signer" => attrs[:signer],
        "nonce" => is_binary(attrs[:nonce]) && Encoding.b64(attrs[:nonce]),
        "expires_at" => attrs[:expires_at],
        "body" => attrs[:body]
      }),
      :unsigned
    )
  end

  @doc """
  Read the request a CYFR hands a passkey to sign from its JSON map: held
  as `new/1` holds its fields, but without `signer` and `sig`. Whoever
  signs chooses the signer, as in the log, and sets it before signing
  (`Prima.SignIn`'s `registry` purpose).
  """
  @spec to_sign(term()) ::
          {:ok, t()} | {:error, :request_malformed | :wrong_protocol | :unknown_operation}
  def to_sign(map), do: checked(map, :to_sign)

  defp checked(map, mode) when is_map(map) and not is_struct(map) do
    with {:ok, request} <- read(map, mode),
         :ok <- body(request),
         do: {:ok, request}
  end

  defp checked(_value, _mode), do: {:error, :request_malformed}

  @doc "The JSON map of a request; `sig` is absent while unsigned."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = request) do
    Encoding.compact(%{
      "protocol" => @protocol,
      "registry" => request.registry,
      "operation" => request.operation,
      "identifier" => request.identifier,
      "signer" => request.signer,
      "nonce" => Encoding.b64(request.nonce),
      "expires_at" => request.expires_at,
      "body" => request.body,
      "sig" => encode_sig(request.sig)
    })
  end

  defp encode_sig(nil), do: nil
  defp encode_sig(sig) when is_binary(sig), do: Encoding.b64(sig)
  defp encode_sig(sig), do: WebAuthn.encode(sig)

  @doc "The bytes a request's signer signs: its JCS form without `sig`."
  @spec signing_bytes(t()) :: binary()
  def signing_bytes(%__MODULE__{} = request),
    do: %{request | sig: nil} |> encode() |> Encoding.jcs!()

  @doc "A passkey's WebAuthn challenge for a request: SHA-256 of its `signing_bytes/1`."
  @spec challenge(t()) :: binary()
  def challenge(%__MODULE__{} = request), do: :crypto.hash(:sha256, signing_bytes(request))

  @doc """
  Sign a request with an Ed25519 private key, a device's or a recovery
  key's: the bytes the signer sends, the JCS form of the request with its
  `sig`. A request whose bytes would exceed `max_bytes/0` (JSON escaping
  can make a body that fits its own bounds larger) is `:request_malformed`,
  as the registry would answer it.
  """
  @spec sign(t(), binary()) :: {:ok, binary()} | {:error, :request_malformed}
  def sign(%__MODULE__{} = request, private_key) do
    sig = :crypto.sign(:eddsa, :none, signing_bytes(request), [private_key, :ed25519])
    sent(%{request | sig: sig})
  end

  @doc """
  Attach a passkey's assertion over `challenge/1` as a request's `sig`:
  the bytes the signer sends, bounded as `sign/2`'s are.
  """
  @spec attach(t(), WebAuthn.t()) :: {:ok, binary()} | {:error, :request_malformed}
  def attach(%__MODULE__{} = request, %{authenticator_data: _, client_data: _} = assertion),
    do: sent(%{request | sig: assertion})

  defp sent(request) do
    bytes = request |> encode() |> Encoding.jcs!()
    if byte_size(bytes) > @max_bytes, do: {:error, :request_malformed}, else: {:ok, bytes}
  end

  @doc """
  Check the bytes of a request as the registry `registry` (its host and
  the directory it is configured with, which every identity it accepts
  names) does at `now` (Unix milliseconds), under `head`, the state it
  verified from the log it read at that directory for the request's
  identifier. Refusals in the moduledoc's order.
  """
  @spec verify(binary(), State.t(), registry(), integer()) :: {:ok, t()} | {:error, reason()}
  def verify(bytes, %State{} = head, %{host: host, directory: directory}, now)
      when is_binary(bytes) and is_integer(now) do
    with {:ok, map} <- parse(bytes),
         {:ok, request} <- read(map, :signed),
         :ok <- same(request.registry, host, :wrong_registry),
         :ok <- body(request),
         :ok <- expiry(request.expires_at, now),
         :ok <- same(request.identifier, head.identifier, :unknown_identity),
         :ok <- same(head.directory, directory, :wrong_directory),
         :ok <- signed(request, head) do
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
  # A signed request, an unsigned one, or one to sign, which has no
  # signer yet.
  defp read(map, mode) do
    fields =
      case mode do
        :signed -> @envelope ++ ["sig"]
        :unsigned -> @envelope
        :to_sign -> @envelope -- ["signer"]
      end

    with :ok <- Encoding.fields(map, fields, []),
         {:ok, _bytes} <- Encoding.jcs(map),
         {:ok, protocol} <- Encoding.check(map, "protocol", &is_binary/1),
         {:ok, registry} <- Encoding.check(map, "registry", &Encoding.host?/1),
         {:ok, operation} <- Encoding.check(map, "operation", &is_binary/1),
         {:ok, identifier} <- Encoding.check(map, "identifier", &Encoding.identifier?/1),
         {:ok, signer} <- signer(map, mode),
         {:ok, nonce} <- Encoding.binary(map, "nonce", @nonce_bytes),
         {:ok, expires_at} <- Encoding.check(map, "expires_at", &Encoding.ms?/1),
         {:ok, body} <- Encoding.check(map, "body", &is_map/1),
         {:ok, sig} <- signature(map, mode == :signed) do
      if protocol == @protocol do
        {:ok,
         %__MODULE__{
           registry: registry,
           operation: operation,
           identifier: identifier,
           signer: signer,
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

  defp signer(_map, :to_sign), do: {:ok, nil}
  defp signer(map, _mode), do: Encoding.check(map, "signer", &signer?/1)

  defp signer?(value), do: is_binary(value) and Regex.match?(@signer, value)

  defp signature(_map, false), do: {:ok, nil}

  defp signature(map, true) do
    case map["sig"] do
      sig when is_binary(sig) ->
        Encoding.binary(map, "sig", 64)

      sig ->
        case WebAuthn.decode(sig) do
          {:ok, assertion} -> {:ok, assertion}
          :error -> {:error, {:invalid_field, "sig"}}
        end
    end
  end

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

  # The signer must be one the head lists, and its `sig` the shape of its
  # algorithm: Ed25519 over the signing bytes, or a passkey's assertion
  # over their SHA-256 at the head's directory.
  defp signed(%__MODULE__{signer: "recovery:" <> _ = signer, sig: sig} = request, head)
       when is_binary(sig),
       do: ed25519(request, sig, State.recovery_key(head, signer))

  defp signed(%__MODULE__{signer: kid, sig: sig} = request, head) do
    case {State.key(head, kid), sig} do
      {%Key{alg: :ed25519, pub: pub}, sig} when is_binary(sig) ->
        ed25519(request, sig, pub)

      {%Key{alg: :es256, pub: pub}, %{} = assertion} ->
        {origin, host} = Encoding.directory_origin(head.directory)

        case WebAuthn.verify(assertion, pub, challenge(request), origin, host) do
          :ok -> :ok
          {:error, _reason} -> {:error, :bad_signature}
        end

      _other ->
        {:error, :bad_signature}
    end
  end

  defp ed25519(_request, _sig, nil), do: {:error, :bad_signature}

  defp ed25519(request, sig, pub) do
    if :crypto.verify(:eddsa, :none, signing_bytes(request), sig, [pub, :ed25519]),
      do: :ok,
      else: {:error, :bad_signature}
  end
end
