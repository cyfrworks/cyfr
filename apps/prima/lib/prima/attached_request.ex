# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.AttachedRequest do
  @moduledoc """
  A guest's request that names a connection, as the worker service posts
  it to CYFR in `c:Prima.HostAPI.attached_fetch/3`: CYFR, not the guest,
  attaches the credential the connection's need is bound to, so the
  request carries none of its own.

  ## Members

  The host call's `args` are exactly:

    * `call_id` — the runner's name for this fetch: 16 bytes as unpadded
      base64url, 22 characters, in that canonical spelling
      (`valid_call_id?/1`). Every answer frame is sealed for it, and the
      runner opens only frames bound to the call id it chose.
    * `connection` — the name of the need the request is made on, in the
      need-name grammar of `Prima.Manifest.Needs`. Whether the node
      declares it is CYFR's check, against the attempt's authority.
    * `method` — an HTTP method of `Prima.Destination.methods/0`.
    * `url` — the absolute `http` or `https` URL the guest named.
    * `headers` — `[name, value]` pairs, order and repeats kept, each name
      an RFC 9110 token and each value without a control character but
      tab. A header of the credential roster
      (`Prima.Network.credential_headers/0`, in any case) is refused: CYFR
      attaches the credential. A header that routes or frames the request
      (`Prima.Network.framing_headers/0`) or overrides its method or
      target or claims a forwarded origin
      (`Prima.Network.override_headers/0`) is refused too, in any case, so
      the request reaches the pinned host as CYFR frames it, never another
      virtual host behind its address, and is answered as the method and
      path the destination admitted.
    * `body` and `body_encoding` — absent for an empty body; otherwise the
      body in standard base64 and `body_encoding` `"base64"`, as a guest
      request encodes its body. Decoded, the body is at most
      `Prima.HostAPI.max_body_bytes/0`; the grant's own `max_request_size`
      is CYFR's check.
    * `purpose` — `fetch` for an answer read whole, `stream` for one read
      as it arrives.

  `read/1` holds `args` to that; `to_args/1` writes them back.
  """

  @enforce_keys [:call_id, :connection, :method, :url, :headers, :purpose]
  defstruct [:call_id, :connection, :method, :url, :headers, :purpose, body: ""]

  @type header :: {String.t(), String.t()}
  @type purpose :: :fetch | :stream

  @type t :: %__MODULE__{
          call_id: String.t(),
          connection: String.t(),
          method: String.t(),
          url: String.t(),
          headers: [header()],
          body: binary(),
          purpose: purpose()
        }

  @typedoc """
  Why `read/1` refuses: `:credential_header_refused` for a request that
  carries a header of the credential roster, `{:invalid_request, name}`
  for one that sets a header routing, framing or overriding it, naming
  that header as the request spells it, `:body_too_large` for a body past the wire's
  bound, and otherwise the member that is unknown, missing or not of its
  grammar.
  """
  @type reason ::
          :not_a_map
          | :credential_header_refused
          | {:invalid_request, String.t()}
          | :body_too_large
          | {:unknown_field, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @required ~w(call_id connection method url headers purpose)
  @optional ~w(body body_encoding)
  @purposes %{"fetch" => :fetch, "stream" => :stream}
  @connection ~r/\A[a-z][a-z0-9_-]{0,31}\z/
  @call_id ~r/\A[A-Za-z0-9_-]{22}\z/
  @header_name ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @header_value ~r/\A[^\x00-\x08\x0A-\x1F\x7F]*\z/u
  @max_headers 128
  @max_header_name_bytes 256
  @max_header_value_bytes 8192
  @max_url_bytes 8192
  @url ~r/\A[\x21-\x7E]+\z/

  @doc "The purposes an attached request is made for."
  @spec purposes() :: [purpose()]
  def purposes, do: [:fetch, :stream]

  @doc """
  Whether `call_id` is a call id: 16 bytes as unpadded base64url, spelled
  exactly as encoding those bytes spells them.
  """
  @spec valid_call_id?(term()) :: boolean()
  def valid_call_id?(call_id) when is_binary(call_id) do
    Regex.match?(@call_id, call_id) and
      case Base.url_decode64(call_id, padding: false) do
        {:ok, <<_::binary-size(16)>> = bytes} ->
          Base.url_encode64(bytes, padding: false) == call_id

        _ ->
          false
      end
  end

  def valid_call_id?(_call_id), do: false

  @doc """
  The call id 16 bytes spell. The runner chooses the bytes; nothing here
  draws them.
  """
  @spec call_id(<<_::128>>) :: String.t()
  def call_id(<<_::binary-size(16)>> = bytes), do: Base.url_encode64(bytes, padding: false)

  @doc "The attached request an `attached_fetch` call's `args` spell, or why not."
  @spec read(term()) :: {:ok, t()} | {:error, reason()}
  def read(args) when is_map(args) and not is_struct(args) do
    with :ok <- members(args),
         {:ok, call_id} <- member(args, "call_id", &valid_call_id?/1),
         {:ok, connection} <- member(args, "connection", &connection?/1),
         {:ok, method} <- member(args, "method", &(&1 in Prima.Destination.methods())),
         {:ok, url} <- member(args, "url", &url?/1),
         {:ok, headers} <- headers(args["headers"]),
         {:ok, body} <- body(args),
         {:ok, purpose} <- purpose(args["purpose"]) do
      {:ok,
       %__MODULE__{
         call_id: call_id,
         connection: connection,
         method: method,
         url: url,
         headers: headers,
         body: body,
         purpose: purpose
       }}
    end
  end

  def read(_args), do: {:error, :not_a_map}

  @doc "The `args` `read/1` reads back to `request`."
  @spec to_args(t()) :: %{String.t() => term()}
  def to_args(%__MODULE__{} = request) do
    args = %{
      "call_id" => request.call_id,
      "connection" => request.connection,
      "method" => request.method,
      "url" => request.url,
      "headers" => Enum.map(request.headers, fn {name, value} -> [name, value] end),
      "purpose" => Atom.to_string(request.purpose)
    }

    if request.body == "",
      do: args,
      else: Map.merge(args, %{"body" => Base.encode64(request.body), "body_encoding" => "base64"})
  end

  defp members(args) do
    case args
         |> Map.keys()
         |> Enum.reject(&(&1 in @required or &1 in @optional))
         |> Enum.sort() do
      [unknown | _rest] ->
        {:error, {:unknown_field, to_string(unknown)}}

      [] ->
        case Enum.find(@required, &(not Map.has_key?(args, &1))) do
          nil -> :ok
          missing -> {:error, {:missing_field, missing}}
        end
    end
  end

  defp member(args, name, valid?) do
    value = Map.fetch!(args, name)
    if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, name}}
  end

  defp connection?(name), do: is_binary(name) and Regex.match?(@connection, name)

  defp url?(url) when is_binary(url) and byte_size(url) <= @max_url_bytes do
    Regex.match?(@url, url) and match?({:ok, _uri}, Prima.Network.parse_url(url))
  end

  defp url?(_url), do: false

  defp headers(pairs) when is_list(pairs) and length(pairs) <= @max_headers do
    read =
      Enum.map(pairs, fn
        [name, value] when is_binary(name) and is_binary(value) -> {name, value}
        _other -> :error
      end)

    cond do
      not Enum.all?(read, &header?/1) ->
        {:error, {:invalid_field, "headers"}}

      Enum.any?(read, &named_in?(&1, Prima.Network.credential_headers())) ->
        {:error, :credential_header_refused}

      index = Enum.find_index(read, &reserved_header?/1) ->
        {name, _value} = Enum.at(read, index)
        {:error, {:invalid_request, name}}

      true ->
        {:ok, read}
    end
  end

  defp headers(_pairs), do: {:error, {:invalid_field, "headers"}}

  defp header?({name, value}) do
    byte_size(name) <= @max_header_name_bytes and Regex.match?(@header_name, name) and
      byte_size(value) <= @max_header_value_bytes and String.valid?(value) and
      Regex.match?(@header_value, value)
  end

  defp header?(:error), do: false

  defp named_in?({name, _value}, roster), do: String.downcase(name) in roster

  defp reserved_header?(header) do
    named_in?(header, Prima.Network.framing_headers()) or
      named_in?(header, Prima.Network.override_headers())
  end

  # Absent members are an empty body; a present one is base64, declared so.
  defp body(args) do
    case {Map.fetch(args, "body"), Map.fetch(args, "body_encoding")} do
      {:error, :error} ->
        {:ok, ""}

      {{:ok, body}, {:ok, "base64"}} when is_binary(body) and body != "" ->
        decode_body(body)

      {{:ok, _body}, {:ok, "base64"}} ->
        {:error, {:invalid_field, "body"}}

      {_body, {:ok, _other}} ->
        {:error, {:invalid_field, "body_encoding"}}

      {{:ok, _body}, :error} ->
        {:error, {:missing_field, "body_encoding"}}
    end
  end

  defp decode_body(body) do
    max = Prima.HostAPI.max_body_bytes()

    if byte_size(body) > div(max + 2, 3) * 4 do
      {:error, :body_too_large}
    else
      case Base.decode64(body) do
        {:ok, bytes} when byte_size(bytes) <= max -> {:ok, bytes}
        {:ok, _bytes} -> {:error, :body_too_large}
        :error -> {:error, {:invalid_field, "body"}}
      end
    end
  end

  defp purpose(purpose) when is_map_key(@purposes, purpose),
    do: {:ok, Map.fetch!(@purposes, purpose)}

  defp purpose(_purpose), do: {:error, {:invalid_field, "purpose"}}
end
