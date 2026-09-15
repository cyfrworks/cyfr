# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderProtocol do
  @moduledoc """
  The version of the wire between `Locus.BuilderClient` and
  `Locus.BuilderService`, and the handshake both ends hold each other to.

  A build request carries the `cyfr-builder-protocol` header with
  `version/0` and `cyfr-version` with `release/0`. The service answers a
  request at any other protocol, or without one, with 409 before it reads
  the body, and every answer it gives — `/health` included — carries
  `protocol` and `version` in its body. The client refuses an answer at
  any other protocol, or without one. Either refusal names both ends'
  protocols and releases.

  Protocol 1. A request is `{source_files: {path: base64}, language,
  target_type, resolve}`. A successful answer is `{ok: true, digest, size,
  exports, language, target_type, logs}` with `wasm_base64` and, when the
  build left one, `lockfile` for a component, or `output_files: {path:
  base64}` for a tincture; a refused build is `{ok: false, error, logs}`.
  """

  @version 1

  @doc "The protocol this release speaks."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "This release's version, as the builder and the server report it."
  @spec release() :: String.t()
  def release, do: :locus |> Application.spec(:vsn) |> to_string()

  @doc "The request header carrying the protocol."
  def protocol_header, do: "cyfr-builder-protocol"

  @doc "The request header carrying the release."
  def release_header, do: "cyfr-version"

  @doc """
  Why a builder and this server cannot build together: the builder's
  protocol and release as it reported them (nil when it reported none)
  beside this release's.
  """
  @spec mismatch(term(), term()) :: String.t()
  def mismatch(builder_protocol, builder_release) do
    "the builder speaks #{describe(builder_protocol, builder_release)} and this server speaks " <>
      "#{describe(@version, release())}; run the builder image of the same release as this server"
  end

  @doc "The service's refusal of a client at another protocol."
  @spec refusal(term(), term()) :: String.t()
  def refusal(client_protocol, client_release) do
    "this builder speaks #{describe(@version, release())} and the server calling it speaks " <>
      "#{describe(client_protocol, client_release)}; run the builder image of the same release as the server"
  end

  defp describe(nil, _release), do: "no builder protocol (a release older than the handshake)"
  defp describe(protocol, nil), do: "builder protocol #{protocol}"
  defp describe(protocol, release), do: "builder protocol #{protocol} (release #{release})"
end
