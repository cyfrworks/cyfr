# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenantPolicy do
  @moduledoc """
  Tenant boundary enforcement on resource access.

  Called from `Sanctum.Context.authorize/3` and the tenant gate:

  - `:platform` scope bypasses tenant checks (system/operator tasks).
  - `athanor_id` is required: `nil`/`""` are rejected with `:missing_tenant`.
    An authenticated context that has not resolved its athanor (via
    `Sanctum.Tenancy.resolve_into/2`) carries `nil` and is rejected here.
  - A record must carry `:athanor_id` and it must equal the context's —
    strict equality, no normalization: there is no sentinel a missing value
    could stand for, so a record without an athanor is malformed and refused.
  """

  alias Sanctum.Context
  require Logger

  @spec require_athanor(Context.t()) :: :ok | {:error, term()}
  def require_athanor(%Context{athanor_id: nil}), do: {:error, :missing_tenant}
  def require_athanor(%Context{athanor_id: ""}), do: {:error, :missing_tenant}
  def require_athanor(%Context{}), do: :ok

  @spec verify(Context.t(), map()) :: :ok | {:error, Sanctum.Unauthorized.reason()}
  def verify(%Context{scope: :platform}, _record), do: :ok

  def verify(%Context{athanor_id: athanor_id}, _record) when athanor_id in [nil, ""],
    do: {:error, :missing_tenant}

  def verify(%Context{athanor_id: athanor_id} = ctx, %{athanor_id: record_athanor})
      when is_binary(record_athanor) and record_athanor != "" do
    if athanor_id == record_athanor do
      :ok
    else
      Logger.warning(
        "[Sanctum.TenantPolicy] Tenant mismatch: " <>
          "ctx=#{athanor_id} record=#{record_athanor} user=#{ctx.user_id}"
      )

      {:error, :tenant_mismatch}
    end
  end

  def verify(%Context{} = ctx, record) do
    Logger.warning(
      "[Sanctum.TenantPolicy] Record without an athanor refused: " <>
        "user=#{ctx.user_id} keys=#{inspect(record |> Map.keys() |> Enum.sort())}"
    )

    {:error, :malformed_record}
  end
end
