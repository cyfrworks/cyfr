# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.DeviceCert do
  @moduledoc """
  A device certificate, `cyfr-device-cert/v2`: a CYFR's own word that a
  connected device is admitted there, for one athanor and a short time.
  `tests/fixtures/device_cert.json` holds its vectors, beside the
  challenge and proof of the connection purposes
  (`Prima.DeviceCert.Challenge`, `Prima.DeviceCert.Proof`);
  `tests/fixtures/device_unlock.json` holds those of the protected
  device's enrollment, unlock, confirmation and lock, and of the storage
  report (`Prima.DeviceCert.Storage`).

  A certificate carries the protocol string, the device key's `kid` as the
  account's log lists it, the client id, the account's `identifier`,
  `head`, the hash of the account's head the certificate was issued under,
  the athanor, `audience`, the issuing CYFR's origin, a not-before and an
  expiry in Unix milliseconds, and `sig`, the Ed25519 signature of that
  CYFR's installation key. Only the CYFR that issued it verifies it, with
  the public half it holds; nothing else ever reads one.

  `verify/3` refuses a certificate whose `head` is not the head its
  paired-client row names, and checks expiry strictly on the CYFR's
  clock: at or after `expires_at` a certificate is refused, whatever the
  tolerance. The clock tolerance applies to `not_before` alone, so it
  never extends a certificate's lifetime. A certificate is not in the
  account's log.
  """

  alias Prima.Identity.Encoding

  @protocol "cyfr-device-cert/v2"
  @required ~w(protocol kid client_id identifier head athanor audience not_before expires_at)

  @type t :: %__MODULE__{
          kid: String.t(),
          client_id: String.t(),
          identifier: String.t(),
          head: String.t(),
          athanor: String.t(),
          audience: String.t(),
          not_before: non_neg_integer(),
          expires_at: non_neg_integer(),
          sig: binary() | nil
        }

  @type reason ::
          Encoding.reason()
          | :wrong_protocol
          | :bad_signature
          | :wrong_audience
          | :stale_head
          | :not_yet_valid
          | :expired

  @enforce_keys [
    :kid,
    :client_id,
    :identifier,
    :head,
    :athanor,
    :audience,
    :not_before,
    :expires_at
  ]
  defstruct [
    :kid,
    :client_id,
    :identifier,
    :head,
    :athanor,
    :audience,
    :not_before,
    :expires_at,
    sig: nil
  ]

  @doc "The protocol string a certificate carries."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc """
  An unsigned certificate from its fields (atom keys). Sign it with
  `sign/2` under the CYFR's installation key.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, reason()}
  def new(attrs) do
    attrs = Map.new(attrs)

    %{
      "protocol" => @protocol,
      "kid" => attrs[:kid],
      "client_id" => attrs[:client_id],
      "identifier" => attrs[:identifier],
      "head" => attrs[:head],
      "athanor" => attrs[:athanor],
      "audience" => attrs[:audience],
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
      "kid" => cert.kid,
      "client_id" => cert.client_id,
      "identifier" => cert.identifier,
      "head" => cert.head,
      "athanor" => cert.athanor,
      "audience" => cert.audience,
      "not_before" => cert.not_before,
      "expires_at" => cert.expires_at,
      "sig" => cert.sig && Encoding.b64(cert.sig)
    })
  end

  @doc "Sign a certificate with the CYFR's installation private key."
  @spec sign(t(), binary()) :: t()
  def sign(%__MODULE__{} = cert, installation_private_key) do
    map = cert |> Map.put(:sig, nil) |> encode() |> Encoding.sign(installation_private_key)
    {:ok, sig} = Encoding.signature(map["sig"])
    %{cert | sig: sig}
  end

  @doc """
  Check a certificate presented at `opts[:home]` under the public half of
  the installation key that CYFR holds, and answer it.

  `opts`: `:home`, the CYFR's origin; `:head`, the head the certificate's
  paired-client row names; `:now`, the CYFR's clock in milliseconds; and
  `:skew`, the clock tolerance in milliseconds, which applies to
  `not_before` only. Refusals, in the order checked: a malformed
  certificate, `:bad_signature`, `:wrong_audience`, `:stale_head`,
  `:not_yet_valid`, and `:expired` at or after `expires_at`.
  """
  @spec verify(t() | map(), binary(), keyword()) :: {:ok, t()} | {:error, reason()}
  def verify(cert, installation_key, opts) do
    home = Keyword.fetch!(opts, :home)
    head = Keyword.fetch!(opts, :head)
    now = Keyword.fetch!(opts, :now)
    skew = Keyword.fetch!(opts, :skew)

    with {:ok, cert} <- reread(cert),
         :ok <- signed(cert, installation_key),
         :ok <- same(cert.audience, home, :wrong_audience),
         :ok <- same(cert.head, head, :stale_head),
         :ok <- window(cert, now, skew) do
      {:ok, cert}
    end
  end

  defp reread(%__MODULE__{} = cert), do: cert |> encode() |> decode()
  defp reread(map), do: decode(map)

  defp signed(cert, installation_key) do
    if Encoding.verify(encode(cert), installation_key), do: :ok, else: {:error, :bad_signature}
  end

  defp same(value, value, _reason), do: :ok
  defp same(_value, _expected, reason), do: {:error, reason}

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
         {:ok, kid} <- Encoding.check(map, "kid", &Encoding.digest?/1),
         {:ok, client_id} <- Encoding.check(map, "client_id", &Encoding.id?/1),
         {:ok, identifier} <- Encoding.check(map, "identifier", &Encoding.identifier?/1),
         {:ok, head} <- Encoding.check(map, "head", &Encoding.digest?/1),
         {:ok, athanor} <- Encoding.check(map, "athanor", &Encoding.id?/1),
         {:ok, audience} <- Encoding.check(map, "audience", &Encoding.home?/1),
         {:ok, not_before} <- Encoding.check(map, "not_before", &Encoding.ms?/1),
         {:ok, expires_at} <-
           Encoding.check(map, "expires_at", &(Encoding.ms?(&1) and &1 > not_before)),
         {:ok, sig} <- signature(map, signed?) do
      {:ok,
       %__MODULE__{
         kid: kid,
         client_id: client_id,
         identifier: identifier,
         head: head,
         athanor: athanor,
         audience: audience,
         not_before: not_before,
         expires_at: expires_at,
         sig: sig
       }}
    end
  end

  defp read(_value, _signed?), do: {:error, {:invalid_field, "certificate"}}

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
  The challenge a home issues a device. Every challenge carries the
  protocol string `cyfr-device-proof/v1`, the domain of the proof that
  signs it (`Prima.DeviceCert.Proof`), a `purpose`, the home, the athanor,
  the client id and the device public key that must answer. A fresh
  purpose adds a 32-byte random nonce the issuer draws and an expiry 60
  seconds after issue on the issuing home's clock (`lifetime_ms/0`).
  Each purpose takes exactly its fields, every one required:

    * `connect` — a paired client proving its key on a new connection.
    * `renew` — a paired client proving the key its paired-client row
      stores, before a replacement certificate is issued.
    * `pair` — pairing completion proving the key it submits, bound to
      the prospective client id the invitation reserved.
    * `enroll` — a protected device enrolling its key at an admission:
      `admission` (`setup`, `restore`, `invitation` or `open`) and the enrollment's
      `request_id`, with the athanor and client id the home reserved.
    * `unlock` — a protected device unlocking: `session_id`, the one
      session the ticket exchange will create.
    * `confirm` — a protected device confirming one pending change:
      `ref`, its public ref, and `digest`, the stored record's
      `Prima.Confirmation.digest/1`. Its expiry is capped by the record's.
    * `lock` — the retirement of exactly the session `session_id` names.
      It has no nonce and no expiry: it can only end one uniquely named
      session, so the device signs it at unlock and submits it whenever it
      locks. `Prima.DeviceCert.Proof.verify_lock/2` is its one verifier.
    * `pin_reset` — a device whose PIN its home evaluates, after it
      unwrapped its key, clearing that evaluator's wrong attempts:
      `revision`, the counter revision the evaluation charged, with the
      evaluation's own nonce and expiry (`Prima.DevicePin`).

  `tests/fixtures/device_cert.json` holds the first three purposes'
  vectors, `tests/fixtures/device_unlock.json` the next four's and
  `tests/fixtures/device_pin.json` the last one's. A fresh
  challenge is held for one connection, completion or exchange and
  consumed at most once; a disconnect discards it. Because it binds
  purpose, home, athanor, client and device key, a proof made for one
  never verifies as another's: a proof of one purpose is refused for
  every other, and a proof for one client, home, athanor or key is
  refused for every other.
  """

  alias Prima.Identity.Encoding

  @protocol "cyfr-device-proof/v1"
  @lifetime_ms 60_000
  @nonce_bytes 32
  @binding ~w(protocol purpose home athanor client_id device_key)
  @freshness ~w(nonce expires_at)
  @purpose_fields %{
    connect: [],
    renew: [],
    pair: [],
    enroll: [:admission, :request_id],
    unlock: [:session_id],
    confirm: [:ref, :digest],
    lock: [:session_id],
    pin_reset: [:revision]
  }
  @purposes Map.new(@purpose_fields, fn {purpose, _fields} ->
              {Atom.to_string(purpose), purpose}
            end)
  @fresh [:connect, :renew, :pair, :enroll, :unlock, :confirm, :pin_reset]
  @admissions %{
    "setup" => :setup,
    "restore" => :restore,
    "invitation" => :invitation,
    "open" => :open
  }

  @type purpose ::
          :connect | :renew | :pair | :enroll | :unlock | :confirm | :lock | :pin_reset
  @type admission :: :setup | :restore | :invitation | :open
  @type t :: %__MODULE__{
          purpose: purpose(),
          home: String.t(),
          athanor: String.t(),
          client_id: String.t(),
          device_key: binary(),
          nonce: binary() | nil,
          expires_at: non_neg_integer() | nil,
          admission: admission() | nil,
          request_id: String.t() | nil,
          session_id: String.t() | nil,
          ref: String.t() | nil,
          digest: String.t() | nil,
          revision: non_neg_integer() | nil
        }

  @enforce_keys [:purpose, :home, :athanor, :client_id, :device_key]
  defstruct [
    :purpose,
    :home,
    :athanor,
    :client_id,
    :device_key,
    nonce: nil,
    expires_at: nil,
    admission: nil,
    request_id: nil,
    session_id: nil,
    ref: nil,
    digest: nil,
    revision: nil
  ]

  @doc "The protocol string a challenge and its proof carry."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc "How long a fresh challenge lives on the issuing home's clock, in milliseconds."
  @spec lifetime_ms() :: pos_integer()
  def lifetime_ms, do: @lifetime_ms

  @doc "The length of a challenge nonce, in bytes."
  @spec nonce_bytes() :: pos_integer()
  def nonce_bytes, do: @nonce_bytes

  @doc "Every purpose, the three pairing ones first."
  @spec purposes() :: [purpose()]
  def purposes, do: [:connect, :renew, :pair, :enroll, :unlock, :confirm, :lock, :pin_reset]

  @doc "The fields a purpose adds to the binding (and, when fresh, the nonce and expiry)."
  @spec purpose_fields(purpose()) :: [atom()]
  def purpose_fields(purpose), do: Map.fetch!(@purpose_fields, purpose)

  @doc "Whether a purpose carries a nonce and an expiry; only `lock` does not."
  @spec fresh?(purpose()) :: boolean()
  def fresh?(purpose), do: purpose in @fresh

  @doc """
  A challenge from its attributes: `:purpose`, `:home`, `:athanor`,
  `:client_id`, `:device_key` (raw bytes) and the purpose's own fields
  (`:admission` as an atom). A fresh purpose takes `:now` (milliseconds)
  and the `:nonce` its issuer drew, and expires `lifetime_ms/0` after
  `:now`, or at `:not_after` when that is sooner (a confirmation's own
  expiry).
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Encoding.reason() | :wrong_protocol}
  def new(attrs) do
    attrs = Map.new(attrs)
    purpose = if is_atom(attrs[:purpose]), do: to_string(attrs[:purpose]), else: attrs[:purpose]

    fields =
      %{
        "protocol" => @protocol,
        "purpose" => purpose,
        "home" => attrs[:home],
        "athanor" => attrs[:athanor],
        "client_id" => attrs[:client_id],
        "device_key" => is_binary(attrs[:device_key]) && Encoding.b64(attrs[:device_key])
      }

    own =
      for field <- Map.get(@purpose_fields, Map.get(@purposes, purpose), []), into: %{} do
        value = attrs[field]
        {Atom.to_string(field), if(is_atom(value) and value, do: to_string(value), else: value)}
      end

    fresh =
      if Map.get(@purposes, purpose) in @fresh do
        %{
          "nonce" => is_binary(attrs[:nonce]) && Encoding.b64(attrs[:nonce]),
          "expires_at" => expiry(attrs[:now], attrs[:not_after])
        }
      else
        %{}
      end

    fields |> Map.merge(own) |> Map.merge(fresh) |> decode()
  end

  defp expiry(now, nil) when is_integer(now), do: now + @lifetime_ms
  defp expiry(now, cap) when is_integer(now) and is_integer(cap), do: min(now + @lifetime_ms, cap)
  defp expiry(_now, _cap), do: false

  @doc "Read a challenge from its JSON map: exactly its purpose's fields."
  @spec decode(term()) :: {:ok, t()} | {:error, Encoding.reason() | :wrong_protocol}
  def decode(map) when is_map(map) and not is_struct(map) do
    with :ok <- Encoding.protocol(map, @protocol),
         {:ok, purpose} <- purpose(map),
         :ok <- Encoding.fields(map, required(purpose), []),
         {:ok, home} <- Encoding.check(map, "home", &Encoding.home?/1),
         {:ok, athanor} <- Encoding.check(map, "athanor", &Encoding.id?/1),
         {:ok, client_id} <- Encoding.check(map, "client_id", &Encoding.id?/1),
         {:ok, device_key} <- Encoding.binary(map, "device_key", Encoding.key_bytes()),
         {:ok, fresh} <- fresh(map, purpose),
         {:ok, own} <- own(map, purpose) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(
           %{
             purpose: purpose,
             home: home,
             athanor: athanor,
             client_id: client_id,
             device_key: device_key
           },
           Map.merge(fresh, own)
         )
       )}
    end
  end

  def decode(_value), do: {:error, {:invalid_field, "challenge"}}

  @doc "The JSON map of a challenge: exactly what its proof signs."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{purpose: purpose} = challenge) do
    binding = %{
      "protocol" => @protocol,
      "purpose" => Atom.to_string(purpose),
      "home" => challenge.home,
      "athanor" => challenge.athanor,
      "client_id" => challenge.client_id,
      "device_key" => Encoding.b64(challenge.device_key)
    }

    fresh =
      if purpose in @fresh,
        do: %{"nonce" => Encoding.b64(challenge.nonce), "expires_at" => challenge.expires_at},
        else: %{}

    own =
      for field <- Map.fetch!(@purpose_fields, purpose), into: %{} do
        value = Map.fetch!(challenge, field)
        {Atom.to_string(field), if(is_atom(value), do: Atom.to_string(value), else: value)}
      end

    binding |> Map.merge(fresh) |> Map.merge(own)
  end

  defp required(purpose) do
    @binding ++
      if(purpose in @fresh, do: @freshness, else: []) ++
      Enum.map(Map.fetch!(@purpose_fields, purpose), &Atom.to_string/1)
  end

  defp purpose(map) when not is_map_key(map, "purpose"), do: {:error, {:missing_field, "purpose"}}

  defp purpose(map) do
    case Map.fetch(@purposes, map["purpose"]) do
      {:ok, purpose} -> {:ok, purpose}
      :error -> {:error, {:invalid_field, "purpose"}}
    end
  end

  defp fresh(map, purpose) when purpose in @fresh do
    with {:ok, nonce} <- Encoding.binary(map, "nonce", @nonce_bytes),
         {:ok, expires_at} <- Encoding.check(map, "expires_at", &Encoding.ms?/1),
         do: {:ok, %{nonce: nonce, expires_at: expires_at}}
  end

  defp fresh(_map, _lock), do: {:ok, %{}}

  defp own(map, purpose) do
    Enum.reduce_while(Map.fetch!(@purpose_fields, purpose), {:ok, %{}}, fn field, {:ok, acc} ->
      case own_field(field, map[Atom.to_string(field)]) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        :error -> {:halt, {:error, {:invalid_field, Atom.to_string(field)}}}
      end
    end)
  end

  defp own_field(:admission, value), do: Map.fetch(@admissions, value)
  defp own_field(:ref, value), do: ok_if(Prima.Confirmation.ref?(value), value)
  defp own_field(:digest, value), do: ok_if(Encoding.digest?(value), value)
  defp own_field(:revision, value), do: ok_if(Encoding.ms?(value), value)
  defp own_field(_id, value), do: ok_if(Encoding.id?(value), value)

  defp ok_if(true, value), do: {:ok, value}
  defp ok_if(false, _value), do: :error
end

defmodule Prima.DeviceCert.Proof do
  @moduledoc """
  A device's proof of possession: the exact challenge it was issued, and
  the device key's signature over it (`sig`, over the challenge's JCS
  bytes). `verify/3` holds a fresh purpose's proof to the challenge the
  home holds, field by field, then the signature under the held
  challenge's device key, then its expiry. `verify_lock/2` holds a `lock`
  proof to the lock challenge the home builds from the session it would
  retire, with no clock: only `lock` has no freshness, and `verify/3`
  never accepts it.
  """

  alias Prima.DeviceCert.Challenge
  alias Prima.Identity.Encoding

  @type t :: %__MODULE__{challenge: Challenge.t(), sig: binary()}
  @enforce_keys [:challenge, :sig]
  defstruct [:challenge, :sig]

  @type refusal ::
          {:challenge_mismatch, atom()}
          | :no_challenge
          | :wrong_purpose
          | :bad_signature
          | :expired
          | Encoding.reason()
          | :wrong_protocol

  @compared [
    :purpose,
    :home,
    :athanor,
    :client_id,
    :device_key,
    :nonce,
    :expires_at,
    :admission,
    :request_id,
    :session_id,
    :ref,
    :digest,
    :revision
  ]

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
  Hold a proof to the fresh challenge `held` at `now` (milliseconds, the
  home's clock): `:no_challenge` when the home holds none (never issued,
  or already consumed), `{:challenge_mismatch, field}` for the first field
  that differs, `:bad_signature` when the held device key did not sign it,
  `:expired` at or after the challenge's expiry. A held `lock` challenge
  is `:wrong_purpose` here: `verify_lock/2` is its verifier.
  """
  @spec verify(t() | map(), Challenge.t() | nil, non_neg_integer()) :: :ok | {:error, refusal()}
  def verify(proof, held, now) when is_integer(now) do
    with {:ok, proof} <- reread(proof),
         {:ok, held} <- held(held, :fresh),
         :ok <- same(proof.challenge, held),
         :ok <- signed(proof, held.device_key) do
      if now >= held.expires_at, do: {:error, :expired}, else: :ok
    end
  end

  @doc """
  Hold a `lock` proof to the lock challenge `held` the home built for the
  session it would retire: `{:challenge_mismatch, field}` for the first
  field that differs, `:bad_signature` when the held device key did not
  sign it. No clock: a lock proof stays valid for its one session. A held
  challenge of any other purpose is `:wrong_purpose`.
  """
  @spec verify_lock(t() | map(), Challenge.t()) :: :ok | {:error, refusal()}
  def verify_lock(proof, held) do
    with {:ok, proof} <- reread(proof),
         {:ok, held} <- held(held, :lock),
         :ok <- same(proof.challenge, held),
         do: signed(proof, held.device_key)
  end

  defp held(nil, _kind), do: {:error, :no_challenge}
  defp held(%Challenge{purpose: :lock} = held, :lock), do: {:ok, held}
  defp held(%Challenge{purpose: :lock}, :fresh), do: {:error, :wrong_purpose}
  defp held(%Challenge{} = _held, :lock), do: {:error, :wrong_purpose}
  defp held(%Challenge{} = held, :fresh), do: {:ok, held}

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

defmodule Prima.DeviceCert.Storage do
  @moduledoc """
  What a protected device reports of its disks, inside the `capabilities`
  it announces (`Prima.Device`): at most one of `root_encrypted`,
  `root_unencrypted` and `root_unknown`, and at most one of
  `data_encrypted`, `data_unencrypted` and `data_unknown`, beside any other
  capability. A volume it names nothing for is unknown; two words for one
  volume contradict each other and the report is refused. The report is
  information a person reads, never an input to a decision.
  `tests/fixtures/device_unlock.json` (`exchange.capabilities`) holds its
  vectors.
  """

  @volumes [:root, :data]
  @states [:encrypted, :unencrypted, :unknown]
  @words for volume <- @volumes,
             state <- @states,
             into: %{},
             do: {"#{volume}_#{state}", {volume, state}}

  @type state :: :encrypted | :unencrypted | :unknown
  @type t :: %{root: state(), data: state()}

  @doc "Every storage word, by volume."
  @spec words() :: %{root: [String.t()], data: [String.t()]}
  def words, do: Map.new(@volumes, &{&1, Enum.map(@states, fn s -> "#{&1}_#{s}" end)})

  @doc "Read the storage report in a list of capability names."
  @spec read([String.t()]) :: {:ok, t()} | {:error, :contradictory}
  def read(capabilities) when is_list(capabilities) do
    named = for name <- capabilities, Map.has_key?(@words, name), do: Map.fetch!(@words, name)

    if Enum.uniq_by(named, &elem(&1, 0)) == named,
      do: {:ok, Map.merge(%{root: :unknown, data: :unknown}, Map.new(named))},
      else: {:error, :contradictory}
  end
end
