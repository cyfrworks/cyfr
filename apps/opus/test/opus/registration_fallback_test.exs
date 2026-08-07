# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RegistrationFallbackTest do
  @moduledoc """
  What an UNBOUND webhook or schedule does, pinned deliberately.

  Through Phase 4 a registration with no `profile_id` keeps firing on the
  legacy path: upgrading an install must not silently kill every existing
  schedule. Phase 5 flips that to disabled-until-reconsented, and this
  test is what makes the flip a decision rather than a discovery — when
  it changes, someone changed it on purpose.

  A registration that IS bound never falls back: the binding is the
  point, so it fires under that profile's consent or not at all.
  """

  use ExUnit.Case, async: true

  @webhook_controller "apps/cyfr/lib/emissary_web/controllers/webhook_controller.ex"
  @cron_scheduler "apps/opus/lib/opus/cron_scheduler.ex"

  defp source(path), do: File.read!(Path.join(Path.expand("../../../..", __DIR__), path))

  test "an unbound webhook still runs the legacy path" do
    src = source(@webhook_controller)

    assert src =~ "webhook.profile_id",
           "the webhook ingress must decide on the binding before running"

    assert src =~ "Opus.Executor.run(",
           """
           An unbound webhook currently falls back to legacy execution.
           If this is being removed, Phase 5 has arrived: the fallback
           becomes disabled-until-reconsented, and the migration guide
           must say so before the release ships.
           """
  end

  test "an unbound schedule still runs the legacy path" do
    src = source(@cron_scheduler)

    assert src =~ "schedule.profile_id",
           "the cron ingress must decide on the binding before running"

    assert src =~ "Opus.run(",
           """
           An unbound schedule currently falls back to legacy execution.
           Removing this is the Phase 5 flip — see the note above.
           """
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
