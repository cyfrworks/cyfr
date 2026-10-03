# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.BoundedBodyTest do
  use ExUnit.Case, async: true

  alias Prima.BoundedBody

  describe "collector/1 + read/2" do
    test "collects a within-limit body in order" do
      collector = BoundedBody.collector(10)
      resp = %{private: %{}}

      {:cont, {_req, resp}} = collector.({:data, "12345"}, {:req, resp})
      {:cont, {_req, resp}} = collector.({:data, "67890"}, {:req, resp})

      assert BoundedBody.read(resp, 10) == {:ok, "1234567890"}
    end

    test "halts the transfer past the ceiling and reports the size" do
      collector = BoundedBody.collector(10)
      resp = %{private: %{}}

      {:cont, {_req, resp}} = collector.({:data, "1234567890"}, {:req, resp})
      {:halt, {_req, resp}} = collector.({:data, "x"}, {:req, resp})

      assert BoundedBody.read(resp, 10) == {:error, {:response_too_large, 11, 10}}
    end

    test "an empty transfer collects an empty body" do
      assert BoundedBody.read(%{private: %{}}, 10) == {:ok, ""}
    end
  end
end
