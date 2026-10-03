# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Carry do
  @moduledoc """
  The sign-in carry: what a person's browser takes, in a URL fragment, from
  their signing home to one destination home and back. It is independent of
  the client's saved addresses, and grants nothing by itself: admission
  stays the destination's decision. `tests/fixtures/carry.json` holds its
  vectors.

    * `Prima.Carry.Envelope` is what the signing home signs with the live
      key for one pending action: the protocol, the action id, the
      identifier, the source and destination homes, the fixed return URL on
      the source (`return_url/1`, its `/carry` path), operation `join`, the
      payload's digest, the `key_epoch` and a timestamp.
    * `Prima.Carry.Return` is the navigation outcome the destination sends
      back to the source's `/carry`. It is unsigned and grants no
      membership or session.

  A fragment (`fragment/2`, `parse_fragment/1`) is the unpadded base64url
  of the JCS bytes of `{"envelope": ..., "payload": ...}`. The payload is a
  JSON object of at most 8 KiB in its JCS form and the whole fragment at
  most 16 KiB; anything larger is `:carry_too_large`, never truncated, and
  there is no multipart form. A fragment is checked against its length
  before it is decoded.
  """

  alias Prima.Carry.Envelope
  alias Prima.Identity.Encoding

  @protocol "cyfr-carry/v1"
  @max_payload_bytes 8192
  @max_fragment_bytes 16_384
  @return_path "/carry"

  @doc "The protocol string an envelope and a return carry."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc "The largest payload, in bytes of its JCS form."
  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: @max_payload_bytes

  @doc "The largest fragment, in bytes."
  @spec max_fragment_bytes() :: pos_integer()
  def max_fragment_bytes, do: @max_fragment_bytes

  @doc "The one return URL of a source home: its `/carry` path."
  @spec return_url(String.t()) :: String.t()
  def return_url(source), do: source <> @return_path

  @doc "A payload's digest, `sha256:<hex>` over its JCS bytes, once it is within the bound."
  @spec payload_digest(term()) ::
          {:ok, String.t()} | {:error, :carry_too_large | Encoding.reason()}
  def payload_digest(payload) do
    with {:ok, bytes} <- payload_bytes(payload), do: {:ok, Prima.Digest.sha256(bytes)}
  end

  @doc "The fragment that carries a signed envelope and its payload."
  @spec fragment(Envelope.t(), map()) ::
          {:ok, String.t()} | {:error, :carry_too_large | Encoding.reason()}
  def fragment(%Envelope{} = envelope, payload) do
    with {:ok, _bytes} <- payload_bytes(payload) do
      %{"envelope" => Envelope.encode(envelope), "payload" => payload}
      |> Encoding.jcs!()
      |> Encoding.b64()
      |> bounded()
    end
  end

  @doc """
  Read a fragment: its length first, then its encoding, then the payload's
  bound and the envelope's shape. The envelope is not yet verified; that
  is `Prima.Carry.Envelope.verify/4`'s, against the payload's digest.
  """
  @spec parse_fragment(term()) ::
          {:ok, %{envelope: Envelope.t(), payload: map()}}
          | {:error, :carry_too_large | :invalid_fragment | Envelope.reason()}
  def parse_fragment(fragment) when is_binary(fragment) do
    with {:ok, fragment} <- bounded(fragment),
         {:ok, object} <- decode_object(fragment),
         {:ok, envelope, payload} <- split(object),
         {:ok, _bytes} <- payload_bytes(payload),
         {:ok, envelope} <- Envelope.decode(envelope) do
      {:ok, %{envelope: envelope, payload: payload}}
    else
      {:error, {:invalid_field, "payload"}} -> {:error, :invalid_fragment}
      {:error, _reason} = error -> error
    end
  end

  def parse_fragment(_fragment), do: {:error, :invalid_fragment}

  defp split(%{"envelope" => envelope, "payload" => payload} = object) when map_size(object) == 2,
    do: {:ok, envelope, payload}

  defp split(_object), do: {:error, :invalid_fragment}

  @doc false
  @spec decode_object(String.t()) :: {:ok, map()} | {:error, :invalid_fragment}
  def decode_object(fragment) do
    with {:ok, json} <- Base.url_decode64(fragment, padding: false),
         ^fragment <- Encoding.b64(json),
         {:ok, %{} = object} <- Prima.Json.decode(json) do
      {:ok, object}
    else
      _ -> {:error, :invalid_fragment}
    end
  end

  @doc false
  @spec bounded(String.t()) :: {:ok, String.t()} | {:error, :carry_too_large}
  def bounded(fragment) do
    if byte_size(fragment) > @max_fragment_bytes,
      do: {:error, :carry_too_large},
      else: {:ok, fragment}
  end

  defp payload_bytes(payload) when is_map(payload) and not is_struct(payload) do
    case Encoding.jcs(payload) do
      {:ok, bytes} when byte_size(bytes) > @max_payload_bytes -> {:error, :carry_too_large}
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, {:invalid_field, "payload"}}
    end
  end

  defp payload_bytes(_payload), do: {:error, {:invalid_field, "payload"}}
end

defmodule Prima.Carry.Envelope do
  @moduledoc """
  What a person's signing home signs, with their live key, for one pending
  carry action: `cyfr-carry/v1`, the action id, the person's identifier,
  the source home, the destination home, the return URL (always the
  source's `/carry`, `Prima.Carry.return_url/1`), the operation (`join`,
  the only one), the payload's digest, the `key_epoch` of the head it was
  signed under, and `issued_at` in Unix milliseconds.

  `verify/4` is the receiver's check under the person's current head.
  `check_replay/2` is its rule for an action id it has already answered:
  the exact same envelope returns the acknowledgment it recorded, and
  other bytes under that action id are refused.
  """

  alias Prima.Carry
  alias Prima.Identity.{Encoding, State}

  @operations %{"join" => :join}
  @required ~w(protocol action_id identifier source destination return_url operation payload_digest key_epoch issued_at)

  @type t :: %__MODULE__{
          action_id: String.t(),
          identifier: String.t(),
          source: String.t(),
          destination: String.t(),
          return_url: String.t(),
          operation: :join,
          payload_digest: String.t(),
          key_epoch: String.t(),
          issued_at: non_neg_integer(),
          sig: binary() | nil
        }

  @type reason ::
          Encoding.reason()
          | :wrong_protocol
          | :invalid_return_url
          | :wrong_identifier
          | :stale_key_epoch
          | :bad_signature
          | :wrong_destination
          | :wrong_action
          | :wrong_payload
          | :not_yet_valid
          | :stale

  @enforce_keys [
    :action_id,
    :identifier,
    :source,
    :destination,
    :return_url,
    :operation,
    :payload_digest,
    :key_epoch,
    :issued_at
  ]
  defstruct [
    :action_id,
    :identifier,
    :source,
    :destination,
    :return_url,
    :operation,
    :payload_digest,
    :key_epoch,
    :issued_at,
    sig: nil
  ]

  @doc "The operations a carry may serve: `join` alone."
  @spec operations() :: [:join]
  def operations, do: [:join]

  @doc """
  An unsigned envelope from its fields (atom keys). The return URL is the
  source's `/carry`, and the operation `join`. Sign it with `sign/2` under
  the person's live private key.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, reason()}
  def new(attrs) do
    attrs = Map.new(attrs)
    source = attrs[:source]

    %{
      "protocol" => Carry.protocol(),
      "action_id" => attrs[:action_id],
      "identifier" => attrs[:identifier],
      "source" => source,
      "destination" => attrs[:destination],
      "return_url" => is_binary(source) && Carry.return_url(source),
      "operation" => "join",
      "payload_digest" => attrs[:payload_digest],
      "key_epoch" => attrs[:key_epoch],
      "issued_at" => attrs[:issued_at]
    }
    |> Encoding.compact()
    |> read(false)
  end

  @doc "Read a signed envelope from its JSON map."
  @spec decode(term()) :: {:ok, t()} | {:error, reason()}
  def decode(map), do: read(map, true)

  @doc "The JSON map of an envelope; `sig` is absent while unsigned."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = envelope) do
    Encoding.compact(%{
      "protocol" => Carry.protocol(),
      "action_id" => envelope.action_id,
      "identifier" => envelope.identifier,
      "source" => envelope.source,
      "destination" => envelope.destination,
      "return_url" => envelope.return_url,
      "operation" => Atom.to_string(envelope.operation),
      "payload_digest" => envelope.payload_digest,
      "key_epoch" => envelope.key_epoch,
      "issued_at" => envelope.issued_at,
      "sig" => envelope.sig && Encoding.b64(envelope.sig)
    })
  end

  @doc "Sign an envelope with the person's live private key."
  @spec sign(t(), binary()) :: t()
  def sign(%__MODULE__{} = envelope, live_private_key) do
    map = envelope |> Map.put(:sig, nil) |> encode() |> Encoding.sign(live_private_key)
    {:ok, sig} = Encoding.signature(map["sig"])
    %{envelope | sig: sig}
  end

  @doc "An envelope's digest, over its JCS bytes, `sig` included: what a receiver records for its action id."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = envelope),
    do: envelope |> encode() |> Encoding.jcs!() |> Prima.Digest.sha256()

  @doc """
  The receiver's check of an envelope under the person's current head
  (`state`, verified and fresh), against what it expects and its clock.

  `expected`: `:destination` (the receiver itself), `:action_id` and
  `:payload_digest` (`Prima.Carry.payload_digest/1` of the payload that
  came with it). `clock`: `:now` in milliseconds, `:skew`, the clock
  tolerance, and `:max_age`, how long after `issued_at` the envelope is
  still taken, both in milliseconds. Refusals, in the order checked: a
  malformed envelope (a return URL that is not the source's `/carry`
  among them), `:wrong_identifier`, `:stale_key_epoch` (signed under a
  head the directory has moved past), `:bad_signature`,
  `:wrong_destination`, `:wrong_action`, `:wrong_payload`,
  `:not_yet_valid` (issued more than `skew` ahead of `now`) and `:stale`
  (older than `max_age` plus `skew`).
  """
  @spec verify(t() | map(), State.t(), keyword() | map(), keyword()) ::
          {:ok, t()} | {:error, reason()}
  def verify(envelope, %State{} = state, expected, clock) do
    expected = Map.new(expected)

    with {:ok, envelope} <- reread(envelope),
         :ok <- same(envelope.identifier, state.identifier, :wrong_identifier),
         :ok <- same(envelope.key_epoch, state.key_epoch, :stale_key_epoch),
         :ok <- signed(envelope, state.live_key),
         :ok <- same(envelope.destination, Map.fetch!(expected, :destination), :wrong_destination),
         :ok <- same(envelope.action_id, Map.fetch!(expected, :action_id), :wrong_action),
         :ok <-
           same(envelope.payload_digest, Map.fetch!(expected, :payload_digest), :wrong_payload),
         :ok <- timely(envelope.issued_at, clock) do
      {:ok, envelope}
    end
  end

  @doc """
  What a receiver answers for an envelope under an action id it may have
  answered before. `recorded` is nil, or what it recorded for that action
  id: `%{digest: Prima.Carry.Envelope.digest/1 of the envelope it
  accepted, ack: its acknowledgment}`. The same envelope again returns
  `{:duplicate, ack}`; other bytes are `:action_reused`.
  """
  @spec check_replay(t(), %{digest: String.t(), ack: term()} | nil) ::
          :fresh | {:duplicate, term()} | {:error, :action_reused}
  def check_replay(%__MODULE__{}, nil), do: :fresh

  def check_replay(%__MODULE__{} = envelope, %{digest: digest, ack: ack}) do
    if digest(envelope) == digest, do: {:duplicate, ack}, else: {:error, :action_reused}
  end

  defp reread(%__MODULE__{} = envelope), do: envelope |> encode() |> decode()
  defp reread(map), do: decode(map)

  defp same(value, value, _reason), do: :ok
  defp same(_value, _expected, reason), do: {:error, reason}

  defp signed(envelope, live_key) do
    if Encoding.verify(encode(envelope), live_key), do: :ok, else: {:error, :bad_signature}
  end

  defp timely(issued_at, clock) do
    now = Keyword.fetch!(clock, :now)
    skew = Keyword.fetch!(clock, :skew)
    max_age = Keyword.fetch!(clock, :max_age)

    cond do
      issued_at > now + skew -> {:error, :not_yet_valid}
      now > issued_at + max_age + skew -> {:error, :stale}
      true -> :ok
    end
  end

  defp read(map, signed?) when is_map(map) and not is_struct(map) do
    sig = if signed?, do: ["sig"], else: []

    with :ok <- Encoding.protocol(map, Carry.protocol()),
         :ok <- Encoding.fields(map, @required ++ sig, []),
         {:ok, action_id} <- Encoding.check(map, "action_id", &Encoding.id?/1),
         {:ok, identifier} <- Encoding.check(map, "identifier", &Encoding.identifier?/1),
         {:ok, source} <- Encoding.check(map, "source", &Encoding.home?/1),
         {:ok, destination} <- Encoding.check(map, "destination", &Encoding.home?/1),
         {:ok, return_url} <- return_url(map, source),
         {:ok, operation} <- operation(map),
         {:ok, digest} <- Encoding.check(map, "payload_digest", &Encoding.digest?/1),
         {:ok, key_epoch} <- Encoding.check(map, "key_epoch", &Encoding.digest?/1),
         {:ok, issued_at} <- Encoding.check(map, "issued_at", &Encoding.ms?/1),
         {:ok, sig} <- signature(map, signed?) do
      {:ok,
       %__MODULE__{
         action_id: action_id,
         identifier: identifier,
         source: source,
         destination: destination,
         return_url: return_url,
         operation: operation,
         payload_digest: digest,
         key_epoch: key_epoch,
         issued_at: issued_at,
         sig: sig
       }}
    end
  end

  defp read(_value, _signed?), do: {:error, {:invalid_field, "envelope"}}

  # No return address comes from anywhere but the signed source: the one
  # return URL is the source's `/carry`.
  defp return_url(map, source) do
    if map["return_url"] == Carry.return_url(source),
      do: {:ok, map["return_url"]},
      else: {:error, :invalid_return_url}
  end

  defp operation(map) do
    case Map.fetch(@operations, map["operation"]) do
      {:ok, operation} -> {:ok, operation}
      :error -> {:error, {:invalid_field, "operation"}}
    end
  end

  defp signature(_map, false), do: {:ok, nil}

  defp signature(map, true) do
    case Encoding.signature(map["sig"]) do
      {:ok, sig} -> {:ok, sig}
      :error -> {:error, {:invalid_field, "sig"}}
    end
  end
end

defmodule Prima.Carry.Return do
  @moduledoc """
  What a destination sends back to the source's `/carry` once it has
  decided: `cyfr-carry/v1`, the action id, and the navigation `outcome`,
  `admitted` or `refused`. It is unsigned and reports navigation only: it
  grants no membership or session and writes no saved-home entry.

  The source records an action's outcome once. `check_replay/2` is that
  rule: the same outcome again returns what was recorded, and a changed
  outcome under the same action id is refused.
  """

  alias Prima.Carry
  alias Prima.Identity.Encoding

  @outcomes %{"admitted" => :admitted, "refused" => :refused}
  @required ~w(protocol action_id outcome)

  @type outcome :: :admitted | :refused
  @type t :: %__MODULE__{action_id: String.t(), outcome: outcome()}
  @enforce_keys [:action_id, :outcome]
  defstruct [:action_id, :outcome]

  @doc "The navigation outcomes."
  @spec outcomes() :: [outcome()]
  def outcomes, do: [:admitted, :refused]

  @doc "A return from its action id and outcome."
  @spec new(String.t(), outcome()) :: {:ok, t()} | {:error, Encoding.reason()}
  def new(action_id, outcome) when is_atom(outcome),
    do:
      decode(%{
        "protocol" => Carry.protocol(),
        "action_id" => action_id,
        "outcome" => to_string(outcome)
      })

  @doc "Read a return from its JSON map."
  @spec decode(term()) :: {:ok, t()} | {:error, Encoding.reason() | :wrong_protocol}
  def decode(map) when is_map(map) and not is_struct(map) do
    with :ok <- Encoding.protocol(map, Carry.protocol()),
         :ok <- Encoding.fields(map, @required, []),
         {:ok, action_id} <- Encoding.check(map, "action_id", &Encoding.id?/1),
         {:ok, outcome} <- outcome(map) do
      {:ok, %__MODULE__{action_id: action_id, outcome: outcome}}
    end
  end

  def decode(_value), do: {:error, {:invalid_field, "return"}}

  @doc "The JSON map of a return."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = return) do
    %{
      "protocol" => Carry.protocol(),
      "action_id" => return.action_id,
      "outcome" => Atom.to_string(return.outcome)
    }
  end

  @doc "The fragment that carries a return: unpadded base64url of its JCS bytes."
  @spec fragment(t()) :: String.t()
  def fragment(%__MODULE__{} = return),
    do: return |> encode() |> Encoding.jcs!() |> Encoding.b64()

  @doc "Read a return's fragment, its length checked before it is decoded."
  @spec parse_fragment(term()) ::
          {:ok, t()}
          | {:error, :carry_too_large | :invalid_fragment | Encoding.reason() | :wrong_protocol}
  def parse_fragment(fragment) when is_binary(fragment) do
    with {:ok, fragment} <- Carry.bounded(fragment),
         {:ok, object} <- Carry.decode_object(fragment) do
      decode(object)
    end
  end

  def parse_fragment(_fragment), do: {:error, :invalid_fragment}

  @doc """
  What the source answers for a return, given what it recorded for that
  action id (nil when nothing): `:fresh`, `{:duplicate, recorded}` for the
  same outcome, or `:outcome_changed`.
  """
  @spec check_replay(t(), t() | nil) :: :fresh | {:duplicate, t()} | {:error, :outcome_changed}
  def check_replay(%__MODULE__{}, nil), do: :fresh
  def check_replay(%__MODULE__{} = return, %__MODULE__{} = return), do: {:duplicate, return}
  def check_replay(%__MODULE__{}, %__MODULE__{}), do: {:error, :outcome_changed}

  defp outcome(map) do
    case Map.fetch(@outcomes, map["outcome"]) do
      {:ok, outcome} -> {:ok, outcome}
      :error -> {:error, {:invalid_field, "outcome"}}
    end
  end
end
