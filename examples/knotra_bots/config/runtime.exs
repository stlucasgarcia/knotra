import Config

if File.exists?(".env") do
  # Real environment variables win over file values (Dotenvy merges left to right).
  System.put_env(Dotenvy.source!([".env", System.get_env()]))
end

env = fn name, default ->
  case System.get_env(name) do
    nil -> default
    "" -> default
    value -> value
  end
end

database =
  env.("KNOTRA_BOTS_DB", Path.expand("../_build/knotra_bots-#{config_env()}.sqlite3", __DIR__))

config :knotra_bots, KnotraBots.Repo,
  database: database,
  pool_size: 5,
  journal_mode: :wal,
  synchronous: :full,
  foreign_keys: :on,
  busy_timeout: 5_000,
  log: false

model =
  if config_env() == :test do
    "fake"
  else
    env.("KNOTRA_BOTS_MODEL", "google:gemini-2.5-flash")
  end

config :knotra_bots,
  model: model,
  notices_path: Path.expand("../_build/notices.log", __DIR__)

port = String.to_integer(env.("KNOTRA_BOTS_PORT", "4000"))

secret_key_base =
  env.("SECRET_KEY_BASE", Base.encode64(:crypto.hash(:sha512, "knotra_bots_dev_secret")))

config :knotra_bots, KnotraBotsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: port],
  secret_key_base: secret_key_base,
  server: config_env() != :test
