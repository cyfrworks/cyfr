# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.PolicyTest do
  use ExUnit.Case, async: true

  alias Aqua.Policy
  alias Compendium.AquaAgent

  test "a destructive or external action is never auto, on any agent" do
    assert {:error, msg} =
             Policy.check_authored(%{"files.delete" => "auto"}, AquaAgent.soul_type())

    assert msg =~ "always asks"
    assert {:error, _} = Policy.check_authored(%{"http.delete" => "auto"}, AquaAgent.role_type())
    assert :ok = Policy.check_authored(%{"files.delete" => "ask"}, AquaAgent.soul_type())
    assert :ok = Policy.check_authored(%{"files.write" => "auto"}, AquaAgent.soul_type())
  end

  test "a glob at auto that covers a destructive action is refused with the actions named" do
    assert {:error, msg} = Policy.check_authored(%{"files.*" => "auto"}, AquaAgent.soul_type())
    assert msg =~ "files.delete"
    assert :ok = Policy.check_authored(%{"files.*" => "ask"}, AquaAgent.soul_type())
  end

  test "a role holds nothing at ask — it has no card to raise" do
    assert {:error, msg} = Policy.check_authored(%{"files.write" => "ask"}, AquaAgent.role_type())
    assert msg =~ "no card"
    assert :ok = Policy.check_authored(%{"files.write" => "auto"}, AquaAgent.role_type())
    assert :ok = Policy.check_authored(%{"files.write" => "ask"}, AquaAgent.soul_type())
  end

  test "a role's delegation glob and the search gate pass" do
    assert :ok =
             Policy.check_authored(
               %{"aqua_builder.*" => "auto", "native_search" => "auto"},
               AquaAgent.soul_type()
             )
  end

  test "a UI event is auto or absent" do
    assert {:error, msg} = Policy.check_auto_only(%{"request_setup.open" => "ask"})
    assert msg =~ "runs on its own"
    assert :ok = Policy.check_auto_only(%{"request_setup.open" => "auto", "files.read" => "ask"})
  end
end
