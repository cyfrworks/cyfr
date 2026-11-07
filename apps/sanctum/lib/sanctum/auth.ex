# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth do
  @moduledoc """
  Behaviour for a bearer-credential provider, the test harness's seam
  (`current_user/1`). No shipped module signs anyone in through it: a
  person signs in with their account (`Sanctum.SignIn`).

  `authenticate/1` returns a `Sanctum.Context` for the credentials it is
  handed; whose they are, and whether they may sign in, is never the
  provider's decision.
  """

  alias Sanctum.Context

  @doc """
  Authenticate with provided credentials/params.

  Returns `{:ok, context}` on success, `{:error, reason}` on failure.
  """
  @callback authenticate(params :: map()) :: {:ok, Context.t()} | {:error, term()}

  @doc """
  The context a bearer credential of the method's OWN issue names, or
  `nil` when the request carries none it recognises.

  Sessions and API keys are this server's credentials, established by
  `Sanctum.Caller.establish/2` before anything else is asked, and a
  shipped method issues no credential of its own, so it answers `nil`.
  The callback is the test harness's seam: `CyfrWeb.ConnCase` installs
  `Emissary.TestAuthProvider` as `:sanctum, :bearer_provider`, whose
  bearer `CyfrWeb.Plugs.Authenticate` reads into a person's context
  through the same establish recipe as a session's. A release sets none.
  """
  @callback current_user(conn :: Plug.Conn.t()) :: Context.t() | nil
end
