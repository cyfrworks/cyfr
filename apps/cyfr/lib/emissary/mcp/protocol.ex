# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.Protocol do
  @moduledoc """
  The MCP protocol revision this server speaks, and the vocabulary that goes
  with it.

  The version used to be a `@protocol_version` module attribute copy-pasted into
  five modules — the router, the controller, the session plug, the origin plug
  and the SSE controller — with three more literals in the clients and the
  bridge. Eight copies of one fact is how a server ends up announcing one
  revision while validating another.

  Everything that needs the version reads it here. The plugs still bind it to a
  module attribute because they match it in a pattern, which a function call
  cannot do; the attribute is initialized from `version/0` at compile time, so
  there is still one source.
  """

  @version "2026-07-28"

  @supported [@version]

  # Reverse-DNS `_meta` keys defined by the specification. Every request carries
  # its own version, identity and capabilities here instead of establishing them
  # once in a handshake — that is what makes the protocol stateless.
  @meta_protocol_version "io.modelcontextprotocol/protocolVersion"
  @meta_client_info "io.modelcontextprotocol/clientInfo"
  @meta_client_capabilities "io.modelcontextprotocol/clientCapabilities"
  @meta_server_info "io.modelcontextprotocol/serverInfo"

  # Every result declares its type so a client can tell a finished answer from
  # one that is asking for more input. `:input_required` is the multi-round-trip
  # half and has no producer yet; it is named here so the vocabulary is complete
  # and the encoder does not have to grow a second shape later.
  @result_types %{complete: "complete", input_required: "input_required"}

  # The server's own identity, reported in every result's `_meta`. The version is
  # read from the application rather than written down: a hardcoded one was
  # announcing 0.1.0 from a 0.5.8 build, which is worse than announcing nothing.
  @server_name "CYFR"

  @doc "The `_meta` key carrying the protocol version of a request."
  @spec meta_protocol_version_key() :: String.t()
  def meta_protocol_version_key, do: @meta_protocol_version

  @doc "The `_meta` key carrying the calling client's identity."
  @spec meta_client_info_key() :: String.t()
  def meta_client_info_key, do: @meta_client_info

  @doc "The `_meta` key carrying the calling client's capabilities."
  @spec meta_client_capabilities_key() :: String.t()
  def meta_client_capabilities_key, do: @meta_client_capabilities

  # Headers a conforming client sends on every request, lower-cased because
  # `Plug.Conn` down-cases and RFC 9110 makes field names case-insensitive.
  #
  # These names live here — with the list built FROM them — because three
  # parties must agree exactly: the CORS preflight advertises the list, the
  # metadata plug demands each header, and the outbound client sends them.
  # When any of those spelled a name for itself, the copies drifted and
  # locked every cross-origin client out.
  @protocol_version_header "mcp-protocol-version"
  @method_header "mcp-method"
  @name_header "mcp-name"
  @request_headers [@protocol_version_header, @method_header, @name_header]

  @doc "The header carrying the declared protocol version."
  @spec protocol_version_header() :: String.t()
  def protocol_version_header, do: @protocol_version_header

  @doc "The header mirroring the request body's method."
  @spec method_header() :: String.t()
  def method_header, do: @method_header

  @doc "The header mirroring the request's named subject (tool/resource)."
  @spec name_header() :: String.t()
  def name_header, do: @name_header

  # Headers a client must be able to read off the response. `x-request-id` is
  # CYFR's, not the specification's, but a client that cannot read it cannot
  # correlate a failure with a server log.
  @exposed_headers [@protocol_version_header, "x-request-id"]

  # `x-mcp-header` mirrors a tool argument into `Mcp-Param-{Name}`. A preflight
  # cannot advertise a prefix, so each one would have to be named explicitly —
  # see `Emissary.MCP.ToolProvider` and the CORS drift test.
  @param_header_prefix "mcp-param-"

  @doc """
  Request headers required on every MCP request, lower-cased.

  `mcp-name` is required only for methods that name a subject (`named_subject/1`),
  but it appears here unconditionally: a preflight advertises what a request
  *may* carry, not what this particular request does.
  """
  @spec request_headers() :: [String.t()]
  def request_headers, do: @request_headers

  @doc "Response headers a client must be able to read."
  @spec exposed_headers() :: [String.t()]
  def exposed_headers, do: @exposed_headers

  @doc "Prefix for headers mirrored from tool arguments by `x-mcp-header`."
  @spec param_header_prefix() :: String.t()
  def param_header_prefix, do: @param_header_prefix

  @doc "The `_meta` key carrying this server's identity."
  @spec meta_server_info_key() :: String.t()
  def meta_server_info_key, do: @meta_server_info

  @doc """
  The `resultType` string for a result kind.

  A client that does not recognise the value must treat the result as invalid,
  so this is deliberately a closed set rather than a free string.
  """
  @spec result_type(:complete | :input_required) :: String.t()
  def result_type(kind) when is_map_key(@result_types, kind), do: @result_types[kind]

  @doc "This server's name and version, for a result's `_meta`."
  @spec server_info() :: %{String.t() => String.t()}
  def server_info do
    %{"name" => @server_name, "version" => Cyfr.Version.current()}
  end

  @doc """
  The protocol version declared in a request's `params._meta`, or `nil`.
  """
  @spec declared_version(term()) :: String.t() | nil
  def declared_version(%{"params" => %{"_meta" => %{@meta_protocol_version => v}}})
      when is_binary(v),
      do: v

  def declared_version(_), do: nil

  @doc """
  Decode a header value that may carry the specification's Base64 sentinel.

  Tool names and resource URIs are only *recommended* to be header-safe, so a
  value outside visible ASCII travels as `=?base64?<encoded>?=`. Comparing a
  header to a body value without decoding first would reject every legitimate
  request that needed the encoding.

  Returns the value unchanged when it carries no sentinel, and `:error` when the
  sentinel is present but its payload is not valid Base64.
  """
  @spec decode_header_value(String.t()) :: {:ok, String.t()} | :error
  def decode_header_value("=?base64?" <> rest) do
    case String.split(rest, "?=", parts: 2) do
      [encoded, ""] -> Base.decode64(encoded)
      _ -> :error
    end
  end

  def decode_header_value(value) when is_binary(value), do: {:ok, value}

  @doc """
  The value a request's `Mcp-Name` header must carry, or `nil` when the method
  does not name a subject.

  `tools/call` names it in `params.name`; `resources/read` names it in
  `params.uri`. The specification also names `prompts/get`, which this server
  does not implement and does not advertise a `prompts` capability for — a rule
  for a method that answers `404` is a rule for nobody, so it is added with the
  handler or not at all.
  """
  @spec named_subject(term()) :: String.t() | nil
  def named_subject(%{"method" => "tools/call", "params" => %{"name" => name}})
      when is_binary(name),
      do: name

  def named_subject(%{"method" => "resources/read", "params" => %{"uri" => uri}})
      when is_binary(uri),
      do: uri

  def named_subject(_), do: nil

  @doc """
  The revision this server implements and announces.
  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Every revision this server accepts, newest first.

  Returned by `server/discover` and in the `data.supported` of an
  `UnsupportedProtocolVersion` error, so a client can retry with something
  mutually understood instead of guessing.
  """
  @spec supported() :: [String.t()]
  def supported, do: @supported

  @doc """
  Whether this server can serve a request declaring `version`.
  """
  @spec supported?(term()) :: boolean()
  def supported?(version) when is_binary(version), do: version in @supported
  def supported?(_), do: false
end
