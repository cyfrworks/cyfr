# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.EmailVerificationTest do
  use ExUnit.Case, async: true

  alias Sanctum.Auth.EmailVerification

  defp extra(email_verified), do: %{raw_info: %{userinfo: %{"email_verified" => email_verified}}}
  defp extra_missing, do: %{raw_info: %{userinfo: %{}}}

  describe "missing email — rejected for every provider" do
    test "oidcc with nil email" do
      assert {:error, :missing_email} = EmailVerification.verify(:oidcc, nil, extra(true))
    end

    test "an unknown provider with an empty-string email" do
      assert {:error, :missing_email} = EmailVerification.verify(:custom, "", extra(true))
    end
  end

  describe "oidcc (generic OIDC) — email_verified absence accepted, explicit false rejected" do
    test "explicit true → :ok" do
      assert :ok = EmailVerification.verify(:oidcc, "carol@acme.com", extra(true))
    end

    test "explicit false → :email_not_verified" do
      assert {:error, :email_not_verified} =
               EmailVerification.verify(:oidcc, "carol@acme.com", extra(false))
    end

    test "missing claim → :ok (enterprise IdPs don't always emit email_verified)" do
      assert :ok = EmailVerification.verify(:oidcc, "carol@acme.com", extra_missing())
    end
  end

  describe "the real ueberauth_oidcc shape" do
    # `%UeberauthOidcc.RawInfo{}` carries `opts/claims/userinfo/introspection`;
    # the arms are only real if they read what the strategy actually builds
    # (`Ueberauth.Strategy.Oidcc.extra/1`).
    defp oidcc(fields), do: %{raw_info: struct!(UeberauthOidcc.RawInfo, fields)}

    test "userinfo email_verified is read" do
      assert :ok =
               EmailVerification.verify(
                 :oidcc,
                 "carol@acme.com",
                 oidcc(userinfo: %{"email_verified" => true})
               )

      assert {:error, :email_not_verified} =
               EmailVerification.verify(
                 :oidcc,
                 "carol@acme.com",
                 oidcc(userinfo: %{"email_verified" => false})
               )
    end

    test "id-token claims are read when userinfo is absent" do
      assert :ok =
               EmailVerification.verify(
                 :oidcc,
                 "carol@acme.com",
                 oidcc(claims: %{"email_verified" => true})
               )

      assert {:error, :email_not_verified} =
               EmailVerification.verify(
                 :oidcc,
                 "carol@acme.com",
                 oidcc(claims: %{"email_verified" => false})
               )
    end

    test "userinfo wins over the id token" do
      extra = oidcc(claims: %{"email_verified" => true}, userinfo: %{"email_verified" => false})

      assert {:error, :email_not_verified} =
               EmailVerification.verify(:oidcc, "carol@acme.com", extra)
    end

    test "silence is still accepted for generic OIDC" do
      assert :ok = EmailVerification.verify(:oidcc, "carol@acme.com", oidcc(claims: %{}))
    end

    test "a proven address reaches the door as `true`, so an email entry can admit it" do
      # `Door.admit/3` only consults an exact email allowlist entry on `true`;
      # while this read returned `:unknown` for every OIDC sign-in, allowlisting
      # an address by email could never let anyone in.
      assert {:ok, true} =
               EmailVerification.verify_with_claim(
                 :oidcc,
                 "carol@acme.com",
                 oidcc(userinfo: %{"email_verified" => true})
               )

      assert {:ok, :unknown} =
               EmailVerification.verify_with_claim(:oidcc, "carol@acme.com", oidcc(claims: %{}))
    end
  end

  describe "unknown provider — fail closed" do
    test "rejects when email_verified is false" do
      assert {:error, :email_not_verified} =
               EmailVerification.verify(:custom, "x@y.com", extra(false))
    end

    test "rejects when the email_verified claim is absent" do
      assert {:error, :email_not_verified} =
               EmailVerification.verify(:custom, "x@y.com", extra_missing())
    end

    test "accepts only with an explicit email_verified == true" do
      assert :ok = EmailVerification.verify(:custom, "x@y.com", extra(true))
    end
  end
end
