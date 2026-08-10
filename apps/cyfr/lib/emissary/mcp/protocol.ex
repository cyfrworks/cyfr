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

  @doc "The `_meta` key carrying the protocol version of a request."
  @spec meta_protocol_version_key() :: String.t()
  def meta_protocol_version_key, do: @meta_protocol_version

  @doc "The `_meta` key carrying the calling client's identity."
  @spec meta_client_info_key() :: String.t()
  def meta_client_info_key, do: @meta_client_info

  @doc "The `_meta` key carrying the calling client's capabilities."
  @spec meta_client_capabilities_key() :: String.t()
  def meta_client_capabilities_key, do: @meta_client_capabilities

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

  `tools/call` and `prompts/get` name it in `params.name`; `resources/read`
  names it in `params.uri`.
  """
  @spec named_subject(term()) :: String.t() | nil
  def named_subject(%{"method" => method, "params" => %{"name" => name}})
      when method in ["tools/call", "prompts/get"] and is_binary(name),
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
