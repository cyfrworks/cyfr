# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Confirmation.Preview do
  @moduledoc """
  What a person is shown before they confirm a sensitive change, built by
  the site that decides the change from the request and stored with the
  pending confirmation, so another of the person's devices renders the
  home's record rather than the asking client's word.

  It names the `home`, the `athanor` (as the person knows it), the
  `operation` (`tool.action`) and, when there is one, the affected
  `resource` by name. `details` holds any further public facts the change
  binds, such as a derived public recovery set or a genesis digest: each a
  lowercase name and a string or list of strings. It never carries a
  secret: a detail whose name `Prima.Sanitizer` treats as sensitive
  (`recovery_secret`, a token, a password, ...) is refused, and the
  deciding site never places a secret argument's value in it. It carries
  no sentence of its own; the words are the surface's.
  """

  alias Prima.Identity.Encoding
  alias Prima.Manifest.Tincture

  @required ~w(home athanor operation)
  @optional ~w(resource details)
  @detail_name ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @max_text 1024
  @max_details 32
  @max_list 64

  @type details :: %{optional(String.t()) => String.t() | [String.t()]}
  @type t :: %__MODULE__{
          home: String.t(),
          athanor: String.t(),
          operation: String.t(),
          resource: String.t() | nil,
          details: details()
        }

  @enforce_keys [:home, :athanor, :operation]
  defstruct [:home, :athanor, :operation, resource: nil, details: %{}]

  @doc "A preview from its fields (atom keys)."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Encoding.reason() | :secret_in_preview}
  def new(attrs) do
    attrs = Map.new(attrs)

    %{
      "home" => attrs[:home],
      "athanor" => attrs[:athanor],
      "operation" => attrs[:operation],
      "resource" => attrs[:resource],
      "details" => if(attrs[:details] in [nil, %{}], do: nil, else: attrs[:details])
    }
    |> Encoding.compact()
    |> decode()
  end

  @doc "Read a preview from its JSON map."
  @spec decode(term()) :: {:ok, t()} | {:error, Encoding.reason() | :secret_in_preview}
  def decode(map) when is_map(map) and not is_struct(map) do
    with :ok <- Encoding.fields(map, @required, @optional),
         {:ok, home} <- Encoding.check(map, "home", &Encoding.home?/1),
         {:ok, athanor} <- Encoding.check(map, "athanor", &Encoding.text?(&1, @max_text)),
         {:ok, operation} <-
           Encoding.check(map, "operation", &Tincture.operation_name?/1),
         {:ok, resource} <- Encoding.optional(map, "resource", &Encoding.text?(&1, @max_text)),
         {:ok, details} <- details(Map.get(map, "details", %{})) do
      {:ok,
       %__MODULE__{
         home: home,
         athanor: athanor,
         operation: operation,
         resource: resource,
         details: details
       }}
    end
  end

  def decode(_value), do: {:error, {:invalid_field, "preview"}}

  @doc """
  The longest text a preview holds, in bytes: its `athanor`, its
  `resource` and each detail value or list item. A value a change must
  name in its preview, such as an enrollment's directory URL, fits within
  it or the change cannot be previewed.
  """
  @spec max_text() :: pos_integer()
  def max_text, do: @max_text

  @doc "The JSON map of a preview; `resource` and empty `details` are absent."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = preview) do
    Encoding.compact(%{
      "home" => preview.home,
      "athanor" => preview.athanor,
      "operation" => preview.operation,
      "resource" => preview.resource,
      "details" => if(preview.details == %{}, do: nil, else: preview.details)
    })
  end

  defp details(details) when is_map(details) and not is_struct(details) do
    cond do
      map_size(details) > @max_details ->
        {:error, {:invalid_field, "details"}}

      Enum.any?(Map.keys(details), &Prima.Sanitizer.sensitive_key?/1) ->
        {:error, :secret_in_preview}

      Enum.all?(details, &detail?/1) ->
        {:ok, details}

      true ->
        {:error, {:invalid_field, "details"}}
    end
  end

  defp details(_details), do: {:error, {:invalid_field, "details"}}

  defp detail?({name, value}) when is_binary(name) do
    Regex.match?(@detail_name, name) and
      (Encoding.text?(value, @max_text) or
         (is_list(value) and length(value) <= @max_list and
            Enum.all?(value, &Encoding.text?(&1, @max_text))))
  end

  defp detail?(_detail), do: false
end

defmodule Prima.Confirmation do
  @moduledoc """
  A pending confirmation of one sensitive change, as the deciding home
  records it: `cyfr-confirmation/v1`, its `id` (the record's public
  `ref/1`, below), the deciding `home` and the
  WebAuthn `rp_id` pinned to it, the `athanor`, the `person` (a local
  `usr_` id), the `operation` (`tool.action`), `args_digest`, the digest of
  the exact arguments, the `action` it confirms (a name from Sanctum's
  action table), its secret-free `preview` (`Prima.Confirmation.Preview`),
  a 32-byte random `challenge` its opener drew, and `expires_at` in Unix
  milliseconds. `tests/fixtures/confirmation.json` holds its vectors.

  `digest/1` is over the JCS bytes of the whole record, the protocol
  string, `home`, `rp_id` and the preview included: it is the challenge a
  passkey assertion signs and the nonce a re-authentication binds, so a
  proof for one record never confirms another, a changed preview or
  another relying party. The `rp_id` is the home's host or a parent domain
  of it; which RP a record names never follows the person's identity
  provenance.

  ## The secret and the ref

  The home answers the `confirmation_required` signal with a secret, 256
  random bits spelled `cnf_` and 43 base64url characters, to the request
  that asked alone: only that request's client repeats the change, by
  presenting it. The record is named everywhere else by its `ref/1`, the
  unpadded base64url SHA-256 of `cyfr-confirmation-ref/v1` followed by
  the secret, prefixed `cnr_`. The record's `id` is that ref, so the
  record, its digest and everything the home stores, announces or lists
  carry no secret. Any holder of the secret computes its ref (a glass
  recognizes its own record's events so), and no ref reveals its secret.
  `tests/fixtures/confirmation.json` holds a vector of the derivation.

  A confirmation is never a permission for a similar change: it is
  proven, consumed and voided by Sanctum and Arca, one record at a time.
  """

  alias Prima.Confirmation.Preview
  alias Prima.Identity.Encoding
  alias Prima.Manifest.Tincture

  @protocol "cyfr-confirmation/v1"
  @ref_protocol "cyfr-confirmation-ref/v1"
  @challenge_bytes 32
  @ref ~r/\Acnr_[A-Za-z0-9_-]{43}\z/
  @action ~r/\A[a-z][a-z0-9_]{0,62}\z/
  @required ~w(protocol id home rp_id athanor person operation args_digest action preview challenge expires_at)

  @type t :: %__MODULE__{
          id: String.t(),
          home: String.t(),
          rp_id: String.t(),
          athanor: String.t(),
          person: String.t(),
          operation: String.t(),
          args_digest: String.t(),
          action: String.t(),
          preview: Preview.t(),
          challenge: binary(),
          expires_at: non_neg_integer()
        }

  @type reason ::
          Encoding.reason()
          | :wrong_protocol
          | :invalid_rp_id
          | :preview_mismatch
          | :secret_in_preview

  @enforce_keys [
    :id,
    :home,
    :rp_id,
    :athanor,
    :person,
    :operation,
    :args_digest,
    :action,
    :preview,
    :challenge,
    :expires_at
  ]
  defstruct [
    :id,
    :home,
    :rp_id,
    :athanor,
    :person,
    :operation,
    :args_digest,
    :action,
    :preview,
    :challenge,
    :expires_at
  ]

  @doc "The protocol string a record carries in the bytes it digests."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc "The length of a record's challenge, in bytes."
  @spec challenge_bytes() :: pos_integer()
  def challenge_bytes, do: @challenge_bytes

  @doc """
  The public ref of the secret `id` the `confirmation_required` signal
  answered: `cnr_` and the unpadded base64url SHA-256 of
  `cyfr-confirmation-ref/v1` followed by the secret. One-way: the ref
  names the record, and no ref reveals the secret it was derived from.
  """
  @spec ref(String.t()) :: String.t()
  def ref(id) when is_binary(id),
    do: "cnr_" <> Encoding.b64(:crypto.hash(:sha256, @ref_protocol <> id))

  @doc "Whether `value` is spelled as a ref (`ref/1`)."
  @spec ref?(term()) :: boolean()
  def ref?(value), do: is_binary(value) and Regex.match?(@ref, value)

  @doc """
  A record from its fields (atom keys; `:preview` a `Prima.Confirmation.Preview`
  or its attributes; `:challenge` the raw bytes its opener drew).
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, reason()}
  def new(attrs) do
    attrs = Map.new(attrs)

    with {:ok, preview} <- preview(attrs[:preview]) do
      %{
        "protocol" => @protocol,
        "id" => attrs[:id],
        "home" => attrs[:home],
        "rp_id" => attrs[:rp_id],
        "athanor" => attrs[:athanor],
        "person" => attrs[:person],
        "operation" => attrs[:operation],
        "args_digest" => attrs[:args_digest],
        "action" => attrs[:action],
        "preview" => Preview.encode(preview),
        "challenge" => is_binary(attrs[:challenge]) && Encoding.b64(attrs[:challenge]),
        "expires_at" => attrs[:expires_at]
      }
      |> Encoding.compact()
      |> decode()
    end
  end

  @doc "Read a record from its JSON map."
  @spec decode(term()) :: {:ok, t()} | {:error, reason()}
  def decode(map) when is_map(map) and not is_struct(map) do
    with :ok <- Encoding.protocol(map, @protocol),
         :ok <- Encoding.fields(map, @required, []),
         {:ok, id} <- Encoding.check(map, "id", &Encoding.id?/1),
         {:ok, home} <- Encoding.check(map, "home", &Encoding.home?/1),
         {:ok, rp_id} <- rp_id(map["rp_id"], home),
         {:ok, athanor} <- Encoding.check(map, "athanor", &Encoding.id?/1),
         {:ok, person} <- Encoding.check(map, "person", &person?/1),
         {:ok, operation} <-
           Encoding.check(map, "operation", &Tincture.operation_name?/1),
         {:ok, args_digest} <- Encoding.check(map, "args_digest", &Encoding.digest?/1),
         {:ok, action} <- Encoding.check(map, "action", &action?/1),
         {:ok, preview} <- Preview.decode(map["preview"]),
         :ok <- previews(preview, home, operation),
         {:ok, challenge} <- Encoding.binary(map, "challenge", @challenge_bytes),
         {:ok, expires_at} <- Encoding.check(map, "expires_at", &Encoding.ms?/1) do
      {:ok,
       %__MODULE__{
         id: id,
         home: home,
         rp_id: rp_id,
         athanor: athanor,
         person: person,
         operation: operation,
         args_digest: args_digest,
         action: action,
         preview: preview,
         challenge: challenge,
         expires_at: expires_at
       }}
    end
  end

  def decode(_value), do: {:error, {:invalid_field, "confirmation"}}

  @doc "The JSON map of a record: exactly the bytes its digest covers."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = record) do
    %{
      "protocol" => @protocol,
      "id" => record.id,
      "home" => record.home,
      "rp_id" => record.rp_id,
      "athanor" => record.athanor,
      "person" => record.person,
      "operation" => record.operation,
      "args_digest" => record.args_digest,
      "action" => record.action,
      "preview" => Preview.encode(record.preview),
      "challenge" => Encoding.b64(record.challenge),
      "expires_at" => record.expires_at
    }
  end

  @doc """
  The record's digest, `sha256:<hex>` over the JCS bytes of the whole
  record, preview, home and RP included.
  """
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = record),
    do: record |> encode() |> Encoding.jcs!() |> Prima.Digest.sha256()

  defp preview(%Preview{} = preview), do: {:ok, preview}
  defp preview(attrs) when is_map(attrs) or is_list(attrs), do: Preview.new(attrs)
  defp preview(_other), do: {:error, {:missing_field, "preview"}}

  defp person?(value), do: Encoding.id?(value) and Prima.PersonId.person?(value)
  defp action?(value), do: is_binary(value) and Regex.match?(@action, value)

  # WebAuthn scopes a credential to an RP ID that is the origin's host or a
  # registrable parent of it; a record names that one RP and no other.
  defp rp_id(rp_id, home) when is_binary(rp_id) do
    host = Encoding.home_host(home)

    if Encoding.host?(rp_id) and (host == rp_id or String.ends_with?(host, "." <> rp_id)),
      do: {:ok, rp_id},
      else: {:error, :invalid_rp_id}
  end

  defp rp_id(_rp_id, _home), do: {:error, {:invalid_field, "rp_id"}}

  defp previews(%Preview{home: home, operation: operation}, home, operation), do: :ok
  defp previews(%Preview{}, _home, _operation), do: {:error, :preview_mismatch}
end
