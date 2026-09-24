# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.LoggerContextTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cyfr.LoggerContext

  describe "set_from_context/1" do
    test "sets correct Logger metadata" do
      ctx = %{user_id: "user_123", athanor_id: "ath_abc", auth_method: :oidc}

      LoggerContext.set_from_context(ctx)

      metadata = Logger.metadata()
      assert metadata[:user_id] == "user_123"
      assert metadata[:athanor_id] == "ath_abc"
      assert metadata[:auth_method] == :oidc
    end
  end

  describe "set_request_id/1" do
    test "sets request_id metadata" do
      LoggerContext.set_request_id("req_abc123")
      metadata = Logger.metadata()
      assert metadata[:request_id] == "req_abc123"
    end
  end

  describe "capture/0 and restore/1" do
    test "cross-process propagation" do
      LoggerContext.set_from_context(%{
        user_id: "parent_user",
        athanor_id: nil,
        auth_method: :oidc
      })

      LoggerContext.set_request_id("req_parent")

      captured = LoggerContext.capture()

      task =
        Task.async(fn ->
          # Metadata should be empty in new process
          assert Logger.metadata()[:user_id] == nil

          LoggerContext.restore(captured)

          metadata = Logger.metadata()
          assert metadata[:user_id] == "parent_user"
          assert metadata[:request_id] == "req_parent"
          :ok
        end)

      assert Task.await(task) == :ok
    end
  end

  describe "unexpected/3" do
    defp line(message, level \\ :warning) do
      log = capture_log(fn -> LoggerContext.unexpected(__MODULE__, message, level) end)
      [line] = Regex.run(~r/\[Cyfr\.LoggerContextTest\] unexpected message: .*/, log)
      line
    end

    defp shape(message),
      do:
        String.replace_prefix(line(message), "[Cyfr.LoggerContextTest] unexpected message: ", "")

    test "an atom is itself; a pid, reference or function is its type" do
      assert shape(:stray) == ":stray"
      assert shape(self()) == "pid"
      assert shape(make_ref()) == "reference"
      assert shape(fn -> :ok end) == "function"
    end

    test "a tuple is its leading atom and arity" do
      assert shape({:DOWN, make_ref(), :process, self(), :normal}) == "tuple :DOWN/5"
      assert shape({"not an atom", :x}) == "tuple/2"
      assert shape({}) == "tuple/0"
    end

    test "a struct is its module and sorted field keys" do
      assert shape(%URI{host: "secret.example", userinfo: "user:pass"}) ==
               "%URI{:authority, :fragment, :host, :path, :port, :query, :scheme, :userinfo}"
    end

    test "a map is its size and its first ten sorted keys; a non-atom key is its type" do
      map = Map.new(?a..?z, &{:"#{<<&1>>}", "value-#{<<&1>>}"})

      assert shape(map) == "map/26 [:a, :b, :c, :d, :e, :f, :g, :h, :i, :j]"

      assert shape(%{:atom => 1, "sk-live-key" => 2, {:t, 1} => 3, 7 => 4}) ==
               "map/4 [integer, :atom, tuple, binary]"
    end

    test "anything else is its type and size" do
      assert shape("sk-secret") == "binary/9 bytes"
      assert shape(<<1::3>>) == "bitstring/3 bits"
      assert shape([1, 2, 3]) == "list/3"
      assert shape([1, 2 | :improper]) == "list/2"
      assert shape(42) == "integer"
      assert shape(1.5) == "float"
    end

    test "no value reaches the line" do
      secret = "sk-live-0123456789abcdef"

      for message <- [
            secret,
            {:event, secret},
            %{"token" => secret},
            %{secret => 1},
            %{{:credential, secret} => 1},
            [secret],
            %URI{userinfo: secret}
          ] do
        refute line(message) =~ "0123456789abcdef"
      end
    end

    test "the line is capped near 200 characters" do
      keys = Map.new(1..10, &{:"#{String.duplicate(<<?a + &1>>, 60)}", &1})

      assert String.length(line(keys)) <= 200
      assert String.ends_with?(line(keys), "…")
    end

    test "the level is the caller's, and must be a Logger level" do
      assert capture_log(fn -> LoggerContext.unexpected(__MODULE__, :x, :error) end) =~ "[error]"

      # Built at run time: a literal is refused by the type checker first.
      notice = String.to_existing_atom("notice")

      assert_raise FunctionClauseError, fn ->
        LoggerContext.unexpected(__MODULE__, :x, notice)
      end
    end
  end
end
