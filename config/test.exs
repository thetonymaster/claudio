import Config

config :tesla, adapter: Claudio.MockAdapter

config :claudio, Claudio.Client,
  adapter: Claudio.MockAdapter,
  retry: false
