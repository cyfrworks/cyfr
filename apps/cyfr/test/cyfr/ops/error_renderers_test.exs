# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.ErrorRenderersTest do
  @moduledoc """
  One refusal, one sentence, whichever surface renders it.

  Checks that MCP, console, and guest surfaces render typed tool errors
  consistently and preserve the distinction between timeouts and crashes.
  """
  use ExUnit.Case, async: true

  alias Cyfr.Ops.Error

  @crash_vocabulary [
    {:crashed, "Tool x crashed: boom"},
    {:exit, "Tool x exited unexpectedly"},
    {:timeout, "Tool x timed out after 300000ms"}
  ]

  # What a unit commit answers (`Arca.StorageUnits`): each is a different
  # thing to do about it, and none of them is "the write failed".
  @commit_vocabulary [
    :stale_writer,
    :stale_revision,
    :missing_unit,
    :invalid_objects,
    :unavailable,
    {:finish_failed, :enospc}
  ]

  describe "a unit commit's refusals" do
    test "are part of the typed roster, and say what to do about each" do
      for reason <- @commit_vocabulary do
        assert Error.reason?(reason), "#{inspect(reason)} is not recognised"
        assert is_binary(Error.message(reason))
      end

      # A writer that died holding a draft blocks the unit until the
      # draft expires, so the sentence says how long rather than "retry
      # shortly".
      assert Error.message(:stale_writer) =~ "fifteen minutes"

      # The two that do not mean "nothing was written": one says the
      # unit is published, the other that nothing may be assumed — so
      # neither tells the caller to simply retry.
      assert Error.message({:finish_failed, :enospc}) =~ "published"
      assert Error.message(:unavailable) =~ "check before asking again"
      refute Error.message(:unavailable) =~ "retry"

      # And the one that does: another commit landed first.
      assert Error.message(:stale_revision) =~ "landed first"
    end

    # `component.create`, `component.fork` and the scroll writes are
    # in-chain, so a guest receives these too. The guest view renders
    # `Cyfr.GuestError`, a second vocabulary that restates the sentences;
    # this case is what holds the two together.
    test "render the same sentence on all three surfaces" do
      for reason <- @commit_vocabulary do
        expected = Error.message(reason)

        assert PrismWeb.Ops.error_message(reason) == expected,
               "the console disagrees about #{inspect(reason)}"

        assert Opus.FormulaHandler.render_reason(reason) == expected,
               "the guest view disagrees about #{inspect(reason)}"
      end
    end

    test "a bare :unavailable is not the named-service one" do
      refute Error.message(:unavailable) == Error.message({:unavailable, "Storage"})
      assert Error.message({:unavailable, "Storage"}) =~ "retry shortly"
    end
  end

  describe "the crash vocabulary" do
    test "is part of the typed roster" do
      for reason <- @crash_vocabulary do
        assert Error.reason?(reason), "#{inspect(reason)} is not recognised"
        assert is_binary(Error.message(reason))
      end
    end

    test "renders the same sentence on all three surfaces" do
      for reason <- @crash_vocabulary do
        expected = Error.message(reason)

        assert PrismWeb.Ops.error_message(reason) == expected,
               "the console disagrees about #{inspect(reason)}"

        assert Opus.FormulaHandler.render_reason(reason) == expected,
               "the guest view disagrees about #{inspect(reason)}"
      end
    end

    test "distinguishes tool timeouts from crashes" do
      timeout = PrismWeb.Ops.error_message({:timeout, "Tool x timed out after 1ms"})
      crash = PrismWeb.Ops.error_message({:crashed, "Tool x crashed: boom"})

      assert timeout =~ "timed out"
      assert crash =~ "crashed"
      refute timeout == crash
    end
  end

  describe "the guest never sees an internal term" do
    test "an unknown reason renders as a generic sentence, not inspect output" do
      rendered = Opus.FormulaHandler.render_reason({:some_internal, %{"secret" => "leak"}})

      refute rendered =~ "secret"
      refute rendered =~ "leak"
      refute rendered =~ "%{"
    end

    test "a crafted binary still passes through" do
      assert Opus.FormulaHandler.render_reason("No provider found for scheme ftp") ==
               "No provider found for scheme ftp"
    end

    test "the other typed vocabularies render through their own module" do
      assert Opus.FormulaHandler.render_reason({:not_found, "component", "x"}) ==
               Error.message({:not_found, "component", "x"})

      # Opus renders from contract data alone (`Cyfr.GuestError`): a Sanctum
      # refusal reaches a guest only once CYFR has rendered it into the wire
      # answer, so the bare term is internal to the engine and generalized.
      unauthorized = {:missing_permission, :vault_read}
      assert Sanctum.Unauthorized.reason?(unauthorized)
      assert Opus.FormulaHandler.render_reason(unauthorized) == "The call failed."
    end
  end
end
