# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Device do
  @moduledoc """
  The device protocol: the messages a paired client (a glass) and its home
  exchange over the device channel. Every message is a JSON object carrying
  `"protocol": "cyfr-device/v1"` and a `type`, and exactly its type's
  fields; a listener refuses any other version and reads no further.
  `tests/fixtures/device.json` holds its vectors.

  A device that is not yet a client of this home opens its first
  connection with `hello`; the home answers `sign_in_request`, the device
  `sign_in_answer` after its local unlock, and the home `admitted`. From
  then on the device connects under the certificate it was given.

  From the glass to the home:

    * `hello` — the first connection: `kid`, the device key's kid as the
      account's log lists it; `identifier`, the account it is a key of;
      `holder_kind`, what holds the key under its local unlock, `chip` or
      `software`; `display_name`, the name it shows, text of at most 64
      bytes; and, when it brings one, `admission`, what admits a person
      new here: `{"setup": token}`, the installation's setup token (64
      lowercase hexadecimal characters), or `{"invitation": code}`, an
      invitation's code (unpadded base64url of 32 bytes).
    * `sign_in_answer` — `answer`, the device's answer to the request
      (`Prima.SignIn.DeviceAnswer`).
    * `connect` — `client_id` and the `certificate` (`Prima.DeviceCert`)
      the glass connects under.
    * `renew` — `client_id`, and optionally the old `certificate`, which
      only locates the client and authorizes nothing.
    * `proof` — the `proof` (`Prima.DeviceCert.Proof`) answering a challenge.
    * `capabilities` — the `capabilities` the glass announces, by name.
    * `intent` — one discrete operation: `id`, `operation` (`tool.action`),
      `args` (an object of at most 64 KiB) and, when repeated under a
      confirmation, `confirmation_id`. An intent is one discrete step: one
      whose own members include a `stream`, `frames`, `chunks`, `samples`
      or `continuous` field is refused by its shape. `args` is not read
      for them; it is the operation's to read.

  From the home to the glass:

    * `sign_in_request` — `request`, the `Prima.SignIn` request a hello is
      answered with, bound to this channel.
    * `admitted` — the device's paired `client_id`, its first
      `certificate`, and `standing`, the client's standing as the
      `standing` message carries it.
    * `challenge` — the `challenge` (`Prima.DeviceCert.Challenge`), for
      `connect` or `renew`.
    * `standing` — the client's standing: `client_id`, `athanor` and
      `expires_at`, the expiry of the certificate it stands under.
    * `certificate` — a renewed `certificate`.
    * `answer` — an intent's `id` and exactly one of `result` or `error`.
    * `grant` — a stream granted to the client: `grant_id`, `stream`,
      `subject` (when it has one), `projection` and `expires_at`.
    * `event` — one fact of a granted stream: `grant_id` and `payload`.
      A stream that declares a refresh answers its current state after
      the `grant` as `event`s whose payload carries `"refresh": true`.
    * `revoke` — the pairing of `client_id` has ended, or, with `grant_id`,
      that one grant.

  `decode/2` reads a message arriving from one side and refuses a type the
  other side sends. Timestamps are Unix milliseconds; binary values are
  unpadded base64url (`Prima.Identity.Encoding`).
  """

  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.Encoding
  alias Prima.Manifest.Tincture
  alias Prima.SignIn
  alias Prima.SignIn.DeviceAnswer

  @protocol "cyfr-device/v1"
  @digest_bytes 32
  @code_group 4
  @max_args_bytes 65_536
  @max_names 64
  @name ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @continuous ~w(stream frames chunks samples continuous)
  @holder_kinds ~w(chip software)
  @max_display_name 64
  @setup_token ~r/\A[0-9a-f]{64}\z/
  @invitation_code_bytes 32
  @standing [client_id: :id, athanor: :id, expires_at: :ms]

  # type => {sender, required fields, optional fields}, each field with its codec
  @types %{
    hello:
      {:glass,
       [
         kid: :kid,
         identifier: :identifier,
         holder_kind: :holder_kind,
         display_name: :display_name
       ], [admission: :admission]},
    sign_in_answer: {:glass, [answer: :device_answer], []},
    connect: {:glass, [client_id: :id, certificate: :certificate], []},
    renew: {:glass, [client_id: :id], [certificate: :certificate]},
    proof: {:glass, [proof: :proof], []},
    capabilities: {:glass, [capabilities: :names], []},
    intent: {:glass, [id: :id, operation: :operation, args: :args], [confirmation_id: :id]},
    sign_in_request: {:home, [request: :request], []},
    admitted: {:home, [client_id: :id, certificate: :certificate, standing: :standing], []},
    challenge: {:home, [challenge: :challenge], []},
    standing: {:home, @standing, []},
    certificate: {:home, [certificate: :certificate], []},
    answer: {:home, [id: :id], [result: :json, error: :object]},
    grant:
      {:home, [grant_id: :id, stream: :stream, projection: :fields, expires_at: :ms],
       [subject: :subject]},
    event: {:home, [grant_id: :id, payload: :object], []},
    revoke: {:home, [client_id: :id], [grant_id: :id]}
  }
  @by_name Map.new(@types, fn {type, _spec} -> {Atom.to_string(type), type} end)

  @type sender :: :glass | :home
  @type type ::
          :hello
          | :sign_in_answer
          | :connect
          | :renew
          | :proof
          | :capabilities
          | :intent
          | :sign_in_request
          | :admitted
          | :challenge
          | :standing
          | :certificate
          | :answer
          | :grant
          | :event
          | :revoke
  @type message :: {type(), map()}
  @type reason ::
          Encoding.reason()
          | :wrong_protocol
          | {:unknown_type, term()}
          | {:wrong_sender, type()}
          | :continuous_payload
          | :too_large

  @doc "The protocol string every message carries."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc "The message types `sender` sends."
  @spec types(sender()) :: [type()]
  def types(sender) when sender in [:glass, :home] do
    Enum.sort(for {type, {^sender, _required, _optional}} <- @types, do: type)
  end

  @doc """
  The digest of the device public key `device_key` (32 raw bytes):
  SHA-256 over those bytes, as unpadded base64url.
  """
  @spec key_digest(binary()) :: String.t()
  def key_digest(device_key) when is_binary(device_key) and byte_size(device_key) == 32,
    do: Encoding.b64(:crypto.hash(:sha256, device_key))

  @doc "Whether `value` is spelled as a key digest is: unpadded base64url of 32 bytes."
  @spec key_digest?(term()) :: boolean()
  def key_digest?(value), do: match?({:ok, _digest}, get(:digest, value))

  @doc """
  The key digest `key_digest` as a person reads and types it: its
  characters in groups of four, separated by single spaces.
  `from_key_code/1` reads it back.
  """
  @spec key_code(String.t()) :: String.t()
  def key_code(key_digest) when is_binary(key_digest) do
    key_digest
    |> String.graphemes()
    |> Enum.chunk_every(@code_group)
    |> Enum.map_join(" ", &Enum.join/1)
  end

  @doc """
  The key digest a person typed or pasted as `text`, its code spelled with
  or without the spaces between its groups: `{:ok, key_digest}`, or
  `:error` for anything else.
  """
  @spec from_key_code(term()) :: {:ok, String.t()} | :error
  def from_key_code(text) when is_binary(text) do
    digest = String.replace(text, ~r/\s+/u, "")
    if key_digest?(digest), do: {:ok, digest}, else: :error
  end

  def from_key_code(_text), do: :error

  @doc """
  What holds a device's key under its local unlock, as a hello names it
  and a paired client records it: a TPM `chip` or a passphrase-wrapped
  `software` file.
  """
  @spec holder_kinds() :: [String.t()]
  def holder_kinds, do: @holder_kinds

  @doc """
  Whether `value` is a name a device shows: non-empty UTF-8 of at most 64
  bytes with no control character.
  """
  @spec display_name?(term()) :: boolean()
  def display_name?(value), do: Encoding.text?(value, @max_display_name)

  @doc """
  Whether `value` is spelled as an installation's setup token is: exactly
  64 lowercase hexadecimal characters, 32 random bytes. The token admits
  the installation's first person; it is never a platform setting or a
  log value.
  """
  @spec setup_token?(term()) :: boolean()
  def setup_token?(value), do: is_binary(value) and Regex.match?(@setup_token, value)

  @doc "Whether `value` is spelled as an invitation's code is: unpadded base64url of 32 bytes."
  @spec invitation_code?(term()) :: boolean()
  def invitation_code?(value),
    do: match?({:ok, _bytes}, Encoding.unb64(value, @invitation_code_bytes))

  @doc "The fields that mark an intent as carrying continuous data."
  @spec continuous_fields() :: [String.t()]
  def continuous_fields, do: @continuous

  @doc """
  Read a message `sender` sent: `{type, body}`, the body's fields as atoms
  and its values decoded (a certificate, challenge, proof, request or
  device answer as its struct, an admission as `{:setup, token}` or
  `{:invitation, code}`, and a standing as its fields).
  """
  @spec decode(term(), sender()) :: {:ok, message()} | {:error, reason()}
  def decode(map, sender) when is_map(map) and not is_struct(map) and sender in [:glass, :home] do
    with :ok <- Encoding.protocol(map, @protocol),
         {:ok, type, {from, required, optional}} <- type(map),
         :ok <- sent_by(type, from, sender),
         :ok <- discrete(type, map),
         :ok <- Encoding.fields(map, names(["protocol", "type"], required), names([], optional)),
         {:ok, body} <- body(map, required ++ optional),
         :ok <- one_outcome(type, body) do
      {:ok, {type, body}}
    end
  end

  def decode(_value, _sender), do: {:error, {:invalid_field, "message"}}

  @doc "The JSON map of a message."
  @spec encode(message()) :: map()
  def encode({type, body}) when is_atom(type) and is_map(body) do
    {_from, required, optional} = Map.fetch!(@types, type)

    for {field, codec} <- required ++ optional, Map.has_key?(body, field), into: %{} do
      {Atom.to_string(field), put(codec, Map.fetch!(body, field))}
    end
    |> Map.merge(%{"protocol" => @protocol, "type" => Atom.to_string(type)})
  end

  defp type(map) do
    case Map.fetch(map, "type") do
      {:ok, name} when is_map_key(@by_name, name) ->
        type = Map.fetch!(@by_name, name)
        {:ok, type, Map.fetch!(@types, type)}

      {:ok, name} ->
        {:error, {:unknown_type, name}}

      :error ->
        {:error, {:missing_field, "type"}}
    end
  end

  defp sent_by(_type, sender, sender), do: :ok
  defp sent_by(type, _from, _sender), do: {:error, {:wrong_sender, type}}

  defp discrete(:intent, map) do
    if Enum.any?(@continuous, &Map.has_key?(map, &1)),
      do: {:error, :continuous_payload},
      else: :ok
  end

  defp discrete(_type, _map), do: :ok

  defp names(base, fields),
    do: base ++ Enum.map(fields, fn {field, _codec} -> Atom.to_string(field) end)

  defp body(map, fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {field, codec}, {:ok, body} ->
      case field(map, field, codec) do
        :absent -> {:cont, {:ok, body}}
        {:ok, decoded} -> {:cont, {:ok, Map.put(body, field, decoded)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp field(map, field, codec) do
    name = Atom.to_string(field)

    with {:ok, value} <- Map.fetch(map, name),
         {:ok, decoded} <- get(codec, value) do
      {:ok, decoded}
    else
      :error -> if Map.has_key?(map, name), do: {:error, {:invalid_field, name}}, else: :absent
      {:error, :too_large} -> {:error, :too_large}
      _invalid -> {:error, {:invalid_field, name}}
    end
  end

  defp one_outcome(:answer, body) do
    if Map.has_key?(body, :result) != Map.has_key?(body, :error),
      do: :ok,
      else: {:error, {:invalid_field, "result"}}
  end

  defp one_outcome(_type, _body), do: :ok

  defp get(:id, value), do: ok_if(Encoding.id?(value), value)
  defp get(:ms, value), do: ok_if(Encoding.ms?(value), value)

  defp get(:digest, value) do
    with {:ok, _bytes} <- Encoding.unb64(value, @digest_bytes), do: {:ok, value}
  end

  defp get(:kid, value), do: ok_if(Encoding.digest?(value), value)
  defp get(:identifier, value), do: ok_if(Encoding.identifier?(value), value)
  defp get(:holder_kind, value), do: ok_if(value in @holder_kinds, value)
  defp get(:display_name, value), do: ok_if(display_name?(value), value)

  # Exactly one capability: the setup token or an invitation's code.
  defp get(:admission, %{"setup" => token} = admission) when map_size(admission) == 1,
    do: ok_if(setup_token?(token), {:setup, token})

  defp get(:admission, %{"invitation" => code} = admission) when map_size(admission) == 1,
    do: ok_if(invitation_code?(code), {:invitation, code})

  defp get(:admission, _value), do: :error

  defp get(:request, value), do: SignIn.decode(value)
  defp get(:device_answer, value), do: DeviceAnswer.decode(value)

  defp get(:standing, value) when is_map(value) and not is_struct(value) do
    with :ok <- Encoding.fields(value, names([], @standing), []), do: body(value, @standing)
  end

  defp get(:standing, _value), do: :error

  defp get(:certificate, value), do: DeviceCert.decode(value)
  defp get(:challenge, value), do: Challenge.decode(value)
  defp get(:proof, value), do: Proof.decode(value)
  defp get(:operation, value), do: ok_if(Tincture.operation_name?(value), value)
  defp get(:stream, value), do: ok_if(Tincture.stream_name?(value), value)
  defp get(:subject, value), do: ok_if(Tincture.literal_subject?(value), value)
  defp get(:object, value), do: ok_if(is_map(value) and not is_struct(value), value)
  defp get(:json, value), do: {:ok, value}

  defp get(:names, value) do
    ok_if(set?(value, &(is_binary(&1) and Regex.match?(@name, &1))), value)
  end

  defp get(:fields, value), do: ok_if(set?(value, &Encoding.text?(&1, 128)), value)

  defp get(:args, value) when is_map(value) and not is_struct(value) do
    case Prima.Json.encode(value) do
      {:ok, json} when byte_size(json) > @max_args_bytes -> {:error, :too_large}
      {:ok, _json} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end

  defp get(:args, _value), do: :error

  defp set?(values, valid?) do
    is_list(values) and length(values) <= @max_names and Enum.all?(values, valid?) and
      length(Enum.uniq(values)) == length(values)
  end

  defp ok_if(true, value), do: {:ok, value}
  defp ok_if(false, _value), do: :error

  defp put(:admission, {kind, value}), do: %{Atom.to_string(kind) => value}
  defp put(:request, request), do: SignIn.encode(request)
  defp put(:device_answer, answer), do: DeviceAnswer.encode(answer)

  defp put(:standing, standing) do
    for {field, codec} <- @standing,
        into: %{},
        do: {Atom.to_string(field), put(codec, Map.fetch!(standing, field))}
  end

  defp put(:certificate, cert), do: DeviceCert.encode(cert)
  defp put(:challenge, challenge), do: Challenge.encode(challenge)
  defp put(:proof, proof), do: Proof.encode(proof)
  defp put(_codec, value), do: value
end
