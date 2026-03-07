defmodule NameBadge.Screen.NameBadge do
  use NameBadge.Screen

  require Logger

  @font_name "New Amsterdam"
  @greeting_size_default 24
  @name_size_default 36
  @company_size_default 24

  @impl NameBadge.Screen
  def render(%{valid?: false}) do
    """
    #show heading: set text(font: "Silkscreen", size: 36pt, weight: 400, tracking: -4pt)

    = Error

    Your name badge is not configured. Please connect to WiFi, then personalize
    your device via QR code.
    """
  end

  def render(%{config: config, show_qr?: true, qr_code: qr_code}) do
    Logger.info("name badge config is: #{inspect(config)}")

    greeting_element =
      case config["greeting"] do
        greeting when greeting == "" or is_nil(greeting) ->
          ""

        greeting when is_binary(greeting) ->
          "text(font: \"#{@font_name}\", size: #{config["greeting_size"] || @greeting_size_default}pt)[#{greeting}],"
      end

    company_element =
      case config["company"] do
        company when company == "" or is_nil(company) ->
          ""

        company when is_binary(company) ->
          "text(font: \"#{@font_name}\", size: #{config["company_size"] || @company_size_default}pt)[#{company}],"
      end

    qr_element =
      case qr_code do
        qr when is_binary(qr) and qr != "" ->
          "#image(width: 45%, format: \"svg\", bytes(\"#{qr}\"))"

        _ ->
          "text(font: \"#{@font_name}\", size: 16pt)[No QR link configured]"
      end

    """
    #place(center + horizon,
      stack(dir: ttb, spacing: #{config["spacing"] || 8}pt,
        #{qr_element},
        #{greeting_element}
        text(font: "#{@font_name}", size: #{config["name_size"] || @name_size_default}pt, "#{config["first_name"]} #{config["last_name"]}"),
        #{company_element}
      )
    );
    """
  end

  def render(%{config: config}) do
    Logger.info("name badge config is: #{inspect(config)}")

    greeting_element =
      case config["greeting"] do
        greeting when greeting == "" or is_nil(greeting) ->
          ""

        greeting when is_binary(greeting) ->
          "text(font: \"#{@font_name}\", size: #{config["greeting_size"] || @greeting_size_default}pt)[#{greeting}],"
      end

    company_element =
      case config["company"] do
        company when company == "" or is_nil(company) ->
          ""

        company when is_binary(company) ->
          "text(font: \"#{@font_name}\", size: #{config["company_size"] || @company_size_default}pt)[#{company}],"
      end

    """
    #place(center + horizon,
      stack(dir: ttb, spacing: #{config["spacing"] || 8}pt,

        #{greeting_element}
        text(font: "#{@font_name}", size: #{config["name_size"] || @name_size_default}pt, "#{config["first_name"]} #{config["last_name"]}"),
        #{company_element}
      )
    );
    """
  end

  @impl NameBadge.Screen
  def mount(_args, screen) do
    config = NameBadge.Config.load_config()

    case config do
      %{"first_name" => _first_name, "last_name" => _last_name} ->
        qr_link = Map.get(config, "qr_link")

        qr_code =
          if is_binary(qr_link) and qr_link != "" do
            qr_code_for_url(String.trim(qr_link))
          else
            nil
          end

        {:ok,
         assign(screen,
           config: config,
           qr_code: qr_code,
           show_qr?: false,
           valid?: true,
           button_hints: %{a: "Toggle QR"}
         )}

      _config ->
        {:ok, assign(screen, valid?: false, button_hints: %{a: "Set up WiFi", b: "View QR code"})}
    end
  end

  @impl NameBadge.Screen
  def handle_button(:button_1, :single_press, screen) do
    cond do
      screen.assigns.valid? ->
        {:noreply, assign(screen, show_qr?: !Map.get(screen.assigns, :show_qr?, false))}

      true ->
        {:noreply, navigate(screen, NameBadge.Screen.Settings.WiFi)}
    end
  end

  def handle_button(:button_2, :single_press, screen) do
    cond do
      screen.assigns.valid? ->
        {:noreply, screen}

      true ->
        {:noreply, navigate(screen, NameBadge.Screen.Settings.QrCode)}
    end
  end

  def handle_button(_, _, screen), do: {:noreply, screen}

  defp qr_code_for_url(url) do
    with {:ok, code} <- QRCode.create(url),
         {:ok, qr_code_svg} <- QRCode.render(code) do
      qr_code_svg
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
    else
      _ -> nil
    end
  end
end
