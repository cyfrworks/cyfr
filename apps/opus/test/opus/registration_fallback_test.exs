# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RegistrationFallbackTest do
  @moduledoc """
  What an UNBOUND webhook or schedule does, pinned deliberately.

  A registration fires under its bound profile's consent or not at all.
  The legacy fallback for unbound rows is gone — the upgrade migration
  disables them, and one that slips through refuses with
  `:profile_required` instead of running with ambient authority. This
  tripwire is inverted from its Phase 3–4 form on purpose: if a fallback
  ever reappears, someone reopened the standing-invocation channel this
  flip closed, and they did it past a test that says so.
  """

  use ExUnit.Case, async: true

  @webhook_controller "apps/cyfr/lib/emissary_web/controllers/webhook_controller.ex"
  @cron_scheduler "apps/opus/lib/opus/cron_scheduler.ex"

  defp source(path), do: File.read!(Path.join(Path.expand("../../../..", __DIR__), path))

  test "an unbound webhook refuses rather than running with ambient authority" do
    src = source(@webhook_controller)

    assert src =~ "webhook.profile_id",
           "the webhook ingress must decide on the binding before running"

    refute src =~ "Opus.Executor.run(",
           "an unbound webhook must never fall back to legacy execution"

    assert src =~ ":profile_required"
  end

  test "an unbound schedule refuses rather than running with ambient authority" do
    src = source(@cron_scheduler)

    assert src =~ "schedule.profile_id",
           "the cron ingress must decide on the binding before running"

    refute src =~ "Opus.run(ctx",
           "an unbound schedule must never fall back to legacy execution"

    assert src =~ ":profile_required"
  end

  test "a bound registration has no legacy fallback" do
    for path <- [@webhook_controller, @cron_scheduler] do
      src = source(path)

      # The guard is `profile_id`, so a bound registration whose load
      # fails errors rather than quietly running with the caller's
      # ambient authority.
      assert src =~ "profile_id do",
             "#{path} must gate the authority path on the binding"
    end
  end
end
