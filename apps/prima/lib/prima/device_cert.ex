# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.DeviceCert do
  @moduledoc """
  A device certificate: the person's live key, at their home, vouching
  that a device key belongs to a paired client of theirs for one home and
  athanor, for a short time. `tests/fixtures/device_cert.json` holds its
  vectors, beside the connect, renewal and pairing challenge and proof
  (`Prima.DeviceCert.Challenge`, `Prima.DeviceCert.Proof`).

  A certificate carries the protocol string `cyfr-device-cert/v1`, the
  device public key, the client id, a tagged subject, the issuing home
  (`issuer`), the home it is presented to (`audience`), the athanor, a
  not-before and an expiry in Unix milliseconds, and the live key's
  signature. The subject is one of:

    * `local`, a `user_id` of the issuing home. A local certificate names
      one home as both issuer and audience, and is valid only there. Local
      pairing needs no identifier, no directory and no `key_epoch`: the
      home checks it under the live key it stores.
    * `identity`, an enrolled person's `identifier` and the `key_epoch` of
      the head the certificate was issued under. Another home accepts only
      this subject, under the live key of a head fresher than its bound,
      and refuses it once that head's `key_epoch` has moved on.

  `verify/3` checks expiry strictly on the receiving home's clock: at or
  after `expires_at` a certificate is refused, whatever the tolerance.
  The clock tolerance applies to `not_before` alone, so it never extends a
  certificate's lifetime. A certificate is not in the identity log.
  """

  alias Prima.Identity.Encoding

  @protocol "cyfr-device-cert/v1"
  @required ~w(protocol device_key client_id subject issuer audience athanor not_before expires_at)

  @type subject ::
          %{kind: :local, user_id: String.t()}
          | %{kind: :identity, identifier: String.t(), key_epoch: String.t()}

  @type t :: %__MODULE__{
          device_key: binary(),
          client_id: String.t(),
          subject: subject(),
          issuer: String.t(),
          audience: String.t(),
          athanor: String.t(),
          not_before: non_neg_integer(),
          expires_at: non_neg_integer(),
          sig: binary() | nil
        }

  @type reason ::
          Encoding.reason()
          | :wrong_protocol
          | :local_subject_elsewhere
          | :bad_signature
          | :wrong_audience
          | :stale_key_epoch
          | :key_epoch_required
          | :not_yet_valid
          | :expired

  @enforce_keys [
    :device_key,
    :client_id,
    :subject,
    :issuer,
    :audience,
    :athanor,
    :not_before,
    :expires_at
  ]
  defstruct [
    :device_key,
    :client_id,
    :subject,
    :issuer,
    :audience,
    :athanor,
    :not_before,
    :expires_at,
    sig: nil
  ]

  @doc "The protocol string a certificate carries."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc """
  An unsigned certificate from its fields (atom keys; the device key as raw
  bytes). Sign it with `sign/2` under the person's live private key.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, reason()}
  def new(attrs) do
    attrs = Map.new(attrs)

    %{
      "protocol" => @protocol,
      "device_key" => attrs[:device_key] && Encoding.b64(attrs[:device_key]),
      "client_id" => attrs[:client_id],
      "subject" => attrs[:subject] && encode_subject(attrs[:subject]),
      "issuer" => attrs[:issuer],
      "audience" => attrs[:audience],
      "athanor" => attrs[:athanor],
      "not_before" => attrs[:not_before],
      "expires_at" => attrs[:expires_at]
    }
    |> Encoding.compact()
    |> read(false)
  end

  @doc "Read a signed certificate from its JSON map."
  @spec decode(term()) :: {:ok, t()} | {:error, reason()}
  def decode(map), do: read(map, true)

  @doc "The JSON map of a certificate; `sig` is absent while unsigned."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = cert) do
    Encoding.compact(%{
      "protocol" => @protocol,
      "device_key" => Encoding.b64(cert.device_key),
      "client_id" => cert.client_id,
      "subject" => encode_subject(cert.subject),
      "issuer" => cert.issuer,
      "audience" => cert.audience,
      "athanor" => cert.athanor,
      "not_before" => cert.not_before,
      "expires_at" => cert.expires_at,
      "sig" => cert.sig && Encoding.b64(cert.sig)
    })
  end

  @doc "Sign a certificate with the person's live private key."
  @spec sign(t(), binary()) :: t()
  def sign(%__MODULE__{} = cert, live_private_key) do
    map = cert |> Map.put(:sig, nil) |> encode() |> Encoding.sign(live_private_key)
    {:ok, sig} = Encoding.signature(map["sig"])
    %{cert | sig: sig}
  end

  @doc """
  Check a certificate presented at `opts[:home]` under the live public key
  the receiving home holds for its subject, and answer it.

  `opts`: `:home`, the receiving home; `:now`, its clock in milliseconds;
  `:skew`, the clock tolerance in milliseconds, which applies to
  `not_before` only; and, for an identity subject, `:key_epoch`, the
  current head's. Refusals, in the order checked: a malformed certificate,
  `:bad_signature`, `:wrong_audience`, `:key_epoch_required` and
  `:stale_key_epoch`, `:not_yet_valid`, and `:expired` at or after
  `expires_at`.
  """
  @spec verify(t() | map(), binary(), keyword()) :: {:ok, t()} | {:error, reason()}
  def verify(cert, live_key, opts) do
    home = Keyword.fetch!(opts, :home)
    now = Keyword.fetch!(opts, :now)
    skew = Keyword.fetch!(opts, :skew)

    with {:ok, cert} <- reread(cert),
         :ok <- signed(cert, live_key),
         :ok <- audience(cert, home),
         :ok <- key_epoch(cert.subject, Keyword.get(opts, :key_epoch)),
         :ok <- window(cert, now, skew) do
      {:ok, cert}
    end
  end

  defp reread(%__MODULE__{} = cert), do: cert |> encode() |> decode()
  defp reread(map), do: decode(map)

  defp signed(cert, live_key) do
    if Encoding.verify(encode(cert), live_key), do: :ok, else: {:error, :bad_signature}
  end

  defp audience(%__MODULE__{audience: home}, home), do: :ok
  defp audience(%__MODULE__{}, _home), do: {:error, :wrong_audience}

  defp key_epoch(%{kind: :local}, _current), do: :ok
  defp key_epoch(%{kind: :identity}, nil), do: {:error, :key_epoch_required}
  defp key_epoch(%{kind: :identity, key_epoch: current}, current), do: :ok
  defp key_epoch(%{kind: :identity}, _current), do: {:error, :stale_key_epoch}

  defp window(cert, now, skew) do
    cond do
      cert.not_before > now + skew -> {:error, :not_yet_valid}
      now >= cert.expires_at -> {:error, :expired}
      true -> :ok
    end
  end

  defp read(map, signed?) when is_map(map) and not is_struct(map) do
    sig = if signed?, do: ["sig"], else: []

    with :ok <- Encoding.protocol(map, @protocol),
         :ok <- Encoding.fields(map, @required ++ sig, []),
         {:ok, device_key} <- Encoding.binary(map, "device_key", Encoding.key_bytes()),
         {:ok, client_id} <- Encoding.check(map, "client_id", &Encoding.id?/1),
         {:ok, subject} <- decode_subject(map["subject"]),
         {:ok, issuer} <- Encoding.check(map, "issuer", &Encoding.home?/1),
         {:ok, audience} <- Encoding.check(map, "audience", &Encoding.home?/1),
         {:ok, athanor} <- Encoding.check(map, "athanor", &Encoding.id?/1),
         {:ok, not_before} <- Encoding.check(map, "not_before", &Encoding.ms?/1),
         {:ok, expires_at} <-
           Encoding.check(map, "expires_at", &(Encoding.ms?(&1) and &1 > not_before)),
         :ok <- local_here(subject, issuer, audience),
         {:ok, sig} <- signature(map, signed?) do
      {:ok,
       %__MODULE__{
         device_key: device_key,
         client_id: client_id,
         subject: subject,
         issuer: issuer,
         audience: audience,
         athanor: athanor,
         not_before: not_before,
         expires_at: expires_at,
         sig: sig
       }}
    end
  end

  defp read(_value, _signed?), do: {:error, {:invalid_field, "certificate"}}

  defp decode_subject(%{"kind" => "local"} = subject) do
    with :ok <- sub_fields(subject, ~w(kind user_id)),
         user_id when is_binary(user_id) <- subject["user_id"],
         true <- Encoding.id?(user_id) and Prima.PersonId.person?(user_id) do
      {:ok, %{kind: :local, user_id: user_id}}
    else
      _ -> {:error, {:invalid_field, "subject"}}
    end
  end

  defp decode_subject(%{"kind" => "identity"} = subject) do
    with :ok <- sub_fields(subject, ~w(kind identifier key_epoch)),
         true <- Encoding.identifier?(subject["identifier"]),
         true <- Encoding.digest?(subject["key_epoch"]) do
      {:ok,
       %{kind: :identity, identifier: subject["identifier"], key_epoch: subject["key_epoch"]}}
    else
      _ -> {:error, {:invalid_field, "subject"}}
    end
  end

  defp decode_subject(_subject), do: {:error, {:invalid_field, "subject"}}

  defp sub_fields(subject, fields) do
    if Enum.sort(Map.keys(subject)) == Enum.sort(fields), do: :ok, else: :error
  end

  defp encode_subject(%{kind: :local, user_id: user_id}),
    do: %{"kind" => "local", "user_id" => user_id}

  defp encode_subject(%{kind: :identity, identifier: identifier, key_epoch: key_epoch}),
    do: %{"kind" => "identity", "identifier" => identifier, "key_epoch" => key_epoch}

  defp encode_subject(_other), do: %{"kind" => "unknown"}

  # A local subject is a user id of the issuing home, meaningful nowhere else.
  defp local_here(%{kind: :local}, home, home), do: :ok
  defp local_here(%{kind: :local}, _issuer, _audience), do: {:error, :local_subject_elsewhere}
  defp local_here(%{kind: :identity}, _issuer, _audience), do: :ok

  defp signature(_map, false), do: {:ok, nil}

  defp signature(map, true) do
    case Encoding.signature(map["sig"]) do
      {:ok, sig} -> {:ok, sig}
      :error -> {:error, {:invalid_field, "sig"}}
    end
  end
end

defmodule Prima.DeviceCert.Challenge do
  @moduledoc """
  The challenge a home issues a device: a `purpose`, the home, the
  athanor, the client id, the device public key that must answer, a
  32-byte random nonce the issuer draws, and an expiry 60 seconds after
  issue on the issuing home's clock (`lifetime_ms/0`). It carries the
  protocol string `cyfr-device-proof/v1`, the domain of the proof that
  signs it (`Prima.DeviceCert.Proof`). The purposes:

    * `connect` — a paired client proving its key on a new connection.
    * `renew` — a paired client proving the key its paired-client row
      stores, before a replacement certificate is issued.
    * `pair` — pairing completion proving the key it submits, bound to
      the prospective client id the invitation reserved.

  A challenge is held for one connection or completion and consumed at
  most once; a disconnect discards it. Because it binds purpose, home,
  athanor, client and device key, a proof made for one never verifies as
  another's: a proof of one purpose is refused for every other, and a
  proof for one client, home, athanor or key is refused for every other.
  """

  alias Prima.Identity.Encoding

  @protocol "cyfr-device-proof/v1"
  @lifetime_ms 60_000
  @nonce_bytes 32
  @purposes %{"connect" => :connect, "renew" => :renew, "pair" => :pair}
  @required ~w(protocol purpose home athanor client_id device_key nonce expires_at)

  @type purpose :: :connect | :renew | :pair
  @type t :: %__MODULE__{
          purpose: purpose(),
          home: String.t(),
          athanor: String.t(),
          client_id: String.t(),
          device_key: binary(),
          nonce: binary(),
          expires_at: non_neg_integer()
        }

  @enforce_keys [:purpose, :home, :athanor, :client_id, :device_key, :nonce, :expires_at]
  defstruct [:purpose, :home, :athanor, :client_id, :device_key, :nonce, :expires_at]

  @doc "The protocol string a challenge and its proof carry."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc "How long a challenge lives on the issuing home's clock, in milliseconds."
  @spec lifetime_ms() :: pos_integer()
  def lifetime_ms, do: @lifetime_ms

  @doc "The length of a challenge nonce, in bytes."
  @spec nonce_bytes() :: pos_integer()
  def nonce_bytes, do: @nonce_bytes

  @doc "The three purposes, `connect`, `renew` and `pair`."
  @spec purposes() :: [purpose()]
  def purposes, do: [:connect, :renew, :pair]

  @doc """
  A challenge issued at `:now` (milliseconds) with the `:nonce` its issuer
  drew, expiring `lifetime_ms/0` later. The other attributes: `:purpose`,
  `:home`, `:athanor`, `:client_id` and `:device_key` (raw bytes).
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Encoding.reason()}
  def new(attrs) do
    attrs = Map.new(attrs)
    now = attrs[:now]

    %{
      "protocol" => @protocol,
      "purpose" =>
        if(is_atom(attrs[:purpose]), do: to_string(attrs[:purpose]), else: attrs[:purpose]),
      "home" => attrs[:home],
      "athanor" => attrs[:athanor],
      "client_id" => attrs[:client_id],
      "device_key" => attrs[:device_key] && Encoding.b64(attrs[:device_key]),
      "nonce" => is_binary(attrs[:nonce]) && Encoding.b64(attrs[:nonce]),
      "expires_at" => is_integer(now) && now + @lifetime_ms
    }
    |> decode()
  end

  @doc "Read a challenge from its JSON map."
  @spec decode(term()) :: {:ok, t()} | {:error, Encoding.reason() | :wrong_protocol}
  def decode(map) when is_map(map) and not is_struct(map) do
    with :ok <- Encoding.protocol(map, @protocol),
         :ok <- Encoding.fields(map, @required, []),
         {:ok, purpose} <- purpose(map),
         {:ok, home} <- Encoding.check(map, "home", &Encoding.home?/1),
         {:ok, athanor} <- Encoding.check(map, "athanor", &Encoding.id?/1),
         {:ok, client_id} <- Encoding.check(map, "client_id", &Encoding.id?/1),
         {:ok, device_key} <- Encoding.binary(map, "device_key", Encoding.key_bytes()),
         {:ok, nonce} <- Encoding.binary(map, "nonce", @nonce_bytes),
         {:ok, expires_at} <- Encoding.check(map, "expires_at", &Encoding.ms?/1) do
      {:ok,
       %__MODULE__{
         purpose: purpose,
         home: home,
         athanor: athanor,
         client_id: client_id,
         device_key: device_key,
         nonce: nonce,
         expires_at: expires_at
       }}
    end
  end

  def decode(_value), do: {:error, {:invalid_field, "challenge"}}

  @doc "The JSON map of a challenge: exactly what its proof signs."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = challenge) do
    %{
      "protocol" => @protocol,
      "purpose" => Atom.to_string(challenge.purpose),
      "home" => challenge.home,
      "athanor" => challenge.athanor,
      "client_id" => challenge.client_id,
      "device_key" => Encoding.b64(challenge.device_key),
      "nonce" => Encoding.b64(challenge.nonce),
      "expires_at" => challenge.expires_at
    }
  end

  defp purpose(map) do
    case Map.fetch(@purposes, map["purpose"]) do
      {:ok, purpose} -> {:ok, purpose}
      :error -> {:error, {:invalid_field, "purpose"}}
    end
  end
end

defmodule Prima.DeviceCert.Proof do
  @moduledoc """
  A device's proof of possession: the exact challenge it was issued, and
  the device key's signature over it (`sig`, over the challenge's JCS
  bytes). `verify/3` holds a proof to the challenge the home holds for
  that connection, field by field, then the signature under the held
  challenge's device key, then its expiry.
  """

  alias Prima.DeviceCert.Challenge
  alias Prima.Identity.Encoding

  @type t :: %__MODULE__{challenge: Challenge.t(), sig: binary()}
  @enforce_keys [:challenge, :sig]
  defstruct [:challenge, :sig]

  @compared [:purpose, :home, :athanor, :client_id, :device_key, :nonce, :expires_at]

  @doc "Answer a challenge with the device's private key."
  @spec sign(Challenge.t(), binary()) :: t()
  def sign(%Challenge{} = challenge, device_private_key) do
    map = challenge |> Challenge.encode() |> Encoding.sign(device_private_key)
    {:ok, sig} = Encoding.signature(map["sig"])
    %__MODULE__{challenge: challenge, sig: sig}
  end

  @doc "Read a proof from its JSON map: the challenge's fields and `sig`."
  @spec decode(term()) :: {:ok, t()} | {:error, Encoding.reason() | :wrong_protocol}
  def decode(map) when is_map(map) and not is_struct(map) do
    with {:ok, challenge} <- Challenge.decode(Map.delete(map, "sig")),
         {:ok, sig} <- sig(map) do
      {:ok, %__MODULE__{challenge: challenge, sig: sig}}
    end
  end

  def decode(_value), do: {:error, {:invalid_field, "proof"}}

  @doc "The JSON map of a proof."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{challenge: challenge, sig: sig}),
    do: Map.put(Challenge.encode(challenge), "sig", Encoding.b64(sig))

  @doc """
  Hold a proof to the challenge `held` for this connection at `now`
  (milliseconds, the home's clock): `{:challenge_mismatch, field}` for the
  first field that differs, `:bad_signature` when the held device key did
  not sign it, `:expired` at or after the challenge's expiry.
  """
  @spec verify(t() | map(), Challenge.t(), non_neg_integer()) ::
          :ok
          | {:error,
             {:challenge_mismatch, atom()}
             | :bad_signature
             | :expired
             | Encoding.reason()
             | :wrong_protocol}
  def verify(proof, %Challenge{} = held, now) when is_integer(now) do
    with {:ok, proof} <- reread(proof),
         :ok <- same(proof.challenge, held),
         :ok <- signed(proof, held.device_key) do
      if now >= held.expires_at, do: {:error, :expired}, else: :ok
    end
  end

  defp reread(%__MODULE__{} = proof), do: proof |> encode() |> decode()
  defp reread(map), do: decode(map)

  defp same(presented, held) do
    case Enum.find(@compared, &(Map.fetch!(presented, &1) != Map.fetch!(held, &1))) do
      nil -> :ok
      field -> {:error, {:challenge_mismatch, field}}
    end
  end

  defp signed(proof, device_key) do
    if Encoding.verify(encode(proof), device_key), do: :ok, else: {:error, :bad_signature}
  end

  defp sig(map) when not is_map_key(map, "sig"), do: {:error, {:missing_field, "sig"}}

  defp sig(map) do
    case Encoding.signature(Map.get(map, "sig")) do
      {:ok, sig} -> {:ok, sig}
      :error -> {:error, {:invalid_field, "sig"}}
    end
  end
end
