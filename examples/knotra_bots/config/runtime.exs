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

# Reset only the example's default test database so `mix test` is deterministic
# across runs; an explicit KNOTRA_BOTS_DB is left alone.
if config_env() == :test and System.get_env("KNOTRA_BOTS_DB") in [nil, ""] do
  default_test_db = Path.expand("../_build/knotra_bots-test.sqlite3", __DIR__)

  if Path.expand(database) == default_test_db do
    for suffix <- ["", "-shm", "-wal"], do: File.rm(default_test_db <> suffix)
  end
end

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
  dashboard_token: env.("KNOTRA_BOTS_DASHBOARD_TOKEN", nil),
  notices_path: Path.expand("../_build/notices.log", __DIR__),
  effects_path: Path.expand("../_build/effects.log", __DIR__)

port = String.to_integer(env.("KNOTRA_BOTS_PORT", "4000"))

secret = env.("SECRET_KEY_BASE", nil)

secret_key_base =
  if secret == nil do
    if config_env() == :prod do
      raise "SECRET_KEY_BASE must be set in production"
    else
      Base.encode64(:crypto.hash(:sha512, "knotra_bots_dev_secret"))
    end
  else
    secret
  end

config :knotra_bots, KnotraBotsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: port],
  secret_key_base: secret_key_base,
  server: config_env() != :test
