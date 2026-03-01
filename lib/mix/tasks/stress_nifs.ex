defmodule Mix.Tasks.NameBadge.StressNifs do
  @moduledoc """
  Stress test NIF libraries (Dither, Typst) to detect memory leaks.

  This task performs repeated operations on the specified NIF library
  and monitors memory growth over time.

  ## Usage

      # Test Typst NIF with default settings (100 iterations)
      mix name_badge.stress_nifs --nif typst

      # Test Dither NIF with 500 iterations
      mix name_badge.stress_nifs --nif dither --iterations 500

      # Test both NIFs
      mix name_badge.stress_nifs --nif all --iterations 200

      # Custom GC frequency and reporting
      mix name_badge.stress_nifs --nif typst --iterations 1000 --gc-every 50 --report-every 100

  ## Options

      --nif          - Which NIF to test: typst, dither, or all (required)
      --iterations   - Number of iterations (default: 100)
      --gc-every     - Run GC every N iterations (default: 50)
      --report-every - Report memory every N iterations (default: 25)
      --verbose      - Show detailed output
      --error-paths  - Also test error handling paths (invalid inputs)
  """

  use Mix.Task

  require Logger

  @shortdoc "Stress test Dither and Typst NIFs to detect memory leaks"

  @switches [
    nif: :string,
    iterations: :integer,
    gc_every: :integer,
    report_every: :integer,
    verbose: :boolean,
    error_paths: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    nif = Keyword.get(opts, :nif) || raise_missing_nif()
    iterations = Keyword.get(opts, :iterations, 100)
    gc_every = Keyword.get(opts, :gc_every, 50)
    report_every = Keyword.get(opts, :report_every, 25)
    verbose = Keyword.get(opts, :verbose, false)
    error_paths = Keyword.get(opts, :error_paths, false)

    # Start the application to load NIFs
    Mix.Task.run("app.start")

    IO.puts("\n=== NIF Memory Leak Stress Test ===")
    IO.puts("NIF: #{nif}")
    IO.puts("Iterations: #{iterations}")
    IO.puts("GC every: #{gc_every} iterations")
    IO.puts("Report every: #{report_every} iterations")
    IO.puts("Error paths: #{error_paths}")
    IO.puts("")

    test_opts = [gc_every: gc_every, report_every: report_every]

    results =
      case nif do
        "typst" -> stress_test_typst(iterations, test_opts, verbose)
        "dither" -> stress_test_dither(iterations, test_opts, verbose)
        "all" -> stress_test_all(iterations, test_opts, verbose)
        other -> raise "Unknown NIF: #{other}. Use 'typst', 'dither', or 'all'."
      end

    print_results(results)

    # Run error path tests if requested
    if error_paths do
      IO.puts("\n")
      error_results =
        case nif do
          "typst" -> stress_test_typst_errors(iterations, test_opts)
          "dither" -> stress_test_dither_errors(iterations, test_opts)
          "all" -> stress_test_all_errors(iterations, test_opts)
          _ -> nil
        end

      if error_results, do: print_error_results(error_results)
    end
  end

  defp raise_missing_nif do
    raise """
    Missing required --nif option.

    Usage:
      mix name_badge.stress_nifs --nif typst
      mix name_badge.stress_nifs --nif dither
      mix name_badge.stress_nifs --nif all
    """
  end

  defp stress_test_typst(iterations, opts, verbose) do
    IO.puts("--- Testing Typst NIF ---")
    IO.puts("Operation: Rendering a simple Typst document to PNG\n")

    typst_opts = typst_options()

    template = """
    #set page(width: 400pt, height: 300pt)
    #set text(size: 24pt)
    #align(center + horizon)[
      = Hello World
      This is iteration #{"#{iterations}"}
    ]
    """

    test_fn = fn ->
      try do
        result = Typst.render_to_png!(template, [], typst_opts)

        if verbose do
          png = List.first(result)
          IO.puts("  Generated PNG: #{byte_size(png)} bytes")
        end

        result
      rescue
        e ->
          IO.puts("  Error: #{inspect(e)}")
          nil
      end
    end

    run_stress_test("Typst", iterations, test_fn, opts)
  end

  defp stress_test_dither(iterations, opts, verbose) do
    IO.puts("--- Testing Dither NIF ---")
    IO.puts("Operation: Decode PNG -> Grayscale -> Dither -> Encode\n")

    # First, generate a test PNG using Typst
    typst_opts = typst_options()

    template = """
    #set page(width: 400pt, height: 300pt)
    #rect(width: 100%, height: 100%, fill: gradient.linear(white, black))
    """

    [test_png] = Typst.render_to_png!(template, [], typst_opts)

    test_fn = fn ->
      try do
        # Full pipeline: decode -> grayscale -> dither -> encode
        # Using the actual Dither API: dither!(img) or dither!(img, opts)
        img = Dither.decode!(test_png)
        gray = Dither.grayscale!(img)
        dithered = Dither.dither!(gray, algorithm: :atkinson)
        result = Dither.encode!(dithered)

        if verbose do
          IO.puts("  Processed image: #{byte_size(result)} bytes")
        end

        result
      rescue
        e ->
          IO.puts("  Error: #{inspect(e)}")
          nil
      end
    end

    run_stress_test("Dither", iterations, test_fn, opts)
  end

  defp stress_test_all(iterations, opts, verbose) do
    IO.puts("--- Testing All NIFs ---\n")

    typst_result = stress_test_typst(iterations, opts, verbose)
    IO.puts("")
    dither_result = stress_test_dither(iterations, opts, verbose)

    %{
      typst: typst_result,
      dither: dither_result,
      combined_leak:
        combine_leak_status(typst_result.leak_detected, dither_result.leak_detected)
    }
  end

  # Error path stress tests - these test NIF error handling for memory leaks

  defp stress_test_typst_errors(iterations, opts) do
    IO.puts("=== Testing Typst NIF Error Paths ===")
    IO.puts("Operation: Triggering various Typst errors\n")

    typst_opts = typst_options()

    # Invalid Typst templates that should trigger errors
    error_cases = [
      # Syntax error
      {"syntax_error", "#set page(width: 400pt\n#missing closing paren"},
      # Undefined variable
      {"undefined_var", "#set page(width: 400pt, height: 300pt)\n#undefined_variable"},
      # Invalid function call
      {"invalid_func", "#set page(width: 400pt, height: 300pt)\n#nonexistent_function()"},
      # Type error
      {"type_error", "#set page(width: \"not a length\", height: 300pt)\nHello"}
    ]

    test_fn = fn ->
      Enum.each(error_cases, fn {_name, template} ->
        try do
          Typst.render_to_png!(template, [], typst_opts)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)
    end

    run_stress_test("Typst Errors", iterations, test_fn, opts)
  end

  defp stress_test_dither_errors(iterations, opts) do
    IO.puts("=== Testing Dither NIF Error Paths ===")
    IO.puts("Operation: Triggering various Dither errors\n")

    # Invalid inputs that should trigger errors
    error_cases = [
      # Invalid PNG data (random bytes)
      {"invalid_png", <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9>>},
      # Truncated PNG header
      {"truncated_header", <<137, 80, 78, 71, 13, 10, 26>>},
      # Empty data
      {"empty", <<>>},
      # PNG header but garbage body
      {"bad_body", <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0, 255, 255, 255>>}
    ]

    test_fn = fn ->
      Enum.each(error_cases, fn {_name, data} ->
        try do
          Dither.decode!(data)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)
    end

    run_stress_test("Dither Errors", iterations, test_fn, opts)
  end

  defp stress_test_all_errors(iterations, opts) do
    IO.puts("--- Testing All NIF Error Paths ---\n")

    typst_result = stress_test_typst_errors(iterations, opts)
    IO.puts("")
    dither_result = stress_test_dither_errors(iterations, opts)

    %{
      typst_errors: typst_result,
      dither_errors: dither_result,
      combined_leak:
        combine_leak_status(typst_result.leak_detected, dither_result.leak_detected)
    }
  end

  defp run_stress_test(name, iterations, test_fn, opts) do
    alias NameBadge.Telemetry.MemoryMonitor

    IO.puts("Starting #{name} stress test...")

    # Ensure MemoryMonitor is started
    case GenServer.whereis(MemoryMonitor) do
      nil ->
        {:ok, _} = MemoryMonitor.start_link(enabled: false)

      _pid ->
        :ok
    end

    result = MemoryMonitor.stress_test(iterations, test_fn, opts)

    IO.puts("\n#{name} stress test complete.")
    result
  end

  defp print_results(%{typst: typst, dither: dither, combined_leak: combined}) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("COMBINED RESULTS")
    IO.puts(String.duplicate("=", 60))

    IO.puts("\n--- Typst ---")
    print_single_result(typst)

    IO.puts("\n--- Dither ---")
    print_single_result(dither)

    IO.puts("\n--- Overall Assessment ---")
    print_leak_status(combined)
  end

  defp print_results(result) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("RESULTS")
    IO.puts(String.duplicate("=", 60))
    print_single_result(result)
  end

  defp print_error_results(%{typst_errors: typst, dither_errors: dither, combined_leak: combined}) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("ERROR PATH RESULTS")
    IO.puts(String.duplicate("=", 60))

    IO.puts("\n--- Typst Error Paths ---")
    print_single_result(typst)

    IO.puts("\n--- Dither Error Paths ---")
    print_single_result(dither)

    IO.puts("\n--- Overall Error Path Assessment ---")
    print_leak_status(combined)
  end

  defp print_error_results(result) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("ERROR PATH RESULTS")
    IO.puts(String.duplicate("=", 60))
    print_single_result(result)
  end

  defp print_single_result(result) do
    IO.puts("Iterations: #{result.iterations}")
    IO.puts("")
    IO.puts("RSS (actual physical memory - includes NIF allocations):")
    IO.puts("  Initial: #{format_bytes(result.initial.rss)}")
    IO.puts("  Final:   #{format_bytes(result.final.rss)}")
    IO.puts("  Delta:   #{format_delta(result.delta.rss)}")
    IO.puts("")
    IO.puts("BEAM memory (erlang:memory/0 - does NOT include NIF allocations):")
    IO.puts("  Initial: #{format_bytes(result.initial.total)}")
    IO.puts("  Final:   #{format_bytes(result.final.total)}")
    IO.puts("  Delta:   #{format_delta(result.delta.total)}")
    IO.puts("")
    IO.puts("NIF estimate (RSS - BEAM):")
    IO.puts("  Initial: #{format_bytes(result.initial.nif_estimate)}")
    IO.puts("  Final:   #{format_bytes(result.final.nif_estimate)}")
    IO.puts("  Delta:   #{format_delta(result.delta.nif_estimate)}")
    IO.puts("")
    IO.puts("BEAM Breakdown:")
    IO.puts("  Processes: #{format_delta(result.delta.processes)}")
    IO.puts("  Binary:    #{format_delta(result.delta.binary)}")
    IO.puts("  ETS:       #{format_delta(result.delta.ets)}")
    IO.puts("  System:    #{format_delta(result.delta.system)}")
    IO.puts("")
    print_leak_status(result.leak_detected)
  end

  defp print_leak_status(:none) do
    IO.puts("Leak status: NONE DETECTED")
  end

  defp print_leak_status({:likely, type, amount}) do
    IO.puts("Leak status: LIKELY LEAK DETECTED")
    IO.puts("  Type: #{type}")
    IO.puts("  Amount: #{format_bytes(amount)}")
  end

  defp print_leak_status({:possible, type, amount}) do
    IO.puts("Leak status: POSSIBLE LEAK (needs investigation)")
    IO.puts("  Type: #{type}")
    IO.puts("  Amount: #{format_bytes(amount)}")
  end

  defp combine_leak_status(:none, :none), do: :none

  defp combine_leak_status({:likely, _, _} = leak, _), do: leak
  defp combine_leak_status(_, {:likely, _, _} = leak), do: leak
  defp combine_leak_status({:possible, _, _} = leak, _), do: leak
  defp combine_leak_status(_, {:possible, _, _} = leak), do: leak

  defp typst_options do
    priv_dir = :code.priv_dir(:name_badge) |> to_string()
    typst_dir = Path.join(priv_dir, "typst")
    fonts_dir = Path.join(typst_dir, "fonts")

    [root_dir: typst_dir, extra_fonts: [fonts_dir]]
  end

  defp format_bytes(bytes) when bytes < 0, do: "-#{format_bytes(-bytes)}"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 2)} KB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 2)} MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"

  defp format_delta(bytes) when bytes >= 0, do: "+#{format_bytes(bytes)}"
  defp format_delta(bytes), do: format_bytes(bytes)
end
