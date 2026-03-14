# SPDX-License-Identifier: FSL-1.1-MIT
# Copyright 2024 CYFR Inc. All Rights Reserved.

defmodule SanctumArx do
  @moduledoc """
  Sanctum Arx - Sanctum Arx of Sanctum.

  Extends the base Sanctum (Apache 2.0) with enterprise features:

  - **License validation** - Validates `/etc/cyfr/license.sig` at startup
  - **OIDC authentication** - Full OAuth2/OIDC provider support
  - **Feature gating** - Runtime and compile-time feature gates
  - **Enterprise auth** - SAML 2.0, custom OIDC, SCIM (future)
  - **Vault secrets** - HashiCorp Vault backend (future)
  - **SIEM forwarding** - Enterprise audit logging (future)

  ## License

  SanctumArx is licensed under FSL-1.1-MIT (Functional Source License).
  See LICENSE for details.

  ## Usage

  SanctumArx is typically used through the `cyfr_arx` release, which
  automatically loads enterprise configuration and validates the license.

      # Build enterprise release
      MIX_ENV=prod mix release cyfr_arx

      # Run with license
      CYFR_LICENSE_PATH=/path/to/license.sig _build/prod/rel/cyfr_arx/bin/cyfr_arx start

  ## Feature Checks

  Use `SanctumArx.Edition` to check feature availability:

      if SanctumArx.Edition.feature_available?(:saml) do
        # SAML is licensed
      end

  """

  @doc """
  Returns the current edition information.
  """
  defdelegate info, to: SanctumArx.Edition
end
