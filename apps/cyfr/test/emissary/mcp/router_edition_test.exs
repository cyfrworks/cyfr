defmodule Emissary.MCP.RouterEditionTest do
  use ExUnit.Case, async: false

  alias Emissary.MCP.Router

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    original = Application.get_env(:cyfr, :edition)
    on_exit(fn -> Application.put_env(:cyfr, :edition, original) end)
    :ok
  end

  # We test public_tool_action? indirectly through dispatch since it's private.
  # We build minimal session + message structures to exercise the auth check.

  defp make_session(authenticated) do
    ctx =
      Sanctum.Context.build(
        user_id: if(authenticated, do: "test_user", else: nil),
        permissions: if(authenticated, do: [:*], else: []),
        scope: :project,
        auth_method: if(authenticated, do: :local, else: nil),
        authenticated: authenticated
      )

    %{context: ctx}
  end

  defp tool_call_msg(tool_name, action) do
    %Emissary.MCP.Message{
      type: :request,
      method: "tools/call",
      id: "test-#{System.unique_integer([:positive])}",
      params: %{
        "name" => tool_name,
        "arguments" => %{"action" => action}
      }
    }
  end

  describe "core edition public actions" do
    setup do
      Application.put_env(:cyfr, :edition, :core)
      :ok
    end

    test "component.list is public in core mode" do
      session = make_session(false)
      msg = tool_call_msg("component", "list")

      # Should not return auth_required error
      result = Router.dispatch(session, msg)
      refute match?({:error, :auth_required, _}, result)
    end

    test "component.search is public in core mode" do
      session = make_session(false)
      msg = tool_call_msg("component", "search")

      result = Router.dispatch(session, msg)
      refute match?({:error, :auth_required, _}, result)
    end

    test "component.inspect is public in core mode" do
      session = make_session(false)
      msg = tool_call_msg("component", "inspect")

      result = Router.dispatch(session, msg)
      refute match?({:error, :auth_required, _}, result)
    end
  end

  describe "arx edition restricted actions" do
    setup do
      Application.put_env(:cyfr, :edition, :arx)
      :ok
    end

    test "component.list requires auth in arx mode" do
      session = make_session(false)
      msg = tool_call_msg("component", "list")

      assert {:error, :auth_required, _} = Router.dispatch(session, msg)
    end

    test "component.search requires auth in arx mode" do
      session = make_session(false)
      msg = tool_call_msg("component", "search")

      assert {:error, :auth_required, _} = Router.dispatch(session, msg)
    end

    test "component.inspect requires auth in arx mode" do
      session = make_session(false)
      msg = tool_call_msg("component", "inspect")

      assert {:error, :auth_required, _} = Router.dispatch(session, msg)
    end

    test "component.categories remains public in arx mode" do
      session = make_session(false)
      msg = tool_call_msg("component", "categories")

      result = Router.dispatch(session, msg)
      refute match?({:error, :auth_required, _}, result)
    end

    test "session tool remains public in arx mode" do
      session = make_session(false)
      msg = tool_call_msg("session", "status")

      result = Router.dispatch(session, msg)
      refute match?({:error, :auth_required, _}, result)
    end

    test "system.status remains public in arx mode" do
      session = make_session(false)
      msg = tool_call_msg("system", "status")

      result = Router.dispatch(session, msg)
      refute match?({:error, :auth_required, _}, result)
    end
  end
end
