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

  @version "2025-11-25"

  @supported [@version]

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
