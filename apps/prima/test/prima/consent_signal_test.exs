# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ConsentSignalTest do
  @moduledoc """
  The consent signal's shape: five tags, a map payload, a sentence,
  `error.data` and a refusal class for each; `confirmation_required`
  names its confirmation's id or is no signal.
  """

  use ExUnit.Case, async: true

  alias Prima.ConsentSignal

  require ConsentSignal

  @classes %{
    setup_required: :setup_required,
    consent_required: :consent_required,
    consent_conflict: :conflict,
    restart_required: :cancelled,
    confirmation_required: :confirmation_required
  }

  @confirmation %{
    id: "confirmation-7f3a",
    operation: "vault/create",
    expires_at: ~U[2026-09-29 12:05:00Z]
  }

  # A payload each tag accepts.
  defp payload(:confirmation_required), do: %{"id" => "confirmation-7f3a"}
  defp payload(_tag), do: %{"node_ref" => "c:local.x:1.0.0"}

  defp guarded?({tag, payload}) when ConsentSignal.is_signal(tag, payload), do: true
  defp guarded?(_term), do: false

  test "the roster is the five tags" do
    assert ConsentSignal.tags() ==
             [
               :setup_required,
               :consent_required,
               :consent_conflict,
               :restart_required,
               :confirmation_required
             ]
  end

  test "a signal is a tag with a map payload, and nothing else is" do
    for tag <- ConsentSignal.tags() do
      assert ConsentSignal.signal?({tag, payload(tag)})
      assert guarded?({tag, payload(tag)})
      refute ConsentSignal.signal?({tag, "payload"})
    end

    refute ConsentSignal.signal?({:not_a_tag, %{}})
    refute ConsentSignal.signal?(:setup_required)
  end

  test "a confirmation signal names its confirmation's id, under either key form" do
    assert ConsentSignal.signal?({:confirmation_required, @confirmation})

    assert ConsentSignal.signal?(
             {:confirmation_required,
              %{"id" => "confirmation-7f3a", "operation" => "vault/create"}}
           )

    for payload <- [
          %{},
          %{operation: "vault/create", expires_at: ~U[2026-09-29 12:05:00Z]},
          %{id: nil},
          %{id: ""},
          %{"id" => ""},
          %{id: 7},
          %{"id" => %{"nested" => "x"}},
          # An id named both ways: no reader may check one and render the other.
          %{:id => 7, "id" => "confirmation-7f3a"},
          %{:id => %{}, "id" => "confirmation-7f3a"},
          %{:id => "confirmation-7f3a", "id" => "confirmation-other"}
        ] do
      refute ConsentSignal.signal?({:confirmation_required, payload}),
             "#{inspect(payload)} is a confirmation signal without an id"

      refute guarded?({:confirmation_required, payload})
      refute Prima.Refusal.reason?({:confirmation_required, payload})
    end
  end

  test "a confirmation signal without its id is refused by shape on every reader" do
    signal = {:confirmation_required, %{operation: "vault/create"}}

    assert_raise FunctionClauseError, fn -> ConsentSignal.data(signal) end
    assert_raise FunctionClauseError, fn -> ConsentSignal.message(signal) end

    ExUnit.CaptureLog.capture_log(fn ->
      assert %Prima.Refusal{class: :internal} = Prima.Refusal.classify(signal)
    end)
  end

  test "each signal has a sentence, its data and its class" do
    for tag <- ConsentSignal.tags() do
      payload = payload(tag)
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

  test "the confirmation sentence names the change and its id, and sends the person to Prism" do
    assert ConsentSignal.message({:confirmation_required, @confirmation}) ==
             "Confirmation required: vault/create needs a fresh confirmation — " <>
               "confirm it in Prism (confirmation confirmation-7f3a)"

    assert ConsentSignal.message({:confirmation_required, %{"id" => "confirmation-7f3a"}}) ==
             "Confirmation required: this change needs a fresh confirmation — " <>
               "confirm it in Prism (confirmation confirmation-7f3a)"
  end

  test "the confirmation data carries its three fields alone, and encodes with its id" do
    data = ConsentSignal.data({:confirmation_required, @confirmation})

    assert data == %{
             "tag" => "confirmation_required",
             "payload" => %{
               "id" => "confirmation-7f3a",
               "operation" => "vault/create",
               "expires_at" => ~U[2026-09-29 12:05:00Z]
             }
           }

    # Whatever else a producer put in the payload reaches no wire.
    assert ConsentSignal.data(
             {:confirmation_required,
              Map.put(@confirmation, :arguments, %{"token" => "sk-live-secret"})}
           ) == data

    assert ConsentSignal.data({:confirmation_required, %{"id" => "c-1", "extra" => "x"}}) ==
             %{"tag" => "confirmation_required", "payload" => %{"id" => "c-1"}}

    assert %{
             "tag" => "confirmation_required",
             "payload" => %{
               "id" => "confirmation-7f3a",
               "operation" => "vault/create",
               "expires_at" => "2026-09-29T12:05:00Z"
             }
           } = data |> Jason.encode!() |> Jason.decode!()
  end
end
