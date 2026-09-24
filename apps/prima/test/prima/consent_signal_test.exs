# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ConsentSignalTest do
  @moduledoc """
  The consent remediation signal's shape: four tags, a map payload, a
  sentence, `error.data` and a refusal class for each.
  """

  use ExUnit.Case, async: true

  alias Prima.ConsentSignal

  @classes %{
    setup_required: :setup_required,
    consent_required: :consent_required,
    consent_conflict: :conflict,
    restart_required: :cancelled
  }

  test "the roster is the four tags" do
    assert ConsentSignal.tags() ==
             [:setup_required, :consent_required, :consent_conflict, :restart_required]
  end

  test "a signal is a tag with a map payload, and nothing else is" do
    for tag <- ConsentSignal.tags() do
      assert ConsentSignal.signal?({tag, %{}})
      refute ConsentSignal.signal?({tag, "payload"})
    end

    refute ConsentSignal.signal?({:not_a_tag, %{}})
    refute ConsentSignal.signal?(:setup_required)
  end

  test "each signal has a sentence, its data and its class" do
    for tag <- ConsentSignal.tags() do
      payload = %{"node_ref" => "c:local.x:1.0.0"}
      signal = {tag, payload}

      assert is_binary(ConsentSignal.message(signal))
      refute ConsentSignal.message(signal) =~ "%{"

      assert ConsentSignal.data(signal) == %{
               "tag" => Atom.to_string(tag),
               "payload" => payload
             }

      assert Prima.Refusal.classify(signal).class == Map.fetch!(@classes, tag)
      assert Prima.Refusal.classify(signal).message == ConsentSignal.message(signal)
    end
  end

  test "the setup sentence names what the payload names" do
    assert ConsentSignal.message(
             {:setup_required, %{"need" => "API_KEY", "node_ref" => "c:local.x:1.0.0"}}
           ) =~ ~s(needs a vault entry for "API_KEY")

    assert ConsentSignal.message({:consent_required, %{"detail" => "scope widened"}}) ==
             "Consent required: scope widened"
  end
end
