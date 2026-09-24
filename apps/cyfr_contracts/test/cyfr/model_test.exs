# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ModelTest do
  @moduledoc """
  The shared reading of `model/chat@1`: the contract is named once, a
  manifest speaks it or not, and the catalyst envelope decodes to its
  data or its typed refusal, whatever wrapping a run result gives it.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cyfr.Model

  test "a manifest speaks the contract when it declares it, by name" do
    assert Model.chat_contract() == "model/chat@1"
    assert Model.speaks_chat?(%{"contracts" => ["model/chat@1"]})
    assert Model.speaks_chat?(~s({"contracts": ["other/x@2", "model/chat@1"]}))
    refute Model.speaks_chat?(%{"contracts" => ["model/chat@2"]})
    refute Model.speaks_chat?(%{"contracts" => "model/chat@1"})
    refute Model.speaks_chat?(%{})
    refute Model.speaks_chat?(nil)
    refute Model.speaks_chat?("not json")
  end

  test "reading a manifest that does not decode says nothing in the log" do
    assert capture_log(fn -> refute Model.speaks_chat?("{not json") end) == ""
  end

  test "a 2xx envelope decodes to its data, from a run result, a map or JSON" do
    data = %{"models" => [%{"id" => "m"}]}
    envelope = %{"status" => 200, "data" => data}

    assert {:ok, ^data} = Model.decode_envelope(envelope)
    assert {:ok, ^data} = Model.decode_envelope(%{result: envelope})
    assert {:ok, ^data} = Model.decode_envelope(%{"result" => Jason.encode!(envelope)})
    assert {:ok, ^data} = Model.decode_envelope(Jason.encode!(envelope))
  end

  test "a refusal decodes to its type and message; anything else is malformed" do
    refusal = %{"status" => 429, "error" => %{"type" => "rate_limited", "message" => "slow"}}

    assert {:error, %{"type" => "rate_limited", "message" => "slow"}} =
             Model.decode_envelope(refusal)

    assert {:error, %{"type" => "provider_error", "message" => "plain"}} =
             Model.decode_envelope(%{"status" => 500, "error" => "plain"})

    assert {:error, %{"type" => "malformed"}} = Model.decode_envelope(%{"status" => 200})

    assert {:error, %{"type" => "malformed"}} =
             Model.decode_envelope(%{"status" => 200, "data" => "s"})

    assert {:error, %{"type" => "malformed"}} = Model.decode_envelope("not json")
    assert {:error, %{"type" => "malformed"}} = Model.decode_envelope(%{"combined_text" => "x"})
    assert {:error, %{"type" => "malformed"}} = Model.decode_envelope(nil)
  end
end
