# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.GuestErrorTest do
  @moduledoc """
  A guest sees a sentence rendered from data alone: wire answers, the
  host client's tuples and a runner's own reasons render; an internal term
  renders as nothing, never as its inspected spelling.
  """

  use ExUnit.Case, async: true

  alias Cyfr.GuestError

  test "wire answers and host client tuples render their message" do
    assert GuestError.render(%{"type" => "denied", "message" => "Not consented"}) ==
             "Not consented"

    assert GuestError.render({:guest_error, "denied", "Not consented"}) == "Not consented"

    assert GuestError.render({:guest_error, "setup_required", "Bind a key", %{"vault" => "x"}}) ==
             "Bind a key"

    assert GuestError.render({:failed, "The child failed"}) == "The child failed"
    assert GuestError.render({:setup_required, %{"vault" => "x"}}) =~ "needs setup"
  end

  test "a runner's own reasons render as the text they carry" do
    assert GuestError.render("already a sentence") == "already a sentence"
    assert GuestError.render(:lost) == "lost"
    assert GuestError.render(:unavailable) == "unavailable"
    assert GuestError.render({:timeout, "The call timed out"}) == "The call timed out"
    assert GuestError.render({:uncertain, "The effect may have happened"}) =~ "may have"
    assert GuestError.render({:not_found, "component", "c:1"}) == "component not found: c:1"
    assert GuestError.render({:unavailable, "The registry"}) =~ "unavailable"
    assert GuestError.render({:corrupt, "The artifact"}) =~ "digest"
  end

  test "an internal term renders as nothing" do
    for internal <- [
          nil,
          true,
          false,
          {:error, :oops},
          {:crashed, :not_a_sentence},
          {:guest_error, :type, "m"},
          %{"type" => "denied"},
          %{"message" => 1},
          %RuntimeError{message: "secret"},
          {:something, "with", "three"},
          self()
        ] do
      assert GuestError.render(internal) == nil, inspect(internal)
    end
  end
end
