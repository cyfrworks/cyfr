# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.DeclaredOperationsTest do
  @moduledoc """
  The identity, device and grant operations: each is on the operation
  table with the annotations it is admitted under, and each argument that
  names a subject, narrows a grant or bounds an approval is decided, never
  dropped, so nothing reads as narrower, bounded or admitted when it is
  not.
  """

  use ExUnit.Case, async: false

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  @seed String.duplicate("A", 43)

  defp operation(tool, action) do
    {_provider, meta} = Map.fetch!(Sanctum.Catalog.operations(), tool)

    Enum.find(meta.operations, &(&1.action == action)) ||
      flunk("#{tool}.#{action} is not declared")
  end

  defp call(ctx, tool, action, args),
    do: Sanctum.Gate.call_external(tool, ctx, Map.put(args, "action", action))

  describe "the declared operations" do
    test "are on the table as they are admitted: interactive, external, never replayed" do
      for tool <- ~w(pairing confirmation) do
        {_provider, meta} = Map.fetch!(Sanctum.Catalog.operations(), tool)

        for op <- meta.operations do
          assert op.planes == [:external], "#{tool}.#{op.action}"
          assert op.recovery == nil, "#{tool}.#{op.action}"
          assert op.consent == :interactive, "#{tool}.#{op.action}"
          assert op.auth == :required, "#{tool}.#{op.action}"
        end
      end

      for action <- ~w(list end) do
        op = operation("session", action)
        assert op.planes == [:external], "session.#{action}"
        assert op.recovery == nil, "session.#{action}"
        assert op.consent == :interactive, "session.#{action}"
        assert op.auth == :required, "session.#{action}"
      end

      for {tool, action} <- [
            {"pairing", "list"},
            {"session", "list"},
            {"confirmation", "pending"}
          ] do
        assert operation(tool, action).kind == :read, "#{tool}.#{action}"
      end

      refute Map.has_key?(Sanctum.Catalog.operations(), "person")
      refute Map.has_key?(Sanctum.Catalog.operations(), "passkey")

      assert operation("pairing", "revoke").kind == :destructive
      assert operation("session", "end").kind == :destructive
    end

    test "a recovery secret and a recovery code are fields the redaction vocabulary keeps out of every log" do
      assert Prima.Sanitizer.sensitive_key?("recovery_secret")
      assert Prima.Sanitizer.sensitive_key?("recovery_code")
      assert Prima.Sanitizer.sensitive_key?("invitation_secret")

      code =
        Prima.RecoveryCode.encode("per_" <> String.duplicate("c", 64), :binary.copy(<<7>>, 32))

      # A recovery secret, a typed code and an answer's `code`, wherever
      # they appear.
      sanitized =
        Prima.Sanitizer.sanitize(%{
          "recovery_secret" => @seed,
          "recovery_code" => code,
          "holder" => %{"recovery_secret" => @seed},
          "answer" => %{"code" => code},
          "setup" => %{"recovery" => %{"code" => code}}
        })

      refute inspect(sanitized) =~ @seed
      refute inspect(sanitized) =~ code
    end
  end

  describe "an argument that names, narrows or bounds" do
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
      # (`Opus.UsageTest`).
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
      assert Enum.map(kinds, & &1.name) == ~w(egress storage tools limits exits)

      {:record, limits} = Enum.find(kinds, &(&1.name == "limits")).type

      assert Enum.map(limits, & &1.name) ==
               Enum.map(Prima.Limits.fields(), &Atom.to_string/1)
    end
  end
end
