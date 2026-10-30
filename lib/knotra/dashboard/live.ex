if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Knotra.Dashboard.Live do
    @moduledoc false
    use Phoenix.LiveView

    alias Knotra.Observability

    @tabs [
      {:overview, "Overview"},
      {:executions, "Executions"},
      {:agents, "Agents"},
      {:swarms, "Swarms"},
      {:topology, "Topology"},
      {:messages, "Messages"}
    ]

    @statuses [
      {"all", "All statuses"},
      {"running", "Running"},
      {"waiting", "Waiting"},
      {"completed", "Completed"},
      {"failed", "Failed / blocked"}
    ]

    @kinds [
      {"all", "All messages"},
      {"assistant", "Assistant"},
      {"tool", "Tool"},
      {"input", "Input"},
      {"human", "Human"},
      {"error", "Error / notice"}
    ]

    @css """
    .knotra {
      color-scheme: light;
      --k-bg: #f7f6f2;
      --k-panel: #ffffff;
      --k-panel-2: #efeee9;
      --k-border: #e2e1da;
      --k-text: #191a17;
      --k-muted: #6c6f66;
      --k-accent: #1f6f4a;
      --k-accent-soft: #e3f1e8;
      --k-green: #1f6f4a;
      --k-green-soft: #e3f1e8;
      --k-amber: #9a6200;
      --k-amber-soft: #fff8e6;
      --k-red: #a12d24;
      --k-red-soft: #fbeae7;
      --k-shadow: 0 1px 2px rgba(20, 20, 15, 0.04), 0 8px 24px rgba(20, 20, 15, 0.04);
      --k-mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      background: var(--k-bg);
      color: var(--k-text);
      font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
      font-size: 0.9rem;
      line-height: 1.45;
      padding: 24px 28px 40px;
    }
    .knotra *, .knotra *::before, .knotra *::after { box-sizing: border-box; }
    .knotra h1, .knotra h2, .knotra h3, .knotra p { margin: 0; }
    .knotra code, .knotra pre, .knotra .kid { font-family: var(--k-mono); font-size: 0.78rem; }
    .knotra code { background: var(--k-panel-2); color: var(--k-text); padding: 1px 5px; border-radius: 5px; }
    .knotra pre { background: transparent; color: inherit; padding: 0; border: 0; white-space: pre-wrap; word-break: break-word; margin: 6px 0 0; }
    .k-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap; padding-bottom: 14px; border-bottom: 1px solid var(--k-border); }
    .k-brand { display: flex; align-items: center; gap: 10px; }
    .k-mark {
      display: grid; place-items: center; width: 30px; height: 30px; border-radius: 9px;
      background: var(--k-text); color: #fff; font-weight: 650; font-size: 0.85rem;
    }
    .k-brand h1 { font-size: 1.15rem; font-weight: 650; letter-spacing: -0.01em; }
    .k-brand p { display: flex; gap: 10px; align-items: center; color: var(--k-muted); font-size: 0.78rem; margin-top: 2px; }
    .k-instance { font-family: var(--k-mono); }
    .k-actions { display: flex; align-items: center; gap: 8px; }
    .k-live { display: inline-flex; align-items: center; gap: 6px; color: var(--k-accent); font-size: 0.78rem; font-weight: 600; }
    .k-live-dot { width: 6px; height: 6px; border-radius: 50%; background: currentColor; }
    .k-live.is-paused { color: var(--k-muted); }
    .k-btn, .k-link, .k-icon-btn {
      appearance: none; background: var(--k-text); border: 1px solid var(--k-text); color: #fff;
      border-radius: 8px; padding: 0.5rem 0.9rem; font: inherit; font-size: 0.85rem; cursor: pointer;
    }
    .k-btn:hover { opacity: 0.9; }
    .k-btn.is-ghost { background: transparent; color: var(--k-text); border-color: var(--k-border); }
    .k-btn.is-ghost:hover { border-color: var(--k-text); color: var(--k-text); opacity: 1; }
    .k-link { border: 0; background: transparent; color: var(--k-accent); padding: 2px 4px; font-size: 0.78rem; }
    .k-link:hover { opacity: 0.75; }
    .k-icon-btn { border: 0; background: transparent; color: var(--k-muted); font-size: 1.25rem; line-height: 1; padding: 2px 8px; }
    .k-icon-btn:hover { color: var(--k-text); opacity: 1; }
    .k-error-inline { color: var(--k-red); }
    .k-tabs { display: flex; gap: 4px; margin: 16px 0 14px; border-bottom: 1px solid var(--k-border); overflow-x: auto; }
    .k-tab {
      appearance: none; background: transparent; border: 0; border-bottom: 2px solid transparent;
      color: var(--k-muted); font: inherit; font-weight: 600; font-size: 0.85rem; padding: 9px 12px;
      cursor: pointer; white-space: nowrap;
    }
    .k-tab:hover { color: var(--k-text); }
    .k-tab.is-active { color: var(--k-accent); border-bottom-color: var(--k-accent); }
    .k-count { display: inline-block; margin-left: 5px; padding: 0 6px; border-radius: 999px; background: var(--k-panel-2); font-size: 0.7rem; }
    .k-body { display: grid; grid-template-columns: minmax(0, 1fr); gap: 14px; }
    .k-body:has(.k-detail) { grid-template-columns: minmax(0, 1fr) minmax(330px, 420px); }
    @media (max-width: 980px) { .k-body:has(.k-detail) { grid-template-columns: minmax(0, 1fr); } }
    .k-main { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
    .k-panel { background: var(--k-panel); border: 1px solid var(--k-border); border-radius: 14px; padding: 16px; min-width: 0; box-shadow: var(--k-shadow); }
    .k-panel-head { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin-bottom: 10px; }
    .k-panel-head h2 { font-size: 0.95rem; letter-spacing: -0.01em; }
    .k-muted { color: var(--k-muted); font-size: 0.78rem; }
    .k-empty { color: var(--k-muted); font-size: 0.85rem; padding: 14px 4px; }
    .k-metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 10px; }
    .k-metric { background: var(--k-panel); border: 1px solid var(--k-border); border-radius: 14px; padding: 12px 14px; box-shadow: var(--k-shadow); }
    .k-metric span { display: block; color: var(--k-muted); font-size: 0.68rem; text-transform: uppercase; letter-spacing: 0.08em; }
    .k-metric strong { display: block; font-size: 1.5rem; letter-spacing: -0.02em; margin-top: 2px; }
    .k-metric.is-running strong { color: var(--k-green); }
    .k-metric.is-waiting strong { color: var(--k-amber); }
    .k-metric.is-completed strong { color: var(--k-accent); }
    .k-metric.is-failed strong { color: var(--k-red); }
    .k-grid2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 14px; align-items: start; }
    .k-list { display: flex; flex-direction: column; gap: 6px; }
    .k-row-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
    .k-swarm-agent { display: flex; flex-direction: column; gap: 4px; padding: 9px; background: var(--k-panel-2); border-radius: 10px; }
    .k-swarm-agent details { font-size: 0.75rem; }
    .k-swarm-agent pre { max-height: 160px; overflow: auto; }
    .k-timeline { display: flex; flex-direction: column; gap: 6px; }
    .k-row-card {
      display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; gap: 12px;
      width: 100%; text-align: left; background: var(--k-panel-2); border: 1px solid transparent;
      border-radius: 10px; padding: 9px 11px; color: inherit; font: inherit; cursor: pointer;
    }
    .k-row-card:hover { border-color: var(--k-accent); }
    .k-row-card.is-selected { border-color: var(--k-accent); background: var(--k-accent-soft); }
    .k-row-main { display: flex; flex-direction: column; min-width: 0; }
    .k-row-main strong { font-size: 0.85rem; }
    .k-row-main span { color: var(--k-muted); font-size: 0.78rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .k-row-side { display: flex; flex-direction: column; align-items: flex-end; gap: 1px; color: var(--k-muted); font-size: 0.7rem; }
    .k-row-side code { color: var(--k-text); }
    .k-badge { display: inline-flex; align-items: center; gap: 4px; padding: 2px 7px; border-radius: 999px; font-size: 0.68rem; font-weight: 600; letter-spacing: 0.05em; text-transform: uppercase; background: var(--k-panel-2); }
    .k-badge-dot { width: 5px; height: 5px; border-radius: 50%; background: currentColor; }
    .k-badge.is-running { color: var(--k-amber); background: var(--k-amber-soft); }
    .k-badge.is-waiting { color: var(--k-amber); background: var(--k-amber-soft); }
    .k-badge.is-completed { color: var(--k-accent); background: var(--k-accent-soft); }
    .k-badge.is-failed { color: var(--k-red); background: var(--k-red-soft); }
    .k-filter { display: flex; gap: 10px; align-items: flex-end; flex-wrap: wrap; margin-bottom: 12px; }
    .k-filter label { display: flex; flex-direction: column; gap: 4px; font-size: 0.7rem; color: var(--k-muted); }
    .k-filter .k-grow { flex: 1; min-width: 180px; }
    .k-filter select, .k-filter input {
      appearance: none; border: 1px solid var(--k-border); background: var(--k-panel); color: var(--k-text);
      border-radius: 8px; padding: 0.5rem 0.6rem; font: inherit; font-size: 0.82rem; width: 100%;
    }
    .k-filter input:focus, .k-filter select:focus { outline: 2px solid var(--k-accent-soft); border-color: var(--k-accent); }
    .k-table-wrap { overflow-x: auto; }
    .k-table { width: 100%; border-collapse: collapse; font-size: 0.78rem; }
    .k-table th { text-align: left; color: var(--k-muted); font-weight: 600; font-size: 0.68rem; text-transform: uppercase; letter-spacing: 0.05em; padding: 6px 8px; border-bottom: 1px solid var(--k-border); }
    .k-table td { padding: 8px; border-bottom: 1px solid var(--k-border); vertical-align: middle; }
    .k-row { cursor: pointer; }
    .k-row:hover td { background: var(--k-panel-2); }
    .k-row.is-selected td { background: var(--k-accent-soft); }
    .k-agent-cell { font-weight: 600; }
    .k-preview { max-width: 260px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--k-muted); }
    .k-arrow-cell { color: var(--k-muted); }
    .k-agents { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 12px; }
    .k-agent-card { border: 1px solid var(--k-border); border-radius: 14px; padding: 14px; background: var(--k-panel); min-width: 0; box-shadow: var(--k-shadow); }
    .k-agent-card > header { display: flex; justify-content: space-between; gap: 10px; align-items: flex-start; }
    .k-agent-card h3 { font-size: 0.95rem; }
    .k-agent-card header code { color: var(--k-muted); }
    .k-agent-stub { display: flex; flex-direction: column; gap: 2px; padding: 9px 10px; border: 1px solid var(--k-border); border-radius: 10px; background: var(--k-panel-2); }
    .k-agent-stub strong { font-size: 0.85rem; }
    .k-agent-list { display: flex; flex-direction: column; gap: 6px; }
    .k-facts { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 6px; margin: 12px 0; }
    .k-facts.is-inline { grid-template-columns: repeat(6, minmax(0, 1fr)); }
    .k-facts div { background: var(--k-panel-2); border: 1px solid var(--k-border); border-radius: 9px; padding: 6px 8px; min-width: 0; }
    .k-facts dt { color: var(--k-muted); font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.06em; }
    .k-facts dd { margin: 1px 0 0; font-weight: 700; font-size: 0.88rem; overflow-wrap: anywhere; }
    .k-facts dd code { font-weight: 400; }
    .k-chips { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 8px; }
    .k-chip { display: inline-block; padding: 2px 7px; border-radius: 999px; border: 1px solid var(--k-border); background: var(--k-panel); color: var(--k-muted); font-size: 0.7rem; }
    .k-chip.is-muted { opacity: 0.7; }
    .k-chip.is-link { cursor: pointer; font-family: var(--k-mono); }
    .k-chip.is-link:hover, .k-chip.is-selected { border-color: var(--k-accent); color: var(--k-accent); }
    .k-flows { display: flex; flex-direction: column; gap: 10px; }
    .k-flow-card { border: 1px solid var(--k-border); border-radius: 14px; background: var(--k-panel); padding: 12px 14px; box-shadow: var(--k-shadow); }
    .k-flow-card > header { display: flex; justify-content: space-between; gap: 10px; margin-bottom: 10px; }
    .k-flow { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; }
    .k-flow-step { display: inline-flex; align-items: center; gap: 6px; }
    .k-flow-step:not(:last-child)::after { content: "→"; color: var(--k-muted); margin-left: 2px; }
    .k-node {
      display: flex; flex-direction: column; align-items: flex-start; gap: 1px; min-width: 120px;
      border: 1px solid var(--k-border); border-left: 3px solid var(--k-border); background: var(--k-panel);
      color: inherit; border-radius: 9px; padding: 6px 9px; font: inherit; cursor: pointer; text-align: left;
    }
    .k-node:hover { border-color: var(--k-accent); }
    .k-node strong { font-size: 0.78rem; }
    .k-node span { font-family: var(--k-mono); font-size: 0.64rem; color: var(--k-muted); }
    .k-node em { font-style: normal; font-size: 0.64rem; color: var(--k-muted); }
    .k-node.running { border-left-color: var(--k-amber); }
    .k-node.waiting { border-left-color: var(--k-amber); }
    .k-node.completed { border-left-color: var(--k-accent); }
    .k-node.failed { border-left-color: var(--k-red); }
    .k-links { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
    .k-links li { display: flex; align-items: center; gap: 6px; }
    .k-feed { display: flex; flex-direction: column; gap: 8px; }
    .k-feed.is-compact .k-msg p { display: -webkit-box; -webkit-line-clamp: 4; -webkit-box-orient: vertical; overflow: hidden; font-size: 0.8rem; }
    .k-msg { border: 1px solid var(--k-border); border-left: 3px solid var(--k-border); border-radius: 10px; padding: 9px 11px; background: var(--k-panel); box-shadow: var(--k-shadow); }
    .k-msg.is-assistant { border-left-color: var(--k-accent); }
    .k-msg.is-tool { border-left-color: var(--k-green); }
    .k-msg.is-input { border-left-color: var(--k-muted); }
    .k-msg.is-human { border-left-color: var(--k-amber); }
    .k-msg.is-error { border-left-color: var(--k-red); }
    .k-msg header { display: flex; gap: 7px; align-items: center; flex-wrap: wrap; font-size: 0.7rem; }
    .k-msg header strong { font-size: 0.8rem; }
    .k-msg p { margin-top: 4px; font-size: 0.85rem; white-space: pre-wrap; overflow-wrap: anywhere; }
    .k-kind { padding: 1px 6px; border-radius: 999px; background: var(--k-panel-2); font-size: 0.62rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; }
    .k-detail {
      background: var(--k-panel); border: 1px solid var(--k-border); border-radius: 14px; padding: 16px;
      position: sticky; top: 14px; max-height: calc(100vh - 28px); overflow: auto; min-width: 0;
      box-shadow: var(--k-shadow);
    }
    .k-detail-head { display: flex; justify-content: space-between; gap: 10px; align-items: flex-start; }
    .k-detail-head h2 { font-size: 1rem; margin-top: 1px; }
    .k-eyebrow { color: var(--k-muted); font-size: 0.62rem; text-transform: uppercase; letter-spacing: 0.1em; }
    .k-detail-meta { display: flex; flex-direction: column; align-items: flex-start; gap: 3px; margin: 10px 0; font-size: 0.78rem; }
    .k-trace { display: flex; flex-direction: column; gap: 3px; margin: 8px 0 12px; }
    .k-trace div { display: flex; gap: 8px; font-size: 0.7rem; }
    .k-trace span { color: var(--k-muted); min-width: 84px; }
    .k-trace code { overflow-wrap: anywhere; }
    .k-callout { border-radius: 10px; border: 1px solid var(--k-border); padding: 9px 11px; margin: 8px 0; background: var(--k-panel-2); }
    .k-callout strong { font-size: 0.78rem; }
    .k-callout p { margin-top: 3px; font-size: 0.78rem; white-space: pre-wrap; overflow-wrap: anywhere; }
    .k-callout.is-warn { border-color: var(--k-amber); background: var(--k-amber-soft); }
    .k-callout.is-ok { border-color: var(--k-accent); background: var(--k-accent-soft); }
    .k-callout.is-error { border-color: var(--k-red); background: var(--k-red-soft); }
    .k-section-title { display: flex; justify-content: space-between; gap: 8px; font-size: 0.68rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--k-muted); margin: 14px 0 6px; }
    .k-input { background: var(--k-panel-2); border: 1px solid var(--k-border); border-radius: 9px; padding: 8px 10px; font-size: 0.78rem; white-space: pre-wrap; overflow-wrap: anywhere; }
    .k-timeline { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 7px; }
    .k-event { background: var(--k-panel); border: 1px solid var(--k-border); border-left: 3px solid var(--k-border); border-radius: 10px; padding: 7px 10px; box-shadow: 0 1px 2px rgba(20, 20, 15, 0.03); }
    .k-event.is-input { border-left-color: var(--k-muted); }
    .k-event.is-model, .k-event.is-assistant { border-left-color: var(--k-accent); }
    .k-event.is-tool { border-left-color: var(--k-accent); }
    .k-event.is-human { border-left-color: var(--k-amber); }
    .k-event.is-terminal.is-completed { border-left-color: var(--k-accent); }
    .k-event.is-terminal.is-failed, .k-event.is-terminal.is-blocked, .k-event.is-terminal.is-cancelled { border-left-color: var(--k-red); }
    .k-event-head { display: flex; align-items: center; gap: 7px; font-size: 0.7rem; }
    .k-event-head strong { font-size: 0.7rem; }
    .k-seq { display: inline-grid; place-items: center; min-width: 20px; height: 18px; border-radius: 5px; background: var(--k-panel-2); font-family: var(--k-mono); font-size: 0.62rem; color: var(--k-muted); }
    .k-event p, .k-event pre { font-size: 0.78rem; margin-top: 3px; white-space: pre-wrap; overflow-wrap: anywhere; }
    .k-calls { list-style: none; margin: 5px 0 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
    .k-calls li { display: flex; gap: 6px; flex-wrap: wrap; background: var(--k-panel-2); border-radius: 6px; padding: 4px 6px; }
    .k-calls span { font-family: var(--k-mono); font-size: 0.7rem; color: var(--k-muted); }
    .k-usage { font-family: var(--k-mono); }
    """

    @impl true
    def mount(_params, session, socket) do
      instance = Map.get(session, "knotra_instance", Map.get(session, :knotra_instance))

      socket =
        socket
        |> assign(:instance, instance)
        |> assign(:tab, :overview)
        |> assign(:selected_id, nil)
        |> assign(:selected, nil)
        |> assign(:selected_swarm, nil)
        |> assign(:status_filter, "all")
        |> assign(:kind_filter, "all")
        |> assign(:query, "")
        |> assign(:paused, false)
        |> assign(:error, if(instance, do: nil, else: :missing_instance))
        |> assign(:snapshot, empty_snapshot())
        |> assign(:last_updated, nil)
        |> assign(:refresh_pending, false)

      if instance && connected?(socket) do
        Observability.subscribe(instance)
        schedule_tick()
      end

      {:ok, if(instance, do: load(socket), else: socket)}
    end

    @impl true
    def handle_info({:knotra_observability, _instance}, %{assigns: %{paused: true}} = socket) do
      {:noreply, socket}
    end

    def handle_info({:knotra_observability, _instance}, socket) do
      if socket.assigns.refresh_pending do
        {:noreply, socket}
      else
        # Coalesce a burst of store notifications into one snapshot read.
        Process.send_after(self(), :refresh, 250)
        {:noreply, assign(socket, :refresh_pending, true)}
      end
    end

    def handle_info(:refresh, socket) do
      {:noreply, socket |> assign(:refresh_pending, false) |> load()}
    end

    def handle_info(:tick, socket) do
      schedule_tick()

      if socket.assigns.paused or socket.assigns.refresh_pending do
        {:noreply, socket}
      else
        {:noreply, load(socket)}
      end
    end

    def handle_info(_message, socket), do: {:noreply, socket}

    @impl true
    def handle_event("tab", %{"tab" => tab}, socket) do
      case Enum.find(@tabs, fn {key, _label} -> Atom.to_string(key) == tab end) do
        {key, _label} -> {:noreply, assign(socket, :tab, key)}
        nil -> {:noreply, socket}
      end
    end

    def handle_event("filter", params, socket) do
      {:noreply,
       assign(socket,
         status_filter: params["status"] || socket.assigns.status_filter,
         kind_filter: params["kind"] || socket.assigns.kind_filter,
         query: params["query"] || socket.assigns.query
       )}
    end

    def handle_event("select", %{"id" => id}, socket) do
      {:noreply, socket |> assign(:selected_swarm, nil) |> load_selected(id)}
    end

    def handle_event("select_swarm", %{"id" => id}, socket) do
      {:noreply, load_swarm(socket, id)}
    end

    def handle_event("close", _params, socket) do
      {:noreply, assign(socket, selected_id: nil, selected: nil)}
    end

    def handle_event("close_swarm", _params, socket) do
      {:noreply, assign(socket, selected_swarm: nil)}
    end

    def handle_event("toggle_pause", _params, socket) do
      paused = not socket.assigns.paused
      socket = assign(socket, :paused, paused)
      {:noreply, if(paused, do: socket, else: load(socket))}
    end

    def handle_event("refresh", _params, socket) do
      {:noreply, load(socket)}
    end

    defp load(socket) do
      case Observability.snapshot(socket.assigns.instance) do
        {:ok, snapshot} ->
          socket
          |> assign(:snapshot, snapshot)
          |> assign(:error, nil)
          |> assign(:last_updated, System.system_time(:millisecond))
          |> refresh_selected()
          |> refresh_selected_swarm()

        {:error, reason} ->
          assign(socket, :error, reason)
      end
    end

    defp refresh_selected(%{assigns: %{selected_id: nil}} = socket), do: socket

    defp refresh_selected(socket), do: load_selected(socket, socket.assigns.selected_id)

    defp refresh_selected_swarm(%{assigns: %{selected_swarm: nil}} = socket), do: socket

    defp refresh_selected_swarm(socket) do
      load_swarm(socket, socket.assigns.selected_swarm.swarm.id)
    end

    defp load_swarm(socket, id) do
      case Observability.swarm(socket.assigns.instance, id) do
        {:ok, swarm} ->
          assign(socket, selected_swarm: swarm, selected_id: nil, selected: nil)

        {:error, _reason} ->
          assign(socket, selected_swarm: nil, error: :swarm_not_found)
      end
    end

    defp load_selected(socket, id) do
      case Observability.execution(socket.assigns.instance, cast_id(id)) do
        {:ok, execution} ->
          assign(socket, selected_id: execution.id, selected: execution)

        {:error, _reason} ->
          assign(socket, selected_id: nil, selected: nil, error: :execution_not_found)
      end
    end

    defp schedule_tick, do: Process.send_after(self(), :tick, 1_000)

    defp empty_snapshot do
      %{
        stats: %{
          executions: 0,
          running: 0,
          waiting: 0,
          completed: 0,
          failed: 0,
          agents: 0,
          models: [],
          events: 0,
          swarms: 0,
          swarms_running: 0,
          swarms_failed: 0,
          newest_started_at: nil
        },
        agents: [],
        executions: [],
        swarms: [],
        graph: %{conversations: [], edges: [], agent_edges: [], links: []},
        messages: []
      }
    end

    @impl true
    def render(assigns) do
      executions =
        filtered_executions(assigns.snapshot.executions, assigns.status_filter, assigns.query)

      messages = filtered_messages(assigns.snapshot.messages, assigns.kind_filter, assigns.query)

      active =
        Enum.filter(assigns.snapshot.executions, &(&1.status in [:running, :accepted, :waiting]))

      assigns =
        assign(assigns,
          executions: executions,
          messages: messages,
          swarms: assigns.snapshot.swarms,
          active: active,
          tabs: @tabs,
          statuses: @statuses,
          kinds: @kinds,
          css: @css
        )

      ~H"""
      <div class="knotra" id="knotra-dashboard">
        <style><%= @css %></style>

        <header class="k-head">
          <div class="k-brand">
            <span class="k-mark">K</span>
            <div>
              <h1>Knotra Observability</h1>
              <p>
                <span :if={@instance} class="k-instance">{inspect(@instance)}</span>
                <span :if={@error} class="k-error-inline">store {to_string(@error)}</span>
                <span :if={@last_updated} class="k-muted">updated {format_clock(@last_updated)}</span>
              </p>
            </div>
          </div>
          <div class="k-actions">
            <span class={["k-live", @paused && "is-paused"]}>
              <span class="k-live-dot"></span>{if @paused, do: "Paused", else: "Live"}
            </span>
            <button class="k-btn" phx-click="toggle_pause">{if @paused, do: "Resume", else: "Pause"}</button>
            <button class="k-btn is-ghost" phx-click="refresh">Refresh</button>
          </div>
        </header>

        <p :if={@error == :missing_instance} class="k-empty">
          No Knotra instance configured. Mount the dashboard with
          <code>knotra_dashboard "/knotra", instance: MyApp.Agents</code>.
        </p>

        <nav class="k-tabs">
          <button
            :for={{key, label} <- @tabs}
            class={["k-tab", @tab == key && "is-active"]}
            phx-click="tab"
            phx-value-tab={key}
          >
            {label}
            <span :if={key == :executions} class="k-count">{length(@snapshot.executions)}</span>
            <span :if={key == :agents} class="k-count">{length(@snapshot.agents)}</span>
            <span :if={key == :swarms} class="k-count">{length(@snapshot.swarms)}</span>
            <span :if={key == :messages} class="k-count">{length(@snapshot.messages)}</span>
          </button>
        </nav>

        <div class="k-body">
          <main class="k-main">
            <.overview
              :if={@tab == :overview}
              snapshot={@snapshot}
              active={@active}
              selected_id={@selected_id}
            />
            <.executions_tab
              :if={@tab == :executions}
              executions={@executions}
              snapshot={@snapshot}
              statuses={@statuses}
              status_filter={@status_filter}
              query={@query}
              selected_id={@selected_id}
            />
            <.agents_tab :if={@tab == :agents} agents={@snapshot.agents} selected_id={@selected_id} />
            <.swarms_tab
              :if={@tab == :swarms}
              swarms={@swarms}
              selected_swarm_id={@selected_swarm && @selected_swarm.swarm.id}
            />
            <.topology_tab :if={@tab == :topology} graph={@snapshot.graph} selected_id={@selected_id} />
            <.messages_tab
              :if={@tab == :messages}
              messages={@messages}
              snapshot={@snapshot}
              kinds={@kinds}
              kind_filter={@kind_filter}
              query={@query}
            />
          </main>

          <aside :if={@selected_swarm} class="k-detail">
            <.swarm_detail detail={@selected_swarm} />
          </aside>

          <aside :if={@selected} class="k-detail">
            <.detail selected={@selected} />
          </aside>
        </div>
      </div>
      """
    end

    attr(:snapshot, :map, required: true)
    attr(:active, :list, required: true)
    attr(:selected_id, :any, required: true)

    defp overview(assigns) do
      ~H"""
      <section class="k-metrics">
        <.metric label="Executions" value={@snapshot.stats.executions} />
        <.metric label="Running" value={@snapshot.stats.running} tone="running" />
        <.metric label="Waiting" value={@snapshot.stats.waiting} tone="waiting" />
        <.metric label="Completed" value={@snapshot.stats.completed} tone="completed" />
        <.metric label="Failed" value={@snapshot.stats.failed} tone="failed" />
        <.metric label="Agents" value={@snapshot.stats.agents} />
      </section>

      <section class="k-panel">
        <header class="k-panel-head">
          <h2>Active executions</h2>
          <span class="k-muted">{length(@active)} running or waiting</span>
        </header>

        <p :if={@active == []} class="k-empty">
          Nothing is running. Start an execution with <code>Knotra.start/5</code> or
          <code>Knotra.submit/6</code> and it appears here immediately.
        </p>

        <div :if={@active != []} class="k-list">
          <.execution_row :for={execution <- @active} execution={execution} selected_id={@selected_id} />
        </div>
      </section>

      <div class="k-grid2">
        <section class="k-panel">
          <header class="k-panel-head">
            <h2>Agents</h2>
            <button class="k-link" phx-click="tab" phx-value-tab="agents">View all</button>
          </header>
          <p :if={@snapshot.agents == []} class="k-empty">No agent definition has run yet.</p>
          <div class="k-agent-list">
            <.agent_stub :for={agent <- Enum.take(@snapshot.agents, 4)} agent={agent} />
          </div>
        </section>

        <section class="k-panel">
          <header class="k-panel-head">
            <h2>Recent messages</h2>
            <button class="k-link" phx-click="tab" phx-value-tab="messages">View all</button>
          </header>
          <p :if={@snapshot.messages == []} class="k-empty">No messages yet.</p>
          <div class="k-feed is-compact">
            <.message_card :for={message <- Enum.take(@snapshot.messages, 6)} message={message} />
          </div>
        </section>
      </div>

      <section class="k-panel">
        <header class="k-panel-head">
          <h2>Latest executions</h2>
          <span class="k-muted">{@snapshot.stats.events} recorded events</span>
        </header>
        <p :if={@snapshot.executions == []} class="k-empty">No executions recorded.</p>
        <div :if={@snapshot.executions != []} class="k-list">
          <.execution_row
            :for={execution <- Enum.take(@snapshot.executions, 10)}
            execution={execution}
            selected_id={@selected_id}
          />
        </div>
      </section>
      """
    end

    attr(:executions, :list, required: true)
    attr(:snapshot, :map, required: true)
    attr(:statuses, :list, required: true)
    attr(:status_filter, :string, required: true)
    attr(:query, :string, required: true)
    attr(:selected_id, :any, required: true)

    defp executions_tab(assigns) do
      ~H"""
      <section class="k-panel">
        <header class="k-panel-head">
          <h2>Executions</h2>
          <span class="k-muted">{length(@executions)} shown of {length(@snapshot.executions)} retained</span>
        </header>

        <form id="knotra-executions-filter" class="k-filter" phx-change="filter" phx-submit="filter">
          <label>
            <span>Status</span>
            <select name="status">
              <option :for={{value, label} <- @statuses} value={value} selected={@status_filter == value}>
                {label}
              </option>
            </select>
          </label>
          <label class="k-grow">
            <span>Search</span>
            <input type="search" name="query" value={@query} placeholder="agent, model, id, or input" />
          </label>
        </form>

        <p :if={@executions == []} class="k-empty">No executions match this filter.</p>

        <div :if={@executions != []} class="k-table-wrap">
          <table class="k-table">
            <thead>
              <tr>
                <th>Status</th>
                <th>Agent</th>
                <th>Model</th>
                <th>Execution</th>
                <th>Started</th>
                <th>Duration</th>
                <th>Last turn</th>
                <th>Turns / tools</th>
                <th>Input</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={execution <- @executions}
                class={["k-row", @selected_id == execution.id && "is-selected"]}
                phx-click="select"
                phx-value-id={execution.id}
              >
                <td><.status_badge status={execution.status} /></td>
                <td class="k-agent-cell">{agent_label(execution)}</td>
                <td><code>{model_label(execution)}</code></td>
                <td><code class="kid">{short_id(execution.id)}</code></td>
                <td>{format_clock(execution.started_at)}</td>
                <td>{format_duration(execution.duration_ms)}</td>
                <td>{format_duration(execution.timings.last_turn_ms)}</td>
                <td>{execution.counts.turns} / {execution.counts.tools}</td>
                <td class="k-preview">{truncate(format_text(execution.input), 64)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
      """
    end

    attr(:agents, :list, required: true)
    attr(:selected_id, :any, required: true)

    defp agents_tab(assigns) do
      ~H"""
      <section class="k-panel">
        <header class="k-panel-head">
          <h2>Agent definitions</h2>
          <span class="k-muted">Aggregated by definition version</span>
        </header>

        <p :if={@agents == []} class="k-empty">No agent definition has run yet.</p>

        <div class="k-agents">
          <.agent_card :for={agent <- @agents} agent={agent} selected_id={@selected_id} />
        </div>
      </section>
      """
    end

    attr(:graph, :map, required: true)
    attr(:selected_id, :any, required: true)

    defp topology_tab(assigns) do
      ~H"""
      <section class="k-panel">
        <header class="k-panel-head">
          <h2>Conversations</h2>
          <span class="k-muted">Executions grouped by correlation id, oldest first</span>
        </header>

        <p :if={@graph.conversations == []} class="k-empty">No executions recorded.</p>

        <div class="k-flows">
          <article :for={conversation <- @graph.conversations} class="k-flow-card">
            <header>
              <code>{to_string(conversation.id)}</code>
              <span class="k-muted">{length(conversation.executions)} execution(s)</span>
            </header>
            <div class="k-flow">
              <span :for={execution <- conversation.executions} class="k-flow-step">
                <button
                  class={["k-node", status_key(execution.status)]}
                  phx-click="select"
                  phx-value-id={execution.id}
                >
                  <strong>{execution.agent}</strong>
                  <span>{short_id(execution.id)}</span>
                  <em>{status_text(execution.status)}</em>
                </button>
              </span>
            </div>
          </article>
        </div>
      </section>

      <div class="k-grid2">
        <section class="k-panel">
          <header class="k-panel-head">
            <h2>Agent connections</h2>
            <span class="k-muted">Observed parent and conversation handoffs</span>
          </header>

          <p :if={@graph.agent_edges == []} class="k-empty">
            No agent-to-agent handoff recorded yet. Correlate executions with
            <code>trace: [conversation_id: ...]</code> or <code>parent_id: ...</code>.
          </p>

          <table :if={@graph.agent_edges != []} class="k-table">
            <thead>
              <tr><th>From</th><th></th><th>To</th><th>Count</th><th>Kind</th></tr>
            </thead>
            <tbody>
              <tr :for={edge <- @graph.agent_edges}>
                <td class="k-agent-cell">{edge.from}</td>
                <td class="k-arrow-cell">→</td>
                <td class="k-agent-cell">{edge.to}</td>
                <td>{edge.count}</td>
                <td>{edge.kinds |> Enum.map(&to_string/1) |> Enum.join(", ")}</td>
              </tr>
            </tbody>
          </table>
        </section>

        <section class="k-panel">
          <header class="k-panel-head">
            <h2>Explicit links</h2>
            <span class="k-muted">Parent ids and host-declared edges</span>
          </header>

          <p :if={@graph.links == []} class="k-empty">
            No parent or explicit links. Use <code>Knotra.Observability.link/4</code> to add one.
          </p>

          <ul :if={@graph.links != []} class="k-links">
            <li :for={link <- @graph.links}>
              <button class="k-link" phx-click="select" phx-value-id={link.from}>
                {short_id(link.from)}
              </button>
              <span class="k-muted">{link.label}</span>
              <button class="k-link" phx-click="select" phx-value-id={link.to}>
                {short_id(link.to)}
              </button>
            </li>
          </ul>
        </section>
      </div>
      """
    end

    attr(:messages, :list, required: true)
    attr(:snapshot, :map, required: true)
    attr(:kinds, :list, required: true)
    attr(:kind_filter, :string, required: true)
    attr(:query, :string, required: true)

    defp messages_tab(assigns) do
      ~H"""
      <section class="k-panel">
        <header class="k-panel-head">
          <h2>Message stream</h2>
          <span class="k-muted">{length(@messages)} newest of {length(@snapshot.messages)} retained</span>
        </header>

        <form id="knotra-messages-filter" class="k-filter" phx-change="filter" phx-submit="filter">
          <label>
            <span>Kind</span>
            <select name="kind">
              <option :for={{value, label} <- @kinds} value={value} selected={@kind_filter == value}>
                {label}
              </option>
            </select>
          </label>
          <label class="k-grow">
            <span>Search</span>
            <input type="search" name="query" value={@query} placeholder="message text, agent, execution" />
          </label>
        </form>

        <p :if={@messages == []} class="k-empty">No messages match this filter.</p>
        <div :if={@messages != []} class="k-feed">
          <.message_card :for={message <- @messages} message={message} />
        </div>
      </section>
      """
    end

    attr(:swarms, :list, required: true)
    attr(:selected_swarm_id, :any, required: true)

    defp swarms_tab(assigns) do
      ~H"""
      <section class="k-panel">
        <header class="k-panel-head">
          <h2>Swarms</h2>
          <span class="k-muted">{length(@swarms)} retained</span>
        </header>

        <p :if={@swarms == []} class="k-empty">
          No swarm recorded. Start one with <code>Knotra.Swarm.run/3</code>.
        </p>

        <div :if={@swarms != []} class="k-table-wrap">
          <table class="k-table">
            <thead>
              <tr>
                <th>Status</th>
                <th>Mode</th>
                <th>Goal</th>
                <th>Agents</th>
                <th>Created</th>
                <th>Tasks</th>
                <th>Escalations</th>
                <th>Started</th>
                <th>Duration</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={swarm <- @swarms}
                class={["k-row", @selected_swarm_id == swarm.id && "is-selected"]}
                phx-click="select_swarm"
                phx-value-id={swarm.id}
              >
                <td><.status_badge status={swarm.status} /></td>
                <td>{swarm.mode}</td>
                <td class="k-preview">{truncate(swarm.goal, 56)}</td>
                <td>{swarm.agents}</td>
                <td>{Enum.join(swarm.created_agents, ", ")}</td>
                <td>{swarm.tasks}</td>
                <td>{swarm.escalations}</td>
                <td>{format_clock(swarm.started_at)}</td>
                <td>{format_duration(swarm.elapsed_ms)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
      """
    end

    attr(:detail, :map, required: true)

    defp swarm_detail(assigns) do
      ~H"""
      <div class="k-detail-head">
        <div>
          <span class="k-eyebrow">Swarm · coordinator</span>
          <h2><code>{short_id(@detail.swarm.id)}</code></h2>
        </div>
        <button class="k-icon-btn" phx-click="close_swarm" title="Close detail">×</button>
      </div>

      <div class="k-detail-meta">
        <.status_badge status={@detail.swarm.status} />
        <span>{to_string(@detail.swarm.mode)} · {format_duration(@detail.swarm.elapsed_ms)}</span>
        <span>started {format_clock(@detail.swarm.started_at)}</span>
      </div>

      <h3 class="k-section-title">Goal</h3>
      <p class="k-input">{@detail.swarm.goal}</p>

      <h3 class="k-section-title">Coordinator output</h3>
      <p :if={@detail.swarm.planner == nil} class="k-muted">No planner trace recorded.</p>
      <div :if={@detail.swarm.planner != nil} class="k-callout is-ok">
        <strong>{@detail.swarm.planner[:model] || "coordinator"}</strong>
        <pre>{@detail.swarm.planner[:output] || "(no output)"}</pre>
        <p :if={@detail.swarm.planner[:fallback]} class="k-muted">
          Fallback: {inspect(@detail.swarm.planner[:fallback])}
        </p>
        <details>
          <summary>Planner input</summary>
          <pre>{@detail.swarm.planner[:input]}</pre>
        </details>
      </div>

      <h3 class="k-section-title">Agents</h3>
      <div class="k-list">
        <article :for={agent <- @detail.swarm.agents} class="k-swarm-agent">
          <div class="k-row-head">
            <strong>{agent.name}</strong>
            <span class="k-muted">
              {if agent.created, do: "created", else: "existing"} · {Enum.join(agent.tools, ", ")}
            </span>
          </div>
          <details :if={agent.prompt}>
            <summary>Initial prompt</summary>
            <pre>{agent.prompt}</pre>
          </details>
          <code>{agent.version}</code>
        </article>
      </div>

      <h3 class="k-section-title">Tasks</h3>
      <p :if={@detail.swarm.tasks == []} class="k-muted">No tasks recorded.</p>
      <div :if={@detail.swarm.tasks != []} class="k-table-wrap">
        <table class="k-table">
          <thead>
            <tr><th>Task</th><th>Agent</th><th>Iteration</th><th>Status</th><th>Duration</th></tr>
          </thead>
          <tbody>
            <tr :for={task <- @detail.swarm.tasks}>
              <td><code>{task.id}</code></td>
              <td>{task.agent}</td>
              <td>{task.iteration}</td>
              <td>{to_string(task.status)}</td>
              <td>{format_duration(task.elapsed_ms)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h3 :if={@detail.swarm.escalations != []} class="k-section-title">Escalations</h3>
      <div :if={@detail.swarm.escalations != []} class="k-list">
        <article :for={escalation <- @detail.swarm.escalations} class="k-swarm-agent">
          <div class="k-row-head">
            <strong>{escalation.tool}</strong>
            <span class="k-muted">{escalation.agent} · {inspect(escalation.reason)}</span>
          </div>
          <code>{inspect(escalation.arguments)}</code>
        </article>
      </div>

      <h3 class="k-section-title">
        Timeline
        <span class="k-muted">coordinator + member executions in event order</span>
      </h3>
      <div class="k-timeline">
        <div :for={event <- @detail.timeline} class={["k-event", "is-" <> to_string(event.type)]}>
          <div class="k-event-head">
            <span class="k-seq">{event.offset_ms} ms</span>
            <strong>{to_string(event.type)}</strong>
            <span class="k-muted">{event.source}</span>
          </div>
          <p>{swarm_event_text(event)}</p>
        </div>
      </div>
      """
    end

    defp swarm_event_text(%{source: "coordinator"} = event) do
      data = event.data || %{}

      case event.type do
        :started ->
          "mode #{data[:mode]} · goal: #{data[:goal]}"

        :planned ->
          "planned #{length(Map.get(data, :agents, []))} agents and " <>
            "#{length(Map.get(data, :tasks, []))} tasks"

        :task_started ->
          "task #{data[:id]} → #{data[:agent]} (iteration #{data[:iteration]})"

        :task_finished ->
          "task #{data[:id]} by #{data[:agent]}: #{data[:status]}" <>
            if(data[:error], do: " (#{inspect(data[:error])})", else: "")

        :escalation ->
          "#{data[:tool]} by #{data[:agent]}: #{inspect(data[:reason])} · #{inspect(data[:arguments])}"

        :finished ->
          "swarm #{data[:status]} in #{data[:elapsed_ms]} ms"

        _other ->
          inspect(data)
      end
    end

    defp swarm_event_text(event) do
      data = event.data || %{}

      case event.type do
        :model_started -> "model call started"
        :model_result -> Map.get(data, :text, "")
        :tool_result -> Map.get(data, :output, "")
        :tool_started -> "calling #{get_in(data, [:call, :name])}"
        :started -> Map.get(data, :input, "")
        :completed -> Map.get(data, :output) || "completed"
        :failed -> "failed: #{inspect(Map.get(data, :error))}"
        :blocked -> "blocked: #{inspect(Map.get(data, :error))}"
        :waiting -> Map.get(data, :prompt, "waiting")
        :retry -> "retry: #{inspect(Map.get(data, :reason))}"
        _other -> truncate(inspect(data), 600)
      end
    end

    attr(:selected, :map, required: true)

    defp detail(assigns) do
      ~H"""
      <div class="k-detail-head">
        <div>
          <span class="k-eyebrow">Execution</span>
          <h2><code>{short_id(@selected.id)}</code></h2>
        </div>
        <button class="k-icon-btn" phx-click="close" title="Close detail">×</button>
      </div>

      <div class="k-detail-meta">
        <.status_badge status={@selected.status} />
        <span><strong>{agent_label(@selected)}</strong> · {model_label(@selected)}</span>
        <span>{format_duration(@selected.duration_ms)} total · started {format_clock(@selected.started_at)}</span>
        <span>
          {@selected.timings.turn_count} turn(s) · last {format_duration(@selected.timings.last_turn_ms)} ·
          avg {format_duration(@selected.timings.avg_turn_ms)}
        </span>
      </div>

      <dl class="k-facts">
        <div><dt>Version</dt><dd><code>{@selected.definition.version}</code></dd></div>
        <div><dt>Run total</dt><dd>{format_duration(@selected.timings.total_ms)}</dd></div>
        <div><dt>Last turn</dt><dd>{format_duration(@selected.timings.last_turn_ms)}</dd></div>
        <div><dt>Model time</dt><dd>{format_duration(@selected.timings.model_ms)}</dd></div>
        <div><dt>Tool time</dt><dd>{format_duration(@selected.timings.tool_ms)}</dd></div>
        <div><dt>Retries</dt><dd>{@selected.counts.retries}</dd></div>
        <div><dt>Steps</dt><dd>{@selected.counts.steps}</dd></div>
        <div><dt>Events</dt><dd>{@selected.event_count}</dd></div>
        <div><dt>Tools</dt><dd>{@selected.counts.tools}</dd></div>
      </dl>

      <h3 class="k-section-title">
        Turn timings
        <span class="k-muted">
          {if @selected.truncated?, do: "partial timeline · ", else: ""}wall time per model turn
        </span>
      </h3>

      <p :if={@selected.timings.turn_count == 0} class="k-muted">
        No model turns recorded.
      </p>

      <div :if={@selected.timings.turn_count > 0} class="k-table-wrap">
        <table class="k-table k-turn-table">
          <thead>
            <tr>
              <th>Turn</th>
              <th>Total</th>
              <th>Model</th>
              <th>Tools</th>
              <th>Other</th>
              <th>Calls</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={turn <- @selected.timings.turns}>
              <td>{turn.number}</td>
              <td>{format_duration(turn.duration_ms)}</td>
              <td>{format_duration(turn.model_ms)}</td>
              <td>{format_duration(turn.tool_ms)}</td>
              <td>{format_duration(turn.other_ms)}</td>
              <td>{turn.tools}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="k-trace">
        <div :if={@selected.trace.conversation_id}>
          <span>Conversation</span><code>{to_string(@selected.trace.conversation_id)}</code>
        </div>
        <div :if={@selected.trace.parent_id}>
          <span>Parent</span><code>{to_string(@selected.trace.parent_id)}</code>
        </div>
        <div :for={{key, value} <- @selected.trace.labels}>
          <span>{key}</span><code>{to_string(value)}</code>
        </div>
      </div>

      <div :if={@selected.approval} class="k-callout is-warn">
        <strong>
          Approval · {to_string(field(@selected.approval, :disposition) || :pending)}
        </strong>
        <p><code>{to_string(field(@selected.approval, :name) || "operation")}</code></p>
        <pre>{inspect(field(@selected.approval, :arguments), pretty: true, limit: 20)}</pre>
      </div>

      <div :if={@selected.input_request} class="k-callout is-warn">
        <strong>
          Clarification · {to_string(field(@selected.input_request, :disposition) || :pending)}
        </strong>
        <p>{field(@selected.input_request, :prompt)}</p>
      </div>

      <div :if={@selected.output} class="k-callout is-ok">
        <strong>Output</strong>
        <p>{@selected.output}</p>
      </div>

      <div :if={@selected.error} class="k-callout is-error">
        <strong>Error</strong>
        <p>{format_text(@selected.error)}</p>
      </div>

      <div :if={@selected.observation_error} class="k-callout is-error">
        <strong>Observer</strong>
        <p>{to_string(@selected.observation_error)}</p>
      </div>

      <h3 class="k-section-title">Input</h3>
      <p class="k-input">{@selected.input}</p>

      <h3 class="k-section-title">
        Timeline
        <span :if={@selected.event_count > length(@selected.events)} class="k-muted">
          showing newest {length(@selected.events)} of {@selected.event_count}
        </span>
      </h3>

      <ol class="k-timeline">
        <.event_card :for={event <- @selected.events} event={event} />
      </ol>
      """
    end

    attr(:label, :string, required: true)
    attr(:value, :any, required: true)
    attr(:tone, :string, default: "default")

    defp metric(assigns) do
      ~H"""
      <div class={["k-metric", "is-" <> @tone]}>
        <span>{@label}</span>
        <strong>{@value}</strong>
      </div>
      """
    end

    attr(:status, :atom, required: true)

    defp status_badge(assigns) do
      ~H"""
      <span class={["k-badge", "is-" <> status_key(@status)]}>
        <span class="k-badge-dot"></span>{status_text(@status)}
      </span>
      """
    end

    attr(:execution, :map, required: true)
    attr(:selected_id, :any, required: true)

    defp execution_row(assigns) do
      ~H"""
      <button
        class={["k-row-card", @selected_id == @execution.id && "is-selected"]}
        phx-click="select"
        phx-value-id={@execution.id}
      >
        <.status_badge status={@execution.status} />
        <span class="k-row-main">
          <strong>{agent_label(@execution)}</strong>
          <span>{truncate(format_text(@execution.input), 110)}</span>
        </span>
        <span class="k-row-side">
          <code>{model_label(@execution)}</code>
          <span>{format_duration(@execution.duration_ms)} · {short_id(@execution.id)}</span>
          <span>
            {@execution.timings.turn_count} turns · last {format_duration(@execution.timings.last_turn_ms)}
          </span>
        </span>
      </button>
      """
    end

    attr(:agent, :map, required: true)

    defp agent_stub(assigns) do
      ~H"""
      <div class="k-agent-stub">
        <strong>{@agent.label}</strong>
        <span><code>{model_display(@agent.model)}</code></span>
        <span class="k-muted">
          {@agent.executions} run(s) · {@agent.running} running
        </span>
      </div>
      """
    end

    attr(:agent, :map, required: true)
    attr(:selected_id, :any, required: true)

    defp agent_card(assigns) do
      ~H"""
      <article class="k-agent-card">
        <header>
          <div>
            <h3>{@agent.label}</h3>
            <code class="k-muted">{@agent.id}</code>
          </div>
          <code>{model_display(@agent.model)}</code>
        </header>

        <dl class="k-facts is-inline">
          <div><dt>Runs</dt><dd>{@agent.executions}</dd></div>
          <div><dt>Running</dt><dd>{@agent.running}</dd></div>
          <div><dt>Waiting</dt><dd>{@agent.waiting}</dd></div>
          <div><dt>Completed</dt><dd>{@agent.completed}</dd></div>
          <div><dt>Failed</dt><dd>{@agent.failed}</dd></div>
          <div><dt>Events</dt><dd>{@agent.events}</dd></div>
        </dl>

        <div class="k-chips">
          <span class="k-chip">loop {module_label(@agent.loop)}</span>
          <span class="k-chip">runtime {module_label(@agent.tool_runtime)}</span>
          <span class="k-chip">observer {module_label(@agent.observer)}</span>
        </div>

        <div class="k-chips">
          <span :if={@agent.tools == []} class="k-chip is-muted">no tools</span>
          <span :for={tool <- @agent.tools} class="k-chip">{tool}</span>
        </div>

        <div class="k-chips">
          <button
            :for={id <- Enum.take(@agent.execution_ids, 8)}
            class={["k-chip", "is-link", @selected_id == id && "is-selected"]}
            phx-click="select"
            phx-value-id={id}
          >
            {short_id(id)}
          </button>
        </div>
      </article>
      """
    end

    attr(:message, :map, required: true)

    defp message_card(assigns) do
      ~H"""
      <article class={["k-msg", "is-" <> to_string(@message.kind)]}>
        <header>
          <span class={["k-kind", "is-" <> to_string(@message.kind)]}>{@message.kind}</span>
          <strong>{@message.agent}</strong>
          <span class="k-muted">{@message.model}</span>
          <button class="k-link" phx-click="select" phx-value-id={@message.execution_id}>
            {short_id(@message.execution_id)}
          </button>
          <span class="k-muted">{format_clock(@message.at)}</span>
        </header>
        <p>{truncate(format_text(@message.text), 600)}</p>
        <p :if={@message.tool} class="k-muted"><code>{@message.tool}</code></p>
      </article>
      """
    end

    attr(:event, :map, required: true)

    defp event_card(%{event: %{type: :started}} = assigns) do
      assigns = assign(assigns, :text, format_text(data(assigns.event, :input)))

      ~H"""
      <li class="k-event is-input">
        <.event_head event={@event} label="input" />
        <p>{@text}</p>
      </li>
      """
    end

    defp event_card(%{event: %{type: :model_started}} = assigns) do
      ~H"""
      <li class="k-event is-model">
        <.event_head event={@event} label="model request" />
        <p class="k-muted">Waiting for the model reply.</p>
      </li>
      """
    end

    defp event_card(%{event: %{type: :model_result}} = assigns) do
      assigns =
        assign(assigns,
          text: format_text(data(assigns.event, :text)),
          calls: data(assigns.event, :calls) || [],
          usage: data(assigns.event, :usage)
        )

      ~H"""
      <li class="k-event is-assistant">
        <.event_head event={@event} label="assistant" />
        <p :if={@text != ""}>{@text}</p>
        <ul :if={@calls != []} class="k-calls">
          <li :for={call <- @calls}>
            <code>{call_name(call)}</code>
            <span>{format_args(call)}</span>
          </li>
        </ul>
        <p :if={@usage} class="k-muted k-usage">usage {format_usage(@usage)}</p>
      </li>
      """
    end

    defp event_card(%{event: %{type: :tool_started}} = assigns) do
      call = data(assigns.event, :call)
      assigns = assign(assigns, call_name: call_name(call), args: format_args(call))

      ~H"""
      <li class="k-event is-tool">
        <.event_head event={@event} label="tool call" />
        <p><code>{@call_name}</code></p>
        <pre>{@args}</pre>
      </li>
      """
    end

    defp event_card(%{event: %{type: :tool_result}} = assigns) do
      assigns =
        assign(
          assigns,
          call_name: call_name(data(assigns.event, :call)),
          output: format_text(data(assigns.event, :output))
        )

      ~H"""
      <li class="k-event is-tool">
        <.event_head event={@event} label="tool result" />
        <p><code>{@call_name}</code></p>
        <pre>{@output}</pre>
      </li>
      """
    end

    defp event_card(%{event: %{type: type}} = assigns)
         when type in [:completed, :failed, :cancelled, :blocked, :rejected, :expired, :waiting] do
      assigns =
        assign(
          assigns,
          :body,
          format_text(
            data(assigns.event, :output) || data(assigns.event, :error) ||
              data(assigns.event, :reason)
          )
        )

      ~H"""
      <li class={["k-event", "is-terminal", "is-" <> to_string(@event.type)]}>
        <.event_head event={@event} label={to_string(@event.type)} />
        <p :if={@body != ""}>{@body}</p>
      </li>
      """
    end

    defp event_card(%{event: %{type: type}} = assigns)
         when type in [:approval_answered, :input_answered] do
      assigns =
        assign(
          assigns,
          :body,
          format_text(data(assigns.event, :answer) || data(assigns.event, :decision))
        )

      ~H"""
      <li class="k-event is-human">
        <.event_head event={@event} label={to_string(@event.type)} />
        <p>{@body}</p>
      </li>
      """
    end

    defp event_card(assigns) do
      assigns = assign(assigns, :body, inspect(assigns.event.data, pretty: true, limit: 20))

      ~H"""
      <li class="k-event">
        <.event_head event={@event} label={to_string(@event.type)} />
        <pre>{@body}</pre>
      </li>
      """
    end

    attr(:event, :map, required: true)
    attr(:label, :string, required: true)

    defp event_head(assigns) do
      ~H"""
      <header class="k-event-head">
        <span class="k-seq">{@event.sequence}</span>
        <strong>{@label}</strong>
        <span class="k-muted">at {@event.elapsed_ms} ms</span>
      </header>
      """
    end

    defp filtered_executions(executions, status_filter, query) do
      executions
      |> Enum.filter(&status_match?(&1.status, status_filter))
      |> Enum.filter(fn execution ->
        search?(
          [
            execution.id,
            agent_label(execution),
            model_label(execution),
            execution.input,
            execution.definition.version
          ],
          query
        )
      end)
    end

    defp filtered_messages(messages, kind_filter, query) do
      messages
      |> Enum.filter(fn message ->
        kind_filter == "all" or to_string(message.kind) == kind_filter
      end)
      |> Enum.filter(fn message ->
        search?([message.text, message.agent, message.execution_id, message.tool], query)
      end)
    end

    defp status_match?(_status, "all"), do: true
    defp status_match?(status, "running"), do: status in [:running, :accepted]
    defp status_match?(status, "waiting"), do: status == :waiting
    defp status_match?(status, "completed"), do: status == :completed

    defp status_match?(status, "failed"),
      do: status in [:failed, :blocked, :cancelled, :rejected, :expired]

    defp status_match?(_status, _filter), do: true

    defp search?(_values, query) when query in [nil, ""], do: true

    defp search?(values, query) do
      query = query |> to_string() |> String.trim() |> String.downcase()
      query == "" or Enum.any?(values, &contains?(&1, query))
    end

    defp contains?(nil, _query), do: false

    defp contains?(value, query) do
      value |> to_string() |> String.downcase() |> String.contains?(query)
    end

    defp cast_id(id) when is_integer(id), do: id

    defp cast_id(id) when is_binary(id) do
      case Integer.parse(id) do
        {integer, ""} -> integer
        _ -> id
      end
    end

    defp data(event, key), do: field(event.data || %{}, key)

    defp field(%{} = map, key) do
      Map.get(map, key) || Map.get(map, Atom.to_string(key))
    end

    defp field(_value, _key), do: nil

    defp call_name(call), do: field(call, :name) || "tool"
    defp format_args(call), do: inspect(field(call, :arguments) || %{}, pretty: true, limit: 20)

    defp format_usage(usage) when is_map(usage) do
      keys = [:input_tokens, :output_tokens, :total_tokens, :input, :output, :total]

      parts =
        for key <- keys,
            value = field(usage, key),
            not is_nil(value) do
          "#{key}=#{value}"
        end

      if parts == [], do: inspect(usage, limit: 8), else: Enum.join(parts, " ")
    end

    defp format_usage(usage), do: inspect(usage)

    defp agent_label(%{trace: %{agent: agent}}) when is_binary(agent), do: agent
    defp agent_label(%{definition: %{version: version}}), do: version
    defp agent_label(_execution), do: "agent"

    defp model_label(%{definition: %{model: model}}), do: model_display(model)
    defp model_label(%{model: model}), do: model_display(model)
    defp model_label(_execution), do: "model"

    defp model_display(%{id: id}) when is_binary(id) and id != "", do: id
    defp model_display(%{module: module}) when is_binary(module), do: module_label(module)
    defp model_display(_model), do: "model"

    defp module_label(nil), do: "—"

    defp module_label(module) when is_binary(module),
      do: module |> String.split(".") |> List.last()

    defp module_label(module), do: module |> inspect() |> module_label()

    defp status_key(status) when status in [:running, :accepted], do: "running"

    defp status_key(status)
         when status in [:failed, :blocked, :cancelled, :rejected, :expired, :timeout],
         do: "failed"

    defp status_key(:partial), do: "waiting"

    defp status_key(status), do: to_string(status)

    defp status_text(status), do: status |> to_string() |> String.replace("_", " ")

    defp short_id(id), do: id |> to_string() |> String.slice(0, 12)

    defp format_clock(nil), do: "—"

    defp format_clock(milliseconds) when is_integer(milliseconds) do
      milliseconds
      |> DateTime.from_unix!(:millisecond)
      |> Calendar.strftime("%H:%M:%S")
    rescue
      _ -> "—"
    end

    defp format_clock(_value), do: "—"

    defp format_duration(nil), do: "—"

    defp format_duration(milliseconds) when is_integer(milliseconds) and milliseconds < 1_000,
      do: "#{milliseconds} ms"

    defp format_duration(milliseconds) when is_number(milliseconds) do
      "#{Float.round(milliseconds / 1_000, 1)} s"
    end

    defp format_duration(_value), do: "—"

    defp format_text(nil), do: ""
    defp format_text(value) when is_binary(value), do: value
    defp format_text(value), do: inspect(value)

    defp truncate(nil, _limit), do: ""
    defp truncate(text, limit) when is_binary(text), do: String.slice(text, 0, limit)
    defp truncate(text, limit), do: text |> format_text() |> truncate(limit)
  end
end
