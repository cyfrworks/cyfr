# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RestoreLiveTest do
  @moduledoc """
  `/restore`: the page a fresh installation serves its returning person.
  It is public and sessionless, reads nothing and decides nothing: its
  form is the browser's, whose inputs carry no name, so the installation
  token and the kit's three lines go only where the page's script sends
  them — the restore ingress, in a header and a JSON body — and never
  into this view, an address or a form submission of the browser's own.
  What the ingress answers is `Emissary.Web.RestoreControllerTest`'s.
  """
  use PrismWeb.ConnCase, async: false

  test "is served to anyone, signed in or not, and reads no session", %{conn: conn} do
    assert conn |> get("/restore") |> html_response(200) =~ "Restore your identity"

    person = test_user()
    signed_in = log_in_user(build_conn(), person)
    {:ok, _view, html} = live(signed_in, "/restore")

    refute html =~ person.email
    refute html =~ person.user_id
  end

  test "its form is the browser's: no input it could submit by itself, and nothing to hold",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/restore")

    assert has_element?(view, ~s(#restore[phx-hook="SystemLayer"][data-restore="page"]))
    assert has_element?(view, ~s(#restore[phx-update="ignore"]))

    for field <- ~w(token identifier directory_url recovery_secret) do
      assert has_element?(view, ~s(#restore input[data-field="#{field}"][autocomplete="off"]))
    end

    refute has_element?(view, "#restore input[name]")
    refute has_element?(view, "#restore form[action]")

    # The page holds nothing of a restore, and says what one brings back.
    assert html =~ "never your private data"
    assert html =~ "never the homes your devices saved"
    assert has_element?(view, ~s([data-test="restore-reproof"][hidden]))
    assert has_element?(view, ~s([data-test="restore-continue"][hidden]))
  end

  test "the view handles no event of its own: a kit sent to it is dropped and kept nowhere",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/restore")
    secret = "c2VlZC1zZW50LXRvLXRoZS12aWV3"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        render_hook(view, "restore", %{"recovery_secret" => secret, "token" => secret})
      end)

    refute log =~ secret
    refute render(view) =~ secret

    refute inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity) =~
             secret
  end

  test "an installation holding a person still serves the page; the ingress refuses the restore",
       %{conn: conn} do
    _person = test_user()
    {:ok, _view, html} = live(conn, "/restore")
    assert html =~ "restore-form"
  end
end
