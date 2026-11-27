// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! `cyfr:oauth/token`: an access token CYFR dispenses through the attempt
//! for a provider, which CYFR adds to the attempt's masking set before it
//! answers. A refusal crosses as a sentence naming its shape, never the
//! material involved; a call CYFR refuses otherwise crosses as the
//! sentence for an unavailable credential store.

use serde_json::Value;

use super::{Guest, args, catalyst, ended};
use crate::host::{Outcome, Reading};
use crate::words::UNCERTAIN;

impl catalyst::cyfr::oauth::token::Host for Guest {
    async fn get_access_token(
        &mut self,
        provider: String,
    ) -> wasmtime::Result<Result<String, String>> {
        let run = self.run.clone();
        let outcome = run
            .host
            .call("oauth_token", args([("provider", Value::String(provider))]))
            .await;
        ended("oauth_token", &outcome)?;
        Ok(match outcome {
            Outcome::Answered(Reading::Ok(token)) => match token.value() {
                Value::String(token) => Ok(token.clone()),
                _ => Err(UNAVAILABLE.to_owned()),
            },
            Outcome::Answered(Reading::GuestError { message, .. }) => {
                Err(message.as_str().to_owned())
            }
            Outcome::Uncertain => Err(UNCERTAIN.to_owned()),
            _ => Err(UNAVAILABLE.to_owned()),
        })
    }
}

const UNAVAILABLE: &str = "the credential store is unavailable";
