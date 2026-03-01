defmodule NameBadge.Telemetry.MemoryMonitor do
  @moduledoc """
  A GenServer that monitors system memory, specifically tracking
  NIF-related memory usage (binaries, process heaps, etc.).

  This module is designed to help identify memory leaks in NIFs
  such as Dither and Typst by providing:

  - Periodic memory snapshots
  - Delta tracking between snapshots
  - Binary reference counting
  - Per-process memory tracking for processes using NIFs

  ## Usage

      # Start monitoring (interval in milliseconds, default 10_000)
      NameBadge.Telemetry.MemoryMonitor.start_link(interval: 5_000)

      # Get current memory state
      NameBadge.Telemetry.MemoryMonitor.snapshot()

      # Get memory delta since monitoring started
      NameBadge.Telemetry.MemoryMonitor.delta()

      # Force garbage collection and get memory after
      NameBadge.Telemetry.MemoryMonitor.gc_and_snapshot()

      # Get history of snapshots
      NameBadge.Telemetry.MemoryMonitor.history()

      # Reset baseline
      NameBadge.Telemetry.MemoryMonitor.reset_baseline()
  """

  use GenServer

  require Logger

  @default_interval 10_000
  @max_history 100

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current memory snapshot.
  """
  @spec snapshot() :: map()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc """
  Returns the memory delta since the baseline was established.
  """
  @spec delta() :: map()
  def delta do
    GenServer.call(__MODULE__, :delta)
  end

  @doc """
  Forces garbage collection on all processes and returns the memory snapshot after.
  """
  @spec gc_and_snapshot() :: map()
  def gc_and_snapshot do
    GenServer.call(__MODULE__, :gc_and_snapshot, 30_000)
  end

  @doc """
  Returns the history of memory snapshots.
  """
  @spec history() :: [map()]
  def history do
    GenServer.call(__MODULE__, :history)
  end

  @doc """
  Resets the baseline to the current memory state.
  """
  @spec reset_baseline() :: :ok
  def reset_baseline do
    GenServer.cast(__MODULE__, :reset_baseline)
  end

  @doc """
  Tracks memory for a specific operation.
  Returns `{result, memory_delta}` where `memory_delta` is the change in memory.
  """
  @spec track((() -> result)) :: {result, map()} when result: any()
  def track(fun) when is_function(fun, 0) do
    before = take_snapshot()
    :erlang.garbage_collect()
    before_gc = take_snapshot()

    result = fun.()

    after_op = take_snapshot()
    :erlang.garbage_collect()
    after_gc = take_snapshot()

    delta = %{
      before_gc: compute_delta(before, before_gc),
      operation: compute_delta(before_gc, after_op),
      after_gc: compute_delta(after_op, after_gc),
      total: compute_delta(before, after_gc)
    }

    {result, delta}
  end

  @doc """
  Monitors memory during repeated execution of a function.
  Useful for detecting leaks that appear over many iterations.
  """
  @spec stress_test(pos_integer(), (() -> any()), keyword()) :: map()
  def stress_test(iterations, fun, opts \\ []) when is_function(fun, 0) do
    gc_every = Keyword.get(opts, :gc_every, 100)
    report_every = Keyword.get(opts, :report_every, iterations)

    _initial = take_snapshot()
    :erlang.garbage_collect()
    initial_gc = take_snapshot()

    samples =
      Enum.reduce(1..iterations, [], fn i, samples ->
        fun.()

        if rem(i, gc_every) == 0 do
          :erlang.garbage_collect()
        end

        if rem(i, report_every) == 0 do
          current = take_snapshot()
          delta = compute_delta(initial_gc, current)

          Logger.info(
            "[MemoryMonitor] Iteration #{i}/#{iterations} - " <>
              "RSS: #{format_bytes(current.rss)} (+#{format_bytes(delta.rss)}), " <>
              "BEAM: #{format_bytes(current.total)} (+#{format_bytes(delta.total)}), " <>
              "NIF est: #{format_bytes(current.nif_estimate)} (+#{format_bytes(delta.nif_estimate)})"
          )

          [{i, current, delta} | samples]
        else
          samples
        end
      end)

    :erlang.garbage_collect()
    final = take_snapshot()
    final_delta = compute_delta(initial_gc, final)

    %{
      iterations: iterations,
      initial: initial_gc,
      final: final,
      delta: final_delta,
      samples: Enum.reverse(samples),
      leak_detected: detect_leak(samples, final_delta)
    }
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    enabled = Keyword.get(opts, :enabled, true)
    # Delay before setting baseline (allows app to fully initialize)
    warmup_delay = Keyword.get(opts, :warmup_delay, 60_000)

    baseline = take_snapshot()

    state = %{
      baseline: baseline,
      interval: interval,
      enabled: enabled,
      history: [{System.monotonic_time(:millisecond), baseline}],
      timer_ref: nil,
      warmed_up: false
    }

    # Schedule baseline reset after warmup period
    if warmup_delay > 0 do
      Process.send_after(self(), :warmup_complete, warmup_delay)
    end

    state =
      if enabled do
        schedule_tick(state)
      else
        state
      end

    Logger.info("[MemoryMonitor] Started with interval #{interval}ms (warmup: #{div(warmup_delay, 1000)}s)")
    Logger.info("[MemoryMonitor] Initial - RSS: #{format_bytes(baseline.rss)}, BEAM: #{format_bytes(baseline.total)}, NIF est: #{format_bytes(baseline.nif_estimate)}")

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, take_snapshot(), state}
  end

  @impl GenServer
  def handle_call(:delta, _from, state) do
    current = take_snapshot()
    delta = compute_delta(state.baseline, current)
    {:reply, delta, state}
  end

  @impl GenServer
  def handle_call(:gc_and_snapshot, _from, state) do
    # Collect garbage on all processes
    for pid <- Process.list() do
      try do
        :erlang.garbage_collect(pid)
      catch
        _, _ -> :ok
      end
    end

    Process.sleep(100)
    snapshot = take_snapshot()
    {:reply, snapshot, state}
  end

  @impl GenServer
  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  @impl GenServer
  def handle_cast(:reset_baseline, state) do
    baseline = take_snapshot()
    Logger.info("[MemoryMonitor] Baseline reset - RSS: #{format_bytes(baseline.rss)}, BEAM: #{format_bytes(baseline.total)}")
    {:noreply, %{state | baseline: baseline, history: [{System.monotonic_time(:millisecond), baseline}]}}
  end

  @impl GenServer
  def handle_info(:warmup_complete, state) do
    baseline = take_snapshot()
    Logger.info("[MemoryMonitor] Warmup complete - Baseline set: RSS: #{format_bytes(baseline.rss)}, BEAM: #{format_bytes(baseline.total)}")
    {:noreply, %{state | baseline: baseline, warmed_up: true, history: [{System.monotonic_time(:millisecond), baseline}]}}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    current = take_snapshot()
    delta = compute_delta(state.baseline, current)

    # Only warn about memory growth after warmup period (to avoid false positives during startup)
    # Check RSS growth as primary indicator (catches NIF leaks)
    cond do
      state.warmed_up and delta.rss > 20 * 1024 * 1024 ->
        Logger.warning(
          "[MemoryMonitor] RSS growth detected (possible NIF leak) - " <>
            "RSS: +#{format_bytes(delta.rss)}, " <>
            "BEAM: +#{format_bytes(delta.total)}, " <>
            "NIF est: +#{format_bytes(delta.nif_estimate)}"
        )

      state.warmed_up and delta.total > 10 * 1024 * 1024 ->
        Logger.warning(
          "[MemoryMonitor] BEAM memory growth detected - " <>
            "Total: +#{format_bytes(delta.total)}, " <>
            "Binary: +#{format_bytes(delta.binary)}, " <>
            "Processes: +#{format_bytes(delta.processes)}"
        )

      true ->
        :ok
    end

    timestamp = System.monotonic_time(:millisecond)
    history = [{timestamp, current} | state.history] |> Enum.take(@max_history)

    state = %{state | history: history}
    state = schedule_tick(state)

    {:noreply, state}
  end

  # Private functions

  defp take_snapshot do
    memory = :erlang.memory()
    {rss, vsz} = get_process_memory()

    %{
      total: memory[:total],
      processes: memory[:processes],
      processes_used: memory[:processes_used],
      system: memory[:system],
      atom: memory[:atom],
      atom_used: memory[:atom_used],
      binary: memory[:binary],
      code: memory[:code],
      ets: memory[:ets],
      # RSS = actual physical memory used (includes NIF allocations)
      rss: rss,
      # VSZ = virtual memory size
      vsz: vsz,
      # NIF memory estimate = RSS - BEAM total (rough approximation)
      nif_estimate: max(0, rss - memory[:total]),
      timestamp: System.monotonic_time(:millisecond)
    }
  end

  # Get RSS and VSZ from /proc/self/statm (Linux) or ps command
  defp get_process_memory do
    case File.read("/proc/self/statm") do
      {:ok, content} ->
        # statm format: size resident shared text lib data dt (all in pages)
        # We want resident (RSS) and size (VSZ)
        parts = String.split(content)
        page_size = get_page_size()

        vsz = parse_int(Enum.at(parts, 0), 0) * page_size
        rss = parse_int(Enum.at(parts, 1), 0) * page_size

        {rss, vsz}

      {:error, _} ->
        # Fallback: try ps command (works on macOS and other Unix)
        get_process_memory_via_ps()
    end
  end

  defp get_process_memory_via_ps do
    try do
      pid = :os.getpid() |> List.to_string()
      # ps output: RSS VSZ in KB
      result = :os.cmd(~c"ps -o rss=,vsz= -p #{pid}") |> List.to_string() |> String.trim()

      case String.split(result) do
        [rss_kb, vsz_kb] ->
          rss = parse_int(rss_kb, 0) * 1024
          vsz = parse_int(vsz_kb, 0) * 1024
          {rss, vsz}

        _ ->
          {0, 0}
      end
    rescue
      _ -> {0, 0}
    end
  end

  defp get_page_size do
    # Try to get page size from system, default to 4096
    try do
      case :os.cmd(~c"getconf PAGE_SIZE") |> List.to_string() |> String.trim() |> Integer.parse() do
        {size, _} -> size
        :error -> 4096
      end
    rescue
      _ -> 4096
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) do
    case Integer.parse(String.trim(str)) do
      {n, _} -> n
      :error -> default
    end
  end

  defp compute_delta(before, after_snapshot) do
    %{
      total: after_snapshot.total - before.total,
      processes: after_snapshot.processes - before.processes,
      processes_used: after_snapshot.processes_used - before.processes_used,
      system: after_snapshot.system - before.system,
      atom: after_snapshot.atom - before.atom,
      atom_used: after_snapshot.atom_used - before.atom_used,
      binary: after_snapshot.binary - before.binary,
      code: after_snapshot.code - before.code,
      ets: after_snapshot.ets - before.ets,
      rss: after_snapshot.rss - before.rss,
      vsz: after_snapshot.vsz - before.vsz,
      nif_estimate: after_snapshot.nif_estimate - before.nif_estimate
    }
  end

  defp detect_leak(samples, final_delta) do
    cond do
      # RSS growth is the most reliable indicator of NIF leaks
      # since it captures memory allocated outside the BEAM
      final_delta.rss > 50 * 1024 * 1024 ->
        {:likely, :rss_memory, final_delta.rss}

      # NIF estimate shows significant growth (RSS growing faster than BEAM)
      final_delta.nif_estimate > 30 * 1024 * 1024 ->
        {:likely, :nif_memory, final_delta.nif_estimate}

      # If final delta shows significant growth that wasn't recovered
      final_delta.total > 50 * 1024 * 1024 ->
        {:likely, :beam_memory, final_delta.total}

      final_delta.binary > 20 * 1024 * 1024 ->
        {:likely, :binary_memory, final_delta.binary}

      # Check for monotonic growth in RSS (most important for NIF leaks)
      length(samples) >= 3 and monotonic_rss_growth?(samples) ->
        {:possible, :rss_monotonic_growth, final_delta.rss}

      # Check for monotonic growth in BEAM memory
      length(samples) >= 3 and monotonic_growth?(samples) ->
        {:possible, :beam_monotonic_growth, final_delta.total}

      true ->
        :none
    end
  end

  defp monotonic_growth?(samples) do
    totals = Enum.map(samples, fn {_i, snapshot, _delta} -> snapshot.total end)

    totals
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> b > a end)
  end

  defp monotonic_rss_growth?(samples) do
    rss_values = Enum.map(samples, fn {_i, snapshot, _delta} -> snapshot.rss end)

    rss_values
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> b > a end)
  end

  defp schedule_tick(state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    ref = Process.send_after(self(), :tick, state.interval)
    %{state | timer_ref: ref}
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 2)} KB"
  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024, do: "#{Float.round(bytes / (1024 * 1024), 2)} MB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"
end
