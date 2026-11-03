# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.RetiredSignInTest do
  @moduledoc """
  The command line's approval sign-in and its command-line session are
  gone: every former entry refuses. The session tool declares none of the
  approval, setup or device-flow actions and the gate dispatches none of
  them, anonymous or signed in; `/cli` is no page; and the store holds
  neither the pending sign-ins table nor the sessions' machine column. A
  command line signs in as a protected device (`POST /device/session`).
  """

  use PrismWeb.ConnCase, async: false

  alias Sanctum.Context

  @retired ~w(cli_begin cli_poll cli_cancel cli_approve cli_list cli_revoke setup device_init device_poll)

  test "the session tool declares no retired action, and the gate dispatches none" do
    declared =
      Sanctum.Providers.Session.definition()
      |> Map.fetch!(:operations)
      |> Enum.map(& &1.action)

    assert declared != []
    assert Enum.filter(@retired, &(&1 in declared)) == []

    anonymous = Context.build(%{authenticated: false, client_ip: "198.51.100.120"})
    person = Sanctum.TestContext.session!(test_user().user_id)
    before = Arca.Repo.aggregate(Arca.Schemas.Session, :count)

    for ctx <- [anonymous, person], action <- @retired do
      args = %{
        "action" => action,
        "machine" => "laptop",
        "setup_token" => String.duplicate("ab", 32),
        "provider" => "github",
        "device_code" => "dc",
        "session_token" => "t",
        "approval_secret" => "s"
      }

      assert {:error, _refused} = Sanctum.Gate.call_external("session", ctx, args), action
    end

    assert Arca.Repo.aggregate(Arca.Schemas.Session, :count) == before
  end

  test "/cli is no page", %{conn: conn} do
    conn = log_in_user(conn, test_user())
    assert get(conn, "/cli").status == 404
  end

  test "the store holds no pending sign-ins table and no session machine column" do
    assert {:error, _missing} = Arca.Repo.query("SELECT 1 FROM cli_sign_ins")
    assert {:error, _missing} = Arca.Repo.query("SELECT cli_machine FROM sessions")
    assert {:ok, _present} = Arca.Repo.query("SELECT client_id FROM sessions")
  end
end
