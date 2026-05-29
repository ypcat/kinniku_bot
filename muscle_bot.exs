# muscle_bot.exs — Telegram bot for Google Sheets "Muscle" workout tracker
#
# ============================================================================
# SETUP GUIDE — Google Service Account + Telegram Bot
# ============================================================================
#
# 1. CREATE A GOOGLE CLOUD PROJECT
#    - Go to https://console.cloud.google.com/
#    - Create a new project (or use existing one)
#
# 2. ENABLE GOOGLE SHEETS API
#    - Go to APIs & Services > Library
#    - Search for "Google Sheets API" and ENABLE it
#
# 3. CREATE A SERVICE ACCOUNT
#    - Go to APIs & Services > Credentials
#    - Click "Create Credentials" > "Service account"
#    - Name it (e.g. "muscle-bot"), click Create
#    - Skip optional role/access steps, click Done
#
# 4. DOWNLOAD THE SERVICE ACCOUNT KEY
#    - Click on the newly created service account
#    - Go to "Keys" tab > "Add Key" > "Create new key" > JSON
#    - Save the downloaded JSON file as `service_account.json`
#      in the same directory as this script
#
# 5. SHARE THE SPREADSHEET WITH THE SERVICE ACCOUNT
#    - Open your spreadsheet in Google Sheets
#    - Click "Share" > paste the service account email
#      (found in service_account.json as "client_email")
#    - Give it "Editor" permission
#
# 6. CREATE A TELEGRAM BOT
#    - Message @BotFather on Telegram
#    - Send /newbot, follow prompts to get a bot token
#
# 7. SET ENVIRONMENT VARIABLES
#    export TELEGRAM_BOT_TOKEN="your-bot-token"
#    export GOOGLE_SPREADSHEET_ID="11N8XTNDS0me4rKsWncqmmvh89C51u8qfXDm4NO4n1N0"
#    export GOOGLE_SERVICE_ACCOUNT_JSON="./service_account.json"
#
# 8. RUN
#    elixir muscle_bot.exs
#
# ============================================================================

Mix.install([
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"},
  {:jose, "~> 1.11"}
])

defmodule MuscleConfig do
  def telegram_token, do: System.fetch_env!("TELEGRAM_BOT_TOKEN")
  def spreadsheet_id, do: System.get_env("GOOGLE_SPREADSHEET_ID", "11N8XTNDS0me4rKsWncqmmvh89C51u8qfXDm4NO4n1N0")
  def sheet_name, do: System.get_env("GOOGLE_SHEET_NAME", "Log")
  def sa_json_path, do: System.get_env("GOOGLE_SERVICE_ACCOUNT_JSON", "./service_account.json")
end

defmodule UsernameMapping do
  @file_path "username_mappings.json"

  def get_mapped_name(tg_username) do
    tg_name = String.downcase(String.trim(tg_username))
    mappings = read_mappings()
    Map.get(mappings, tg_name, tg_name)
  end

  def save_mapping(tg_username, sheet_name) do
    tg_name = String.downcase(String.trim(tg_username))
    mappings = read_mappings()
    new_mappings = Map.put(mappings, tg_name, sheet_name)
    write_mappings(new_mappings)
  end

  def has_mapping?(tg_username) do
    tg_name = String.downcase(String.trim(tg_username))
    Map.has_key?(read_mappings(), tg_name)
  end

  defp read_mappings do
    if File.exists?(@file_path) do
      case File.read(@file_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp write_mappings(mappings) do
    File.write!(@file_path, Jason.encode!(mappings))
  end
end

# ============================================================================
# Google Auth — JWT-based service account token
# ============================================================================

defmodule GoogleAuth do
  @scope "https://www.googleapis.com/auth/spreadsheets"
  @token_url "https://oauth2.googleapis.com/token"

  def get_access_token do
    case Process.get(:goog_token) do
      {token, expires_at} when is_integer(expires_at) ->
        if System.system_time(:second) < expires_at - 60 do
          token
        else
          fetch_and_cache()
        end

      _ ->
        fetch_and_cache()
    end
  end

  defp fetch_and_cache do
    sa = read_service_account()
    now = System.system_time(:second)

    claims = %{
      "iss" => sa["client_email"],
      "scope" => @scope,
      "aud" => @token_url,
      "iat" => now,
      "exp" => now + 3600
    }

    jwk = JOSE.JWK.from_pem(sa["private_key"])
    {_, jwt} = JOSE.JWS.compact(JOSE.JWT.sign(jwk, %{"alg" => "RS256"}, claims))

    %{status: 200, body: body} =
      Req.post!(@token_url,
        form: [grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt]
      )

    token = body["access_token"]
    expires_at = now + (body["expires_in"] || 3600)
    Process.put(:goog_token, {token, expires_at})
    token
  end

  defp read_service_account do
    MuscleConfig.sa_json_path()
    |> File.read!()
    |> Jason.decode!()
  end
end

# ============================================================================
# Google Sheets API
# ============================================================================

defmodule Sheets do
  @base "https://sheets.googleapis.com/v4/spreadsheets"

  def headers do
    [{"authorization", "Bearer #{GoogleAuth.get_access_token()}"}]
  end

  def get_all_rows do
    sheet = MuscleConfig.sheet_name()
    sid = MuscleConfig.spreadsheet_id()
    url = "#{@base}/#{sid}/values/#{sheet}"

    case Req.get!(url, headers: headers()) do
      %{status: 200, body: %{"values" => values}} -> values
      %{status: 200, body: _} -> []
      %{status: status, body: body} ->
        IO.puts("⚠️  Sheets API error #{status}: #{inspect(body)}")
        []
    end
  end

  def append_row(values) do
    sheet = MuscleConfig.sheet_name()
    sid = MuscleConfig.spreadsheet_id()
    url = "#{@base}/#{sid}/values/#{sheet}:append"

    Req.post!(url,
      headers: headers(),
      params: [valueInputOption: "USER_ENTERED", insertDataOption: "INSERT_ROWS"],
      json: %{"values" => [values]}
    )
  end

  def append_rows(rows) do
    sheet = MuscleConfig.sheet_name()
    sid = MuscleConfig.spreadsheet_id()
    url = "#{@base}/#{sid}/values/#{sheet}:append"

    Req.post!(url,
      headers: headers(),
      params: [valueInputOption: "USER_ENTERED", insertDataOption: "INSERT_ROWS"],
      json: %{"values" => rows}
    )
  end

  def update_range(range, values) do
    sid = MuscleConfig.spreadsheet_id()
    url = "#{@base}/#{sid}/values/#{range}"

    Req.put!(url,
      headers: headers(),
      params: [valueInputOption: "USER_ENTERED"],
      json: %{"values" => [values]}
    )
  end

  def get_data_rows do
    case get_all_rows() do
      [_header | rows] ->
        rows
        |> Enum.with_index(2)
        |> Enum.map(fn {row, idx} -> {idx, row} end)

      _ ->
        []
    end
  end

  # Get distinct names from the sheet
  def get_names do
    get_data_rows()
    |> Enum.map(fn {_idx, row} -> Enum.at(row, 1, "") end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # Get distinct exercises ordered by most recent usage
  def get_exercises_by_recency do
    get_data_rows()
    |> Enum.reverse()
    |> Enum.map(fn {_idx, row} -> Enum.at(row, 2, "") end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def get_last_workout_day_entries(name) do
    name_down = String.downcase(name)
    rows = get_data_rows()

    user_rows =
      rows
      |> Enum.filter(fn {_idx, row} ->
        Enum.at(row, 1, "") |> String.downcase() == name_down
      end)

    if user_rows == [] do
      []
    else
      {_last_idx, last_row} = List.last(user_rows)
      last_date = Enum.at(last_row, 0, "")

      user_rows
      |> Enum.filter(fn {_idx, row} -> Enum.at(row, 0, "") == last_date end)
      |> Enum.map(fn {_idx, row} ->
        # Ensure row has exactly 6 elements by padding with empty strings
        row ++ List.duplicate("", max(0, 6 - length(row)))
      end)
    end
  end
end

# ============================================================================
# Telegram API
# ============================================================================

defmodule Telegram do
  def api(method, params \\ %{}) do
    url = "https://api.telegram.org/bot#{MuscleConfig.telegram_token()}/#{method}"

    case Req.post!(url, json: params, receive_timeout: 60_000) do
      %{status: 200, body: %{"ok" => true, "result" => result}} -> {:ok, result}
      %{body: body} -> {:error, body}
    end
  end

  def send_message(chat_id, text, opts \\ %{}) do
    api("sendMessage", Map.merge(%{chat_id: chat_id, text: text, parse_mode: "HTML"}, opts))
  end

  def answer_callback(callback_id, text \\ "") do
    api("answerCallbackQuery", %{callback_query_id: callback_id, text: text})
  end

  def edit_message(chat_id, msg_id, text, opts \\ %{}) do
    api("editMessageText",
      Map.merge(%{chat_id: chat_id, message_id: msg_id, text: text, parse_mode: "HTML"}, opts)
    )
  end

  def get_updates(offset) do
    api("getUpdates", %{offset: offset, timeout: 30})
  end

  def set_my_commands do
    api("setMyCommands", %{
      commands: [
        %{command: "input", description: "Log a new exercise entry"},
        %{command: "edit", description: "Edit an existing entry"},
        %{command: "query", description: "Query workout history"},
        %{command: "help", description: "Show help"}
      ]
    })
  end

  def inline_keyboard(buttons) do
    %{reply_markup: %{inline_keyboard: buttons}}
  end
end

# ============================================================================
# Bot Logic — conversation state machine
# ============================================================================

defmodule Bot do
  @columns ["date", "name", "exercise", "rep", "set", "load kg"]
  @exercises_per_page 6

  def start do
    IO.puts("🤖 Muscle Bot starting...")
    Telegram.set_my_commands()
    IO.puts("✅ Bot commands registered. Polling for updates...")
    poll(0)
  end

  defp poll(offset) do
    case Telegram.get_updates(offset) do
      {:ok, updates} when is_list(updates) ->
        new_offset =
          Enum.reduce(updates, offset, fn update, _acc ->
            try do
              handle_update(update)
            rescue
              e ->
                IO.puts("⚠️  Error handling update: #{Exception.message(e)}")
                IO.puts(Exception.format_stacktrace(__STACKTRACE__))
            end
            update["update_id"] + 1
          end)

        poll(new_offset)

      {:error, err} ->
        IO.puts("⚠️  Polling error: #{inspect(err)}")
        Process.sleep(5_000)
        poll(offset)
    end
  end

  defp handle_update(%{"message" => msg}) do
    chat_id = msg["chat"]["id"]
    text = msg["text"] || ""
    username = get_in(msg, ["from", "username"]) || ""

    cond do
      String.starts_with?(text, "/input") -> start_input(chat_id, username)
      String.starts_with?(text, "/edit") -> start_edit(chat_id, username)
      String.starts_with?(text, "/query") -> start_query(chat_id)
      String.starts_with?(text, "/help") or String.starts_with?(text, "/start") -> send_help(chat_id)
      String.starts_with?(text, "/cancel") -> cancel(chat_id)
      true -> handle_text_input(chat_id, text, username)
    end
  end

  defp handle_update(%{"callback_query" => cb}) do
    chat_id = cb["message"]["chat"]["id"]
    msg_id = cb["message"]["message_id"]
    data = cb["data"]
    cb_id = cb["id"]
    username = get_in(cb, ["from", "username"]) || ""

    Telegram.answer_callback(cb_id)
    handle_callback(chat_id, msg_id, data, username)
  end

  defp handle_update(_), do: :ok

  # ---- Helpers ----

  defp user_name(username) do
    name = String.downcase(String.trim(username))
    if name == "", do: "unknown", else: name
  end

  defp send_help(chat_id) do
    Telegram.send_message(chat_id, """
    💪 <b>Muscle Bot</b> — Workout Tracker

    /input — Log a new exercise entry
    /edit — Edit an existing entry
    /query — Query workout history
    /cancel — Cancel current operation
    /help — Show this help
    """)
  end

  defp cancel(chat_id) do
    clear_state(chat_id)
    Telegram.send_message(chat_id, "❌ Cancelled.")
  end

  # ============================================================================
  # /input flow: name → exercise (paginated menu) → reps → sets → load → confirm
  # ============================================================================

  defp start_input(chat_id, username) do
    tg_name = user_name(username)
    existing_names = Sheets.get_names()

    cond do
      UsernameMapping.has_mapping?(username) ->
        mapped_name = UsernameMapping.get_mapped_name(username)
        data = %{"date" => Date.to_string(Date.utc_today()), "name" => mapped_name}
        put_state(chat_id, %{flow: :input, step: :exercise_menu, data: data})
        send_exercise_menu(chat_id, 0)

      tg_name in Enum.map(existing_names, &String.downcase/1) ->
        matched = Enum.find(existing_names, fn n -> String.downcase(n) == tg_name end)
        UsernameMapping.save_mapping(username, matched)
        data = %{"date" => Date.to_string(Date.utc_today()), "name" => matched}
        put_state(chat_id, %{flow: :input, step: :exercise_menu, data: data})
        send_exercise_menu(chat_id, 0)

      true ->
        # New user — ask to map to existing name or create new
        put_state(chat_id, %{flow: :input, step: :pick_name, data: %{
          "date" => Date.to_string(Date.utc_today()),
          "tg_name" => tg_name
        }})

        buttons =
          existing_names
          |> Enum.map(fn name ->
            [%{text: name, callback_data: "iname:#{name}"}]
          end)

        buttons = buttons ++ [[%{text: "➕ New: #{tg_name}", callback_data: "iname_new"}]]

        Telegram.send_message(
          chat_id,
          "👤 <b>Who are you?</b>\nPick your name or create new:",
          Telegram.inline_keyboard(buttons)
        )
    end
  end

  defp send_exercise_menu(chat_id, page) do
    exercises = Sheets.get_exercises_by_recency()
    per_page = @exercises_per_page
    total_pages = max(div(length(exercises) + per_page - 1, per_page), 1)
    page = min(page, total_pages - 1)
    page_items = Enum.slice(exercises, page * per_page, per_page)

    buttons =
      page_items
      |> Enum.map(fn ex ->
        # Truncate callback_data to stay under 64 bytes
        short = String.slice(ex, 0, 40)
        [%{text: ex, callback_data: "iex:#{short}"}]
      end)

    # Navigation row
    nav = []
    nav = if page > 0, do: nav ++ [%{text: "⬅️", callback_data: "iex_p:#{page - 1}"}], else: nav
    nav = nav ++ [%{text: "#{page + 1}/#{total_pages}", callback_data: "noop"}]
    nav = if page < total_pages - 1, do: nav ++ [%{text: "➡️", callback_data: "iex_p:#{page + 1}"}], else: nav

    buttons = buttons ++ [
      nav,
      [%{text: "➕ New exercise", callback_data: "iex_new"}],
      [%{text: "📋 Copy last day's workout", callback_data: "input_copy_last"}]
    ]

    Telegram.send_message(
      chat_id,
      "🏋️ <b>Pick exercise:</b>",
      Telegram.inline_keyboard(buttons)
    )
  end

  defp handle_text_input(chat_id, text, _username) do
    case get_state(chat_id) do
      %{flow: :input, step: step, data: data} ->
        handle_input_step(chat_id, step, text, data)

      %{flow: :edit, step: step, data: data} ->
        handle_edit_step(chat_id, step, text, data)

      %{flow: :query, step: step, data: data} ->
        handle_query_step(chat_id, step, text, data)

      _ ->
        :ok
    end
  end

  # Input: new exercise name typed
  defp handle_input_step(chat_id, :new_exercise, text, data) do
    data = Map.put(data, "exercise", String.trim(text))
    put_state(chat_id, %{flow: :input, step: :rep, data: data})
    Telegram.send_message(chat_id, "How many <b>reps</b>?")
  end

  # Input: new name typed
  defp handle_input_step(chat_id, :new_name, text, data) do
    name = String.trim(text)
    data = data |> Map.put("name", name) |> Map.delete("tg_name")
    put_state(chat_id, %{flow: :input, step: :exercise_menu, data: data})
    send_exercise_menu(chat_id, 0)
  end

  defp handle_input_step(chat_id, :rep, text, data) do
    data = Map.put(data, "rep", String.trim(text))
    put_state(chat_id, %{flow: :input, step: :set, data: data})
    Telegram.send_message(chat_id, "How many <b>sets</b>?")
  end

  defp handle_input_step(chat_id, :set, text, data) do
    data = Map.put(data, "set", String.trim(text))
    put_state(chat_id, %{flow: :input, step: :load, data: data})
    Telegram.send_message(chat_id, "Load in <b>kg</b>? (send 0 or - for bodyweight)")
  end

  defp handle_input_step(chat_id, :load, text, data) do
    load = String.trim(text)
    load = if load in ["0", "-", "bw", ""], do: "", else: load
    data = Map.put(data, "load kg", load)

    row = Enum.map(@columns, fn col -> Map.get(data, col, "") end)

    case Sheets.append_row(row) do
      %{status: 200} ->
        clear_state(chat_id)
        Telegram.send_message(chat_id, "✅ Entry saved!\n\n#{format_entry(data)}")

      resp ->
        clear_state(chat_id)
        Telegram.send_message(chat_id, "❌ Failed to save: #{inspect(resp.body)}")
    end
  end

  defp handle_input_step(chat_id, _step, _text, _data) do
    Telegram.send_message(chat_id, "Unexpected input. Use /cancel to restart.")
  end

  # ============================================================================
  # /edit flow
  # ============================================================================

  defp start_edit(chat_id, username) do
    name = UsernameMapping.get_mapped_name(username)
    rows = Sheets.get_data_rows()

    my_rows =
      rows
      |> Enum.filter(fn {_idx, row} ->
        Enum.at(row, 1, "") |> String.downcase() == String.downcase(name)
      end)
      |> Enum.take(-10)

    if my_rows == [] do
      Telegram.send_message(chat_id, "No entries found for <b>#{name}</b>.")
    else
      buttons =
        my_rows
        |> Enum.map(fn {idx, row} ->
          ex = Enum.at(row, 2, "?")
          rep = Enum.at(row, 3, "")
          set = Enum.at(row, 4, "")
          load = Enum.at(row, 5, "")
          load_s = if load in ["", nil], do: "bw", else: "#{load}kg"
          label = "#{ex} #{rep}×#{set} @#{load_s}"
          [%{text: label, callback_data: "edit_row_#{idx}"}]
        end)

      put_state(chat_id, %{flow: :edit, step: :pick_row, data: %{name: name}})

      Telegram.send_message(
        chat_id,
        "📝 <b>Select an entry to edit</b> (last 10):",
        Telegram.inline_keyboard(buttons)
      )
    end
  end

  defp handle_edit_step(chat_id, :enter_value, text, data) do
    col_idx = data.col_idx
    row_idx = data.row_idx
    sheet = MuscleConfig.sheet_name()
    col_letter = Enum.at(~w[A B C D E F], col_idx, "A")
    range = "#{sheet}!#{col_letter}#{row_idx}"

    new_val = String.trim(text)

    case Sheets.update_range(range, [new_val]) do
      %{status: 200} ->
        clear_state(chat_id)
        Telegram.send_message(chat_id, "✅ Updated <b>#{Enum.at(@columns, col_idx)}</b> to <b>#{new_val}</b>.")

      resp ->
        clear_state(chat_id)
        Telegram.send_message(chat_id, "❌ Update failed: #{inspect(resp.body)}")
    end
  end

  defp handle_edit_step(chat_id, _step, _text, _data) do
    Telegram.send_message(chat_id, "Unexpected input. Use /cancel to restart.")
  end

  # ============================================================================
  # /query flow — results grouped by date & name for mobile
  # ============================================================================

  defp start_query(chat_id) do
    put_state(chat_id, %{flow: :query, step: :pick_filter, data: %{}})

    Telegram.send_message(
      chat_id,
      "🔍 <b>Query workout data</b>\nChoose a filter:",
      Telegram.inline_keyboard([
        [%{text: "📅 Today", callback_data: "query_today"}],
        [%{text: "📆 Last 7 days", callback_data: "query_week"}],
        [%{text: "🏋️ By exercise", callback_data: "query_exercise"}],
        [%{text: "📋 Last 20 entries", callback_data: "query_recent"}]
      ])
    )
  end

  defp handle_query_step(chat_id, :enter_exercise, text, _data) do
    exercise = String.trim(text) |> String.downcase()
    rows = Sheets.get_data_rows()

    matches =
      rows
      |> Enum.filter(fn {_idx, row} ->
        String.downcase(Enum.at(row, 2, "")) |> String.contains?(exercise)
      end)
      |> Enum.take(-30)

    clear_state(chat_id)
    send_query_results(chat_id, matches, "exercise \"#{exercise}\"")
  end

  defp handle_query_step(chat_id, _step, _text, _data) do
    Telegram.send_message(chat_id, "Unexpected input. Use /cancel to restart.")
  end

  # ============================================================================
  # Callback handlers
  # ============================================================================

  # -- Input callbacks --

  defp handle_callback(chat_id, _msg_id, "iname:" <> name, username) do
    case get_state(chat_id) do
      %{flow: :input, data: data} ->
        UsernameMapping.save_mapping(username, name)
        data = data |> Map.put("name", name) |> Map.delete("tg_name")
        put_state(chat_id, %{flow: :input, step: :exercise_menu, data: data})
        send_exercise_menu(chat_id, 0)
      _ ->
        Telegram.send_message(chat_id, "Session expired. Send /input again.")
    end
  end

  defp handle_callback(chat_id, _msg_id, "iname_new", username) do
    case get_state(chat_id) do
      %{flow: :input, data: data} ->
        tg_name = Map.get(data, "tg_name", "")
        UsernameMapping.save_mapping(username, tg_name)
        data = data |> Map.put("name", tg_name) |> Map.delete("tg_name")
        put_state(chat_id, %{flow: :input, step: :exercise_menu, data: data})
        send_exercise_menu(chat_id, 0)
      _ ->
        Telegram.send_message(chat_id, "Session expired. Send /input again.")
    end
  end

  defp handle_callback(chat_id, _msg_id, "iex:" <> exercise, _username) do
    case get_state(chat_id) do
      %{flow: :input, data: data} ->
        # Resolve full name from sheet if truncated
        full = resolve_exercise(exercise)
        data = Map.put(data, "exercise", full)
        put_state(chat_id, %{flow: :input, step: :rep, data: data})
        Telegram.send_message(chat_id, "🏋️ <b>#{full}</b>\nHow many <b>reps</b>?")
      _ ->
        Telegram.send_message(chat_id, "Session expired. Send /input again.")
    end
  end

  defp handle_callback(chat_id, msg_id, "iex_p:" <> page_str, _username) do
    page = String.to_integer(page_str)
    # Edit the existing message with the new page
    exercises = Sheets.get_exercises_by_recency()
    per_page = @exercises_per_page
    total_pages = max(div(length(exercises) + per_page - 1, per_page), 1)
    page = min(page, total_pages - 1)
    page_items = Enum.slice(exercises, page * per_page, per_page)

    buttons =
      page_items
      |> Enum.map(fn ex ->
        short = String.slice(ex, 0, 40)
        [%{text: ex, callback_data: "iex:#{short}"}]
      end)

    nav = []
    nav = if page > 0, do: nav ++ [%{text: "⬅️", callback_data: "iex_p:#{page - 1}"}], else: nav
    nav = nav ++ [%{text: "#{page + 1}/#{total_pages}", callback_data: "noop"}]
    nav = if page < total_pages - 1, do: nav ++ [%{text: "➡️", callback_data: "iex_p:#{page + 1}"}], else: nav

    buttons = buttons ++ [
      nav,
      [%{text: "➕ New exercise", callback_data: "iex_new"}],
      [%{text: "📋 Copy last day's workout", callback_data: "input_copy_last"}]
    ]

    Telegram.edit_message(
      chat_id, msg_id,
      "🏋️ <b>Pick exercise:</b>",
      Telegram.inline_keyboard(buttons)
    )
  end

  defp handle_callback(chat_id, _msg_id, "iex_new", _username) do
    case get_state(chat_id) do
      %{flow: :input} = state ->
        put_state(chat_id, %{state | step: :new_exercise})
        Telegram.send_message(chat_id, "Type the new exercise name:")
      _ ->
        Telegram.send_message(chat_id, "Session expired. Send /input again.")
    end
  end

  defp handle_callback(chat_id, _msg_id, "input_copy_last", _username) do
    case get_state(chat_id) do
      %{flow: :input, data: %{"name" => name} = data} ->
        case Sheets.get_last_workout_day_entries(name) do
          [] ->
            Telegram.send_message(chat_id, "⚠️ No previous workout found for <b>#{name}</b>.")

          last_entries ->
            today = Date.to_string(Date.utc_today())
            new_entries =
              last_entries
              |> Enum.map(fn row ->
                List.replace_at(row, 0, today)
              end)

            formatted =
              new_entries
              |> Enum.map(fn row ->
                ex = Enum.at(row, 2, "?")
                rep = Enum.at(row, 3, "?")
                set = Enum.at(row, 4, "?")
                load = Enum.at(row, 5, "")
                load_s = if load in ["", nil], do: "", else: " @ #{load}kg"
                "• #{ex}  #{rep}×#{set}#{load_s}"
              end)
              |> Enum.join("\n")

            msg = """
            📋 <b>Copy last workout to today?</b>

            #{formatted}

            Confirm copying these entries to today (<b>#{today}</b>)?
            """

            put_state(chat_id, %{flow: :input, step: :confirm_copy_last, data: Map.put(data, "copy_entries", new_entries)})

            Telegram.send_message(
              chat_id,
              msg,
              Telegram.inline_keyboard([
                [
                  %{text: "✅ Copy & Save", callback_data: "input_copy_confirm"},
                  %{text: "❌ Cancel", callback_data: "input_cancel"}
                ]
              ])
            )
        end

      _ ->
        Telegram.send_message(chat_id, "Session expired. Send /input again.")
    end
  end

  defp handle_callback(chat_id, _msg_id, "input_copy_confirm", _username) do
    case get_state(chat_id) do
      %{flow: :input, step: :confirm_copy_last, data: %{"copy_entries" => new_entries}} ->
        case Sheets.append_rows(new_entries) do
          %{status: 200} ->
            clear_state(chat_id)
            formatted =
              new_entries
              |> Enum.map(fn row ->
                ex = Enum.at(row, 2, "?")
                rep = Enum.at(row, 3, "?")
                set = Enum.at(row, 4, "?")
                load = Enum.at(row, 5, "")
                load_s = if load in ["", nil], do: "", else: " @ #{load}kg"
                "• #{ex}  #{rep}×#{set}#{load_s}"
              end)
              |> Enum.join("\n")

            Telegram.send_message(
              chat_id,
              "✅ <b>Copied last workout successfully!</b>\n\n#{formatted}"
            )

          resp ->
            clear_state(chat_id)
            Telegram.send_message(chat_id, "❌ Failed to copy workout: #{inspect(resp.body)}")
        end

      _ ->
        Telegram.send_message(chat_id, "No pending copy operation. Use /input to start.")
    end
  end

  defp handle_callback(chat_id, _msg_id, "input_confirm", _username) do
    case get_state(chat_id) do
      %{flow: :input, step: :confirm, data: data} ->
        row = Enum.map(@columns, fn col -> Map.get(data, col, "") end)

        case Sheets.append_row(row) do
          %{status: 200} ->
            clear_state(chat_id)
            Telegram.send_message(chat_id, "✅ Entry saved!\n\n#{format_entry(data)}")

          resp ->
            clear_state(chat_id)
            Telegram.send_message(chat_id, "❌ Failed to save: #{inspect(resp.body)}")
        end

      _ ->
        Telegram.send_message(chat_id, "No pending entry. Use /input to start.")
    end
  end

  defp handle_callback(chat_id, _msg_id, "input_cancel", _username) do
    cancel(chat_id)
  end

  # -- Edit callbacks --

  defp handle_callback(chat_id, _msg_id, "edit_row_" <> row_idx_str, _username) do
    row_idx = String.to_integer(row_idx_str)

    buttons =
      @columns
      |> Enum.with_index()
      |> Enum.map(fn {col, idx} ->
        [%{text: col, callback_data: "edit_col_#{row_idx}_#{idx}"}]
      end)

    case get_state(chat_id) do
      %{} = state ->
        put_state(chat_id, %{state | step: :pick_col, data: Map.put(state.data, :row_idx, row_idx)})
      _ -> nil
    end

    Telegram.send_message(
      chat_id,
      "Which field do you want to edit?",
      Telegram.inline_keyboard(buttons)
    )
  end

  defp handle_callback(chat_id, _msg_id, "edit_col_" <> rest, _username) do
    [row_idx_str, col_idx_str] = String.split(rest, "_")
    row_idx = String.to_integer(row_idx_str)
    col_idx = String.to_integer(col_idx_str)
    col_name = Enum.at(@columns, col_idx)

    case get_state(chat_id) do
      %{} = state ->
        put_state(chat_id, %{
          state
          | step: :enter_value,
            data: Map.merge(state.data, %{row_idx: row_idx, col_idx: col_idx})
        })
        Telegram.send_message(chat_id, "Enter new value for <b>#{col_name}</b>:")
      _ ->
        Telegram.send_message(chat_id, "Session expired. Please send /edit again.")
    end
  end

  # -- Query callbacks --

  defp handle_callback(chat_id, _msg_id, "query_today", _username) do
    today = Date.to_string(Date.utc_today())
    rows = Sheets.get_data_rows()

    matches =
      rows
      |> Enum.filter(fn {_idx, row} -> Enum.at(row, 0, "") == today end)

    clear_state(chat_id)
    send_query_results(chat_id, matches, "today (#{today})")
  end

  defp handle_callback(chat_id, _msg_id, "query_week", _username) do
    week_ago = Date.add(Date.utc_today(), -7) |> Date.to_string()
    rows = Sheets.get_data_rows()

    matches =
      rows
      |> Enum.filter(fn {_idx, row} -> Enum.at(row, 0, "") >= week_ago end)

    clear_state(chat_id)
    send_query_results(chat_id, matches, "last 7 days")
  end

  defp handle_callback(chat_id, _msg_id, "query_exercise", _username) do
    case get_state(chat_id) do
      %{} = state ->
        put_state(chat_id, %{state | step: :enter_exercise})
        Telegram.send_message(chat_id, "Enter exercise name (or part of it) to search:")
      _ ->
        Telegram.send_message(chat_id, "Session expired. Please send /query again.")
    end
  end

  defp handle_callback(chat_id, _msg_id, "query_recent", _username) do
    rows = Sheets.get_data_rows()
    matches = Enum.take(rows, -20)

    clear_state(chat_id)
    send_query_results(chat_id, matches, "last 20 entries")
  end

  defp handle_callback(_chat_id, _msg_id, "noop", _username), do: :ok
  defp handle_callback(_chat_id, _msg_id, _data, _username), do: :ok

  # ============================================================================
  # Display helpers
  # ============================================================================

  defp format_entry(data) do
    load = if data["load kg"] in ["", nil], do: "bodyweight", else: "#{data["load kg"]} kg"

    """
    📋 <b>#{data["exercise"]}</b>
    #{data["date"]} · #{data["name"]}
    #{data["rep"]} reps × #{data["set"]} sets · #{load}
    """
  end

  # Resolve a possibly-truncated exercise name back to full
  defp resolve_exercise(short) do
    Sheets.get_exercises_by_recency()
    |> Enum.find(short, fn ex -> String.starts_with?(ex, short) end)
  end

  # Query results: grouped by date & name, mobile-friendly
  defp send_query_results(chat_id, matches, label) do
    if matches == [] do
      Telegram.send_message(chat_id, "No results for <b>#{label}</b>.")
    else
      # Group by {date, name}
      grouped =
        matches
        |> Enum.group_by(fn {_idx, row} ->
          {Enum.at(row, 0, "?"), Enum.at(row, 1, "?")}
        end)
        |> Enum.sort_by(fn {{date, _name}, _rows} -> date end)

      text =
        grouped
        |> Enum.map(fn {{date, name}, rows} ->
          header = "📅 <b>#{date}</b> · #{name}"
          entries =
            rows
            |> Enum.map(fn {_idx, row} ->
              ex = Enum.at(row, 2, "?")
              rep = Enum.at(row, 3, "?")
              set = Enum.at(row, 4, "?")
              load = Enum.at(row, 5, "")
              load_s = if load in ["", nil], do: "", else: "  #{load}kg"
              "  #{ex}  #{rep}×#{set}#{load_s}"
            end)
            |> Enum.join("\n")
          "#{header}\n#{entries}"
        end)
        |> Enum.join("\n\n")

      msg = "🔍 <b>#{label}</b> — #{length(matches)} entries\n\n#{text}"

      # Telegram message limit is 4096 chars
      if String.length(msg) > 4000 do
        msg
        |> chunk_message(4000)
        |> Enum.each(fn chunk -> Telegram.send_message(chat_id, chunk) end)
      else
        Telegram.send_message(chat_id, msg)
      end
    end
  end

  defp chunk_message(text, max_len) do
    lines = String.split(text, "\n")
    chunk_lines(lines, max_len, "", [])
  end

  defp chunk_lines([], _max, current, acc) do
    if current == "", do: Enum.reverse(acc), else: Enum.reverse([current | acc])
  end

  defp chunk_lines([line | rest], max, current, acc) do
    candidate = if current == "", do: line, else: current <> "\n" <> line
    if String.length(candidate) > max do
      chunk_lines([line | rest], max, "", [current | acc])
    else
      chunk_lines(rest, max, candidate, acc)
    end
  end

  # ============================================================================
  # Per-chat state (ETS)
  # ============================================================================

  def init_state do
    :ets.new(:bot_state, [:named_table, :public, :set])
  end

  defp get_state(chat_id) do
    case :ets.lookup(:bot_state, chat_id) do
      [{^chat_id, state}] -> state
      _ -> nil
    end
  end

  defp put_state(chat_id, state) do
    :ets.insert(:bot_state, {chat_id, state})
  end

  defp clear_state(chat_id) do
    :ets.delete(:bot_state, chat_id)
  end
end

# ============================================================================
# Main
# ============================================================================

Bot.init_state()
Bot.start()
