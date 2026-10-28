# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RegistryLiveTest do
  @moduledoc """
  The registry page's acts are requests the person's identity signs: an
  appeal of a takedown, the acceptance of the registry's policies, and a
  sync of their push tokens, which waits on a fresh confirmation. No
  identity provider is asked for any of them.

  The registry is `Sanctum.Test.RegistryStub`, which verifies each signed
  request under the person's head as the registry does.
  """
  use PrismWeb.ConnCase, async: false

  alias Sanctum.Test.RegistryStub

  setup %{conn: conn} do
    user = test_user()
    state = RegistryStub.enroll!(user.user_id)
    {:ok, conn: log_in_user(conn, user), user: user, state: state}
  end

  # The registry: the policy version answered to the page's load, every
  # other request verified under `state` and handed to `answer`.
  defp registry(state, answer) do
    RegistryStub.start!(fn
      %{method: "GET", path: "/v1/legal/version"} ->
        {200,
         RegistryStub.answer(%{
           "policy_version" => "2026-09",
           "policies" => [%{"name" => "terms", "title" => "Terms of Service", "sha256" => "x"}]
         })}

      %{method: "GET"} ->
        {404, ""}

      %{body: body} = request ->
        case RegistryStub.verify(body, state) do
          {:ok, signed} -> answer.(Map.put(request, :signed, signed))
          {:error, reason} -> flunk("the registry refused the request: #{inspect(reason)}")
        end
    end)
  end

  # `registry.whoami` names the person's publisher namespaces, and the page
  # lists each beside the personal one. The test registry is a closed
  # port, so the namespace is kept unconfirmed and its listing is refused.
  test "a publisher namespace the person holds a push token for is one the page reads",
       %{conn: conn, user: user} do
    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: seated_athanor().id}

    :ok =
      Compendium.Registry.CredentialStore.put_push_token(
        ctx,
        Compendium.RegistryHost.canonical_host(),
        "acme.dev",
        "cyfr_pt_fake_acme",
        "owner"
      )

    {view, _html} = mount_athanor(conn, "/registry")
    assert "acme.dev" in :sys.get_state(view.pid).socket.assigns.namespaces
  end

  test "an appeal is signed by the person's identity, with no sign-in method asked",
       %{conn: conn, state: state} do
    parent = self()

    registry(state, fn %{path: "/v1/appeals", signed: signed} ->
      send(parent, {:appealed, signed.body})
      {201, RegistryStub.answer(%{"id" => "apl_1"})}
    end)

    {view, _html} = mount_athanor(conn, "/registry")
    html = render_click(view, "open-appeal", %{"id" => "cmp_taken_down"})
    refute html =~ "GitHub"
    refute html =~ "provider"

    render_submit(view, "submit-appeal", %{"argument" => "This named the wrong component."})

    assert_receive {:appealed,
                    %{
                      "action_type" => "takedown",
                      "action_ref" => "cmp_taken_down",
                      "argument" => "This named the wrong component."
                    }}

    assert render(view) =~ "Appeal filed"
  end

  test "an appeal the registry cannot take keeps the form and what was typed",
       %{conn: conn, state: state} do
    registry(state, fn %{path: "/v1/appeals"} -> {503, "Bad Gateway"} end)

    {view, _html} = mount_athanor(conn, "/registry")
    render_click(view, "open-appeal", %{"id" => "cmp_taken_down"})

    {submitted, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        render_submit(view, "submit-appeal", %{"argument" => "Again."})
      end)

    assert submitted =~ "Submit failed"
    assert has_element?(view, "form[phx-submit=submit-appeal]")
    assert render(view) =~ "Again."
  end

  test "the registry's policies are shown, and accepting signs their version",
       %{conn: conn, state: state} do
    parent = self()

    registry(state, fn %{path: "/v1/legal/accept", signed: signed} ->
      send(parent, {:accepted, signed.body})
      {201, RegistryStub.answer(%{"accepted" => true})}
    end)

    {view, _html} = mount_athanor(conn, "/registry")
    html = render(view)
    assert html =~ "Terms of Service"
    assert html =~ "Accept version 2026-09"

    render_click(view, "accept-policy", %{"version" => "2026-09"})
    assert_receive {:accepted, %{"policy_version" => "2026-09"}}
    assert render(view) =~ "Accepted the registry"
  end

  test "a sync waits on a fresh confirmation and sends nothing until it is given",
       %{conn: conn, state: state} do
    registry(state, fn _request -> flunk("nothing is sent before the confirmation") end)

    {view, _html} = mount_athanor(conn, "/registry")
    assert render_click(view, "sync", %{}) =~ "Confirm the sync"
    refute_received {:registry_request, %{method: "POST"}}
  end
end
