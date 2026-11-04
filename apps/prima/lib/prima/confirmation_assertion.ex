# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ConfirmationAssertion do
  @moduledoc """
  A person's home certifying, with their live key, that the person
  confirmed one pending confirmation at another home (`audience`): the
  proof a remote person gives at a home that holds no passkey or device of
  theirs that home could check. The person's home signs it only after a
  fresh confirmation of its own, given there by a passkey under its own RP
  ID or a protected device of the person's, never by a sign-in method; the
  deciding home never sees, and never verifies, another RP's WebAuthn
  assertion.

  It carries the protocol string `cyfr-confirmation-assertion/v1`, the
  person's `identifier`, the `key_epoch` of the head it was signed under,
  the deciding home as `audience`, the deciding home's `athanor` the
  record lives in, the record's public `ref` (`Prima.Confirmation.ref/1`)
  and stored `digest` (`Prima.Confirmation.digest/1`), the
  `preview_digest` of the preview the person's home showed
  (`preview_digest/1`), an expiry in Unix milliseconds and the live key's
  signature over the JCS bytes of every other field. `tests/fixtures/confirmation_assertion.json` holds its
  vectors and the exchange that carries it.

  `verify/3` checks it under the current head the deciding home resolved
  for the person, fresh from their directory, against the record it holds.
  An assertion confirms the one record its `ref` and `digest` name, while
  that record waits for a proof: the record's own single confirmation is
  its replay bound.

  The record's `digest` covers its secret `id`, which the person's home
  never holds, so that home cannot tell from it which change it is shown.
  `preview_digest` binds what it showed: the person's home computes it
  from the preview it carries and signs nothing for a preview whose digest
  is not the one it was told, and the deciding home computes it from its
  own record's preview, whose `operation` is the record's
  (`Prima.Confirmation`), and refuses an assertion over any other, so a
  preview of another change cannot be shown for a record of this one.
  """

  alias Prima.Confirmation.Preview
  alias Prima.Identity.{Encoding, State}

  @protocol "cyfr-confirmation-assertion/v1"
  @lifetime_ms 60_000
  @required ~w(protocol identifier key_epoch audience athanor ref digest preview_digest expires_at)

  @type t :: %__MODULE__{
          identifier: String.t(),
          key_epoch: String.t(),
          audience: String.t(),
          athanor: String.t(),
          ref: String.t(),
          digest: String.t(),
          preview_digest: String.t(),
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
          | :wrong_athanor
          | :wrong_ref
          | :wrong_digest
          | :wrong_preview
          | :expired

  @enforce_keys [
    :identifier,
    :key_epoch,
    :audience,
    :athanor,
    :ref,
    :digest,
    :preview_digest,
    :expires_at
  ]
  defstruct [
    :identifier,
    :key_epoch,
    :audience,
    :athanor,
    :ref,
    :digest,
    :preview_digest,
    :expires_at,
    sig: nil
  ]

  @doc "The protocol string an assertion carries."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc """
  How long after its signing an assertion lives, in milliseconds: the
  person's home sets `expires_at` this far past its clock, and no later
  than the record's own expiry it was told.
  """
  @spec lifetime_ms() :: pos_integer()
  def lifetime_ms, do: @lifetime_ms

  @doc """
  The digest of a confirmation's preview, as an assertion binds it: the
  SHA-256 of the JCS bytes of its JSON (`Prima.Confirmation.Preview.encode/1`),
  as `sha256:<hex>`.
  """
  @spec preview_digest(Preview.t()) :: String.t()
  def preview_digest(%Preview{} = preview),
    do: preview |> Preview.encode() |> Encoding.jcs!() |> Prima.Digest.sha256()

  @doc """
  An unsigned assertion from its fields (atom keys). Sign it with
  `sign/2` under the person's live private key.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, reason()}
  def new(attrs) do
    attrs = Map.new(attrs)

    %{
      "protocol" => @protocol,
      "identifier" => attrs[:identifier],
      "key_epoch" => attrs[:key_epoch],
      "audience" => attrs[:audience],
      "athanor" => attrs[:athanor],
      "ref" => attrs[:ref],
      "digest" => attrs[:digest],
      "preview_digest" => attrs[:preview_digest],
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
      "key_epoch" => assertion.key_epoch,
      "audience" => assertion.audience,
      "athanor" => assertion.athanor,
      "ref" => assertion.ref,
      "digest" => assertion.digest,
      "preview_digest" => assertion.preview_digest,
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
  Check an assertion under `state`, the person's current head the deciding
  home read fresh from their directory, against the record it holds:
  `opts[:audience]` (itself), `opts[:athanor]`, `opts[:ref]`,
  `opts[:digest]` and `opts[:preview_digest]` (the record's, the last by
  `preview_digest/1` over its preview), and `opts[:now]` (its clock,
  milliseconds). Refusals, in the order checked: a malformed assertion,
  `:wrong_identifier`, `:stale_key_epoch` (signed under a head the
  directory has moved past), `:bad_signature`, `:wrong_audience`,
  `:wrong_athanor`, `:wrong_ref`, `:wrong_digest`, `:wrong_preview` (the
  person's home showed another preview), and `:expired` at or after
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
         :ok <- same(assertion.athanor, Keyword.fetch!(opts, :athanor), :wrong_athanor),
         :ok <- same(assertion.ref, Keyword.fetch!(opts, :ref), :wrong_ref),
         :ok <- same(assertion.digest, Keyword.fetch!(opts, :digest), :wrong_digest),
         :ok <-
           same(assertion.preview_digest, Keyword.fetch!(opts, :preview_digest), :wrong_preview) do
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
         {:ok, key_epoch} <- Encoding.check(map, "key_epoch", &Encoding.digest?/1),
         {:ok, audience} <- Encoding.check(map, "audience", &Encoding.home?/1),
         {:ok, athanor} <- Encoding.check(map, "athanor", &Encoding.id?/1),
         {:ok, ref} <- Encoding.check(map, "ref", &Prima.Confirmation.ref?/1),
         {:ok, digest} <- Encoding.check(map, "digest", &Encoding.digest?/1),
         {:ok, preview_digest} <- Encoding.check(map, "preview_digest", &Encoding.digest?/1),
         {:ok, expires_at} <- Encoding.check(map, "expires_at", &Encoding.ms?/1),
         {:ok, sig} <- signature(map, signed?) do
      {:ok,
       %__MODULE__{
         identifier: identifier,
         key_epoch: key_epoch,
         audience: audience,
         athanor: athanor,
         ref: ref,
         digest: digest,
         preview_digest: preview_digest,
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
