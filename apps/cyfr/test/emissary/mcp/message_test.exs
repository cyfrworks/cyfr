# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.MessageTest do
  @moduledoc """
  Every refusal the gate classifies answers the MCP wire with its code:
  the row's override, a consent signal's own tag, or its class's code.
  The codec (`Prima.MCP.Message`) is pure; the classification and the
  override are the gate's, so this reads both through `Grimoire`.
  """
  use ExUnit.Case, async: true

  alias Prima.MCP.Message

  describe "refusal_code/3" do
    # Classified by the gate and answered with its row's override, as every
    # caller does: the override is what keeps a Sanctum row's code.
    defp code(reason, where \\ :tools_call) do
      refusal = Grimoire.classify(reason)

      refusal
      |> Message.refusal_code(where, Grimoire.code_override(refusal))
      |> Message.error_code()
    end

    test "each class answers with its code" do
      assert code({:invalid_argument, "x"}) == -32602
      assert code({:not_found, "component", "x"}, :resources_read) == -32002
      assert code({:not_found, "component", "x"}, :tools_call) == -32602
      assert code(:unauthenticated) == -33001
      assert code({:missing_permission, :execute}) == -33004
      assert code(:no_agent) == -33501
      assert code({:consent_required, %{}}) == -33502
      assert code(:rate_limited) == -33304
      assert code({:cancelled, "stopped"}) == -33305
      assert code({:conflict, "moved"}) == -33101
      assert code(:control_plane_lost) == -33102
      assert code(:database_error) == -33103
      assert code({:corrupt, {:digest, "The artifact"}}) == -33104
      assert code({:timeout, "slow"}) == -33105
      assert code(:outcome_unknown) == -33106
      assert code({:exit, "Tool x exited unexpectedly"}) == -33100
    end

    test "a store the authentication provider could not reach is unavailable, never auth_invalid" do
      assert code(:auth_provider_error) == -33103
    end

    test "the rows that answered with another code keep it" do
      for reason <- [:invalid_bearer, :invalid_api_key, :api_key_revoked],
          do: assert(code(reason) == -33002)

      assert code({:authorization_required, "grant expired"}) == -33001
    end

    test "the authorization rows without an override answer with their class's code" do
      # internal
      assert code(:malformed_record) == -33100
      assert code(:untagged_tenant_resource) == -33100
      assert code({:malformed_resource, :execution}) == -33100
      # unauthenticated
      assert code({:consent_class_required, :not_authenticated}) == -33001
      assert code(:missing_token) == -33001
    end

    test "a consent signal answers with its own tag's code" do
      assert code({:consent_conflict, %{}}) == -33503
      assert code({:restart_required, %{}}) == -33504
      assert code({:setup_required, %{}}) == -33501

      assert code({:confirmation_required, %{id: "confirmation-7f3a", operation: "vault/create"}}) ==
               -33505
    end

    test "a pending confirmation is neither a denial nor a consent to give" do
      signal = {:confirmation_required, %{id: "confirmation-7f3a"}}

      refute code(signal) in [
               code({:missing_permission, :execute}),
               code({:consent_required, %{}})
             ]

      assert Grimoire.classify(signal).class == :confirmation_required
    end

    test "a confirmation signal that names no confirmation is refused by shape" do
      ExUnit.CaptureLog.capture_log(fn ->
        assert code({:confirmation_required, %{operation: "vault/create"}}) == -33100
      end)
    end
  end
end
