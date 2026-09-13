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

  @keys [:platform_admin_emails, :provisioning_boot_enabled, :establish_cache_ms]

  setup do
    prev = Map.new(@keys, &{&1, Application.get_env(:cyfr, &1)})

    Application.put_env(:cyfr, :provisioning_boot_enabled, true)
    # The suite keeps the establish memo off; primed here, so the
    # revocation has cached state to invalidate.
    Application.put_env(:cyfr, :establish_cache_ms, :timer.minutes(1))

    on_exit(fn ->
      for {key, value} <- prev do
        if is_nil(value),
          do: Application.delete_env(:cyfr, key),
          else: Application.put_env(:cyfr, key, value)
      end
    end)

    :ok
  end

  test "de-listing an operator ends their connected console and their primed caller memo",
       %{conn: conn} do
    operator = test_user()
    Application.put_env(:cyfr, :platform_admin_emails, [operator.email])
    {:ok, _} = Members.ensure_platform(operator.user_id)

    conn = log_in_user(conn, operator)
    token = Plug.Conn.get_session(conn, session_key())

    # The console is open, and the caller memo holds this session.
    {:ok, view, _html} = live(conn, "/chat")
    assert {:ok, %{user_id: user_id}} = Sanctum.Caller.establish(token)
    assert user_id == operator.user_id

    # The environment no longer names them; the boot reconciles.
    Application.put_env(:cyfr, :platform_admin_emails, [])
    :ok = Cyfr.Bootstrap.run()

    # The connected console lets go, and the memo keeps no earlier answer.
    assert_redirect(view, "/login", 2_000)
    assert {:error, _} = Sanctum.Caller.establish(token)
  end
end
