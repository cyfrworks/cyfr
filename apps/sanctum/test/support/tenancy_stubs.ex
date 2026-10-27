# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.FailingResolver do
  @moduledoc """
  Test double that always returns `{:error, :resolve_failed}` from `resolve/1`.
  Wired via `config :sanctum, :tenancy_resolver_override`. Used by tests that
  exercise the resolver-failure path (`Sanctum.Tenancy.resolve_status/2`
  refusing, and logging, when the resolver cannot answer).
  """
  def resolve(_user_id), do: {:error, :resolve_failed}
end

defmodule Sanctum.Test.OtherAthanorResolver do
  @moduledoc """
  Test double that always resolves to a *different* athanor than any
  key/context carries. Wired via `config :sanctum, :tenancy_resolver_override`.
  Used to prove the API-key path does NOT consult the configured resolver: if
  it did, the resulting context would carry "ath_other" instead of the key's
  own athanor.
  """
  def resolve(_user_id), do: %{athanor_id: "ath_other"}
end
