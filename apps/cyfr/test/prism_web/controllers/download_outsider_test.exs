# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.DownloadOutsiderTest do
  @moduledoc """
  The console's two download routes, `/a/:athanor/files/download/*path`
  and `/a/:athanor/attachments/:message_id/:filename`, answer anyone
  without a current seat in the URL's athanor exactly as they answer for
  an athanor that does not exist (`ARCHITECTURE.md` §5.1): a visitor with
  no session is sent to sign in for an active, an archived and a missing
  athanor alike, and a signed-in person with no seat, a former member
  included, gets 404 for each.
  """

  use PrismWeb.ConnCase, async: false

  alias Sanctum.Tenancy.{Athanors, Members}

  setup do
    owner = test_user()
    {:ok, active} = Athanors.create_group(owner.user_id, "Open #{owner.namespace}")
    {:ok, closed} = Athanors.create_group(owner.user_id, "Closed #{owner.namespace}")
    {:ok, _archived} = Athanors.archive(closed)

    routes = %{
      active: Athanors.route_slug(active),
      archived: Athanors.route_slug(closed),
      missing: "no-such-group-#{System.unique_integer([:positive])}"
    }

    {:ok, active: active, routes: routes}
  end

  @downloads %{
    files: "/files/download/data/report.csv",
    attachments: "/attachments/msg_0190f0a0-0000-7000-8000-000000000000/0-note.txt"
  }

  for {route_name, suffix} <- @downloads do
    describe "the #{route_name} download route" do
      @suffix suffix

      test "sends a visitor with no session to sign in whether the athanor exists or not", %{
        routes: routes
      } do
        for {_which, route} <- routes do
          conn = get(build_conn(), "/a/#{route}" <> @suffix)
          assert redirected_to(conn) == PrismWeb.AuthHelpers.sign_in_path(), route
        end
      end

      test "answers a signed-in person with no seat 404 whether the athanor exists or not", %{
        conn: conn,
        routes: routes
      } do
        conn = log_in_user(conn, test_user())

        for {_which, route} <- routes do
          assert get(conn, "/a/#{route}" <> @suffix).status == 404, route
        end
      end

      test "answers a former member 404 as it answers for a missing athanor", %{
        conn: conn,
        active: active,
        routes: routes
      } do
        former = test_user()
        conn = log_in_user(conn, former)
        {:ok, _seat} = Members.ensure(former.user_id, scope: "athanor", athanor_id: active.id)
        :ok = Members.remove_member(active, user_id: former.user_id)

        assert get(conn, "/a/#{routes.active}" <> @suffix).status == 404
        assert get(conn, "/a/#{routes.missing}" <> @suffix).status == 404
      end
    end
  end
end
