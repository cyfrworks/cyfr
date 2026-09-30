# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PairingTest do
  @moduledoc """
  Which changes need a fresh confirmation, and which clients can give
  one: the closed action table, the operations that confirm each action,
  the requirement no change asks for before a proof exists, and a client
  with no person behind it confirming nothing. No rank is held anywhere.
  """

  use ExUnit.Case, async: true

  alias Sanctum.Context
  alias Sanctum.Pairing

  defp ctx(attrs) do
    Context.build(
      Map.merge(
        %{user_id: "usr_pair", athanor_id: "ath_pair", authenticated: true, permissions: [:*]},
        Map.new(attrs)
      )
    )
  end

  @sensitive [
    :credential_entry,
    :credential_issuance,
    :vault_unlock,
    :home_transfer,
    :pairing_revocation,
    :recovery_material,
    :device_pairing,
    :passkey_registration,
    :remote_sign_in,
    :key_rotation,
    :sign_in_methods
  ]

  describe "the action table" do
    test "is closed: today's rows and the seven this plan adds" do
      assert Pairing.actions() == Enum.sort([:grant, :approval | @sensitive])
    end

    test "a grant and an approval need the session alone; every other action is sensitive" do
      refute Pairing.sensitive?(:grant)
      refute Pairing.sensitive?(:approval)
      for action <- @sensitive, do: assert(Pairing.sensitive?(action), inspect(action))

      assert_raise FunctionClauseError, fn -> Pairing.sensitive?(:anything) end
    end

    test "each operation that confirms something maps to its action, and no other does" do
      expected = %{
        "vault.create" => :credential_entry,
        "vault.rotate" => :credential_entry,
        "vault.authorize" => :credential_entry,
        "oauth.set_client" => :credential_entry,
        "key.create" => :credential_issuance,
        "key.rotate" => :credential_issuance,
        "webhook.create" => :credential_issuance,
        "webhook.rotate" => :credential_issuance,
        "pairing.revoke" => :pairing_revocation,
        "person.enroll" => :recovery_material,
        "person.kit" => :recovery_material,
        "person.enroll_holder" => :recovery_material,
        "passkey.register" => :passkey_registration,
        "passkey.revoke" => :passkey_registration,
        "passkey.recover_admin" => :passkey_registration,
        "pairing.begin" => :device_pairing,
        "person.certify" => :device_pairing,
        "person.assert" => :remote_sign_in,
        "person.rotate" => :key_rotation,
        "person.link_door" => :sign_in_methods,
        "person.unlink_door" => :sign_in_methods
      }

      for {operation, action} <- expected do
        assert Pairing.action_for(operation) == action, operation
        assert action in Pairing.actions()
      end

      # The unlock and the transfer have no operation yet, and a read or an
      # everyday change confirms nothing.
      for operation <- ~w(vault.list vault.rename key.revoke profile.commit person.kit_ack
                          pairing.complete pairing.list vault/create) do
        assert Pairing.action_for(operation) == nil, operation
      end
    end
  end

  describe "fresh_required?/2" do
    test "asks for no proof before one can be given, for any action or caller" do
      for action <- Pairing.actions(),
          context <- [ctx(auth_method: :oidc), ctx(auth_method: :api_key)] do
        refute Pairing.fresh_required?(action, context)
      end

      assert_raise FunctionClauseError, fn ->
        Pairing.fresh_required?(:delete_everything, ctx(auth_method: :oidc))
      end
    end
  end

  describe "can_confirm?/1" do
    test "a signed-in browser session has a person behind it who can give a proof" do
      assert Pairing.can_confirm?(ctx(auth_method: :oidc))
    end

    test "a client with no person behind it confirms nothing" do
      nobody = [
        ctx(auth_method: :oidc, plane: :guest),
        ctx(auth_method: :api_key, api_key_type: :admin),
        ctx(auth_method: :api_key, plane: :guest),
        ctx(auth_method: :session),
        ctx(auth_method: :tincture),
        ctx(auth_method: :webhook),
        ctx(auth_method: :scheduled),
        ctx(auth_method: :system),
        ctx(auth_method: :oidc, anonymous: true),
        Context.build(%{auth_method: :oidc, authenticated: false})
      ]

      for context <- nobody,
          do: refute(Pairing.can_confirm?(context), inspect(context.auth_method))
    end

    test "a paired device confirms nothing until its paired client's standing is read" do
      refute Pairing.can_confirm?(ctx(auth_method: :device, client_id: "pcl_1"))
      refute Pairing.can_confirm?(ctx(auth_method: :oidc, client_id: "pcl_1"))
    end
  end
end
