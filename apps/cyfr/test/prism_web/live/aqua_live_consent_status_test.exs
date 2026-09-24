# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLiveConsentStatusTest do
  @moduledoc """
  What the AQUA page says about consent: a row and a re-consent button per
  source whose consent no longer answers, nothing when none drifted, and
  — when the status could not be read — one line that says so and offers
  nothing to press. An outage never reads as "all consents current".
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PrismWeb.AquaLive

  test "an unreadable status is one line, with no re-consent button" do
    for refused <- [:unavailable, :corrupt, :forbidden] do
      html = render_component(&AquaLive.consent_status/1, stale_consents: {:error, refused})

      assert html =~ "Consent status unavailable"
      assert [_one] = Regex.scan(~r/role="status"/, html)
      refute html =~ "Re-consent"
      refute html =~ "open_consent"
    end
  end

  test "each stale or drifted source is a row with its own re-consent button" do
    html =
      render_component(&AquaLive.consent_status/1,
        stale_consents:
          {:ok,
           [
             {"formula:local.uses-remote", :stale},
             {"agent:local.aqua", {:drifted, ["notes.keep"]}}
           ]}
      )

    assert html =~ ~s(id="aqua-consent-drift-formula:local.uses-remote")
    assert html =~ ~s(id="aqua-consent-drift-agent:local.aqua")
    assert html =~ "uses-remote cannot run until a member consents again"
    assert html =~ "notes.keep"
    assert [_, _] = Regex.scan(~r/Re-consent/, html)
    refute html =~ "Consent status unavailable"
  end

  test "nothing stale renders nothing" do
    html = render_component(&AquaLive.consent_status/1, stale_consents: {:ok, []})

    refute html =~ "Re-consent"
    refute html =~ "Consent status unavailable"
  end
end
