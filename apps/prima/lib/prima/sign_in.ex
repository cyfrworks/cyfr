# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.SignIn do
  @moduledoc """
  What a CYFR mints for one sign-in, confirmation or registry signature,
  and the answers that come back, `cyfr-sign-in/v1`.
  `tests/fixtures/sign_in.json` holds its vectors, which the account pages
  read too.

  ## The request

  `{protocol, purpose, audience, challenge, expires_at, return}` and, by
  purpose, one more field:

    * `sign_in` — nothing more.
    * `confirm` — `subject`, the pending confirmation's digest
      (`Prima.Confirmation.digest/1`).
    * `registry` — `registry_request`, the `Prima.RegistryRequest` the
      person is asked to sign, without `signer` and `sig`: whoever signs
      chooses the signer, as in the log, so the account pages set it to the
      chosen passkey's kid before signing (`Prima.RegistryRequest.to_sign/1`).

  `audience` is the minting CYFR's origin, `challenge` 32 random bytes,
  `expires_at` `lifetime_ms/0` after the mint on its clock, and `return` a
  URL of an origin and a path, without a query or fragment, on `audience`.
  The CYFR keeps the request keyed by `challenge`, bound to the browser or
  device channel that asked, and spends it on the first answer.

  ## The digest

  What a signer signs: SHA-256 of the request's JCS bytes for `sign_in`
  and `confirm` (`digest/1`), and for `registry` of the registry request's
  with `signer` set to the signing passkey's kid (`digest/2`), so the
  registry receives exactly `Prima.RegistryRequest`'s signature over its
  own request (`registry_bytes/2`). A passkey signs it as its WebAuthn
  challenge; a device signs its 32 bytes with Ed25519.

  ## The answers

    * `Prima.SignIn.PasskeyAnswer`, from the account pages:
      `{challenge, identifier, credential_id, authenticator_data,
      client_data, signature}`, the identifier the passkey's user handle
      names (`Prima.Identity.identifier_for_user_id/1`), and `signer`, the
      passkey's kid, for a `registry` request.
    * `Prima.SignIn.DeviceAnswer`, over the device channel:
      `{challenge, kid, sig}`. A device answers `sign_in` and `confirm`; for
      `registry` a terminal signs the registry request itself.

  ## Fragments

  The request travels to the account pages, and a passkey's answer back to
  `return`, in a URL fragment (`fragment/1`, `parse_fragment/1`): the
  unpadded base64url of the object's JCS bytes, at most
  `max_fragment_bytes/0`, checked before it is decoded. Any other spelling
  of the same object is refused, so a fragment has one spelling.

  ## Verification

  `verify/4` is the CYFR's check of an answer against the request it
  held for that answer's challenge, in the order the CYFR makes it, the
  first failure refusing. Whether the request is unspent and bound to the
  browser or channel answering, which log policy the state was read
  under, and what each purpose then does are the CYFR's.
  """

  alias Prima.Identity.{Encoding, Key, State, WebAuthn}
  alias Prima.RegistryRequest
  alias Prima.SignIn.{DeviceAnswer, PasskeyAnswer}

  @protocol "cyfr-sign-in/v1"
  @lifetime_ms 300_000
  @challenge_bytes 32
  @max_fragment_bytes 32_768
  @required ~w(protocol purpose audience challenge expires_at return)
  @purposes %{"sign_in" => :sign_in, "confirm" => :confirm, "registry" => :registry}
  @by_purpose %{sign_in: [], confirm: ["subject"], registry: ["registry_request"]}

  @type purpose :: :sign_in | :confirm | :registry

  @type t :: %__MODULE__{
          purpose: purpose(),
          audience: String.t(),
          challenge: binary(),
          expires_at: non_neg_integer(),
          return: String.t(),
          subject: String.t() | nil,
          registry_request: RegistryRequest.t() | nil
        }

  @type reason ::
          Encoding.reason()
          | :wrong_protocol
          | :unknown_challenge
          | :expired
          | :wrong_audience
          | :wrong_identifier
          | :unknown_key
          | :wrong_purpose
          | :wrong_signer
          | :bad_signature
          | WebAuthn.reason()

  @enforce_keys [:purpose, :audience, :challenge, :expires_at, :return]
  defstruct [:purpose, :audience, :challenge, :expires_at, :return, :subject, :registry_request]

  @doc "The protocol string a request carries."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc "The three purposes, exhaustively."
  @spec purposes() :: [purpose()]
  def purposes, do: [:sign_in, :confirm, :registry]

  @doc "How long a request lives after its mint, in milliseconds."
  @spec lifetime_ms() :: pos_integer()
  def lifetime_ms, do: @lifetime_ms

  @doc "The length of a request's challenge, in bytes."
  @spec challenge_bytes() :: pos_integer()
  def challenge_bytes, do: @challenge_bytes

  @doc "The longest fragment read, in bytes."
  @spec max_fragment_bytes() :: pos_integer()
  def max_fragment_bytes, do: @max_fragment_bytes

  @doc """
  A request from its fields (atom keys; the challenge as raw bytes, the
  registry request as a `Prima.RegistryRequest` struct).
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, reason()}
  def new(attrs) do
    attrs = Map.new(attrs)

    %{
      "protocol" => @protocol,
      "purpose" => attrs[:purpose] && Atom.to_string(attrs[:purpose]),
      "audience" => attrs[:audience],
      "challenge" => is_binary(attrs[:challenge]) && Encoding.b64(attrs[:challenge]),
      "expires_at" => attrs[:expires_at],
      "return" => attrs[:return],
      "subject" => attrs[:subject],
      "registry_request" =>
        attrs[:registry_request] && RegistryRequest.encode(attrs[:registry_request])
    }
    |> Encoding.compact()
    |> decode()
  end

  @doc "Read a request from its JSON map."
  @spec decode(term()) :: {:ok, t()} | {:error, reason()}
  def decode(map) when is_map(map) and not is_struct(map) do
    with :ok <- Encoding.protocol(map, @protocol),
         {:ok, purpose} <- purpose(map),
         :ok <- Encoding.fields(map, @required ++ Map.fetch!(@by_purpose, purpose), []),
         {:ok, audience} <- Encoding.check(map, "audience", &Encoding.home?/1),
         {:ok, challenge} <- Encoding.binary(map, "challenge", @challenge_bytes),
         {:ok, expires_at} <- Encoding.check(map, "expires_at", &Encoding.ms?/1),
         {:ok, return} <- Encoding.check(map, "return", &on?(&1, audience)),
         {:ok, subject} <- Encoding.optional(map, "subject", &Encoding.digest?/1),
         {:ok, registry_request} <- registry_request(map) do
      {:ok,
       %__MODULE__{
         purpose: purpose,
         audience: audience,
         challenge: challenge,
         expires_at: expires_at,
         return: return,
         subject: subject,
         registry_request: registry_request
       }}
    end
  end

  def decode(_value), do: {:error, {:invalid_field, "request"}}

  @doc "The JSON map of a request."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = request) do
    Encoding.compact(%{
      "protocol" => @protocol,
      "purpose" => Atom.to_string(request.purpose),
      "audience" => request.audience,
      "challenge" => Encoding.b64(request.challenge),
      "expires_at" => request.expires_at,
      "return" => request.return,
      "subject" => request.subject,
      "registry_request" =>
        request.registry_request && RegistryRequest.encode(request.registry_request)
    })
  end

  @doc "The 32 bytes a signer of a `sign_in` or `confirm` request signs: SHA-256 of its JCS bytes."
  @spec digest(t()) :: binary()
  def digest(%__MODULE__{purpose: purpose} = request) when purpose in [:sign_in, :confirm],
    do: :crypto.hash(:sha256, request |> encode() |> Encoding.jcs!())

  @doc """
  The 32 bytes a passkey signs for a `registry` request: SHA-256 of the
  registry request's JCS bytes with `signer` set to its kid.
  """
  @spec digest(t(), String.t()) :: binary()
  def digest(%__MODULE__{purpose: :registry, registry_request: request}, signer),
    do: RegistryRequest.challenge(%{request | signer: signer})

  @doc "The fragment that carries a request or an answer: unpadded base64url of its JCS bytes."
  @spec fragment(t() | PasskeyAnswer.t()) :: String.t()
  def fragment(%__MODULE__{} = request),
    do: request |> encode() |> Encoding.jcs!() |> Encoding.b64()

  def fragment(%PasskeyAnswer{} = answer),
    do: answer |> PasskeyAnswer.encode() |> Encoding.jcs!() |> Encoding.b64()

  @doc """
  The JSON object a fragment carries, its length checked before it is
  decoded: `:too_large` past `max_fragment_bytes/0`, `:invalid_fragment`
  for anything that is not unpadded base64url, in its one spelling, of a
  JSON object's JCS bytes: whitespace, another key order, a repeated key
  or a number JCS does not write are each refused. The object is then read
  as a request (`decode/1`) or an answer (`PasskeyAnswer.decode/1`).
  """
  @spec parse_fragment(term()) :: {:ok, map()} | {:error, :too_large | :invalid_fragment}
  def parse_fragment(fragment) when is_binary(fragment) do
    with :ok <- bounded(fragment),
         {:ok, bytes} <- Base.url_decode64(fragment, padding: false),
         ^fragment <- Encoding.b64(bytes),
         {:ok, %{} = object} <- Prima.Json.decode(bytes),
         {:ok, ^bytes} <- Encoding.jcs(object) do
      {:ok, object}
    else
      {:error, :too_large} -> {:error, :too_large}
      _ -> {:error, :invalid_fragment}
    end
  end

  def parse_fragment(_fragment), do: {:error, :invalid_fragment}

  defp bounded(fragment) do
    if byte_size(fragment) > @max_fragment_bytes, do: {:error, :too_large}, else: :ok
  end

  @doc """
  Check an answer against `request`, the request the CYFR held for its
  challenge, under `state`, the answering account's verified log. `opts`:
  `:home`, this CYFR's origin, and `:now`, its clock in milliseconds.

  In order, the first failure answering: the answer's challenge is the
  request's (`:unknown_challenge`) and the request is unexpired
  (`:expired`); the request's audience is this CYFR (`:wrong_audience`);
  then, for a passkey's answer, the state is the answer's identifier's
  (`:wrong_identifier`), a passkey it lists has the answer's credential id
  (`:unknown_key`), a `registry` answer names a signer (`:wrong_signer`),
  its assertion verifies over the digest at the state's directory
  (`Prima.Identity.WebAuthn.verify/5`'s refusals), a `registry` answer's
  identifier is the registry request's (`:wrong_identifier`), and its
  `signer` is the kid of the passkey that made the assertion while any
  other answer names none (`:wrong_signer`); for a device's answer, the purpose is `sign_in`
  or `confirm` (`:wrong_purpose`), the state lists a device key with the
  answer's `kid` (`:unknown_key`) and its Ed25519 signature over
  `digest/1` verifies (`:bad_signature`). Answers the key that signed.
  """
  @spec verify(PasskeyAnswer.t() | DeviceAnswer.t(), t(), State.t(), keyword()) ::
          {:ok, Key.t()} | {:error, reason()}
  def verify(answer, %__MODULE__{} = request, %State{} = state, opts) do
    home = Keyword.fetch!(opts, :home)
    now = Keyword.fetch!(opts, :now)

    with :ok <- same(answer.challenge, request.challenge, :unknown_challenge),
         :ok <- unexpired(request, now),
         :ok <- same(request.audience, home, :wrong_audience) do
      signed(answer, request, state)
    end
  end

  defp signed(%PasskeyAnswer{} = answer, request, state) do
    with :ok <- same(answer.identifier, state.identifier, :wrong_identifier),
         {:ok, key} <- found(State.passkey(state, answer.credential_id)),
         {:ok, digest} <- passkey_digest(request, answer),
         {origin, host} = Encoding.directory_origin(state.directory),
         :ok <- WebAuthn.verify(PasskeyAnswer.assertion(answer), key.pub, digest, origin, host),
         :ok <- registry_identifier(request, answer),
         :ok <- signer(request, answer, key) do
      {:ok, key}
    end
  end

  defp signed(%DeviceAnswer{}, %__MODULE__{purpose: :registry}, _state),
    do: {:error, :wrong_purpose}

  defp signed(%DeviceAnswer{} = answer, request, state) do
    case State.key(state, answer.kid) do
      %Key{kind: :device, pub: pub} = key ->
        if :crypto.verify(:eddsa, :none, digest(request), answer.sig, [pub, :ed25519]),
          do: {:ok, key},
          else: {:error, :bad_signature}

      _other ->
        {:error, :unknown_key}
    end
  end

  defp found(nil), do: {:error, :unknown_key}
  defp found(key), do: {:ok, key}

  defp passkey_digest(%__MODULE__{purpose: :registry}, %PasskeyAnswer{signer: nil}),
    do: {:error, :wrong_signer}

  defp passkey_digest(%__MODULE__{purpose: :registry} = request, answer),
    do: {:ok, digest(request, answer.signer)}

  defp passkey_digest(request, _answer), do: {:ok, digest(request)}

  # A registry answer's signer is the kid of the passkey that made its
  # assertion, the key the registry looks up; no other answer names one.
  defp signer(%__MODULE__{purpose: :registry}, answer, key),
    do: same(answer.signer, key.kid, :wrong_signer)

  defp signer(_request, %PasskeyAnswer{signer: nil}, _key), do: :ok
  defp signer(_request, _answer, _key), do: {:error, :wrong_signer}

  defp registry_identifier(%__MODULE__{purpose: :registry, registry_request: registry}, answer),
    do: same(answer.identifier, registry.identifier, :wrong_identifier)

  defp registry_identifier(_request, _answer), do: :ok

  defp unexpired(%__MODULE__{expires_at: expires_at}, now) when now < expires_at, do: :ok
  defp unexpired(_request, _now), do: {:error, :expired}

  @doc """
  The signed registry request a passkey's answer to a `registry` request
  makes, once `verify/4` accepted it: the registry request with the
  answer's `signer` and its assertion as `sig`, as the bytes the registry
  is sent (`Prima.RegistryRequest.attach/2`).
  """
  @spec registry_bytes(t(), PasskeyAnswer.t()) :: {:ok, binary()} | {:error, :request_malformed}
  def registry_bytes(%__MODULE__{purpose: :registry} = request, %PasskeyAnswer{} = answer) do
    %{request.registry_request | signer: answer.signer}
    |> RegistryRequest.attach(PasskeyAnswer.assertion(answer))
  end

  defp purpose(map) do
    case Map.fetch(map, "purpose") do
      {:ok, name} when is_map_key(@purposes, name) -> {:ok, Map.fetch!(@purposes, name)}
      {:ok, _name} -> {:error, {:invalid_field, "purpose"}}
      :error -> {:error, {:missing_field, "purpose"}}
    end
  end

  # A URL of `audience`'s origin and a path: no query, no fragment.
  defp on?(value, audience) do
    Encoding.directory_url?(value) and elem(Encoding.directory_origin(value), 0) == audience
  end

  defp registry_request(%{"registry_request" => map}) do
    case RegistryRequest.to_sign(map) do
      {:ok, request} -> {:ok, request}
      {:error, _reason} -> {:error, {:invalid_field, "registry_request"}}
    end
  end

  defp registry_request(_map), do: {:ok, nil}

  defp same(value, value, _reason), do: :ok
  defp same(_value, _expected, reason), do: {:error, reason}
end

defmodule Prima.SignIn.PasskeyAnswer do
  @moduledoc """
  The account pages' answer to a request, from the passkey the person
  chose: `{challenge, identifier, credential_id, authenticator_data,
  client_data, signature}`, each binary unpadded base64url, and for a
  `registry` request `signer`, the chosen passkey's kid, which the
  registry request it signed carries. `identifier` is the one the
  assertion's user handle names (`Prima.Identity.identifier_for_user_id/1`).
  """

  alias Prima.Identity.{Encoding, WebAuthn}

  @fields ~w(challenge identifier credential_id authenticator_data client_data signature)
  @max_bytes 16_384

  @type t :: %__MODULE__{
          challenge: binary(),
          identifier: String.t(),
          credential_id: binary(),
          authenticator_data: binary(),
          client_data: binary(),
          signature: binary(),
          signer: String.t() | nil
        }

  @enforce_keys [
    :challenge,
    :identifier,
    :credential_id,
    :authenticator_data,
    :client_data,
    :signature
  ]
  defstruct @enforce_keys ++ [signer: nil]

  @doc "Read an answer from its JSON map."
  @spec decode(term()) :: {:ok, t()} | {:error, Encoding.reason()}
  def decode(map) when is_map(map) and not is_struct(map) do
    with :ok <- Encoding.fields(map, @fields, ["signer"]),
         {:ok, challenge} <- Encoding.binary(map, "challenge", Prima.SignIn.challenge_bytes()),
         {:ok, identifier} <- Encoding.check(map, "identifier", &Encoding.identifier?/1),
         {:ok, credential_id} <- bytes(map, "credential_id", 1023),
         {:ok, authenticator_data} <- bytes(map, "authenticator_data", @max_bytes),
         {:ok, client_data} <- bytes(map, "client_data", @max_bytes),
         {:ok, signature} <- bytes(map, "signature", @max_bytes),
         {:ok, signer} <- Encoding.optional(map, "signer", &Encoding.digest?/1) do
      {:ok,
       %__MODULE__{
         challenge: challenge,
         identifier: identifier,
         credential_id: credential_id,
         authenticator_data: authenticator_data,
         client_data: client_data,
         signature: signature,
         signer: signer
       }}
    end
  end

  def decode(_value), do: {:error, {:invalid_field, "answer"}}

  @doc "The JSON map of an answer."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = answer) do
    answer
    |> assertion()
    |> WebAuthn.encode()
    |> Map.merge(%{
      "challenge" => Encoding.b64(answer.challenge),
      "identifier" => answer.identifier,
      "credential_id" => Encoding.b64(answer.credential_id),
      "signer" => answer.signer
    })
    |> Encoding.compact()
  end

  @doc "The answer's WebAuthn assertion."
  @spec assertion(t()) :: WebAuthn.t()
  def assertion(%__MODULE__{} = answer) do
    %{
      authenticator_data: answer.authenticator_data,
      client_data: answer.client_data,
      signature: answer.signature
    }
  end

  defp bytes(map, field, max) do
    case Encoding.unb64(map[field], 1, max) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:invalid_field, field}}
    end
  end
end

defmodule Prima.SignIn.DeviceAnswer do
  @moduledoc """
  A device's answer to a request over its channel, after its local unlock:
  `{challenge, kid, sig}`, `sig` the Ed25519 signature of the key `kid`
  names over the request's digest (`Prima.SignIn.digest/1`).
  """

  alias Prima.Identity.Encoding

  @fields ~w(challenge kid sig)

  @type t :: %__MODULE__{challenge: binary(), kid: String.t(), sig: binary()}

  @enforce_keys [:challenge, :kid, :sig]
  defstruct @enforce_keys

  @doc "A device's answer to `request`, signed with its Ed25519 private key."
  @spec sign(Prima.SignIn.t(), String.t(), binary()) :: t()
  def sign(%Prima.SignIn{} = request, kid, private_key) do
    sig = :crypto.sign(:eddsa, :none, Prima.SignIn.digest(request), [private_key, :ed25519])
    %__MODULE__{challenge: request.challenge, kid: kid, sig: sig}
  end

  @doc "Read an answer from its JSON map."
  @spec decode(term()) :: {:ok, t()} | {:error, Encoding.reason()}
  def decode(map) when is_map(map) and not is_struct(map) do
    with :ok <- Encoding.fields(map, @fields, []),
         {:ok, challenge} <- Encoding.binary(map, "challenge", Prima.SignIn.challenge_bytes()),
         {:ok, kid} <- Encoding.check(map, "kid", &Encoding.digest?/1),
         {:ok, sig} <- Encoding.binary(map, "sig", 64) do
      {:ok, %__MODULE__{challenge: challenge, kid: kid, sig: sig}}
    end
  end

  def decode(_value), do: {:error, {:invalid_field, "answer"}}

  @doc "The JSON map of an answer."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = answer) do
    %{
      "challenge" => Encoding.b64(answer.challenge),
      "kid" => answer.kid,
      "sig" => Encoding.b64(answer.sig)
    }
  end
end
