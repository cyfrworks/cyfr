# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RestoreLiveTest do
  @moduledoc """
  `/restore`: the page an empty CYFR serves its returning person. It is
  public and sessionless, reads nothing and decides nothing: its form is
  the browser's, whose inputs carry no name, so the installation token and
  the recovery code go only where the page's script sends them — the
  restore ingress, in a header and a JSON body — and never into this view,
  an address or a form submission of the browser's own. What the ingress
  answers is `Emissary.Web.RestoreControllerTest`'s.
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

    for {form, field, test} <- [
          {"#restore-form", "token", "restore-token"},
          {"#restore-form", "recovery_code", "restore-code"},
          {"#restore-kit-form", "recovery_code", "restore-kit-code"}
        ] do
      assert has_element?(
               view,
               ~s(#{form} input[data-field="#{field}"][data-test="#{test}"][autocomplete="off"])
             )
    end

    refute has_element?(view, "#restore input[name]")
    refute has_element?(view, "#restore form[action]")

    # The page holds nothing of a restore, and says what one brings back.
    assert html =~ "never your private data"
    assert html =~ "never the CYFR addresses your devices saved"
    assert has_element?(view, ~s([data-test="restore-reproof"][hidden]))
    assert has_element?(view, ~s([data-test="restore-continue"][hidden]))
  end

  test "asks for the installation token and the recovery code alone, and says code, never kit",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/restore")

    assert has_element?(
             view,
             "main > p",
             "This CYFR is empty and its operator set it up for one restore. Type the " <>
               "installation token they gave you and your recovery code. They go to this CYFR " <>
               "alone, and nothing is kept in this browser."
           )

    assert has_element?(view, ~s(#restore-form label[for="restore-token"]), "Installation token")
    assert has_element?(view, ~s(#restore-form label[for="restore-code"]), "Your recovery code")
    assert has_element?(view, ~s([data-test="restore-submit"]), "Restore")
    assert has_element?(view, ~s([data-test="restore-clear"]), "Clear")
    assert has_element?(view, ~s([data-test="restore-reproof"]), "Check your recovery code again")
    assert has_element?(view, ~s([data-test="restore-continue"]), "Continue to Aqua")

    assert has_element?(view, "#restore-kit-title", "Recover after a restore")

    assert has_element?(
             view,
             "#restore-kit p",
             "When this CYFR was restored from a backup, every passkey, device, API key and " <>
               "webhook it held was suspended and every session ended. Type your recovery code " <>
               "here to turn back on what is yours. It signs in this browser and is never sent."
           )

    assert has_element?(
             view,
             ~s(#restore-kit-form label[for="restore-kit-code"]),
             "Your recovery code"
           )

    assert has_element?(view, ~s([data-test="restore-kit-submit"]), "Recover")
    assert has_element?(view, ~s([data-test="restore-kit-clear"]), "Clear")
    assert html =~ "This page needs JavaScript to send your recovery code to this CYFR."

    # Nothing of the printed kit's three lines is asked for or named.
    for gone <- ~w(identifier directory_url recovery_secret) do
      refute has_element?(view, ~s(#restore input[data-field="#{gone}"]))
    end

    for gone <-
          ~w(restore-identifier restore-directory restore-secret restore-kit-identifier restore-kit-secret) do
      refute has_element?(view, ~s([data-test="#{gone}"]))
    end

    refute has_element?(view, "main", ~r/\bkits?\b|printed|three lines|installation(?! token)/i)
  end

  test "the view handles no event of its own: a recovery code sent to it is dropped and kept nowhere",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/restore")

    code =
      Prima.RecoveryCode.encode(
        "per_" <> String.duplicate("0", 64),
        :crypto.strong_rand_bytes(32)
      )

    token = "c2VlZC1zZW50LXRvLXRoZS12aWV3"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        render_hook(view, "restore", %{"recovery_code" => code, "token" => token})
      end)

    for secret <- [code, token] do
      refute log =~ secret
      refute render(view) =~ secret

      refute inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity) =~
               secret
    end
  end

  test "a CYFR holding a person still serves the page; the ingress refuses the restore",
       %{conn: conn} do
    _person = test_user()
    {:ok, _view, html} = live(conn, "/restore")
    assert html =~ "restore-form"
  end
end
