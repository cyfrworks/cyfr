# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RegistryLiveTest do
  @moduledoc """
  Appealing a registry takedown runs a device flow, and a device flow can
  fail for reasons that have nothing to do with the person: a provider
  blip, a dropped connection, a timeout.

  Every other end of that poll — expired, denied — put the panel back on
  its form. The error arm did not: it wrote the message and left the state
  at `:waiting`. Nothing reschedules the poll from there, and `start-appeal`
  deliberately refuses to run while a flow is out (a second click would
  mint a second code and orphan the first), so the panel was wedged until
  the page was reloaded — losing the argument the person had typed.

  `LoginLive` handles the identical case correctly, which is what made this
  worth pinning on both sides: the message AND the state it leaves behind.
  """
  use PrismWeb.ConnCase, async: false

  defmodule FakeDeviceFlow do
    @moduledoc false

    # See LoginLiveTest's fake: the appeal flow is the second anonymous
    # device flow on a socket that passes no rate-limit plug, so the
    # address it budgets against is recorded and asserted.
    def init_device_flow(provider, client_ip) when provider in [:github, :google] do
      Application.put_env(:cyfr, :device_flow_last_ip, client_ip)

      {:ok,
       %{
         device_code: "dev-code",
         user_code: "WXYZ-1234",
         verification_uri: "https://github.com/login/device",
         expires_in: 900,
         interval: 60
       }}
    end

    def poll_for_access_token(_provider, _code, client_ip) do
      Application.put_env(:cyfr, :device_flow_last_ip, client_ip)
      Application.get_env(:cyfr, :device_flow_poll_result, {:ok, %{status: "pending"}})
    end
  end

  setup %{conn: conn} do
    original = Application.get_env(:cyfr, :device_flow)
    Application.put_env(:cyfr, :device_flow, FakeDeviceFlow)

    on_exit(fn ->
      Application.delete_env(:cyfr, :device_flow_poll_result)

      if original,
        do: Application.put_env(:cyfr, :device_flow, original),
        else: Application.delete_env(:cyfr, :device_flow)
    end)

    {view, _html} = conn |> log_in_user(test_user()) |> mount_athanor("/registry")
    {:ok, view: view}
  end

  defp open_appeal(view) do
    render_click(view, "open-appeal", %{"id" => "reagent:acme.widget:1.0.0"})
  end

  defp start_appeal(view) do
    render_submit(view, "start-appeal", %{
      "argument" => "This takedown named the wrong component.",
      "provider" => "github"
    })
  end

  test "a poll error returns the appeal to its form, and the appeal can be retried",
       %{view: view} do
    open_appeal(view)

    # The device flow is out: the code is on screen and a retry would be
    # refused, which is correct while the flow is genuinely live.
    assert start_appeal(view) =~ "WXYZ-1234"
    assert render(view) =~ "Waiting for authorization"

    # The provider blips. The scheduled poll is 60s out, so drive the arm.
    Application.put_env(:cyfr, :device_flow_poll_result, {:error, :timeout})
    send(view.pid, :appeal_poll)
    html = render(view)

    refute html =~ "Waiting for authorization",
           "the appeal is still waiting on a flow that already failed"

    assert has_element?(view, "form[phx-submit=start-appeal]"),
           "the error left no form to retry from"

    # And the retry is real: the guard that refuses a second click while a
    # flow is out no longer sees one.
    Application.put_env(:cyfr, :device_flow_poll_result, {:ok, %{status: "pending"}})
    assert start_appeal(view) =~ "WXYZ-1234"
    assert render(view) =~ "Waiting for authorization"
  end

  test "a denied poll returns the appeal to its form too", %{view: view} do
    open_appeal(view)
    start_appeal(view)

    Application.put_env(:cyfr, :device_flow_poll_result, {:ok, %{status: "denied"}})
    send(view.pid, :appeal_poll)

    assert render(view) =~ "Authorization was denied."
    assert has_element?(view, "form[phx-submit=start-appeal]")
  end

  # The fake has recorded the address since the budget landed; nothing read
  # it back, so a `nil` would have passed. The appeal is the second
  # anonymous device flow on a socket that passes no rate-limit plug —
  # `/live` is handled by the endpoint before the router — which makes this
  # assign the only per-address bound the surface has.
  test "the appeal flow is charged to a resolved address, not nil", %{view: view} do
    Application.delete_env(:cyfr, :device_flow_last_ip)

    open_appeal(view)
    start_appeal(view)

    ip = Application.get_env(:cyfr, :device_flow_last_ip)

    assert is_binary(ip), "the appeal device flow was charged no address"
    assert {:ok, _} = ip |> to_charlist() |> :inet.parse_address()

    refute ip == "0.0.0.0",
           "the appeal fell back to the unresolved address, so every caller shares one bucket"
  end
end
