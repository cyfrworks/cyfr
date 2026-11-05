# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ModelTest do
  @moduledoc """
  The shared reading of `model/chat@1`: the contract is named once, a
  manifest speaks it or not, the catalyst envelope decodes to its data or
  its typed refusal, whatever wrapping a run result gives it, and the
  members a caller sets per brain hold to the shared vectors
  (`tests/fixtures/model_chat.json`, which a model catalyst's own tests
  read too): every valid describe's options read as the vector says,
  every invalid one is refused naming its member, and so are chat
  requests and responses; the file carries exactly the categories this
  test reads, none empty.
  """

  # Synchronous: one test asserts the log stays empty, and `capture_log/1`
  # reads every process's log, so a concurrent test's warning would land in it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Prima.Model

  # Read as this module compiles, so a checkout without the file fails
  # here, naming it, rather than running without the vectors.
  @vectors Path.expand("../../../../tests/fixtures/model_chat.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @categories ~w(option_kinds valid_describes invalid_describes valid_chat_requests invalid_chat_requests valid_chat_responses invalid_chat_responses)

  describe "the vectors" do
    test "carry exactly the categories this test reads, none empty" do
      assert @vectors |> Map.keys() |> Enum.sort() == Enum.sort(["comment" | @categories])

      for category <- @categories do
        assert @vectors[category] not in [nil, []], "#{category} is empty"
      end
    end

    test "pin the option kinds this side spells" do
      assert @vectors["option_kinds"] == Model.option_kinds()
    end

    test "every valid describe declares its options as they are" do
      for %{"why" => why, "describe" => described, "options" => options} <-
            @vectors["valid_describes"] do
        assert Model.options(described) == {:ok, options}, why
      end
    end

    test "every invalid describe is refused, naming its member" do
      for %{"why" => why, "describe" => described, "member" => member} <-
            @vectors["invalid_describes"] do
        assert Model.options(described) == {:error, {:invalid, member}}, why
      end
    end

    test "every valid chat request holds under what its brain declares" do
      for %{"why" => why, "declared" => declared, "request" => request} <-
            @vectors["valid_chat_requests"] do
        assert {:ok, ^declared} = Model.options(%{"options" => declared})
        assert Model.check_chat_request(request, declared) == :ok, why
      end
    end

    test "every invalid chat request is refused, naming its member" do
      for %{"why" => why, "declared" => declared, "request" => request, "member" => member} <-
            @vectors["invalid_chat_requests"] do
        assert {:ok, ^declared} = Model.options(%{"options" => declared})
        assert Model.check_chat_request(request, declared) == {:error, {:invalid, member}}, why
      end
    end

    test "every valid chat response names its session, or none" do
      for %{"why" => why, "response" => response, "session" => session} <-
            @vectors["valid_chat_responses"] do
        assert Model.response_session(response) == {:ok, session}, why
      end
    end

    test "every invalid chat response is refused, naming its member" do
      for %{"why" => why, "response" => response, "member" => member} <-
            @vectors["invalid_chat_responses"] do
        assert Model.response_session(response) == {:error, {:invalid, member}}, why
      end
    end
  end

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
