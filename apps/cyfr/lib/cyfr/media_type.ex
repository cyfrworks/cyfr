# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.MediaType do
  @moduledoc """
  The one spelling of the fallback media types and of the text-vs-binary
  split.

  Content that doesn't say what it is defaults to `json/0` when this
  server's own providers produced it and to `binary/0` when the bytes are
  opaque. `binary_mime?/1` decides which MCP content field carries a
  resource on the wire (`blob` vs `text`). Specific types a handler knows
  ("image/png" for a PNG it just read) stay literal at their sites — this
  module owns only the defaults and the classification.
  """

  @json "application/json"
  @binary "application/octet-stream"

  @doc "The default media type for structured provider content."
  @spec json() :: String.t()
  def json, do: @json

  @doc "The default media type for opaque bytes."
  @spec binary() :: String.t()
  def binary, do: @binary

  @doc """
  Whether content of this media type is opaque bytes — carried base64 in
  an MCP `blob` field — rather than text carried verbatim in `text`.
  """
  @spec binary_mime?(String.t()) :: boolean()
  def binary_mime?(@binary), do: true
  def binary_mime?("image/" <> _), do: true
  def binary_mime?("audio/" <> _), do: true
  def binary_mime?("video/" <> _), do: true
  def binary_mime?("application/pdf"), do: true
  def binary_mime?("application/zip"), do: true
  def binary_mime?("application/gzip"), do: true
  def binary_mime?("application/wasm"), do: true
  def binary_mime?(_), do: false
end
