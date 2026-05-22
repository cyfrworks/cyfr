# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.TestAuthProvider do
  @moduledoc false
  @behaviour Sanctum.Auth

  @impl true
  def authenticate(_params), do: {:error, :not_implemented}

  @impl true
  def current_user(_conn) do
    # Mirrors a single-operator deployment: the authenticated user is resolved
    # to the seeded local/default workspace.
    Sanctum.Context.build(
      user_id: "test_user",
      email: "test@example.com",
      provider: "test",
      permissions: [:*],
      org_id: "local",
      project_id: "default",
      namespace: "testns",
      authenticated: true
    )
  end
end