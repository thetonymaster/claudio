import Config

config :tesla, adapter: Tesla.Adapter.Mint

import_config "#{config_env()}.exs"
