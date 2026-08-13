# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.ErrorRenderer do
  @moduledoc """
  How an ingress plug says no.

  `Plugs.Authenticate`, `Plugs.MCPOrigin` and `Plugs.MCPRateLimit` decide
  *whether* to reject a request; the pipeline they are mounted in decides what
  the rejection looks like on the wire. The MCP endpoint answers in JSON-RPC
  (`EmissaryWeb.MCPError`); an ordinary HTTP route answers in plain JSON
  (`EmissaryWeb.ApiError`).

  Splitting it this way is what stops the two from drifting apart: one
  implementation of "is this caller who they say they are", two renderings. The
  alternative — a second copy of the credential logic for routes that do not
  speak JSON-RPC — is how an endpoint ends up answering a bad token with a
  JSON-RPC envelope carrying a null id, which is what `/api/executions/:id/events`
  did while it shared the MCP pipeline.

  `code` is an atom from `Emissary.MCP.Message`'s tables. Each renderer maps it
  to whatever its wire format calls an error code.
  """

  @doc "Render an error body and set the status."
  @callback send(Plug.Conn.t(), non_neg_integer(), atom() | integer(), String.t()) ::
              Plug.Conn.t()

  @doc "Render an error and halt the pipeline."
  @callback halt(Plug.Conn.t(), non_neg_integer(), atom() | integer(), String.t()) ::
              Plug.Conn.t()
end
