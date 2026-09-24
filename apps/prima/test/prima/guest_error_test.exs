# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.GuestErrorTest do
  @moduledoc """
  A guest sees a sentence rendered from data alone: wire answers, the
  host client's tuples and a runner's own reasons render; an internal term
  renders as nothing, never as its inspected spelling.
  """

  use ExUnit.Case, async: true

  alias Prima.GuestError

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
    # A host call CYFR could not answer. It read as the atom's own name
    # until there was one vocabulary to render it from.
    assert GuestError.render(:lost) =~ "check before asking again"
    assert GuestError.render({:timeout, "The call timed out"}) == "The call timed out"
    assert GuestError.render({:uncertain, "The effect may have happened"}) =~ "may have"
    assert GuestError.render({:not_found, "component", "c:1"}) == "component not found: c:1"
    assert GuestError.render({:unavailable, "The registry"}) =~ "unavailable"
    assert GuestError.render({:corrupt, "The artifact"}) =~ "digest"
  end

  test "a unit commit's refusals render as the sentence the console renders" do
    # The same words the console renders, so a guest in a chain and
    # a person at the console are told the same thing; the parity is held
    # by `Grimoire.ErrorRenderersTest`.
    assert GuestError.render(:stale_writer) =~ "fifteen minutes"
    assert GuestError.render(:stale_revision) =~ "landed first"
    assert GuestError.render(:missing_unit) =~ "removed"
    assert GuestError.render(:invalid_objects) =~ "nothing was published"
    assert GuestError.render({:finish_failed, :enospc}) =~ "published"

    # Named, this is a service to retry; bare, it is a call whose outcome
    # is unknown, and the advice is to check instead.
    assert GuestError.render({:unavailable, "The registry"}) =~ "retry shortly"
    assert GuestError.render(:unavailable) =~ "check before asking again"
  end

  test "an internal term renders as nothing" do
    for internal <- [
          # An atom that is not a refusal of the vocabulary: an internal
          # name is not a sentence, and spelling it is how internal
          # vocabulary reaches a guest-visible surface.
          :some_internal_state,
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
