# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.FallbackTest do
  @moduledoc """
  The fallback as data: it begins for a reason over one canvas, the
  tincture the layout names for it and the version its versions document
  keeps. It offers opening the canvas again, and the kept version while
  there is one; choosing the kept version asks to restore the canvas by its
  component name.
  """

  use ExUnit.Case, async: true

  alias Prism.Fallback

  # Safe mode's reasons are none of the fallback's.
  @not_reasons [:ok, :crashed, :requested]

  defp canvas(fields \\ %{}),
    do: Map.merge(%{canvas: "home", tincture: "tincture:local.markets", kept: "0.1.3"}, fields)

  test "it keeps the reason and the canvas" do
    for reason <- [:not_ready, :gone, :not_validated] do
      assert Fallback.enter(reason, canvas()) == %Fallback{
               reason: reason,
               canvas: "home",
               tincture: "tincture:local.markets",
               kept: "0.1.3"
             }
    end

    assert Fallback.shipped_canvas() == "tincture:local.canvas"
  end

  test "an unknown reason, or a canvas that is not one, is refused" do
    # Reasons read at runtime, so each refusal is the function's own.
    for reason <- @not_reasons do
      unknown = String.to_existing_atom(Atom.to_string(reason))
      assert_raise FunctionClauseError, fn -> Fallback.enter(unknown, canvas()) end
    end

    for fields <- [%{kept: 3}, %{canvas: nil}, %{canvas: :home}, %{tincture: nil}] do
      assert_raise FunctionClauseError, fn -> Fallback.enter(:gone, canvas(fields)) end
    end
  end

  test "offers trying again, then the kept version" do
    fallback = Fallback.enter(:gone, canvas())

    assert Fallback.offers(fallback) == [
             %{offer: :retry, version: nil},
             %{offer: :kept, version: "0.1.3"}
           ]
  end

  test "with no kept version, or a canvas that is no local canvas, only trying again is offered" do
    for fields <- [%{kept: nil}, %{tincture: "tincture:acme.markets"}] do
      fallback = Fallback.enter(:not_validated, canvas(fields))

      assert Fallback.offers(fallback) == [%{offer: :retry, version: nil}]
      assert Fallback.choose(fallback, :kept) == {:error, :not_offered}
    end
  end

  test "choosing answers what the way back asks for, and nothing it does not offer" do
    fallback = Fallback.enter(:not_ready, canvas())

    assert Fallback.choose(fallback, :retry) == :retry
    assert Fallback.choose(fallback, :kept) == {:restore, "markets"}
    assert Fallback.choose(fallback, :shipped) == {:error, :not_offered}
    assert Fallback.choose(fallback, "retry") == {:error, :not_offered}
  end
end
