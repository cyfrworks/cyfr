# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Device do
  @moduledoc """
  The device protocol: the messages a paired client (a glass) and its home
  exchange over the device channel. Every message is a JSON object carrying
  `"protocol": "cyfr-device/v1"` and a `type`, and exactly its type's
  fields; a listener refuses any other version and reads no further.
  `tests/fixtures/device.json` holds its vectors.

  From the glass to the home:

    * `pair_request` — `invitation_secret`, the 16-byte bearer secret from
      the pairing QR, named so `Prima.Sanitizer` redacts it wherever a
      message is logged, and `device_key`, the public key the glass
      generated and never exports.
    * `connect` — `client_id` and the `certificate` (`Prima.DeviceCert`)
      the glass connects under.
    * `renew` — `client_id`, and optionally the old `certificate`, which
      only locates the client and authorizes nothing.
    * `proof` — the `proof` (`Prima.DeviceCert.Proof`) answering a challenge.
    * `capabilities` — the `capabilities` the glass announces, by name.
    * `intent` — one discrete operation: `id`, `operation` (`tool.action`),
      `args` (an object of at most 64 KiB) and, when repeated under a
      confirmation, `confirmation_id`. An intent never carries continuous
      data: one that carries a `stream`, `frames`, `chunks`, `samples` or
      `continuous` field is refused by its shape.

  From the home to the glass:

    * `pair_answer` — the paired `client_id` and its first `certificate`.
    * `challenge` — the `challenge` (`Prima.DeviceCert.Challenge`), for
      `connect`, `renew` or `pair`.
    * `standing` — the client's standing: `client_id`, `athanor` and
      `expires_at`, the expiry of the certificate it stands under.
    * `certificate` — a renewed `certificate`.
    * `answer` — an intent's `id` and exactly one of `result` or `error`.
    * `grant` — a stream granted to the client: `grant_id`, `stream`,
      `subject` (when it has one), `projection` and `expires_at`.
    * `event` — one fact of a granted stream: `grant_id` and `payload`.
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

  @protocol "cyfr-device/v1"
  @invitation_bytes 16
  @max_args_bytes 65_536
  @max_names 64
  @name ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @continuous ~w(stream frames chunks samples continuous)

  # type => {sender, required fields, optional fields}, each field with its codec
  @types %{
    pair_request: {:glass, [invitation_secret: :invitation, device_key: :key], []},
    connect: {:glass, [client_id: :id, certificate: :certificate], []},
    renew: {:glass, [client_id: :id], [certificate: :certificate]},
    proof: {:glass, [proof: :proof], []},
    capabilities: {:glass, [capabilities: :names], []},
    intent: {:glass, [id: :id, operation: :operation, args: :args], [confirmation_id: :id]},
    pair_answer: {:home, [client_id: :id, certificate: :certificate], []},
    challenge: {:home, [challenge: :challenge], []},
    standing: {:home, [client_id: :id, athanor: :id, expires_at: :ms], []},
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
          :pair_request
          | :connect
          | :renew
          | :proof
          | :capabilities
          | :intent
          | :pair_answer
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

  @doc "The fields that mark an intent as carrying continuous data."
  @spec continuous_fields() :: [String.t()]
  def continuous_fields, do: @continuous

  @doc """
  Read a message `sender` sent: `{type, body}`, the body's fields as atoms
  and its values decoded (keys and the invitation as raw bytes, a
  certificate, challenge or proof as its struct).
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
  defp get(:key, value), do: Encoding.unb64(value, Encoding.key_bytes())
  defp get(:invitation, value), do: Encoding.unb64(value, @invitation_bytes)
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

  defp put(:key, bytes), do: Encoding.b64(bytes)
  defp put(:invitation, bytes), do: Encoding.b64(bytes)
  defp put(:certificate, cert), do: DeviceCert.encode(cert)
  defp put(:challenge, challenge), do: Challenge.encode(challenge)
  defp put(:proof, proof), do: Proof.encode(proof)
  defp put(_codec, value), do: value
end
