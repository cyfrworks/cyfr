# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.SafeModeTest do
  @moduledoc """
  Safe mode as data: it is entered for a reason over the visible canvas,
  the tincture it runs and the version its versions document keeps, and
  carries no layout document. It offers trying the canvas again, the kept
  version while there is one, and the shipped canvas while a canvas is
  visible; choosing the kept version asks to restore the canvas by its
  component name.
  """

  use ExUnit.Case, async: true

  alias Prism.SafeMode

  defp canvas(fields \\ %{}),
    do: Map.merge(%{canvas: "home", tincture: "tincture:local.markets", kept: "0.1.3"}, fields)

  test "entering keeps the reason and the visible canvas, and no layout" do
    for reason <- [:not_ready, :crashed, :not_validated, :requested] do
      safe_mode = SafeMode.enter(reason, canvas())

      assert safe_mode == %SafeMode{
               reason: reason,
               canvas: "home",
               tincture: "tincture:local.markets",
               kept: "0.1.3"
             }

      assert SafeMode.active?(safe_mode)
    end

    assert SafeMode.reasons() == [:not_ready, :crashed, :not_validated, :requested]
    refute Map.has_key?(SafeMode.enter(:crashed, canvas()), :document)
  end

  test "an unknown reason, or a canvas that is not one, is not safe mode" do
    # A reason read at runtime, so the refusal is the function's own.
    unknown = String.to_existing_atom("ok")
    assert_raise FunctionClauseError, fn -> SafeMode.enter(unknown, canvas()) end
    assert_raise FunctionClauseError, fn -> SafeMode.enter(:crashed, canvas(%{kept: 3})) end
    assert_raise FunctionClauseError, fn -> SafeMode.enter(:crashed, canvas(%{canvas: :home})) end

    refute SafeMode.active?(nil)
    refute SafeMode.active?(%{reason: :crashed})
  end

  test "offers trying again, the kept version and the shipped canvas" do
    safe_mode = SafeMode.enter(:crashed, canvas())

    assert SafeMode.offers(safe_mode) == [
             %{offer: :retry, version: nil},
             %{offer: :kept, version: "0.1.3"},
             %{offer: :shipped, version: nil}
           ]

    assert SafeMode.shipped_canvas() == "tincture:local.canvas"
  end

  test "with no kept version, or a canvas that is no local canvas, the kept version is not offered" do
    for fields <- [%{kept: nil}, %{tincture: "tincture:acme.markets"}] do
      safe_mode = SafeMode.enter(:not_validated, canvas(fields))

      assert Enum.map(SafeMode.offers(safe_mode), & &1.offer) == [:retry, :shipped]
      assert SafeMode.choose(safe_mode, :kept) == {:error, :not_offered}
    end
  end

  test "with no canvas visible, only trying again is offered" do
    safe_mode = SafeMode.enter(:requested, %{canvas: nil, tincture: nil, kept: nil})

    assert SafeMode.offers(safe_mode) == [%{offer: :retry, version: nil}]
    assert SafeMode.choose(safe_mode, :shipped) == {:error, :not_offered}
  end

  test "choosing answers what the way out asks for" do
    safe_mode = SafeMode.enter(:crashed, canvas())

    assert SafeMode.choose(safe_mode, :retry) == :retry
    assert SafeMode.choose(safe_mode, :kept) == {:restore, "markets"}
    assert SafeMode.choose(safe_mode, :shipped) == :shipped
  end

  test "an offer it does not make is refused" do
    safe_mode = SafeMode.enter(:requested, canvas())
    assert SafeMode.choose(safe_mode, :default) == {:error, :not_offered}
    assert SafeMode.choose(safe_mode, :earlier_version) == {:error, :not_offered}
  end
end
