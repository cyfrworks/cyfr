# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.PersonAssertion do
  @moduledoc """
  The CYFR door's assertion: a person's home, with their live key, vouching
  to one other home (`audience`) for one sign-in. It carries the protocol
  string `cyfr-person-assertion/v1`, the person's `identifier`, the
  audience home, the exact `challenge` that home issued (32 bytes), the
  carry action it serves (`action_id`), the `key_epoch` of the head it was
  signed under, an expiry in Unix milliseconds and the live key's
  signature. `tests/fixtures/person_assertion.json` holds its vectors.

  The transport beside it carries the person's genesis, so the relying home
  can find their directory without asking anyone: `open/1` reads the pair
  and holds the genesis to the assertion's identifier with
  `Prima.Identity.locate/2`, bounded to 16 KiB and hash-checked before any
  network use. `verify/3` then checks the assertion under the current head
  the relying home resolved from that directory.
  """

  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry, State}

  @protocol "cyfr-person-assertion/v1"
  @challenge_bytes 32
  @code_domain "cyfr/sign-in-code/v1"
  @code_alphabet "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @required ~w(protocol identifier audience challenge action_id key_epoch expires_at)

  @type t :: %__MODULE__{
          identifier: String.t(),
          audience: String.t(),
          challenge: binary(),
          action_id: String.t(),
          key_epoch: String.t(),
          expires_at: non_neg_integer(),
          sig: binary() | nil
        }

  @type reason ::
          Encoding.reason()
          | :wrong_protocol
          | :wrong_identifier
          | :stale_key_epoch
          | :bad_signature
          | :wrong_audience
          | :wrong_challenge
          | :wrong_action
          | :expired

  @enforce_keys [:identifier, :audience, :challenge, :action_id, :key_epoch, :expires_at]
  defstruct [:identifier, :audience, :challenge, :action_id, :key_epoch, :expires_at, sig: nil]

  @doc "The protocol string an assertion carries."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc "The length of the audience's challenge, in bytes."
  @spec challenge_bytes() :: pos_integer()
  def challenge_bytes, do: @challenge_bytes

  @doc """
  The short code a person compares between the two homes of one sign-in:
  the relying home shows it for the challenge it issued, and the signing
  home's confirmation preview names it for the challenge it is asked to
  sign over, so a challenge another session substituted shows another
  code.

  It is the first 40 bits of SHA-256 over `"cyfr/sign-in-code/v1"`, a
  zero byte and the 32 raw challenge bytes, written in Crockford base32
  (`0123456789ABCDEFGHJKMNPQRSTVWXYZ`, most significant bits first) as two
  groups of four, `ABCD-EFGH`.
  """
  @spec comparison_code(binary()) :: String.t()
  def comparison_code(challenge)
      when is_binary(challenge) and byte_size(challenge) == @challenge_bytes do
    <<bits::40, _rest::binary>> =
      :crypto.hash(:sha256, [@code_domain, <<0>>, challenge])

    symbols =
      for shift <- [35, 30, 25, 20, 15, 10, 5, 0],
          into: "",
          do: <<:binary.at(@code_alphabet, Bitwise.band(Bitwise.bsr(bits, shift), 31))>>

    binary_part(symbols, 0, 4) <> "-" <> binary_part(symbols, 4, 4)
  end

  @doc """
  An unsigned assertion from its fields (atom keys; the challenge as raw
  bytes). Sign it with `sign/2` under the person's live private key.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, reason()}
  def new(attrs) do
    attrs = Map.new(attrs)

    %{
      "protocol" => @protocol,
      "identifier" => attrs[:identifier],
      "audience" => attrs[:audience],
      "challenge" => is_binary(attrs[:challenge]) && Encoding.b64(attrs[:challenge]),
      "action_id" => attrs[:action_id],
      "key_epoch" => attrs[:key_epoch],
      "expires_at" => attrs[:expires_at]
    }
    |> Encoding.compact()
    |> read(false)
  end

  @doc "Read a signed assertion from its JSON map."
  @spec decode(term()) :: {:ok, t()} | {:error, reason()}
  def decode(map), do: read(map, true)

  @doc "The JSON map of an assertion; `sig` is absent while unsigned."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = assertion) do
    Encoding.compact(%{
      "protocol" => @protocol,
      "identifier" => assertion.identifier,
      "audience" => assertion.audience,
      "challenge" => Encoding.b64(assertion.challenge),
      "action_id" => assertion.action_id,
      "key_epoch" => assertion.key_epoch,
      "expires_at" => assertion.expires_at,
      "sig" => assertion.sig && Encoding.b64(assertion.sig)
    })
  end

  @doc "Sign an assertion with the person's live private key."
  @spec sign(t(), binary()) :: t()
  def sign(%__MODULE__{} = assertion, live_private_key) do
    map = assertion |> Map.put(:sig, nil) |> encode() |> Encoding.sign(live_private_key)
    {:ok, sig} = Encoding.signature(map["sig"])
    %{assertion | sig: sig}
  end

  @doc """
  Read an assertion and the genesis carried beside it,
  `%{"assertion" => ..., "genesis" => ...}`, holding the genesis to the
  assertion's identifier (`Prima.Identity.locate/2`) before anything uses
  its directory.
  """
  @spec open(term()) ::
          {:ok, %{assertion: t(), genesis: Entry.t()}}
          | {:error, reason() | :too_large | :invalid_json | :not_genesis | :identifier_mismatch}
  def open(%{"assertion" => assertion, "genesis" => genesis} = transport)
      when map_size(transport) == 2 do
    with {:ok, assertion} <- decode(assertion),
         {:ok, genesis} <- Identity.locate(genesis, assertion.identifier) do
      {:ok, %{assertion: assertion, genesis: genesis}}
    end
  end

  def open(_transport), do: {:error, {:invalid_field, "transport"}}

  @doc """
  Check an assertion under `state`, the current head the relying home
  resolved and verified, against what it expects: `opts[:audience]`
  (itself), `opts[:challenge]` (the raw bytes it issued), `opts[:action_id]`
  (the carry action its challenge was bound to) and `opts[:now]` (its
  clock, milliseconds). Refusals, in the order checked: a malformed
  assertion, `:wrong_identifier`, `:stale_key_epoch` (signed under a head
  the directory has moved past), `:bad_signature`, `:wrong_audience`,
  `:wrong_challenge`, `:wrong_action`, and `:expired` at or after
  `expires_at`.
  """
  @spec verify(t() | map(), State.t(), keyword()) :: {:ok, t()} | {:error, reason()}
  def verify(assertion, %State{} = state, opts) do
    now = Keyword.fetch!(opts, :now)

    with {:ok, assertion} <- reread(assertion),
         :ok <- same(assertion.identifier, state.identifier, :wrong_identifier),
         :ok <- same(assertion.key_epoch, state.key_epoch, :stale_key_epoch),
         :ok <- signed(assertion, state.live_key),
         :ok <- same(assertion.audience, Keyword.fetch!(opts, :audience), :wrong_audience),
         :ok <- same(assertion.challenge, Keyword.fetch!(opts, :challenge), :wrong_challenge),
         :ok <- same(assertion.action_id, Keyword.fetch!(opts, :action_id), :wrong_action) do
      if now >= assertion.expires_at, do: {:error, :expired}, else: {:ok, assertion}
    end
  end

  defp reread(%__MODULE__{} = assertion), do: assertion |> encode() |> decode()
  defp reread(map), do: decode(map)

  defp same(value, value, _reason), do: :ok
  defp same(_value, _expected, reason), do: {:error, reason}

  defp signed(assertion, live_key) do
    if Encoding.verify(encode(assertion), live_key), do: :ok, else: {:error, :bad_signature}
  end

  defp read(map, signed?) when is_map(map) and not is_struct(map) do
    sig = if signed?, do: ["sig"], else: []

    with :ok <- Encoding.protocol(map, @protocol),
         :ok <- Encoding.fields(map, @required ++ sig, []),
         {:ok, identifier} <- Encoding.check(map, "identifier", &Encoding.identifier?/1),
         {:ok, audience} <- Encoding.check(map, "audience", &Encoding.home?/1),
         {:ok, challenge} <- Encoding.binary(map, "challenge", @challenge_bytes),
         {:ok, action_id} <- Encoding.check(map, "action_id", &Encoding.id?/1),
         {:ok, key_epoch} <- Encoding.check(map, "key_epoch", &Encoding.digest?/1),
         {:ok, expires_at} <- Encoding.check(map, "expires_at", &Encoding.ms?/1),
         {:ok, sig} <- signature(map, signed?) do
      {:ok,
       %__MODULE__{
         identifier: identifier,
         audience: audience,
         challenge: challenge,
         action_id: action_id,
         key_epoch: key_epoch,
         expires_at: expires_at,
         sig: sig
       }}
    end
  end

  defp read(_value, _signed?), do: {:error, {:invalid_field, "assertion"}}

  defp signature(_map, false), do: {:ok, nil}

  defp signature(map, true) do
    case Encoding.signature(map["sig"]) do
      {:ok, sig} -> {:ok, sig}
      :error -> {:error, {:invalid_field, "sig"}}
    end
  end
end
