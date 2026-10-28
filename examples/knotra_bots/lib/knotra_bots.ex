defmodule KnotraBots do
  @moduledoc """
  A runnable example host for the Knotra library.

  The host owns its Ecto Repo, migration, tenant authorization and Phoenix
  LiveViews. Humans and host-defined agents share channels; each agent reply is
  one durable execution with an inline clarification or approval gate and a public
  trace. Agent replies may mention teammates to hand work off. The only effect is
  a fake append-only notice file; no network messaging happens.
  """

  @default_model "google:gemini-2.5-flash"
  @catalog [
    "google:gemini-2.5-flash",
    "google:gemini-2.5-pro",
    "openai:gpt-4o-mini",
    "xai:grok-4.6",
    "anthropic:claude-sonnet-4-5"
  ]
  @offline "fake"
  @tenant "demo"
  @permissions [:submit, :inspect, :answer]

  @doc "The demo tenant used by the UI, the access policy and the tools."
  def tenant, do: @tenant

  @doc "Actions the dashboard scope grants; other Knotra actions stay forbidden."
  def permissions, do: @permissions

  @doc "Host authorization scope handed to Knotra's public API."
  def scope, do: %{tenant: @tenant, permissions: @permissions}

  @doc "Selectable model strings: the online catalog plus the offline fake."
  def catalog, do: @catalog ++ [@offline]

  @doc "The model string the app was configured with (`KNOTRA_BOTS_MODEL`)."
  def configured_model, do: Application.get_env(:knotra_bots, :model, @default_model)

  @doc """
  Applies the migrations through the host's own workflow, as ADR 0001 requires,
  then seeds the starter agents and channels. Run it before the server starts:

      mix knotra_bots.migrate
  """
  def migrate! do
    Ecto.Migrator.up(KnotraBots.Repo, 1, Knotra.Persistence.Migration, log: false)
    Ecto.Migrator.up(KnotraBots.Repo, 2, KnotraBots.Persistence.Migration, log: false)
    Ecto.Migrator.up(KnotraBots.Repo, 3, KnotraBots.Persistence.MigrationV3, log: false)
    Ecto.Migrator.up(KnotraBots.Repo, 4, KnotraBots.Persistence.MigrationV4, log: false)
    KnotraBots.Agents.seed!()
    KnotraBots.Channels.seed!()
  end

  @doc """
  Builds the configured model plugin.

  `"fake"` selects the offline deterministic model; anything else is passed to
  `Knotra.Models.ReqLLM`. `GEMINI_API_KEY` is forwarded at runtime only for Google
  models and only when `GOOGLE_API_KEY` (ReqLLM's provider default) is absent.
  """
  def model do
    case configured_model() do
      "fake" ->
        {KnotraBots.Models.ChatFake,
         [name: "Check", handle: "check", system_prompt: "Reply with the single word: ok"]}

      model ->
        {KnotraBots.Models.Logged,
         plugin: {Knotra.Models.ReqLLM, model: model, options: model_options(model, "")}}
    end
  end

  @doc "ReqLLM options for a bot, including its system prompt when it has one."
  def model_options(model, system_prompt) do
    opts = [max_tokens: 1024]

    opts =
      if system_prompt in [nil, ""],
        do: opts,
        else: Keyword.put(opts, :system_prompt, system_prompt)

    case {provider(model), System.get_env("GOOGLE_API_KEY"), System.get_env("GEMINI_API_KEY")} do
      {"google", google, key} when google in [nil, ""] and is_binary(key) and key != "" ->
        # `.env.example` sets GOOGLE_API_KEY to ""; treat that as absent. Never
        # forward a Google credential to a different provider.
        Keyword.put(opts, :api_key, key)

      _ ->
        opts
    end
  end

  defp provider(model) when is_binary(model),
    do: model |> String.split(":", parts: 2) |> hd()

  defp provider(_model), do: nil

  @doc "The ReqLLM model plugin for a bot row; shared by single runs and conversations."
  def req_llm_plugin(%{model: model, system_prompt: prompt}) do
    {KnotraBots.Models.Logged,
     plugin: {Knotra.Models.ReqLLM, model: model, options: model_options(model, prompt)}}
  end

  @doc """
  Whether a model string can be called. The dashboard and the conversation form
  refuse to start while this is an error, so a missing key or bad model string is
  readable instead of becoming a redacted `plugin_exception` after acceptance.
  """
  def model_status("fake"), do: :ok

  def model_status(model) when is_binary(model) do
    with {:ok, resolved} <- ReqLLM.model(model),
         {:ok, _key, _source} <-
           ReqLLM.Keys.get(resolved, Keyword.take(model_options(model, ""), [:api_key])) do
      :ok
    else
      {:error, :invalid_format} ->
        {:error, "invalid model #{inspect(model)} (expected \"provider:model\")"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, other} ->
        {:error, inspect(other)}
    end
  end

  @doc "Preflight for the app's configured model (`mix knotra_bots.check`)."
  def model_status, do: model_status(configured_model())

  def notices_path, do: Application.get_env(:knotra_bots, :notices_path)

  def start_instance, do: KnotraBots.Application.start_instance()
  def stop_instance, do: KnotraBots.Application.stop_instance()
end
