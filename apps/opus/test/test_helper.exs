# Ensure the Opus application supervisor is running so GenServers
# (RateLimiter, SharedEngine, CronScheduler, etc.) are alive during tests.
{:ok, _} = Application.ensure_all_started(:opus)

ExUnit.start()
