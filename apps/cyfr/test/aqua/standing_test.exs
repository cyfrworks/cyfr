# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.StandingTest do
  @moduledoc """
  Whether a card's answer may stand for calls nobody has seen yet: an
  external or destructive action takes no standing allow, whatever its
  own standing rule says, and answers for this call alone or a standing
  deny stay open to it.
  """

  use ExUnit.Case, async: true

  alias Aqua.Loop.Binding
  alias Aqua.Loop.Policy
  alias Aqua.Standing

  # The intent a card carries, in the wire shape the decision reads.
  defp intent(kind, standing \\ nil),
    do: %{"tool" => "t", "action" => "a", "action_kind" => kind, "standing" => standing}

  # The card a model's call becomes, resolved through the binding the loop
  # uses, so its kind is the one the gate classifies.
  defp card_for(name) do
    {:ok, call} = Binding.resolve(name, %{"url" => "https://example.test/", "body" => "b"})
    Policy.card(call)
  end

  test "an external card takes neither a thread nor an always answer" do
    for scope <- [:thread, :always], standing <- [nil, "thread"] do
      assert {:error, {:scope_not_permitted, "external"}} =
               Standing.check(intent("external", standing), scope)
    end
  end

  test "an external card is still answered once, or denied for good" do
    for scope <- [:once, :never] do
      assert :ok = Standing.check(intent("external"), scope)
    end
  end

  test "a destructive card takes no standing allow either" do
    for scope <- [:thread, :always] do
      assert {:error, {:scope_not_permitted, "destructive"}} =
               Standing.check(intent("destructive"), scope)
    end
  end

  test "a write with no standing rule of its own may stand for the thread or always" do
    for scope <- [:thread, :always] do
      assert :ok = Standing.check(intent("write"), scope)
    end
  end

  describe "an HTTP post, put or patch to a destination outside the home" do
    setup do
      {:ok, ctx: Sanctum.TestContext.local()}
    end

    test "is external on its card, so it takes no standing answer but once or never" do
      for name <- ~w(http.post http.put http.patch) do
        card = card_for(name)
        assert card["action_kind"] == "external", "#{name} is not external"

        for scope <- [:thread, :always] do
          assert {:error, {:scope_not_permitted, "external"}} = Standing.check(card, scope),
                 "#{name} took a #{scope} standing answer"
        end

        assert :ok = Standing.check(card, :once)
        assert :ok = Standing.check(card, :never)
      end
    end

    test "is refused at the write of its standing row, at either scope", %{ctx: ctx} do
      turn = %{thread_id: "thread_1", agent: "aqua"}

      for action <- ~w(post put patch), scope <- [:thread, :always] do
        proposal = %{"tool" => "http", "action" => action}

        assert {:error, {:scope_not_permitted, :external}} =
                 Standing.rows(ctx, turn, proposal, scope),
               "http.#{action} wrote a #{scope} standing row"
      end
    end

    test "a GET is a read and keeps both standing answers", %{ctx: ctx} do
      get = card_for("http.get")
      assert get["action_kind"] == "read"
      assert :ok = Standing.check(get, :thread)
      assert :ok = Standing.check(get, :always)

      turn = %{thread_id: "thread_1", agent: "aqua"}

      assert {:ok, [_row]} =
               Standing.rows(ctx, turn, %{"tool" => "http", "action" => "get"}, :thread)
    end
  end
end
