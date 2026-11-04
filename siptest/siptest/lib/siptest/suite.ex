defmodule SipTest.Suite do
  @moduledoc "Runs a list of scenarios one after another (one run at a time) and broadcasts progress events."
  use GenServer
  require Logger

  alias SipTest.{Engine, Events, Params, Scenarios, Script}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Start a run. `ids` are catalog ids; `custom` is optional script text run last as \"custom\"."
  def run(ids, params, custom), do: GenServer.call(__MODULE__, {:run, ids, params, custom})
  def stop, do: GenServer.call(__MODULE__, :stop)
  def running?, do: GenServer.call(__MODULE__, :running?)

  ## ------------------------------------------------------------------

  @impl true
  def init(_), do: {:ok, %{task: nil}}

  @impl true
  def handle_call(:running?, _from, st), do: {:reply, st.task != nil, st}

  def handle_call({:run, _ids, _params, _custom}, _from, %{task: %Task{}} = st),
    do: {:reply, {:error, "A run is already in progress"}, st}

  def handle_call({:run, ids, params, custom}, _from, st) do
    with {:ok, p} <- Params.normalize(params),
         {:ok, list} <- build_list(ids, custom) do
      task = Task.Supervisor.async_nolink(SipTest.RunSup, fn -> execute(list, p) end)

      Events.broadcast(%{
        type: "run_started",
        scenarios: Enum.map(list, fn sc -> %{id: sc.id, title: sc.title} end),
        target: "#{p.host}:#{p.port}"
      })

      {:reply, :ok, %{st | task: task}}
    else
      {:error, msg} -> {:reply, {:error, msg}, st}
    end
  end

  def handle_call(:stop, _from, %{task: nil} = st), do: {:reply, :ok, st}

  def handle_call(:stop, _from, %{task: task} = st) do
    send(task.pid, :stop_run)
    {:reply, :ok, st}
  end

  @impl true
  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = st) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{st | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = st) do
    Logger.error("test run crashed: #{inspect(reason)}")
    Events.broadcast(%{type: "run_done", passed: 0, failed: 0, total: 0, ms: 0, stopped: false, crashed: true})
    {:noreply, %{st | task: nil}}
  end

  def handle_info(_other, st), do: {:noreply, st}

  ## ------------------------------------------------------------------

  defp build_list(ids, custom) do
    ids = if is_list(ids), do: Enum.filter(ids, &is_binary/1), else: []

    catalog =
      Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
        with %{} = sc <- Scenarios.get(id),
             {:ok, sc} <- Scenarios.with_steps(sc) do
          {:cont, {:ok, acc ++ [sc]}}
        else
          nil -> {:halt, {:error, "Unknown scenario #{id}"}}
          {:error, msg} -> {:halt, {:error, msg}}
        end
      end)

    with {:ok, list} <- catalog,
         {:ok, list} <- add_custom(list, custom) do
      if list == [], do: {:error, "Select at least one scenario"}, else: {:ok, list}
    end
  end

  defp add_custom(list, custom) when is_binary(custom) do
    if String.trim(custom) == "" do
      {:ok, list}
    else
      case Script.parse(custom) do
        {:ok, steps} -> {:ok, list ++ [%{id: "custom", title: "Custom script", steps: steps}]}
        {:error, msg} -> {:error, "Custom script: " <> msg}
      end
    end
  end

  defp add_custom(list, _), do: {:ok, list}

  # Runs inside the task process (so :stop_run lands in its mailbox).
  defp execute(list, p) do
    started = System.monotonic_time(:millisecond)

    results =
      Enum.reduce_while(list, [], fn sc, acc ->
        if stop_requested?() do
          {:halt, [%{status: "fail", error: "stopped by user"} | acc]}
        else
          Events.broadcast(%{type: "scenario_started", id: sc.id})
          emit = fn ev -> Events.broadcast(Map.put(ev, :scenario, sc.id)) end

          res =
            try do
              Engine.run(sc.steps, p, emit)
            rescue
              e ->
                Logger.error(Exception.format(:error, e, __STACKTRACE__))
                %{status: "fail", error: "internal error: " <> Exception.message(e), ms: 0}
            end

          Events.broadcast(%{type: "scenario_done", id: sc.id, status: res.status, error: res.error, ms: res.ms})

          if res.error == "stopped by user", do: {:halt, [res | acc]}, else: {:cont, [res | acc]}
        end
      end)

    stopped = Enum.any?(results, fn r -> r.error == "stopped by user" end)
    ran = Enum.reject(results, fn r -> r.error == "stopped by user" end)
    passed = Enum.count(ran, fn r -> r.status == "pass" end)

    Events.broadcast(%{
      type: "run_done",
      passed: passed,
      failed: length(ran) - passed,
      total: length(list),
      ms: System.monotonic_time(:millisecond) - started,
      stopped: stopped
    })

    :ok
  end

  defp stop_requested? do
    receive do
      :stop_run -> true
    after
      0 -> false
    end
  end
end
