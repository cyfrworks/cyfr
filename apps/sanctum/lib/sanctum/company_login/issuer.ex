# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CompanyLogin.Issuer do
  @moduledoc """
  A company's issuer: the URL that begins its sign-in for an attempt and
  its state, and the exchange of the code its callback carries for the
  configuration and the subject it answered. The exchange runs outside
  any transaction. `{:error, :issuer_refused}` is the issuer's own
  refusal or an answer that proves nothing; `{:error, :unavailable}` an
  issuer that could not be reached.
  """

  @callback authorize_url(Sanctum.CompanyLogin.attempt(), state :: String.t()) ::
              {:ok, String.t()} | {:error, :unavailable}

  @callback complete(code :: String.t(), Sanctum.CompanyLogin.attempt()) ::
              {:ok, %{configuration: Sanctum.CompanyLogin.configuration(), subject: String.t()}}
              | {:error, :issuer_refused | :wrong_organization | :unavailable}
end
