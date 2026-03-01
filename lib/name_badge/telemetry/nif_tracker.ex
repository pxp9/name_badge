defmodule NameBadge.Telemetry.NifTracker do
  @moduledoc """
  Wraps NIF calls with memory tracking to identify which specific
  operations are causing memory growth.

  ## Usage

  Instead of calling NIFs directly, use the tracked versions:

      # Instead of:
      Typst.render_to_png!(template, [], opts)

      # Use:
      NifTracker.track_typst(:render_to_png, fn ->
        Typst.render_to_png!(template, [], opts)
      end)

  Or wrap an entire pipeline:

      NifTracker.track_dither(:full_pipeline, fn ->
        png
        |> Dither.decode!()
        |> Dither.grayscale!()
        |> Dither.to_raw!()
      end)

  ## Retrieving Stats

      NifTracker.stats()
      # => %{
      #   typst: %{render_to_png: %{calls: 10, total_delta: 1024000, avg_delta: 102400}},
      #   dither: %{decode: %{calls: 5, total_delta: 512000, avg_delta: 102400}}
      # }

      NifTracker.reset()
  """

  use GenServer

  require Logger

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track a Typst NIF operation.
  """
  @spec track_typst(atom(), (() -> result)) :: result when result: any()
  def track_typst(operation, fun) do
    track(:typst, operation, fun)
  end

  @doc """
  Track a Dither NIF operation.
  """
  @spec track_dither(atom(), (() -> result)) :: result when result: any()
  def track_dither(operation, fun) do
    track(:dither, operation, fun)
  end

  @doc """
  Track any NIF operation with a custom category.
  """
  @spec track(atom(), atom(), (() -> result)) :: result when result: any()
  def track(nif, operation, fun) do
    before_memory = :erlang.memory(:total)
    before_binary = :erlang.memory(:binary)
    before_time = System.monotonic_time(:microsecond)

    result = fun.()

    after_time = System.monotonic_time(:microsecond)
    after_memory = :erlang.memory(:total)
    after_binary = :erlang.memory(:binary)

    measurement = %{
      memory_delta: after_memory - before_memory,
      binary_delta: after_binary - before_binary,
      duration_us: after_time - before_time,
      timestamp: System.monotonic_time(:millisecond)
    }

    GenServer.cast(__MODULE__, {:record, nif, operation, measurement})

    result
  end

  @doc """
  Get statistics for all tracked NIF operations.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Get detailed history of a specific NIF operation.
  """
  @spec history(atom(), atom()) :: [map()]
  def history(nif, operation) do
    GenServer.call(__MODULE__, {:history, nif, operation})
  end

  @doc """
  Reset all tracking data.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  @doc """
  Print a formatted report of NIF memory usage.
  """
  @spec report() :: :ok
  def report do
    stats = stats()

    IO.puts("\n=== NIF Memory Usage Report ===\n")

    for {nif, operations} <- stats do
      IO.puts("#{String.upcase(to_string(nif))}:")

      for {operation, data} <- operations do
        IO.puts("  #{operation}:")
        IO.puts("    Calls: #{data.calls}")
        IO.puts("    Total memory delta: #{format_bytes(data.total_memory_delta)}")
        IO.puts("    Avg memory delta: #{format_bytes(data.avg_memory_delta)}")
        IO.puts("    Total binary delta: #{format_bytes(data.total_binary_delta)}")
        IO.puts("    Avg duration: #{Float.round(data.avg_duration_us / 1000, 2)}ms")

        if data.max_memory_delta > 0 do
          IO.puts("    Max memory spike: #{format_bytes(data.max_memory_delta)}")
        end
      end

      IO.puts("")
    end

    :ok
  end

  # GenServer callbacks

  @impl GenServer
  def init(_opts) do
    {:ok, %{data: %{}, history: %{}}}
  end

  @impl GenServer
  def handle_cast({:record, nif, operation, measurement}, state) do
    key = {nif, operation}

    # Update aggregated data
    data =
      Map.update(state.data, key, init_data(measurement), fn existing ->
        update_data(existing, measurement)
      end)

    # Keep last 100 measurements in history
    history =
      Map.update(state.history, key, [measurement], fn existing ->
        [measurement | existing] |> Enum.take(100)
      end)

    {:noreply, %{state | data: data, history: history}}
  end

  @impl GenServer
  def handle_cast(:reset, _state) do
    Logger.info("[NifTracker] Stats reset")
    {:noreply, %{data: %{}, history: %{}}}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    stats =
      state.data
      |> Enum.group_by(fn {{nif, _op}, _data} -> nif end, fn {{_nif, op}, data} -> {op, data} end)
      |> Enum.map(fn {nif, ops} -> {nif, Map.new(ops)} end)
      |> Map.new()

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_call({:history, nif, operation}, _from, state) do
    history = Map.get(state.history, {nif, operation}, [])
    {:reply, history, state}
  end

  # Private functions

  defp init_data(measurement) do
    %{
      calls: 1,
      total_memory_delta: measurement.memory_delta,
      total_binary_delta: measurement.binary_delta,
      total_duration_us: measurement.duration_us,
      max_memory_delta: measurement.memory_delta,
      min_memory_delta: measurement.memory_delta,
      avg_memory_delta: measurement.memory_delta,
      avg_duration_us: measurement.duration_us
    }
  end

  defp update_data(existing, measurement) do
    calls = existing.calls + 1
    total_memory = existing.total_memory_delta + measurement.memory_delta
    total_binary = existing.total_binary_delta + measurement.binary_delta
    total_duration = existing.total_duration_us + measurement.duration_us

    %{
      calls: calls,
      total_memory_delta: total_memory,
      total_binary_delta: total_binary,
      total_duration_us: total_duration,
      max_memory_delta: max(existing.max_memory_delta, measurement.memory_delta),
      min_memory_delta: min(existing.min_memory_delta, measurement.memory_delta),
      avg_memory_delta: div(total_memory, calls),
      avg_duration_us: div(total_duration, calls)
    }
  end

  defp format_bytes(bytes) when bytes < 0, do: "-#{format_bytes(-bytes)}"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 2)} KB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 2)} MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"
end
