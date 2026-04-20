defmodule SanctumArx.IdentityLinksTODO do
  @moduledoc false

  # Phase D.2 placeholder — DO NOT IMPLEMENT YET.
  #
  # Per auth_refactor.md §Phase D (line 670), Phase D.2 ships:
  #   - apps/cyfr/priv/repo/migrations/*_create_identity_links.exs (Arx-only)
  #   - apps/cyfr/lib/sanctum_arx/identity_links.ex
  #   - Arx Shell UI for identity linking + namespace claim + multi-device
  #
  # This module exists only to make the deferral visible to greppers.
  # Actual implementation is BLOCKED on Arx roadmap items 2.1d (org picker)
  # and 2.1e (membership enforcement) per the spec.
  #
  # When Phase D.2 unblocks:
  #   1. Mirror SanctumArx.Memberships (same Ecto + require_arx pattern).
  #   2. Store table: identity_links (user_id, provider, provider_subject,
  #      access_token_ciphertext, linked_at). UNIQUE (user_id, provider).
  #   3. Arx Shell LiveView: "Link GitHub/Google identity" flow.
  #   4. Claim flow: Arx enterprise-OIDC user falls through to the linked
  #      identity's access_token when calling cyfr.run claim endpoints.
  #
  # See auth_refactor.md §Phase D.2 for the full contract and §4 clause 5
  # for the Lane 2 enterprise-OIDC semantics this unblocks.
end
