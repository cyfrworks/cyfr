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

  alias Aqua.Standing

  # The intent a card carries, in the wire shape the decision reads.
  defp intent(kind, standing \\ nil),
    do: %{"tool" => "t", "action" => "a", "action_kind" => kind, "standing" => standing}

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
end
