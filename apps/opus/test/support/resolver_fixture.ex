# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Test.Resolver do
  @moduledoc """
  A resolver of fixed answers, for a test of what the host decides about
  an address. It answers `getaddr/2` as `:inet` does, from the table
  below and never from the network, so a test that resolves a name
  asserts the decision the table leads to, not what the public DNS
  answers that day.

  The names, each with the class of address the code under test decides
  on (`Cyfr.Cidr`):

    * `public.test` — an A answer, `203.0.113.10`, public
    * `private.test` — an A answer, `10.0.0.5`, private
    * `metadata.test` — an A answer, `169.254.169.254`, the cloud
      metadata address
    * `dual.test` — an A answer, `203.0.113.20`, and an AAAA answer,
      `2001:db8::20`: a dual-stack host
    * `v6only.test` — an AAAA answer only, `2001:db8::30`
    * every other name — `nxdomain`; `nonexistent.test` by convention

  An address literal is answered as `:inet` answers it, without a lookup,
  so a test may mix literals and names. The table has no CNAME chain:
  `:inet.getaddr/2` follows one inside the resolver, and the code under
  test sees only the address it ends at.

  Injected through the `:resolver` option of `Opus.Egress.pin/2`, or
  `config :opus, :resolver` for the guest-facing entry points, which
  take no options. `Sanctum.Test.Resolver` is this table for CYFR's suite,
  which injects it into `Sanctum.Network.pin/2` as well.
  """

  @table %{
    "public.test" => %{inet: {203, 0, 113, 10}},
    "private.test" => %{inet: {10, 0, 0, 5}},
    "metadata.test" => %{inet: {169, 254, 169, 254}},
    "dual.test" => %{inet: {203, 0, 113, 20}, inet6: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x20}},
    "v6only.test" => %{inet6: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x30}}
  }

  @doc "The address of `name` in `family`, as `:inet.getaddr/2` answers it."
  @spec getaddr(charlist() | String.t(), :inet | :inet6) ::
          {:ok, :inet.ip_address()} | {:error, :nxdomain}
  def getaddr(name, family) when family in [:inet, :inet6] do
    name = to_string(name)

    case literal(name, family) do
      {:ok, ip} -> {:ok, ip}
      :error -> answer(Map.get(@table, name, %{}), family)
    end
  end

  defp literal(name, family) do
    case :inet.parse_address(String.to_charlist(name)) do
      {:ok, ip} when tuple_size(ip) == 4 and family == :inet -> {:ok, ip}
      {:ok, ip} when tuple_size(ip) == 8 and family == :inet6 -> {:ok, ip}
      _ -> :error
    end
  end

  defp answer(answers, family) do
    case Map.fetch(answers, family) do
      {:ok, ip} -> {:ok, ip}
      :error -> {:error, :nxdomain}
    end
  end
end
