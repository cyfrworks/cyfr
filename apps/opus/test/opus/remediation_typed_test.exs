# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RemediationTypedTest do
  # The typed §4.3 path: an unbound need or a drifted consent is known
  # structurally at resolution time, so remediation is built from the
  # payload rather than recovered from prose. Typed terms are the only
  # source — string reasons always report :not_setup_error.
  use ExUnit.Case, async: false

  alias Opus.Remediation

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  describe "setup_required" do
    test "names the unbound need and points at the consent walk", %{ctx: ctx} do
      payload = %{
        profile_id: "prof-x",
        node_ref: "catalyst:local.gmail",
        need: "@ingress",
        reason: :unbound_need
      }

      assert {:setup_required, remediation} = Remediation.analyze({:setup_required, payload})

      assert remediation["component_ref"] == "catalyst:local.gmail"
      assert remediation["profile_id"] == "prof-x"
      assert remediation["setup_command"] == "cyfr profile grant catalyst:local.gmail"
      assert remediation["message"] =~ "@ingress"

      assert [%{"type" => "unbound_need", "fix" => fix} | _] = remediation["issues"]
      assert fix["tool"] == "profile"
      assert fix["action"] == "plan"
    end

    test "an activation-level miss carries no need but still remediates", %{ctx: ctx} do
      payload = %{
        profile_id: "prof-y",
        node_ref: "formula:local.report",
        need: "",
        reason: :unresolvable_target
      }

      assert {:setup_required, remediation} = Remediation.analyze({:setup_required, payload})

      assert remediation["message"] =~ "needs setup"
      refute Enum.any?(remediation["issues"], &(&1["type"] == "unbound_need"))
    end
  end

  describe "consent_required" do
    test "renders as an approve-to-continue remediation", %{ctx: ctx} do
      payload = %{profile_id: "prof-z", current_revision: 3, shape_diff: []}

      assert {:setup_required, remediation} =
               Remediation.analyze({:consent_required, payload})

      assert remediation["profile_id"] == "prof-z"
      assert remediation["message"] =~ "permissions changed"
      assert [%{"type" => "consent_required", "fix" => fix}] = remediation["issues"]
      assert fix["action"] == "plan"
    end
  end

  describe "the envelope is unchanged" do
    test "non-setup terms still report as such", %{ctx: ctx} do
      assert :not_setup_error = Remediation.analyze("some unrelated failure")
      assert :not_setup_error = Remediation.analyze({:something_else, %{}})
      assert :not_setup_error = Remediation.analyze(nil)
    end

    test "every typed remediation carries the keys the surfaces read", %{ctx: ctx} do
      for term <- [
            {:setup_required, %{profile_id: "p", node_ref: "r", need: "n", reason: :x}},
            {:consent_required, %{profile_id: "p", current_revision: 1, shape_diff: []}}
          ] do
        assert {:setup_required, remediation} = Remediation.analyze(term)

        for key <- ["component_ref", "message", "setup_command", "issues"] do
          assert Map.has_key?(remediation, key), "#{inspect(term)} lost #{key}"
        end

        assert is_list(remediation["issues"])
      end
    end
  end
end
