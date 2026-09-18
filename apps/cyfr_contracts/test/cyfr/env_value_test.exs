# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.EnvValueTest do
  @moduledoc """
  Every reader takes an unset or blank variable as its default, takes a
  value of the accepted form, and refuses anything else with a message
  naming the variable and the form; a key's message never carries the
  value.
  """
  use ExUnit.Case, async: true

  alias Cyfr.EnvValue

  defp env(map), do: fn key -> Map.get(map, key) end

  describe "switch/3" do
    test "unset and blank take the default" do
      assert {:ok, true} = EnvValue.switch(env(%{}), "K", true)
      assert {:ok, false} = EnvValue.switch(env(%{"K" => "  "}), "K", false)
    end

    test "every spelling of on and off, any case" do
      for on <- ~w(on ON true True yes 1),
          do: assert({:ok, true} = EnvValue.switch(env(%{"K" => on}), "K", false))

      for off <- ~w(off OFF false False no 0),
          do: assert({:ok, false} = EnvValue.switch(env(%{"K" => off}), "K", true))
    end

    test "an unrecognised spelling is an error naming the key, not the default" do
      assert {:error, message} =
               EnvValue.switch(env(%{"CYFR_BUILDS" => "disabled"}), "CYFR_BUILDS", true)

      assert message =~ "CYFR_BUILDS"
      assert message =~ "disabled"
      assert message =~ "on or off"
    end
  end

  describe "milliseconds/3 and whole_number/4" do
    test "unset and blank keep the default; a whole number in range is taken" do
      assert {:ok, nil} = EnvValue.milliseconds(env(%{}), "K", 1_000..60_000)
      assert {:ok, nil} = EnvValue.milliseconds(env(%{"K" => " "}), "K", 1_000..60_000)
      assert {:ok, 1_000} = EnvValue.milliseconds(env(%{"K" => "1000"}), "K", 1_000..60_000)
      assert {:ok, 60_000} = EnvValue.milliseconds(env(%{"K" => " 60000 "}), "K", 1_000..60_000)
    end

    test "a unit, a fraction, a sign or a value out of range is an error naming the key and the unit" do
      for bad <- ~w(999 60001 30s 1e4 1.5 -5000 +5000 0x10 five) do
        assert {:error, message} =
                 EnvValue.milliseconds(env(%{"K_MS" => bad}), "K_MS", 1_000..60_000)

        assert message =~ "K_MS"
        assert message =~ bad
        assert message =~ "whole number of milliseconds from 1000 to 60000"
      end
    end

    test "a value out of range names the unit and the range" do
      assert {:ok, 512} = EnvValue.whole_number(env(%{"K" => "512"}), "K", 64..65_536, "MiB")

      assert {:error, message} =
               EnvValue.whole_number(env(%{"K" => "2G"}), "K", 64..65_536, "MiB")

      assert message =~ "whole number of MiB from 64 to 65536"
    end
  end

  describe "text/2" do
    test "is the trimmed value, or nil when unset or blank" do
      assert {:ok, nil} = EnvValue.text(env(%{}), "K")
      assert {:ok, nil} = EnvValue.text(env(%{"K" => "  "}), "K")
      assert {:ok, "/opt/seed"} = EnvValue.text(env(%{"K" => " /opt/seed "}), "K")
    end
  end

  describe "hex_key/2" do
    @key_hex "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

    test "decodes 64 hexadecimal digits in either case, and nil when unset" do
      bytes = :binary.list_to_bin(Enum.to_list(0..31))

      assert {:ok, nil} = EnvValue.hex_key(env(%{}), "K")
      assert {:ok, ^bytes} = EnvValue.hex_key(env(%{"K" => @key_hex}), "K")
      assert {:ok, ^bytes} = EnvValue.hex_key(env(%{"K" => String.upcase(@key_hex)}), "K")
      assert {:ok, ^bytes} = EnvValue.hex_key(env(%{"K" => " #{@key_hex} "}), "K")
    end

    test "refuses any other spelling with a message that names the form and never the value" do
      for bad <- [
            String.slice(@key_hex, 0..62),
            @key_hex <> "0",
            String.replace_suffix(@key_hex, "f", "g"),
            Base.encode64(:binary.list_to_bin(Enum.to_list(0..31))),
            "secret"
          ] do
        assert {:error, message} =
                 EnvValue.hex_key(env(%{"LOCUS_BUILDS_KEY" => bad}), "LOCUS_BUILDS_KEY")

        assert message =~ "LOCUS_BUILDS_KEY"
        assert message =~ "64 hexadecimal digits"
        refute message =~ bad
      end
    end
  end

  describe "port/2" do
    test "is a port from 1 to 65535, or nil when unset" do
      assert {:ok, nil} = EnvValue.port(env(%{}), "K")
      assert {:ok, 1} = EnvValue.port(env(%{"K" => "1"}), "K")
      assert {:ok, 4100} = EnvValue.port(env(%{"K" => " 4100 "}), "K")
      assert {:ok, 65_535} = EnvValue.port(env(%{"K" => "65535"}), "K")

      for bad <- ~w(0 65536 -1 4100a http 4100.0) do
        assert {:error, message} =
                 EnvValue.port(env(%{"LOCUS_BUILDS_PORT" => bad}), "LOCUS_BUILDS_PORT")

        assert message =~ "LOCUS_BUILDS_PORT"
        assert message =~ "port from 1 to 65535"
      end
    end
  end

  describe "bind/2" do
    test "is an IPv4 or IPv6 address as :inet reads it, or nil when unset" do
      assert {:ok, nil} = EnvValue.bind(env(%{}), "K")
      assert {:ok, {0, 0, 0, 0}} = EnvValue.bind(env(%{"K" => "0.0.0.0"}), "K")
      assert {:ok, {127, 0, 0, 1}} = EnvValue.bind(env(%{"K" => "127.0.0.1"}), "K")
      assert {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} = EnvValue.bind(env(%{"K" => "::1"}), "K")

      for bad <- ["builder", "127.0.0.1:4100", "http://127.0.0.1", "256.0.0.1"] do
        assert {:error, message} =
                 EnvValue.bind(env(%{"LOCUS_BUILDS_BIND" => bad}), "LOCUS_BUILDS_BIND")

        assert message =~ "LOCUS_BUILDS_BIND"
        assert message =~ "IPv4 or IPv6 address"
      end
    end
  end

  describe "url/2" do
    test "is a base URL with no path, without its trailing slash, or nil when unset" do
      assert {:ok, nil} = EnvValue.url(env(%{}), "K")

      assert {:ok, "http://builder:4100"} =
               EnvValue.url(env(%{"K" => "http://builder:4100"}), "K")

      assert {:ok, "https://locus.internal"} =
               EnvValue.url(env(%{"K" => "https://locus.internal/"}), "K")

      for bad <- [
            "builder:4100",
            "ftp://builder",
            "http://builder:4100/build",
            "http://u:p@builder"
          ] do
        assert {:error, message} =
                 EnvValue.url(env(%{"CYFR_LOCUS_BUILDS_URL" => bad}), "CYFR_LOCUS_BUILDS_URL")

        assert message =~ "CYFR_LOCUS_BUILDS_URL"
        assert message =~ "http or https URL with a host and no path"
      end
    end
  end
end
