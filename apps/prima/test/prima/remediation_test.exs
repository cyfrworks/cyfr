# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.RemediationTest do
  # Typed consent errors produce remediation; string errors return :not_setup_error.
  use ExUnit.Case, async: true

  alias Prima.Remediation

  describe "setup_required" do
    test "names the unbound need and points at the consent walk" do
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

    test "an activation-level miss carries no need but still remediates" do
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
    test "renders a grant to make for the component, saying why" do
      ref = "reagent:local.weather"

      for {cause, message} <- [
            {:no_grant, "This app has not been granted yet"},
            {:revoked, "This app's grant was revoked; grant it again to continue"},
            {:shape_moved,
             "This app asks for more than its grant holds; review and grant it again to continue"}
          ] do
        assert Remediation.analyze({:consent_required, %{cause: cause, ref: ref}}) ==
                 {:setup_required,
                  %{
                    "component_ref" => ref,
                    "profile_id" => nil,
                    "message" => message,
                    "setup_command" => "cyfr profile grant #{ref}",
                    "issues" => [
                      %{
                        "type" => "consent_required",
                        "message" => message,
                        "fix" => %{
                          "tool" => "profile",
                          "action" => "plan",
                          "args" => %{"ref" => ref}
                        }
                      }
                    ]
                  }}
      end
    end
  end

  describe "the envelope is unchanged" do
    test "non-setup terms still report as such" do
      assert :not_setup_error = Remediation.analyze("some unrelated failure")
      assert :not_setup_error = Remediation.analyze({:something_else, %{}})
      assert :not_setup_error = Remediation.analyze(nil)
    end

    test "every typed remediation carries the keys the surfaces read" do
      for term <- [
            {:setup_required, %{profile_id: "p", node_ref: "r", need: "n", reason: :x}},
            {:consent_required,
             %{
               cause: :shape_moved,
               ref: "r",
               profile_id: "p",
               current_revision: 1,
               shape_diff: []
             }}
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
