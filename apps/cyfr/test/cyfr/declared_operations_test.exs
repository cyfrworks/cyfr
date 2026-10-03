# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.DeclaredOperationsTest do
  @moduledoc """
  The operations the identity, device and grant work declared: each is on
  the operation table with the annotations it is admitted under. Each new
  argument of an operation that existed before is decided, never dropped,
  so nothing reads as narrower, bounded or admitted when it is not. That
  no operation answers as a stub is `Cyfr.NoStubOperationsTest`'s.
  """

  use ExUnit.Case, async: false

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  @seed String.duplicate("A", 43)
  @digest "sha256:" <> String.duplicate("ab", 32)

  defp operation(tool, action) do
    {_provider, meta} = Map.fetch!(Grimoire.Catalog.operations(), tool)

    Enum.find(meta.operations, &(&1.action == action)) ||
      flunk("#{tool}.#{action} is not declared")
  end

  defp call(ctx, tool, action, args),
    do: Grimoire.call_external(tool, ctx, Map.put(args, "action", action))

  describe "the declared operations" do
    test "are on the table as their work will be admitted: interactive, external, never replayed" do
      for tool <- ~w(person pairing passkey confirmation) do
        {_provider, meta} = Map.fetch!(Grimoire.Catalog.operations(), tool)

        for op <- meta.operations do
          assert op.planes == [:external], "#{tool}.#{op.action}"
          assert op.recovery == nil, "#{tool}.#{op.action}"

          # A glass completing its pairing, and a device renewing at its
          # person's home, hold no session: their proof is their credential.
          if {tool, op.action} in [{"pairing", "complete"}, {"person", "renew_certificate"}] do
            assert {op.auth, op.consent, op.kind} == {:anonymous, nil, :write}
          else
            assert op.consent == :interactive, "#{tool}.#{op.action}"
            assert op.auth == :required, "#{tool}.#{op.action}"
          end
        end
      end

      for {tool, action} <- [
            {"pairing", "list"},
            {"passkey", "list"},
            {"confirmation", "pending"},
            {"person", "kit"},
            {"person", "carry_list"},
            {"person", "status"}
          ] do
        assert operation(tool, action).kind == :read, "#{tool}.#{action}"
      end

      # A carry is cancelled and listed as it is completed: on the same
      # plane and consent class, the list a read. Abandoning an unfinished
      # enrollment is a write that takes no arguments.
      assert operation("person", "enroll_abandon").args == []

      for action <- ~w(carry_cancel carry_complete enroll_abandon) do
        assert operation("person", action).kind == :write, "person.#{action}"
      end

      assert operation("passkey", "recover_admin").scope == :platform
      assert operation("pairing", "revoke").kind == :destructive
      assert operation("passkey", "revoke").kind == :destructive
    end

    test "a platform-scoped one refuses an ordinary member before its handler", %{ctx: ctx} do
      assert {:error, %Prima.Refusal{class: :forbidden, reason: :platform_admin_required}} =
               call(ctx, "passkey", "recover_admin", %{
                 "user_id" => "usr_1",
                 "passkey_id" => "psk_1",
                 "registration_digest" => @digest
               })
    end

    test "a recovery seed is a field the redaction vocabulary keeps out of every log" do
      assert Prima.Sanitizer.sensitive_key?("recovery_secret")
      assert Prima.Sanitizer.sensitive_key?("invitation_secret")

      sanitized =
        Prima.Sanitizer.sanitize(%{
          "recovery_secret" => @seed,
          "holder" => %{"kind" => "kit", "recovery_secret" => @seed}
        })

      refute inspect(sanitized) =~ @seed
    end
  end

  describe "a new argument of an operation that exists" do
    test "a member's identifier is decided, and stands alone", %{ctx: ctx} do
      identifier = "per_" <> String.duplicate("ab", 32)

      for action <- ~w(add remove) do
        for other <- [%{"email" => "someone@example.com"}, %{"user_id" => "usr_1"}] do
          assert {:error, {:invalid_argument, "Name one of email, user_id or identifier" <> _}} =
                   call(ctx, "member", action, Map.put(other, "identifier", identifier)),
                 "member.#{action}"
        end
      end
    end

    test "a grant's origins and narrowing are decided", %{ctx: ctx} do
      for extra <- [
            %{"origins" => ["interactive", "programmatic"]},
            %{"subset" => %{"reagent:local.x" => %{"egress" => %{"domains" => []}}}}
          ] do
        decisions = Map.merge(%{"ref" => "reagent:local.no-such-component"}, extra)

        # Decoded and carried into the walk, which finds no such component.
        assert call(ctx, "profile", "preview", %{"decisions" => decisions}) ==
                 {:error, "component_not_found"}
      end
    end

    test "the grant and run reads are answered", %{ctx: ctx} do
      # An athanor that granted nothing reaches nothing
      # (`Sanctum.Providers.ProfileGrantsTest`).
      assert call(ctx, "profile", "grants", %{"domain" => "api.example.com"}) ==
               {:ok,
                %{
                  resource: %{kind: "domain", value: "api.example.com"},
                  grants: [],
                  count: 0,
                  truncated: false
                }}

      # The profile is read first, so an unknown one is refused by name
      # (`Crucible.UsageTest`).
      assert call(ctx, "execution", "usage", %{"profile_id" => "prf_1"}) ==
               {:error, {:not_found, "Profile", "prf_1"}}
    end

    test "an approval's bounds are decided", %{ctx: ctx} do
      for bound <- [
            %{"lifecycle" => "turn"},
            %{"until" => "2026-10-01T00:00:00Z"},
            %{"constraint" => %{"kind" => "storage_path", "patterns" => ["data/notes/"]}}
          ] do
        args = Map.merge(%{"approval" => "apr_1", "decision" => "approve"}, bound)

        # Carried into the decision, which finds no such approval.
        assert call(ctx, "approval", "resolve", args) ==
                 {:error, {:not_found, "approval", "apr_1"}}
      end
    end

    test "a narrowing names the limits in their own vocabulary, and the origins in theirs" do
      decisions =
        Enum.find(operation("profile", "preview").args, &(&1.name == "decisions"))

      {:record, fields} = decisions.type
      origins = Enum.find(fields, &(&1.name == "origins"))
      assert {:array, %{enum: spellings}} = origins.type
      assert spellings == Prima.Origin.spellings()
      assert origins.min == 1

      subset = Enum.find(fields, &(&1.name == "subset"))
      assert {:map, %{type: {:record, kinds}}} = subset.type
      assert Enum.map(kinds, & &1.name) == ~w(egress storage tools limits)

      {:record, limits} = Enum.find(kinds, &(&1.name == "limits")).type

      assert Enum.map(limits, & &1.name) ==
               Enum.map(Prima.Limits.fields(), &Atom.to_string/1)
    end
  end
end
