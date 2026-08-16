# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.TestAuthProvider do
  @moduledoc false
  @behaviour Sanctum.Auth

  @impl true
  def authenticate(_params), do: {:error, :not_implemented}

  @impl true
  def current_user(_conn) do
    # The authenticated test user works in the same athanor as
    # `Sanctum.TestContext.local/0`, so fixtures written through one are
    # visible through the other.
    Sanctum.Context.build(
      user_id: "test_user",
      email: "test@example.com",
      provider: "test",
      permissions: [:*],
      athanor_id: Sanctum.TestContext.athanor_id(),
      namespace: "testns",
      authenticated: true
    )
  end
end
