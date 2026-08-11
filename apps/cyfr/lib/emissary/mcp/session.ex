# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.Session do
  @moduledoc """
  The per-request bundle a dispatched MCP call runs under.

  Despite the name there is no session. MCP 2026-07-28 removed protocol-level
  sessions: every request carries its own credential and its own protocol
  version, and the server resolves both per request. What is left is a struct
  that pairs a `%Sanctum.Context{}` with an id for correlation, built fresh for
  each request and discarded with it.

  ## What this used to be

  A stored, 24-hour, `Arca.Cache`-backed session with a lifecycle: `create/3`
  minted one and returned an `Mcp-Session-Id`, `hydrate/4` rebuilt one from a
  persistent token, `update_capabilities/2` recorded what the handshake had
  negotiated, and `terminate/1` ended it. All of that is gone with the handshake
  that justified it, along with `for_credential/2`, which existed only to give a
  bearer caller's `POST` and its separate `GET` progress stream a shared key —
  progress now travels on the request's own response stream, so there is nothing
  left to correlate.

  Keeping the name is deliberate: it is what the dispatch layer and every tool
  provider call the thing they are handed, and renaming it would touch far more
  code than it would clarify.
  """

  alias Emissary.UUID7
  alias Sanctum.Context

  @type t :: %__MODULE__{
          id: String.t(),
          context: Context.t(),
          capabilities: map()
        }

  defstruct [:id, :context, capabilities: %{}]

  @doc """
  Build the request-scoped session for `context`.

  The id is correlation only — it appears in logs and telemetry and grants
  nothing. It is minted rather than derived from the caller's credential, which
  an earlier version did: that hashed the raw token, and before that persisted it
  verbatim into `mcp_logs.session_id`.
  """
  @spec ephemeral(Context.t() | nil) :: t()
  def ephemeral(%Context{} = context) do
    %__MODULE__{id: "req_" <> UUID7.generate(), context: context, capabilities: %{}}
  end

  # The plug always assigns a context before the controller runs, so this is
  # reachable only from a caller that skipped the pipeline — a test, in practice.
  # Fail to the least authority rather than to a crash.
  def ephemeral(nil) do
    ephemeral(
      Context.build(
        user_id: nil,
        org_id: nil,
        permissions: [],
        scope: :project,
        auth_method: nil,
        authenticated: false
      )
    )
  end
end
