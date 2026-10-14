defmodule KnotraBots do
  @moduledoc """
  A runnable example host for the Knotra library.

  The host owns its Ecto Repo, migration, tenant authorization and this Phoenix
  LiveView. It demonstrates durable acceptance, a clarification input request, an
  operation-bound approval, responder provenance and restart recovery. The only
  effect is a fake append-only notice file; no network messaging happens.
  """

  @default_model "google:gemini-2.5-flash"
  @tenant "demo"
  @permissions [:submit, :inspect, :answer]

  @doc "The demo tenant used by the UI, the access policy and the tools."
  def tenant, do: @tenant

  @doc "Actions the dashboard scope grants; other Knotra actions stay forbidden."
  def permissions, do: @permissions

  @doc """
  Applies Knotra's persistence migration through the host's own workflow, as
  ADR 0001 requires. Run it before the server starts:

      mix knotra_bots.migrate
  """
  def migrate! do
    Ecto.Migrator.up(KnotraBots.Repo, 1, Knotra.Persistence.Migration, log: false)
  end

  @doc """
  Builds the configured model plugin.

  `"fake"` selects the offline deterministic model; anything else is passed to
  `Knotra.Models.ReqLLM`. `GEMINI_API_KEY` is forwarded at runtime only when
  `GOOGLE_API_KEY` (ReqLLM's provider default) is absent.
  """
  def model do
    case Application.get_env(:knotra_bots, :model, @default_model) do
      "fake" ->
        {KnotraBots.Models.Fake, []}

      model ->
        {KnotraBots.Models.Logged,
         plugin: {Knotra.Models.ReqLLM, model: model, options: options()}}
    end
  end

  @doc """
  Whether the configured model can be called. The dashboard refuses to submit
  while this is an error, so a missing key or bad model string is readable
  instead of becoming a redacted `plugin_exception` after acceptance.
  """
  def model_status do
    case model() do
      {KnotraBots.Models.Fake, _} ->
        :ok

      {KnotraBots.Models.Logged, opts} ->
        {_module, inner} = Keyword.fetch!(opts, :plugin)

        with {:ok, resolved} <- ReqLLM.model(inner[:model]),
             {:ok, _key, _source} <- ReqLLM.Keys.get(resolved, inner[:options] || []) do
          :ok
        else
          {:error, :invalid_format} ->
            {:error,
             "invalid KNOTRA_BOTS_MODEL #{inspect(inner[:model])} (expected \"provider:model\")"}

          {:error, message} when is_binary(message) ->
            {:error, message}

          {:error, other} ->
            {:error, inspect(other)}
        end
    end
  end

  def notices_path, do: Application.get_env(:knotra_bots, :notices_path)

  def start_instance, do: KnotraBots.Application.start_instance()
  def stop_instance, do: KnotraBots.Application.stop_instance()

  defp options do
    opts = [max_tokens: 1024]

    case {System.get_env("GOOGLE_API_KEY"), System.get_env("GEMINI_API_KEY")} do
      {google, key} when google in [nil, ""] and is_binary(key) and key != "" ->
        # `.env.example` sets GOOGLE_API_KEY to ""; treat that as absent.
        Keyword.put(opts, :api_key, key)

      _ ->
        opts
    end
  end
end
