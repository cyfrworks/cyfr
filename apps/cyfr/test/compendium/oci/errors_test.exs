# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.ErrorsTest do
  use ExUnit.Case, async: true

  alias Compendium.OCI.Errors

  describe "from_response/3" do
    test "410 maps to :taken_down with status 410" do
      err = Errors.from_response(410, "", "registry.cyfr.run")

      assert %Errors{
               reason: :taken_down,
               status: 410,
               registry: "registry.cyfr.run",
               message: "Component taken down on registry.cyfr.run"
             } = err
    end

    test "410 with JSON error body lifts errors into detail" do
      body =
        Jason.encode!(%{"errors" => [%{"code" => "TAKEN_DOWN", "message" => "moderator action"}]})

      err = Errors.from_response(410, body, "registry.cyfr.run")

      assert err.reason == :taken_down
      assert [%{"code" => "TAKEN_DOWN"}] = err.detail
    end

    test "412 with POLICY_ACCEPTANCE_REQUIRED code maps to :policy_acceptance_required" do
      body =
        Jason.encode!(%{
          "errors" => [%{"code" => "POLICY_ACCEPTANCE_REQUIRED"}],
          "required_version" => "v3"
        })

      err = Errors.from_response(412, body, "cyfr.run")

      assert err.reason == :policy_acceptance_required
      assert err.status == 412
      assert err.detail.required_version == "v3"
    end

    test "412 with POLICY_VERSION_MISMATCH code maps to :policy_version_mismatch" do
      body =
        Jason.encode!(%{
          "errors" => [%{"code" => "POLICY_VERSION_MISMATCH"}],
          "required_version" => "v4"
        })

      err = Errors.from_response(412, body, "cyfr.run")

      assert err.reason == :policy_version_mismatch
      assert err.detail.required_version == "v4"
    end

    test "412 without a recognized code falls back to :manifest_invalid" do
      body = Jason.encode!(%{"errors" => [%{"code" => "UNKNOWN"}]})
      err = Errors.from_response(412, body, "cyfr.run")
      assert err.reason == :manifest_invalid
    end

    test "412 with no required_version sets detail.required_version to nil" do
      body = Jason.encode!(%{"errors" => [%{"code" => "POLICY_ACCEPTANCE_REQUIRED"}]})
      err = Errors.from_response(412, body, "cyfr.run")
      assert err.reason == :policy_acceptance_required
      assert err.detail.required_version == nil
    end

    test "404 maps to :not_found (regression — adding 410 must not shift other clauses)" do
      err = Errors.from_response(404, "", "registry.cyfr.run")
      assert err.reason == :not_found
      assert err.status == 404
    end

    test "5xx still routes to :registry_unavailable (catch-all order preserved)" do
      err = Errors.from_response(503, "", "registry.cyfr.run")
      assert err.reason == :registry_unavailable
      assert err.status == 503
    end
  end

  describe "actionable_hint/1" do
    test ":taken_down returns the moderator-removal hint with appeal pointer" do
      err = Errors.from_response(410, "", "registry.cyfr.run")
      hint = Errors.actionable_hint(err)
      assert hint =~ "moderators"
      assert hint =~ "appeal"
    end

    test "reason without a defined hint returns empty string" do
      # :manifest_invalid is one of the reasons with no specific actionable hint
      # — it falls through to the catch-all clause.
      assert Errors.actionable_hint(%Errors{reason: :manifest_invalid}) == ""
    end
  end

  describe "to_string/1" do
    test ":taken_down formats as message + status + reason suffix" do
      err = Errors.from_response(410, "", "registry.cyfr.run")

      assert Errors.to_string(err) ==
               "Component taken down on registry.cyfr.run (HTTP 410, taken_down)"
    end
  end

  describe "required_version/1" do
    @mismatch Jason.encode!(%{
                "errors" => [%{"code" => "POLICY_VERSION_MISMATCH"}],
                "required_version" => "2026-08-01"
              })

    test "reads the version a 412 names" do
      err = Errors.from_response(412, @mismatch, "cyfr.run")

      assert err.reason == :policy_version_mismatch
      assert Errors.required_version(err) == "2026-08-01"
    end

    test "reads it through the wrapper from_api_response/3 adds" do
      # The API builder replaces `detail` with %{operation:, original_detail:},
      # so a flat read of detail[:required_version] finds nothing here.
      err = Errors.from_api_response(412, @mismatch, "accept_policies")

      refute err.detail[:required_version]
      assert Errors.required_version(err) == "2026-08-01"
    end

    test "is nil when the error names no version" do
      assert Errors.required_version(Errors.from_response(500, "", "cyfr.run")) == nil
    end
  end
end
