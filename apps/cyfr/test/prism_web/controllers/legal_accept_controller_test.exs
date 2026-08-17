# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LegalAcceptControllerTest do
  @moduledoc """
  The policy-acceptance page on the merged origin: rendered in the Prism
  face, reachable before a namespace is claimed (it sits ahead of the claim
  gate in the sign-in flow), and self-gating on its inputs. cyfr.run is
  unreachable here, so the page shows its error face rather than policies.
  """
  use PrismWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:cyfr, :registry_url)
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")

    on_exit(fn ->
      if original,
        do: Application.put_env(:cyfr, :registry_url, original),
        else: Application.delete_env(:cyfr, :registry_url)
    end)

    :ok
  end

  test "GET renders the error face in the Prism layout when cyfr.run cannot be reached", %{conn: conn} do
    conn = get(conn, "/legal/accept")
    body = response(conn, 502)
    assert body =~ "load policies from cyfr.run"
    assert body =~ "Couldn't continue"
    # the Prism root layout, not a bare inline page
    assert body =~ ~s(<link rel="manifest" href="/manifest.webmanifest")
    assert body =~ "/assets/app.css"
  end

  test "the page is ahead of the claim gate: an unclaimed session is not bounced to /claim-namespace",
       %{conn: conn} do
    conn = log_in_user(conn, test_user(), claim: false)
    conn = get(conn, "/legal/accept")
    assert conn.status == 502
    refute get_resp_header(conn, "location") != []
  end

  test "POST refuses a submission that has not ticked every policy, and one without a version",
       %{conn: conn} do
    conn = log_in_user(conn, test_user())

    partial = post(conn, "/legal/accept/submit", %{"policy_version" => "v3", "ack_terms" => "on"})
    assert response(partial, 400) =~ "All policy checkboxes must be ticked"

    missing = post(conn, "/legal/accept/submit", %{"ack_terms" => "on"})
    assert response(missing, 400) =~ "policy_version is required"
  end

  test "POST with every policy ticked but no pending probe cookie says the login expired", %{conn: conn} do
    conn = log_in_user(conn, test_user())

    acks =
      for name <- ~w(terms privacy aup content-policy dmca cookies transparency), into: %{} do
        {"ack_" <> String.replace(name, "-", "_"), "on"}
      end

    conn = post(conn, "/legal/accept/submit", Map.put(acks, "policy_version", "v3"))
    assert response(conn, 400) =~ "Login session expired"
  end
end
