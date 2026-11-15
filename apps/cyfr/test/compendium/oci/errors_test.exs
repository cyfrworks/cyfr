# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.ErrorsTest do
  use ExUnit.Case, async: true

  alias Compendium.OCI.Errors

  # A member change goes under the namespace's own push token, so a 403
  # to one is the caller's role there; any other 403 keeps its class.
  describe "from_api_response/3's 403" do
    @forbidden ~s({"errors":[{"code":"FORBIDDEN","message":"admin role required for this namespace"}]})

    test "to a member change is the administrator's role the change needs" do
      for operation <- ~w(add_member update_member remove_member) do
        err = Errors.from_api_response(403, @forbidden, operation)
        assert err.reason == :admin_required, operation

        assert Compendium.Providers.Shared.refusal(err) == %Prima.Refusal{
                 class: :forbidden,
                 reason: {:registry, :admin_required},
                 message:
                   "Only an administrator of this namespace can add, change or remove its members."
               }
      end
    end

    test "to anything else stays access denied" do
      for operation <- ~w(list_members list_tokens issue_additional_token revoke_token deprecate) do
        err = Errors.from_api_response(403, @forbidden, operation)
        assert err.reason == :unauthorized, operation

        assert %Prima.Refusal{reason: {:registry, :unauthorized}} =
                 Compendium.Providers.Shared.refusal(err)
      end
    end
  end

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

    test "400 carries the registry's own message as the sentence" do
      body =
        Jason.encode!(%{
          "errors" => [%{"code" => "INVALID_CATEGORY", "message" => "unknown category"}]
        })

      assert Errors.from_response(400, body, "cyfr.run") == %Errors{
               reason: :invalid_request,
               message: "unknown category",
               registry: "cyfr.run",
               status: 400,
               detail: [%{"code" => "INVALID_CATEGORY", "message" => "unknown category"}]
             }
    end

    test "400's message is shown with a credential it echoes redacted" do
      secret = Prima.CredentialShape.mint(:confirmation_secret)
      body = Jason.encode!(%{"errors" => [%{"message" => "unknown reference #{secret}"}]})

      assert %Errors{reason: :invalid_request, message: "unknown reference [REDACTED]"} =
               Errors.from_response(400, body, "cyfr.run")
    end

    test "400 without a message says the registry refused the request" do
      assert Errors.from_response(400, "<html>bad request</html>", "cyfr.run") == %Errors{
               reason: :invalid_request,
               message: "Request refused by cyfr.run",
               registry: "cyfr.run",
               status: 400,
               detail: "<html>bad request</html>"
             }
    end

    test "404 maps to :not_found, beside 410's :taken_down" do
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
      assert hint =~ "removed by registry.cyfr.run's moderators"
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
end
