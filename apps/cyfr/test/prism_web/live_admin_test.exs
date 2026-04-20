defmodule PrismWeb.LiveAdminTest do
  # LiveAdmin is an on_mount module, not a full LiveView. We exercise it
  # directly against the behaviour callback to keep tests fast and focused.
  use ExUnit.Case, async: true

  alias PrismWeb.LiveAdmin

  # Minimal fake socket matching the shape on_mount receives. Phoenix.LiveView
  # real sockets carry a lot more but on_mount only reads .assigns, so a
  # plain map works.
  defp socket(current_user) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_user: current_user, flash: %{}}
    }
  end

  test "admin permission passes" do
    user = %{id: "admin-1", permissions: [:admin]}
    assert {:cont, _socket} = LiveAdmin.on_mount(:require_admin, %{}, %{}, socket(user))
  end

  test "wildcard :* permission passes" do
    user = %{id: "root", permissions: [:*]}
    assert {:cont, _} = LiveAdmin.on_mount(:require_admin, %{}, %{}, socket(user))
  end

  test "non-admin is redirected to dashboard" do
    user = %{id: "bob", permissions: [:execute]}
    assert {:halt, s} = LiveAdmin.on_mount(:require_admin, %{}, %{}, socket(user))
    assert s.redirected == {:redirect, %{to: "/", status: 302}}
  end

  test "nil current_user falls back to login redirect" do
    assert {:halt, s} = LiveAdmin.on_mount(:require_admin, %{}, %{}, socket(nil))
    assert match?({:redirect, %{to: "/login"}}, s.redirected)
  end

  test "user with empty id falls back to login redirect" do
    user = %{id: "", permissions: [:admin]}
    assert {:halt, s} = LiveAdmin.on_mount(:require_admin, %{}, %{}, socket(user))
    assert match?({:redirect, %{to: "/login"}}, s.redirected)
  end

  test "user with nil permissions list defaults to empty (no admin)" do
    user = %{id: "alice", permissions: nil}
    assert {:halt, s} = LiveAdmin.on_mount(:require_admin, %{}, %{}, socket(user))
    assert match?({:redirect, %{to: "/"}}, s.redirected)
  end
end
