# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.EmailVerificationTest do
  use ExUnit.Case, async: true

  alias Sanctum.Auth.EmailVerification

  defp extra(email_verified), do: %{raw_info: %{user: %{"email_verified" => email_verified}}}
  defp extra_missing, do: %{raw_info: %{user: %{}}}

  describe "missing email — rejected for every provider" do
    test "github with nil email" do
      assert {:error, :missing_email} = EmailVerification.verify(:github, nil, extra(true))
    end

    test "google with empty-string email" do
      assert {:error, :missing_email} = EmailVerification.verify(:google, "", extra(true))
    end

    test "oidcc with nil email" do
      assert {:error, :missing_email} = EmailVerification.verify(:oidcc, nil, extra(true))
    end
  end

  describe "github — absence of email_verified is accepted" do
    test "explicit true → :ok" do
      assert :ok = EmailVerification.verify(:github, "alice@example.com", extra(true))
    end

    test "explicit false → :email_not_verified" do
      assert {:error, :email_not_verified} =
               EmailVerification.verify(:github, "alice@example.com", extra(false))
    end

    test "missing email_verified claim → :ok (Ueberauth already filters unverified primaries)" do
      assert :ok = EmailVerification.verify(:github, "alice@example.com", extra_missing())
    end
  end

  describe "google — email_verified must be explicitly true" do
    test "explicit true → :ok" do
      assert :ok = EmailVerification.verify(:google, "bob@example.com", extra(true))
    end

    test "explicit false → :email_not_verified" do
      assert {:error, :email_not_verified} =
               EmailVerification.verify(:google, "bob@example.com", extra(false))
    end

    test "missing email_verified claim → :email_not_verified" do
      assert {:error, :email_not_verified} =
               EmailVerification.verify(:google, "bob@example.com", extra_missing())
    end

    test "stringly-typed \"true\" is not treated as true → :email_not_verified" do
      assert {:error, :email_not_verified} =
               EmailVerification.verify(:google, "bob@example.com", extra("true"))
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

  describe "alternate claim shapes" do
    test "atom :email_verified key" do
      extra = %{raw_info: %{user: %{email_verified: true}}}
      assert :ok = EmailVerification.verify(:google, "bob@example.com", extra)
    end

    test "stringly-keyed \"user\" map" do
      extra = %{raw_info: %{"user" => %{"email_verified" => true}}}
      assert :ok = EmailVerification.verify(:google, "bob@example.com", extra)
    end

    test "unrecognized shape → treated as missing claim" do
      assert {:error, :email_not_verified} =
               EmailVerification.verify(:google, "bob@example.com", %{})
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
