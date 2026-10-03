# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.OperatorDelistLiveTest do
  @moduledoc """
  An operator the environment no longer names loses more than their next
  sign-in: the console they already have open lets go, and a caller memo
  primed with their session refuses on its next establish.
  """
  use PrismWeb.ConnCase, async: false

  alias Sanctum.Tenancy.Members

  # The platform roster and the establish memo are the identity domain's;
  # the boot switch is the host's.
  @keys [
    sanctum: :platform_admin_emails,
    cyfr: :provisioning_boot_enabled,
    sanctum: :caller_memo_ttl_ms
  ]

  # The four control-plane terms `Arca.ControlPlane` keeps: `Cyfr.Bootstrap.run/0`
  # reconciles without a slot only from the erased, no-claimant baseline, so
  # this case starts from it and hands back whatever the run had before.
  @control_plane_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot},
    {Arca.ControlPlane, :roster}
  ]

  setup do
    prev = Map.new(@keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    saved_terms = Map.new(@control_plane_keys, &{&1, :persistent_term.get(&1, :absent)})
    for key <- @control_plane_keys, do: :persistent_term.erase(key)

    Application.put_env(:cyfr, :provisioning_boot_enabled, true)
    # The suite keeps the establish memo off; primed here, so the
    # revocation has cached state to invalidate.
    Application.put_env(:sanctum, :caller_memo_ttl_ms, :timer.minutes(1))

    on_exit(fn ->
      # The memos this case primed are the node's, not its own: left
      # behind they make a neighbour's "no caller is memoized" read false.
      Arca.Cache.delete_match({:established, :_, :_, :_})

      for {{app, key}, value} <- prev do
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end

      for {key, value} <- saved_terms do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end
    end)

    :ok
  end

  test "de-listing an operator ends their connected console and their primed caller memo",
       %{conn: conn} do
    operator = test_user()
    Application.put_env(:sanctum, :platform_admin_emails, [operator.email])
    {:ok, _} = Members.ensure_platform(operator.user_id)

    conn = log_in_user(conn, operator)
    token = Plug.Conn.get_session(conn, session_key())

    # The console is open, and the caller memo holds this session.
    {:ok, view, _html} = live(conn, "/chat")
    assert {:ok, %{user_id: user_id}} = Sanctum.Caller.establish(token)
    assert user_id == operator.user_id

    # The environment no longer names them; the boot reconciles.
    Application.put_env(:sanctum, :platform_admin_emails, [])
    :ok = Cyfr.Bootstrap.run()

    # The connected console lets go, and the memo keeps no earlier answer.
    assert_redirect(view, "/login", 2_000)
    assert {:error, _} = Sanctum.Caller.establish(token)
  end
end
