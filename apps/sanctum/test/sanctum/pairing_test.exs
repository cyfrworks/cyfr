# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PairingTest do
  @moduledoc """
  Confirmation authority: the class a client holds from its standing, the
  closed table of what each action requires, and the check the consent
  decision makes — a `none` client confirms nothing, and an action whose
  class no client holds waits rather than degrading.
  """

  use ExUnit.Case, async: true

  alias Sanctum.Consent.Authz
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

  describe "class_of/1" do
    test "an authenticated browser session or API key is a session client" do
      assert Pairing.class_of(ctx(auth_method: :oidc)) == :session
      assert Pairing.class_of(ctx(auth_method: :api_key, api_key_type: :admin)) == :session
    end

    test "every other context is a none client" do
      nones = [
        ctx(auth_method: :oidc, plane: :guest),
        ctx(auth_method: :api_key, plane: :guest),
        ctx(auth_method: :session),
        ctx(auth_method: :tincture),
        ctx(auth_method: :webhook),
        ctx(auth_method: :scheduled),
        ctx(auth_method: :system),
        ctx(auth_method: :oidc, anonymous: true),
        Context.build(%{auth_method: :oidc, authenticated: false})
      ]

      for context <- nones,
          do: assert(Pairing.class_of(context) == :none, inspect(context.auth_method))
    end

    test "no client holds paired or strong yet" do
      for method <- [:oidc, :api_key, :session, :tincture, :webhook, :scheduled, :system] do
        refute Pairing.class_of(ctx(auth_method: method)) in [:paired, :strong]
      end
    end
  end

  describe "required_class/1" do
    test "the table is closed and reads as the policy says" do
      assert Pairing.actions() ==
               Enum.sort([
                 :grant,
                 :approval,
                 :credential_entry,
                 :vault_unlock,
                 :home_transfer,
                 :pairing_revocation
               ])

      for action <- [:grant, :approval, :credential_entry, :vault_unlock],
          do: assert(Pairing.required_class(action) == :session)

      for action <- [:home_transfer, :pairing_revocation],
          do: assert(Pairing.required_class(action) == :strong)

      assert_raise FunctionClauseError, fn -> Pairing.required_class(:anything) end
    end
  end

  describe "confirm?/2" do
    test "a session client confirms grants, approvals, credential entry and the vault unlock" do
      session = ctx(auth_method: :oidc)

      for action <- [:grant, :approval, :credential_entry, :vault_unlock],
          do: assert(Pairing.confirm?(session, action) == :ok)
    end

    test "a none client presenting a confirmation is refused, whatever it asks" do
      for context <- [ctx(auth_method: :oidc, plane: :guest), ctx(auth_method: :tincture)],
          action <- Pairing.actions() do
        assert Pairing.confirm?(context, action) == {:error, :class_too_low}
      end
    end

    test "an action whose class no client holds waits: it never degrades to session" do
      session = ctx(auth_method: :oidc)

      for action <- [:home_transfer, :pairing_revocation] do
        assert Pairing.confirm?(session, action) == {:error, :class_too_low}
        assert Pairing.required_class(action) == :strong
      end
    end

    test "an action the table does not name is never confirmed" do
      assert Pairing.confirm?(ctx(auth_method: :oidc), :delete_everything) ==
               {:error, :class_too_low}
    end
  end

  describe "the consent decision" do
    test "a session client's grant passes the class check" do
      request = %Authz.Request{commit_digest: "sha256:commit"}
      assert Authz.authorize(ctx(auth_method: :oidc), request) == {:ok, :interactive}
    end

    test "a none client never confirms a grant" do
      request = %Authz.Request{commit_digest: "sha256:commit"}

      for context <- [
            ctx(auth_method: :oidc, plane: :guest),
            ctx(auth_method: :session),
            ctx(auth_method: :tincture)
          ] do
        assert {:error, _} = Authz.authorize(context, request)
      end
    end

    test "the class refusal renders through the vocabulary's owner" do
      assert Authz.message(:class_too_low) =~ "cannot confirm"
    end
  end
end
