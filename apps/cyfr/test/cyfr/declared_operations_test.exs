# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.DeclaredOperationsTest do
  @moduledoc """
  The operations declared ahead of the work that fills them: each is on
  the operation table with the annotations it will be admitted under, and
  answers `{:error, :not_built}` through the gate — a refusal, never a
  success — until that work lands. So does each new argument of an
  operation that exists: given, it refuses rather than being dropped, so
  nothing reads as narrower, bounded or admitted when it is not.
  """

  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  @seed String.duplicate("A", 43)
  @digest "sha256:" <> String.duplicate("ab", 32)

  # Each declared action with arguments its declaration accepts.
  @stubs [
    {"person", "enroll", %{"recovery_secret" => @seed, "request_id" => "req_1"}},
    {"person", "rotate", %{"request_id" => "req_1"}},
    {"person", "kit", %{"attempt_id" => "att_1"}},
    {"person", "kit_ack", %{"attempt_id" => "att_1"}},
    {"person", "link_door", %{"provider" => "github", "ticket" => "tkt_1"}},
    {"person", "unlink_door", %{"door" => "github|https://github.com|1"}},
    {"person", "enroll_holder",
     %{
       "recovery_secret" => @seed,
       "holder" => %{"kind" => "kit", "recovery_secret" => @seed},
       "request_id" => "req_1"
     }},
    {"person", "carry_begin", %{"destination" => "https://hub.example.com"}},
    {"person", "carry_complete", %{"action_id" => "act_1", "outcome" => "admitted"}},
    {"person", "certify",
     %{
       "device_key" => @seed,
       "audience" => "https://hub.example.com",
       "athanor" => "ath_1",
       "client_id" => "pcl_1"
     }},
    {"person", "assert",
     %{
       "audience" => "https://hub.example.com",
       "challenge" => "chl_1",
       "action_id" => "act_1",
       "key_epoch" => @digest
     }},
    {"passkey", "register", %{}},
    {"passkey", "list", %{}},
    {"passkey", "revoke", %{"passkey_id" => "psk_1"}},
    {"confirmation", "confirm", %{"id" => "cnf_1"}},
    {"confirmation", "reauth", %{"id" => "cnf_1", "method" => "email"}},
    {"confirmation", "pending", %{}},
    {"confirmation", "cancel", %{"id" => "cnf_1"}}
  ]

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

          if {tool, op.action} == {"pairing", "complete"} do
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
            {"person", "kit"}
          ] do
        assert operation(tool, action).kind == :read, "#{tool}.#{action}"
      end

      assert operation("passkey", "recover_admin").scope == :platform
      assert operation("pairing", "revoke").kind == :destructive
      assert operation("passkey", "revoke").kind == :destructive
    end

    test "answer not built through the gate, never a success", %{ctx: ctx} do
      for {tool, action, args} <- @stubs do
        assert call(ctx, tool, action, args) == {:error, :not_built}, "#{tool}.#{action}"
      end

      # The platform administrator's authorization of a pending passkey.
      admin = %{ctx | platform_admin: true}

      assert call(admin, "passkey", "recover_admin", %{
               "user_id" => "usr_1",
               "passkey_id" => "psk_1",
               "registration_digest" => @digest
             }) == {:error, :not_built}
    end

    test "a stub's answer reads as unavailable, in its own sentence, and logs nothing unexpected",
         %{ctx: ctx} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for {tool, action, args} <- @stubs do
            {:error, reason} = call(ctx, tool, action, args)

            assert %Prima.Refusal{
                     class: :unavailable,
                     message: "This operation is not built yet."
                   } = Prima.Refusal.classify(reason),
                   "#{tool}.#{action}"
          end
        end)

      refute log =~ "unexpected message: :not_built"
    end

    test "a platform-scoped one refuses an ordinary member before its handler", %{ctx: ctx} do
      assert {:error, reason} =
               call(ctx, "passkey", "recover_admin", %{
                 "user_id" => "usr_1",
                 "passkey_id" => "psk_1",
                 "registration_digest" => @digest
               })

      refute reason == :not_built
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
    test "an identifier adds no member yet, and stands alone", %{ctx: ctx} do
      identifier = "per_" <> String.duplicate("ab", 32)

      assert call(ctx, "member", "add", %{"identifier" => identifier}) == {:error, :not_built}

      assert {:error, {:invalid_argument, _}} =
               call(ctx, "member", "add", %{
                 "identifier" => identifier,
                 "email" => "someone@example.com"
               })
    end

    test "the door takes no identifier entry yet", %{ctx: ctx} do
      admin = %{ctx | platform_admin: true}
      identifier = "per_" <> String.duplicate("ab", 32)

      for action <- ~w(allow deny) do
        assert call(admin, "door", action, %{"value" => identifier, "kind" => "identifier"}) ==
                 {:error, :not_built}
      end
    end

    test "a grant's origins and narrowing are decided, never refused as not built",
         %{ctx: ctx} do
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

    test "the grant and run reads are answered, never refused as not built", %{ctx: ctx} do
      # An athanor that granted nothing reaches nothing
      # (`Sanctum.Providers.ProfileGrantsTest`).
      assert call(ctx, "profile", "grants", %{"domain" => "api.example.com"}) ==
               {:ok,
                %{resource: %{kind: "domain", value: "api.example.com"}, grants: [], count: 0}}

      # The profile is read first, so an unknown one is refused by name
      # (`Crucible.UsageTest`).
      assert call(ctx, "execution", "usage", %{"profile_id" => "prf_1"}) ==
               {:error, {:not_found, "Profile", "prf_1"}}
    end

    test "an approval's bounds are decided, never refused as not built", %{ctx: ctx} do
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
