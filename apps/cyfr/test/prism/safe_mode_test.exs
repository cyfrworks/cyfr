# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.SafeModeTest do
  @moduledoc """
  Safe mode as data: it is entered for a reason over the layout as read,
  offers trying the current desktop again and the shipped default while
  some posture runs another, and choosing the default answers the
  person's own document with only each posture's desktop replaced.
  """

  use ExUnit.Case, async: true

  alias Prism.SafeMode

  @default "tincture:local.desktop"

  defp layout(desktop, revision \\ 3) do
    {:ok, document} =
      Prima.Layout.validate(%{
        "version" => 1,
        "postures" => %{
          "desk" => %{
            "desktop" => desktop,
            "slots" => [
              %{
                "id" => "vault",
                "tincture" => "tincture:local.vault",
                "size" => "icon",
                "order" => 0
              }
            ],
            "floating" => [
              %{"tincture" => "tincture:acme.clock", "position" => %{"x" => 100, "y" => 200}}
            ]
          }
        }
      })

    %{document: document, revision: revision, digest: Prima.Layout.digest(document)}
  end

  test "entering keeps the reason, the document and the revision read" do
    read = layout("tincture:acme.desk")

    for reason <- [:not_ready, :crashed, :requested] do
      safe_mode = SafeMode.enter(reason, read)
      assert %SafeMode{reason: ^reason, revision: 3} = safe_mode
      assert safe_mode.document == read.document
      assert SafeMode.active?(safe_mode)
    end
  end

  test "an unknown reason or a revision below zero is not safe mode" do
    # A reason read at runtime, so the refusal is the function's own.
    unknown = String.to_existing_atom("ok")
    assert_raise FunctionClauseError, fn -> SafeMode.enter(unknown, layout(@default)) end

    assert_raise FunctionClauseError, fn ->
      SafeMode.enter(:crashed, %{layout(@default) | revision: -1})
    end

    refute SafeMode.active?(nil)
    refute SafeMode.active?(%{reason: :crashed})
  end

  test "offers try the current desktops again, then the shipped default" do
    safe_mode = SafeMode.enter(:crashed, layout("tincture:acme.desk"))

    # The hand posture is not named, so it reads as the default's desktop.
    assert SafeMode.offers(safe_mode) == [
             %{offer: :retry, desktops: ["tincture:acme.desk", @default]},
             %{offer: :default, desktops: [@default]}
           ]

    assert SafeMode.default_desktop() == @default
  end

  test "a layout already on the default desktop offers only trying again" do
    safe_mode = SafeMode.enter(:not_ready, layout(@default))

    assert SafeMode.offers(safe_mode) == [%{offer: :retry, desktops: [@default]}]
    assert SafeMode.choose(safe_mode, :default) == {:error, :not_offered}
  end

  test "choosing to try again writes nothing" do
    assert SafeMode.choose(SafeMode.enter(:crashed, layout("tincture:acme.desk")), :retry) ==
             :retry
  end

  test "choosing the default replaces each posture's desktop and keeps the rest" do
    read = layout("tincture:acme.desk")
    safe_mode = SafeMode.enter(:crashed, read)

    assert {:publish, document} = SafeMode.choose(safe_mode, :default)
    assert {:ok, desk} = Prima.Layout.posture(document, "desk")
    {:ok, before} = Prima.Layout.posture(read.document, "desk")

    assert desk.desktop == @default
    assert desk.slots == before.slots
    assert desk.floating == before.floating
    assert Map.keys(document.postures) == Map.keys(read.document.postures)

    # The document to publish is still a layout.
    assert {:ok, ^document} = Prima.Layout.validate(Prima.Layout.to_json(document))
  end

  test "an offer it does not make is refused" do
    safe_mode = SafeMode.enter(:requested, layout("tincture:acme.desk"))
    assert SafeMode.choose(safe_mode, :earlier_version) == {:error, :not_offered}
  end
end
